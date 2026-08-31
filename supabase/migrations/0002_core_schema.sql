-- 0002_core_schema.sql
-- Ate backend — Wave 0, BE-2: core tables, types, indexes, constraints.
--
-- Grounded in docs/backend/data-model.md (§1–§5) and the client data layer
-- (src/data/types.ts, store.ts, fixtures.ts). Every entity is a first-class row
-- with a surrogate UUID PK (data-model §3). Restaurants are Google-Places-backed;
-- dishes are UGC shared globally; identity rules per §0/§3.
--
-- PK note: the model prefers UUID v7 (time-sortable) but Postgres has no native
-- v7 generator pre-PG18; we use gen_random_uuid() (v4) — the client mints its own
-- ids optimistically anyway (data-model §3, store.ts newId()), so index locality
-- on the feed is handled by the (created_at, id) keyset indexes below, not by id
-- ordering. Revisit with pg_uuidv7 if feed index bloat ever bites.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- profiles — 1:1 with auth.users (data-model §1.1; integration-design Schema)
-- The seeded "me" becomes the authenticated row on first sign-in.
-- Derived counts (reviews/followers/following/dishes_reviewed) are NOT stored
-- here as truth; follower_count/following_count/review_count are denormalised
-- caches maintained by triggers (0005) — rebuildable from the edge tables.
-- ---------------------------------------------------------------------------
create table public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  username        citext not null unique,
  name            text   not null,
  avatar_url      text,
  bio             text,
  created_at      timestamptz not null default now(),
  -- soft-delete tombstone (data-model §4, §9.C: account deletion = soft-delete)
  deleted_at      timestamptz,
  -- denormalised counter caches (data-model §5 derived-count caching)
  follower_count  integer not null default 0,
  following_count integer not null default 0,
  review_count    integer not null default 0,
  constraint profiles_username_format check (length(username) between 1 and 30)
);

comment on table public.profiles is
  'User profiles, 1:1 with auth.users. Counts are denormalised caches (rebuildable from edges).';

-- ---------------------------------------------------------------------------
-- restaurants — Google-Places-backed reference data (data-model §1.2)
-- Natural key google_place_id UNIQUE; upsert target for the "resolve Place → row"
-- write path. location is geography(Point,4326) for the "nearby" KNN query.
-- avg_rating/review_count are DERIVED (mean of per-dish averages) — exposed via
-- a view (0005), NOT stored here.
-- ---------------------------------------------------------------------------
create table public.restaurants (
  id              uuid primary key default gen_random_uuid(),
  google_place_id text not null unique,
  name            text not null,
  address         text,
  city            text not null,
  location        geography(Point, 4326),
  cuisine         text,
  cover_url       text,
  created_at      timestamptz not null default now()
);

comment on table public.restaurants is
  'Google-Places-backed catalogue. avg_rating/review_count are derived (see restaurant_stats view).';

-- GIST index for ST_DWithin / KNN ordering (data-model §4, §5 nearby pattern)
create index restaurants_location_gix on public.restaurants using gist (location);
-- trigram search on name (search screen, data-model §5)
create index restaurants_name_trgm on public.restaurants using gin (name extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- dishes — UGC, shared globally (data-model §1.3)
-- Identity = (name, restaurant_id), enforced by a PARTIAL unique index that
-- excludes tombstones so a merged dish can coexist with its survivor (§3).
-- merged_into_dish_id is the dedup tombstone (self-ref FK, §4).
-- score (avg) / reviews (count) are DERIVED — exposed via dish_stats view (0005).
-- ---------------------------------------------------------------------------
create table public.dishes (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  restaurant_id       uuid not null references public.restaurants(id) on delete cascade,
  created_by_user_id  uuid references public.profiles(id) on delete set null,
  merged_into_dish_id uuid references public.dishes(id) on delete set null,
  -- category is FREE TEXT (lead decision E-3) — not an enum; menus may grow.
  category            text,
  photo_url           text,
  created_at          timestamptz not null default now(),
  -- a dish cannot be its own tombstone
  constraint dishes_no_self_merge check (merged_into_dish_id is null or merged_into_dish_id <> id)
);

comment on table public.dishes is
  'UGC dishes, shared globally. Identity (name, restaurant_id) for LIVE rows only. Tombstones redirect via merged_into_dish_id.';
comment on column public.dishes.category is 'Free text (Meats/Sides/Sweets/Mains observed) — intentionally not an enum.';

-- The §3 partial UNIQUE: one live dish per (name, restaurant_id); tombstones excluded.
-- Case-insensitive on name (lower()) so "Brisket" / "brisket" collide as intended.
create unique index dishes_identity_uq
  on public.dishes (restaurant_id, lower(name))
  where merged_into_dish_id is null;

create index dishes_restaurant_idx on public.dishes (restaurant_id);
create index dishes_merged_into_idx on public.dishes (merged_into_dish_id) where merged_into_dish_id is not null;
create index dishes_name_trgm on public.dishes using gin (name extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- reviews — the atomic unit (data-model §1.4)
-- restaurant_id is denormalised from the dish for fast "reviews by restaurant",
-- and a trigger (0005) keeps it == dishes.restaurant_id. score is half-steps
-- 0.5..5.0 (§4 CHECK). like_count/comment_count are denormalised caches.
-- ---------------------------------------------------------------------------
create table public.reviews (
  id            uuid primary key default gen_random_uuid(),
  reviewer_id   uuid not null references public.profiles(id) on delete cascade,
  dish_id       uuid not null references public.dishes(id) on delete cascade,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  score         numeric(2,1) not null,
  note          text,
  photo_url     text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  like_count    integer not null default 0,
  comment_count integer not null default 0,
  -- half-step rating scale (data-model §4; compose.tsx enforces >= 0.5)
  constraint reviews_score_halfstep check (score >= 0.5 and score <= 5.0 and (score * 2) = floor(score * 2))
);

comment on table public.reviews is
  'Atomic dish review. restaurant_id denormalised from dish (kept consistent by trigger). like/comment counts are caches.';

-- feed + diary + dish-stream access patterns (data-model §5) — keyset on (created_at, id)
create index reviews_created_idx     on public.reviews (created_at desc, id desc);
create index reviews_reviewer_idx    on public.reviews (reviewer_id, created_at desc, id desc);
create index reviews_dish_idx        on public.reviews (dish_id, created_at desc, id desc);
create index reviews_restaurant_idx  on public.reviews (restaurant_id);

-- ---------------------------------------------------------------------------
-- comments (data-model §1.5) — like_count denormalised cache
-- ---------------------------------------------------------------------------
create table public.comments (
  id          uuid primary key default gen_random_uuid(),
  review_id   uuid not null references public.reviews(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  text        text not null,
  created_at  timestamptz not null default now(),
  like_count  integer not null default 0,
  constraint comments_text_nonempty check (length(btrim(text)) > 0)
);

-- comments(review_id, created_at ASC) — the comments sheet reads oldest-first
create index comments_review_idx on public.comments (review_id, created_at asc, id asc);

-- ---------------------------------------------------------------------------
-- lists (data-model §1.6) — saved lists / collections
-- The default "Saved" list is is_system + pinned, auto-created per user (0005).
-- dishCount/meta/byline are DERIVED (view / on-the-wire), not stored.
-- ---------------------------------------------------------------------------
create table public.lists (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles(id) on delete cascade,
  name        text not null,
  description text,
  cover_url   text,
  pinned      boolean not null default false,
  is_system   boolean not null default false,
  created_at  timestamptz not null default now()
);

create index lists_owner_idx on public.lists (owner_id);
-- exactly one system ("Saved") list per user
create unique index lists_one_system_per_owner on public.lists (owner_id) where is_system;

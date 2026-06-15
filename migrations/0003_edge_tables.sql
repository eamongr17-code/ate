-- 0003_edge_tables.sql
-- Ate backend — Wave 0, BE-3: edge / join tables (the M:N relationships).
-- data-model §1.7–§1.10. PKs are the composite (actor, target) pairs so a
-- double-action is a no-op (matches the client's idempotent toggles).

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- follows — the social graph (data-model §1.7). M:N self-ref on profiles.
-- ---------------------------------------------------------------------------
create table public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  followee_id uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, followee_id),
  constraint follows_no_self check (follower_id <> followee_id)
);

-- follow-by-followee lookups (followers screen + follower_count rebuild)
create index follows_followee_idx on public.follows (followee_id);

-- ---------------------------------------------------------------------------
-- review_likes (data-model §1.8). M:N profiles↔reviews.
-- ---------------------------------------------------------------------------
create table public.review_likes (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  review_id  uuid not null references public.reviews(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, review_id)
);

create index review_likes_review_idx on public.review_likes (review_id);

-- ---------------------------------------------------------------------------
-- comment_likes (data-model §1.9). M:N profiles↔comments.
-- ---------------------------------------------------------------------------
create table public.comment_likes (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  comment_id uuid not null references public.comments(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, comment_id)
);

create index comment_likes_comment_idx on public.comment_likes (comment_id);

-- ---------------------------------------------------------------------------
-- list_dishes — list membership (data-model §1.10). M:N lists↔dishes.
-- Keyed by dish_id (NOT dish name). "save = list membership" (§9.C) — a save is
-- membership in the owner's system list; no separate saves table.
-- position supports ranked lists ("definitive ranked brisket list").
-- ---------------------------------------------------------------------------
create table public.list_dishes (
  list_id   uuid not null references public.lists(id) on delete cascade,
  dish_id   uuid not null references public.dishes(id) on delete cascade,
  position  integer,
  added_at  timestamptz not null default now(),
  primary key (list_id, dish_id)
);

-- membership lookups both directions (list contents + "is this dish saved anywhere")
create index list_dishes_dish_idx on public.list_dishes (dish_id);

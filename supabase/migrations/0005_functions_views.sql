-- 0005_functions_views.sql
-- Ate backend — Wave 0, BE-5: derived views, counter triggers, new-user
-- provisioning, feed RPC, soft-delete RPC.
-- data-model §1.2 (restaurant rating = MEAN OF PER-DISH AVERAGES), §5 (feed +
-- derived-count caching), §4 (soft-delete), integration-design (get_feed, trigger).

set search_path = public, extensions;

-- ===========================================================================
-- DERIVED VIEWS (read-time aggregates — the honest "derived" path, PV5-5)
-- These are computed on read. The denormalised counter COLUMNS (like_count,
-- follower_count, …) are the cached path maintained by triggers below; the views
-- here are the source-of-truth derivations used where freshness matters
-- (restaurant/dish stat pages are not hot like the feed).
-- ===========================================================================

-- dish_stats: per-dish average score + review count.
-- score = NULL when the dish has zero reviews (the "want-to-try / ?/5" state,
-- data-model §1.3 note). Tombstoned dishes are excluded from the live catalogue.
create or replace view public.dish_stats
with (security_invoker = true) as
  select
    d.id              as dish_id,
    d.restaurant_id,
    round(avg(r.score), 1)::numeric(2,1) as score,   -- NULL when no reviews
    count(r.id)::int  as review_count
  from public.dishes d
  left join public.reviews r on r.dish_id = d.id
  where d.merged_into_dish_id is null
  group by d.id, d.restaurant_id;

comment on view public.dish_stats is
  'Per-dish derived avg score (NULL = unrated) + review count. Live dishes only.';

-- restaurant_stats: rating = MEAN OF PER-DISH AVERAGES (data-model §1.2 — DECIDED).
-- Each dish counts once; dishes with no reviews (score NULL) are excluded from the
-- mean. review_count is the TOTAL review count across the restaurant (unchanged by
-- the rating-derivation decision, §1.2).
-- NOTE: this DIVERGES from the current client (useRestaurantStats averages all
-- reviews flat, store.ts:369-371) — the FE selector change is a coordinated
-- contract move, sequenced through the lead.
create or replace view public.restaurant_stats
with (security_invoker = true) as
  select
    rst.id as restaurant_id,
    -- mean of the per-dish averages (each dish once; NULL-score dishes excluded)
    round(avg(ds.score) filter (where ds.score is not null), 1)::numeric(2,1) as avg_rating,
    coalesce(sum(ds.review_count), 0)::int as review_count
  from public.restaurants rst
  left join public.dish_stats ds on ds.restaurant_id = rst.id
  group by rst.id;

comment on view public.restaurant_stats is
  'Restaurant rating = MEAN OF PER-DISH AVERAGES (data-model §1.2). Diverges from current client selector.';

-- views are read by the client; grant SELECT (RLS on the underlying tables still
-- applies because the views are security_invoker).
grant select on public.dish_stats       to authenticated, anon;
grant select on public.restaurant_stats to authenticated, anon;

-- ===========================================================================
-- DISH RESOLUTION — follow a merge tombstone to the live survivor (data-model §4)
-- One-hop-plus: resolves transitively (chains flattened) up to a safety bound.
-- ===========================================================================
create or replace function public.resolve_dish(p_dish_id uuid)
returns uuid
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
declare
  cur   uuid := p_dish_id;
  nxt   uuid;
  hops  int  := 0;
begin
  loop
    select merged_into_dish_id into nxt from public.dishes where id = cur;
    if nxt is null then
      return cur;            -- live survivor
    end if;
    cur := nxt;
    hops := hops + 1;
    if hops > 16 then
      return cur;            -- safety bound against a pathological cycle
    end if;
  end loop;
end;
$$;

comment on function public.resolve_dish(uuid) is
  'Follows merged_into_dish_id chains to the live survivor (data-model §4 redirect).';

-- ===========================================================================
-- COUNTER-CACHE TRIGGERS (data-model §5 derived-count caching)
-- Counts are derived-in-truth (rebuildable from the edge/child tables) but cached
-- on the parent row for hot reads (feed/profile). Each trigger mirrors exactly how
-- the client keeps inline counts in sync on toggle (store.ts:169,182,194).
-- ===========================================================================

-- review_likes → reviews.like_count
create or replace function public.trg_review_like_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.reviews set like_count = like_count + 1 where id = new.review_id;
  elsif tg_op = 'DELETE' then
    update public.reviews set like_count = greatest(0, like_count - 1) where id = old.review_id;
  end if;
  return null;
end; $$;
create trigger review_likes_count_aiud
  after insert or delete on public.review_likes
  for each row execute function public.trg_review_like_count();

-- comments → reviews.comment_count
create or replace function public.trg_review_comment_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.reviews set comment_count = comment_count + 1 where id = new.review_id;
  elsif tg_op = 'DELETE' then
    update public.reviews set comment_count = greatest(0, comment_count - 1) where id = old.review_id;
  end if;
  return null;
end; $$;
create trigger comments_count_aiud
  after insert or delete on public.comments
  for each row execute function public.trg_review_comment_count();

-- comment_likes → comments.like_count
create or replace function public.trg_comment_like_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.comments set like_count = like_count + 1 where id = new.comment_id;
  elsif tg_op = 'DELETE' then
    update public.comments set like_count = greatest(0, like_count - 1) where id = old.comment_id;
  end if;
  return null;
end; $$;
create trigger comment_likes_count_aiud
  after insert or delete on public.comment_likes
  for each row execute function public.trg_comment_like_count();

-- follows → profiles.follower_count / following_count
create or replace function public.trg_follow_counts()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.profiles set following_count = following_count + 1 where id = new.follower_id;
    update public.profiles set follower_count  = follower_count  + 1 where id = new.followee_id;
  elsif tg_op = 'DELETE' then
    update public.profiles set following_count = greatest(0, following_count - 1) where id = old.follower_id;
    update public.profiles set follower_count  = greatest(0, follower_count  - 1) where id = old.followee_id;
  end if;
  return null;
end; $$;
create trigger follows_counts_aiud
  after insert or delete on public.follows
  for each row execute function public.trg_follow_counts();

-- reviews → profiles.review_count (authored-review count, data-model §1.1)
create or replace function public.trg_review_author_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.profiles set review_count = review_count + 1 where id = new.reviewer_id;
  elsif tg_op = 'DELETE' then
    update public.profiles set review_count = greatest(0, review_count - 1) where id = old.reviewer_id;
  end if;
  return null;
end; $$;
create trigger reviews_author_count_aiud
  after insert or delete on public.reviews
  for each row execute function public.trg_review_author_count();

-- ===========================================================================
-- REVIEW INTEGRITY: keep reviews.restaurant_id == dishes.restaurant_id and bump
-- updated_at on edit (data-model §1.4). The client supplies dish_id; we derive
-- restaurant_id from the dish so the denormalisation can never drift.
-- ===========================================================================
create or replace function public.trg_review_set_restaurant()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  rid uuid;
begin
  select restaurant_id into rid from public.dishes where id = new.dish_id;
  if rid is null then
    raise exception 'review references unknown dish_id %', new.dish_id;
  end if;
  new.restaurant_id := rid;          -- always authoritative, ignore any client value
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  return new;
end; $$;
create trigger reviews_set_restaurant_biu
  before insert or update on public.reviews
  for each row execute function public.trg_review_set_restaurant();

-- ===========================================================================
-- NEW-USER PROVISIONING (data-model §3 step 2; integration-design "New-user")
-- On auth.users insert, create the matching profiles row + the system "Saved"
-- list. username/name come from the sign-up metadata; fall back to a derived
-- handle so the trigger never fails a sign-up. SECURITY DEFINER (runs as owner,
-- not the signing-up user) so it can write the profile + list.
-- ===========================================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  v_username citext;
  v_name     text;
  v_base     text;
  v_try      int := 0;
begin
  v_name := coalesce(nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
                     split_part(new.email, '@', 1),
                     'Ate user');
  v_base := coalesce(nullif(btrim(new.raw_user_meta_data ->> 'username'), ''),
                     split_part(new.email, '@', 1),
                     'user');
  -- sanitise to a handle-safe slug
  v_base := regexp_replace(lower(v_base), '[^a-z0-9_]', '', 'g');
  if v_base = '' then v_base := 'user'; end if;
  v_username := left(v_base, 30);

  -- ensure uniqueness (append a counter on collision)
  while exists (select 1 from public.profiles where username = v_username) loop
    v_try := v_try + 1;
    v_username := left(v_base, 26) || v_try::text;
  end loop;

  insert into public.profiles (id, username, name, avatar_url, bio)
  values (new.id, v_username, v_name,
          new.raw_user_meta_data ->> 'avatar_url',
          new.raw_user_meta_data ->> 'bio');

  -- auto-create the system "Saved" list (data-model §1.6, §9.C save=list-membership)
  insert into public.lists (owner_id, name, pinned, is_system)
  values (new.id, 'Saved', true, true);

  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ===========================================================================
-- get_feed RPC — fan-out-on-read + KEYSET pagination (data-model §5)
-- Returns reviews authored by people the caller follows, EXCLUDING the caller's
-- own (those live in the diary — matches useFeed, store.ts:313). Keyset cursor on
-- (created_at, id) — NOT offset. Default page 30.
-- SECURITY INVOKER so RLS still applies to the underlying rows.
-- ===========================================================================
create or replace function public.get_feed(
  cursor_created_at timestamptz default null,
  cursor_id         uuid        default null,
  page_size         int         default 30
)
returns setof public.reviews
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select r.*
  from public.reviews r
  join public.follows f
    on f.followee_id = r.reviewer_id
   and f.follower_id = (select auth.uid())
  where r.reviewer_id <> (select auth.uid())
    and (
      cursor_created_at is null
      or (r.created_at, r.id) < (cursor_created_at, cursor_id)
    )
  order by r.created_at desc, r.id desc
  limit least(greatest(page_size, 1), 100);
$$;

comment on function public.get_feed(timestamptz, uuid, int) is
  'Following feed, fan-out-on-read, keyset paginated on (created_at,id). Excludes own posts.';

-- ===========================================================================
-- restaurants_nearby RPC — the "nearby" access pattern (data-model §5).
-- KNN ordering by distance from the caller's point, using the GIST index on
-- restaurants.location. Returns each restaurant + its distance in metres.
-- SECURITY INVOKER so RLS applies (restaurants are public-read to authed users).
-- ===========================================================================
create or replace function public.restaurants_nearby(
  p_lat       double precision,
  p_lng       double precision,
  p_radius_m  double precision default 50000,
  page_size   int default 30
)
returns table (
  id              uuid,
  google_place_id text,
  name            text,
  address         text,
  city            text,
  cuisine         text,
  cover_url       text,
  distance_m      double precision
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select r.id, r.google_place_id, r.name, r.address, r.city, r.cuisine, r.cover_url,
         extensions.ST_Distance(r.location, extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::geography) as distance_m
  from public.restaurants r
  where r.location is not null
    and extensions.ST_DWithin(
          r.location,
          extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::geography,
          p_radius_m)
  order by r.location <-> extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::geography
  limit least(greatest(page_size, 1), 100);
$$;

comment on function public.restaurants_nearby(double precision, double precision, double precision, int) is
  'Restaurants within radius of a point, KNN-ordered by distance (data-model §5 nearby). Uses the GIST index.';

-- ===========================================================================
-- deactivate_account RPC — SOFT-delete (data-model §4, §9.C)
-- Tombstones the caller's profile (deleted_at) without dropping the shared dish/
-- rating data the flywheel depends on, and without breaking others' comment
-- threads. Hard cascade is NOT used for accounts.
-- ===========================================================================
create or replace function public.deactivate_account()
returns void
language plpgsql
volatile
security invoker
set search_path = public, extensions
as $$
begin
  update public.profiles
    set deleted_at = now()
  where id = (select auth.uid())
    and deleted_at is null;
end; $$;

comment on function public.deactivate_account() is
  'Soft-delete the caller''s account (tombstone). Preserves shared dish/rating data.';

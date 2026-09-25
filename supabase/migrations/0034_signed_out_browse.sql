-- 0034_signed_out_browse.sql
-- Ate backend — "See what everyone's eating" (design/v1 Welcome): a signed-out, read-only browse of
-- the feed, a place, a dish and someone's profile. Until now every one of those reads was
-- `authenticated`-only, so the signed-out path errored.
--
-- DEPENDS ON 0033 (every entry is public). Apply in order; never on its own.
--
-- WHAT ANON CAN NOW DO — EXECUTE on nine public RPCs, and nothing else:
--   get_entry_feed · get_entries_by_author · get_entries_at_place · place_summary · place_dishes ·
--   dish_summary · get_dish_reviews · profile_summary · is_dish_saved
-- WHAT ANON STILL CANNOT DO — select any table or view directly (RLS/grants untouched: a raw
--   `restaurants` read is still `[]`, `entries`/`entry_cards`/`profiles` are still refused), call any
--   write, search, stats, saves, block or report RPC, or see any column the signed-in read does not
--   already print (no email — it is in auth.users, which none of these touch — no entry_seq,
--   deleted_at, sort_plan or score_evidence).
--
-- HOW, AND WHY NOT THE OBVIOUS WAY. The obvious way — grant anon SELECT on entries/reviews/profiles/…
-- and add `to anon` policies — would hand anon the raw tables through PostgREST (and a column-grant
-- list that has to track every view forever). Instead the nine reads DISPATCH on the role:
--   * signed in: the existing SECURITY INVOKER query, unchanged, still under RLS (blocks);
--   * anon: a SECURITY DEFINER twin in a schema PostgREST does not expose (`browse`), which calls
--     the same public read as its owner — so there is ONE query per read, not two to keep in step —
--     and pins what "no viewer" means: is_mine/is_me/saved = false, my_visits = 0, my_last_visit/
--     my_last_score = NULL, the 'mine' scope empty, public entries only. No blocks: there is no viewer.
--
-- WIRE IMPACT
--   ADDITIVE for anon (a 401/42501 becomes rows). NOTHING changes for a signed-in caller: same
--   parameters, same OUT columns, same query. Grants to `authenticated` survive create-or-replace.
--   Client note: several AteKit readers still call `requireCurrentUserID()` before these RPCs
--   (EntryFeedClient.feedPage, ProfileClient.entriesPage, PlacePageClient.entriesAtPlace,
--   DishPageClient.dishReviews); the signed-out path has to skip that guard.
--   NOT COVERED: the Entry page reads the `entry_cards` VIEW directly, which anon still cannot. A
--   signed-out tap on a feed slip needs either the sign-in prompt or a follow-up `get_entry_card` RPC.

set search_path = public, extensions;

-- ===========================================================================
-- 1. THE BROWSE READS — schema `browse`, SECURITY DEFINER, anon-only EXECUTE.
--
-- Each one calls the PUBLIC read of the same name. Inside a definer function `current_user` is the
-- owner, so the public read takes its ordinary signed-in branch (section 2) and runs with the
-- owner's rights: no table grant is involved, RLS is not consulted, and `auth.uid()` is NULL. What
-- each wrapper adds is only what "no viewer" must mean on the wire:
--   * every viewer-relative flag is a real FALSE (is_mine, is_me, saved) and every "you" number is
--     0/NULL — never the NULL that `x = auth.uid()` evaluates to, which a Bool decoder rejects;
--   * entries are filtered to `visibility = 'public'` explicitly. 0033's CHECK already makes that
--     every row; this is the second lock, so browse can never serve a private entry even if the
--     column ever means something again;
--   * the order is restated, because a wrapper must not rely on a function scan's order.
-- `browse` is NOT in PostgREST's exposed schemas (config.toml `[api].schemas`), so these are
-- reachable only through the public reads below.
-- ===========================================================================
create schema if not exists browse;
comment on schema browse is
  'Signed-out (anon) implementations of the public browse reads (0034). Not exposed by PostgREST; reached only through the public read of the same name.';
revoke all on schema browse from public;
grant usage on schema browse to anon;

create or replace function browse.get_entry_feed(
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int,
  p_include_own       boolean
)
returns setof public.entry_cards
language sql
stable
security definer
set search_path = public, extensions
as $$
  -- p_include_own is forced TRUE: with no viewer, `author_id <> auth.uid()` is NULL for every row
  -- and the feed would be empty. There is no "own" to leave out.
  select r.*
  from public.get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, true) c
  cross join lateral jsonb_populate_record(c, '{"is_mine": false}'::jsonb) r
  where c.visibility = 'public'
  order by r.created_at desc, r.id desc;
$$;
revoke all on function browse.get_entry_feed(timestamptz, uuid, int, boolean) from public;
grant execute on function browse.get_entry_feed(timestamptz, uuid, int, boolean) to anon;

create or replace function browse.get_entries_by_author(
  p_author_id         uuid,
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int
)
returns setof public.entry_cards
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.*
  from public.get_entries_by_author(p_author_id, p_cursor_created_at, p_cursor_id, p_page_size) c
  cross join lateral jsonb_populate_record(c, '{"is_mine": false}'::jsonb) r
  where c.visibility = 'public'
  order by r.created_at desc, r.id desc;
$$;
revoke all on function browse.get_entries_by_author(uuid, timestamptz, uuid, int) from public;
grant execute on function browse.get_entries_by_author(uuid, timestamptz, uuid, int) to anon;

create or replace function browse.get_entries_at_place(
  p_restaurant_id     uuid,
  p_scope             text,
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int
)
returns setof public.entry_cards
language sql
stable
security definer
set search_path = public, extensions
as $$
  -- 'mine' is nobody's: empty. 'others' is everyone (with no viewer, `<> auth.uid()` is NULL, so it
  -- is read as 'all').
  select r.*
  from public.get_entries_at_place(p_restaurant_id, 'all', p_cursor_created_at, p_cursor_id, p_page_size) c
  cross join lateral jsonb_populate_record(c, '{"is_mine": false}'::jsonb) r
  where c.visibility = 'public'
    and p_scope is distinct from 'mine'
  order by r.created_at desc, r.id desc;
$$;
revoke all on function browse.get_entries_at_place(uuid, text, timestamptz, uuid, int) from public;
grant execute on function browse.get_entries_at_place(uuid, text, timestamptz, uuid, int) to anon;

create or replace function browse.place_summary(p_restaurant_id uuid)
returns table (
  restaurant_id uuid,
  name          text,
  address       text,
  city          text,
  cuisine       text,
  cover_url     text,
  avg_rating    numeric(2,1),
  review_count  int,
  people_count  int,
  dish_count    int,
  my_visits     int,
  my_last_visit timestamptz,
  -- appended 0029
  locality      text,
  entry_count   int
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select s.restaurant_id, s.name, s.address, s.city, s.cuisine, s.cover_url, s.avg_rating,
         s.review_count, s.people_count, s.dish_count,
         0, null::timestamptz,                         -- my_visits, my_last_visit: no viewer
         s.locality, s.entry_count
  from public.place_summary(p_restaurant_id) s;
$$;
revoke all on function browse.place_summary(uuid) from public;
grant execute on function browse.place_summary(uuid) to anon;

create or replace function browse.place_dishes(
  p_restaurant_id      uuid,
  p_limit              int,
  p_cursor_review_count int,
  p_cursor_score       numeric,
  p_cursor_dish_name   text,
  p_cursor_dish_id     uuid
)
returns table (
  dish_id      uuid,
  dish_name    text,
  score        numeric(2,1),
  people_count int,
  review_count int,
  cover_url    text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select d.*
  from public.place_dishes(p_restaurant_id, p_limit, p_cursor_review_count, p_cursor_score,
                           p_cursor_dish_name, p_cursor_dish_id) d
  order by d.review_count desc, coalesce(d.score, -1) desc, lower(d.dish_name), d.dish_id;
$$;
revoke all on function browse.place_dishes(uuid, int, int, numeric, text, uuid) from public;
grant execute on function browse.place_dishes(uuid, int, int, numeric, text, uuid) to anon;

create or replace function browse.dish_summary(p_dish_id uuid)
returns table (
  dish_id             uuid,
  dish_name           text,
  restaurant_id       uuid,
  restaurant_name     text,
  restaurant_city     text,
  score               numeric(2,1),
  review_count        int,
  scored_count        int,
  people_count        int,
  cover_url           text,
  saved               boolean,
  my_last_score       numeric(2,1),
  -- appended 0029
  photos              jsonb,
  restaurant_locality text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select s.dish_id, s.dish_name, s.restaurant_id, s.restaurant_name, s.restaurant_city, s.score,
         s.review_count, s.scored_count, s.people_count, s.cover_url,
         false, null::numeric(2,1),                    -- saved, my_last_score: no viewer
         s.photos, s.restaurant_locality
  from public.dish_summary(p_dish_id) s;
$$;
revoke all on function browse.dish_summary(uuid) from public;
grant execute on function browse.dish_summary(uuid) to anon;

create or replace function browse.get_dish_reviews(
  p_dish_id           uuid,
  p_cursor_mine       boolean,
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int
)
returns table (
  review_id  uuid,
  entry_id   uuid,
  author     jsonb,
  score      numeric(2,1),
  note       text,
  created_at timestamptz,
  is_mine    boolean,
  photos     jsonb
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select v.review_id, v.entry_id, v.author, v.score, v.note, v.created_at,
         false,                                        -- is_mine: no viewer
         v.photos
  from public.get_dish_reviews(p_dish_id, false, p_cursor_created_at, p_cursor_id, p_page_size) v
  order by v.created_at desc, v.review_id desc;
$$;
revoke all on function browse.get_dish_reviews(uuid, boolean, timestamptz, uuid, int) from public;
grant execute on function browse.get_dish_reviews(uuid, boolean, timestamptz, uuid, int) to anon;

create or replace function browse.profile_summary(p_user_id uuid)
returns table (
  user_id      uuid,
  username     citext,
  name         text,
  avatar_url   text,
  bio          text,
  city         text,
  created_at   timestamptz,
  orders       int,
  places       int,
  dishes       int,
  scored       int,
  avg_score    numeric(3,2),
  is_me        boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select s.user_id, s.username, s.name, s.avatar_url, s.bio, s.city, s.created_at,
         s.orders, s.places, s.dishes, s.scored, s.avg_score,
         false                                         -- is_me: no viewer
  from public.profile_summary(p_user_id) s;
$$;
revoke all on function browse.profile_summary(uuid) from public;
grant execute on function browse.profile_summary(uuid) to anon;

-- ===========================================================================
-- 2. THE PUBLIC READS — same names, same parameters, same OUT columns (so create-or-replace is legal
-- and every grant survives; landmine 7 does not apply). Each becomes a plpgsql dispatcher:
--   anon          → the browse read above;
--   anyone else   → the ORIGINAL query, byte for byte (copied from 0020/0022/0029/0030/0033).
-- plpgsql, not sql, is load-bearing: plpgsql plans a statement when it first RUNS, so anon never
-- plans the signed-in branch and so never needs a privilege on the tables in it. A `language sql`
-- body is planned whole, and would fail for anon with 42501 on `entries`.
-- `#variable_conflict use_column`: the OUT columns become plpgsql variables, and every one of these
-- queries names columns with the same names.
-- ===========================================================================

create or replace function public.get_entry_feed(
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20,
  p_include_own       boolean     default false
)
returns setof public.entry_cards
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, p_include_own);
    return;
  end if;

  -- Signed in: unchanged.
  return query
  select c.*
  from public.entry_cards c
  where (p_include_own or c.author_id <> (select auth.uid()))
    and (
      p_cursor_created_at is null
      or (c.created_at, c.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.created_at desc, c.id desc
  limit least(greatest(p_page_size, 1), 50);
end;
$$;

create or replace function public.get_entries_by_author(
  p_author_id         uuid,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20
)
returns setof public.entry_cards
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.get_entries_by_author(p_author_id, p_cursor_created_at, p_cursor_id, p_page_size);
    return;
  end if;

  -- Signed in: unchanged.
  return query
  select c.*
  from public.entry_cards c
  where c.author_id = p_author_id
    and (
      p_cursor_created_at is null
      or (c.created_at, c.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.created_at desc, c.id desc
  limit least(greatest(p_page_size, 1), 50);
end;
$$;

create or replace function public.get_entries_at_place(
  p_restaurant_id     uuid,
  p_scope             text        default 'all',
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20
)
returns setof public.entry_cards
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.get_entries_at_place(p_restaurant_id, p_scope, p_cursor_created_at, p_cursor_id, p_page_size);
    return;
  end if;

  -- Signed in: unchanged.
  return query
  select c.*
  from public.entry_cards c
  where c.restaurant_id = p_restaurant_id
    and case p_scope
          when 'mine'   then c.author_id  = (select auth.uid())
          when 'others' then c.author_id <> (select auth.uid())
          else true
        end
    and (
      p_cursor_created_at is null
      or (c.created_at, c.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.created_at desc, c.id desc
  limit least(greatest(p_page_size, 1), 50);
end;
$$;

create or replace function public.place_summary(p_restaurant_id uuid)
returns table (
  restaurant_id uuid,
  name          text,
  address       text,
  city          text,
  cuisine       text,
  cover_url     text,
  avg_rating    numeric(2,1),
  review_count  int,
  people_count  int,
  dish_count    int,
  my_visits     int,
  my_last_visit timestamptz,
  -- appended 0029
  locality      text,
  entry_count   int
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.place_summary(p_restaurant_id);
    return;
  end if;

  -- Signed in: unchanged.
  return query
  select
    r.id, r.name,
    nullif(btrim(r.address), ''), nullif(btrim(r.city), ''), nullif(btrim(r.cuisine), ''),
    nullif(btrim(coalesce(rs.cover_url, r.cover_url)), ''),
    rs.avg_rating, coalesce(rs.review_count, 0), coalesce(rs.people_count, 0),
    coalesce(rs.dish_count, 0),
    coalesce(mine.visits, 0), mine.last_visit,
    public.place_locality(r.address, r.city),
    coalesce(here.visits, 0)
  from public.restaurants r
  left join public.restaurant_stats rs on rs.restaurant_id = r.id
  left join lateral (
    select count(*)::int as visits, max(e.created_at) as last_visit
    from public.entries e
    where e.restaurant_id = r.id and e.author_id = (select auth.uid())
  ) mine on true
  left join lateral (
    select count(*)::int as visits
    from public.entries e
    where e.restaurant_id = r.id
  ) here on true
  where r.id = p_restaurant_id;
end;
$$;

create or replace function public.place_dishes(
  p_restaurant_id      uuid,
  p_limit              int     default 50,
  p_cursor_review_count int    default null,
  p_cursor_score       numeric default null,
  p_cursor_dish_name   text    default null,
  p_cursor_dish_id     uuid    default null
)
returns table (
  dish_id      uuid,
  dish_name    text,
  score        numeric(2,1),
  people_count int,
  review_count int,
  cover_url    text
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.place_dishes(p_restaurant_id, p_limit, p_cursor_review_count, p_cursor_score, p_cursor_dish_name, p_cursor_dish_id);
    return;
  end if;

  -- Signed in: unchanged.
  return query
  select ds.dish_id, d.name, ds.score, ds.people_count, ds.review_count, ds.cover_url
  from public.dish_stats ds
  join public.dishes d on d.id = ds.dish_id
  where ds.restaurant_id = p_restaurant_id
    -- never logged = not a menu item (an unscored dish WITH a line stays)
    and ds.review_count > 0
    and (
      p_cursor_dish_id is null
      or ds.review_count < p_cursor_review_count
      or (ds.review_count = p_cursor_review_count
          and coalesce(ds.score, -1) < coalesce(p_cursor_score, -1))
      or (ds.review_count = p_cursor_review_count
          and coalesce(ds.score, -1) = coalesce(p_cursor_score, -1)
          and (lower(d.name), ds.dish_id) > (lower(coalesce(p_cursor_dish_name, '')), p_cursor_dish_id))
    )
  order by ds.review_count desc, coalesce(ds.score, -1) desc, lower(d.name), ds.dish_id
  limit least(greatest(p_limit, 1), 200);
end;
$$;

create or replace function public.dish_summary(p_dish_id uuid)
returns table (
  dish_id             uuid,
  dish_name           text,
  restaurant_id       uuid,
  restaurant_name     text,
  restaurant_city     text,
  score               numeric(2,1),
  review_count        int,
  scored_count        int,
  people_count        int,
  cover_url           text,
  saved               boolean,
  my_last_score       numeric(2,1),
  -- appended 0029
  photos              jsonb,
  restaurant_locality text
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.dish_summary(p_dish_id);
    return;
  end if;

  -- Signed in: unchanged.
  return query
  select
    d.id, d.name, r.id, r.name, nullif(btrim(r.city), ''),
    ds.score, coalesce(ds.review_count, 0), coalesce(ds.scored_count, 0),
    coalesce(ds.people_count, 0),
    ds.cover_url,
    exists (select 1 from public.saves s where s.dish_id = d.id and s.user_id = (select auth.uid())),
    (
      select v.score from public.reviews v
      where v.dish_id = d.id and v.reviewer_id = (select auth.uid()) and v.score is not null
      order by v.created_at desc, v.id desc limit 1
    ),
    public.dish_photos(d.id, 8),
    public.place_locality(r.address, r.city)
  from public.dishes d
  join public.restaurants r on r.id = d.restaurant_id
  left join public.dish_stats ds on ds.dish_id = d.id
  where d.id = p_dish_id;
end;
$$;

create or replace function public.get_dish_reviews(
  p_dish_id           uuid,
  p_cursor_mine       boolean     default null,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20
)
returns table (
  review_id  uuid,
  entry_id   uuid,
  author     jsonb,
  score      numeric(2,1),
  note       text,
  created_at timestamptz,
  is_mine    boolean,
  photos     jsonb
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.get_dish_reviews(p_dish_id, p_cursor_mine, p_cursor_created_at, p_cursor_id, p_page_size);
    return;
  end if;

  -- Signed in: unchanged.
  return query
  select
    v.id, v.entry_id,
    jsonb_build_object('id', p.id, 'username', p.username, 'name', p.name, 'avatar_url', p.avatar_url),
    v.score, v.note, v.created_at,
    (v.reviewer_id = (select auth.uid())),
    coalesce((
      select jsonb_agg(jsonb_build_object('url', x.photo_url, 'position', x.position) order by x.position)
      from public.entry_photos x where x.entry_id = v.entry_id
    ), '[]'::jsonb)
  from public.reviews v
  join public.profiles p on p.id = v.reviewer_id
  where v.dish_id = p_dish_id
    and (
      p_cursor_created_at is null
      or (
        (case when v.reviewer_id = (select auth.uid()) then 1 else 0 end),
        v.created_at, v.id
      ) < (
        (case when coalesce(p_cursor_mine, false) then 1 else 0 end),
        p_cursor_created_at,
        coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid)
      )
    )
  order by (v.reviewer_id = (select auth.uid())) desc, v.created_at desc, v.id desc
  limit least(greatest(p_page_size, 1), 50);
end;
$$;

create or replace function public.profile_summary(p_user_id uuid)
returns table (
  user_id      uuid,
  username     citext,
  name         text,
  avatar_url   text,
  bio          text,
  city         text,
  created_at   timestamptz,
  orders       int,
  places       int,
  dishes       int,
  scored       int,
  avg_score    numeric(3,2),
  is_me        boolean
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.profile_summary(p_user_id);
    return;
  end if;

  -- Signed in: unchanged.
  return query
  select
    p.id, p.username, p.name, p.avatar_url, p.bio, nullif(btrim(p.city), ''), p.created_at,
    coalesce(e.orders, 0), coalesce(e.places, 0),
    coalesce(v.dishes, 0), coalesce(v.scored, 0), v.avg_score,
    (p.id = (select auth.uid()))
  from public.profiles p
  left join lateral (
    select count(*)::int as orders,
           count(distinct en.restaurant_id)::int as places
    from public.entries en where en.author_id = p.id
  ) e on true
  left join lateral (
    select count(*)::int as dishes,
           count(rv.score)::int as scored,
           round(avg(rv.score), 2)::numeric(3,2) as avg_score
    from public.reviews rv
    where rv.reviewer_id = p.id
  ) v on true
  where p.id = p_user_id;
end;
$$;

create or replace function public.is_dish_saved(p_dish_id uuid)
returns boolean language plpgsql stable security invoker
set search_path = public, extensions as $$
begin
  -- Signed out (0034): nobody is looking, so nothing is saved. No table is read.
  if current_user = 'anon' then
    return false;
  end if;
  return (
  select exists (
    select 1 from public.saves s
    where s.user_id = (select auth.uid()) and s.dish_id = p_dish_id
  )
  );
end;
$$;

-- ===========================================================================
-- 3. GRANTS — EXECUTE for anon on exactly these nine. No table, view, policy or schema-level grant
-- in `public` changes: anon still selects nothing raw (the CI curl gate on `restaurants` keeps
-- returning []), and every write, search, stats and saves RPC stays revoked from anon.
-- ===========================================================================
grant execute on function public.get_entry_feed(timestamptz, uuid, int, boolean) to anon;
grant execute on function public.get_entries_by_author(uuid, timestamptz, uuid, int) to anon;
grant execute on function public.get_entries_at_place(uuid, text, timestamptz, uuid, int) to anon;
grant execute on function public.place_summary(uuid) to anon;
grant execute on function public.place_dishes(uuid, int, int, numeric, text, uuid) to anon;
grant execute on function public.dish_summary(uuid) to anon;
grant execute on function public.get_dish_reviews(uuid, boolean, timestamptz, uuid, int) to anon;
grant execute on function public.profile_summary(uuid) to anon;
grant execute on function public.is_dish_saved(uuid) to anon;

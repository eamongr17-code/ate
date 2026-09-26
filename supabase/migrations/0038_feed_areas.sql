-- 0038_feed_areas.sql
-- Ate backend — round 3: a changeable Feed area. The Feed can be narrowed to one suburb/city, and a
-- picker lists the areas worth picking.
--
--   feed_areas(p_limit int default 30, p_cursor_entry_count int default null, p_cursor_area text default null)
--                          → table(area text, entry_count int): every area with entries the Feed would
--                            show YOU, busiest first (then A→Z). The area is `place_locality(address,
--                            city)` (0029) — the same string `entry_cards.place.locality` prints — so a
--                            picked area round-trips exactly. Grouped trimmed + case-insensitively
--                            (the label is the most common spelling), matching p_area's comparison.
--                            Entries with no place, or a place we cannot name, are counted nowhere.
--                            Signed in: through RLS (blocked/deactivated authors are absent, exactly as
--                            in the feed) and WITHOUT your own entries (the Feed never shows them —
--                            both shipped callers pass p_include_own=false), so every listed area has a
--                            non-empty Feed. Signed out (anon): everyone's public entries.
--   get_entry_feed(…, p_area text default null)
--                          → NULL = everywhere (today's behaviour, byte for byte). A value keeps only
--                            entries whose place locality equals it (trimmed, case-insensitive). Keyset
--                            paging is unchanged: `(created_at, id)` desc, pass the last row's pair.
--
-- WHY THE FEED IS ADAPTED, NOT FORKED: the proven `get_entry_feed` keyset query gains one predicate.
-- A sparse area walks more rows to fill a page; at V1 volume that is nothing, and the area predicate is
-- on the same view row the feed already builds.
--
-- LANDMINE 7: a new parameter means DROP-then-CREATE (a `create or replace` would leave a second
-- overload and every named-argument call would be 42725). Both the public read and its browse twin
-- (0034/0035) are dropped and recreated, and every grant is restated.
--
-- WIRE IMPACT: ADDITIVE. `get_entry_feed` keeps its four parameters, their defaults, its OUT shape
-- (`setof entry_cards`) and its grants (authenticated + anon); a shipped client that never sends
-- `p_area` gets today's feed. New RPC `feed_areas(p_limit, p_cursor_entry_count, p_cursor_area)`, keyset-paged
-- on (entry_count desc, area), for authenticated and anon.

set search_path = public, extensions;

-- ===========================================================================
-- 1. get_entry_feed + p_area — drop both (browse first: it is the dependent), recreate public, then
--    browse (a `language sql` body is validated at create time, so its callee must exist).
-- ===========================================================================
drop function if exists browse.get_entry_feed(timestamptz, uuid, int, boolean);
drop function if exists public.get_entry_feed(timestamptz, uuid, int, boolean);

create function public.get_entry_feed(
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20,
  p_include_own       boolean     default false,
  p_area              text        default null
)
returns setof public.entry_cards
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_area text := nullif(lower(btrim(coalesce(p_area, ''))), '');
begin
  -- Signed out (0034): the browse read, which runs as its owner and needs no table grant.
  if current_user = 'anon' then
    return query select * from browse.get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, p_include_own, p_area);
    return;
  end if;

  -- Signed in: 0034's query + the area predicate.
  return query
  select c.*
  from public.entry_cards c
  where (p_include_own or c.author_id <> (select auth.uid()))
    and (v_area is null or lower(btrim(c.place ->> 'locality')) = v_area)
    and (
      p_cursor_created_at is null
      or (c.created_at, c.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.created_at desc, c.id desc
  limit least(greatest(p_page_size, 1), 50);
end;
$$;

comment on function public.get_entry_feed(timestamptz, uuid, int, boolean, text) is
  'The Feed: every entry the viewer may see (blocked/deactivated authors gone), newest first, keyset (created_at, id). p_include_own defaults false. p_area (0038) = a feed_areas() value to keep only entries whose place locality matches (trimmed, case-insensitive); NULL = everywhere. anon → browse twin.';

create function browse.get_entry_feed(
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int,
  p_include_own       boolean,
  p_area              text
)
returns setof public.entry_cards
language sql
stable
security definer
set search_path = public, extensions
as $$
  -- 0035's twin + p_area (passed through: the public read's signed-in branch applies it).
  select r.*
  from public.get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, true, p_area) c
  cross join lateral jsonb_populate_record(c, '{"is_mine": false}'::jsonb) r
  where c.visibility = 'public'
    and exists (select 1 from public.profiles p where p.id = c.author_id and p.deleted_at is null)
  order by r.created_at desc, r.id desc;
$$;

revoke all on function public.get_entry_feed(timestamptz, uuid, int, boolean, text) from public;
grant execute on function public.get_entry_feed(timestamptz, uuid, int, boolean, text) to authenticated, anon, service_role;
revoke all on function browse.get_entry_feed(timestamptz, uuid, int, boolean, text) from public;
grant execute on function browse.get_entry_feed(timestamptz, uuid, int, boolean, text) to anon;

-- ===========================================================================
-- 2. feed_areas — paged, same dispatch shape as every browse read.
--
-- Keyset on the list's own order, (entry_count DESC, area ASC): first page → nulls; next page → the
-- LAST row's `entry_count` AND `area`. `p_limit` defaults to 30, clamped to 1..100. `area` is unique
-- per list (grouped case-insensitively), so the pair is a total order and a page never repeats a row.
-- ===========================================================================
create or replace function browse.feed_areas(
  p_limit              int,
  p_cursor_entry_count int,
  p_cursor_area        text
)
returns table (area text, entry_count int)
language sql
stable
security definer
set search_path = public, extensions
as $$
  -- No viewer: every public entry by a live profile (the browse feed's own filter).
  select g.area, g.entry_count
  from (
    select mode() within group (order by a.area) as area, count(*)::int as entry_count
    from (
      select public.place_locality(r.address, r.city) as area
      from public.entries e
      join public.profiles p on p.id = e.author_id and p.deleted_at is null
      join public.restaurants r on r.id = e.restaurant_id
      where e.visibility = 'public'
    ) a
    where a.area is not null
    group by lower(btrim(a.area))
  ) g
  where p_cursor_entry_count is null
     or g.entry_count < p_cursor_entry_count
     or (g.entry_count = p_cursor_entry_count and g.area > coalesce(p_cursor_area, ''))
  order by g.entry_count desc, g.area
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;
revoke all on function browse.feed_areas(int, int, text) from public;
grant execute on function browse.feed_areas(int, int, text) to anon;

create or replace function public.feed_areas(
  p_limit              int  default 30,
  p_cursor_entry_count int  default null,
  p_cursor_area        text default null
)
returns table (area text, entry_count int)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  if current_user = 'anon' then
    return query select * from browse.feed_areas(p_limit, p_cursor_entry_count, p_cursor_area);
    return;
  end if;

  -- Signed in: through RLS on entries AND profiles — the same rows entry_cards (INNER JOIN profiles)
  -- lets the feed show — minus your own, which the Feed never shows.
  return query
  select g.area, g.entry_count
  from (
    select mode() within group (order by a.area) as area, count(*)::int as entry_count
    from (
      select public.place_locality(r.address, r.city) as area
      from public.entries e
      join public.profiles p on p.id = e.author_id
      join public.restaurants r on r.id = e.restaurant_id
      where e.author_id <> (select auth.uid())
    ) a
    where a.area is not null
    group by lower(btrim(a.area))
  ) g
  where p_cursor_entry_count is null
     or g.entry_count < p_cursor_entry_count
     or (g.entry_count = p_cursor_entry_count and g.area > coalesce(p_cursor_area, ''))
  order by g.entry_count desc, g.area
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
end;
$$;

comment on function public.feed_areas(int, int, text) is
  'The Feed area picker (0038): place_locality() of every entry the Feed would show the viewer (own entries excluded; blocked/deactivated authors excluded), grouped case-insensitively, with its entry count. Keyset-paged on (entry_count desc, area asc): pass the last row''s entry_count + area; p_limit default 30, max 100. Pass a row''s `area` to get_entry_feed(p_area). anon → browse twin (all public entries).';

revoke all on function public.feed_areas(int, int, text) from public;
grant execute on function public.feed_areas(int, int, text) to authenticated, anon, service_role;

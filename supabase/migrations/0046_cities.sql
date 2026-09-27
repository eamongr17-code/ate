-- 0046_cities.sql
-- Ate backend — round 5: THE FEED IS A CITY. By default the Feed shows "near me" — the metro area the
-- device is in — and never anything outside it; the picker switches to another city's food.
--
-- THE MODEL
--   cities (reference data, this file seeds it) — one row per metro area: a slug `id` ('melbourne'),
--     `name`, `region` (state/territory code), a `center` point and a `radius_m`. Changing the list is a
--     migration, never console SQL.
--   A place's city is DERIVED ON READ (view `place_cities`), never stored — no backfill, and a new place
--   can re-home an old one (rule 3). In order:
--     1. location — the nearest city centre whose radius holds the place's point;
--     2. name — the place's locality (place_locality(), what every chip prints) IS a city's name or one
--        of its `aliases` ("CBD" → Melbourne while the launch market is VIC);
--     3. locality — the city most LOCATED places with that same locality fall in. A hand-added
--        (manual, no coordinates) "Thornbury" is Melbourne because Google's Thornbury places are.
--     A place none of these place is in no city: the everywhere feed (p_city NULL) still shows it.
--
--   feed_cities()            → (city, name, region, lat, lng, radius_m, entry_count): the cities the
--                              Feed has food in FOR YOU (own entries excluded, blocked/deactivated
--                              authors excluded — feed_areas' rule), busiest first. Unpaged (a handful).
--   resolve_city(lat, lng)   → ONE row of feed_cities + distance_m + is_nearby, or none:
--                              · a city WITH FOOD whose radius holds the point (nearest centre) —
--                                is_nearby = true;
--                              · else the nearest city with food — is_nearby = false;
--                              · no coordinates (location denied): the busiest city — is_nearby false;
--                              · no city has food at all: zero rows (use p_city NULL).
--                              The point is used for this answer and nothing else: never stored,
--                              never attached to anything (rule 8 is about places on entries).
--   get_entry_feed(…, p_city) → NULL = every city (today). A slug keeps entries whose place maps to
--                              that city. Unknown slug → []. Composes with p_area (both apply).
--
-- WHY DERIVED, NOT A COLUMN: a stored restaurants.city_id needs a bulk backfill of prod catalogue rows
-- and goes stale the moment rule 3's evidence changes. place_cities is one pass over restaurants with
-- a ~15-row inner lookup; every read computes the city's place set ONCE (plpgsql variable or an
-- uncorrelated IN), never per row. At a few thousand places that is milliseconds; if it ever is not,
-- materialise it then.
--
-- WIRE IMPACT: ADDITIVE. get_entry_feed keeps its five parameters, defaults, OUT shape and grants; a
-- client that never sends p_city gets today's feed (LANDMINE 7: drop-then-create, browse twin too).
-- New: table `cities` (authenticated SELECT), view `place_cities`, RPCs feed_cities, resolve_city.

set search_path = public, extensions;

-- ===========================================================================
-- 1. cities
-- ===========================================================================
create table public.cities (
  id       text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name     text not null,
  region   text not null,
  country  text not null default 'AU',
  center   geography(Point, 4326) not null,
  radius_m int  not null check (radius_m between 5000 and 150000),
  aliases  text[] not null default '{}'
);

comment on table public.cities is
  'Round 5 (0046): the metro areas the Feed can be set to. Reference data, seeded and changed by migration only. A place''s city is derived by place_cities (location → name/alias → sibling locality). `aliases` are lower-case localities that mean this city for a place with no usable coordinates.';

alter table public.cities enable row level security;
create policy cities_select_all on public.cities for select to authenticated using (true);
revoke all on public.cities from anon, authenticated;
grant select on public.cities to authenticated;
grant all on public.cities to service_role;

-- Radii are metro-sized; overlaps resolve to the nearest centre (Werribee → Melbourne, Lara → Geelong).
insert into public.cities (id, name, region, center, radius_m, aliases) values
  ('melbourne',      'Melbourne',      'VIC', extensions.ST_SetSRID(extensions.ST_MakePoint(144.9631, -37.8136), 4326)::geography, 65000, '{cbd,"melbourne cbd"}'),
  ('geelong',        'Geelong',        'VIC', extensions.ST_SetSRID(extensions.ST_MakePoint(144.3617, -38.1499), 4326)::geography, 30000, '{}'),
  ('ballarat',       'Ballarat',       'VIC', extensions.ST_SetSRID(extensions.ST_MakePoint(143.8503, -37.5622), 4326)::geography, 25000, '{}'),
  ('bendigo',        'Bendigo',        'VIC', extensions.ST_SetSRID(extensions.ST_MakePoint(144.2794, -36.7570), 4326)::geography, 25000, '{}'),
  ('sydney',         'Sydney',         'NSW', extensions.ST_SetSRID(extensions.ST_MakePoint(151.2093, -33.8688), 4326)::geography, 60000, '{"sydney cbd"}'),
  ('newcastle',      'Newcastle',      'NSW', extensions.ST_SetSRID(extensions.ST_MakePoint(151.7817, -32.9283), 4326)::geography, 35000, '{}'),
  ('wollongong',     'Wollongong',     'NSW', extensions.ST_SetSRID(extensions.ST_MakePoint(150.8931, -34.4278), 4326)::geography, 30000, '{}'),
  ('canberra',       'Canberra',       'ACT', extensions.ST_SetSRID(extensions.ST_MakePoint(149.1300, -35.2809), 4326)::geography, 30000, '{}'),
  ('brisbane',       'Brisbane',       'QLD', extensions.ST_SetSRID(extensions.ST_MakePoint(153.0251, -27.4698), 4326)::geography, 50000, '{"brisbane city"}'),
  ('gold-coast',     'Gold Coast',     'QLD', extensions.ST_SetSRID(extensions.ST_MakePoint(153.4000, -28.0167), 4326)::geography, 35000, '{}'),
  ('sunshine-coast', 'Sunshine Coast', 'QLD', extensions.ST_SetSRID(extensions.ST_MakePoint(153.0667, -26.6500), 4326)::geography, 35000, '{}'),
  ('adelaide',       'Adelaide',       'SA',  extensions.ST_SetSRID(extensions.ST_MakePoint(138.6007, -34.9285), 4326)::geography, 45000, '{}'),
  ('perth',          'Perth',          'WA',  extensions.ST_SetSRID(extensions.ST_MakePoint(115.8605, -31.9505), 4326)::geography, 50000, '{}'),
  ('hobart',         'Hobart',         'TAS', extensions.ST_SetSRID(extensions.ST_MakePoint(147.3272, -42.8821), 4326)::geography, 25000, '{}'),
  ('darwin',         'Darwin',         'NT',  extensions.ST_SetSRID(extensions.ST_MakePoint(130.8456, -12.4634), 4326)::geography, 25000, '{}');

-- ===========================================================================
-- 2. city_at + place_cities — a point's city, and every place's.
-- ===========================================================================
create or replace function public.city_at(p_point geography)
returns text
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select c.id
  from public.cities c
  where p_point is not null
    and extensions.ST_DWithin(c.center, p_point, c.radius_m)
  order by extensions.ST_Distance(c.center, p_point), c.id
  limit 1;
$$;

comment on function public.city_at(geography) is
  'Round 5: the city whose radius holds the point (nearest centre wins an overlap), NULL when none.';

create view public.place_cities with (security_invoker = true) as
  with located as (
    select r.id,
           lower(btrim(public.place_locality(r.address, r.city))) as loc,
           public.city_at(r.location)                            as geo
    from public.restaurants r
  ),
  by_locality as (
    -- mode() breaks a tie on the first id — deterministic.
    select l.loc, mode() within group (order by l.geo) as city
    from located l
    where l.geo is not null and l.loc is not null
    group by l.loc
  )
  select m.restaurant_id, m.city, m.via
  from (
    select l.id as restaurant_id,
           coalesce(l.geo, a.id, b.city) as city,
           case when l.geo is not null then 'location'
                when a.id  is not null then 'name'
                when b.city is not null then 'locality' end as via
    from located l
    left join lateral (
      select c.id
      from public.cities c
      where l.loc is not null
        and (l.loc = lower(c.name) or l.loc = any(c.aliases))
      order by c.id
      limit 1
    ) a on true
    left join by_locality b on b.loc = l.loc
  ) m
  where m.city is not null;

comment on view public.place_cities is
  'Round 5 (0046): each place''s city, derived on read — by location (nearest containing centre), else its locality naming a city (name/aliases), else the city most located places with the same locality are in. `via` = location | name | locality. Places in no city are absent.';

revoke all on function public.city_at(geography) from public, anon;
grant execute on function public.city_at(geography) to authenticated, service_role;
revoke all on public.place_cities from anon, authenticated;
grant select on public.place_cities to authenticated, service_role;

-- ===========================================================================
-- 3. get_entry_feed + p_city — drop both (browse first: it is the dependent), recreate.
-- ===========================================================================
drop function if exists browse.get_entry_feed(timestamptz, uuid, int, boolean, text);
drop function if exists public.get_entry_feed(timestamptz, uuid, int, boolean, text);

create function public.get_entry_feed(
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_page_size         int         default 20,
  p_include_own       boolean     default false,
  p_area              text        default null,
  p_city              text        default null
)
returns setof public.entry_cards
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_area   text   := nullif(lower(btrim(coalesce(p_area, ''))), '');
  v_city   text   := nullif(lower(btrim(coalesce(p_city, ''))), '');
  v_places uuid[];
begin
  if current_user = 'anon' then
    return query select * from browse.get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, p_include_own, p_area, p_city);
    return;
  end if;

  -- The city's places, once — never per row.
  if v_city is not null then
    v_places := coalesce(array(select pc.restaurant_id from public.place_cities pc where pc.city = v_city), '{}');
  end if;

  return query
  select c.*
  from public.entry_cards c
  where (p_include_own or c.author_id <> (select auth.uid()))
    and (v_area is null or lower(btrim(c.place ->> 'locality')) = v_area)
    and (v_city is null or c.restaurant_id = any(v_places))
    and (
      p_cursor_created_at is null
      or (c.created_at, c.id) <
         (p_cursor_created_at, coalesce(p_cursor_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.created_at desc, c.id desc
  limit least(greatest(p_page_size, 1), 50);
end;
$$;

comment on function public.get_entry_feed(timestamptz, uuid, int, boolean, text, text) is
  'The Feed: every entry the viewer may see (blocked/deactivated authors gone), newest first, keyset (created_at, id). p_include_own defaults false. p_area (0038) = a feed_areas() locality; p_city (0046) = a cities.id — only entries whose place maps to it (place_cities); unknown → []. NULL = everywhere. anon → browse twin.';

create function browse.get_entry_feed(
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int,
  p_include_own       boolean,
  p_area              text,
  p_city              text
)
returns setof public.entry_cards
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.*
  from public.get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, true, p_area, p_city) c
  cross join lateral jsonb_populate_record(c, '{"is_mine": false}'::jsonb) r
  where c.visibility = 'public'
    and exists (select 1 from public.profiles p where p.id = c.author_id and p.deleted_at is null)
  order by r.created_at desc, r.id desc;
$$;

revoke all on function public.get_entry_feed(timestamptz, uuid, int, boolean, text, text) from public;
grant execute on function public.get_entry_feed(timestamptz, uuid, int, boolean, text, text) to authenticated, anon, service_role;
revoke all on function browse.get_entry_feed(timestamptz, uuid, int, boolean, text, text) from public;
grant execute on function browse.get_entry_feed(timestamptz, uuid, int, boolean, text, text) to anon;

-- ===========================================================================
-- 4. feed_cities — the picker. Same dispatch shape as every browse read.
-- ===========================================================================
create or replace function browse.feed_cities()
returns table (city text, name text, region text, lat double precision, lng double precision,
               radius_m int, entry_count int)
language sql
stable
security definer
set search_path = public, extensions
as $$
  -- No viewer: every public entry by a live profile (the browse feed's own filter).
  select c.id, c.name, c.region,
         extensions.ST_Y(c.center::extensions.geometry), extensions.ST_X(c.center::extensions.geometry),
         c.radius_m, n.entry_count
  from (
    select pc.city, count(*)::int as entry_count
    from public.entries e
    join public.profiles p on p.id = e.author_id and p.deleted_at is null
    join public.place_cities pc on pc.restaurant_id = e.restaurant_id
    where e.visibility = 'public'
    group by pc.city
  ) n
  join public.cities c on c.id = n.city
  order by n.entry_count desc, c.name, c.id;
$$;
revoke all on function browse.feed_cities() from public;
grant execute on function browse.feed_cities() to anon;

create or replace function public.feed_cities()
returns table (city text, name text, region text, lat double precision, lng double precision,
               radius_m int, entry_count int)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
  if current_user = 'anon' then
    return query select * from browse.feed_cities();
    return;
  end if;

  -- Signed in: through RLS on entries AND profiles (the rows the Feed can show), minus your own.
  return query
  select c.id, c.name, c.region,
         extensions.ST_Y(c.center::extensions.geometry), extensions.ST_X(c.center::extensions.geometry),
         c.radius_m, n.entry_count
  from (
    select pc.city, count(*)::int as entry_count
    from public.entries e
    join public.profiles p on p.id = e.author_id
    join public.place_cities pc on pc.restaurant_id = e.restaurant_id
    where e.author_id <> (select auth.uid())
    group by pc.city
  ) n
  join public.cities c on c.id = n.city
  order by n.entry_count desc, c.name, c.id;
end;
$$;

comment on function public.feed_cities() is
  'Round 5 Feed city picker (0046): the cities the Feed has entries in for the viewer (own excluded; blocked/deactivated authors excluded), with the count, busiest first then name. Pass `city` to get_entry_feed(p_city). Unpaged. anon → browse twin (all public entries).';

revoke all on function public.feed_cities() from public;
grant execute on function public.feed_cities() to authenticated, anon, service_role;

-- ===========================================================================
-- 5. resolve_city — "near me". Built on feed_cities (which dispatches for anon), so it needs no twin.
-- ===========================================================================
create or replace function public.resolve_city(
  p_lat double precision default null,
  p_lng double precision default null
)
returns table (city text, name text, region text, lat double precision, lng double precision,
               radius_m int, entry_count int, distance_m double precision, is_nearby boolean)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with pt as (
    select case
             when p_lat between -90 and 90 and p_lng between -180 and 180
               then extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::geography
           end as g
  ),
  d as (
    select f.*,
           extensions.ST_Distance(
             extensions.ST_SetSRID(extensions.ST_MakePoint(f.lng, f.lat), 4326)::geography, pt.g) as dist
    from public.feed_cities() f
    cross join pt
  )
  select d.city, d.name, d.region, d.lat, d.lng, d.radius_m, d.entry_count,
         d.dist, coalesce(d.dist <= d.radius_m, false)
  from d
  order by coalesce(d.dist <= d.radius_m, false) desc, d.dist asc nulls last,
           d.entry_count desc, d.name, d.city
  limit 1;
$$;

comment on function public.resolve_city(double precision, double precision) is
  'Round 5 "near me" (0046): the Feed city for a device point. A city with food whose radius holds the point (nearest centre) → is_nearby true; else the nearest city with food → false; no/invalid point → the busiest city, false; no city has food → no row. The point is not stored. Same counts as feed_cities (anon included).';

revoke all on function public.resolve_city(double precision, double precision) from public;
grant execute on function public.resolve_city(double precision, double precision) to authenticated, anon, service_role;

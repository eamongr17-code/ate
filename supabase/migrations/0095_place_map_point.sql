-- 0095_place_map_point.sql
-- Ate backend — a place page opens the restaurant in Maps (Eamon, 26 Oct: "Restaurant pages should
-- link to maps so users can see the location").
--
-- place_summary (signed in, and browse.place_summary for anon) appends three columns:
--   lat, lng         — restaurants.location as degrees. NULL when there is no point: a hand-added
--                      place (0014) has none, and a 0,0 point is treated as none (places-search
--                      writes 0 where Google left `location` out).
--   google_place_id  — Google's place id, so Google Maps opens the exact listing. NULL on a
--                      hand-added place.
-- The app opens Maps on the point when there is one, and otherwise searches Maps for the name and
-- address, so every place still opens somewhere.
--
-- WIRE IMPACT: additive (three columns at the end). An older app ignores them; the new app reads
-- them with decodeIfPresent, so it still works against a project without this migration.
-- A RETURNS TABLE shape cannot change in place, so both functions are dropped and recreated with
-- the grants they had (0029, 0034). browse.place_summary is dropped first: it reads public's.

drop function if exists browse.place_summary(uuid);
drop function if exists public.place_summary(uuid);

create function public.place_summary(p_restaurant_id uuid)
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
  entry_count   int,
  -- appended 0095
  lat             double precision,
  lng             double precision,
  google_place_id text
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
    coalesce(here.visits, 0),
    pt.lat, pt.lng,
    nullif(btrim(r.google_place_id), '')
  from public.restaurants r
  -- A point Google sent as 0,0 (places-search writes 0 when Google leaves `location` out) is no
  -- point: it would open Maps in the Gulf of Guinea.
  left join lateral (
    select ST_Y(r.location::geometry) as lat, ST_X(r.location::geometry) as lng
    where r.location is not null
      and not (ST_X(r.location::geometry) = 0 and ST_Y(r.location::geometry) = 0)
  ) pt on true
  left join public.restaurant_stats rs on rs.restaurant_id = r.id
  left join lateral (
    select count(*)::int as visits, max(e.created_at) as last_visit
    from public.entries e
    where e.restaurant_id = any (public.place_family(r.id)) and e.author_id = (select auth.uid())
  ) mine on true
  left join lateral (
    select count(*)::int as visits
    from public.entries e
    where e.restaurant_id = any (public.place_family(r.id))
  ) here on true
  where r.id = p_restaurant_id;
end;
$$;

comment on function public.place_summary(uuid) is
  'The place page header in one call (0029; 0085 chains; 0095 lat/lng/google_place_id for Maps). Text is NULL, never ''''.';

revoke all on function public.place_summary(uuid) from public, anon;
grant execute on function public.place_summary(uuid) to authenticated;
grant execute on function public.place_summary(uuid) to anon;

create function browse.place_summary(p_restaurant_id uuid)
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
  entry_count   int,
  -- appended 0095
  lat             double precision,
  lng             double precision,
  google_place_id text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select s.restaurant_id, s.name, s.address, s.city, s.cuisine, s.cover_url, s.avg_rating,
         s.review_count, s.people_count, s.dish_count,
         0, null::timestamptz,                         -- my_visits, my_last_visit: no viewer
         s.locality, s.entry_count,
         s.lat, s.lng, s.google_place_id
  from public.place_summary(p_restaurant_id) s;
$$;
revoke all on function browse.place_summary(uuid) from public;
grant execute on function browse.place_summary(uuid) to anon;

-- How many places have no map point (they open a Maps search instead). Read in the apply log.
do $$
declare
  total int;
  missing int;
begin
  select count(*), count(*) filter (
           where location is null
              or (extensions.ST_X(location::geometry) = 0 and extensions.ST_Y(location::geometry) = 0))
    into total, missing
  from public.restaurants;
  raise notice '0095: % of % places have no map point', missing, total;
end $$;

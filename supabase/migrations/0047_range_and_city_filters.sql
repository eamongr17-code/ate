-- 0047_range_and_city_filters.sql
-- Ate backend — round 5: SIMPLER FILTERS. The Journal (my_entries) and Search (search_places,
-- search_dishes, nearby_places) filter by a score RANGE and by CITY (0046's model). The Journal's
-- per-restaurant filter stays working for shipped clients; new clients use p_city.
--
--   p_max_score numeric  beside p_min_score, on the same number each read already filters: an entry's
--                        best_score (Journal), a place's avg_rating, a dish's score.
--   THE SECRET 6 AND THE TOP OF THE RANGE: the visible scale ends at 5, so a range whose top is at
--   the top of the scale is OPEN: p_max_score >= 5 means "no upper bound". A 6 — and an aggregate
--   above 5 because a 6 is in it (5.3) — is kept by [x, 5] and dropped by any lower top ([x, 4.5]).
--   Only 6s: p_min_score = 6 (6 >= 6). The slider at full width may send (0.5, 5) or nulls; both
--   keep every SCORED row. Rule, per row with number s:
--       no bound set                      → kept (unscored too)
--       any bound set                     → s is not null
--                                           and (p_min_score is null or s >= p_min_score)
--                                           and (p_max_score is null or p_max_score >= 5 or s <= p_max_score)
--   min > max → nothing (no error). Unscored rows drop out once EITHER bound is set.
--   p_city text          a cities.id: only places place_cities maps to it (Search: the place, or the
--                        dish's place; Journal: the entry's place). Unknown → nothing. NULL = anywhere.
--
--   my_entry_cities()    → (city, name, region, entry_count): the cities YOUR entries are in, busiest
--                          first. The Journal's picker.
--   search_cities()      → (city, name, region, place_count): cities of places we hold, busiest first.
--                          The Search picker; place_count = how many places search_places can return.
--
-- Predicates stay INSIDE the ranked set, never after the LIMIT, so every keyset is unchanged — send
-- the same filters on every page. The city's place set is computed once per call (uncorrelated IN /
-- plpgsql variable), never per row.
--
-- WIRE IMPACT: ADDITIVE. Two trailing optional params on my_entries / search_places / search_dishes /
-- nearby_places (drop-then-create, LANDMINE 7; named calls without them bind unchanged; OUT columns
-- unchanged; grants restated). New: score_in_range (helper), my_entry_cities, search_cities.

set search_path = public, extensions;

-- ===========================================================================
-- Helper
-- ===========================================================================
create or replace function public.score_in_range(p_score numeric, p_min numeric, p_max numeric)
returns boolean
language sql
immutable
set search_path = public, extensions
as $$
  select (p_min is null and p_max is null)
      or (p_score is not null
          and (p_min is null or p_score >= p_min)
          and (p_max is null or p_max >= 5 or p_score <= p_max));
$$;

comment on function public.score_in_range(numeric, numeric, numeric) is
  'Round 5 range filter (0047): true with no bound; else the score is set, >= min, and <= max unless max >= 5 (the top of the visible scale is open, so a secret 6 — or an average lifted past 5 by one — stays in).';

revoke all on function public.score_in_range(numeric, numeric, numeric) from public, anon;
grant execute on function public.score_in_range(numeric, numeric, numeric) to authenticated, service_role;

-- ===========================================================================
-- 1. my_entries + p_max_score, p_city
-- ===========================================================================
drop function if exists public.my_entries(text, uuid, numeric, text, date, date, int, timestamptz, uuid, numeric, text);

create function public.my_entries(
  p_sort              text        default 'newest',
  p_restaurant_id     uuid        default null,
  p_min_score         numeric     default null,
  p_tag               text        default null,
  p_from              date        default null,
  p_to                date        default null,
  p_limit             int         default 30,
  p_cursor_created_at timestamptz default null,
  p_cursor_id         uuid        default null,
  p_cursor_best_score numeric     default null,
  p_tz                text        default 'Australia/Melbourne',
  p_max_score         numeric     default null,
  p_city              text        default null
)
returns table (
  id         uuid,
  created_at timestamptz,
  best_score numeric(2,1)
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_me     uuid := auth.uid();
  v_sort   text := lower(btrim(coalesce(p_sort, 'newest')));
  v_tag    text := nullif(lower(btrim(coalesce(p_tag, ''))), '');
  v_tz     text := coalesce(nullif(btrim(coalesce(p_tz, '')), ''), 'Australia/Melbourne');
  v_lim    int  := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_city   text := nullif(lower(btrim(coalesce(p_city, ''))), '');
  v_places uuid[];
begin
  if v_me is null then
    raise exception 'my_entries needs a signed-in caller' using errcode = '42501';
  end if;
  if v_sort not in ('newest', 'oldest', 'top') then
    raise exception 'p_sort must be newest, oldest or top (got %)', p_sort using errcode = '22023';
  end if;
  if v_city is not null then
    v_places := coalesce(array(select pc.restaurant_id from public.place_cities pc where pc.city = v_city), '{}');
  end if;

  return query
  with base as (
    select e.id,
           e.created_at,
           (select max(v.score) from public.reviews v where v.entry_id = e.id) as best_score
    from public.entries e
    where e.author_id = v_me
      and (p_restaurant_id is null or e.restaurant_id = p_restaurant_id)
      and (v_city is null or e.restaurant_id = any(v_places))
      and (p_from is null or (e.created_at at time zone v_tz)::date >= p_from)
      and (p_to   is null or (e.created_at at time zone v_tz)::date <= p_to)
      and (v_tag is null or exists (
            select 1 from public.reviews v where v.entry_id = e.id and v_tag = any(v.tags)))
  )
  select b.id, b.created_at, b.best_score::numeric(2,1)
  from base b
  where public.score_in_range(b.best_score, p_min_score, p_max_score)
    and (
      p_cursor_id is null
      or (v_sort = 'newest' and (b.created_at, b.id) < (p_cursor_created_at, p_cursor_id))
      or (v_sort = 'oldest' and (b.created_at, b.id) > (p_cursor_created_at, p_cursor_id))
      or (v_sort = 'top' and (
            case
              when p_cursor_best_score is null then
                b.best_score is null and (b.created_at, b.id) < (p_cursor_created_at, p_cursor_id)
              else
                b.best_score is null
                or b.best_score < p_cursor_best_score
                or (b.best_score = p_cursor_best_score
                    and (b.created_at, b.id) < (p_cursor_created_at, p_cursor_id))
            end))
    )
  order by
    case when v_sort = 'top'    then b.best_score end desc nulls last,
    case when v_sort = 'oldest' then b.created_at end asc,
    case when v_sort = 'oldest' then b.id         end asc,
    b.created_at desc,
    b.id desc
  limit v_lim;
end;
$$;

comment on function public.my_entries(text, uuid, numeric, text, date, date, int, timestamptz, uuid, numeric, text, numeric, text) is
  'Journal: the caller''s own entry ids in order (newest | oldest | top by best line score, unscored last). Filters: place (p_restaurant_id, 0043) or city (p_city, 0047), best-score range (p_min_score/p_max_score — score_in_range: max >= 5 is open), one dietary tag, visit dates (inclusive, in p_tz). Read the cards from entry_cards. Keyset: newest/oldest (created_at, id); top (best_score desc nulls last, created_at desc, id desc) — pass every field of the last row, with the same filters.';

-- ===========================================================================
-- 2. my_entry_cities — the Journal's city picker.
-- ===========================================================================
create or replace function public.my_entry_cities()
returns table (city text, name text, region text, entry_count int)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select c.id, c.name, c.region, n.entry_count
  from (
    select pc.city, count(*)::int as entry_count
    from public.entries e
    join public.place_cities pc on pc.restaurant_id = e.restaurant_id
    where e.author_id = (select auth.uid())
    group by pc.city
  ) n
  join public.cities c on c.id = n.city
  order by n.entry_count desc, c.name, c.id;
$$;

comment on function public.my_entry_cities() is
  'Round 5 Journal city filter (0047): the cities the caller''s own entries are in, with how many visits each, busiest first then name. Pass `city` to my_entries(p_city).';

-- ===========================================================================
-- 3. search_places — 0042's body + range + city.
-- ===========================================================================
drop function if exists public.search_places(text, int, int, int, text, uuid, text[], text[], numeric);

create function public.search_places(
  p_query               text,
  p_limit               int       default 20,
  p_cursor_match_tier   int       default null,
  p_cursor_review_count int       default null,
  p_cursor_name         text      default null,
  p_cursor_id           uuid      default null,
  p_cuisines            text[]    default null,
  p_tags                text[]    default null,
  p_min_score           numeric   default null,
  p_max_score           numeric   default null,
  p_city                text      default null
)
returns table (
  restaurant_id uuid,
  name          text,
  cuisine       text,
  locality      text,
  avg_rating    numeric(2,1),
  review_count  int,
  people_count  int,
  dish_count    int,
  cover_url     text,
  match_tier    int
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with q as (
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim,
           public.search_filter_keys(p_cuisines) as cuisines,
           public.search_filter_keys(p_tags)     as tags
  ),
  hits as (
    select
      r.id,
      r.name,
      nullif(btrim(coalesce(r.cuisine, '')), '')           as cuisine,
      public.place_locality(r.address, r.city)             as locality,
      rs.avg_rating,
      coalesce(rs.review_count, 0)                         as review_count,
      coalesce(rs.people_count, 0)                         as people_count,
      coalesce(rs.dish_count, 0)                           as dish_count,
      nullif(btrim(coalesce(rs.cover_url, '')), '')        as cover_url,
      public.search_tier(public.search_key(r.name), q.key) as match_tier
    from public.restaurants r
    left join public.restaurant_stats rs on rs.restaurant_id = r.id
    cross join q
    where char_length(q.key) >= 2
      and public.search_key(r.name) like '%' || q.pat || '%'
      and (q.cuisines is null or lower(btrim(coalesce(r.cuisine, ''))) = any(q.cuisines))
      and public.score_in_range(rs.avg_rating, p_min_score, p_max_score)
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
      and (q.tags is null or public.place_has_tagged_dish(r.id, q.tags))
  )
  select h.id, h.name, h.cuisine, h.locality, h.avg_rating,
         h.review_count, h.people_count, h.dish_count, h.cover_url, h.match_tier
  from hits h
  where p_cursor_id is null
     or (h.match_tier, -h.review_count, h.name, h.id)
        > (coalesce(p_cursor_match_tier, 0), -coalesce(p_cursor_review_count, 0),
           coalesce(p_cursor_name, ''), p_cursor_id)
  order by h.match_tier, h.review_count desc, h.name, h.id
  limit (select lim from q);
$$;

comment on function public.search_places(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text) is
  'Search tab, Places scope: name · cuisine · score (design/v1/SearchResults). Accent-insensitive substring match, ranked by match tier then review count. Filters (NULL/empty = off): p_cuisines (any, case-insensitive), p_tags (a dish here carries every code), p_min_score/p_max_score (avg_rating range, score_in_range: max >= 5 is open; 0047), p_city (a cities.id, 0047). Keyset (match_tier, review_count, name, restaurant_id) — pass all four from the last row, and the same filters.';

-- ===========================================================================
-- 4. search_dishes — 0042's body + range + city (the dish's place's city).
-- ===========================================================================
drop function if exists public.search_dishes(text, int, int, int, text, uuid, text[], text[], numeric);

create function public.search_dishes(
  p_query               text,
  p_limit               int       default 20,
  p_cursor_match_tier   int       default null,
  p_cursor_review_count int       default null,
  p_cursor_dish_name    text      default null,
  p_cursor_dish_id      uuid      default null,
  p_cuisines            text[]    default null,
  p_tags                text[]    default null,
  p_min_score           numeric   default null,
  p_max_score           numeric   default null,
  p_city                text      default null
)
returns table (
  dish_id             uuid,
  dish_name           text,
  restaurant_id       uuid,
  restaurant_name     text,
  restaurant_locality text,
  score               numeric(2,1),
  review_count        int,
  scored_count        int,
  people_count        int,
  cover_url           text,
  match_tier          int,
  tags                text[]
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with q as (
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim,
           public.search_filter_keys(p_cuisines) as cuisines,
           public.search_filter_keys(p_tags)     as tags
  ),
  hits as (
    select
      d.id                                                 as dish_id,
      d.name                                               as dish_name,
      r.id                                                 as restaurant_id,
      r.name                                               as restaurant_name,
      public.place_locality(r.address, r.city)             as restaurant_locality,
      ds.score,
      coalesce(ds.review_count, 0)                         as review_count,
      coalesce(ds.scored_count, 0)                         as scored_count,
      coalesce(ds.people_count, 0)                         as people_count,
      nullif(btrim(coalesce(ds.cover_url, '')), '')        as cover_url,
      public.search_tier(public.search_key(d.name), q.key) as match_tier
    from public.dishes d
    join public.restaurants r on r.id = d.restaurant_id
    left join public.dish_stats ds on ds.dish_id = d.id
    cross join q
    where char_length(q.key) >= 2
      and d.merged_into_dish_id is null
      and public.search_key(d.name) like '%' || q.pat || '%'
      and coalesce(ds.review_count, 0) > 0
      and (q.cuisines is null or lower(btrim(coalesce(r.cuisine, ''))) = any(q.cuisines))
      and public.score_in_range(ds.score, p_min_score, p_max_score)
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
      and (q.tags is null or public.dish_consensus_tags(d.id) @> q.tags)
  )
  select pg.*, public.dish_consensus_tags(pg.dish_id) as tags
  from (
    select h.dish_id, h.dish_name, h.restaurant_id, h.restaurant_name, h.restaurant_locality,
           h.score, h.review_count, h.scored_count, h.people_count, h.cover_url, h.match_tier
    from hits h
    where p_cursor_dish_id is null
       or (h.match_tier, -h.review_count, h.dish_name, h.dish_id)
          > (coalesce(p_cursor_match_tier, 0), -coalesce(p_cursor_review_count, 0),
             coalesce(p_cursor_dish_name, ''), p_cursor_dish_id)
    order by h.match_tier, h.review_count desc, h.dish_name, h.dish_id
    limit (select lim from q)
  ) pg
  order by pg.match_tier, pg.review_count desc, pg.dish_name, pg.dish_id;
$$;

comment on function public.search_dishes(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text) is
  'Search tab, Dishes scope: cover · dish · place · score in ONE call (design/v1/SearchResults). Only dishes with a review the viewer can see. Filters (NULL/empty = off): p_cuisines (the place''s, any), p_tags (the dish''s consensus chips carry every code), p_min_score/p_max_score (score range, score_in_range: max >= 5 is open; 0047), p_city (the place''s city, 0047). `tags` = the dish''s chips. Keyset (match_tier, review_count, dish_name, dish_id), same filters on every page.';

-- ===========================================================================
-- 5. nearby_places — 0042's body + range + city.
-- ===========================================================================
drop function if exists public.nearby_places(double precision, double precision, double precision, int, double precision, uuid, text[], text[], numeric);

create function public.nearby_places(
  p_lat               double precision,
  p_lng               double precision,
  p_radius_m          double precision default 5000,
  p_limit             int              default 20,
  p_cursor_distance_m double precision default null,
  p_cursor_id         uuid             default null,
  p_cuisines          text[]           default null,
  p_tags              text[]           default null,
  p_min_score         numeric          default null,
  p_max_score         numeric          default null,
  p_city              text             default null
)
returns table (
  restaurant_id uuid,
  name          text,
  cuisine       text,
  locality      text,
  avg_rating    numeric(2,1),
  review_count  int,
  people_count  int,
  dish_count    int,
  cover_url     text,
  distance_m    double precision
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with origin as (
    select extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::geography as g,
           least(greatest(coalesce(p_radius_m, 5000), 100), 50000) as radius,
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim,
           public.search_filter_keys(p_cuisines) as cuisines,
           public.search_filter_keys(p_tags)     as tags
  ),
  hits as (
    select
      r.id,
      r.name,
      nullif(btrim(coalesce(r.cuisine, '')), '')    as cuisine,
      public.place_locality(r.address, r.city)      as locality,
      rs.avg_rating,
      coalesce(rs.review_count, 0)                  as review_count,
      coalesce(rs.people_count, 0)                  as people_count,
      coalesce(rs.dish_count, 0)                    as dish_count,
      nullif(btrim(coalesce(rs.cover_url, '')), '') as cover_url,
      extensions.ST_Distance(r.location, o.g)       as distance_m
    from public.restaurants r
    left join public.restaurant_stats rs on rs.restaurant_id = r.id
    cross join origin o
    where r.location is not null
      and extensions.ST_DWithin(r.location, o.g, o.radius)
      and (o.cuisines is null or lower(btrim(coalesce(r.cuisine, ''))) = any(o.cuisines))
      and public.score_in_range(rs.avg_rating, p_min_score, p_max_score)
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
      and (o.tags is null or public.place_has_tagged_dish(r.id, o.tags))
  )
  select h.id, h.name, h.cuisine, h.locality, h.avg_rating,
         h.review_count, h.people_count, h.dish_count, h.cover_url, h.distance_m
  from hits h
  where p_cursor_id is null
     or (h.distance_m, h.id) > (coalesce(p_cursor_distance_m, -1), p_cursor_id)
  order by h.distance_m, h.id
  limit (select lim from origin);
$$;

comment on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid, text[], text[], numeric, numeric, text) is
  'Search tab "Nearby" (design/v1/Search): places we already hold near a point, with their viewer-relative score. SECURITY INVOKER, PostGIS only — no Google call. Filters as search_places (0042, 0047). Keyset (distance_m, restaurant_id).';

-- ===========================================================================
-- 6. search_cities — the Search city picker.
-- ===========================================================================
create or replace function public.search_cities()
returns table (city text, name text, region text, place_count int)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select c.id, c.name, c.region, n.place_count
  from (
    select pc.city, count(*)::int as place_count
    from public.place_cities pc
    group by pc.city
  ) n
  join public.cities c on c.id = n.city
  order by n.place_count desc, c.name, c.id;
$$;

comment on function public.search_cities() is
  'Round 5 Search city filter (0047): cities of the places we hold, with how many places each, busiest first then name. Pass `city` in p_city.';

-- ===========================================================================
-- GRANTS — signed-in only, as every Search and Journal read.
-- ===========================================================================
revoke all on function public.my_entries(text, uuid, numeric, text, date, date, int, timestamptz, uuid, numeric, text, numeric, text) from public, anon;
revoke all on function public.my_entry_cities() from public, anon;
revoke all on function public.search_places(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text) from public, anon;
revoke all on function public.search_dishes(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text) from public, anon;
revoke all on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid, text[], text[], numeric, numeric, text)
  from public, anon;
revoke all on function public.search_cities() from public, anon;

grant execute on function public.my_entries(text, uuid, numeric, text, date, date, int, timestamptz, uuid, numeric, text, numeric, text) to authenticated;
grant execute on function public.my_entry_cities() to authenticated;
grant execute on function public.search_places(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text) to authenticated;
grant execute on function public.search_dishes(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text) to authenticated;
grant execute on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid, text[], text[], numeric, numeric, text)
  to authenticated;
grant execute on function public.search_cities() to authenticated;

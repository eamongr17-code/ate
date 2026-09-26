-- 0042_search_filters.sql
-- Ate backend — round 4: SEARCH FILTERS. The Search tab's Places and Dishes scopes, and the Nearby
-- list before a key is pressed, gain three optional filters, and one new read lists the cuisines
-- to offer:
--
--   p_cuisines  text[]   the place's cuisine is ANY of these (trimmed, case-insensitive). Pass the
--                        `cuisine` strings search_cuisines() returns.
--   p_tags      text[]   dietary codes (gf · df · v · vg · nf). A DISH matches when its chips carry
--                        EVERY requested code — `dish_consensus_tags` (0036), the same chips
--                        dish_summary prints, viewer-relative. A PLACE matches when ANY of its dishes
--                        does. (One dish carrying all of them: a diner who is vegan AND gluten free
--                        needs one plate that is both, not a vegan plate and a GF plate.) An unknown
--                        code matches nothing.
--   p_min_score numeric  the printed aggregate is at least this: `avg_rating` for a place, `score`
--                        for a dish. Unscored rows drop out once it is set.
--
-- NULL or an empty array = no filter, so every existing call returns exactly what it did. The filters
-- are predicates inside the ranked set, never after the LIMIT, so KEYSET PAGING IS UNCHANGED: the same
-- cursor columns, and pages stay gap-free as long as every page is asked with the same filters. The
-- two-character query rule is unchanged too (the pre-typing state is nearby_places, which filters).
--
--   search_cuisines()  → (cuisine, place_count): the cuisines of places we hold, grouped
--                        case-insensitively under their commonest spelling, busiest first then A→Z.
--                        place_count = how many places search_places can return for it.
--
-- Search is signed-in only (0031) — there are no anon twins to change, and none are added.
--
-- WIRE IMPACT
--   ADDITIVE: three trailing optional params on search_places / search_dishes / nearby_places (named
--     calls without them bind unchanged); new RPC search_cuisines(); helpers search_filter_keys,
--     place_has_tagged_dish. OUT columns unchanged. New params ⇒ DROP-then-CREATE (landmine 7), then
--     re-grant.

set search_path = public, extensions;

-- ===========================================================================
-- Helpers
-- ===========================================================================

-- A filter list, normalised: trimmed, lower-cased, deduped, blanks dropped. NULL when nothing is
-- left — so NULL, '{}' and '{" "}' all mean "no filter".
create or replace function public.search_filter_keys(p_values text[])
returns text[]
language sql
immutable
set search_path = public, extensions
as $$
  select case when cardinality(k.keys) > 0 then k.keys end
  from (
    select array_agg(distinct lower(btrim(x))) filter (where btrim(coalesce(x, '')) <> '') as keys
    from unnest(coalesce(p_values, '{}'::text[])) as x
  ) k;
$$;

-- Does any dish at this place carry EVERY code in p_tags (its consensus chips)? The overlap on
-- reviews.tags is a cheap pre-filter on the place's own lines (reviews_restaurant_idx); only those
-- dishes pay for the consensus. SECURITY INVOKER: a blocked author's lines count for nothing here,
-- exactly as in dish_summary.
create or replace function public.place_has_tagged_dish(p_restaurant_id uuid, p_tags text[])
returns boolean
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select exists (
    select 1
    from (
      select distinct v.dish_id
      from public.reviews v
      where v.restaurant_id = p_restaurant_id
        and v.tags && p_tags
    ) c
    join public.dishes d on d.id = c.dish_id and d.merged_into_dish_id is null
    where public.dish_consensus_tags(c.dish_id) @> p_tags
  );
$$;

comment on function public.place_has_tagged_dish(uuid, text[]) is
  'Round 4 search filter: true when one of the place''s dishes carries every code in p_tags as a consensus chip (dish_consensus_tags, viewer-relative).';

revoke all on function public.search_filter_keys(text[]) from public, anon;
revoke all on function public.place_has_tagged_dish(uuid, text[]) from public, anon;
grant execute on function public.search_filter_keys(text[]) to authenticated, service_role;
grant execute on function public.place_has_tagged_dish(uuid, text[]) to authenticated, service_role;

-- ===========================================================================
-- 1. search_places — 0031's body + the three filters.
-- ===========================================================================
drop function if exists public.search_places(text, int, int, int, text, uuid);

create function public.search_places(
  p_query               text,
  p_limit               int       default 20,
  p_cursor_match_tier   int       default null,
  p_cursor_review_count int       default null,
  p_cursor_name         text      default null,
  p_cursor_id           uuid      default null,
  p_cuisines            text[]    default null,
  p_tags                text[]    default null,
  p_min_score           numeric   default null
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
      and (p_min_score is null or rs.avg_rating >= p_min_score)
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

comment on function public.search_places(text, int, int, int, text, uuid, text[], text[], numeric) is
  'Search tab, Places scope: name · cuisine · score (design/v1/SearchResults). Accent-insensitive substring match, ranked by match tier then review count. Filters (0042, NULL/empty = off): p_cuisines (any, case-insensitive), p_tags (a dish here carries every code), p_min_score (avg_rating >=). Keyset (match_tier, review_count, name, restaurant_id) — pass all four from the last row, and the same filters.';

-- ===========================================================================
-- 2. search_dishes — 0031's body + the three filters (cuisine = the dish's place's).
-- ===========================================================================
drop function if exists public.search_dishes(text, int, int, int, text, uuid);

create function public.search_dishes(
  p_query               text,
  p_limit               int       default 20,
  p_cursor_match_tier   int       default null,
  p_cursor_review_count int       default null,
  p_cursor_dish_name    text      default null,
  p_cursor_dish_id      uuid      default null,
  p_cuisines            text[]    default null,
  p_tags                text[]    default null,
  p_min_score           numeric   default null
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
  match_tier          int
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
      and (p_min_score is null or ds.score >= p_min_score)
      and (q.tags is null or public.dish_consensus_tags(d.id) @> q.tags)
  )
  select h.dish_id, h.dish_name, h.restaurant_id, h.restaurant_name, h.restaurant_locality,
         h.score, h.review_count, h.scored_count, h.people_count, h.cover_url, h.match_tier
  from hits h
  where p_cursor_dish_id is null
     or (h.match_tier, -h.review_count, h.dish_name, h.dish_id)
        > (coalesce(p_cursor_match_tier, 0), -coalesce(p_cursor_review_count, 0),
           coalesce(p_cursor_dish_name, ''), p_cursor_dish_id)
  order by h.match_tier, h.review_count desc, h.dish_name, h.dish_id
  limit (select lim from q);
$$;

comment on function public.search_dishes(text, int, int, int, text, uuid, text[], text[], numeric) is
  'Search tab, Dishes scope: cover · dish · place · score in ONE call (design/v1/SearchResults). Only dishes with a review the viewer can see. Filters (0042, NULL/empty = off): p_cuisines (the place''s, any), p_tags (the dish''s consensus chips carry every code), p_min_score (score >=). Keyset (match_tier, review_count, dish_name, dish_id), same filters on every page.';

-- ===========================================================================
-- 3. nearby_places — 0031's body + the three filters.
-- ===========================================================================
drop function if exists public.nearby_places(double precision, double precision, double precision, int, double precision, uuid);

create function public.nearby_places(
  p_lat               double precision,
  p_lng               double precision,
  p_radius_m          double precision default 5000,
  p_limit             int              default 20,
  p_cursor_distance_m double precision default null,
  p_cursor_id         uuid             default null,
  p_cuisines          text[]           default null,
  p_tags              text[]           default null,
  p_min_score         numeric          default null
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
      and (p_min_score is null or rs.avg_rating >= p_min_score)
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

comment on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid, text[], text[], numeric) is
  'Search tab "Nearby" (design/v1/Search): places we already hold near a point, with their viewer-relative score. SECURITY INVOKER, PostGIS only — no Google call. Filters as search_places (0042). Keyset (distance_m, restaurant_id).';

-- ===========================================================================
-- 4. search_cuisines — the filter's choices.
-- ===========================================================================
create or replace function public.search_cuisines()
returns table (cuisine text, place_count int)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select g.cuisine, g.place_count
  from (
    -- mode() breaks a tie on the first value in its ORDER BY; "C" makes that the same on every
    -- database (a capital first: "Italian" over "italian"), whatever the default collation is.
    select mode() within group (order by btrim(r.cuisine) collate "C") as cuisine, count(*)::int as place_count
    from public.restaurants r
    where btrim(coalesce(r.cuisine, '')) <> ''
    group by lower(btrim(r.cuisine))
  ) g
  order by g.place_count desc, g.cuisine;
$$;

comment on function public.search_cuisines() is
  'Round 4 search filter choices: the cuisines of places we hold, grouped case-insensitively under the commonest spelling, with how many places carry each (= what search_places can return for it). Busiest first, then A→Z. Pass `cuisine` back in p_cuisines.';

-- ===========================================================================
-- GRANTS — signed-in only, as every Search read (0031).
-- ===========================================================================
revoke all on function public.search_places(text, int, int, int, text, uuid, text[], text[], numeric) from public, anon;
revoke all on function public.search_dishes(text, int, int, int, text, uuid, text[], text[], numeric) from public, anon;
revoke all on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid, text[], text[], numeric)
  from public, anon;
revoke all on function public.search_cuisines() from public, anon;

grant execute on function public.search_places(text, int, int, int, text, uuid, text[], text[], numeric) to authenticated;
grant execute on function public.search_dishes(text, int, int, int, text, uuid, text[], text[], numeric) to authenticated;
grant execute on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid, text[], text[], numeric)
  to authenticated;
grant execute on function public.search_cuisines() to authenticated;

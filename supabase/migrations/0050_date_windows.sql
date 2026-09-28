-- 0050_date_windows.sql
-- Ate backend — round 6: a DATE RANGE on the shared filter sheet, for Search and Saved. The Journal's
-- my_entries has had it since 0043; this gives the other two surfaces the same parameters with the same
-- meaning.
--
--   p_from date, p_to date, p_tz text   inclusive calendar days in p_tz (default Australia/Melbourne,
--                                       the launch market; pass the device zone). Either may be NULL
--                                       (open-ended). Both NULL = no window, today's reads byte for
--                                       byte. Identical to my_entries' p_from/p_to/p_tz.
--
-- WHAT THE WINDOW MEANS, per surface:
--   Journal (0043, unchanged) — the VISIT's day (entries.created_at).
--   Search — only the dish lines whose visit falls in the window COUNT: a row's score, review_count,
--     scored_count, people_count, dish_count (and a place's avg_rating, still the mean of per-dish
--     averages) are computed over those lines alone, and a place or dish with NO line in the window is
--     not a result. The score range (0047) then applies to the windowed number, and the keyset
--     cursors carry the windowed review_count, so paging stays gap-free with the same filters.
--     NOT windowed: cover_url (the newest photo is the right picture whatever the range) and dietary
--     chips / p_tags (a dish's chips describe the plate, not a period).
--     THE TRADE-OFF, accepted: a windowed row can print a different number from the Place / Dish page
--     it opens (those stay all-time). That is the point of the filter — "how good has it been since
--     June" — so the sheet's date chip must be visible whenever a window is on. The alternative
--     considered, "was reviewed in the window but show all-time numbers", answers "is it still open",
--     not "is it still good", and is reachable later as its own flag if wanted.
--   Saved — the day you SAVED the dish (saves.created_at).
--   nearby_places gets the same window as search_places (it is the Places list before typing, under
--     the same sheet).
--
-- WIRE IMPACT: ADDITIVE. Three trailing optional params on search_places, search_dishes,
-- nearby_places and search_saved (drop-then-create, LANDMINE 7; old calls bind; OUT columns
-- unchanged; grants restated). New helper in_window().

set search_path = public, extensions;

-- ===========================================================================
-- Helper — my_entries' date rule, once.
-- ===========================================================================
create or replace function public.in_window(p_at timestamptz, p_from date, p_to date, p_tz text)
returns boolean
language sql
stable
set search_path = public, extensions
as $$
  select (p_from is null or (p_at at time zone coalesce(nullif(btrim(coalesce(p_tz, '')), ''), 'Australia/Melbourne'))::date >= p_from)
     and (p_to   is null or (p_at at time zone coalesce(nullif(btrim(coalesce(p_tz, '')), ''), 'Australia/Melbourne'))::date <= p_to);
$$;

comment on function public.in_window(timestamptz, date, date, text) is
  'Round 6 date filter (0050): is the instant on a calendar day in [p_from, p_to] (inclusive, either open) in p_tz (default Australia/Melbourne)? my_entries'' rule.';

revoke all on function public.in_window(timestamptz, date, date, text) from public, anon;
grant execute on function public.in_window(timestamptz, date, date, text) to authenticated, service_role;

-- ===========================================================================
-- 1. search_places — 0047's body; with a window, the numbers come from the window's lines.
-- ===========================================================================
drop function if exists public.search_places(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text);

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
  p_city                text      default null,
  p_from                date      default null,
  p_to                  date      default null,
  p_tz                  text      default 'Australia/Melbourne'
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
           public.search_filter_keys(p_tags)     as tags,
           (p_from is not null or p_to is not null) as windowed
  ),
  -- The window's lines, per dish then per place. Empty (and not scanned) when there is no window.
  wd as (
    select v.dish_id, v.restaurant_id, avg(v.score) as score, count(*) as n
    from public.reviews v
    join public.dishes d on d.id = v.dish_id and d.merged_into_dish_id is null
    where (p_from is not null or p_to is not null)
      and public.in_window(v.created_at, p_from, p_to, p_tz)
    group by v.dish_id, v.restaurant_id
  ),
  wr as (
    select w.restaurant_id,
           round(avg(round(w.score, 1)) filter (where w.score is not null), 1)::numeric(2,1) as avg_rating,
           sum(w.n)::int as review_count,
           count(*)::int as dish_count,
           (select count(distinct v.reviewer_id)::int from public.reviews v
             where v.restaurant_id = w.restaurant_id
               and public.in_window(v.created_at, p_from, p_to, p_tz)) as people_count
    from wd w
    group by w.restaurant_id
  ),
  hits as (
    select
      r.id,
      r.name,
      nullif(btrim(coalesce(r.cuisine, '')), '')                               as cuisine,
      public.place_locality(r.address, r.city)                                 as locality,
      case when q.windowed then wr.avg_rating else rs.avg_rating end           as avg_rating,
      case when q.windowed then wr.review_count else coalesce(rs.review_count, 0) end as review_count,
      case when q.windowed then wr.people_count else coalesce(rs.people_count, 0) end as people_count,
      case when q.windowed then wr.dish_count else coalesce(rs.dish_count, 0) end     as dish_count,
      nullif(btrim(coalesce(rs.cover_url, '')), '')                            as cover_url,
      public.search_tier(public.search_key(r.name), q.key)                     as match_tier
    from public.restaurants r
    left join public.restaurant_stats rs on rs.restaurant_id = r.id
    left join wr on wr.restaurant_id = r.id
    cross join q
    where char_length(q.key) >= 2
      and public.search_key(r.name) like '%' || q.pat || '%'
      and (not q.windowed or wr.restaurant_id is not null)
      and (q.cuisines is null or lower(btrim(coalesce(r.cuisine, ''))) = any(q.cuisines))
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
      and (q.tags is null or public.place_has_tagged_dish(r.id, q.tags))
  )
  select h.id, h.name, h.cuisine, h.locality, h.avg_rating,
         h.review_count, h.people_count, h.dish_count, h.cover_url, h.match_tier
  from hits h
  where public.score_in_range(h.avg_rating, p_min_score, p_max_score)
    and (p_cursor_id is null
         or (h.match_tier, -h.review_count, h.name, h.id)
            > (coalesce(p_cursor_match_tier, 0), -coalesce(p_cursor_review_count, 0),
               coalesce(p_cursor_name, ''), p_cursor_id))
  order by h.match_tier, h.review_count desc, h.name, h.id
  limit (select lim from q);
$$;

comment on function public.search_places(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text, date, date, text) is
  'Search tab, Places scope. Accent-insensitive substring match, ranked by match tier then review count. Filters (NULL/empty = off): p_cuisines, p_tags (a dish here carries every code), p_min_score/p_max_score (avg_rating, score_in_range), p_city, and p_from/p_to/p_tz (0050: only lines whose visit day is in the window count — avg_rating, review_count, people_count, dish_count are the window''s, and a place with none is not a result; cover_url stays all-time). Keyset (match_tier, review_count, name, restaurant_id) — the same filters on every page.';

-- ===========================================================================
-- 2. search_dishes — 0047's body; with a window, the dish's numbers are the window's.
-- ===========================================================================
drop function if exists public.search_dishes(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text);

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
  p_city                text      default null,
  p_from                date      default null,
  p_to                  date      default null,
  p_tz                  text      default 'Australia/Melbourne'
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
           public.search_filter_keys(p_tags)     as tags,
           (p_from is not null or p_to is not null) as windowed
  ),
  wd as (
    select v.dish_id,
           round(avg(v.score), 1)::numeric(2,1)  as score,
           count(*)::int                         as review_count,
           count(v.score)::int                   as scored_count,
           count(distinct v.reviewer_id)::int    as people_count
    from public.reviews v
    where (p_from is not null or p_to is not null)
      and public.in_window(v.created_at, p_from, p_to, p_tz)
    group by v.dish_id
  ),
  hits as (
    select
      d.id                                                 as dish_id,
      d.name                                               as dish_name,
      r.id                                                 as restaurant_id,
      r.name                                               as restaurant_name,
      public.place_locality(r.address, r.city)             as restaurant_locality,
      case when q.windowed then wd.score else ds.score end as score,
      case when q.windowed then coalesce(wd.review_count, 0) else coalesce(ds.review_count, 0) end as review_count,
      case when q.windowed then coalesce(wd.scored_count, 0) else coalesce(ds.scored_count, 0) end as scored_count,
      case when q.windowed then coalesce(wd.people_count, 0) else coalesce(ds.people_count, 0) end as people_count,
      nullif(btrim(coalesce(ds.cover_url, '')), '')        as cover_url,
      public.search_tier(public.search_key(d.name), q.key) as match_tier
    from public.dishes d
    join public.restaurants r on r.id = d.restaurant_id
    left join public.dish_stats ds on ds.dish_id = d.id
    left join wd on wd.dish_id = d.id
    cross join q
    where char_length(q.key) >= 2
      and d.merged_into_dish_id is null
      and public.search_key(d.name) like '%' || q.pat || '%'
      and (q.cuisines is null or lower(btrim(coalesce(r.cuisine, ''))) = any(q.cuisines))
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
      and (q.tags is null or public.dish_consensus_tags(d.id) @> q.tags)
  )
  select pg.*, public.dish_consensus_tags(pg.dish_id) as tags
  from (
    select h.dish_id, h.dish_name, h.restaurant_id, h.restaurant_name, h.restaurant_locality,
           h.score, h.review_count, h.scored_count, h.people_count, h.cover_url, h.match_tier
    from hits h
    where h.review_count > 0
      and public.score_in_range(h.score, p_min_score, p_max_score)
      and (p_cursor_dish_id is null
           or (h.match_tier, -h.review_count, h.dish_name, h.dish_id)
              > (coalesce(p_cursor_match_tier, 0), -coalesce(p_cursor_review_count, 0),
                 coalesce(p_cursor_dish_name, ''), p_cursor_dish_id))
    order by h.match_tier, h.review_count desc, h.dish_name, h.dish_id
    limit (select lim from q)
  ) pg
  order by pg.match_tier, pg.review_count desc, pg.dish_name, pg.dish_id;
$$;

comment on function public.search_dishes(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text, date, date, text) is
  'Search tab, Dishes scope, in ONE call. Only dishes with a line the viewer can see. Filters (NULL/empty = off): p_cuisines, p_tags (consensus chips carry every code), p_min_score/p_max_score (score, score_in_range), p_city, and p_from/p_to/p_tz (0050: score, review_count, scored_count, people_count are over the window''s lines only; a dish with none is not a result; cover_url and tags stay all-time). Keyset (match_tier, review_count, dish_name, dish_id), same filters on every page.';

-- ===========================================================================
-- 3. nearby_places — 0047's body + the same window as search_places.
-- ===========================================================================
drop function if exists public.nearby_places(double precision, double precision, double precision, int, double precision, uuid, text[], text[], numeric, numeric, text);

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
  p_city              text             default null,
  p_from              date             default null,
  p_to                date             default null,
  p_tz                text             default 'Australia/Melbourne'
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
           public.search_filter_keys(p_tags)     as tags,
           (p_from is not null or p_to is not null) as windowed
  ),
  wd as (
    select v.dish_id, v.restaurant_id, avg(v.score) as score, count(*) as n
    from public.reviews v
    join public.dishes d on d.id = v.dish_id and d.merged_into_dish_id is null
    where (p_from is not null or p_to is not null)
      and public.in_window(v.created_at, p_from, p_to, p_tz)
    group by v.dish_id, v.restaurant_id
  ),
  wr as (
    select w.restaurant_id,
           round(avg(round(w.score, 1)) filter (where w.score is not null), 1)::numeric(2,1) as avg_rating,
           sum(w.n)::int as review_count,
           count(*)::int as dish_count,
           (select count(distinct v.reviewer_id)::int from public.reviews v
             where v.restaurant_id = w.restaurant_id
               and public.in_window(v.created_at, p_from, p_to, p_tz)) as people_count
    from wd w
    group by w.restaurant_id
  ),
  hits as (
    select
      r.id,
      r.name,
      nullif(btrim(coalesce(r.cuisine, '')), '')                               as cuisine,
      public.place_locality(r.address, r.city)                                 as locality,
      case when o.windowed then wr.avg_rating else rs.avg_rating end           as avg_rating,
      case when o.windowed then wr.review_count else coalesce(rs.review_count, 0) end as review_count,
      case when o.windowed then wr.people_count else coalesce(rs.people_count, 0) end as people_count,
      case when o.windowed then wr.dish_count else coalesce(rs.dish_count, 0) end     as dish_count,
      nullif(btrim(coalesce(rs.cover_url, '')), '')                            as cover_url,
      extensions.ST_Distance(r.location, o.g)                                  as distance_m
    from public.restaurants r
    left join public.restaurant_stats rs on rs.restaurant_id = r.id
    left join wr on wr.restaurant_id = r.id
    cross join origin o
    where r.location is not null
      and extensions.ST_DWithin(r.location, o.g, o.radius)
      and (not o.windowed or wr.restaurant_id is not null)
      and (o.cuisines is null or lower(btrim(coalesce(r.cuisine, ''))) = any(o.cuisines))
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
      and (o.tags is null or public.place_has_tagged_dish(r.id, o.tags))
  )
  select h.id, h.name, h.cuisine, h.locality, h.avg_rating,
         h.review_count, h.people_count, h.dish_count, h.cover_url, h.distance_m
  from hits h
  where public.score_in_range(h.avg_rating, p_min_score, p_max_score)
    and (p_cursor_id is null
         or (h.distance_m, h.id) > (coalesce(p_cursor_distance_m, -1), p_cursor_id))
  order by h.distance_m, h.id
  limit (select lim from origin);
$$;

comment on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid, text[], text[], numeric, numeric, text, date, date, text) is
  'Search tab "Nearby": places we already hold near a point, with their viewer-relative score. PostGIS only — no Google call. Filters as search_places, including the 0050 date window. Keyset (distance_m, restaurant_id).';

-- ===========================================================================
-- 4. search_saved — 0049's body + the day you saved it.
-- ===========================================================================
drop function if exists public.search_saved(text, int, timestamptz, uuid, numeric, numeric, text);

create function public.search_saved(
  p_query           text        default null,
  p_limit           int         default 20,
  p_cursor_saved_at timestamptz default null,
  p_cursor_dish_id  uuid        default null,
  p_min_score       numeric     default null,
  p_max_score       numeric     default null,
  p_city            text        default null,
  p_from            date        default null,
  p_to              date        default null,
  p_tz              text        default 'Australia/Melbourne'
)
returns table (
  dish_id             uuid,
  dish_name           text,
  restaurant_id       uuid,
  restaurant_name     text,
  restaurant_city     text,
  restaurant_locality text,
  dish_score          numeric(2,1),
  dish_cover_url      text,
  source_entry_id     uuid,
  source_user_id      uuid,
  source_username     citext,
  saved_at            timestamptz,
  cover_url           text
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with q as (
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim
  )
  select
    s.dish_id,
    d.name                                        as dish_name,
    r.id                                          as restaurant_id,
    r.name                                        as restaurant_name,
    nullif(btrim(coalesce(r.city, '')), '')       as restaurant_city,
    public.place_locality(r.address, r.city)      as restaurant_locality,
    ds.score                                      as dish_score,
    nullif(btrim(coalesce(ds.cover_url, '')), '') as dish_cover_url,
    s.source_entry_id,
    s.source_user_id,
    sp.username                                   as source_username,
    s.created_at                                  as saved_at,
    nullif(btrim(coalesce(ds.cover_url, '')), '') as cover_url
  from public.saves s
  join public.dishes d           on d.id = s.dish_id
  join public.restaurants r      on r.id = d.restaurant_id
  left join public.dish_stats ds on ds.dish_id = s.dish_id
  left join public.profiles sp   on sp.id = s.source_user_id
  cross join q
  where s.user_id = (select auth.uid())
    and (
      q.key = ''
      or public.search_key(d.name) like '%' || q.pat || '%'
      or public.search_key(r.name) like '%' || q.pat || '%'
    )
    and public.score_in_range(ds.score, p_min_score, p_max_score)
    and (nullif(btrim(coalesce(p_city, '')), '') is null
         or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
    and public.in_window(s.created_at, p_from, p_to, p_tz)
    and (
      p_cursor_dish_id is null
      or (s.created_at, s.dish_id) < (p_cursor_saved_at, p_cursor_dish_id)
    )
  order by s.created_at desc, s.dish_id desc
  limit (select lim from q);
$$;

comment on function public.search_saved(text, int, timestamptz, uuid, numeric, numeric, text, date, date, text) is
  'Saved shelf + Search Saved scope: my_saved_dishes'' columns (+ restaurant_locality), filtered by dish OR place name (empty query = the whole list), dish_score range (score_in_range), city, and the day you saved it (p_from/p_to inclusive in p_tz, 0050). Keyset (saved_at, dish_id), same filters on every page.';

-- ===========================================================================
-- GRANTS — signed-in only, as before.
-- ===========================================================================
revoke all on function public.search_places(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text, date, date, text) from public, anon;
revoke all on function public.search_dishes(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text, date, date, text) from public, anon;
revoke all on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid, text[], text[], numeric, numeric, text, date, date, text)
  from public, anon;
revoke all on function public.search_saved(text, int, timestamptz, uuid, numeric, numeric, text, date, date, text) from public, anon;

grant execute on function public.search_places(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text, date, date, text) to authenticated;
grant execute on function public.search_dishes(text, int, int, int, text, uuid, text[], text[], numeric, numeric, text, date, date, text) to authenticated;
grant execute on function public.nearby_places(double precision, double precision, double precision, int, double precision, uuid, text[], text[], numeric, numeric, text, date, date, text)
  to authenticated;
grant execute on function public.search_saved(text, int, timestamptz, uuid, numeric, numeric, text, date, date, text) to authenticated;

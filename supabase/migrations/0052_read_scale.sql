-- 0052_read_scale.sql
-- Ate backend — reads at scale. On the round-6 staging dataset (334 places, 1.7k dishes, 1.6k entries,
-- 5k lines) Search took 0.4–2 s, a date-windowed search hit the statement timeout, and entry_cards
-- pages timed out under concurrent load. NOTHING HERE CHANGES WHAT ANY READ RETURNS — same rows, same
-- numbers, same order, same signatures and columns. It changes HOW the numbers are computed:
--
--  1. dish_stats / restaurant_stats: from "GROUP BY over every dish/place, then join" to "per row,
--     LATERAL". A grouped view cannot take a join condition, so any read joining it (search, saved,
--     search_all) aggregated and cover-photo'd EVERY dish in the catalogue to use a page of them. As a
--     lateral view it computes only the rows the outer query asks for. Same columns, same values.
--  2. The Search reads (search_places, search_dishes, nearby_places, search_saved) compute their numbers
--     per HIT through two helpers, place_numbers / dish_numbers, and the cover photo only for the PAGE
--     they return. A date window becomes a timestamp range (the first instant of p_from … the first
--     instant after p_to, in p_tz) — exactly in_window()'s calendar-day rule, but index-friendly.
--  3. place_cities reads a cache table, place_city_cache, instead of deriving every place's city on
--     every read (a regex and a PostGIS lookup per place). Triggers keep it exact: a place's own row
--     on insert/update/delete, plus every place sharing its locality (the "sibling locality" rule of
--     0046 means one located place can re-home a hand-added namesake); a change to `cities` rebuilds
--     it. The view's columns and rows are unchanged.
--
-- STILL VIEWER-RELATIVE: nothing viewer-dependent is cached. Scores, counts and covers are still
-- computed live under RLS (a blocked author's lines count for nobody but themselves); only the
-- city of a place — catalogue data, the same for every viewer — is stored.
--
-- WIRE IMPACT: NONE. New objects: place_city_cache (+ triggers, refresh functions), place_numbers,
-- dish_numbers, window_bounds. Existing functions are replaced in place (same signatures); search_all
-- also gains a final `id` sort key (its order among exact ties was unspecified).
-- DATA: place_city_cache is filled from the catalogue here (restaurants → derived city). No existing
-- row is modified.

set search_path = public, extensions;

-- ===========================================================================
-- 1. Stats views, per row.
-- ===========================================================================
create or replace view public.dish_stats
with (security_invoker = true) as
  select
    d.id                      as dish_id,
    d.restaurant_id,
    a.score,
    a.review_count,
    public.dish_cover_url(d.id) as cover_url,
    a.scored_count,
    a.people_count
  from public.dishes d
  cross join lateral (
    select round(avg(r.score), 1)::numeric(2,1) as score,     -- NULL when nobody scored it
           count(r.id)::int                     as review_count,
           count(r.score)::int                  as scored_count,
           count(distinct r.reviewer_id)::int   as people_count
    from public.reviews r
    where r.dish_id = d.id
  ) a
  where d.merged_into_dish_id is null;

create or replace view public.restaurant_stats
with (security_invoker = true) as
  select
    rst.id                                  as restaurant_id,
    a.avg_rating,
    a.review_count,
    public.restaurant_cover_url(rst.id)     as cover_url,
    p.people_count,
    a.dish_count
  from public.restaurants rst
  cross join lateral (
    select round(avg(ds.score) filter (where ds.score is not null), 1)::numeric(2,1) as avg_rating,
           coalesce(sum(ds.review_count), 0)::int                                   as review_count,
           count(ds.dish_id) filter (where ds.review_count > 0)::int                as dish_count
    from (
      select round(avg(r.score), 1)::numeric(2,1) as score, count(r.id)::int as review_count, d.id as dish_id
      from public.dishes d
      left join public.reviews r on r.dish_id = d.id
      where d.restaurant_id = rst.id and d.merged_into_dish_id is null
      group by d.id
    ) ds
  ) a
  cross join lateral (
    select count(distinct rp.reviewer_id)::int as people_count
    from public.reviews rp
    where rp.restaurant_id = rst.id
  ) p;

-- ===========================================================================
-- 2. Per-hit numbers for the Search reads.
-- ===========================================================================
-- [start, end) for a p_from/p_to calendar-day window in p_tz: in_window()'s rule as a range.
create or replace function public.window_bounds(p_from date, p_to date, p_tz text)
returns table (start_at timestamptz, end_at timestamptz)
language sql
stable
set search_path = public, extensions
as $$
  select (p_from::timestamp       at time zone coalesce(nullif(btrim(coalesce(p_tz, '')), ''), 'Australia/Melbourne')),
         ((p_to + 1)::timestamp   at time zone coalesce(nullif(btrim(coalesce(p_tz, '')), ''), 'Australia/Melbourne'));
$$;

-- A dish's numbers over the lines the viewer can see, optionally only those in [p_start, p_end).
-- NULL bounds = all time = dish_stats' score/review_count/scored_count/people_count.
create or replace function public.dish_numbers(p_dish_id uuid, p_start timestamptz, p_end timestamptz)
returns table (score numeric(2,1), review_count int, scored_count int, people_count int)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select round(avg(v.score), 1)::numeric(2,1), count(*)::int, count(v.score)::int, count(distinct v.reviewer_id)::int
  from public.reviews v
  where v.dish_id = p_dish_id
    and (p_start is null or v.created_at >= p_start)
    and (p_end   is null or v.created_at <  p_end);
$$;

-- A place's numbers, the restaurant_stats rule (mean of per-dish averages over live dishes; people
-- over every line there), optionally only over lines in [p_start, p_end).
create or replace function public.place_numbers(p_restaurant_id uuid, p_start timestamptz, p_end timestamptz)
returns table (avg_rating numeric(2,1), review_count int, people_count int, dish_count int)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with per_dish as (
    select round(avg(v.score), 1)::numeric(2,1) as score, count(*)::int as n
    from public.dishes d
    join public.reviews v on v.dish_id = d.id
    where d.restaurant_id = p_restaurant_id
      and d.merged_into_dish_id is null
      and (p_start is null or v.created_at >= p_start)
      and (p_end   is null or v.created_at <  p_end)
    group by d.id
  )
  select (select round(avg(pd.score) filter (where pd.score is not null), 1)::numeric(2,1) from per_dish pd),
         (select coalesce(sum(pd.n), 0)::int from per_dish pd),
         (select count(distinct v.reviewer_id)::int from public.reviews v
           where v.restaurant_id = p_restaurant_id
             and (p_start is null or v.created_at >= p_start)
             and (p_end   is null or v.created_at <  p_end)),
         (select count(*)::int from per_dish);
$$;

revoke all on function public.window_bounds(date, date, text) from public, anon;
revoke all on function public.dish_numbers(uuid, timestamptz, timestamptz) from public, anon;
revoke all on function public.place_numbers(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.window_bounds(date, date, text) to authenticated, service_role;
grant execute on function public.dish_numbers(uuid, timestamptz, timestamptz) to authenticated, service_role;
grant execute on function public.place_numbers(uuid, timestamptz, timestamptz) to authenticated, service_role;

-- ===========================================================================
-- 3. place_city_cache — each place's city, stored; place_cities reads it.
-- ===========================================================================
create table if not exists public.place_city_cache (
  restaurant_id uuid primary key references public.restaurants(id) on delete cascade,
  loc           text,          -- lower(btrim(place_locality(address, city)))
  geo           text,          -- city_at(location): the city whose radius holds the point
  city          text,          -- the resolved city (0046's rule), NULL = in no city
  via           text
);
create index if not exists place_city_cache_loc_idx  on public.place_city_cache (loc) where loc is not null;
create index if not exists place_city_cache_city_idx on public.place_city_cache (city) where city is not null;

alter table public.place_city_cache enable row level security;
drop policy if exists place_city_cache_select on public.place_city_cache;
create policy place_city_cache_select on public.place_city_cache for select to authenticated using (true);
revoke all on public.place_city_cache from anon, authenticated;
grant select on public.place_city_cache to authenticated;
grant all on public.place_city_cache to service_role;

comment on table public.place_city_cache is
  'Derived (0052): each place''s city under 0046''s rule, kept exact by triggers on restaurants and cities. Read through place_cities. Never written by clients.';

-- Resolve city/via for the rows given (by id) and for every row sharing one of the localities given —
-- 0046's order: location, else name/alias, else the city most located namesakes fall in.
create or replace function public.place_city_resolve(p_ids uuid[], p_locs text[])
returns void
language sql
security definer
set search_path = public, extensions
as $$
  update public.place_city_cache c
     set city = x.city, via = x.via
    from (
      select c2.restaurant_id,
             coalesce(c2.geo, a.id, b.city) as city,
             case when c2.geo is not null then 'location'
                  when a.id  is not null then 'name'
                  when b.city is not null then 'locality' end as via
      from public.place_city_cache c2
      left join lateral (
        select ci.id from public.cities ci
        where c2.loc is not null and (c2.loc = lower(ci.name) or c2.loc = any(ci.aliases))
        order by ci.id limit 1
      ) a on true
      left join lateral (
        select mode() within group (order by s.geo) as city
        from public.place_city_cache s
        where s.loc = c2.loc and s.geo is not null
      ) b on c2.loc is not null
      where c2.restaurant_id = any(coalesce(p_ids, '{}')) or c2.loc = any(coalesce(p_locs, '{}'))
    ) x
   where c.restaurant_id = x.restaurant_id
     and (c.city is distinct from x.city or c.via is distinct from x.via);
$$;

-- Recompute one place's own inputs (locality, point's city), then everything that depends on them.
create or replace function public.place_city_refresh(p_id uuid, p_old_loc text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_loc text;
begin
  insert into public.place_city_cache (restaurant_id, loc, geo)
  select r.id, lower(btrim(public.place_locality(r.address, r.city))), public.city_at(r.location)
  from public.restaurants r
  where r.id = p_id
  on conflict (restaurant_id) do update set loc = excluded.loc, geo = excluded.geo
  returning loc into v_loc;
  perform public.place_city_resolve(array[p_id], array_remove(array[v_loc, p_old_loc], null));
end;
$$;

-- Everything, from scratch (initial fill; a change to `cities`).
create or replace function public.place_city_rebuild()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  insert into public.place_city_cache (restaurant_id, loc, geo)
  select r.id, lower(btrim(public.place_locality(r.address, r.city))), public.city_at(r.location)
  from public.restaurants r
  on conflict (restaurant_id) do update set loc = excluded.loc, geo = excluded.geo;
  perform public.place_city_resolve(array(select restaurant_id from public.place_city_cache), null);
end;
$$;

create or replace function public.trg_place_city_restaurants()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_old_loc text;
begin
  if tg_op = 'DELETE' then
    -- its namesakes may lose their "locality" city: drop its row first (the FK cascade may not
    -- have run yet), then re-resolve them
    delete from public.place_city_cache where restaurant_id = old.id;
    perform public.place_city_resolve(null, array_remove(array[lower(btrim(public.place_locality(old.address, old.city)))], null));
    return old;
  end if;
  if tg_op = 'UPDATE' then
    v_old_loc := lower(btrim(public.place_locality(old.address, old.city)));
  end if;
  perform public.place_city_refresh(new.id, v_old_loc);
  return new;
end;
$$;

drop trigger if exists place_city_restaurants_aiu on public.restaurants;
create trigger place_city_restaurants_aiu
  after insert or update of location, address, city on public.restaurants
  for each row execute function public.trg_place_city_restaurants();
drop trigger if exists place_city_restaurants_ad on public.restaurants;
create trigger place_city_restaurants_ad
  after delete on public.restaurants
  for each row execute function public.trg_place_city_restaurants();

create or replace function public.trg_place_city_cities()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.place_city_rebuild();
  return null;
end;
$$;

drop trigger if exists place_city_cities_aiud on public.cities;
create trigger place_city_cities_aiud
  after insert or update or delete on public.cities
  for each statement execute function public.trg_place_city_cities();

revoke all on function public.place_city_resolve(uuid[], text[]) from public, anon, authenticated;
revoke all on function public.place_city_refresh(uuid, text) from public, anon, authenticated;
revoke all on function public.place_city_rebuild() from public, anon, authenticated;
revoke all on function public.trg_place_city_restaurants() from public, anon, authenticated;
revoke all on function public.trg_place_city_cities() from public, anon, authenticated;

select public.place_city_rebuild();

create or replace view public.place_cities with (security_invoker = true) as
  select c.restaurant_id, c.city, c.via
  from public.place_city_cache c
  where c.city is not null;

comment on view public.place_cities is
  'Round 5 (0046): each place''s city — by location (nearest containing centre), else its locality naming a city (name/aliases), else the city most located places with the same locality are in. `via` = location | name | locality. Places in no city are absent. Stored since 0052 (place_city_cache, trigger-maintained).';

-- ===========================================================================
-- 4. The Search reads — same signatures, numbers per hit, covers per page.
-- ===========================================================================
create or replace function public.search_places(
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
           (p_from is not null or p_to is not null) as windowed,
           case when p_from is not null then (select w.start_at from public.window_bounds(p_from, p_to, p_tz) w) end as start_at,
           case when p_to   is not null then (select w.end_at   from public.window_bounds(p_from, p_to, p_tz) w) end as end_at
  ),
  hits as (
    select r.id, r.name,
           nullif(btrim(coalesce(r.cuisine, '')), '')           as cuisine,
           public.place_locality(r.address, r.city)             as locality,
           public.search_tier(public.search_key(r.name), q.key) as match_tier
    from public.restaurants r
    cross join q
    where char_length(q.key) >= 2
      and public.search_key(r.name) like '%' || q.pat || '%'
      and (q.cuisines is null or lower(btrim(coalesce(r.cuisine, ''))) = any(q.cuisines))
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
  ),
  page as (
    select h.id, h.name, h.cuisine, h.locality, n.avg_rating, n.review_count, n.people_count, n.dish_count, h.match_tier
    from hits h
    cross join q
    cross join lateral public.place_numbers(h.id, q.start_at, q.end_at) n
    where (not q.windowed or n.review_count > 0)
      and public.score_in_range(n.avg_rating, p_min_score, p_max_score)
      and (q.tags is null or public.place_has_tagged_dish(h.id, q.tags))
      and (p_cursor_id is null
           or (h.match_tier, -n.review_count, h.name, h.id)
              > (coalesce(p_cursor_match_tier, 0), -coalesce(p_cursor_review_count, 0),
                 coalesce(p_cursor_name, ''), p_cursor_id))
    order by h.match_tier, n.review_count desc, h.name, h.id
    limit (select lim from q)
  )
  select p.id, p.name, p.cuisine, p.locality, p.avg_rating, p.review_count, p.people_count, p.dish_count,
         nullif(btrim(coalesce(public.restaurant_cover_url(p.id), '')), ''), p.match_tier
  from page p
  order by p.match_tier, p.review_count desc, p.name, p.id;
$$;

create or replace function public.search_dishes(
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
           case when p_from is not null then (select w.start_at from public.window_bounds(p_from, p_to, p_tz) w) end as start_at,
           case when p_to   is not null then (select w.end_at   from public.window_bounds(p_from, p_to, p_tz) w) end as end_at
  ),
  hits as (
    select d.id as dish_id, d.name as dish_name, r.id as restaurant_id, r.name as restaurant_name,
           public.place_locality(r.address, r.city)             as restaurant_locality,
           public.search_tier(public.search_key(d.name), q.key) as match_tier
    from public.dishes d
    join public.restaurants r on r.id = d.restaurant_id
    cross join q
    where char_length(q.key) >= 2
      and d.merged_into_dish_id is null
      and public.search_key(d.name) like '%' || q.pat || '%'
      and (q.cuisines is null or lower(btrim(coalesce(r.cuisine, ''))) = any(q.cuisines))
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
  ),
  page as (
    select h.dish_id, h.dish_name, h.restaurant_id, h.restaurant_name, h.restaurant_locality,
           n.score, n.review_count, n.scored_count, n.people_count, h.match_tier
    from hits h
    cross join q
    cross join lateral public.dish_numbers(h.dish_id, q.start_at, q.end_at) n
    where n.review_count > 0
      and public.score_in_range(n.score, p_min_score, p_max_score)
      and (q.tags is null or public.dish_consensus_tags(h.dish_id) @> q.tags)
      and (p_cursor_dish_id is null
           or (h.match_tier, -n.review_count, h.dish_name, h.dish_id)
              > (coalesce(p_cursor_match_tier, 0), -coalesce(p_cursor_review_count, 0),
                 coalesce(p_cursor_dish_name, ''), p_cursor_dish_id))
    order by h.match_tier, n.review_count desc, h.dish_name, h.dish_id
    limit (select lim from q)
  )
  select p.dish_id, p.dish_name, p.restaurant_id, p.restaurant_name, p.restaurant_locality,
         p.score, p.review_count, p.scored_count, p.people_count,
         nullif(btrim(coalesce(public.dish_cover_url(p.dish_id), '')), ''), p.match_tier,
         public.dish_consensus_tags(p.dish_id)
  from page p
  order by p.match_tier, p.review_count desc, p.dish_name, p.dish_id;
$$;

create or replace function public.nearby_places(
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
           (p_from is not null or p_to is not null) as windowed,
           case when p_from is not null then (select w.start_at from public.window_bounds(p_from, p_to, p_tz) w) end as start_at,
           case when p_to   is not null then (select w.end_at   from public.window_bounds(p_from, p_to, p_tz) w) end as end_at
  ),
  hits as (
    select r.id, r.name,
           nullif(btrim(coalesce(r.cuisine, '')), '')    as cuisine,
           public.place_locality(r.address, r.city)      as locality,
           extensions.ST_Distance(r.location, o.g)       as distance_m
    from public.restaurants r
    cross join origin o
    where r.location is not null
      and extensions.ST_DWithin(r.location, o.g, o.radius)
      and (o.cuisines is null or lower(btrim(coalesce(r.cuisine, ''))) = any(o.cuisines))
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
  ),
  page as (
    select h.id, h.name, h.cuisine, h.locality, n.avg_rating, n.review_count, n.people_count, n.dish_count, h.distance_m
    from hits h
    cross join origin o
    cross join lateral public.place_numbers(h.id, o.start_at, o.end_at) n
    where (not o.windowed or n.review_count > 0)
      and public.score_in_range(n.avg_rating, p_min_score, p_max_score)
      and (o.tags is null or public.place_has_tagged_dish(h.id, o.tags))
      and (p_cursor_id is null
           or (h.distance_m, h.id) > (coalesce(p_cursor_distance_m, -1), p_cursor_id))
    order by h.distance_m, h.id
    limit (select lim from origin)
  )
  select p.id, p.name, p.cuisine, p.locality, p.avg_rating, p.review_count, p.people_count, p.dish_count,
         nullif(btrim(coalesce(public.restaurant_cover_url(p.id), '')), ''), p.distance_m
  from page p
  order by p.distance_m, p.id;
$$;

create or replace function public.search_saved(
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
           least(greatest(coalesce(p_limit, 20), 1), 50) as lim,
           case when p_from is not null then (select w.start_at from public.window_bounds(p_from, p_to, p_tz) w) end as start_at,
           case when p_to   is not null then (select w.end_at   from public.window_bounds(p_from, p_to, p_tz) w) end as end_at
  ),
  page as (
    select s.dish_id, d.name as dish_name, r.id as restaurant_id, r.name as restaurant_name,
           nullif(btrim(coalesce(r.city, '')), '')  as restaurant_city,
           public.place_locality(r.address, r.city) as restaurant_locality,
           n.score                                  as dish_score,
           (d.merged_into_dish_id is null)          as live,
           s.source_entry_id, s.source_user_id, s.created_at as saved_at
    from public.saves s
    join public.dishes d      on d.id = s.dish_id
    join public.restaurants r on r.id = d.restaurant_id
    cross join q
    -- dish_stats' numbers: a merged-away dish has none (the view lists live dishes only)
    left join lateral (
      select dn.score from public.dish_numbers(s.dish_id, null, null) dn where d.merged_into_dish_id is null
    ) n on true
    where s.user_id = (select auth.uid())
      and (
        q.key = ''
        or public.search_key(d.name) like '%' || q.pat || '%'
        or public.search_key(r.name) like '%' || q.pat || '%'
      )
      and public.score_in_range(n.score, p_min_score, p_max_score)
      and (nullif(btrim(coalesce(p_city, '')), '') is null
           or r.id in (select pc.restaurant_id from public.place_cities pc where pc.city = lower(btrim(p_city))))
      and (q.start_at is null or s.created_at >= q.start_at)
      and (q.end_at   is null or s.created_at <  q.end_at)
      and (p_cursor_dish_id is null or (s.created_at, s.dish_id) < (p_cursor_saved_at, p_cursor_dish_id))
    order by s.created_at desc, s.dish_id desc
    limit (select lim from q)
  ),
  covered as (
    select p.*, case when p.live then nullif(btrim(coalesce(public.dish_cover_url(p.dish_id), '')), '') end as cover
    from page p
  )
  select c.dish_id, c.dish_name, c.restaurant_id, c.restaurant_name, c.restaurant_city, c.restaurant_locality,
         c.dish_score, c.cover, c.source_entry_id, c.source_user_id, sp.username, c.saved_at, c.cover
  from covered c
  left join public.profiles sp on sp.id = c.source_user_id
  order by c.saved_at desc, c.dish_id desc;
$$;

-- ===========================================================================
-- 5. search_all — the composer's place sheet. Same body as 0031 plus a final `id` key on each kind's
--    ORDER BY: similarity + name was not a total order, so which of two tied rows made the LIMIT was
--    up to the plan. Now it is fixed. Same signature: create or replace, grants survive.
-- ===========================================================================
create or replace function public.search_all(p_query text, p_limit_per_kind int default 10)
returns table (
  kind       text,
  id         uuid,
  title      text,
  subtitle   text,
  score      numeric(2,1),
  match_rank real,
  detail     jsonb
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with q as (
    select public.search_key(p_query)     as key,
           public.search_pattern(p_query) as pat,
           least(greatest(p_limit_per_kind, 1), 25) as lim
  ),
  place_hits as (
    select 'place'::text as kind, r.id, r.name as title,
           coalesce(nullif(btrim(coalesce(r.cuisine, '')), ''),
                    public.place_locality(r.address, r.city)) as subtitle,
           rs.avg_rating as score,
           similarity(public.search_key(r.name), q.key)::real as match_rank,
           jsonb_build_object('city', r.city, 'cuisine', r.cuisine, 'address', r.address,
                              'locality', public.place_locality(r.address, r.city),
                              'people_count', coalesce(rs.people_count, 0)) as detail
    from public.restaurants r
    left join public.restaurant_stats rs on rs.restaurant_id = r.id
    cross join q
    where char_length(q.key) >= 2
      and public.search_key(r.name) like '%' || q.pat || '%'
    order by similarity(public.search_key(r.name), q.key) desc, r.name, r.id
    limit (select lim from q)
  ),
  dish_hits as (
    select 'dish'::text as kind, d.id, d.name as title, r.name as subtitle,
           ds.score,
           similarity(public.search_key(d.name), q.key)::real as match_rank,
           jsonb_build_object('restaurant_id', r.id, 'restaurant_city', r.city,
                              'restaurant_locality', public.place_locality(r.address, r.city),
                              'people_count', coalesce(ds.people_count, 0),
                              'cover_url', ds.cover_url) as detail
    from public.dishes d
    join public.restaurants r on r.id = d.restaurant_id
    left join public.dish_stats ds on ds.dish_id = d.id
    cross join q
    where char_length(q.key) >= 2
      and d.merged_into_dish_id is null
      and public.search_key(d.name) like '%' || q.pat || '%'
    order by similarity(public.search_key(d.name), q.key) desc, d.name, d.id
    limit (select lim from q)
  ),
  people_hits as (
    select 'person'::text as kind, p.id, p.username::text as title, p.name as subtitle,
           null::numeric(2,1) as score,
           greatest(similarity(public.search_key(p.username::text), q.key),
                    similarity(public.search_key(p.name), q.key))::real as match_rank,
           jsonb_build_object('avatar_url', p.avatar_url, 'city', p.city) as detail
    from public.profiles p
    cross join q
    where char_length(q.key) >= 2
      and p.deleted_at is null
      and (public.search_key(p.username::text) like '%' || q.pat || '%'
           or public.search_key(p.name)        like '%' || q.pat || '%')
    order by greatest(similarity(public.search_key(p.username::text), q.key),
                      similarity(public.search_key(p.name), q.key)) desc, p.username, p.id
    limit (select lim from q)
  )
  select * from place_hits
  union all select * from dish_hits
  union all select * from people_hits;
$$;

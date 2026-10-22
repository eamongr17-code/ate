-- 0080_suggestions_nearby.sql
-- Ate backend — dish suggestions come from around you, never from the other side of the world.
--
-- Bug (22 Oct, Eamon): in Melbourne, "Similar dishes" and a tag chip's page suggested chicken dishes
-- from Thailand. "Never suggest dishes that are not from the country you are currently in … only
-- recommend things within a logical radius." Both reads ranked every dish in the catalogue.
--
-- The rule, one place: public.suggestion_area(p_lat, p_lng, p_dish_id) names the AREA, and
-- public.in_suggestion_area(...) holds a place to it.
--   centre — in order: the phone's point (the app sends it when it has a fix); else the dish's own
--            place (similar_dishes); else where the caller last ate (their newest entry at a located
--            place). None of these → no area: the read is everywhere, as before (a new person with
--            location off has nothing else to go on).
--   area   — places within suggestion_radius_m() (25 km: a metro's inner and middle ring) of the
--            centre. A place with no coordinates (hand-added) counts when its city (place_city_cache)
--            is the centre's city.
--   The point is used for this answer and nothing else: never stored (0046's rule for resolve_city).
--
-- Reads:
--   similar_dishes(p_dish_id, p_limit, p_lat, p_lng) — always in the area.
--   dishes_by_tag(…, p_city, p_lat, p_lng)            — p_city given: that city, as before (the Feed
--     already scopes itself). A suburb or city chip is already a place: as before. Otherwise in the
--     area.
--
-- Volume: the area test is one ST_DWithin per candidate place against restaurants_location_gix's
-- column (geography, so the distance is metres), after the tag-link index has narrowed the
-- candidates; the centre is computed once per call. No new table, no new index.
--
-- WIRE IMPACT: ADDITIVE. Two trailing optional params on each read (DROP + CREATE: landmine 7,
-- re-granted). The old named calls bind unchanged; without a point they still answer, now in the
-- dish's / the caller's area.

set search_path = public, extensions;

create or replace function public.suggestion_radius_m()
returns int
language sql
immutable
as $$ select 25000 $$;

comment on function public.suggestion_radius_m() is
  '0080: how far from the centre a suggested dish''s place may be (metres).';

create or replace function public.suggestion_area(
  p_lat     double precision,
  p_lng     double precision,
  p_dish_id uuid default null
)
returns table (center geography, city text)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
declare
  v_center geography;
  v_city   text;
begin
  if p_lat is not null and p_lng is not null
     and p_lat between -90 and 90 and p_lng between -180 and 180 then
    v_center := extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::geography;
  elsif p_dish_id is not null then
    select r.location, pc.city into v_center, v_city
    from public.dishes d
    join public.restaurants r on r.id = d.restaurant_id
    left join public.place_city_cache pc on pc.restaurant_id = r.id
    where d.id = p_dish_id;
  end if;
  if v_center is null and v_city is null then
    select r.location into v_center
    from public.entries e
    join public.restaurants r on r.id = e.restaurant_id
    where e.author_id = auth.uid() and r.location is not null
    order by e.created_at desc
    limit 1;
  end if;
  return query select v_center, coalesce(public.city_at(v_center), v_city);
end;
$$;

comment on function public.suggestion_area(double precision, double precision, uuid) is
  '0080: the area dish suggestions come from — centre = the phone''s point, else the dish''s place, else the caller''s newest located entry; city = the centre''s city (or the dish''s place''s, for a hand-added place). No row values when nothing is known.';

create or replace function public.in_suggestion_area(
  p_location    geography,
  p_place_city  text,
  p_center      geography,
  p_center_city text
)
returns boolean
language sql
immutable
set search_path = public, extensions
as $$
  select case
    when p_center is null and p_center_city is null then true
    when p_location is not null and p_center is not null
      then extensions.ST_DWithin(p_location, p_center, public.suggestion_radius_m())
    else p_place_city is not null and p_place_city = p_center_city
  end;
$$;

comment on function public.in_suggestion_area(geography, text, geography, text) is
  '0080: a place is in the area when it is within suggestion_radius_m() of the centre, or — without coordinates on either side — in the same city. No area at all → every place.';

-- ===========================================================================
-- 1. similar_dishes — 0053's body, held to the area.
-- ===========================================================================
drop function if exists public.similar_dishes(uuid, int);

create function public.similar_dishes(
  p_dish_id uuid,
  p_limit   int              default 10,
  p_lat     double precision default null,
  p_lng     double precision default null
)
returns table (
  dish_id         uuid,
  name            text,
  restaurant_id   uuid,
  restaurant_name text,
  score           numeric(2,1),
  review_count    int,
  cover_url       text
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_lim    int := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_center geography;
  v_city   text;
begin
  if auth.uid() is null then
    raise exception 'signed-in callers only' using errcode = '42501';
  end if;
  select a.center, a.city into v_center, v_city from public.suggestion_area(p_lat, p_lng, p_dish_id) a;
  return query
  with me as (
    select t.kind, t.slug from public.dish_tag_links t where t.dish_id = p_dish_id
  ),
  -- similar = shares a style or the cuisine, at a place in the area; then every shared tag weighs in
  cand as (
    select distinct t.dish_id
    from public.dish_tag_links t
    join me on me.kind = t.kind and me.slug = t.slug
    join public.dishes d on d.id = t.dish_id
    join public.restaurants r on r.id = d.restaurant_id
    left join public.place_city_cache pc on pc.restaurant_id = r.id
    where t.kind in ('style', 'cuisine') and t.dish_id <> p_dish_id
      and public.in_suggestion_area(r.location, pc.city, v_center, v_city)
  ),
  weighed as (
    select c.dish_id,
           sum(case t.kind when 'style' then 8 when 'cuisine' then 4 when 'suburb' then 2 else 1 end)::int as weight
    from cand c
    join public.dish_tag_links t on t.dish_id = c.dish_id
    join me on me.kind = t.kind and me.slug = t.slug
    group by c.dish_id
  ),
  numbered as (
    select w.dish_id, w.weight,
           round(avg(v.score), 1)::numeric(2,1) as score,
           count(*)::int as review_count
    from weighed w
    join public.reviews v on v.dish_id = w.dish_id
    group by w.dish_id, w.weight
  ),
  page as (
    select n.dish_id, d.name, d.restaurant_id, r.name as restaurant_name, n.score, n.review_count, n.weight
    from numbered n
    join public.dishes d on d.id = n.dish_id and d.merged_into_dish_id is null
    join public.restaurants r on r.id = d.restaurant_id
    order by n.weight desc, coalesce(n.score, -1) desc, n.review_count desc, lower(d.name), n.dish_id
    limit v_lim
  )
  select p.dish_id, p.name, p.restaurant_id, p.restaurant_name, p.score, p.review_count,
         public.dish_cover_url(p.dish_id)
  from page p
  order by p.weight desc, coalesce(p.score, -1) desc, p.review_count desc, lower(p.name), p.dish_id;
end;
$$;

comment on function public.similar_dishes(uuid, int, double precision, double precision) is
  'Round 7 (0053), area 0080: dishes like this one — sharing a style or the cuisine — at places in the suggestion area (suggestion_area: the phone''s point p_lat/p_lng, else the dish''s place, else the caller''s last located entry; 25 km), ranked by weighted tag overlap (style 8, cuisine 4, suburb 2, city 1), then printed score (unscored last), review_count, name, id. Excludes the dish itself, merged and never-logged dishes. p_limit default 10, max 50. Unpaged.';

-- ===========================================================================
-- 2. dishes_by_tag — 0074's body; with no city, held to the area.
-- ===========================================================================
drop function if exists public.dishes_by_tag(text, text, int, numeric, int, text, uuid, text);

create function public.dishes_by_tag(
  p_kind                text,
  p_slug                text,
  p_limit               int              default 30,
  p_cursor_score        numeric          default null,
  p_cursor_review_count int              default null,
  p_cursor_name         text             default null,
  p_cursor_dish_id      uuid             default null,
  p_city                text             default null,
  p_lat                 double precision default null,
  p_lng                 double precision default null
)
returns table (
  dish_id         uuid,
  name            text,
  restaurant_id   uuid,
  restaurant_name text,
  score           numeric(2,1),
  review_count    int,
  cover_url       text,
  saved           boolean
)
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_uid    uuid   := auth.uid();
  v_kind   text   := lower(btrim(coalesce(p_kind, '')));
  v_slug   text   := lower(btrim(coalesce(p_slug, '')));
  v_lim    int    := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_places uuid[];
  v_center geography;
  v_city   text;
begin
  if v_uid is null then
    raise exception 'signed-in callers only' using errcode = '42501';
  end if;
  if v_kind not in ('style', 'cuisine', 'suburb', 'city', 'diet') then
    raise exception 'p_kind must be style, cuisine, suburb, city or diet (got %)', p_kind using errcode = '22023';
  end if;
  v_places := public.city_places(p_city);
  -- A city (the Feed's) or a place chip already says where; anything else is the caller's area.
  if p_city is null and v_kind not in ('suburb', 'city') then
    select a.center, a.city into v_center, v_city from public.suggestion_area(p_lat, p_lng, null) a;
  end if;

  return query
  with cand as (
    select t.dish_id from public.dish_tag_links t
    where v_kind <> 'diet' and t.kind = v_kind and t.slug = v_slug
    union
    -- diet: any dish with a line carrying the code (0074: or one that counts as it), kept below
    -- only if labelled
    select v.dish_id from public.reviews v
    where v_kind = 'diet' and v.tags && public.diet_codes_counting_as(v_slug)
  ),
  placed as (
    select c.dish_id, d.name, d.restaurant_id
    from cand c
    join public.dishes d on d.id = c.dish_id and d.merged_into_dish_id is null
    join public.restaurants r on r.id = d.restaurant_id
    left join public.place_city_cache pc on pc.restaurant_id = r.id
    where (v_places is null or d.restaurant_id = any(v_places))
      and public.in_suggestion_area(r.location, pc.city, v_center, v_city)
  ),
  numbered as (
    select c.dish_id, c.name, c.restaurant_id,
           round(avg(v.score), 1)::numeric(2,1) as score,
           count(*)::int as review_count
    from placed c
    join public.reviews v on v.dish_id = c.dish_id
    group by c.dish_id, c.name, c.restaurant_id
  ),
  page as (
    select n.dish_id, n.name, n.restaurant_id, r.name as restaurant_name, n.score, n.review_count
    from numbered n
    join public.restaurants r on r.id = n.restaurant_id
    where (v_kind <> 'diet' or v_slug = any(public.dish_consensus_tags(n.dish_id)))
      and (
        p_cursor_dish_id is null
        or coalesce(n.score, -1) < coalesce(p_cursor_score, -1)
        or (coalesce(n.score, -1) = coalesce(p_cursor_score, -1)
            and n.review_count < p_cursor_review_count)
        or (coalesce(n.score, -1) = coalesce(p_cursor_score, -1)
            and n.review_count = p_cursor_review_count
            and (lower(n.name), n.dish_id) > (lower(coalesce(p_cursor_name, '')), p_cursor_dish_id))
      )
    order by coalesce(n.score, -1) desc, n.review_count desc, lower(n.name), n.dish_id
    limit v_lim
  )
  select p.dish_id, p.name, p.restaurant_id, p.restaurant_name, p.score, p.review_count,
         public.dish_cover_url(p.dish_id),
         exists (select 1 from public.saves s where s.user_id = v_uid and s.dish_id = p.dish_id)
  from page p
  order by coalesce(p.score, -1) desc, p.review_count desc, lower(p.name), p.dish_id;
end;
$$;

comment on function public.dishes_by_tag(text, text, int, numeric, int, text, uuid, text, double precision, double precision) is
  'Round 7 (0053), city + saved 0055, area 0080: a tag chip''s results — every live, logged dish carrying (p_kind, p_slug) from dish_tags (diet: the consensus rule, live), best first: printed score desc (a 6 above every 5, unscored last), review_count desc, lower(name), dish_id. Keyset: pass the last row''s score, review_count, name, dish_id (score may be null). p_city (0055): only dishes whose place is in that city (unknown → []). With no p_city, and a kind other than suburb/city: only places in the suggestion area (suggestion_area: p_lat/p_lng, else the caller''s last located entry; 25 km; nothing known = everywhere). saved = the viewer''s save. p_limit default 30, max 100. Unknown slug → []; unknown kind → 22023.';

-- ===========================================================================
-- 3. Grants — explicit (new functions get no automatic API grants).
-- ===========================================================================
revoke all on function public.suggestion_radius_m()                                                   from public, anon;
revoke all on function public.suggestion_area(double precision, double precision, uuid)               from public, anon;
revoke all on function public.in_suggestion_area(geography, text, geography, text)                     from public, anon;
revoke all on function public.similar_dishes(uuid, int, double precision, double precision)           from public, anon;
revoke all on function public.dishes_by_tag(text, text, int, numeric, int, text, uuid, text, double precision, double precision) from public, anon;

grant execute on function public.suggestion_radius_m()                                                 to authenticated, service_role;
grant execute on function public.suggestion_area(double precision, double precision, uuid)             to authenticated, service_role;
grant execute on function public.in_suggestion_area(geography, text, geography, text)                   to authenticated, service_role;
grant execute on function public.similar_dishes(uuid, int, double precision, double precision)         to authenticated, service_role;
grant execute on function public.dishes_by_tag(text, text, int, numeric, int, text, uuid, text, double precision, double precision) to authenticated, service_role;

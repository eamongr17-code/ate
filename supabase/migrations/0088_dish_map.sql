-- 0088_dish_map.sql
-- THE DISH MAP (25 Oct, Eamon approved design/rebuild/nearby-map.html, option A): a map button on the
-- Feed opens a map of the dishes around you. Two reads, both over the same set of places so the pins
-- and the sheet under them always agree:
--
--   map_places(box | point, …) — the PINS. Every place in the visible box that has a dish anyone can
--       see, nearest the centre first, capped at p_limit (≤ 200). Each row carries its best dish (the
--       pin's score and photo) and the next dish with a photo (the one photo stacked behind it, two at
--       most). With no box it answers the p_limit places nearest the point, however far: that is how
--       the map opens framed on you and the nearest 10, so it is never empty. With no point either
--       (location off) it answers those around the place most written about.
--   map_dishes(box, …)          — the SHEET, "Dishes near you": every dish at those places, best
--       first, keyset-paged. A chain's dish (one menu, 0085) is listed once, at its nearest location.
--
-- Numbers are dish_stats' own (avg score to 1 dp over the reviews the viewer can see; RLS, security
-- invoker), so a pin says what the place page says. A dish nobody scored has no score (rule: scores
-- never inferred) and sorts after the scored ones.
--
-- Volume: the box test is `location && envelope` on restaurants_location_gix (geography gist) and the
-- order is the index's own KNN (`<->`), so a call reads at most p_limit places however big the box. The
-- "has a dish" test is reviews_restaurant_idx. Per place, the lateral reads only that menu's dishes.
-- At the beta's ~50 people this is a few hundred small reads a day; the map itself is Apple's (free).
--
-- Signed-in only (the Feed is): anon is refused. WIRE IMPACT: ADDITIVE (two new functions).

set search_path = public, extensions;

-- The places a map read covers: in the box (when one is given), with a visible dish, nearest the
-- centre first. One definition so the pins and the sheet can never disagree about what is in view.
create or replace function public.map_candidates(
  p_min_lat double precision, p_min_lng double precision,
  p_max_lat double precision, p_max_lng double precision,
  p_lat double precision, p_lng double precision,
  p_limit integer
)
returns table (restaurant_id uuid, menu_id uuid, distance_m double precision, centre_m double precision)
language plpgsql stable set search_path = public, extensions as $$
declare
  v_box    geography;
  v_centre geography;
  v_me     geography;
begin
  if p_min_lat is not null and p_min_lng is not null and p_max_lat is not null and p_max_lng is not null then
    if p_min_lat > p_max_lat or p_min_lat < -90 or p_max_lat > 90
       or p_min_lng < -180 or p_max_lng > 180 or p_min_lng > p_max_lng then
      raise exception 'bad_box' using errcode = '22023';
    end if;
    v_box := ST_MakeEnvelope(p_min_lng, p_min_lat, p_max_lng, p_max_lat, 4326)::geography;
  end if;
  if p_lat is not null and p_lng is not null and p_lat between -90 and 90 and p_lng between -180 and 180 then
    v_me := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  end if;
  v_centre := coalesce(
    case when v_box is not null
      then ST_SetSRID(ST_MakePoint((p_min_lng + p_max_lng) / 2, (p_min_lat + p_max_lat) / 2), 4326)::geography end,
    v_me);
  if v_centre is null then
    -- No box and no point (location off): around the place most written about, so the map opens on
    -- the busiest part of the record. One grouped read of reviews_restaurant_idx; only this opening.
    select r.location into v_centre
    from public.reviews v
    join public.restaurants r on r.id = v.restaurant_id and r.location is not null
    group by r.id, r.location
    order by count(*) desc, r.id
    limit 1;
  end if;
  if v_centre is null then
    return;                                   -- nothing anywhere has a place on the map
  end if;

  return query
  select r.id, public.place_menu(r.id),
         case when v_me is null then null else ST_Distance(r.location, v_me) end,
         r.location <-> v_centre
  from public.restaurants r
  where r.location is not null
    and (v_box is null or r.location && v_box)
    and exists (
      select 1 from public.reviews v
      join public.dishes d on d.id = v.dish_id and d.merged_into_dish_id is null
      where v.restaurant_id = public.place_menu(r.id))
  order by r.location <-> v_centre, r.id
  limit least(greatest(coalesce(p_limit, 150), 1), 200);
end;
$$;
comment on function public.map_candidates(double precision, double precision, double precision, double precision, double precision, double precision, integer) is
  '0088: the places a map read covers — in the box (if given), with a visible dish, nearest the centre first, ≤ 200.';

-- One menu's dishes with their numbers, best first (place_dishes' order since 0051).
create or replace function public.map_menu(p_menu_id uuid)
returns table (dish_id uuid, dish_name text, score numeric, review_count integer, rank integer)
language sql stable set search_path = public, extensions as $$
  select d.id, d.name, a.score, a.n,
         (row_number() over (order by coalesce(a.score, -1) desc, a.n desc, lower(d.name), d.id))::int
  from public.dishes d
  cross join lateral (
    select round(avg(v.score), 1)::numeric(2,1) as score, count(v.id)::int as n
    from public.reviews v where v.dish_id = d.id
  ) a
  where d.restaurant_id = p_menu_id and d.merged_into_dish_id is null and a.n > 0;
$$;
comment on function public.map_menu(uuid) is '0088: a menu''s visible dishes and numbers, best first.';

create or replace function public.map_places(
  p_min_lat double precision default null, p_min_lng double precision default null,
  p_max_lat double precision default null, p_max_lng double precision default null,
  p_lat double precision default null, p_lng double precision default null,
  p_limit integer default 150
)
returns table (
  restaurant_id uuid, name text, locality text,
  latitude double precision, longitude double precision, distance_m integer,
  dish_count integer,
  top_dish_id uuid, top_dish_name text, top_score numeric, top_cover_url text,
  second_cover_url text
)
language plpgsql stable set search_path = public, extensions as $$
#variable_conflict use_column
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  return query
  select c.restaurant_id, r.name, public.place_locality(r.address, r.city),
         ST_Y(r.location::geometry), ST_X(r.location::geometry),
         round(c.distance_m)::int,
         m.dish_count, m.top_id, m.top_name, m.top_score,
         public.dish_cover_url(m.top_id),
         s.cover
  from public.map_candidates(p_min_lat, p_min_lng, p_max_lat, p_max_lng, p_lat, p_lng, p_limit) c
  join public.restaurants r on r.id = c.restaurant_id
  cross join lateral (
    select count(*)::int as dish_count,
           (array_agg(x.dish_id order by x.rank))[1]   as top_id,
           (array_agg(x.dish_name order by x.rank))[1] as top_name,
           (array_agg(x.score order by x.rank))[1]     as top_score
    from public.map_menu(c.menu_id) x
  ) m
  -- The one photo stacked behind: the best other dish that has one.
  left join lateral (
    select cu.cover
    from public.map_menu(c.menu_id) x
    cross join lateral (select public.dish_cover_url(x.dish_id) as cover) cu
    where x.dish_id <> m.top_id and cu.cover is not null
    order by x.rank
    limit 1
  ) s on true
  where m.top_id is not null
  order by c.centre_m, c.restaurant_id;
end;
$$;
comment on function public.map_places(double precision, double precision, double precision, double precision, double precision, double precision, integer) is
  '0088: the dish map''s pins — places in the box (or nearest the point), each with its best dish and one more photo.';

create or replace function public.map_dishes(
  p_min_lat double precision, p_min_lng double precision,
  p_max_lat double precision, p_max_lng double precision,
  p_lat double precision default null, p_lng double precision default null,
  p_limit integer default 20,
  p_cursor_score numeric default null,
  p_cursor_review_count integer default null,
  p_cursor_dish_id uuid default null
)
returns table (
  dish_id uuid, dish_name text, score numeric, review_count integer, cover_url text,
  restaurant_id uuid, place_name text, locality text, distance_m integer
)
language plpgsql stable set search_path = public, extensions as $$
#variable_conflict use_column
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  return query
  select pg.dish_id, pg.dish_name, pg.score, pg.review_count, public.dish_cover_url(pg.dish_id),
         pg.restaurant_id, r.name, public.place_locality(r.address, r.city), round(pg.distance_m)::int
  from (
    select one.*
    from (
      -- A chain's dish sits on every location's menu: keep the nearest location in view.
      select distinct on (x.dish_id)
             x.dish_id, x.dish_name, x.score, x.review_count, c.restaurant_id, c.distance_m, c.centre_m
      from public.map_candidates(p_min_lat, p_min_lng, p_max_lat, p_max_lng, p_lat, p_lng, 200) c
      cross join lateral public.map_menu(c.menu_id) x
      order by x.dish_id, c.centre_m, c.restaurant_id
    ) one
    where p_cursor_dish_id is null
       or coalesce(one.score, -1) < coalesce(p_cursor_score, -1)
       or (coalesce(one.score, -1) = coalesce(p_cursor_score, -1) and one.review_count < p_cursor_review_count)
       or (coalesce(one.score, -1) = coalesce(p_cursor_score, -1) and one.review_count = p_cursor_review_count
           and one.dish_id > p_cursor_dish_id)
    order by coalesce(one.score, -1) desc, one.review_count desc, one.dish_id
    limit least(greatest(coalesce(p_limit, 20), 1), 50)
  ) pg
  join public.restaurants r on r.id = pg.restaurant_id
  order by coalesce(pg.score, -1) desc, pg.review_count desc, pg.dish_id;
end;
$$;
comment on function public.map_dishes(double precision, double precision, double precision, double precision, double precision, double precision, integer, numeric, integer, uuid) is
  '0088: the dish map''s sheet — every dish at the places in view, best first, keyset (score, review_count, dish_id).';

revoke all on function public.map_candidates(double precision, double precision, double precision, double precision, double precision, double precision, integer) from public, anon;
revoke all on function public.map_menu(uuid) from public, anon;
revoke all on function public.map_places(double precision, double precision, double precision, double precision, double precision, double precision, integer) from public, anon;
revoke all on function public.map_dishes(double precision, double precision, double precision, double precision, double precision, double precision, integer, numeric, integer, uuid) from public, anon;
grant execute on function public.map_candidates(double precision, double precision, double precision, double precision, double precision, double precision, integer) to authenticated, service_role;
grant execute on function public.map_menu(uuid) to authenticated, service_role;
grant execute on function public.map_places(double precision, double precision, double precision, double precision, double precision, double precision, integer) to authenticated, service_role;
grant execute on function public.map_dishes(double precision, double precision, double precision, double precision, double precision, double precision, integer, numeric, integer, uuid) to authenticated, service_role;

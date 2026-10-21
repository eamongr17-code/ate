-- 0076_place_city_resolve_scale.sql
-- Ate backend — adding a place stops getting slower with every place in its suburb.
--
-- Found by the load test (supabase/tests/load): place_city_resolve (0052) recomputes every place that
-- shares the new place's locality, and for EACH of them recounted the locality's most common city
-- over all of its namesakes — N places in a suburb cost N² row reads per insert. At 750 places in a
-- suburb one restaurants insert took 1.7 s, and places-search upserts up to 10 at a time, which runs
-- into the API's statement timeout once a suburb like the CBD fills up.
--
-- Now the most common city is counted ONCE per locality (a grouped CTE) and the "by id OR by
-- locality" filter is two index lookups instead of a scan. Same rule, same rows, same result: the
-- mode is taken over the same set in the same order. Same signature: create or replace.

create or replace function public.place_city_resolve(p_ids uuid[], p_locs text[])
returns void
language sql
security definer
set search_path = public, extensions
as $$
  with t as (
    select c2.restaurant_id, c2.loc, c2.geo
    from public.place_city_cache c2
    where c2.restaurant_id = any(coalesce(p_ids, '{}'))
    union
    select c2.restaurant_id, c2.loc, c2.geo
    from public.place_city_cache c2
    where c2.loc = any(coalesce(p_locs, '{}'))
  ),
  m as (
    select s.loc, mode() within group (order by s.geo) as city
    from public.place_city_cache s
    where s.geo is not null
      and s.loc in (select t.loc from t where t.loc is not null)
    group by s.loc
  )
  update public.place_city_cache c
     set city = x.city, via = x.via
    from (
      select t.restaurant_id,
             coalesce(t.geo, a.id, m.city) as city,
             case when t.geo is not null then 'location'
                  when a.id  is not null then 'name'
                  when m.city is not null then 'locality' end as via
      from t
      left join lateral (
        select ci.id from public.cities ci
        where t.loc is not null and (t.loc = lower(ci.name) or t.loc = any(ci.aliases))
        order by ci.id limit 1
      ) a on true
      left join m on m.loc = t.loc
    ) x
   where c.restaurant_id = x.restaurant_id
     and (c.city is distinct from x.city or c.via is distinct from x.via);
$$;

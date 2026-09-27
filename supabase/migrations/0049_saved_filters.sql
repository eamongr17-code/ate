-- 0049_saved_filters.sql
-- Ate backend — round 5: the SAVED shelf shares the Journal's filters. `search_saved` (0031) — the
-- shelf's own columns and keyset, where an empty query is the whole list — gains 0047's score range
-- and city. A filtered shelf is `search_saved(p_query => null, filters…)`; the unfiltered shelf can
-- keep reading `my_saved_dishes` (same rows, same order).
--
--   p_min_score / p_max_score  on `dish_score` — the dish's aggregate the shelf prints (viewer-
--                              relative, as everywhere). score_in_range (0047): no bound = every row;
--                              any bound drops unscored dishes; a max >= 5 is open, so a dish whose
--                              average a secret 6 lifts past 5 stays in [x, 5].
--   p_city                     a cities.id: the saved dish's place's city (place_cities). Unknown → [].
--
--   my_saved_cities() → (city, name, region, dish_count): the cities your saved dishes are in, most
--   first. Not my_entry_cities(): you save dishes in places you have never been.
--
-- Filters are inside the keyset, so paging is unchanged — send the same filters on every page.
--
-- WIRE IMPACT: ADDITIVE. Three trailing optional params on search_saved (drop-then-create, LANDMINE 7;
-- old calls bind; OUT columns unchanged; grants restated). New RPC my_saved_cities.

set search_path = public, extensions;

drop function if exists public.search_saved(text, int, timestamptz, uuid);

create function public.search_saved(
  p_query           text        default null,
  p_limit           int         default 20,
  p_cursor_saved_at timestamptz default null,
  p_cursor_dish_id  uuid        default null,
  p_min_score       numeric     default null,
  p_max_score       numeric     default null,
  p_city            text        default null
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
    and (
      p_cursor_dish_id is null
      or (s.created_at, s.dish_id) < (p_cursor_saved_at, p_cursor_dish_id)
    )
  order by s.created_at desc, s.dish_id desc
  limit (select lim from q);
$$;

comment on function public.search_saved(text, int, timestamptz, uuid, numeric, numeric, text) is
  'Saved shelf + Search Saved scope: my_saved_dishes'' columns (+ restaurant_locality), filtered by dish OR place name (empty query = the whole list), dish_score range (score_in_range: max >= 5 is open; 0049) and city (p_city, 0049). Keyset (saved_at, dish_id), same filters on every page.';

create or replace function public.my_saved_cities()
returns table (city text, name text, region text, dish_count int)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select c.id, c.name, c.region, n.dish_count
  from (
    select pc.city, count(*)::int as dish_count
    from public.saves s
    join public.dishes d on d.id = s.dish_id
    join public.place_cities pc on pc.restaurant_id = d.restaurant_id
    where s.user_id = (select auth.uid())
    group by pc.city
  ) n
  join public.cities c on c.id = n.city
  order by n.dish_count desc, c.name, c.id;
$$;

comment on function public.my_saved_cities() is
  'Round 5 Saved city filter (0049): the cities the caller''s saved dishes are in, with how many dishes each, most first then name. Pass `city` to search_saved(p_city).';

revoke all on function public.search_saved(text, int, timestamptz, uuid, numeric, numeric, text) from public, anon;
revoke all on function public.my_saved_cities() from public, anon;
grant execute on function public.search_saved(text, int, timestamptz, uuid, numeric, numeric, text) to authenticated;
grant execute on function public.my_saved_cities() to authenticated;

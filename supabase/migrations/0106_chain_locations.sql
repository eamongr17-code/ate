-- 0106_chain_locations.sql
-- A CHAIN'S DISHES SHOW AT EVERY LOCATION (Eamon, 2 Nov, feedback #5: "Chain dishes should appear on
-- the map in all chain locations of that restaurant"; mockup approved 3 Nov).
--
-- The map already pins every location that is in a chain (map_candidates reads place_menu, 0088).
-- What was missing: a chain's other locations are only rows once somebody happens to search for them,
-- so one rated Guzman y Gomez had one pin. Now, once per place that has a dish, the server asks
-- Google one Text Search for the place's name around it (places-search/chains.ts), keeps the results
-- with the same name key AND the same website host (0085's rule), stores them as places, and links
-- them into the chain. They are then ordinary chain locations: the map pins them, Near me lists a
-- chain dish once at the nearest (0088), and their place page shows the chain's menu.
--
--   restaurants.locations_checked_at  — when Google was asked for this place's other locations.
--       Set for the place asked about and for every location found (that search covered them), so a
--       chain is searched about once per area, never once per location.
--   chain_locations_due(ids, limit)   — which of ids (null = every place: the backfill) still need
--       the search: a Google place with a point, never asked, with a dish on its menu.
--   chain_add_locations(place, host, places) — records the answer and links. A shared host
--       (instagram, ubereats …) or no website links nothing, as in 0085.
--
-- Volume: chain_locations_due is a primary-key read per id (or one pass with the backfill's limit);
-- the dish test is reviews_restaurant_idx. Google: one Text Search (Enterprise, for websiteUri) per
-- place, at most three pages for a big chain; charged to the caller's daily places budget.
--
-- WIRE IMPACT: none (service-role functions; no client read changes). GRANTS: service_role only.

set search_path = public, extensions;

alter table public.restaurants add column if not exists locations_checked_at timestamptz;
comment on column public.restaurants.locations_checked_at is
  '0106: when Google was asked for the other locations of this place''s name (chain discovery). Never asked again.';

-- ---------------------------------------------------------------------------
-- Which places still need their other locations looked up.
-- ---------------------------------------------------------------------------
create or replace function public.chain_locations_due(p_ids uuid[] default null, p_limit int default 20)
returns table (restaurant_id uuid, google_place_id text, name text,
               latitude double precision, longitude double precision,
               website_host text, website_checked boolean)
language sql stable security definer set search_path = public, extensions as $$
  select r.id, r.google_place_id, r.name,
         ST_Y(r.location::geometry), ST_X(r.location::geometry),
         r.website_host, r.website_checked_at is not null
  from public.restaurants r
  where (p_ids is null or r.id = any (p_ids))
    and r.source = 'places' and r.google_place_id is not null
    and r.locations_checked_at is null
    and r.location is not null
    and not (ST_X(r.location::geometry) = 0 and ST_Y(r.location::geometry) = 0)
    and public.dish_key(r.name) <> ''
    and exists (select 1 from public.reviews v where v.restaurant_id = public.place_menu(r.id))
  order by r.created_at, r.id
  limit least(greatest(coalesce(p_limit, 20), 1), 200);
$$;
comment on function public.chain_locations_due(uuid[], int) is
  '0106: places (of p_ids, or all) whose other locations Google has not been asked for yet and that have a dish. Service role only.';

-- ---------------------------------------------------------------------------
-- Record one search's answer and link what it found.
--   p_host   — the asked place's website host (null = it has none). Recorded as 0085 records it.
--   p_places — Google's results: [{ google_place_id, name, address, city, lat, lng, cuisine, host }].
-- Returns the chain the place is in afterwards (null when nothing linked).
-- ---------------------------------------------------------------------------
create or replace function public.chain_add_locations(p_restaurant_id uuid, p_host text, p_places jsonb)
returns uuid
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  r      public.restaurants;
  v_host text := nullif(lower(btrim(coalesce(p_host, ''))), '');
  p      jsonb;
  v_id   uuid;
  v_ids  uuid[] := '{}';
  v_lat  double precision;
  v_lng  double precision;
begin
  update public.restaurants
     set locations_checked_at = now(),
         website_host = v_host,
         website_checked_at = now()
   where id = p_restaurant_id and source = 'places'
  returning * into r;
  if r.id is null or public.chain_shared_host(v_host) or public.dish_key(r.name) = '' then
    return r.chain_id;
  end if;

  for p in select * from jsonb_array_elements(coalesce(p_places, '[]'::jsonb)) limit 60 loop
    continue when coalesce(p ->> 'google_place_id', '') = '' or p ->> 'google_place_id' = r.google_place_id;
    continue when nullif(lower(btrim(coalesce(p ->> 'host', ''))), '') is distinct from v_host;
    continue when public.dish_key(public.clean_place_name(coalesce(p ->> 'name', ''))) <> public.dish_key(r.name);
    v_lat := (p ->> 'lat')::double precision;
    v_lng := (p ->> 'lng')::double precision;
    continue when v_lat is null or v_lng is null or (v_lat = 0 and v_lng = 0)
               or v_lat not between -90 and 90 or v_lng not between -180 and 180;

    -- A place we already hold keeps its own name and address; it only learns its website.
    insert into public.restaurants as x
      (google_place_id, name, address, city, location, cuisine, source,
       website_host, website_checked_at, locations_checked_at)
    values
      (p ->> 'google_place_id', p ->> 'name', nullif(p ->> 'address', ''), coalesce(p ->> 'city', ''),
       ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography, nullif(p ->> 'cuisine', ''), 'places',
       v_host, now(), now())
    on conflict (google_place_id) where google_place_id is not null do update
      set website_host = excluded.website_host,
          website_checked_at = now(),
          locations_checked_at = coalesce(x.locations_checked_at, now())
    returning x.id into v_id;
    v_ids := v_ids || v_id;
  end loop;

  if cardinality(v_ids) = 0 then
    return r.chain_id;
  end if;
  perform public.chain_record_and_link('[]'::jsonb, array[p_restaurant_id] || v_ids);
  return (select x.chain_id from public.restaurants x where x.id = p_restaurant_id);
end; $$;
comment on function public.chain_add_locations(uuid, text, jsonb) is
  '0106: record a place''s website and the same-name, same-website places Google found around it, then link them into one chain. Service role only.';

revoke all on function public.chain_locations_due(uuid[], int)        from public, anon, authenticated;
revoke all on function public.chain_add_locations(uuid, text, jsonb)  from public, anon, authenticated;
grant execute on function public.chain_locations_due(uuid[], int)       to service_role;
grant execute on function public.chain_add_locations(uuid, text, jsonb) to service_role;

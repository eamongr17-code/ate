-- 0070_link_manual_places.sql
-- Ate backend — the four places prod's testers added by hand while Google Places was refused (the
-- key only allowed localhost and the trial had lapsed; fixed 18 Oct) become the Google places they
-- are, so they get a map point (Nearby, distances), an address and a place id that a later Google
-- pick of the same venue resolves to instead of duplicating (Eamon, 18 Oct: "match them").
--
-- Each was matched by hand on Google Maps (name + suburb, single unambiguous result). The place id is
-- Google's ChIJ encoding of the Maps feature id; the encoding was checked against a row Google itself
-- wrote (Wise Guys Pizzeria: ChIJlWmUV0xo1moRWrMgvlB8XYM ↔ 0x6ad6684c57946995:0x835d7c50be20b35a).
--
-- DATA (prod only in effect; staging has no such ids, so every update matches nothing):
--   4 restaurants rows, keyed by id AND still manual AND same name, gain source 'places',
--   google_place_id, address and location. Name, city and every entry/review pointing at them are
--   unchanged. A row is skipped (notice) if Google's row for the venue already exists — then two rows
--   would need merging, which is not this migration's job.
-- WIRE IMPACT: none.

do $$
declare
  m record;
begin
  for m in
    select * from (values
      ('6bd8faae-58dc-4b25-9064-9527aa3c4b07'::uuid, 'Small Wins',        'ChIJH8uNX8Rp1moR3B6YRXsiNNc',
       '1203 High St, Armadale VIC 3143, Australia',            -37.8562109, 145.0278178),
      ('78089cad-3b46-405f-bd17-ca9891d23a1b'::uuid, 'Fitness Smoothies', 'ChIJDX8KZLlp1moRqL9gz95kmmI',
       '46 Chapel St, Windsor VIC 3181, Australia',             -37.8560139, 144.9927565),
      ('a0a8cd35-0add-428e-95e4-07ece6066a7e'::uuid, 'Bali Hai',          'ChIJlZMigFlD1moRi3xJROFiChQ',
       'Shop 2/32 Bourke St, Melbourne VIC 3000, Australia',    -37.811442,  144.9720127),
      ('eab3717d-d12c-4dc1-9055-c4129da9fd4d'::uuid, 'Astrid',            'ChIJd9i-34xD1moR7On3sPz07RI',
       '710 Sydney Rd, Brunswick VIC 3056, Australia',          -37.7606344, 144.9633886)
    ) as v(id, name, place_id, address, lat, lng)
  loop
    if exists (select 1 from public.restaurants where google_place_id = m.place_id) then
      raise notice '0070: % already has a Google row; left manual', m.name;
      continue;
    end if;

    update public.restaurants
       set source = 'places',
           google_place_id = m.place_id,
           address = m.address,
           location = extensions.ST_SetSRID(extensions.ST_MakePoint(m.lng, m.lat), 4326)::geography
     where id = m.id
       and source = 'manual'
       and google_place_id is null
       and name = m.name;
  end loop;
end $$;

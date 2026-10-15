-- 0066_beyond_one_city.sql
-- Ate backend — the app works wherever you are, not only in Victoria (Eamon, 15 Oct: testing in
-- Thailand). Two additive pieces; places-search's VIC fence goes in the same change.
--
--   1. cities — Thailand's food cities join the reference list, so a Bangkok place belongs to a city
--      the Feed, Journal and Search filters can name (0046's model, unchanged). Reference data, not
--      user data: changing the list is a migration (0046's rule).
--   2. places_bias_point(p_user_id) — where this person last ate (the newest of their entries with a
--      located place). places-search ranks a typed search around it when the app sends no location:
--      a search sent from Bangkok without permission still finds Bangkok once you've eaten there.
--      Service role only; it answers for the caller places-search has already verified.
--
-- WIRE IMPACT: ADDITIVE. No existing function or column changes shape.

set search_path = public, extensions;

insert into public.cities (id, name, region, country, center, radius_m, aliases) values
  ('bangkok',    'Bangkok',    'BKK', 'TH', extensions.ST_SetSRID(extensions.ST_MakePoint(100.5018, 13.7563), 4326)::geography, 50000, '{"krung thep maha nakhon","krung thep"}'),
  ('chiang-mai', 'Chiang Mai', 'CMI', 'TH', extensions.ST_SetSRID(extensions.ST_MakePoint( 98.9853, 18.7883), 4326)::geography, 25000, '{}'),
  ('chiang-rai', 'Chiang Rai', 'CRI', 'TH', extensions.ST_SetSRID(extensions.ST_MakePoint( 99.8325, 19.9105), 4326)::geography, 20000, '{}'),
  ('phuket',     'Phuket',     'PKT', 'TH', extensions.ST_SetSRID(extensions.ST_MakePoint( 98.3381,  7.9519), 4326)::geography, 35000, '{}'),
  ('krabi',      'Krabi',      'KBI', 'TH', extensions.ST_SetSRID(extensions.ST_MakePoint( 98.9063,  8.0863), 4326)::geography, 30000, '{"ao nang"}'),
  ('koh-samui',  'Koh Samui',  'SNI', 'TH', extensions.ST_SetSRID(extensions.ST_MakePoint(100.0136,  9.5120), 4326)::geography, 20000, '{"ko samui"}'),
  ('koh-phangan','Koh Phangan','SNI', 'TH', extensions.ST_SetSRID(extensions.ST_MakePoint(100.0287,  9.7380), 4326)::geography, 12000, '{"ko pha-ngan","ko phangan"}'),
  ('pattaya',    'Pattaya',    'CBI', 'TH', extensions.ST_SetSRID(extensions.ST_MakePoint(100.8825, 12.9236), 4326)::geography, 20000, '{}'),
  ('hua-hin',    'Hua Hin',    'PKN', 'TH', extensions.ST_SetSRID(extensions.ST_MakePoint( 99.9580, 12.5684), 4326)::geography, 15000, '{}')
on conflict (id) do nothing;

create or replace function public.places_bias_point(p_user_id uuid)
returns table (lat double precision, lng double precision)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select extensions.ST_Y(r.location::geometry), extensions.ST_X(r.location::geometry)
  from public.entries e
  join public.restaurants r on r.id = e.restaurant_id
  where e.author_id = p_user_id
    and r.location is not null
  order by e.created_at desc
  limit 1;
$$;

comment on function public.places_bias_point(uuid) is
  '0066: where this person last ate (newest entry with a located place) as lat/lng, or no row. places-search ranks typed searches around it when the app sends no location. Service role only.';

revoke all on function public.places_bias_point(uuid) from public, anon, authenticated;
grant execute on function public.places_bias_point(uuid) to service_role;

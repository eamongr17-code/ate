-- supabase/seed.sql
-- Ate — reboot seed dataset (Melbourne).
--
-- WHAT THIS IS
--   A realistic, entirely SYNTHETIC Melbourne dataset for STAGING and local dev:
--   8 Places-backed restaurants + 1 manual restaurant, 21 dishes, 46 reviews across
--   6 accounts, plus the social edges (follows/likes/comments), lists, and two
--   review-tags. Enough to exercise every read surface the iOS app has: global feed,
--   following feed, diary, restaurant page (mean-of-per-dish-averages), dish page,
--   search, lists, notifications, and the empty states.
--
-- SYNTHETIC MARKERS (so this data is never mistaken for real user data)
--   * every account is @ate.test
--   * every Places-backed restaurant has google_place_id = 'stub-<slug>' (no real
--     Google Place id is ever a 'stub-' string)
--   * the one manual restaurant is literally named "... (synthetic)"
--   * all seeded rows use fixed UUIDs in the a0000000-/b0000000-/c0000000-/
--     d0000000-/e0000000- namespaces
--   NEVER run this against production.
--
-- AUTH USERS
--   profiles.id references auth.users(id), so the accounts must exist first.
--   Preferred path (staging): create them via the GoTrue admin API
--   (POST /auth/v1/admin/users, email_confirm=true, user_metadata {name, username}).
--   The handle_new_user trigger (0005) then creates profiles + the system "Saved"
--   list. This file RESOLVES the accounts by email and, if one is missing (local
--   `supabase db reset`), falls back to a direct auth.users insert with the same
--   password so the seed is self-contained. Password for all accounts: atedemo123.
--
-- IDEMPOTENT
--   Re-running deletes the seeded restaurants (cascading dishes -> reviews ->
--   likes/comments/tags/notifications), the seeded lists, and the seeded follows,
--   then re-inserts. Counter caches (profiles.review_count, follower/following,
--   reviews.like_count/comment_count) are trigger-maintained and unwind correctly
--   on those deletes. The auth accounts themselves are NOT deleted.
--
-- DERIVED vs STORED (see data-model + migration 0009)
--   dish_stats.score / review_count / cover_url and restaurant_stats.avg_rating /
--   review_count / cover_url are LIVE-DERIVED VIEWS — nothing here materialises
--   them. reviews.like_count/comment_count and profiles.*_count ARE stored caches,
--   maintained by triggers (0005). This seed writes none of them by hand.

set search_path = public, extensions;

-- ===========================================================================
-- 0. Accounts — resolve by email; create only if absent (local-dev fallback).
-- ===========================================================================
do $$
declare
  a record;
  enc_pw text := extensions.crypt('atedemo123', extensions.gen_salt('bf'));
begin
  for a in
    select * from (values
      ('eamon@ate.test', 'Eamon',          'eamon'),
      ('priya@ate.test', 'Priya Raman',    'priyaeats'),
      ('tom@ate.test',   'Tom Nguyen',     'brunswickbites'),
      ('alice@ate.test', 'Alice Whitlock', 'southsidealice'),
      ('marco@ate.test', 'Marco Bellini',  'pastaindex'),
      ('jess@ate.test',  'Jess Okafor',    'crumbsmelb')
    ) as t(email, name, username)
  loop
    if not exists (select 1 from auth.users where email = a.email) then
      insert into auth.users
        (instance_id, id, aud, role, email, encrypted_password,
         email_confirmed_at, created_at, updated_at, last_sign_in_at,
         raw_app_meta_data, raw_user_meta_data,
         confirmation_token, recovery_token, email_change_token_new, email_change)
      values
        ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
         'authenticated', 'authenticated', a.email, enc_pw,
         now(), now(), now(), now(),
         '{"provider":"email","providers":["email"]}',
         jsonb_build_object('name', a.name, 'username', a.username),
         '', '', '', '');
      -- handle_new_user (0005) creates the profile + "Saved" list.
    end if;
  end loop;
end $$;

-- ---- curate profile display fields (idempotent UPDATE) --------------------
update public.profiles p set
  name       = v.name,
  username   = v.username,
  bio        = v.bio,
  avatar_url = v.avatar_url
from (values
  ('eamon@ate.test', 'Eamon',          'eamon',
   'Melbourne. Logging every dish worth ordering again.', 'https://i.pravatar.cc/300?img=12'),
  ('priya@ate.test', 'Priya Raman',    'priyaeats',
   'CBD lunch specialist. Will queue.',                   'https://i.pravatar.cc/300?img=32'),
  ('tom@ate.test',   'Tom Nguyen',     'brunswickbites',
   'Northside. Pasta, pastry, and the 96 tram.',          'https://i.pravatar.cc/300?img=68'),
  ('alice@ate.test', 'Alice Whitlock', 'southsidealice',
   'Eating my way east one bistro at a time.',            'https://i.pravatar.cc/300?img=45'),
  ('marco@ate.test', 'Marco Bellini',  'pastaindex',
   'I rate pasta. That is the whole personality.',        'https://i.pravatar.cc/300?img=59'),
  ('jess@ate.test',  'Jess Okafor',    'crumbsmelb',
   'Croissant-first decision making.',                    'https://i.pravatar.cc/300?img=26')
) as v(email, name, username, bio, avatar_url)
where p.id = (select u.id from auth.users u where u.email = v.email);

-- ===========================================================================
-- 1. Clean prior seed (cascades to dishes -> reviews -> likes/comments/tags/
--    notifications; trigger caches unwind on the way down).
-- ===========================================================================
delete from public.restaurants
 where id in (
   'a0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000002',
   'a0000000-0000-4000-8000-000000000003','a0000000-0000-4000-8000-000000000004',
   'a0000000-0000-4000-8000-000000000005','a0000000-0000-4000-8000-000000000006',
   'a0000000-0000-4000-8000-000000000007','a0000000-0000-4000-8000-000000000008',
   'a0000000-0000-4000-8000-000000000009');

delete from public.lists
 where id in ('d0000000-0000-4000-8000-000000000001',
              'd0000000-0000-4000-8000-000000000002');

delete from public.follows
 where follower_id in (select id from auth.users where email like '%@ate.test')
   and followee_id in (select id from auth.users where email like '%@ate.test');

-- 'follow' notifications are not cascaded by the follows delete (notifications has
-- no FK to follows), so clear them explicitly for the seeded cohort.
delete from public.notifications
 where type = 'follow'
   and recipient_id in (select id from auth.users where email like '%@ate.test');

-- ===========================================================================
-- 2. Restaurants (8 Places-backed 'stub-' rows + 1 manual row)
--    location is geography(Point,4326): ST_MakePoint(LONGITUDE, LATITUDE).
--    cover_url here is the physical column; clients should prefer the
--    LIVE-DERIVED restaurant_stats.cover_url (migration 0009).
-- ===========================================================================
insert into public.restaurants
  (id, source, google_place_id, name, address, city, cuisine, location, cover_url)
values
  ('a0000000-0000-4000-8000-000000000001', 'places', 'stub-chin-chin',
   'Chin Chin', '125 Flinders Ln', 'Melbourne', 'Thai',
   extensions.ST_SetSRID(extensions.ST_MakePoint(144.96950, -37.81630), 4326)::geography,
   'https://images.unsplash.com/photo-1414235077428-338989a2e8c0?auto=format&fit=crop&w=800&q=70'),

  ('a0000000-0000-4000-8000-000000000002', 'places', 'stub-supernormal',
   'Supernormal', '180 Flinders Ln', 'Melbourne', 'Asian',
   extensions.ST_SetSRID(extensions.ST_MakePoint(144.97070, -37.81570), 4326)::geography,
   'https://images.unsplash.com/photo-1552332386-f8dd00dc2f85?auto=format&fit=crop&w=800&q=70'),

  ('a0000000-0000-4000-8000-000000000003', 'places', 'stub-tipo-00',
   'Tipo 00', '361 Little Bourke St', 'Melbourne', 'Italian',
   extensions.ST_SetSRID(extensions.ST_MakePoint(144.96170, -37.81340), 4326)::geography,
   'https://images.unsplash.com/photo-1551782450-a2132b4ba21d?auto=format&fit=crop&w=800&q=70'),

  ('a0000000-0000-4000-8000-000000000004', 'places', 'stub-gimlet',
   'Gimlet at Cavendish House', '33 Russell St', 'Melbourne', 'European',
   extensions.ST_SetSRID(extensions.ST_MakePoint(144.96950, -37.81430), 4326)::geography,
   'https://images.unsplash.com/photo-1414235077428-338989a2e8c0?auto=format&fit=crop&w=800&q=70'),

  ('a0000000-0000-4000-8000-000000000005', 'places', 'stub-cutler-and-co',
   'Cutler & Co', '55-57 Gertrude St', 'Fitzroy', 'Modern Australian',
   extensions.ST_SetSRID(extensions.ST_MakePoint(144.97870, -37.80630), 4326)::geography,
   'https://images.unsplash.com/photo-1481931098730-318b6f776db0?auto=format&fit=crop&w=800&q=70'),

  ('a0000000-0000-4000-8000-000000000006', 'places', 'stub-lune-fitzroy',
   'Lune Croissanterie', '119 Rose St', 'Fitzroy', 'Bakery',
   extensions.ST_SetSRID(extensions.ST_MakePoint(144.98030, -37.79860), 4326)::geography,
   'https://images.unsplash.com/photo-1509440159596-0249088772ff?auto=format&fit=crop&w=800&q=70'),

  ('a0000000-0000-4000-8000-000000000007', 'places', 'stub-baby-pizza',
   'Baby Pizza', '631 Church St', 'Richmond', 'Pizza',
   extensions.ST_SetSRID(extensions.ST_MakePoint(144.99550, -37.82880), 4326)::geography,
   'https://images.unsplash.com/photo-1565299624946-b28f40a0ae38?auto=format&fit=crop&w=800&q=70'),

  ('a0000000-0000-4000-8000-000000000008', 'places', 'stub-etta',
   'Etta', '60 Lygon St', 'Brunswick East', 'Modern Australian',
   extensions.ST_SetSRID(extensions.ST_MakePoint(144.97610, -37.77170), 4326)::geography,
   'https://images.unsplash.com/photo-1476224203421-9ac39bcb3327?auto=format&fit=crop&w=800&q=70'),

  -- source='manual' MUST carry google_place_id NULL (restaurants_source_placeid_ck,
  -- migration 0014). Deliberately dish-less so the app's empty restaurant state has
  -- something real to render.
  ('a0000000-0000-4000-8000-000000000009', 'manual', null,
   'Nonna''s Kitchen (synthetic)', '12 Sydney Rd', 'Coburg', 'Italian',
   extensions.ST_SetSRID(extensions.ST_MakePoint(144.96500, -37.74400), 4326)::geography,
   null);

-- ===========================================================================
-- 3. Dishes (21). Identity is (restaurant_id, lower(name)) for live rows
--    (dishes_identity_uq, 0002) — no duplicate name within a restaurant.
--    photo_url intentionally NULL: covers are LIVE-DERIVED from reviews (0009).
-- ===========================================================================
insert into public.dishes (id, name, restaurant_id, created_by_user_id, category)
select v.id::uuid, v.name, v.restaurant_id::uuid, u.id, v.category
from (values
  -- Chin Chin
  ('b0000000-0000-4000-8000-000000000001','Twice Cooked Beef Short Rib','a0000000-0000-4000-8000-000000000001','priya@ate.test','Mains'),
  ('b0000000-0000-4000-8000-000000000002','Kingfish Sashimi',           'a0000000-0000-4000-8000-000000000001','priya@ate.test','Starters'),
  ('b0000000-0000-4000-8000-000000000003','Son-in-Law Eggs',            'a0000000-0000-4000-8000-000000000001','eamon@ate.test','Starters'),
  -- Supernormal
  ('b0000000-0000-4000-8000-000000000004','New England Lobster Roll',   'a0000000-0000-4000-8000-000000000002','alice@ate.test','Mains'),
  ('b0000000-0000-4000-8000-000000000005','Prawn & Pork Wontons',       'a0000000-0000-4000-8000-000000000002','tom@ate.test',  'Starters'),
  ('b0000000-0000-4000-8000-000000000006','Peanut Butter Parfait',      'a0000000-0000-4000-8000-000000000002','alice@ate.test','Sweets'),
  -- Tipo 00
  ('b0000000-0000-4000-8000-000000000007','Tagliolini with Blue Swimmer Crab','a0000000-0000-4000-8000-000000000003','marco@ate.test','Pasta'),
  ('b0000000-0000-4000-8000-000000000008','Wagyu Bresaola',             'a0000000-0000-4000-8000-000000000003','marco@ate.test','Starters'),
  ('b0000000-0000-4000-8000-000000000009','Cacio e Pepe',               'a0000000-0000-4000-8000-000000000003','marco@ate.test','Pasta'),
  -- Gimlet
  ('b0000000-0000-4000-8000-000000000010','Wood-Fired Sourdough Crumpet','a0000000-0000-4000-8000-000000000004','alice@ate.test','Snacks'),
  ('b0000000-0000-4000-8000-000000000011','Vitello Tonnato',            'a0000000-0000-4000-8000-000000000004','alice@ate.test','Starters'),
  ('b0000000-0000-4000-8000-000000000012','Roast Duck',                 'a0000000-0000-4000-8000-000000000004','eamon@ate.test','Mains'),
  -- Cutler & Co
  ('b0000000-0000-4000-8000-000000000013','Smoked Eel Croquette',       'a0000000-0000-4000-8000-000000000005','priya@ate.test','Snacks'),
  ('b0000000-0000-4000-8000-000000000014','Dry-Aged Duck',              'a0000000-0000-4000-8000-000000000005','alice@ate.test','Mains'),
  -- Lune
  ('b0000000-0000-4000-8000-000000000015','Plain Croissant',            'a0000000-0000-4000-8000-000000000006','jess@ate.test', 'Pastry'),
  ('b0000000-0000-4000-8000-000000000016','Kouign-Amann',               'a0000000-0000-4000-8000-000000000006','jess@ate.test', 'Pastry'),
  ('b0000000-0000-4000-8000-000000000017','Twice-Baked Almond Croissant','a0000000-0000-4000-8000-000000000006','jess@ate.test', 'Pastry'),
  -- Baby Pizza
  ('b0000000-0000-4000-8000-000000000018','Margherita',                 'a0000000-0000-4000-8000-000000000007','tom@ate.test',  'Pizza'),
  ('b0000000-0000-4000-8000-000000000019','Nduja & Honey Pizza',        'a0000000-0000-4000-8000-000000000007','marco@ate.test','Pizza'),
  -- Etta
  ('b0000000-0000-4000-8000-000000000020','Charred Cabbage',            'a0000000-0000-4000-8000-000000000008','tom@ate.test',  'Sides'),
  ('b0000000-0000-4000-8000-000000000021','Handmade Rigatoni',          'a0000000-0000-4000-8000-000000000008','tom@ate.test',  'Pasta')
) as v(id, name, restaurant_id, email, category)
join auth.users u on u.email = v.email;

-- ===========================================================================
-- 4. Reviews (46).
--    * score is half-step constrained 0.5..5.0 (reviews_score_halfstep, 0002) —
--      only .0 and .5 values are legal INPUT. The 0.1-granularity numbers the UI
--      shows are DERIVED averages (dish_stats.score), never review inputs.
--    * restaurant_id is DELIBERATELY OMITTED: trg_review_set_restaurant (0005) is a
--      BEFORE trigger that derives it authoritatively from the dish.
--    * dishes b..03 (Son-in-Law Eggs) and b..08 (Wagyu Bresaola) are left
--      UNREVIEWED on purpose so the "unrated dish" state (dish_stats.score IS NULL)
--      is exercised.
--    * photo_url on 13 reviews so the derived cover_url (0009) is non-null for a
--      representative sample of dishes AND restaurants, and null for the rest.
-- ===========================================================================
insert into public.reviews (id, reviewer_id, dish_id, score, note, photo_url, created_at)
select v.id::uuid, u.id, v.dish_id::uuid, v.score::numeric(2,1), v.note, v.photo,
       now() - (v.days_ago || ' days')::interval
from (values
  -- ---- eamon (the demo account's diary) ----
  ('c0000000-0000-4000-8000-000000000001','eamon@ate.test','b0000000-0000-4000-8000-000000000001',4.5,'Sticky, hot, deeply savoury. Get extra rice or regret it.','https://images.unsplash.com/photo-1414235077428-338989a2e8c0?auto=format&fit=crop&w=800&q=70',1),
  ('c0000000-0000-4000-8000-000000000002','eamon@ate.test','b0000000-0000-4000-8000-000000000007',5.0,'Best plate of pasta in the city and it is not close.','https://images.unsplash.com/photo-1551782450-a2132b4ba21d?auto=format&fit=crop&w=800&q=70',3),
  ('c0000000-0000-4000-8000-000000000003','eamon@ate.test','b0000000-0000-4000-8000-000000000015',5.0,'Shatters properly. Worth the Rose St queue on a cold morning.','https://images.unsplash.com/photo-1509440159596-0249088772ff?auto=format&fit=crop&w=800&q=70',6),
  ('c0000000-0000-4000-8000-000000000004','eamon@ate.test','b0000000-0000-4000-8000-000000000018',4.0,'Clean, simple, well-blistered base. Slightly underseasoned.',null,9),
  ('c0000000-0000-4000-8000-000000000005','eamon@ate.test','b0000000-0000-4000-8000-000000000012',4.5,'Skin like glass. The sauce does a lot of heavy lifting.',null,14),
  ('c0000000-0000-4000-8000-000000000006','eamon@ate.test','b0000000-0000-4000-8000-000000000005',4.0,'Good snap on the wrapper, the broth is the star.',null,21),
  ('c0000000-0000-4000-8000-000000000007','eamon@ate.test','b0000000-0000-4000-8000-000000000021',3.5,'Nice chew but the sauce was thin the night I went.',null,28),
  ('c0000000-0000-4000-8000-000000000008','eamon@ate.test','b0000000-0000-4000-8000-000000000016',4.5,'Caramelised to the edge of burnt, exactly right.','https://images.unsplash.com/photo-1509440159596-0249088772ff?auto=format&fit=crop&w=800&q=70',35),
  -- ---- priya ----
  ('c0000000-0000-4000-8000-000000000009','priya@ate.test','b0000000-0000-4000-8000-000000000001',5.0,'I order this every single time. Non-negotiable.','https://images.unsplash.com/photo-1555939594-58d7cb561ad1?auto=format&fit=crop&w=800&q=70',2),
  ('c0000000-0000-4000-8000-000000000010','priya@ate.test','b0000000-0000-4000-8000-000000000002',4.5,'Sharp, citrusy, and cold in the right way.',null,5),
  ('c0000000-0000-4000-8000-000000000011','priya@ate.test','b0000000-0000-4000-8000-000000000007',4.5,'Crab is generous. Would have liked a touch more chilli.',null,8),
  ('c0000000-0000-4000-8000-000000000012','priya@ate.test','b0000000-0000-4000-8000-000000000009',4.0,'Very good, but I have had better for half the price.',null,12),
  ('c0000000-0000-4000-8000-000000000013','priya@ate.test','b0000000-0000-4000-8000-000000000013',5.0,'Two bites of pure smoke. Order four.','https://images.unsplash.com/photo-1481931098730-318b6f776db0?auto=format&fit=crop&w=800&q=70',17),
  ('c0000000-0000-4000-8000-000000000014','priya@ate.test','b0000000-0000-4000-8000-000000000015',4.5,'Textbook lamination. Slightly under-baked on my visit.',null,24),
  ('c0000000-0000-4000-8000-000000000015','priya@ate.test','b0000000-0000-4000-8000-000000000019',4.5,'Sweet-hot-salty. Best thing on the Baby menu.',null,30),
  -- ---- tom ----
  ('c0000000-0000-4000-8000-000000000016','tom@ate.test','b0000000-0000-4000-8000-000000000016',5.0,'Sugar shell, custardy middle. Genuinely perfect.','https://images.unsplash.com/photo-1533089860892-a7c6f0a88666?auto=format&fit=crop&w=800&q=70',1),
  ('c0000000-0000-4000-8000-000000000017','tom@ate.test','b0000000-0000-4000-8000-000000000015',4.5,'Still the benchmark, even on an ordinary day.',null,4),
  ('c0000000-0000-4000-8000-000000000018','tom@ate.test','b0000000-0000-4000-8000-000000000021',4.0,'Solid northside pasta. Portion is honest.',null,7),
  ('c0000000-0000-4000-8000-000000000019','tom@ate.test','b0000000-0000-4000-8000-000000000020',3.5,'Charred hard, dressed light. A bit one-note.',null,11),
  ('c0000000-0000-4000-8000-000000000020','tom@ate.test','b0000000-0000-4000-8000-000000000018',4.5,'Leopard-spotted, properly wet in the middle. Very good.',null,15),
  ('c0000000-0000-4000-8000-000000000021','tom@ate.test','b0000000-0000-4000-8000-000000000005',4.5,'Better than the version I keep chasing in Richmond.',null,20),
  ('c0000000-0000-4000-8000-000000000022','tom@ate.test','b0000000-0000-4000-8000-000000000004',4.0,'Rich, buttery, gone in four bites. Pricey.',null,27),
  -- ---- alice ----
  ('c0000000-0000-4000-8000-000000000023','alice@ate.test','b0000000-0000-4000-8000-000000000004',5.0,'The bun is toasted properly, which is the whole game.','https://images.unsplash.com/photo-1512058564366-18510be2db19?auto=format&fit=crop&w=800&q=70',2),
  ('c0000000-0000-4000-8000-000000000024','alice@ate.test','b0000000-0000-4000-8000-000000000006',4.0,'Rich enough to share. The salt on top saves it.',null,6),
  ('c0000000-0000-4000-8000-000000000025','alice@ate.test','b0000000-0000-4000-8000-000000000011',4.5,'Tuna sauce is silky, veal paper thin. Classic done right.',null,10),
  ('c0000000-0000-4000-8000-000000000026','alice@ate.test','b0000000-0000-4000-8000-000000000010',5.0,'A crumpet has no business being this good.','https://images.unsplash.com/photo-1546069901-ba9599a7e63c?auto=format&fit=crop&w=800&q=70',13),
  ('c0000000-0000-4000-8000-000000000027','alice@ate.test','b0000000-0000-4000-8000-000000000014',4.5,'Funky in the best way. The skin is the point.',null,18),
  ('c0000000-0000-4000-8000-000000000028','alice@ate.test','b0000000-0000-4000-8000-000000000012',4.0,'Very good duck, slightly overshadowed by everything else.',null,23),
  ('c0000000-0000-4000-8000-000000000029','alice@ate.test','b0000000-0000-4000-8000-000000000002',4.0,'Fresh, but I wanted more of the dressing.',null,31),
  -- ---- marco ----
  ('c0000000-0000-4000-8000-000000000030','marco@ate.test','b0000000-0000-4000-8000-000000000009',5.0,'Emulsified properly. No clumps, no oil slick. Rare.','https://images.unsplash.com/photo-1551782450-a2132b4ba21d?auto=format&fit=crop&w=800&q=70',1),
  ('c0000000-0000-4000-8000-000000000031','marco@ate.test','b0000000-0000-4000-8000-000000000007',4.5,'Beautiful, though I would pull it 30 seconds earlier.',null,4),
  ('c0000000-0000-4000-8000-000000000032','marco@ate.test','b0000000-0000-4000-8000-000000000021',4.5,'Rigatoni with real bite. Northside is eating well.',null,9),
  ('c0000000-0000-4000-8000-000000000033','marco@ate.test','b0000000-0000-4000-8000-000000000019',5.0,'Honey on nduja should be illegal. Order two.','https://images.unsplash.com/photo-1565299624946-b28f40a0ae38?auto=format&fit=crop&w=800&q=70',13),
  ('c0000000-0000-4000-8000-000000000034','marco@ate.test','b0000000-0000-4000-8000-000000000018',3.5,'Base was a little pale. Off night, I think.',null,19),
  ('c0000000-0000-4000-8000-000000000035','marco@ate.test','b0000000-0000-4000-8000-000000000001',4.0,'Great, but sweeter than I want it to be.',null,26),
  ('c0000000-0000-4000-8000-000000000036','marco@ate.test','b0000000-0000-4000-8000-000000000014',4.5,'Worth the walk up Gertrude St.',null,33),
  -- ---- jess ----
  ('c0000000-0000-4000-8000-000000000037','jess@ate.test','b0000000-0000-4000-8000-000000000015',5.0,'The one I compare every other croissant to.','https://images.unsplash.com/photo-1509440159596-0249088772ff?auto=format&fit=crop&w=800&q=70',2),
  ('c0000000-0000-4000-8000-000000000038','jess@ate.test','b0000000-0000-4000-8000-000000000017',5.0,'Frangipane to the edges. Sit down for this one.','https://images.unsplash.com/photo-1533089860892-a7c6f0a88666?auto=format&fit=crop&w=800&q=70',5),
  ('c0000000-0000-4000-8000-000000000039','jess@ate.test','b0000000-0000-4000-8000-000000000016',4.5,'Sweeter than the almond. Still excellent.',null,8),
  ('c0000000-0000-4000-8000-000000000040','jess@ate.test','b0000000-0000-4000-8000-000000000010',4.5,'Salty, buttery, absurd. Great with a martini.',null,12),
  ('c0000000-0000-4000-8000-000000000041','jess@ate.test','b0000000-0000-4000-8000-000000000006',4.5,'Dessert that actually finishes the meal properly.',null,16),
  ('c0000000-0000-4000-8000-000000000042','jess@ate.test','b0000000-0000-4000-8000-000000000013',4.0,'Lovely, but I wanted a sharper hit of vinegar.',null,22),
  ('c0000000-0000-4000-8000-000000000043','jess@ate.test','b0000000-0000-4000-8000-000000000020',4.0,'More interesting than it sounds. Good char.',null,29),
  ('c0000000-0000-4000-8000-000000000044','jess@ate.test','b0000000-0000-4000-8000-000000000011',3.5,'Fine. Not the reason to come here.',null,34),
  -- ---- older tail (so keyset pagination has something past page 1) ----
  ('c0000000-0000-4000-8000-000000000045','alice@ate.test','b0000000-0000-4000-8000-000000000017',4.5,'Enormous. Split it unless you are very committed.',null,40),
  ('c0000000-0000-4000-8000-000000000046','priya@ate.test','b0000000-0000-4000-8000-000000000010',4.0,'Good, though it is a snack priced like a main.',null,38)
) as v(id, email, dish_id, score, note, photo, days_ago)
join auth.users u on u.email = v.email;

-- ===========================================================================
-- 5. Follows (16 edges). Drives get_feed + follower/following counter caches
--    + 'follow' notifications.
-- ===========================================================================
insert into public.follows (follower_id, followee_id)
select f.id, t.id
from (values
  ('eamon@ate.test','priya@ate.test'), ('eamon@ate.test','tom@ate.test'),
  ('eamon@ate.test','alice@ate.test'), ('eamon@ate.test','marco@ate.test'),
  ('eamon@ate.test','jess@ate.test'),
  ('priya@ate.test','eamon@ate.test'), ('priya@ate.test','marco@ate.test'),
  ('priya@ate.test','jess@ate.test'),
  ('tom@ate.test','eamon@ate.test'),   ('tom@ate.test','jess@ate.test'),
  ('alice@ate.test','priya@ate.test'), ('alice@ate.test','eamon@ate.test'),
  ('marco@ate.test','priya@ate.test'),
  ('jess@ate.test','tom@ate.test'),    ('jess@ate.test','eamon@ate.test'),
  ('jess@ate.test','priya@ate.test')
) as v(follower, followee)
join auth.users f on f.email = v.follower
join auth.users t on t.email = v.followee
on conflict do nothing;

-- ===========================================================================
-- 6. Likes (24). Bumps reviews.like_count via trigger + fans out notifications.
-- ===========================================================================
insert into public.review_likes (user_id, review_id)
select u.id, v.review_id::uuid
from (values
  ('priya@ate.test','c0000000-0000-4000-8000-000000000001'),
  ('tom@ate.test',  'c0000000-0000-4000-8000-000000000001'),
  ('marco@ate.test','c0000000-0000-4000-8000-000000000001'),
  ('jess@ate.test', 'c0000000-0000-4000-8000-000000000001'),
  ('eamon@ate.test','c0000000-0000-4000-8000-000000000009'),
  ('tom@ate.test',  'c0000000-0000-4000-8000-000000000009'),
  ('eamon@ate.test','c0000000-0000-4000-8000-000000000016'),
  ('jess@ate.test', 'c0000000-0000-4000-8000-000000000016'),
  ('priya@ate.test','c0000000-0000-4000-8000-000000000016'),
  ('eamon@ate.test','c0000000-0000-4000-8000-000000000030'),
  ('priya@ate.test','c0000000-0000-4000-8000-000000000030'),
  ('marco@ate.test','c0000000-0000-4000-8000-000000000002'),
  ('priya@ate.test','c0000000-0000-4000-8000-000000000002'),
  ('jess@ate.test', 'c0000000-0000-4000-8000-000000000002'),
  ('eamon@ate.test','c0000000-0000-4000-8000-000000000037'),
  ('tom@ate.test',  'c0000000-0000-4000-8000-000000000037'),
  ('priya@ate.test','c0000000-0000-4000-8000-000000000038'),
  ('eamon@ate.test','c0000000-0000-4000-8000-000000000023'),
  ('marco@ate.test','c0000000-0000-4000-8000-000000000033'),
  ('tom@ate.test',  'c0000000-0000-4000-8000-000000000033'),
  ('alice@ate.test','c0000000-0000-4000-8000-000000000003'),
  ('jess@ate.test', 'c0000000-0000-4000-8000-000000000003'),
  ('eamon@ate.test','c0000000-0000-4000-8000-000000000026'),
  ('alice@ate.test','c0000000-0000-4000-8000-000000000013')
) as v(email, review_id)
join auth.users u on u.email = v.email
on conflict do nothing;

-- ===========================================================================
-- 7. Comments (11). Bumps reviews.comment_count + fans out notifications.
-- ===========================================================================
insert into public.comments (id, review_id, user_id, text, created_at)
select v.id::uuid, v.review_id::uuid, u.id, v.text,
       now() - (v.hours_ago || ' hours')::interval
from (values
  ('e0000000-0000-4000-8000-000000000001','c0000000-0000-4000-8000-000000000001','priya@ate.test','Told you. It is the only thing I order there.',20),
  ('e0000000-0000-4000-8000-000000000002','c0000000-0000-4000-8000-000000000001','marco@ate.test','Too sweet for me but I respect the rating.',14),
  ('e0000000-0000-4000-8000-000000000003','c0000000-0000-4000-8000-000000000002','marco@ate.test','Finally someone else says it out loud.',60),
  ('e0000000-0000-4000-8000-000000000004','c0000000-0000-4000-8000-000000000002','priya@ate.test','Booking for next Thursday, you are coming.',55),
  ('e0000000-0000-4000-8000-000000000005','c0000000-0000-4000-8000-000000000016','jess@ate.test','The 8am batch is the one. Any later and it is gone.',18),
  ('e0000000-0000-4000-8000-000000000006','c0000000-0000-4000-8000-000000000016','eamon@ate.test','Adding to the list immediately.',10),
  ('e0000000-0000-4000-8000-000000000007','c0000000-0000-4000-8000-000000000030','priya@ate.test','Agreed, and the room is half the reason.',9),
  ('e0000000-0000-4000-8000-000000000008','c0000000-0000-4000-8000-000000000037','tom@ate.test','Correct. Everything else is a croissant-shaped object.',30),
  ('e0000000-0000-4000-8000-000000000009','c0000000-0000-4000-8000-000000000023','eamon@ate.test','Worth the price? Genuinely asking.',40),
  ('e0000000-0000-4000-8000-000000000010','c0000000-0000-4000-8000-000000000023','alice@ate.test','Once a year, yes. Weekly, absolutely not.',38),
  ('e0000000-0000-4000-8000-000000000011','c0000000-0000-4000-8000-000000000033','tom@ate.test','Riding to Richmond on Saturday for this.',26)
) as v(id, review_id, email, text, hours_ago)
join auth.users u on u.email = v.email;

-- ===========================================================================
-- 8. Lists. The per-user system "Saved" list already exists (handle_new_user);
--    we add memberships to it, plus two bespoke lists.
-- ===========================================================================
insert into public.lists (id, owner_id, name, description, cover_url, pinned, is_system)
select v.id::uuid, u.id, v.name, v.description, v.cover_url, false, false
from (values
  ('d0000000-0000-4000-8000-000000000001','eamon@ate.test','Melbourne hit list',
   'The order, ranked. Take visitors here.',
   'https://images.unsplash.com/photo-1414235077428-338989a2e8c0?auto=format&fit=crop&w=800&q=70'),
  ('d0000000-0000-4000-8000-000000000002','priya@ate.test','CBD lunch, under an hour',
   'Sit down, eat well, be back at the desk.',
   'https://images.unsplash.com/photo-1552332386-f8dd00dc2f85?auto=format&fit=crop&w=800&q=70')
) as v(id, email, name, description, cover_url)
join auth.users u on u.email = v.email;

-- ranked bespoke lists (position drives the ranked order)
insert into public.list_dishes (list_id, dish_id, position) values
  ('d0000000-0000-4000-8000-000000000001','b0000000-0000-4000-8000-000000000007',1),
  ('d0000000-0000-4000-8000-000000000001','b0000000-0000-4000-8000-000000000015',2),
  ('d0000000-0000-4000-8000-000000000001','b0000000-0000-4000-8000-000000000001',3),
  ('d0000000-0000-4000-8000-000000000001','b0000000-0000-4000-8000-000000000013',4),
  ('d0000000-0000-4000-8000-000000000001','b0000000-0000-4000-8000-000000000019',5),
  ('d0000000-0000-4000-8000-000000000001','b0000000-0000-4000-8000-000000000010',6),
  ('d0000000-0000-4000-8000-000000000002','b0000000-0000-4000-8000-000000000007',1),
  ('d0000000-0000-4000-8000-000000000002','b0000000-0000-4000-8000-000000000002',2),
  ('d0000000-0000-4000-8000-000000000002','b0000000-0000-4000-8000-000000000005',3)
on conflict do nothing;

-- "save = list membership": drop a few into the system "Saved" lists.
insert into public.list_dishes (list_id, dish_id)
select l.id, v.dish_id::uuid
from (values
  ('eamon@ate.test','b0000000-0000-4000-8000-000000000016'),
  ('eamon@ate.test','b0000000-0000-4000-8000-000000000014'),
  ('eamon@ate.test','b0000000-0000-4000-8000-000000000004'),
  ('jess@ate.test', 'b0000000-0000-4000-8000-000000000009'),
  ('jess@ate.test', 'b0000000-0000-4000-8000-000000000001')
) as v(email, dish_id)
join auth.users u on u.email = v.email
join public.lists l on l.owner_id = u.id and l.is_system
on conflict do nothing;

-- ===========================================================================
-- 9. Review tags (2). tagger_id is derived by trg_review_tag_guard (0010); the
--    tagger MUST already follow the tagged user (enforced by that trigger).
--      * tag A: eamon's Chin Chin review tags priya, who responded with her own
--        review of the SAME dish -> the UPDATE guard flips status to 'rated'.
--      * tag B: priya's Kingfish review tags jess -> stays 'pending' (the prompt).
-- ===========================================================================
insert into public.review_tags (review_id, tagged_user_id, tagger_id)
select v.review_id::uuid, t.id, r.reviewer_id  -- trigger re-derives tagger_id anyway
from (values
  ('c0000000-0000-4000-8000-000000000001','priya@ate.test'),
  ('c0000000-0000-4000-8000-000000000010','jess@ate.test')
) as v(review_id, email)
join auth.users t on t.email = v.email
join public.reviews r on r.id = v.review_id::uuid
on conflict do nothing;

-- tag A: record priya's response (trigger stamps responded_at + status='rated')
update public.review_tags
   set responding_review_id = 'c0000000-0000-4000-8000-000000000009'
 where review_id = 'c0000000-0000-4000-8000-000000000001';

-- ===========================================================================
-- 10. Notification read state.
--
--     SCHEMA NOTE: notifications.created_at is IMMUTABLE — trg_notification_update_guard
--     (0011) re-pins id/recipient/actor/type/subject/created_at from OLD on every
--     UPDATE, so a seed CANNOT backdate a notification. Every notification row here
--     therefore carries the seed-run timestamp, not its subject's timestamp. Only
--     read_at / dismissed_at are writable after insert.
--
--     So instead of backdating, we derive read state from the SUBJECT's age: anything
--     about a review older than 7 days is marked read; recent activity and all follow
--     notifications stay unread, giving the badge a realistic non-zero count.
-- ===========================================================================
update public.notifications n
   set read_at = now() - interval '1 day'
 where n.read_at is null
   and exists (
     select 1 from public.reviews r
      where r.id = n.review_id
        and r.created_at < now() - interval '7 days'
   );

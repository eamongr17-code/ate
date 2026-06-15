-- seed.sql
-- Ate backend — Wave 0, BE seed (lead decision E-4: seed data = yes).
-- Grounded in src/data/fixtures.ts so the seeded server exercises the SAME
-- screens the client fixtures do: a following feed, restaurant stat pages
-- (mean-of-per-dish-averages), dish pages, comments, likes, follows, and lists
-- (incl. the system "Saved" list + a ranked bespoke list).
--
-- Scale: 3 users (me + 2 others) · 2 restaurants · 5 dishes · 8 reviews · 1
-- bespoke list, plus the auto-created per-user "Saved" lists.
--
-- AUTH-USERS DEPENDENCY (read the runbook): profiles.id references auth.users(id).
-- This seed creates auth.users rows DIRECTLY (a test-only path) with a known
-- password so the accounts are login-capable in the test project. The
-- handle_new_user trigger (0005) fires on each auth.users insert and creates the
-- matching profiles row + system "Saved" list; we then UPDATE the profile display
-- fields to the curated fixture values. Email confirmation is pre-set so the
-- accounts can sign in immediately.
--
-- Idempotent: re-running deletes the seeded auth.users (cascading profiles +
-- all content) and re-inserts. SAFE ONLY on a test/seed project.
--
-- Test password for all seeded accounts: "atedemo123"

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Fixed UUIDs (so the seed is deterministic + re-runnable)
-- ---------------------------------------------------------------------------
do $$
declare
  u_me        uuid := '00000000-0000-4000-8000-000000000001';
  u_feastfix  uuid := '00000000-0000-4000-8000-000000000002';
  u_smokering uuid := '00000000-0000-4000-8000-000000000003';

  r_goldees   uuid := '00000000-0000-4000-8000-0000000000a1';
  r_smokering uuid := '00000000-0000-4000-8000-0000000000a2';

  d_brisket   uuid := '00000000-0000-4000-8000-0000000000b1'; -- Goldee's
  d_beefrib_g uuid := '00000000-0000-4000-8000-0000000000b2'; -- Goldee's
  d_sausage   uuid := '00000000-0000-4000-8000-0000000000b3'; -- Goldee's
  d_macchz    uuid := '00000000-0000-4000-8000-0000000000b4'; -- Goldee's
  d_beefrib_s uuid := '00000000-0000-4000-8000-0000000000b5'; -- Smoke Ring Co.

  list_bbq    uuid := '00000000-0000-4000-8000-0000000000c1';

  r1 uuid := '00000000-0000-4000-8000-0000000000d1';
  r2 uuid := '00000000-0000-4000-8000-0000000000d2';
  r3 uuid := '00000000-0000-4000-8000-0000000000d3';
  r4 uuid := '00000000-0000-4000-8000-0000000000d4';
  r5 uuid := '00000000-0000-4000-8000-0000000000d5';
  r6 uuid := '00000000-0000-4000-8000-0000000000d6';
  r7 uuid := '00000000-0000-4000-8000-0000000000d7';
  r8 uuid := '00000000-0000-4000-8000-0000000000d8';

  enc_pw text := extensions.crypt('atedemo123', extensions.gen_salt('bf'));
begin
  -- ---- clean prior seed (cascades to profiles + all owned content) ----
  delete from auth.users where id in (u_me, u_feastfix, u_smokering);

  -- ---- auth.users (test-only direct insert; trigger creates profiles) ----
  -- The explicit empty-string token columns + confirmation_token guard against
  -- NOT-NULL defaults that some GoTrue versions enforce on direct auth.users inserts.
  insert into auth.users
    (instance_id, id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at, last_sign_in_at,
     raw_app_meta_data, raw_user_meta_data,
     confirmation_token, recovery_token, email_change_token_new, email_change)
  values
    ('00000000-0000-0000-0000-000000000000', u_me, 'authenticated', 'authenticated',
     'eamon@ate.test', enc_pw, now(), now(), now(), now(),
     '{"provider":"email","providers":["email"]}',
     '{"name":"Eamon","username":"eamon"}', '', '', '', ''),
    ('00000000-0000-0000-0000-000000000000', u_feastfix, 'authenticated', 'authenticated',
     'feastfix@ate.test', enc_pw, now(), now(), now(), now(),
     '{"provider":"email","providers":["email"]}',
     '{"name":"Marisa Vance","username":"feastfix"}', '', '', '', ''),
    ('00000000-0000-0000-0000-000000000000', u_smokering, 'authenticated', 'authenticated',
     'smokering@ate.test', enc_pw, now(), now(), now(), now(),
     '{"provider":"email","providers":["email"]}',
     '{"name":"Cole Whitfield","username":"smokering"}', '', '', '', '');

  -- ---- curate profile display fields (trigger already created the rows) ----
  update public.profiles set bio = 'Brand designer. Logging every dish worth remembering.'
    where id = u_me;
  update public.profiles set bio = 'Eating my way through Texas, one brisket at a time.'
    where id = u_feastfix;
  update public.profiles set bio = 'Low and slow. Backyard pitmaster, weekend reviewer.'
    where id = u_smokering;

  -- ---- restaurants (Places-backed; synthetic place ids for the seed) ----
  insert into public.restaurants (id, google_place_id, name, address, city, location, cuisine, cover_url)
  values
    (r_goldees, 'seed_place_goldees', 'Goldee''s BBQ', '4645 Dick Price Rd', 'Fort Worth, TX',
     extensions.ST_SetSRID(extensions.ST_MakePoint(-97.2078, 32.6543), 4326)::geography, 'Barbecue',
     'https://images.unsplash.com/photo-1558030006-450675393462?auto=format&fit=crop&w=600&q=70'),
    (r_smokering, 'seed_place_smokering', 'Smoke Ring Co.', '1 Pit Row', 'Kansas City, MO',
     extensions.ST_SetSRID(extensions.ST_MakePoint(-94.5786, 39.0997), 4326)::geography, 'Barbecue',
     'https://images.unsplash.com/photo-1529193591184-b1d58069ecdd?auto=format&fit=crop&w=600&q=70');

  -- ---- dishes (UGC; (name, restaurant) identity; two "Beef Rib" across restaurants) ----
  insert into public.dishes (id, name, restaurant_id, created_by_user_id, category, photo_url)
  values
    (d_brisket,   'Smoked Brisket', r_goldees,   u_feastfix,  'Meats',
     'https://images.unsplash.com/photo-1529193591184-b1d58069ecdd?auto=format&fit=crop&w=300&q=70'),
    (d_beefrib_g, 'Beef Rib',       r_goldees,   u_smokering, 'Meats', null),
    (d_sausage,   'Pork Sausage',   r_goldees,   u_me,        'Meats',
     'https://images.unsplash.com/photo-1607103058027-4c5f7a1f5d54?auto=format&fit=crop&w=300&q=70'),
    (d_macchz,    'Mac & Cheese',   r_goldees,   u_feastfix,  'Sides',
     'https://images.unsplash.com/photo-1543339494-b4cd4f7ba686?auto=format&fit=crop&w=300&q=70'),
    (d_beefrib_s, 'Beef Rib',       r_smokering, u_smokering, 'Meats',
     'https://images.unsplash.com/photo-1529193591184-b1d58069ecdd?auto=format&fit=crop&w=300&q=70');

  -- ---- reviews (restaurant_id set by the BIU trigger from dish_id) ----
  -- created_at staggered so the feed + diary order is deterministic (newest first).
  -- NOTE: reviews.score is half-step constrained (data-model §4; matches the real
  -- compose UI which rounds to 0.5). The fixtures' 0.1-granularity display scores
  -- (4.8, 4.6, …) are NOT valid review inputs — they only ever existed as derived
  -- averages. Seed uses valid half-steps. (See runbook "contract divergences".)
  insert into public.reviews (id, reviewer_id, dish_id, restaurant_id, score, note, created_at) values
    (r1, u_feastfix,  d_brisket,   r_goldees,   5.0,
     'The bark is unreal — peppery, deep, and that smoke ring goes forever.', now() - interval '2 days'),
    (r2, u_smokering, d_beefrib_g, r_goldees,   5.0,
     'A single rib the size of a forearm. Render was perfect.',               now() - interval '7 days'),
    (r3, u_feastfix,  d_brisket,   r_goldees,   4.5,
     'Second visit, still flawless. Fatty end is where it lives.',            now() - interval '8 days'),
    (r4, u_smokering, d_macchz,    r_goldees,   4.0,
     'Creamy without being gluey, proper crust on top.',                      now() - interval '9 days'),
    (r5, u_smokering, d_beefrib_s, r_smokering, 4.5,
     'Smoke Ring earns the name — clean, deep ring, no oversmoke.',           now() - interval '11 days'),
    -- me's own diary entries (excluded from the feed; shown in diary)
    (r6, u_me,        d_sausage,   r_goldees,   4.5,
     'Coarse grind, snappy casing, just enough fat.',                         now() - interval '3 days'),
    (r7, u_me,        d_brisket,   r_goldees,   4.5,
     'Worth the queue. The fatty slices are the move.',                       now() - interval '4 days'),
    (r8, u_me,        d_macchz,    r_goldees,   4.0,
     'A real side, not an afterthought.',                                     now() - interval '5 days');

  -- ---- follows: me follows both others; they follow each other a bit ----
  insert into public.follows (follower_id, followee_id) values
    (u_me, u_feastfix), (u_me, u_smokering),
    (u_feastfix, u_smokering), (u_smokering, u_feastfix),
    (u_feastfix, u_me);

  -- ---- likes (drives like_count cache via trigger) ----
  insert into public.review_likes (user_id, review_id) values
    (u_me, r1), (u_smokering, r1), (u_feastfix, r2), (u_me, r2);

  -- ---- comments (drives comment_count cache + the comments sheet) ----
  insert into public.comments (review_id, user_id, text) values
    (r1, u_smokering, 'Bark looks textbook.'),
    (r1, u_me,        'Adding this to the list immediately.'),
    (r2, u_feastfix,  'A forearm is underselling it honestly.');

  -- ---- bespoke list (ranked) + memberships; "save = list membership" demo ----
  insert into public.lists (id, owner_id, name, description, cover_url, pinned, is_system)
  values (list_bbq, u_me, 'BBQ crawl', 'The Goldee''s order, ranked.',
          'https://images.unsplash.com/photo-1558030006-450675393462?auto=format&fit=crop&w=300&q=70',
          false, false);

  insert into public.list_dishes (list_id, dish_id, position) values
    (list_bbq, d_brisket, 1),
    (list_bbq, d_beefrib_g, 2),
    (list_bbq, d_sausage, 3),
    (list_bbq, d_macchz, 4);

  -- me's auto-created "Saved" list (made by the trigger) — drop a couple of saves in it.
  insert into public.list_dishes (list_id, dish_id)
  select l.id, d_brisket from public.lists l where l.owner_id = u_me and l.is_system
  union all
  select l.id, d_beefrib_s from public.lists l where l.owner_id = u_me and l.is_system;
end $$;

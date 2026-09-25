-- 0035_account_integrity.sql
-- Ate backend — three fixes QA found in 0032/0034 (PR #56). 0031–0033 are applied on staging and
-- are never edited; everything here is create-or-replace / drop-and-create-policy on top.
--
--  1. delete_account() COULD REPORT A FALSE SUCCESS. 0032 caught a failed `delete from auth.users`,
--     scrubbed SOME tables by hand and returned `ok: true`. The auth row survived (email, Apple
--     identity — so the person could sign straight back in) and so did their rows in comments,
--     follows, review_likes, comment_likes, review_tags, notifications and lists. Now there is ONE
--     path: delete the auth user, let the FK cascade do the rest, VERIFY nothing personal survived,
--     and RAISE on anything else. A raise aborts the whole statement, so a failure deletes nothing
--     and the client shows an error instead of a lie.
--     The cascade, audited per table (every FK below is `on delete cascade` from auth.users →
--     profiles, or from a row that is): profiles (0002 → auth.users) · entries, entry_photos,
--     reviews (0018/0002) · saves, blocks, reports (0019/0020) · comments, lists, list_dishes
--     (0002/0003) · follows (both sides), review_likes, comment_likes (0003) · review_tags (tagged
--     and tagger, 0010) · notifications (recipient and actor, 0011) · places_rate_limit (0013 →
--     auth.users) · entries_private_before_0033 (→ entries). SET NULL by design, and not personal
--     content: dishes.created_by_user_id, saves.source_user_id (other people's provenance).
--
--  2. handle_new_user() COULD LEAVE A USER WITH NO PROFILE. 0032 swallowed a failed profile insert
--     "for the client's first-run repair" — which does not exist — so a placeholder-handle collision
--     produced an auth user with no `profiles` row, and every later write failed with 23503. Now it
--     retries with fresh placeholders in a bounded loop and NEVER returns without a profile: the only
--     way out without one is to raise, which aborts the sign-up cleanly (no orphan auth user).
--
--  3. DEACTIVATED PROFILES WERE STILL READABLE. `deleted_at` hid a person from search only. Now a
--     deactivated profile, and everything that renders through it, is gone for every other viewer:
--       * signed in — `profiles_select_visible` adds `deleted_at is null` (own row still visible).
--         `profile_summary` then returns no row, and `entry_cards` (INNER JOIN profiles) drops their
--         entries from `get_entries_by_author`, the feed and place lists; `get_dish_reviews` (INNER
--         JOIN) drops their lines; `search_people`/`search_all` already filtered it.
--       * signed out — the `browse.*` twins run as owner (no RLS), so each filters explicitly.
--     Aggregates (scores, counts, covers) are NOT changed: a deactivated account's lines still count
--     in a dish's numbers, exactly as a blocked user's do for everyone who has not blocked them.
--
-- WIRE IMPACT
--   BEHAVIOURAL: delete_account now RAISES where it used to return `auth_user_deleted: false` (the
--     success shape `{ok: true, auth_user_deleted: true}` is unchanged); profile_summary /
--     get_entries_by_author / get_dish_reviews / the feed return FEWER rows when an author is
--     deactivated — treat an absent profile exactly like a blocked one (already required).
--   NOT CHANGED: every signature, OUT list and grant.

set search_path = public, extensions;

-- ===========================================================================
-- 1. delete_account — one path, verified, atomic.
-- ===========================================================================
create or replace function public.delete_account()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_deleted int;
begin
  if v_uid is null then
    raise exception 'delete_account requires an authenticated caller' using errcode = '42501';
  end if;

  -- Everything personal hangs off this row by `on delete cascade` (header of 0035). Any failure
  -- here — privilege, trigger, FK — propagates and rolls the whole call back.
  delete from auth.users where id = v_uid;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 1 then
    raise exception 'delete_account: no auth user % to delete', v_uid using errcode = 'P0002';
  end if;

  -- Verify, don't trust: if a future table forgets its cascade, this refuses to report success —
  -- and, by raising, un-deletes everything above.
  if exists (select 1 from public.profiles       where id = v_uid)
  or exists (select 1 from public.entries        where author_id = v_uid)
  or exists (select 1 from public.reviews        where reviewer_id = v_uid)
  or exists (select 1 from public.saves          where user_id = v_uid)
  or exists (select 1 from public.blocks         where blocker_id = v_uid or blocked_id = v_uid)
  or exists (select 1 from public.reports        where reporter_id = v_uid or profile_id = v_uid)
  or exists (select 1 from public.comments       where user_id = v_uid)
  or exists (select 1 from public.lists          where owner_id = v_uid)
  or exists (select 1 from public.follows        where follower_id = v_uid or followee_id = v_uid)
  or exists (select 1 from public.review_likes   where user_id = v_uid)
  or exists (select 1 from public.comment_likes  where user_id = v_uid)
  or exists (select 1 from public.review_tags    where tagged_user_id = v_uid or tagger_id = v_uid)
  or exists (select 1 from public.notifications  where recipient_id = v_uid or actor_id = v_uid)
  then
    raise exception 'delete_account: personal rows survived the cascade for %', v_uid
      using errcode = 'P0001';
  end if;

  -- Shape unchanged from 0032 so shipped decoders keep working; it can no longer say false.
  return jsonb_build_object('ok', true, 'auth_user_deleted', true);
end; $$;

comment on function public.delete_account() is
  'Deletes the CALLER''S account: the auth user, and by FK cascade every personal row (profile, entries, photos, lines, saves, blocks, reports, comments, lists, follows, likes, tags, notifications). Verifies nothing survived. RAISES on any failure and deletes nothing — never a false success. Returns {ok: true, auth_user_deleted: true}. Storage objects are the client''s to purge first. App Store 5.1.1(v).';

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

-- ===========================================================================
-- 2. handle_new_user — always a profile, or no sign-up at all.
-- ===========================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_local    text;
  v_name     text;
  v_base     text;
  v_username text;
  v_try      int := 0;
begin
  -- The email's local part, only when it is really the person's (never Apple's private relay).
  v_local := case
    when new.email is null then null
    when lower(new.email) like '%@privaterelay.appleid.com' then null
    else nullif(btrim(split_part(new.email, '@', 1)), '')
  end;

  v_name := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    v_local,
    'Ate user'
  );

  v_base := regexp_replace(lower(coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'username'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'preferred_username'), ''),
    v_local,
    ''
  )), '[^a-z0-9_]', '', 'g');
  if v_base = '' then
    v_base := 'ate' || substr(replace(new.id::text, '-', ''), 1, 8);
  end if;
  v_username := left(v_base, 30);

  -- Insert, and on a HANDLE collision try the next candidate: base1..base5, then random
  -- `ate<12 hex>` placeholders. `on conflict (id)` (the PK, a TOTAL constraint) makes a re-fire for
  -- an id that already has a profile a no-op, so the only unique_violation left is the handle.
  -- Bounded; running out RAISES, which aborts the auth insert — an unfinished sign-up the user can
  -- retry, never an account with no profile.
  loop
    begin
      insert into public.profiles (id, username, name, avatar_url, bio)
      values (new.id, v_username::citext, v_name,
              new.raw_user_meta_data ->> 'avatar_url',
              new.raw_user_meta_data ->> 'bio')
      on conflict (id) do nothing;
      exit;
    exception when unique_violation then
      v_try := v_try + 1;
      if v_try > 25 then
        raise exception 'handle_new_user: no free handle for % after % tries', new.id, v_try
          using errcode = '23505';
      end if;
      v_username := case
        when v_try <= 5 then left(v_base, 26) || v_try::text
        else 'ate' || substr(md5(new.id::text || clock_timestamp()::text || v_try::text), 1, 12)
      end;
    end;
  end loop;

  -- The dormant Wave-0 system list: bookkeeping, never a reason to fail a sign-up, and never a
  -- reason to lose the profile above (its own subtransaction).
  begin
    insert into public.lists (owner_id, name, pinned, is_system)
    values (new.id, 'Saved', true, true);
  exception when others then
    raise warning 'handle_new_user: system list insert failed for %: %', new.id, sqlerrm;
  end;

  return new;
end; $$;

comment on function public.handle_new_user() is
  'Provisions profiles (+ the dormant system list) on auth.users insert. Apple-safe (NULL email, relay address → ate<hex> placeholder). ALWAYS leaves a profile: handle collisions retry with fresh placeholders (bounded); anything else raises and aborts the sign-up rather than orphaning the auth user (0035).';

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- ===========================================================================
-- 3a. Signed in — a deactivated profile is visible to its owner only.
-- DROP + CREATE (0019 created it; the block filter is unchanged).
-- ===========================================================================
drop policy if exists profiles_select_visible on public.profiles;
create policy profiles_select_visible on public.profiles
  for select to authenticated
  using (
    id = (select auth.uid())
    or (deleted_at is null and not public.blocked_with(id))
  );

-- ===========================================================================
-- 3b. Signed out — the browse twins run as owner, past RLS, so each says it explicitly.
-- Same signatures and OUT lists as 0034: create-or-replace, grants survive.
-- ===========================================================================
create or replace function browse.get_entry_feed(
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int,
  p_include_own       boolean
)
returns setof public.entry_cards
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.*
  from public.get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, true) c
  cross join lateral jsonb_populate_record(c, '{"is_mine": false}'::jsonb) r
  where c.visibility = 'public'
    and exists (select 1 from public.profiles p where p.id = c.author_id and p.deleted_at is null)
  order by r.created_at desc, r.id desc;
$$;

create or replace function browse.get_entries_by_author(
  p_author_id         uuid,
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int
)
returns setof public.entry_cards
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.*
  from public.get_entries_by_author(p_author_id, p_cursor_created_at, p_cursor_id, p_page_size) c
  cross join lateral jsonb_populate_record(c, '{"is_mine": false}'::jsonb) r
  where c.visibility = 'public'
    and exists (select 1 from public.profiles p where p.id = c.author_id and p.deleted_at is null)
  order by r.created_at desc, r.id desc;
$$;

create or replace function browse.get_entries_at_place(
  p_restaurant_id     uuid,
  p_scope             text,
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int
)
returns setof public.entry_cards
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.*
  from public.get_entries_at_place(p_restaurant_id, 'all', p_cursor_created_at, p_cursor_id, p_page_size) c
  cross join lateral jsonb_populate_record(c, '{"is_mine": false}'::jsonb) r
  where c.visibility = 'public'
    and p_scope is distinct from 'mine'
    and exists (select 1 from public.profiles p where p.id = c.author_id and p.deleted_at is null)
  order by r.created_at desc, r.id desc;
$$;

create or replace function browse.get_dish_reviews(
  p_dish_id           uuid,
  p_cursor_mine       boolean,
  p_cursor_created_at timestamptz,
  p_cursor_id         uuid,
  p_page_size         int
)
returns table (
  review_id  uuid,
  entry_id   uuid,
  author     jsonb,
  score      numeric(2,1),
  note       text,
  created_at timestamptz,
  is_mine    boolean,
  photos     jsonb
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select v.review_id, v.entry_id, v.author, v.score, v.note, v.created_at,
         false,                                        -- is_mine: no viewer
         v.photos
  from public.get_dish_reviews(p_dish_id, false, p_cursor_created_at, p_cursor_id, p_page_size) v
  where exists (
    select 1 from public.profiles p
    where p.id = (v.author ->> 'id')::uuid and p.deleted_at is null
  )
  order by v.created_at desc, v.review_id desc;
$$;

create or replace function browse.profile_summary(p_user_id uuid)
returns table (
  user_id      uuid,
  username     citext,
  name         text,
  avatar_url   text,
  bio          text,
  city         text,
  created_at   timestamptz,
  orders       int,
  places       int,
  dishes       int,
  scored       int,
  avg_score    numeric(3,2),
  is_me        boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select s.user_id, s.username, s.name, s.avatar_url, s.bio, s.city, s.created_at,
         s.orders, s.places, s.dishes, s.scored, s.avg_score,
         false                                         -- is_me: no viewer
  from public.profile_summary(p_user_id) s
  where exists (select 1 from public.profiles p where p.id = s.user_id and p.deleted_at is null);
$$;

-- 0032_apple_auth_account_blocks.sql
-- Ate backend — what Sign in with Apple and the Settings page need from the database:
-- an identity with NO email and NO name must still become a usable account, deleting an account
-- must actually delete it (App Store guideline 5.1.1(v)), and the blocked-people list must be able
-- to print a handle and a face.
--
-- WHAT THE AUDIT FOUND:
--
--  1. `handle_new_user` (0005) SURVIVES an Apple identity but produces junk from it. It derives both
--     the name and the handle from `split_part(new.email, '@', 1)`, and a native Apple sign-in gives
--     us either no email at all (NULL — the coalesce chain already handles that, so sign-up does not
--     fail) or Apple's PRIVATE RELAY address. The relay case is the bad one: it sails through every
--     guard and mints a handle out of Apple's opaque local part (`@k7f2h9x4m1`). Both cases are
--     handled explicitly now, and the trigger can no longer abort a sign-up for ANY reason — an
--     exception here is "Database error saving new user" at the Apple sheet, which is
--     unrecoverable from the app. It logs and lets the auth user through instead; the client's
--     first-run repair (`profiles_insert_self`, 0004) covers the rest.
--
--  2. `deactivate_account` (0005) IS NOT ACCOUNT DELETION. It sets `profiles.deleted_at` and stops.
--     The auth user survives, so the same Apple ID signs straight back into a live account with
--     every entry, photo and score still there, and nothing in V1 even reads the tombstone except
--     `search_all`'s people branch. Apple requires an in-app path that DELETES the account. That is
--     `delete_account()` below. `deactivate_account` is left in place, unedited (it is applied, and
--     applied migrations are never edited) and re-commented so nobody mistakes it for the one.
--
--  3. THE BLOCKED LIST COULD NOT RENDER. `blocks` IS readable by its blocker (`blocks_select_own`,
--     0019 — confirmed, no change needed), but the obvious PostgREST embed
--     `blocks?select=blocked_id,profiles(username,avatar_url)` returns NULL for every row: the
--     profiles SELECT policy is `id = auth.uid() or not blocked_with(id)`, and a person you blocked
--     is BY DEFINITION `blocked_with`. So Settings would print a list of UUIDs. `my_blocks()` is a
--     SECURITY DEFINER read scoped to `blocker_id = auth.uid()` — the same justified escalation as
--     `handle_available` (0019): it can only ever reveal the caller's own relationships.
--
--  4. `handle_available` (0019) IS ALREADY CASE-INSENSITIVE — verified, not changed.
--     `profiles.username` is `citext`, so `p.username = btrim(p_handle)::citext` compares
--     case-insensitively, and the UNIQUE index behind it is case-insensitive too, so the check and
--     the insert agree. It does NOT validate the character set (only length 1–30); the client owns
--     that rule. A contract test pins the case-insensitivity so a future "optimisation" to a plain
--     `=` on text cannot quietly reopen it.
--
-- WIRE IMPACT
--   ADDITIVE: RPCs `delete_account()` and `my_blocks(p_limit, p_cursor_created_at,
--     p_cursor_blocked_id)`. Nothing existing is renamed, retyped or removed.
--   BEHAVIOURAL: `handle_new_user` picks different DEFAULT names/handles for an identity with no
--     usable email (`ate<8 hex>` instead of `user`/`user1`), and never derives one from an Apple
--     private-relay address. It only ever affected rows it creates at sign-up; no existing profile
--     changes.
--   NOT CHANGED: `deactivate_account`, `handle_available`, `blocks` and its policies, every grant.
--
-- DELETION SEMANTICS (the privacy stance, docs/PRODUCT.md: "the user's words are sacred" — they are
-- the USER'S, so they leave with them):
--   GONE — the auth user, the profile, every entry and its photos, every review line (including
--     pre-entries ones), saves, blocks, reports, and the dormant-table rows. One `delete from
--     auth.users` does all of it through FKs that were already `on delete cascade`.
--   KEPT — `restaurants` and `dishes`, the shared catalogue. `dishes.created_by_user_id` is
--     `on delete set null` (0002), so a dish other people have reviewed survives with no
--     attribution. A menu is not personal data; the scores on it were, and those go.
--   NOT COVERED BY SQL — the objects in `review-photos/<uid>/` and `avatars/<uid>/`. A storage row
--     delete does not free the bytes; the client must purge its own folders FIRST (it has
--     `*_list_own` + `*_delete_own` on both buckets, 0007/0008), THEN call this, THEN sign out.
--     Written down in integration-design.md as the required order.

set search_path = public, extensions;

-- ===========================================================================
-- 1. handle_new_user — Apple-safe new-user provisioning.
--
-- Three things a native Apple identity does that an email sign-up never did:
--   * `new.email` can be NULL. Every derivation coalesces past it.
--   * `new.email` can be `<opaque>@privaterelay.appleid.com`. That local part is Apple's, not the
--     person's, and it must never become their public handle.
--   * `raw_user_meta_data` usually carries NO name (Apple returns the name only in the initial
--     ASAuthorization credential, which `signInWithIdToken` has no room for). The app sets the real
--     name and handle on the first-run Handle screen; what this trigger writes is a placeholder
--     that must be legal, unique and not embarrassing.
--
-- AND IT MUST NOT RAISE. A raise here aborts the auth.users insert, which surfaces at the Apple
-- sheet as "Database error saving new user" with no way forward for the user. Every failure path
-- logs a warning and returns NEW.
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
  v_username citext;
  v_try      int := 0;
begin
  -- The email's local part, but only when it is really the person's. Apple's private relay is an
  -- opaque per-app identifier; deriving a handle from it leaks nothing but reads like a bug.
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

  v_base := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'username'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'preferred_username'), ''),
    v_local,
    ''
  );
  -- sanitise to a handle-safe slug
  v_base := regexp_replace(lower(v_base), '[^a-z0-9_]', '', 'g');
  -- No usable source (an Apple identity with a relay address or no email at all): a stable,
  -- collision-proof placeholder derived from the user id, not 'user'/'user1'/'user2'.
  if v_base = '' then
    v_base := 'ate' || substr(replace(new.id::text, '-', ''), 1, 8);
  end if;
  v_username := left(v_base, 30);

  -- Ensure uniqueness. Bounded, unlike the original unbounded loop, and the fallback is the id
  -- itself — which cannot collide with anything but itself.
  while v_try < 20 and exists (select 1 from public.profiles where username = v_username) loop
    v_try := v_try + 1;
    v_username := left(v_base, 26) || v_try::text;
  end loop;
  if exists (select 1 from public.profiles where username = v_username) then
    v_username := left('ate' || replace(new.id::text, '-', ''), 30);
  end if;

  begin
    insert into public.profiles (id, username, name, avatar_url, bio)
    values (new.id, v_username, v_name,
            new.raw_user_meta_data ->> 'avatar_url',
            new.raw_user_meta_data ->> 'bio');
  exception when others then
    -- A sign-in that cannot be completed is worse than a profile the client has to repair
    -- (profiles_insert_self, 0004). Never abort the auth insert.
    raise warning 'handle_new_user: profile insert failed for % (%): %', new.id, sqlstate, sqlerrm;
    return new;
  end;

  -- The dormant Wave-0 system list. V1 stores saves in `saves`, so this is bookkeeping and must
  -- never be the reason a sign-up fails.
  begin
    insert into public.lists (owner_id, name, pinned, is_system)
    values (new.id, 'Saved', true, true);
  exception when others then
    raise warning 'handle_new_user: system list insert failed for %: %', new.id, sqlerrm;
  end;

  return new;
end; $$;

comment on function public.handle_new_user() is
  'Provisions profiles (+ the dormant system list) on auth.users insert. Apple-safe: copes with a NULL email, never derives a handle from an @privaterelay.appleid.com address, and CANNOT raise — an exception here is an unrecoverable "Database error saving new user" at the Apple sheet.';

-- The trigger itself is unchanged (0005 created it); restated so a fresh database and an existing
-- one end up identical.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- ===========================================================================
-- 2. delete_account — the App Store path (guideline 5.1.1(v): account deletion, not deactivation).
--
-- ONE statement does the whole job in the happy case: `delete from auth.users` cascades to
-- `profiles` (0002) and from there to entries (→ entry_photos, → their reviews), reviews, saves,
-- blocks, reports, notifications and the dormant edge tables — every FK to `profiles` is already
-- `on delete cascade` except the two that must NOT be (`dishes.created_by_user_id` and
-- `saves.source_user_id`, both `set null`, which is what keeps the shared catalogue and other
-- people's provenance intact).
--
-- SECURITY DEFINER because `auth.users` is not the caller's to delete, and the only id it will ever
-- touch is `auth.uid()`'s own. It takes no parameters, on purpose: there is no way to ask it to
-- delete somebody else.
--
-- THE FALLBACK, and why it exists: the delete depends on the function owner's rights on
-- `auth.users`. If that ever fails (a privilege change on the auth schema), the exception block
-- does the equivalent by hand — scrub the identity, free the handle, delete the content — so the
-- user's data is gone either way and the RETURN VALUE says which happened. The client should treat
-- `ok = true` as done and report `auth_user_deleted = false` to us: it means the account can still
-- be signed into (a fresh, empty profile), and we owe the lead an edge function using
-- `auth.admin.deleteUser`.
-- ===========================================================================
create or replace function public.delete_account()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_uid          uuid := (select auth.uid());
  v_auth_deleted boolean := false;
begin
  if v_uid is null then
    raise exception 'delete_account requires an authenticated caller' using errcode = '42501';
  end if;

  begin
    delete from auth.users where id = v_uid;
    v_auth_deleted := true;
  exception when others then
    raise warning 'delete_account: auth.users delete failed for % (%): %', v_uid, sqlstate, sqlerrm;
    v_auth_deleted := false;
  end;

  if not v_auth_deleted then
    -- Identity first: whatever else happens, nothing identifiable is left and the handle goes back
    -- into the pool.
    update public.profiles
       set username   = left('deleted_' || replace(v_uid::text, '-', ''), 30)::citext,
           name       = 'Deleted account',
           avatar_url = null,
           bio        = null,
           city       = null,
           deleted_at = coalesce(deleted_at, now())
     where id = v_uid;

    -- Then the content, in the same order the cascade would have taken it.
    delete from public.entries where author_id   = v_uid;  -- cascades entry_photos + its reviews
    delete from public.reviews where reviewer_id = v_uid;  -- pre-entries lines have no entry above them
    delete from public.saves   where user_id     = v_uid;
    delete from public.blocks  where blocker_id  = v_uid or blocked_id = v_uid;
    delete from public.reports where reporter_id = v_uid or profile_id = v_uid;
  end if;

  return jsonb_build_object('ok', true, 'auth_user_deleted', v_auth_deleted);
end; $$;

comment on function public.delete_account() is
  'Deletes the CALLER''S account: auth user + profile + entries + photos + review lines + saves + blocks + reports, by FK cascade. Keeps the shared catalogue (dishes.created_by_user_id is set-null). Returns {ok, auth_user_deleted}; false there means the auth row survived and needs the admin API. Storage objects are the client''s to purge first. This is the App Store 5.1.1(v) path — deactivate_account is NOT.';

comment on function public.deactivate_account() is
  'SOFT-delete: tombstones the caller''s profile (deleted_at) and nothing else. NOT account deletion — the auth user survives and can sign straight back in. App Store account deletion is delete_account() (0032). Kept for the "hide me for now" case; nothing in V1 calls it.';

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

-- ===========================================================================
-- 3. my_blocks — the Settings list of people you blocked, with a handle and a face.
--
-- DEFINER for one specific reason (finding 3): `profiles_select_visible` hides exactly the people
-- this list is about, so no invoker-side join or PostgREST embed can name them. Scoped to
-- `blocker_id = auth.uid()` with no parameter that could widen it, so it reveals only the caller's
-- own relationships — the same argument that makes `handle_available` definer.
--
-- Deliberately one-way: it lists whom YOU blocked, never who blocked you (0019's choice, unchanged).
-- Tombstoned profiles are INCLUDED — you blocked a person, and the row has to stay unblockable-able
-- until you unblock it.
-- KEYSET (2 parts): created_at, blocked_id — newest block first.
-- ===========================================================================
drop function if exists public.my_blocks(int, timestamptz, uuid);

create function public.my_blocks(
  p_limit             int         default 50,
  p_cursor_created_at timestamptz default null,
  p_cursor_blocked_id uuid        default null
)
returns table (
  blocked_id uuid,
  username   citext,
  name       text,
  avatar_url text,
  city       text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select
    b.blocked_id,
    p.username,
    p.name,
    nullif(btrim(coalesce(p.avatar_url, '')), ''),
    nullif(btrim(coalesce(p.city, '')), ''),
    b.created_at
  from public.blocks b
  left join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = (select auth.uid())
    and (
      p_cursor_blocked_id is null
      or (b.created_at, b.blocked_id) < (p_cursor_created_at, p_cursor_blocked_id)
    )
  order by b.created_at desc, b.blocked_id desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

comment on function public.my_blocks(int, timestamptz, uuid) is
  'Whom the caller blocked, with handle/name/avatar for design/v1/Settings. DEFINER because the profiles SELECT policy hides precisely these people from precisely this viewer, so an embed returns nulls. Scoped to blocker_id = auth.uid(). Unblock with unblock_user(). Keyset (created_at, blocked_id).';

revoke all on function public.my_blocks(int, timestamptz, uuid) from public, anon;
grant execute on function public.my_blocks(int, timestamptz, uuid) to authenticated;

-- 0008_harden_security.sql
-- Ate backend — Wave 0 follow-up: security-advisor WARN-level hardening.
-- The Wave 0 advisor returned ZERO errors; this migration closes the three
-- WARN findings (SECURITY DEFINER triggers exposed as RPC, an always-true
-- restaurant INSERT policy, and a bucket-wide public LIST policy).
--
-- Idempotent where sensible (REVOKE / DROP POLICY IF EXISTS / CREATE-after-DROP).
-- Forward-only; no applied migration is edited or reordered.
--
-- NOT covered here (auth project SETTING, not SQL — applied via dashboard/Mgmt API):
--   leaked-password protection (HaveIBeenPwned). This is an Auth project setting,
--   not a schema object, so it lives outside migration SQL.
--   HOW TO ENABLE: Dashboard → Authentication → Providers → Email → toggle ON
--     "Prevent sign-ups/updates with leaked passwords" (the HaveIBeenPwned check),
--   OR Management API:
--     PATCH https://api.supabase.com/v1/projects/{ref}/config/auth
--     Authorization: Bearer <SUPABASE_ACCESS_TOKEN>
--     { "password_hibp_enabled": true }
--   VERIFY: `get_advisors(type=security)` should no longer flag
--     "leaked_password_protection" / auth_leaked_password_protection.
--   STATUS (ONB-BE-2, 2026-06-17): the toggle requires Management-API/MCP access
--   the BE engineer does not hold locally (anon key only). Owner-applied via MCP
--   (lead) or dashboard (Eamon); flip then re-run get_advisors to confirm clear.

set search_path = public, extensions;

-- ===========================================================================
-- FINDING 1 (primary) — trigger functions are SECURITY DEFINER in `public` and
-- are therefore exposed as callable RPC endpoints (/rest/v1/rpc/<fn>) to anon +
-- authenticated. They only ever need to fire AS TRIGGERS. Revoke EXECUTE from
-- the public-facing roles so they are not reachable as RPCs.
--
-- WHY THIS DOES NOT STOP THE TRIGGERS FIRING:
--   Trigger invocation runs the function as the table owner under the trigger
--   machinery — it does NOT perform a SQL-level EXECUTE privilege check against
--   the *caller's* role. EXECUTE privilege gates direct callers (RPC, SELECT fn()),
--   not the trigger dispatcher. Postgres revoking EXECUTE on a trigger function
--   has no effect on its firing as an AFTER/BEFORE trigger. (Verified intent:
--   QA's allow-test = perform the INSERT/DELETE that fires each trigger and
--   confirm the cached counter still updates after this migration.)
--
-- Note: PostgREST only exposes functions EXECUTE-able by anon/authenticated, so
-- revoking from those roles also removes them from the exposed RPC surface.
-- We additionally revoke from PUBLIC so no future role inherits EXECUTE.
-- ===========================================================================

revoke execute on function public.handle_new_user()            from public, anon, authenticated;
revoke execute on function public.trg_review_like_count()      from public, anon, authenticated;
revoke execute on function public.trg_review_comment_count()   from public, anon, authenticated;
revoke execute on function public.trg_comment_like_count()     from public, anon, authenticated;
revoke execute on function public.trg_follow_counts()          from public, anon, authenticated;
revoke execute on function public.trg_review_author_count()    from public, anon, authenticated;
revoke execute on function public.trg_review_set_restaurant()  from public, anon, authenticated;

-- ===========================================================================
-- FINDING 2 — restaurants_insert_authed was WITH CHECK (true): any authenticated
-- user could insert an arbitrary restaurant row directly through RLS.
--
-- DECISION: DROP the end-user INSERT policy entirely.
-- REASONING:
--   * Per the data model (§1.2/§3/§5), restaurants are Google-Places-backed
--     reference data. The ONLY write path is "resolve a Google Place → upsert by
--     google_place_id", performed server-side by the `places-search` edge
--     function using the SERVICE ROLE, which bypasses RLS. That path does not
--     depend on this policy and is unaffected by the drop.
--   * The client never inserts restaurants directly — confirmed against the
--     client data layer (src/data/: no `from('restaurants').insert/upsert`; the
--     only upsert in store.ts is the local draft cache, store.ts:251). So nothing
--     in the live contract needs a direct authed restaurant insert.
--   * Leaving WITH CHECK (true) would let any signed-in user mint uncurated
--     restaurant rows (bypassing Places resolution), fragmenting the catalogue —
--     exactly what the curated-import model exists to prevent.
--   * With this policy gone and no INSERT policy present, RLS is deny-by-default:
--     authenticated/anon cannot insert restaurants. SELECT (public read) is
--     unchanged; the service-role upsert is unchanged.
-- ===========================================================================

drop policy if exists restaurants_insert_authed on public.restaurants;

-- ===========================================================================
-- FINDING 3 — public-read storage policies (avatars, review-photos) used
-- `for select to public using (bucket_id = '…')`, which grants bucket-wide
-- LIST/enumeration, not just object reads.
--
-- DECISION: scope the public read so it cannot list the bucket; replace the
-- broad public SELECT with an authenticated, OWN-FOLDER-ONLY listing policy.
-- REASONING:
--   * The `*_url` columns store durable PUBLIC CDN object URLs (data-model
--     §6, lines 319-321). Fetching a known public object URL is served by the
--     bucket's `public = true` flag via /storage/v1/object/public/<bucket>/<path>
--     and does NOT consult a SELECT policy at all — so public object read keeps
--     working after we remove the `to public` SELECT policy.
--   * The SELECT policy on storage.objects is what powers LIST/enumeration (and
--     SDK metadata GET). Granting that `to public` let anyone enumerate every
--     object key in the bucket — unnecessary for serving URLs and a leak of the
--     object namespace. We replace it with a policy that lets an AUTHENTICATED
--     user list only objects under their own auth.uid()/ prefix (matching the
--     insert/update/delete owner scoping already in 0007). This supports a user
--     managing their own uploads without exposing bucket-wide listing.
-- ===========================================================================

-- review-photos: drop the bucket-wide public LIST, add own-folder listing.
drop policy if exists "review_photos_public_read" on storage.objects;

create policy "review_photos_list_own" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'review-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- avatars: drop the bucket-wide public LIST, add own-folder listing.
drop policy if exists "avatars_public_read" on storage.objects;

create policy "avatars_list_own" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

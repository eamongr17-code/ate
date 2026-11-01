-- 0100_security_hygiene.sql — the 1 Nov 2026 security sweep (thread "Run full security sweep").
--
-- Nothing here changes what the app can do. Three things:
--
-- 1. New objects are closed by default. Prod still carries Supabase's old default privileges: every
--    new table in public is granted to anon + authenticated (all privileges) and every new function
--    is executable by PUBLIC, so one migration that forgets RLS or a revoke opens a table or an RPC
--    to the internet. Supabase made "no automatic grants" the default for new projects on 30 Oct;
--    this makes prod, staging and the local stack agree with that. From here on a migration must
--    GRANT what the app needs (every recent one already does), and a forgotten grant fails loudly
--    in CI instead of leaking quietly.
-- 2. Trigger functions are not RPCs. Five were left executable by anon/authenticated through
--    /rest/v1/rpc (Postgres refuses to run a trigger function outside a trigger, so nothing could be
--    done with them; this is hygiene the linter flags). Two constant functions get a fixed search_path.
-- 3. Foreign keys without an index (production-readiness audit, 15 Oct, plus the ones added since).
--    Each one makes a delete on the parent table scan the child: a deleted account scans user_awards
--    and ate_with_ledger, a dish merge scans the merge tables. Small now, linear in rows later.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Closed by default (objects created by postgres, which is who runs migrations)
-- ---------------------------------------------------------------------------
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated;
-- PUBLIC's EXECUTE on new functions is a global default: a per-schema line cannot take it away.
alter default privileges for role postgres
  revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- 2. Trigger functions out of the API; fixed search_path on two constants
-- ---------------------------------------------------------------------------
revoke all on function public.entry_photo_left()       from public, anon, authenticated;
revoke all on function public.photo_also_forget()      from public, anon, authenticated;
revoke all on function public.restaurants_clean_name() from public, anon, authenticated;
revoke all on function public.trg_client_image_url()   from public, anon, authenticated;
revoke all on function public.trg_report_budget()      from public, anon, authenticated;

alter function public.suggestion_radius_m() set search_path = public, extensions;
alter function public.award_day_zone()      set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 3. Indexes on unindexed foreign keys
-- ---------------------------------------------------------------------------
create index if not exists ate_with_ledger_recipient_idx        on public.ate_with_ledger (recipient_id);
create index if not exists chains_anchor_restaurant_idx         on public.chains (anchor_restaurant_id);
create index if not exists dish_merge_proposals_target_idx      on public.dish_merge_proposals (target_dish_id);
create index if not exists dish_merge_proposals_restaurant_idx  on public.dish_merge_proposals (restaurant_id);
create index if not exists dish_merge_proposals_merge_idx       on public.dish_merge_proposals (merge_id);
create index if not exists dish_merges_restaurant_idx           on public.dish_merges (restaurant_id);
create index if not exists dish_pair_verdicts_dish_b_idx        on public.dish_pair_verdicts (dish_b);
create index if not exists entry_companions_invite_idx          on public.entry_companions (invite_id);
create index if not exists entry_invites_redeemed_by_idx        on public.entry_invites (redeemed_by);
create index if not exists user_awards_entry_idx                on public.user_awards (entry_id);
create index if not exists user_awards_dish_idx                 on public.user_awards (dish_id);
create index if not exists user_awards_other_user_idx           on public.user_awards (other_user_id);

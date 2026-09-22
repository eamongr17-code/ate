-- 0019_moderation.sql
-- Ate backend — V1 RETHINK: the two things an invite-only cohort of 20-50 cannot
-- ship without — REPORT (an entry or a profile) and BLOCK (user → user).
--
-- The requirement is "blocked users vanish from feed/place/dish reads BOTH WAYS".
-- That is enforced in RLS, not in each query, because there are six read paths to
-- the same rows (feed, journal, profile, place page, dish page, search) and any one
-- of them forgetting the filter is a leak. One policy per table, one helper.
--
-- HELPER: blocked_with(other) — true when EITHER direction of a block exists
-- between the caller and `other`. SECURITY DEFINER so it can read `blocks` without
-- being subject to the blocks SELECT policy (which is caller-scoped) — this also
-- avoids any policy-recursion risk. It only ever reveals the CALLER'S OWN
-- relationships, so definer leaks nothing.
--
-- WIRE IMPACT:
--   ADDITIVE : tables `blocks`, `reports`; RPCs `blocked_with`, `block_user`,
--              `unblock_user`, `report_entry`, `report_profile`, `handle_available`.
--   BEHAVIOURAL (not a shape change, annotate for iOS): the SELECT policies on
--              `profiles`, `entries` and `reviews` now RETURN FEWER ROWS once a
--              block exists. No column moves; a blocked user's rows simply are not
--              there. Clients must tolerate a profile/author being absent (render
--              the row as unavailable rather than crash on a nil join).
--
-- Forward-only. `comments`, `review_likes`, `comment_likes`, `lists`, `list_dishes`
-- and `follows` are DORMANT in V1 (no likes, no follows) and are deliberately left
-- exactly as they are.

set search_path = public, extensions;

-- ===========================================================================
-- blocks — user → user. Symmetric in EFFECT (both directions vanish), asymmetric
-- in RECORD (we keep who blocked whom, because unblock is the blocker's to do).
-- ===========================================================================
create table public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocks_no_self check (blocker_id <> blocked_id)
);

comment on table public.blocks is
  'user→user block. Enforced in the SELECT policies of profiles/entries/reviews, both directions (V1 moderation).';

create index blocks_blocked_idx on public.blocks (blocked_id);

-- ===========================================================================
-- reports — an entry OR a profile, exactly one. Triage is manual (service role /
-- SQL) for a 20-50 cohort; there is no moderation UI and no admin role yet.
-- ===========================================================================
create table public.reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  entry_id    uuid references public.entries(id)  on delete cascade,
  profile_id  uuid references public.profiles(id) on delete cascade,
  reason      text,
  note        text,
  status      text not null default 'open',
  created_at  timestamptz not null default now(),
  constraint reports_one_target_ck check (
    (entry_id is not null and profile_id is null)
    or (entry_id is null and profile_id is not null)
  ),
  constraint reports_status_ck check (status in ('open', 'actioned', 'dismissed'))
);

comment on table public.reports is
  'Report an entry or a profile. Reporter-visible only; triaged manually via service role (V1 moderation).';

create index reports_open_idx     on public.reports (created_at desc) where status = 'open';
create index reports_reporter_idx on public.reports (reporter_id, created_at desc);
create index reports_entry_idx    on public.reports (entry_id)   where entry_id is not null;
create index reports_profile_idx  on public.reports (profile_id) where profile_id is not null;

-- ===========================================================================
-- blocked_with — the one place the both-ways rule is expressed.
-- ===========================================================================
create or replace function public.blocked_with(p_other uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from public.blocks b
    where (b.blocker_id = (select auth.uid()) and b.blocked_id = p_other)
       or (b.blocker_id = p_other            and b.blocked_id = (select auth.uid()))
  );
$$;

comment on function public.blocked_with(uuid) is
  'True when a block exists in EITHER direction between the caller and p_other. The single expression of the both-ways rule; used by the profiles/entries/reviews SELECT policies.';

revoke all on function public.blocked_with(uuid) from public, anon;
grant execute on function public.blocked_with(uuid) to authenticated, service_role;

-- ===========================================================================
-- RLS — blocks + reports
-- ===========================================================================
alter table public.blocks  enable row level security;
alter table public.reports enable row level security;

-- A user sees the blocks they created (so the Settings list can render) and may
-- create/remove only their own. They deliberately CANNOT see who blocked them.
create policy blocks_select_own on public.blocks
  for select to authenticated using (blocker_id = (select auth.uid()));

create policy blocks_insert_own on public.blocks
  for insert to authenticated with check (blocker_id = (select auth.uid()));

create policy blocks_delete_own on public.blocks
  for delete to authenticated using (blocker_id = (select auth.uid()));

create policy reports_select_own on public.reports
  for select to authenticated using (reporter_id = (select auth.uid()));

create policy reports_insert_own on public.reports
  for insert to authenticated with check (reporter_id = (select auth.uid()));

-- no UPDATE/DELETE policy: a report is a fact, not an editable row. Triage happens
-- with the service role.

revoke all on public.blocks  from anon;
revoke all on public.reports from anon;
grant select, insert, delete on public.blocks  to authenticated;
grant select, insert         on public.reports to authenticated;
grant all on public.blocks  to service_role;
grant all on public.reports to service_role;

-- ===========================================================================
-- THE BOTH-WAYS FILTER — replace three SELECT policies.
--
-- Each is DROP + CREATE (forward-only; the dropped policies were created in 0004).
-- "own rows always" comes first in every predicate so a user can never lose sight
-- of their own content through someone else's action.
-- ===========================================================================

-- profiles: a blocked user's profile is gone both ways.
drop policy if exists profiles_select_all on public.profiles;
create policy profiles_select_visible on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or not public.blocked_with(id));

-- entries: own always; others' only when public AND not blocked.
drop policy if exists entries_select_visible on public.entries;
create policy entries_select_visible on public.entries
  for select to authenticated
  using (
    author_id = (select auth.uid())
    or (visibility = 'public' and not public.blocked_with(author_id))
  );

-- reviews: own always; others' only when not blocked AND — when the review belongs
-- to an entry — that entry is public. This is what stops a PRIVATE entry's dish
-- reviews leaking onto a public dish or place page. Legacy reviews (entry_id NULL)
-- keep their previous world-readable behaviour.
drop policy if exists reviews_select_all on public.reviews;
create policy reviews_select_visible on public.reviews
  for select to authenticated
  using (
    reviewer_id = (select auth.uid())
    or (
      not public.blocked_with(reviewer_id)
      and (
        entry_id is null
        or exists (
          select 1 from public.entries e
          where e.id = reviews.entry_id and e.visibility = 'public'
        )
      )
    )
  );

-- ===========================================================================
-- MUTATIONS — thin RPCs so the client has one call per action and the Actions
-- sheet (design/v1/Actions.dc.html: Save · Share · Report · Block) maps 1:1.
-- Each is SECURITY INVOKER: RLS above is already exactly right, so there is
-- nothing to escalate.
-- ===========================================================================
create or replace function public.block_user(p_user_id uuid)
returns void language sql volatile security invoker
set search_path = public, extensions as $$
  insert into public.blocks (blocker_id, blocked_id)
  values ((select auth.uid()), p_user_id)
  on conflict (blocker_id, blocked_id) do nothing;
$$;

-- NOTE on the ON CONFLICT above: blocks' PK is a TOTAL unique constraint on exactly
-- those two columns, which is what makes this legal. (0014/0016: never aim
-- ON CONFLICT at a PARTIAL index.)

create or replace function public.unblock_user(p_user_id uuid)
returns void language sql volatile security invoker
set search_path = public, extensions as $$
  delete from public.blocks
  where blocker_id = (select auth.uid()) and blocked_id = p_user_id;
$$;

create or replace function public.report_entry(p_entry_id uuid, p_reason text default null, p_note text default null)
returns uuid language sql volatile security invoker
set search_path = public, extensions as $$
  insert into public.reports (reporter_id, entry_id, reason, note)
  values ((select auth.uid()), p_entry_id, nullif(btrim(coalesce(p_reason, '')), ''), nullif(btrim(coalesce(p_note, '')), ''))
  returning id;
$$;

create or replace function public.report_profile(p_user_id uuid, p_reason text default null, p_note text default null)
returns uuid language sql volatile security invoker
set search_path = public, extensions as $$
  insert into public.reports (reporter_id, profile_id, reason, note)
  values ((select auth.uid()), p_user_id, nullif(btrim(coalesce(p_reason, '')), ''), nullif(btrim(coalesce(p_note, '')), ''))
  returning id;
$$;

-- ===========================================================================
-- handle_available — first-run handle check (design/v1/Handle.dc.html).
-- SECURITY DEFINER on purpose: the profiles SELECT policy now hides blocked users,
-- so a plain client-side `select … where username = ?` would report a TAKEN handle
-- as free and the insert would then fail on the unique index. This reads past RLS
-- to answer only a boolean about a handle — no row, no identity, is returned.
-- ===========================================================================
create or replace function public.handle_available(p_handle text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select case
    when length(btrim(coalesce(p_handle, ''))) between 1 and 30
      then not exists (select 1 from public.profiles p where p.username = btrim(p_handle)::citext)
    else false
  end;
$$;

comment on function public.handle_available(text) is
  'True when a handle is free and 1-30 chars. DEFINER so the block-aware profiles policy cannot make a taken handle look available.';

revoke all on function public.handle_available(text) from public, anon;
grant execute on function public.handle_available(text) to authenticated, service_role;

revoke all on function public.block_user(uuid)                  from public, anon;
revoke all on function public.unblock_user(uuid)                from public, anon;
revoke all on function public.report_entry(uuid, text, text)    from public, anon;
revoke all on function public.report_profile(uuid, text, text)  from public, anon;
grant execute on function public.block_user(uuid)                 to authenticated;
grant execute on function public.unblock_user(uuid)               to authenticated;
grant execute on function public.report_entry(uuid, text, text)   to authenticated;
grant execute on function public.report_profile(uuid, text, text) to authenticated;

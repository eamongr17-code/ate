-- 0028_report_reason.sql
-- Ate backend — a report's `reason` becomes a small closed vocabulary.
--
-- `reports.reason` was free text (0019) and triage is a human reading SQL, so five buckets
-- is all it needs to be sortable:
--     spam · abuse · wrong_place · not_food · other        (NULL stays legal)
-- NULL is not a placeholder to be filled in later — it is "reported, no reason given",
-- which is what the client sends today and what the Actions sheet offers (one tap to
-- report; picking a reason is an optional refinement).
--
-- NOT VALID, DELIBERATELY. The constraint is enforced on every INSERT and UPDATE from the
-- moment it lands, but Postgres does not scan the rows already there. Any historic report
-- carrying some other string keeps its words: a real user's report is user data, and
-- rewriting or deleting one to make a constraint validate is exactly the kind of "cleanup"
-- this team does not do. If a future pass ever wants `VALIDATE CONSTRAINT`, that is a read
-- of prod data first and a CEO decision after, not a migration.
--
-- WIRE IMPACT: ADDITIVE, with one new failure mode on a value the client does not send
-- today. `report_entry` / `report_profile` keep their exact signatures and both now
-- lower-case + trim the reason, so 'Spam' and ' spam ' are accepted as `spam`. A reason
-- outside the list is refused with `23514` (check_violation) rather than being silently
-- rewritten to 'other' — inventing a category on the user's behalf is a lie about what
-- they said, and 'other' is right there for them to choose.

set search_path = public, extensions;

alter table public.reports
  add constraint reports_reason_ck
  check (reason is null or reason in ('spam', 'abuse', 'wrong_place', 'not_food', 'other'))
  not valid;

comment on column public.reports.reason is
  'Why it was reported: spam | abuse | wrong_place | not_food | other, or NULL for "no reason given" (what the client sends by default). CHECKed by reports_reason_ck, NOT VALID so pre-0028 rows keep whatever they said.';

-- The two RPCs: same signatures, same behaviour, plus case/whitespace normalisation so a
-- client that sends 'Spam' is not punished for a capital letter.
create or replace function public.report_entry(p_entry_id uuid, p_reason text default null, p_note text default null)
returns uuid language sql volatile security invoker
set search_path = public, extensions as $$
  insert into public.reports (reporter_id, entry_id, reason, note)
  values (
    (select auth.uid()),
    p_entry_id,
    nullif(btrim(lower(coalesce(p_reason, ''))), ''),
    nullif(btrim(coalesce(p_note, '')), '')
  )
  returning id;
$$;

create or replace function public.report_profile(p_user_id uuid, p_reason text default null, p_note text default null)
returns uuid language sql volatile security invoker
set search_path = public, extensions as $$
  insert into public.reports (reporter_id, profile_id, reason, note)
  values (
    (select auth.uid()),
    p_user_id,
    nullif(btrim(lower(coalesce(p_reason, ''))), ''),
    nullif(btrim(coalesce(p_note, '')), '')
  )
  returning id;
$$;

comment on function public.report_entry(uuid, text, text) is
  'Report an entry. p_reason ∈ (spam, abuse, wrong_place, not_food, other) or NULL; lower-cased and trimmed here, CHECKed by reports_reason_ck (anything else → 23514). p_note is free text, kept verbatim.';
comment on function public.report_profile(uuid, text, text) is
  'Report a profile. Same reason vocabulary as report_entry.';

-- create-or-replace preserves grants; restated so this file stands alone.
revoke all on function public.report_entry(uuid, text, text)    from public, anon;
revoke all on function public.report_profile(uuid, text, text)  from public, anon;
grant execute on function public.report_entry(uuid, text, text)   to authenticated;
grant execute on function public.report_profile(uuid, text, text) to authenticated;

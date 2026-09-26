-- 0040_place_required.sql
-- Ate backend — round 3: a NEW entry must name its place. The app now refuses Done without one; the
-- database refuses the insert too, so no client (an old build, an offline queue, a script) can land a
-- placeless visit.
--
-- HOW: a BEFORE INSERT trigger, not a constraint. A CHECK (even NOT VALID) is re-evaluated on every
-- UPDATE of an existing row, so the placeless entries already written would fail their next body edit
-- or re-sort — and `entries.restaurant_id` is `on delete set null`, which a NOT NULL would turn into a
-- blocked restaurant delete. The trigger looks at INSERT only:
--   * existing placeless rows are untouched and stay fully editable;
--   * the parked-plan path still works for them — `apply_entry_sort` parks the plan, and
--     `correct_entry_place` prints it when a place is attached (both are UPDATEs);
--   * the sorter's code paths for a null place stay (they now serve those older rows only).
-- It applies to every role, service_role included: synthetic/seed entries must name a place as well.
--
-- ERROR: SQLSTATE 23502 (not_null_violation — the family a NOT NULL would raise), message
-- `place_required`, so the client can switch on the code and the message together. PostgREST → 400
-- `{"code":"23502","message":"place_required",...}`. The whole insert (and the order number the insert
-- trigger allocated) rolls back.
--
-- WIRE IMPACT: BEHAVIOURAL / BREAKING for one request: `POST /rest/v1/entries` without `restaurant_id`
-- (or with null) now fails 23502 `place_required`, where it used to land a placeless entry. Builds that
-- allow a placeless Done must not be the live TestFlight build when this is applied — sequenced with
-- iOS through the lead. Every other call is unchanged.

set search_path = public, extensions;

create or replace function public.trg_entry_place_required()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.restaurant_id is null then
    raise exception 'place_required'
      using errcode = '23502',
            detail  = 'A new entry needs restaurant_id (round 3). Existing placeless entries are unaffected.',
            hint    = 'Pick a place before Done.';
  end if;
  return new;
end; $$;

comment on function public.trg_entry_place_required() is
  'Round 3 (0040): rejects an entries INSERT with a NULL restaurant_id — 23502 place_required. INSERT only, so existing placeless rows keep working (edits, re-sorts, correct_entry_place).';

-- 0008's rule: trigger functions must not be reachable as RPCs.
revoke execute on function public.trg_entry_place_required() from public, anon, authenticated;

drop trigger if exists entries_place_required on public.entries;
create trigger entries_place_required
  before insert on public.entries
  for each row execute function public.trg_entry_place_required();

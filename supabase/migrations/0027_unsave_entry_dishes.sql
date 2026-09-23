-- 0027_unsave_entry_dishes.sql
-- Ate backend — the whole-visit bookmark toggles OFF in one call.
--
-- `save_entry_dishes(entry)` (0020) saves every dish an entry printed; there was no
-- inverse, so the client had to fan out one `unsave_dish` per line and could leave the
-- bookmark half-on if one call failed. This is that inverse, with the same argument and
-- the same "how many rows did you touch" return.
--
-- IT REMOVES THE SAVE, NOT JUST THIS ENTRY'S PROVENANCE. If the caller had already saved
-- one of these dishes from somewhere else, that save goes too — deliberate: the toggle's
-- OFF state has to mean "none of these lines reads saved", which is exactly what
-- `entry_cards.items[].saved` will report on the next fetch. (Filtering by
-- `source_entry_id = p_entry_id` instead would leave the bookmark stuck ON, which is the
-- bug, not the fix.) A save is cheap to remake; a lying toggle is not.
--
-- LENIENT ON PURPOSE, unlike its sibling: `save_entry_dishes` raises 42501 when the entry
-- is not visible, because saving from an entry you cannot see is a bug. UNSAVING is a
-- cleanup, and the entry may legitimately be gone (deleted → its reviews cascaded, or its
-- author has since blocked you). Returning 0 is the honest answer; raising would strand a
-- bookmark the user is trying to turn off.
--
-- SECURITY INVOKER: the `saves` DELETE policy already restricts this to the caller's own
-- rows, and the `reviews` SELECT policy decides which lines the entry is allowed to show.
-- Nothing to escalate.
--
-- WIRE IMPACT: ADDITIVE only — one new RPC, one new index. No shape change.

set search_path = public, extensions;

create or replace function public.unsave_entry_dishes(p_entry_id uuid)
returns integer
language plpgsql
volatile
security invoker
set search_path = public, extensions
as $$
declare
  v_count integer := 0;
begin
  delete from public.saves s
  where s.user_id = (select auth.uid())
    and s.dish_id in (
      select v.dish_id from public.reviews v where v.entry_id = p_entry_id
    );

  get diagnostics v_count = row_count;
  return v_count;
end; $$;

comment on function public.unsave_entry_dishes(uuid) is
  'The inverse of save_entry_dishes: drop the caller''s saves for every dish this entry printed, regardless of which entry they were saved from. Returns rows removed; 0 (never an error) when the entry is gone or not visible.';

revoke all on function public.unsave_entry_dishes(uuid) from public, anon;
grant execute on function public.unsave_entry_dishes(uuid) to authenticated;

-- ===========================================================================
-- The Saved screen pages on the keyset (saved_at desc, dish_id desc) — that is the
-- documented contract (integration-design.md), and `saved_at` IS `saves.created_at`.
-- `saves_user_idx (user_id, created_at desc)` is a prefix of this one and is left in
-- place (forward-only; dropping it buys nothing during a release).
-- ===========================================================================
create index if not exists saves_user_keyset_idx
  on public.saves (user_id, created_at desc, dish_id desc);

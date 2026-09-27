-- 0048_entry_card_read.sql
-- Ate backend — round 5: SHARE A REVIEW. The app shares `ate://entry/<id>`; opening it reads ONE
-- entry by id — signed in or signed out. Until now the Entry page read the `entry_cards` VIEW
-- directly, which anon cannot (0034 named this gap), so a signed-out tap on a shared link had nothing
-- to call.
--
--   get_entry_card(p_entry_id uuid) → setof entry_cards: the one row, or [] when the viewer may not
--   see it (or it is gone). Never an error for "not visible" — render it as unavailable.
--
-- WHO SEES WHAT — exactly the other entry reads:
--   signed in: `entry_cards` under RLS — your own; anyone's unless a block stands between you (either
--              direction); not a deactivated author's (profiles RLS + the view's inner join) unless
--              it is yours. Identical to `entry_cards?id=eq.<id>`.
--   signed out: the browse twin (DEFINER, 0034 pattern) — public entries by live profiles, with
--              is_mine and items[].saved = false. There is no viewer, so no block applies.
--
-- WIRE IMPACT: ADDITIVE — one new RPC (authenticated + anon). The `entry_cards?id=eq.` read is
-- unchanged and still right for a signed-in client.

set search_path = public, extensions;

-- public first: the browse twin is `language sql`, validated at create time against its callee.
create or replace function public.get_entry_card(p_entry_id uuid)
returns setof public.entry_cards
language plpgsql
stable
security invoker
set search_path = public, extensions
as $$
begin
  if current_user = 'anon' then
    return query select * from browse.get_entry_card(p_entry_id);
    return;
  end if;

  return query select c.* from public.entry_cards c where c.id = p_entry_id;
end;
$$;

create or replace function browse.get_entry_card(p_entry_id uuid)
returns setof public.entry_cards
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.*
  from public.get_entry_card(p_entry_id) c
  cross join lateral jsonb_populate_record(c, '{"is_mine": false}'::jsonb) r
  where c.visibility = 'public'
    and exists (select 1 from public.profiles p where p.id = c.author_id and p.deleted_at is null);
$$;

comment on function public.get_entry_card(uuid) is
  'Round 5 share link (0048): one entry_cards row by id — [] when the viewer may not see it or it is gone. Signed in: entry_cards under RLS (same as ?id=eq.). anon → browse twin: public entries by live profiles, is_mine/saved false.';

revoke all on function public.get_entry_card(uuid) from public;
grant execute on function public.get_entry_card(uuid) to authenticated, anon, service_role;
revoke all on function browse.get_entry_card(uuid) from public;
grant execute on function browse.get_entry_card(uuid) to anon;

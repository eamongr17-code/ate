-- 0006_merge_dish.sql
-- Ate backend — Wave 0, BE-6: transactional dish-merge RPC (data-model §4).
-- Merge dish B (source) INTO dish A (canonical survivor):
--   1. repoint reviews.dish_id  B → A  (ratings accrue to A — the whole point)
--   2. repoint list_dishes.dish_id B → A, DEDUPING (drop B-membership where the
--      list already has A, rather than violate the (list_id, dish_id) PK)
--   3. tombstone B: merged_into_dish_id = A.id
--   4. flatten any chain that pointed AT B so it now points at A (one canonical hop)
-- ALL in one transaction (the function body is atomic) — never orphan reviews.
--
-- SECURITY DEFINER: dishes have no end-user UPDATE policy (merge is admin/moderation
-- only), so this runs as owner and bypasses RLS. Lock down EXECUTE accordingly.

set search_path = public, extensions;

create or replace function public.merge_dish(p_source uuid, p_target uuid)
returns uuid                                   -- returns the canonical survivor id
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_target uuid;
  v_src_live   boolean;
  v_tgt_exists boolean;
begin
  if p_source = p_target then
    raise exception 'cannot merge a dish into itself (%).', p_source;
  end if;

  -- Resolve the target through any existing tombstone chain so we always merge
  -- into the live canonical survivor (idempotent-ish, data-model §4).
  v_target := public.resolve_dish(p_target);

  if v_target = p_source then
    raise exception 'merge would create a cycle: target % resolves to source %', p_target, p_source;
  end if;

  select (merged_into_dish_id is null) into v_src_live from public.dishes where id = p_source;
  if v_src_live is null then
    raise exception 'source dish % does not exist', p_source;
  end if;

  select true into v_tgt_exists from public.dishes where id = v_target;
  if v_tgt_exists is null then
    raise exception 'target dish % does not exist', v_target;
  end if;

  -- 1. repoint reviews B → A (restaurant_id is reset by the reviews BIU trigger)
  update public.reviews set dish_id = v_target where dish_id = p_source;

  -- 2. repoint list_dishes B → A, deduping collisions.
  --    Drop any B-membership in a list that already contains A (avoid PK clash).
  delete from public.list_dishes ld_b
  where ld_b.dish_id = p_source
    and exists (
      select 1 from public.list_dishes ld_a
      where ld_a.list_id = ld_b.list_id and ld_a.dish_id = v_target
    );
  --    Repoint the remaining (non-colliding) B-memberships to A.
  update public.list_dishes set dish_id = v_target where dish_id = p_source;

  -- 3. tombstone B → A
  update public.dishes set merged_into_dish_id = v_target where id = p_source;

  -- 4. flatten: anything that was merged INTO B now points at A directly
  update public.dishes set merged_into_dish_id = v_target where merged_into_dish_id = p_source;

  return v_target;
end; $$;

comment on function public.merge_dish(uuid, uuid) is
  'Transactionally merge source dish into target survivor: repoint reviews+list_dishes, tombstone, flatten chain (data-model §4).';

-- merge is moderation-only — not callable by app users.
revoke all on function public.merge_dish(uuid, uuid) from public, anon, authenticated;

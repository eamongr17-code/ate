-- 0099_retire_first_drink.sql
-- Ate backend — "First drink" is no longer an award (Eamon, 28 Oct: "so it's just plates").
--
--   * award_put never writes it again: one guard where every award is written, so award_check
--     (whose first-drink pass still runs, finding nothing it may keep) needs no rewrite;
--   * the rows people already hold are removed (the app no longer knows the id, and skips it);
--   * the award CHECK drops it, so nothing can put it back.

create or replace function public.award_put(
  p_user uuid, p_award text, p_at timestamptz,
  p_entry uuid default null, p_dish uuid default null,
  p_entries uuid[] default '{}', p_dishes uuid[] default '{}', p_other uuid default null)
returns int
language sql
volatile
security definer
set search_path = public, extensions
as $$
  with ins as (
    insert into public.user_awards (user_id, award, earned_at, entry_id, dish_id, entry_ids, dish_ids, other_user_id)
    select p_user, p_award, p_at, p_entry, p_dish, coalesce(p_entries, '{}'), coalesce(p_dishes, '{}'), p_other
    where p_at is not null
      and p_award <> 'first_drink'  -- retired (0099)
    on conflict (user_id, award) do nothing
    returning 1)
  select count(*)::int from ins;
$$;

revoke all on function public.award_put(uuid, text, timestamptz, uuid, uuid, uuid[], uuid[], uuid) from public, anon, authenticated;

delete from public.user_awards where award = 'first_drink';

alter table public.user_awards drop constraint if exists user_awards_award_ck;
alter table public.user_awards add constraint user_awards_award_ck check (award in (
  'dishes_1', 'dishes_10', 'dishes_25', 'dishes_50', 'dishes_100', 'dishes_250', 'dishes_500',
  'first_5', 'first_6', 'first_half',
  'first_dessert', 'new_country', 'ate_with', 'saved_by_someone', 'saves_10',
  'same_dish_3', 'five_in_entry', 'three_in_day', 'five_at_place'));

-- 0064 — a photo the author paired by hand stays paired through a re-sort (PR #154 follow-up).
--
-- 0063 kept the author's pick on the LINE (reviews.photo_picked_at). A re-sort rebuilds every line
-- the author didn't correct (0053), so editing the words quietly dropped the pick and the next match
-- could pair that photo with another dish. The pick now also lives on the ENTRY, keyed by photo:
--
--   entries.photo_picks = { "<photo url>": "<dish name, lower case>" | null }
--
-- null is "No dish": that photo is never matched to anything. set_review_photo writes both places;
-- match-photos calls restore_photo_picks (after prune_photo_pairs, before it reads), which puts every
-- pick back on the line now carrying that dish and drops picks whose photo has left the entry.
-- apply_entry_sort is untouched.

set search_path = public, extensions;

alter table public.entries add column if not exists photo_picks jsonb not null default '{}'::jsonb;

comment on column public.entries.photo_picks is
  'The author''s own photo pairings, photo url → lower(dish name), or null for "No dish". Outlives the lines a re-sort rebuilds; restore_photo_picks reapplies it.';

-- ===========================================================================
-- 1. set_review_photo — 0063's, plus the pick recorded on the entry.
-- ===========================================================================
create or replace function public.set_review_photo(p_entry_id uuid, p_photo_url text, p_review_id uuid default null)
returns void
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid  uuid := (select auth.uid());
  v_name text;
begin
  if v_uid is null then
    raise exception 'sign in to edit' using errcode = '42501';
  end if;
  if not exists (select 1 from public.entries e where e.id = p_entry_id and e.author_id = v_uid) then
    raise exception 'entry not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.entry_photos x where x.entry_id = p_entry_id and x.photo_url = p_photo_url) then
    raise exception 'photo not on this entry' using errcode = '22023';
  end if;
  if p_review_id is not null then
    select lower(d.name) into v_name
    from public.reviews r join public.dishes d on d.id = r.dish_id
    where r.id = p_review_id and r.entry_id = p_entry_id;
    if v_name is null then
      raise exception 'line not on this entry' using errcode = '22023';
    end if;
  end if;

  -- One photo, one dish: whoever had it lets it go, and that is the author's choice too.
  update public.reviews r set photo_url = null, photo_picked_at = now()
  where r.entry_id = p_entry_id and r.photo_url = p_photo_url and r.id is distinct from p_review_id;

  if p_review_id is not null then
    update public.reviews r set photo_url = p_photo_url, photo_picked_at = now()
    where r.id = p_review_id;
  end if;

  -- The entry's record: this photo is this dish (no other photo is), or no dish.
  update public.entries e
     set photo_picks = coalesce((
           select jsonb_object_agg(k.key, k.value)
           from jsonb_each(e.photo_picks) k
           where k.key <> p_photo_url and (v_name is null or k.value is distinct from to_jsonb(v_name))
         ), '{}'::jsonb) || jsonb_build_object(p_photo_url, v_name)
   where e.id = p_entry_id;
end; $$;

revoke all on function public.set_review_photo(uuid, text, uuid) from public, anon;
grant execute on function public.set_review_photo(uuid, text, uuid) to authenticated;

-- ===========================================================================
-- 2. restore_photo_picks — the entry's picks back onto its current lines. service_role only.
--    Returns how many lines it moved.
-- ===========================================================================
create or replace function public.restore_photo_picks(p_entry_id uuid)
returns int
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_pick record;
  v_line uuid;
  v_n    int := 0;
  v_k    int;
begin
  -- A pick whose photo has left the entry is gone with it.
  update public.entries e
     set photo_picks = coalesce((
           select jsonb_object_agg(k.key, k.value)
           from jsonb_each(e.photo_picks) k
           where exists (select 1 from public.entry_photos p where p.entry_id = e.id and p.photo_url = k.key)
         ), '{}'::jsonb)
   where e.id = p_entry_id and e.photo_picks <> '{}'::jsonb;

  for v_pick in
    select k.key as url, k.value #>> '{}' as name
    from public.entries e, jsonb_each(e.photo_picks) k
    where e.id = p_entry_id
  loop
    v_line := null;
    if v_pick.name is not null then
      select r.id into v_line
      from public.reviews r join public.dishes d on d.id = r.dish_id
      where r.entry_id = p_entry_id and lower(d.name) = v_pick.name
      order by r.entry_position nulls last, r.created_at, r.id
      limit 1;
    end if;

    -- Nobody else holds the photo, unless the author put it there by hand since.
    update public.reviews r set photo_url = null
    where r.entry_id = p_entry_id and r.photo_url = v_pick.url
      and r.id is distinct from v_line and r.photo_picked_at is null;
    get diagnostics v_k = row_count;
    v_n := v_n + v_k;

    if v_line is not null then
      update public.reviews r set photo_url = v_pick.url, photo_picked_at = coalesce(r.photo_picked_at, now())
      where r.id = v_line and r.photo_url is distinct from v_pick.url;
      get diagnostics v_k = row_count;
      v_n := v_n + v_k;
    end if;
  end loop;
  return v_n;
end; $$;

revoke all on function public.restore_photo_picks(uuid) from public, anon, authenticated;
grant execute on function public.restore_photo_picks(uuid) to service_role;

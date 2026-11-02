-- 0104_fold_same_day_entries.sql
-- Ate backend — the entries already posted twice at one place on one day become one (Eamon, 2 Nov:
-- "yes merge", on same-day-one-entry). 0103 stops new doubles; this folds the old ones, once.
--
--   fold_same_day_entry(from, into) — service-only. Everything of `from` goes into `into`, then `from`
--     is deleted:
--       * lines: a dish not on `into` moves as it is (its word offsets shifted past `into`'s words), after
--         `into`'s lines. A dish already on `into` keeps `into`'s line, which takes the LATER score (the
--         later post's, when it has one: "a new score for a dish already on the entry replaces the old
--         one"), both lines' tags, and the later line's photo pairings.
--       * words: `into`'s, a blank line, then `from`'s — both the author's own, in the order written.
--       * photos (after `into`'s, each url once), their dish pairings, picks; 6 grants (so a 6 that
--         moves is a carry, never spent twice); tagged people (each person once), invites, answers to
--         tags, list items (each list's dish once, renumbered), saves' source, reports, awards.
--     Refuses (returns false, changes nothing) when the two would hold more than 24 photos or 20,000
--     characters of words — kept apart rather than lose anything.
--   The one-off fold: every author's entries at one place on one Melbourne day, all printed (sorted),
--   folded into the earliest. Unprinted ones are left for their sort to finish; 0103 then keeps them apart
--   (edits never merge).
--
-- BACKUP: every row the fold touches is copied first into backup_0104_* (RLS on, no grants: service
--   role only). Drop them once Eamon has checked the result.
--
-- WIRE IMPACT: none. A folded entry's id stops resolving (get_entry_card → []); a share link to it shows
--   the web page's "not here" state.
--
-- Volume: one pass over entries grouped by (author, place, day) — beta-sized (hundreds of rows); every
--   per-entry write is by entry id.

set search_path = public, extensions;

create or replace function public.fold_same_day_entry(p_from uuid, p_into uuid)
returns boolean language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  i        public.entries;
  f        public.entries;
  v_shift  int;
  v_pos    int;
  v_first  int;
  v_match  uuid;
  v_lists  uuid[];
  ln       record;
begin
  select * into i from public.entries where id = p_into for update;
  select * into f from public.entries where id = p_from for update;
  if i.id is null or f.id is null or i.id = f.id or f.author_id <> i.author_id
     or f.restaurant_id is distinct from i.restaurant_id then
    raise exception 'not the same author and place' using errcode = '22023';
  end if;

  -- Nothing may be lost: refuse what would overflow a cap.
  if (select count(distinct p.photo_url) from public.entry_photos p where p.entry_id in (p_from, p_into)) > 24
     or char_length(i.body) + char_length(f.body) + 2 > 20000 then
    return false;
  end if;

  -- Offsets are Unicode scalars into the words (0024); `from`'s words start past `into`'s and a blank line.
  v_shift := case when btrim(i.body) = '' or btrim(f.body) = '' then 0 else char_length(i.body) + 2 end;

  -- 6s first: `into` holds `from`'s grants, so a 6 moving across is a carry (0091/0094).
  insert into public.six_grants (entry_id, author_id, granted, first_at)
  select p_into, g.author_id, g.granted, g.first_at from public.six_grants g where g.entry_id = p_from
  on conflict (entry_id) do update
    set granted = public.six_grants.granted + excluded.granted,
        first_at = least(public.six_grants.first_at, excluded.first_at);
  delete from public.six_grants where entry_id = p_from;

  -- Photos, after `into`'s, each url once.
  select coalesce(max(position) + 1, 0) into v_first from public.entry_photos where entry_id = p_into;
  insert into public.entry_photos (entry_id, position, photo_url)
  select p_into, (v_first + x.n - 1)::smallint, x.photo_url
  from (select p.photo_url, row_number() over (order by p.position) as n
        from public.entry_photos p
        where p.entry_id = p_from
          and not exists (select 1 from public.entry_photos o where o.entry_id = p_into and o.photo_url = p.photo_url)) x;

  -- Lines.
  select coalesce(max(entry_position), 0) into v_pos from public.reviews where entry_id = p_into;
  for ln in
    select m.*, coalesce(md.merged_into_dish_id, m.dish_id) as dish
    from public.reviews m left join public.dishes md on md.id = m.dish_id
    where m.entry_id = p_from
    order by m.entry_position nulls last, m.id
  loop
    select t.id into v_match
    from public.reviews t left join public.dishes td on td.id = t.dish_id
    where t.entry_id = p_into and coalesce(td.merged_into_dish_id, t.dish_id) = ln.dish
    order by t.entry_position nulls last, t.id
    limit 1;
    if v_match is not null then
      update public.reviews t
         set score           = coalesce(ln.score, t.score),
             score_evidence  = case when ln.score is not null then ln.score_evidence else t.score_evidence end,
             evidence_offset = case when ln.score is not null then ln.evidence_offset + v_shift else t.evidence_offset end,
             tags            = array(select distinct x from unnest(t.tags || ln.tags) x),
             photo_url       = coalesce(ln.photo_url, t.photo_url)
       where t.id = v_match;
      insert into public.photo_dishes (entry_id, photo_url, review_id, box_left, box_top, box_right, box_bottom)
      select p_into, pd.photo_url, v_match, pd.box_left, pd.box_top, pd.box_right, pd.box_bottom
      from public.photo_dishes pd where pd.review_id = ln.id
      on conflict do nothing;
    else
      v_pos := v_pos + 1;
      update public.reviews
         set entry_id = p_into, entry_position = v_pos,
             evidence_offset = evidence_offset + v_shift,
             mention_offset  = mention_offset + v_shift
       where id = ln.id;
      update public.photo_dishes set entry_id = p_into where review_id = ln.id and entry_id = p_from;
    end if;
  end loop;

  update public.entries
     set body = case when btrim(f.body) = '' then body
                     when btrim(body) = '' then f.body
                     else body || E'\n\n' || f.body end,
         photo_picks = photo_picks || f.photo_picks,
         photo_also  = photo_also || f.photo_also,
         photos_matched_at = case when f.photos_matched_at is null
                                   and exists (select 1 from public.entry_photos p where p.entry_id = p_from)
                                  then null else photos_matched_at end
   where id = p_into;

  -- People: each person once on `into`; answers to tags now point at `into`.
  delete from public.entry_companions c
   where c.entry_id = p_from
     and exists (select 1 from public.entry_companions o where o.entry_id = p_into and o.companion_id = c.companion_id);
  update public.entry_companions set entry_id = p_into where entry_id = p_from;
  update public.entry_companions set response_entry_id = p_into where response_entry_id = p_from;
  update public.entry_invites set entry_id = p_into where entry_id = p_from;

  -- Lists: each list's dish once, then dense again.
  select array_agg(distinct l.list_id) into v_lists from public.user_list_items l where l.entry_id = p_from;
  delete from public.user_list_items l
   where l.entry_id = p_from
     and exists (select 1 from public.user_list_items o
                 where o.list_id = l.list_id and o.entry_id = p_into and o.dish_id = l.dish_id);
  update public.user_list_items set entry_id = p_into where entry_id = p_from;
  if v_lists is not null then
    perform public.list_renumber(l) from unnest(v_lists) l;
  end if;

  update public.saves set source_entry_id = p_into where source_entry_id = p_from;
  delete from public.reports r
   where r.entry_id = p_from and r.status = 'open'
     and exists (select 1 from public.reports o where o.entry_id = p_into and o.reporter_id = r.reporter_id and o.status = 'open');
  update public.reports set entry_id = p_into where entry_id = p_from;
  update public.user_awards set entry_id = p_into where entry_id = p_from;
  update public.user_awards set entry_ids = array_replace(entry_ids, p_from, p_into) where p_from = any(entry_ids);

  delete from public.entries where id = p_from;
  return true;
end; $$;
revoke all on function public.fold_same_day_entry(uuid, uuid) from public, anon, authenticated;
grant execute on function public.fold_same_day_entry(uuid, uuid) to service_role;

-- ===========================================================================
-- The one-off fold
-- ===========================================================================
drop table if exists pg_temp.fold_0104;
create temporary table fold_0104 as
select e.id as from_id, g.into_id
from public.entries e
join lateral (
  select o.id as into_id
  from public.entries o
  where o.author_id = e.author_id and o.restaurant_id = e.restaurant_id
    and (o.created_at at time zone public.award_day_zone())::date = (e.created_at at time zone public.award_day_zone())::date
    and o.sort_status = 'sorted'
  order by o.created_at, o.id
  limit 1
) g on true
where e.restaurant_id is not null
  and e.sort_status = 'sorted'
  and e.id <> g.into_id;

-- Backups of every row the fold can touch.
create table if not exists public.backup_0104_entries as
  select * from public.entries where id in (select from_id from fold_0104 union select into_id from fold_0104);
create table if not exists public.backup_0104_reviews as
  select * from public.reviews where entry_id in (select entry_id from (select from_id entry_id from fold_0104 union select into_id from fold_0104) k);
create table if not exists public.backup_0104_entry_photos as
  select * from public.entry_photos where entry_id in (select from_id from fold_0104 union select into_id from fold_0104);
create table if not exists public.backup_0104_photo_dishes as
  select * from public.photo_dishes where entry_id in (select from_id from fold_0104 union select into_id from fold_0104);
create table if not exists public.backup_0104_entry_companions as
  select * from public.entry_companions
  where entry_id in (select from_id from fold_0104 union select into_id from fold_0104)
     or response_entry_id in (select from_id from fold_0104);
create table if not exists public.backup_0104_user_list_items as
  select * from public.user_list_items where entry_id in (select from_id from fold_0104 union select into_id from fold_0104);
create table if not exists public.backup_0104_six_grants as
  select * from public.six_grants where entry_id in (select from_id from fold_0104 union select into_id from fold_0104);
create table if not exists public.backup_0104_saves as
  select * from public.saves where source_entry_id in (select from_id from fold_0104);
create table if not exists public.backup_0104_user_awards as
  select * from public.user_awards
  where entry_id in (select from_id from fold_0104) or entry_ids && array(select from_id from fold_0104);

do $$
declare t text;
begin
  foreach t in array array['entries','reviews','entry_photos','photo_dishes','entry_companions',
                           'user_list_items','six_grants','saves','user_awards'] loop
    execute format('alter table public.backup_0104_%s enable row level security', t);
    execute format('revoke all on public.backup_0104_%s from public, anon, authenticated', t);
  end loop;
end $$;

do $$
declare
  r       record;
  v_done  int := 0;
  v_kept  int := 0;
begin
  for r in
    select f.from_id, f.into_id from fold_0104 f
    join public.entries e on e.id = f.from_id
    order by f.into_id, e.created_at, e.id
  loop
    if public.fold_same_day_entry(r.from_id, r.into_id) then
      v_done := v_done + 1;
    else
      v_kept := v_kept + 1;
    end if;
  end loop;
  raise notice '0104: folded % same-day entries; % kept apart (over a cap)', v_done, v_kept;
end $$;

drop table if exists pg_temp.fold_0104;

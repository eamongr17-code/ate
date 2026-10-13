-- 0063 — when you ate it, and which photo is which dish (13 Oct beta, design/rebuild/date-and-photos.html).
--
-- 1. THE DATE. `entries.created_at` is already "when you ate" (0018) and already client-set on
--    insert, so a new entry carries the day the person picked. Changing it afterwards had no path:
--    `set_entry_date` is that path, author-only, never in the future.
--
-- 2. EACH DISH'S PHOTO. `reviews.photo_url` has existed since Wave 0 and every cover read already
--    prefers it over "the entry's first photo" (0026, 0029, 0053, 0060). Nothing has written it
--    since entries arrived, so every dish of a multi-dish entry showed photo one. Now:
--      * `match-photos` (edge function) pairs photos with lines after the sort and the uploads, and
--        writes them with `apply_photo_matches` (service role);
--      * the person fixes one with `set_review_photo` (author-only), which marks the line
--        `photo_picked_at` so a later match never overrides their choice;
--      * a photo leaving the entry leaves every line that pointed at it (trigger + prune below).
--    A re-sort rebuilds uncorrected lines (0053), so the client asks for a match again after it;
--    a pick made by hand lasts until then (the rebuilt line is a new row).

set search_path = public, extensions;

alter table public.reviews add column if not exists photo_picked_at timestamptz;
alter table public.entries add column if not exists photos_matched_at timestamptz;

comment on column public.reviews.photo_picked_at is
  'Set when the author chose this line''s photo (or chose none) by hand: match-photos leaves the line alone.';
comment on column public.entries.photos_matched_at is
  'Last time match-photos paired this entry''s photos with its lines.';

-- ===========================================================================
-- 1. set_entry_date
-- ===========================================================================
create or replace function public.set_entry_date(p_entry_id uuid, p_eaten_at timestamptz)
returns void
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'sign in to edit' using errcode = '42501';
  end if;
  -- A day of slack for time zones; nothing before the app could have existed.
  if p_eaten_at is null or p_eaten_at > now() + interval '1 day' or p_eaten_at < timestamptz '2000-01-01' then
    raise exception 'eaten_at' using errcode = '22023';
  end if;
  update public.entries e set created_at = p_eaten_at
  where e.id = p_entry_id and e.author_id = v_uid;
  if not found then
    raise exception 'entry not found' using errcode = 'P0002';
  end if;
end; $$;

revoke all on function public.set_entry_date(uuid, timestamptz) from public, anon;
grant execute on function public.set_entry_date(uuid, timestamptz) to authenticated;

-- ===========================================================================
-- 2. set_review_photo — the author's own pick. p_review_id null = "No dish".
-- ===========================================================================
create or replace function public.set_review_photo(p_entry_id uuid, p_photo_url text, p_review_id uuid default null)
returns void
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_uid uuid := (select auth.uid());
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
  if p_review_id is not null
     and not exists (select 1 from public.reviews r where r.id = p_review_id and r.entry_id = p_entry_id) then
    raise exception 'line not on this entry' using errcode = '22023';
  end if;

  -- One photo, one dish: whoever had it lets it go, and that is the author's choice too.
  update public.reviews r set photo_url = null, photo_picked_at = now()
  where r.entry_id = p_entry_id and r.photo_url = p_photo_url and r.id is distinct from p_review_id;

  if p_review_id is not null then
    update public.reviews r set photo_url = p_photo_url, photo_picked_at = now()
    where r.id = p_review_id;
  end if;
end; $$;

revoke all on function public.set_review_photo(uuid, text, uuid) from public, anon;
grant execute on function public.set_review_photo(uuid, text, uuid) to authenticated;

-- ===========================================================================
-- 3. apply_photo_matches — match-photos' write. p_matches: [{review_id, photo_url}].
--    Lines the author picked keep their pick; every other line takes its match or none.
-- ===========================================================================
create or replace function public.apply_photo_matches(p_entry_id uuid, p_matches jsonb)
returns int
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_n int;
begin
  with m as (
    select (x->>'review_id')::uuid as review_id, x->>'photo_url' as photo_url
    from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) x
    where x ? 'review_id'
  ),
  -- Only photos really on the entry and not already a picked line's.
  ok as (
    select m.review_id, m.photo_url from m
    where exists (select 1 from public.entry_photos p where p.entry_id = p_entry_id and p.photo_url = m.photo_url)
      and not exists (
        select 1 from public.reviews r
        where r.entry_id = p_entry_id and r.photo_picked_at is not null and r.photo_url = m.photo_url
      )
  )
  update public.reviews r
  set photo_url = (select ok.photo_url from ok where ok.review_id = r.id limit 1)
  where r.entry_id = p_entry_id and r.photo_picked_at is null;
  get diagnostics v_n = row_count;

  update public.entries set photos_matched_at = now() where id = p_entry_id;
  return v_n;
end; $$;

revoke all on function public.apply_photo_matches(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.apply_photo_matches(uuid, jsonb) to service_role;

-- ===========================================================================
-- 4. A photo that leaves the entry leaves its line — and the line is open to matching again.
--
--    Only a DELETE is final. An edit moves photos one upsert at a time (EntryEdit.savePhotos), so
--    while A,B becomes B,A there is a request where A is on no row: clearing on that UPDATE would
--    throw away a pairing the next request puts right back (QA, PR #154). Photos overwritten in
--    place are swept by prune_photo_pairs, which match-photos runs first, once the edit is done.
-- ===========================================================================
create or replace function public.prune_photo_pairs(p_entry_id uuid)
returns int
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_n int;
begin
  update public.reviews r set photo_url = null, photo_picked_at = null
  where r.entry_id = p_entry_id
    and r.photo_url is not null
    and not exists (
      select 1 from public.entry_photos p where p.entry_id = p_entry_id and p.photo_url = r.photo_url
    );
  get diagnostics v_n = row_count;
  return v_n;
end; $$;

revoke all on function public.prune_photo_pairs(uuid) from public, anon, authenticated;
grant execute on function public.prune_photo_pairs(uuid) to service_role;

create or replace function public.entry_photo_left()
returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (
    select 1 from public.entry_photos p where p.entry_id = old.entry_id and p.photo_url = old.photo_url
  ) then
    update public.reviews r set photo_url = null, photo_picked_at = null
    where r.entry_id = old.entry_id and r.photo_url = old.photo_url;
  end if;
  return old;
end; $$;

drop trigger if exists entry_photo_left on public.entry_photos;
create trigger entry_photo_left
  after delete on public.entry_photos
  for each row execute function public.entry_photo_left();

-- 0081_every_photo_of_a_dish.sql
-- Ate backend — two photos of one dish are both that dish.
--
-- Bug (22 Oct, Eamon): Paris posted one noodle soup with two photos. Only the first was named: the
-- second showed no dish in the viewer and never reached the dish page. 0063 kept a dish's photo on
-- the LINE (reviews.photo_url), one per line, so a second photo of the same dish had nowhere to go:
-- match-photos gave a one-line entry its first photo only, and the model was told "each dish has at
-- most one photo".
--
-- Now the pairing is kept per PHOTO, in public.photo_dishes (entry, photo url → line). A line may
-- have several photos; each photo still names at most one line. reviews.photo_url stays what it was,
-- the line's MAIN photo (its earliest), so every cover read (review_photo_url, 0079) is unchanged.
--
--   * apply_photo_matches  — main = the line's earliest matched photo; every match lands in photo_dishes.
--   * set_review_photo     — the pick lands in photo_dishes; a line that loses its main photo takes
--                            its next one; picking a second photo for a dish no longer drops the first
--                            photo's pick (0064's photo_picks keeps both).
--   * restore_photo_picks  — after 0064's pass, every named photo back onto its dish in photo_dishes.
--   * prune / photo left   — a photo that leaves the entry leaves photo_dishes too.
--   * dish_photos          — every photo of each review, main first.
--   * backfill             — every main photo, and every photo of a one-dish entry not called No dish.
--
-- The app reads photo_dishes (photo url → review id) instead of reviews.photo_url. Older builds keep
-- reading the main photo, exactly as before.
--
-- Volume: one row per photo (the composer allows five). PK (entry_id, photo_url) serves every
-- per-entry read and write; reviews(id) cascade and dish_photos use photo_dishes_review_idx.

set search_path = public, extensions;

create table if not exists public.photo_dishes (
  entry_id   uuid not null references public.entries(id) on delete cascade,
  photo_url  text not null,
  review_id  uuid not null references public.reviews(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (entry_id, photo_url)
);

create index if not exists photo_dishes_review_idx on public.photo_dishes (review_id);

comment on table public.photo_dishes is
  '0081: which dish line each photo of an entry shows. Several photos per line; one line per photo. Written only by the photo-matching functions (service role / set_review_photo).';

alter table public.photo_dishes enable row level security;

drop policy if exists photo_dishes_select_visible on public.photo_dishes;
create policy photo_dishes_select_visible on public.photo_dishes
  for select to authenticated
  using (exists (select 1 from public.entries e where e.id = entry_id));

revoke all on public.photo_dishes from public, anon, authenticated;
grant select on public.photo_dishes to authenticated;
grant all on public.photo_dishes to service_role;

-- ===========================================================================
-- 1. apply_photo_matches — p_matches: [{review_id, photo_url}]. Several photos may name one line.
--    Lines the author picked keep their pick; every other line takes its earliest match as its main
--    photo, or none, and exactly its matches in photo_dishes.
-- ===========================================================================
create or replace function public.apply_photo_matches(p_entry_id uuid, p_matches jsonb)
returns int
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_n  int;
  v_ok jsonb;
begin
  -- Only photos really on the entry, not spoken for by the author (a pick, or a picked line's
  -- photo), onto lines of this entry nobody picked. First claim on a photo wins.
  with m as (
    select (x->>'review_id')::uuid as review_id, x->>'photo_url' as photo_url, n
    from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) with ordinality t(x, n)
    where x ? 'review_id' and x ? 'photo_url'
  ),
  ok as (
    select distinct on (m.photo_url) m.review_id, m.photo_url, p.position
    from m
    join public.entry_photos p on p.entry_id = p_entry_id and p.photo_url = m.photo_url
    join public.reviews r on r.id = m.review_id and r.entry_id = p_entry_id and r.photo_picked_at is null
    join public.entries e on e.id = p_entry_id
    where not (e.photo_picks ? m.photo_url)
      and not exists (
        select 1 from public.reviews h
        where h.entry_id = p_entry_id and h.photo_picked_at is not null and h.photo_url = m.photo_url
      )
    order by m.photo_url, m.n
  )
  select coalesce(jsonb_agg(jsonb_build_object('review_id', review_id, 'photo_url', photo_url, 'position', position)), '[]'::jsonb)
    into v_ok
  from ok;

  update public.reviews r
  set photo_url = (
    select o->>'photo_url' from jsonb_array_elements(v_ok) o
    where (o->>'review_id')::uuid = r.id
    order by (o->>'position')::int
    limit 1
  )
  where r.entry_id = p_entry_id and r.photo_picked_at is null;
  get diagnostics v_n = row_count;

  -- The open lines' photos are exactly this match; the author's own pairings stay.
  delete from public.photo_dishes pd
  using public.reviews r, public.entries e
  where pd.entry_id = p_entry_id
    and r.id = pd.review_id and r.photo_picked_at is null
    and e.id = p_entry_id and not (e.photo_picks ? pd.photo_url);
  insert into public.photo_dishes (entry_id, photo_url, review_id)
  select p_entry_id, o->>'photo_url', (o->>'review_id')::uuid
  from jsonb_array_elements(v_ok) o
  on conflict (entry_id, photo_url) do nothing;

  update public.entries set photos_matched_at = now() where id = p_entry_id;
  return v_n;
end; $$;

revoke all on function public.apply_photo_matches(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.apply_photo_matches(uuid, jsonb) to service_role;

-- ===========================================================================
-- 2. set_review_photo — 0064's, plus photo_dishes, and a second photo of a dish keeps the first.
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
    if not found then
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

  delete from public.photo_dishes where entry_id = p_entry_id and photo_url = p_photo_url;
  if p_review_id is not null then
    insert into public.photo_dishes (entry_id, photo_url, review_id) values (p_entry_id, p_photo_url, p_review_id);
  end if;

  -- A line that just lost its main photo shows its next one, if it has one.
  update public.reviews r
  set photo_url = (
    select pd.photo_url from public.photo_dishes pd
    join public.entry_photos x on x.entry_id = pd.entry_id and x.photo_url = pd.photo_url
    where pd.review_id = r.id
    order by x.position
    limit 1
  )
  where r.entry_id = p_entry_id and r.photo_url is null
    and exists (select 1 from public.photo_dishes pd where pd.review_id = r.id);

  -- The entry's record: this photo is this dish, or no dish. Other photos keep their picks, so two
  -- photos of one dish stay that dish through a re-sort.
  update public.entries e
     set photo_picks = (e.photo_picks - p_photo_url) || jsonb_build_object(p_photo_url, v_name)
   where e.id = p_entry_id;
end; $$;

revoke all on function public.set_review_photo(uuid, text, uuid) from public, anon;
grant execute on function public.set_review_photo(uuid, text, uuid) to authenticated;

-- ===========================================================================
-- 3. restore_photo_picks — 0064's pass is unchanged (it sets each line's main photo); this wrapper
--    then puts every named photo onto its dish in photo_dishes, and takes No-dish photos off.
-- ===========================================================================
alter function public.restore_photo_picks(uuid) rename to restore_photo_picks_0064;
revoke all on function public.restore_photo_picks_0064(uuid) from public, anon, authenticated;
grant execute on function public.restore_photo_picks_0064(uuid) to service_role;

create or replace function public.restore_photo_picks(p_entry_id uuid)
returns int
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_n int;
begin
  v_n := public.restore_photo_picks_0064(p_entry_id);

  delete from public.photo_dishes pd
  using public.entries e
  where pd.entry_id = p_entry_id and e.id = p_entry_id and e.photo_picks -> pd.photo_url = 'null'::jsonb;

  insert into public.photo_dishes (entry_id, photo_url, review_id)
  select p_entry_id, k.url, k.line
  from (
    select k.key as url, coalesce(
      (select r.id from public.reviews r
       where r.entry_id = p_entry_id and r.photo_url = k.key
       order by r.entry_position nulls last, r.created_at, r.id limit 1),
      (select r.id from public.reviews r join public.dishes d on d.id = r.dish_id
       where r.entry_id = p_entry_id and lower(d.name) = k.value #>> '{}'
       order by (r.photo_picked_at is null), r.entry_position nulls last, r.created_at, r.id limit 1)
    ) as line
    from public.entries e, jsonb_each(e.photo_picks) k
    where e.id = p_entry_id and k.value <> 'null'::jsonb
  ) k
  where k.line is not null
  on conflict (entry_id, photo_url) do update set review_id = excluded.review_id;

  return v_n;
end; $$;

revoke all on function public.restore_photo_picks(uuid) from public, anon, authenticated;
grant execute on function public.restore_photo_picks(uuid) to service_role;

-- ===========================================================================
-- 4. A photo that leaves the entry leaves photo_dishes (0063's rule, per photo).
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
  delete from public.photo_dishes pd
  where pd.entry_id = p_entry_id
    and not exists (select 1 from public.entry_photos p where p.entry_id = p_entry_id and p.photo_url = pd.photo_url);
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
    delete from public.photo_dishes pd where pd.entry_id = old.entry_id and pd.photo_url = old.photo_url;
  end if;
  return old;
end; $$;

-- ===========================================================================
-- 5. dish_photos — every photo of each review (main first), newest review first. photos[0] is still
--    the cover (dish_cover_url).
-- ===========================================================================
create or replace function public.dish_photos(p_dish_id uuid, p_limit int default 8)
returns jsonb
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object('url', p.url, 'entry_id', p.entry_id)
              order by p.created_at desc, p.review_id desc, p.ord),
    '[]'::jsonb)
  from (
    select v.id as review_id, v.entry_id, v.created_at, ph.url, ph.ord
    from public.reviews v
    cross join lateral (
      select u.url, min(u.ord) as ord
      from (
        select public.review_photo_url(v) as url, -1 as ord
        union all
        select pd.photo_url, x.position
        from public.photo_dishes pd
        join public.entry_photos x on x.entry_id = pd.entry_id and x.photo_url = pd.photo_url
        where pd.review_id = v.id
      ) u
      where u.url is not null
      group by u.url
    ) ph
    where v.dish_id = p_dish_id
    order by v.created_at desc, v.id desc, ph.ord
    limit least(greatest(p_limit, 1), 24)
  ) p;
$$;

comment on function public.dish_photos(uuid, int) is
  'A dish''s photos, newest review first, every photo of each review (0081), its main photo (review_photo_url, 0079) first — photos[0].url == cover_url. [] when it has none. Viewer-relative through RLS.';

-- ===========================================================================
-- 6. Backfill: every line's main photo, and every photo of a one-dish entry the author did not call
--    No dish (on a line the author did not set to No dish).
-- ===========================================================================
insert into public.photo_dishes (entry_id, photo_url, review_id)
select r.entry_id, r.photo_url, r.id
from public.reviews r
where r.entry_id is not null and r.photo_url is not null
  and exists (select 1 from public.entry_photos x where x.entry_id = r.entry_id and x.photo_url = r.photo_url)
on conflict (entry_id, photo_url) do nothing;

insert into public.photo_dishes (entry_id, photo_url, review_id)
select x.entry_id, x.photo_url, r.id
from public.entry_photos x
join public.entries e on e.id = x.entry_id
join public.reviews r on r.entry_id = x.entry_id
where not exists (select 1 from public.reviews o where o.entry_id = x.entry_id and o.id <> r.id)
  and not (r.photo_picked_at is not null and r.photo_url is null)
  and e.photo_picks -> x.photo_url is distinct from 'null'::jsonb
on conflict (entry_id, photo_url) do nothing;

-- 0083 — several dishes in one photo (22 Oct, Eamon: a shared plate, a sandwich and its fries).
--
-- Until now photo_dishes held one dish per photo (PK entry_id, photo_url) and the matcher was told
-- "at most one dish per photo", so a photo of the table named one dish and the rest lost it.
--
--   * photo_dishes: one row per (photo, dish). Each row may carry WHERE the dish sits in the photo,
--     a box in 0–1 fractions of the image (left, top, right, bottom), from the same match-photos
--     model call (no second call). No box = we know the dish is in it, not where.
--   * entries.photos_located_at: the entry was matched by the matcher that places dishes. Entries
--     matched before it are matched once more the first time someone opens their photos
--     (match-photos, unmatched_only), so old shared-plate photos get their dishes too.
--   * apply_photo_matches: several dishes per photo; boxes kept; a dish's main photo is its own
--     photo before a shared one, then the earliest.
--   * set_photo_dishes: the author ticks every dish a photo shows (the viewer's menu). The first, in
--     receipt order, is the photo's pick as before (entries.photo_picks); the rest are remembered in
--     entries.photo_also (url → [dish names]) so they outlive a re-sort too.
--   * restore_photo_picks: puts the picks and photo_also back on their lines, keeping boxes on rows
--     that stay; the 0081 upsert named the old primary key.
--   * set_review_photo: 0081's, and the photo's photo_also goes (one dish, by the old menu).
--   * dish_photos: each photo also says where this dish sits when the photo holds other dishes, so
--     the dish page can crop onto it.
--
-- Old builds read photo_dishes as "photo url → dish, first row wins" (PhotoDishRow.map), so more
-- rows per photo only mean they name one of the dishes, as before.
--
-- Volume: at most five photos × the entry's lines per entry. The new PK (entry_id, photo_url,
-- review_id) serves every per-entry read and write; photo_dishes_review_idx stays for dish_photos.

set search_path = public, extensions;

alter table public.photo_dishes drop constraint if exists photo_dishes_pkey;
alter table public.photo_dishes add primary key (entry_id, photo_url, review_id);

alter table public.photo_dishes
  add column if not exists box_left   real,
  add column if not exists box_top    real,
  add column if not exists box_right  real,
  add column if not exists box_bottom real;

alter table public.photo_dishes drop constraint if exists photo_dishes_box_valid;
alter table public.photo_dishes add constraint photo_dishes_box_valid check (
  (box_left is null and box_top is null and box_right is null and box_bottom is null)
  or (box_left >= 0 and box_top >= 0 and box_right <= 1 and box_bottom <= 1
      and box_left < box_right and box_top < box_bottom)
);

comment on table public.photo_dishes is
  '0081/0083: which dish lines each photo of an entry shows, and where (box_* in 0–1 fractions of the image; null = not placed). Several photos per line, several lines per photo. Written only by the photo-matching functions (service role / set_review_photo).';

alter table public.entries add column if not exists photos_located_at timestamptz;
alter table public.entries add column if not exists photo_also jsonb not null default '{}'::jsonb;

-- ===========================================================================
-- 1. apply_photo_matches — p_matches: [{review_id, photo_url, box?: [l, t, r, b]}]. p_located: the
--    matcher placed dishes (stamps photos_located_at).
-- ===========================================================================
drop function if exists public.apply_photo_matches(uuid, jsonb);

create or replace function public.apply_photo_matches(p_entry_id uuid, p_matches jsonb, p_located boolean default false)
returns int
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_n  int;
  v_ok jsonb;
begin
  -- Only photos really on the entry, not spoken for by the author (a pick, or a picked line's
  -- photo), onto lines of this entry nobody picked. One row per (photo, line); first claim wins.
  -- A box is kept only when it is whole and inside the image.
  with m as (
    select (x->>'review_id')::uuid as review_id, x->>'photo_url' as photo_url, n,
           case when jsonb_typeof(x->'box') = 'array' and jsonb_array_length(x->'box') = 4
                 and (select bool_and(jsonb_typeof(v) = 'number') from jsonb_array_elements(x->'box') v)
                then x->'box' end as box
    from jsonb_array_elements(coalesce(p_matches, '[]'::jsonb)) with ordinality t(x, n)
    where x ? 'review_id' and x ? 'photo_url'
  ),
  ok as (
    select distinct on (m.photo_url, m.review_id) m.review_id, m.photo_url, p.position,
           case when (m.box->>0)::real >= 0 and (m.box->>1)::real >= 0
                 and (m.box->>2)::real <= 1 and (m.box->>3)::real <= 1
                 and (m.box->>0)::real < (m.box->>2)::real and (m.box->>1)::real < (m.box->>3)::real
                then m.box end as box
    from m
    join public.entry_photos p on p.entry_id = p_entry_id and p.photo_url = m.photo_url
    join public.reviews r on r.id = m.review_id and r.entry_id = p_entry_id and r.photo_picked_at is null
    join public.entries e on e.id = p_entry_id
    where not (e.photo_picks ? m.photo_url)
      and not exists (
        select 1 from public.reviews h
        where h.entry_id = p_entry_id and h.photo_picked_at is not null and h.photo_url = m.photo_url
      )
    order by m.photo_url, m.review_id, m.n
  ),
  shared as (
    select photo_url, count(*) as dishes from ok group by photo_url
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'review_id', ok.review_id, 'photo_url', ok.photo_url, 'position', ok.position,
           'box', ok.box, 'solo', s.dishes = 1)), '[]'::jsonb)
    into v_ok
  from ok join shared s using (photo_url);

  -- Main photo: the dish on its own before a shared plate, then the earliest; else a photo the
  -- author ticked it in (set_photo_dishes), which no match touches.
  update public.reviews r
  set photo_url = coalesce((
    select o->>'photo_url' from jsonb_array_elements(v_ok) o
    where (o->>'review_id')::uuid = r.id
    order by (o->>'solo')::boolean desc, (o->>'position')::int
    limit 1
  ), (
    select pd.photo_url from public.photo_dishes pd
    join public.entry_photos x on x.entry_id = pd.entry_id and x.photo_url = pd.photo_url
    join public.entries e on e.id = pd.entry_id
    where pd.review_id = r.id and e.photo_picks ? pd.photo_url
    order by x.position
    limit 1
  ))
  where r.entry_id = p_entry_id and r.photo_picked_at is null;
  get diagnostics v_n = row_count;

  -- The open lines' photos are exactly this match; the author's own pairings stay.
  delete from public.photo_dishes pd
  using public.reviews r, public.entries e
  where pd.entry_id = p_entry_id
    and r.id = pd.review_id and r.photo_picked_at is null
    and e.id = p_entry_id and not (e.photo_picks ? pd.photo_url);
  insert into public.photo_dishes (entry_id, photo_url, review_id, box_left, box_top, box_right, box_bottom)
  select p_entry_id, o->>'photo_url', (o->>'review_id')::uuid,
         (o->'box'->>0)::real, (o->'box'->>1)::real, (o->'box'->>2)::real, (o->'box'->>3)::real
  from jsonb_array_elements(v_ok) o
  on conflict (entry_id, photo_url, review_id) do nothing;

  update public.entries
     set photos_matched_at = now(),
         photos_located_at = case when p_located then now() else photos_located_at end
   where id = p_entry_id;
  return v_n;
end; $$;

revoke all on function public.apply_photo_matches(uuid, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.apply_photo_matches(uuid, jsonb, boolean) to service_role;

-- ===========================================================================
-- 2. restore_photo_picks — after 0064's pass (main photos), every hand-named photo is exactly its
--    named dishes in photo_dishes: the pick, then photo_also. Rows that stay keep their box.
-- ===========================================================================
create or replace function public.restore_photo_picks(p_entry_id uuid)
returns int
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_n     int;
  v_named jsonb;
begin
  v_n := public.restore_photo_picks_0064(p_entry_id);

  -- photo_also follows photo_picks: a photo that left the entry, or was named one dish or none.
  update public.entries e
     set photo_also = coalesce((
           select jsonb_object_agg(k.key, k.value)
           from jsonb_each(e.photo_also) k
           where e.photo_picks ? k.key and e.photo_picks -> k.key <> 'null'::jsonb
         ), '{}'::jsonb)
   where e.id = p_entry_id and e.photo_also <> '{}'::jsonb;

  select coalesce(jsonb_agg(distinct jsonb_build_object('url', k.url, 'line', k.line)), '[]'::jsonb)
    into v_named
  from (
    -- The pick: the line holding the photo, else the first line by that name.
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
    union all
    -- The rest the author ticked: the first line by each name.
    select a.key, (select r.id from public.reviews r join public.dishes d on d.id = r.dish_id
                   where r.entry_id = p_entry_id and lower(d.name) = n.name
                   order by r.entry_position nulls last, r.created_at, r.id limit 1)
    from public.entries e, jsonb_each(e.photo_also) a, jsonb_array_elements_text(a.value) n(name)
    where e.id = p_entry_id and jsonb_typeof(a.value) = 'array'
  ) k
  where k.line is not null;

  delete from public.photo_dishes pd
  using public.entries e
  where pd.entry_id = p_entry_id and e.id = p_entry_id and e.photo_picks ? pd.photo_url
    and not exists (select 1 from jsonb_array_elements(v_named) n
                    where n->>'url' = pd.photo_url and (n->>'line')::uuid = pd.review_id);

  insert into public.photo_dishes (entry_id, photo_url, review_id)
  select p_entry_id, n->>'url', (n->>'line')::uuid from jsonb_array_elements(v_named) n
  on conflict (entry_id, photo_url, review_id) do nothing;

  return v_n;
end; $$;

revoke all on function public.restore_photo_picks(uuid) from public, anon, authenticated;
grant execute on function public.restore_photo_picks(uuid) to service_role;

-- ===========================================================================
-- 2b. set_photo_dishes — the author: this photo shows exactly these dishes (the viewer's menu, with
--     a tick per dish). Empty = No dish. The first in receipt order is the photo's pick, through
--     set_review_photo as ever; the rest join it in photo_dishes and photo_also. A dish that was
--     already in the photo keeps its box.
-- ===========================================================================
create or replace function public.set_photo_dishes(p_entry_id uuid, p_photo_url text, p_review_ids uuid[])
returns void
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_ids   uuid[];
  v_kept  jsonb;
  v_names jsonb;
begin
  if (select auth.uid()) is null then
    raise exception 'sign in to edit' using errcode = '42501';
  end if;
  if not exists (select 1 from public.entries e where e.id = p_entry_id and e.author_id = (select auth.uid())) then
    raise exception 'entry not found' using errcode = 'P0002';
  end if;
  -- Only this entry's lines, each once, in receipt order.
  select coalesce(array_agg(r.id order by r.entry_position nulls last, r.created_at, r.id), '{}')
    into v_ids
  from public.reviews r
  where r.entry_id = p_entry_id and r.id = any(coalesce(p_review_ids, '{}'));
  if cardinality(v_ids) <> cardinality(array(select distinct x from unnest(coalesce(p_review_ids, '{}')) x)) then
    raise exception 'line not on this entry' using errcode = '22023';
  end if;

  -- Boxes the matcher placed for dishes that stay in the photo.
  select coalesce(jsonb_agg(jsonb_build_object('line', pd.review_id,
           'box', jsonb_build_array(pd.box_left, pd.box_top, pd.box_right, pd.box_bottom))), '[]'::jsonb)
    into v_kept
  from public.photo_dishes pd
  where pd.entry_id = p_entry_id and pd.photo_url = p_photo_url
    and pd.review_id = any(v_ids) and pd.box_left is not null;

  perform public.set_review_photo(p_entry_id, p_photo_url, v_ids[1]);
  update public.entries e set photo_also = e.photo_also - p_photo_url
  where e.id = p_entry_id and e.photo_also ? p_photo_url;

  if cardinality(v_ids) > 1 then
    insert into public.photo_dishes (entry_id, photo_url, review_id)
    select p_entry_id, p_photo_url, x from unnest(v_ids[2:]) x
    on conflict (entry_id, photo_url, review_id) do nothing;
    select jsonb_agg(lower(d.name) order by r.entry_position nulls last, r.created_at, r.id)
      into v_names
    from public.reviews r join public.dishes d on d.id = r.dish_id
    where r.id = any(v_ids[2:]);
    update public.entries e set photo_also = e.photo_also || jsonb_build_object(p_photo_url, v_names)
    where e.id = p_entry_id;
    -- A ticked dish with no photo of its own shows this one.
    update public.reviews r set photo_url = p_photo_url
    where r.id = any(v_ids[2:]) and r.photo_url is null;
  end if;

  update public.photo_dishes pd
     set box_left = (k->'box'->>0)::real, box_top = (k->'box'->>1)::real,
         box_right = (k->'box'->>2)::real, box_bottom = (k->'box'->>3)::real
  from jsonb_array_elements(v_kept) k
  where pd.entry_id = p_entry_id and pd.photo_url = p_photo_url and pd.review_id = (k->>'line')::uuid;
end; $$;

revoke all on function public.set_photo_dishes(uuid, text, uuid[]) from public, anon;
grant execute on function public.set_photo_dishes(uuid, text, uuid[]) to authenticated;

-- set_review_photo (0081) names one dish or none: whatever else the photo was ticked with goes.
create or replace function public.photo_also_forget()
returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.photo_picks is distinct from old.photo_picks then
    new.photo_also := coalesce((
      select jsonb_object_agg(k.key, k.value) from jsonb_each(new.photo_also) k
      where new.photo_picks ? k.key and new.photo_picks -> k.key <> 'null'::jsonb
        and not (old.photo_picks ? k.key and old.photo_picks -> k.key is distinct from new.photo_picks -> k.key)
    ), '{}'::jsonb);
  end if;
  return new;
end; $$;

drop trigger if exists entries_photo_also_forget on public.entries;
create trigger entries_photo_also_forget before update of photo_picks on public.entries
  for each row when (old.photo_also <> '{}'::jsonb) execute function public.photo_also_forget();

-- ===========================================================================
-- 3. dish_photos — 0081's, plus, on a photo this dish shares with other dishes and was placed in,
--    `box` ([l, t, r, b]) and `with` (the other placed dishes: [{name, box}]), so the dish page crops
--    onto it and the viewer can name the rest. A photo of the dish alone has neither: shown whole.
-- ===========================================================================
create or replace function public.dish_photos(p_dish_id uuid, p_limit int default 8)
returns jsonb
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(
    jsonb_agg(jsonb_strip_nulls(jsonb_build_object('url', p.url, 'entry_id', p.entry_id, 'box', p.box,
                                                   'with', case when p.box is not null then p.others end))
              order by p.created_at desc, p.review_id desc, p.ord),
    '[]'::jsonb)
  from (
    select v.id as review_id, v.entry_id, v.created_at, ph.url, ph.ord,
           (select jsonb_build_array(pd.box_left, pd.box_top, pd.box_right, pd.box_bottom)
            from public.photo_dishes pd
            where pd.entry_id = v.entry_id and pd.photo_url = ph.url and pd.review_id = v.id
              and pd.box_left is not null
              and exists (select 1 from public.photo_dishes o
                          where o.entry_id = pd.entry_id and o.photo_url = pd.photo_url
                            and o.review_id <> pd.review_id)) as box,
           (select jsonb_agg(jsonb_build_object('name', d.name,
                     'box', jsonb_build_array(o.box_left, o.box_top, o.box_right, o.box_bottom)) order by o.box_left)
            from public.photo_dishes o
            join public.reviews r on r.id = o.review_id
            join public.dishes d on d.id = r.dish_id
            where o.entry_id = v.entry_id and o.photo_url = ph.url and o.review_id <> v.id
              and o.box_left is not null) as others
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
  'A dish''s photos, newest review first, every photo of each review (0081), its main photo (review_photo_url, 0079) first — photos[0].url == cover_url. `box` [l,t,r,b] (0–1) and `with` [{name, box}] (the other placed dishes) where the photo is shared and this dish was placed (0083). [] when it has none. Viewer-relative through RLS.';

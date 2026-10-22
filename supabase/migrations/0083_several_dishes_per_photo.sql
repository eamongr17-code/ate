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
--   * restore_photo_picks: the 0081 upsert named the old primary key; same rows, delete-then-insert.
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

  -- Main photo: the dish on its own before a shared plate, then the earliest.
  update public.reviews r
  set photo_url = (
    select o->>'photo_url' from jsonb_array_elements(v_ok) o
    where (o->>'review_id')::uuid = r.id
    order by (o->>'solo')::boolean desc, (o->>'position')::int
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
-- 2. restore_photo_picks — 0081's, without the old primary key's upsert. A named photo is the
--    author's: its rows are exactly the one dish they named.
-- ===========================================================================
create or replace function public.restore_photo_picks(p_entry_id uuid)
returns int
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_n int;
begin
  v_n := public.restore_photo_picks_0064(p_entry_id);

  delete from public.photo_dishes pd
  using public.entries e
  where pd.entry_id = p_entry_id and e.id = p_entry_id and e.photo_picks ? pd.photo_url;

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
  on conflict (entry_id, photo_url, review_id) do nothing;

  return v_n;
end; $$;

revoke all on function public.restore_photo_picks(uuid) from public, anon, authenticated;
grant execute on function public.restore_photo_picks(uuid) to service_role;

-- ===========================================================================
-- 3. dish_photos — 0081's, plus `box` ([l, t, r, b]) on a photo this dish shares with other dishes
--    and was placed in. A photo of the dish alone has no box: it is shown whole.
-- ===========================================================================
create or replace function public.dish_photos(p_dish_id uuid, p_limit int default 8)
returns jsonb
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select coalesce(
    jsonb_agg(jsonb_strip_nulls(jsonb_build_object('url', p.url, 'entry_id', p.entry_id, 'box', p.box))
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
                            and o.review_id <> pd.review_id)) as box
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
  'A dish''s photos, newest review first, every photo of each review (0081), its main photo (review_photo_url, 0079) first — photos[0].url == cover_url. `box` [l,t,r,b] (0–1) where the photo is shared with other dishes and this one was placed (0083). [] when it has none. Viewer-relative through RLS.';

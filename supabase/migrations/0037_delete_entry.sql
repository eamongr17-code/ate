-- 0037_delete_entry.sql
-- Ate backend — round 3: delete a visit, in one call, and hand back the photo files to purge.
--
-- Until now the only path was `DELETE /rest/v1/entries?id=eq.<uuid>`: correct rows, but the client had
-- no way to learn which storage objects the entry owned once the rows were gone, so photos leaked in
-- `review-photos/<uid>/` forever. `delete_entry` reads the entry's photo paths, deletes the entry, and
-- returns the paths — one transaction, owner only.
--
-- WHAT GOES (all by existing FK cascades from `entries`, audited):
--   entry_photos (0018, cascade) · reviews.entry_id (0018, cascade) — and through each review its
--   review_likes, comments (+ comment_likes), review_tags, notifications (0003/0010/0011, cascade) ·
--   reports.entry_id (0019, cascade) · entries_private_before_0033 (cascade). Dietary tags are a
--   column on the review, so they go with it.
--   And, by 0039's `entries_purge_preview_cache` trigger, every early-sort plan the author has cached
--   (they hold verbatim draft text).
-- WHAT STAYS: dishes and restaurants (shared catalogue — a dish this entry created stays, as a shell
--   `place_dishes`/search already hide until someone logs it); saves (the SAVER'S rows —
--   `saves.source_entry_id` is SET NULL, provenance handle `source_user_id` survives);
--   `profiles.entry_seq` (order numbers are never reused — "Order #" is print order).
-- AGGREGATES: every number (dish_stats, restaurant_stats, place/dish/profile summaries, histograms,
--   statements, covers, search counts) is derived live from these rows, so they are correct the
--   moment this commits. The one stored counter touched, the legacy per-author review count (0005
--   `reviews_author_count_aiud`), is trigger-maintained on the cascaded review deletes.
-- VIEWER CACHES: the entry vanishes from `entry_cards`, the feed, profile, place, dish and search
--   reads because all of them read these tables; nothing is materialised.
--
-- PHOTO PATHS: bucket-relative object names (`<uid>/<file>`, exactly what
--   `storage.from("review-photos").remove([...])` takes), parsed from the entry's `entry_photos.photo_url`
--   (plus a legacy `reviews.photo_url` on its lines, if any), restricted to the CALLER'S folder, minus
--   any URL another row still references, plus each original's thumbnail sibling
--   (`<path minus extension>_t.jpg`, round 3). A thumbnail that was never uploaded is harmless to
--   remove. Storage deletion stays the client's: the owner-only storage policy (0007) is the gate.
--
-- WIRE IMPACT: ADDITIVE — new RPC `delete_entry(p_entry_id uuid) → jsonb {photo_paths: text[]}`.
--   The raw `DELETE /rest/v1/entries` path is unchanged (still works, still leaks the files).
--   Errors: 42501 not signed in / not the author · P0002 no such entry (treat as already deleted).

set search_path = public, extensions;

create or replace function public.delete_entry(p_entry_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_author  uuid;
  v_paths   text[];
  v_deleted int;
begin
  if v_uid is null then
    raise exception 'delete_entry requires an authenticated caller' using errcode = '42501';
  end if;

  -- Lock the row so a concurrent sort/correction cannot write lines under an entry mid-delete.
  select e.author_id into v_author
  from public.entries e
  where e.id = p_entry_id
  for update;

  if not found then
    raise exception 'entry % not found', p_entry_id using errcode = 'P0002';
  end if;
  if v_author <> v_uid then
    raise exception 'delete_entry: not your entry' using errcode = '42501';
  end if;

  -- The files, read BEFORE the rows that name them go.
  with urls as (
    select x.photo_url as url
    from public.entry_photos x
    where x.entry_id = p_entry_id
    union
    select v.photo_url
    from public.reviews v
    where v.entry_id = p_entry_id and v.photo_url is not null
  ),
  unshared as (
    -- a URL another entry or line still prints is not ours to purge
    select u.url
    from urls u
    where not exists (
            select 1 from public.entry_photos o
            where o.photo_url = u.url and o.entry_id <> p_entry_id)
      and not exists (
            select 1 from public.reviews o
            where o.photo_url = u.url and o.entry_id is distinct from p_entry_id)
  ),
  originals as (
    select (regexp_match(
              u.url,
              '/storage/v1/object/(?:public|sign|authenticated)/review-photos/([^?#]+)'
           ))[1] as path
    from unshared u
  ),
  mine as (
    select o.path
    from originals o
    where o.path is not null
      and o.path like v_uid::text || '/%'
      and position('..' in o.path) = 0
  ),
  both_sizes as (
    select m.path from mine m
    union
    select regexp_replace(m.path, '\.[^./]*$', '') || '_t.jpg'
    from mine m
    where m.path !~ '_t\.jpg$'
  )
  select coalesce(array_agg(b.path order by b.path), '{}'::text[])
    into v_paths
  from both_sizes b;

  -- The rows. Every dependent goes by FK cascade (header); the catalogue stays.
  delete from public.entries where id = p_entry_id;
  get diagnostics v_deleted = row_count;
  if v_deleted <> 1 then
    raise exception 'delete_entry: entry % was not deleted', p_entry_id using errcode = 'P0001';
  end if;

  return jsonb_build_object('photo_paths', to_jsonb(v_paths));
end; $$;

comment on function public.delete_entry(uuid) is
  'Deletes the CALLER''S entry (42501 otherwise; P0002 if gone) and, by FK cascade, its photos rows, its dish lines (tags with them), their likes/comments/notifications and reports on it. Dishes/restaurants stay; saves stay with source_entry_id nulled. Returns {photo_paths: [...]} — bucket-relative review-photos object names under the caller''s folder (originals + their _t.jpg thumbnails) for the client to remove. Round 3.';

revoke all on function public.delete_entry(uuid) from public, anon;
grant execute on function public.delete_entry(uuid) to authenticated;

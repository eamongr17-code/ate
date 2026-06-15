-- 0007_storage.sql
-- Ate backend — Wave 0, BE-7: Storage buckets + RLS (data-model §6;
-- integration-design "Storage").
-- Two PUBLIC-read buckets: review-photos + avatars. Authenticated users may
-- upload/update/delete ONLY under their own auth.uid()/… path prefix.
-- Public read is what the *_url columns reference (durable CDN URLs, not blobs).
--
-- Path convention (enforced by the policies below):
--   review-photos/<auth.uid()>/<reviewId or filename>.<ext>
--   avatars/<auth.uid()>/<filename>.<ext>
-- storage.foldername(name)[1] = the first path segment = the owner uid.

set search_path = public, extensions;

-- Buckets (public read; idempotent insert).
insert into storage.buckets (id, name, public)
values ('review-photos', 'review-photos', true)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- review-photos policies
-- ---------------------------------------------------------------------------
create policy "review_photos_public_read" on storage.objects
  for select to public
  using (bucket_id = 'review-photos');

create policy "review_photos_insert_own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'review-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "review_photos_update_own" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'review-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "review_photos_delete_own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'review-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ---------------------------------------------------------------------------
-- avatars policies
-- ---------------------------------------------------------------------------
create policy "avatars_public_read" on storage.objects
  for select to public
  using (bucket_id = 'avatars');

create policy "avatars_insert_own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "avatars_update_own" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "avatars_delete_own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

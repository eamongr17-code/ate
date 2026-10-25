-- 0092 — Size and type limits on the two public photo buckets.
--
-- `review-photos` and `avatars` (0007) were created with no file_size_limit and no
-- allowed_mime_types, so any signed-in account could upload a file of any size or type into its
-- own folder and have it served publicly. On the Free plan's 1 GB storage / 5 GB egress that is
-- one abusive account away from breaking photos for everyone.
--
-- Every client upload is a JPEG: entry photos are downscaled to 1600 px at quality 0.8 (~1 MB),
-- avatars and list covers are smaller still. The caps below leave generous headroom; PNG is
-- allowed so a future client change can't be silently refused. `feedback-screenshots` (0082)
-- already has 3 MB / JPEG+PNG.
--
-- Limits apply to new uploads only; existing objects are untouched.

update storage.buckets
   set file_size_limit = 10485760,                       -- 10 MB
       allowed_mime_types = array['image/jpeg', 'image/png']
 where id = 'review-photos';

update storage.buckets
   set file_size_limit = 5242880,                        -- 5 MB
       allowed_mime_types = array['image/jpeg', 'image/png']
 where id = 'avatars';

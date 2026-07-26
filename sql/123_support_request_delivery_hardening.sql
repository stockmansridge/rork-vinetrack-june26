-- 123_support_request_delivery_hardening.sql
-- Makes the private support attachment contract explicit for all clients.
-- Existing objects and support request rows are preserved.

begin;

-- Mobile clients upload compressed JPEG screenshots/photos. PNG and WebP allow
-- portal screenshots without opening the bucket to arbitrary file types.
update storage.buckets
set
  file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']::text[]
where id = 'support-attachments';

commit;

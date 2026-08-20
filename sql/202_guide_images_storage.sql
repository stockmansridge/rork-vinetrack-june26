-- 202_guide_images_storage.sql
-- How VineTrack Works — Guide Images storage bucket (Lovable Stage 2.9/4A/4B).
--
-- Provisions the `guide-images` Storage bucket expected by the Lovable
-- System Admin → Guide Images manager. Audited against the Lovable repo
-- (stockmansridge/vinetrack-a0d975b1 @ 714a9565):
--   src/lib/guide/guideImageStore.ts   (bucket, paths, URL + persistence)
--   src/lib/guide/guideImages.ts       (slot keys, MIME accept, 10 MB max)
--   src/pages/admin/GuideImagesPage.tsx (upload / focus / remove flows)
--
-- Contract found in that audit:
--   * Bucket id (exact):  guide-images            (GUIDE_IMAGE_BUCKET)
--   * Object paths:       {image-key}/{epoch-ms}.{jpg|png|webp}
--                         e.g. hero/1755612345678.jpg, pins.step.drop/….webp
--                         Image keys are the stable slot keys (hero, setup,
--                         pins, trips, sprays, work-tasks, operational-tools,
--                         reports, <area>.step.<name>, tool.<id>, reports.<x>);
--                         some contain dots. Keys are never changed here.
--   * Read model:         supabase.storage.getPublicUrl(path) with a
--                         ?v=<updated_at> cache-buster → the bucket MUST be
--                         PUBLIC. No signed URLs, no list(), no download()
--                         anywhere in the guide implementation. These are
--                         non-sensitive product-guide images.
--   * Metadata:           the key → {path, focus, updated_at} map persists in
--                         the EXISTING system_feature_flags mechanism (sql/062)
--                         under the key 'guide.visual_assets', written through
--                         set_system_feature_flag() which is already System
--                         Admin-gated. NO new table is created here.
--   * Writes:             System Admin only — public.is_system_admin()
--                         (sql/062, active-only). Upload uses upsert:true
--                         (insert + overwrite-update); replace and remove both
--                         call storage remove() (delete). Postgres RLS requires
--                         SELECT visibility for DELETE…RETURNING and for upsert
--                         overwrites, so admins also get a scoped select
--                         policy. Public display reads use the public-bucket
--                         object endpoint, which does not consult RLS.
--   * Limits:             10 MB (10485760 bytes); image/jpeg, image/png,
--                         image/webp — mirrors GUIDE_IMAGE_ACCEPT /
--                         GUIDE_IMAGE_MAX_BYTES and the sql/123 bucket-limit
--                         convention used for support-attachments.
--
-- Safety:
--   * Additive + idempotent: safe to re-run. If the bucket already exists the
--     insert normalises its configuration instead of duplicating it.
--   * Scope: touches ONLY storage.buckets row 'guide-images' and
--     storage.objects policies prefixed guide_images_. No other buckets,
--     tables, RPCs or RLS are modified. No objects are deleted.

begin;

-- Preflight: the System Admin authority must exist (created by sql/062).
do $$
begin
  if to_regprocedure('public.is_system_admin()') is null then
    raise exception 'sql/202 precondition failed: public.is_system_admin() is missing (apply sql/062 first)';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- Bucket: public content bucket with MIME + size limits.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'guide-images',
  'guide-images',
  true,
  10485760, -- 10 MB
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
  set public             = true,
      file_size_limit    = 10485760,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']::text[];

-- ---------------------------------------------------------------------------
-- storage.objects policies — every predicate is scoped to
-- bucket_id = 'guide-images' so no other bucket's access model changes.
-- ---------------------------------------------------------------------------

-- System Admin read via the storage API. Needed because the admin replace /
-- remove flows delete objects (DELETE…RETURNING needs SELECT visibility) and
-- upload uses upsert:true (an overwrite is an UPDATE, which also references
-- the existing row). Guide display for everyone else uses the public object
-- endpoint, which is served by the bucket's public flag — not by this policy.
drop policy if exists "guide_images_select_admin" on storage.objects;
create policy "guide_images_select_admin"
on storage.objects for select
to authenticated
using (
  bucket_id = 'guide-images'
  and public.is_system_admin()
);

drop policy if exists "guide_images_insert_admin" on storage.objects;
create policy "guide_images_insert_admin"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'guide-images'
  and public.is_system_admin()
);

drop policy if exists "guide_images_update_admin" on storage.objects;
create policy "guide_images_update_admin"
on storage.objects for update
to authenticated
using (
  bucket_id = 'guide-images'
  and public.is_system_admin()
)
with check (
  bucket_id = 'guide-images'
  and public.is_system_admin()
);

drop policy if exists "guide_images_delete_admin" on storage.objects;
create policy "guide_images_delete_admin"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'guide-images'
  and public.is_system_admin()
);

commit;

-- ---------------------------------------------------------------------------
-- Verification (read-only; run after applying — mutates nothing)
-- ---------------------------------------------------------------------------
-- 1. Bucket exists with the intended configuration:
--      select id, public, file_size_limit, allowed_mime_types
--        from storage.buckets
--       where id = 'guide-images';
--    Expect one row: public = true, file_size_limit = 10485760,
--    allowed_mime_types = {image/jpeg,image/png,image/webp}.
--
-- 2. Exactly these four policies exist for the bucket:
--      select policyname, cmd, roles
--        from pg_policies
--       where schemaname = 'storage' and tablename = 'objects'
--         and policyname like 'guide_images_%'
--       order by policyname;
--    Expect: guide_images_delete_admin (DELETE), guide_images_insert_admin
--    (INSERT), guide_images_select_admin (SELECT), guide_images_update_admin
--    (UPDATE) — all to {authenticated}.
--
-- 3. No guide-images policy is unrestricted, and all are bucket-scoped +
--    System Admin-gated:
--      select policyname
--        from pg_policies
--       where schemaname = 'storage' and tablename = 'objects'
--         and policyname like 'guide_images_%'
--         and (
--               coalesce(qual, '')       = 'true'
--            or coalesce(with_check, '') = 'true'
--            or (coalesce(qual, '') || coalesce(with_check, ''))
--                 not like '%guide-images%'
--            or (coalesce(qual, '') || coalesce(with_check, ''))
--                 not like '%is_system_admin%'
--         );
--    Expect: 0 rows.
--
-- 4. No other bucket was touched (compare against the pre-apply list):
--      select id, public from storage.buckets order by id;

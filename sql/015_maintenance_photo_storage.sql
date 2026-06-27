-- Phase 15H: Shared maintenance log invoice / photo storage.
--
-- Adds private storage bucket "vineyard-maintenance-photos" with RLS aligned
-- to maintenance_logs row-level access. Path layout:
--   {vineyard_id}/maintenance/{maintenance_log_id}/photo.jpg
--
-- The maintenance_logs.photo_path column was already introduced by
-- sql/014_work_maintenance_yield_sync.sql; this migration only sets up
-- Storage so the path can be uploaded/downloaded by clients.

insert into storage.buckets (id, name, public)
values ('vineyard-maintenance-photos', 'vineyard-maintenance-photos', false)
on conflict (id) do nothing;

drop policy if exists "vineyard_maintenance_photos_select_members" on storage.objects;
create policy "vineyard_maintenance_photos_select_members"
on storage.objects for select
to authenticated
using (
  bucket_id = 'vineyard-maintenance-photos'
  and public.is_vineyard_member(public.storage_first_folder_uuid(name))
);

-- Anyone who can create/update a maintenance log can upload its photo.
drop policy if exists "vineyard_maintenance_photos_insert_members" on storage.objects;
create policy "vineyard_maintenance_photos_insert_members"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'vineyard-maintenance-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager', 'supervisor', 'operator']
      )
);

drop policy if exists "vineyard_maintenance_photos_update_members" on storage.objects;
create policy "vineyard_maintenance_photos_update_members"
on storage.objects for update
to authenticated
using (
  bucket_id = 'vineyard-maintenance-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager', 'supervisor', 'operator']
      )
)
with check (
  bucket_id = 'vineyard-maintenance-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager', 'supervisor', 'operator']
      )
);

-- Only roles that can soft-delete a maintenance log may delete its photo.
drop policy if exists "vineyard_maintenance_photos_delete_managers" on storage.objects;
create policy "vineyard_maintenance_photos_delete_managers"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'vineyard-maintenance-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager', 'supervisor']
      )
);

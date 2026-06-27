-- Phase 15F: Shared photo / image sync via Supabase Storage.
--
-- Adds:
--   * private storage bucket  "vineyard-pin-photos"
--     Path: {vineyard_id}/pins/{pin_id}/photo.jpg
--   * private storage bucket  "vineyard-el-stage-images"
--     Path: {vineyard_id}/el-stages/{stage_code}.jpg
--   * pins.photo_path column
--   * vineyard_growth_stage_images table for custom E-L reference image metadata
--   * RLS policies based on vineyard membership / role helpers
--
-- Repair photos are stored on VinePin (mode = 'Repairs'), so they reuse the
-- pin photo bucket. Maintenance log photos remain local-only for now since
-- the maintenance_logs table is not yet synced.

-- =============================================================
-- 1. Pin photos
-- =============================================================

alter table public.pins
  add column if not exists photo_path text;

insert into storage.buckets (id, name, public)
values ('vineyard-pin-photos', 'vineyard-pin-photos', false)
on conflict (id) do nothing;

drop policy if exists "vineyard_pin_photos_select_members" on storage.objects;
create policy "vineyard_pin_photos_select_members"
on storage.objects for select
to authenticated
using (
  bucket_id = 'vineyard-pin-photos'
  and public.is_vineyard_member(public.storage_first_folder_uuid(name))
);

drop policy if exists "vineyard_pin_photos_insert_members" on storage.objects;
create policy "vineyard_pin_photos_insert_members"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'vineyard-pin-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager', 'supervisor', 'operator']
      )
);

drop policy if exists "vineyard_pin_photos_update_members" on storage.objects;
create policy "vineyard_pin_photos_update_members"
on storage.objects for update
to authenticated
using (
  bucket_id = 'vineyard-pin-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager', 'supervisor', 'operator']
      )
)
with check (
  bucket_id = 'vineyard-pin-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager', 'supervisor', 'operator']
      )
);

-- Only roles that can soft-delete a pin can delete its photo.
drop policy if exists "vineyard_pin_photos_delete_managers" on storage.objects;
create policy "vineyard_pin_photos_delete_managers"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'vineyard-pin-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager', 'supervisor']
      )
);

-- =============================================================
-- 2. Custom E-L stage reference images
-- =============================================================

create table if not exists public.vineyard_growth_stage_images (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  stage_code text not null,
  image_path text not null,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1,
  unique (vineyard_id, stage_code)
);

create index if not exists idx_vgsi_vineyard_id on public.vineyard_growth_stage_images (vineyard_id);
create index if not exists idx_vgsi_updated_at on public.vineyard_growth_stage_images (updated_at);
create index if not exists idx_vgsi_deleted_at on public.vineyard_growth_stage_images (deleted_at);

create or replace trigger vgsi_set_updated_at
before update on public.vineyard_growth_stage_images
for each row execute function public.set_updated_at();

alter table public.vineyard_growth_stage_images enable row level security;

drop policy if exists "vgsi_select_members" on public.vineyard_growth_stage_images;
create policy "vgsi_select_members"
on public.vineyard_growth_stage_images for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "vgsi_insert_managers" on public.vineyard_growth_stage_images;
create policy "vgsi_insert_managers"
on public.vineyard_growth_stage_images for insert
to authenticated
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager'])
);

drop policy if exists "vgsi_update_managers" on public.vineyard_growth_stage_images;
create policy "vgsi_update_managers"
on public.vineyard_growth_stage_images for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "vgsi_no_client_hard_delete" on public.vineyard_growth_stage_images;
create policy "vgsi_no_client_hard_delete"
on public.vineyard_growth_stage_images for delete
to authenticated
using (false);

create or replace function public.soft_delete_growth_stage_image(p_image_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select vineyard_id into v_vineyard_id
  from public.vineyard_growth_stage_images
  where id = p_image_id;

  if v_vineyard_id is null then
    raise exception 'Growth stage image not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete growth stage image';
  end if;

  update public.vineyard_growth_stage_images
  set deleted_at = now(),
      updated_by = auth.uid()
  where id = p_image_id;
end;
$function$;

revoke all on function public.soft_delete_growth_stage_image(uuid) from public;
grant execute on function public.soft_delete_growth_stage_image(uuid) to authenticated;

-- Storage bucket for E-L reference images.

insert into storage.buckets (id, name, public)
values ('vineyard-el-stage-images', 'vineyard-el-stage-images', false)
on conflict (id) do nothing;

drop policy if exists "vineyard_el_stage_images_select_members" on storage.objects;
create policy "vineyard_el_stage_images_select_members"
on storage.objects for select
to authenticated
using (
  bucket_id = 'vineyard-el-stage-images'
  and public.is_vineyard_member(public.storage_first_folder_uuid(name))
);

drop policy if exists "vineyard_el_stage_images_insert_managers" on storage.objects;
create policy "vineyard_el_stage_images_insert_managers"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'vineyard-el-stage-images'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager']
      )
);

drop policy if exists "vineyard_el_stage_images_update_managers" on storage.objects;
create policy "vineyard_el_stage_images_update_managers"
on storage.objects for update
to authenticated
using (
  bucket_id = 'vineyard-el-stage-images'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager']
      )
)
with check (
  bucket_id = 'vineyard-el-stage-images'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager']
      )
);

drop policy if exists "vineyard_el_stage_images_delete_managers" on storage.objects;
create policy "vineyard_el_stage_images_delete_managers"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'vineyard-el-stage-images'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager']
      )
);

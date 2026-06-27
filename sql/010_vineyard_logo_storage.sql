-- Phase 14C: Vineyard logo synced via Supabase Storage.
--
-- Adds:
--   * vineyards.logo_updated_at   timestamptz null
--   * private storage bucket      "vineyard-logos"
--   * RLS policies so vineyard members can read the logo, and only
--     owners/managers can upload/update/delete.
--
-- Logo objects are stored at path:   {vineyard_id}/logo.jpg
-- so the first folder name is the vineyard UUID, which the policies
-- use to authorise access via existing helper functions.

alter table public.vineyards
  add column if not exists logo_updated_at timestamptz;

-- Bucket --------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('vineyard-logos', 'vineyard-logos', false)
on conflict (id) do nothing;

-- Helper: safely extract first folder component as UUID. Returns null
-- if the segment isn't a valid UUID, so RLS policies just deny access
-- instead of erroring out.
create or replace function public.storage_first_folder_uuid(p_name text)
returns uuid
language plpgsql
immutable
as $$
declare
  v_first text;
  v_uuid uuid;
begin
  v_first := (storage.foldername(p_name))[1];
  if v_first is null or v_first = '' then
    return null;
  end if;
  begin
    v_uuid := v_first::uuid;
  exception when others then
    return null;
  end;
  return v_uuid;
end;
$$;

-- Policies ------------------------------------------------------------

drop policy if exists "vineyard_logos_select_members" on storage.objects;
create policy "vineyard_logos_select_members"
on storage.objects for select
to authenticated
using (
  bucket_id = 'vineyard-logos'
  and public.is_vineyard_member(public.storage_first_folder_uuid(name))
);

drop policy if exists "vineyard_logos_insert_managers" on storage.objects;
create policy "vineyard_logos_insert_managers"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'vineyard-logos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager']
      )
);

drop policy if exists "vineyard_logos_update_managers" on storage.objects;
create policy "vineyard_logos_update_managers"
on storage.objects for update
to authenticated
using (
  bucket_id = 'vineyard-logos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager']
      )
)
with check (
  bucket_id = 'vineyard-logos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager']
      )
);

drop policy if exists "vineyard_logos_delete_managers" on storage.objects;
create policy "vineyard_logos_delete_managers"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'vineyard-logos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner', 'manager']
      )
);

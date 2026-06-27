-- =====================================================================
-- 048 · Damage Records — portal-facing extension (additive only)
-- =====================================================================
-- Adds the columns the Lovable web portal needs to create / display
-- damage records, on top of the iOS-owned `public.damage_records` table
-- defined in 014_work_maintenance_yield_sync.sql.
--
-- All changes are ADDITIVE — existing iOS reads/writes continue to work.
--
-- Notes / deferred items:
--   * Validation trigger from the proposal is intentionally NOT applied:
--     existing iOS rows use capitalised damage_type values (e.g. 'Frost',
--     'Hail') while the proposal validates snake_case codes. Codes need
--     to be reconciled before any CHECK / trigger is enabled.
--   * RLS already uses the security-definer helpers `is_vineyard_member`
--     and `has_vineyard_role`. The proposal explicitly recommends reusing
--     these, so we leave the existing policies in place.
--   * Hard DELETE remains denied (see 014); soft-delete via UPDATE only.
-- =====================================================================

-- ----- 1. Additive columns -------------------------------------------------
alter table public.damage_records
  add column if not exists row_number     integer          null,
  add column if not exists side           text             null,  -- 'left' | 'right' | 'both' | 'unknown'
  add column if not exists severity       text             null,  -- 'low' | 'medium' | 'high' | 'severe'
  add column if not exists status         text             not null default 'open',
                                                                  -- 'open' | 'monitoring' | 'resolved'
  add column if not exists date_observed  timestamptz      null,
  add column if not exists operator_name  text             null,
  add column if not exists latitude       double precision null,
  add column if not exists longitude      double precision null,
  add column if not exists pin_id         uuid             null,
  add column if not exists trip_id        uuid             null,
  add column if not exists photo_urls     text[]           null;

-- Best-effort FKs (only if the referenced tables exist in this project)
do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema = 'public' and table_name = 'pins')
     and not exists (select 1 from information_schema.table_constraints
                     where table_schema = 'public'
                       and table_name = 'damage_records'
                       and constraint_name = 'damage_records_pin_id_fkey') then
    alter table public.damage_records
      add constraint damage_records_pin_id_fkey
      foreign key (pin_id) references public.pins(id) on delete set null;
  end if;

  if exists (select 1 from information_schema.tables
             where table_schema = 'public' and table_name = 'trips')
     and not exists (select 1 from information_schema.table_constraints
                     where table_schema = 'public'
                       and table_name = 'damage_records'
                       and constraint_name = 'damage_records_trip_id_fkey') then
    alter table public.damage_records
      add constraint damage_records_trip_id_fkey
      foreign key (trip_id) references public.trips(id) on delete set null;
  end if;
end$$;

-- ----- 2. Indexes ---------------------------------------------------------
create index if not exists damage_records_vineyard_observed_idx
  on public.damage_records (vineyard_id, coalesce(date_observed, created_at) desc)
  where deleted_at is null;

create index if not exists damage_records_status_idx
  on public.damage_records (vineyard_id, status)
  where deleted_at is null;

-- (idx_damage_records_paddock_id already created in 014.)

-- ----- 3. Optional damage-photos storage bucket ---------------------------
-- Private bucket. Object path convention:
--   {vineyard_id}/{damage_record_id}/{uuid}.jpg
insert into storage.buckets (id, name, public)
values ('damage-photos', 'damage-photos', false)
on conflict (id) do nothing;

drop policy if exists "Members can read damage photos" on storage.objects;
create policy "Members can read damage photos"
on storage.objects for select to authenticated
using (
  bucket_id = 'damage-photos'
  and exists (
    select 1 from public.vineyard_members vm
    where vm.user_id = auth.uid()
      and vm.vineyard_id::text = (storage.foldername(name))[1]
  )
);

drop policy if exists "Members can upload damage photos" on storage.objects;
create policy "Members can upload damage photos"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'damage-photos'
  and exists (
    select 1 from public.vineyard_members vm
    where vm.user_id = auth.uid()
      and vm.vineyard_id::text = (storage.foldername(name))[1]
  )
);

drop policy if exists "Managers can delete damage photos" on storage.objects;
create policy "Managers can delete damage photos"
on storage.objects for delete to authenticated
using (
  bucket_id = 'damage-photos'
  and exists (
    select 1 from public.vineyard_members vm
    where vm.user_id = auth.uid()
      and vm.vineyard_id::text = (storage.foldername(name))[1]
      and vm.role in ('owner','manager')
  )
);

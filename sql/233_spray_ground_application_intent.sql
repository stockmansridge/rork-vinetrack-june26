-- Additive persistence for banded ground-application intent.
-- Apply manually after review. Historical NULL means "not recorded"; no backfill.
begin;

alter table public.spray_records
  add column if not exists ground_application_target text null,
  add column if not exists carrier_area_basis text null;

alter table public.spray_jobs
  add column if not exists ground_application_target text null,
  add column if not exists carrier_area_basis text null;

alter table public.spray_records
  drop constraint if exists spray_records_ground_application_target_check,
  add constraint spray_records_ground_application_target_check
    check (ground_application_target is null or ground_application_target in ('undervine', 'midrow')),
  drop constraint if exists spray_records_carrier_area_basis_check,
  add constraint spray_records_carrier_area_basis_check
    check (carrier_area_basis is null or carrier_area_basis in ('treated_area', 'whole_block_area'));

alter table public.spray_jobs
  drop constraint if exists spray_jobs_ground_application_target_check,
  add constraint spray_jobs_ground_application_target_check
    check (ground_application_target is null or ground_application_target in ('undervine', 'midrow')),
  drop constraint if exists spray_jobs_carrier_area_basis_check,
  add constraint spray_jobs_carrier_area_basis_check
    check (carrier_area_basis is null or carrier_area_basis in ('treated_area', 'whole_block_area'));

comment on column public.spray_records.ground_application_target is
  'Banded ground application location: undervine or midrow. NULL means not recorded.';
comment on column public.spray_records.carrier_area_basis is
  'Area denominator for an L/ha carrier rate: treated_area or whole_block_area. NULL means not recorded.';
comment on column public.spray_jobs.ground_application_target is
  'Reusable banded ground application location intent. NULL means not recorded.';
comment on column public.spray_jobs.carrier_area_basis is
  'Reusable area denominator intent for an L/ha carrier rate. NULL means not recorded.';

commit;

-- 034_spray_jobs_growth_stage_and_vsp.sql
-- Phase 1.1: Add Growth Stage + VSP water-rate calculation inputs to
-- public.spray_jobs.
--
-- This migration is purely additive:
--   * All new columns are nullable.
--   * No backfill is performed.
--   * No existing rows are modified.
--   * No RLS / policy / trigger changes are required (the existing
--     spray_jobs_validate_refs trigger does not reference these columns).
--   * iOS sync and Lovable portal are unchanged by this file alone.
--
-- Source priority and rainfall logic are unrelated and unchanged.

-- =====================================================================
-- Columns
-- =====================================================================
alter table public.spray_jobs
  add column if not exists growth_stage_code     text    null,
  add column if not exists vsp_canopy_size       text    null,
  add column if not exists vsp_canopy_density    text    null,
  add column if not exists row_spacing_metres    numeric null,
  add column if not exists concentration_factor  numeric null default 1.0;

-- =====================================================================
-- CHECK constraints
--
-- growth_stage_code is left UNCONSTRAINED at the SQL level so that future
-- E-L stage additions or custom client-defined codes do not require a new
-- migration. Validation of the canonical E-L list (e.g. 'EL23') is enforced
-- in the iOS app and the Lovable portal.
--
-- vsp_canopy_size, vsp_canopy_density, row_spacing_metres and
-- concentration_factor are constrained because their domains are stable.
-- =====================================================================
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'spray_jobs_vsp_canopy_size_check'
      and conrelid = 'public.spray_jobs'::regclass
  ) then
    alter table public.spray_jobs
      add constraint spray_jobs_vsp_canopy_size_check
      check (
        vsp_canopy_size is null
        or vsp_canopy_size in ('Small', 'Medium', 'Large', 'Full')
      );
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'spray_jobs_vsp_canopy_density_check'
      and conrelid = 'public.spray_jobs'::regclass
  ) then
    alter table public.spray_jobs
      add constraint spray_jobs_vsp_canopy_density_check
      check (
        vsp_canopy_density is null
        or vsp_canopy_density in ('Low', 'High')
      );
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'spray_jobs_row_spacing_metres_positive_check'
      and conrelid = 'public.spray_jobs'::regclass
  ) then
    alter table public.spray_jobs
      add constraint spray_jobs_row_spacing_metres_positive_check
      check (row_spacing_metres is null or row_spacing_metres > 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'spray_jobs_concentration_factor_positive_check'
      and conrelid = 'public.spray_jobs'::regclass
  ) then
    alter table public.spray_jobs
      add constraint spray_jobs_concentration_factor_positive_check
      check (concentration_factor is null or concentration_factor > 0);
  end if;
end$$;

-- =====================================================================
-- Documentation
-- =====================================================================
comment on column public.spray_jobs.growth_stage_code is
  'Canonical Eichhorn-Lorenz growth stage code (e.g. ''EL23''). Stored as '
  'text and intentionally unconstrained at the SQL level to allow future '
  'E-L expansion and custom client codes; the iOS app and Lovable portal '
  'enforce the canonical list. Optional.';

comment on column public.spray_jobs.spray_rate_per_ha is
  'Water rate in L/ha for the job. Either VSP-calculated from '
  'vsp_canopy_size + vsp_canopy_density + row_spacing_metres, or chosen '
  'manually by the user. This is the per-hectare water application rate, '
  'not the chemical rate.';

comment on column public.spray_jobs.water_volume is
  'Total job water in litres, if calculated (typically '
  'spray_rate_per_ha * total sprayed area in ha). Optional.';

comment on column public.spray_jobs.vsp_canopy_size is
  'VSP water-rate matrix input: canopy size. One of '
  '''Small'', ''Medium'', ''Large'', ''Full''. Optional.';

comment on column public.spray_jobs.vsp_canopy_density is
  'VSP water-rate matrix input: canopy density. One of '
  '''Low'', ''High''. Optional.';

comment on column public.spray_jobs.row_spacing_metres is
  'Average row-spacing snapshot in metres used for the VSP water-rate '
  'calculation at the time of saving. Captured so the calculation is '
  'reproducible/auditable even if vineyard row spacing later changes. '
  'Must be > 0 if present.';

comment on column public.spray_jobs.concentration_factor is
  'Concentration factor for foliar-style calculations: '
  'litresPerHa / chosenSprayRate. Defaults to 1.0 (dilute). Must be > 0 '
  'if present.';

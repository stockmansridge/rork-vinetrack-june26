-- REVIEW DRAFT v2 ONLY. DO NOT APPLY ANYWHERE WITHOUT REVIEW/APPROVAL.
-- Supersedes the unapplied v1 draft; NOT an upgrade for a database containing v1.
-- No automatic migration registration, backfill, default, policy, grant or trigger.
-- NULL means unknown, not Standard Pass. Planned hectares are NOT Trip actuals.
-- CF and raw operator text are evidence, NEVER verified chemical label authority.
-- Existing geometry/tanks/chemical quantities/actuals remain untouched.
-- v2 client projections do not authorize execution; full clone/replay acceptance remains required.
-- Restore the current full schema + custom roles, not migration history, for staging.

begin;

-- Inputs, resolved values and controller outputs have distinct storage locations.
-- 'intended' is the operator's requested fill, NOT equipment maximum tank capacity.
alter table public.spray_records
  add column if not exists sprayer_configuration text,
  add column if not exists spray_planning_method text,
  add column if not exists full_tank_specification text,
  add column if not exists planning_input_provenance jsonb,
  add column if not exists planning_intended_tank_litres numeric,
  add column if not exists planning_target_area_ha numeric,
  add column if not exists planning_calibrated_litres_per_hectare numeric,
  add column if not exists planned_application_area_ha numeric,
  add column if not exists resolved_planning_carrier_litres numeric,
  add column if not exists resolved_planning_litres_per_hectare numeric,
  add column if not exists resolved_planning_physical_row_litres_per_100m numeric,
  add column if not exists resolved_planning_concentration_factor numeric,
  add column if not exists controller_litres_per_100m_travel numeric,
  add column if not exists effective_working_width_metres numeric;

-- Reusable jobs/templates carry INPUTS only. New execution resolves fresh outputs;
-- historical record outputs must never be reconstructed from a mutable job.
alter table public.spray_jobs
  add column if not exists sprayer_configuration text,
  add column if not exists spray_planning_method text,
  add column if not exists full_tank_specification text,
  add column if not exists planning_input_provenance jsonb,
  add column if not exists planning_intended_tank_litres numeric,
  add column if not exists planning_target_area_ha numeric,
  add column if not exists planning_calibrated_litres_per_hectare numeric;

-- Raw text is retained verbatim (including blank inactive/draft fields), not parsed
-- by PostgreSQL. Units are unambiguous contract identifiers, not localized labels:
-- volume_unit = litres/us_gallons/imperial_gallons; area_unit = hectares/acres;
-- rate_area_unit = hectare/acre/100m_travel/100ft_travel. Travel identifiers retain a controller-travel
-- entry, NOT a physical-vine-row dilute reference. Canonical numeric input stays L/ha.
-- Current local 'gallons' must be mapped explicitly
-- using its captured country, never the current account's country on reopen.
-- Provenance version 1: {schema_version:1,tank_text,area_text,rate_text,volume_unit,area_unit,
--            rate_area_unit,country_code}; all seven non-version values are strings.
-- Input canonicals belong to the three planning_* numeric input columns above.
-- Positive/finite checks validate values, NOT operational completeness/permission.
do $review$
declare
  table_name text;
  column_name text;
  constraint_name text;
begin
  foreach table_name in array array['spray_records', 'spray_jobs'] loop
    constraint_name := table_name || '_sprayer_configuration_check';
    if not exists (select 1 from pg_constraint where conrelid = ('public.' || table_name)::regclass and conname = constraint_name) then
      execute format('alter table public.%I add constraint %I check (sprayer_configuration is null or sprayer_configuration in (''standard_pass'', ''over_row_two_rows''))', table_name, constraint_name);
    end if;
    constraint_name := table_name || '_spray_planning_method_check';
    if not exists (select 1 from pg_constraint where conrelid = ('public.' || table_name)::regclass and conname = constraint_name) then
      execute format('alter table public.%I add constraint %I check (spray_planning_method is null or spray_planning_method in (''by_area'', ''full_tank''))', table_name, constraint_name);
    end if;
    constraint_name := table_name || '_full_tank_specification_check';
    if not exists (select 1 from pg_constraint where conrelid = ('public.' || table_name)::regclass and conname = constraint_name) then
      execute format('alter table public.%I add constraint %I check (full_tank_specification is null or (spray_planning_method = ''full_tank'' and full_tank_specification in (''target_area'', ''calibrated_rate'')) is true)', table_name, constraint_name);
    end if;
    constraint_name := table_name || '_planning_input_provenance_check';
    if not exists (select 1 from pg_constraint where conrelid = ('public.' || table_name)::regclass and conname = constraint_name) then
      execute format($shape$
        alter table public.%I add constraint %I check (
          planning_input_provenance is null or (
            jsonb_typeof(planning_input_provenance) = 'object'
            and planning_input_provenance -> 'schema_version' = '1'::jsonb
            and planning_input_provenance ?& array['schema_version','tank_text','area_text','rate_text','volume_unit','area_unit','rate_area_unit','country_code']
            and planning_input_provenance - array['schema_version','tank_text','area_text','rate_text','volume_unit','area_unit','rate_area_unit','country_code'] = '{}'::jsonb
            and jsonb_typeof(planning_input_provenance -> 'tank_text') = 'string'
            and jsonb_typeof(planning_input_provenance -> 'area_text') = 'string'
            and jsonb_typeof(planning_input_provenance -> 'rate_text') = 'string'
            and jsonb_typeof(planning_input_provenance -> 'volume_unit') = 'string'
            and jsonb_typeof(planning_input_provenance -> 'area_unit') = 'string'
            and jsonb_typeof(planning_input_provenance -> 'rate_area_unit') = 'string'
            and jsonb_typeof(planning_input_provenance -> 'country_code') = 'string'
            and planning_input_provenance ->> 'volume_unit' in ('litres','us_gallons','imperial_gallons')
            and planning_input_provenance ->> 'area_unit' in ('hectares','acres')
            and planning_input_provenance ->> 'rate_area_unit' in ('hectare','acre','100m_travel','100ft_travel')
            and length(btrim(planning_input_provenance ->> 'country_code')) > 0
          ) is true
        )
      $shape$, table_name, constraint_name);
    end if;
    foreach column_name in array array['planning_intended_tank_litres', 'planning_target_area_ha', 'planning_calibrated_litres_per_hectare'] loop
      constraint_name := table_name || '_' || column_name || '_check';
      if not exists (select 1 from pg_constraint where conrelid = ('public.' || table_name)::regclass and conname = constraint_name) then
        execute format('alter table public.%I add constraint %I check (%I is null or (%I > 0 and %I::text not in (''NaN'', ''Infinity'', ''-Infinity'')) is true)', table_name, constraint_name, column_name, column_name, column_name);
      end if;
    end loop;
  end loop;
  foreach column_name in array array['planned_application_area_ha', 'resolved_planning_carrier_litres', 'resolved_planning_litres_per_hectare', 'resolved_planning_physical_row_litres_per_100m', 'resolved_planning_concentration_factor', 'controller_litres_per_100m_travel', 'effective_working_width_metres'] loop
    constraint_name := left('spray_records_' || column_name || '_check', 63);
    if not exists (select 1 from pg_constraint where conrelid = 'public.spray_records'::regclass and conname = constraint_name) then
      execute format('alter table public.spray_records add constraint %I check (%I is null or (%I > 0 and %I::text not in (''NaN'', ''Infinity'', ''-Infinity'')) is true)', constraint_name, column_name, column_name, column_name);
    end if;
  end loop;
end;
$review$;

comment on column public.spray_records.planning_input_provenance is 'Versioned original operator text and selected unit/country identifiers; not resolved values, label permission or actual coverage.';
comment on column public.spray_jobs.planning_input_provenance is 'Reusable original input evidence only; do not persist calculated execution outputs in this object.';
comment on column public.spray_records.planning_target_area_ha is 'Canonical operator target-area input. NULL when no area input was supplied; never populate from a calculated area.';
comment on column public.spray_jobs.planning_target_area_ha is 'Reusable canonical operator target-area input; revalidate for every execution.';
comment on column public.spray_records.planned_application_area_ha is 'Frozen RESOLVED planned area; distinct from operator target, selected gross area, treated area and Trip actual coverage.';
comment on column public.spray_records.planning_intended_tank_litres is 'Canonical requested fill INPUT, not equipment capacity and not resolved carrier output.';
comment on column public.spray_jobs.planning_intended_tank_litres is 'Reusable requested fill INPUT, not equipment capacity.';
comment on column public.spray_records.resolved_planning_carrier_litres is 'Frozen resolved carrier output; reopen verbatim, never infer from current equipment or Trip actuals.';
comment on column public.spray_records.resolved_planning_litres_per_hectare is 'Frozen resolved canonical rate; may be derived rather than operator-entered.';
comment on column public.spray_records.resolved_planning_physical_row_litres_per_100m is 'Frozen physical-vine-row rate, NOT travel-controller output; does not redefine applied_litres_per_100m.';
comment on column public.spray_records.resolved_planning_concentration_factor is 'Frozen calculated CF only. Not verified label permission or a maximum concentration limit.';
comment on column public.spray_records.controller_litres_per_100m_travel is 'Frozen controller output per 100m travelled; separate from physical-vine-row rate.';
comment on column public.spray_records.effective_working_width_metres is 'Frozen spacing times declared row equivalents. Never modifies vineyard spacing.';
comment on column public.spray_records.sprayer_configuration is 'Declared configuration; NULL means not recorded, never assume Standard Pass.';

-- PATCH contract for future adapters: omitted = unchanged; SQL NULL = explicit clear.
-- Edit a plan atomically: update raw + canonical INPUTS, invalidate all old OUTPUTS,
-- then store freshly resolved outputs only after validation; never relabel outputs
-- as inputs. Historical NULL rows remain NULL. Templates strip all outputs.
-- Freeze/history protections, old SELECT */RPC consumers, column grants and
-- malformed/mismatched-input execution admission MUST be tested on the full clone.
-- Existing job four-field provenance-freeze trigger is NOT a freeze of these fields.
-- No CHECK here approves execution or prevents privileged bypass of client gates.
commit;

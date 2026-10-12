-- REVIEW DRAFT ONLY. Not applied; not registered as an automatic migration.
-- New calculator intent belongs to the existing records and shared job/template rows.
-- No backfill/default: NULL means historical configuration or planning intent unknown.
-- Existing applied_litres_per_100m remains PER PHYSICAL VINE ROW, not controller travel.
-- Existing geometry, tanks, chemical snapshots, actuals, inventory and RLS are untouched.
-- Agreed partial-area policy: store target as PLANNED area only; collect actual
-- block/row coverage during the Trip. Do not proportionally invent block coverage.
-- Agreed concentrate policy: comparison/warning may be displayed, but affected
-- dilute-rate concentrated recipes must block save/start until label permission
-- and limits are verified. This draft does not create chemical label authority.
-- Schema approval and application integration are required before deployment.
-- A numeric concentration_factor is never label authorisation.

begin;

alter table public.spray_records
  add column if not exists sprayer_configuration text,
  add column if not exists spray_planning_method text,
  add column if not exists full_tank_specification text,
  add column if not exists planned_application_area_ha numeric,
  add column if not exists planning_tank_capacity_litres numeric,
  add column if not exists planning_calibrated_litres_per_hectare numeric,
  add column if not exists controller_litres_per_100m_travel numeric,
  add column if not exists effective_working_width_metres numeric;

alter table public.spray_jobs
  add column if not exists sprayer_configuration text,
  add column if not exists spray_planning_method text,
  add column if not exists full_tank_specification text,
  add column if not exists planned_application_area_ha numeric,
  add column if not exists planning_tank_capacity_litres numeric,
  add column if not exists planning_calibrated_litres_per_hectare numeric;

-- These constraints validate new intent values only, not chemical label compliance.
-- IS TRUE is deliberate: SQL CHECK otherwise accepts unknown/NULL predicates.
-- NaN and infinities are not valid operator inputs.
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
    foreach column_name in array array['planned_application_area_ha', 'planning_tank_capacity_litres', 'planning_calibrated_litres_per_hectare'] loop
      constraint_name := table_name || '_' || column_name || '_check';
      if not exists (select 1 from pg_constraint where conrelid = ('public.' || table_name)::regclass and conname = constraint_name) then
        execute format('alter table public.%I add constraint %I check (%I is null or (%I > 0 and %I::text not in (''NaN'', ''Infinity'', ''-Infinity'')) is true)', table_name, constraint_name, column_name, column_name, column_name);
      end if;
    end loop;
  end loop;
  foreach column_name in array array['controller_litres_per_100m_travel', 'effective_working_width_metres'] loop
    constraint_name := 'spray_records_' || column_name || '_check';
    if not exists (select 1 from pg_constraint where conrelid = 'public.spray_records'::regclass and conname = constraint_name) then
      execute format('alter table public.spray_records add constraint %I check (%I is null or (%I > 0 and %I::text not in (''NaN'', ''Infinity'', ''-Infinity'')) is true)', constraint_name, column_name, column_name, column_name);
    end if;
  end loop;
end;
$review$;

comment on column public.spray_records.sprayer_configuration is 'Declared calculator configuration; NULL means not recorded, never infer Standard Pass for historical records.';
comment on column public.spray_records.planned_application_area_ha is 'Planned area, distinct from selected-block gross area and actual applied area. Not proof of actual coverage or partial-block attribution.';
comment on column public.spray_records.controller_litres_per_100m_travel is 'Frozen machine controller rate per 100m travelled. Do not replace the canopy/physical-vine-row applied_litres_per_100m snapshot.';
comment on column public.spray_records.effective_working_width_metres is 'Frozen physical row spacing times declared complete-row equivalents per pass. Never modifies vineyard row spacing.';
comment on column public.spray_jobs.sprayer_configuration is 'Reusable declared configuration; NULL means not recorded. Derive working width from current geometry for each new application.';
comment on column public.spray_jobs.planned_application_area_ha is 'Reusable planned-area intent, not historical actual coverage; must be revalidated against selected blocks for a new application.';

commit;

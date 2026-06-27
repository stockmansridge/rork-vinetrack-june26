-- Phase 19: Optional machine hour reading on maintenance logs (additive).
--
-- Adds public.maintenance_logs.machine_hours so users can record the
-- machinery hour-meter reading at the time of maintenance (tractor hours,
-- quad bike hours, pump hours, generator hours, etc.).
--
-- Design goals:
--   * Strictly additive: nullable double precision, no default.
--   * Existing rows continue to work with NULL machine_hours.
--   * Distinct from the existing "hours" column which records labour hours
--     spent on the maintenance task itself. machine_hours records the
--     equipment's lifetime hour-meter reading at the time of service.
--   * Lovable and iOS share this column via sync.

alter table public.maintenance_logs
  add column if not exists machine_hours double precision null;

comment on column public.maintenance_logs.machine_hours is
  'Optional machine hour-meter reading at the time of maintenance (e.g. tractor lifetime hours). Distinct from the labour hours stored in the hours column.';

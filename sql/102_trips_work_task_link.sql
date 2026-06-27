-- =====================================================================
-- 102_trips_work_task_link.sql
-- =====================================================================
-- Step 1B: optional grouping link from a successful GPS trip to one Work Task.
--
-- Goal: allow many Trips to optionally belong to a single Work Task, while
-- a Trip may belong to zero or one Work Task. No backfill, no costing or
-- reporting change, no UI requirement.
--
-- Design / safety guarantees:
--   * Strictly additive. One NEW nullable column only:
--       - work_task_id  uuid -> public.work_tasks(id) on delete set null
--   * No column is made NOT NULL. No RLS change. No rename / drop.
--   * No backfill of existing trips (work_task_id stays NULL).
--   * work_tasks, work_task_labour_lines, work_task_paddocks and
--     trip_cost_allocations are left completely untouched.
--   * Fully idempotent and safe to re-run.
--   * Old app versions ignore the new column; old rows still render and
--     sync exactly as before.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Additive column
-- ---------------------------------------------------------------------
alter table public.trips
  add column if not exists work_task_id uuid null
    references public.work_tasks(id) on delete set null;

comment on column public.trips.work_task_id is
  'Optional grouping link: the Work Task this successful GPS trip belongs to. NULL = ungrouped standalone trip. One Work Task can have many trips; a trip belongs to zero or one Work Task. ON DELETE SET NULL preserves the trip if the parent Work Task is removed. No costing/reporting impact.';

-- ---------------------------------------------------------------------
-- 2. Lookup index for "trips for this work task" queries
-- ---------------------------------------------------------------------
create index if not exists idx_trips_work_task_id
  on public.trips (work_task_id);

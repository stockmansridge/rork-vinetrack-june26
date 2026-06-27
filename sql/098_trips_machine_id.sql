-- =====================================================================
-- 098_trips_machine_id.sql
-- =====================================================================
-- Phase 3: link trips/jobs to a Vineyard Machine (the successor to the
-- tractor-only model) while preserving existing tractor-based trip costing
-- as a legacy fallback.
--
-- Safety / compatibility guarantees:
--   * Strictly additive. trips.tractor_id is UNCHANGED and continues to work
--     exactly as before — it remains the legacy fallback link.
--   * A nullable machine_id is added and becomes the preferred link for new
--     trips going forward.
--   * Existing trips are backfilled with machine_id from tractor_id via the
--     linked vineyard_machines.legacy_tractor_id row (active machines only).
--   * Fully idempotent and safe to re-run (guarded add, WHERE-NULL backfill).
--   * No RLS changes (existing trip RLS already covers this column).
--   * Does NOT change TripCostService, fuel_purchases, cost reports, or rename
--     tractor_fuel_logs.
--
-- Depends on:
--   public.trips              (sql/001 + later)
--   public.vineyard_machines  (sql/097_vineyard_machines.sql)
-- =====================================================================

-- ---------------------------------------------------------------------
-- trips.machine_id (preferred link; tractor_id kept as legacy fallback)
-- ---------------------------------------------------------------------
alter table public.trips
  add column if not exists machine_id uuid null
    references public.vineyard_machines(id) on delete set null;

create index if not exists idx_trips_machine_id
  on public.trips (machine_id);

comment on column public.trips.machine_id is
  'Optional link to the vineyard machine (vineyard_machines.id) used for this '
  'trip/job. Preferred over the legacy trips.tractor_id link. When a machine '
  'has legacy_tractor_id, clients also populate tractor_id for backward '
  'compatibility with existing trip costing. Nullable, on delete set null.';

-- ---------------------------------------------------------------------
-- Backfill: existing trips.machine_id from tractor_id via the linked
-- vineyard_machines row. Only fills rows where machine_id is still null
-- and a matching active machine exists.
-- ---------------------------------------------------------------------
update public.trips t
set machine_id = m.id
from public.vineyard_machines m
where t.machine_id is null
  and t.tractor_id is not null
  and m.legacy_tractor_id = t.tractor_id
  and m.deleted_at is null;

-- =====================================================================
-- Smoke-test queries (run manually after applying):
--
--   -- 1) Column exists, nullable uuid
--   select column_name, data_type, is_nullable
--   from information_schema.columns
--   where table_schema = 'public'
--     and table_name = 'trips'
--     and column_name = 'machine_id';
--   -- expect: 1 row, data_type = uuid, is_nullable = YES
--
--   -- 2) Trips with a tractor now have a machine (when a backfilled machine
--   --    exists for that tractor)
--   select count(*) filter (where tractor_id is not null) as with_tractor,
--          count(*) filter (where machine_id is not null) as with_machine
--   from public.trips;
-- =====================================================================

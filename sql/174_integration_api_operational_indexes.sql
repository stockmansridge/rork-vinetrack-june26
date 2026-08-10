-- =====================================================================
-- 174_integration_api_operational_indexes.sql
-- =====================================================================
-- Integration Platform — Stage 3B (operational read API) index support.
--
-- Strictly additive: composite partial indexes that back the API gateway's
-- keyset pagination over operational collections. No table, column, RLS
-- policy, RPC or existing index is changed.
--
-- Why these exact indexes:
--   Every Stage 3B collection endpoint runs the same query shape:
--     where vineyard_id = $1 and deleted_at is null
--     order by created_at (desc), id (desc)   -- keyset pagination
--   The existing single-column indexes (vineyard_id) force a sort per page.
--   A composite (vineyard_id, created_at, id) partial index over active rows
--   serves both ascending and descending iteration (backward scan) with no
--   sort, and stays small because soft-deleted rows are excluded.
--
--   fuel_purchases additionally gets (vineyard_id, date) because `date` is
--   its API date-filter column and had NO index at all (unlike
--   trips.start_time, spray_records.date and
--   tractor_fuel_logs.fill_datetime which are already indexed).
--
-- Deliberately NOT indexed (speculative, unjustified at current volumes):
--   * equipment tables (vineyard_machines / spray_equipment /
--     equipment_items) — small per-vineyard catalogues, existing
--     vineyard_id indexes are sufficient.
--   * trips.machine_id / trips.tractor_id / tractor_fuel_logs.machine_id —
--     already indexed by sql/098, sql/057 and sql/097.
--
-- Idempotent and safe to re-run.
-- =====================================================================

create index if not exists idx_trips_vineyard_created_id_active
  on public.trips (vineyard_id, created_at, id)
  where deleted_at is null;

create index if not exists idx_spray_records_vineyard_created_id_active
  on public.spray_records (vineyard_id, created_at, id)
  where deleted_at is null;

create index if not exists idx_tractor_fuel_logs_vineyard_created_id_active
  on public.tractor_fuel_logs (vineyard_id, created_at, id)
  where deleted_at is null;

create index if not exists idx_fuel_purchases_vineyard_created_id_active
  on public.fuel_purchases (vineyard_id, created_at, id)
  where deleted_at is null;

create index if not exists idx_fuel_purchases_vineyard_date_active
  on public.fuel_purchases (vineyard_id, date)
  where deleted_at is null;

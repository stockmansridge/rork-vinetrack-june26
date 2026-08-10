-- =============================================================================
-- 175: Integration API Stage 3C — operational read API support indexes.
--
-- Strictly ADDITIVE. No table, RLS, RPC or SQL 172–174 object is modified.
--
-- The Stage 3C read API (Edge Function vinetrack-api) paginates every
-- operational collection with a deterministic keyset over
-- (vineyard_id, created_at, id) among live rows (deleted_at is null),
-- newest first. These composite partial indexes make that access path an
-- index range scan instead of a per-vineyard sort:
--
--   * work_tasks               GET /v1/work-tasks
--   * pruning_activities       GET /v1/pruning
--   * irrigation_sessions      GET /v1/irrigation-records
--   * growth_stage_records     GET /v1/growth-stages
--   * historical_yield_records GET /v1/yield-records
--   * pins                     GET /v1/pins
--
-- Filter-support indexes (only where no existing index covers the API's
-- filter path — audited against sql/014/050/109/166/125/055/004):
--
--   * work_tasks (vineyard_id, date)           from/to filter on the task's
--                                              business date (existing indexes
--                                              cover start_date only)
--   * pruning_entries (vineyard_id, paddock_id) block_id filter resolves
--                                              activity ids via allocations
--   * historical_yield_records (vineyard_id, year) vintage filter
--
-- Existing indexes already cover the remaining filter paths:
--   work_task_paddocks.paddock_id (sql/051), pruning_activities
--   (vineyard_id, entry_date desc) (sql/166), irrigation_sessions
--   (vineyard_id, session_date desc) (sql/125), irrigation_session_blocks
--   (vineyard_id, block_id) (sql/125), growth_stage_records
--   (vineyard_id, observed_at desc) + paddock_id (sql/055),
--   pins.paddock_id (sql/004).
--
-- Idempotent: safe to re-run.
-- =============================================================================

-- Keyset pagination indexes -------------------------------------------------

create index if not exists idx_work_tasks_api_keyset
  on public.work_tasks (vineyard_id, created_at, id)
  where deleted_at is null;

create index if not exists idx_pruning_activities_api_keyset
  on public.pruning_activities (vineyard_id, created_at, id)
  where deleted_at is null;

create index if not exists idx_irrigation_sessions_api_keyset
  on public.irrigation_sessions (vineyard_id, created_at, id)
  where deleted_at is null;

create index if not exists idx_growth_stage_records_api_keyset
  on public.growth_stage_records (vineyard_id, created_at, id)
  where deleted_at is null;

create index if not exists idx_historical_yield_records_api_keyset
  on public.historical_yield_records (vineyard_id, created_at, id)
  where deleted_at is null;

create index if not exists idx_pins_api_keyset
  on public.pins (vineyard_id, created_at, id)
  where deleted_at is null;

-- Filter-support indexes ------------------------------------------------------

create index if not exists idx_work_tasks_vineyard_date
  on public.work_tasks (vineyard_id, date)
  where deleted_at is null;

create index if not exists idx_pruning_entries_vineyard_paddock
  on public.pruning_entries (vineyard_id, paddock_id)
  where deleted_at is null;

create index if not exists idx_historical_yield_records_vineyard_year
  on public.historical_yield_records (vineyard_id, year)
  where deleted_at is null;

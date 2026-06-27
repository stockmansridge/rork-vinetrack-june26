-- 093_trips_engine_hours.sql
-- Phase 3: optional trip engine-hour readings for fuel allocation.
--
-- Approved approach:
--   * Add two nullable double precision columns to public.trips:
--       start_engine_hours, end_engine_hours
--   * Add non-negative check constraints (null allowed)
--   * No defaults, no backfill, no triggers
--   * No RLS changes (existing trip RLS already covers these columns)
--   * No changes to other tables, RPCs, or sync logic
--   * Do NOT store litres_per_hour or calculated fuel litres on the trip —
--     fuel allocation stays a client-side calculation (TripCostService).
--
-- Semantics:
--   * start_engine_hours / end_engine_hours are the tractor engine-hour meter
--     readings captured (optionally) at trip start and end.
--   * When both are present and end > start, the engine-hour delta is the
--     preferred basis for fuel litres (delta × tractor L/hr). Otherwise the
--     existing active trip duration is used as the fallback basis.
--   * Older clients ignore these columns safely (nullable, no default).

-- =====================================================================
-- Columns
-- =====================================================================
alter table public.trips
  add column if not exists start_engine_hours double precision null;

alter table public.trips
  add column if not exists end_engine_hours double precision null;

-- =====================================================================
-- Check constraints (null allowed, must be non-negative when present)
-- =====================================================================
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'trips_start_engine_hours_nonneg'
  ) then
    alter table public.trips
      add constraint trips_start_engine_hours_nonneg
      check (start_engine_hours is null or start_engine_hours >= 0);
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'trips_end_engine_hours_nonneg'
  ) then
    alter table public.trips
      add constraint trips_end_engine_hours_nonneg
      check (end_engine_hours is null or end_engine_hours >= 0);
  end if;
end $$;

comment on column public.trips.start_engine_hours is
  'Optional tractor engine-hour meter reading at trip start. Used with '
  'end_engine_hours to derive fuel litres (delta x tractor L/hr). Nullable, '
  'no default; older clients ignore safely.';

comment on column public.trips.end_engine_hours is
  'Optional tractor engine-hour meter reading at trip end. Used with '
  'start_engine_hours to derive fuel litres (delta x tractor L/hr). Nullable, '
  'no default; older clients ignore safely.';

-- =====================================================================
-- Smoke-test queries (run manually after applying):
--
--   -- 1) Columns exist and are nullable double precision
--   select column_name, data_type, is_nullable
--   from information_schema.columns
--   where table_schema = 'public'
--     and table_name = 'trips'
--     and column_name in ('start_engine_hours', 'end_engine_hours');
--   -- expect: 2 rows, data_type = double precision, is_nullable = YES
--
--   -- 2) Existing trips are unaffected
--   select count(*) as total,
--          count(*) filter (where start_engine_hours is null) as null_start,
--          count(*) filter (where end_engine_hours is null) as null_end
--   from public.trips;
--   -- expect: total = null_start = null_end (no backfill)
-- =====================================================================

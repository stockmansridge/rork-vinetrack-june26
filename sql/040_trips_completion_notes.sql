-- 040_trips_completion_notes.sql
-- Phase: optional free-text Completion Notes captured at End Trip Review.
--
-- Approved approach:
--   * Add a single nullable text column to public.trips: completion_notes
--   * No defaults, no backfill, no triggers
--   * No RLS changes (existing trip RLS already covers this column)
--   * No changes to other tables, RPCs, or sync logic
--
-- Semantics:
--   * Distinct from trip_title (job details entered at trip start) and from
--     manual_correction_events (audit log).
--   * Free-text notes the operator types into the End Trip Review sheet.
--     Surfaces in the iOS Trip Detail, the iOS Trip Report PDF, and the
--     Lovable Trip Detail / Trip Report PDF.
--   * Older clients ignore this column safely (nullable, no default).
--
-- Example value:
--   "Finished block but last row was wet. Skipped one short row due to
--    a broken post."

-- =====================================================================
-- Column
-- =====================================================================
alter table public.trips
  add column if not exists completion_notes text null;

comment on column public.trips.completion_notes is
  'Optional free-text notes captured at End Trip Review. Distinct from '
  'trip_title (start-of-trip details) and manual_correction_events '
  '(internal audit log). Surfaced in iOS + Lovable Trip Detail and Trip '
  'Reports. Nullable, no default; older clients ignore safely.';

-- =====================================================================
-- Smoke-test queries (run manually after applying):
--
--   -- 1) Column exists and is nullable text
--   select column_name, data_type, is_nullable
--   from information_schema.columns
--   where table_schema = 'public'
--     and table_name = 'trips'
--     and column_name = 'completion_notes';
--   -- expect: 1 row, data_type = text, is_nullable = YES
--
--   -- 2) Existing trips are unaffected
--   select count(*) as total,
--          count(*) filter (where completion_notes is null) as null_count
--   from public.trips;
--   -- expect: total = null_count (no backfill)
-- =====================================================================

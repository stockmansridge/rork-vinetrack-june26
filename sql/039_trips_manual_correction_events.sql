-- 039_trips_manual_correction_events.sql
-- Phase: Live Trip manual corrections audit trail synced to Supabase.
--
-- Approved approach:
--   * Add a single nullable JSONB column to public.trips: manual_correction_events
--   * No defaults, no backfill, no triggers
--   * No RLS changes (existing trip RLS already covers this column)
--   * No changes to other tables, RPCs, or sync logic
--
-- Storage model:
--   * JSONB array of strings. Each entry is "<ISO8601 timestamp> <note>".
--   * Notes use stable slug-style keys produced by the iOS client, e.g.:
--       - "manual_next_path"
--       - "manual_back_path: 4.5"
--       - "manual_complete: 10.5"
--       - "manual_skip: 8.5"
--       - "confirm_locked_path: 4.5"
--       - "snap_to_live_path: 4.5"
--       - "auto_realign_accepted: 4.5"
--       - "auto_realign_ignored: 4.5"
--       - "paddocks_added: <Block names...>"
--       - "end_review_completed: [10.5, 12.5]"
--       - "end_review_finalised"
--   * Older clients ignore this column safely (column is nullable, no default).
--   * Lovable can read trips.manual_correction_events for backend Trip Reports
--     and reproduce the same official record as the iOS PDF.
--
-- Example value:
--   [
--     "2026-05-08T09:48:00+10:00 manual_next_path",
--     "2026-05-08T10:22:00+10:00 end_review_completed: [10.5]",
--     "2026-05-08T10:24:00+10:00 end_review_finalised"
--   ]

-- =====================================================================
-- Column
-- =====================================================================
alter table public.trips
  add column if not exists manual_correction_events jsonb null;

comment on column public.trips.manual_correction_events is
  'Optional audit trail of manual Live-Trip corrections. JSONB array of strings, '
  'each formatted as "<ISO8601 timestamp> <note>". Note slugs are documented in '
  'sql/039_trips_manual_correction_events.sql. Older clients ignore this column safely. '
  'Lovable can read this for backend Trip Reports.';

-- =====================================================================
-- Index (optional, for future reporting / filtering by note prefix)
-- GIN with jsonb_path_ops keeps index small. Only indexes rows that
-- actually have manual_correction_events populated.
-- =====================================================================
create index if not exists idx_trips_manual_correction_events_gin
  on public.trips
  using gin (manual_correction_events jsonb_path_ops)
  where manual_correction_events is not null;

-- =====================================================================
-- Smoke-test queries (run manually after applying):
--
--   -- 1) Column exists and is nullable jsonb
--   select column_name, data_type, is_nullable
--   from information_schema.columns
--   where table_schema = 'public'
--     and table_name = 'trips'
--     and column_name = 'manual_correction_events';
--   -- expect: 1 row, data_type = jsonb, is_nullable = YES
--
--   -- 2) Index exists
--   select indexname
--   from pg_indexes
--   where schemaname = 'public'
--     and tablename = 'trips'
--     and indexname = 'idx_trips_manual_correction_events_gin';
--
--   -- 3) Existing trips are unaffected
--   select count(*) as total,
--          count(*) filter (where manual_correction_events is null) as null_count
--   from public.trips;
--   -- expect: total = null_count (no backfill)
-- =====================================================================

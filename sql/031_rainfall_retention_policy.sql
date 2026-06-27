-- 031_rainfall_retention_policy.sql
-- Docs-only migration. Makes the rainfall_daily retention contract explicit
-- via COMMENT ON statements so future changes can't silently drift. No
-- table, index, function, grant, or row is altered.
--
-- Retention rule (authoritative):
--
--   1. public.rainfall_daily rows are retained INDEFINITELY. There is no
--      automatic expiry, no scheduled cleanup, no pg_cron job, and no
--      edge-function path that deletes historical rainfall rows.
--
--   2. The only ways a rainfall_daily row leaves the table are:
--        a. The parent vineyard is deleted -> ON DELETE CASCADE removes
--           that vineyard's rainfall rows (see FK in 028).
--        b. An owner/manager calls archive_manual_rainfall(...) which
--           SOFT-deletes (sets deleted_at) a single 'manual' row only.
--           Davis / WU / Open-Meteo rows are NEVER touched by this path.
--
--   3. Each source writes to its own row family and never reads or
--      modifies another source's rows:
--        - upsert_manual_rainfall            -> source='manual'
--        - upsert_davis_rainfall_daily       -> source='davis_weatherlink'
--        - upsert_wunderground_rainfall_daily-> source='wunderground_pws'
--        - upsert_open_meteo_rainfall_daily  -> source='open_meteo'
--          (additionally refuses to write if a higher-priority row exists)
--
--   4. Higher-priority rows COEXIST with lower-priority rows; priority is
--      resolved at READ time by get_daily_rainfall:
--          manual (1) > davis_weatherlink (2) > wunderground_pws (3)
--                                              > open_meteo (4)
--
--   5. Any backfill (Davis chunked, WU chunked, Open-Meteo gap-fill) only
--      adds or updates rows for its own source within the requested
--      window. It does NOT delete rows inside or outside that window.
--      The "365-day backfill" range is purely the *fill* horizon; it
--      does not imply data older than 365 days is removed or ignored.
--
--   6. Open-Meteo writes are additionally guarded server-side: the
--      upsert function refuses to insert/update if a Manual, Davis or
--      WU row already exists for that vineyard+date.
--
-- If you ever need to add a retention/cleanup policy, do it in a NEW
-- migration and update this comment block. Do not add ad-hoc DELETEs
-- against rainfall_daily from edge functions or app code.

comment on table public.rainfall_daily is
  'Persistent vineyard daily rainfall history. Rows are retained '
  'indefinitely. No automatic cleanup or expiry. Removed only by '
  'vineyard cascade-delete or by archive_manual_rainfall (manual rows '
  'only, soft delete). Each source writes to its own row family; '
  'priority (manual > davis_weatherlink > wunderground_pws > '
  'open_meteo) is resolved at read time by get_daily_rainfall. See '
  'sql/031_rainfall_retention_policy.sql for the full contract.';

comment on column public.rainfall_daily.deleted_at is
  'Soft-delete timestamp. Set ONLY by archive_manual_rainfall on '
  'source=manual rows. Provider rows (davis_weatherlink, '
  'wunderground_pws, open_meteo) are never soft-deleted by '
  'application code; their upsert paths actively clear deleted_at '
  'on revive.';

comment on function public.get_daily_rainfall(uuid, date, date) is
  'Read-time source-priority resolver for rainfall_daily. Returns one '
  'row per day in the requested range, choosing the highest-priority '
  'non-deleted source: manual > davis_weatherlink > wunderground_pws '
  '> open_meteo. Does not modify or delete any row.';

comment on function public.upsert_manual_rainfall(uuid, date, numeric, text) is
  'Owner/manager-only. Writes (or revives) the source=manual row for '
  '(vineyard,date). Never reads or modifies davis_weatherlink, '
  'wunderground_pws or open_meteo rows.';

comment on function public.archive_manual_rainfall(uuid, date) is
  'Owner/manager-only. Soft-deletes the source=manual row for '
  '(vineyard,date) only. Provider rows are untouched and become '
  'visible again via get_daily_rainfall priority.';

comment on function public.upsert_davis_rainfall_daily(uuid, date, numeric, text, text) is
  'Service-role only (davis-proxy). Writes source=davis_weatherlink '
  'rows for (vineyard,date,station). Never reads or modifies manual, '
  'wunderground_pws or open_meteo rows. No deletes.';

comment on function public.upsert_wunderground_rainfall_daily(uuid, date, numeric, text, text) is
  'Service-role only (wunderground-proxy). Writes source=wunderground_pws '
  'rows for (vineyard,date,station). Never reads or modifies manual, '
  'davis_weatherlink or open_meteo rows. No deletes.';

comment on function public.upsert_open_meteo_rainfall_daily(uuid, date, numeric) is
  'Service-role only (open-meteo-proxy). Writes source=open_meteo rows '
  'for (vineyard,date) ONLY when no manual / davis_weatherlink / '
  'wunderground_pws row already exists for that day (defensive '
  'double-check via days_with_better_rainfall_source). Never reads or '
  'modifies higher-priority rows. No deletes.';

comment on function public.days_with_better_rainfall_source(uuid, date, date) is
  'Service-role only. Helper used by open-meteo-proxy to skip days '
  'that already have a manual / davis_weatherlink / wunderground_pws '
  'row. Read-only.';

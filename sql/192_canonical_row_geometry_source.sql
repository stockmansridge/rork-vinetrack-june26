-- =====================================================================
-- 192 — Canonical row geometry: add the `operator_override` source
--
-- WHY
-- SQL 191 shipped `geometry_source` with four permitted values:
--   mapped_rows | stored_row_length | derived_from_area_and_spacing | unavailable
--
-- The geometry reconciliation audit that followed established that the
-- block field previously modelled as "stored row length" is NOT a cache or
-- a calculated leftover. It is `row_length_override`, an explicit operator
-- correction. The iOS block editor presents it under a "Calculation
-- Overrides" heading, shows a "Manual override active" badge with a Reset
-- control, and states: "Override values here for more accurate water usage
-- and yield calculations". It is only ever written from that field.
--
-- That makes it USER-AUTHORITATIVE and it must outrank mapped geometry for
-- calculation purposes, matching the long-standing legacy behaviour
-- (`effectiveTotalRowLength = rowLengthOverride ?? totalRowLengthMetres`).
-- `stored_row_length` was therefore a misnomer that understated the field's
-- authority.
--
-- WHAT
-- Adds `operator_override` to the permitted `geometry_source` values on
-- `spray_records` and `spray_jobs`. `stored_row_length` is RETAINED, not
-- renamed or dropped: SQL 191 is already applied in production and any row
-- already written with it must stay valid. No data is rewritten.
--
-- SAFETY
--   * Additive only — widens a CHECK, never narrows it.
--   * No column added, dropped or retyped.
--   * No backfill. No historical row is reinterpreted.
--   * Idempotent: safe to re-run.
-- =====================================================================

begin;

do $$
declare
  t text;
begin
  foreach t in array array['spray_records', 'spray_jobs'] loop
    -- Drop and re-add rather than ALTER: Postgres has no "widen CHECK" verb.
    -- Both statements are in the same transaction, so the table is never
    -- left unconstrained to a concurrent writer.
    if exists (
      select 1 from pg_constraint where conname = t || '_geometry_source_check'
    ) then
      execute format('alter table public.%I drop constraint %I',
                     t, t || '_geometry_source_check');
    end if;

    execute format(
      'alter table public.%I add constraint %I check (
         geometry_source is null
         or geometry_source in (
           ''operator_override'',
           ''mapped_rows'',
           ''stored_row_length'',
           ''derived_from_area_and_spacing'',
           ''unavailable''))',
      t, t || '_geometry_source_check'
    );
  end loop;
end$$;

comment on column public.spray_records.geometry_source is
  'Where canonical_row_length_metres came from. Precedence, highest first: '
  'operator_override (explicit operator correction, row_length_override) > '
  'mapped_rows (summed mapped row geometry) > '
  'derived_from_area_and_spacing (gross area x 10000 / row spacing) > '
  'unavailable. "stored_row_length" is the deprecated SQL 191 name for '
  'operator_override and is retained only so rows already written with it '
  'stay valid; new writes must use operator_override.';

commit;

-- =====================================================================
-- ROLLBACK (restores the SQL 191 domain)
--
-- Only safe while no row uses the new value. Check first:
--   select count(*) from public.spray_records where geometry_source = 'operator_override';
--   select count(*) from public.spray_jobs    where geometry_source = 'operator_override';
--
-- begin;
-- do $$
-- declare t text;
-- begin
--   foreach t in array array['spray_records', 'spray_jobs'] loop
--     execute format('alter table public.%I drop constraint if exists %I',
--                    t, t || '_geometry_source_check');
--     execute format(
--       'alter table public.%I add constraint %I check (
--          geometry_source is null
--          or geometry_source in (
--            ''mapped_rows'', ''stored_row_length'',
--            ''derived_from_area_and_spacing'', ''unavailable''))',
--       t, t || '_geometry_source_check');
--   end loop;
-- end$$;
-- commit;
-- =====================================================================

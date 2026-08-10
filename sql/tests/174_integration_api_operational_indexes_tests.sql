-- =====================================================================
-- 174_integration_api_operational_indexes_tests.sql — verification
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying
-- sql/174_integration_api_operational_indexes.sql.
--
-- Read-only: checks that all five Stage 3B pagination/filter indexes
-- exist. Nothing is created, changed or deleted.
--
-- Expected final output:
--   NOTICE: SQL 174 operational index tests: ALL PASSED
-- =====================================================================

do $$
declare
  v_name text;
begin
  foreach v_name in array array[
    'idx_trips_vineyard_created_id_active',
    'idx_spray_records_vineyard_created_id_active',
    'idx_tractor_fuel_logs_vineyard_created_id_active',
    'idx_fuel_purchases_vineyard_created_id_active',
    'idx_fuel_purchases_vineyard_date_active'
  ] loop
    if not exists (
      select 1 from pg_indexes
      where schemaname = 'public' and indexname = v_name
    ) then
      raise exception 'SQL 174 test failed: index % missing', v_name;
    end if;
  end loop;

  raise notice 'SQL 174 operational index tests: ALL PASSED';
end$$;

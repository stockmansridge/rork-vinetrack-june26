-- =====================================================================
-- 147_irrigation_reporting_tests.sql — Phase 2B reporting reconciliation
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying
-- sql/147_irrigation_phase_2b_reporting.sql. Everything runs inside ONE
-- transaction that is ROLLED BACK — no production data is touched.
-- Expected final output:
--   NOTICE: SQL 147 irrigation reporting tests: ALL PASSED
--
-- Fixture design (vintage 2026 = 2025-07-01 .. 2026-06-30, default season):
--   S1 manual_ios       total_volume                5,000 L  60 min  10 Jan
--        B1 3,000 L (area 10,000 m², 1,000 vines, eff 2,700)
--        B2 2,000 L (no area / vines / efficiency)
--   S2 manual_android   configured_flow (estimated) 2,400 L 120 min  15 Jan
--        B1 2,400 L (eff 2,160) — snapshot flow_is_estimated = true
--   S3 galcon_gsi_import controller_reported_volume 12,000 L 90 min   1 Feb
--        B1 12,000 L (eff 10,800), status 'imported'
--   S4 manual_portal    meter_readings              1,000 L  30 min  10 Feb
--        B2 1,000 L (no area)
--   S5 REVERSED         total_volume                  999 L (excluded)
--   S6 vintage 2025     total_volume                7,000 L (prev vintage)
--   Rainfall: 10 Jan 5 mm (manual), 11 Jan 3 mm (davis) — partial coverage.
-- =====================================================================

begin;

do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_irrigation_vintage_overview'
  ) then
    raise exception 'SQL 147 not applied — run sql/147_irrigation_phase_2b_reporting.sql first.';
  end if;
end$$;

do $$
declare
  u_admin uuid := gen_random_uuid();
  u_member uuid := gen_random_uuid();
  v_vy uuid := gen_random_uuid();
  v_sys uuid := gen_random_uuid();
  v_v1 uuid := gen_random_uuid();
  v_v2 uuid := gen_random_uuid();
  v_b1 uuid := gen_random_uuid();
  v_b2 uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid();
  s2 uuid := gen_random_uuid();
  s3 uuid := gen_random_uuid();
  s4 uuid := gen_random_uuid();
  s5 uuid := gen_random_uuid();
  s6 uuid := gen_random_uuid();
  r jsonb;
  rows jsonb;
  v_sum numeric;
  v_denied boolean := false;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (u_admin,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't147-admin@test.local',  'x', now(), now(), now()),
         (u_member, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't147-member@test.local', 'x', now(), now(), now());
  insert into public.profiles (id, email) values (u_admin, 't147-admin@test.local'), (u_member, 't147-member@test.local')
  on conflict (id) do nothing;
  insert into public.system_admins (user_id, is_active) values (u_admin, true) on conflict do nothing;

  insert into public.vineyards (id, name) values (v_vy, 'T147 Reporting Test Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role)
  values (v_vy, u_admin, 'owner'), (v_vy, u_member, 'manager');

  insert into public.paddocks (id, vineyard_id, name, irrigation_efficiency_percent)
  values (v_b1, v_vy, 'T147 Block One', 90), (v_b2, v_vy, 'T147 Block Two', null);

  insert into public.irrigation_systems (id, vineyard_id, name, water_source)
  values (v_sys, v_vy, 'T147 System', 'bore');
  insert into public.irrigation_valves (id, vineyard_id, irrigation_system_id, name, valve_number, configured_flow_litres_per_hour)
  values (v_v1, v_vy, v_sys, 'T147 Valve 1', '1', 1200),
         (v_v2, v_vy, v_sys, 'T147 Valve 2', '2', null);
  insert into public.irrigation_valve_blocks (vineyard_id, valve_id, block_id, allocation_method, allocation_percentage, serviced_area_m2, serviced_vine_count, row_start, row_end)
  values (v_vy, v_v1, v_b1, 'manual_percentage', 100, 10000, 1000, 1, 30),
         (v_vy, v_v2, v_b2, 'manual_percentage', 100, null, null, null, null);

  insert into public.irrigation_sessions (
    id, vineyard_id, irrigation_system_id, valve_id, session_date, vintage_year,
    duration_minutes, calculation_method, total_volume_litres, effective_volume_litres,
    irrigation_efficiency_percent, status, source_type, configuration_snapshot, created_by)
  values
    (s1, v_vy, v_sys, v_v1, '2026-01-10', 2026,  60, 'total_volume',               5000, null, null, 'completed', 'manual_ios',        '{}'::jsonb, u_admin),
    (s2, v_vy, v_sys, v_v1, '2026-01-15', 2026, 120, 'configured_flow',            2400, 2160,   90, 'completed', 'manual_android',    '{"flow_is_estimated": true}'::jsonb, u_admin),
    (s3, v_vy, v_sys, v_v2, '2026-02-01', 2026,  90, 'controller_reported_volume',12000,10800,   90, 'imported',  'galcon_gsi_import', '{"flow_is_estimated": false}'::jsonb, u_admin),
    (s4, v_vy, v_sys, v_v2, '2026-02-10', 2026,  30, 'meter_readings',             1000, null, null, 'completed', 'manual_portal',     '{}'::jsonb, u_admin),
    (s5, v_vy, v_sys, v_v1, '2026-02-11', 2026,  10, 'total_volume',                999, null, null, 'reversed',  'manual_ios',        '{}'::jsonb, u_admin),
    (s6, v_vy, v_sys, v_v1, '2024-12-01', 2025,  70, 'total_volume',               7000, 6300,   90, 'completed', 'manual_ios',        '{}'::jsonb, u_admin);

  insert into public.irrigation_session_blocks (
    session_id, vineyard_id, valve_id, block_id, variety_name,
    allocation_method, allocation_percentage, allocated_volume_litres,
    effective_volume_litres, serviced_area_m2, serviced_vine_count)
  values
    (s1, v_vy, v_v1, v_b1, 'Shiraz', 'manual_percentage',  60,  3000,  2700, 10000, 1000),
    (s1, v_vy, v_v1, v_b2, null,     'manual_percentage',  40,  2000,  null,  null, null),
    (s2, v_vy, v_v1, v_b1, 'Shiraz', 'manual_percentage', 100,  2400,  2160, 10000, 1000),
    (s3, v_vy, v_v2, v_b1, 'Shiraz', 'manual_percentage', 100, 12000, 10800, 10000, 1000),
    (s4, v_vy, v_v2, v_b2, null,     'manual_percentage', 100,  1000,  null,  null, null),
    (s5, v_vy, v_v1, v_b1, 'Shiraz', 'manual_percentage', 100,   999,  null, 10000, 1000),
    (s6, v_vy, v_v1, v_b1, 'Shiraz', 'manual_percentage', 100,  7000,  6300, 10000, 1000);

  insert into public.rainfall_daily (vineyard_id, date, rainfall_mm, source)
  values (v_vy, '2026-01-10', 5, 'manual'), (v_vy, '2026-01-11', 3, 'davis_weatherlink');

  -- ---- act as System Admin ------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);

  -- T1. Vintage overview totals + classification splits
  r := public.get_irrigation_vintage_overview(v_vy, 2026);
  assert (r->>'total_irrigation_litres')::numeric = 20400, 'T1 total, got ' || (r->>'total_irrigation_litres');
  assert (r->>'manual_litres')::numeric = 8400,            'T1 manual';
  assert (r->>'imported_litres')::numeric = 12000,         'T1 imported';
  assert (r->>'estimated_litres')::numeric = 2400,         'T1 estimated';
  assert (r->>'directly_reported_litres')::numeric = 17000,'T1 directly reported';
  assert (r->>'directly_measured_litres')::numeric = 1000, 'T1 directly measured';
  assert (r->>'calculated_litres')::numeric = 0,           'T1 calculated';
  assert (r->>'session_count')::integer = 4,               'T1 sessions';
  assert (r->>'total_runtime_minutes')::integer = 300,     'T1 runtime';
  assert r->>'effective_irrigation_litres' is null,        'T1 effective must be null (2 sessions lack efficiency)';
  assert (r->>'period_start') = '2025-07-01' and (r->>'period_end') = '2026-06-30', 'T1 vintage period';
  assert (r->>'serviced_area_hectares')::numeric = 1.0,    'T1 area ha';
  assert (r->>'serviced_vines')::integer = 1000,           'T1 vines';
  assert (r->>'irrigation_depth_mm')::numeric = 1.74,      'T1 depth, got ' || (r->>'irrigation_depth_mm');
  assert (r->>'litres_per_vine')::numeric = 17.4,          'T1 per vine';
  assert (r->>'litres_per_hectare')::numeric = 17400,      'T1 per hectare';
  assert (r->>'previous_total_litres')::numeric = 7000,    'T1 previous vintage';
  assert (r->>'volume_difference_litres')::numeric = 13400,'T1 volume diff';
  assert (r->>'highest_use_date') = '2026-02-01',          'T1 highest use date';
  assert (r->>'rainfall_mm')::numeric = 8,                 'T1 rainfall';
  assert (r->>'rainfall_data_complete')::boolean = false,  'T1 rainfall completeness';
  assert r->'warnings' @> '[{"code":"missing_irrigation_efficiency"}]'::jsonb, 'T1 efficiency warning';
  assert r->'warnings' @> '[{"code":"missing_serviced_area"}]'::jsonb,         'T1 area warning';

  -- T2. Daily = Monthly = Weekly = Vintage total (reconciliation §26)
  r := public.get_irrigation_daily_report(v_vy, 2026);
  select sum((x->>'total_litres')::numeric) into v_sum from jsonb_array_elements(r->'rows') x;
  assert v_sum = 20400, 'T2 daily sum, got ' || v_sum;
  assert jsonb_array_length(r->'rows') = 4, 'T2 daily row count (zero days off)';

  r := public.get_irrigation_daily_report(v_vy, 2026, p_include_zero_days => true);
  assert jsonb_array_length(r->'rows') = 365, 'T2 daily continuity rows, got ' || jsonb_array_length(r->'rows');

  r := public.get_irrigation_weekly_summary(v_vy, 2026);
  select sum((x->>'total_litres')::numeric) into v_sum from jsonb_array_elements(r->'rows') x;
  assert v_sum = 20400, 'T2 weekly sum';

  r := public.get_irrigation_monthly_report(v_vy, 2026);
  select sum((x->>'total_litres')::numeric) into v_sum from jsonb_array_elements(r->'rows') x;
  assert v_sum = 20400, 'T2 monthly sum';
  assert jsonb_array_length(r->'rows') = 12, 'T2 monthly includes zero months';
  -- January: 5,000 + 2,400; previous-vintage December comparison = 7,000
  select x into r from jsonb_array_elements(r->'rows') x where x->>'month_key' = '2026-01';
  assert (r->>'total_litres')::numeric = 7400, 'T2 January total';
  assert (r->>'rainfall_mm')::numeric = 8, 'T2 January rainfall';

  -- T3. Valve totals reconcile + weighted flow
  r := public.get_irrigation_valve_report(v_vy, 2026);
  select sum((x->>'total_litres')::numeric) into v_sum from jsonb_array_elements(r->'rows') x;
  assert v_sum = 20400, 'T3 valve sum';
  select x into r from jsonb_array_elements(r->'rows') x where x->>'valve_name' = 'T147 Valve 1';
  assert (r->>'total_litres')::numeric = 7400, 'T3 valve 1 total';
  assert (r->>'session_count')::integer = 2, 'T3 valve 1 sessions';
  -- weighted: 7,400 L over 180 min = 2,466.7 L/h
  assert (r->>'average_flow_litres_per_hour')::numeric = 2466.7, 'T3 weighted flow, got ' || (r->>'average_flow_litres_per_hour');
  assert (r->>'automatic_flow_source') = 'configured_valve_flow', 'T3 flow source';
  assert (r->>'rows_supplied')::integer = 30, 'T3 rows supplied';

  -- T4. Block allocated totals reconcile
  r := public.get_irrigation_block_report(v_vy, 2026);
  select sum((x->>'total_litres')::numeric) into v_sum from jsonb_array_elements(r->'rows') x;
  assert v_sum = 20400, 'T4 block sum';
  select x into r from jsonb_array_elements(r->'rows') x where x->>'block_name' = 'T147 Block One';
  assert (r->>'total_litres')::numeric = 17400, 'T4 B1 total';
  assert (r->>'irrigation_depth_mm')::numeric = 1.74, 'T4 B1 depth';
  assert (r->>'effective_litres')::numeric = 15660, 'T4 B1 effective, got ' || (r->>'effective_litres');
  assert (r->>'previous_vintage_litres')::numeric = 7000, 'T4 B1 previous vintage';
  select x into r from (select x from jsonb_array_elements(public.get_irrigation_block_report(v_vy, 2026)->'rows') x) t
  where x->>'block_name' = 'T147 Block Two';
  assert (r->>'total_litres')::numeric = 3000, 'T4 B2 total';
  assert r->>'irrigation_depth_mm' is null, 'T4 B2 depth null (no saved area)';
  assert r->'warnings' @> '[{"code":"missing_serviced_area"}]'::jsonb, 'T4 B2 area warning';

  -- T5. Variety totals reconcile to block totals (Unassigned documented)
  r := public.get_irrigation_variety_report(v_vy, 2026);
  select sum((x->>'total_litres')::numeric) into v_sum from jsonb_array_elements(r->'rows') x;
  assert v_sum = 20400, 'T5 variety sum';
  select x into r from jsonb_array_elements(r->'rows') x where x->>'variety_name' = 'Shiraz';
  assert (r->>'total_litres')::numeric = 17400, 'T5 Shiraz total';
  assert (r->>'litres_per_vine')::numeric = 17.4, 'T5 Shiraz per vine (weighted, not averaged)';

  -- T6. Water-source totals reconcile
  r := public.get_irrigation_water_source_summary(v_vy, 2026);
  select sum((x->>'total_litres')::numeric) into v_sum from jsonb_array_elements(r->'rows') x;
  assert v_sum = 20400, 'T6 water source sum';
  assert jsonb_array_length(r->'rows') = 1, 'T6 single bore source';
  assert (r->'rows'->0->>'percent_of_vineyard_total')::numeric = 100, 'T6 percent';

  -- T7. Calculation-method totals reconcile
  r := public.get_irrigation_calculation_source_summary(v_vy, 2026);
  select sum((x->>'total_litres')::numeric) into v_sum from jsonb_array_elements(r->'rows') x;
  assert v_sum = 20400, 'T7 calc sum';
  assert r->'rows' @> '[{"calculation_method":"controller_reported_volume","measurement_group":"directly_reported"}]'::jsonb,
    'T7 controller volume is directly_reported (never a meter reading)';
  assert r->'rows' @> '[{"calculation_method":"configured_flow","measurement_group":"estimated"}]'::jsonb,
    'T7 emitter-derived configured flow is estimated';
  assert r->'rows' @> '[{"calculation_method":"meter_readings","measurement_group":"directly_measured"}]'::jsonb,
    'T7 meter readings directly measured';

  -- T8. Record-source totals reconcile, Galcon distinct
  r := public.get_irrigation_record_source_summary(v_vy, 2026);
  select sum((x->>'total_litres')::numeric) into v_sum from jsonb_array_elements(r->'rows') x;
  assert v_sum = 20400, 'T8 source sum';
  assert r->'rows' @> '[{"source_type":"galcon_gsi_import","source_group":"controller_import"}]'::jsonb, 'T8 galcon row';
  assert jsonb_array_length(r->'rows') = 4, 'T8 four source types';

  -- T9. Filters: reversed / imported / estimated
  r := public.get_irrigation_vintage_overview(v_vy, 2026, p_include_reversed => true);
  assert (r->>'total_irrigation_litres')::numeric = 21399, 'T9 reversed included';
  r := public.get_irrigation_vintage_overview(v_vy, 2026, p_include_imported => false);
  assert (r->>'total_irrigation_litres')::numeric = 8400, 'T9 imported excluded';
  r := public.get_irrigation_vintage_overview(v_vy, 2026, p_include_estimated => false);
  assert (r->>'total_irrigation_litres')::numeric = 18000, 'T9 estimated excluded';
  r := public.get_irrigation_vintage_overview(v_vy, 2026, p_source_group => 'manual');
  assert (r->>'total_irrigation_litres')::numeric = 8400, 'T9 source group manual';

  -- T10. Rainfall comparison (monthly): January combined = 8 mm + 0.54 mm
  r := public.get_irrigation_rainfall_summary(v_vy, 2026, 'month');
  select x into r from jsonb_array_elements(r->'rows') x where x->>'period_key' = '2026-01';
  assert (r->>'rainfall_mm')::numeric = 8, 'T10 Jan rainfall';
  assert (r->>'gross_irrigation_depth_mm')::numeric = 0.54, 'T10 Jan depth, got ' || (r->>'gross_irrigation_depth_mm');
  assert (r->>'combined_water_input_mm')::numeric = 8.54, 'T10 Jan combined';
  assert (r->>'rainfall_data_complete')::boolean = false, 'T10 Jan partial rainfall';
  r := public.get_irrigation_rainfall_summary(v_vy, 2026, 'vintage');
  assert jsonb_array_length(r->'rows') = 1, 'T10 vintage grouping single row';
  assert (r->'rows'->0->>'gross_irrigation_depth_mm')::numeric = 1.74, 'T10 vintage depth matches overview';
  assert (r->'rows'->0->>'combined_water_input_mm')::numeric = 9.74, 'T10 vintage combined';

  -- T11. Multi-vintage trends
  r := public.get_irrigation_vintage_trends(v_vy, 2026, 2);
  assert jsonb_array_length(r->'rows') = 2, 'T11 two vintages';
  assert (r->'rows'->0->>'vintage_year')::integer = 2025, 'T11 order ascending';
  assert (r->'rows'->0->>'total_litres')::numeric = 7000, 'T11 2025 total';
  assert (r->'rows'->1->>'total_litres')::numeric = 20400, 'T11 2026 total';
  assert r->'rows'->1->>'data_quality' is not null, 'T11 data quality present';

  -- T12. Drill-down contract
  r := public.list_irrigation_report_sessions(v_vy, 2026);
  assert (r->>'total_count')::integer = 4, 'T12 drill-down count';
  r := public.list_irrigation_report_sessions(v_vy, 2026, p_source_group => 'controller_import');
  assert (r->>'total_count')::integer = 1, 'T12 imported filter';
  assert r->'sessions'->0->>'source_label' = 'Galcon GSI import', 'T12 source label';

  -- T13. Non-admin vineyard member is rejected (server-side gate, not UI)
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_member::text, 'role', 'authenticated')::text, true);
  begin
    r := public.get_irrigation_vintage_overview(v_vy, 2026);
    v_denied := false;
  exception when others then
    v_denied := sqlerrm like '%irrigation_access_denied%';
  end;
  assert v_denied, 'T13 non-admin must be denied';

  raise notice 'SQL 147 irrigation reporting tests: ALL PASSED';
end$$;

rollback;

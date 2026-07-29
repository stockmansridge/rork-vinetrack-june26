-- =====================================================================
-- 149_irrigation_rainfall_coverage_tests.sql — rainfall coverage fix
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying
-- sql/149_irrigation_rainfall_coverage_fix.sql. Everything runs inside
-- ONE transaction that is ROLLED BACK — no production data is touched.
-- Expected final output:
--   NOTICE: SQL 149 rainfall coverage tests: ALL PASSED
--
-- Fixture design (all dates are relative to the vineyard-LOCAL today so
-- the suite passes on any calendar date):
--   V1  default tz (Australia/Sydney)
--       29 rainfall rows: local_today-28 .. local_today, 1 mm each except
--       a recorded 0.0 mm day at local_today-3 (valid observed day), PLUS
--       a FUTURE forecast row at local_today+5 (must never count).
--   V2  27 rainfall rows over the same 29-day window (2 dates skipped).
--   V3  provider tz Pacific/Kiritimati (UTC+14) — timezone cut-off test.
--   V4  provider tz Etc/GMT+12 (UTC-12)        — timezone cut-off test.
-- =====================================================================

begin;

do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = '_irrigation_rainfall_coverage'
  ) then
    raise exception 'SQL 149 not applied — run sql/149_irrigation_rainfall_coverage_fix.sql first.';
  end if;
end$$;

do $$
declare
  u_admin uuid := gen_random_uuid();
  v_vy1 uuid := gen_random_uuid();
  v_vy2 uuid := gen_random_uuid();
  v_vy3 uuid := gen_random_uuid();
  v_vy4 uuid := gen_random_uuid();
  v_today date;
  v_base date;
  v_vintage integer;
  v_period_days integer;
  c record;
  w jsonb;
  r jsonb;
  r_row jsonb;
  v_sum numeric;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (u_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't149-admin@test.local', 'x', now(), now(), now());
  insert into public.profiles (id, email) values (u_admin, 't149-admin@test.local')
  on conflict (id) do nothing;
  insert into public.system_admins (user_id, is_active) values (u_admin, true) on conflict do nothing;

  insert into public.vineyards (id, name)
  values (v_vy1, 'T149 Coverage Vineyard'),
         (v_vy2, 'T149 Missing Days Vineyard'),
         (v_vy3, 'T149 Kiritimati Vineyard'),
         (v_vy4, 'T149 GMT+12 Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role)
  values (v_vy1, u_admin, 'owner');

  v_today := public._irrigation_local_today(v_vy1);

  -- V1: 29 fully-observed elapsed days (one valid 0.0 mm day) + 1 future row
  insert into public.rainfall_daily (vineyard_id, date, rainfall_mm, source)
  select v_vy1, d::date,
         case when d::date = v_today - 3 then 0 else 1 end,
         'manual'
  from generate_series(v_today - 28, v_today, interval '1 day') d;
  insert into public.rainfall_daily (vineyard_id, date, rainfall_mm, source)
  values (v_vy1, v_today + 5, 4, 'open_meteo');

  -- V2: 27 of 29 elapsed days observed (2 genuinely missing)
  insert into public.rainfall_daily (vineyard_id, date, rainfall_mm, source)
  select v_vy2, d::date, 2, 'manual'
  from generate_series(v_today - 28, v_today, interval '1 day') d
  where d::date not in (v_today - 10, v_today - 20);

  -- T1. Current-vintage style period: 29 elapsed of 365, all observed.
  select * into c
  from public._irrigation_rainfall_coverage(v_vy1, v_today - 28, v_today + 336);
  assert c.expected_days = 29,  'T1 expected, got ' || c.expected_days;
  assert c.observed_days = 29,  'T1 observed, got ' || c.observed_days;
  assert c.missing_days = 0,    'T1 missing, got ' || c.missing_days;
  assert c.future_days = 336,   'T1 future, got ' || c.future_days;
  assert c.data_complete = true,'T1 complete';
  assert c.coverage_start = v_today - 28, 'T1 coverage start';
  assert c.coverage_end = v_today,        'T1 coverage end (local today)';
  w := public._irrigation_rainfall_warnings(v_vy1, v_today - 28, v_today + 336);
  assert w = '[]'::jsonb, 'T1 no warning for future days, got ' || w::text;

  -- T2. Future/forecast rows never count as observed or leak into sums.
  select sum(rb.rainfall_mm) into v_sum
  from public._irrigation_rainfall_best(v_vy1, v_today - 28, v_today + 336) rb;
  assert v_sum = 28, 'T2 future 4 mm row must be excluded, got ' || v_sum;

  -- T3. Genuinely missing elapsed dates: 27 of 29 observed.
  select * into c
  from public._irrigation_rainfall_coverage(v_vy2, v_today - 28, v_today);
  assert c.expected_days = 29 and c.observed_days = 27, 'T3 counts';
  assert c.missing_days = 2,      'T3 missing, got ' || c.missing_days;
  assert c.data_complete = false, 'T3 complete must be false';
  w := public._irrigation_rainfall_warnings(v_vy2, v_today - 28, v_today);
  assert w @> '[{"code":"partial_rainfall_coverage","affected_count":2}]'::jsonb,
    'T3 warning shape, got ' || w::text;
  assert (w->0->>'message') like '%2 of 29%', 'T3 message says 2 of 29, got ' || (w->0->>'message');

  -- T4. A recorded 0.0 mm day is a valid OBSERVED day.
  select * into c
  from public._irrigation_rainfall_coverage(v_vy1, v_today - 3, v_today - 3);
  assert c.expected_days = 1 and c.observed_days = 1 and c.data_complete = true,
    'T4 zero-rainfall day must count as observed';

  -- T5. Historical, fully-ended period: every day expected, none future.
  select * into c
  from public._irrigation_rainfall_coverage(v_vy2, v_today - 400, v_today - 371);
  assert c.expected_days = 30 and c.future_days = 0, 'T5 full period expected';
  assert c.observed_days = 0 and c.missing_days = 30, 'T5 missing across full period';
  w := public._irrigation_rainfall_warnings(v_vy2, v_today - 400, v_today - 371);
  assert w @> '[{"code":"missing_rainfall","affected_count":30}]'::jsonb,
    'T5 missing_rainfall warning, got ' || w::text;

  -- T6. Future-only range: nothing expected, nothing missing, no warning.
  select * into c
  from public._irrigation_rainfall_coverage(v_vy1, v_today + 10, v_today + 20);
  assert c.expected_days = 0 and c.missing_days = 0, 'T6 nothing expected';
  assert c.future_days = 11,        'T6 future, got ' || c.future_days;
  assert c.data_complete is null,   'T6 completeness not yet applicable';
  assert c.coverage_start is null and c.coverage_end is null, 'T6 coverage bounds null';
  w := public._irrigation_rainfall_warnings(v_vy1, v_today + 10, v_today + 20);
  assert w = '[]'::jsonb, 'T6 no warning for future-only range';

  -- T7. Timezone: the cut-off is the VINEYARD-local date, never the UTC date.
  insert into public.irrigation_import_provider_settings (vineyard_id, provider, timezone, created_by)
  values (v_vy3, 'galcon_gsi', 'Pacific/Kiritimati', u_admin),
         (v_vy4, 'galcon_gsi', 'Etc/GMT+12', u_admin);
  assert public._irrigation_local_today(v_vy3) = (now() at time zone 'Pacific/Kiritimati')::date,
    'T7 Kiritimati local today';
  assert public._irrigation_local_today(v_vy4) = (now() at time zone 'Etc/GMT+12')::date,
    'T7 GMT+12 local today';
  assert public._irrigation_local_today(v_vy3) >= public._irrigation_local_today(v_vy4),
    'T7 per-vineyard cut-off ordering';
  assert public._irrigation_local_today(v_vy1) = (now() at time zone 'Australia/Sydney')::date,
    'T7 default timezone fallback';

  -- ---- end-to-end through the Phase 2B RPCs (as System Admin) -------------
  -- Season configured so the CURRENT vintage started exactly 28 days ago:
  -- period = [v_today-28 .. ~1 year later], 29 elapsed days, all observed.
  v_base := v_today - 28;
  update public.vineyards
     set season_start_month = extract(month from v_base)::smallint,
         season_start_day   = extract(day from v_base)::smallint
   where id = v_vy1;
  v_vintage := extract(year from v_base)::integer + 1;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);

  -- T8. Vintage overview: complete elapsed coverage, future days warn-free.
  r := public.get_irrigation_vintage_overview(v_vy1, v_vintage);
  assert (r->>'period_start')::date = v_base, 'T8 period start, got ' || (r->>'period_start');
  v_period_days := (r->>'period_end')::date - (r->>'period_start')::date + 1;
  assert (r->>'rainfall_expected_days')::integer = 29, 'T8 expected 29, got ' || (r->>'rainfall_expected_days');
  assert (r->>'rainfall_observed_days')::integer = 29, 'T8 observed';
  assert (r->>'rainfall_missing_days')::integer = 0,   'T8 missing 0';
  assert (r->>'rainfall_future_days')::integer = v_period_days - 29,
    'T8 future days, got ' || (r->>'rainfall_future_days');
  assert (r->>'rainfall_data_complete')::boolean = true, 'T8 complete';
  assert (r->>'rainfall_coverage_start')::date = v_base, 'T8 coverage start';
  assert (r->>'rainfall_coverage_end')::date = v_today,  'T8 coverage end';
  assert (r->>'rainfall_mm')::numeric = 28, 'T8 rainfall sum excludes future row';
  assert not (r->'warnings' @> '[{"code":"partial_rainfall_coverage"}]'::jsonb),
    'T8 no partial coverage warning, got ' || (r->'warnings')::text;
  assert not (r->'warnings' @> '[{"code":"missing_rainfall"}]'::jsonb),
    'T8 no missing rainfall warning';

  -- T9. Daily report: future rows are "not yet applicable", never zero/false.
  r := public.get_irrigation_daily_report(
    v_vy1, v_vintage,
    p_date_from => v_today - 1, p_date_to => v_today + 1,
    p_include_zero_days => true);
  assert jsonb_array_length(r->'rows') = 3, 'T9 three rows';
  select x into r_row from jsonb_array_elements(r->'rows') x
  where x->>'period_key' = to_char(v_today + 1, 'YYYY-MM-DD');
  assert r_row->'rainfall_data_complete' = 'null'::jsonb, 'T9 future day completeness null';
  assert (r_row->>'rainfall_expected_days')::integer = 0, 'T9 future day expected 0';
  assert (r_row->>'rainfall_future_days')::integer = 1,   'T9 future day future 1';
  assert r_row->'rainfall_mm' = 'null'::jsonb, 'T9 future rainfall null, never zero';
  select x into r_row from jsonb_array_elements(r->'rows') x
  where x->>'period_key' = to_char(v_today - 1, 'YYYY-MM-DD');
  assert (r_row->>'rainfall_data_complete')::boolean = true, 'T9 elapsed day complete';
  assert (r_row->>'rainfall_mm')::numeric = 1, 'T9 elapsed day rainfall';
  assert not (r->'warnings' @> '[{"code":"partial_rainfall_coverage"}]'::jsonb)
     and not (r->'warnings' @> '[{"code":"missing_rainfall"}]'::jsonb),
    'T9 no rainfall warning for covered elapsed range';

  -- T10. Rainfall summary (vintage grouping) carries the coverage fields.
  r := public.get_irrigation_rainfall_summary(v_vy1, v_vintage, 'vintage');
  r_row := r->'rows'->0;
  assert (r_row->>'rainfall_data_complete')::boolean = true, 'T10 complete';
  assert (r_row->>'rainfall_expected_days')::integer = 29,   'T10 expected';
  assert (r_row->>'rainfall_future_days')::integer = v_period_days - 29, 'T10 future';
  assert not (r->'warnings' @> '[{"code":"partial_rainfall_coverage"}]'::jsonb),
    'T10 no false warning';

  -- T11. Vintage trends: an in-progress vintage with full elapsed coverage
  --      is not penalised for the days that have not happened yet.
  r := public.get_irrigation_vintage_trends(v_vy1, v_vintage, 1);
  r_row := r->'rows'->0;
  assert (r_row->>'rainfall_missing_days')::integer = 0, 'T11 missing 0';
  assert (r_row->>'rainfall_data_complete')::boolean = true, 'T11 complete';
  assert not (r_row->'warnings' @> '[{"code":"partial_rainfall_coverage"}]'::jsonb),
    'T11 no false warning in trend row';

  raise notice 'SQL 149 rainfall coverage tests: ALL PASSED';
end$$;

rollback;

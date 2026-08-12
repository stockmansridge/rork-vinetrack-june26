-- =====================================================================
-- 187_picking_financial_privacy_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/187_yield_reports_picking_financial_privacy.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects: companion table, routing trigger, RPCs, vineyards column,
--       latest-completed session index
--   T2  Manager insert of a sold pick: base row is stripped (sold_to /
--       price_per_tonne / grape_value all NULL), companion row holds the
--       values, RPC returns the computed grape value
--   T3  Operator cannot read financials: companion SELECT returns no rows,
--       RPC raises 42501; `sold` itself stays member-visible
--   T4  Operator edit echoing masked NULLs does NOT wipe the companion row
--   T5  Manager edit echoing sold=true + both NULLs (old build after 187)
--       is a no-op — companion preserved
--   T6  Manager price change updates the companion row
--   T7  Manager un-sell (sold=false) clears the companion row
--   T8  Totals views: manager sees total_grape_value, operator reads NULL
--       (same rows, same totals otherwise)
--   T9  Sampling default: 20 by default, operator can set it, member reads
--       it back, outsider is rejected, out-of-range value rejected
--   T10 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 187 picking financial privacy tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 187 is applied.
do $$
begin
  if to_regclass('public.picking_record_financials') is null
     or to_regprocedure('public.picking_records_route_financials()') is null
     or to_regprocedure('public.get_picking_record_financials(uuid)') is null
     or to_regprocedure('public.set_vineyard_yield_sampling_settings(uuid, integer)') is null then
    raise exception 'SQL 187 not applied — run sql/187_yield_reports_picking_financial_privacy.sql first.';
  end if;
end$$;

do $$
declare
  u_mgr uuid;
  u_op  uuid;
  u_out uuid;
  v_vy  uuid := gen_random_uuid();
  v_vy2 uuid := gen_random_uuid();
  b_1   uuid := gen_random_uuid();
  p1    uuid := gen_random_uuid();
  p2    uuid := gen_random_uuid();
  r     record;
  n     integer;
  num   double precision;
  v_failed boolean;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t187-mgr@test.local','t187-op@test.local','t187-out@test.local']) e;
  select id into u_mgr from auth.users where email = 't187-mgr@test.local';
  select id into u_op  from auth.users where email = 't187-op@test.local';
  select id into u_out from auth.users where email = 't187-out@test.local';

  insert into public.profiles (id, email)
  select u, 't187-' || u::text || '@test.local' from unnest(array[u_mgr, u_op, u_out]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_vy,  'T187 Privacy Vineyard'),
    (v_vy2, 'T187 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vy,  u_mgr, 'manager'),
    (v_vy,  u_op,  'operator'),
    (v_vy2, u_out, 'manager');

  -- ---- T1. Objects ---------------------------------------------------------
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'picking_record_financials'
    and column_name in ('picking_record_id','vineyard_id','sold_to','price_per_tonne','updated_by','updated_at');
  if n <> 6 then raise exception 'T1: expected 6 companion columns, found %', n; end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.picking_records'::regclass
      and tgname = 'picking_records_route_financials') then
    raise exception 'T1: routing trigger missing';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'vineyards'
      and column_name = 'yield_samples_per_hectare') then
    raise exception 'T1: vineyards.yield_samples_per_hectare missing';
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'idx_yield_sessions_latest_completed') then
    raise exception 'T1: latest-completed session index missing';
  end if;
  raise notice 'T1 passed';

  -- ---- T2. Manager insert of a sold pick ------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  insert into public.picking_records
    (id, vineyard_id, picked_at, paddock_id, paddock_name, variety_name,
     weight_kg, purpose, sold, sold_to, price_per_tonne, created_by, updated_by)
  values
    (p1, v_vy, date '2026-02-10', b_1, 'Block 1', 'Shiraz',
     2000, 'Sale', true, 'Wine Co', 1500, u_mgr, u_mgr);

  select * into r from public.picking_records where id = p1;
  if r.sold_to is not null or r.price_per_tonne is not null or r.grape_value is not null then
    raise exception 'T2: base row must be stripped of financials';
  end if;
  if r.sold is not true then raise exception 'T2: sold flag must survive'; end if;

  select * into r from public.picking_record_financials where picking_record_id = p1;
  if r.sold_to <> 'Wine Co' or r.price_per_tonne <> 1500 then
    raise exception 'T2: companion row missing/incorrect (%, %)', r.sold_to, r.price_per_tonne;
  end if;

  select grape_value into num from public.get_picking_record_financials(v_vy)
  where picking_record_id = p1;
  if num is distinct from 3.0 then
    raise exception 'T2: RPC grape_value expected 3.0 (2 t x 1500), got %', num;
  end if;
  raise notice 'T2 passed';

  -- ---- T3. Operator cannot read financials ----------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);

  select count(*) into n from public.picking_record_financials where vineyard_id = v_vy;
  if n <> 0 then raise exception 'T3: operator read % companion rows via RLS', n; end if;

  v_failed := false;
  begin
    perform * from public.get_picking_record_financials(v_vy);
  exception when insufficient_privilege then
    v_failed := true;
  end;
  if not v_failed then raise exception 'T3: RPC must raise 42501 for operator'; end if;

  -- Operational row (incl. sold flag) still visible.
  select * into r from public.picking_records where id = p1;
  if r.weight_kg <> 2000 or r.sold is not true then
    raise exception 'T3: operator must still read operational fields';
  end if;
  raise notice 'T3 passed';

  -- ---- T4. Operator echo-edit does not wipe financials -----------------------
  -- Post-187 clients read masked NULLs and echo them back on unrelated edits.
  update public.picking_records
     set notes = 'operator note', sold = true, sold_to = null, price_per_tonne = null
   where id = p1;

  perform set_config('role', 'postgres', true);
  select * into r from public.picking_record_financials where picking_record_id = p1;
  if r.sold_to is distinct from 'Wine Co' or r.price_per_tonne is distinct from 1500::double precision then
    raise exception 'T4: operator edit wiped companion financials';
  end if;
  raise notice 'T4 passed';

  -- ---- T5. Manager echo-edit (both nulls) is a no-op -------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  update public.picking_records
     set notes = 'manager note', sold = true, sold_to = null, price_per_tonne = null
   where id = p1;

  perform set_config('role', 'postgres', true);
  select * into r from public.picking_record_financials where picking_record_id = p1;
  if r.sold_to is distinct from 'Wine Co' then
    raise exception 'T5: manager echo-edit must not clear companion values';
  end if;
  perform set_config('role', 'authenticated', true);
  raise notice 'T5 passed';

  -- ---- T6. Manager price change updates the companion ------------------------
  update public.picking_records
     set sold = true, sold_to = 'Wine Co', price_per_tonne = 1750
   where id = p1;

  select price_per_tonne, grape_value into r
  from public.get_picking_record_financials(v_vy)
  where picking_record_id = p1;
  if r.price_per_tonne <> 1750 or r.grape_value is distinct from 3.5 then
    raise exception 'T6: price update not routed (%, %)', r.price_per_tonne, r.grape_value;
  end if;
  raise notice 'T6 passed';

  -- ---- T7. Un-sell clears the companion --------------------------------------
  update public.picking_records set sold = false where id = p1;

  perform set_config('role', 'postgres', true);
  select count(*) into n from public.picking_record_financials where picking_record_id = p1;
  if n <> 0 then raise exception 'T7: un-sell must clear the companion row'; end if;
  perform set_config('role', 'authenticated', true);

  -- Restore sold state for the view tests.
  update public.picking_records
     set sold = true, sold_to = 'Wine Co', price_per_tonne = 1500
   where id = p1;
  raise notice 'T7 passed';

  -- ---- T8. Totals views: manager sees money, operator does not ----------------
  insert into public.picking_records
    (id, vineyard_id, picked_at, paddock_id, paddock_name, variety_name,
     weight_kg, purpose, sold, created_by, updated_by)
  values
    (p2, v_vy, date '2026-02-12', b_1, 'Block 1', 'Shiraz',
     1000, 'Winery', false, u_mgr, u_mgr);

  select total_weight_kg, total_grape_value into r
  from public.picking_yield_totals
  where vineyard_id = v_vy and paddock_id = b_1;
  if r.total_weight_kg <> 3000 then
    raise exception 'T8: manager totals weight expected 3000, got %', r.total_weight_kg;
  end if;
  if r.total_grape_value is distinct from 3.0 then
    raise exception 'T8: manager total_grape_value expected 3.0, got %', r.total_grape_value;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  select total_weight_kg, total_grape_value into r
  from public.picking_yield_totals
  where vineyard_id = v_vy and paddock_id = b_1;
  if r.total_weight_kg <> 3000 then
    raise exception 'T8: operator must still see operational totals';
  end if;
  if r.total_grape_value is not null then
    raise exception 'T8: operator must NOT see total_grape_value (got %)', r.total_grape_value;
  end if;

  select total_grape_value into r
  from public.picking_yield_planting_totals
  where vineyard_id = v_vy and paddock_id = b_1
  limit 1;
  if r.total_grape_value is not null then
    raise exception 'T8: operator must NOT see planting total_grape_value';
  end if;
  raise notice 'T8 passed';

  -- ---- T9. Sampling default ---------------------------------------------------
  select samples_per_hectare into n from public.get_vineyard_yield_sampling_settings(v_vy);
  if n <> 20 then raise exception 'T9: default samples_per_hectare expected 20, got %', n; end if;

  -- Operator (trip runner) may persist a new shared default.
  select samples_per_hectare into n from public.set_vineyard_yield_sampling_settings(v_vy, 24);
  if n <> 24 then raise exception 'T9: set RPC should return 24, got %', n; end if;
  select samples_per_hectare into n from public.get_vineyard_yield_sampling_settings(v_vy);
  if n <> 24 then raise exception 'T9: get RPC should read back 24, got %', n; end if;

  -- Outsider rejected.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_out::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.set_vineyard_yield_sampling_settings(v_vy, 30);
  exception when insufficient_privilege then
    v_failed := true;
  end;
  if not v_failed then raise exception 'T9: outsider set must raise 42501'; end if;

  -- Out-of-range rejected.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.set_vineyard_yield_sampling_settings(v_vy, 0);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then raise exception 'T9: samples_per_hectare 0 must be rejected'; end if;
  raise notice 'T9 passed';

  perform set_config('role', 'postgres', true);
  raise notice 'SQL 187 picking financial privacy tests: ALL PASSED';
end$$;

-- T10: discard every fixture.
rollback;

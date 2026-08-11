-- =====================================================================
-- 180_picking_records_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/180_picking_records.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects, constraints, trigger, view, RPC grants exist
--   T2  Vintage is server-derived from picked_at + vineyard season settings
--       and a client-supplied vintage is never trusted
--   T3  Sugar integrity: unit normalised, value-without-unit rejected,
--       invalid unit rejected, unit cleared when value is null
--   T4  Sold behaviour: unsold rows drop sold_to/price; grape_value is
--       generated as (weight_kg/1000)*price_per_tonne for sold rows only
--   T5  Many picks per Block+Variety+Vintage; picking_yield_totals
--       aggregates SUM(weight_kg)/1000 correctly per combination
--   T6  RLS: members read/write their vineyard only; outsiders see nothing;
--       client hard delete is blocked
--   T7  soft_delete_picking_record: supervisor+ only, sets deleted_at,
--       row leaves the aggregation view
--   T8  Region settings: sugar_measurement_unit column + constraint,
--       12-param set RPC round-trips, invalid value rejected,
--       legacy 11-param set overload does NOT clear the sugar preference
--
-- Expected final output:
--   NOTICE: SQL 180 picking records tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 180 is applied.
do $$
begin
  if to_regclass('public.picking_records') is null
     or to_regclass('public.picking_yield_totals') is null
     or to_regprocedure('public.soft_delete_picking_record(uuid)') is null
     or to_regprocedure('public.set_vineyard_region_settings(uuid, text, text, text, text, text, text, text, text, text, text, text)') is null then
    raise exception 'SQL 180 not applied — run sql/180_picking_records.sql first.';
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
  b_2   uuid := gen_random_uuid();
  p1    uuid := gen_random_uuid();
  p2    uuid := gen_random_uuid();
  p3    uuid := gen_random_uuid();
  p4    uuid := gen_random_uuid();
  p5    uuid := gen_random_uuid();
  r     record;
  n     integer;
  num   double precision;
  v_failed boolean;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t180-mgr@test.local','t180-op@test.local','t180-out@test.local']) e;
  select id into u_mgr from auth.users where email = 't180-mgr@test.local';
  select id into u_op  from auth.users where email = 't180-op@test.local';
  select id into u_out from auth.users where email = 't180-out@test.local';

  insert into public.profiles (id, email)
  select u, 't180-' || u::text || '@test.local' from unnest(array[u_mgr, u_op, u_out]) u
  on conflict (id) do nothing;

  -- v_vy keeps the default season start (1 July); v_vy2 belongs to u_out.
  insert into public.vineyards (id, name) values
    (v_vy,  'T180 Picking Vineyard'),
    (v_vy2, 'T180 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vy,  u_mgr, 'manager'),
    (v_vy,  u_op,  'operator'),
    (v_vy2, u_out, 'manager');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- ---- T1. Objects, constraints, grants -----------------------------------
  perform set_config('role', 'postgres', true);
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'picking_records'
    and column_name in ('id','vineyard_id','picked_at','vintage','paddock_id','paddock_name',
                        'variety_id','variety_key','variety_name','clone','weight_kg',
                        'sugar_value','sugar_unit','ph','ta_g_l','purpose','sold','sold_to',
                        'price_per_tonne','grape_value','notes','created_by','updated_by',
                        'created_at','updated_at','deleted_at','client_updated_at','sync_version');
  if n <> 28 then raise exception 'T1: expected 28 contract columns, found %', n; end if;

  select count(*) into n from pg_trigger
  where tgrelid = 'public.picking_records'::regclass
    and tgname in ('picking_records_before_write', 'picking_records_set_updated_at');
  if n <> 2 then raise exception 'T1: triggers missing'; end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.vineyards'::regclass
      and conname = 'vineyards_sugar_measurement_unit_check') then
    raise exception 'T1: vineyards sugar unit constraint missing';
  end if;
  raise notice 'T1 passed';

  -- ---- T2. Server-derived vintage ------------------------------------------
  perform set_config('role', 'authenticated', true);

  -- Feb 2026 is BEFORE the 1 July season start -> vintage 2026.
  insert into public.picking_records (id, vineyard_id, picked_at, vintage, paddock_id, paddock_name, variety_name, weight_kg, created_by, updated_by)
  values (p1, v_vy, date '2026-02-10', 9999, b_1, 'Block 1', 'Shiraz', 2450, u_mgr, u_mgr);
  select * into r from public.picking_records where id = p1;
  if r.vintage <> 2026 then
    raise exception 'T2: Feb 2026 should be vintage 2026 (client 9999 ignored), got %', r.vintage;
  end if;

  -- Aug 2026 is ON/AFTER the 1 July season start -> vintage 2027.
  insert into public.picking_records (id, vineyard_id, picked_at, paddock_id, paddock_name, variety_name, weight_kg, created_by, updated_by)
  values (p2, v_vy, date '2026-08-15', b_1, 'Block 1', 'Shiraz', 1000, u_mgr, u_mgr);
  select * into r from public.picking_records where id = p2;
  if r.vintage <> 2027 then
    raise exception 'T2: Aug 2026 should be vintage 2027, got %', r.vintage;
  end if;

  -- Changing picked_at on update re-derives the vintage.
  update public.picking_records set picked_at = date '2027-02-01' where id = p2;
  select * into r from public.picking_records where id = p2;
  if r.vintage <> 2027 then
    raise exception 'T2: Feb 2027 should stay vintage 2027, got %', r.vintage;
  end if;
  update public.picking_records set picked_at = date '2026-08-15' where id = p2;
  raise notice 'T2 passed';

  -- ---- T3. Sugar integrity --------------------------------------------------
  update public.picking_records set sugar_value = 22.4, sugar_unit = '  BRIX ' where id = p1;
  select * into r from public.picking_records where id = p1;
  if r.sugar_unit <> 'brix' or r.sugar_value <> 22.4 then
    raise exception 'T3: sugar unit not normalised: % %', r.sugar_unit, r.sugar_value;
  end if;

  -- value without unit rejected
  v_failed := false;
  begin
    update public.picking_records set sugar_value = 12.4, sugar_unit = null where id = p1;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T3: sugar value without unit not rejected'; end if;

  -- invalid unit rejected
  v_failed := false;
  begin
    update public.picking_records set sugar_unit = 'oechsle' where id = p1;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T3: invalid sugar unit not rejected'; end if;

  -- clearing the value clears the stored unit
  update public.picking_records set sugar_value = null where id = p1;
  select * into r from public.picking_records where id = p1;
  if r.sugar_unit is not null then raise exception 'T3: unit should clear with value'; end if;
  update public.picking_records set sugar_value = 12.4, sugar_unit = 'baume' where id = p1;
  raise notice 'T3 passed';

  -- ---- T4. Sold behaviour + generated grape_value ---------------------------
  update public.picking_records
     set sold = true, sold_to = 'Casella Wines', price_per_tonne = 850
   where id = p1;
  select * into r from public.picking_records where id = p1;
  if round((r.grape_value)::numeric, 4) <> round((2450.0 / 1000.0 * 850.0)::numeric, 4) then
    raise exception 'T4: grape_value wrong: %', r.grape_value;
  end if;

  -- flipping sold off drops the commercial fields and the generated value
  update public.picking_records set sold = false where id = p1;
  select * into r from public.picking_records where id = p1;
  if r.sold_to is not null or r.price_per_tonne is not null or r.grape_value is not null then
    raise exception 'T4: unsold row kept commercial fields: % % %', r.sold_to, r.price_per_tonne, r.grape_value;
  end if;
  update public.picking_records
     set sold = true, sold_to = 'Casella Wines', price_per_tonne = 850
   where id = p1;

  -- zero/negative weight rejected
  v_failed := false;
  begin
    insert into public.picking_records (vineyard_id, picked_at, paddock_id, variety_name, weight_kg)
    values (v_vy, date '2026-02-11', b_1, 'Shiraz', 0);
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T4: zero weight not rejected'; end if;
  raise notice 'T4 passed';

  -- ---- T5. Many picks + aggregation view ------------------------------------
  -- Spec example: 10 Feb 2450 kg + 12 Feb 3100 kg + 15 Feb 1900 kg, same
  -- Block+Variety+Vintage -> 7.45 t. p1 already holds the 10 Feb pick.
  insert into public.picking_records (id, vineyard_id, picked_at, paddock_id, paddock_name, variety_name, weight_kg, created_by, updated_by)
  values
    (p3, v_vy, date '2026-02-12', b_1, 'Block 1', 'Shiraz', 3100, u_mgr, u_mgr),
    (p4, v_vy, date '2026-02-15', b_1, 'Block 1', 'Shiraz', 1900, u_mgr, u_mgr);
  -- A different variety in the same block must aggregate separately.
  insert into public.picking_records (id, vineyard_id, picked_at, paddock_id, paddock_name, variety_name, weight_kg, created_by, updated_by)
  values (p5, v_vy, date '2026-02-16', b_1, 'Block 1', 'Grenache', 500, u_mgr, u_mgr);

  select * into r from public.picking_yield_totals
  where vineyard_id = v_vy and vintage = 2026 and paddock_id = b_1 and variety_name = 'Shiraz';
  if r.pick_count <> 3
     or round((r.total_weight_kg)::numeric, 4) <> 7450
     or round((r.actual_yield_tonnes)::numeric, 4) <> 7.45
     or r.first_picked_at <> date '2026-02-10'
     or r.last_picked_at <> date '2026-02-15' then
    raise exception 'T5: Shiraz totals wrong: count=% kg=% t=%', r.pick_count, r.total_weight_kg, r.actual_yield_tonnes;
  end if;

  select * into r from public.picking_yield_totals
  where vineyard_id = v_vy and vintage = 2026 and paddock_id = b_1 and variety_name = 'Grenache';
  if r.pick_count <> 1 or round((r.actual_yield_tonnes)::numeric, 4) <> 0.5 then
    raise exception 'T5: Grenache totals wrong';
  end if;

  -- The Aug 2026 pick (vintage 2027) must NOT be inside the 2026 bucket.
  select count(*) into n from public.picking_yield_totals
  where vineyard_id = v_vy and vintage = 2027 and paddock_id = b_1 and variety_name = 'Shiraz';
  if n <> 1 then raise exception 'T5: vintage 2027 bucket missing'; end if;
  raise notice 'T5 passed';

  -- ---- T6. RLS ---------------------------------------------------------------
  -- outsider sees nothing in v_vy
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_out::text, 'role', 'authenticated')::text, true);
  select count(*) into n from public.picking_records where vineyard_id = v_vy;
  if n <> 0 then raise exception 'T6: outsider can read foreign picking records'; end if;
  select count(*) into n from public.picking_yield_totals where vineyard_id = v_vy;
  if n <> 0 then raise exception 'T6: outsider can read foreign totals via view'; end if;

  -- outsider cannot insert into v_vy
  v_failed := false;
  begin
    insert into public.picking_records (vineyard_id, picked_at, paddock_id, variety_name, weight_kg)
    values (v_vy, date '2026-02-20', b_1, 'Shiraz', 100);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T6: outsider insert not blocked'; end if;

  -- operator CAN insert (owner/manager/supervisor/operator write roles)
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  insert into public.picking_records (vineyard_id, picked_at, paddock_id, paddock_name, variety_name, weight_kg, created_by, updated_by)
  values (v_vy, date '2026-02-21', b_2, 'Block 2', 'Chardonnay', 750, u_op, u_op);

  -- client hard delete blocked for everyone
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  delete from public.picking_records where id = p1;
  select count(*) into n from public.picking_records where id = p1;
  if n <> 1 then raise exception 'T6: client hard delete was not blocked'; end if;
  raise notice 'T6 passed';

  -- ---- T7. Soft delete RPC ----------------------------------------------------
  -- operator (below supervisor) is rejected
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.soft_delete_picking_record(p4);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T7: operator delete not rejected'; end if;

  -- manager succeeds; row leaves the aggregation view
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  perform public.soft_delete_picking_record(p4);
  select * into r from public.picking_records where id = p4;
  if r.deleted_at is null or r.updated_by <> u_mgr then
    raise exception 'T7: soft delete did not stamp deleted_at/updated_by';
  end if;
  select total_weight_kg into num from public.picking_yield_totals
  where vineyard_id = v_vy and vintage = 2026 and paddock_id = b_1 and variety_name = 'Shiraz';
  if round(num::numeric, 4) <> 5550 then
    raise exception 'T7: deleted pick still aggregated: % kg', num;
  end if;
  raise notice 'T7 passed';

  -- ---- T8. Region settings sugar preference -----------------------------------
  select sugar_measurement_unit into r from public.get_vineyard_region_settings(v_vy) g(vineyard_id, country_code, currency_code, timezone, area_unit, volume_unit, distance_unit, fuel_unit, spray_rate_area_unit, date_format, terminology_region, sugar_measurement_unit);
  if r.sugar_measurement_unit is not null then
    raise exception 'T8: fresh vineyard should have null sugar preference';
  end if;

  perform public.set_vineyard_region_settings(
    v_vy, 'AU', 'AUD', 'Australia/Sydney', null, null, null, null, null, null, null, 'Baume');
  select v.sugar_measurement_unit into r from public.vineyards v where v.id = v_vy;
  if r.sugar_measurement_unit <> 'baume' then
    raise exception 'T8: sugar preference not normalised/saved: %', r.sugar_measurement_unit;
  end if;

  -- invalid value rejected
  v_failed := false;
  begin
    perform public.set_vineyard_region_settings(
      v_vy, 'AU', 'AUD', 'Australia/Sydney', null, null, null, null, null, null, null, 'oechsle');
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T8: invalid sugar unit not rejected'; end if;

  -- legacy 11-param overload must NOT clear the preference
  perform public.set_vineyard_region_settings(
    v_vy, 'AU', 'AUD', 'Australia/Sydney', null, null, null, null, null, null, null);
  select v.sugar_measurement_unit into r from public.vineyards v where v.id = v_vy;
  if r.sugar_measurement_unit <> 'baume' then
    raise exception 'T8: legacy set overload cleared the sugar preference';
  end if;

  -- non-member cannot write settings
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_out::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.set_vineyard_region_settings(
      v_vy, 'AU', 'AUD', 'Australia/Sydney', null, null, null, null, null, null, null, 'brix');
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T8: outsider settings write not rejected'; end if;
  raise notice 'T8 passed';

  perform set_config('role', 'postgres', true);
  raise notice 'SQL 180 picking records tests: ALL PASSED';
end$$;

rollback;

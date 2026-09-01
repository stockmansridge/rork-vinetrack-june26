-- =====================================================================
-- 217_grape_allocations_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/217_grape_allocations.sql
-- AND sql/218_grape_allocation_costs_write.sql (218 re-points the price
-- write gate from costs:read to the dedicated costs:write scope).
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
--
-- Test map
--   T1  Objects: tables, financial companion, routing trigger, RPCs,
--       scope catalogue rows
--   T2  Financial routing: owner-written price never rests on the base
--       row; companion holds it; own_use rows never hold a price
--   T3  DB financial privacy: operator reads allocation but CANNOT read
--       the companion (RLS) and get_grape_allocation_financials raises
--       42501; owner receives price + derived contract_value
--   T4  Vineyard isolation: a member of another vineyard sees nothing
--   T5  API create: own_use and external with a multi-block split;
--       provenance columns; representation contains blocks and NO price
--   T6  Idempotency: replay returns the original id; different payload
--       with the same key → idempotency_conflict; missing key →
--       idempotency_required
--   T7  PATCH: expected_updated_at required; stale token → conflict;
--       partial update semantics; blocks replaced wholesale
--   T8  Scopes: read-only key cannot write; write key with costs:read but
--       WITHOUT costs:write cannot set price_per_tonne (read disclosure
--       never authorises a financial write); write key WITH costs:write can
--   T9  Contract totals: two contracts at different $/t sum individually
--       (never an averaged $/t) via get_grape_allocation_financials
--   T10 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 217 grape allocation tests: ALL PASSED
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.integration_api_create_grape_allocation(text,uuid,text,jsonb)') is null then
    raise exception 'SQL 217 not applied — run sql/217_grape_allocations.sql first.';
  end if;
end$$;

do $$
declare
  u_owner uuid; u_operator uuid; u_stranger uuid;
  v1 uuid := gen_random_uuid();          -- test vineyard
  v2 uuid := gen_random_uuid();          -- other vineyard (isolation)
  b1 uuid := gen_random_uuid();
  b2 uuid := gen_random_uuid();
  i1 uuid := gen_random_uuid();          -- write + costs:read + costs:write
  i2 uuid := gen_random_uuid();          -- read only
  i4 uuid := gen_random_uuid();          -- write + costs:read, NO costs:write
  k1 text := 'vt_test_' || repeat('e5', 24);
  k2 text := 'vt_test_' || repeat('f6', 24);
  k4 text := 'vt_test_' || repeat('a7', 24);
  r jsonb; n integer;
  a_own uuid := gen_random_uuid();
  a_ext uuid := gen_random_uuid();
  a_ext2 uuid := gen_random_uuid();
  v_id uuid;
  v_updated timestamptz;
  v_row record;
  v_total double precision;
  v_caught boolean;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't217-owner@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't217-operator@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't217-stranger@test.local', 'x', now(), now(), now());
  select id into u_owner from auth.users where email = 't217-owner@test.local';
  select id into u_operator from auth.users where email = 't217-operator@test.local';
  select id into u_stranger from auth.users where email = 't217-stranger@test.local';
  insert into public.profiles (id, email)
  values (u_owner, 't217-owner@test.local'), (u_operator, 't217-operator@test.local'),
         (u_stranger, 't217-stranger@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values (v1, 'T217 Vineyard'), (v2, 'T217 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v1, u_owner, 'owner'), (v1, u_operator, 'operator'), (v2, u_stranger, 'owner');
  insert into public.paddocks (id, vineyard_id, name) values
    (b1, v1, 'T217 Block One'), (b2, v1, 'T217 Block Two');

  insert into public.integration_clients (id, owner_user_id, name, integration_type, status, created_by)
  values (i1, u_owner, 'T217 Writer+Costs', 'custom_api', 'active', u_owner),
         (i2, u_owner, 'T217 Reader', 'custom_api', 'active', u_owner),
         (i4, u_owner, 'T217 Writer NoCosts', 'custom_api', 'active', u_owner);
  insert into public.integration_api_keys (integration_client_id, environment, key_prefix, key_hash, created_by)
  values (i1, 'test', left(k1, 16), public._integration_hash_secret(k1), u_owner),
         (i2, 'test', left(k2, 16), public._integration_hash_secret(k2), u_owner),
         (i4, 'test', left(k4, 16), public._integration_hash_secret(k4), u_owner);
  insert into public.integration_client_vineyards (integration_client_id, vineyard_id, granted_by)
  values (i1, v1, u_owner), (i2, v1, u_owner), (i4, v1, u_owner);
  insert into public.integration_client_scopes (integration_client_id, scope, granted_by)
  values (i1, 'grape_allocations:write', u_owner),
         (i1, 'grape_allocations:read', u_owner),
         (i1, 'costs:read', u_owner),
         (i1, 'costs:write', u_owner),
         (i2, 'grape_allocations:read', u_owner),
         (i4, 'grape_allocations:write', u_owner),
         (i4, 'costs:read', u_owner);

  -- ---- T1. Objects ---------------------------------------------------------
  if to_regclass('public.grape_allocations') is null then raise exception 'T1: grape_allocations missing'; end if;
  if to_regclass('public.grape_allocation_blocks') is null then raise exception 'T1: grape_allocation_blocks missing'; end if;
  if to_regclass('public.grape_allocation_financials') is null then raise exception 'T1: financial companion missing'; end if;
  select count(*) into n from pg_trigger
  where tgrelid = 'public.grape_allocations'::regclass and tgname = 'grape_allocations_route_financials';
  if n <> 1 then raise exception 'T1: routing trigger missing'; end if;
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname in (
    'soft_delete_grape_allocation', 'get_grape_allocation_financials',
    'integration_api_create_grape_allocation', 'integration_api_update_grape_allocation',
    '_integration_api_grape_allocation_json');
  if n <> 5 then raise exception 'T1: expected 5 RPCs, found %', n; end if;
  select count(*) into n from public.integration_scope_catalog
  where scope in ('grape_allocations:read', 'grape_allocations:write');
  if n <> 2 then raise exception 'T1: scope catalogue rows missing'; end if;
  raise notice 'T1 passed';

  -- ---- T2. Financial routing ------------------------------------------------
  -- Simulate the OWNER writing through the app (RLS + trigger path).
  perform set_config('request.jwt.claims', json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  insert into public.grape_allocations
    (id, vineyard_id, vintage, allocation_type, variety_name, destination_name, quantity_tonnes, created_by)
  values (a_own, v1, 2027, 'own_use', 'Shiraz', 'Estate wine', 5, u_owner);

  insert into public.grape_allocations
    (id, vineyard_id, vintage, allocation_type, variety_name, quantity_tonnes,
     purchaser_name, contact_name, contact_email, contact_phone, price_per_tonne, created_by)
  values (a_ext, v1, 2027, 'external', 'Shiraz', 20,
          'T217 Winery A', 'Alice', 'alice@a.test', '+61 400 000 001', 2500, u_owner);

  insert into public.grape_allocations
    (id, vineyard_id, vintage, allocation_type, variety_name, quantity_tonnes,
     purchaser_name, price_per_tonne, created_by)
  values (a_ext2, v1, 2027, 'external', 'Chardonnay', 10, 'T217 Winery B', 1800, u_owner);

  insert into public.grape_allocation_blocks (allocation_id, vineyard_id, paddock_id, paddock_name, quantity_tonnes)
  values (a_ext, v1, b1, 'T217 Block One', 12), (a_ext, v1, b2, 'T217 Block Two', 8);

  perform set_config('role', 'postgres', true);
  select * into v_row from public.grape_allocations where id = a_ext;
  if v_row.price_per_tonne is not null then raise exception 'T2: price rested on the base row'; end if;
  select count(*) into n from public.grape_allocation_financials where allocation_id = a_ext and price_per_tonne = 2500;
  if n <> 1 then raise exception 'T2: companion row missing/wrong'; end if;
  select count(*) into n from public.grape_allocation_financials where allocation_id = a_own;
  if n <> 0 then raise exception 'T2: own_use must never hold a price'; end if;
  raise notice 'T2 passed';

  -- ---- T3. DB financial privacy ----------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', u_operator, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  select count(*) into n from public.grape_allocations where vineyard_id = v1;
  if n <> 3 then raise exception 'T3: operator should read 3 allocations, got %', n; end if;
  select count(*) into n from public.grape_allocation_financials where vineyard_id = v1;
  if n <> 0 then raise exception 'T3: operator must not read the financial companion'; end if;

  v_caught := false;
  begin
    perform * from public.get_grape_allocation_financials(v1);
  exception when insufficient_privilege then
    v_caught := true;
  end;
  if not v_caught then raise exception 'T3: get_grape_allocation_financials must raise 42501 for operator'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  select count(*) into n from public.get_grape_allocation_financials(v1)
  where allocation_id = a_ext and price_per_tonne = 2500 and contract_value = 50000;
  if n <> 1 then raise exception 'T3: owner financials wrong (expected 20t x 2500 = 50000)'; end if;
  perform set_config('role', 'postgres', true);
  raise notice 'T3 passed';

  -- ---- T4. Vineyard isolation --------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', u_stranger, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  select count(*) into n from public.grape_allocations where vineyard_id = v1;
  if n <> 0 then raise exception 'T4: stranger read another vineyard''s allocations'; end if;
  select count(*) into n from public.grape_allocation_blocks where vineyard_id = v1;
  if n <> 0 then raise exception 'T4: stranger read another vineyard''s block splits'; end if;
  perform set_config('role', 'postgres', true);
  raise notice 'T4 passed';

  -- ---- T5. API create -----------------------------------------------------------
  r := public.integration_api_create_grape_allocation(k1, v1, 'idem-ga-1', jsonb_build_object(
    'vintage', 2027,
    'allocation_type', 'external',
    'variety_name', 'Shiraz',
    'purchaser_name', 'T217 Winery C',
    'contact_email', 'c@c.test',
    'quantity_tonnes', 15,
    'price_per_tonne', 2100,
    'blocks', jsonb_build_array(
      jsonb_build_object('block_id', b1, 'quantity_tonnes', 9),
      jsonb_build_object('block_id', b2, 'quantity_tonnes', 6)),
    'external_id', 'crm-ga-1'));
  if not (r->>'ok')::boolean or (r->>'status')::int <> 201 then raise exception 'T5: create failed: %', r; end if;
  v_id := (r->'data'->>'id')::uuid;
  if r->'data' ? 'price_per_tonne' then raise exception 'T5: base representation must not contain price'; end if;
  if jsonb_array_length(r->'data'->'blocks') <> 2 then raise exception 'T5: blocks not in representation'; end if;

  select * into v_row from public.grape_allocations where id = v_id;
  if v_row.origin <> 'integration' or v_row.integration_client_id <> i1 or v_row.created_by is not null then
    raise exception 'T5: provenance wrong';
  end if;
  select count(*) into n from public.grape_allocation_blocks where allocation_id = v_id;
  if n <> 2 then raise exception 'T5: block split rows missing'; end if;
  select count(*) into n from public.grape_allocation_financials where allocation_id = v_id and price_per_tonne = 2100;
  if n <> 1 then raise exception 'T5: API price not routed to companion'; end if;

  r := public.integration_api_create_grape_allocation(k1, v1, 'idem-ga-own', jsonb_build_object(
    'vintage', 2027, 'allocation_type', 'own_use', 'variety_name', 'Chardonnay',
    'destination_name', 'Sparkling program', 'quantity_tonnes', 3));
  if not (r->>'ok')::boolean then raise exception 'T5: own_use create failed: %', r; end if;
  raise notice 'T5 passed';

  -- ---- T6. Idempotency -----------------------------------------------------------
  r := public.integration_api_create_grape_allocation(k1, v1, 'idem-ga-1', jsonb_build_object(
    'vintage', 2027,
    'allocation_type', 'external',
    'variety_name', 'Shiraz',
    'purchaser_name', 'T217 Winery C',
    'contact_email', 'c@c.test',
    'quantity_tonnes', 15,
    'price_per_tonne', 2100,
    'blocks', jsonb_build_array(
      jsonb_build_object('block_id', b1, 'quantity_tonnes', 9),
      jsonb_build_object('block_id', b2, 'quantity_tonnes', 6)),
    'external_id', 'crm-ga-1'));
  if not (r->>'replayed')::boolean or (r->'data'->>'id')::uuid <> v_id then
    raise exception 'T6: idempotent replay failed: %', r;
  end if;
  select count(*) into n from public.grape_allocations where external_id = 'crm-ga-1';
  if n <> 1 then raise exception 'T6: replay created a duplicate'; end if;

  r := public.integration_api_create_grape_allocation(k1, v1, 'idem-ga-1', jsonb_build_object(
    'vintage', 2027, 'allocation_type', 'own_use', 'variety_name', 'Merlot', 'quantity_tonnes', 1));
  if (r->>'ok')::boolean or r->>'error' <> 'idempotency_conflict' then
    raise exception 'T6: same key different payload must be idempotency_conflict: %', r;
  end if;

  r := public.integration_api_create_grape_allocation(k1, v1, null, jsonb_build_object(
    'vintage', 2027, 'allocation_type', 'own_use', 'variety_name', 'Merlot', 'quantity_tonnes', 1));
  if (r->>'ok')::boolean or r->>'error' <> 'idempotency_required' then
    raise exception 'T6: missing key must be idempotency_required: %', r;
  end if;
  raise notice 'T6 passed';

  -- ---- T7. PATCH ------------------------------------------------------------------
  select updated_at into v_updated from public.grape_allocations where id = v_id;

  r := public.integration_api_update_grape_allocation(k1, v_id, jsonb_build_object('quantity_tonnes', 18));
  if (r->>'ok')::boolean or r->>'error' <> 'validation_failed' then
    raise exception 'T7: expected_updated_at must be required: %', r;
  end if;

  r := public.integration_api_update_grape_allocation(k1, v_id, jsonb_build_object(
    'expected_updated_at', '2000-01-01T00:00:00Z', 'quantity_tonnes', 18));
  if (r->>'ok')::boolean or r->>'error' <> 'conflict' then
    raise exception 'T7: stale token must be conflict: %', r;
  end if;

  r := public.integration_api_update_grape_allocation(k1, v_id, jsonb_build_object(
    'expected_updated_at', to_char(v_updated at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'quantity_tonnes', 18,
    'blocks', jsonb_build_array(jsonb_build_object('block_id', b1, 'quantity_tonnes', 18))));
  if not (r->>'ok')::boolean then raise exception 'T7: patch failed: %', r; end if;
  if (r->'data'->>'quantity_tonnes')::numeric <> 18 then raise exception 'T7: quantity not updated'; end if;
  if (r->'data'->>'purchaser_name') <> 'T217 Winery C' then raise exception 'T7: omitted field changed'; end if;
  select count(*) into n from public.grape_allocation_blocks where allocation_id = v_id;
  if n <> 1 then raise exception 'T7: blocks not replaced wholesale'; end if;
  -- Price untouched by the PATCH must survive (companion preserved).
  select count(*) into n from public.grape_allocation_financials where allocation_id = v_id and price_per_tonne = 2100;
  if n <> 1 then raise exception 'T7: untouched price was lost by PATCH'; end if;
  raise notice 'T7 passed';

  -- ---- T8. Scopes --------------------------------------------------------------------
  r := public.integration_api_create_grape_allocation(k2, v1, 'idem-ga-ro', jsonb_build_object(
    'vintage', 2027, 'allocation_type', 'own_use', 'variety_name', 'Merlot', 'quantity_tonnes', 1));
  if (r->>'ok')::boolean or r->>'error' <> 'scope_not_granted' then
    raise exception 'T8: read-only key must not write: %', r;
  end if;

  r := public.integration_api_create_grape_allocation(k4, v1, 'idem-ga-nc', jsonb_build_object(
    'vintage', 2027, 'allocation_type', 'external', 'variety_name', 'Merlot',
    'purchaser_name', 'T217 Winery D', 'quantity_tonnes', 2, 'price_per_tonne', 3000));
  if (r->>'ok')::boolean or r->>'error' <> 'validation_failed' then
    raise exception 'T8: price with costs:read but WITHOUT costs:write must be validation_failed: %', r;
  end if;
  if not exists (
    select 1 from jsonb_array_elements(r->'details') d
    where d->>'field' = 'price_per_tonne' and d->>'issue' like '%costs:write%'
  ) then
    raise exception 'T8: rejection must name the costs:write scope: %', r;
  end if;

  r := public.integration_api_create_grape_allocation(k4, v1, 'idem-ga-nc2', jsonb_build_object(
    'vintage', 2027, 'allocation_type', 'external', 'variety_name', 'Merlot',
    'purchaser_name', 'T217 Winery D', 'quantity_tonnes', 2));
  if not (r->>'ok')::boolean then raise exception 'T8: priceless external create should succeed: %', r; end if;
  raise notice 'T8 passed';

  -- ---- T9. Contract totals: individual values, never averaged $/t ---------------------
  perform set_config('request.jwt.claims', json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  -- a_ext 20t @ 2500 = 50000; a_ext2 10t @ 1800 = 18000; API v_id 18t @ 2100 = 37800.
  select sum(contract_value) into v_total from public.get_grape_allocation_financials(v1);
  if round(v_total::numeric, 2) <> 105800.00 then
    raise exception 'T9: expected 105800 (sum of individual contract values), got %', v_total;
  end if;
  perform set_config('role', 'postgres', true);
  raise notice 'T9 passed';

  raise notice 'SQL 217 grape allocation tests: ALL PASSED';
end$$;

rollback;

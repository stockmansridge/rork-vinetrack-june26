-- =====================================================================
-- 219_grape_purchasers_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/217, sql/218 AND
-- sql/219_grape_purchasers.sql.
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
--
-- Test map
--   T1  Objects: grape_purchasers table, purchaser_id column + constraint,
--       same-vineyard trigger, RPCs, scope catalogue rows
--   T2  App path: member creates and edits a purchaser through RLS;
--       vineyard isolation (a member of another vineyard sees nothing);
--       soft delete via RPC (never hard delete)
--   T3  API purchaser CRUD: POST creates with provenance; idempotent
--       replay; PATCH requires expected_updated_at, stale token conflicts;
--       read-only key cannot write (scope_not_granted)
--   T4  API allocation + purchaser_id: snapshot copied onto the
--       allocation; purchaser_id mutually exclusive with explicit fields;
--       cross-vineyard purchaser rejected; own_use + purchaser_id rejected
--   T5  Snapshot immutability: editing the purchaser later does NOT
--       rewrite the old allocation snapshot; a NEW allocation snapshots
--       the NEW details; one purchaser carries multiple allocations
--   T6  Compatibility: allocation without purchaser_id (explicit snapshot
--       fields only) still creates/updates; PATCH switching to own_use
--       clears the purchaser link; unlink (purchaser_id null) keeps the
--       historical snapshot; DB constraint rejects own_use + purchaser_id
--   T7  Financial architecture unchanged: price still routes to the
--       companion on a purchaser-linked allocation (costs:write path)
--   T8  All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 219 grape purchaser tests: ALL PASSED
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.integration_api_create_grape_purchaser(text,uuid,text,jsonb)') is null then
    raise exception 'SQL 219 not applied — run sql/219_grape_purchasers.sql first.';
  end if;
end$$;

do $$
declare
  u_owner uuid; u_operator uuid; u_stranger uuid;
  v1 uuid := gen_random_uuid();          -- test vineyard
  v2 uuid := gen_random_uuid();          -- other vineyard (isolation)
  b1 uuid := gen_random_uuid();
  i1 uuid := gen_random_uuid();          -- allocations+purchasers write + costs:write
  i2 uuid := gen_random_uuid();          -- grape_purchasers:read only
  k1 text := 'vt_test_' || repeat('c9', 24);
  k2 text := 'vt_test_' || repeat('d8', 24);
  r jsonb; n integer;
  p_app uuid := gen_random_uuid();       -- app-created purchaser
  p_v2 uuid := gen_random_uuid();        -- purchaser in the OTHER vineyard
  p_api uuid;                            -- API-created purchaser
  a1 uuid;                               -- purchaser-linked allocation
  a2 uuid;                               -- second allocation, same purchaser
  a_plain uuid;                          -- snapshot-only allocation (no link)
  v_updated timestamptz;
  v_row record;
  v_caught boolean;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't219-owner@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't219-operator@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't219-stranger@test.local', 'x', now(), now(), now());
  select id into u_owner from auth.users where email = 't219-owner@test.local';
  select id into u_operator from auth.users where email = 't219-operator@test.local';
  select id into u_stranger from auth.users where email = 't219-stranger@test.local';
  insert into public.profiles (id, email)
  values (u_owner, 't219-owner@test.local'), (u_operator, 't219-operator@test.local'),
         (u_stranger, 't219-stranger@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values (v1, 'T219 Vineyard'), (v2, 'T219 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v1, u_owner, 'owner'), (v1, u_operator, 'operator'), (v2, u_stranger, 'owner');
  insert into public.paddocks (id, vineyard_id, name) values (b1, v1, 'T219 Block One');

  -- Purchaser in the OTHER vineyard (cross-vineyard rejection fixture).
  insert into public.grape_purchasers (id, vineyard_id, winery_name, created_by)
  values (p_v2, v2, 'T219 Foreign Winery', u_stranger);

  insert into public.integration_clients (id, owner_user_id, name, integration_type, status, created_by)
  values (i1, u_owner, 'T219 Writer', 'custom_api', 'active', u_owner),
         (i2, u_owner, 'T219 Purchaser Reader', 'custom_api', 'active', u_owner);
  insert into public.integration_api_keys (integration_client_id, environment, key_prefix, key_hash, created_by)
  values (i1, 'test', left(k1, 16), public._integration_hash_secret(k1), u_owner),
         (i2, 'test', left(k2, 16), public._integration_hash_secret(k2), u_owner);
  insert into public.integration_client_vineyards (integration_client_id, vineyard_id, granted_by)
  values (i1, v1, u_owner), (i2, v1, u_owner);
  insert into public.integration_client_scopes (integration_client_id, scope, granted_by)
  values (i1, 'grape_allocations:write', u_owner),
         (i1, 'grape_allocations:read', u_owner),
         (i1, 'grape_purchasers:write', u_owner),
         (i1, 'grape_purchasers:read', u_owner),
         (i1, 'costs:read', u_owner),
         (i1, 'costs:write', u_owner),
         (i2, 'grape_purchasers:read', u_owner);

  -- ---- T1. Objects ---------------------------------------------------------
  if to_regclass('public.grape_purchasers') is null then raise exception 'T1: grape_purchasers missing'; end if;
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'grape_allocations' and column_name = 'purchaser_id';
  if n <> 1 then raise exception 'T1: grape_allocations.purchaser_id missing'; end if;
  select count(*) into n from pg_constraint
  where conrelid = 'public.grape_allocations'::regclass
    and conname = 'grape_allocations_own_use_no_purchaser_link';
  if n <> 1 then raise exception 'T1: own_use purchaser_id constraint missing'; end if;
  select count(*) into n from pg_trigger
  where tgrelid = 'public.grape_allocations'::regclass and tgname = 'grape_allocations_validate_purchaser';
  if n <> 1 then raise exception 'T1: same-vineyard purchaser trigger missing'; end if;
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname in (
    'soft_delete_grape_purchaser',
    'integration_api_create_grape_purchaser', 'integration_api_update_grape_purchaser',
    '_integration_api_grape_purchaser_json');
  if n <> 4 then raise exception 'T1: expected 4 purchaser RPCs, found %', n; end if;
  select count(*) into n from public.integration_scope_catalog
  where scope in ('grape_purchasers:read', 'grape_purchasers:write');
  if n <> 2 then raise exception 'T1: scope catalogue rows missing'; end if;
  raise notice 'T1 passed';

  -- ---- T2. App path (RLS) ----------------------------------------------------
  -- Operator (write role) creates a purchaser through the table.
  perform set_config('request.jwt.claims', json_build_object('sub', u_operator, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  insert into public.grape_purchasers (id, vineyard_id, winery_name, contact_name, contact_email, created_by)
  values (p_app, v1, 'T219 Winery A', 'Alice', 'alice@a.test', u_operator);

  -- ...and edits it.
  update public.grape_purchasers set contact_phone = '+61 400 000 001' where id = p_app;
  select count(*) into n from public.grape_purchasers
  where id = p_app and contact_phone = '+61 400 000 001';
  if n <> 1 then raise exception 'T2: member edit failed'; end if;

  -- No financial columns exist on the purchaser table.
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'grape_purchasers'
    and column_name in ('price_per_tonne', 'contract_value');
  if n <> 0 then raise exception 'T2: financial data must never live in grape_purchasers'; end if;

  -- Vineyard isolation: the stranger sees nothing of v1.
  perform set_config('request.jwt.claims', json_build_object('sub', u_stranger, 'role', 'authenticated')::text, true);
  select count(*) into n from public.grape_purchasers where vineyard_id = v1;
  if n <> 0 then raise exception 'T2: stranger read another vineyard''s purchasers'; end if;

  -- Hard delete is denied by policy (0 rows affected under RLS).
  perform set_config('request.jwt.claims', json_build_object('sub', u_operator, 'role', 'authenticated')::text, true);
  delete from public.grape_purchasers where id = p_app;
  select count(*) into n from public.grape_purchasers where id = p_app;
  if n <> 1 then raise exception 'T2: hard delete must be denied'; end if;

  -- Soft delete goes through the RPC and only marks deleted_at.
  perform public.soft_delete_grape_purchaser(p_app);
  select count(*) into n from public.grape_purchasers where id = p_app and deleted_at is not null;
  if n <> 1 then raise exception 'T2: soft delete RPC failed'; end if;
  -- Restore for later tests (postgres path).
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  update public.grape_purchasers set deleted_at = null where id = p_app;
  raise notice 'T2 passed';

  -- ---- T3. API purchaser CRUD -------------------------------------------------
  r := public.integration_api_create_grape_purchaser(k1, v1, 'idem-gp-1', jsonb_build_object(
    'winery_name', 'T219 Winery B',
    'contact_name', 'Bob',
    'contact_email', 'bob@b.test',
    'contact_phone', '+61 400 000 002',
    'contact_address', '1 Cellar Lane',
    'external_id', 'crm-gp-1'));
  if not (r->>'ok')::boolean or (r->>'status')::int <> 201 then raise exception 'T3: create failed: %', r; end if;
  p_api := (r->'data'->>'id')::uuid;
  select * into v_row from public.grape_purchasers where id = p_api;
  if v_row.origin <> 'integration' or v_row.integration_client_id <> i1 or v_row.created_by is not null then
    raise exception 'T3: provenance wrong';
  end if;

  -- Idempotent replay returns the original id.
  r := public.integration_api_create_grape_purchaser(k1, v1, 'idem-gp-1', jsonb_build_object(
    'winery_name', 'T219 Winery B',
    'contact_name', 'Bob',
    'contact_email', 'bob@b.test',
    'contact_phone', '+61 400 000 002',
    'contact_address', '1 Cellar Lane',
    'external_id', 'crm-gp-1'));
  if not (r->>'replayed')::boolean or (r->'data'->>'id')::uuid <> p_api then
    raise exception 'T3: idempotent replay failed: %', r;
  end if;

  -- Missing Idempotency-Key.
  r := public.integration_api_create_grape_purchaser(k1, v1, null, jsonb_build_object('winery_name', 'X'));
  if (r->>'error') is distinct from 'idempotency_required' then raise exception 'T3: missing idempotency key not rejected: %', r; end if;

  -- winery_name required.
  r := public.integration_api_create_grape_purchaser(k1, v1, 'idem-gp-2', jsonb_build_object('contact_name', 'No Name'));
  if (r->>'error') is distinct from 'validation_failed' then raise exception 'T3: missing winery_name not rejected: %', r; end if;

  -- PATCH requires expected_updated_at.
  r := public.integration_api_update_grape_purchaser(k1, p_api, jsonb_build_object('contact_name', 'Robert'));
  if (r->>'error') is distinct from 'validation_failed' then raise exception 'T3: PATCH without expected_updated_at not rejected: %', r; end if;

  -- Stale token conflicts.
  r := public.integration_api_update_grape_purchaser(k1, p_api, jsonb_build_object(
    'expected_updated_at', '2000-01-01T00:00:00Z', 'contact_name', 'Robert'));
  if (r->>'error') is distinct from 'conflict' then raise exception 'T3: stale expected_updated_at not rejected: %', r; end if;

  -- Valid PATCH.
  select updated_at into v_updated from public.grape_purchasers where id = p_api;
  r := public.integration_api_update_grape_purchaser(k1, p_api, jsonb_build_object(
    'expected_updated_at', to_char(v_updated at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'contact_name', 'Robert'));
  if not (r->>'ok')::boolean then raise exception 'T3: valid PATCH failed: %', r; end if;
  if r->'data'->>'contact_name' <> 'Robert' then raise exception 'T3: PATCH did not apply'; end if;

  -- Read-only key cannot write.
  r := public.integration_api_create_grape_purchaser(k2, v1, 'idem-gp-3', jsonb_build_object('winery_name', 'Nope'));
  if (r->>'ok')::boolean or (r->>'error') is distinct from 'scope_not_granted' then raise exception 'T3: read-only key wrote a purchaser: %', r; end if;
  raise notice 'T3 passed';

  -- ---- T4. Allocation + purchaser_id ------------------------------------------
  -- purchaser_id resolves and snapshots the CURRENT purchaser details.
  r := public.integration_api_create_grape_allocation(k1, v1, 'idem-ga-p1', jsonb_build_object(
    'vintage', 2027,
    'allocation_type', 'external',
    'variety_name', 'Shiraz',
    'quantity_tonnes', 12,
    'price_per_tonne', 2400,
    'purchaser_id', p_api::text,
    'blocks', jsonb_build_array(jsonb_build_object('block_id', b1, 'quantity_tonnes', 7))));
  if not (r->>'ok')::boolean or (r->>'status')::int <> 201 then raise exception 'T4: create with purchaser_id failed: %', r; end if;
  a1 := (r->'data'->>'id')::uuid;
  if (r->'data'->>'purchaser_id')::uuid is distinct from p_api then raise exception 'T4: purchaser_id missing from representation'; end if;

  select * into v_row from public.grape_allocations where id = a1;
  if v_row.purchaser_id is distinct from p_api then raise exception 'T4: purchaser_id not stored'; end if;
  if v_row.purchaser_name <> 'T219 Winery B' or v_row.contact_name <> 'Robert'
     or v_row.contact_email <> 'bob@b.test' or v_row.contact_phone <> '+61 400 000 002'
     or v_row.contact_address <> '1 Cellar Lane' then
    raise exception 'T4: purchaser snapshot not copied onto the allocation';
  end if;

  -- purchaser_id + explicit snapshot fields is rejected.
  r := public.integration_api_create_grape_allocation(k1, v1, 'idem-ga-p2', jsonb_build_object(
    'vintage', 2027, 'allocation_type', 'external', 'variety_name', 'Shiraz',
    'quantity_tonnes', 3, 'purchaser_id', p_api::text, 'purchaser_name', 'Conflicting'));
  if (r->>'error') is distinct from 'validation_failed' then raise exception 'T4: purchaser_id + explicit fields not rejected: %', r; end if;

  -- Cross-vineyard purchaser is rejected.
  r := public.integration_api_create_grape_allocation(k1, v1, 'idem-ga-p3', jsonb_build_object(
    'vintage', 2027, 'allocation_type', 'external', 'variety_name', 'Shiraz',
    'quantity_tonnes', 3, 'purchaser_id', p_v2::text));
  if (r->>'error') is distinct from 'validation_failed' then raise exception 'T4: cross-vineyard purchaser not rejected: %', r; end if;

  -- own_use + purchaser_id is rejected.
  r := public.integration_api_create_grape_allocation(k1, v1, 'idem-ga-p4', jsonb_build_object(
    'vintage', 2027, 'allocation_type', 'own_use', 'variety_name', 'Shiraz',
    'quantity_tonnes', 2, 'purchaser_id', p_api::text));
  if (r->>'error') is distinct from 'validation_failed' then raise exception 'T4: own_use + purchaser_id not rejected: %', r; end if;
  raise notice 'T4 passed';

  -- ---- T5. Snapshot immutability + many allocations per purchaser -------------
  -- Edit the purchaser AFTER a1 was created.
  select updated_at into v_updated from public.grape_purchasers where id = p_api;
  r := public.integration_api_update_grape_purchaser(k1, p_api, jsonb_build_object(
    'expected_updated_at', to_char(v_updated at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'winery_name', 'T219 Winery B Renamed',
    'contact_email', 'new@b.test'));
  if not (r->>'ok')::boolean then raise exception 'T5: purchaser edit failed: %', r; end if;

  -- Old allocation snapshot must be UNCHANGED.
  select * into v_row from public.grape_allocations where id = a1;
  if v_row.purchaser_name <> 'T219 Winery B' or v_row.contact_email <> 'bob@b.test' then
    raise exception 'T5: purchaser edit rewrote an old allocation snapshot';
  end if;

  -- A NEW allocation for the SAME purchaser snapshots the NEW details.
  r := public.integration_api_create_grape_allocation(k1, v1, 'idem-ga-p5', jsonb_build_object(
    'vintage', 2028, 'allocation_type', 'external', 'variety_name', 'Chardonnay',
    'quantity_tonnes', 5, 'purchaser_id', p_api::text));
  if not (r->>'ok')::boolean then raise exception 'T5: second allocation failed: %', r; end if;
  a2 := (r->'data'->>'id')::uuid;
  select * into v_row from public.grape_allocations where id = a2;
  if v_row.purchaser_name <> 'T219 Winery B Renamed' or v_row.contact_email <> 'new@b.test' then
    raise exception 'T5: new allocation did not snapshot the updated purchaser';
  end if;

  -- One purchaser, multiple allocations — each its own contract.
  select count(*) into n from public.grape_allocations
  where purchaser_id = p_api and deleted_at is null;
  if n <> 2 then raise exception 'T5: expected 2 allocations for the purchaser, got %', n; end if;
  raise notice 'T5 passed';

  -- ---- T6. Compatibility --------------------------------------------------------
  -- Explicit snapshot fields, no purchaser_id — still fully supported.
  r := public.integration_api_create_grape_allocation(k1, v1, 'idem-ga-p6', jsonb_build_object(
    'vintage', 2027, 'allocation_type', 'external', 'variety_name', 'Merlot',
    'quantity_tonnes', 4, 'purchaser_name', 'T219 Legacy Winery', 'contact_email', 'legacy@l.test'));
  if not (r->>'ok')::boolean then raise exception 'T6: snapshot-only create failed: %', r; end if;
  a_plain := (r->'data'->>'id')::uuid;
  if r->'data'->'purchaser_id' is distinct from 'null'::jsonb then raise exception 'T6: purchaser_id should be null'; end if;

  -- ...and it still updates.
  select updated_at into v_updated from public.grape_allocations where id = a_plain;
  r := public.integration_api_update_grape_allocation(k1, a_plain, jsonb_build_object(
    'expected_updated_at', to_char(v_updated at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'quantity_tonnes', 4.5));
  if not (r->>'ok')::boolean then raise exception 'T6: snapshot-only update failed: %', r; end if;

  -- PATCH switching a purchaser-linked allocation to own_use clears the link.
  select updated_at into v_updated from public.grape_allocations where id = a2;
  r := public.integration_api_update_grape_allocation(k1, a2, jsonb_build_object(
    'expected_updated_at', to_char(v_updated at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'allocation_type', 'own_use', 'destination_name', 'Estate wine'));
  if not (r->>'ok')::boolean then raise exception 'T6: switch to own_use failed: %', r; end if;
  select * into v_row from public.grape_allocations where id = a2;
  if v_row.purchaser_id is not null or v_row.purchaser_name is not null then
    raise exception 'T6: own_use switch did not clear the purchaser link';
  end if;

  -- Unlink (purchaser_id -> null) keeps the historical snapshot fields.
  select updated_at into v_updated from public.grape_allocations where id = a1;
  r := public.integration_api_update_grape_allocation(k1, a1, jsonb_build_object(
    'expected_updated_at', to_char(v_updated at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'purchaser_id', null));
  if not (r->>'ok')::boolean then raise exception 'T6: unlink failed: %', r; end if;
  select * into v_row from public.grape_allocations where id = a1;
  if v_row.purchaser_id is not null then raise exception 'T6: unlink did not clear purchaser_id'; end if;
  if v_row.purchaser_name <> 'T219 Winery B' then raise exception 'T6: unlink wiped the historical snapshot'; end if;

  -- DB constraint: own_use can never carry purchaser_id even via raw SQL.
  v_caught := false;
  begin
    insert into public.grape_allocations
      (vineyard_id, vintage, allocation_type, variety_name, quantity_tonnes, purchaser_id)
    values (v1, 2027, 'own_use', 'Shiraz', 1, p_api);
  exception when check_violation then
    v_caught := true;
  end;
  if not v_caught then raise exception 'T6: own_use + purchaser_id constraint not enforced'; end if;

  -- DB trigger: cross-vineyard purchaser rejected even via raw SQL.
  v_caught := false;
  begin
    insert into public.grape_allocations
      (vineyard_id, vintage, allocation_type, variety_name, quantity_tonnes, purchaser_id)
    values (v1, 2027, 'external', 'Shiraz', 1, p_v2);
  exception when check_violation then
    v_caught := true;
  end;
  if not v_caught then raise exception 'T6: cross-vineyard purchaser trigger not enforced'; end if;
  raise notice 'T6 passed';

  -- ---- T7. Financial architecture unchanged -----------------------------------
  select count(*) into n from public.grape_allocation_financials
  where allocation_id = a1 and price_per_tonne = 2400;
  if n <> 1 then raise exception 'T7: price on a purchaser-linked allocation did not route to the companion'; end if;
  select price_per_tonne into v_row from public.grape_allocations where id = a1;
  if v_row.price_per_tonne is not null then raise exception 'T7: price rested on the base row'; end if;
  raise notice 'T7 passed';

  raise notice 'SQL 219 grape purchaser tests: ALL PASSED';
end$$;

rollback;

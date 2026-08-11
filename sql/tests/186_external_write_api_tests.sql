-- =====================================================================
-- 186_external_write_api_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/186_external_write_api.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- HTTP-level behaviour (envelopes, headers, rate limiting, malformed JSON,
-- missing bodies) is covered by scripts/test-vinetrack-api.sh against the
-- deployed gateway. This file proves the database contract.
--
-- Test map
--   T1  Objects: idempotency table + unique index; provenance columns on all
--       five write-enabled tables; per-table external-id unique indexes;
--       source_type check includes external_api; all 8 write RPCs exist;
--       write-scope catalogue descriptions activated (no 'Future:')
--   T2  Work task create: 201, provenance (origin=integration, client/key
--       ids, created_by NULL — no human impersonation), blocks written to
--       work_task_paddocks + legacy paddock columns, representation matches
--       the stored row, integration audit row (api.write.created), outbox
--       event work_task.created carrying origin + external_id, canonical
--       data (GET surface) sees the record
--   T3  Durable idempotency: same key + same payload replays the ORIGINAL
--       response (same id, replayed=true) and creates NO duplicate row
--   T4  Same key + DIFFERENT payload → idempotency_conflict
--   T5  Missing Idempotency-Key → idempotency_required
--   T6  Validation: unknown field, missing required field, cross-vineyard
--       block reference → validation_failed with field-level details and
--       NO row created
--   T7  Scope/grant separation: read-only-scoped integration cannot write
--       (scope_not_granted); ungranted vineyard → vineyard_not_granted on
--       create and resource_not_found on update (anti-enumeration)
--   T8  Work task PATCH: partial update semantics (omitted unchanged, null
--       clears), expected_updated_at REQUIRED, stale token → conflict,
--       finalised task → conflict, updated_by_integration_client_id set,
--       created attribution untouched
--   T9  External-id ownership: a VineTrack-created row cannot receive an
--       external_id from an integration (no mapping hijack); duplicate
--       external_id within one integration+table → conflict
--   T10 Fuel record create/update: cost fields are NOT accepted (unknown
--       field), cross-vineyard equipment refused, valid equipment linked
--       via machine_id
--   T11 Irrigation create: canonical calculation core derives vintage,
--       volume, allocations and status; source_type='external_api';
--       session blocks written; wrong valve/system pairing refused;
--       irrigation audit row written with NULL user (machine write)
--   T12 Growth stage create: supported E-L code stores catalogue label,
--       recorded_by_name = integration name; unsupported code refused;
--       growth_stage.recorded event carries provenance
--   T13 Yield create/update: canonical camelCase block_results preserved
--       (paddockId/paddockName/yieldPerHectare derived), duplicate block
--       refused, totals derived from blocks when omitted, PATCH replaces
--       blocks + re-derives totals under concurrency control
--   T14 Suspension/revocation: paused integration → integration_not_active;
--       revoked key → key_revoked (no write bypass)
--   T15 Request logging: POST/PATCH rows land in integration_api_requests
--       via the existing RPC (method check accepts POST/PATCH)
--   T16 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 186 external write API tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 186 is applied.
do $$
begin
  if to_regprocedure('public.integration_api_create_work_task(text,uuid,text,jsonb)') is null then
    raise exception 'SQL 186 not applied — run sql/186_external_write_api.sql first.';
  end if;
end$$;

do $$
declare
  u_owner uuid;
  v1 uuid := gen_random_uuid();          -- granted vineyard
  v2 uuid := gen_random_uuid();          -- NEVER granted
  b1 uuid := gen_random_uuid();          -- blocks in v1
  b2 uuid := gen_random_uuid();
  bx uuid := gen_random_uuid();          -- block in v2
  m1 uuid := gen_random_uuid();          -- machine in v1
  m2 uuid := gen_random_uuid();          -- machine in v2
  sys1 uuid := gen_random_uuid();        -- irrigation system v1
  va1 uuid := gen_random_uuid();         -- valve v1
  i1 uuid := gen_random_uuid();          -- integration (write scopes, grant v1)
  i2 uuid := gen_random_uuid();          -- integration (read scope only)
  i3 uuid := gen_random_uuid();          -- paused integration
  k1_id uuid := gen_random_uuid();
  k1 text := 'vt_test_' || repeat('a1', 24);   -- 48 hex chars
  k2 text := 'vt_test_' || repeat('b2', 24);
  k3 text := 'vt_test_' || repeat('c3', 24);
  k4 text := 'vt_test_' || repeat('d4', 24);   -- revoked key on i1
  r jsonb;
  r2 jsonb;
  n integer;
  v_id uuid;
  v_id2 uuid;
  v_updated timestamptz;
  v_row record;
  s text;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't186-owner@test.local', 'x', now(), now(), now());
  select id into u_owner from auth.users where email = 't186-owner@test.local';
  insert into public.profiles (id, email) values (u_owner, 't186-owner@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values (v1, 'T186 Granted Vineyard'), (v2, 'T186 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values (v1, u_owner, 'owner'), (v2, u_owner, 'owner');
  insert into public.paddocks (id, vineyard_id, name) values
    (b1, v1, 'T186 Block One'), (b2, v1, 'T186 Block Two'), (bx, v2, 'T186 Foreign Block');
  insert into public.vineyard_machines (id, vineyard_id, name) values
    (m1, v1, 'T186 Tractor'), (m2, v2, 'T186 Foreign Tractor');

  insert into public.irrigation_systems (id, vineyard_id, name) values (sys1, v1, 'T186 System');
  insert into public.irrigation_valves (id, vineyard_id, irrigation_system_id, name)
  values (va1, v1, sys1, 'T186 Valve 1');
  insert into public.irrigation_valve_blocks (vineyard_id, valve_id, block_id, allocation_method, allocation_percentage)
  values (v1, va1, b1, 'manual_percentage', 100);

  -- Integrations + keys (hash-only storage convention, sql/172).
  insert into public.integration_clients (id, owner_user_id, name, integration_type, status, created_by)
  values (i1, u_owner, 'T186 Writer Integration', 'custom_api', 'active', u_owner),
         (i2, u_owner, 'T186 Reader Integration', 'custom_api', 'active', u_owner);
  insert into public.integration_clients (id, owner_user_id, name, integration_type, status, created_by, paused_at)
  values (i3, u_owner, 'T186 Paused Integration', 'custom_api', 'paused', u_owner, now());

  insert into public.integration_api_keys (id, integration_client_id, environment, key_prefix, key_hash, created_by)
  values (k1_id, i1, 'test', left(k1, 16), public._integration_hash_secret(k1), u_owner);
  insert into public.integration_api_keys (integration_client_id, environment, key_prefix, key_hash, created_by)
  values (i2, 'test', left(k2, 16), public._integration_hash_secret(k2), u_owner),
         (i3, 'test', left(k3, 16), public._integration_hash_secret(k3), u_owner);
  insert into public.integration_api_keys (integration_client_id, environment, key_prefix, key_hash, created_by, revoked_at)
  values (i1, 'test', left(k4, 16), public._integration_hash_secret(k4), u_owner, now());

  insert into public.integration_client_vineyards (integration_client_id, vineyard_id, granted_by)
  values (i1, v1, u_owner), (i2, v1, u_owner), (i3, v1, u_owner);

  insert into public.integration_client_scopes (integration_client_id, scope, granted_by)
  select i1, s2, u_owner from unnest(array[
    'work_tasks:write', 'fuel:write', 'irrigation:write', 'growth_stages:write', 'yield:write']) s2;
  insert into public.integration_client_scopes (integration_client_id, scope, granted_by)
  values (i2, 'work_tasks:read', u_owner),
         (i3, 'work_tasks:write', u_owner);

  -- ---- T1. Objects ---------------------------------------------------------
  if to_regclass('public.integration_idempotency_keys') is null then
    raise exception 'T1: idempotency table missing';
  end if;
  if to_regclass('public.uq_integration_idempotency') is null then
    raise exception 'T1: idempotency unique index missing';
  end if;
  select count(*) into n from information_schema.columns
  where table_schema = 'public'
    and table_name in ('work_tasks', 'tractor_fuel_logs', 'irrigation_sessions',
                       'growth_stage_records', 'historical_yield_records')
    and column_name in ('origin', 'integration_client_id', 'integration_api_key_id',
                        'updated_by_integration_client_id', 'external_id');
  if n <> 25 then raise exception 'T1: expected 25 provenance columns (5 tables x 5), found %', n; end if;
  select count(*) into n from pg_indexes
  where schemaname = 'public' and indexname like 'uq\_%\_integration\_external\_id';
  if n <> 5 then raise exception 'T1: expected 5 external-id unique indexes, found %', n; end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.irrigation_sessions'::regclass
      and pg_get_constraintdef(oid) ilike '%external_api%') then
    raise exception 'T1: irrigation source_type check missing external_api';
  end if;
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname in (
    'integration_api_create_work_task', 'integration_api_update_work_task',
    'integration_api_create_fuel_record', 'integration_api_update_fuel_record',
    'integration_api_create_irrigation_record', 'integration_api_create_growth_stage',
    'integration_api_create_yield_record', 'integration_api_update_yield_record');
  if n <> 8 then raise exception 'T1: expected 8 write RPCs, found %', n; end if;
  select count(*) into n from public.integration_scope_catalog
  where scope in ('work_tasks:write', 'fuel:write', 'irrigation:write', 'growth_stages:write', 'yield:write')
    and description not ilike 'future:%';
  if n <> 5 then raise exception 'T1: expected 5 activated write-scope descriptions, found %', n; end if;
  raise notice 'T1 passed';

  -- ---- T2. Work task create -------------------------------------------------
  r := public.integration_api_create_work_task(k1, v1, 'idem-wt-1', jsonb_build_object(
    'task_type', 'Slashing',
    'date', '2027-01-15T09:00:00Z',
    'description', 'Mid-row slashing',
    'status', 'planned',
    'notes', 'Stage 8 test task',
    'block_ids', jsonb_build_array(b1, b2),
    'external_id', 'farmos-task-100'));
  if not (r->>'ok')::boolean or (r->>'status')::int <> 201 then
    raise exception 'T2: create failed: %', r;
  end if;
  v_id := (r->'data'->>'id')::uuid;

  select * into v_row from public.work_tasks where id = v_id;
  if v_row.origin <> 'integration' or v_row.integration_client_id <> i1
     or v_row.integration_api_key_id <> k1_id or v_row.external_id <> 'farmos-task-100' then
    raise exception 'T2: provenance columns wrong';
  end if;
  if v_row.created_by is not null then
    raise exception 'T2: machine write must not impersonate a human (created_by must be NULL)';
  end if;
  if v_row.paddock_id <> b1 or v_row.paddock_name <> 'T186 Block One' then
    raise exception 'T2: legacy block columns not set from first block';
  end if;
  select count(*) into n from public.work_task_paddocks
  where work_task_id = v_id and deleted_at is null;
  if n <> 2 then raise exception 'T2: expected 2 work_task_paddocks rows, found %', n; end if;
  if jsonb_array_length(r->'data'->'blocks') <> 2
     or r->'data'->>'external_id' <> 'farmos-task-100'
     or r->'data'->>'origin' <> 'integration' then
    raise exception 'T2: representation incomplete: %', r->'data';
  end if;
  if not exists (
    select 1 from public.integration_audit_log
    where integration_client_id = i1 and action = 'api.write.created'
      and vineyard_id = v1 and (metadata->>'resource_id')::uuid = v_id) then
    raise exception 'T2: integration audit row missing';
  end if;
  select payload into r2 from public.integration_events
  where event_type = 'work_task.created' and resource_id = v_id;
  if r2 is null then raise exception 'T2: work_task.created outbox event missing'; end if;
  if r2->>'origin' <> 'integration' or r2->>'external_id' <> 'farmos-task-100' then
    raise exception 'T2: event payload missing provenance: %', r2;
  end if;
  -- Canonical data (the GET surface reads this table directly) sees it.
  if not exists (select 1 from public.work_tasks where id = v_id and vineyard_id = v1 and deleted_at is null) then
    raise exception 'T2: canonical read surface cannot see the record';
  end if;
  raise notice 'T2 passed';

  -- ---- T3. Idempotent replay -------------------------------------------------
  r2 := public.integration_api_create_work_task(k1, v1, 'idem-wt-1', jsonb_build_object(
    'task_type', 'Slashing',
    'date', '2027-01-15T09:00:00Z',
    'description', 'Mid-row slashing',
    'status', 'planned',
    'notes', 'Stage 8 test task',
    'block_ids', jsonb_build_array(b1, b2),
    'external_id', 'farmos-task-100'));
  if not (r2->>'ok')::boolean or not (r2->>'replayed')::boolean then
    raise exception 'T3: replay not detected: %', r2;
  end if;
  if (r2->'data'->>'id')::uuid <> v_id then
    raise exception 'T3: replay returned a different record';
  end if;
  select count(*) into n from public.work_tasks
  where vineyard_id = v1 and external_id = 'farmos-task-100' and deleted_at is null;
  if n <> 1 then raise exception 'T3: duplicate canonical record created (%)', n; end if;
  raise notice 'T3 passed';

  -- ---- T4. Same key, different payload → idempotency_conflict -----------------
  r2 := public.integration_api_create_work_task(k1, v1, 'idem-wt-1', jsonb_build_object(
    'task_type', 'Different task', 'date', '2027-01-16T09:00:00Z'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'idempotency_conflict' then
    raise exception 'T4: expected idempotency_conflict, got %', r2;
  end if;
  raise notice 'T4 passed';

  -- ---- T5. Missing Idempotency-Key -------------------------------------------
  r2 := public.integration_api_create_work_task(k1, v1, null, jsonb_build_object(
    'task_type', 'X', 'date', '2027-01-16T09:00:00Z'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'idempotency_required' then
    raise exception 'T5: expected idempotency_required, got %', r2;
  end if;
  raise notice 'T5 passed';

  -- ---- T6. Validation errors ---------------------------------------------------
  -- Unknown field.
  r2 := public.integration_api_create_work_task(k1, v1, 'idem-wt-bad-1', jsonb_build_object(
    'task_type', 'X', 'date', '2027-01-16T09:00:00Z', 'labour_cost', 500));
  if (r2->>'ok')::boolean or r2->>'error' <> 'validation_failed' then
    raise exception 'T6: unknown field accepted: %', r2;
  end if;
  if not exists (select 1 from jsonb_array_elements(r2->'details') d
                 where d->>'field' = 'labour_cost' and d->>'issue' = 'unknown field') then
    raise exception 'T6: field-level detail missing: %', r2->'details';
  end if;
  -- Missing required field.
  r2 := public.integration_api_create_work_task(k1, v1, 'idem-wt-bad-2',
    jsonb_build_object('date', '2027-01-16T09:00:00Z'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'validation_failed' then
    raise exception 'T6: missing task_type accepted';
  end if;
  -- Cross-vineyard block substitution.
  r2 := public.integration_api_create_work_task(k1, v1, 'idem-wt-bad-3', jsonb_build_object(
    'task_type', 'X', 'date', '2027-01-16T09:00:00Z', 'block_ids', jsonb_build_array(bx)));
  if (r2->>'ok')::boolean or r2->>'error' <> 'validation_failed' then
    raise exception 'T6: cross-vineyard block accepted';
  end if;
  select count(*) into n from public.work_tasks where vineyard_id = v1 and deleted_at is null;
  if n <> 1 then raise exception 'T6: failed validations must create no rows (found %)', n; end if;
  raise notice 'T6 passed';

  -- ---- T7. Scope / grant separation --------------------------------------------
  r2 := public.integration_api_create_work_task(k2, v1, 'idem-wt-ro-1',
    jsonb_build_object('task_type', 'X', 'date', '2027-01-16T09:00:00Z'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'scope_not_granted' then
    raise exception 'T7: read-only scope permitted a write: %', r2;
  end if;
  r2 := public.integration_api_create_work_task(k1, v2, 'idem-wt-v2-1',
    jsonb_build_object('task_type', 'X', 'date', '2027-01-16T09:00:00Z'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'vineyard_not_granted' then
    raise exception 'T7: ungranted vineyard write not refused: %', r2;
  end if;
  -- Update of a resource in an ungranted vineyard is indistinguishable from
  -- a missing resource.
  insert into public.work_tasks (id, vineyard_id, paddock_name, task_type, notes)
  values (gen_random_uuid(), v2, '', 'Foreign task', '') returning id into v_id2;
  r2 := public.integration_api_update_work_task(k1, v_id2, jsonb_build_object(
    'expected_updated_at', now()::text, 'notes', 'hijack'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'resource_not_found' then
    raise exception 'T7: cross-vineyard update leaked information: %', r2;
  end if;
  raise notice 'T7 passed';

  -- ---- T8. Work task PATCH -------------------------------------------------------
  select updated_at into v_updated from public.work_tasks where id = v_id;
  -- Stale token refused.
  r2 := public.integration_api_update_work_task(k1, v_id, jsonb_build_object(
    'expected_updated_at', (v_updated - interval '1 second')::text, 'status', 'in_progress'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'conflict' then
    raise exception 'T8: stale expected_updated_at not refused: %', r2;
  end if;
  -- Missing token refused.
  r2 := public.integration_api_update_work_task(k1, v_id, jsonb_build_object('status', 'in_progress'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'validation_failed' then
    raise exception 'T8: missing expected_updated_at not refused';
  end if;
  -- Valid partial update: status changed, description cleared, rest unchanged.
  r2 := public.integration_api_update_work_task(k1, v_id, jsonb_build_object(
    'expected_updated_at', v_updated::text,
    'status', 'in_progress',
    'description', null));
  if not (r2->>'ok')::boolean or (r2->>'status')::int <> 200 then
    raise exception 'T8: valid PATCH failed: %', r2;
  end if;
  select * into v_row from public.work_tasks where id = v_id;
  if v_row.status <> 'in_progress' or v_row.description is not null
     or v_row.task_type <> 'Slashing' or v_row.notes <> 'Stage 8 test task' then
    raise exception 'T8: partial-update semantics broken';
  end if;
  if v_row.updated_by_integration_client_id <> i1 or v_row.updated_by is not null then
    raise exception 'T8: external-modifier provenance not recorded';
  end if;
  if v_row.origin <> 'integration' or v_row.integration_client_id <> i1 then
    raise exception 'T8: creator provenance must never change on update';
  end if;
  if not exists (select 1 from public.integration_audit_log
    where integration_client_id = i1 and action = 'api.write.updated'
      and (metadata->>'resource_id')::uuid = v_id) then
    raise exception 'T8: update audit row missing';
  end if;
  -- Finalised task refuses external edits.
  update public.work_tasks set is_finalized = true, finalized_at = now() where id = v_id;
  select updated_at into v_updated from public.work_tasks where id = v_id;
  r2 := public.integration_api_update_work_task(k1, v_id, jsonb_build_object(
    'expected_updated_at', v_updated::text, 'notes', 'too late'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'conflict' then
    raise exception 'T8: finalised task accepted an external edit';
  end if;
  update public.work_tasks set is_finalized = false, finalized_at = null where id = v_id;
  raise notice 'T8 passed';

  -- ---- T9. External-id ownership ---------------------------------------------------
  -- A VineTrack-created row cannot receive an external mapping from an
  -- integration.
  insert into public.work_tasks (id, vineyard_id, paddock_name, task_type, notes, created_by)
  values (gen_random_uuid(), v1, '', 'Native task', '', u_owner) returning id into v_id2;
  select updated_at into v_updated from public.work_tasks where id = v_id2;
  r2 := public.integration_api_update_work_task(k1, v_id2, jsonb_build_object(
    'expected_updated_at', v_updated::text, 'external_id', 'stolen-mapping'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'validation_failed' then
    raise exception 'T9: external mapping hijack not refused: %', r2;
  end if;
  -- Duplicate external_id within one integration + table → conflict.
  r2 := public.integration_api_create_work_task(k1, v1, 'idem-wt-dup-1', jsonb_build_object(
    'task_type', 'Dup', 'date', '2027-01-17T09:00:00Z', 'external_id', 'farmos-task-100'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'conflict' then
    raise exception 'T9: duplicate external_id accepted: %', r2;
  end if;
  raise notice 'T9 passed';

  -- ---- T10. Fuel records --------------------------------------------------------------
  -- Cost fields are NOT part of the write surface.
  r2 := public.integration_api_create_fuel_record(k1, v1, 'idem-fuel-bad-1', jsonb_build_object(
    'date', '2027-01-15T07:30:00Z', 'volume_l', 55.5, 'cost_per_litre', 1.85));
  if (r2->>'ok')::boolean or r2->>'error' <> 'validation_failed' then
    raise exception 'T10: cost field accepted on fuel write';
  end if;
  -- Cross-vineyard equipment refused.
  r2 := public.integration_api_create_fuel_record(k1, v1, 'idem-fuel-bad-2', jsonb_build_object(
    'date', '2027-01-15T07:30:00Z', 'volume_l', 55.5, 'equipment_id', m2));
  if (r2->>'ok')::boolean or r2->>'error' <> 'validation_failed' then
    raise exception 'T10: cross-vineyard equipment accepted';
  end if;
  -- Valid create.
  r := public.integration_api_create_fuel_record(k1, v1, 'idem-fuel-1', jsonb_build_object(
    'date', '2027-01-15T07:30:00Z', 'volume_l', 55.5, 'equipment_id', m1,
    'engine_hours', 1204.5, 'filled_to_full', true, 'notes', 'Stage 8 fuel test',
    'external_id', 'fms-fuel-1'));
  if not (r->>'ok')::boolean or (r->>'status')::int <> 201 then
    raise exception 'T10: fuel create failed: %', r;
  end if;
  v_id := (r->'data'->>'id')::uuid;
  select * into v_row from public.tractor_fuel_logs where id = v_id;
  if v_row.machine_id <> m1 or v_row.litres_added <> 55.5 or v_row.origin <> 'integration'
     or v_row.cost_per_litre is not null or v_row.created_by is not null then
    raise exception 'T10: fuel row wrong';
  end if;
  if r->'data'->>'equipment_id' <> m1::text or r->'data'->>'equipment_name' <> 'T186 Tractor' then
    raise exception 'T10: fuel representation equipment wrong';
  end if;
  -- PATCH: volume + clear equipment.
  select updated_at into v_updated from public.tractor_fuel_logs where id = v_id;
  r2 := public.integration_api_update_fuel_record(k1, v_id, jsonb_build_object(
    'expected_updated_at', v_updated::text, 'volume_l', 60.0, 'equipment_id', null));
  if not (r2->>'ok')::boolean then raise exception 'T10: fuel PATCH failed: %', r2; end if;
  select * into v_row from public.tractor_fuel_logs where id = v_id;
  if v_row.litres_added <> 60.0 or v_row.machine_id is not null
     or v_row.updated_by_integration_client_id <> i1 then
    raise exception 'T10: fuel PATCH semantics wrong';
  end if;
  if not exists (select 1 from public.integration_events
                 where event_type = 'fuel_log.created' and resource_id = v_id) then
    raise exception 'T10: fuel_log.created event missing';
  end if;
  raise notice 'T10 passed';

  -- ---- T11. Irrigation records ------------------------------------------------------
  -- Wrong valve/system pairing refused.
  r2 := public.integration_api_create_irrigation_record(k1, v1, 'idem-irr-bad-1', jsonb_build_object(
    'system_id', gen_random_uuid(), 'valve_id', va1, 'date', '2027-01-20',
    'duration_minutes', 120, 'calculation_method', 'total_volume', 'volume_l', 5000));
  if (r2->>'ok')::boolean or r2->>'error' <> 'validation_failed' then
    raise exception 'T11: wrong system pairing accepted';
  end if;
  -- Valid create (total_volume — VineTrack core derives everything else).
  r := public.integration_api_create_irrigation_record(k1, v1, 'idem-irr-1', jsonb_build_object(
    'system_id', sys1, 'valve_id', va1, 'date', '2027-01-20',
    'duration_minutes', 120, 'calculation_method', 'total_volume', 'volume_l', 5000,
    'notes', 'Stage 8 irrigation test', 'external_id', 'ctrl-run-77'));
  if not (r->>'ok')::boolean or (r->>'status')::int <> 201 then
    raise exception 'T11: irrigation create failed: %', r;
  end if;
  v_id := (r->'data'->>'id')::uuid;
  select * into v_row from public.irrigation_sessions where id = v_id;
  if v_row.source_type <> 'external_api' or v_row.origin <> 'integration'
     or v_row.status <> 'completed' or v_row.total_volume_litres <> 5000
     or v_row.vintage_year is null or v_row.configuration_snapshot is null
     or v_row.created_by is not null then
    raise exception 'T11: irrigation session wrong';
  end if;
  select count(*) into n from public.irrigation_session_blocks where session_id = v_id;
  if n <> 1 then raise exception 'T11: expected 1 derived session block, found %', n; end if;
  select allocated_volume_litres into v_row from public.irrigation_session_blocks where session_id = v_id;
  if v_row.allocated_volume_litres <> 5000 then
    raise exception 'T11: allocation not derived by the canonical core';
  end if;
  if not exists (select 1 from public.irrigation_audit
                 where entity_id = v_id and action = 'create' and user_id is null) then
    raise exception 'T11: irrigation audit row (machine write, NULL user) missing';
  end if;
  if not exists (select 1 from public.integration_events
                 where event_type = 'irrigation_record.created' and resource_id = v_id) then
    raise exception 'T11: irrigation_record.created event missing';
  end if;
  raise notice 'T11 passed';

  -- ---- T12. Growth stages -----------------------------------------------------------
  r2 := public.integration_api_create_growth_stage(k1, v1, 'idem-gs-bad-1', jsonb_build_object(
    'stage_code', 'EL99'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'validation_failed' then
    raise exception 'T12: unsupported E-L code accepted';
  end if;
  r := public.integration_api_create_growth_stage(k1, v1, 'idem-gs-1', jsonb_build_object(
    'stage_code', 'el4', 'observed_at', '2026-09-20T08:00:00Z', 'block_id', b1,
    'variety', 'Shiraz', 'notes', 'Stage 8 growth test', 'external_id', 'sensor-obs-9'));
  if not (r->>'ok')::boolean or (r->>'status')::int <> 201 then
    raise exception 'T12: growth stage create failed: %', r;
  end if;
  v_id := (r->'data'->>'id')::uuid;
  select * into v_row from public.growth_stage_records where id = v_id;
  if v_row.stage_code <> 'EL4' or v_row.stage_label <> 'Budburst; leaf tips visible'
     or v_row.recorded_by_name <> 'T186 Writer Integration'
     or v_row.origin <> 'integration' or v_row.created_by is not null then
    raise exception 'T12: growth stage row wrong';
  end if;
  select payload into r2 from public.integration_events
  where event_type = 'growth_stage.recorded' and resource_id = v_id;
  if r2 is null or r2->>'origin' <> 'integration' or r2->>'external_id' <> 'sensor-obs-9' then
    raise exception 'T12: growth_stage.recorded provenance missing: %', r2;
  end if;
  raise notice 'T12 passed';

  -- ---- T13. Yield records -------------------------------------------------------------
  -- Duplicate block refused.
  r2 := public.integration_api_create_yield_record(k1, v1, 'idem-yr-bad-1', jsonb_build_object(
    'vintage_year', 2027,
    'blocks', jsonb_build_array(
      jsonb_build_object('block_id', b1, 'area_ha', 2.0, 'yield_tonnes', 10),
      jsonb_build_object('block_id', b1, 'area_ha', 1.0, 'yield_tonnes', 5))));
  if (r2->>'ok')::boolean or r2->>'error' <> 'validation_failed' then
    raise exception 'T13: duplicate block accepted';
  end if;
  -- Valid create: totals derived from blocks; camelCase canonical shape.
  r := public.integration_api_create_yield_record(k1, v1, 'idem-yr-1', jsonb_build_object(
    'vintage_year', 2027, 'season', '2026/27',
    'notes', 'Stage 8 yield test', 'external_id', 'erp-yield-2027',
    'blocks', jsonb_build_array(
      jsonb_build_object('block_id', b1, 'area_ha', 2.0, 'yield_tonnes', 15.0, 'vine_count', 4400),
      jsonb_build_object('block_id', b2, 'area_ha', 1.5, 'yield_tonnes', 9.0))));
  if not (r->>'ok')::boolean or (r->>'status')::int <> 201 then
    raise exception 'T13: yield create failed: %', r;
  end if;
  v_id := (r->'data'->>'id')::uuid;
  select * into v_row from public.historical_yield_records where id = v_id;
  if v_row.year <> 2027 or v_row.total_yield_tonnes <> 24.0 or v_row.total_area_hectares <> 3.5 then
    raise exception 'T13: totals not derived from blocks (% t, % ha)', v_row.total_yield_tonnes, v_row.total_area_hectares;
  end if;
  -- Canonical camelCase JSONB (iOS Codable keys) with derived yieldPerHectare.
  r2 := v_row.block_results->0;
  if (r2->>'paddockId')::uuid <> b1 or r2->>'paddockName' <> 'T186 Block One'
     or (r2->>'yieldPerHectare')::numeric <> 7.5
     or (r2->>'totalVines')::int <> 4400 or (r2->>'id') is null then
    raise exception 'T13: canonical block_results shape broken: %', r2;
  end if;
  -- PATCH: replace blocks; totals re-derived; concurrency enforced.
  select updated_at into v_updated from public.historical_yield_records where id = v_id;
  r2 := public.integration_api_update_yield_record(k1, v_id, jsonb_build_object(
    'expected_updated_at', v_updated::text,
    'blocks', jsonb_build_array(
      jsonb_build_object('block_id', b1, 'area_ha', 2.0, 'yield_tonnes', 16.0))));
  if not (r2->>'ok')::boolean then raise exception 'T13: yield PATCH failed: %', r2; end if;
  select * into v_row from public.historical_yield_records where id = v_id;
  if v_row.total_yield_tonnes <> 16.0 or v_row.total_area_hectares <> 2.0
     or jsonb_array_length(v_row.block_results) <> 1 then
    raise exception 'T13: PATCH block replacement / total re-derivation wrong';
  end if;
  if not exists (select 1 from public.integration_events
                 where event_type = 'yield_record.updated' and resource_id = v_id) then
    raise exception 'T13: yield_record.updated event missing';
  end if;
  raise notice 'T13 passed';

  -- ---- T14. Suspension / revocation -----------------------------------------------------
  r2 := public.integration_api_create_work_task(k3, v1, 'idem-paused-1',
    jsonb_build_object('task_type', 'X', 'date', '2027-01-16T09:00:00Z'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'integration_not_active' then
    raise exception 'T14: paused integration wrote: %', r2;
  end if;
  r2 := public.integration_api_create_work_task(k4, v1, 'idem-revoked-1',
    jsonb_build_object('task_type', 'X', 'date', '2027-01-16T09:00:00Z'));
  if (r2->>'ok')::boolean or r2->>'error' <> 'key_revoked' then
    raise exception 'T14: revoked key wrote: %', r2;
  end if;
  raise notice 'T14 passed';

  -- ---- T15. Request logging accepts POST/PATCH ------------------------------------------
  s := 'req_' || replace(gen_random_uuid()::text, '-', '');
  perform public.integration_log_api_request(
    s, i1, k1_id, v1, 'POST', '/v1/work-tasks', 201, 42, null);
  if not exists (select 1 from public.integration_api_requests
                 where request_id = s and method = 'POST' and path = '/v1/work-tasks'
                   and status_code = 201) then
    raise exception 'T15: POST request log row missing';
  end if;
  s := 'req_' || replace(gen_random_uuid()::text, '-', '');
  perform public.integration_log_api_request(
    s, i1, k1_id, v1, 'PATCH', '/v1/work-tasks/{work_task_id}', 409, 18, 'conflict');
  if not exists (select 1 from public.integration_api_requests
                 where request_id = s and method = 'PATCH' and error_code = 'conflict') then
    raise exception 'T15: PATCH request log row missing';
  end if;
  raise notice 'T15 passed';

  raise notice 'SQL 186 external write API tests: ALL PASSED';
end$$;

-- ---- T16. Discard every fixture -------------------------------------------
rollback;

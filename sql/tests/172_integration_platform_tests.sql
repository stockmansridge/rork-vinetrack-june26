-- =====================================================================
-- 172_integration_platform_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/172_integration_platform_foundation.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects exist: 11 tables, 28 catalogue scopes, 25 catalogue
--       events, 14 management RPCs + validation function
--   T2  Direct table access is denied to authenticated clients
--       (integration_clients / api_keys / audit_log unreadable; grants
--       cannot be forged by direct INSERT; catalogues stay readable)
--   T3  Owner A creates an integration; audit 'integration.created'
--   T4  Cross-account isolation: Owner B cannot list, update, pause,
--       grant to, or read audit of A's integration (same error as
--       "not found" — no ID probing)
--   T5  Vineyard grants: A grants own vineyard VA; duplicate refused;
--       B's vineyard refused; granting VA does NOT grant A's other
--       vineyard VA2
--   T6  Manager: cannot create integrations, issue credentials or
--       grant vineyards/scopes; CAN view the integration + audit via
--       membership of granted vineyard VA; cannot list key metadata
--   T7  Supervisor and Operator have no integration access at all
--   T8  Scopes: catalogue-checked grant, duplicate refused, unknown
--       scope refused, trips:read does NOT imply costs:read, revoke ok
--   T9  API keys: one-time secret (vt_live_/vt_test_), only SHA-256
--       hash + prefix stored, secret in no column and no audit row,
--       metadata list exposes no hash/secret, revocation keeps history
--   T10 integration_validate_api_request: full chain passes; each of
--       invalid key / revoked key / expired key / paused integration /
--       missing scope / missing vineyard grant fails INDEPENDENTLY —
--       including a vineyard the human owner controls but never granted
--   T11 Lifecycle: pause keeps config; reactivate; revoke is terminal
--       (no reactivation, no new grants); all rows retained
--   T12 integration_audit_log is append-only (UPDATE/DELETE blocked)
--   T13 Webhook schema: HTTPS-only endpoints, catalogue-constrained
--       events, duplicate subscriptions refused — and NO dispatching
--   T14 Idempotency uniqueness per (integration client, key)
--   T15 authenticated role cannot execute the validation function
--   T16 Existing safety: core vineyard_members RLS path still works
--
-- Expected final output:
--   NOTICE: SQL 172 integration platform tests: ALL PASSED
-- =====================================================================

begin;

do $$
declare
  u_owner_a uuid;
  u_owner_b uuid;
  u_mgr     uuid;
  u_sup     uuid;
  u_op      uuid;

  v_va  uuid := gen_random_uuid();  -- vineyard A (owner A; mgr/sup/op are members)
  v_va2 uuid := gen_random_uuid();  -- second vineyard owned by A (never granted)
  v_vb  uuid := gen_random_uuid();  -- vineyard B (owner B)

  c_a uuid;                          -- Owner A's integration client
  k1 uuid;                           -- live key id
  k1_secret text;                    -- one-time plaintext (test-local only)
  k2_secret text;

  j jsonb;
  v_failed boolean;
  n integer;
  v_ep uuid := gen_random_uuid();
begin
  -- =====================================================================
  -- Fixtures
  -- =====================================================================
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array[
    't172-owner-a@test.local', 't172-owner-b@test.local', 't172-mgr@test.local',
    't172-sup@test.local',     't172-op@test.local'
  ]) e;

  select id into u_owner_a from auth.users where email = 't172-owner-a@test.local';
  select id into u_owner_b from auth.users where email = 't172-owner-b@test.local';
  select id into u_mgr     from auth.users where email = 't172-mgr@test.local';
  select id into u_sup     from auth.users where email = 't172-sup@test.local';
  select id into u_op      from auth.users where email = 't172-op@test.local';

  insert into public.profiles (id, email) values
    (u_owner_a, 't172-owner-a@test.local'),
    (u_owner_b, 't172-owner-b@test.local'),
    (u_mgr,     't172-mgr@test.local'),
    (u_sup,     't172-sup@test.local'),
    (u_op,      't172-op@test.local');

  insert into public.vineyards (id, name, owner_id) values
    (v_va,  'T172 Vineyard A',  u_owner_a),
    (v_va2, 'T172 Vineyard A2', u_owner_a),
    (v_vb,  'T172 Vineyard B',  u_owner_b);

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_va,  u_owner_a, 'owner'),
    (v_va,  u_mgr,     'manager'),
    (v_va,  u_sup,     'supervisor'),
    (v_va,  u_op,      'operator'),
    (v_va2, u_owner_a, 'owner'),
    (v_vb,  u_owner_b, 'owner');

  -- ---------------------------------------------------------------
  -- T1: objects exist
  -- ---------------------------------------------------------------
  if to_regclass('public.integration_scope_catalog') is null
     or to_regclass('public.integration_webhook_event_catalog') is null
     or to_regclass('public.integration_clients') is null
     or to_regclass('public.integration_api_keys') is null
     or to_regclass('public.integration_client_vineyards') is null
     or to_regclass('public.integration_client_scopes') is null
     or to_regclass('public.integration_audit_log') is null
     or to_regclass('public.integration_api_requests') is null
     or to_regclass('public.webhook_endpoints') is null
     or to_regclass('public.webhook_subscriptions') is null
     or to_regclass('public.integration_idempotency_keys') is null then
    raise exception 'T1: a Stage-2 table is missing';
  end if;

  select count(*) into n from public.integration_scope_catalog;
  if n < 28 then raise exception 'T1: expected >= 28 catalogue scopes, got %', n; end if;
  select count(*) into n from public.integration_scope_catalog where is_sensitive;
  if n < 3 then raise exception 'T1: expected sensitive scopes (labour/costs/team), got %', n; end if;
  select count(*) into n from public.integration_webhook_event_catalog;
  if n < 25 then raise exception 'T1: expected >= 25 catalogue events, got %', n; end if;

  if to_regprocedure('public.integration_list_clients()') is null
     or to_regprocedure('public.integration_create_client(text, text, text)') is null
     or to_regprocedure('public.integration_update_client(uuid, text, text)') is null
     or to_regprocedure('public.integration_set_status(uuid, text)') is null
     or to_regprocedure('public.integration_list_vineyard_grants(uuid)') is null
     or to_regprocedure('public.integration_grant_vineyard(uuid, uuid)') is null
     or to_regprocedure('public.integration_revoke_vineyard(uuid, uuid)') is null
     or to_regprocedure('public.integration_list_scopes(uuid)') is null
     or to_regprocedure('public.integration_grant_scope(uuid, text)') is null
     or to_regprocedure('public.integration_revoke_scope(uuid, text)') is null
     or to_regprocedure('public.integration_list_api_keys(uuid)') is null
     or to_regprocedure('public.integration_create_api_key(uuid, text, text, timestamptz)') is null
     or to_regprocedure('public.integration_revoke_api_key(uuid, uuid)') is null
     or to_regprocedure('public.integration_audit_history(uuid, integer)') is null
     or to_regprocedure('public.integration_validate_api_request(text, text, uuid)') is null then
    raise exception 'T1: a Stage-2 function is missing';
  end if;
  raise notice 'T1 passed';

  -- ---------------------------------------------------------------
  -- T2: direct table access is locked down for authenticated clients
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  v_failed := false;
  begin
    perform 1 from public.integration_clients;
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T2: integration_clients readable directly'; end if;

  v_failed := false;
  begin
    perform 1 from public.integration_api_keys;
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T2: integration_api_keys readable directly'; end if;

  v_failed := false;
  begin
    perform 1 from public.integration_audit_log;
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T2: integration_audit_log readable directly'; end if;

  -- grants cannot be forged by direct insert
  v_failed := false;
  begin
    insert into public.integration_client_vineyards (integration_client_id, vineyard_id, granted_by)
    values (gen_random_uuid(), v_vb, u_owner_a);
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T2: vineyard grant forgeable by direct insert'; end if;

  -- catalogues stay readable (reference data)
  select count(*) into n from public.integration_scope_catalog;
  if n < 28 then raise exception 'T2: scope catalogue not readable, got %', n; end if;

  perform set_config('role', 'postgres', true);
  raise notice 'T2 passed';

  -- ---------------------------------------------------------------
  -- T3: Owner A creates an integration
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);

  j := public.integration_create_client('Packhouse Sync', 'custom_api', 'T172 test integration');
  c_a := (j->>'id')::uuid;
  if c_a is null or j->>'status' is distinct from 'active' then
    raise exception 'T3: create_client returned %', j;
  end if;

  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'integration.created' and actor_user_id = u_owner_a;
  if n <> 1 then raise exception 'T3: integration.created audit missing'; end if;

  j := public.integration_list_clients();
  if not exists (select 1 from jsonb_array_elements(j) e
                 where (e->>'id')::uuid = c_a and (e->>'can_manage')::boolean) then
    raise exception 'T3: owner list does not show manageable client';
  end if;

  -- invalid type rejected
  v_failed := false;
  begin
    perform public.integration_create_client('Bad', 'not_a_type', null);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%invalid_integration_type%' then raise; end if;
  end;
  if not v_failed then raise exception 'T3: invalid type accepted'; end if;
  raise notice 'T3 passed';

  -- ---------------------------------------------------------------
  -- T4: Owner B cannot see or manage A's integration
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_b::text, 'role', 'authenticated')::text, true);

  j := public.integration_list_clients();
  if exists (select 1 from jsonb_array_elements(j) e where (e->>'id')::uuid = c_a) then
    raise exception 'T4: B can list A''s integration';
  end if;

  v_failed := false;
  begin
    perform public.integration_update_client(c_a, 'Hijacked', null);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%integration_not_found%' then raise; end if;
  end;
  if not v_failed then raise exception 'T4: B updated A''s integration'; end if;

  v_failed := false;
  begin
    perform public.integration_set_status(c_a, 'pause');
  exception when others then
    v_failed := true;
    if sqlerrm not like '%integration_not_found%' then raise; end if;
  end;
  if not v_failed then raise exception 'T4: B paused A''s integration'; end if;

  v_failed := false;
  begin
    perform public.integration_grant_vineyard(c_a, v_vb);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%integration_not_found%' then raise; end if;
  end;
  if not v_failed then raise exception 'T4: B granted a vineyard to A''s integration'; end if;

  v_failed := false;
  begin
    perform public.integration_audit_history(c_a, 10);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%integration_not_found%' then raise; end if;
  end;
  if not v_failed then raise exception 'T4: B read A''s audit history'; end if;
  raise notice 'T4 passed';

  -- ---------------------------------------------------------------
  -- T5: vineyard grants
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);

  j := public.integration_grant_vineyard(c_a, v_va);
  if (j->>'ok')::boolean is not true then raise exception 'T5: grant VA failed %', j; end if;

  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'vineyard_access.granted' and vineyard_id = v_va;
  if n <> 1 then raise exception 'T5: vineyard_access.granted audit missing'; end if;

  v_failed := false;
  begin
    perform public.integration_grant_vineyard(c_a, v_va);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%vineyard_already_granted%' then raise; end if;
  end;
  if not v_failed then raise exception 'T5: duplicate grant accepted'; end if;

  -- A cannot grant B's vineyard
  v_failed := false;
  begin
    perform public.integration_grant_vineyard(c_a, v_vb);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%not_authorised_for_vineyard%' then raise; end if;
  end;
  if not v_failed then raise exception 'T5: A granted B''s vineyard'; end if;

  -- granting VA does not grant VA2
  j := public.integration_list_vineyard_grants(c_a);
  if exists (select 1 from jsonb_array_elements(j) e where (e->>'vineyard_id')::uuid = v_va2) then
    raise exception 'T5: VA2 appears granted without an explicit grant';
  end if;
  if not exists (select 1 from jsonb_array_elements(j) e
                 where (e->>'vineyard_id')::uuid = v_va and (e->>'is_active')::boolean) then
    raise exception 'T5: VA grant not listed active';
  end if;
  raise notice 'T5 passed';

  -- ---------------------------------------------------------------
  -- T6: Manager = view only (via granted-vineyard membership)
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    perform public.integration_create_client('Mgr Client', 'custom_api', null);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%not_authorised%' then raise; end if;
  end;
  if not v_failed then raise exception 'T6: manager created an integration'; end if;

  j := public.integration_list_clients();
  if not exists (select 1 from jsonb_array_elements(j) e
                 where (e->>'id')::uuid = c_a and (e->>'can_manage')::boolean = false) then
    raise exception 'T6: manager of granted vineyard cannot view integration';
  end if;

  v_failed := false;
  begin
    perform public.integration_grant_vineyard(c_a, v_va2);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%integration_not_found%' then raise; end if;
  end;
  if not v_failed then raise exception 'T6: manager granted a vineyard'; end if;

  v_failed := false;
  begin
    perform public.integration_grant_scope(c_a, 'trips:read');
  exception when others then
    v_failed := true;
    if sqlerrm not like '%integration_not_found%' then raise; end if;
  end;
  if not v_failed then raise exception 'T6: manager granted a scope'; end if;

  v_failed := false;
  begin
    perform public.integration_create_api_key(c_a, 'live', null, null);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%integration_not_found%' then raise; end if;
  end;
  if not v_failed then raise exception 'T6: manager created an API key'; end if;

  v_failed := false;
  begin
    perform public.integration_list_api_keys(c_a);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%integration_not_found%' then raise; end if;
  end;
  if not v_failed then raise exception 'T6: manager listed key metadata'; end if;

  -- manager may read audit history (view authority)
  j := public.integration_audit_history(c_a, 50);
  if jsonb_array_length(j) < 1 then raise exception 'T6: manager cannot view audit history'; end if;
  raise notice 'T6 passed';

  -- ---------------------------------------------------------------
  -- T7: Supervisor / Operator — no access
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_sup::text, 'role', 'authenticated')::text, true);
  j := public.integration_list_clients();
  if jsonb_array_length(j) <> 0 then raise exception 'T7: supervisor sees integrations'; end if;
  v_failed := false;
  begin
    perform public.integration_audit_history(c_a, 10);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%integration_not_found%' then raise; end if;
  end;
  if not v_failed then raise exception 'T7: supervisor read audit'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  j := public.integration_list_clients();
  if jsonb_array_length(j) <> 0 then raise exception 'T7: operator sees integrations'; end if;
  v_failed := false;
  begin
    perform public.integration_create_client('Op Client', 'custom_api', null);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%not_authorised%' then raise; end if;
  end;
  if not v_failed then raise exception 'T7: operator created an integration'; end if;
  raise notice 'T7 passed';

  -- ---------------------------------------------------------------
  -- T8: scope grants
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);

  j := public.integration_grant_scope(c_a, 'trips:read');
  if (j->>'ok')::boolean is not true then raise exception 'T8: grant trips:read failed'; end if;

  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'scope.granted'
    and metadata->>'scope' = 'trips:read';
  if n <> 1 then raise exception 'T8: scope.granted audit missing'; end if;

  v_failed := false;
  begin
    perform public.integration_grant_scope(c_a, 'made_up:read');
  exception when others then
    v_failed := true;
    if sqlerrm not like '%unknown_scope%' then raise; end if;
  end;
  if not v_failed then raise exception 'T8: unknown scope accepted'; end if;

  v_failed := false;
  begin
    perform public.integration_grant_scope(c_a, 'trips:read');
  exception when others then
    v_failed := true;
    if sqlerrm not like '%scope_already_granted%' then raise; end if;
  end;
  if not v_failed then raise exception 'T8: duplicate scope accepted'; end if;

  -- trips:read does not imply the sensitive costs:read
  j := public.integration_list_scopes(c_a);
  if exists (select 1 from jsonb_array_elements(j) e where e->>'scope' = 'costs:read') then
    raise exception 'T8: costs:read implied by trips:read';
  end if;

  -- revoke + audit, then re-grant for T10
  j := public.integration_revoke_scope(c_a, 'trips:read');
  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'scope.revoked'
    and metadata->>'scope' = 'trips:read';
  if n <> 1 then raise exception 'T8: scope.revoked audit missing'; end if;
  j := public.integration_grant_scope(c_a, 'trips:read');
  raise notice 'T8 passed';

  -- ---------------------------------------------------------------
  -- T9: API keys — hash-only storage, one-time secret
  -- ---------------------------------------------------------------
  j := public.integration_create_api_key(c_a, 'live', 'Primary key', null);
  k1 := (j->>'api_key_id')::uuid;
  k1_secret := j->>'secret';
  if k1_secret not like 'vt_live_%' or length(k1_secret) <> 56 then
    raise exception 'T9: unexpected secret shape';
  end if;
  if j->>'key_prefix' is distinct from left(k1_secret, 16) then
    raise exception 'T9: key_prefix mismatch';
  end if;

  -- stored row: hash only, never the secret
  perform 1 from public.integration_api_keys k
  where k.id = k1
    and k.key_hash = public._integration_hash_secret(k1_secret)
    and k.key_hash <> k1_secret;
  if not found then raise exception 'T9: stored hash does not match SHA-256 of secret'; end if;

  perform 1 from public.integration_api_keys k
  where k.id = k1 and to_jsonb(k)::text like '%' || k1_secret || '%';
  if found then raise exception 'T9: plaintext secret stored in key row'; end if;

  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and metadata::text like '%' || k1_secret || '%';
  if n <> 0 then raise exception 'T9: secret leaked into audit metadata'; end if;

  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'api_key.created'
    and metadata->>'api_key_id' = k1::text;
  if n <> 1 then raise exception 'T9: api_key.created audit missing'; end if;

  -- metadata listing: prefix yes, hash/secret never
  j := public.integration_list_api_keys(c_a);
  if not exists (select 1 from jsonb_array_elements(j) e
                 where (e->>'id')::uuid = k1
                   and e->>'key_prefix' = left(k1_secret, 16)
                   and not (e ? 'key_hash') and not (e ? 'secret')) then
    raise exception 'T9: key metadata list wrong or leaks material';
  end if;

  -- test-environment key
  j := public.integration_create_api_key(c_a, 'test', null, null);
  k2_secret := j->>'secret';
  if k2_secret not like 'vt_test_%' then raise exception 'T9: test env secret shape'; end if;
  perform public.integration_revoke_api_key(c_a, (j->>'api_key_id')::uuid);

  v_failed := false;
  begin
    perform public.integration_create_api_key(c_a, 'production', null, null);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%invalid_environment%' then raise; end if;
  end;
  if not v_failed then raise exception 'T9: invalid environment accepted'; end if;
  raise notice 'T9 passed';

  -- ---------------------------------------------------------------
  -- T10: validation chain — each check independent
  -- ---------------------------------------------------------------
  -- full chain valid: real key + granted scope + granted vineyard
  j := public.integration_validate_api_request(k1_secret, 'trips:read', v_va);
  if (j->>'valid')::boolean is not true
     or (j->>'integration_client_id')::uuid <> c_a
     or (j->>'api_key_id')::uuid <> k1 then
    raise exception 'T10: valid request refused: %', j;
  end if;
  perform 1 from public.integration_api_keys where id = k1 and last_used_at is not null;
  if not found then raise exception 'T10: last_used_at not stamped'; end if;

  -- unknown secret
  j := public.integration_validate_api_request('vt_live_' || repeat('0', 48), 'trips:read', v_va);
  if j->>'failure_code' is distinct from 'invalid_key' then
    raise exception 'T10: expected invalid_key, got %', j;
  end if;

  -- scope not granted (sensitive scope never implied)
  j := public.integration_validate_api_request(k1_secret, 'costs:read', v_va);
  if j->>'failure_code' is distinct from 'scope_not_granted' then
    raise exception 'T10: expected scope_not_granted, got %', j;
  end if;

  -- vineyard not granted — even though the HUMAN owner controls VA2.
  -- Integration access is never inherited from user membership.
  j := public.integration_validate_api_request(k1_secret, 'trips:read', v_va2);
  if j->>'failure_code' is distinct from 'vineyard_not_granted' then
    raise exception 'T10: expected vineyard_not_granted, got %', j;
  end if;

  -- expired key
  update public.integration_api_keys set expires_at = now() - interval '1 hour' where id = k1;
  j := public.integration_validate_api_request(k1_secret, 'trips:read', v_va);
  if j->>'failure_code' is distinct from 'key_expired' then
    raise exception 'T10: expected key_expired, got %', j;
  end if;
  update public.integration_api_keys set expires_at = null where id = k1;

  -- paused integration refuses API access
  perform public.integration_set_status(c_a, 'pause');
  j := public.integration_validate_api_request(k1_secret, 'trips:read', v_va);
  if j->>'failure_code' is distinct from 'integration_not_active' then
    raise exception 'T10: expected integration_not_active, got %', j;
  end if;
  perform public.integration_set_status(c_a, 'reactivate');

  -- revoked key stops working immediately
  perform public.integration_revoke_api_key(c_a, k1);
  j := public.integration_validate_api_request(k1_secret, 'trips:read', v_va);
  if j->>'failure_code' is distinct from 'key_revoked' then
    raise exception 'T10: expected key_revoked, got %', j;
  end if;
  perform 1 from public.integration_api_keys where id = k1 and revoked_at is not null;
  if not found then raise exception 'T10: revoked key row not retained'; end if;
  raise notice 'T10 passed';

  -- ---------------------------------------------------------------
  -- T11: lifecycle — pause keeps config, revoke is terminal
  -- ---------------------------------------------------------------
  perform public.integration_set_status(c_a, 'pause');
  perform 1 from public.integration_clients where id = c_a and status = 'paused' and paused_at is not null;
  if not found then raise exception 'T11: pause state wrong'; end if;

  j := public.integration_list_vineyard_grants(c_a);
  if not exists (select 1 from jsonb_array_elements(j) e
                 where (e->>'vineyard_id')::uuid = v_va and (e->>'is_active')::boolean) then
    raise exception 'T11: pause dropped vineyard grant config';
  end if;

  perform public.integration_set_status(c_a, 'reactivate');
  perform 1 from public.integration_clients where id = c_a and status = 'active' and paused_at is null;
  if not found then raise exception 'T11: reactivate state wrong'; end if;

  perform public.integration_set_status(c_a, 'revoke');
  perform 1 from public.integration_clients where id = c_a and status = 'revoked' and revoked_at is not null;
  if not found then raise exception 'T11: revoke state wrong'; end if;

  v_failed := false;
  begin
    perform public.integration_set_status(c_a, 'reactivate');
  exception when others then
    v_failed := true;
    if sqlerrm not like '%integration_revoked%' then raise; end if;
  end;
  if not v_failed then raise exception 'T11: revoked integration reactivated'; end if;

  v_failed := false;
  begin
    perform public.integration_grant_scope(c_a, 'fuel:read');
  exception when others then
    v_failed := true;
    if sqlerrm not like '%integration_revoked%' then raise; end if;
  end;
  if not v_failed then raise exception 'T11: revoked integration accepted new scope'; end if;

  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a
    and action in ('integration.paused', 'integration.reactivated', 'integration.revoked');
  if n < 4 then raise exception 'T11: lifecycle audit rows missing (got %)', n; end if;
  raise notice 'T11 passed';

  -- ---------------------------------------------------------------
  -- T12: audit log is append-only
  -- ---------------------------------------------------------------
  v_failed := false;
  begin
    update public.integration_audit_log set action = 'integration.updated'
    where integration_client_id = c_a;
  exception when others then
    v_failed := true;
    if sqlerrm not like '%append-only%' then raise; end if;
  end;
  if not v_failed then raise exception 'T12: audit UPDATE allowed'; end if;

  v_failed := false;
  begin
    delete from public.integration_audit_log where integration_client_id = c_a;
  exception when others then
    v_failed := true;
    if sqlerrm not like '%append-only%' then raise; end if;
  end;
  if not v_failed then raise exception 'T12: audit DELETE allowed'; end if;
  raise notice 'T12 passed';

  -- ---------------------------------------------------------------
  -- T13: webhook schema constraints (no dispatching exists)
  -- ---------------------------------------------------------------
  insert into public.webhook_endpoints
    (id, integration_client_id, url, signing_secret_hash, signing_secret_prefix, created_by)
  values
    (v_ep, c_a, 'https://example.com/vinetrack-hook',
     public._integration_hash_secret('whsec_t172'), 'whsec_t1', u_owner_a);

  v_failed := false;
  begin
    insert into public.webhook_endpoints
      (integration_client_id, url, signing_secret_hash, signing_secret_prefix, created_by)
    values (c_a, 'http://insecure.example.com',
            public._integration_hash_secret('whsec_bad'), 'whsec_ba', u_owner_a);
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T13: non-HTTPS endpoint accepted'; end if;

  insert into public.webhook_subscriptions (webhook_endpoint_id, event_type)
  values (v_ep, 'trip.completed');

  v_failed := false;
  begin
    insert into public.webhook_subscriptions (webhook_endpoint_id, event_type)
    values (v_ep, 'trip.exploded');
  exception when foreign_key_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T13: non-catalogue event accepted'; end if;

  v_failed := false;
  begin
    insert into public.webhook_subscriptions (webhook_endpoint_id, event_type)
    values (v_ep, 'trip.completed');
  exception when unique_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T13: duplicate subscription accepted'; end if;
  raise notice 'T13 passed';

  -- ---------------------------------------------------------------
  -- T14: idempotency uniqueness
  -- ---------------------------------------------------------------
  insert into public.integration_idempotency_keys
    (integration_client_id, idempotency_key, method, path)
  values (c_a, 'req-001', 'POST', '/v1/trips');

  v_failed := false;
  begin
    insert into public.integration_idempotency_keys
      (integration_client_id, idempotency_key, method, path)
    values (c_a, 'req-001', 'POST', '/v1/trips');
  exception when unique_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T14: duplicate idempotency key accepted'; end if;
  raise notice 'T14 passed';

  -- ---------------------------------------------------------------
  -- T15: authenticated role cannot execute the validation function
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  v_failed := false;
  begin
    perform public.integration_validate_api_request('vt_live_' || repeat('0', 48), 'trips:read', v_va);
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T15: authenticated executed validation function'; end if;

  -- ---------------------------------------------------------------
  -- T16: existing core RLS path still intact (still role=authenticated)
  -- ---------------------------------------------------------------
  select count(*) into n from public.vineyard_members where user_id = auth.uid();
  if n < 1 then raise exception 'T16: owner cannot read own memberships'; end if;

  perform set_config('role', 'postgres', true);
  raise notice 'T15 passed';
  raise notice 'T16 passed';

  raise notice 'SQL 172 integration platform tests: ALL PASSED';
end$$;

rollback;

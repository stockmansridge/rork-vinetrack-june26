-- =====================================================================
-- 173_integration_api_gateway_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/172_integration_platform_foundation.sql AND
-- sql/173_integration_api_gateway_support.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects exist: request_id column (+ format check), nullable
--       integration_client_id, rate-limit counter table, the three
--       Stage-3A functions
--   T2  integration_authenticate_api_key: valid key returns the safe
--       profile (active scopes + active vineyard grants ONLY); malformed
--       and unknown keys → invalid_key; revoked key → key_revoked;
--       expired key → key_expired; paused integration →
--       integration_not_active; revoked integration →
--       integration_not_active
--   T3  last_used_at is set on authenticate and throttled (no second
--       write inside 60 s; refreshed when stale)
--   T4  integration_check_rate_limit: fixed 60 s window counts up,
--       blocks past the limit with a sane retry_after, and counters are
--       isolated per API key
--   T5  integration_log_api_request: logs success rows with request_id,
--       logs failed-auth rows with NULL client id, rejects bad methods,
--       and the request_id format constraint holds
--   T6  Lockdown: authenticated role cannot execute the three Stage-3A
--       functions and cannot read the rate-limit counter table
--
-- Expected final output:
--   NOTICE: SQL 173 integration gateway tests: ALL PASSED
-- =====================================================================

begin;

do $$
declare
  u_owner uuid;

  v_va  uuid := gen_random_uuid();  -- granted vineyard
  v_va2 uuid := gen_random_uuid();  -- granted then revoked
  v_va3 uuid := gen_random_uuid();  -- never granted

  c_a uuid;  -- active integration
  c_b uuid;  -- paused integration
  c_c uuid;  -- revoked integration

  k_valid_id uuid;
  k_valid text;   -- one-time plaintext (test-local only)
  k_revoked text;
  k_expired text;
  k_expired_id uuid;
  k_b text;
  k_c text;

  j jsonb;
  v_failed boolean;
  n integer;
  t1 timestamptz;
  t2 timestamptz;
  v_req text := 'req_' || replace(gen_random_uuid()::text, '-', '');
begin
  -- =====================================================================
  -- Fixtures
  -- =====================================================================
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't173-owner@test.local', 'x', now(), now(), now());
  select id into u_owner from auth.users where email = 't173-owner@test.local';

  insert into public.profiles (id, email) values (u_owner, 't173-owner@test.local');

  insert into public.vineyards (id, name, owner_id) values
    (v_va,  'T173 Vineyard A',  u_owner),
    (v_va2, 'T173 Vineyard A2', u_owner),
    (v_va3, 'T173 Vineyard A3', u_owner);

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_va,  u_owner, 'owner'),
    (v_va2, u_owner, 'owner'),
    (v_va3, u_owner, 'owner');

  -- Build integrations through the canonical Stage-2 RPCs as the owner.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner::text, 'role', 'authenticated')::text, true);

  j := public.integration_create_client('T173 Active', 'custom_api', null);
  c_a := (j->>'id')::uuid;
  j := public.integration_create_client('T173 Paused', 'custom_api', null);
  c_b := (j->>'id')::uuid;
  j := public.integration_create_client('T173 Revoked', 'custom_api', null);
  c_c := (j->>'id')::uuid;

  perform public.integration_grant_vineyard(c_a, v_va);
  perform public.integration_grant_vineyard(c_a, v_va2);
  perform public.integration_revoke_vineyard(c_a, v_va2);

  perform public.integration_grant_scope(c_a, 'vineyards:read');
  perform public.integration_grant_scope(c_a, 'blocks:read');
  perform public.integration_grant_scope(c_a, 'trips:read');
  perform public.integration_revoke_scope(c_a, 'trips:read');

  j := public.integration_create_api_key(c_a, 'live', 'valid', null);
  k_valid    := j->>'secret';
  k_valid_id := (j->>'api_key_id')::uuid;

  j := public.integration_create_api_key(c_a, 'live', 'to-revoke', null);
  k_revoked := j->>'secret';
  perform public.integration_revoke_api_key(c_a, (j->>'api_key_id')::uuid);

  j := public.integration_create_api_key(c_a, 'test', 'to-expire', now() + interval '1 hour');
  k_expired    := j->>'secret';
  k_expired_id := (j->>'api_key_id')::uuid;

  j := public.integration_create_api_key(c_b, 'live', 'paused-client-key', null);
  k_b := j->>'secret';
  perform public.integration_set_status(c_b, 'pause');

  j := public.integration_create_api_key(c_c, 'live', 'revoked-client-key', null);
  k_c := j->>'secret';
  perform public.integration_set_status(c_c, 'revoke');

  -- Back to superuser for direct fixture surgery + service-side calls.
  perform set_config('role', 'postgres', true);
  update public.integration_api_keys
  set expires_at = now() - interval '1 minute'
  where id = k_expired_id;

  -- ---------------------------------------------------------------
  -- T1: Stage-3A objects exist
  -- ---------------------------------------------------------------
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'integration_api_requests'
      and column_name = 'request_id'
  ) then
    raise exception 'T1: integration_api_requests.request_id missing';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'integration_api_requests'
      and column_name = 'integration_client_id' and is_nullable = 'NO'
  ) then
    raise exception 'T1: integration_client_id must be nullable for failed-auth logging';
  end if;

  if to_regclass('public.integration_rate_limit_counters') is null then
    raise exception 'T1: integration_rate_limit_counters missing';
  end if;

  if to_regprocedure('public.integration_authenticate_api_key(text)') is null
     or to_regprocedure('public.integration_check_rate_limit(uuid, integer)') is null
     or to_regprocedure('public.integration_log_api_request(text, uuid, uuid, uuid, text, text, integer, integer, text)') is null then
    raise exception 'T1: a Stage-3A function is missing';
  end if;
  raise notice 'T1 passed';

  -- ---------------------------------------------------------------
  -- T2: authenticate chain
  -- ---------------------------------------------------------------
  j := public.integration_authenticate_api_key(k_valid);
  if not (j->>'valid')::boolean then raise exception 'T2: valid key rejected: %', j; end if;
  if (j->>'integration_client_id')::uuid <> c_a then raise exception 'T2: wrong client'; end if;
  if (j->>'api_key_id')::uuid <> k_valid_id then raise exception 'T2: wrong key id'; end if;
  if j->>'environment' <> 'live' then raise exception 'T2: wrong environment'; end if;
  if j->>'integration_name' <> 'T173 Active' then raise exception 'T2: wrong name'; end if;

  -- scopes: only ACTIVE grants (trips:read was revoked)
  if not (j->'scopes' ? 'vineyards:read') or not (j->'scopes' ? 'blocks:read') then
    raise exception 'T2: active scopes missing: %', j->'scopes';
  end if;
  if j->'scopes' ? 'trips:read' then
    raise exception 'T2: revoked scope leaked: %', j->'scopes';
  end if;

  -- vineyards: only ACTIVE grants (VA2 revoked, VA3 never granted)
  select count(*) into n from jsonb_array_elements(j->'vineyards') e
  where (e->>'id')::uuid = v_va;
  if n <> 1 then raise exception 'T2: granted vineyard missing'; end if;
  select count(*) into n from jsonb_array_elements(j->'vineyards') e
  where (e->>'id')::uuid in (v_va2, v_va3);
  if n <> 0 then raise exception 'T2: ungranted/revoked vineyard leaked'; end if;

  -- no secret material in the profile
  if j::text like '%' || k_valid || '%' then raise exception 'T2: secret leaked'; end if;
  if j ? 'key_hash' then raise exception 'T2: hash leaked'; end if;

  -- failure codes
  j := public.integration_authenticate_api_key('not-a-key');
  if (j->>'valid')::boolean or j->>'failure_code' <> 'invalid_key' then
    raise exception 'T2: malformed key not refused: %', j;
  end if;

  j := public.integration_authenticate_api_key('vt_live_' || repeat('0', 48));
  if (j->>'valid')::boolean or j->>'failure_code' <> 'invalid_key' then
    raise exception 'T2: unknown key not refused: %', j;
  end if;

  j := public.integration_authenticate_api_key(k_revoked);
  if (j->>'valid')::boolean or j->>'failure_code' <> 'key_revoked' then
    raise exception 'T2: revoked key not refused: %', j;
  end if;

  j := public.integration_authenticate_api_key(k_expired);
  if (j->>'valid')::boolean or j->>'failure_code' <> 'key_expired' then
    raise exception 'T2: expired key not refused: %', j;
  end if;

  j := public.integration_authenticate_api_key(k_b);
  if (j->>'valid')::boolean or j->>'failure_code' <> 'integration_not_active' then
    raise exception 'T2: paused integration not refused: %', j;
  end if;

  j := public.integration_authenticate_api_key(k_c);
  if (j->>'valid')::boolean or j->>'failure_code' <> 'integration_not_active' then
    raise exception 'T2: revoked integration not refused: %', j;
  end if;
  raise notice 'T2 passed';

  -- ---------------------------------------------------------------
  -- T3: last_used_at throttle (60 s)
  -- ---------------------------------------------------------------
  select last_used_at into t1 from public.integration_api_keys where id = k_valid_id;
  if t1 is null then raise exception 'T3: last_used_at not set by authenticate'; end if;

  perform public.integration_authenticate_api_key(k_valid);
  select last_used_at into t2 from public.integration_api_keys where id = k_valid_id;
  if t2 <> t1 then raise exception 'T3: last_used_at rewritten inside 60 s window'; end if;

  update public.integration_api_keys
  set last_used_at = now() - interval '2 minutes' where id = k_valid_id;
  perform public.integration_authenticate_api_key(k_valid);
  select last_used_at into t2 from public.integration_api_keys where id = k_valid_id;
  if t2 < now() - interval '30 seconds' then
    raise exception 'T3: stale last_used_at not refreshed';
  end if;
  raise notice 'T3 passed';

  -- ---------------------------------------------------------------
  -- T4: rate limiting
  -- ---------------------------------------------------------------
  j := public.integration_check_rate_limit(k_valid_id, 3);
  if not (j->>'allowed')::boolean or (j->>'remaining')::int <> 2 then
    raise exception 'T4: call 1 wrong: %', j;
  end if;
  j := public.integration_check_rate_limit(k_valid_id, 3);
  if not (j->>'allowed')::boolean or (j->>'remaining')::int <> 1 then
    raise exception 'T4: call 2 wrong: %', j;
  end if;
  j := public.integration_check_rate_limit(k_valid_id, 3);
  if not (j->>'allowed')::boolean or (j->>'remaining')::int <> 0 then
    raise exception 'T4: call 3 wrong: %', j;
  end if;
  j := public.integration_check_rate_limit(k_valid_id, 3);
  if (j->>'allowed')::boolean then raise exception 'T4: limit not enforced'; end if;
  if (j->>'retry_after_seconds')::int not between 1 and 60 then
    raise exception 'T4: retry_after out of range: %', j;
  end if;

  -- counters isolated per key
  j := public.integration_check_rate_limit(k_expired_id, 3);
  if not (j->>'allowed')::boolean or (j->>'remaining')::int <> 2 then
    raise exception 'T4: counters not isolated per key: %', j;
  end if;

  -- null key refused
  j := public.integration_check_rate_limit(null, 3);
  if (j->>'allowed')::boolean then raise exception 'T4: null key allowed'; end if;
  raise notice 'T4 passed';

  -- ---------------------------------------------------------------
  -- T5: request logging
  -- ---------------------------------------------------------------
  perform public.integration_log_api_request(
    v_req, c_a, k_valid_id, v_va, 'GET', '/v1/blocks', 200, 42, null);
  select count(*) into n from public.integration_api_requests
  where request_id = v_req and integration_client_id = c_a
    and api_key_id = k_valid_id and vineyard_id = v_va
    and method = 'GET' and path = '/v1/blocks' and status_code = 200;
  if n <> 1 then raise exception 'T5: success row not logged'; end if;

  -- failed auth: no client/key known
  perform public.integration_log_api_request(
    'req_' || replace(gen_random_uuid()::text, '-', ''),
    null, null, null, 'GET', '/v1/me', 401, 5, 'invalid_api_key');
  select count(*) into n from public.integration_api_requests
  where integration_client_id is null and error_code = 'invalid_api_key';
  if n < 1 then raise exception 'T5: failed-auth row not logged'; end if;

  -- bad method refused
  v_failed := false;
  begin
    perform public.integration_log_api_request(
      v_req, null, null, null, 'OPTIONS', '/v1/me', 204, 1, null);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%invalid_method%' then raise; end if;
  end;
  if not v_failed then raise exception 'T5: OPTIONS accepted by log writer'; end if;

  -- request_id format constraint holds
  v_failed := false;
  begin
    insert into public.integration_api_requests
      (request_id, method, path, status_code)
    values ('bogus-format', 'GET', '/v1/me', 200);
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T5: request_id format not enforced'; end if;
  raise notice 'T5 passed';

  -- ---------------------------------------------------------------
  -- T6: authenticated role locked out of gateway functions + counters
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  v_failed := false;
  begin
    perform public.integration_authenticate_api_key(k_valid);
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T6: authenticated can call authenticate_api_key'; end if;

  v_failed := false;
  begin
    perform public.integration_check_rate_limit(k_valid_id, 3);
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T6: authenticated can call check_rate_limit'; end if;

  v_failed := false;
  begin
    perform public.integration_log_api_request(
      v_req, null, null, null, 'GET', '/v1/me', 200, 1, null);
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T6: authenticated can call log_api_request'; end if;

  v_failed := false;
  begin
    perform 1 from public.integration_rate_limit_counters;
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T6: rate counters readable by authenticated'; end if;

  perform set_config('role', 'postgres', true);
  raise notice 'T6 passed';

  raise notice 'SQL 173 integration gateway tests: ALL PASSED';
end$$;

rollback;

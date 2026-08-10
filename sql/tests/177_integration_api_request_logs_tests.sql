-- =====================================================================
-- 177_integration_api_request_logs_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/177_integration_api_request_logs_rpc.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects exist: RPC signature + keyset index
--   T2  Direct table access to integration_api_requests remains blocked
--       for authenticated clients
--   T3  Owner reads own integration logs: full row set, newest-first
--       ordering, safe fields present, key hash NEVER present
--   T4  Key display metadata: prefix/name resolved; revoked key still
--       resolvable for historical rows
--   T5  Vineyard display metadata: vineyard_name resolved
--   T6  Manager (member of an actively granted vineyard) can read
--   T7  Supervisor and Operator denied (integration_not_found)
--   T8  Cross-account isolation: Owner B gets the SAME error for A's
--       integration id and for a random uuid (non-disclosing)
--   T9  Filters: vineyard, status code, error-only, api key, date range
--   T10 Invalid inputs: bad status, from > to, lone cursor half
--   T11 Pagination: keyset newest-first, no duplicates/gaps, has_more,
--       limit clamped (min 1; max 1000 accepted without error)
--   T12 Existing write path unchanged: integration_log_api_request
--       still appends and the new row is visible via the RPC
--
-- Expected final output:
--   NOTICE: SQL 177 request-log RPC tests: ALL PASSED
-- =====================================================================

begin;

do $$
declare
  u_owner_a uuid;
  u_owner_b uuid;
  u_mgr     uuid;
  u_sup     uuid;
  u_op      uuid;

  v_va  uuid := gen_random_uuid();  -- vineyard A (granted; mgr/sup/op are members)
  v_va2 uuid := gen_random_uuid();  -- second vineyard owned by A (also granted)
  v_vb  uuid := gen_random_uuid();  -- vineyard B (owner B)

  c_a uuid;                          -- Owner A's integration client
  k1 uuid; k1_secret text;           -- active key
  k2 uuid; k2_secret text;           -- key revoked after logging

  j jsonb;
  e jsonb;
  v_failed boolean;
  n integer;
  ids uuid[] := '{}';
  v_cursor_t timestamptz;
  v_cursor_id uuid;
  v_pages integer := 0;
begin
  -- =====================================================================
  -- Fixtures
  -- =====================================================================
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e2, 'x', now(), now(), now()
  from unnest(array[
    't177-owner-a@test.local', 't177-owner-b@test.local', 't177-mgr@test.local',
    't177-sup@test.local',     't177-op@test.local'
  ]) e2;

  select id into u_owner_a from auth.users where email = 't177-owner-a@test.local';
  select id into u_owner_b from auth.users where email = 't177-owner-b@test.local';
  select id into u_mgr     from auth.users where email = 't177-mgr@test.local';
  select id into u_sup     from auth.users where email = 't177-sup@test.local';
  select id into u_op      from auth.users where email = 't177-op@test.local';

  insert into public.profiles (id, email) values
    (u_owner_a, 't177-owner-a@test.local'),
    (u_owner_b, 't177-owner-b@test.local'),
    (u_mgr,     't177-mgr@test.local'),
    (u_sup,     't177-sup@test.local'),
    (u_op,      't177-op@test.local');

  insert into public.vineyards (id, name, owner_id) values
    (v_va,  'T177 Vineyard A',  u_owner_a),
    (v_va2, 'T177 Vineyard A2', u_owner_a),
    (v_vb,  'T177 Vineyard B',  u_owner_b);

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_va,  u_owner_a, 'owner'),
    (v_va,  u_mgr,     'manager'),
    (v_va,  u_sup,     'supervisor'),
    (v_va,  u_op,      'operator'),
    (v_va2, u_owner_a, 'owner'),
    (v_vb,  u_owner_b, 'owner');

  -- Owner A creates the integration, grants both vineyards, mints keys.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);

  j := public.integration_create_client('T177 Logs Integration', 'custom_api', null);
  c_a := (j->>'id')::uuid;
  perform public.integration_grant_vineyard(c_a, v_va);
  perform public.integration_grant_vineyard(c_a, v_va2);

  j := public.integration_create_api_key(c_a, 'test', 't177 key one', null);
  k1 := (j->>'api_key_id')::uuid;
  k1_secret := j->>'secret';
  j := public.integration_create_api_key(c_a, 'test', 't177 key two', null);
  k2 := (j->>'api_key_id')::uuid;
  k2_secret := j->>'secret';

  -- Seed 7 log rows through the CANONICAL writer (also proves the write
  -- path is intact), then spread created_at for deterministic paging.
  perform public.integration_log_api_request('req_' || md5('t177-1'), c_a, k1, v_va,  'GET', '/v1/trips',          200, 40,  null);
  perform public.integration_log_api_request('req_' || md5('t177-2'), c_a, k1, v_va,  'GET', '/v1/trips',          200, 35,  null);
  perform public.integration_log_api_request('req_' || md5('t177-3'), c_a, k1, v_va,  'GET', '/v1/spray-jobs',     403, 20,  'vineyard_access_denied');
  perform public.integration_log_api_request('req_' || md5('t177-4'), c_a, k1, v_va2, 'GET', '/v1/weather',        200, 250, null);
  perform public.integration_log_api_request('req_' || md5('t177-5'), c_a, k2, v_va2, 'GET', '/v1/pins/{pin_id}',  404, 15,  'resource_not_found');
  perform public.integration_log_api_request('req_' || md5('t177-6'), c_a, k2, null,  'GET', '/v1/me',             200, 10,  null);
  perform public.integration_log_api_request('req_' || md5('t177-7'), c_a, k1, v_va,  'GET', '/v1/rainfall',       429, 5,   'rate_limit_exceeded');

  update public.integration_api_requests set created_at = now() - interval '1 minute' where request_id = 'req_' || md5('t177-1');
  update public.integration_api_requests set created_at = now() - interval '2 minutes' where request_id = 'req_' || md5('t177-2');
  update public.integration_api_requests set created_at = now() - interval '3 minutes' where request_id = 'req_' || md5('t177-3');
  update public.integration_api_requests set created_at = now() - interval '4 minutes' where request_id = 'req_' || md5('t177-4');
  update public.integration_api_requests set created_at = now() - interval '5 minutes' where request_id = 'req_' || md5('t177-5');
  update public.integration_api_requests set created_at = now() - interval '6 minutes' where request_id = 'req_' || md5('t177-6');
  update public.integration_api_requests set created_at = now() - interval '7 minutes' where request_id = 'req_' || md5('t177-7');

  -- Revoke key two AFTER its rows were logged (historical resolvability).
  perform public.integration_revoke_api_key(c_a, k2);

  -- ---------------------------------------------------------------
  -- T1: objects exist
  -- ---------------------------------------------------------------
  if to_regprocedure('public.integration_list_api_requests(uuid, timestamptz, timestamptz, integer, uuid, uuid, boolean, integer, timestamptz, uuid)') is null then
    raise exception 'T1: integration_list_api_requests signature missing';
  end if;
  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'idx_integration_api_requests_client_keyset'
  ) then
    raise exception 'T1: keyset index missing';
  end if;
  raise notice 'T1 passed';

  -- ---------------------------------------------------------------
  -- T2: direct table access remains blocked for authenticated
  -- ---------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  v_failed := false;
  begin
    perform 1 from public.integration_api_requests;
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T2: integration_api_requests readable directly'; end if;
  perform set_config('role', 'postgres', true);
  raise notice 'T2 passed';

  -- ---------------------------------------------------------------
  -- T3: Owner reads own logs — full set, newest first, no hash
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  j := public.integration_list_api_requests(c_a);
  if jsonb_array_length(j->'data') <> 7 then
    raise exception 'T3: expected 7 rows, got %', jsonb_array_length(j->'data');
  end if;
  if (j->'data'->0->>'request_id') is distinct from ('req_' || md5('t177-1')) then
    raise exception 'T3: newest-first ordering broken';
  end if;
  e := j->'data'->0;
  if not (e ? 'id' and e ? 'request_id' and e ? 'created_at' and e ? 'integration_client_id'
          and e ? 'api_key_id' and e ? 'api_key_prefix' and e ? 'api_key_name'
          and e ? 'vineyard_id' and e ? 'vineyard_name' and e ? 'method' and e ? 'path'
          and e ? 'status_code' and e ? 'duration_ms' and e ? 'error_code') then
    raise exception 'T3: expected safe fields missing';
  end if;
  if e ? 'key_hash' or e ? 'api_key_hash' then
    raise exception 'T3: hash field exposed';
  end if;
  if position(public._integration_hash_secret(k1_secret) in j::text) > 0
     or position(public._integration_hash_secret(k2_secret) in j::text) > 0
     or position(k1_secret in j::text) > 0 or position(k2_secret in j::text) > 0 then
    raise exception 'T3: key hash or secret material leaked into the response';
  end if;
  raise notice 'T3 passed';

  -- ---------------------------------------------------------------
  -- T4: key display metadata; revoked key still resolvable
  -- ---------------------------------------------------------------
  select x into e from jsonb_array_elements(j->'data') x
  where x->>'request_id' = 'req_' || md5('t177-5');
  if e->>'api_key_prefix' is null or e->>'api_key_name' is distinct from 't177 key two' then
    raise exception 'T4: revoked key metadata not resolved';
  end if;
  if e->>'api_key_revoked_at' is null then
    raise exception 'T4: revoked key not marked revoked';
  end if;
  if left(e->>'api_key_prefix', 8) <> 'vt_test_' then
    raise exception 'T4: unexpected key prefix %', e->>'api_key_prefix';
  end if;
  raise notice 'T4 passed';

  -- ---------------------------------------------------------------
  -- T5: vineyard display metadata
  -- ---------------------------------------------------------------
  select x into e from jsonb_array_elements(j->'data') x
  where x->>'request_id' = 'req_' || md5('t177-1');
  if e->>'vineyard_name' is distinct from 'T177 Vineyard A' then
    raise exception 'T5: vineyard_name not resolved (%)', e->>'vineyard_name';
  end if;
  raise notice 'T5 passed';

  -- ---------------------------------------------------------------
  -- T6: Manager (owner/manager member of granted vineyard) can read
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  j := public.integration_list_api_requests(c_a);
  if jsonb_array_length(j->'data') <> 7 then
    raise exception 'T6: manager expected 7 rows, got %', jsonb_array_length(j->'data');
  end if;
  raise notice 'T6 passed';

  -- ---------------------------------------------------------------
  -- T7: Supervisor / Operator denied
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_sup::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    j := public.integration_list_api_requests(c_a);
  exception when others then
    v_failed := sqlerrm = 'integration_not_found';
  end;
  if not v_failed then raise exception 'T7: supervisor was not denied correctly'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    j := public.integration_list_api_requests(c_a);
  exception when others then
    v_failed := sqlerrm = 'integration_not_found';
  end;
  if not v_failed then raise exception 'T7: operator was not denied correctly'; end if;
  raise notice 'T7 passed';

  -- ---------------------------------------------------------------
  -- T8: cross-account non-disclosure — same error for A's id and a
  --     random uuid
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_b::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    j := public.integration_list_api_requests(c_a);
  exception when others then
    v_failed := sqlerrm = 'integration_not_found';
  end;
  if not v_failed then raise exception 'T8: owner B could probe A''s integration'; end if;

  v_failed := false;
  begin
    j := public.integration_list_api_requests(gen_random_uuid());
  exception when others then
    v_failed := sqlerrm = 'integration_not_found';
  end;
  if not v_failed then raise exception 'T8: nonexistent id error differs (discloses existence)'; end if;
  raise notice 'T8 passed';

  -- ---------------------------------------------------------------
  -- T9: filters
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);

  j := public.integration_list_api_requests(c_a, p_vineyard_id => v_va);
  if jsonb_array_length(j->'data') <> 4 then
    raise exception 'T9: vineyard filter expected 4, got %', jsonb_array_length(j->'data');
  end if;

  j := public.integration_list_api_requests(c_a, p_status_code => 403);
  if jsonb_array_length(j->'data') <> 1
     or (j->'data'->0->>'error_code') is distinct from 'vineyard_access_denied' then
    raise exception 'T9: status filter broken';
  end if;

  j := public.integration_list_api_requests(c_a, p_error_only => true);
  if jsonb_array_length(j->'data') <> 3 then
    raise exception 'T9: error-only filter expected 3, got %', jsonb_array_length(j->'data');
  end if;

  j := public.integration_list_api_requests(c_a, p_api_key_id => k2);
  if jsonb_array_length(j->'data') <> 2 then
    raise exception 'T9: api key filter expected 2, got %', jsonb_array_length(j->'data');
  end if;

  j := public.integration_list_api_requests(c_a,
    p_from => now() - interval '3 minutes 30 seconds');
  if jsonb_array_length(j->'data') <> 3 then
    raise exception 'T9: from filter expected 3, got %', jsonb_array_length(j->'data');
  end if;

  j := public.integration_list_api_requests(c_a,
    p_from => now() - interval '7 minutes 30 seconds',
    p_to   => now() - interval '5 minutes 30 seconds');
  if jsonb_array_length(j->'data') <> 2 then
    raise exception 'T9: date-range filter expected 2, got %', jsonb_array_length(j->'data');
  end if;
  raise notice 'T9 passed';

  -- ---------------------------------------------------------------
  -- T10: invalid inputs
  -- ---------------------------------------------------------------
  v_failed := false;
  begin
    j := public.integration_list_api_requests(c_a, p_status_code => 42);
  exception when others then v_failed := sqlerrm = 'invalid_status';
  end;
  if not v_failed then raise exception 'T10: bad status accepted'; end if;

  v_failed := false;
  begin
    j := public.integration_list_api_requests(c_a,
      p_from => now(), p_to => now() - interval '1 day');
  exception when others then v_failed := sqlerrm = 'invalid_range';
  end;
  if not v_failed then raise exception 'T10: from > to accepted'; end if;

  v_failed := false;
  begin
    j := public.integration_list_api_requests(c_a, p_before_created_at => now());
  exception when others then v_failed := sqlerrm = 'invalid_cursor';
  end;
  if not v_failed then raise exception 'T10: lone cursor half accepted'; end if;
  raise notice 'T10 passed';

  -- ---------------------------------------------------------------
  -- T11: pagination — keyset, no duplicates, has_more, limit clamps
  -- ---------------------------------------------------------------
  v_cursor_t := null; v_cursor_id := null; ids := '{}'; v_pages := 0;
  loop
    j := public.integration_list_api_requests(c_a, p_limit => 2,
      p_before_created_at => v_cursor_t, p_before_id => v_cursor_id);
    v_pages := v_pages + 1;
    ids := ids || (select coalesce(array_agg((x->>'id')::uuid), '{}')
                   from jsonb_array_elements(j->'data') x);
    exit when not (j->'pagination'->>'has_more')::boolean;
    v_cursor_t  := (j->'pagination'->>'next_before_created_at')::timestamptz;
    v_cursor_id := (j->'pagination'->>'next_before_id')::uuid;
    if v_cursor_t is null or v_cursor_id is null then
      raise exception 'T11: has_more true but next cursor missing';
    end if;
    if v_pages > 10 then raise exception 'T11: pagination did not terminate'; end if;
  end loop;
  if array_length(ids, 1) <> 7 then
    raise exception 'T11: pagination returned % rows, expected 7', array_length(ids, 1);
  end if;
  select count(distinct u) into n from unnest(ids) u;
  if n <> 7 then raise exception 'T11: pagination produced duplicate rows'; end if;
  if v_pages < 4 then raise exception 'T11: expected >= 4 pages of 2, got %', v_pages; end if;

  -- Limit clamps: below minimum -> 1 row; huge -> accepted (max 1000).
  j := public.integration_list_api_requests(c_a, p_limit => -5);
  if jsonb_array_length(j->'data') <> 1 then
    raise exception 'T11: limit floor not enforced';
  end if;
  j := public.integration_list_api_requests(c_a, p_limit => 5000);
  if jsonb_array_length(j->'data') <> 7 then
    raise exception 'T11: oversized limit rejected instead of clamped';
  end if;
  raise notice 'T11 passed';

  -- ---------------------------------------------------------------
  -- T12: existing write path unchanged; new row visible via RPC
  -- ---------------------------------------------------------------
  perform set_config('role', 'postgres', true);
  perform public.integration_log_api_request('req_' || md5('t177-8'), c_a, k1, v_va,
    'GET', '/v1/blocks', 200, 22, null);

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  j := public.integration_list_api_requests(c_a);
  if jsonb_array_length(j->'data') <> 8 then
    raise exception 'T12: expected 8 rows after new log write, got %', jsonb_array_length(j->'data');
  end if;
  if (j->'data'->0->>'path') is distinct from '/v1/blocks' then
    raise exception 'T12: newest write not first';
  end if;
  perform set_config('role', 'postgres', true);
  raise notice 'T12 passed';

  raise notice 'SQL 177 request-log RPC tests: ALL PASSED';
end$$;

rollback;

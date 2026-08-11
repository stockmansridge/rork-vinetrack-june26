-- ===========================================================================
-- SQL 179 tests — Integration Platform Administration (Stage 7A)
--
-- Rollback-only verification. Everything runs inside ONE transaction that is
-- ROLLED BACK at the end. Requires sql/062, 172, 173, 177, 178, 179 applied.
--
-- Test map:
--   T1  objects exist (functions + indexes)
--   T2  anon denied (no execute privilege)
--   T3  non-admin authenticated users denied (owner/manager/supervisor/operator)
--   T4  service_role denied (no execute grant; admin surface is user-JWT only)
--   T5  admin list: rows, counts, safe output (no hashes/secrets)
--   T6  list filters (status, environment, vineyard, owner query, rate-limited)
--   T7  keyset pagination (has_more, cursor, no overlap) + invalid cursor
--   T8  health classification (healthy / inactive / critical) + health filter
--   T9  API metrics totals + breakdown + invalid window
--   T10 request-log listing: unauthenticated rows, filters, safety
--   T11 webhook metrics (delivery counts, auto-disabled, oldest pending)
--   T12 endpoint list: URL query redaction, no signing secrets, failing filter
--   T13 delivery list: cross-client rows, status filter, no payload/response
--   T14 diagnostics snapshot shape + safety
--   T15 suspend / suspended auth behaviour / internal-helper boundary /
--       reactivate + audit records
--   T16 admin key revocation + audit + double-revoke rejected
--   T17 endpoint pause / reactivate-from-disabled (clears disable state)
--   T18 audit listing (global, per-client, actor_type, action filter)
--
-- Expected final output:
--   NOTICE: SQL 179 integration platform admin tests: ALL PASSED
-- ===========================================================================

begin;

-- Stable snapshot: these tests run against a shared/live database. All global
-- metrics assertions are baseline-relative; repeatable read keeps the baseline
-- and the later RPC reads on the same snapshot so exact deltas hold even with
-- concurrent API traffic.
set transaction isolation level repeatable read;

do $$
declare
  u_admin uuid;
  u_owner_a uuid;
  u_owner_b uuid;
  u_manager uuid;
  u_supervisor uuid;
  u_operator uuid;
  vy_a uuid := gen_random_uuid();
  cl_a uuid := gen_random_uuid();
  cl_b uuid := gen_random_uuid();
  cl_old uuid := gen_random_uuid();
  k_a1 uuid := gen_random_uuid();
  k_a2 uuid := gen_random_uuid();
  k_b1 uuid := gen_random_uuid();
  k_old uuid := gen_random_uuid();
  ep_a uuid := gen_random_uuid();
  ep_b uuid := gen_random_uuid();
  ev1 uuid := gen_random_uuid();
  ev2 uuid := gen_random_uuid();
  ev3 uuid := gen_random_uuid();
  d1 uuid := gen_random_uuid();
  d2 uuid := gen_random_uuid();
  d3 uuid := gen_random_uuid();
  v_event text;
  v_plain_b text := 'vt_live_' || repeat('0123456789abcdef', 3);  -- 48 hex chars
  v_hash_a1 text := md5('t179-a1') || md5('t179-a1x');
  v_hash_a2 text := md5('t179-a2') || md5('t179-a2x');
  v_hash_old text := md5('t179-old') || md5('t179-oldx');
  v jsonb;
  v2 jsonb;
  v_row jsonb;
  v_failed boolean;
  v_text text;
  v_count integer;
  e text;
  -- Live-data baselines (captured before activity fixtures are inserted)
  b_req integer;
  b_rl integer;
  b_5xx integer;
  b_unauth integer;
  b_keys integer;
  b_d_total integer;
  b_d_delivered integer;
  b_d_failed integer;
  b_d_pending integer;
  b_d_retry integer;
  b_att_failed integer;
  b_ep_auto integer;
begin
  -- =========================================================================
  -- Fixtures (created as postgres; RLS bypassed)
  -- =========================================================================
  foreach e in array array[
    't179-admin@test.local', 't179-owner-a@test.local', 't179-owner-b@test.local',
    't179-manager@test.local', 't179-supervisor@test.local', 't179-operator@test.local'
  ] loop
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                            email_confirmed_at, created_at, updated_at)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated', e, 'x', now(), now(), now());
  end loop;

  select id into u_admin from auth.users where email = 't179-admin@test.local';
  select id into u_owner_a from auth.users where email = 't179-owner-a@test.local';
  select id into u_owner_b from auth.users where email = 't179-owner-b@test.local';
  select id into u_manager from auth.users where email = 't179-manager@test.local';
  select id into u_supervisor from auth.users where email = 't179-supervisor@test.local';
  select id into u_operator from auth.users where email = 't179-operator@test.local';

  insert into public.profiles (id, email)
  select id, email from auth.users where email like 't179-%@test.local'
  on conflict (id) do nothing;

  insert into public.system_admins (user_id, email, is_active)
  values (u_admin, 't179-admin@test.local', true);

  insert into public.vineyards (id, name, owner_id) values (vy_a, 'T179 Vineyard A', u_owner_a);
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (vy_a, u_owner_a, 'owner'),
    (vy_a, u_manager, 'manager'),
    (vy_a, u_supervisor, 'supervisor'),
    (vy_a, u_operator, 'operator');

  -- Integrations: cl_a active+healthy, cl_b active with auto-disabled endpoint,
  -- cl_old dormant (created 40 days ago, no activity).
  insert into public.integration_clients (id, owner_user_id, name, integration_type, status, created_by, created_at)
  values
    (cl_a, u_owner_a, 'T179 Integration A', 'custom_api', 'active', u_owner_a, now() - interval '2 days'),
    (cl_b, u_owner_b, 'T179 Integration B', 'custom_api', 'active', u_owner_b, now() - interval '3 days'),
    (cl_old, u_owner_b, 'T179 Integration Old', 'custom_api', 'active', u_owner_b, now() - interval '40 days');

  insert into public.integration_api_keys (id, integration_client_id, environment, key_prefix, key_hash, name, created_by)
  values
    (k_a1, cl_a, 'live', 'vt_live_00000a01', v_hash_a1, 'A live key', u_owner_a),
    (k_a2, cl_a, 'test', 'vt_test_00000a02', v_hash_a2, 'A test key', u_owner_a),
    (k_b1, cl_b, 'live', 'vt_live_00000b01', public._integration_hash_secret(v_plain_b), 'B live key', u_owner_b),
    (k_old, cl_old, 'live', 'vt_live_00000c01', v_hash_old, 'Old key', u_owner_b);

  insert into public.integration_client_vineyards (integration_client_id, vineyard_id, granted_by)
  values (cl_a, vy_a, u_owner_a);

  insert into public.integration_client_scopes (integration_client_id, scope, granted_by)
  values (cl_a, 'trips:read', u_owner_a);

  -- Baselines: pre-fixture state of the global tables the metrics RPCs read.
  -- now() is transaction-stable, so these windows match the RPCs' windows.
  select count(*),
         count(*) filter (where status_code = 429),
         count(*) filter (where status_code between 500 and 599),
         count(*) filter (where integration_client_id is null),
         count(distinct api_key_id)
    into b_req, b_rl, b_5xx, b_unauth, b_keys
  from public.integration_api_requests
  where created_at >= now() - interval '24 hours';

  select count(*),
         count(*) filter (where status = 'delivered'),
         count(*) filter (where status = 'failed'),
         count(*) filter (where status = 'pending'),
         count(*) filter (where status = 'pending' and attempt_count >= 1)
    into b_d_total, b_d_delivered, b_d_failed, b_d_pending, b_d_retry
  from public.webhook_deliveries
  where created_at >= now() - interval '24 hours';

  select count(*) filter (where a.error_category is not null)
    into b_att_failed
  from public.webhook_delivery_attempts a
  join public.webhook_deliveries d on d.id = a.delivery_id
  where a.attempted_at >= now() - interval '24 hours';

  select count(*)
    into b_ep_auto
  from public.webhook_endpoints
  where deleted_at is null
    and status = 'disabled'
    and disabled_reason = 'auto_disabled_after_consecutive_failures';

  -- API request log: cl_a gets 2x200, 1x429, 1x500; plus one unauthenticated 401.
  insert into public.integration_api_requests
    (integration_client_id, api_key_id, vineyard_id, method, path, status_code, duration_ms, error_code, request_id)
  values
    (cl_a, k_a1, vy_a, 'GET', '/v1/trips', 200, 42, null, 'req_' || md5('t179-r1')),
    (cl_a, k_a1, vy_a, 'GET', '/v1/trips', 200, 55, null, 'req_' || md5('t179-r2')),
    (cl_a, k_a1, null, 'GET', '/v1/me', 429, 3, 'rate_limit_exceeded', 'req_' || md5('t179-r3')),
    (cl_a, k_a1, vy_a, 'GET', '/v1/sprays', 500, 120, 'internal_error', 'req_' || md5('t179-r4')),
    (null, null, null, 'GET', '/v1/me', 401, 2, 'invalid_api_key', 'req_' || md5('t179-r5'));

  -- Webhook endpoints: ep_a healthy (URL has a query string to test masking),
  -- ep_b auto-disabled after consecutive failures.
  insert into public.webhook_endpoints
    (id, integration_client_id, url, status, signing_secret_hash, signing_secret_prefix,
     created_by, name, consecutive_failures)
  values
    (ep_a, cl_a, 'https://receiver.example.com/hooks/vinetrack?token=supersecretvalue', 'active',
     md5('t179-s1') || md5('t179-s1x'), 'whsec_t179aaaa', u_owner_a, 'A receiver', 0);

  insert into public.webhook_endpoints
    (id, integration_client_id, url, status, signing_secret_hash, signing_secret_prefix,
     created_by, name, consecutive_failures, disabled_at, disabled_reason, last_failure_at)
  values
    (ep_b, cl_b, 'https://receiver-b.example.com/hooks', 'disabled',
     md5('t179-s2') || md5('t179-s2x'), 'whsec_t179bbbb', u_owner_b, 'B receiver', 10,
     now() - interval '1 hour', 'auto_disabled_after_consecutive_failures', now() - interval '1 hour');

  select event into v_event
  from public.integration_webhook_event_catalog
  where is_system = false
  limit 1;
  if v_event is null then
    raise exception 'T0: no subscribable event in integration_webhook_event_catalog';
  end if;

  insert into public.webhook_subscriptions (webhook_endpoint_id, event_type)
  values (ep_a, v_event);

  -- Three distinct events: the partial unique index on webhook_deliveries
  -- allows only one original delivery per (event, endpoint).
  insert into public.integration_events (id, event_type, vineyard_id, resource_type, resource_id, occurred_at)
  values
    (ev1, v_event, vy_a, 't179_resource', gen_random_uuid(), now() - interval '2 hours'),
    (ev2, v_event, vy_a, 't179_resource', gen_random_uuid(), now() - interval '100 minutes'),
    (ev3, v_event, vy_a, 't179_resource', gen_random_uuid(), now() - interval '50 minutes');

  -- Deliveries: delivered, failed, pending-retry (all cl_a / ep_a).
  insert into public.webhook_deliveries
    (id, event_id, endpoint_id, integration_client_id, vineyard_id, status,
     attempt_count, next_attempt_at, delivered_at, failed_at, last_status_code, last_error_code, created_at)
  values
    (d1, ev1, ep_a, cl_a, vy_a, 'delivered', 1, now() - interval '2 hours',
     now() - interval '110 minutes', null, 200, null, now() - interval '2 hours'),
    (d2, ev2, ep_a, cl_a, vy_a, 'failed', 7, now() - interval '1 hour',
     null, now() - interval '30 minutes', 500, 'http_5xx', now() - interval '100 minutes'),
    (d3, ev3, ep_a, cl_a, vy_a, 'pending', 1, now() + interval '30 minutes',
     null, null, 503, 'http_5xx', now() - interval '50 minutes');

  insert into public.webhook_delivery_attempts
    (delivery_id, attempt_number, attempted_at, finished_at, http_status, duration_ms, error_category)
  values
    (d1, 1, now() - interval '110 minutes', now() - interval '110 minutes', 200, 150, null),
    (d2, 1, now() - interval '95 minutes', now() - interval '95 minutes', 500, 300, 'http_5xx'),
    (d3, 1, now() - interval '45 minutes', now() - interval '45 minutes', 503, 280, 'http_5xx');

  -- =========================================================================
  -- T1: objects exist
  -- =========================================================================
  if to_regprocedure('public._admin_integration_health(uuid)') is null
     or to_regprocedure('public._admin_mask_url(text)') is null
     or to_regprocedure('public.admin_get_integration(uuid)') is null
     or to_regprocedure('public.admin_get_integration_diagnostics(uuid)') is null
     or to_regprocedure('public.admin_integration_api_metrics(text, uuid, text)') is null
     or to_regprocedure('public.admin_webhook_metrics(text, uuid)') is null
     or to_regprocedure('public.admin_suspend_integration(uuid, text)') is null
     or to_regprocedure('public.admin_reactivate_integration(uuid)') is null
     or to_regprocedure('public.admin_revoke_integration_api_key(uuid, text)') is null
     or to_regprocedure('public.admin_set_webhook_endpoint_status(uuid, text, text)') is null then
    raise exception 'T1: expected SQL 179 functions missing';
  end if;
  select count(*) into v_count from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname in ('admin_list_integrations', 'admin_list_integration_api_requests',
                    'admin_list_webhook_endpoints', 'admin_list_webhook_deliveries',
                    'admin_list_integration_audit');
  if v_count <> 5 then
    raise exception 'T1: expected 5 admin list functions, found %', v_count;
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'public'
                 and indexname = 'idx_integration_api_requests_created_keyset')
     or not exists (select 1 from pg_indexes where schemaname = 'public'
                 and indexname = 'idx_webhook_deliveries_created_keyset')
     or not exists (select 1 from pg_indexes where schemaname = 'public'
                 and indexname = 'idx_integration_audit_created_keyset') then
    raise exception 'T1: expected SQL 179 indexes missing';
  end if;
  raise notice 'T1 passed';

  -- =========================================================================
  -- T2: anon denied (no execute privilege)
  -- =========================================================================
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'anon', true);
  v_failed := false;
  begin
    perform public.admin_list_integrations();
  exception when insufficient_privilege then v_failed := true;
  end;
  perform set_config('role', 'postgres', true);
  if not v_failed then raise exception 'T2: anon was not denied'; end if;
  raise notice 'T2 passed';

  -- =========================================================================
  -- T3: non-admin authenticated users denied
  -- =========================================================================
  foreach e in array array[
    u_owner_a::text, u_owner_b::text, u_manager::text, u_supervisor::text, u_operator::text
  ] loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', e, 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);

    v_failed := false;
    begin
      perform public.admin_list_integrations();
    exception when insufficient_privilege then v_failed := true;
    end;
    if not v_failed then raise exception 'T3: user % not denied on list', e; end if;

    v_failed := false;
    begin
      perform public.admin_suspend_integration(cl_a, 'nope');
    exception when insufficient_privilege then v_failed := true;
    end;
    if not v_failed then raise exception 'T3: user % not denied on suspend', e; end if;

    v_failed := false;
    begin
      perform public.admin_get_integration_diagnostics(cl_a);
    exception when insufficient_privilege then v_failed := true;
    end;
    if not v_failed then raise exception 'T3: user % not denied on diagnostics', e; end if;

    perform set_config('role', 'postgres', true);
  end loop;
  raise notice 'T3 passed';

  -- =========================================================================
  -- T4: service_role denied (no execute grant on the admin surface)
  -- =========================================================================
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    perform set_config('request.jwt.claims',
      json_build_object('role', 'service_role')::text, true);
    perform set_config('role', 'service_role', true);
    v_failed := false;
    begin
      perform public.admin_list_integrations();
    exception when others then v_failed := true;  -- insufficient_privilege or admin gate
    end;
    perform set_config('role', 'postgres', true);
    if not v_failed then raise exception 'T4: service_role was not denied'; end if;
    raise notice 'T4 passed';
  else
    raise notice 'T4 skipped (no service_role role in this database)';
  end if;

  -- =========================================================================
  -- Switch to platform admin for the remaining tests
  -- =========================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- =========================================================================
  -- T5: admin list — rows, counts, safety
  -- =========================================================================
  v := public.admin_list_integrations();
  if jsonb_array_length(v -> 'data') < 3 then
    raise exception 'T5: expected >= 3 integrations, got %', jsonb_array_length(v -> 'data');
  end if;

  -- Fixture-scoped page (the live DB may have more than a page of integrations)
  v := public.admin_list_integrations(p_owner_query => 't179');
  select x into v_row from jsonb_array_elements(v -> 'data') x
  where x ->> 'id' = cl_a::text;
  if v_row is null then raise exception 'T5: cl_a missing from list'; end if;
  if (v_row #>> '{counts,vineyard_grants}')::integer <> 1
     or (v_row #>> '{counts,scopes}')::integer <> 1
     or (v_row #>> '{counts,api_keys}')::integer <> 2
     or (v_row #>> '{counts,active_api_keys}')::integer <> 2
     or (v_row #>> '{counts,webhook_endpoints}')::integer <> 1 then
    raise exception 'T5: cl_a counts wrong: %', v_row -> 'counts';
  end if;
  if v_row #>> '{owner,email}' <> 't179-owner-a@test.local' then
    raise exception 'T5: owner display wrong';
  end if;

  v_text := v::text;
  if v_text like '%key_hash%' or v_text like '%signing_secret%' or v_text like '%secret_ref%'
     or position(v_hash_a1 in v_text) > 0 or position(v_plain_b in v_text) > 0 then
    raise exception 'T5: list output leaks credential material';
  end if;
  raise notice 'T5 passed';

  -- =========================================================================
  -- T6: filters
  -- =========================================================================
  v := public.admin_list_integrations(p_environment => 'test', p_owner_query => 't179');
  if jsonb_array_length(v -> 'data') <> 1
     or (v -> 'data' -> 0 ->> 'id') <> cl_a::text then
    raise exception 'T6: environment=test filter wrong';
  end if;

  v := public.admin_list_integrations(p_vineyard_id => vy_a);
  if jsonb_array_length(v -> 'data') <> 1
     or (v -> 'data' -> 0 ->> 'id') <> cl_a::text then
    raise exception 'T6: vineyard filter wrong';
  end if;

  v := public.admin_list_integrations(p_owner_query => 't179-owner-b');
  select count(*) into v_count from jsonb_array_elements(v -> 'data') x
  where x ->> 'id' in (cl_b::text, cl_old::text);
  if v_count <> 2 then raise exception 'T6: owner query filter wrong'; end if;

  v := public.admin_list_integrations(p_rate_limited_only => true, p_owner_query => 't179');
  select count(*) into v_count from jsonb_array_elements(v -> 'data') x
  where x ->> 'id' = cl_a::text;
  if v_count <> 1 then raise exception 'T6: rate_limited_only filter wrong'; end if;

  v_failed := false;
  begin
    v := public.admin_list_integrations(p_status => 'bogus');
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T6: invalid status not rejected'; end if;
  raise notice 'T6 passed';

  -- =========================================================================
  -- T7: keyset pagination + invalid cursor
  -- =========================================================================
  v := public.admin_list_integrations(p_limit => 1);
  if jsonb_array_length(v -> 'data') <> 1
     or (v #>> '{pagination,has_more}')::boolean is distinct from true
     or (v #>> '{pagination,next_before_id}') is null then
    raise exception 'T7: first page wrong';
  end if;
  v2 := public.admin_list_integrations(
          p_limit => 1,
          p_before_created_at => (v #>> '{pagination,next_before_created_at}')::timestamptz,
          p_before_id => (v #>> '{pagination,next_before_id}')::uuid);
  if (v2 -> 'data' -> 0 ->> 'id') = (v -> 'data' -> 0 ->> 'id') then
    raise exception 'T7: pages overlap';
  end if;

  v_failed := false;
  begin
    v2 := public.admin_list_integrations(p_before_id => cl_a);  -- half a cursor
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T7: invalid cursor not rejected'; end if;
  raise notice 'T7 passed';

  -- =========================================================================
  -- T8: health classification
  -- =========================================================================
  v := public.admin_list_integrations(p_owner_query => 't179');
  select x into v_row from jsonb_array_elements(v -> 'data') x where x ->> 'id' = cl_a::text;
  if v_row #>> '{health,classification}' <> 'healthy' then
    raise exception 'T8: cl_a expected healthy, got % (%)',
      v_row #>> '{health,classification}', v_row #> '{health,reasons}';
  end if;
  select x into v_row from jsonb_array_elements(v -> 'data') x where x ->> 'id' = cl_old::text;
  if v_row #>> '{health,classification}' <> 'inactive' then
    raise exception 'T8: cl_old expected inactive, got %', v_row #>> '{health,classification}';
  end if;
  select x into v_row from jsonb_array_elements(v -> 'data') x where x ->> 'id' = cl_b::text;
  if v_row #>> '{health,classification}' <> 'critical'
     or not (v_row #> '{health,reasons}') ? 'webhook_endpoint_auto_disabled' then
    raise exception 'T8: cl_b expected critical/auto_disabled, got % (%)',
      v_row #>> '{health,classification}', v_row #> '{health,reasons}';
  end if;

  v := public.admin_list_integrations(p_health => 'critical', p_owner_query => 't179');
  if jsonb_array_length(v -> 'data') <> 1
     or (v -> 'data' -> 0 ->> 'id') <> cl_b::text then
    raise exception 'T8: health filter wrong';
  end if;
  raise notice 'T8 passed';

  -- =========================================================================
  -- T9: API metrics
  -- =========================================================================
  -- Baseline-relative: the fixture adds 5 requests (2x200, 1x429, 1x500,
  -- 1 unauthenticated 401) using exactly one new api key (k_a1).
  v := public.admin_integration_api_metrics('24h');
  if (v #>> '{totals,requests}')::integer <> b_req + 5
     or (v #>> '{totals,rate_limited}')::integer <> b_rl + 1
     or (v #>> '{totals,server_error_5xx}')::integer <> b_5xx + 1
     or (v #>> '{totals,unauthenticated}')::integer <> b_unauth + 1
     or (v #>> '{totals,unique_api_keys}')::integer <> b_keys + 1
     or (v #>> '{totals,avg_duration_ms}') is null
     or (v #>> '{totals,p95_duration_ms}') is null then
    raise exception 'T9: totals wrong (baseline req=% rl=% 5xx=% unauth=% keys=%): %',
      b_req, b_rl, b_5xx, b_unauth, b_keys, v -> 'totals';
  end if;

  v := public.admin_integration_api_metrics('24h', null, 'integration');
  if jsonb_array_length(v -> 'breakdown') < 2 then  -- cl_a + unauthenticated
    raise exception 'T9: integration breakdown wrong: %', v -> 'breakdown';
  end if;
  v := public.admin_integration_api_metrics('7d', cl_a, 'day');
  if jsonb_array_length(v -> 'breakdown') < 1 then
    raise exception 'T9: day breakdown wrong';
  end if;

  v_failed := false;
  begin
    v := public.admin_integration_api_metrics('12h');
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T9: invalid window not rejected'; end if;
  raise notice 'T9 passed';

  -- =========================================================================
  -- T10: request-log listing
  -- =========================================================================
  v := public.admin_list_integration_api_requests();
  if jsonb_array_length(v -> 'data') < 5 then
    raise exception 'T10: expected >= 5 request rows';
  end if;

  -- Fixture rows are the newest in the table (created_at = now()), so they are
  -- always on the first page; assertions are presence-based, not count-based,
  -- because the live DB has its own log rows.
  v := public.admin_list_integration_api_requests(p_unauthenticated_only => true);
  select x into v_row from jsonb_array_elements(v -> 'data') x
  where x ->> 'request_id' = 'req_' || md5('t179-r5');
  if v_row is null
     or (v_row -> 'integration_client_id') <> 'null'::jsonb
     or (v_row ->> 'error_code') <> 'invalid_api_key' then
    raise exception 'T10: unauthenticated filter wrong';
  end if;
  select count(*) into v_count from jsonb_array_elements(v -> 'data') x
  where (x -> 'integration_client_id') <> 'null'::jsonb;
  if v_count <> 0 then
    raise exception 'T10: unauthenticated filter returned authenticated rows';
  end if;

  v := public.admin_list_integration_api_requests(p_rate_limited_only => true);
  select x into v_row from jsonb_array_elements(v -> 'data') x
  where x ->> 'request_id' = 'req_' || md5('t179-r3');
  if v_row is null then raise exception 'T10: rate_limited fixture row missing'; end if;
  select count(*) into v_count from jsonb_array_elements(v -> 'data') x
  where (x ->> 'status_code')::integer <> 429;
  if v_count <> 0 then raise exception 'T10: rate_limited filter wrong'; end if;

  v := public.admin_list_integration_api_requests(p_errors_only => true);
  select count(*) into v_count from jsonb_array_elements(v -> 'data') x
  where x ->> 'request_id' in
    ('req_' || md5('t179-r3'), 'req_' || md5('t179-r4'), 'req_' || md5('t179-r5'));
  if v_count <> 3 then
    raise exception 'T10: errors_only expected 3 fixture rows, got %', v_count;
  end if;
  select count(*) into v_count from jsonb_array_elements(v -> 'data') x
  where (x ->> 'status_code')::integer < 400;
  if v_count <> 0 then raise exception 'T10: errors_only returned non-error rows'; end if;

  v := public.admin_list_integration_api_requests(p_client_id => cl_a, p_status_class => '2xx');
  if jsonb_array_length(v -> 'data') <> 2
     or (v -> 'data' -> 0 ->> 'api_key_prefix') <> 'vt_live_00000a01' then
    raise exception 'T10: client/status_class filter wrong';
  end if;

  v_text := v::text;
  if v_text like '%key_hash%' or v_text like '%authorization%' or v_text like '%request_body%'
     or position(v_hash_a1 in v_text) > 0 then
    raise exception 'T10: request listing leaks sensitive material';
  end if;
  raise notice 'T10 passed';

  -- =========================================================================
  -- T11: webhook metrics
  -- =========================================================================
  -- Baseline-relative: fixture adds 3 deliveries (delivered/failed/pending-
  -- retry), 2 failed attempts and 1 auto-disabled endpoint on top of live data.
  v := public.admin_webhook_metrics('24h');
  if (v #>> '{deliveries,total}')::integer <> b_d_total + 3
     or (v #>> '{deliveries,delivered}')::integer <> b_d_delivered + 1
     or (v #>> '{deliveries,failed}')::integer <> b_d_failed + 1
     or (v #>> '{deliveries,pending}')::integer <> b_d_pending + 1
     or (v #>> '{deliveries,retry_scheduled}')::integer <> b_d_retry + 1 then
    raise exception 'T11: delivery counts wrong (baseline total=%): %',
      b_d_total, v -> 'deliveries';
  end if;
  if (v #>> '{endpoints,auto_disabled}')::integer <> b_ep_auto + 1 then
    raise exception 'T11: auto_disabled count wrong (baseline %): %',
      b_ep_auto, v -> 'endpoints';
  end if;
  if (v #>> '{attempts,failed}')::integer <> b_att_failed + 2 then
    raise exception 'T11: failed attempts wrong (baseline %): %',
      b_att_failed, v -> 'attempts';
  end if;
  if v #>> '{oldest_pending_delivery,public_id}' is null then
    raise exception 'T11: oldest pending delivery missing';
  end if;
  select count(*) into v_count from jsonb_array_elements(v -> 'integrations_with_problems') x
  where x ->> 'integration_client_id' = cl_b::text;
  if v_count <> 1 then
    raise exception 'T11: cl_b missing from integrations_with_problems';
  end if;
  raise notice 'T11 passed';

  -- =========================================================================
  -- T12: endpoint diagnostics — masking + safety + failing filter
  -- =========================================================================
  -- Client-scoped (the live DB has its own endpoints)
  v := public.admin_list_webhook_endpoints(p_client_id => cl_a);
  if jsonb_array_length(v -> 'data') <> 1 then
    raise exception 'T12: expected 1 endpoint for cl_a';
  end if;
  v_row := v -> 'data' -> 0;
  if v_row ->> 'url' <> 'https://receiver.example.com/hooks/vinetrack?[redacted]' then
    raise exception 'T12: URL not masked: %', v_row ->> 'url';
  end if;

  v2 := public.admin_list_webhook_endpoints(p_client_id => cl_b);
  if jsonb_array_length(v2 -> 'data') <> 1 then
    raise exception 'T12: expected 1 endpoint for cl_b';
  end if;

  v_text := v::text || v2::text;
  if v_text like '%supersecretvalue%' or v_text like '%signing_secret%'
     or v_text like '%whsec_t179%' or v_text like '%secret_ref%' then
    raise exception 'T12: endpoint listing leaks secrets';
  end if;

  v := public.admin_list_webhook_endpoints(p_failing_only => true, p_client_id => cl_b);
  if jsonb_array_length(v -> 'data') <> 1
     or (v -> 'data' -> 0 ->> 'id') <> ep_b::text
     or (v -> 'data' -> 0 ->> 'disabled_reason') <> 'auto_disabled_after_consecutive_failures' then
    raise exception 'T12: failing_only filter wrong';
  end if;
  v := public.admin_list_webhook_endpoints(p_failing_only => true, p_client_id => cl_a);
  if jsonb_array_length(v -> 'data') <> 0 then
    raise exception 'T12: failing_only returned healthy endpoint';
  end if;
  raise notice 'T12 passed';

  -- =========================================================================
  -- T13: delivery diagnostics
  -- =========================================================================
  -- Client-scoped (the live DB has its own deliveries)
  v := public.admin_list_webhook_deliveries(p_client_id => cl_a);
  if jsonb_array_length(v -> 'data') <> 3 then
    raise exception 'T13: expected 3 deliveries for cl_a';
  end if;
  v := public.admin_list_webhook_deliveries(p_client_id => cl_a, p_status => 'failed');
  if jsonb_array_length(v -> 'data') <> 1
     or (v -> 'data' -> 0 ->> 'public_id') is null
     or (v -> 'data' -> 0 ->> 'event_type') <> v_event
     or (v -> 'data' -> 0 ->> 'last_error_code') <> 'http_5xx' then
    raise exception 'T13: failed delivery row wrong';
  end if;
  if (v -> 'data' -> 0) ? 'payload' or (v -> 'data' -> 0) ? 'response_body' then
    raise exception 'T13: delivery row exposes payload/response';
  end if;
  raise notice 'T13 passed';

  -- =========================================================================
  -- T14: diagnostics snapshot
  -- =========================================================================
  v := public.admin_get_integration_diagnostics(cl_a);
  if not (v ? 'integration' and v ? 'owner' and v ? 'health' and v ? 'vineyard_grants'
          and v ? 'scopes' and v ? 'api_keys' and v ? 'webhook_endpoints'
          and v ? 'api_activity' and v ? 'webhook_activity' and v ? 'recent_audit') then
    raise exception 'T14: diagnostics missing keys';
  end if;
  if (v #>> '{api_activity,window_24h,requests}')::integer <> 4
     or (v #>> '{api_activity,window_24h,rate_limited}')::integer <> 1 then
    raise exception 'T14: api_activity wrong: %', v -> 'api_activity';
  end if;
  if (v #>> '{webhook_activity,pending_deliveries}')::integer <> 1
     or (v #>> '{webhook_activity,retrying_deliveries}')::integer <> 1 then
    raise exception 'T14: webhook_activity wrong: %', v -> 'webhook_activity';
  end if;
  v_text := v::text;
  if v_text like '%key_hash%' or v_text like '%signing_secret%'
     or position(v_hash_a1 in v_text) > 0 or v_text like '%supersecretvalue%' then
    raise exception 'T14: diagnostics leak sensitive material';
  end if;
  raise notice 'T14 passed';

  -- =========================================================================
  -- T15: suspend / suspended behaviour / helper boundary / reactivate
  -- =========================================================================
  v := public.admin_suspend_integration(cl_b, 'abuse investigation');
  if v ->> 'status' <> 'paused' then raise exception 'T15: suspend result wrong'; end if;
  -- direct table verification requires postgres (authenticated has no table grants)
  perform set_config('role', 'postgres', true);
  if not exists (select 1 from public.integration_clients
                 where id = cl_b and status = 'paused' and paused_at is not null) then
    raise exception 'T15: cl_b not paused';
  end if;
  if not exists (select 1 from public.integration_audit_log
                 where integration_client_id = cl_b
                   and action = 'integration.paused'
                   and actor_user_id = u_admin
                   and metadata ->> 'platform_admin' = 'true'
                   and metadata ->> 'reason' = 'abuse investigation') then
    raise exception 'T15: suspend audit record missing';
  end if;
  perform set_config('role', 'authenticated', true);

  -- double suspend rejected
  v_failed := false;
  begin
    v := public.admin_suspend_integration(cl_b, 'again');
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T15: double suspend not rejected'; end if;

  -- suspended integration fails API authentication safely
  perform set_config('role', 'postgres', true);
  v := public.integration_authenticate_api_key(v_plain_b);
  if (v ->> 'valid')::boolean is distinct from false
     or v ->> 'failure_code' <> 'integration_not_active' then
    raise exception 'T15: suspended integration auth did not fail safely: %', v;
  end if;
  perform set_config('role', 'authenticated', true);

  -- internal health helper is NOT directly callable by authenticated
  v_failed := false;
  begin
    perform public._admin_integration_health(cl_b);
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T15: _admin_integration_health callable by authenticated';
  end if;

  -- health of the suspended integration via the admin surface
  v := public.admin_get_integration(cl_b);
  if v #>> '{health,classification}' <> 'critical'
     or not (v #> '{health,reasons}') ? 'integration_suspended' then
    raise exception 'T15: suspended health wrong: %', v -> 'health';
  end if;

  -- reactivate
  v := public.admin_reactivate_integration(cl_b);
  if v ->> 'status' <> 'active' then raise exception 'T15: reactivate result wrong'; end if;
  perform set_config('role', 'postgres', true);
  if not exists (select 1 from public.integration_clients
                 where id = cl_b and status = 'active' and paused_at is null) then
    raise exception 'T15: cl_b not reactivated';
  end if;
  if not exists (select 1 from public.integration_audit_log
                 where integration_client_id = cl_b
                   and action = 'integration.reactivated'
                   and metadata ->> 'platform_admin' = 'true') then
    raise exception 'T15: reactivate audit record missing';
  end if;
  perform set_config('role', 'authenticated', true);
  raise notice 'T15 passed';

  -- =========================================================================
  -- T16: admin key revocation
  -- =========================================================================
  v := public.admin_revoke_integration_api_key(k_a2, 'compromised in support ticket');
  if v ->> 'status' <> 'revoked' or v ->> 'key_prefix' <> 'vt_test_00000a02' then
    raise exception 'T16: revoke result wrong';
  end if;
  perform set_config('role', 'postgres', true);
  if not exists (select 1 from public.integration_api_keys
                 where id = k_a2 and revoked_at is not null) then
    raise exception 'T16: key not revoked';
  end if;
  if not exists (select 1 from public.integration_audit_log
                 where integration_client_id = cl_a
                   and action = 'api_key.revoked'
                   and metadata ->> 'platform_admin' = 'true'
                   and metadata ->> 'key_prefix' = 'vt_test_00000a02') then
    raise exception 'T16: revoke audit record missing';
  end if;
  perform set_config('role', 'authenticated', true);

  v_failed := false;
  begin
    v := public.admin_revoke_integration_api_key(k_a2);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T16: double revoke not rejected'; end if;

  -- active key count reflects revocation
  v := public.admin_get_integration(cl_a);
  select count(*) into v_count from jsonb_array_elements(v -> 'api_keys') x
  where x ->> 'status' = 'active';
  if v_count <> 1 then raise exception 'T16: active key count wrong'; end if;
  raise notice 'T16 passed';

  -- =========================================================================
  -- T17: endpoint pause / reactivate-from-disabled
  -- =========================================================================
  v := public.admin_set_webhook_endpoint_status(ep_a, 'paused', 'receiver maintenance');
  if v ->> 'status' <> 'paused' then raise exception 'T17: pause result wrong'; end if;
  perform set_config('role', 'postgres', true);
  if not exists (select 1 from public.webhook_endpoints
                 where id = ep_a and status = 'paused' and paused_at is not null) then
    raise exception 'T17: ep_a not paused';
  end if;
  if not exists (select 1 from public.integration_audit_log
                 where integration_client_id = cl_a
                   and action = 'webhook_endpoint.paused'
                   and metadata ->> 'platform_admin' = 'true') then
    raise exception 'T17: pause audit record missing';
  end if;
  perform set_config('role', 'authenticated', true);

  v := public.admin_set_webhook_endpoint_status(ep_b, 'active', 'receiver fixed');
  perform set_config('role', 'postgres', true);
  if not exists (select 1 from public.webhook_endpoints
                 where id = ep_b and status = 'active'
                   and disabled_at is null and disabled_reason is null
                   and consecutive_failures = 0) then
    raise exception 'T17: ep_b reactivation did not clear disable state';
  end if;
  if not exists (select 1 from public.integration_audit_log
                 where integration_client_id = cl_b
                   and action = 'webhook_endpoint.reactivated'
                   and metadata ->> 'platform_admin' = 'true') then
    raise exception 'T17: reactivate audit record missing';
  end if;
  perform set_config('role', 'authenticated', true);

  v_failed := false;
  begin
    v := public.admin_set_webhook_endpoint_status(ep_b, 'disabled');
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T17: invalid target status not rejected'; end if;
  raise notice 'T17 passed';

  -- =========================================================================
  -- T18: audit listing
  -- =========================================================================
  v := public.admin_list_integration_audit();
  if jsonb_array_length(v -> 'data') < 6 then
    raise exception 'T18: expected >= 6 audit rows, got %', jsonb_array_length(v -> 'data');
  end if;

  v := public.admin_list_integration_audit(p_client_id => cl_b);
  select count(*) into v_count from jsonb_array_elements(v -> 'data') x
  where x ->> 'integration_client_id' <> cl_b::text;
  if v_count <> 0 then raise exception 'T18: client filter leaked other rows'; end if;

  v := public.admin_list_integration_audit(p_action => 'integration.paused');
  if jsonb_array_length(v -> 'data') < 1 then
    raise exception 'T18: action filter returned nothing';
  end if;
  select x into v_row from jsonb_array_elements(v -> 'data') x
  where x ->> 'integration_client_id' = cl_b::text
  limit 1;
  if v_row ->> 'actor_type' <> 'platform_admin'
     or v_row ->> 'actor_email' <> 't179-admin@test.local' then
    raise exception 'T18: actor attribution wrong: %', v_row;
  end if;
  raise notice 'T18 passed';

  perform set_config('role', 'postgres', true);
  raise notice 'SQL 179 integration platform admin tests: ALL PASSED';
end$$;

rollback;

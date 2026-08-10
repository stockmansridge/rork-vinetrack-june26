-- =====================================================================
-- 178_integration_webhook_platform_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/178_integration_webhook_platform.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted (claim locks taken on
-- production-pending deliveries, if any existed, are released on rollback).
--
-- Requires Supabase Vault (vault.create_secret) — present on all hosted
-- Supabase projects.
--
-- Test map
--   T1  Objects exist: 3 new tables, catalogue webhook.test (is_system),
--       endpoint lifecycle columns, management + dispatcher functions,
--       event triggers on all 11 canonical tables
--   T2  Direct table access denied to authenticated clients
--       (integration_events / webhook_deliveries / attempts unreadable)
--   T3  Endpoint creation: HTTPS-only + SSRF matrix (http, localhost,
--       IP literals, decimal/hex IPs, internal suffixes, ports, userinfo,
--       single-label hosts all refused); 10-endpoint cap enforced
--   T4  Secret handling: whsec_ one-time secret, only SHA-256 hash +
--       prefix in the table, plaintext in NO column and NO audit row,
--       Vault reference set; rotation swaps hash immediately
--   T5  Authority: Owner B gets webhook_endpoint_not_found for A's
--       endpoint (no probing); Manager can VIEW endpoint + deliveries
--       but cannot create/rotate/pause/delete/subscribe;
--       Supervisor/Operator have nothing
--   T6  Subscriptions: unknown event refused; webhook.test refused;
--       missing scope refused INDEPENDENTLY of vineyard grant;
--       non-granted vineyard restriction refused; duplicate refused
--   T7  Emission fast-exit: writes on a NEVER-granted vineyard store
--       NO event rows at all
--   T8  Trip lifecycle: created / completed / updated transitions;
--       live-tracking (is_active) updates suppressed; already-finished
--       insert emits ONLY trip.completed; same-transaction duplicate
--       updates dedup to ONE event
--   T9  Fan-out: completed trip → exactly ONE pending delivery even with
--       overlapping all-vineyards + vineyard-specific subscriptions;
--       events without subscriptions get NO delivery; paused endpoint
--       receives NO new deliveries at emit time
--   T10 Every resource family emits exactly one correct event:
--       spray_job.completed (template rows silent), fuel_purchase.created,
--       fuel_log.created/updated, work_task.created/completed(finalise),
--       pruning_activity.created, irrigation_record.created,
--       growth_stage.recorded, yield_record.created, pin.created/resolved,
--       block.created
--   T11 Outbox atomicity: rolled-back operational write leaves NO event
--   T12 integration_events is immutable (UPDATE/DELETE blocked)
--   T13 Dispatcher claim: envelope shape (evt_/dlv_ ids, ISO occurred_at,
--       data payload); claimed rows are not claimable twice; expired
--       lease is reclaimable; successful attempt → delivered + endpoint
--       health reset + attempt row
--   T14 Retry machinery: wrong claim token refused; retryable failure →
--       pending with ~1 minute backoff; Retry-After widens the gap;
--       permanent 4xx fails immediately; attempt 7 fails terminally
--   T15 Auto-disable: 10th consecutive failure disables the endpoint +
--       audit row (actor null); queued deliveries cancel at claim time;
--       owner reactivation resets health counters
--   T16 Pause & revocation: paused endpoint defers claims (+5 min,
--       nothing lost); revoked scope cancels at claim (scope_revoked);
--       revoked vineyard grant cancels at claim (vineyard_grant_revoked)
--       and blocks replay (replay_not_allowed)
--   T17 Test webhook + replay: webhook.test event with is_test delivery
--       claimable without any grants; replay of a delivered delivery
--       creates a NEW pending delivery with a NEW public id (audited)
--   T18 Management surface: delivery list (filters + keyset shape) and
--       detail (attempt history) for owner and manager; Owner B refused;
--       endpoint delete cancels queue + clears Vault ref; audit log
--       carries every webhook action and stays append-only
--
-- Expected final output:
--   NOTICE: SQL 178 webhook platform tests: ALL PASSED
-- =====================================================================

begin;

do $$
declare
  u_owner_a uuid;
  u_owner_b uuid;
  u_mgr     uuid;
  u_sup     uuid;
  u_op      uuid;

  v_va  uuid := gen_random_uuid();  -- vineyard A (granted to the integration)
  v_va2 uuid := gen_random_uuid();  -- second vineyard owned by A (NEVER granted)
  v_vb  uuid := gen_random_uuid();  -- vineyard B (owner B)

  c_a uuid := gen_random_uuid();    -- Owner A's integration client
  ep1 uuid;                         -- endpoint under test
  ep1_secret text;
  ep1_secret2 text;
  sub_all uuid;                     -- trip.completed, all vineyards
  sub_va  uuid;                     -- trip.completed, restricted to VA

  j jsonb;
  jd jsonb;
  v_failed boolean;
  v_err text;
  n integer;
  i integer;

  trip1 uuid := gen_random_uuid();
  trip2 uuid := gen_random_uuid();
  trip3 uuid := gen_random_uuid();
  trip_ghost uuid := gen_random_uuid();
  spray1 uuid := gen_random_uuid();
  spray_tpl uuid := gen_random_uuid();
  fuelp1 uuid := gen_random_uuid();
  fuellog1 uuid := gen_random_uuid();
  task1 uuid := gen_random_uuid();
  prune1 uuid := gen_random_uuid();
  irrsys1 uuid := gen_random_uuid();
  irrvalve1 uuid := gen_random_uuid();
  irr1 uuid := gen_random_uuid();
  growth1 uuid := gen_random_uuid();
  yield1 uuid := gen_random_uuid();
  pin1 uuid := gen_random_uuid();
  block1 uuid := gen_random_uuid();

  d_first uuid;                     -- first fan-out delivery (T9/T13)
  d_tmp uuid;
  d_tmp2 uuid;
  d3 uuid;
  d4 uuid;
  d5 uuid;
  d6 uuid;
  d_test uuid;
  v_token uuid;
  v_evt uuid;
  v_pub text;
  v_ref uuid;
  v_delta numeric;
  ts1 timestamptz;
begin
  -- =====================================================================
  -- Fixtures
  -- =====================================================================
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array[
    't178-owner-a@test.local', 't178-owner-b@test.local', 't178-mgr@test.local',
    't178-sup@test.local',     't178-op@test.local'
  ]) e;

  select id into u_owner_a from auth.users where email = 't178-owner-a@test.local';
  select id into u_owner_b from auth.users where email = 't178-owner-b@test.local';
  select id into u_mgr     from auth.users where email = 't178-mgr@test.local';
  select id into u_sup     from auth.users where email = 't178-sup@test.local';
  select id into u_op      from auth.users where email = 't178-op@test.local';

  insert into public.profiles (id, email) values
    (u_owner_a, 't178-owner-a@test.local'),
    (u_owner_b, 't178-owner-b@test.local'),
    (u_mgr,     't178-mgr@test.local'),
    (u_sup,     't178-sup@test.local'),
    (u_op,      't178-op@test.local');

  insert into public.vineyards (id, name, owner_id) values
    (v_va,  'T178 Vineyard A',  u_owner_a),
    (v_va2, 'T178 Vineyard A2', u_owner_a),
    (v_vb,  'T178 Vineyard B',  u_owner_b);

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_va,  u_owner_a, 'owner'),
    (v_va,  u_mgr,     'manager'),
    (v_va,  u_sup,     'supervisor'),
    (v_va,  u_op,      'operator'),
    (v_va2, u_owner_a, 'owner'),
    (v_vb,  u_owner_b, 'owner');

  -- integration client owned by A, VA granted, trips:read granted
  -- (management RPC paths for these are already covered by SQL 172 tests)
  insert into public.integration_clients (id, owner_user_id, name, integration_type, created_by)
  values (c_a, u_owner_a, 'T178 Webhook Consumer', 'custom_webhook', u_owner_a);
  insert into public.integration_client_vineyards (integration_client_id, vineyard_id, granted_by)
  values (c_a, v_va, u_owner_a);
  insert into public.integration_client_scopes (integration_client_id, scope, granted_by)
  values (c_a, 'trips:read', u_owner_a);

  -- ---------------------------------------------------------------
  -- T1: objects exist
  -- ---------------------------------------------------------------
  if to_regclass('public.integration_events') is null
     or to_regclass('public.webhook_deliveries') is null
     or to_regclass('public.webhook_delivery_attempts') is null then
    raise exception 'T1: a Stage-5A table is missing';
  end if;

  select count(*) into n from public.integration_webhook_event_catalog
  where event = 'webhook.test' and is_system;
  if n <> 1 then raise exception 'T1: webhook.test system event missing'; end if;

  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'webhook_endpoints'
    and column_name in ('name', 'secret_ref', 'last_success_at', 'last_failure_at',
                        'consecutive_failures', 'paused_at', 'disabled_at',
                        'disabled_reason', 'deleted_at');
  if n <> 9 then raise exception 'T1: webhook_endpoints lifecycle columns missing (%)', n; end if;

  if to_regprocedure('public.integration_list_webhook_endpoints(uuid)') is null
     or to_regprocedure('public.integration_get_webhook_endpoint(uuid)') is null
     or to_regprocedure('public.integration_create_webhook_endpoint(uuid, text, text)') is null
     or to_regprocedure('public.integration_update_webhook_endpoint(uuid, text, text)') is null
     or to_regprocedure('public.integration_set_webhook_endpoint_status(uuid, text)') is null
     or to_regprocedure('public.integration_delete_webhook_endpoint(uuid)') is null
     or to_regprocedure('public.integration_rotate_webhook_secret(uuid)') is null
     or to_regprocedure('public.integration_list_webhook_subscriptions(uuid)') is null
     or to_regprocedure('public.integration_create_webhook_subscription(uuid, text, uuid)') is null
     or to_regprocedure('public.integration_delete_webhook_subscription(uuid)') is null
     or to_regprocedure('public.integration_send_test_webhook(uuid)') is null
     or to_regprocedure('public.integration_replay_webhook_delivery(uuid)') is null
     or to_regprocedure('public.integration_list_webhook_deliveries(uuid, uuid, text, text, uuid, timestamptz, timestamptz, integer, timestamptz, uuid)') is null
     or to_regprocedure('public.integration_get_webhook_delivery(uuid)') is null
     or to_regprocedure('public.integration_webhook_claim_deliveries(integer, integer)') is null
     or to_regprocedure('public.integration_webhook_get_endpoint_secret(uuid)') is null
     or to_regprocedure('public.integration_webhook_record_attempt(uuid, uuid, text, integer, integer, text, text, integer)') is null then
    raise exception 'T1: a Stage-5A function is missing';
  end if;

  select count(*) into n
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  where not t.tgisinternal
    and t.tgname like 'trg_integration_evt_%'
    and c.relname in ('trips', 'spray_records', 'fuel_purchases', 'tractor_fuel_logs',
                      'work_tasks', 'pruning_activities', 'irrigation_sessions',
                      'growth_stage_records', 'historical_yield_records', 'pins', 'paddocks');
  if n <> 11 then raise exception 'T1: expected 11 event triggers, found %', n; end if;
  raise notice 'T1 passed';

  -- ---------------------------------------------------------------
  -- T2: direct table access denied to authenticated clients
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  v_failed := false;
  begin
    perform 1 from public.integration_events;
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T2: integration_events readable directly'; end if;

  v_failed := false;
  begin
    perform 1 from public.webhook_deliveries;
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T2: webhook_deliveries readable directly'; end if;

  v_failed := false;
  begin
    perform 1 from public.webhook_delivery_attempts;
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T2: webhook_delivery_attempts readable directly'; end if;

  v_failed := false;
  begin
    insert into public.integration_events (event_type, vineyard_id, resource_type, resource_id)
    values ('trip.created', v_va, 'trip', gen_random_uuid());
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T2: integration_events writable directly'; end if;

  perform set_config('role', 'postgres', true);
  raise notice 'T2 passed';

  -- ---------------------------------------------------------------
  -- T3: endpoint creation — HTTPS-only + SSRF matrix + cap
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  j := public.integration_create_webhook_endpoint(c_a, 'https://hooks.example.com/vinetrack', 'Primary hook');
  ep1 := (j ->> 'id')::uuid;
  ep1_secret := j ->> 'signing_secret';
  if ep1 is null or ep1_secret is null then
    raise exception 'T3: endpoint creation did not return id + signing_secret';
  end if;

  declare
    bad_urls text[] := array[
      'http://hooks.example.com/x',            -- not HTTPS
      'https://localhost/x',                   -- loopback name
      'https://api.localhost/x',
      'https://127.0.0.1/x',                   -- loopback IP
      'https://10.0.0.8/x',                    -- RFC1918
      'https://172.16.4.2/x',
      'https://192.168.1.10/x',
      'https://169.254.169.254/latest/meta-data', -- cloud metadata
      'https://2130706433/x',                  -- decimal IP
      'https://0x7f000001/x',                  -- hex IP
      'https://[::1]/x',                       -- IPv6 literal
      'https://db.internal/x',                 -- internal suffix
      'https://printer.local/x',
      'https://nas.home.arpa/x',
      'https://metadata.google.internal/x',
      'https://intranet/x',                    -- single label
      'https://hooks.example.com:8080/x',      -- port not allowed
      'https://user@hooks.example.com/x'       -- userinfo
    ];
    bad text;
  begin
    foreach bad in array bad_urls loop
      v_failed := false;
      begin
        perform public.integration_create_webhook_endpoint(c_a, bad, null);
      exception when raise_exception then
        v_failed := sqlerrm in ('invalid_webhook_url', 'webhook_url_not_allowed');
      end;
      if not v_failed then
        raise exception 'T3: URL accepted or wrong error: %', bad;
      end if;
    end loop;
  end;

  -- cap: 10 active endpoints per integration
  for i in 2..10 loop
    perform public.integration_create_webhook_endpoint(
      c_a, 'https://hooks.example.com/cap' || i, null);
  end loop;
  v_failed := false;
  begin
    perform public.integration_create_webhook_endpoint(c_a, 'https://hooks.example.com/cap11', null);
  exception when raise_exception then
    v_failed := sqlerrm = 'endpoint_limit_reached';
  end;
  if not v_failed then raise exception 'T3: endpoint cap not enforced'; end if;

  perform set_config('role', 'postgres', true);
  -- tidy the cap fixtures (test-transaction only; keeps later counts simple)
  delete from public.webhook_endpoints
  where integration_client_id = c_a and id <> ep1;
  raise notice 'T3 passed';

  -- ---------------------------------------------------------------
  -- T4: secret handling + rotation
  -- ---------------------------------------------------------------
  if ep1_secret !~ '^whsec_[0-9a-f]{48}$' then
    raise exception 'T4: signing secret shape unexpected';
  end if;

  declare
    r public.webhook_endpoints;
  begin
    select * into r from public.webhook_endpoints where id = ep1;
    if r.signing_secret_hash <> public._integration_hash_secret(ep1_secret) then
      raise exception 'T4: stored hash does not match presented secret';
    end if;
    if r.signing_secret_prefix <> left(ep1_secret, 14) then
      raise exception 'T4: stored prefix mismatch';
    end if;
    if r.secret_ref is null then
      raise exception 'T4: Vault secret_ref not set';
    end if;
    if position(ep1_secret in row_to_json(r)::text) > 0 then
      raise exception 'T4: plaintext secret stored in webhook_endpoints row';
    end if;
  end;

  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and metadata::text like '%' || ep1_secret || '%';
  if n > 0 then raise exception 'T4: plaintext secret leaked into audit metadata'; end if;

  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'webhook_endpoint.created';
  if n < 1 then raise exception 'T4: webhook_endpoint.created not audited'; end if;

  -- rotation: immediate cutover
  perform set_config('role', 'authenticated', true);
  j := public.integration_rotate_webhook_secret(ep1);
  ep1_secret2 := j ->> 'signing_secret';
  perform set_config('role', 'postgres', true);

  if ep1_secret2 is null or ep1_secret2 = ep1_secret then
    raise exception 'T4: rotation did not produce a new secret';
  end if;
  select count(*) into n from public.webhook_endpoints
  where id = ep1 and signing_secret_hash = public._integration_hash_secret(ep1_secret2);
  if n <> 1 then raise exception 'T4: rotated hash not stored'; end if;
  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'webhook_secret.rotated';
  if n <> 1 then raise exception 'T4: rotation not audited'; end if;

  -- dispatcher can read the usable secret (service-role path, run as postgres)
  if public.integration_webhook_get_endpoint_secret(ep1) <> ep1_secret2 then
    raise exception 'T4: Vault secret does not round-trip for the dispatcher';
  end if;
  raise notice 'T4 passed';

  -- ---------------------------------------------------------------
  -- T5: authority matrix
  -- ---------------------------------------------------------------
  -- Owner B: complete non-disclosure
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_b::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  v_failed := false;
  begin
    perform public.integration_get_webhook_endpoint(ep1);
  exception when raise_exception then
    v_failed := sqlerrm = 'webhook_endpoint_not_found';
  end;
  if not v_failed then raise exception 'T5: owner B can see A''s endpoint'; end if;

  v_failed := false;
  begin
    perform public.integration_rotate_webhook_secret(ep1);
  exception when raise_exception then
    v_failed := sqlerrm = 'webhook_endpoint_not_found';
  end;
  if not v_failed then raise exception 'T5: owner B can rotate A''s secret'; end if;

  -- Manager: view yes, manage no
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);

  j := public.integration_list_webhook_endpoints(c_a);
  if jsonb_array_length(j) <> 1 then
    raise exception 'T5: manager cannot view endpoints of granted integration';
  end if;
  if j -> 0 ? 'signing_secret_hash' or j -> 0 ? 'secret_ref' then
    raise exception 'T5: endpoint listing exposes secret material';
  end if;

  v_failed := false;
  begin
    perform public.integration_create_webhook_endpoint(c_a, 'https://hooks.example.com/mgr', null);
  exception when raise_exception then v_failed := true;
  end;
  if not v_failed then raise exception 'T5: manager can create endpoints'; end if;

  v_failed := false;
  begin
    perform public.integration_set_webhook_endpoint_status(ep1, 'paused');
  exception when raise_exception then
    v_failed := sqlerrm = 'webhook_endpoint_not_found';
  end;
  if not v_failed then raise exception 'T5: manager can pause endpoints'; end if;

  v_failed := false;
  begin
    perform public.integration_create_webhook_subscription(ep1, 'trip.completed', null);
  exception when raise_exception then
    v_failed := sqlerrm = 'webhook_endpoint_not_found';
  end;
  if not v_failed then raise exception 'T5: manager can create subscriptions'; end if;

  -- Supervisor and Operator: nothing
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_sup::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.integration_list_webhook_endpoints(c_a);
  exception when raise_exception then
    v_failed := sqlerrm = 'integration_not_found';
  end;
  if not v_failed then raise exception 'T5: supervisor can list endpoints'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.integration_list_webhook_endpoints(c_a);
  exception when raise_exception then
    v_failed := sqlerrm = 'integration_not_found';
  end;
  if not v_failed then raise exception 'T5: operator can list endpoints'; end if;

  perform set_config('role', 'postgres', true);
  raise notice 'T5 passed';

  -- ---------------------------------------------------------------
  -- T6: subscription gates
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  v_failed := false;
  begin
    perform public.integration_create_webhook_subscription(ep1, 'nonexistent.event', null);
  exception when raise_exception then
    v_failed := sqlerrm = 'event_not_found';
  end;
  if not v_failed then raise exception 'T6: unknown event accepted'; end if;

  v_failed := false;
  begin
    perform public.integration_create_webhook_subscription(ep1, 'webhook.test', null);
  exception when raise_exception then
    v_failed := sqlerrm = 'event_not_subscribable';
  end;
  if not v_failed then raise exception 'T6: system event subscribable'; end if;

  -- yield:read is NOT granted → scope gate fires even though VA is granted
  v_failed := false;
  begin
    perform public.integration_create_webhook_subscription(ep1, 'yield_record.created', null);
  exception when raise_exception then
    v_failed := sqlerrm = 'scope_not_granted';
  end;
  if not v_failed then raise exception 'T6: subscription without scope accepted'; end if;

  -- trips:read IS granted, but VB is not a granted vineyard
  v_failed := false;
  begin
    perform public.integration_create_webhook_subscription(ep1, 'trip.completed', v_vb);
  exception when raise_exception then
    v_failed := sqlerrm = 'vineyard_not_granted';
  end;
  if not v_failed then raise exception 'T6: non-granted vineyard restriction accepted'; end if;

  j := public.integration_create_webhook_subscription(ep1, 'trip.completed', null);
  sub_all := (j ->> 'id')::uuid;
  j := public.integration_create_webhook_subscription(ep1, 'trip.completed', v_va);
  sub_va := (j ->> 'id')::uuid;

  v_failed := false;
  begin
    perform public.integration_create_webhook_subscription(ep1, 'trip.completed', null);
  exception when raise_exception then
    v_failed := sqlerrm = 'subscription_exists';
  end;
  if not v_failed then raise exception 'T6: duplicate subscription accepted'; end if;

  perform set_config('role', 'postgres', true);
  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'webhook_subscription.created';
  if n <> 2 then raise exception 'T6: subscription creation not audited (%)', n; end if;
  raise notice 'T6 passed';

  -- ---------------------------------------------------------------
  -- T7: emission fast-exit — never-granted vineyard stores nothing
  -- ---------------------------------------------------------------
  insert into public.trips (id, vineyard_id, is_active, created_by)
  values (trip_ghost, v_va2, true, u_owner_a);
  select count(*) into n from public.integration_events where resource_id = trip_ghost;
  if n <> 0 then raise exception 'T7: event stored for non-granted vineyard'; end if;
  delete from public.trips where id = trip_ghost;
  raise notice 'T7 passed';

  -- ---------------------------------------------------------------
  -- T8: trip lifecycle events + same-transaction dedup
  -- ---------------------------------------------------------------
  insert into public.trips (id, vineyard_id, is_active, created_by)
  values (trip1, v_va, true, u_owner_a);
  select count(*) into n from public.integration_events
  where resource_id = trip1 and event_type = 'trip.created';
  if n <> 1 then raise exception 'T8: trip.created not emitted once (%)', n; end if;

  -- live-tracking updates are suppressed while is_active
  update public.trips set total_distance = 5.0 where id = trip1;
  update public.trips set total_distance = 6.0 where id = trip1;
  select count(*) into n from public.integration_events
  where resource_id = trip1 and event_type = 'trip.updated';
  if n <> 0 then raise exception 'T8: live-tracking update emitted trip.updated'; end if;

  -- completion transition
  update public.trips set end_time = now(), is_active = false where id = trip1;
  select count(*) into n from public.integration_events
  where resource_id = trip1 and event_type = 'trip.completed';
  if n <> 1 then raise exception 'T8: trip.completed not emitted once (%)', n; end if;

  -- post-completion edits: same-transaction updates dedup to ONE event
  update public.trips set person_name = 'edited' where id = trip1;
  update public.trips set person_name = 'edited again' where id = trip1;
  select count(*) into n from public.integration_events
  where resource_id = trip1 and event_type = 'trip.updated';
  if n <> 1 then raise exception 'T8: same-tx trip.updated not deduplicated (%)', n; end if;

  -- already-finished insert (offline sync) emits ONLY trip.completed
  insert into public.trips (id, vineyard_id, is_active, end_time, created_by)
  values (trip2, v_va, false, now(), u_owner_a);
  select count(*) into n from public.integration_events
  where resource_id = trip2 and event_type = 'trip.created';
  if n <> 0 then raise exception 'T8: already-finished insert emitted trip.created'; end if;
  select count(*) into n from public.integration_events
  where resource_id = trip2 and event_type = 'trip.completed';
  if n <> 1 then raise exception 'T8: already-finished insert missing trip.completed'; end if;
  raise notice 'T8 passed';

  -- ---------------------------------------------------------------
  -- T9: fan-out
  -- ---------------------------------------------------------------
  select id into v_evt from public.integration_events
  where resource_id = trip1 and event_type = 'trip.completed';

  -- overlapping all-vineyards + VA-specific subscriptions → exactly ONE delivery
  select count(*) into n from public.webhook_deliveries where event_id = v_evt;
  if n <> 1 then raise exception 'T9: expected 1 delivery for completed trip, got %', n; end if;
  select id into d_first from public.webhook_deliveries where event_id = v_evt;

  -- no subscription for trip.created → event stored, no delivery
  select count(*) into n
  from public.webhook_deliveries d
  join public.integration_events ev on ev.id = d.event_id
  where ev.resource_id = trip1 and ev.event_type = 'trip.created';
  if n <> 0 then raise exception 'T9: delivery created without subscription'; end if;

  -- paused endpoint receives NO new deliveries at emit time
  perform set_config('role', 'authenticated', true);
  perform public.integration_set_webhook_endpoint_status(ep1, 'paused');
  perform set_config('role', 'postgres', true);

  insert into public.trips (id, vineyard_id, is_active, end_time, created_by)
  values (trip3, v_va, false, now(), u_owner_a);
  select count(*) into n from public.integration_events
  where resource_id = trip3 and event_type = 'trip.completed';
  if n <> 1 then raise exception 'T9: paused endpoint suppressed the EVENT (must only skip delivery)'; end if;
  select count(*) into n
  from public.webhook_deliveries d
  join public.integration_events ev on ev.id = d.event_id
  where ev.resource_id = trip3;
  if n <> 0 then raise exception 'T9: paused endpoint still got a delivery at emit'; end if;

  perform set_config('role', 'authenticated', true);
  perform public.integration_set_webhook_endpoint_status(ep1, 'active');
  perform set_config('role', 'postgres', true);
  raise notice 'T9 passed';

  -- ---------------------------------------------------------------
  -- T10: every resource family emits exactly one correct event
  -- ---------------------------------------------------------------
  -- spray: record insert = completed application; templates are silent
  insert into public.spray_records (id, vineyard_id, created_by) values (spray1, v_va, u_owner_a);
  insert into public.spray_records (id, vineyard_id, is_template, created_by) values (spray_tpl, v_va, true, u_owner_a);
  update public.spray_records set notes = 'wind corrected' where id = spray1;

  select count(*) into n from public.integration_events
  where resource_id = spray1 and event_type = 'spray_job.completed';
  if n <> 1 then raise exception 'T10: spray_job.completed missing'; end if;
  select count(*) into n from public.integration_events
  where resource_id = spray1 and event_type = 'spray_job.updated';
  if n <> 1 then raise exception 'T10: spray_job.updated missing'; end if;
  select count(*) into n from public.integration_events where resource_id = spray_tpl;
  if n <> 0 then raise exception 'T10: template spray emitted events'; end if;

  insert into public.fuel_purchases (id, vineyard_id, volume_litres, total_cost, created_by)
  values (fuelp1, v_va, 500, 900, u_owner_a);
  select count(*) into n from public.integration_events
  where resource_id = fuelp1 and event_type = 'fuel_purchase.created';
  if n <> 1 then raise exception 'T10: fuel_purchase.created missing'; end if;

  insert into public.tractor_fuel_logs (id, vineyard_id, litres_added, created_by)
  values (fuellog1, v_va, 40, u_owner_a);
  update public.tractor_fuel_logs set litres_added = 45 where id = fuellog1;
  select count(*) into n from public.integration_events
  where resource_id = fuellog1 and event_type in ('fuel_log.created', 'fuel_log.updated');
  if n <> 2 then raise exception 'T10: fuel_log events wrong (%)', n; end if;

  insert into public.work_tasks (id, vineyard_id, created_by) values (task1, v_va, u_owner_a);
  update public.work_tasks set is_finalized = true, finalized_at = now() where id = task1;
  select count(*) into n from public.integration_events
  where resource_id = task1 and event_type = 'work_task.created';
  if n <> 1 then raise exception 'T10: work_task.created missing'; end if;
  select count(*) into n from public.integration_events
  where resource_id = task1 and event_type = 'work_task.completed';
  if n <> 1 then raise exception 'T10: work_task.completed (finalise) missing'; end if;

  insert into public.pruning_activities (id, vineyard_id, entry_date, created_by)
  values (prune1, v_va, current_date, u_owner_a);
  select count(*) into n from public.integration_events
  where resource_id = prune1 and event_type = 'pruning_activity.created';
  if n <> 1 then raise exception 'T10: pruning_activity.created missing'; end if;

  insert into public.irrigation_systems (id, vineyard_id, name) values (irrsys1, v_va, 'T178 System');
  insert into public.irrigation_valves (id, vineyard_id, irrigation_system_id, name)
  values (irrvalve1, v_va, irrsys1, 'T178 Valve');
  insert into public.irrigation_sessions
    (id, vineyard_id, irrigation_system_id, valve_id, session_date, vintage_year,
     duration_minutes, calculation_method, total_volume_litres, status, source_type,
     configuration_snapshot, created_by)
  values
    (irr1, v_va, irrsys1, irrvalve1, current_date, 2026,
     60, 'total_volume', 1000, 'completed', 'manual_ios', '{}'::jsonb, u_owner_a);
  select count(*) into n from public.integration_events
  where resource_id = irr1 and event_type = 'irrigation_record.created';
  if n <> 1 then raise exception 'T10: irrigation_record.created missing'; end if;

  insert into public.growth_stage_records (id, vineyard_id, stage_code, created_by)
  values (growth1, v_va, 'EL-04', u_owner_a);
  select count(*) into n from public.integration_events
  where resource_id = growth1 and event_type = 'growth_stage.recorded';
  if n <> 1 then raise exception 'T10: growth_stage.recorded missing'; end if;

  insert into public.historical_yield_records (id, vineyard_id, created_by)
  values (yield1, v_va, u_owner_a);
  select count(*) into n from public.integration_events
  where resource_id = yield1 and event_type = 'yield_record.created';
  if n <> 1 then raise exception 'T10: yield_record.created missing'; end if;

  insert into public.pins (id, vineyard_id, created_by) values (pin1, v_va, u_owner_a);
  update public.pins set is_completed = true, completed_at = now() where id = pin1;
  select count(*) into n from public.integration_events
  where resource_id = pin1 and event_type = 'pin.created';
  if n <> 1 then raise exception 'T10: pin.created missing'; end if;
  select count(*) into n from public.integration_events
  where resource_id = pin1 and event_type = 'pin.resolved';
  if n <> 1 then raise exception 'T10: pin.resolved missing'; end if;

  insert into public.paddocks (id, vineyard_id, name, created_by) values (block1, v_va, 'T178 Block', u_owner_a);
  select count(*) into n from public.integration_events
  where resource_id = block1 and event_type = 'block.created';
  if n <> 1 then raise exception 'T10: block.created missing'; end if;

  -- every event carries the right vineyard + api_version + evt_ public id
  select count(*) into n from public.integration_events
  where resource_id in (spray1, fuelp1, fuellog1, task1, prune1, irr1, growth1, yield1, pin1, block1)
    and (vineyard_id <> v_va or api_version <> 'v1' or public_id !~ '^evt_[0-9a-f]{32}$');
  if n <> 0 then raise exception 'T10: malformed event envelope fields'; end if;
  raise notice 'T10 passed';

  -- ---------------------------------------------------------------
  -- T11: outbox atomicity — rolled-back write leaves no event
  -- ---------------------------------------------------------------
  begin
    insert into public.trips (id, vineyard_id, is_active, created_by)
    values (trip_ghost, v_va, true, u_owner_a);
    raise exception 'force_rollback';
  exception when raise_exception then
    if sqlerrm <> 'force_rollback' then raise; end if;
  end;
  select count(*) into n from public.integration_events where resource_id = trip_ghost;
  if n <> 0 then raise exception 'T11: event survived a rolled-back operational write'; end if;
  raise notice 'T11 passed';

  -- ---------------------------------------------------------------
  -- T12: integration_events is immutable
  -- ---------------------------------------------------------------
  v_failed := false;
  begin
    update public.integration_events set payload = '{}'::jsonb where resource_id = trip1;
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T12: events are updatable'; end if;

  v_failed := false;
  begin
    delete from public.integration_events where resource_id = trip1;
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T12: events are deletable'; end if;
  raise notice 'T12 passed';

  -- ---------------------------------------------------------------
  -- T13: dispatcher claim + successful attempt
  -- ---------------------------------------------------------------
  j := public.integration_webhook_claim_deliveries(50, 60);
  v_token := null;
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d_first then
      v_token := (jd ->> 'claim_token')::uuid;
      if (jd ->> 'delivery_public_id') !~ '^dlv_[0-9a-f]{32}$' then
        raise exception 'T13: delivery public id malformed';
      end if;
      if (jd ->> 'attempt_number')::integer <> 1 then
        raise exception 'T13: first attempt number wrong';
      end if;
      if (jd -> 'event' ->> 'id') !~ '^evt_[0-9a-f]{32}$'
         or (jd -> 'event' ->> 'type') <> 'trip.completed'
         or (jd -> 'event' ->> 'api_version') <> 'v1'
         or (jd -> 'event' ->> 'occurred_at') !~ '^\d{4}-\d{2}-\d{2}T.*Z$'
         or (jd -> 'event' -> 'data' ->> 'id')::uuid <> trip1
         or (jd -> 'event' ->> 'vineyard_id')::uuid <> v_va
         or (jd ->> 'url') is null then
        raise exception 'T13: claim envelope malformed: %', jd;
      end if;
    end if;
  end loop;
  if v_token is null then raise exception 'T13: due delivery was not claimed'; end if;

  -- claimed rows are not claimable again while the lease is fresh
  j := public.integration_webhook_claim_deliveries(50, 60);
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d_first then
      raise exception 'T13: delivery claimed twice inside the lease';
    end if;
  end loop;

  -- an expired lease is reclaimable (at-least-once)
  update public.webhook_deliveries set claimed_at = now() - interval '10 minutes' where id = d_first;
  j := public.integration_webhook_claim_deliveries(50, 60);
  v_token := null;
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d_first then
      v_token := (jd ->> 'claim_token')::uuid;
    end if;
  end loop;
  if v_token is null then raise exception 'T13: expired lease not reclaimable'; end if;

  j := public.integration_webhook_record_attempt(d_first, v_token, 'success', 200, 123, null, null, null);
  if j ->> 'status' <> 'delivered' then raise exception 'T13: success not recorded'; end if;
  select count(*) into n from public.webhook_deliveries
  where id = d_first and status = 'delivered' and delivered_at is not null and attempt_count = 1;
  if n <> 1 then raise exception 'T13: delivered bookkeeping wrong'; end if;
  select count(*) into n from public.webhook_delivery_attempts
  where delivery_id = d_first and attempt_number = 1 and http_status = 200 and error_category is null;
  if n <> 1 then raise exception 'T13: attempt row wrong'; end if;
  select count(*) into n from public.webhook_endpoints
  where id = ep1 and consecutive_failures = 0 and last_success_at is not null;
  if n <> 1 then raise exception 'T13: endpoint health not updated on success'; end if;
  raise notice 'T13 passed';

  -- ---------------------------------------------------------------
  -- T14: retry machinery
  -- ---------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  j := public.integration_replay_webhook_delivery(d_first);
  d_tmp := (j ->> 'delivery_id')::uuid;
  perform set_config('role', 'postgres', true);

  -- recording against a non-claimed delivery / wrong token is refused
  v_failed := false;
  begin
    perform public.integration_webhook_record_attempt(d_tmp, gen_random_uuid(), 'retryable', 500, 10, 'http_5xx', 'x', null);
  exception when raise_exception then
    v_failed := sqlerrm = 'claim_invalid';
  end;
  if not v_failed then raise exception 'T14: wrong claim token accepted'; end if;

  -- attempt 1: retryable 500 → pending again in ~1 minute
  j := public.integration_webhook_claim_deliveries(50, 60);
  v_token := null;
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d_tmp then v_token := (jd ->> 'claim_token')::uuid; end if;
  end loop;
  if v_token is null then raise exception 'T14: replay delivery not claimable'; end if;
  j := public.integration_webhook_record_attempt(d_tmp, v_token, 'retryable', 500, 45, 'http_5xx', 'receiver responded 500', null);
  if j ->> 'status' <> 'pending' then raise exception 'T14: retryable did not requeue'; end if;
  select extract(epoch from (next_attempt_at - now())) into v_delta
  from public.webhook_deliveries where id = d_tmp;
  if v_delta not between 55 and 65 then
    raise exception 'T14: attempt-1 backoff not ~60s (got %s)', v_delta;
  end if;

  -- attempt 2: 429 with Retry-After 600 widens the 5-minute schedule
  update public.webhook_deliveries set next_attempt_at = now() where id = d_tmp;
  j := public.integration_webhook_claim_deliveries(50, 60);
  v_token := null;
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d_tmp then v_token := (jd ->> 'claim_token')::uuid; end if;
  end loop;
  perform public.integration_webhook_record_attempt(d_tmp, v_token, 'retryable', 429, 30, 'http_4xx', 'receiver responded 429', 600);
  select extract(epoch from (next_attempt_at - now())) into v_delta
  from public.webhook_deliveries where id = d_tmp;
  if v_delta not between 590 and 610 then
    raise exception 'T14: Retry-After not honoured (got %s)', v_delta;
  end if;

  -- attempt 3: permanent 404 → failed immediately
  update public.webhook_deliveries set next_attempt_at = now() where id = d_tmp;
  j := public.integration_webhook_claim_deliveries(50, 60);
  v_token := null;
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d_tmp then v_token := (jd ->> 'claim_token')::uuid; end if;
  end loop;
  j := public.integration_webhook_record_attempt(d_tmp, v_token, 'permanent', 404, 20, 'http_4xx', 'receiver responded 404', null);
  if j ->> 'status' <> 'failed' then raise exception 'T14: permanent 4xx did not fail'; end if;
  select count(*) into n from public.webhook_deliveries
  where id = d_tmp and status = 'failed' and failed_at is not null and attempt_count = 3;
  if n <> 1 then raise exception 'T14: failed bookkeeping wrong'; end if;

  -- attempt cap: the 7th attempt fails terminally even when retryable
  perform set_config('role', 'authenticated', true);
  j := public.integration_replay_webhook_delivery(d_first);
  d_tmp2 := (j ->> 'delivery_id')::uuid;
  perform set_config('role', 'postgres', true);
  update public.webhook_deliveries set attempt_count = 6 where id = d_tmp2;
  j := public.integration_webhook_claim_deliveries(50, 60);
  v_token := null;
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d_tmp2 then v_token := (jd ->> 'claim_token')::uuid; end if;
  end loop;
  j := public.integration_webhook_record_attempt(d_tmp2, v_token, 'retryable', 503, 15, 'http_5xx', 'receiver responded 503', null);
  if j ->> 'status' <> 'failed' then raise exception 'T14: attempt cap not enforced'; end if;
  select count(*) into n from public.webhook_delivery_attempts
  where delivery_id = d_tmp2 and attempt_number = 7;
  if n <> 1 then raise exception 'T14: capped attempt row missing'; end if;
  raise notice 'T14 passed';

  -- ---------------------------------------------------------------
  -- T15: auto-disable after 10 consecutive failures
  -- ---------------------------------------------------------------
  update public.webhook_endpoints set consecutive_failures = 9 where id = ep1;
  perform set_config('role', 'authenticated', true);
  j := public.integration_replay_webhook_delivery(d_first);
  d3 := (j ->> 'delivery_id')::uuid;
  perform set_config('role', 'postgres', true);

  j := public.integration_webhook_claim_deliveries(50, 60);
  v_token := null;
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d3 then v_token := (jd ->> 'claim_token')::uuid; end if;
  end loop;
  perform public.integration_webhook_record_attempt(d3, v_token, 'retryable', 500, 12, 'http_5xx', 'receiver responded 500', null);

  select count(*) into n from public.webhook_endpoints
  where id = ep1 and status = 'disabled'
    and disabled_reason = 'auto_disabled_after_consecutive_failures'
    and disabled_at is not null and consecutive_failures = 10;
  if n <> 1 then raise exception 'T15: endpoint not auto-disabled'; end if;
  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'webhook_endpoint.disabled'
    and (metadata ->> 'auto')::boolean;
  if n <> 1 then raise exception 'T15: auto-disable not audited'; end if;

  -- queued delivery to a disabled endpoint cancels at claim time
  update public.webhook_deliveries set next_attempt_at = now() where id = d3;
  j := public.integration_webhook_claim_deliveries(50, 60);
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d3 then
      raise exception 'T15: delivery to disabled endpoint was claimed';
    end if;
  end loop;
  select count(*) into n from public.webhook_deliveries
  where id = d3 and status = 'cancelled' and cancel_reason = 'endpoint_disabled';
  if n <> 1 then raise exception 'T15: disabled-endpoint delivery not cancelled'; end if;

  -- owner reactivation resets health
  perform set_config('role', 'authenticated', true);
  perform public.integration_set_webhook_endpoint_status(ep1, 'active');
  perform set_config('role', 'postgres', true);
  select count(*) into n from public.webhook_endpoints
  where id = ep1 and status = 'active' and disabled_at is null and consecutive_failures = 0;
  if n <> 1 then raise exception 'T15: reactivation did not reset health'; end if;
  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'webhook_endpoint.reactivated';
  if n < 1 then raise exception 'T15: reactivation not audited'; end if;
  raise notice 'T15 passed';

  -- ---------------------------------------------------------------
  -- T16: pause defers; revocation cancels + blocks replay
  -- ---------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  j := public.integration_replay_webhook_delivery(d_first);
  d4 := (j ->> 'delivery_id')::uuid;
  perform public.integration_set_webhook_endpoint_status(ep1, 'paused');
  perform set_config('role', 'postgres', true);

  j := public.integration_webhook_claim_deliveries(50, 60);
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d4 then
      raise exception 'T16: paused endpoint delivery was claimed';
    end if;
  end loop;
  select count(*) into n from public.webhook_deliveries
  where id = d4 and status = 'pending' and next_attempt_at > now();
  if n <> 1 then raise exception 'T16: paused delivery not deferred (must stay pending)'; end if;

  perform set_config('role', 'authenticated', true);
  perform public.integration_set_webhook_endpoint_status(ep1, 'active');
  perform set_config('role', 'postgres', true);

  -- scope revocation cancels at claim time
  update public.integration_client_scopes
  set revoked_at = now()
  where integration_client_id = c_a and scope = 'trips:read' and revoked_at is null;

  update public.webhook_deliveries set next_attempt_at = now() where id = d4;
  j := public.integration_webhook_claim_deliveries(50, 60);
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d4 then
      raise exception 'T16: delivery claimed after scope revocation';
    end if;
  end loop;
  select count(*) into n from public.webhook_deliveries
  where id = d4 and status = 'cancelled' and cancel_reason = 'scope_revoked';
  if n <> 1 then raise exception 'T16: scope revocation did not cancel delivery'; end if;

  -- re-grant the scope, queue another delivery, then revoke the VINEYARD grant
  insert into public.integration_client_scopes (integration_client_id, scope, granted_by)
  values (c_a, 'trips:read', u_owner_a);

  perform set_config('role', 'authenticated', true);
  j := public.integration_replay_webhook_delivery(d_first);
  d5 := (j ->> 'delivery_id')::uuid;
  perform set_config('role', 'postgres', true);

  update public.integration_client_vineyards
  set revoked_at = now()
  where integration_client_id = c_a and vineyard_id = v_va and revoked_at is null;

  -- replay of vineyard data is refused while the grant is revoked
  perform set_config('role', 'authenticated', true);
  v_failed := false;
  begin
    perform public.integration_replay_webhook_delivery(d_first);
  exception when raise_exception then
    v_failed := sqlerrm = 'replay_not_allowed';
  end;
  if not v_failed then raise exception 'T16: replay allowed after grant revocation'; end if;
  perform set_config('role', 'postgres', true);

  update public.webhook_deliveries set next_attempt_at = now() where id = d5;
  j := public.integration_webhook_claim_deliveries(50, 60);
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d5 then
      raise exception 'T16: delivery claimed after vineyard grant revocation';
    end if;
  end loop;
  select count(*) into n from public.webhook_deliveries
  where id = d5 and status = 'cancelled' and cancel_reason = 'vineyard_grant_revoked';
  if n <> 1 then raise exception 'T16: grant revocation did not cancel delivery'; end if;

  -- restore the grant for the remaining tests
  update public.integration_client_vineyards
  set revoked_at = null
  where integration_client_id = c_a and vineyard_id = v_va;
  raise notice 'T16 passed';

  -- ---------------------------------------------------------------
  -- T17: test webhook + replay bookkeeping
  -- ---------------------------------------------------------------
  perform set_config('role', 'authenticated', true);
  j := public.integration_send_test_webhook(ep1);
  d_test := (j ->> 'delivery_id')::uuid;
  perform set_config('role', 'postgres', true);

  j := public.integration_webhook_claim_deliveries(50, 60);
  v_token := null;
  for jd in select value from jsonb_array_elements(j) loop
    if (jd ->> 'delivery_id')::uuid = d_test then
      v_token := (jd ->> 'claim_token')::uuid;
      if (jd -> 'event' ->> 'type') <> 'webhook.test'
         or (jd -> 'event' ->> 'vineyard_id') is not null then
        raise exception 'T17: test envelope malformed';
      end if;
    end if;
  end loop;
  if v_token is null then raise exception 'T17: test delivery not claimable'; end if;
  perform public.integration_webhook_record_attempt(d_test, v_token, 'success', 200, 80, null, null, null);

  select count(*) into n from public.webhook_deliveries where id = d_test and is_test and status = 'delivered';
  if n <> 1 then raise exception 'T17: test delivery bookkeeping wrong'; end if;
  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'webhook.test_sent';
  if n <> 1 then raise exception 'T17: test webhook not audited'; end if;
  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a and action = 'webhook.replayed';
  if n < 5 then raise exception 'T17: replays not audited (%)', n; end if;

  -- replays created fresh public ids
  select count(distinct public_id) into n from public.webhook_deliveries
  where event_id = (select event_id from public.webhook_deliveries where id = d_first);
  select count(*) into i from public.webhook_deliveries
  where event_id = (select event_id from public.webhook_deliveries where id = d_first);
  if n <> i then raise exception 'T17: delivery public ids reused across replays'; end if;
  raise notice 'T17 passed';

  -- ---------------------------------------------------------------
  -- T18: management surface + endpoint delete + audit integrity
  -- ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  j := public.integration_list_webhook_deliveries(c_a, null, null, null, null, null, null, 100, null, null);
  if jsonb_array_length(j -> 'data') < 6
     or not (j -> 'pagination' ? 'limit')
     or not (j -> 'pagination' ? 'has_more') then
    raise exception 'T18: delivery listing shape wrong';
  end if;

  j := public.integration_list_webhook_deliveries(c_a, null, null, 'delivered', null, null, null, 100, null, null);
  for jd in select value from jsonb_array_elements(j -> 'data') loop
    if jd ->> 'status' <> 'delivered' then raise exception 'T18: status filter leaked rows'; end if;
  end loop;

  j := public.integration_list_webhook_deliveries(c_a, null, 'webhook.test', null, null, null, null, 100, null, null);
  if jsonb_array_length(j -> 'data') < 1 then raise exception 'T18: event filter lost rows'; end if;

  v_failed := false;
  begin
    perform public.integration_list_webhook_deliveries(c_a, null, null, 'bogus', null, null, null, 100, null, null);
  exception when raise_exception then v_failed := sqlerrm = 'invalid_status';
  end;
  if not v_failed then raise exception 'T18: bogus status accepted'; end if;

  v_failed := false;
  begin
    perform public.integration_list_webhook_deliveries(c_a, null, null, null, null, null, null, 100, now(), null);
  exception when raise_exception then v_failed := sqlerrm = 'invalid_cursor';
  end;
  if not v_failed then raise exception 'T18: half cursor accepted'; end if;

  j := public.integration_get_webhook_delivery(d_tmp);
  if jsonb_array_length(j -> 'attempts') <> 3
     or (j ->> 'status') <> 'failed'
     or (j -> 'event' ->> 'type') <> 'trip.completed' then
    raise exception 'T18: delivery detail wrong';
  end if;

  -- manager can view deliveries; owner B cannot
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  j := public.integration_list_webhook_deliveries(c_a, null, null, null, null, null, null, 10, null, null);
  if jsonb_array_length(j -> 'data') < 1 then raise exception 'T18: manager cannot view deliveries'; end if;
  j := public.integration_get_webhook_delivery(d_first);
  if (j ->> 'id')::uuid <> d_first then raise exception 'T18: manager delivery detail broken'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_b::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.integration_list_webhook_deliveries(c_a, null, null, null, null, null, null, 10, null, null);
  exception when raise_exception then v_failed := sqlerrm = 'integration_not_found';
  end;
  if not v_failed then raise exception 'T18: owner B can list A''s deliveries'; end if;
  v_failed := false;
  begin
    perform public.integration_get_webhook_delivery(d_first);
  exception when raise_exception then v_failed := sqlerrm = 'delivery_not_found';
  end;
  if not v_failed then raise exception 'T18: owner B can read A''s delivery'; end if;

  -- subscription delete (audited); repeat delete refused
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner_a::text, 'role', 'authenticated')::text, true);
  perform public.integration_delete_webhook_subscription(sub_va);
  v_failed := false;
  begin
    perform public.integration_delete_webhook_subscription(sub_va);
  exception when raise_exception then v_failed := sqlerrm = 'subscription_not_found';
  end;
  if not v_failed then raise exception 'T18: double subscription delete accepted'; end if;

  -- endpoint delete cancels the queue and clears the Vault reference
  j := public.integration_replay_webhook_delivery(d_first);
  d6 := (j ->> 'delivery_id')::uuid;
  perform set_config('role', 'postgres', true);
  select secret_ref into v_ref from public.webhook_endpoints where id = ep1;
  perform set_config('role', 'authenticated', true);
  perform public.integration_delete_webhook_endpoint(ep1);
  perform set_config('role', 'postgres', true);

  select count(*) into n from public.webhook_deliveries
  where id = d6 and status = 'cancelled' and cancel_reason = 'endpoint_deleted';
  if n <> 1 then raise exception 'T18: endpoint delete left queued delivery live'; end if;
  select count(*) into n from public.webhook_endpoints
  where id = ep1 and deleted_at is not null and secret_ref is null;
  if n <> 1 then raise exception 'T18: endpoint delete bookkeeping wrong'; end if;
  select count(*) into n from vault.secrets where id = v_ref;
  if n <> 0 then raise exception 'T18: Vault secret survived endpoint delete'; end if;

  perform set_config('role', 'authenticated', true);
  v_failed := false;
  begin
    perform public.integration_get_webhook_endpoint(ep1);
  exception when raise_exception then v_failed := sqlerrm = 'webhook_endpoint_not_found';
  end;
  if not v_failed then raise exception 'T18: deleted endpoint still readable'; end if;
  perform set_config('role', 'postgres', true);

  select count(*) into n from public.integration_audit_log
  where integration_client_id = c_a
    and action in ('webhook_endpoint.created', 'webhook_endpoint.updated',
                   'webhook_endpoint.paused', 'webhook_endpoint.reactivated',
                   'webhook_endpoint.disabled', 'webhook_endpoint.deleted',
                   'webhook_secret.rotated',
                   'webhook_subscription.created', 'webhook_subscription.deleted',
                   'webhook.test_sent', 'webhook.replayed');
  if n < 12 then raise exception 'T18: webhook audit coverage incomplete (%)', n; end if;

  -- audit stays append-only for webhook actions too
  v_failed := false;
  begin
    update public.integration_audit_log set metadata = '{}'::jsonb
    where integration_client_id = c_a and action = 'webhook_endpoint.deleted';
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T18: audit log updatable'; end if;
  raise notice 'T18 passed';

  raise notice 'SQL 178 webhook platform tests: ALL PASSED';
end$$;

rollback;

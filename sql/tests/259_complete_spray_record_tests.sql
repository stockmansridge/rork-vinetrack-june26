-- DRAFT: rollback-only contract tests for 259. NOT executed by drafting this file.
-- Run ONLY on an explicitly approved disposable/local database with the existing
-- migrations and 259 installed. Never point this at production, even with ROLLBACK:
-- normal triggers run and may have integration side effects outside this test.
-- No migration is applied/included here. All fixtures are synthetic; no live IDs.
-- Use psql -X -v ON_ERROR_STOP=1 -f <this file> on the isolated test database.
-- Connect as postgres (or a test-session role permitted to SET ROLE postgres,
-- authenticated and anon). The invoker helpers do not elevate a normal client.
-- SQL 007 permits all four existing membership roles; there is no separate
-- read-only member role to fabricate. Test denial for a non-member and for an
-- owner whose membership is in another vineyard; test success for all four roles.
-- These single-session tests check state contracts, not multi-session lock races.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

-- Session-local, invoker-rights helpers disappear on rollback; no public test RPC.
create function pg_temp.t259_login(p_user uuid, p_role text default 'authenticated')
returns void language plpgsql as $fn$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claim.sub', coalesce(p_user::text, ''), true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', p_role)::text, true);
  perform set_config('role', p_role, true);
end;
$fn$;

create function pg_temp.t259_expect_error(
  p_id uuid, p_allow boolean, p_state text, p_message text
) returns void language plpgsql as $fn$
declare v_state text; v_message text;
begin
  begin
    perform public.complete_spray_record(p_id, p_allow);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  end;
  if v_state is distinct from p_state or v_message is distinct from p_message then
    raise exception 'Expected % / %, got % / %',
      p_state, p_message, coalesce(v_state, 'success'), coalesce(v_message, 'success');
  end if;
end;
$fn$;

-- Fail fast on an uninstalled draft or unexpectedly broad EXECUTE access.
do $security$
declare v_rpc oid := to_regprocedure('public.complete_spray_record(uuid,boolean)');
begin
  if v_rpc is null then raise exception '259 must be installed on an isolated test DB first'; end if;
  if has_function_privilege('anon', v_rpc, 'execute')
     or has_function_privilege('service_role', v_rpc, 'execute')
     or not has_function_privilege('authenticated', v_rpc, 'execute') then
    raise exception '259 EXECUTE privilege contract failed';
  end if;
  if not exists(select 1 from pg_proc where oid = v_rpc and prosecdef
    and proconfig @> array['search_path=public']) then
    raise exception '259 security-definer/fixed-search-path contract failed';
  end if;
end;
$security$;

do $tests$
declare
  v_vineyard uuid := gen_random_uuid(); v_other uuid := gen_random_uuid();
  v_owner uuid := gen_random_uuid(); v_manager uuid := gen_random_uuid();
  v_supervisor uuid := gen_random_uuid(); v_operator uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid(); v_foreign_owner uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid(); v_block uuid := gen_random_uuid();
  v_tractor uuid := gen_random_uuid(); v_unit uuid := gen_random_uuid(); v_chemical uuid := gen_random_uuid();
  v_manual uuid := gen_random_uuid(); v_manual_trip uuid := gen_random_uuid();
  v_manual_id_only uuid := gen_random_uuid();
  v_manual_identity uuid := gen_random_uuid(); v_manual_tank uuid := gen_random_uuid();
  v_ended_trip uuid := gen_random_uuid(); v_active_trip uuid := gen_random_uuid();
  v_unfinished_trip uuid := gen_random_uuid(); v_deleted_trip uuid := gen_random_uuid();
  v_foreign_trip uuid := gen_random_uuid(); v_bad_trip uuid := gen_random_uuid();
  v_paused_trip uuid := gen_random_uuid();
  v_template uuid := gen_random_uuid(); v_deleted uuid := gen_random_uuid();
  v_existing uuid := gen_random_uuid(); v_ended uuid := gen_random_uuid();
  v_active uuid := gen_random_uuid(); v_unfinished uuid := gen_random_uuid();
  v_missing uuid := gen_random_uuid(); v_dead_link uuid := gen_random_uuid();
  v_cross_link uuid := gen_random_uuid(); v_bad_link uuid := gen_random_uuid();
  v_paused_link uuid := gen_random_uuid(); v_manual_trip_link uuid := gen_random_uuid();
  v_unlinked uuid := gen_random_uuid();
  v_role_ids uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  v_actors uuid[]; v_all_sprays uuid[]; v_rejected uuid[];
  v_index integer; v_state text; v_message text; v_result jsonb; v_retry jsonb;
  v_before jsonb; v_after jsonb; v_rejected_before jsonb;
  v_paused_trip_before jsonb;
  v_trips_before jsonb; v_actuals_before jsonb; v_jobs_before jsonb;
  v_weather_before jsonb; v_costs_before jsonb; v_manual_ops_before jsonb;
  v_guard_before text; v_guard_triggers_before jsonb;
  v_end timestamptz := '2026-02-03 04:05:06.123456+00';
  v_existing_end timestamptz := '2025-12-02 03:04:05.654321+00';
  v_audit_exclusions text[] := array['end_time','updated_by','client_updated_at','sync_version','updated_at'];
begin
  perform pg_temp.t259_login(null, 'postgres');
  v_actors := array[v_owner, v_manager, v_supervisor, v_operator];
  insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select actor, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    't259-' || actor::text || '@test.local', 'x', now(), now(), now()
  from unnest(v_actors || array[v_outsider, v_foreign_owner]) actor;
  insert into public.profiles(id, email, full_name)
  select actor, 't259-' || actor::text || '@test.local', 'T259 Synthetic User'
  from unnest(v_actors || array[v_outsider, v_foreign_owner]) actor
  on conflict(id) do nothing;
  insert into public.vineyards(id, name) values
    (v_vineyard, 'T259 Synthetic Vineyard'), (v_other, 'T259 Other Vineyard');
  insert into public.vineyard_members(vineyard_id, user_id, role) values
    (v_vineyard, v_owner, 'owner'), (v_vineyard, v_manager, 'manager'),
    (v_vineyard, v_supervisor, 'supervisor'), (v_vineyard, v_operator, 'operator'),
    (v_other, v_foreign_owner, 'owner');
  insert into public.paddocks(id, vineyard_id, name) values(v_block, v_vineyard, 'T259 Block');
  insert into public.spray_jobs(id, vineyard_id, name, is_template, chemical_lines)
  values(v_job, v_vineyard, 'T259 Program Provenance', true,
    '[{"name":"Frozen product","rate":125,"unit":"mL/100 L"}]');
  insert into public.tractors(id, vineyard_id, name, brand, model, fuel_usage_l_per_hour)
  values(v_tractor, v_vineyard, 'T259 Tractor', 'Test', 'One', 6);
  insert into public.spray_equipment(id, vineyard_id, name, tank_capacity_litres)
  values(v_unit, v_vineyard, 'T259 Unit', 1000);
  insert into public.saved_chemicals(id, vineyard_id, name, unit)
  values(v_chemical, v_vineyard, 'T259 Product', 'Litres');

  -- Build the manual fixture THROUGH the existing coordinated workflow, never
  -- set its bypass flag in this test. Then explicitly clear that RPC-local flag.
  perform pg_temp.t259_login(v_supervisor);
  perform public.save_manual_spray_v1(gen_random_uuid(), jsonb_build_object(
    'vineyardId', v_vineyard, 'manualEntryId', v_manual_identity,
    'sprayRecordId', v_manual, 'tripId', v_manual_trip,
    'reference', 'T259 Manual', 'operationType', 'Foliar Spray',
    'startUtc', '2026-02-03T03:05:06Z', 'endUtc', v_end,
    'tractorId', v_tractor, 'sprayEquipmentId', v_unit, 'operatorUserId', v_supervisor,
    'blocks', jsonb_build_array(jsonb_build_object('blockId', v_block, 'blockName', 'T259 Block')),
    'tanks', jsonb_build_array(jsonb_build_object(
      'id', v_manual_tank, 'actualId', gen_random_uuid(), 'tankNumber', 1, 'waterVolumeLitres', 1000,
      'chemicals', jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid(), 'savedChemicalId', v_chemical, 'name', 'T259 Product',
        'actualAmountBase', 125, 'unit', 'Litres', 'productCategory', 'fungicide',
        'physicalForm', 'liquid', 'snapshotAt', '2026-02-03T02:00:00Z'
      ))
    ))
  ), 0);
  perform set_config('vinetrack.manual_spray_rpc', '', true);
  perform pg_temp.t259_login(v_operator, 'postgres');

  insert into public.trips(id, vineyard_id, start_time, end_time, is_active, is_paused,
    deleted_at, path_points, tank_sessions, completion_notes)
  values
    (v_ended_trip, v_vineyard, v_end - interval '1 hour', v_end, false, false,
      null, '[{"latitude":-33,"longitude":149}]', '[{"id":"t259-tank","tank_number":1}]', 'Frozen Trip'),
    (v_active_trip, v_vineyard, v_end - interval '1 hour', v_end, true, false,
      null, '[]', '[]', 'Active wins even with end timestamp'),
    (v_unfinished_trip, v_vineyard, v_end - interval '1 hour', null, false, false, null, '[]', '[]', null),
    (v_deleted_trip, v_vineyard, v_end - interval '1 hour', v_end, false, false, now(), '[]', '[]', null),
    (v_foreign_trip, v_other, v_end - interval '1 hour', v_end, false, false, null, '[]', '[]', null),
    (v_bad_trip, v_vineyard, v_end + interval '1 hour', v_end, false, false, null, '[]', '[]', null),
    (v_paused_trip, v_vineyard, v_end - interval '1 hour', v_end, false, true, null, '[]', '[]', null);

  v_all_sprays := array[v_template,v_deleted,v_existing,v_ended,v_active,v_unfinished,
    v_missing,v_dead_link,v_cross_link,v_bad_link,v_paused_link,v_manual_trip_link,v_unlinked,v_manual_id_only] || v_role_ids;
  insert into public.spray_records(id, vineyard_id, spray_job_id, date, start_time,
    spray_reference, notes, tanks, application_blocks, gross_area_ha, treated_area_ha,
    total_carrier_litres, carrier_volume_basis, temperature, wind_speed, tractor_id,
    spray_equipment_id, created_by, updated_by, client_updated_at, updated_at, sync_version)
  select id, v_vineyard, v_job, v_end - interval '1 hour', v_end - interval '1 hour',
    'T259 Frozen Spray', 'Do not rewrite application data',
    '[{"id":"t259-tank","tankNumber":1,"waterVolume":1000,"chemicals":[{"name":"Frozen product","volumePerTank":125,"unit":"mL","rateBasis":"per_100_litres"}]}]',
    jsonb_build_array(jsonb_build_object('blockId', v_block, 'blockName', 'T259 Block')),
    2, 1, 1000, 'l_per_ha', 18, 6, v_tractor, v_unit, v_supervisor, v_supervisor,
    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 7
  from unnest(v_all_sprays) id;
  update public.spray_records set is_template = true where id = v_template;
  update public.spray_records set deleted_at = now() where id = v_deleted;
  update public.spray_records set trip_id = v_active_trip, end_time = v_existing_end where id = v_existing;
  update public.spray_records set trip_id = v_ended_trip where id = v_ended;
  update public.spray_records set trip_id = v_active_trip where id = v_active;
  update public.spray_records set trip_id = v_unfinished_trip where id = v_unfinished;
  -- trip_id has no FK in 007; exercise an actually missing canonical row.
  update public.spray_records set trip_id = gen_random_uuid() where id = v_missing;
  update public.spray_records set trip_id = v_deleted_trip where id = v_dead_link;
  update public.spray_records set trip_id = v_foreign_trip where id = v_cross_link;
  update public.spray_records set trip_id = v_bad_trip where id = v_bad_link;
  update public.spray_records set trip_id = v_paused_trip where id = v_paused_link;
  update public.spray_records set trip_id = v_manual_trip where id = v_manual_trip_link;
  -- SQL 232's CHECK permits NULL source + nonnull identity (CHECK UNKNOWN).
  -- Protect this legacy/inconsistent shape too, without disabling any guard.
  update public.spray_records set manual_entry_id = gen_random_uuid() where id = v_manual_id_only;
  insert into public.spray_tank_actuals(id, vineyard_id, spray_record_id, trip_id,
    tank_session_id, tank_number, water_volume_l, chemicals, confirmed_at, confirmed_by, client_updated_at)
  values(gen_random_uuid(), v_vineyard, v_ended, v_ended_trip, 't259-tank', 1, 975,
    jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'plannedChemicalId', null,
      'savedChemicalId', v_chemical, 'name', 'Frozen actual', 'actualAmountBase', 120, 'unit', 'mL')),
    v_end, v_operator, v_end);
  insert into public.trip_weather_observations(vineyard_id, trip_id, sample_slot,
    observed_at, source, source_kind, temperature_c, humidity_pct, wind_speed_kmh)
  values(v_vineyard, v_ended_trip, v_end, v_end, 'T259 Frozen weather', 'observed', 18, 70, 6);
  insert into public.trip_cost_allocations(vineyard_id, trip_id, season_year,
    paddock_id, paddock_name, labour_cost, fuel_cost, chemical_cost, total_cost,
    allocation_basis, costing_status)
  values(v_vineyard, v_ended_trip, 2026, v_block, 'T259 Block', 30, 10, 20, 60, 'area', 'complete');

  v_rejected := array[v_template,v_deleted,v_active,v_unfinished,v_missing,v_dead_link,
    v_cross_link,v_bad_link,v_manual_trip_link,v_manual,v_manual_id_only];
  select jsonb_agg(to_jsonb(r) order by r.id) into v_rejected_before
    from public.spray_records r where r.id = any(v_rejected);
  select jsonb_agg(to_jsonb(t) order by t.id) into v_trips_before
    from public.trips t where t.vineyard_id in (v_vineyard,v_other);
  select jsonb_agg(to_jsonb(a) order by a.id) into v_actuals_before
    from public.spray_tank_actuals a where a.vineyard_id = v_vineyard;
  select to_jsonb(j) into v_jobs_before from public.spray_jobs j where j.id = v_job;
  select jsonb_agg(to_jsonb(w) order by w.id) into v_weather_before
    from public.trip_weather_observations w where w.vineyard_id = v_vineyard;
  select jsonb_agg(to_jsonb(c) order by c.id) into v_costs_before
    from public.trip_cost_allocations c where c.vineyard_id = v_vineyard;
  select jsonb_agg(to_jsonb(o) order by o.operation_id) into v_manual_ops_before
    from public.manual_spray_operations o where o.vineyard_id = v_vineyard;
  v_guard_before := pg_get_functiondef('public.manual_spray_guard_v1()'::regprocedure);
  select jsonb_agg(pg_get_triggerdef(oid) order by tgname) into v_guard_triggers_before
    from pg_trigger where tgname in ('trg_spray_records_manual_guard_v1','trg_trips_manual_guard_v1');

  -- T1: function-level auth check AND anonymous execution ACL denial.
  perform pg_temp.t259_login(null);
  perform pg_temp.t259_expect_error(v_unlinked, true, '42501', 'AUTH_REQUIRED');
  perform pg_temp.t259_login(null, 'anon');
  perform pg_temp.t259_expect_error(v_unlinked, true, '42501', 'permission denied for function complete_spray_record');
  -- T2: neither non-members nor an owner in another vineyard can edit/complete.
  perform pg_temp.t259_login(v_outsider);
  perform pg_temp.t259_expect_error(v_unlinked, true, '42501', 'SPRAY_EDIT_FORBIDDEN');
  perform pg_temp.t259_expect_error(v_existing, true, '42501', 'SPRAY_EDIT_FORBIDDEN');
  perform pg_temp.t259_login(v_foreign_owner);
  perform pg_temp.t259_expect_error(v_unlinked, true, '42501', 'SPRAY_EDIT_FORBIDDEN');
  perform pg_temp.t259_login(v_operator);
  perform pg_temp.t259_expect_error(gen_random_uuid(), true, 'P0002', 'SPRAY_NOT_FOUND');
  -- T3-5: template, tombstone and manual workflow exclusions precede completion.
  perform pg_temp.t259_expect_error(v_template, true, '55000', 'SPRAY_TEMPLATE');
  perform pg_temp.t259_expect_error(v_deleted, true, '55000', 'SPRAY_DELETED');
  perform pg_temp.t259_expect_error(v_manual, true, '42501', 'MANUAL_SPRAY_WORKFLOW_REQUIRED');
  perform pg_temp.t259_expect_error(v_manual_id_only, true, '42501', 'MANUAL_SPRAY_WORKFLOW_REQUIRED');
  if coalesce(current_setting('vinetrack.manual_spray_rpc', true), '') <> '' then
    raise exception 'T5: new RPC changed manual bypass flag';
  end if;
  -- Check the original SQL 232 direct-update guard itself as an authorised manual actor.
  perform pg_temp.t259_login(v_supervisor);
  begin
    update public.spray_records set notes = 'Must fail' where id = v_manual;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  end;
  if v_state is distinct from '42501' or v_message is distinct from 'Manual sprays must use the coordinated manual RPC' then
    raise exception 'T5: SQL 232 guard was bypassed';
  end if;
  perform pg_temp.t259_login(v_operator);

  -- T6: explicit completion wins even over an active historical Trip; no audit write.
  select to_jsonb(r) into v_before from public.spray_records r where r.id = v_existing;
  v_result := public.complete_spray_record(v_existing);
  v_retry := public.complete_spray_record(v_existing, true);
  select to_jsonb(r) into v_after from public.spray_records r where r.id = v_existing;
  if v_result is distinct from v_retry or v_before is distinct from v_after
     or (v_result->>'endTime')::timestamptz is distinct from v_existing_end
     or v_result->>'completionSource' is distinct from 'existing' then
    raise exception 'T6: existing completion was not idempotent';
  end if;
  -- T7/11: allow_unlinked never authorises any linked record, including bad links.
  perform pg_temp.t259_expect_error(v_active, true, '55000', 'ACTIVE_TRIP');
  perform pg_temp.t259_expect_error(v_unfinished, true, '55000', 'LINKED_TRIP_NOT_ENDED');
  perform pg_temp.t259_expect_error(v_missing, true, '55000', 'LINKED_TRIP_UNAVAILABLE');
  perform pg_temp.t259_expect_error(v_dead_link, true, '55000', 'LINKED_TRIP_UNAVAILABLE');
  perform pg_temp.t259_expect_error(v_cross_link, true, '55000', 'LINKED_TRIP_VINEYARD_MISMATCH');
  perform pg_temp.t259_expect_error(v_bad_link, true, '55000', 'LINKED_TRIP_INCONSISTENT');
  -- An ended, inactive Trip remains authoritative despite a stale paused flag.
  select to_jsonb(t) into v_paused_trip_before from public.trips t where t.id = v_paused_trip;
  if (v_paused_trip_before->>'end_time')::timestamptz is distinct from v_end
     or (v_paused_trip_before->>'is_active')::boolean is distinct from false
     or (v_paused_trip_before->>'is_paused')::boolean is distinct from true then
    raise exception 'Paused-ended Trip fixture does not match the completion scenario';
  end if;
  v_result := public.complete_spray_record(v_paused_link, false);
  select to_jsonb(r) into v_after from public.spray_records r where r.id = v_paused_link;
  if (v_after->>'end_time')::timestamptz is distinct from v_end
     or (v_result->>'endTime')::timestamptz is distinct from v_end
     or v_result->>'completionSource' is distinct from 'trip_end' then
    raise exception 'Paused-ended Trip did not supply exact Spray completion';
  end if;
  select to_jsonb(t) into v_after from public.trips t where t.id = v_paused_trip;
  if v_after is distinct from v_paused_trip_before then
    raise exception 'Paused-ended Trip row mutated during Spray completion';
  end if;
  perform pg_temp.t259_expect_error(v_manual_trip_link, true, '55000', 'LINKED_TRIP_INCONSISTENT');

  -- T8/12/13/15/16: exact microsecond Trip completion; strict full-row comparison
  -- excludes ONLY completion/audit fields. Also proves retained spray_job_id.
  select to_jsonb(r) into v_before from public.spray_records r where r.id = v_ended;
  v_result := public.complete_spray_record(v_ended, false);
  select to_jsonb(r) into v_after from public.spray_records r where r.id = v_ended;
  if (v_result->>'endTime')::timestamptz is distinct from v_end or v_end = now()
     or v_result->>'completionSource' is distinct from 'trip_end'
     or v_result->>'sprayRecordId' is distinct from v_ended::text
     or v_result->'serverConfirmed' is distinct from 'true'::jsonb
     or (v_before - v_audit_exclusions) is distinct from (v_after - v_audit_exclusions)
     or v_after->>'spray_job_id' is distinct from v_job::text
     or (v_after->>'sync_version')::integer is distinct from ((v_before->>'sync_version')::integer + 1)
     or v_after->>'updated_by' is distinct from v_operator::text
     or (v_after->>'client_updated_at')::timestamptz is distinct from now()
     or (v_after->>'updated_at')::timestamptz is distinct from now()
     or (v_result->>'syncVersion')::integer is distinct from (v_after->>'sync_version')::integer
     or (v_result->>'updatedAt')::timestamptz is distinct from (v_after->>'updated_at')::timestamptz
     or v_result->>'updatedBy' is distinct from v_operator::text
     or (v_result->>'clientUpdatedAt')::timestamptz is distinct from now() then
    raise exception 'T8/12/13/15: linked completion or narrow audit contract failed';
  end if;
  v_retry := public.complete_spray_record(v_ended, true);
  select to_jsonb(r) into v_before from public.spray_records r where r.id = v_ended;
  if v_retry->>'completionSource' is distinct from 'existing'
     or (v_retry - 'completionSource') is distinct from (v_result - 'completionSource')
     or v_before is distinct from v_after then
    raise exception 'T16: linked completion retry moved completion or audit';
  end if;

  -- T9: false, omitted default and NULL all require affirmative confirmation.
  select to_jsonb(r) into v_before from public.spray_records r where r.id = v_unlinked;
  perform pg_temp.t259_expect_error(v_unlinked, false, '55000', 'UNLINKED_CONFIRMATION_REQUIRED');
  perform pg_temp.t259_expect_error(v_unlinked, null, '55000', 'UNLINKED_CONFIRMATION_REQUIRED');
  v_state := null;
  begin perform public.complete_spray_record(v_unlinked);
  exception when others then get stacked diagnostics v_state = returned_sqlstate, v_message = message_text; end;
  if v_state is distinct from '55000' or v_message is distinct from 'UNLINKED_CONFIRMATION_REQUIRED' then
    raise exception 'T9: default did not require confirmation';
  end if;
  select to_jsonb(r) into v_after from public.spray_records r where r.id = v_unlinked;
  if v_before is distinct from v_after then raise exception 'T9: rejected confirmation changed Spray'; end if;
  -- T10/12/15/16: canonical server now, narrow write, repeat performs no write.
  v_result := public.complete_spray_record(v_unlinked, true);
  select to_jsonb(r) into v_after from public.spray_records r where r.id = v_unlinked;
  if (v_result->>'endTime')::timestamptz is distinct from now()
     or v_result->>'completionSource' is distinct from 'server_now'
     or v_result->'serverConfirmed' is distinct from 'true'::jsonb
     or v_after->>'trip_id' is not null
     or (v_before - v_audit_exclusions) is distinct from (v_after - v_audit_exclusions)
     or (v_after->>'sync_version')::integer is distinct from ((v_before->>'sync_version')::integer + 1)
     or v_after->>'updated_by' is distinct from v_operator::text
     or (v_after->>'client_updated_at')::timestamptz is distinct from now()
     or (v_after->>'updated_at')::timestamptz is distinct from now()
     or v_result->>'sprayRecordId' is distinct from v_unlinked::text
     or (v_result->>'syncVersion')::integer is distinct from (v_after->>'sync_version')::integer
     or (v_result->>'updatedAt')::timestamptz is distinct from now()
     or v_result->>'updatedBy' is distinct from v_operator::text
     or (v_result->>'clientUpdatedAt')::timestamptz is distinct from now() then
    raise exception 'T10/12/15: unlinked completion/audit contract failed';
  end if;
  v_retry := public.complete_spray_record(v_unlinked, false);
  select to_jsonb(r) into v_before from public.spray_records r where r.id = v_unlinked;
  if v_retry->>'completionSource' is distinct from 'existing'
     or (v_retry - 'completionSource') is distinct from (v_result - 'completionSource')
     or v_before is distinct from v_after then
    raise exception 'T16: unlinked completion retry moved completion or audit';
  end if;

  -- Preserve the four existing roles, not just owner/manager/supervisor.
  for v_index in 1..4 loop
    perform pg_temp.t259_login(v_actors[v_index]);
    v_result := public.complete_spray_record(v_role_ids[v_index], true);
    if v_result->>'completionSource' is distinct from 'server_now'
       or v_result->>'updatedBy' is distinct from v_actors[v_index]::text then
      raise exception 'Existing operational role % could not complete', v_index;
    end if;
  end loop;

  -- T7/11/12/13/14: EVERY rejected Spray, EVERY Trip (including foreign/deleted),
  -- Program job, real tank actual, weather, costs and manual operation unchanged.
  perform pg_temp.t259_login(null, 'postgres');
  select jsonb_agg(to_jsonb(r) order by r.id) into v_after
    from public.spray_records r where r.id = any(v_rejected);
  if v_after is distinct from v_rejected_before then raise exception 'Rejected RPC changed Spray data'; end if;
  select jsonb_agg(to_jsonb(t) order by t.id) into v_after
    from public.trips t where t.vineyard_id in (v_vineyard,v_other);
  if v_after is distinct from v_trips_before then raise exception 'T14: Trip row mutated'; end if;
  select jsonb_agg(to_jsonb(a) order by a.id) into v_after
    from public.spray_tank_actuals a where a.vineyard_id = v_vineyard;
  if v_after is distinct from v_actuals_before then raise exception 'T12: tank actuals mutated'; end if;
  select to_jsonb(j) into v_after from public.spray_jobs j where j.id = v_job;
  if v_after is distinct from v_jobs_before then raise exception 'T13: Program job mutated'; end if;
  select jsonb_agg(to_jsonb(w) order by w.id) into v_after
    from public.trip_weather_observations w where w.vineyard_id = v_vineyard;
  if v_after is distinct from v_weather_before then raise exception 'Trip weather mutated'; end if;
  select jsonb_agg(to_jsonb(c) order by c.id) into v_after
    from public.trip_cost_allocations c where c.vineyard_id = v_vineyard;
  if v_after is distinct from v_costs_before then raise exception 'Trip costing mutated'; end if;
  select jsonb_agg(to_jsonb(o) order by o.operation_id) into v_after
    from public.manual_spray_operations o where o.vineyard_id = v_vineyard;
  if v_after is distinct from v_manual_ops_before then raise exception 'Manual operation contract mutated'; end if;
  select jsonb_agg(pg_get_triggerdef(oid) order by tgname) into v_after
    from pg_trigger where tgname in ('trg_spray_records_manual_guard_v1','trg_trips_manual_guard_v1');
  if v_after is distinct from v_guard_triggers_before
     or pg_get_functiondef('public.manual_spray_guard_v1()'::regprocedure) is distinct from v_guard_before then
    raise exception 'T5: SQL 232 guard definition or triggers changed';
  end if;
  raise notice '259 completion contract assertions passed (T1-T16 plus ACL, default/NULL confirmation, all four roles and inconsistent links).';
end;
$tests$;

rollback;

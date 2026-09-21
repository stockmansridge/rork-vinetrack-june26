begin;

-- Fixture-based V2 tests. All fixtures, calls, extension state, and mutations roll back.
create extension if not exists dblink;

do $tests$
declare
  v_user uuid := gen_random_uuid();
  v_vineyard uuid := gen_random_uuid();
  v_trip_a uuid := gen_random_uuid();
  v_trip_b uuid := gen_random_uuid();
  v_block_a uuid := gen_random_uuid();
  v_block_b uuid := gen_random_uuid();
  v_operation_a uuid := gen_random_uuid();
  v_operation_same_logical uuid := gen_random_uuid();
  v_operation_partial uuid := gen_random_uuid();
  v_operation_rate uuid := gen_random_uuid();
  v_assignment_a jsonb;
  v_assignment_changed jsonb;
  v_partial_assignments jsonb;
  v_result jsonb;
  v_before jsonb;
  v_after jsonb;
  v_started_at timestamptz;
  v_connection_name text := 't245_' || replace(gen_random_uuid()::text, '-', '');
  v_lock_key bigint;
  v_count bigint;
begin
  perform set_config('role','postgres',true);
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values(v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    't245-actor-' || v_user || '@test.local','x',now(),now(),now());
  insert into public.profiles(id,email,full_name)
  values(v_user,'t245-actor-' || v_user || '@test.local','T245 Recovery Actor');
  insert into public.vineyards(id,name) values(v_vineyard,'T245 Recovery Vineyard');
  insert into public.vineyard_members(vineyard_id,user_id,role) values(v_vineyard,v_user,'supervisor');
  insert into public.paddocks(id,vineyard_id,name,rows) values
    (v_block_a,v_vineyard,'T245 Historical Block',jsonb_build_array(jsonb_build_object('id','old-row-1','number',1,'startPoint',jsonb_build_object('latitude',-33.1,'longitude',149.1),'endPoint',jsonb_build_object('latitude',-33.2,'longitude',149.2)))),
    (v_block_b,v_vineyard,'T245 Current Block',jsonb_build_array(jsonb_build_object('id','new-row-2','number',2)));
  insert into public.trips(id,vineyard_id,trip_function,row_sequence) values
    (v_trip_a,v_vineyard,'spraying','[1,2]'::jsonb),
    (v_trip_b,v_vineyard,'spraying','[1]'::jsonb);

  v_assignment_a := jsonb_build_array(jsonb_build_object(
    'blockId',v_block_a,'blockName','T245 Historical Block',
    'rowIdentity',v_block_a::text || ':old-row-1','rowNumber',1,
    'tankSessionId','','status','Complete','assignmentSource','saved_plan_identity','confidence',1,
    'originalEvidence',jsonb_build_object(
      'derivationVersion','spray-row-recovery-v1','pathNumber',1,
      'candidateBlockIds',jsonb_build_array(v_block_a::text),
      'matchingRowIds',jsonb_build_array('old-row-1')
    )
  ));
  v_assignment_changed := jsonb_build_array(jsonb_build_object(
    'blockId',v_block_b,'blockName','T245 Current Block',
    'rowIdentity',v_block_b::text || ':new-row-1','rowNumber',1,
    'tankSessionId','','status','Complete','assignmentSource','saved_plan_identity','confidence',1,
    'originalEvidence',jsonb_build_object(
      'derivationVersion','spray-row-recovery-v1','pathNumber',1,
      'candidateBlockIds',jsonb_build_array(v_block_b::text),
      'matchingRowIds',jsonb_build_array('new-row-1')
    )
  ));

  perform set_config('request.jwt.claims',json_build_object('sub',v_user::text,'role','service_role')::text,true);

  -- Exact replay keeps one operation and one immutable evidence set.
  v_result := public.recover_spray_row_assignments_v2(v_operation_a,v_trip_a,v_user,v_assignment_a);
  if v_result->>'status' <> 'recovered' then
    raise exception 'T1 FAILED: first recovery returned %',v_result;
  end if;
  v_result := public.recover_spray_row_assignments_v2(v_operation_a,v_trip_a,v_user,v_assignment_a);
  if v_result->>'status' <> 'already_recovered'
     or (select count(*) from public.spray_row_recovery_operations where trip_id=v_trip_a) <> 1
     or (select count(*) from public.spray_row_assignment_evidence where trip_id=v_trip_a) <> 1 then
    raise exception 'T1 FAILED: exact replay duplicated operation or evidence: %',v_result;
  end if;

  -- A different operation id with the same canonical fingerprint resolves logically.
  v_result := public.recover_spray_row_assignments_v2(v_operation_same_logical,v_trip_a,v_user,v_assignment_a);
  if v_result->>'status' <> 'already_recovered'
     or v_result->>'operationId' <> v_operation_a::text
     or (select count(*) from public.spray_row_recovery_operations where trip_id=v_trip_a) <> 1 then
    raise exception 'T2 FAILED: logical replay was not deduplicated: %',v_result;
  end if;

  -- One operation id cannot identify changed content or another trip.
  v_result := public.recover_spray_row_assignments_v2(v_operation_a,v_trip_a,v_user,v_assignment_changed);
  if v_result->>'status' <> 'operation_id_conflict' or (v_result->>'retryable')::boolean then
    raise exception 'T3 FAILED: changed-payload operation reuse was not a deterministic conflict: %',v_result;
  end if;
  v_result := public.recover_spray_row_assignments_v2(v_operation_a,v_trip_b,v_user,v_assignment_a);
  if v_result->>'status' <> 'operation_id_conflict' or (v_result->>'retryable')::boolean then
    raise exception 'T4 FAILED: cross-trip operation reuse was not a deterministic conflict: %',v_result;
  end if;

  -- Save the historical row byte-for-byte, then replace today's paddock geometry.
  select to_jsonb(e) into v_before
  from public.spray_row_assignment_evidence e where e.trip_id=v_trip_a and e.row_number=1;
  update public.paddocks set rows=jsonb_build_array(
    jsonb_build_object('id','geometry-replaced','number',99,'startPoint',jsonb_build_object('latitude',-34.0,'longitude',150.0))
  ) where id=v_block_a;
  update public.spray_row_recovery_trip_guard
  set last_started_at=clock_timestamp()-interval '3 seconds'
  where trip_id=v_trip_a;

  v_partial_assignments := jsonb_build_array(
    v_assignment_changed->0,
    jsonb_build_object(
      'blockId',v_block_b,'blockName','T245 Current Block',
      'rowIdentity',v_block_b::text || ':new-row-2','rowNumber',2,
      'tankSessionId','','status','Partial','assignmentSource','saved_plan_identity','confidence',1,
      'originalEvidence',jsonb_build_object(
        'derivationVersion','spray-row-recovery-v1','pathNumber',2,
        'candidateBlockIds',jsonb_build_array(v_block_b::text),
        'matchingRowIds',jsonb_build_array('new-row-2')
      )
    )
  );
  v_result := public.recover_spray_row_assignments_v2(v_operation_partial,v_trip_a,v_user,v_partial_assignments);
  select to_jsonb(e) into v_after
  from public.spray_row_assignment_evidence e where e.trip_id=v_trip_a and e.row_number=1;
  if v_result->>'status' <> 'recovered_with_preserved_history'
     or (v_result->>'retryable')::boolean
     or (v_result->>'inserted')::integer <> 1
     or (v_result->>'preserved')::integer <> 1
     or jsonb_array_length(v_result->'conflicts') <> 1
     or v_after is distinct from v_before
     or (select count(*) from public.spray_row_assignment_evidence where trip_id=v_trip_a) <> 2 then
    raise exception 'T5 FAILED: partial preservation was not successful and immutable: %',v_result;
  end if;

  -- The non-blocking advisory lock returns immediately instead of joining a row-lock queue.
  v_lock_key := hashtextextended('spray-row-recovery-v2:' || v_trip_a::text,0);
  perform dblink_connect(v_connection_name,'dbname=' || current_database());
  perform dblink_send_query(v_connection_name,format(
    'with locked as materialized (select pg_advisory_lock(%s)), slept as materialized (select pg_sleep(2) from locked), unlocked as materialized (select pg_advisory_unlock(%s) as value from slept) select value from unlocked',
    v_lock_key,v_lock_key
  ));
  perform pg_sleep(0.15);
  v_started_at := clock_timestamp();
  v_result := public.recover_spray_row_assignments_v2(gen_random_uuid(),v_trip_a,v_user,'[]'::jsonb);
  if v_result->>'status' <> 'already_in_progress'
     or clock_timestamp()-v_started_at > interval '1 second' then
    raise exception 'T6 FAILED: concurrent same-trip recovery queued instead of returning: %',v_result;
  end if;
  perform * from dblink_get_result(v_connection_name) as remote_result(unlocked boolean);
  perform dblink_disconnect(v_connection_name);

  -- Five accepted novel starts per minute are bounded; exact/logical replays above bypassed capacity.
  update public.spray_row_recovery_trip_guard set
    window_started_at=clock_timestamp(),accepted_count=5,last_started_at=clock_timestamp()-interval '3 seconds'
  where trip_id=v_trip_a;
  v_result := public.recover_spray_row_assignments_v2(v_operation_rate,v_trip_a,v_user,'[]'::jsonb);
  if v_result->>'status' <> 'rate_limited' or (v_result->>'retryAfterSeconds')::integer <> 60 then
    raise exception 'T7 FAILED: novel-attempt guard was not bounded: %',v_result;
  end if;

  select count(*) into v_count from public.spray_row_recovery_operations where trip_id=v_trip_a;
  if v_count <> 2 then raise exception 'T8 FAILED: rejected/replayed calls committed unexpected operations: %',v_count; end if;

  if has_function_privilege('service_role','public.recover_spray_row_assignments_v1(uuid,uuid,uuid,jsonb)','execute') then
    raise exception 'T9 FAILED: V1 is executable by service_role';
  end if;
  if has_function_privilege('anon','public.recover_spray_row_assignments_v2(uuid,uuid,uuid,jsonb)','execute')
     or has_function_privilege('authenticated','public.recover_spray_row_assignments_v2(uuid,uuid,uuid,jsonb)','execute')
     or not has_function_privilege('service_role','public.recover_spray_row_assignments_v2(uuid,uuid,uuid,jsonb)','execute') then
    raise exception 'T10 FAILED: V2 execution boundary changed';
  end if;

  raise notice 'SQL 245 spray-row recovery behavioral tests passed; transaction will roll back.';
exception when others then
  begin perform dblink_disconnect(v_connection_name); exception when others then null; end;
  raise;
end
$tests$;

rollback;

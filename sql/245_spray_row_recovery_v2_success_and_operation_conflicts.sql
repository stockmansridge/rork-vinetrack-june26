begin;

-- SQL 244 is already live. This additive replacement keeps its V2 persistence
-- boundary while making committed preservation outcomes successful and primary-key
-- collisions deterministic.
create or replace function public.recover_spray_row_assignments_v2(
  p_operation_id uuid,
  p_trip_id uuid,
  p_actor_user_id uuid,
  p_assignments jsonb
) returns jsonb
language plpgsql
security definer
set search_path=public
as $fn$
declare
  t public.trips;
  a jsonb;
  canonical_assignments jsonb;
  fingerprint text;
  prior_operation public.spray_row_recovery_operations;
  logical_operation public.spray_row_recovery_operations;
  guard_row public.spray_row_recovery_trip_guard;
  v_block_id uuid;
  v_confidence double precision;
  v_row_number double precision;
  v_tank_number integer;
  session_id text;
  source text;
  evidence jsonb;
  existing_evidence public.spray_row_assignment_evidence;
  inserted_count integer := 0;
  preserved_count integer := 0;
  conflicts jsonb := '[]'::jsonb;
  result_evidence jsonb;
  now_at timestamptz := clock_timestamp();
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service recovery authority required' using errcode='42501';
  end if;
  if p_operation_id is null or p_trip_id is null or p_actor_user_id is null
     or jsonb_typeof(p_assignments) <> 'array'
     or jsonb_array_length(p_assignments) > 500 then
    raise exception 'Invalid recovery request' using errcode='22023';
  end if;

  select coalesce(jsonb_agg(normalized order by
    normalized->>'blockId', normalized->>'rowIdentity', normalized->>'tankSessionId',
    normalized->>'rowNumber', normalized->>'tankNumber'), '[]'::jsonb)
  into canonical_assignments
  from (
    select jsonb_strip_nulls(jsonb_build_object(
      'blockId', value->'blockId',
      'blockName', value->'blockName',
      'rowIdentity', value->'rowIdentity',
      'rowNumber', value->'rowNumber',
      'tankSessionId', value->'tankSessionId',
      'tankNumber', value->'tankNumber',
      'status', value->'status',
      'assignmentSource', value->'assignmentSource',
      'confidence', value->'confidence',
      'originalEvidence', value->'originalEvidence'
    )) normalized
    from jsonb_array_elements(p_assignments)
  ) canonical;
  fingerprint := 'v2:' || md5(canonical_assignments::text);

  -- Exact operation and logical replays never consume guard capacity.
  select * into prior_operation
  from public.spray_row_recovery_operations
  where operation_id=p_operation_id;
  if prior_operation.operation_id is not null then
    if prior_operation.trip_id <> p_trip_id
       or prior_operation.assignment_fingerprint <> fingerprint then
      return jsonb_build_object(
        'status','operation_id_conflict',
        'operationId',p_operation_id,
        'retryable',false,
        'message','Recovery operation id was reused for a different request'
      );
    end if;
    select coalesce(jsonb_agg(to_jsonb(e) order by e.block_name_snapshot,e.row_number,e.row_identity),'[]'::jsonb)
      into result_evidence from public.spray_row_assignment_evidence e where e.trip_id=p_trip_id;
    return jsonb_build_object('status','already_recovered','operationId',p_operation_id,
      'assignmentFingerprint',fingerprint,'retryable',false,'evidence',result_evidence);
  end if;

  select * into logical_operation
  from public.spray_row_recovery_operations
  where trip_id=p_trip_id and assignment_fingerprint=fingerprint;
  if logical_operation.operation_id is not null then
    select coalesce(jsonb_agg(to_jsonb(e) order by e.block_name_snapshot,e.row_number,e.row_identity),'[]'::jsonb)
      into result_evidence from public.spray_row_assignment_evidence e where e.trip_id=p_trip_id;
    return jsonb_build_object('status','already_recovered','operationId',logical_operation.operation_id,
      'requestOperationId',p_operation_id,'assignmentFingerprint',fingerprint,
      'retryable',false,'evidence',result_evidence);
  end if;

  -- The non-blocking advisory guard prevents a same-trip row-lock queue.
  if not pg_try_advisory_xact_lock(hashtextextended('spray-row-recovery-v2:' || p_trip_id::text, 0)) then
    return jsonb_build_object('status','already_in_progress','operationId',p_operation_id,
      'assignmentFingerprint',fingerprint,'retryable',false,
      'message','Recovery is already in progress for this trip');
  end if;

  -- A concurrent winner may have committed before this transaction obtained the guard.
  select * into prior_operation
  from public.spray_row_recovery_operations
  where operation_id=p_operation_id;
  if prior_operation.operation_id is not null then
    if prior_operation.trip_id <> p_trip_id
       or prior_operation.assignment_fingerprint <> fingerprint then
      return jsonb_build_object(
        'status','operation_id_conflict',
        'operationId',p_operation_id,
        'retryable',false,
        'message','Recovery operation id was reused for a different request'
      );
    end if;
    select coalesce(jsonb_agg(to_jsonb(e) order by e.block_name_snapshot,e.row_number,e.row_identity),'[]'::jsonb)
      into result_evidence from public.spray_row_assignment_evidence e where e.trip_id=p_trip_id;
    return jsonb_build_object('status','already_recovered','operationId',p_operation_id,
      'assignmentFingerprint',fingerprint,'retryable',false,'evidence',result_evidence);
  end if;

  select * into logical_operation
  from public.spray_row_recovery_operations
  where trip_id=p_trip_id and assignment_fingerprint=fingerprint;
  if logical_operation.operation_id is not null then
    select coalesce(jsonb_agg(to_jsonb(e) order by e.block_name_snapshot,e.row_number,e.row_identity),'[]'::jsonb)
      into result_evidence from public.spray_row_assignment_evidence e where e.trip_id=p_trip_id;
    return jsonb_build_object('status','already_recovered','operationId',logical_operation.operation_id,
      'requestOperationId',p_operation_id,'assignmentFingerprint',fingerprint,
      'retryable',false,'evidence',result_evidence);
  end if;

  -- Novel fingerprints are deliberately bounded. Replays bypass this guard above.
  select * into guard_row from public.spray_row_recovery_trip_guard where trip_id=p_trip_id for update;
  if guard_row.trip_id is not null then
    if guard_row.last_started_at > now_at - interval '2 seconds' then
      return jsonb_build_object('status','rate_limited','operationId',p_operation_id,
        'assignmentFingerprint',fingerprint,'retryable',false,'retryAfterSeconds',2);
    end if;
    if guard_row.window_started_at > now_at - interval '1 minute' and guard_row.accepted_count >= 5 then
      return jsonb_build_object('status','rate_limited','operationId',p_operation_id,
        'assignmentFingerprint',fingerprint,'retryable',false,'retryAfterSeconds',60);
    end if;
  end if;

  select * into t from public.trips where id=p_trip_id and deleted_at is null;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if not (coalesce(t.trip_function,'')='spraying' or exists(
    select 1 from public.spray_records r
    where r.trip_id=t.id and not r.is_template and r.deleted_at is null
  )) then
    raise exception 'Trip is not a spray trip' using errcode='22023';
  end if;
  if not exists(
    select 1 from public.vineyard_members
    where vineyard_id=t.vineyard_id and user_id=p_actor_user_id
      and role in ('owner','manager','supervisor')
  ) then
    raise exception 'Recovery access required' using errcode='42501';
  end if;

  insert into public.spray_row_recovery_trip_guard(trip_id,window_started_at,accepted_count,last_started_at)
  values(t.id,now_at,1,now_at)
  on conflict(trip_id) do update set
    window_started_at=case
      when public.spray_row_recovery_trip_guard.window_started_at <= now_at - interval '1 minute'
      then now_at else public.spray_row_recovery_trip_guard.window_started_at end,
    accepted_count=case
      when public.spray_row_recovery_trip_guard.window_started_at <= now_at - interval '1 minute'
      then 1 else public.spray_row_recovery_trip_guard.accepted_count+1 end,
    last_started_at=now_at;

  for a in select value from jsonb_array_elements(canonical_assignments) loop
    begin
      v_block_id := (a->>'blockId')::uuid;
      v_confidence := (a->>'confidence')::double precision;
      v_row_number := (a->>'rowNumber')::double precision;
      v_tank_number := nullif(a->>'tankNumber','')::integer;
    exception when others then
      raise exception 'Invalid assignment identity, path, or confidence' using errcode='22023';
    end;
    source := a->>'assignmentSource';
    session_id := coalesce(nullif(btrim(a->>'tankSessionId'),''),'');
    evidence := a->'originalEvidence';

    -- Existing evidence is immutable history. Preserve it before current-geometry checks.
    select * into existing_evidence
    from public.spray_row_assignment_evidence e
    where e.trip_id=t.id and (
      e.row_number=v_row_number or
      public.spray_report_safe_number_v1(e.original_evidence->>'pathNumber')=v_row_number
    )
    order by e.derived_at,e.id limit 1;
    if existing_evidence.id is not null then
      preserved_count := preserved_count + 1;
      if existing_evidence.block_id is distinct from v_block_id
         or existing_evidence.row_identity is distinct from btrim(a->>'rowIdentity')
         or existing_evidence.tank_session_id is distinct from session_id then
        conflicts := conflicts || jsonb_build_array(jsonb_build_object(
          'rowNumber',v_row_number,
          'code','historical_evidence_preserved',
          'existingEvidenceId',existing_evidence.id,
          'message','Existing historical recovery evidence was preserved unchanged'
        ));
      end if;
      existing_evidence := null;
      continue;
    end if;

    if v_confidence is null or v_confidence<>v_confidence or v_confidence<0 or v_confidence>1 then
      raise exception 'Invalid assignment confidence' using errcode='22023';
    end if;
    if source='gps_geometry_intersection' and v_confidence<0.9 then
      raise exception 'GPS/geometry assignments require confidence of at least 0.9' using errcode='22023';
    end if;
    if source not in ('saved_plan_identity','session_boundary_order','gps_geometry_intersection') then
      raise exception 'Unsupported derived assignment evidence' using errcode='22023';
    end if;
    if jsonb_typeof(evidence)<>'object'
       or evidence->>'derivationVersion'<>'spray-row-recovery-v1'
       or public.spray_report_safe_number_v1(evidence->>'pathNumber') is distinct from v_row_number then
      raise exception 'Shared recovery derivation evidence is required' using errcode='22023';
    end if;
    if 1<>(select count(*) from jsonb_array_elements(coalesce(t.row_sequence,'[]'::jsonb)) x
           where public.spray_report_safe_number_v1(x#>>'{}')=v_row_number) then
      raise exception 'Recovered path must occur exactly once in the recorded trip plan' using errcode='22023';
    end if;
    if not exists(select 1 from public.paddocks
                  where id=v_block_id and vineyard_id=t.vineyard_id and deleted_at is null) then
      raise exception 'Block identity is not available in this vineyard' using errcode='22023';
    end if;
    if not (coalesce(evidence->'candidateBlockIds','[]'::jsonb) ? v_block_id::text)
       or jsonb_array_length(coalesce(evidence->'matchingRowIds','[]'::jsonb))=0
       or position(v_block_id::text in a->>'rowIdentity')=0
       or exists(select 1 from jsonb_array_elements_text(evidence->'matchingRowIds') rid
                 where position(rid in a->>'rowIdentity')=0) then
      raise exception 'Saved row/block evidence does not support this assignment identity' using errcode='22023';
    end if;
    if session_id<>'' and not exists(
      select 1 from jsonb_array_elements(coalesce(t.tank_sessions,'[]'::jsonb)) s
      where coalesce(s->>'id',s->>'tank_session_id')=session_id
    ) then
      raise exception 'Tank session identity is not recorded on this trip' using errcode='22023';
    end if;

    insert into public.spray_row_assignment_evidence(
      operation_id,vineyard_id,trip_id,block_id,block_name_snapshot,row_identity,row_number,
      tank_session_id,tank_number,status,assignment_source,confidence,original_evidence,derived_by
    ) values(
      p_operation_id,t.vineyard_id,t.id,v_block_id,
      coalesce(nullif(btrim(a->>'blockName'),''),(select name from public.paddocks where id=v_block_id),'Archived block'),
      btrim(a->>'rowIdentity'),v_row_number,session_id,v_tank_number,
      coalesce(nullif(a->>'status',''),'Not recorded'),source,v_confidence,evidence,p_actor_user_id
    ) on conflict(trip_id,block_id,row_identity,tank_session_id) do nothing;
    if found then inserted_count := inserted_count + 1; end if;
  end loop;

  insert into public.spray_row_recovery_operations(
    operation_id,vineyard_id,trip_id,actor_user_id,assignment_fingerprint,assignment_count
  ) values(
    p_operation_id,t.vineyard_id,t.id,p_actor_user_id,fingerprint,jsonb_array_length(canonical_assignments)
  );

  select coalesce(jsonb_agg(to_jsonb(e) order by e.block_name_snapshot,e.row_number,e.row_identity),'[]'::jsonb)
    into result_evidence from public.spray_row_assignment_evidence e where e.trip_id=t.id;
  return jsonb_build_object(
    'status',case
      when jsonb_array_length(conflicts)>0 then 'recovered_with_preserved_history'
      when inserted_count=0 then 'already_recovered'
      else 'recovered' end,
    'operationId',p_operation_id,
    'assignmentFingerprint',fingerprint,
    'inserted',inserted_count,
    'preserved',preserved_count,
    'retryable',false,
    'conflicts',conflicts,
    'evidence',result_evidence
  );
exception
  when unique_violation then
    -- Either uniqueness boundary can win a concurrent race. Resolve both into the
    -- public contract rather than leaking SQLSTATE 23505.
    select * into prior_operation
    from public.spray_row_recovery_operations
    where operation_id=p_operation_id;
    if prior_operation.operation_id is not null then
      if prior_operation.trip_id <> p_trip_id
         or prior_operation.assignment_fingerprint <> fingerprint then
        return jsonb_build_object(
          'status','operation_id_conflict',
          'operationId',p_operation_id,
          'retryable',false,
          'message','Recovery operation id was reused for a different request'
        );
      end if;
      select coalesce(jsonb_agg(to_jsonb(e) order by e.block_name_snapshot,e.row_number,e.row_identity),'[]'::jsonb)
        into result_evidence from public.spray_row_assignment_evidence e where e.trip_id=p_trip_id;
      return jsonb_build_object('status','already_recovered','operationId',p_operation_id,
        'assignmentFingerprint',fingerprint,'retryable',false,'evidence',result_evidence);
    end if;

    select * into logical_operation
    from public.spray_row_recovery_operations
    where trip_id=p_trip_id and assignment_fingerprint=fingerprint;
    if logical_operation.operation_id is not null then
      select coalesce(jsonb_agg(to_jsonb(e) order by e.block_name_snapshot,e.row_number,e.row_identity),'[]'::jsonb)
        into result_evidence from public.spray_row_assignment_evidence e where e.trip_id=p_trip_id;
      return jsonb_build_object('status','already_recovered','operationId',logical_operation.operation_id,
        'requestOperationId',p_operation_id,'assignmentFingerprint',fingerprint,
        'retryable',false,'evidence',result_evidence);
    end if;
    raise;
end
$fn$;

-- Preserve SQL 244's production authority boundary explicitly.
revoke all on function public.recover_spray_row_assignments_v1(uuid,uuid,uuid,jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.recover_spray_row_assignments_v2(uuid,uuid,uuid,jsonb)
  from public, anon, authenticated;
grant execute on function public.recover_spray_row_assignments_v2(uuid,uuid,uuid,jsonb)
  to service_role;

commit;

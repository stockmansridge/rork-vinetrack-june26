-- Undeployed scoped recovery. One locked snapshot, current reversible ledger evidence
-- and exact receipts for uncertain requests. No historical writes or inferred history.
begin;
create function public.get_trip_occurrence_recovery_v1(p_trip_id uuid,p_operation_ids uuid[] default array[]::uuid[])
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $fn$
declare t public.trips; d jsonb; reversible jsonb; receipts jsonb;
begin
  if auth.uid() is null then raise exception 'OCCURRENCE_AUTH_REQUIRED' using errcode='42501'; end if;
  if p_trip_id is null or p_operation_ids is null or cardinality(p_operation_ids)>256 then
    raise exception 'OCCURRENCE_INVALID_REQUEST' using errcode='22023';
  end if;
  select * into t from public.trips where id=p_trip_id for share;
  if t.id is null or t.deleted_at is not null or not public.is_vineyard_member(t.vineyard_id) then
    raise exception 'OCCURRENCE_TRIP_FORBIDDEN' using errcode='42501';
  end if;
  d:=t.occurrence_coverage;
  perform public.validate_trip_occurrences_v1(d,t.vineyard_id);
  -- Current lastOperationId is required. Selection/reorder cannot masquerade as Undo.
  -- Finalised/inactive trips honestly have no live reversible target.
  select coalesce(jsonb_agg(jsonb_build_object('operationId',op.operation_id,'tripId',op.trip_id,
      'actorId',op.actor_id,'request',op.request,'result',op.result,
      'previousState',op.previous_state,'resultingState',op.resulting_state)
      order by (op.result#>>'{coverage,revision}')::bigint),'[]') into reversible
    from public.trip_occurrence_operations op
    where t.is_active and t.end_time is null and op.trip_id=t.id and op.occurrence_id is not null
      and d->'activeOrder' ? op.occurrence_id::text
      and d#>>array['states',op.occurrence_id::text,'lastOperationId']=op.operation_id::text
      and op.request#>>'{action,kind}' in ('setStatus','undo')
      and op.resulting_state=d#>array['states',op.occurrence_id::text]
      and op.previous_state is not null;
  select coalesce(jsonb_agg(jsonb_build_object('operationId',op.operation_id,'tripId',op.trip_id,
      'actorId',op.actor_id,'request',op.request,'result',op.result)
      order by (op.result#>>'{coverage,revision}')::bigint),'[]') into receipts
    from public.trip_occurrence_operations op where op.trip_id=t.id and op.actor_id=auth.uid()
      and op.operation_id=any(p_operation_ids);
  return jsonb_build_object('contract','vinetrack.occurrence-recovery','schemaVersion',1,
    'tripId',t.id,'vineyardId',t.vineyard_id,'coverage',d,'isActive',t.is_active,'endTime',t.end_time,
    'reversibleOperations',reversible,'receipts',receipts);
end $fn$;
-- This function shares the inaccessible authority role and the same member-read RLS.
alter function public.get_trip_occurrence_recovery_v1(uuid,uuid[]) owner to vinetrack_occurrence_writer;
revoke all on function public.get_trip_occurrence_recovery_v1(uuid,uuid[]) from public,anon,service_role;
grant execute on function public.get_trip_occurrence_recovery_v1(uuid,uuid[]) to authenticated;
commit;

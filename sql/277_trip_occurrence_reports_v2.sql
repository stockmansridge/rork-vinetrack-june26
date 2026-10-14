-- Undeployed, prospective readers. Prerequisite: 276 and current v1 report chain.
-- No historical DML; preserve canonical non-coverage facts and cost redaction.
begin;

do $wrap$
begin
  if to_regprocedure('public.get_spray_report_v1_pre_occurrence_v1(uuid)') is not null then
    raise exception 'Occurrence report wrapper already installed; inspect rather than wrap twice';
  end if;
  if to_regprocedure('public.get_spray_report_v1(uuid)') is null then
    raise exception 'Current canonical Spray Report v1 is required';
  end if;
  alter function public.get_spray_report_v1(uuid) rename to get_spray_report_v1_pre_occurrence_v1;
end $wrap$;
revoke all on function public.get_spray_report_v1_pre_occurrence_v1(uuid) from public,anon,authenticated,service_role;

create function public.get_spray_report_v1(p_trip_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $fn$
declare payload jsonb; d jsonb; conservative_rows jsonb;
begin
  -- Delegate all original authorization, spray eligibility and non-coverage facts.
  payload:=public.get_spray_report_v1_pre_occurrence_v1(p_trip_id);
  select occurrence_coverage into d from public.trips where id=p_trip_id;
  if d is null then return payload; end if;
  select coalesce(jsonb_agg(jsonb_build_object('rowNumber',x->'rowNumber','blockName',x->'blockName',
    'status','Not recorded','source','Occurrence-aware coverage requires v2','tank',null)),'[]')
    into conservative_rows from jsonb_array_elements(coalesce(payload->'rows','[]')) x;
  payload:=payload||jsonb_build_object('coverageBasis','occurrenceUnavailable','rows',conservative_rows,
    'warnings',coalesce(payload->'warnings','[]')||jsonb_build_array('Occurrence coverage is unavailable in this report version. Use the updated v2 report.'));
  -- Never publish numeric derived row assignments/tank ranges as independent evidence.
  if payload ? 'tankSessions' then
    payload:=jsonb_set(payload,'{tankSessions}',coalesce((select jsonb_agg(x||jsonb_build_object(
      'pathsCovered','[]'::jsonb,'startRow',null,'endRow',null,'assignmentSource','occurrenceUnavailable'))
      from jsonb_array_elements(payload->'tankSessions') x),'[]'));
  end if;
  return payload;
end $fn$;
revoke all on function public.get_spray_report_v1(uuid) from public,anon,service_role;
grant execute on function public.get_spray_report_v1(uuid) to authenticated;

create function public.get_spray_report_v2(p_trip_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $fn$
declare payload jsonb; t public.trips; d jsonb; rows jsonb; item jsonb; state jsonb;
  occurrence_id text; position integer; row_payload jsonb;
begin
  payload:=public.get_spray_report_v1_pre_occurrence_v1(p_trip_id);
  select * into t from public.trips where id=p_trip_id;
  d:=t.occurrence_coverage;
  if d is null then return payload||jsonb_build_object('schemaVersion','2.0','coverageBasis','legacyNumeric'); end if;
  perform public.validate_trip_occurrences_v1(d,t.vineyard_id);
  rows:='[]';
  -- Active order followed by tombstones: preserved evidence, separate current-work basis.
  for occurrence_id,position in select id,ord::integer from
    jsonb_array_elements_text((d->'activeOrder')||(d->'retired')) with ordinality x(id,ord) loop
    select value into item from jsonb_array_elements(d->'items') where value->>'occurrenceId'=occurrence_id;
    state:=d->'states'->occurrence_id;
    row_payload:=jsonb_build_object('occurrenceId',occurrence_id,'rowIdentity',occurrence_id,
      'planId',d->'planId','blockId',item->'blockId','blockName',item->'blockNameSnapshot',
      'rowNumber',item->'pathNumber','passOrdinal',item->'passOrdinal','direction',item->'direction',
      'position',position,'isRetired',d->'retired' ? occurrence_id,'state',state->'status',
      'status',case state->>'status' when 'done' then 'Complete' when 'skipped' then 'Skipped' else 'Not recorded' end,
      'source',coalesce(state->>'source','notRecorded'),'tank',null,'tankSessionIds',state->'tankSessionIds',
      'lastOperationId',state->'lastOperationId');
    rows:=rows||jsonb_build_array(row_payload);
  end loop;
  payload:=payload||jsonb_build_object('schemaVersion','2.0','coverageBasis','plannedOccurrencesV1',
    'coverageContract',jsonb_build_object('contract',d->'contract','schemaVersion',d->'schemaVersion',
      'planId',d->'planId','revision',d->'revision','planRevision',d->'planRevision'),
    'rows',rows);
  if payload ? 'tankSessions' then
    payload:=jsonb_set(payload,'{tankSessions}',coalesce((select jsonb_agg(x||jsonb_build_object(
      'pathsCovered','[]'::jsonb,'startRow',null,'endRow',null,'assignmentSource','occurrenceLinks',
      'occurrenceIds',coalesce((select jsonb_agg(s.key) from jsonb_each(d->'states') s
         where s.value->'tankSessionIds' ? (x->>'tankSessionId')),'[]'::jsonb)))
      from jsonb_array_elements(payload->'tankSessions') x),'[]'));
  end if;
  return payload;
end $fn$;
revoke all on function public.get_spray_report_v2(uuid) from public,anon,service_role;
grant execute on function public.get_spray_report_v2(uuid) to authenticated;

-- Applies at the existing privileged recovery boundary, irrespective of edge version.
-- Legacy recovery remains untouched; occurrence trips cannot acquire numeric evidence.
create function public.guard_occurrence_numeric_recovery_v1() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $fn$
begin
  if exists(select 1 from public.trips where id=new.trip_id and occurrence_coverage is not null) then
    raise exception 'OCCURRENCE_UPDATE_REQUIRED' using errcode='0A000',
      detail='Numeric row recovery cannot mutate an occurrence-aware trip.';
  end if;
  return new;
end $fn$;
create trigger aaa_occurrence_numeric_recovery_guard before insert or update on public.spray_row_assignment_evidence
  for each row execute function public.guard_occurrence_numeric_recovery_v1();
revoke all on function public.guard_occurrence_numeric_recovery_v1() from public,anon,authenticated,service_role;
commit;

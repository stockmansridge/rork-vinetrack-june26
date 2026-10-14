-- Prospective occurrence authority foundation. Undeployed; no historical DML.
-- Requires 006 and the existing auth.uid()/vineyard role contracts.
-- Native producers MUST remain disabled until all consumers and replay pass.
begin;
alter table public.trips add column if not exists occurrence_coverage jsonb;
comment on column public.trips.occurrence_coverage is
  'NULL means unchanged legacy rules. Non-null: occurrence document and operation ledger are sole coverage authority. Never downgrade to numeric membership.';

do $role$
begin
  if not exists(select 1 from pg_roles where rolname='vinetrack_occurrence_writer') then
    create role vinetrack_occurrence_writer nologin nosuperuser nocreatedb nocreaterole noinherit nobypassrls;
  end if;
  if exists(select 1 from pg_roles where rolname='vinetrack_occurrence_writer' and
    (rolcanlogin or rolsuper or rolcreaterole or rolbypassrls)) or exists(
    select 1 from pg_auth_members where roleid='vinetrack_occurrence_writer'::regrole) then
    raise exception 'Unsafe existing occurrence writer role';
  end if;
end $role$;
grant usage on schema public,auth to vinetrack_occurrence_writer;
grant execute on function auth.uid(),public.has_vineyard_role(uuid,text[]),public.is_vineyard_member(uuid) to vinetrack_occurrence_writer;
grant select,insert,update on public.trips to vinetrack_occurrence_writer;
grant select on public.paddocks to vinetrack_occurrence_writer;
create policy trip_occurrence_rpc_select on public.trips for select to vinetrack_occurrence_writer using(public.is_vineyard_member(vineyard_id));
create policy trip_occurrence_rpc_insert on public.trips for insert to vinetrack_occurrence_writer with check(public.has_vineyard_role(vineyard_id,array['owner','manager','supervisor','operator']));
create policy trip_occurrence_rpc_update on public.trips for update to vinetrack_occurrence_writer
  using(public.has_vineyard_role(vineyard_id,array['owner','manager','supervisor','operator']))
  with check(public.has_vineyard_role(vineyard_id,array['owner','manager','supervisor','operator']));
create policy trip_occurrence_rpc_blocks on public.paddocks for select to vinetrack_occurrence_writer using(public.is_vineyard_member(vineyard_id));

create table public.trip_occurrence_operations (
  operation_id uuid primary key, trip_id uuid not null references public.trips(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id), actor_id uuid not null,
  request jsonb not null, result jsonb not null, occurrence_id uuid,
  previous_state jsonb, resulting_state jsonb, accepted_at timestamptz not null default clock_timestamp()
);
create index trip_occurrence_operations_trip on public.trip_occurrence_operations(trip_id,accepted_at,operation_id);
alter table public.trip_occurrence_operations enable row level security;
revoke all on public.trip_occurrence_operations from public,anon,authenticated,service_role;
grant select on public.trip_occurrence_operations to authenticated;
create policy trip_occurrence_operations_members on public.trip_occurrence_operations for select to authenticated using(public.is_vineyard_member(vineyard_id));
grant select,insert on public.trip_occurrence_operations to vinetrack_occurrence_writer;
create policy trip_occurrence_operations_rpc_read on public.trip_occurrence_operations for select to vinetrack_occurrence_writer using(public.is_vineyard_member(vineyard_id));
create policy trip_occurrence_operations_rpc_insert on public.trip_occurrence_operations for insert to vinetrack_occurrence_writer
  with check(actor_id=auth.uid() and public.has_vineyard_role(vineyard_id,array['owner','manager','supervisor','operator']));

-- Scope-linked setup validation reads through a narrow definer helper, not client table grants.
create function public.validate_occurrence_setup_links_v1(v uuid,setup jsonb) returns void
language plpgsql security definer set search_path=pg_catalog,public as $fn$
begin
  if auth.uid() is null or not public.has_vineyard_role(v,array['owner','manager','supervisor','operator']) then
    raise exception 'OCCURRENCE_TRIP_FORBIDDEN' using errcode='42501';
  end if;
  if (setup->>'machine_id' is not null and not exists(select 1 from public.vineyard_machines where id=(setup->>'machine_id')::uuid and vineyard_id=v and deleted_at is null)) or
     (setup->>'tractor_id' is not null and not exists(select 1 from public.tractors where id=(setup->>'tractor_id')::uuid and vineyard_id=v and deleted_at is null)) or
     (setup->>'operator_user_id' is not null and not exists(select 1 from public.vineyard_members where user_id=(setup->>'operator_user_id')::uuid and vineyard_id=v)) or
     (setup->>'work_task_id' is not null and not exists(select 1 from public.work_tasks where id=(setup->>'work_task_id')::uuid and vineyard_id=v and deleted_at is null)) or
     (setup->>'worker_type_id' is not null and not exists(select 1 from public.worker_types where id=(setup->>'worker_type_id')::uuid and vineyard_id=v and deleted_at is null)) then
    raise exception 'OCCURRENCE_SETUP_SCOPE_CONFLICT' using errcode='22023';
  end if;
  if setup->>'operator_user_id' is not null and (setup->>'operator_user_id')::uuid<>auth.uid() and
     not public.has_vineyard_role(v,array['owner','manager','supervisor']) then
    raise exception 'OCCURRENCE_OWNER_CONFLICT' using errcode='42501';
  end if;
end $fn$;
revoke all on function public.validate_occurrence_setup_links_v1(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.validate_occurrence_setup_links_v1(uuid,jsonb) to vinetrack_occurrence_writer;

-- SECURITY INVOKER: only an inaccessible NOLOGIN RPC owner passes, never a GUC/header.
create function public.guard_trip_occurrence_authority_v1() returns trigger language plpgsql security invoker
set search_path=pg_catalog,public as $fn$
declare old_json jsonb; new_json jsonb; linked text; fields text[]:=array[
 'id','vineyard_id','created_by','row_sequence','completed_paths','skipped_paths','sequence_index',
 'current_row_number','next_row_number','paddock_id','paddock_ids','tracking_pattern','start_time','end_time','is_active','operator_user_id'];
begin
  if tg_op='UPDATE' then old_json:=to_jsonb(old); end if;
  if new.occurrence_coverage is null and (tg_op='INSERT' or old.occurrence_coverage is null) then return new; end if;
  new_json:=to_jsonb(new);
  if tg_op='UPDATE' and new.deleted_at is distinct from old.deleted_at and
     (old.deleted_at is not null or new.deleted_at is null or not coalesce(public.has_vineyard_role(old.vineyard_id,array['owner','manager','supervisor']),false)) then
    raise exception 'OCCURRENCE_DELETE_FORBIDDEN' using errcode='42501';
  end if;
  if current_user<>'vinetrack_occurrence_writer' and (tg_op='INSERT' or
    new.occurrence_coverage is distinct from old.occurrence_coverage or
    (select jsonb_object_agg(key,value) from jsonb_each(new_json) where key=any(fields)) is distinct from
    (select jsonb_object_agg(key,value) from jsonb_each(old_json) where key=any(fields))) then
    raise exception 'OCCURRENCE_UPDATE_REQUIRED' using errcode='0A000',
      detail='Occurrence-aware actions required. Update the client; numeric writes and downgrade are unsupported.';
  end if;
  if new.occurrence_coverage is null or coalesce(new.completed_paths,'[]'::jsonb)<>'[]'::jsonb or
     coalesce(new.skipped_paths,'[]'::jsonb)<>'[]'::jsonb then
    raise exception 'OCCURRENCE_UPDATE_REQUIRED' using errcode='0A000';
  end if;
  for linked in select distinct jsonb_array_elements_text(value->'tankSessionIds') from jsonb_each(new.occurrence_coverage->'states') loop
    if not exists(select 1 from jsonb_array_elements(coalesce(new.tank_sessions,'[]')) s where s->>'id'=linked) then
      raise exception 'OCCURRENCE_TANK_LINK_CONFLICT' using errcode='40001';
    end if;
  end loop;
  return new;
end $fn$;
create trigger aaa_trip_occurrence_authority_guard before insert or update on public.trips
  for each row execute function public.guard_trip_occurrence_authority_v1();
revoke all on function public.guard_trip_occurrence_authority_v1() from public,anon,authenticated,service_role;

create function public.validate_trip_occurrences_v1(d jsonb,v_vineyard uuid) returns void
language plpgsql security invoker set search_path=pg_catalog,public as $fn$
declare item jsonb; state jsonb; oid text; ids text[]:=array[]::text[]; orders text[]; retired text[]; rid text;
begin
  if d is null or jsonb_typeof(d)<>'object' or d->>'contract' is distinct from 'vinetrack.planned-occurrence' or d->'schemaVersion' is distinct from '1'::jsonb then
    raise exception 'OCCURRENCE_UNSUPPORTED_VERSION' using errcode='0A000';
  end if;
  perform (d->>'planId')::uuid;
  if d->>'planId' is not null and d->>'planId'<>(d->>'planId')::uuid::text then
    raise exception 'OCCURRENCE_INVALID_IDENTITY' using errcode='22023';
  end if;
  if d->>'planId' is null or jsonb_typeof(d->'revision') is distinct from 'number' or jsonb_typeof(d->'planRevision') is distinct from 'number' or
    d->>'revision' !~ '^[0-9]+$' or d->>'planRevision' !~ '^[1-9][0-9]*$' or
    jsonb_typeof(d->'items') is distinct from 'array' or jsonb_array_length(d->'items') not between 1 and 5000 or
    jsonb_typeof(d->'activeOrder') is distinct from 'array' or jsonb_typeof(d->'retired') is distinct from 'array' or jsonb_typeof(d->'states') is distinct from 'object' then
    raise exception 'OCCURRENCE_INVALID_DOCUMENT' using errcode='22023';
  end if;
  for item in select value from jsonb_array_elements(d->'items') loop
    oid:=item->>'occurrenceId'; perform oid::uuid; perform (item->>'blockId')::uuid; perform (item#>>'{physicalPathRef,pathId}')::uuid;
    if oid is null or oid<>oid::uuid::text or oid=any(ids) or item->>'blockId' is null or
      item->>'blockId'<>(item->>'blockId')::uuid::text or item#>>'{physicalPathRef,pathId}' is null or
      item#>>'{physicalPathRef,pathId}'<>(item#>>'{physicalPathRef,pathId}')::uuid::text or
      jsonb_typeof(item->'pathNumber') is distinct from 'number' or item->>'passOrdinal' is null or item->>'passOrdinal' !~ '^[1-9][0-9]*$' or
      jsonb_typeof(item->'blockNameSnapshot') is distinct from 'string' or jsonb_typeof(item#>'{physicalPathRef,rowIds}') is distinct from 'array' or
      not exists(select 1 from public.paddocks where id=(item->>'blockId')::uuid and vineyard_id=v_vineyard) then
      raise exception 'OCCURRENCE_INVALID_IDENTITY' using errcode='22023';
    end if;
    for rid in select jsonb_array_elements_text(item#>'{physicalPathRef,rowIds}') loop
      if rid is null or rid<>rid::uuid::text then raise exception 'OCCURRENCE_INVALID_ROW_ID' using errcode='22023'; end if;
      perform rid::uuid;
    end loop;
    if (select count(*)<>count(distinct value) from jsonb_array_elements_text(item#>'{physicalPathRef,rowIds}')) then
      raise exception 'OCCURRENCE_INVALID_ROW_ID' using errcode='22023';
    end if;
    ids:=array_append(ids,oid); state:=d->'states'->oid;
    if jsonb_typeof(state) is distinct from 'object' or coalesce(state->>'status','') not in ('incomplete','done','skipped') or
      jsonb_typeof(state->'tankSessionIds') is distinct from 'array' or
      (state->>'source' is not null and state->>'source' not in ('manual','automatic','endReview','correction')) then
      raise exception 'OCCURRENCE_INVALID_STATE' using errcode='22023';
    end if;
    if state->>'lastOperationId' is not null then perform (state->>'lastOperationId')::uuid; end if;
    if exists(select 1 from jsonb_array_elements(d->'items') other where other#>>'{physicalPathRef,pathId}'=item#>>'{physicalPathRef,pathId}' and
      (other->'blockId' is distinct from item->'blockId' or other->'physicalPathRef' is distinct from item->'physicalPathRef' or other->'pathNumber' is distinct from item->'pathNumber')) then
      raise exception 'OCCURRENCE_PHYSICAL_REFERENCE_CONFLICT' using errcode='22023';
    end if;
  end loop;
  select coalesce(array_agg(value),array[]::text[]) into orders from jsonb_array_elements_text(d->'activeOrder');
  select coalesce(array_agg(value),array[]::text[]) into retired from jsonb_array_elements_text(d->'retired');
  if cardinality(orders||retired)<>cardinality(ids) or (select count(distinct x) from unnest(orders||retired) x)<>cardinality(ids) or
    exists(select 1 from unnest(orders||retired) x where not x=any(ids)) or
    (select count(*) from jsonb_object_keys(d->'states'))<>cardinality(ids) or exists(select 1 from jsonb_object_keys(d->'states') x where not x=any(ids)) or
    (d->>'selectedOccurrenceId' is not null and not d->>'selectedOccurrenceId'=any(orders)) or
    (d->>'plannedCursorId' is not null and not d->>'plannedCursorId'=any(orders)) then
    raise exception 'OCCURRENCE_INVALID_ORDER' using errcode='22023';
  end if;
end $fn$;
-- Admission validates only NEW physical items against current scoped block geometry.
-- Existing frozen items remain valid after later block/geometry edits.
create function public.validate_new_occurrence_geometry_v1(item jsonb,v uuid) returns void
language plpgsql security definer set search_path=pg_catalog,public as $fn$
declare b public.paddocks; rid text; mapped jsonb; snapshot jsonb; row_count integer; n numeric;
begin
  if auth.uid() is null or not public.has_vineyard_role(v,array['owner','manager','supervisor','operator']) then
    raise exception 'OCCURRENCE_TRIP_FORBIDDEN' using errcode='42501';
  end if;
  select * into b from public.paddocks where id=(item->>'blockId')::uuid and vineyard_id=v and deleted_at is null;
  if b.id is null or item->>'blockNameSnapshot' is distinct from b.name then
    raise exception 'OCCURRENCE_BLOCK_SNAPSHOT_CONFLICT' using errcode='22023';
  end if;
  row_count:=jsonb_array_length(item#>'{physicalPathRef,rowIds}');
  if row_count=0 then
    if item#>>'{physicalPathRef,geometryRevision}' is distinct from 'unresolved' then
      raise exception 'OCCURRENCE_GEOMETRY_REQUIRED' using errcode='22023';
    end if;
    return; -- Explicit manual-only reference; no claimed geometry.
  end if;
  if row_count not between 1 and 2 or jsonb_typeof(item#>'{physicalPathRef,rowSnapshots}') is distinct from 'array' or
     jsonb_array_length(item#>'{physicalPathRef,rowSnapshots}')<>row_count then
    raise exception 'OCCURRENCE_GEOMETRY_REQUIRED' using errcode='22023';
  end if;
  n:=(item->>'pathNumber')::numeric;
  for rid in select jsonb_array_elements_text(item#>'{physicalPathRef,rowIds}') loop
    select r into mapped from jsonb_array_elements(coalesce(b.rows,'[]')) r where lower(r->>'id')=rid;
    select r into snapshot from jsonb_array_elements(item#>'{physicalPathRef,rowSnapshots}') r where lower(r->>'id')=rid;
    if mapped is null or snapshot is distinct from mapped or
       abs(coalesce((mapped->>'decimalNumber')::numeric,(mapped->>'number')::numeric)-n)>0.5 then
      raise exception 'OCCURRENCE_ROW_SCOPE_CONFLICT' using errcode='22023';
    end if;
  end loop;
end $fn$;
revoke all on function public.validate_new_occurrence_geometry_v1(jsonb,uuid) from public,anon,authenticated,service_role;
grant execute on function public.validate_new_occurrence_geometry_v1(jsonb,uuid) to vinetrack_occurrence_writer;

revoke all on function public.validate_trip_occurrences_v1(jsonb,uuid) from public,anon,authenticated,service_role;
grant execute on function public.validate_trip_occurrences_v1(jsonb,uuid) to vinetrack_occurrence_writer;

create function public.apply_trip_occurrence_action_v1(p_operation_id uuid,p_trip_id uuid,p_expected_revision bigint,p_expected_plan_revision bigint,p_action jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $fn$
declare t public.trips; d jsonb; request jsonb; prior public.trip_occurrence_operations; undo_op public.trip_occurrence_operations;
 oid text; item jsonb; before_state jsonb; after_state jsonb; kind text; result jsonb; session_id text;
 new_items jsonb; old_item jsonb; cursor_id text; cursor_index integer; current_number double precision; next_number double precision;
begin
  if auth.uid() is null then raise exception 'OCCURRENCE_AUTH_REQUIRED' using errcode='42501'; end if;
  if p_operation_id is null or p_trip_id is null or p_expected_revision is null or p_expected_plan_revision is null or jsonb_typeof(p_action) is distinct from 'object' then
    raise exception 'OCCURRENCE_INVALID_REQUEST' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('occurrence-operation:'||p_operation_id::text,0));
  select * into t from public.trips where id=p_trip_id for update;
  if t.id is null or not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor','operator']) then
    raise exception 'OCCURRENCE_TRIP_FORBIDDEN' using errcode='42501';
  end if;
  request:=jsonb_build_object('tripId',p_trip_id,'expectedRevision',p_expected_revision,'expectedPlanRevision',p_expected_plan_revision,'action',p_action);
  select * into prior from public.trip_occurrence_operations where operation_id=p_operation_id;
  if prior.operation_id is not null then
    if prior.actor_id<>auth.uid() or prior.trip_id<>t.id or prior.request<>request then raise exception 'OCCURRENCE_OPERATION_ID_CONFLICT' using errcode='22023'; end if;
    return prior.result;
  end if;
  d:=t.occurrence_coverage; perform public.validate_trip_occurrences_v1(d,t.vineyard_id);
  if t.deleted_at is not null or t.end_time is not null then raise exception 'OCCURRENCE_TRIP_CLOSED' using errcode='55000'; end if;
  if (d->>'revision')::bigint<>p_expected_revision or (d->>'planRevision')::bigint<>p_expected_plan_revision then raise exception 'OCCURRENCE_REVISION_CONFLICT' using errcode='40001'; end if;
  if p_action->>'planId' is distinct from d->>'planId' then raise exception 'OCCURRENCE_PLAN_CONFLICT' using errcode='40001'; end if;
  kind:=p_action->>'kind';
  if kind<>'editPlan' and not t.is_active then raise exception 'OCCURRENCE_TRIP_NOT_ACTIVE' using errcode='55000'; end if;
  if t.operator_user_id is distinct from auth.uid() and not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor']) then
    raise exception 'OCCURRENCE_OWNER_CONFLICT' using errcode='42501';
  end if;
  oid:=case when kind in ('setStatus','undo','selectOccurrence') then p_action->>'occurrenceId' else null end;
  if kind='clearSelection' and p_action ? 'occurrenceId' then
    raise exception 'OCCURRENCE_INVALID_REQUEST' using errcode='22023';
  end if;
  if kind in ('setStatus','undo','selectOccurrence') then
    select value into item from jsonb_array_elements(d->'items') where value->>'occurrenceId'=oid;
    if item is null or not (d->'activeOrder' ? oid) or p_action->>'blockId' is distinct from item->>'blockId' then raise exception 'OCCURRENCE_IDENTITY_CONFLICT' using errcode='40001'; end if;
    before_state:=d->'states'->oid;
  end if;
  if kind='setStatus' then
    if p_action->'expectedBeforeState' is distinct from before_state then raise exception 'OCCURRENCE_STATE_CONFLICT' using errcode='40001'; end if;
    if coalesce(p_action->>'toStatus','') not in ('incomplete','done','skipped') or coalesce(p_action->>'source','') not in ('manual','automatic','endReview','correction') or
      jsonb_typeof(p_action->'tankSessionIds') is distinct from 'array' then raise exception 'OCCURRENCE_INVALID_TRANSITION' using errcode='22023'; end if;
    if p_action->>'source'='automatic' and (t.is_paused or not t.is_active or before_state->>'status'<>'incomplete' or p_action->>'toStatus'<>'done' or
      item#>>'{physicalPathRef,geometryRevision}'='unresolved' or
      jsonb_array_length(item#>'{physicalPathRef,rowIds}')=0 or p_action#>>'{evidence,occurrenceId}' is distinct from oid or p_action#>>'{evidence,ruleVersion}' is distinct from 'traversal-v1' or
      coalesce((p_action#>>'{evidence,qualifiedSamples}')::integer,0)<4 or coalesce((p_action#>>'{evidence,durationSeconds}')::numeric,0)<3 or
      coalesce((p_action#>>'{evidence,longitudinalSpan}')::numeric,0)<0.8 or p_action#>'{evidence,unambiguous}' is distinct from 'true'::jsonb) then
      raise exception 'OCCURRENCE_TRAVERSAL_REQUIRED' using errcode='22023';
    end if;
    if p_action->>'source'='automatic' then
      if p_action#>>'{evidence,runId}' is null or
         p_action#>>'{evidence,runId}'<>(p_action#>>'{evidence,runId}')::uuid::text or
         exists(select 1 from public.trip_occurrence_operations operation where operation.trip_id=t.id and
           operation.request#>>'{action,source}'='automatic' and operation.request#>>'{action,evidence,runId}'=p_action#>>'{evidence,runId}') or
         exists(select 1 from unnest(array['qualifiedSamples','durationSeconds','longitudinalSpan','entryFraction','exitFraction']) k
           where jsonb_typeof(p_action#>array['evidence',k]) is distinct from 'number') or
         (p_action#>>'{evidence,longitudinalSpan}')::numeric>1 or
         not (((p_action#>>'{evidence,entryFraction}')::numeric between 0 and 0.1 and
               (p_action#>>'{evidence,exitFraction}')::numeric between 0.9 and 1) or
              ((p_action#>>'{evidence,entryFraction}')::numeric between 0.9 and 1 and
               (p_action#>>'{evidence,exitFraction}')::numeric between 0 and 0.1)) then
        raise exception 'OCCURRENCE_TRAVERSAL_REQUIRED' using errcode='22023';
      end if;
      -- GPS identifies physical geometry, not a pass. Ambiguous passes require selection.
      if d->>'selectedOccurrenceId' is distinct from oid and
        (d->>'plannedCursorId' is distinct from oid or 1<(select count(*) from jsonb_array_elements(d->'items') candidate
          where d->'activeOrder' ? (candidate->>'occurrenceId') and
            d#>>array['states',candidate->>'occurrenceId','status']='incomplete' and
            candidate->'physicalPathRef'=item->'physicalPathRef')) then
        raise exception 'OCCURRENCE_SELECTION_REQUIRED' using errcode='55000';
      end if;
    end if;
    after_state:=jsonb_build_object('status',p_action->>'toStatus','source',p_action->>'source','lastOperationId',p_operation_id,'tankSessionIds',p_action->'tankSessionIds');
  elsif kind='undo' then
    select * into undo_op from public.trip_occurrence_operations where operation_id=(p_action->>'undoOfOperationId')::uuid;
    if undo_op.trip_id is distinct from t.id or undo_op.occurrence_id is distinct from oid::uuid or
      coalesce(undo_op.request#>>'{action,kind}','') not in ('setStatus','undo') or before_state->>'lastOperationId' is distinct from undo_op.operation_id::text or undo_op.previous_state is null then
      raise exception 'OCCURRENCE_UNDO_CONFLICT' using errcode='40001';
    end if;
    after_state:=undo_op.previous_state||jsonb_build_object('lastOperationId',p_operation_id,'source','correction');
  elsif kind='selectOccurrence' then d:=jsonb_set(d,'{selectedOccurrenceId}',to_jsonb(oid));
  elsif kind='clearSelection' then d:=jsonb_set(d,'{selectedOccurrenceId}','null');
  elsif kind='editPlan' then
    new_items:=p_action->'items';
    if jsonb_typeof(new_items) is distinct from 'array' then raise exception 'OCCURRENCE_INVALID_PLAN_EDIT' using errcode='22023'; end if;
    for old_item in select value from jsonb_array_elements(d->'items') loop
      if not exists(select 1 from jsonb_array_elements(new_items) x where x=old_item) or
        ((d->'retired' ? (old_item->>'occurrenceId')) and not (p_action->'retired' ? (old_item->>'occurrenceId'))) then
        raise exception 'OCCURRENCE_IMMUTABLE_IDENTITY' using errcode='22023';
      end if;
    end loop;
    for item in select value from jsonb_array_elements(new_items) loop
      oid:=item->>'occurrenceId';
      if not (d->'states' ? oid) then
        perform public.validate_new_occurrence_geometry_v1(item,t.vineyard_id);
        d:=jsonb_set(d,array['states',oid],jsonb_build_object('status','incomplete','source',null,'lastOperationId',null,'tankSessionIds','[]'::jsonb));
      end if;
    end loop;
    oid:=null;
    d:=d||jsonb_build_object('items',new_items,'activeOrder',p_action->'activeOrder','retired',p_action->'retired','planRevision',p_expected_plan_revision+1,'selectedOccurrenceId',null,'plannedCursorId',null);
  else raise exception 'OCCURRENCE_UNKNOWN_ACTION' using errcode='22023';
  end if;
  if after_state is not null then
    for session_id in select jsonb_array_elements_text(after_state->'tankSessionIds') loop
      if not exists(select 1 from jsonb_array_elements(coalesce(t.tank_sessions,'[]')) s where s->>'id'=session_id) then raise exception 'OCCURRENCE_TANK_LINK_CONFLICT' using errcode='40001'; end if;
    end loop;
    d:=jsonb_set(d,array['states',oid],after_state);
    if d->>'selectedOccurrenceId'=oid then d:=jsonb_set(d,'{selectedOccurrenceId}','null'); end if;
  end if;
  select x.id,(x.ord-1)::integer into cursor_id,cursor_index from jsonb_array_elements_text(d->'activeOrder') with ordinality x(id,ord)
    where d#>>array['states',x.id,'status']='incomplete' order by x.ord limit 1;
  d:=d||jsonb_build_object('revision',p_expected_revision+1,'plannedCursorId',cursor_id);
  perform public.validate_trip_occurrences_v1(d,t.vineyard_id);
  select (value->>'pathNumber')::double precision into current_number from jsonb_array_elements(d->'items') where value->>'occurrenceId'=coalesce(d->>'selectedOccurrenceId',cursor_id);
  select (i->>'pathNumber')::double precision into next_number
    from jsonb_array_elements_text(d->'activeOrder') with ordinality x(id,ord)
    join lateral(select value i from jsonb_array_elements(d->'items') where value->>'occurrenceId'=x.id)y on true
    where x.id<>coalesce(d->>'selectedOccurrenceId',cursor_id) and d#>>array['states',x.id,'status']='incomplete'
    order by ord limit 1;
  update public.trips set occurrence_coverage=d,completed_paths='[]',skipped_paths='[]',
    row_sequence=(select coalesce(jsonb_agg(i->'pathNumber' order by ord),'[]') from jsonb_array_elements_text(d->'activeOrder') with ordinality x(id,ord)
      join lateral(select value i from jsonb_array_elements(d->'items') where value->>'occurrenceId'=x.id)y on true),
    paddock_ids=(select coalesce(jsonb_agg(distinct value->'blockId'),'[]') from jsonb_array_elements(d->'items')),
    sequence_index=coalesce(cursor_index,jsonb_array_length(d->'activeOrder')),current_row_number=current_number,next_row_number=next_number,
    updated_by=auth.uid(),client_updated_at=clock_timestamp(),sync_version=sync_version+1 where id=t.id returning * into t;
  if not found then raise exception 'OCCURRENCE_WRITE_NOT_APPLIED' using errcode='40001'; end if;
  result:=jsonb_build_object('operationId',p_operation_id,'tripId',t.id,'coverage',d);
  insert into public.trip_occurrence_operations(operation_id,trip_id,vineyard_id,actor_id,request,result,occurrence_id,previous_state,resulting_state)
    values(p_operation_id,t.id,t.vineyard_id,auth.uid(),request,result,oid::uuid,before_state,after_state);
  return result;
end $fn$;
alter function public.apply_trip_occurrence_action_v1(uuid,uuid,bigint,bigint,jsonb) owner to vinetrack_occurrence_writer;
revoke all on function public.apply_trip_occurrence_action_v1(uuid,uuid,bigint,bigint,jsonb) from public,anon,service_role;
grant execute on function public.apply_trip_occurrence_action_v1(uuid,uuid,bigint,bigint,jsonb) to authenticated;

create function public.create_trip_with_occurrences_v1(p_operation_id uuid,p_trip jsonb,p_coverage jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $fn$
declare t public.trips; prior public.trip_occurrence_operations; request jsonb; result jsonb; trip_id uuid; vineyard uuid; first_id text; n double precision; next_n double precision; item jsonb;
  projection jsonb; key text; provided_blocks jsonb;
begin
  if auth.uid() is null then raise exception 'OCCURRENCE_AUTH_REQUIRED' using errcode='42501'; end if;
  if p_operation_id is null or jsonb_typeof(p_trip) is distinct from 'object' then raise exception 'OCCURRENCE_INVALID_REQUEST' using errcode='22023'; end if;
  trip_id:=(p_trip->>'id')::uuid; vineyard:=(p_trip->>'vineyard_id')::uuid;
  if trip_id is null or not coalesce(public.has_vineyard_role(vineyard,array['owner','manager','supervisor','operator']),false) then raise exception 'OCCURRENCE_TRIP_FORBIDDEN' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('occurrence-operation:'||p_operation_id::text,0));
  request:=jsonb_build_object('kind','create','trip',p_trip,'coverage',p_coverage);
  select * into prior from public.trip_occurrence_operations where operation_id=p_operation_id;
  if prior.operation_id is not null then
    if prior.actor_id<>auth.uid() or prior.trip_id<>trip_id or prior.request<>request then raise exception 'OCCURRENCE_OPERATION_ID_CONFLICT' using errcode='22023'; end if;
    return prior.result;
  end if;
  if exists(select 1 from public.trips where id=trip_id) then raise exception 'OCCURRENCE_EXISTING_TRIP' using errcode='40001'; end if;
  perform public.validate_trip_occurrences_v1(p_coverage,vineyard);
  if p_coverage->'revision'<>'0'::jsonb or p_coverage->'planRevision'<>'1'::jsonb or p_coverage->'retired'<>'[]'::jsonb or p_coverage->>'selectedOccurrenceId' is not null or
    exists(select 1 from jsonb_each(p_coverage->'states') where value<>jsonb_build_object('status','incomplete','source',null,'lastOperationId',null,'tankSessionIds','[]'::jsonb)) then
    raise exception 'OCCURRENCE_INITIAL_STATE_REQUIRED' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_object_keys(p_trip) k where not k=any(array[
    'id','vineyard_id','paddock_name','tracking_pattern','start_time','is_active','is_paused','person_name',
    'trip_function','trip_title','tractor_id','operator_user_id','worker_type_id','machine_id','work_task_id',
    'start_engine_hours','end_engine_hours','seeding_details','total_tanks','paddock_id','paddock_ids',
    'total_distance','current_path_distance','path_points','pin_ids','tank_sessions','active_tank_number',
    'pause_timestamps','resume_timestamps','is_filling_tank','filling_tank_number','manual_correction_events',
    'completion_notes','created_by','client_updated_at','end_time','row_sequence','sequence_index',
    'current_row_number','next_row_number','completed_paths','skipped_paths'])) then
    raise exception 'OCCURRENCE_INVALID_CREATE_FIELDS' using errcode='22023';
  end if;
  perform public.validate_occurrence_setup_links_v1(vineyard,p_trip);
  for item in select value from jsonb_array_elements(p_coverage->'items') loop
    perform public.validate_new_occurrence_geometry_v1(item,vineyard);
  end loop;
  first_id:=p_coverage#>>'{activeOrder,0}';
  if p_coverage->>'plannedCursorId' is distinct from first_id then raise exception 'OCCURRENCE_INITIAL_CURSOR_REQUIRED' using errcode='22023'; end if;
  select (value->>'pathNumber')::double precision into n from jsonb_array_elements(p_coverage->'items') where value->>'occurrenceId'=first_id;
  select (value->>'pathNumber')::double precision into next_n from jsonb_array_elements(p_coverage->'items') where value->>'occurrenceId'=p_coverage#>>'{activeOrder,1}';
  projection:=jsonb_build_object('row_sequence',(select jsonb_agg(i->'pathNumber' order by ord) from
      jsonb_array_elements_text(p_coverage->'activeOrder') with ordinality x(id,ord)
      join lateral(select value i from jsonb_array_elements(p_coverage->'items') where value->>'occurrenceId'=x.id)y on true),
    'sequence_index',0,'current_row_number',n,'next_row_number',next_n,'completed_paths','[]'::jsonb,'skipped_paths','[]'::jsonb);
  for key in select jsonb_object_keys(projection) loop
    if p_trip ? key and p_trip->key is distinct from projection->key then
      raise exception 'OCCURRENCE_CREATE_PROJECTION_CONFLICT' using errcode='22023';
    end if;
  end loop;
  if p_trip->>'end_time' is not null or
     (p_trip->>'created_by' is not null and (p_trip->>'created_by')::uuid<>auth.uid()) or
     (p_trip->>'paddock_id' is not null and not exists(select 1 from public.paddocks where
       id=(p_trip->>'paddock_id')::uuid and vineyard_id=vineyard and deleted_at is null)) then
    raise exception 'OCCURRENCE_SETUP_SCOPE_CONFLICT' using errcode='22023';
  end if;
  provided_blocks:=coalesce(nullif(p_trip->'paddock_ids','null'::jsonb),
    (select jsonb_agg(distinct value->'blockId') from jsonb_array_elements(p_coverage->'items')));
  if jsonb_typeof(provided_blocks) is distinct from 'array' or
     exists(select 1 from jsonb_array_elements_text(provided_blocks) id where not exists(
       select 1 from public.paddocks where paddocks.id=id::uuid and vineyard_id=vineyard and deleted_at is null)) or
     exists(select 1 from jsonb_array_elements(p_coverage->'items') i where not provided_blocks ? (i->>'blockId')) then
    raise exception 'OCCURRENCE_SETUP_SCOPE_CONFLICT' using errcode='22023';
  end if;
  select * into t from jsonb_populate_record(null::public.trips,jsonb_build_object(
    'total_distance',0,'current_path_distance',0,'path_points','[]'::jsonb,'pin_ids','[]'::jsonb,
    'tank_sessions','[]'::jsonb,'pause_timestamps','[]'::jsonb,'resume_timestamps','[]'::jsonb,
    'is_filling_tank',false,'total_tanks',0,'manual_correction_events','[]'::jsonb)||p_trip||projection||jsonb_build_object(
    'occurrence_coverage',p_coverage,'operator_user_id',coalesce((p_trip->>'operator_user_id')::uuid,auth.uid()),'created_by',auth.uid(),'updated_by',auth.uid(),'created_at',clock_timestamp(),'updated_at',clock_timestamp(),
    'client_updated_at',coalesce((p_trip->>'client_updated_at')::timestamptz,clock_timestamp()),'sync_version',1,
    'is_active',coalesce((p_trip->>'is_active')::boolean,false),'is_paused',coalesce((p_trip->>'is_paused')::boolean,false),
    'paddock_ids',provided_blocks));
  insert into public.trips select t.* returning * into t;
  result:=jsonb_build_object('operationId',p_operation_id,'tripId',t.id,'coverage',t.occurrence_coverage);
  insert into public.trip_occurrence_operations(operation_id,trip_id,vineyard_id,actor_id,request,result) values(p_operation_id,t.id,t.vineyard_id,auth.uid(),request,result);
  return result;
end $fn$;
alter function public.create_trip_with_occurrences_v1(uuid,jsonb,jsonb) owner to vinetrack_occurrence_writer;
revoke all on function public.create_trip_with_occurrences_v1(uuid,jsonb,jsonb) from public,anon,service_role;
grant execute on function public.create_trip_with_occurrences_v1(uuid,jsonb,jsonb) to authenticated;

-- Saved prospective plans cannot be activated through a legacy PATCH.
create function public.activate_trip_occurrences_v1(p_operation_id uuid,p_trip_id uuid,
  p_expected_revision bigint,p_expected_plan_revision bigint,p_start jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $fn$
declare t public.trips; d jsonb; prior public.trip_occurrence_operations; request jsonb;
  started timestamptz; hours double precision; result jsonb;
begin
  if auth.uid() is null then raise exception 'OCCURRENCE_AUTH_REQUIRED' using errcode='42501'; end if;
  if p_operation_id is null or p_trip_id is null or p_expected_revision is null or p_expected_plan_revision is null or jsonb_typeof(p_start) is distinct from 'object' then
    raise exception 'OCCURRENCE_INVALID_REQUEST' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('occurrence-operation:'||p_operation_id::text,0));
  select * into t from public.trips where id=p_trip_id for update;
  if t.id is null or not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor','operator']) then
    raise exception 'OCCURRENCE_TRIP_FORBIDDEN' using errcode='42501';
  end if;
  request:=jsonb_build_object('kind','activate','tripId',p_trip_id,'expectedRevision',p_expected_revision,'expectedPlanRevision',p_expected_plan_revision,'start',p_start);
  select * into prior from public.trip_occurrence_operations where operation_id=p_operation_id;
  if prior.operation_id is not null then
    if prior.actor_id<>auth.uid() or prior.trip_id<>t.id or prior.request<>request then raise exception 'OCCURRENCE_OPERATION_ID_CONFLICT' using errcode='22023'; end if;
    return prior.result;
  end if;
  if t.operator_user_id is distinct from auth.uid() and not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor']) then
    raise exception 'OCCURRENCE_OWNER_CONFLICT' using errcode='42501';
  end if;
  d:=t.occurrence_coverage; perform public.validate_trip_occurrences_v1(d,t.vineyard_id);
  if t.deleted_at is not null or t.end_time is not null or t.is_active then raise exception 'OCCURRENCE_ACTIVATION_CONFLICT' using errcode='55000'; end if;
  if (d->>'revision')::bigint<>p_expected_revision or (d->>'planRevision')::bigint<>p_expected_plan_revision then raise exception 'OCCURRENCE_REVISION_CONFLICT' using errcode='40001'; end if;
  if exists(select 1 from jsonb_object_keys(p_start) k where not k=any(array['startTime','startEngineHours'])) then raise exception 'OCCURRENCE_INVALID_START' using errcode='22023'; end if;
  started:=(p_start->>'startTime')::timestamptz; hours:=(p_start->>'startEngineHours')::double precision;
  if started is null or not isfinite(started) or (hours is not null and (hours<0 or hours::text in ('NaN','Infinity','-Infinity'))) then raise exception 'OCCURRENCE_INVALID_START' using errcode='22023'; end if;
  d:=d||jsonb_build_object('revision',p_expected_revision+1);
  update public.trips set occurrence_coverage=d,start_time=started,start_engine_hours=hours,is_active=true,is_paused=false,
    updated_by=auth.uid(),client_updated_at=clock_timestamp(),sync_version=sync_version+1 where id=t.id;
  if not found then raise exception 'OCCURRENCE_WRITE_NOT_APPLIED' using errcode='40001'; end if;
  result:=jsonb_build_object('operationId',p_operation_id,'tripId',t.id,'coverage',d,'startTime',started,'isActive',true);
  insert into public.trip_occurrence_operations(operation_id,trip_id,vineyard_id,actor_id,request,result)
    values(p_operation_id,t.id,t.vineyard_id,auth.uid(),request,result);
  return result;
end $fn$;
alter function public.activate_trip_occurrences_v1(uuid,uuid,bigint,bigint,jsonb) owner to vinetrack_occurrence_writer;
revoke all on function public.activate_trip_occurrences_v1(uuid,uuid,bigint,bigint,jsonb) from public,anon,service_role;
grant execute on function public.activate_trip_occurrences_v1(uuid,uuid,bigint,bigint,jsonb) to authenticated;

-- Coverage actions precede this barrier. No inference/tick-all or automatic tank end.
create function public.finalize_trip_occurrences_v1(p_operation_id uuid,p_trip_id uuid,
  p_expected_revision bigint,p_expected_plan_revision bigint,p_reviewed_states jsonb,p_end jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $fn$
declare t public.trips; d jsonb; request jsonb; prior public.trip_occurrence_operations;
  ended timestamptz; hours double precision; result jsonb;
begin
  if auth.uid() is null then raise exception 'OCCURRENCE_AUTH_REQUIRED' using errcode='42501'; end if;
  if p_operation_id is null or p_trip_id is null or p_expected_revision is null or p_expected_plan_revision is null or
    jsonb_typeof(p_reviewed_states) is distinct from 'object' or jsonb_typeof(p_end) is distinct from 'object' then
    raise exception 'OCCURRENCE_INVALID_REQUEST' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('occurrence-operation:'||p_operation_id::text,0));
  select * into t from public.trips where id=p_trip_id for update;
  if t.id is null or not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor','operator']) then
    raise exception 'OCCURRENCE_TRIP_FORBIDDEN' using errcode='42501';
  end if;
  request:=jsonb_build_object('kind','finalize','tripId',p_trip_id,'expectedRevision',p_expected_revision,
    'expectedPlanRevision',p_expected_plan_revision,'reviewedStates',p_reviewed_states,'end',p_end);
  select * into prior from public.trip_occurrence_operations where operation_id=p_operation_id;
  if prior.operation_id is not null then
    if prior.actor_id<>auth.uid() or prior.trip_id<>t.id or prior.request<>request then
      raise exception 'OCCURRENCE_OPERATION_ID_CONFLICT' using errcode='22023';
    end if;
    return prior.result;
  end if;
  if t.operator_user_id is distinct from auth.uid() and not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor']) then
    raise exception 'OCCURRENCE_OWNER_CONFLICT' using errcode='42501';
  end if;
  d:=t.occurrence_coverage; perform public.validate_trip_occurrences_v1(d,t.vineyard_id);
  if t.deleted_at is not null or t.end_time is not null or not t.is_active then raise exception 'OCCURRENCE_TRIP_CLOSED' using errcode='55000'; end if;
  if (d->>'revision')::bigint<>p_expected_revision or (d->>'planRevision')::bigint<>p_expected_plan_revision or
    p_reviewed_states is distinct from d->'states' then raise exception 'OCCURRENCE_REVISION_CONFLICT' using errcode='40001'; end if;
  if t.active_tank_number is not null or coalesce(t.is_filling_tank,false) or exists(
    select 1 from jsonb_array_elements(coalesce(t.tank_sessions,'[]')) s where
      coalesce(s->>'endTime',s->>'end_time') is null) then
    raise exception 'OCCURRENCE_TANK_REVIEW_REQUIRED' using errcode='55000';
  end if;
  if exists(select 1 from jsonb_object_keys(p_end) k where not k=any(array['endTime','endEngineHours','completionNotes'])) then
    raise exception 'OCCURRENCE_INVALID_END_FIELDS' using errcode='22023';
  end if;
  ended:=(p_end->>'endTime')::timestamptz; hours:=(p_end->>'endEngineHours')::double precision;
  if ended is null or not isfinite(ended) or t.start_time is null or ended<t.start_time or
    (hours is not null and (hours<0 or hours::text in ('NaN','Infinity','-Infinity') or hours<coalesce(t.start_engine_hours,0))) then
    raise exception 'OCCURRENCE_INVALID_END' using errcode='22023';
  end if;
  d:=d||jsonb_build_object('revision',p_expected_revision+1,'selectedOccurrenceId',null);
  update public.trips set occurrence_coverage=d,end_time=ended,is_active=false,is_paused=false,
    end_engine_hours=hours,completion_notes=p_end->>'completionNotes',updated_by=auth.uid(),
    client_updated_at=clock_timestamp(),sync_version=sync_version+1 where id=t.id;
  if not found then raise exception 'OCCURRENCE_WRITE_NOT_APPLIED' using errcode='40001'; end if;
  result:=jsonb_build_object('operationId',p_operation_id,'tripId',t.id,'coverage',d,'endTime',ended,'isActive',false);
  insert into public.trip_occurrence_operations(operation_id,trip_id,vineyard_id,actor_id,request,result)
    values(p_operation_id,t.id,t.vineyard_id,auth.uid(),request,result);
  return result;
end $fn$;
alter function public.finalize_trip_occurrences_v1(uuid,uuid,bigint,bigint,jsonb,jsonb) owner to vinetrack_occurrence_writer;
revoke all on function public.finalize_trip_occurrences_v1(uuid,uuid,bigint,bigint,jsonb,jsonb) from public,anon,service_role;
grant execute on function public.finalize_trip_occurrences_v1(uuid,uuid,bigint,bigint,jsonb,jsonb) to authenticated;
commit;

-- 228: Canonical Spray Report 1.1 facts, evidence-labelled row recovery, and audited trip metadata corrections.
-- Run manually after SQL 227. This version also upgrades the earlier SQL 228/229 drafts without deleting operational data.
-- Do not rerun SQL 224-227.
begin;
select pg_advisory_xact_lock(hashtext('vinetrack:spray-report-228-upgrade'));

-- An earlier SQL 229 draft wrapped the earlier SQL 228 report. Unwrap only that
-- known chain so this transaction can replace SQL 228 beneath the final weather wrapper.
do $upgrade$
begin
  if to_regprocedure('public.get_spray_report_v1_pre_weather_provenance_v1(uuid)') is not null then
    if to_regprocedure('public.get_spray_report_v1(uuid)') is null
       or to_regprocedure('public.get_spray_report_v1_pre_canonical_facts_v1(uuid)') is null
       or pg_get_functiondef('public.get_spray_report_v1(uuid)'::regprocedure) not like '%get_spray_report_v1_pre_weather_provenance_v1%'
       or pg_get_functiondef('public.get_spray_report_v1_pre_weather_provenance_v1(uuid)'::regprocedure) not like '%get_spray_report_v1_pre_canonical_facts_v1%' then
      raise exception 'Unexpected Spray Report function chain; reconciliation stopped without changes';
    end if;
    drop function public.get_spray_report_v1(uuid);
    alter function public.get_spray_report_v1_pre_weather_provenance_v1(uuid) rename to get_spray_report_v1;
  end if;
end $upgrade$;

create table if not exists public.spray_trip_corrections (
  trip_id uuid primary key references public.trips(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  version bigint not null default 0,
  machine_id uuid references public.vineyard_machines(id) on delete set null,
  tractor_id uuid references public.tractors(id) on delete set null,
  spray_equipment_id uuid references public.spray_equipment(id) on delete set null,
  operator_user_id uuid references auth.users(id) on delete set null,
  machine_name_snapshot text,
  spray_unit_name_snapshot text,
  operator_name_snapshot text,
  fuel_consumption_l_per_hour double precision,
  fuel_consumption_source text,
  start_engine_hours double precision,
  end_engine_hours double precision,
  corrected_at timestamptz not null default now(),
  corrected_by uuid not null references auth.users(id),
  constraint spray_trip_corrections_fuel_check check (fuel_consumption_l_per_hour is null or (fuel_consumption_l_per_hour > 0 and fuel_consumption_l_per_hour < 1000)),
  constraint spray_trip_corrections_engine_check check ((start_engine_hours is null or start_engine_hours >= 0) and (end_engine_hours is null or end_engine_hours >= 0)),
  constraint spray_trip_corrections_source_check check (fuel_consumption_source is null or fuel_consumption_source = 'explicit_correction')
);

create table if not exists public.spray_trip_correction_amendments (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null unique,
  trip_id uuid not null references public.trips(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  revision bigint not null,
  previous_value jsonb not null,
  new_value jsonb not null,
  edited_by uuid not null references auth.users(id),
  editor_name text not null,
  edited_at timestamptz not null default now()
);
create index if not exists spray_trip_correction_amendments_trip_idx on public.spray_trip_correction_amendments(trip_id, revision);

create table if not exists public.spray_trip_correction_operations (
  operation_id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  request_fingerprint text not null,
  result_version bigint not null,
  completed_at timestamptz not null default now()
);

create table if not exists public.spray_row_assignment_evidence (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  block_id uuid not null,
  block_name_snapshot text not null,
  row_identity text not null,
  row_number double precision not null,
  tank_session_id text not null default '',
  tank_number integer,
  status text not null,
  assignment_source text not null,
  confidence double precision not null,
  original_evidence jsonb not null,
  derived_at timestamptz not null default now(),
  derived_by uuid not null references auth.users(id),
  unique(trip_id, block_id, row_identity, tank_session_id),
  unique(operation_id, block_id, row_identity, tank_session_id),
  constraint spray_row_assignment_status_check check (status in ('Complete','Partial','Skipped/Not complete','Not recorded')),
  constraint spray_row_assignment_source_check check (assignment_source in ('recorded_path_identity','saved_plan_identity','session_boundary_order','gps_geometry_intersection')),
  constraint spray_row_assignment_confidence_check check (confidence between 0 and 1),
  constraint spray_row_assignment_evidence_check check (jsonb_typeof(original_evidence) = 'object'),
  constraint spray_row_assignment_tank_check check (tank_number is null or tank_number >= 1),
  constraint spray_row_assignment_identity_check check (btrim(row_identity) <> '')
);
create index if not exists spray_row_assignment_evidence_trip_idx on public.spray_row_assignment_evidence(trip_id, block_id, row_number);

-- The early draft allowed NULL session IDs. Refuse to collapse genuinely
-- conflicting historical rows, otherwise normalize NULL to the canonical empty key.
do $upgrade$
begin
  if exists (
    select 1
    from public.spray_row_assignment_evidence
    group by trip_id, block_id, row_identity, coalesce(tank_session_id, '')
    having count(*) > 1
  ) then
    raise exception 'Duplicate historical row evidence would collide after session normalization; reconciliation stopped without changes';
  end if;
end $upgrade$;
update public.spray_row_assignment_evidence set tank_session_id='' where tank_session_id is null;
alter table public.spray_row_assignment_evidence alter column tank_session_id set default '';
alter table public.spray_row_assignment_evidence alter column tank_session_id set not null;

create table if not exists public.spray_row_recovery_operations (
  operation_id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  actor_user_id uuid not null references auth.users(id),
  assignment_fingerprint text not null,
  assignment_count integer not null,
  completed_at timestamptz not null default now()
);

alter table public.spray_trip_corrections enable row level security;
alter table public.spray_trip_correction_amendments enable row level security;
alter table public.spray_trip_correction_operations enable row level security;
alter table public.spray_row_assignment_evidence enable row level security;
alter table public.spray_row_recovery_operations enable row level security;
drop policy if exists spray_trip_corrections_member_read on public.spray_trip_corrections;
drop policy if exists spray_trip_amendments_member_read on public.spray_trip_correction_amendments;
drop policy if exists spray_trip_operations_member_read on public.spray_trip_correction_operations;
drop policy if exists spray_row_evidence_member_read on public.spray_row_assignment_evidence;
drop policy if exists spray_row_operations_member_read on public.spray_row_recovery_operations;
create policy spray_trip_corrections_member_read on public.spray_trip_corrections for select to authenticated using (public.is_vineyard_member(vineyard_id));
create policy spray_trip_amendments_member_read on public.spray_trip_correction_amendments for select to authenticated using (public.is_vineyard_member(vineyard_id));
create policy spray_trip_operations_member_read on public.spray_trip_correction_operations for select to authenticated using (public.is_vineyard_member(vineyard_id));
create policy spray_row_evidence_member_read on public.spray_row_assignment_evidence for select to authenticated using (public.is_vineyard_member(vineyard_id));
create policy spray_row_operations_member_read on public.spray_row_recovery_operations for select to authenticated using (public.is_vineyard_member(vineyard_id));

-- Preserve historical operation IDs from the early draft. Correction requests can
-- be reconstructed from immutable amendment snapshots. Legacy row-recovery IDs
-- are reserved because their original request array order was not stored.
insert into public.spray_trip_correction_operations(operation_id,vineyard_id,trip_id,request_fingerprint,result_version,completed_at)
select a.operation_id,a.vineyard_id,a.trip_id,
  md5(jsonb_build_object(
    'machineId',a.new_value->'machine_id',
    'tractorId',a.new_value->'tractor_id',
    'sprayEquipmentId',a.new_value->'spray_equipment_id',
    'operatorUserId',a.new_value->'operator_user_id',
    'fuelRate',a.new_value->'fuel_consumption_l_per_hour',
    'startEngineHours',a.new_value->'start_engine_hours',
    'endEngineHours',a.new_value->'end_engine_hours'
  )::text),a.revision,a.edited_at
from public.spray_trip_correction_amendments a
on conflict(operation_id) do nothing;

insert into public.spray_row_recovery_operations(operation_id,vineyard_id,trip_id,actor_user_id,assignment_fingerprint,assignment_count,completed_at)
select e.operation_id,e.vineyard_id,e.trip_id,(array_agg(e.derived_by order by e.derived_at,e.id))[1],
  'legacy_unverifiable:'||md5(jsonb_agg(to_jsonb(e) order by e.derived_at,e.id)::text),count(*)::integer,min(e.derived_at)
from public.spray_row_assignment_evidence e
group by e.operation_id,e.vineyard_id,e.trip_id
on conflict(operation_id) do nothing;
revoke all on public.spray_trip_corrections, public.spray_trip_correction_amendments, public.spray_trip_correction_operations, public.spray_row_assignment_evidence, public.spray_row_recovery_operations from public, anon, authenticated;
grant select on public.spray_trip_corrections, public.spray_trip_correction_amendments, public.spray_trip_correction_operations, public.spray_row_assignment_evidence, public.spray_row_recovery_operations to authenticated, service_role;

create or replace function public.correct_spray_trip_metadata_v1(
  p_operation_id uuid, p_trip_id uuid, p_expected_version bigint,
  p_machine_id uuid, p_tractor_id uuid, p_spray_equipment_id uuid, p_operator_user_id uuid,
  p_fuel_consumption_l_per_hour double precision, p_start_engine_hours double precision, p_end_engine_hours double precision
) returns jsonb language plpgsql security definer set search_path=public as $fn$
declare t public.trips; c public.spray_trip_corrections; old_json jsonb; new_json jsonb; actor_name text; new_version bigint; request_fingerprint text; prior_operation public.spray_trip_correction_operations;
  machine_name text; unit_name text; operator_name text;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_operation_id is null or p_expected_version is null or p_expected_version < 0 then raise exception 'Invalid correction request' using errcode='22023'; end if;
  select * into t from public.trips where id=p_trip_id and deleted_at is null for update;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor']) then raise exception 'Correction access required' using errcode='42501'; end if;
  request_fingerprint:=md5(jsonb_build_object('machineId',p_machine_id,'tractorId',p_tractor_id,'sprayEquipmentId',p_spray_equipment_id,'operatorUserId',p_operator_user_id,'fuelRate',p_fuel_consumption_l_per_hour,'startEngineHours',p_start_engine_hours,'endEngineHours',p_end_engine_hours)::text);
  select * into prior_operation from public.spray_trip_correction_operations where operation_id=p_operation_id;
  if prior_operation.operation_id is not null then
    if prior_operation.trip_id<>t.id or prior_operation.request_fingerprint<>request_fingerprint then raise exception 'Correction operation id was reused for a different request' using errcode='22023'; end if;
    select * into c from public.spray_trip_corrections where trip_id=t.id;
    return jsonb_build_object('correction',to_jsonb(c),'report',public.get_spray_report_v1(t.id));
  end if;
  if p_machine_id is not null then select name into machine_name from public.vineyard_machines where id=p_machine_id and vineyard_id=t.vineyard_id; if machine_name is null then raise exception 'Machine is not available in this vineyard' using errcode='22023'; end if; end if;
  if p_tractor_id is not null then perform 1 from public.tractors where id=p_tractor_id and vineyard_id=t.vineyard_id; if not found then raise exception 'Tractor is not available in this vineyard' using errcode='22023'; end if; end if;
  if p_spray_equipment_id is not null then select name into unit_name from public.spray_equipment where id=p_spray_equipment_id and vineyard_id=t.vineyard_id; if unit_name is null then raise exception 'Spray unit is not available in this vineyard' using errcode='22023'; end if; end if;
  if p_operator_user_id is not null then
    if not exists(select 1 from public.vineyard_members where vineyard_id=t.vineyard_id and user_id=p_operator_user_id) then raise exception 'Operator is not an active vineyard member' using errcode='22023'; end if;
    select coalesce(nullif(btrim(full_name),''),nullif(btrim(email),''),'VineTrack user') into operator_name from public.profiles where id=p_operator_user_id;
  end if;
  if p_fuel_consumption_l_per_hour is not null and (p_fuel_consumption_l_per_hour <= 0 or p_fuel_consumption_l_per_hour >= 1000 or (p_fuel_consumption_l_per_hour<>p_fuel_consumption_l_per_hour or p_fuel_consumption_l_per_hour in ('Infinity'::double precision,'-Infinity'::double precision))) then raise exception 'Fuel consumption must be a finite positive hourly rate' using errcode='22023'; end if;
  if p_start_engine_hours is not null and (p_start_engine_hours < 0 or (p_start_engine_hours<>p_start_engine_hours or p_start_engine_hours in ('Infinity'::double precision,'-Infinity'::double precision))) then raise exception 'Invalid start engine hours' using errcode='22023'; end if;
  if p_end_engine_hours is not null and (p_end_engine_hours < 0 or (p_end_engine_hours<>p_end_engine_hours or p_end_engine_hours in ('Infinity'::double precision,'-Infinity'::double precision))) then raise exception 'Invalid end engine hours' using errcode='22023'; end if;
  select * into c from public.spray_trip_corrections where trip_id=t.id for update;
  if c.trip_id is null and p_expected_version<>0 then raise exception 'Trip correction version conflict' using errcode='40001'; end if;
  if c.trip_id is not null and c.version<>p_expected_version then raise exception 'Trip correction version conflict' using errcode='40001'; end if;
  if c.trip_id is not null and c.machine_id is not distinct from p_machine_id and c.tractor_id is not distinct from p_tractor_id and c.spray_equipment_id is not distinct from p_spray_equipment_id and c.operator_user_id is not distinct from p_operator_user_id and c.fuel_consumption_l_per_hour is not distinct from p_fuel_consumption_l_per_hour and c.start_engine_hours is not distinct from p_start_engine_hours and c.end_engine_hours is not distinct from p_end_engine_hours then
    insert into public.spray_trip_correction_operations(operation_id,vineyard_id,trip_id,request_fingerprint,result_version) values(p_operation_id,t.vineyard_id,t.id,request_fingerprint,c.version);
    return jsonb_build_object('correction',to_jsonb(c),'report',public.get_spray_report_v1(t.id));
  end if;
  old_json:=coalesce(to_jsonb(c),'{}'::jsonb); new_version:=coalesce(c.version,0)+1;
  insert into public.spray_trip_corrections(trip_id,vineyard_id,version,machine_id,tractor_id,spray_equipment_id,operator_user_id,machine_name_snapshot,spray_unit_name_snapshot,operator_name_snapshot,fuel_consumption_l_per_hour,fuel_consumption_source,start_engine_hours,end_engine_hours,corrected_at,corrected_by)
  values(t.id,t.vineyard_id,new_version,p_machine_id,p_tractor_id,p_spray_equipment_id,p_operator_user_id,machine_name,unit_name,operator_name,p_fuel_consumption_l_per_hour,case when p_fuel_consumption_l_per_hour is null then null else 'explicit_correction' end,p_start_engine_hours,p_end_engine_hours,clock_timestamp(),auth.uid())
  on conflict(trip_id) do update set version=excluded.version,machine_id=excluded.machine_id,tractor_id=excluded.tractor_id,spray_equipment_id=excluded.spray_equipment_id,operator_user_id=excluded.operator_user_id,machine_name_snapshot=excluded.machine_name_snapshot,spray_unit_name_snapshot=excluded.spray_unit_name_snapshot,operator_name_snapshot=excluded.operator_name_snapshot,fuel_consumption_l_per_hour=excluded.fuel_consumption_l_per_hour,fuel_consumption_source=excluded.fuel_consumption_source,start_engine_hours=excluded.start_engine_hours,end_engine_hours=excluded.end_engine_hours,corrected_at=excluded.corrected_at,corrected_by=excluded.corrected_by returning * into c;
  new_json:=to_jsonb(c);
  if old_json is distinct from new_json then
    select coalesce(nullif(btrim(full_name),''),nullif(btrim(email),''),'VineTrack user') into actor_name from public.profiles where id=auth.uid();
    insert into public.spray_trip_correction_amendments(operation_id,trip_id,vineyard_id,revision,previous_value,new_value,edited_by,editor_name)
    values(p_operation_id,t.id,t.vineyard_id,new_version,old_json,new_json,auth.uid(),coalesce(actor_name,'VineTrack user'));
  end if;
  insert into public.spray_trip_correction_operations(operation_id,vineyard_id,trip_id,request_fingerprint,result_version) values(p_operation_id,t.vineyard_id,t.id,request_fingerprint,c.version);
  return jsonb_build_object('correction',to_jsonb(c),'report',public.get_spray_report_v1(t.id));
end $fn$;

create or replace function public.recover_spray_row_assignments_v1(p_operation_id uuid,p_trip_id uuid,p_actor_user_id uuid,p_assignments jsonb)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare t public.trips; a jsonb; v_block_id uuid; source text; v_confidence double precision; v_row_number double precision; session_id text; evidence jsonb; fingerprint text; prior_operation public.spray_row_recovery_operations;
begin
  if auth.role()<>'service_role' then raise exception 'Service recovery authority required' using errcode='42501'; end if;
  select * into t from public.trips where id=p_trip_id and deleted_at is null for update;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if not (coalesce(t.trip_function,'')='spraying' or exists(select 1 from public.spray_records r where r.trip_id=t.id and not r.is_template and r.deleted_at is null)) then raise exception 'Trip is not a spray trip' using errcode='22023'; end if;
  if p_actor_user_id is null or not exists(select 1 from public.vineyard_members where vineyard_id=t.vineyard_id and user_id=p_actor_user_id and role in ('owner','manager','supervisor')) then raise exception 'Recovery access required' using errcode='42501'; end if;
  if p_operation_id is null or jsonb_typeof(p_assignments)<>'array' then raise exception 'Invalid recovery request' using errcode='22023'; end if;
  fingerprint:=md5(p_assignments::text);
  select * into prior_operation from public.spray_row_recovery_operations where operation_id=p_operation_id;
  if prior_operation.operation_id is not null then
    if prior_operation.trip_id<>t.id or prior_operation.assignment_fingerprint<>fingerprint then raise exception 'Recovery operation id was reused for a different request' using errcode='22023'; end if;
    return coalesce((select jsonb_agg(to_jsonb(e) order by e.block_name_snapshot,e.row_number,e.row_identity) from public.spray_row_assignment_evidence e where e.trip_id=t.id),'[]'::jsonb);
  end if;
  insert into public.spray_row_recovery_operations(operation_id,vineyard_id,trip_id,actor_user_id,assignment_fingerprint,assignment_count) values(p_operation_id,t.vineyard_id,t.id,p_actor_user_id,fingerprint,jsonb_array_length(p_assignments));
  for a in select value from jsonb_array_elements(p_assignments) loop
    begin v_block_id:=(a->>'blockId')::uuid; v_confidence:=(a->>'confidence')::double precision; v_row_number:=(a->>'rowNumber')::double precision; exception when others then raise exception 'Invalid assignment identity, path, or confidence' using errcode='22023'; end;
    source:=a->>'assignmentSource'; session_id:=coalesce(nullif(btrim(a->>'tankSessionId'),''),''); evidence:=a->'originalEvidence';
    if v_confidence is null or v_confidence<>v_confidence or v_confidence<0 or v_confidence>1 then raise exception 'Invalid assignment confidence' using errcode='22023'; end if;
    if source='gps_geometry_intersection' and v_confidence<0.9 then raise exception 'GPS/geometry assignments require confidence of at least 0.9' using errcode='22023'; end if;
    if source not in ('saved_plan_identity','session_boundary_order','gps_geometry_intersection') then raise exception 'Unsupported derived assignment evidence' using errcode='22023'; end if;
    if jsonb_typeof(evidence)<>'object' or evidence->>'derivationVersion'<>'spray-row-recovery-v1' or (evidence->>'pathNumber')::double precision is distinct from v_row_number then raise exception 'Shared recovery derivation evidence is required' using errcode='22023'; end if;
    if 1<>(select count(*) from jsonb_array_elements(coalesce(t.row_sequence,'[]'::jsonb)) x where (x#>>'{}')::double precision=v_row_number) then raise exception 'Recovered path must occur exactly once in the recorded trip plan' using errcode='22023'; end if;
    if not exists(select 1 from public.paddocks where id=v_block_id and vineyard_id=t.vineyard_id and deleted_at is null) then raise exception 'Block identity is not available in this vineyard' using errcode='22023'; end if;
    if not (coalesce(evidence->'candidateBlockIds','[]'::jsonb) ? v_block_id::text) or jsonb_array_length(coalesce(evidence->'matchingRowIds','[]'::jsonb))=0 or position(v_block_id::text in a->>'rowIdentity')=0 or exists(select 1 from jsonb_array_elements_text(evidence->'matchingRowIds') rid where position(rid in a->>'rowIdentity')=0) then raise exception 'Saved row/block evidence does not support this assignment identity' using errcode='22023'; end if;
    if session_id<>'' and not exists(select 1 from jsonb_array_elements(coalesce(t.tank_sessions,'[]'::jsonb)) s where coalesce(s->>'id',s->>'tank_session_id')=session_id) then raise exception 'Tank session identity is not recorded on this trip' using errcode='22023'; end if;
    if exists(select 1 from public.spray_row_assignment_evidence e where e.trip_id=t.id and e.block_id=v_block_id and e.row_identity=btrim(a->>'rowIdentity') and e.tank_session_id=session_id and (e.row_number is distinct from v_row_number or e.tank_number is distinct from (a->>'tankNumber')::integer or e.status is distinct from coalesce(nullif(a->>'status',''),'Not recorded') or e.assignment_source is distinct from source or e.confidence is distinct from v_confidence or e.original_evidence is distinct from evidence)) then raise exception 'Conflicting recovery evidence already exists' using errcode='40001'; end if;
    insert into public.spray_row_assignment_evidence(operation_id,vineyard_id,trip_id,block_id,block_name_snapshot,row_identity,row_number,tank_session_id,tank_number,status,assignment_source,confidence,original_evidence,derived_by)
    values(p_operation_id,t.vineyard_id,t.id,v_block_id,coalesce(nullif(btrim(a->>'blockName'),''),(select name from public.paddocks where id=v_block_id),'Archived block'),btrim(a->>'rowIdentity'),v_row_number,session_id,(a->>'tankNumber')::integer,coalesce(nullif(a->>'status',''),'Not recorded'),source,v_confidence,evidence,p_actor_user_id)
    on conflict(trip_id,block_id,row_identity,tank_session_id) do nothing;
  end loop;
  return coalesce((select jsonb_agg(to_jsonb(e) order by e.block_name_snapshot,e.row_number,e.row_identity) from public.spray_row_assignment_evidence e where e.trip_id=t.id),'[]'::jsonb);
end $fn$;

-- Parse optional legacy JSON numerics without allowing malformed text, NaN, or infinity to break a report.
create or replace function public.spray_report_safe_number_v1(p_value text) returns double precision language plpgsql immutable set search_path=public as $safe$
declare parsed double precision;
begin
  if btrim(coalesce(p_value,'')) !~ '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$' then return null; end if;
  begin
    parsed:=p_value::double precision;
  exception when invalid_text_representation or numeric_value_out_of_range then
    return null;
  end;
  if parsed<>parsed or parsed in ('Infinity'::double precision,'-Infinity'::double precision) then return null; end if;
  return parsed;
end $safe$;
revoke all on function public.spray_report_safe_number_v1(text) from public,anon,authenticated;
grant execute on function public.spray_report_safe_number_v1(text) to service_role;

-- Add canonical report facts without modifying the applied SQL 227 body.
do $upgrade$
begin
  if to_regprocedure('public.get_spray_report_v1_pre_canonical_facts_v1(uuid)') is null then
    alter function public.get_spray_report_v1(uuid) rename to get_spray_report_v1_pre_canonical_facts_v1;
  elsif to_regprocedure('public.get_spray_report_v1(uuid)') is null then
    raise exception 'Canonical Spray Report base exists but its public wrapper is missing';
  end if;
end $upgrade$;
create or replace function public.get_spray_report_v1(p_trip_id uuid) returns jsonb language plpgsql security definer set search_path=public as $fn$
declare payload jsonb; t public.trips; r public.spray_records; c public.spray_trip_corrections; j public.spray_jobs;
  machine_id uuid; tractor_id uuid; unit_id uuid; operator_id uuid; machine_name text; unit_name text; operator_name text;
  fuel_rate double precision; fuel_source text; active_seconds bigint; engine_used double precision; fuel_hours double precision; fuel_litres double precision; fuel_price double precision; fuel_cost double precision;
  labour_rate double precision; labour_cost double precision; labour_source text; chemical_cost double precision; chemical_basis text; chemical_amount_count integer; chemical_priced_count integer; chemical_missing boolean; known_cost_subtotal double precision; total_cost double precision; costing_reasons jsonb; is_cost_complete boolean;
  planned_totals jsonb; actual_totals jsonb; sessions jsonb; recovered_rows jsonb; unresolved_rows jsonb; metadata_history jsonb; can_cost boolean;
begin
  payload:=public.get_spray_report_v1_pre_canonical_facts_v1(p_trip_id);
  select * into t from public.trips where id=p_trip_id and deleted_at is null;
  select * into r from public.spray_records where id=(payload#>>'{identity,sprayRecordId}')::uuid;
  select * into c from public.spray_trip_corrections where trip_id=t.id;
  if r.spray_job_id is not null then select * into j from public.spray_jobs where id=r.spray_job_id; end if;
  machine_id:=case when c.trip_id is not null then c.machine_id else coalesce(t.machine_id,r.machine_id) end;
  tractor_id:=case when c.trip_id is not null then c.tractor_id else coalesce(t.tractor_id,r.tractor_id) end;
  unit_id:=case when c.trip_id is not null then c.spray_equipment_id else r.spray_equipment_id end;
  operator_id:=case when c.trip_id is not null then c.operator_user_id else t.operator_user_id end;
  select name into machine_name from public.vineyard_machines where id=machine_id; select name into unit_name from public.spray_equipment where id=unit_id;
  select coalesce(nullif(btrim(full_name),''),nullif(btrim(email),'')) into operator_name from public.profiles where id=operator_id;
  machine_name:=case when c.trip_id is not null then c.machine_name_snapshot else coalesce(machine_name,r.tractor) end;
  unit_name:=case when c.trip_id is not null then c.spray_unit_name_snapshot else coalesce(unit_name,r.equipment_type) end;
  operator_name:=case when c.trip_id is not null then c.operator_name_snapshot else coalesce(operator_name,nullif(t.person_name,'')) end;
  fuel_rate:=c.fuel_consumption_l_per_hour;
  if fuel_rate is not null then fuel_source:='explicit_correction';
  elsif machine_id is not null then select nullif(fuel_usage_l_per_hour,0) into fuel_rate from public.vineyard_machines where id=machine_id; fuel_source:=case when fuel_rate is null then 'not_recorded' else 'equipment_default' end;
  elsif tractor_id is not null then select nullif(fuel_usage_l_per_hour,0) into fuel_rate from public.tractors where id=tractor_id; fuel_source:=case when fuel_rate is null then 'not_recorded' else 'legacy_tractor_default' end;
  else fuel_source:='not_recorded'; end if;
  active_seconds:=(payload#>>'{trip,activeDurationSeconds}')::bigint;
  engine_used:=case when (case when c.trip_id is not null then c.end_engine_hours else t.end_engine_hours end)>(case when c.trip_id is not null then c.start_engine_hours else t.start_engine_hours end) then (case when c.trip_id is not null then c.end_engine_hours else t.end_engine_hours end)-(case when c.trip_id is not null then c.start_engine_hours else t.start_engine_hours end) end;
  fuel_hours:=coalesce(engine_used,active_seconds/3600.0); fuel_litres:=case when fuel_rate>0 and fuel_hours>=0 then fuel_rate*fuel_hours end;
  select sum(fp.total_cost)/nullif(sum(fp.volume_litres),0) into fuel_price from public.fuel_purchases fp where fp.vineyard_id=t.vineyard_id and fp.deleted_at is null and fp.volume_litres>0;
  if fuel_price is not null and (fuel_price<=0 or fuel_price<>fuel_price or fuel_price in ('Infinity'::double precision,'-Infinity'::double precision)) then fuel_price:=null; end if;
  if fuel_rate is not null and (fuel_rate<=0 or fuel_rate<>fuel_rate or fuel_rate in ('Infinity'::double precision,'-Infinity'::double precision)) then fuel_rate:=null; fuel_litres:=null; end if;
  fuel_cost:=case when fuel_litres is not null and fuel_price is not null then fuel_litres*fuel_price end;
  select wt.cost_per_hour,case when t.worker_type_id is not null then 'trip_worker_type' else 'operator_membership_worker_type' end into labour_rate,labour_source
  from public.worker_types wt where wt.id=coalesce(t.worker_type_id,(select vm.worker_type_id from public.vineyard_members vm where vm.vineyard_id=t.vineyard_id and vm.user_id=operator_id limit 1)) and wt.vineyard_id=t.vineyard_id and wt.deleted_at is null and wt.cost_per_hour>0;
  select case when count(*)>0 and bool_and(tca.labour_cost is not null) then sum(tca.labour_cost)::double precision end into labour_cost from public.trip_cost_allocations tca where tca.trip_id=t.id and tca.deleted_at is null;
  if labour_rate is not null and (labour_rate<=0 or labour_rate<>labour_rate or labour_rate in ('Infinity'::double precision,'-Infinity'::double precision)) then labour_rate:=null; end if;
  if labour_cost is not null and (labour_cost<0 or labour_cost<>labour_cost or labour_cost in ('Infinity'::double precision,'-Infinity'::double precision)) then labour_cost:=null; end if;
  if labour_cost is not null then labour_source:='trip_cost_allocation';
  elsif t.end_time is null and labour_rate is not null and active_seconds is not null then labour_cost:=labour_rate*active_seconds/3600.0; labour_source:=coalesce(labour_source,'current_worker_type');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('identityKey',identity_key,'name',name,'unit',display_unit,'actualAmountBase',total) order by lower(name),dimension),'[]') into planned_totals from (
    select coalesce(x->>'savedChemicalId',x->>'saved_chemical_id',lower(btrim(x->>'name'))||'|'||case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end) identity_key,
      min(coalesce(x->>'name','Unnamed chemical')) name,case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end dimension,
      case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'Litres' else 'Kg' end display_unit,
      sum(coalesce(public.spray_report_safe_number_v1(x->>'volumePerTank')::numeric,public.spray_report_safe_number_v1(x->>'volume_per_tank')::numeric,0)) total
    from jsonb_array_elements(coalesce(r.tanks,'[]')) tank cross join lateral jsonb_array_elements(coalesce(tank->'chemicals','[]')) x
    group by coalesce(x->>'savedChemicalId',x->>'saved_chemical_id',lower(btrim(x->>'name'))||'|'||case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end),case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end
  ) q;
  select coalesce(jsonb_agg(jsonb_build_object('identityKey',identity_key,'name',name,'unit',display_unit,'actualAmountBase',total) order by lower(name),dimension),'[]') into actual_totals from (
    select coalesce(x->>'savedChemicalId',lower(btrim(x->>'name'))||'|'||case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end) identity_key,
      min(coalesce(x->>'name','Unnamed chemical')) name,case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end dimension,
      case when x->>'unit' in ('Litres','mL') then 'Litres' else 'Kg' end display_unit,sum(public.spray_report_safe_number_v1(x->>'actualAmountBase')::numeric) total
    from jsonb_array_elements(payload->'tanks') tank cross join lateral jsonb_array_elements(tank->'chemicals') x
    where x->'actualAmountBase' <> 'null'::jsonb
    group by coalesce(x->>'savedChemicalId',lower(btrim(x->>'name'))||'|'||case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end),case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end
  ) q;
  select coalesce(jsonb_agg(jsonb_build_object('tankSessionId',coalesce(s->>'id',s->>'tank_session_id'),'tankNumber',coalesce((s->>'tankNumber')::int,(s->>'tank_number')::int),'startedAt',coalesce(s->>'startTime',s->>'start_time'),'endedAt',coalesce(s->>'endTime',s->>'end_time'),'startRow',coalesce((s->>'startRow')::double precision,(s->>'start_row')::double precision),'endRow',coalesce((s->>'endRow')::double precision,(s->>'end_row')::double precision),'pathsCovered',coalesce(s->'pathsCovered',s->'paths_covered','[]'),'status',case when coalesce(s->>'endTime',s->>'end_time') is not null then 'Complete' when t.end_time is not null then 'End not recorded' else 'In progress' end,'assignmentSource',case when jsonb_array_length(coalesce(s->'pathsCovered',s->'paths_covered','[]'))>0 then 'recorded_path_identity' when coalesce(s->>'startRow',s->>'start_row') is not null and coalesce(s->>'endRow',s->>'end_row') is not null then 'session_boundary_order' else 'not_recorded' end) order by ord),'[]') into sessions from jsonb_array_elements(coalesce(t.tank_sessions,'[]')) with ordinality z(s,ord);
  select jsonb_agg(jsonb_build_object('rowIdentity',e.row_identity,'rowNumber',e.row_number,'blockId',e.block_id,'blockName',e.block_name_snapshot,'status',e.status,'source',e.assignment_source,'confidence',e.confidence,'isDerived',true,'tank',e.tank_number,'tankSessionId',nullif(e.tank_session_id,''),'originalEvidence',e.original_evidence) order by e.block_name_snapshot,e.row_number,e.row_identity) into recovered_rows from public.spray_row_assignment_evidence e where e.trip_id=t.id;
  select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'operationId',a.operation_id,'revision',a.revision,'previousValue',a.previous_value,'newValue',a.new_value,'editedBy',a.edited_by,'editorName',a.editor_name,'editedAt',a.edited_at) order by a.revision),'[]') into metadata_history from public.spray_trip_correction_amendments a where a.trip_id=t.id;
  can_cost:=public.has_vineyard_role(t.vineyard_id,array['owner','manager']);
  payload:=jsonb_set(payload,'{schemaVersion}',to_jsonb('1.1'::text));
  payload:=jsonb_set(payload,'{trip}',(payload->'trip')||jsonb_build_object('operatorId',operator_id,'operatorName',operator_name,'operatorSource',case when c.operator_user_id is not null then 'explicit_correction' when t.operator_user_id is not null then 'recorded_identity' when nullif(t.person_name,'') is not null then 'recorded_snapshot' else 'not_recorded' end,'elapsedDurationSeconds',case when t.start_time is null then null else greatest(0,extract(epoch from (coalesce(t.end_time,now())-t.start_time))::bigint) end,'pausedDurationSeconds',case when active_seconds is null or t.start_time is null then null else greatest(0,extract(epoch from (coalesce(t.end_time,now())-t.start_time))::bigint-active_seconds) end));
  payload:=jsonb_set(payload,'{equipment}',jsonb_build_object('machineId',machine_id,'tractorId',tractor_id,'tractorName',nullif(machine_name,''),'sprayEquipmentId',unit_id,'sprayUnitName',nullif(unit_name,''),'equipmentSource',case when c.trip_id is not null then 'explicit_correction' when t.machine_id is not null or t.tractor_id is not null then 'trip_recorded_identity' else 'spray_record_snapshot' end,'startEngineHours',case when c.trip_id is not null then c.start_engine_hours else t.start_engine_hours end,'endEngineHours',case when c.trip_id is not null then c.end_engine_hours else t.end_engine_hours end,'engineHoursUsed',engine_used,'tractorGear',nullif(r.tractor_gear,''),'numberOfFansJets',nullif(r.number_of_fans_jets,''),'averageSpeedKmh',r.average_speed,'fuelConsumptionLPerHour',fuel_rate,'fuelConsumptionSource',fuel_source,'fuelHours',fuel_hours,'fuelHoursSource',case when engine_used is not null then 'engine_hours' else 'pause_adjusted_duration' end));
  payload:=jsonb_set(payload,'{application}',jsonb_build_object('operationType',r.operation_type,'applicationMode',r.application_mode,'grossAreaHa',r.gross_area_ha,'treatedAreaHa',r.treated_area_ha,'treatedAreaMethod',r.treated_area_method,'geometrySource',r.geometry_source,'geometryQuality',r.geometry_quality,'carrierVolumeBasis',r.carrier_volume_basis,'totalCarrierLitres',r.total_carrier_litres,'carrierLitresPerHectare',r.carrier_litres_per_hectare,'diluteLitresPer100m',r.dilute_litres_per_100m,'appliedLitresPer100m',r.applied_litres_per_100m,'concentrationFactor',r.concentration_factor,'notes',nullif(r.notes,'')));
  payload:=jsonb_set(payload,'{programStep}',jsonb_build_object('linkState',case when r.spray_job_id is null then 'not_recorded' when j.id is null then 'linked_step_unavailable' else 'program_linked' end,'sprayJobId',r.spray_job_id,'name',j.name,'status',j.status,'plannedDate',j.planned_date,'operationType',j.operation_type,'target',j.target,'notes',j.notes));
  payload:=jsonb_set(payload,'{tankSessions}',sessions); payload:=jsonb_set(payload,'{plannedChemicalTotals}',planned_totals); payload:=jsonb_set(payload,'{actualChemicalTotals}',actual_totals);
  select coalesce(jsonb_agg(case when x->>'source'='incompletePlannedPath' then x||jsonb_build_object('status','Not recorded','source','noProgressEvidence') else x end),'[]'::jsonb) into unresolved_rows
  from jsonb_array_elements(payload->'rows') x
  where not exists(select 1 from public.spray_row_assignment_evidence e where e.trip_id=t.id and e.row_number=(x->>'rowNumber')::double precision)
     or 1<(select count(*) from jsonb_array_elements(payload->'rows') repeated where repeated->>'rowNumber'=x->>'rowNumber');
  payload:=jsonb_set(payload,'{rows}',coalesce(recovered_rows,'[]'::jsonb)||coalesce(unresolved_rows,'[]'::jsonb));
  payload:=jsonb_set(payload,'{metadataCorrectionVersion}',to_jsonb(coalesce(c.version,0))); payload:=jsonb_set(payload,'{metadataAmendments}',metadata_history);
  -- Chemical prices use the immutable tank-line cost first, then the vineyard's saved purchase price per base mL/g. Each recorded actual quantity wins for its line; missing actuals retain the frozen planned estimate without changing the plan.
  select sum(line_cost),case when bool_and(using_actual) then 'actual' when bool_or(using_actual) then 'mixed_actual_and_planned' else 'estimated_planned' end,count(line_cost) into chemical_cost,chemical_basis,chemical_priced_count from (
    select case when using_actual then amount*purchase_cpu when frozen_cpu is not null then amount*frozen_cpu when cchem->>'unit' in ('mL','g') then amount*purchase_cpu else null end line_cost,using_actual
    from (
      select cchem,ptank,coalesce(public.spray_report_safe_number_v1(cchem->>'actualAmountBase'),public.spray_report_safe_number_v1(cchem->>'plannedAmountBase')) amount,
        (select nullif(public.spray_report_safe_number_v1(pc->>'costPerUnit'),0) from jsonb_array_elements(coalesce(ptank->'chemicals','[]'::jsonb)) pc where pc->>'id'=cchem->>'plannedChemicalId' limit 1) frozen_cpu,
        (select case when public.spray_report_safe_number_v1(sc.purchase->>'costDollars')>0 and public.spray_report_safe_number_v1(sc.purchase->>'containerSizeML')>0 then public.spray_report_safe_number_v1(sc.purchase->>'costDollars')/(public.spray_report_safe_number_v1(sc.purchase->>'containerSizeML')*case when sc.purchase->>'containerUnit' in ('Litres','Kg') then 1000 else 1 end) end from public.saved_chemicals sc where sc.vineyard_id=t.vineyard_id and sc.deleted_at is null and ((cchem->>'unit' in ('Litres','mL') and sc.purchase->>'containerUnit' in ('Litres','mL')) or (cchem->>'unit' in ('Kg','g') and sc.purchase->>'containerUnit' in ('Kg','g'))) and (sc.id::text=cchem->>'savedChemicalId' or (cchem->>'savedChemicalId' is null and lower(btrim(sc.name))=lower(btrim(cchem->>'name')) and 1=(select count(*) from public.saved_chemicals sx where sx.vineyard_id=t.vineyard_id and sx.deleted_at is null and lower(btrim(sx.name))=lower(btrim(cchem->>'name'))))) order by (sc.id::text=cchem->>'savedChemicalId') desc limit 1) purchase_cpu,
        (cchem->'actualAmountBase'<>'null'::jsonb) using_actual
      from jsonb_array_elements(payload->'tanks') ctank
      cross join lateral jsonb_array_elements(ctank->'chemicals') cchem
      left join lateral (select p value from jsonb_array_elements(coalesce(r.tanks,'[]'::jsonb)) p where coalesce((p->>'tankNumber')::integer,(p->>'tank_number')::integer)=(ctank->>'tankNumber')::integer limit 1) planned(ptank) on true
    ) priced where amount>0
  ) costs;
  select count(*) into chemical_amount_count from jsonb_array_elements(payload->'tanks') tank cross join lateral jsonb_array_elements(tank->'chemicals') chem where coalesce(public.spray_report_safe_number_v1(chem->>'actualAmountBase'),public.spray_report_safe_number_v1(chem->>'plannedAmountBase'),0)>0;
  chemical_missing:=coalesce(chemical_priced_count,0)<chemical_amount_count;
  if chemical_amount_count=0 then chemical_cost:=0; chemical_basis:='none'; elsif chemical_missing then chemical_cost:=null; end if;
  costing_reasons:='[]'::jsonb;
  if fuel_rate is null then costing_reasons:=costing_reasons||jsonb_build_array(jsonb_build_object('component','fuel','code','missing_fuel_rate','kind','missing_data')); elsif fuel_price is null then costing_reasons:=costing_reasons||jsonb_build_array(jsonb_build_object('component','fuel','code','missing_fuel_purchase_price','kind','missing_data')); elsif fuel_hours is null then costing_reasons:=costing_reasons||jsonb_build_array(jsonb_build_object('component','fuel','code','missing_active_or_engine_hours','kind','missing_data')); end if;
  if labour_cost is null and t.end_time is not null and labour_rate is not null then costing_reasons:=costing_reasons||jsonb_build_array(jsonb_build_object('component','labour','code','missing_historical_labour_cost_snapshot','kind','missing_data')); elsif labour_rate is null and labour_cost is null then costing_reasons:=costing_reasons||jsonb_build_array(jsonb_build_object('component','labour','code','missing_worker_type_rate','kind','missing_data')); elsif active_seconds is null and labour_cost is null then costing_reasons:=costing_reasons||jsonb_build_array(jsonb_build_object('component','labour','code','missing_active_duration','kind','missing_data')); end if;
  if chemical_missing then costing_reasons:=costing_reasons||jsonb_build_array(jsonb_build_object('component','chemical','code','missing_or_ambiguous_chemical_unit_price','kind','missing_data')); end if;
  is_cost_complete:=jsonb_array_length(costing_reasons)=0; known_cost_subtotal:=case when fuel_cost is not null or chemical_cost is not null or labour_cost is not null then coalesce(fuel_cost,0)+coalesce(chemical_cost,0)+coalesce(labour_cost,0) end; total_cost:=case when is_cost_complete then known_cost_subtotal end;
  payload:=jsonb_set(payload,'{cost}',case when not can_cost then 'null'::jsonb else jsonb_build_object('visibility','owner_manager','currencyCode',coalesce((select currency_code from public.vineyards where id=t.vineyard_id),'AUD'),'fuelLitres',fuel_litres,'fuelRateLPerHour',fuel_rate,'fuelHours',fuel_hours,'fuelPricePerLitre',fuel_price,'fuelCost',fuel_cost,'chemicalCost',chemical_cost,'chemicalCostBasis',chemical_basis,'labourRatePerHour',labour_rate,'labourRateSource',coalesce(labour_source,'not_recorded'),'labourCost',labour_cost,'knownCostSubtotal',known_cost_subtotal,'totalCost',total_cost,'treatedAreaHa',r.treated_area_ha,'costPerTreatedHa',case when r.treated_area_ha>0 and total_cost is not null then total_cost/r.treated_area_ha end,'isComplete',is_cost_complete,'incompleteReasons',costing_reasons,'basis','Fuel uses weighted recorded purchases and corrected/equipment consumption. Labour uses a stored trip cost allocation for completed history, or the current recorded worker type and active duration while a trip is open. Planned chemicals use their frozen price/quantity pair; actual chemicals require an unambiguous saved purchase price per base mL/g. Ambiguous legacy unit pricing remains incomplete.') end);
  return payload;
end $fn$;

revoke all on function public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision) from public,anon,service_role;
grant execute on function public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision) to authenticated;
revoke all on function public.recover_spray_row_assignments_v1(uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.recover_spray_row_assignments_v1(uuid,uuid,uuid,jsonb) to service_role;
drop function if exists public.recover_spray_row_assignments_v1(uuid,uuid,jsonb);
revoke all on function public.get_spray_report_v1_pre_canonical_facts_v1(uuid) from public,anon,authenticated;
revoke all on function public.get_spray_report_v1(uuid) from public,anon;
grant execute on function public.get_spray_report_v1(uuid) to authenticated;

commit;

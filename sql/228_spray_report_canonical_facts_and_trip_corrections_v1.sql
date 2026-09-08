-- 228: Canonical Spray Report 1.1 facts, evidence-labelled row recovery, and audited trip metadata corrections.
-- Run manually once after SQL 227. Do not rerun SQL 224-227.
begin;

create table public.spray_trip_corrections (
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

create table public.spray_trip_correction_amendments (
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
create index spray_trip_correction_amendments_trip_idx on public.spray_trip_correction_amendments(trip_id, revision);

create table public.spray_row_assignment_evidence (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  block_id uuid not null,
  block_name_snapshot text not null,
  row_identity text not null,
  row_number double precision not null,
  tank_session_id text,
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
create index spray_row_assignment_evidence_trip_idx on public.spray_row_assignment_evidence(trip_id, block_id, row_number);

alter table public.spray_trip_corrections enable row level security;
alter table public.spray_trip_correction_amendments enable row level security;
alter table public.spray_row_assignment_evidence enable row level security;
create policy spray_trip_corrections_member_read on public.spray_trip_corrections for select to authenticated using (public.is_vineyard_member(vineyard_id));
create policy spray_trip_amendments_member_read on public.spray_trip_correction_amendments for select to authenticated using (public.is_vineyard_member(vineyard_id));
create policy spray_row_evidence_member_read on public.spray_row_assignment_evidence for select to authenticated using (public.is_vineyard_member(vineyard_id));
revoke all on public.spray_trip_corrections, public.spray_trip_correction_amendments, public.spray_row_assignment_evidence from public, anon, authenticated;
grant select on public.spray_trip_corrections, public.spray_trip_correction_amendments, public.spray_row_assignment_evidence to authenticated, service_role;

create or replace function public.correct_spray_trip_metadata_v1(
  p_operation_id uuid, p_trip_id uuid, p_expected_version bigint,
  p_machine_id uuid, p_tractor_id uuid, p_spray_equipment_id uuid, p_operator_user_id uuid,
  p_fuel_consumption_l_per_hour double precision, p_start_engine_hours double precision, p_end_engine_hours double precision
) returns jsonb language plpgsql security definer set search_path=public as $fn$
declare t public.trips; c public.spray_trip_corrections; old_json jsonb; new_json jsonb; actor_name text; new_version bigint;
  machine_name text; unit_name text; operator_name text;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_operation_id is null or p_expected_version is null or p_expected_version < 0 then raise exception 'Invalid correction request' using errcode='22023'; end if;
  select * into t from public.trips where id=p_trip_id and deleted_at is null for update;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor']) then raise exception 'Correction access required' using errcode='42501'; end if;
  if exists(select 1 from public.spray_trip_correction_amendments where operation_id=p_operation_id) then
    select * into c from public.spray_trip_corrections where trip_id=t.id;
    return jsonb_build_object('correction',to_jsonb(c),'report',public.get_spray_report_v1(t.id));
  end if;
  if p_machine_id is not null then select name into machine_name from public.vineyard_machines where id=p_machine_id and vineyard_id=t.vineyard_id; if machine_name is null then raise exception 'Machine is not available in this vineyard' using errcode='22023'; end if; end if;
  if p_tractor_id is not null then perform 1 from public.tractors where id=p_tractor_id and vineyard_id=t.vineyard_id; if not found then raise exception 'Tractor is not available in this vineyard' using errcode='22023'; end if; end if;
  if p_spray_equipment_id is not null then select name into unit_name from public.spray_equipment where id=p_spray_equipment_id and vineyard_id=t.vineyard_id; if unit_name is null then raise exception 'Spray unit is not available in this vineyard' using errcode='22023'; end if; end if;
  if p_operator_user_id is not null then
    if not exists(select 1 from public.vineyard_members where vineyard_id=t.vineyard_id and user_id=p_operator_user_id and deleted_at is null) then raise exception 'Operator is not an active vineyard member' using errcode='22023'; end if;
    select coalesce(nullif(btrim(full_name),''),nullif(btrim(email),''),'VineTrack user') into operator_name from public.profiles where id=p_operator_user_id;
  end if;
  if p_fuel_consumption_l_per_hour is not null and (p_fuel_consumption_l_per_hour <= 0 or p_fuel_consumption_l_per_hour >= 1000 or (p_fuel_consumption_l_per_hour<>p_fuel_consumption_l_per_hour or p_fuel_consumption_l_per_hour in ('Infinity'::double precision,'-Infinity'::double precision))) then raise exception 'Fuel consumption must be a finite positive hourly rate' using errcode='22023'; end if;
  if p_start_engine_hours is not null and (p_start_engine_hours < 0 or (p_start_engine_hours<>p_start_engine_hours or p_start_engine_hours in ('Infinity'::double precision,'-Infinity'::double precision))) then raise exception 'Invalid start engine hours' using errcode='22023'; end if;
  if p_end_engine_hours is not null and (p_end_engine_hours < 0 or (p_end_engine_hours<>p_end_engine_hours or p_end_engine_hours in ('Infinity'::double precision,'-Infinity'::double precision))) then raise exception 'Invalid end engine hours' using errcode='22023'; end if;
  select * into c from public.spray_trip_corrections where trip_id=t.id for update;
  if c.trip_id is null and p_expected_version<>0 then raise exception 'Trip correction version conflict' using errcode='40001'; end if;
  if c.trip_id is not null and c.version<>p_expected_version then raise exception 'Trip correction version conflict' using errcode='40001'; end if;
  if c.trip_id is not null and c.machine_id is not distinct from p_machine_id and c.tractor_id is not distinct from p_tractor_id and c.spray_equipment_id is not distinct from p_spray_equipment_id and c.operator_user_id is not distinct from p_operator_user_id and c.fuel_consumption_l_per_hour is not distinct from p_fuel_consumption_l_per_hour and c.start_engine_hours is not distinct from p_start_engine_hours and c.end_engine_hours is not distinct from p_end_engine_hours then
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
  return jsonb_build_object('correction',to_jsonb(c),'report',public.get_spray_report_v1(t.id));
end $fn$;

create or replace function public.recover_spray_row_assignments_v1(p_operation_id uuid,p_trip_id uuid,p_assignments jsonb)
returns jsonb language plpgsql security definer set search_path=public as $fn$
declare t public.trips; a jsonb; block_id uuid; source text; confidence double precision;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select * into t from public.trips where id=p_trip_id and deleted_at is null for update;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor']) then raise exception 'Recovery access required' using errcode='42501'; end if;
  if p_operation_id is null or jsonb_typeof(p_assignments)<>'array' then raise exception 'Invalid recovery request' using errcode='22023'; end if;
  for a in select value from jsonb_array_elements(p_assignments) loop
    begin block_id:=(a->>'blockId')::uuid; confidence:=(a->>'confidence')::double precision; exception when others then raise exception 'Invalid assignment identity or confidence' using errcode='22023'; end;
    source:=a->>'assignmentSource';
    if source='gps_geometry_intersection' and confidence<0.9 then raise exception 'GPS/geometry assignments require confidence of at least 0.9' using errcode='22023'; end if;
    if source not in ('recorded_path_identity','saved_plan_identity','session_boundary_order','gps_geometry_intersection') then raise exception 'Unsupported assignment evidence' using errcode='22023'; end if;
    if not exists(select 1 from public.paddocks where id=block_id and vineyard_id=t.vineyard_id) and not exists(select 1 from public.spray_records r cross join lateral jsonb_array_elements(coalesce(r.application_blocks,'[]')) b where r.trip_id=t.id and b->>'blockId'=block_id::text) then raise exception 'Block identity is not recorded for this vineyard or spray' using errcode='22023'; end if;
    insert into public.spray_row_assignment_evidence(operation_id,vineyard_id,trip_id,block_id,block_name_snapshot,row_identity,row_number,tank_session_id,tank_number,status,assignment_source,confidence,original_evidence,derived_by)
    values(p_operation_id,t.vineyard_id,t.id,block_id,coalesce(nullif(a->>'blockName',''),(select name from public.paddocks where id=block_id),'Archived block'),a->>'rowIdentity',(a->>'rowNumber')::double precision,nullif(a->>'tankSessionId',''),(a->>'tankNumber')::integer,coalesce(nullif(a->>'status',''),'Not recorded'),source,confidence,a->'originalEvidence',auth.uid())
    on conflict(trip_id,block_id,row_identity,tank_session_id) do nothing;
  end loop;
  return coalesce((select jsonb_agg(to_jsonb(e) order by e.block_name_snapshot,e.row_number,e.row_identity) from public.spray_row_assignment_evidence e where e.trip_id=t.id),'[]'::jsonb);
end $fn$;

-- Add canonical report facts without modifying the applied SQL 227 body.
alter function public.get_spray_report_v1(uuid) rename to get_spray_report_v1_pre_canonical_facts_v1;
create or replace function public.get_spray_report_v1(p_trip_id uuid) returns jsonb language plpgsql security definer set search_path=public as $fn$
declare payload jsonb; t public.trips; r public.spray_records; c public.spray_trip_corrections; j public.spray_jobs;
  machine_id uuid; tractor_id uuid; unit_id uuid; operator_id uuid; machine_name text; unit_name text; operator_name text;
  fuel_rate double precision; fuel_source text; active_seconds bigint; engine_used double precision; fuel_hours double precision; fuel_litres double precision; fuel_price double precision;
  planned_totals jsonb; actual_totals jsonb; sessions jsonb; recovered_rows jsonb; metadata_history jsonb; can_cost boolean;
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
  select total_cost/nullif(volume_litres,0) into fuel_price from public.fuel_purchases where vineyard_id=t.vineyard_id and deleted_at is null and volume_litres>0 order by date desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('identityKey',identity_key,'name',name,'dimension',dimension,'displayUnit',display_unit,'actualAmountBase',total) order by lower(name),dimension),'[]') into planned_totals from (
    select coalesce(x->>'savedChemicalId',x->>'saved_chemical_id',lower(btrim(x->>'name'))||'|'||case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end) identity_key,
      min(coalesce(x->>'name','Unnamed chemical')) name,case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end dimension,
      case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'Litres' else 'Kg' end display_unit,
      sum(coalesce((x->>'volumePerTank')::numeric,(x->>'volume_per_tank')::numeric,0)) total
    from jsonb_array_elements(coalesce(r.tanks,'[]')) tank cross join lateral jsonb_array_elements(coalesce(tank->'chemicals','[]')) x
    group by coalesce(x->>'savedChemicalId',x->>'saved_chemical_id',lower(btrim(x->>'name'))||'|'||case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end),case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end
  ) q;
  select coalesce(jsonb_agg(jsonb_build_object('identityKey',identity_key,'name',name,'unit',display_unit,'actualAmountBase',total) order by lower(name),dimension),'[]') into actual_totals from (
    select coalesce(x->>'savedChemicalId',lower(btrim(x->>'name'))||'|'||case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end) identity_key,
      min(coalesce(x->>'name','Unnamed chemical')) name,case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end dimension,
      case when x->>'unit' in ('Litres','mL') then 'Litres' else 'Kg' end display_unit,sum((x->>'actualAmountBase')::numeric) total
    from jsonb_array_elements(payload->'tanks') tank cross join lateral jsonb_array_elements(tank->'chemicals') x
    where x->'actualAmountBase' <> 'null'::jsonb
    group by coalesce(x->>'savedChemicalId',lower(btrim(x->>'name'))||'|'||case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end),case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end
  ) q;
  select coalesce(jsonb_agg(jsonb_build_object('tankSessionId',coalesce(s->>'id',s->>'tank_session_id'),'tankNumber',coalesce((s->>'tankNumber')::int,(s->>'tank_number')::int),'startedAt',coalesce(s->>'startTime',s->>'start_time'),'endedAt',coalesce(s->>'endTime',s->>'end_time'),'startRow',coalesce((s->>'startRow')::double precision,(s->>'start_row')::double precision),'endRow',coalesce((s->>'endRow')::double precision,(s->>'end_row')::double precision),'pathsCovered',coalesce(s->'pathsCovered',s->'paths_covered','[]'),'status',case when coalesce(s->>'endTime',s->>'end_time') is not null then 'Complete' when t.end_time is not null then 'End not recorded' else 'In progress' end,'assignmentSource',case when jsonb_array_length(coalesce(s->'pathsCovered',s->'paths_covered','[]'))>0 then 'recorded_path_identity' when coalesce(s->>'startRow',s->>'start_row') is not null and coalesce(s->>'endRow',s->>'end_row') is not null then 'session_boundary_order' else 'not_recorded' end) order by ord),'[]') into sessions from jsonb_array_elements(coalesce(t.tank_sessions,'[]')) with ordinality z(s,ord);
  select jsonb_agg(jsonb_build_object('rowIdentity',e.row_identity,'rowNumber',e.row_number,'blockId',e.block_id,'blockName',e.block_name_snapshot,'status',e.status,'source',e.assignment_source,'confidence',e.confidence,'isDerived',e.assignment_source<>'recorded_path_identity','tank',e.tank_number,'tankSessionId',e.tank_session_id,'originalEvidence',e.original_evidence) order by e.block_name_snapshot,e.row_number,e.row_identity) into recovered_rows from public.spray_row_assignment_evidence e where e.trip_id=t.id;
  select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'operationId',a.operation_id,'revision',a.revision,'previousValue',a.previous_value,'newValue',a.new_value,'editedBy',a.edited_by,'editorName',a.editor_name,'editedAt',a.edited_at) order by a.revision),'[]') into metadata_history from public.spray_trip_correction_amendments a where a.trip_id=t.id;
  can_cost:=public.has_vineyard_role(t.vineyard_id,array['owner','manager']);
  payload:=jsonb_set(payload,'{schemaVersion}',to_jsonb('1.1'::text));
  payload:=jsonb_set(payload,'{trip}',(payload->'trip')||jsonb_build_object('operatorId',operator_id,'operatorName',operator_name,'operatorSource',case when c.operator_user_id is not null then 'explicit_correction' when t.operator_user_id is not null then 'recorded_identity' when nullif(t.person_name,'') is not null then 'recorded_snapshot' else 'not_recorded' end,'elapsedDurationSeconds',case when t.start_time is null then null else greatest(0,extract(epoch from (coalesce(t.end_time,now())-t.start_time))::bigint) end,'pausedDurationSeconds',case when active_seconds is null or t.start_time is null then null else greatest(0,extract(epoch from (coalesce(t.end_time,now())-t.start_time))::bigint-active_seconds) end));
  payload:=jsonb_set(payload,'{equipment}',jsonb_build_object('machineId',machine_id,'tractorId',tractor_id,'tractorName',nullif(machine_name,''),'sprayEquipmentId',unit_id,'sprayUnitName',nullif(unit_name,''),'equipmentSource',case when c.trip_id is not null then 'explicit_correction' when t.machine_id is not null or t.tractor_id is not null then 'trip_recorded_identity' else 'spray_record_snapshot' end,'startEngineHours',case when c.trip_id is not null then c.start_engine_hours else t.start_engine_hours end,'endEngineHours',case when c.trip_id is not null then c.end_engine_hours else t.end_engine_hours end,'engineHoursUsed',engine_used,'tractorGear',nullif(r.tractor_gear,''),'numberOfFansJets',nullif(r.number_of_fans_jets,''),'averageSpeedKmh',r.average_speed,'fuelConsumptionLPerHour',fuel_rate,'fuelConsumptionSource',fuel_source,'fuelHours',fuel_hours,'fuelHoursSource',case when engine_used is not null then 'engine_hours' else 'pause_adjusted_duration' end));
  payload:=jsonb_set(payload,'{application}',jsonb_build_object('operationType',r.operation_type,'applicationMode',r.application_mode,'grossAreaHa',r.gross_area_ha,'treatedAreaHa',r.treated_area_ha,'treatedAreaMethod',r.treated_area_method,'geometrySource',r.geometry_source,'geometryQuality',r.geometry_quality,'carrierVolumeBasis',r.carrier_volume_basis,'totalCarrierLitres',r.total_carrier_litres,'carrierLitresPerHectare',r.carrier_litres_per_hectare,'diluteLitresPer100m',r.dilute_litres_per_100m,'appliedLitresPer100m',r.applied_litres_per_100m,'concentrationFactor',r.concentration_factor,'notes',nullif(r.notes,'')));
  payload:=jsonb_set(payload,'{programStep}',jsonb_build_object('linkState',case when r.spray_job_id is null then 'not_recorded' when j.id is null then 'linked_step_unavailable' else 'program_linked' end,'sprayJobId',r.spray_job_id,'name',j.name,'status',j.status,'plannedDate',j.planned_date,'operationType',j.operation_type,'target',j.target,'notes',j.notes));
  payload:=jsonb_set(payload,'{tankSessions}',sessions); payload:=jsonb_set(payload,'{plannedChemicalTotals}',planned_totals); payload:=jsonb_set(payload,'{actualChemicalTotals}',actual_totals);
  if recovered_rows is not null then
    payload:=jsonb_set(payload,'{rows}',recovered_rows);
  else
    payload:=jsonb_set(payload,'{rows}',coalesce((select jsonb_agg(case when x->>'source'='incompletePlannedPath' then x||jsonb_build_object('status','Not recorded','source','noProgressEvidence') else x end) from jsonb_array_elements(payload->'rows') x),'[]'::jsonb));
  end if;
  payload:=jsonb_set(payload,'{metadataCorrectionVersion}',to_jsonb(coalesce(c.version,0))); payload:=jsonb_set(payload,'{metadataAmendments}',metadata_history);
  payload:=jsonb_set(payload,'{cost}',case when not can_cost then 'null'::jsonb else jsonb_build_object('visibility','owner_manager','currencyCode',coalesce((select currency_code from public.vineyards where id=t.vineyard_id),'AUD'),'fuelLitres',fuel_litres,'fuelRateLPerHour',fuel_rate,'fuelHours',fuel_hours,'fuelPricePerLitre',fuel_price,'fuelCost',case when fuel_litres is not null and fuel_price is not null then fuel_litres*fuel_price end,'chemicalCost',null,'labourCost',null,'totalCost',case when fuel_litres is not null and fuel_price is not null then fuel_litres*fuel_price end,'treatedAreaHa',r.treated_area_ha,'costPerTreatedHa',case when r.treated_area_ha>0 and fuel_litres is not null and fuel_price is not null then fuel_litres*fuel_price/r.treated_area_ha end,'isComplete',false,'basis','Recorded correction/equipment rate; engine delta when valid, otherwise pause-adjusted duration. Missing components remain null.') end);
  return payload;
end $fn$;

revoke all on function public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision) from public,anon,service_role;
grant execute on function public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision) to authenticated;
revoke all on function public.recover_spray_row_assignments_v1(uuid,uuid,jsonb) from public,anon,service_role;
grant execute on function public.recover_spray_row_assignments_v1(uuid,uuid,jsonb) to authenticated;
revoke all on function public.get_spray_report_v1_pre_canonical_facts_v1(uuid) from public,anon,authenticated;
revoke all on function public.get_spray_report_v1(uuid) from public,anon;
grant execute on function public.get_spray_report_v1(uuid) to authenticated;

commit;

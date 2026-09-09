-- 232: completed manual spray applications, atomic/idempotent save/delete, and report provenance.
-- Prerequisites: SQL 223, 228, and 229. Run manually; do not rerun earlier spray-report migrations.
begin;
select pg_advisory_xact_lock(hashtext('vinetrack:manual-spray-entry-v1'));

alter table public.spray_records
  add column if not exists entry_source text null,
  add column if not exists manual_entry_id uuid null;
alter table public.spray_records drop constraint if exists spray_records_carrier_volume_basis_check;
alter table public.spray_records add constraint spray_records_carrier_volume_basis_check
  check (carrier_volume_basis is null or carrier_volume_basis in ('l_per_ha','l_per_100m','manual_actual_total'));
alter table public.trips
  add column if not exists entry_source text null,
  add column if not exists manual_entry_id uuid null;

alter table public.spray_records drop constraint if exists spray_records_entry_source_check;
alter table public.spray_records add constraint spray_records_entry_source_check
  check (entry_source is null or entry_source in ('tracked','manual'));
alter table public.trips drop constraint if exists trips_entry_source_check;
alter table public.trips add constraint trips_entry_source_check
  check (entry_source is null or entry_source in ('tracked','manual'));
alter table public.spray_records drop constraint if exists spray_records_manual_identity_check;
alter table public.spray_records add constraint spray_records_manual_identity_check
  check ((entry_source = 'manual' and manual_entry_id is not null)
      or (entry_source is distinct from 'manual' and manual_entry_id is null));
alter table public.trips drop constraint if exists trips_manual_identity_check;
alter table public.trips add constraint trips_manual_identity_check
  check ((entry_source = 'manual' and manual_entry_id is not null)
      or (entry_source is distinct from 'manual' and manual_entry_id is null));

create unique index if not exists spray_records_manual_entry_id_unique
  on public.spray_records(manual_entry_id) where manual_entry_id is not null;
create unique index if not exists trips_manual_entry_id_unique
  on public.trips(manual_entry_id) where manual_entry_id is not null;
create index if not exists spray_records_entry_source_active_idx
  on public.spray_records(vineyard_id,entry_source) where deleted_at is null;

comment on column public.spray_records.entry_source is
  'Explicit application provenance: manual, tracked, or NULL when historical origin is unknown. Never infer this value.';
comment on column public.spray_records.manual_entry_id is
  'Stable identity for one completed manual application. Shared with its exclusively owned backing trip.';

create table if not exists public.manual_spray_operations (
  operation_id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  manual_entry_id uuid not null,
  operation_kind text not null check (operation_kind in ('save','delete')),
  request_fingerprint text not null,
  result jsonb not null,
  actor_user_id uuid not null references auth.users(id),
  completed_at timestamptz not null default now()
);
create index if not exists manual_spray_operations_entry_idx
  on public.manual_spray_operations(vineyard_id,manual_entry_id,completed_at);

create table if not exists public.manual_spray_tombstones (
  manual_entry_id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  spray_record_id uuid not null,
  trip_id uuid not null,
  deleted_by uuid not null references auth.users(id),
  deleted_at timestamptz not null default now()
);

alter table public.manual_spray_operations enable row level security;
alter table public.manual_spray_tombstones enable row level security;
drop policy if exists manual_spray_operations_member_read on public.manual_spray_operations;
create policy manual_spray_operations_member_read on public.manual_spray_operations for select to authenticated
  using (public.is_vineyard_member(vineyard_id));
drop policy if exists manual_spray_tombstones_member_read on public.manual_spray_tombstones;
create policy manual_spray_tombstones_member_read on public.manual_spray_tombstones for select to authenticated
  using (public.is_vineyard_member(vineyard_id));
revoke all on public.manual_spray_operations,public.manual_spray_tombstones from public,anon,authenticated;
grant select on public.manual_spray_operations,public.manual_spray_tombstones to authenticated,service_role;

create or replace function public.manual_spray_guard_v1()
returns trigger language plpgsql security definer set search_path=public as $fn$
declare source_before text; manual_id_before uuid;
begin
  source_before:=case when tg_op='UPDATE' then old.entry_source else null end;
  manual_id_before:=case when tg_op='UPDATE' then old.manual_entry_id else null end;
  if tg_op='UPDATE' and source_before='manual' then
    if coalesce(current_setting('vinetrack.manual_spray_rpc',true),'')<>'on' then
      raise exception 'Manual sprays must use the coordinated manual RPC' using errcode='42501';
    end if;
    -- Older PATCH clients normally omit these columns. If one sends null or a different
    -- value, retain the immutable provenance rather than converting the application.
    new.entry_source:='manual';
    new.manual_entry_id:=manual_id_before;
    if not public.has_vineyard_role(old.vineyard_id,array['owner','manager','supervisor']) then
      raise exception 'Manual spray access required' using errcode='42501';
    end if;
    if old.deleted_at is not null and new.deleted_at is null then
      raise exception 'Deleted manual sprays cannot be revived' using errcode='55000';
    end if;
  elsif new.entry_source='manual' then
    if coalesce(current_setting('vinetrack.manual_spray_rpc',true),'')<>'on' then raise exception 'Manual sprays must use the coordinated manual RPC' using errcode='42501'; end if;
    if not public.has_vineyard_role(new.vineyard_id,array['owner','manager','supervisor']) then
      raise exception 'Manual spray access required' using errcode='42501';
    end if;
  end if;
  return new;
end $fn$;

drop trigger if exists trg_spray_records_manual_guard_v1 on public.spray_records;
create trigger trg_spray_records_manual_guard_v1 before insert or update on public.spray_records
  for each row execute function public.manual_spray_guard_v1();
drop trigger if exists trg_trips_manual_guard_v1 on public.trips;
create trigger trg_trips_manual_guard_v1 before insert or update on public.trips
  for each row execute function public.manual_spray_guard_v1();

-- Manual actuals have stable tank identities but no invented live tank timing/session telemetry.
-- The tank identity must instead occur in the manual spray's frozen tank list.
create or replace function public.spray_tank_actuals_before_write()
returns trigger language plpgsql security definer set search_path=public as $fn$
declare v_trip public.trips; v_record public.spray_records;
begin
  select * into v_trip from public.trips where id=new.trip_id and deleted_at is null;
  select * into v_record from public.spray_records where id=new.spray_record_id and deleted_at is null and is_template=false;
  if v_trip.id is null then raise exception 'Trip not found'; end if;
  if v_record.id is null then raise exception 'Spray record not found'; end if;
  if new.vineyard_id<>v_trip.vineyard_id or new.vineyard_id<>v_record.vineyard_id or v_record.trip_id is distinct from new.trip_id then
    raise exception 'Vineyard, trip and spray record do not match';
  end if;
  if v_record.entry_source='manual' then
    if v_trip.entry_source<>'manual' or v_trip.manual_entry_id is distinct from v_record.manual_entry_id then
      raise exception 'Manual application provenance does not match' using errcode='23514';
    end if;
    if coalesce(current_setting('vinetrack.manual_spray_rpc',true),'')<>'on' or not public.has_vineyard_role(new.vineyard_id,array['owner','manager','supervisor']) then
      raise exception 'Manual spray coordinated access required' using errcode='42501';
    end if;
    if not exists (
      select 1 from jsonb_array_elements(coalesce(v_record.tanks,'[]'::jsonb)) tank
      where coalesce(tank->>'id',tank->>'tankSessionId')=new.tank_session_id
        and coalesce((tank->>'tankNumber')::integer,(tank->>'tank_number')::integer)=new.tank_number
    ) then raise exception 'Manual tank identity does not belong to spray'; end if;
  elsif not exists (
    select 1 from jsonb_array_elements(coalesce(v_trip.tank_sessions,'[]'::jsonb)) session
    where coalesce(session->>'id',session->>'tank_session_id')=new.tank_session_id
      and coalesce((session->>'tank_number')::integer,(session->>'tankNumber')::integer)=new.tank_number
  ) then raise exception 'Tank session does not belong to trip'; end if;
  new.updated_by:=auth.uid();
  if tg_op='INSERT' then
    new.created_by:=coalesce(new.created_by,auth.uid()); new.confirmed_by:=auth.uid();
  else
    new.id:=old.id; new.created_at:=old.created_at; new.created_by:=old.created_by;
    new.confirmed_by:=old.confirmed_by; new.sync_version:=old.sync_version+1;
  end if;
  return new;
end $fn$;

create or replace function public.manual_spray_number_v1(p_value jsonb,p_field text,p_required boolean default true)
returns double precision language plpgsql immutable set search_path=public as $fn$
declare result double precision;
begin
  if p_value is null or p_value='null'::jsonb then
    if p_required then raise exception '% is required',p_field using errcode='22023'; end if;
    return null;
  end if;
  if jsonb_typeof(p_value)<>'number' then raise exception '% must be numeric',p_field using errcode='22023'; end if;
  result:=(p_value#>>'{}')::double precision;
  if result<>result or result in ('Infinity'::double precision,'-Infinity'::double precision) then
    raise exception '% must be finite',p_field using errcode='22023';
  end if;
  return result;
end $fn$;

create or replace function public.save_manual_spray_v1(
  p_operation_id uuid,p_payload jsonb,p_expected_version integer default null
) returns jsonb language plpgsql security definer set search_path=public as $fn$
declare
  v_vineyard_id uuid; v_manual_id uuid; v_spray_id uuid; v_trip_id uuid; v_tractor_id uuid; v_unit_id uuid; v_operator_id uuid;
  v_started_at timestamptz; v_ended_at timestamptz; v_client_at timestamptz; v_reference text; v_notes text; v_operation_type text;
  v_start_hours double precision; v_end_hours double precision; v_fingerprint text; v_prior public.manual_spray_operations;
  v_existing public.spray_records; v_tractor_name text; v_unit_name text; v_operator_name text; v_tanks jsonb; v_blocks jsonb;
  v_tank jsonb; v_chemical jsonb; v_tank_ids text[]:='{}'; v_tank_numbers integer[]:='{}'; v_tank_no integer; v_tank_id text; v_actual_id uuid; v_water_l double precision;
  v_actual_chemicals jsonb; v_normal_tanks jsonb:='[]'::jsonb; v_normal_actual_tanks jsonb:='[]'::jsonb; v_normal_chemicals jsonb; v_saved public.saved_chemicals;
  v_result jsonb; v_weather jsonb; v_weather_at timestamptz;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_operation_id is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Invalid manual spray request' using errcode='22023'; end if;
  begin
    v_vineyard_id:=(p_payload->>'vineyardId')::uuid; v_manual_id:=(p_payload->>'manualEntryId')::uuid;
    v_spray_id:=(p_payload->>'sprayRecordId')::uuid; v_trip_id:=(p_payload->>'tripId')::uuid;
    v_tractor_id:=(p_payload->>'tractorId')::uuid; v_unit_id:=(p_payload->>'sprayEquipmentId')::uuid;
    v_operator_id:=(p_payload->>'operatorUserId')::uuid; v_started_at:=(p_payload->>'startUtc')::timestamptz;
    v_ended_at:=(p_payload->>'endUtc')::timestamptz; v_client_at:=coalesce((p_payload->>'clientUpdatedAt')::timestamptz,now());
    v_start_hours:=public.manual_spray_number_v1(p_payload->'startEngineHours','startEngineHours',false);
    v_end_hours:=public.manual_spray_number_v1(p_payload->'endEngineHours','endEngineHours',false);
  exception when others then raise exception 'Manual spray identities, dates, or engine readings are invalid' using errcode='22023'; end;
  v_reference:=btrim(coalesce(p_payload->>'reference','')); v_notes:=nullif(btrim(p_payload->>'notes'),'');
  v_operation_type:=nullif(btrim(p_payload->>'operationType'),''); v_tanks:=p_payload->'tanks'; v_blocks:=p_payload->'blocks'; v_weather:=p_payload->'manualWeather';
  if not public.has_vineyard_role(v_vineyard_id,array['owner','manager','supervisor']) then raise exception 'Manual spray access required' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_operation_id::text,0));
  perform pg_advisory_xact_lock(hashtextextended(v_manual_id::text,0));
  perform set_config('vinetrack.manual_spray_rpc','on',true);
  v_fingerprint:=md5(jsonb_build_object('payload',p_payload,'expectedVersion',p_expected_version)::text);
  select o.* into v_prior from public.manual_spray_operations o where o.operation_id=p_operation_id;
  if v_prior.operation_id is not null then
    if v_prior.vineyard_id is distinct from v_vineyard_id or v_prior.manual_entry_id is distinct from v_manual_id or v_prior.operation_kind<>'save' or v_prior.request_fingerprint<>v_fingerprint then raise exception 'Operation id was reused for a different request' using errcode='22023'; end if;
    return v_prior.result;
  end if;
  if v_reference='' or v_started_at is null or v_ended_at is null or v_ended_at<=v_started_at then raise exception 'Name and a valid completed interval are required' using errcode='22023'; end if;
  if (v_start_hours is not null and v_start_hours<0) or (v_end_hours is not null and v_end_hours<0) or (v_start_hours is not null and v_end_hours is not null and v_end_hours<v_start_hours) then raise exception 'Invalid engine-hour readings' using errcode='22023'; end if;
  if jsonb_typeof(v_blocks)<>'array' or jsonb_array_length(v_blocks)<1 or jsonb_typeof(v_tanks)<>'array' or jsonb_array_length(v_tanks)<1 then raise exception 'At least one block and one tank are required' using errcode='22023'; end if;
  select t.name into v_tractor_name from public.tractors t where t.id=v_tractor_id and t.vineyard_id=v_vineyard_id and t.deleted_at is null;
  select e.name into v_unit_name from public.spray_equipment e where e.id=v_unit_id and e.vineyard_id=v_vineyard_id and e.deleted_at is null;
  if v_tractor_name is null or v_unit_name is null then raise exception 'Selected tractor or spray unit is not available in this vineyard' using errcode='22023'; end if;
  if not exists(select 1 from public.vineyard_members m where m.vineyard_id=v_vineyard_id and m.user_id=v_operator_id) then raise exception 'Selected operator is not a vineyard member' using errcode='22023'; end if;
  select coalesce(nullif(btrim(p.full_name),''),nullif(btrim(p.email),''),'VineTrack user') into v_operator_name from public.profiles p where p.id=v_operator_id;
  if exists(select 1 from jsonb_array_elements(v_blocks) b left join public.paddocks p on p.id=(b->>'blockId')::uuid where p.id is null or p.vineyard_id<>v_vineyard_id or p.deleted_at is not null) then raise exception 'Every selected block must be active in this vineyard' using errcode='22023'; end if;
  if exists(select 1 from public.manual_spray_tombstones d where d.manual_entry_id=v_manual_id) then raise exception 'Manual spray was deleted and cannot be replayed' using errcode='55000'; end if;
  select r.* into v_existing from public.spray_records r where r.id=v_spray_id for update;
  if v_existing.id is not null then
    if v_existing.entry_source is distinct from 'manual' or v_existing.manual_entry_id is distinct from v_manual_id or v_existing.trip_id is distinct from v_trip_id or v_existing.vineyard_id is distinct from v_vineyard_id then raise exception 'Manual spray identity conflict' using errcode='40001'; end if;
    if v_existing.deleted_at is not null then raise exception 'Deleted manual sprays cannot be revived' using errcode='55000'; end if;
    if p_expected_version is null or p_expected_version<>v_existing.sync_version then raise exception 'Manual spray version conflict' using errcode='40001'; end if;
  elsif p_expected_version is not null and p_expected_version<>0 then raise exception 'Manual spray version conflict' using errcode='40001'; end if;

  for v_tank in select value from jsonb_array_elements(v_tanks) loop
    begin v_tank_id:=(v_tank->>'id')::uuid::text; v_actual_id:=(v_tank->>'actualId')::uuid; v_tank_no:=(v_tank->>'tankNumber')::integer; exception when others then raise exception 'Every tank requires stable UUID identities and a number' using errcode='22023'; end;
    v_water_l:=public.manual_spray_number_v1(v_tank->'waterVolumeLitres','waterVolumeLitres');
    if v_tank_id is null or v_actual_id is null or v_tank_no is null or v_water_l is null or v_tank_no<1 or v_water_l<0 or v_tank_id=any(v_tank_ids) or v_tank_no=any(v_tank_numbers) then raise exception 'Tank identities, numbers, and water must be valid and unique' using errcode='22023'; end if;
    v_tank_ids:=array_append(v_tank_ids,v_tank_id); v_tank_numbers:=array_append(v_tank_numbers,v_tank_no); v_actual_chemicals:='[]'::jsonb; v_normal_chemicals:='[]'::jsonb;
    if jsonb_typeof(v_tank->'chemicals')<>'array' or jsonb_array_length(v_tank->'chemicals')<1 then raise exception 'Every tank requires at least one chemical' using errcode='22023'; end if;
    for v_chemical in select value from jsonb_array_elements(v_tank->'chemicals') loop
      begin select s.* into v_saved from public.saved_chemicals s where s.id=(v_chemical->>'savedChemicalId')::uuid and s.vineyard_id=v_vineyard_id and s.deleted_at is null; exception when others then v_saved.id:=null; end;
      if v_saved.id is null then raise exception 'Every chemical must reference this vineyard Chemical Store' using errcode='22023'; end if;
      if nullif(btrim(v_chemical->>'name'),'') is null or v_chemical->>'unit' not in ('Litres','mL','Kg','g') or v_chemical->>'physicalForm' not in ('liquid','solid') or nullif(btrim(v_chemical->>'productCategory'),'') is null or nullif(v_chemical->>'snapshotAt','') is null then raise exception 'Chemical snapshot is incomplete' using errcode='22023'; end if;
      if (v_chemical->>'physicalForm'='liquid')<>(v_chemical->>'unit' in ('Litres','mL')) then raise exception 'Chemical unit and physical form do not agree' using errcode='22023'; end if;
      if public.manual_spray_number_v1(v_chemical->'actualAmountBase','actualAmountBase')<0 then raise exception 'Chemical amount must be nonnegative' using errcode='22023'; end if;
      v_actual_chemicals:=v_actual_chemicals||jsonb_build_array(jsonb_build_object('id',v_chemical->>'id','plannedChemicalId',null,'savedChemicalId',v_saved.id,'name',btrim(v_chemical->>'name'),'actualAmountBase',public.manual_spray_number_v1(v_chemical->'actualAmountBase','actualAmountBase'),'unit',v_chemical->>'unit','productCategory',v_chemical->>'productCategory','physicalForm',v_chemical->>'physicalForm','snapshotAt',v_chemical->>'snapshotAt'));
      v_normal_chemicals:=v_normal_chemicals||jsonb_build_array(jsonb_build_object('id',v_chemical->>'id','savedChemicalId',v_saved.id,'name',btrim(v_chemical->>'name'),'unit',v_chemical->>'unit','productCategory',v_chemical->>'productCategory','physicalForm',v_chemical->>'physicalForm','snapshotAt',v_chemical->>'snapshotAt'));
    end loop;
    v_normal_tanks:=v_normal_tanks||jsonb_build_array(jsonb_build_object('id',v_tank_id,'tankNumber',v_tank_no,'chemicals',v_normal_chemicals));
    v_normal_actual_tanks:=v_normal_actual_tanks||jsonb_build_array(jsonb_build_object('id',v_tank_id,'actualId',v_actual_id,'tankNumber',v_tank_no,'waterVolumeLitres',v_water_l,'chemicals',v_actual_chemicals));
  end loop;

  if v_existing.id is null then
    insert into public.trips(id,vineyard_id,paddock_ids,paddock_name,start_time,end_time,is_active,is_paused,path_points,completed_paths,skipped_paths,row_sequence,tank_sessions,total_tanks,person_name,trip_function,tractor_id,operator_user_id,start_engine_hours,end_engine_hours,completion_notes,entry_source,manual_entry_id,created_by,updated_by,client_updated_at)
    values(v_trip_id,v_vineyard_id,(select jsonb_agg(b->>'blockId') from jsonb_array_elements(v_blocks)b),(select string_agg(b->>'blockName',', ') from jsonb_array_elements(v_blocks)b),v_started_at,v_ended_at,false,false,'[]','[]','[]','[]','[]',jsonb_array_length(v_tanks),v_operator_name,'spraying',v_tractor_id,v_operator_id,v_start_hours,v_end_hours,v_notes,'manual',v_manual_id,auth.uid(),auth.uid(),v_client_at);
    insert into public.spray_records(id,vineyard_id,trip_id,date,start_time,end_time,spray_reference,notes,equipment_type,tractor,tractor_id,spray_equipment_id,is_template,operation_type,tanks,application_blocks,total_carrier_litres,carrier_volume_basis,entry_source,manual_entry_id,created_by,updated_by,client_updated_at)
    values(v_spray_id,v_vineyard_id,v_trip_id,v_started_at,v_started_at,v_ended_at,v_reference,v_notes,v_unit_name,v_tractor_name,v_tractor_id,v_unit_id,false,v_operation_type,v_normal_tanks,v_blocks,(select sum(public.manual_spray_number_v1(x->'waterVolumeLitres','waterVolumeLitres')) from jsonb_array_elements(v_tanks)x),'manual_actual_total','manual',v_manual_id,auth.uid(),auth.uid(),v_client_at);
  else
    update public.trips t set start_time=v_started_at,end_time=v_ended_at,is_active=false,is_paused=false,paddock_ids=(select jsonb_agg(b->>'blockId') from jsonb_array_elements(v_blocks)b),paddock_name=(select string_agg(b->>'blockName',', ') from jsonb_array_elements(v_blocks)b),person_name=v_operator_name,tractor_id=v_tractor_id,operator_user_id=v_operator_id,total_tanks=jsonb_array_length(v_tanks),start_engine_hours=v_start_hours,end_engine_hours=v_end_hours,completion_notes=v_notes,updated_by=auth.uid(),client_updated_at=v_client_at,sync_version=t.sync_version+1 where t.id=v_trip_id and t.entry_source='manual' and t.manual_entry_id=v_manual_id and t.deleted_at is null;
    update public.spray_records r set date=v_started_at,start_time=v_started_at,end_time=v_ended_at,spray_reference=v_reference,notes=v_notes,equipment_type=v_unit_name,tractor=v_tractor_name,tractor_id=v_tractor_id,spray_equipment_id=v_unit_id,operation_type=v_operation_type,tanks=v_normal_tanks,application_blocks=v_blocks,total_carrier_litres=(select sum(public.manual_spray_number_v1(x->'waterVolumeLitres','waterVolumeLitres')) from jsonb_array_elements(v_tanks)x),carrier_volume_basis='manual_actual_total',updated_by=auth.uid(),client_updated_at=v_client_at,sync_version=r.sync_version+1 where r.id=v_spray_id;
  end if;

  update public.spray_tank_actuals a set deleted_at=now(),updated_by=auth.uid(),client_updated_at=v_client_at
    where a.spray_record_id=v_spray_id and a.deleted_at is null and not (a.tank_session_id=any(v_tank_ids));
  for v_tank in select value from jsonb_array_elements(v_normal_actual_tanks) loop
    v_tank_id:=v_tank->>'id'; v_actual_id:=(v_tank->>'actualId')::uuid; v_tank_no:=(v_tank->>'tankNumber')::integer;
    v_water_l:=(v_tank->>'waterVolumeLitres')::double precision; v_actual_chemicals:=v_tank->'chemicals';
    insert into public.spray_tank_actuals(id,vineyard_id,spray_record_id,trip_id,tank_session_id,tank_number,water_volume_l,chemicals,confirmed_at,confirmed_by,created_by,updated_by,client_updated_at)
    values(v_actual_id,v_vineyard_id,v_spray_id,v_trip_id,v_tank_id,v_tank_no,v_water_l,v_actual_chemicals,v_ended_at,auth.uid(),auth.uid(),auth.uid(),v_client_at)
    on conflict(trip_id,tank_session_id) do update set water_volume_l=excluded.water_volume_l,chemicals=excluded.chemicals,confirmed_at=excluded.confirmed_at,updated_by=auth.uid(),client_updated_at=excluded.client_updated_at,deleted_at=null;
  end loop;

  delete from public.trip_weather_observations w where w.trip_id=v_trip_id and w.source_kind='manual' and w.provider='manual_entry';
  if v_weather is not null and v_weather<>'null'::jsonb then
    v_weather_at:=coalesce((v_weather->>'observedAt')::timestamptz,v_started_at);
    perform public.record_trip_weather_observation_v2(v_trip_id,v_started_at,v_weather_at,coalesce(nullif(btrim(v_weather->>'source'),''),'Manual entry'),'manual',null,public.manual_spray_number_v1(v_weather->'temperatureC','temperatureC',false),public.manual_spray_number_v1(v_weather->'humidityPct','humidityPct',false),public.manual_spray_number_v1(v_weather->'windSpeedKmh','windSpeedKmh',false),public.manual_spray_number_v1(v_weather->'windGustKmh','windGustKmh',false),public.manual_spray_number_v1(v_weather->'windDirectionDeg','windDirectionDeg',false),public.manual_spray_number_v1(v_weather->'rainMm','rainMm',false),false,'legacy_snapshot',null,'manual_entry',null);
  end if;
  select jsonb_build_object('operationId',p_operation_id,'manualEntryId',v_manual_id,'sprayRecordId',v_spray_id,'tripId',v_trip_id,'source','manual','status','completed','syncVersion',r.sync_version,'serverConfirmed',true) into v_result from public.spray_records r where r.id=v_spray_id;
  insert into public.manual_spray_operations(operation_id,vineyard_id,manual_entry_id,operation_kind,request_fingerprint,result,actor_user_id) values(p_operation_id,v_vineyard_id,v_manual_id,'save',v_fingerprint,v_result,auth.uid());
  return v_result;
end $fn$;

create or replace function public.delete_manual_spray_v1(
  p_operation_id uuid,p_vineyard_id uuid,p_manual_entry_id uuid,p_spray_record_id uuid,p_trip_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $fn$
declare fingerprint text; prior public.manual_spray_operations; result jsonb; existing public.spray_records;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if not public.has_vineyard_role(p_vineyard_id,array['owner','manager','supervisor']) then raise exception 'Manual spray access required' using errcode='42501'; end if;
  if p_operation_id is null or p_manual_entry_id is null or p_spray_record_id is null or p_trip_id is null then raise exception 'Manual spray delete identities are required' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_operation_id::text,0));
  perform pg_advisory_xact_lock(hashtextextended(p_manual_entry_id::text,0));
  perform set_config('vinetrack.manual_spray_rpc','on',true);
  fingerprint:=md5(jsonb_build_object('vineyardId',p_vineyard_id,'manualEntryId',p_manual_entry_id,'sprayRecordId',p_spray_record_id,'tripId',p_trip_id)::text);
  select * into prior from public.manual_spray_operations where operation_id=p_operation_id;
  if prior.operation_id is not null then
    if prior.vineyard_id<>p_vineyard_id or prior.manual_entry_id<>p_manual_entry_id or prior.operation_kind<>'delete' or prior.request_fingerprint<>fingerprint then raise exception 'Operation id was reused for a different request' using errcode='22023'; end if;
    return prior.result;
  end if;
  select * into existing from public.spray_records where id=p_spray_record_id for update;
  if existing.id is not null and (existing.vineyard_id is distinct from p_vineyard_id or existing.entry_source is distinct from 'manual' or existing.manual_entry_id is distinct from p_manual_entry_id or existing.trip_id is distinct from p_trip_id) then raise exception 'Manual spray identity conflict' using errcode='40001'; end if;
  insert into public.manual_spray_tombstones(manual_entry_id,vineyard_id,spray_record_id,trip_id,deleted_by)
    values(p_manual_entry_id,p_vineyard_id,p_spray_record_id,p_trip_id,auth.uid()) on conflict(manual_entry_id) do nothing;
  update public.spray_tank_actuals set deleted_at=now(),updated_by=auth.uid(),sync_version=sync_version+1 where spray_record_id=p_spray_record_id and vineyard_id=p_vineyard_id and deleted_at is null;
  update public.spray_records set deleted_at=now(),updated_by=auth.uid(),sync_version=sync_version+1 where id=p_spray_record_id and vineyard_id=p_vineyard_id and entry_source='manual' and manual_entry_id=p_manual_entry_id and deleted_at is null;
  update public.trips set deleted_at=now(),is_active=false,is_paused=false,updated_by=auth.uid(),sync_version=sync_version+1 where id=p_trip_id and vineyard_id=p_vineyard_id and entry_source='manual' and manual_entry_id=p_manual_entry_id and deleted_at is null;
  result:=jsonb_build_object('operationId',p_operation_id,'manualEntryId',p_manual_entry_id,'sprayRecordId',p_spray_record_id,'tripId',p_trip_id,'deleted',true,'serverConfirmed',true);
  insert into public.manual_spray_operations(operation_id,vineyard_id,manual_entry_id,operation_kind,request_fingerprint,result,actor_user_id) values(p_operation_id,p_vineyard_id,p_manual_entry_id,'delete',fingerprint,result,auth.uid());
  return result;
end $fn$;

-- Add explicit provenance and manual-specific absence semantics without changing tracked reports.
do $upgrade$
begin
  if to_regprocedure('public.get_spray_report_v1_pre_manual_entry_v1(uuid)') is null then
    alter function public.get_spray_report_v1(uuid) rename to get_spray_report_v1_pre_manual_entry_v1;
  elsif to_regprocedure('public.get_spray_report_v1(uuid)') is null then
    raise exception 'Manual Spray Report base exists but its public wrapper is missing';
  end if;
end $upgrade$;
create or replace function public.get_spray_report_v1(p_trip_id uuid) returns jsonb
language plpgsql security definer set search_path=public as $fn$
declare payload jsonb; record public.spray_records;
begin
  payload:=public.get_spray_report_v1_pre_manual_entry_v1(p_trip_id);
  select * into record from public.spray_records where id=(payload#>>'{identity,sprayRecordId}')::uuid and deleted_at is null;
  if record.id is null then raise exception 'Spray record not found' using errcode='P0002'; end if;
  payload:=jsonb_set(payload,'{schemaVersion}',to_jsonb('1.2'::text));
  payload:=payload||jsonb_build_object('provenance',jsonb_build_object('source',record.entry_source,'manualEntryId',record.manual_entry_id,'isManualEntry',coalesce(record.entry_source='manual',false),'label',case when record.entry_source='manual' then 'Manual entry' when record.entry_source='tracked' then 'Tracked application' else 'Origin not recorded' end),'recordingEvidence',jsonb_build_object('route',null,'rows',null));
  if record.entry_source='manual' then
    payload:=jsonb_set(payload,'{plannedChemicalTotals}','[]'::jsonb);
    payload:=jsonb_set(payload,'{rows}','[]'::jsonb);
    payload:=jsonb_set(payload,'{route}','null'::jsonb);
    payload:=payload||jsonb_build_object('recordingEvidence',jsonb_build_object('route','Not recorded — manual application','rows','Not recorded — manual application'));
    payload:=jsonb_set(payload,'{application}',(payload->'application')||jsonb_build_object('actualUseBasis','manually_recorded_actual_use'));
    payload:=jsonb_set(payload,'{tanks}',coalesce((select jsonb_agg(jsonb_build_object('tankNumber',a.tank_number,'actualId',a.id,'actualVersion',a.correction_version,'plannedWaterLitres',null,'actualWaterLitres',a.water_volume_l,'chemicals',(select coalesce(jsonb_agg(jsonb_build_object('actualChemicalId',c->>'id','plannedChemicalId',null,'savedChemicalId',c->>'savedChemicalId','replacesPlannedChemicalId',null,'usageKind','additional','name',c->>'name','unit',c->>'unit','plannedAmountBase',null,'actualAmountBase',(c->>'actualAmountBase')::double precision,'matchSource','actualOnly','productCategory',c->>'productCategory','physicalForm',c->>'physicalForm','snapshotAt',c->>'snapshotAt')),'[]'::jsonb) from jsonb_array_elements(a.chemicals)c)) order by a.tank_number) from public.spray_tank_actuals a where a.spray_record_id=record.id and a.deleted_at is null),'[]'::jsonb));
  end if;
  return payload;
end $fn$;

revoke all on function public.manual_spray_number_v1(jsonb,text,boolean) from public,anon,authenticated;
revoke all on function public.save_manual_spray_v1(uuid,jsonb,integer) from public,anon,service_role;
grant execute on function public.save_manual_spray_v1(uuid,jsonb,integer) to authenticated;
revoke all on function public.delete_manual_spray_v1(uuid,uuid,uuid,uuid,uuid) from public,anon,service_role;
grant execute on function public.delete_manual_spray_v1(uuid,uuid,uuid,uuid,uuid) to authenticated;
revoke all on function public.get_spray_report_v1_pre_manual_entry_v1(uuid) from public,anon,authenticated;
revoke all on function public.get_spray_report_v1(uuid) from public,anon;
grant execute on function public.get_spray_report_v1(uuid) to authenticated;
commit;

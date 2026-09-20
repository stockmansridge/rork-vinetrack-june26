-- Commit audited spray-trip metadata corrections independently of canonical
-- report reconstruction. The RPC signature and all authorization, validation,
-- versioning, idempotency, and amendment contracts remain unchanged.

create or replace function public.correct_spray_trip_metadata_v1(
  p_operation_id uuid, p_trip_id uuid, p_expected_version bigint,
  p_machine_id uuid, p_tractor_id uuid, p_spray_equipment_id uuid, p_operator_user_id uuid,
  p_fuel_consumption_l_per_hour double precision, p_start_engine_hours double precision, p_end_engine_hours double precision
) returns jsonb language plpgsql security definer set search_path=public as $fn$
declare
  t public.trips;
  c public.spray_trip_corrections;
  old_json jsonb;
  new_json jsonb;
  actor_name text;
  new_version bigint;
  request_fingerprint text;
  prior_operation public.spray_trip_correction_operations;
  machine_name text;
  unit_name text;
  operator_name text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  if p_operation_id is null or p_expected_version is null or p_expected_version < 0 then
    raise exception 'Invalid correction request' using errcode='22023';
  end if;

  select * into t from public.trips where id=p_trip_id and deleted_at is null for update;
  if t.id is null then
    raise exception 'Trip not found' using errcode='P0002';
  end if;
  if not (
    coalesce(t.trip_function,'')='spraying'
    or exists(
      select 1 from public.spray_records r
      where r.trip_id=t.id and not r.is_template and r.deleted_at is null
    )
  ) then
    raise exception 'Trip is not a spray trip' using errcode='22023';
  end if;
  if not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor']) then
    raise exception 'Correction access required' using errcode='42501';
  end if;

  request_fingerprint:=md5(jsonb_build_object(
    'machineId',p_machine_id,
    'tractorId',p_tractor_id,
    'sprayEquipmentId',p_spray_equipment_id,
    'operatorUserId',p_operator_user_id,
    'fuelRate',p_fuel_consumption_l_per_hour,
    'startEngineHours',p_start_engine_hours,
    'endEngineHours',p_end_engine_hours
  )::text);

  select * into prior_operation from public.spray_trip_correction_operations where operation_id=p_operation_id;
  if prior_operation.operation_id is not null then
    if prior_operation.trip_id<>t.id or prior_operation.request_fingerprint<>request_fingerprint then
      raise exception 'Correction operation id was reused for a different request' using errcode='22023';
    end if;
    select * into c from public.spray_trip_corrections where trip_id=t.id;
    return jsonb_build_object('correction',to_jsonb(c));
  end if;

  if p_machine_id is not null then
    select name into machine_name from public.vineyard_machines where id=p_machine_id and vineyard_id=t.vineyard_id;
    if machine_name is null then raise exception 'Machine is not available in this vineyard' using errcode='22023'; end if;
  end if;
  if p_tractor_id is not null then
    perform 1 from public.tractors where id=p_tractor_id and vineyard_id=t.vineyard_id;
    if not found then raise exception 'Tractor is not available in this vineyard' using errcode='22023'; end if;
  end if;
  if p_spray_equipment_id is not null then
    select name into unit_name from public.spray_equipment where id=p_spray_equipment_id and vineyard_id=t.vineyard_id;
    if unit_name is null then raise exception 'Spray unit is not available in this vineyard' using errcode='22023'; end if;
  end if;
  if p_operator_user_id is not null then
    if not exists(select 1 from public.vineyard_members where vineyard_id=t.vineyard_id and user_id=p_operator_user_id) then
      raise exception 'Operator is not an active vineyard member' using errcode='22023';
    end if;
    select coalesce(nullif(btrim(full_name),''),nullif(btrim(email),''),'VineTrack user')
      into operator_name from public.profiles where id=p_operator_user_id;
  end if;

  if p_fuel_consumption_l_per_hour is not null and (
    p_fuel_consumption_l_per_hour <= 0 or p_fuel_consumption_l_per_hour >= 1000
    or p_fuel_consumption_l_per_hour<>p_fuel_consumption_l_per_hour
    or p_fuel_consumption_l_per_hour in ('Infinity'::double precision,'-Infinity'::double precision)
  ) then raise exception 'Fuel consumption must be a finite positive hourly rate' using errcode='22023'; end if;
  if p_start_engine_hours is not null and (
    p_start_engine_hours < 0 or p_start_engine_hours<>p_start_engine_hours
    or p_start_engine_hours in ('Infinity'::double precision,'-Infinity'::double precision)
  ) then raise exception 'Invalid start engine hours' using errcode='22023'; end if;
  if p_end_engine_hours is not null and (
    p_end_engine_hours < 0 or p_end_engine_hours<>p_end_engine_hours
    or p_end_engine_hours in ('Infinity'::double precision,'-Infinity'::double precision)
  ) then raise exception 'Invalid end engine hours' using errcode='22023'; end if;

  select * into c from public.spray_trip_corrections where trip_id=t.id for update;
  if c.trip_id is null and p_expected_version<>0 then
    raise exception 'Trip correction version conflict' using errcode='40001';
  end if;
  if c.trip_id is not null and c.version<>p_expected_version then
    raise exception 'Trip correction version conflict' using errcode='40001';
  end if;

  if c.trip_id is not null
    and c.machine_id is not distinct from p_machine_id
    and c.tractor_id is not distinct from p_tractor_id
    and c.spray_equipment_id is not distinct from p_spray_equipment_id
    and c.operator_user_id is not distinct from p_operator_user_id
    and c.fuel_consumption_l_per_hour is not distinct from p_fuel_consumption_l_per_hour
    and c.start_engine_hours is not distinct from p_start_engine_hours
    and c.end_engine_hours is not distinct from p_end_engine_hours then
    insert into public.spray_trip_correction_operations(operation_id,vineyard_id,trip_id,request_fingerprint,result_version)
      values(p_operation_id,t.vineyard_id,t.id,request_fingerprint,c.version);
    return jsonb_build_object('correction',to_jsonb(c));
  end if;

  old_json:=coalesce(to_jsonb(c),'{}'::jsonb);
  new_version:=coalesce(c.version,0)+1;
  insert into public.spray_trip_corrections(
    trip_id,vineyard_id,version,machine_id,tractor_id,spray_equipment_id,operator_user_id,
    machine_name_snapshot,spray_unit_name_snapshot,operator_name_snapshot,
    fuel_consumption_l_per_hour,fuel_consumption_source,start_engine_hours,end_engine_hours,
    corrected_at,corrected_by
  ) values(
    t.id,t.vineyard_id,new_version,p_machine_id,p_tractor_id,p_spray_equipment_id,p_operator_user_id,
    machine_name,unit_name,operator_name,p_fuel_consumption_l_per_hour,
    case when p_fuel_consumption_l_per_hour is null then null else 'explicit_correction' end,
    p_start_engine_hours,p_end_engine_hours,clock_timestamp(),auth.uid()
  )
  on conflict(trip_id) do update set
    version=excluded.version,
    machine_id=excluded.machine_id,
    tractor_id=excluded.tractor_id,
    spray_equipment_id=excluded.spray_equipment_id,
    operator_user_id=excluded.operator_user_id,
    machine_name_snapshot=excluded.machine_name_snapshot,
    spray_unit_name_snapshot=excluded.spray_unit_name_snapshot,
    operator_name_snapshot=excluded.operator_name_snapshot,
    fuel_consumption_l_per_hour=excluded.fuel_consumption_l_per_hour,
    fuel_consumption_source=excluded.fuel_consumption_source,
    start_engine_hours=excluded.start_engine_hours,
    end_engine_hours=excluded.end_engine_hours,
    corrected_at=excluded.corrected_at,
    corrected_by=excluded.corrected_by
  returning * into c;

  new_json:=to_jsonb(c);
  if old_json is distinct from new_json then
    select coalesce(nullif(btrim(full_name),''),nullif(btrim(email),''),'VineTrack user')
      into actor_name from public.profiles where id=auth.uid();
    insert into public.spray_trip_correction_amendments(
      operation_id,trip_id,vineyard_id,revision,previous_value,new_value,edited_by,editor_name
    ) values(
      p_operation_id,t.id,t.vineyard_id,new_version,old_json,new_json,auth.uid(),coalesce(actor_name,'VineTrack user')
    );
  end if;

  insert into public.spray_trip_correction_operations(operation_id,vineyard_id,trip_id,request_fingerprint,result_version)
    values(p_operation_id,t.vineyard_id,t.id,request_fingerprint,c.version);
  return jsonb_build_object('correction',to_jsonb(c));
end $fn$;

revoke all on function public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision) from public,anon,service_role;
grant execute on function public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision) to authenticated;

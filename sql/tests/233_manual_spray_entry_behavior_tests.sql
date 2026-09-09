-- Executable rollback-isolated behavioral tests for SQL 232 + additive correction 233.
-- Uses only synthetic @test.local fixtures and rolls every row back.
begin;

create or replace function public._t233_login(p_user_id uuid)
returns void language plpgsql as $fn$
begin
  perform set_config('role','postgres',true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_user_id::text,'role','authenticated')::text,true);
  perform set_config('role','authenticated',true);
end
$fn$;

do $tests$
declare
  v_vineyard uuid:=gen_random_uuid(); v_supervisor uuid:=gen_random_uuid(); v_operator uuid:=gen_random_uuid();
  v_block uuid:=gen_random_uuid(); v_tractor uuid:=gen_random_uuid(); v_unit uuid:=gen_random_uuid(); v_liquid uuid:=gen_random_uuid(); v_solid uuid:=gen_random_uuid();
  v_manual uuid:=gen_random_uuid(); v_spray uuid:=gen_random_uuid(); v_trip uuid:=gen_random_uuid();
  v_tank1 uuid:=gen_random_uuid(); v_tank2 uuid:=gen_random_uuid(); v_tank3 uuid:=gen_random_uuid();
  v_actual1 uuid:=gen_random_uuid(); v_actual2 uuid:=gen_random_uuid(); v_actual3 uuid:=gen_random_uuid();
  v_chem1 uuid:=gen_random_uuid(); v_chem2 uuid:=gen_random_uuid(); v_chem3 uuid:=gen_random_uuid();
  v_create_op uuid:=gen_random_uuid(); v_add_op uuid:=gen_random_uuid(); v_remove_op uuid:=gen_random_uuid(); v_delete_op uuid:=gen_random_uuid();
  v_payload jsonb; v_added jsonb; v_retained jsonb; v_result jsonb; v_retry jsonb; v_report jsonb;
  v_version integer; v_state text; v_count bigint; v_deleted_at timestamptz; v_deleted_version integer;
  v_before_sprays bigint; v_before_trips bigint; v_before_actuals bigint;
  v_missing_manual uuid:=gen_random_uuid(); v_missing_spray uuid:=gen_random_uuid(); v_missing_trip uuid:=gen_random_uuid();
  v_missing_delete_op uuid:=gen_random_uuid(); v_missing_save_op uuid:=gen_random_uuid();
  v_tracked_trip uuid:=gen_random_uuid(); v_tracked_spray uuid:=gen_random_uuid(); v_tracked_tank uuid:=gen_random_uuid(); v_tracked_chemical uuid:=gen_random_uuid();
begin
  perform set_config('role','postgres',true);
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at) values
    (v_supervisor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','t233-supervisor@test.local','x',now(),now(),now()),
    (v_operator,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','t233-operator@test.local','x',now(),now(),now());
  insert into public.profiles(id,email,full_name) values
    (v_supervisor,'t233-supervisor@test.local','T233 Supervisor'),
    (v_operator,'t233-operator@test.local','T233 Operator') on conflict(id) do update set full_name=excluded.full_name;
  insert into public.vineyards(id,name) values(v_vineyard,'T233 Synthetic Vineyard');
  insert into public.vineyard_members(vineyard_id,user_id,role) values
    (v_vineyard,v_supervisor,'supervisor'),(v_vineyard,v_operator,'operator');
  insert into public.paddocks(id,vineyard_id,name) values(v_block,v_vineyard,'T233 Block');
  insert into public.tractors(id,vineyard_id,name,brand,model,fuel_usage_l_per_hour) values(v_tractor,v_vineyard,'T233 Tractor','Test','One',6);
  insert into public.spray_equipment(id,vineyard_id,name,tank_capacity_litres) values(v_unit,v_vineyard,'T233 Spray Unit',2000);
  insert into public.saved_chemicals(id,vineyard_id,name,unit) values
    (v_liquid,v_vineyard,'T233 Liquid','Litres'),(v_solid,v_vineyard,'T233 Solid','Kg');

  v_payload:=jsonb_build_object(
    'vineyardId',v_vineyard,'manualEntryId',v_manual,'sprayRecordId',v_spray,'tripId',v_trip,
    'reference','T233 manual application','operationType','Foliar Spray',
    'startUtc','2026-09-08T13:30:00Z','endUtc','2026-09-08T16:15:00Z','vineyardTimeZone','Australia/Adelaide',
    'tractorId',v_tractor,'operatorUserId',v_operator,'sprayEquipmentId',v_unit,'startEngineHours',100.5,'endEngineHours',102.0,
    'clientUpdatedAt','2026-09-09T01:20:00Z','notes','Synthetic rollback-only fixture',
    'blocks',jsonb_build_array(jsonb_build_object('blockId',v_block,'blockName','T233 Block')),
    'tanks',jsonb_build_array(
      jsonb_build_object('id',v_tank1,'actualId',v_actual1,'tankNumber',1,'waterVolumeLitres',1000,
        'chemicals',jsonb_build_array(jsonb_build_object('id',v_chem1,'savedChemicalId',v_liquid,'name','T233 Liquid','actualAmountBase',2500,'unit','Litres','productCategory','fungicide','physicalForm','liquid','snapshotAt','2026-09-08T13:00:00Z'))),
      jsonb_build_object('id',v_tank2,'actualId',v_actual2,'tankNumber',2,'waterVolumeLitres',750,
        'chemicals',jsonb_build_array(jsonb_build_object('id',v_chem2,'savedChemicalId',v_solid,'name','T233 Solid','actualAmountBase',800,'unit','Kg','productCategory','fungicide','physicalForm','solid','snapshotAt','2026-09-08T13:00:00Z')))
    ),
    'manualWeather',jsonb_build_object('observedAt','2026-09-08T13:30:00Z','source','Operator observation','temperatureC',18.2,'humidityPct',71,'windSpeedKmh',6.4,'windGustKmh',9.1,'windDirectionDeg',210,'rainMm',0)
  );

  -- Operator rejection does not partially create anything.
  perform public._t233_login(v_operator); v_state:=null;
  begin perform public.save_manual_spray_v1(v_create_op,v_payload,0); exception when others then v_state:=sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'T1 FAILED: Operator save expected 42501, got %',coalesce(v_state,'no error'); end if;
  if exists(select 1 from public.spray_records where id=v_spray) then raise exception 'T1 FAILED: rejected save created a spray'; end if;

  -- Supervisor atomic create, actual liquid/solid round-trip, weather, provenance.
  perform public._t233_login(v_supervisor);
  v_result:=public.save_manual_spray_v1(v_create_op,v_payload,0); v_version:=(v_result->>'syncVersion')::integer;
  if v_result#>>'{source}' <> 'manual' or v_version<1 then raise exception 'T2 FAILED: Supervisor create response invalid'; end if;
  if not exists(select 1 from public.trips where id=v_trip and entry_source='manual' and manual_entry_id=v_manual and not is_active and end_time is not null and total_tanks=2) then raise exception 'T2 FAILED: completed backing trip missing'; end if;
  if (select count(*) from public.spray_tank_actuals where spray_record_id=v_spray and deleted_at is null)<>2 then raise exception 'T2 FAILED: two active actual tanks not created'; end if;
  if (select (chemicals->0->>'actualAmountBase')::double precision from public.spray_tank_actuals where id=v_actual1) is distinct from 2500::double precision then raise exception 'T2 FAILED: liquid mL base amount changed'; end if;
  if (select (chemicals->0->>'actualAmountBase')::double precision from public.spray_tank_actuals where id=v_actual2) is distinct from 800::double precision then raise exception 'T2 FAILED: solid g base amount changed'; end if;
  if not exists(select 1 from public.trip_weather_observations where trip_id=v_trip and source_kind='manual' and provider='manual_entry' and temperature_c=18.2) then raise exception 'T2 FAILED: manual weather missing'; end if;
  if not exists(select 1 from public.spray_records where id=v_spray and tanks->0 ? 'waterVolume' and tanks->0 ? 'rowApplications' and tanks->0->'chemicals'->0 ? 'volumePerTank') then raise exception 'T2 FAILED: released-client tank compatibility keys missing'; end if;

  -- Identical lost-response retry is cached and does not move version.
  v_retry:=public.save_manual_spray_v1(v_create_op,v_payload,0);
  if v_retry is distinct from v_result or (select sync_version from public.spray_records where id=v_spray)<>v_version then raise exception 'T3 FAILED: identical retry was not stable'; end if;
  v_state:=null;
  begin perform public.save_manual_spray_v1(v_create_op,jsonb_set(v_payload,'{reference}','"changed reuse"'::jsonb),0); exception when others then v_state:=sqlstate; end;
  if v_state is distinct from '22023' then raise exception 'T3 FAILED: changed payload reuse expected 22023, got %',coalesce(v_state,'no error'); end if;

  -- Invalid create rolls every table back atomically.
  select count(*) into v_before_sprays from public.spray_records;
  select count(*) into v_before_trips from public.trips;
  select count(*) into v_before_actuals from public.spray_tank_actuals;
  v_state:=null;
  begin perform public.save_manual_spray_v1(gen_random_uuid(),jsonb_set(jsonb_set(jsonb_set(v_payload,'{manualEntryId}',to_jsonb(gen_random_uuid())),'{sprayRecordId}',to_jsonb(gen_random_uuid())),'{blocks}','[]'::jsonb),0); exception when others then v_state:=sqlstate; end;
  if v_state is distinct from '22023' or (select count(*) from public.spray_records)<>v_before_sprays or (select count(*) from public.trips)<>v_before_trips or (select count(*) from public.spray_tank_actuals)<>v_before_actuals then raise exception 'T4 FAILED: invalid save was not atomic'; end if;

  -- Add a third tank, preserving existing identities and quantities.
  v_added:=jsonb_set(v_payload,'{tanks}',(v_payload->'tanks')||jsonb_build_array(
    jsonb_build_object('id',v_tank3,'actualId',v_actual3,'tankNumber',3,'waterVolumeLitres',500,
      'chemicals',jsonb_build_array(jsonb_build_object('id',v_chem3,'savedChemicalId',v_liquid,'name','T233 Liquid','actualAmountBase',1250,'unit','mL','productCategory','fungicide','physicalForm','liquid','snapshotAt','2026-09-08T13:00:00Z')))
  ));
  v_result:=public.save_manual_spray_v1(v_add_op,v_added,v_version); v_version:=(v_result->>'syncVersion')::integer;
  if (select count(*) from public.spray_tank_actuals where spray_record_id=v_spray and deleted_at is null)<>3 or (select total_tanks from public.trips where id=v_trip)<>3 then raise exception 'T5 FAILED: tank addition failed'; end if;

  -- Stale edit conflicts before changing rows.
  v_state:=null;
  begin perform public.save_manual_spray_v1(gen_random_uuid(),v_added,v_version-1); exception when others then v_state:=sqlstate; end;
  if v_state is distinct from '40001' then raise exception 'T6 FAILED: stale version expected 40001, got %',coalesce(v_state,'no error'); end if;

  -- Remove Tank 1; retain stable tanks 2/3 and renumber them to 1/2.
  v_retained:=jsonb_set(v_added,'{tanks}',jsonb_build_array(
    jsonb_set(v_added->'tanks'->1,'{tankNumber}','1'::jsonb),
    jsonb_set(v_added->'tanks'->2,'{tankNumber}','2'::jsonb)
  ));
  v_result:=public.save_manual_spray_v1(v_remove_op,v_retained,v_version); v_version:=(v_result->>'syncVersion')::integer;
  if not exists(select 1 from public.spray_tank_actuals where id=v_actual1 and deleted_at is not null) then raise exception 'T7 FAILED: removed actual was not soft-deleted'; end if;
  if not exists(select 1 from public.spray_tank_actuals where id=v_actual2 and deleted_at is null and tank_number=1 and water_volume_l=750) then raise exception 'T7 FAILED: retained Tank 2 identity/amount/renumber changed'; end if;
  if not exists(select 1 from public.spray_tank_actuals where id=v_actual3 and deleted_at is null and tank_number=2 and water_volume_l=500) then raise exception 'T7 FAILED: retained Tank 3 identity/amount/renumber changed'; end if;
  if (select total_tanks from public.trips where id=v_trip)<>2 then raise exception 'T7 FAILED: trip total_tanks not reduced'; end if;
  v_report:=public.get_spray_report_v1(v_trip);
  if v_report->>'schemaVersion'<>'1.2' or v_report#>>'{provenance,isManualEntry}'<>'true' or jsonb_array_length(v_report->'tanks')<>2 or jsonb_array_length(v_report->'plannedChemicalTotals')<>0 then raise exception 'T8 FAILED: canonical manual report shape/tank count invalid'; end if;
  if v_report#>>'{tanks,0,plannedWaterLitres}' is not null or (v_report#>>'{tanks,0,actualWaterLitres}')::double precision<>750 then raise exception 'T8 FAILED: report planned/actual semantics invalid'; end if;
  if v_report#>>'{recordingEvidence,route}'<>'Not recorded — manual application' then raise exception 'T8 FAILED: report evidence/provenance invalid'; end if;

  -- Existing tracked reports remain schema 1.2 with their planned quantities.
  insert into public.trips(id,vineyard_id,start_time,end_time,is_active,trip_function,tractor_id,operator_user_id,tank_sessions,total_tanks,entry_source,created_by)
  values(v_tracked_trip,v_vineyard,'2026-09-07T10:00:00Z','2026-09-07T11:00:00Z',false,'spraying',v_tractor,v_operator,
    jsonb_build_array(jsonb_build_object('id',v_tracked_tank,'tank_number',1,'tankNumber',1,'status','completed','paths_covered','[]'::jsonb)),1,'tracked',v_supervisor);
  insert into public.spray_records(id,vineyard_id,trip_id,date,start_time,end_time,spray_reference,is_template,operation_type,tanks,entry_source,created_by)
  values(v_tracked_spray,v_vineyard,v_tracked_trip,'2026-09-07T10:00:00Z','2026-09-07T10:00:00Z','2026-09-07T11:00:00Z','T233 tracked',false,'Foliar Spray',
    jsonb_build_array(jsonb_build_object('id',v_tracked_tank,'tankNumber',1,'waterVolume',600,'sprayRatePerHa',100,'concentrationFactor',1,'rowApplications','[]'::jsonb,
      'chemicals',jsonb_build_array(jsonb_build_object('id',v_tracked_chemical,'name','T233 Liquid','volumePerTank',1000,'ratePerHa',100,'ratePer100L',0,'costPerUnit',0,'unit','mL','savedChemicalId',v_liquid)))),'tracked',v_supervisor);
  v_report:=public.get_spray_report_v1(v_tracked_trip);
  if v_report->>'schemaVersion'<>'1.2' or v_report#>>'{provenance,isManualEntry}'<>'false' or (v_report#>>'{tanks,0,plannedWaterLitres}')::double precision<>600 then raise exception 'T9 FAILED: tracked report compatibility changed'; end if;

  -- Coordinated delete, idempotent delete retry, and retry-after-delete authority.
  v_result:=public.delete_manual_spray_v1(v_delete_op,v_vineyard,v_manual,v_spray,v_trip);
  select deleted_at,sync_version into v_deleted_at,v_deleted_version from public.spray_records where id=v_spray;
  v_retry:=public.delete_manual_spray_v1(v_delete_op,v_vineyard,v_manual,v_spray,v_trip);
  if v_retry is distinct from v_result or (select deleted_at from public.spray_records where id=v_spray) is distinct from v_deleted_at or (select sync_version from public.spray_records where id=v_spray)<>v_deleted_version then raise exception 'T10 FAILED: delete retry changed state'; end if;
  if not exists(select 1 from public.trips where id=v_trip and deleted_at is not null) or exists(select 1 from public.spray_tank_actuals where spray_record_id=v_spray and deleted_at is null) then raise exception 'T10 FAILED: coordinated delete incomplete'; end if;
  foreach v_count in array array[0,1] loop
    v_state:=null;
    begin perform public.save_manual_spray_v1(case when v_count=0 then v_create_op else v_remove_op end,case when v_count=0 then v_payload else v_retained end,case when v_count=0 then 0 else v_version-1 end); exception when others then v_state:=sqlstate; end;
    if v_state is distinct from '55000' then raise exception 'T11 FAILED: cached save retry after delete expected 55000, got %',coalesce(v_state,'no error'); end if;
  end loop;

  -- Delete-before-create is authoritative and creates no application rows.
  perform public.delete_manual_spray_v1(v_missing_delete_op,v_vineyard,v_missing_manual,v_missing_spray,v_missing_trip);
  v_state:=null;
  begin perform public.save_manual_spray_v1(v_missing_save_op,jsonb_set(jsonb_set(jsonb_set(v_payload,'{manualEntryId}',to_jsonb(v_missing_manual)),'{sprayRecordId}',to_jsonb(v_missing_spray)),'{tripId}',to_jsonb(v_missing_trip)),0); exception when others then v_state:=sqlstate; end;
  if v_state is distinct from '55000' or exists(select 1 from public.spray_records where id=v_missing_spray) or exists(select 1 from public.trips where id=v_missing_trip) then raise exception 'T12 FAILED: delete-before-create did not suppress save'; end if;

  raise notice 'SQL 233 manual spray behavioral tests passed; transaction will roll back.';
end
$tests$;
rollback;

-- Isolated executable verification for 232. All rows and claims roll back.
begin;

set local client_min_messages = warning;

do $$
declare
  captured timestamptz := clock_timestamp();
  wrap jsonb;
  contradictory jsonb;
  rows_json jsonb := '[
    {"number":25,"startPoint":{"latitude":-0.001,"longitude":-0.0000134747},"endPoint":{"latitude":0.001,"longitude":-0.0000134747}},
    {"number":26,"startPoint":{"latitude":-0.001,"longitude":0.0000134747},"endPoint":{"latitude":0.001,"longitude":0.0000134747}}
  ]';
  polygon_json jsonb := '[
    {"latitude":-0.0012,"longitude":-0.00003},{"latitude":0.0012,"longitude":-0.00003},
    {"latitude":0.0012,"longitude":0.00003},{"latitude":-0.0012,"longitude":0.00003}
  ]';
  observations jsonb;
  result jsonb;
begin
  observations := jsonb_build_array(
    jsonb_build_object('observedAt',captured-interval '4 seconds','latitude',0.0,'longitude',0.0,'horizontalAccuracyM',0.4,'courseDegrees',359,'speedMps',1.0),
    jsonb_build_object('observedAt',captured-interval '2 seconds','latitude',0.00001,'longitude',0.0,'horizontalAccuracyM',0.4,'courseDegrees',1,'speedMps',1.0),
    jsonb_build_object('observedAt',captured-interval '1 second','latitude',0.00002,'longitude',0.0,'horizontalAccuracyM',0.4,'courseDegrees',0,'speedMps',1.0)
  );
  wrap:=public.pin_capture_course_direction(observations,captured,0.70);
  if wrap is null or least(abs((wrap->>'heading')::double precision),abs((wrap->>'heading')::double precision-360))>2 then
    raise exception 'T1 north wraparound did not produce north: %',wrap;
  end if;

  result:=public.resolve_pin_row_geometry(rows_json,polygon_json,gen_random_uuid(),0.00002,0.0,0.4,null,null,captured,'Left',null,observations,3);
  if result is null or (result->>'row')::numeric<>25 or (result->>'driving_row')::numeric<>25.5
     or least(abs((result->>'heading_used')::double precision),abs((result->>'heading_used')::double precision-360))>2 then
    raise exception 'T2 lock-free north-facing Left resolution failed: %',result;
  end if;

  contradictory:=jsonb_build_array(
    jsonb_build_object('observedAt',captured-interval '4 seconds','latitude',0.0,'longitude',0.0,'courseDegrees',0,'speedMps',1),
    jsonb_build_object('observedAt',captured-interval '2 seconds','latitude',0.00001,'longitude',0.0,'courseDegrees',180,'speedMps',1),
    jsonb_build_object('observedAt',captured-interval '1 second','latitude',0.00002,'longitude',0.0,'courseDegrees',90,'speedMps',1)
  );
  if public.pin_capture_course_direction(contradictory,captured,0.70) is not null then
    raise exception 'T3 contradictory direction was accepted';
  end if;

  if public.pin_capture_course_direction(observations || (observations->0) || (observations->0),captured,0.70) is null then
    raise exception 'T4 duplicate samples incorrectly erased otherwise independent support';
  end if;
  if public.pin_capture_course_direction(jsonb_build_array(observations->0,observations->0,observations->0),captured,0.70) is not null then
    raise exception 'T5 repeated sample counted as independent movement';
  end if;
  if public.pin_capture_course_direction(jsonb_build_array(
      (observations->0)||jsonb_build_object('observedAt',captured-interval '9 seconds'),
      (observations->1)||jsonb_build_object('observedAt',captured-interval '8 seconds'),
      (observations->2)||jsonb_build_object('observedAt',captured-interval '7 seconds')),captured,0.70) is not null then
    raise exception 'T6 stale course samples were accepted';
  end if;

  if public.resolve_pin_row_geometry(rows_json,polygon_json,gen_random_uuid(),0.0011,0.0,0.4,0,captured,captured,'Left',null,
      jsonb_build_array(
        jsonb_build_object('observedAt',captured-interval '3 seconds','latitude',0.00108,'longitude',0.0,'horizontalAccuracyM',0.4),
        jsonb_build_object('observedAt',captured-interval '2 seconds','latitude',0.00109,'longitude',0.0,'horizontalAccuracyM',0.4),
        jsonb_build_object('observedAt',captured-interval '1 second','latitude',0.0011,'longitude',0.0,'horizontalAccuracyM',0.4)),3) is not null then
    raise exception 'T7 headland observations were accepted';
  end if;
  if public.resolve_pin_row_geometry(rows_json,polygon_json,gen_random_uuid(),0.00002,0.00002,0.4,0,captured,captured,'Left',null,
      jsonb_build_array(
        jsonb_build_object('observedAt',captured-interval '3 seconds','latitude',0.0,'longitude',0.00002,'horizontalAccuracyM',0.4),
        jsonb_build_object('observedAt',captured-interval '2 seconds','latitude',0.00001,'longitude',0.00002,'horizontalAccuracyM',0.4),
        jsonb_build_object('observedAt',captured-interval '1 second','latitude',0.00002,'longitude',0.00002,'horizontalAccuracyM',0.4)),3) is not null then
    raise exception 'T8 outside-aisle observations were accepted';
  end if;
end $$;

do $$
declare
  user_id uuid:=gen_random_uuid(); vineyard_id uuid:=gen_random_uuid(); paddock_id uuid:=gen_random_uuid();
  pin_id uuid:=gen_random_uuid(); stale_pin_id uuid:=gen_random_uuid(); operation_id uuid:=gen_random_uuid(); stale_operation_id uuid:=gen_random_uuid();
  captured timestamptz; rows_json jsonb; polygon_json jsonb; observations jsonb; geometry_hash text; resolved jsonb;
  first_outcome text; retry_outcome text; stale_outcome text; expected_version integer;
begin
  insert into auth.users(id,email) values(user_id,'pin-232-'||user_id||'@example.invalid');
  insert into public.profiles(id,email) values(user_id,'pin-232-'||user_id||'@example.invalid');
  insert into public.vineyards(id,name,owner_id) values(vineyard_id,'Pin 232 fixture',user_id);
  insert into public.vineyard_members(vineyard_id,user_id,role) values(vineyard_id,user_id,'owner');
  perform set_config('request.jwt.claims',json_build_object('role','authenticated','sub',user_id)::text,true);

  rows_json:='[{"number":25,"startPoint":{"latitude":-0.001,"longitude":-0.0000134747},"endPoint":{"latitude":0.001,"longitude":-0.0000134747}},{"number":26,"startPoint":{"latitude":-0.001,"longitude":0.0000134747},"endPoint":{"latitude":0.001,"longitude":0.0000134747}}]';
  polygon_json:='[{"latitude":-0.0012,"longitude":-0.00003},{"latitude":0.0012,"longitude":-0.00003},{"latitude":0.0012,"longitude":0.00003},{"latitude":-0.0012,"longitude":0.00003}]';
  insert into public.paddocks(id,vineyard_id,name,row_width,polygon_points,rows) values(paddock_id,vineyard_id,'Fixture block',3,polygon_json,rows_json);
  captured:=clock_timestamp();
  observations:=jsonb_build_array(
    jsonb_build_object('observedAt',captured-interval '4 seconds','latitude',0.0,'longitude',0.0,'horizontalAccuracyM',0.4,'courseDegrees',359,'speedMps',1),
    jsonb_build_object('observedAt',captured-interval '2 seconds','latitude',0.00001,'longitude',0.0,'horizontalAccuracyM',0.4,'courseDegrees',1,'speedMps',1),
    jsonb_build_object('observedAt',captured-interval '1 second','latitude',0.00002,'longitude',0.0,'horizontalAccuracyM',0.4,'courseDegrees',0,'speedMps',1));
  geometry_hash:=public.pin_geometry_identity(polygon_json,rows_json);
  resolved:=public.resolve_pin_row_geometry(rows_json,polygon_json,paddock_id,0.00002,0.0,0.4,null,null,captured,'Left',null,observations,3);
  if resolved is null then raise exception 'T9 confirmation setup did not resolve'; end if;

  insert into public.pins(id,vineyard_id,mode,button_name,title,latitude,longitude,side,created_by,created_at,sync_version)
  values(pin_id,vineyard_id,'Repairs','Fixture','Fixture',0.00002,0.0,'Left',user_id,captured,1),
        (stale_pin_id,vineyard_id,'Repairs','Fixture','Fixture',0.00002,0.0,'Left',user_id,captured,1);
  insert into public.pin_capture_evidence(pin_id,vineyard_id,evidence_revision,resolver_version,captured_at,location_observed_at,raw_latitude,raw_longitude,
    horizontal_accuracy_m,pressed_side,capture_user_id,capture_button_name,capture_mode,observations,geometry_revision,geometry_hash,created_by)
  values(pin_id,vineyard_id,1,'fixture-232',captured,captured,0.00002,0.0,0.4,'Left',user_id,'Fixture','Repairs',observations,'pin-geometry-v1',geometry_hash,user_id),
        (stale_pin_id,vineyard_id,1,'fixture-232',captured,captured,0.00002,0.0,0.4,'Left',user_id,'Fixture','Repairs',observations,'pin-geometry-v1',geometry_hash,user_id);

  select fixture_pin.sync_version into expected_version
  from public.pins as fixture_pin
  where fixture_pin.id = pin_id;
  first_outcome:=public.confirm_saved_pin_location_v2(operation_id,pin_id,1,expected_version,paddock_id,25.5,25,'Left',
    (resolved->>'snapped_latitude')::double precision,(resolved->>'snapped_longitude')::double precision,(resolved->>'along_m')::numeric);
  retry_outcome:=public.confirm_saved_pin_location_v2(operation_id,pin_id,1,expected_version,paddock_id,25.5,25,'Left',
    (resolved->>'snapped_latitude')::double precision,(resolved->>'snapped_longitude')::double precision,(resolved->>'along_m')::numeric);
  if first_outcome<>'confirmed' or retry_outcome<>'confirmed' then raise exception 'T10 lost-response retry was not idempotent: %, %',first_outcome,retry_outcome; end if;
  if (select fixture_pin.sync_version from public.pins as fixture_pin where fixture_pin.id = pin_id)<>expected_version+1 then
    raise exception 'T11 identical retry applied twice';
  end if;

  select fixture_pin.sync_version into expected_version
  from public.pins as fixture_pin
  where fixture_pin.id = stale_pin_id;
  update public.pins as fixture_pin
  set notes='newer handset edit',sync_version=fixture_pin.sync_version+1
  where fixture_pin.id = stale_pin_id;
  stale_outcome:=public.confirm_saved_pin_location_v2(stale_operation_id,stale_pin_id,1,expected_version,paddock_id,25.5,25,'Left',
    (resolved->>'snapped_latitude')::double precision,(resolved->>'snapped_longitude')::double precision,(resolved->>'along_m')::numeric);
  if stale_outcome<>'conflict_newer_edit' then raise exception 'T12 newer edit was not preserved: %',stale_outcome; end if;
  if (select fixture_pin.pin_row_number from public.pins as fixture_pin where fixture_pin.id = stale_pin_id) is not null then
    raise exception 'T13 stale confirmation changed placement';
  end if;
  if not exists(
    select 1
    from public.pin_location_confirmation_operations as confirmation_operation
    where confirmation_operation.operation_id = stale_operation_id
      and confirmation_operation.outcome = 'conflict_newer_edit'
  ) then
    raise exception 'T14 durable conflict outcome missing';
  end if;
end $$;

rollback;

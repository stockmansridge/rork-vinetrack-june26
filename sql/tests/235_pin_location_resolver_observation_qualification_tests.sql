-- Rollback-isolated executable verification for SQL 235.
begin;
set local client_min_messages = warning;

do $$
declare
  captured timestamptz:=clock_timestamp();
  paddock_id uuid:=gen_random_uuid();
  rows_two jsonb:='[
    {"number":25,"startPoint":{"latitude":-0.001,"longitude":-0.0000134747},"endPoint":{"latitude":0.001,"longitude":-0.0000134747}},
    {"number":26,"startPoint":{"latitude":-0.001,"longitude":0.0000134747},"endPoint":{"latitude":0.001,"longitude":0.0000134747}}
  ]';
  rows_three jsonb:='[
    {"number":25,"startPoint":{"latitude":-0.001,"longitude":-0.0000269494},"endPoint":{"latitude":0.001,"longitude":-0.0000269494}},
    {"number":26,"startPoint":{"latitude":-0.001,"longitude":0.0},"endPoint":{"latitude":0.001,"longitude":0.0}},
    {"number":27,"startPoint":{"latitude":-0.001,"longitude":0.0000269494},"endPoint":{"latitude":0.001,"longitude":0.0000269494}}
  ]';
  polygon_two jsonb:='[
    {"latitude":-0.0012,"longitude":-0.00003},{"latitude":0.0012,"longitude":-0.00003},
    {"latitude":0.0012,"longitude":0.00003},{"latitude":-0.0012,"longitude":0.00003}
  ]';
  polygon_three jsonb:='[
    {"latitude":-0.0012,"longitude":-0.00004},{"latitude":0.0012,"longitude":-0.00004},
    {"latitude":0.0012,"longitude":0.00004},{"latitude":-0.0012,"longitude":0.00004}
  ]';
  moving jsonb; stationary jsonb; replayed jsonb; stale jsonb; future_samples jsonb; headland jsonb; ambiguous jsonb; conflicting jsonb;
  result jsonb;
begin
  moving:=jsonb_build_array(
    jsonb_build_object('observedAt',captured-interval '4 seconds','latitude',0.0,'longitude',0.0,'horizontalAccuracyM',2.8,'courseDegrees',359,'speedMps',1.0),
    jsonb_build_object('observedAt',captured-interval '2 seconds','latitude',0.00001,'longitude',0.0,'horizontalAccuracyM',2.8,'courseDegrees',1,'speedMps',1.0),
    jsonb_build_object('observedAt',captured-interval '1 second','latitude',0.00002,'longitude',0.0,'horizontalAccuracyM',2.8,'courseDegrees',0,'speedMps',1.0));
  result:=public.resolve_pin_row_geometry(rows_two,polygon_two,paddock_id,0.00002,0.0,2.8,null,null,captured,'Left',null,moving,3);
  if result is null or (result->>'driving_row')::numeric<>25.5 or (result->>'row')::numeric<>25 then
    raise exception 'T1 realistic 2.8 m accuracy did not resolve unique 3 m aisle: %',result;
  end if;

  stationary:=jsonb_build_array(
    jsonb_build_object('observedAt',captured-interval '3 seconds','latitude',0.00002,'longitude',0.0,'horizontalAccuracyM',0.4),
    jsonb_build_object('observedAt',captured-interval '2 seconds','latitude',0.00002,'longitude',0.0,'horizontalAccuracyM',0.4),
    jsonb_build_object('observedAt',captured-interval '1 second','latitude',0.00002,'longitude',0.0,'horizontalAccuracyM',0.4));
  result:=public.resolve_pin_row_geometry(rows_two,polygon_two,paddock_id,0.00002,0.0,0.4,0,captured,captured,'Left',null,stationary,3);
  if result is null or (result->>'support_count')::integer<>3 then
    raise exception 'T2 distinct fresh stationary observations were not retained: %',result;
  end if;

  replayed:=jsonb_build_array(stationary->0,stationary->0,stationary->0);
  if public.resolve_pin_row_geometry(rows_two,polygon_two,paddock_id,0.00002,0.0,0.4,0,captured,captured,'Left',null,replayed,3) is not null then
    raise exception 'T3 replayed copies of one observation counted as support';
  end if;

  conflicting:=stationary || jsonb_build_array((stationary->0)||jsonb_build_object('longitude',0.00002));
  if public.resolve_pin_row_geometry(rows_two,polygon_two,paddock_id,0.00002,0.0,0.4,0,captured,captured,'Left',null,conflicting,3) is not null then
    raise exception 'T4 conflicting payloads with one observation identity were accepted';
  end if;

  ambiguous:=jsonb_build_array(
    jsonb_build_object('observedAt',captured-interval '3 seconds','latitude',0.0,'longitude',0.0,'horizontalAccuracyM',0.4),
    jsonb_build_object('observedAt',captured-interval '2 seconds','latitude',0.00001,'longitude',0.0,'horizontalAccuracyM',0.4),
    jsonb_build_object('observedAt',captured-interval '1 second','latitude',0.00002,'longitude',0.0,'horizontalAccuracyM',0.4));
  if public.resolve_pin_row_geometry(rows_three,polygon_three,paddock_id,0.00002,0.0,0.4,0,captured,captured,'Left',
      jsonb_build_object('paddockId',paddock_id,'aisleNumber',25.5,'supportingObservations',3,'confirmedAt',captured),ambiguous,3) is not null then
    raise exception 'T5 lock metadata forced an adjacent-aisle ambiguity';
  end if;

  stale:=jsonb_build_array(
    (stationary->0)||jsonb_build_object('observedAt',captured-interval '23 seconds'),
    (stationary->1)||jsonb_build_object('observedAt',captured-interval '22 seconds'),
    (stationary->2)||jsonb_build_object('observedAt',captured-interval '21 seconds'));
  if public.resolve_pin_row_geometry(rows_two,polygon_two,paddock_id,0.00002,0.0,0.4,0,captured,captured,'Left',null,stale,3) is not null then
    raise exception 'T6 stale observations were accepted';
  end if;

  future_samples:=jsonb_build_array(
    (stationary->0)||jsonb_build_object('observedAt',captured+interval '1 second'),
    (stationary->1)||jsonb_build_object('observedAt',captured+interval '2 seconds'),
    (stationary->2)||jsonb_build_object('observedAt',captured+interval '3 seconds'));
  if public.resolve_pin_row_geometry(rows_two,polygon_two,paddock_id,0.00002,0.0,0.4,0,captured,captured,'Left',null,future_samples,3) is not null then
    raise exception 'T7 future observations were accepted';
  end if;

  headland:=jsonb_build_array(
    jsonb_build_object('observedAt',captured-interval '3 seconds','latitude',0.00108,'longitude',0.0,'horizontalAccuracyM',0.4),
    jsonb_build_object('observedAt',captured-interval '2 seconds','latitude',0.00109,'longitude',0.0,'horizontalAccuracyM',0.4),
    jsonb_build_object('observedAt',captured-interval '1 second','latitude',0.00110,'longitude',0.0,'horizontalAccuracyM',0.4));
  if public.resolve_pin_row_geometry(rows_two,polygon_two,paddock_id,0.00110,0.0,0.4,0,captured,captured,'Left',null,headland,3) is not null then
    raise exception 'T8 headland observations were accepted';
  end if;

  if public.resolve_pin_row_geometry(rows_two,polygon_two,paddock_id,0.00002,0.0,0.4,0,captured,captured,'Left',
      jsonb_build_object('paddockId',paddock_id,'aisleNumber',26.5,'supportingObservations',3,'confirmedAt',captured),stationary,3) is not null then
    raise exception 'T9 contradictory lock metadata overrode independently qualified history';
  end if;
end $$;

rollback;

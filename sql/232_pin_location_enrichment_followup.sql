-- Forward-only correction for deployed pin enrichment 231.
-- No historical enqueue, scheduling, worker deployment, or data rewrite.

-- Supabase installs pgcrypto in the extensions schema. Qualify digest calls so
-- security-definer functions with a restricted search_path remain executable.
create or replace function public.pin_geometry_identity(points jsonb, rows jsonb)
returns text language sql immutable as $$
select 'pin-geometry-v1:' || encode(extensions.digest(
  'pin-geometry-v1|p=' || coalesce((
    select string_agg(to_char(coalesce((p->>'latitude')::numeric,(p->>'lat')::numeric),'FM999999990.00000000') || ',' ||
                      to_char(coalesce((p->>'longitude')::numeric,(p->>'lng')::numeric),'FM999999990.00000000'),';' order by ord)
    from jsonb_array_elements(coalesce(points,'[]'::jsonb)) with ordinality x(p,ord)
  ),'') || '|r=' || coalesce((
    select string_agg((r->>'number') || ':' ||
      to_char(coalesce((coalesce(r->'startPoint',r->'start_point')->>'latitude')::numeric,(coalesce(r->'startPoint',r->'start_point')->>'lat')::numeric),'FM999999990.00000000') || ',' ||
      to_char(coalesce((coalesce(r->'startPoint',r->'start_point')->>'longitude')::numeric,(coalesce(r->'startPoint',r->'start_point')->>'lng')::numeric),'FM999999990.00000000') || '>' ||
      to_char(coalesce((coalesce(r->'endPoint',r->'end_point')->>'latitude')::numeric,(coalesce(r->'endPoint',r->'end_point')->>'lat')::numeric),'FM999999990.00000000') || ',' ||
      to_char(coalesce((coalesce(r->'endPoint',r->'end_point')->>'longitude')::numeric,(coalesce(r->'endPoint',r->'end_point')->>'lng')::numeric),'FM999999990.00000000'),';' order by (r->>'number')::numeric)
    from jsonb_array_elements(coalesce(rows,'[]'::jsonb)) x(r)
  ),''), 'sha256'),'hex')
$$;

alter function public.insert_pin_capture_evidence(jsonb)
  set search_path = public, extensions;

create or replace function public.pin_capture_course_direction(
  observations jsonb,
  captured_at timestamptz,
  minimum_agreement double precision default 0.70
)
returns jsonb
language plpgsql
immutable
as $$
declare
  sample_count integer;
  sum_sin double precision;
  sum_cos double precision;
  resultant double precision;
  heading_used double precision;
  first_lat double precision;
  first_lon double precision;
  last_lat double precision;
  last_lon double precision;
  displacement_m double precision;
  displacement_heading double precision;
  heading_delta double precision;
begin
  if jsonb_typeof(observations) <> 'array' then return null; end if;

  with unique_samples as (
    select distinct on (x->>'observedAt', x->>'latitude', x->>'longitude')
      (x->>'observedAt')::timestamptz observed_at,
      (x->>'latitude')::double precision latitude,
      (x->>'longitude')::double precision longitude,
      (x->>'courseDegrees')::double precision course_degrees
    from jsonb_array_elements(observations) x
    where x ? 'observedAt' and x ? 'latitude' and x ? 'longitude' and x ? 'courseDegrees'
      and x ? 'speedMps' and (x->>'speedMps')::double precision >= 0.5
      and (x->>'observedAt')::timestamptz <= captured_at
      and captured_at - (x->>'observedAt')::timestamptz <= interval '5 seconds'
      and (x->>'courseDegrees')::double precision >= 0
      and (x->>'courseDegrees')::double precision < 360
    order by x->>'observedAt', x->>'latitude', x->>'longitude'
  ), aggregate_direction as (
    select count(*)::integer n,
      sum(sin(radians(course_degrees))) sin_total,
      sum(cos(radians(course_degrees))) cos_total
    from unique_samples
  ), endpoints as (
    select
      (array_agg(latitude order by observed_at))[1] first_latitude,
      (array_agg(longitude order by observed_at))[1] first_longitude,
      (array_agg(latitude order by observed_at desc))[1] last_latitude,
      (array_agg(longitude order by observed_at desc))[1] last_longitude
    from unique_samples
  )
  select a.n,a.sin_total,a.cos_total,e.first_latitude,e.first_longitude,e.last_latitude,e.last_longitude
  into sample_count,sum_sin,sum_cos,first_lat,first_lon,last_lat,last_lon
  from aggregate_direction a cross join endpoints e;

  if sample_count < 3 then return null; end if;
  resultant := sqrt(sum_sin*sum_sin + sum_cos*sum_cos) / sample_count;
  if resultant < minimum_agreement then return null; end if;
  heading_used := degrees(atan2(sum_sin, sum_cos));
  if heading_used < 0 then heading_used := heading_used + 360.0; end if;

  displacement_m := sqrt(
    power((last_lat-first_lat)*111320.0,2) +
    power((last_lon-first_lon)*111320.0*cos(radians((first_lat+last_lat)/2.0)),2)
  );
  if displacement_m < 1.0 then return null; end if;
  displacement_heading := degrees(atan2(
    (last_lon-first_lon)*cos(radians((first_lat+last_lat)/2.0)),
    last_lat-first_lat
  ));
  if displacement_heading < 0 then displacement_heading := displacement_heading + 360.0; end if;
  heading_delta := abs(displacement_heading-heading_used);
  heading_delta := least(heading_delta,360.0-heading_delta);
  if heading_delta > 60.0 then return null; end if;

  return jsonb_build_object(
    'heading', heading_used,
    'agreement', resultant,
    'sample_count', sample_count,
    'displacement_m', displacement_m
  );
exception when others then
  return null;
end $$;

create or replace function public.resolve_pin_row_geometry(
  rows jsonb, polygon jsonb, paddock_id uuid, lat double precision, lon double precision,
  accuracy_m double precision, heading double precision, heading_observed_at timestamptz,
  captured_at timestamptz, pressed_side text, aisle_lock jsonb, observations jsonb, row_width double precision)
returns jsonb language plpgsql immutable as $$
declare
  pair record; r jsonb; o jsonb; s jsonb; e jsonb;
  first_row jsonb; second_row jsonb; selected_pair_first jsonb; selected_pair_second jsonb;
  selected_aisle numeric; lock_aisle numeric; lock_is_valid boolean:=false;
  lat0 double precision:=radians(lat); heading_used double precision:=heading; course_direction jsonb;
  x1 double precision; y1 double precision; x2 double precision; y2 double precision; dx double precision; dy double precision; len2 double precision;
  t double precision; px double precision; py double precision; d1 double precision; d2 double precision; width double precision;
  first_px double precision; first_py double precision; second_px double precision; second_py double precision;
  support_count integer; candidate_count integer:=0;
  first_projection jsonb; second_projection jsonb; projection jsonb; side_label text; cross_side double precision;
begin
  if pressed_side not in ('Left','Right') or jsonb_typeof(rows)<>'array' or jsonb_typeof(observations)<>'array'
     or accuracy_m is null or accuracy_m<0 then return null; end if;

  if heading_used is not null and
     (heading_observed_at is null or captured_at-heading_observed_at not between interval '0 seconds' and interval '5 seconds') then
    heading_used:=null;
  end if;
  if heading_used is null then
    course_direction:=public.pin_capture_course_direction(observations,captured_at,0.70);
    heading_used:=(course_direction->>'heading')::double precision;
  end if;
  if heading_used is null then return null; end if;

  if aisle_lock is not null then
    begin
      lock_is_valid := (aisle_lock->>'paddockId')::uuid=paddock_id
        and (aisle_lock->>'supportingObservations')::integer>=3
        and captured_at-(aisle_lock->>'confirmedAt')::timestamptz between interval '0 seconds' and interval '20 seconds';
      if lock_is_valid then lock_aisle:=(aisle_lock->>'aisleNumber')::numeric; end if;
    exception when others then lock_is_valid:=false; lock_aisle:=null; end;
  end if;

  for pair in
    with ordered as (
      select value r,row_number() over(order by (value->>'number')::numeric) n
      from jsonb_array_elements(rows)
    )
    select a.r first_value,b.r second_value,
      ((a.r->>'number')::numeric+(b.r->>'number')::numeric)/2 aisle_number
    from ordered a join ordered b on b.n=a.n+1
  loop
    if lock_is_valid and abs(pair.aisle_number-lock_aisle)>=0.01 then continue; end if;
    first_row:=pair.first_value; second_row:=pair.second_value; support_count:=0;

    for o in
      select sample
      from (
        select distinct on (value->>'latitude',value->>'longitude') value sample
        from jsonb_array_elements(observations)
        where value ? 'observedAt' and value ? 'latitude' and value ? 'longitude'
        order by value->>'latitude',value->>'longitude',(value->>'observedAt')::timestamptz desc
      ) unique_observations
      order by sample->>'observedAt' desc limit 16
    loop
      if (o->>'observedAt')::timestamptz>captured_at
         or captured_at-(o->>'observedAt')::timestamptz>interval '20 seconds'
         or not public.pin_point_in_polygon((o->>'latitude')::double precision,(o->>'longitude')::double precision,polygon)
         or not (o ? 'horizontalAccuracyM') then continue; end if;
      d1:=null; d2:=null; first_px:=null; first_py:=null; second_px:=null; second_py:=null;
      for r in select value from jsonb_array_elements(jsonb_build_array(first_row,second_row)) loop
        s:=coalesce(r->'startPoint',r->'start_point'); e:=coalesce(r->'endPoint',r->'end_point');
        x1:=(coalesce((s->>'longitude')::double precision,(s->>'lng')::double precision)-(o->>'longitude')::double precision)*111320*cos(radians((o->>'latitude')::double precision));
        y1:=(coalesce((s->>'latitude')::double precision,(s->>'lat')::double precision)-(o->>'latitude')::double precision)*111320;
        x2:=(coalesce((e->>'longitude')::double precision,(e->>'lng')::double precision)-(o->>'longitude')::double precision)*111320*cos(radians((o->>'latitude')::double precision));
        y2:=(coalesce((e->>'latitude')::double precision,(e->>'lat')::double precision)-(o->>'latitude')::double precision)*111320;
        dx:=x2-x1; dy:=y2-y1; len2:=dx*dx+dy*dy; if len2<0.01 then continue; end if;
        t:=-(x1*dx+y1*dy)/len2; if t<0 or t>1 then continue; end if;
        px:=x1+t*dx; py:=y1+t*dy;
        if d1 is null then d1:=sqrt(px*px+py*py); first_px:=px; first_py:=py;
        else d2:=sqrt(px*px+py*py); second_px:=px; second_py:=py; end if;
      end loop;
      if d1 is not null and d2 is not null then
        width:=d1+d2;
        if width between 1.5 and coalesce(nullif(row_width,0)*2.5,12)
           and first_px*second_px+first_py*second_py<=0
           and (o->>'horizontalAccuracyM')::double precision>=0
           and (o->>'horizontalAccuracyM')::double precision<least(d1,d2) then
          support_count:=support_count+1;
        end if;
      end if;
    end loop;

    if support_count>=3 then
      candidate_count:=candidate_count+1;
      selected_pair_first:=first_row; selected_pair_second:=second_row; selected_aisle:=pair.aisle_number;
    end if;
  end loop;

  if candidate_count<>1 then return null; end if;
  first_projection:=null; second_projection:=null;
  for r in select value from jsonb_array_elements(jsonb_build_array(selected_pair_first,selected_pair_second)) loop
    s:=coalesce(r->'startPoint',r->'start_point'); e:=coalesce(r->'endPoint',r->'end_point');
    x1:=(coalesce((s->>'longitude')::double precision,(s->>'lng')::double precision)-lon)*111320*cos(lat0);
    y1:=(coalesce((s->>'latitude')::double precision,(s->>'lat')::double precision)-lat)*111320;
    x2:=(coalesce((e->>'longitude')::double precision,(e->>'lng')::double precision)-lon)*111320*cos(lat0);
    y2:=(coalesce((e->>'latitude')::double precision,(e->>'lat')::double precision)-lat)*111320;
    dx:=x2-x1; dy:=y2-y1; len2:=dx*dx+dy*dy; if len2<0.01 then return null; end if;
    t:=-(x1*dx+y1*dy)/len2; if t<0 or t>1 then return null; end if;
    px:=x1+t*dx; py:=y1+t*dy;
    if sqrt(px*px+py*py)<=accuracy_m then return null; end if;
    cross_side:=sin(radians(heading_used))*py-cos(radians(heading_used))*px;
    side_label:=case when cross_side>=0 then 'Left' else 'Right' end;
    projection:=jsonb_build_object('row',(r->>'number')::numeric,'snapped_latitude',lat+py/111320,'snapped_longitude',lon+px/(111320*cos(lat0)),'along_m',t*sqrt(len2));
    if side_label=pressed_side then first_projection:=projection; else second_projection:=projection; end if;
  end loop;
  if first_projection is null or second_projection is null then return null; end if;
  return first_projection || jsonb_build_object('driving_row',selected_aisle,'pin_side',pressed_side,'support_count',support_count,'heading_used',heading_used);
exception when others then return null;
end $$;

create or replace function public.confirm_saved_pin_location_v2(
  p_operation_id uuid,p_pin_id uuid,p_evidence_revision integer,p_expected_sync_version integer,p_paddock_id uuid,
  p_driving_row numeric,p_pin_row numeric,p_pin_side text,p_snapped_latitude double precision,p_snapped_longitude double precision,p_along_row_distance_m numeric)
returns text language plpgsql security definer set search_path=public as $$
declare
  p public.pins%rowtype; e public.pin_capture_evidence%rowtype; g public.pin_location_geometry_history%rowtype;
  before_row jsonb; after_row jsonb; resolved jsonb; v_hash text; existing_hash text; existing_outcome text; v_outcome text;
begin
  if p_expected_sync_version is null then return 'conflict_missing_expected_revision'; end if;
  v_hash:=encode(extensions.digest(concat_ws('|',p_pin_id,p_evidence_revision,p_expected_sync_version,p_paddock_id,p_driving_row,p_pin_row,p_pin_side,p_snapped_latitude,p_snapped_longitude,p_along_row_distance_m),'sha256'),'hex');
  select operations.payload_hash, operations.outcome
  into existing_hash, existing_outcome
  from public.pin_location_confirmation_operations as operations
  where operations.operation_id = p_operation_id;
  if found then
    if existing_hash<>v_hash then return 'conflict_operation_payload'; end if;
    return existing_outcome;
  end if;

  select * into p from public.pins where id=p_pin_id for update;
  if not found or p.deleted_at is not null then return 'conflict_pin_missing'; end if;
  if not public.is_vineyard_member(p.vineyard_id) then return 'conflict_forbidden'; end if;
  select * into e from public.pin_capture_evidence where pin_id=p.id and evidence_revision=p_evidence_revision and vineyard_id=p.vineyard_id;
  if not found then return 'conflict_evidence_missing'; end if;

  if p.sync_version<>p_expected_sync_version then v_outcome:='conflict_newer_edit';
  elsif p.location_confirmation_revision is not null and p.location_confirmation_revision>=p_evidence_revision then v_outcome:='conflict_newer_edit';
  elsif p.driving_row_number is not null or p.pin_row_number is not null or p.pin_side is not null or p.snapped_to_row then v_outcome:='conflict_current_placement';
  else
    select * into g from public.pin_location_geometry_history h
    where h.paddock_id=p_paddock_id and h.vineyard_id=p.vineyard_id
      and h.valid_from<=e.captured_at and (h.valid_to is null or h.valid_to>e.captured_at)
      and public.pin_point_in_polygon(e.raw_latitude,e.raw_longitude,h.polygon_points)
    order by h.valid_from desc limit 1;
    if not found or (e.geometry_hash is not null and e.geometry_hash<>g.geometry_hash) then v_outcome:='conflict_candidate_invalid';
    else
      resolved:=public.resolve_pin_row_geometry(g.rows,g.polygon_points,g.paddock_id,e.raw_latitude,e.raw_longitude,e.horizontal_accuracy_m,e.heading_degrees,e.heading_observed_at,e.captured_at,e.pressed_side,e.aisle_lock,e.observations,g.row_width);
      if resolved is null
         or (resolved->>'driving_row')::numeric is distinct from p_driving_row
         or (resolved->>'row')::numeric is distinct from p_pin_row
         or resolved->>'pin_side' is distinct from p_pin_side
         or abs((resolved->>'snapped_latitude')::double precision-p_snapped_latitude)>0.0000001
         or abs((resolved->>'snapped_longitude')::double precision-p_snapped_longitude)>0.0000001
         or abs((resolved->>'along_m')::numeric-p_along_row_distance_m)>0.05 then v_outcome:='conflict_candidate_invalid';
      else v_outcome:='confirmed'; end if;
    end if;
  end if;

  if v_outcome<>'confirmed' then
    insert into public.pin_location_confirmation_operations(operation_id,pin_id,evidence_revision,payload_hash,outcome)
    values(p_operation_id,p_pin_id,p_evidence_revision,v_hash,v_outcome);
    return v_outcome;
  end if;

  before_row:=public.pin_location_placement_json(p);
  update public.pins set paddock_id=p_paddock_id,driving_row_number=p_driving_row,pin_row_number=p_pin_row,pin_side=p_pin_side,
    snapped_latitude=p_snapped_latitude,snapped_longitude=p_snapped_longitude,along_row_distance_m=p_along_row_distance_m,snapped_to_row=true,
    location_confirmation_revision=p_evidence_revision,location_confirmed_at=now(),location_confirmed_by=auth.uid(),
    location_enrichment_status='user_confirmed',location_resolver_version='user-confirmation-v3',sync_version=sync_version+1
  where id=p_pin_id and sync_version=p_expected_sync_version returning * into p;
  if not found then
    v_outcome:='conflict_newer_edit';
    insert into public.pin_location_confirmation_operations(operation_id,pin_id,evidence_revision,payload_hash,outcome)
    values(p_operation_id,p_pin_id,p_evidence_revision,v_hash,v_outcome);
    return v_outcome;
  end if;
  after_row:=public.pin_location_placement_json(p);
  insert into public.pin_location_confirmation_operations(operation_id,pin_id,evidence_revision,payload_hash,outcome)
  values(p_operation_id,p_pin_id,p_evidence_revision,v_hash,'confirmed');
  insert into public.pin_location_enrichment_audit(pin_id,evidence_revision,resolver_version,outcome,before_placement,after_placement,detail)
  values(p_pin_id,p_evidence_revision,'user-confirmation-v3','user_confirmed',before_row,after_row,jsonb_build_object('operation_id',p_operation_id,'expected_sync_version',p_expected_sync_version));
  return 'confirmed';
end $$;

revoke all on function public.pin_capture_course_direction(jsonb,timestamptz,double precision) from public,anon,authenticated;
revoke all on function public.resolve_pin_row_geometry(jsonb,jsonb,uuid,double precision,double precision,double precision,double precision,timestamptz,timestamptz,text,jsonb,jsonb,double precision) from public,anon,authenticated;
revoke all on function public.confirm_saved_pin_location_v2(uuid,uuid,integer,integer,uuid,numeric,numeric,text,double precision,double precision,numeric) from public,anon;
grant execute on function public.confirm_saved_pin_location_v2(uuid,uuid,integer,integer,uuid,numeric,numeric,text,double precision,double precision,numeric) to authenticated;

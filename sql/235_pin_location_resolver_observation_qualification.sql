-- 235: forward-only correction for deployed pin resolver 232.
-- Preserves frozen evidence and confirmation behavior; performs no data rewrite.

create or replace function public.resolve_pin_row_geometry(
  rows jsonb, polygon jsonb, paddock_id uuid, lat double precision, lon double precision,
  accuracy_m double precision, heading double precision, heading_observed_at timestamptz,
  captured_at timestamptz, pressed_side text, aisle_lock jsonb, observations jsonb, row_width double precision)
returns jsonb language plpgsql immutable as $$
declare
  pair record; r jsonb; o jsonb; s jsonb; e jsonb;
  first_row jsonb; second_row jsonb; selected_pair_first jsonb; selected_pair_second jsonb;
  selected_aisle numeric; lock_aisle numeric; lock_metadata_valid boolean:=false; lock_supported boolean:=false;
  lat0 double precision:=radians(lat); heading_used double precision:=heading; course_direction jsonb;
  x1 double precision; y1 double precision; x2 double precision; y2 double precision; dx double precision; dy double precision; len2 double precision;
  t double precision; px double precision; py double precision; d1 double precision; d2 double precision; width double precision;
  first_px double precision; first_py double precision; second_px double precision; second_py double precision;
  support_count integer; selected_support_count integer:=0; candidate_count integer:=0; selected_width double precision:=0;
  first_projection jsonb; second_projection jsonb; projection jsonb; side_label text; cross_side double precision;
begin
  if pressed_side not in ('Left','Right') or jsonb_typeof(rows)<>'array' or jsonb_typeof(observations)<>'array'
     or accuracy_m is null or accuracy_m<0 then return null; end if;

  -- observedAt is the identity emitted by both mobile capture formats. Exact replay
  -- copies collapse to one identity; contradictory payloads for one identity reject
  -- the evidence rather than choosing one copy.
  if exists (
    select 1
    from jsonb_array_elements(observations) identity_sample
    where identity_sample ? 'observedAt'
    group by (identity_sample->>'observedAt')::timestamptz
    having count(distinct identity_sample)>1
  ) then return null; end if;

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
      lock_metadata_valid := (aisle_lock->>'paddockId')::uuid=paddock_id
        and (aisle_lock->>'supportingObservations')::integer>=3
        and captured_at-(aisle_lock->>'confirmedAt')::timestamptz between interval '0 seconds' and interval '20 seconds';
      if lock_metadata_valid then lock_aisle:=(aisle_lock->>'aisleNumber')::numeric; end if;
    exception when others then lock_metadata_valid:=false; lock_aisle:=null; end;
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
    first_row:=pair.first_value; second_row:=pair.second_value; support_count:=0;

    for o in
      select identity_sample
      from (
        select distinct on ((value->>'observedAt')::timestamptz) value identity_sample
        from jsonb_array_elements(observations)
        where value ? 'observedAt' and value ? 'latitude' and value ? 'longitude' and value ? 'horizontalAccuracyM'
          and (value->>'observedAt')::timestamptz<=captured_at
          and captured_at-(value->>'observedAt')::timestamptz<=interval '20 seconds'
          and (value->>'horizontalAccuracyM')::double precision>=0
        order by (value->>'observedAt')::timestamptz
      ) qualified_identities
      order by (identity_sample->>'observedAt')::timestamptz desc limit 16
    loop
      if not public.pin_point_in_polygon((o->>'latitude')::double precision,(o->>'longitude')::double precision,polygon) then continue; end if;
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
           and (o->>'horizontalAccuracyM')::double precision<=width
           and first_px*second_px+first_py*second_py<=0 then
          support_count:=support_count+1;
        end if;
      end if;
    end loop;

    if support_count>=3 then
      candidate_count:=candidate_count+1;
      selected_pair_first:=first_row; selected_pair_second:=second_row; selected_aisle:=pair.aisle_number; selected_support_count:=support_count;
      if lock_metadata_valid and abs(pair.aisle_number-lock_aisle)<0.01 then lock_supported:=true; end if;
    end if;
  end loop;

  -- A lock is supporting evidence only after the retained observation history
  -- independently supports the same aisle. It never breaks geometric ambiguity.
  if candidate_count<>1 or (lock_metadata_valid and not lock_supported) then return null; end if;
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
    selected_width:=selected_width+sqrt(px*px+py*py);
    cross_side:=sin(radians(heading_used))*py-cos(radians(heading_used))*px;
    side_label:=case when cross_side>=0 then 'Left' else 'Right' end;
    projection:=jsonb_build_object('row',(r->>'number')::numeric,'snapped_latitude',lat+py/111320,'snapped_longitude',lon+px/(111320*cos(lat0)),'along_m',t*sqrt(len2));
    if side_label=pressed_side then first_projection:=projection; else second_projection:=projection; end if;
  end loop;
  if first_projection is null or second_projection is null or accuracy_m>selected_width then return null; end if;
  return first_projection || jsonb_build_object('driving_row',selected_aisle,'pin_side',pressed_side,'support_count',selected_support_count,'heading_used',heading_used);
exception when others then return null;
end $$;

revoke all on function public.resolve_pin_row_geometry(jsonb,jsonb,uuid,double precision,double precision,double precision,double precision,timestamptz,timestamptz,text,jsonb,jsonb,double precision) from public,anon,authenticated;

-- Prompt 4E — guarded Estellar Estate exact block-link repair APPLY (1 pins)
-- REVIEW AND RUN MANUALLY. Prepared only; never executed by Rork.
-- Source SHA-256: 548e8d59344a72c894d65d1a3600df33f5a0e998272c3b578e0ce161037cfcb4
-- Current containment is review evidence, not proof of historical accuracy.
begin transaction isolation level serializable;

create table if not exists public.pin_block_link_repair_audit (
  run_id uuid not null, pin_id uuid not null, vineyard_id uuid not null,
  target_paddock_id uuid not null, repair_basis text not null,
  status text not null check (status in ('applied', 'rolled_back')),
  before_row jsonb not null, after_row jsonb not null,
  applied_at timestamptz not null default clock_timestamp(),
  rollback_after_row jsonb null, rolled_back_at timestamptz null,
  primary key (run_id, pin_id)
);
alter table public.pin_block_link_repair_audit enable row level security;
revoke all on table public.pin_block_link_repair_audit from anon, authenticated;

do $repair$
declare
  v_run_id constant uuid := '514aaaa4-7abe-411a-80c1-e6f9f4e5f076';
  v_vineyard_id constant uuid := '00bb9a18-28da-4ba7-9136-b2c5a1b56fb5';
  v_vineyard_name constant text := 'Estellar Estate';
  v_expected_count constant integer := 1;
  v_source_sha constant text := '548e8d59344a72c894d65d1a3600df33f5a0e998272c3b578e0ce161037cfcb4';
  v_expected constant jsonb := $expected$[{"pin_id":"eeb37c41-592a-4a1e-a3f7-efb57374cd04","proposed_block_id":"2fb055a3-76e6-4ec4-ae81-c1fa9fcdc1ae","proposed_block_name":"G1 Pinot Noir","pin_type":"Irrigation","pin_mode":"Repairs","completion_state":"active","pin_capture_time":"2026-09-08 02:03:19.512+00","stored_latitude":-37.6116082059341,"stored_longitude":145.42076284519,"nearest_current_boundary_metres":"3.09"}]$expected$::jsonb;
  v_candidate record;
  v_pin public.pins%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_audit_count integer;
  v_locked_count integer;
  v_match_count integer;
  v_changed_count integer := 0;
  v_target_is_match boolean;
  v_boundary_metres double precision;
begin
  perform pg_advisory_xact_lock(hashtextextended(v_run_id::text, 0));
  lock table public.paddocks in share mode;
  lock table public.pin_row_segments in share mode;

  if jsonb_array_length(v_expected) <> v_expected_count
     or (select count(distinct e.pin_id) from jsonb_to_recordset(v_expected) e(pin_id uuid)) <> v_expected_count then
    raise exception 'PACKAGE_DEFINITION_FAILED: expected % unique pins', v_expected_count;
  end if;

  select count(*)::integer into v_audit_count
  from public.pin_block_link_repair_audit where run_id = v_run_id;
  if v_audit_count > 0 then
    if v_audit_count = v_expected_count and not exists (
      select 1
      from jsonb_to_recordset(v_expected) e(pin_id uuid, proposed_block_id uuid) 
      left join public.pin_block_link_repair_audit a on a.run_id = v_run_id and a.pin_id = e.pin_id
      left join public.pins p on p.id = e.pin_id
      where a.pin_id is null or a.status <> 'applied' or a.vineyard_id <> v_vineyard_id
         or a.target_paddock_id <> e.proposed_block_id or (a.before_row->>'paddock_id') is not null
         or to_jsonb(p) is distinct from a.after_row
         or (a.after_row - array['paddock_id','updated_at','sync_version']::text[])
            is distinct from (a.before_row - array['paddock_id','updated_at','sync_version']::text[])
         or (a.after_row->>'sync_version')::integer <> (a.before_row->>'sync_version')::integer + 1
    ) then
      raise notice 'Run % is already applied exactly; no rows changed.', v_run_id;
      return;
    end if;
    raise exception 'RUN_ID_STATE_CONFLICT: existing run is not the exact applied post-state';
  end if;

  if not exists (select 1 from public.vineyards where id = v_vineyard_id and name = v_vineyard_name) then
    raise exception 'VINEYARD_PRECONDITION_FAILED: vineyard identity or name changed';
  end if;

  -- Original preview reported zero excluded polygons. Any now-invalid active block
  -- is an evidence change and aborts this vineyard batch.
  if exists (
    select 1 from public.paddocks pd
    where pd.vineyard_id = v_vineyard_id and pd.deleted_at is null
      and case
        when pd.polygon_points is null then true
        when jsonb_typeof(pd.polygon_points) <> 'array' then true
        when jsonb_array_length(pd.polygon_points) < 3 then true
        when exists (
          select 1 from jsonb_array_elements(pd.polygon_points) vertex(value)
          where not (case
            when jsonb_typeof(vertex.value->'latitude') = 'number'
             and jsonb_typeof(vertex.value->'longitude') = 'number'
              then (vertex.value->>'latitude')::numeric between -90 and 90
               and (vertex.value->>'longitude')::numeric between -180 and 180
            else false end)
        ) then true
        else false
      end
  ) then raise exception 'GEOMETRY_INVENTORY_CHANGED: active vineyard geometry is now missing or malformed'; end if;

  -- Lock the exact pin set deterministically; no other pin can enter this package.
  perform p.id from public.pins p
  join jsonb_to_recordset(v_expected) e(pin_id uuid) on e.pin_id = p.id
  order by p.id for update of p;
  get diagnostics v_locked_count = row_count;
  if v_locked_count <> v_expected_count then
    raise exception 'PIN_SET_PRECONDITION_FAILED: expected %, locked %', v_expected_count, v_locked_count;
  end if;

  for v_candidate in
    select * from jsonb_to_recordset(v_expected) e(
      pin_id uuid, proposed_block_id uuid, proposed_block_name text, pin_type text,
      pin_mode text, completion_state text, pin_capture_time timestamptz,
      stored_latitude double precision, stored_longitude double precision,
      nearest_current_boundary_metres numeric
    ) order by pin_id
  loop
    if not exists (
      select 1 from public.paddocks pd where pd.id = v_candidate.proposed_block_id
      and pd.vineyard_id = v_vineyard_id and pd.deleted_at is null
      and pd.name = v_candidate.proposed_block_name
    ) then raise exception 'TARGET_BLOCK_PRECONDITION_FAILED: target % changed', v_candidate.proposed_block_id; end if;

    select * into strict v_pin from public.pins where id = v_candidate.pin_id;
    if v_pin.vineyard_id <> v_vineyard_id or v_pin.deleted_at is not null
       or v_pin.paddock_id is not null or v_pin.sync_version is null
       or v_pin.button_name is distinct from v_candidate.pin_type
       or v_pin.mode is distinct from v_candidate.pin_mode
       or v_pin.is_completed is distinct from (v_candidate.completion_state = 'completed')
       or v_pin.created_at is distinct from v_candidate.pin_capture_time
       -- JSON/float8 round-tripping can move a coordinate by a few machine ULPs.
       -- 1e-12 degrees is sub-micrometre and rejects any material coordinate edit.
       or v_pin.latitude is null
       or abs(v_pin.latitude - v_candidate.stored_latitude) > 1e-12
       or v_pin.longitude is null
       or abs(v_pin.longitude - v_candidate.stored_longitude) > 1e-12
       or v_pin.snapped_latitude is not null or v_pin.snapped_longitude is not null
       or v_pin.snapped_to_row is distinct from false or v_pin.location_scope is not null
       or exists (select 1 from public.pin_row_segments s where s.pin_id = v_pin.id) then
      raise exception 'PIN_EVIDENCE_CHANGED: pin % no longer matches the reviewed unassigned, non-deleted, non-manual evidence', v_pin.id;
    end if;

    with valid_blocks as materialized (
      select pd.id, pd.polygon_points, jsonb_array_length(pd.polygon_points) vertex_count,
        (select avg((v.value->>'latitude')::double precision) from jsonb_array_elements(pd.polygon_points) v(value)) centroid_latitude
      from public.paddocks pd where pd.vineyard_id = v_vineyard_id and pd.deleted_at is null
    ), matches as (
      select id from valid_blocks where public._pin_point_in_polygon(v_pin.latitude, v_pin.longitude, polygon_points)
    ), edges as (
      select vb.centroid_latitude,
        (vb.polygon_points->i->>'latitude')::double precision a_lat,
        (vb.polygon_points->i->>'longitude')::double precision a_lon,
        (vb.polygon_points->((i+1)%vb.vertex_count)->>'latitude')::double precision b_lat,
        (vb.polygon_points->((i+1)%vb.vertex_count)->>'longitude')::double precision b_lon
      from valid_blocks vb cross join lateral generate_series(0,vb.vertex_count-1) i
    ), distances as (
      select sqrt(power(m.px-(m.ax+m.t*m.dx),2)+power(m.py-(m.ay+m.t*m.dy),2)) distance_metres
      from edges e cross join lateral (
        select v_pin.longitude*s.m_per_lon px, v_pin.latitude*111320.0 py,
          e.a_lon*s.m_per_lon ax, e.a_lat*111320.0 ay,
          (e.b_lon-e.a_lon)*s.m_per_lon dx, (e.b_lat-e.a_lat)*111320.0 dy,
          case when power((e.b_lon-e.a_lon)*s.m_per_lon,2)+power((e.b_lat-e.a_lat)*111320.0,2)=0 then 0.0
          else greatest(0.0,least(1.0,(((v_pin.longitude-e.a_lon)*s.m_per_lon)*((e.b_lon-e.a_lon)*s.m_per_lon)
            +((v_pin.latitude-e.a_lat)*111320.0)*((e.b_lat-e.a_lat)*111320.0))
            /(power((e.b_lon-e.a_lon)*s.m_per_lon,2)+power((e.b_lat-e.a_lat)*111320.0,2)))) end t
        from (select 111320.0*cos(e.centroid_latitude*pi()/180.0) m_per_lon) s
      ) m
    ) select (select count(*)::integer from matches),
      coalesce((select bool_or(id=v_candidate.proposed_block_id) from matches),false),
      (select min(distance_metres) from distances)
    into v_match_count,v_target_is_match,v_boundary_metres;

    if v_match_count <> 1 or not v_target_is_match then
      raise exception 'CONTAINMENT_PRECONDITION_FAILED: pin % candidates %, target_match %', v_pin.id,v_match_count,v_target_is_match;
    end if;
    -- Keep the established >3 m rule. The 11 values below 5 m remain eligible,
    -- but are visibly highlighted in the separate review list.
    if v_boundary_metres is null or v_boundary_metres <= 3.0 then
      raise exception 'BOUNDARY_PRECONDITION_FAILED: pin % boundary % m',v_pin.id,v_boundary_metres;
    end if;

    v_before := to_jsonb(v_pin);
    insert into public.pin_block_link_repair_audit(run_id,pin_id,vineyard_id,target_paddock_id,repair_basis,status,before_row,after_row)
    values(v_run_id,v_pin.id,v_vineyard_id,v_candidate.proposed_block_id,
      'Jonathan-reviewed exact Prompt 4E mapping; source_sha256='||v_source_sha||'; unique current same-vineyard containment; >3m current boundary; no manual placement evidence; historical accuracy not proven',
      'applied',v_before,v_before);

    update public.pins p set paddock_id=v_candidate.proposed_block_id,sync_version=p.sync_version+1
    where p.id=v_pin.id and p.vineyard_id=v_vineyard_id and p.paddock_id is null
      and p.deleted_at is null and to_jsonb(p)=v_before returning to_jsonb(p) into v_after;
    if v_after is null then raise exception 'CONCURRENT_PIN_CHANGE: pin % changed',v_pin.id; end if;
    if (v_after-array['paddock_id','updated_at','sync_version']::text[])
       is distinct from (v_before-array['paddock_id','updated_at','sync_version']::text[])
       or (v_after->>'paddock_id')::uuid <> v_candidate.proposed_block_id
       or (v_after->>'sync_version')::integer <> (v_before->>'sync_version')::integer+1 then
      raise exception 'AUTHORIZED_FIELD_GUARD_FAILED: pin %',v_pin.id;
    end if;
    update public.pin_block_link_repair_audit set after_row=v_after
    where run_id=v_run_id and pin_id=v_pin.id and after_row=v_before;
    get diagnostics v_locked_count=row_count;
    if v_locked_count<>1 then raise exception 'AUDIT_FINALIZATION_FAILED: pin %',v_pin.id; end if;
    v_changed_count:=v_changed_count+1;
  end loop;
  if v_changed_count<>v_expected_count then raise exception 'EXPECTED_ROW_COUNT_FAILED: expected %, changed %',v_expected_count,v_changed_count; end if;
end;$repair$;
commit;
select run_id,status,count(*)::integer audited_pin_count,min(applied_at) first_applied_at,max(applied_at) last_applied_at
from public.pin_block_link_repair_audit where run_id='514aaaa4-7abe-411a-80c1-e6f9f4e5f076'::uuid group by run_id,status;

-- Prompt 4C — guarded Stockmans Ridge three-pin block-link repair (APPLY)
-- REVIEW AND RUN MANUALLY. This file has not been executed by Rork.
--
-- Historical accuracy is not claimed. The repair is supported only by the
-- reviewed current-polygon evidence. The transaction changes pins.paddock_id,
-- increments the existing pins.sync_version marker, and lets the existing
-- pins_set_updated_at trigger set updated_at from the database clock.
-- client_updated_at is device-authored and is deliberately not changed.
-- updated_by is deliberately preserved because an SQL-editor session may not
-- have an auth.uid(); the durable run audit identifies this repair instead.

begin transaction isolation level serializable;

-- Dedicated durable audit: one immutable before/after pair per run and pin,
-- plus a rollback snapshot if the separately supplied rollback is later used.
create table if not exists public.pin_block_link_repair_audit (
  run_id uuid not null,
  pin_id uuid not null,
  vineyard_id uuid not null,
  target_paddock_id uuid not null,
  repair_basis text not null,
  status text not null check (status in ('applied', 'rolled_back')),
  before_row jsonb not null,
  after_row jsonb not null,
  applied_at timestamptz not null default clock_timestamp(),
  rollback_after_row jsonb null,
  rolled_back_at timestamptz null,
  primary key (run_id, pin_id)
);

alter table public.pin_block_link_repair_audit enable row level security;
revoke all on table public.pin_block_link_repair_audit from anon, authenticated;

comment on table public.pin_block_link_repair_audit is
  'Restricted durable before/after evidence for explicitly reviewed pin block-link repairs and guarded rollbacks.';

do $repair$
declare
  v_run_id constant uuid := 'a778659b-1a13-4e56-bc1b-f1a340bcb5da';
  v_vineyard_id constant uuid := 'fe952afe-437f-4be7-8cbf-fdd8e630411c';
  v_target_id constant uuid := '53128d1c-d745-4d99-8194-52e0ba08767b';
  v_expected_ids constant uuid[] := array[
    '2e4f7cc6-4876-47d5-b280-30d1ea1259ac'::uuid,
    '2c981eca-2981-435a-ac2a-a10aaaabf0ee'::uuid,
    'b46d0087-76ec-443b-936f-f010c8baffe3'::uuid
  ];
  v_pin public.pins%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_existing_audit_count integer;
  v_locked_count integer;
  v_match_count integer;
  v_target_is_match boolean;
  v_nearest_boundary_metres double precision;
  v_changed_count integer := 0;
begin
  -- Serialize this exact package's apply/rollback/retry operations. Together
  -- with SERIALIZABLE predicate tracking, this also closes candidate-set races.
  perform pg_advisory_xact_lock(hashtextextended(v_run_id::text, 0));
  -- SHARE blocks concurrent INSERT/UPDATE/DELETE of any paddock until commit,
  -- so no new, moved, deleted or undeleted polygon can change the candidate set.
  lock table public.paddocks in share mode;

  -- A repeated run ID is a no-op only when all three audited post-images are
  -- still exact. Any partial audit, rollback, or subsequent edit aborts.
  select count(*)::integer
    into v_existing_audit_count
    from public.pin_block_link_repair_audit
   where run_id = v_run_id;

  if v_existing_audit_count > 0 then
    if v_existing_audit_count = 3
       and not exists (
         select 1
           from public.pin_block_link_repair_audit a
           left join public.pins p on p.id = a.pin_id
          where a.run_id = v_run_id
            and (
              a.status <> 'applied'
              or a.vineyard_id <> v_vineyard_id
              or a.target_paddock_id <> v_target_id
              or a.pin_id <> all(v_expected_ids)
              or (a.before_row->>'paddock_id') is not null
              or (a.after_row->>'paddock_id')::uuid <> v_target_id
              or (a.before_row->>'sync_version') is null
              or (a.after_row->>'sync_version') is null
              or (a.after_row->>'sync_version')::integer
                  <> (a.before_row->>'sync_version')::integer + 1
              or (a.after_row - array['paddock_id', 'updated_at', 'sync_version']::text[])
                  is distinct from
                 (a.before_row - array['paddock_id', 'updated_at', 'sync_version']::text[])
              or to_jsonb(p) is distinct from a.after_row
            )
       ) then
      raise notice 'Run % is already applied exactly; no rows changed.', v_run_id;
      return;
    end if;
    raise exception 'RUN_ID_STATE_CONFLICT: run % already exists but is not the exact applied post-state', v_run_id;
  end if;

  -- Lock every current block in the vineyard so the candidate set and boundary
  -- evidence cannot change between revalidation and update.
  perform pd.id
    from public.paddocks pd
   where pd.vineyard_id = v_vineyard_id
     and pd.deleted_at is null
   order by pd.id
   for share;

  -- Target must remain the named, non-deleted same-vineyard block with usable
  -- polygon geometry. The name is a guard, never a duplicated pin field.
  if not exists (
    select 1
    from (
      select
        pd.id,
        pd.vineyard_id,
        pd.name,
        pd.deleted_at,
        case
          when pd.polygon_points is null then false
          when jsonb_typeof(pd.polygon_points) <> 'array' then false
          when jsonb_array_length(pd.polygon_points) < 3 then false
          when exists (
            select 1
              from jsonb_array_elements(pd.polygon_points) vertex(value)
             where not (
               case
                 when jsonb_typeof(vertex.value->'latitude') = 'number'
                  and jsonb_typeof(vertex.value->'longitude') = 'number'
                   then (vertex.value->>'latitude')::numeric between -90::numeric and 90::numeric
                    and (vertex.value->>'longitude')::numeric between -180::numeric and 180::numeric
                 else false
               end
             )
          ) then false
          else true
        end as has_usable_geometry
      from public.paddocks pd
      where pd.id = v_target_id
    ) target
    where target.vineyard_id = v_vineyard_id
      and target.deleted_at is null
      and target.name = 'Pinot Noir'
      and target.has_usable_geometry
  ) then
    raise exception 'TARGET_BLOCK_PRECONDITION_FAILED: Pinot Noir target is missing, deleted, cross-vineyard, renamed, or has invalid geometry';
  end if;

  -- Deterministic row locks are the write-concurrency guard.
  perform p.id
    from public.pins p
   where p.id = any(v_expected_ids)
   order by p.id
   for update;
  get diagnostics v_locked_count = row_count;
  if v_locked_count <> 3 then
    raise exception 'PIN_SET_PRECONDITION_FAILED: expected 3 pin rows, locked %', v_locked_count;
  end if;

  for v_pin in
    select p.*
      from public.pins p
     where p.id = any(v_expected_ids)
     order by p.id
  loop
    -- Exact reviewed identity, type and coordinate evidence; active means both
    -- non-deleted and not completed. No snapped coordinate may have appeared.
    if v_pin.vineyard_id <> v_vineyard_id
       or v_pin.deleted_at is not null
       or v_pin.is_completed
       or v_pin.paddock_id is not null
       or v_pin.sync_version is null
       or v_pin.snapped_latitude is not null
       or v_pin.snapped_longitude is not null
       or v_pin.latitude is null
       or v_pin.longitude is null then
      raise exception 'PIN_PRECONDITION_FAILED: pin % no longer has the reviewed active/unassigned/base-only state', v_pin.id;
    end if;

    if v_pin.id = '2e4f7cc6-4876-47d5-b280-30d1ea1259ac'::uuid then
      if v_pin.button_name is distinct from 'Other'
         or v_pin.latitude is distinct from -33.2958835::double precision
         or v_pin.longitude is distinct from 148.9550808::double precision then
        raise exception 'PIN_EVIDENCE_CHANGED: pin % type or coordinates changed', v_pin.id;
      end if;
    elsif v_pin.id = '2c981eca-2981-435a-ac2a-a10aaaabf0ee'::uuid then
      if v_pin.button_name is distinct from 'Vine Issue'
         or v_pin.latitude is distinct from -33.2958835::double precision
         or v_pin.longitude is distinct from 148.9550808::double precision then
        raise exception 'PIN_EVIDENCE_CHANGED: pin % type or coordinates changed', v_pin.id;
      end if;
    elsif v_pin.id = 'b46d0087-76ec-443b-936f-f010c8baffe3'::uuid then
      if v_pin.button_name is distinct from 'Vine Issue'
         or v_pin.latitude is distinct from -33.2958747::double precision
         or v_pin.longitude is distinct from 148.9548024::double precision then
        raise exception 'PIN_EVIDENCE_CHANGED: pin % type or coordinates changed', v_pin.id;
      end if;
    else
      raise exception 'UNEXPECTED_PIN_ID: %', v_pin.id;
    end if;

    -- Re-run the preview's valid-polygon, containment and 3 m boundary logic.
    with block_inventory as materialized (
      select
        pd.id,
        pd.polygon_points,
        case
          when pd.polygon_points is null then false
          when jsonb_typeof(pd.polygon_points) <> 'array' then false
          when jsonb_array_length(pd.polygon_points) < 3 then false
          when exists (
            select 1
              from jsonb_array_elements(pd.polygon_points) vertex(value)
             where not (
               case
                 when jsonb_typeof(vertex.value->'latitude') = 'number'
                  and jsonb_typeof(vertex.value->'longitude') = 'number'
                   then (vertex.value->>'latitude')::numeric between -90::numeric and 90::numeric
                    and (vertex.value->>'longitude')::numeric between -180::numeric and 180::numeric
                 else false
               end
             )
          ) then false
          else true
        end as has_usable_geometry
      from public.paddocks pd
      where pd.vineyard_id = v_vineyard_id
        and pd.deleted_at is null
    ), valid_blocks as materialized (
      select
        bi.id,
        bi.polygon_points,
        jsonb_array_length(bi.polygon_points) as vertex_count,
        (
          select avg((vertex.value->>'latitude')::double precision)
            from jsonb_array_elements(bi.polygon_points) vertex(value)
        ) as centroid_latitude
      from block_inventory bi
      where bi.has_usable_geometry
    ), matches as (
      select vb.id
        from valid_blocks vb
       where public._pin_point_in_polygon(v_pin.latitude, v_pin.longitude, vb.polygon_points)
    ), edges as (
      select
        vb.centroid_latitude,
        (vb.polygon_points->edge_index->>'latitude')::double precision as a_lat,
        (vb.polygon_points->edge_index->>'longitude')::double precision as a_lon,
        (vb.polygon_points->((edge_index + 1) % vb.vertex_count)->>'latitude')::double precision as b_lat,
        (vb.polygon_points->((edge_index + 1) % vb.vertex_count)->>'longitude')::double precision as b_lon
      from valid_blocks vb
      cross join lateral generate_series(0, vb.vertex_count - 1) edge_index
    ), distances as (
      select sqrt(
        power(metric.px - (metric.ax + metric.t * metric.dx), 2)
        + power(metric.py - (metric.ay + metric.t * metric.dy), 2)
      ) as distance_metres
      from edges e
      cross join lateral (
        select
          v_pin.longitude * scale.m_per_lon as px,
          v_pin.latitude * 111320.0 as py,
          e.a_lon * scale.m_per_lon as ax,
          e.a_lat * 111320.0 as ay,
          (e.b_lon - e.a_lon) * scale.m_per_lon as dx,
          (e.b_lat - e.a_lat) * 111320.0 as dy,
          case
            when power((e.b_lon - e.a_lon) * scale.m_per_lon, 2)
                 + power((e.b_lat - e.a_lat) * 111320.0, 2) = 0 then 0.0
            else greatest(0.0, least(1.0,
              (
                ((v_pin.longitude - e.a_lon) * scale.m_per_lon)
                  * ((e.b_lon - e.a_lon) * scale.m_per_lon)
                + ((v_pin.latitude - e.a_lat) * 111320.0)
                  * ((e.b_lat - e.a_lat) * 111320.0)
              ) / (
                power((e.b_lon - e.a_lon) * scale.m_per_lon, 2)
                + power((e.b_lat - e.a_lat) * 111320.0, 2)
              )
            ))
          end as t
        from (
          select 111320.0 * cos(e.centroid_latitude * pi() / 180.0) as m_per_lon
        ) scale
      ) metric
    )
    select
      (select count(*)::integer from matches),
      coalesce((select bool_or(id = v_target_id) from matches), false),
      (select min(distance_metres) from distances)
    into v_match_count, v_target_is_match, v_nearest_boundary_metres;

    if v_match_count <> 1 or not v_target_is_match then
      raise exception 'CONTAINMENT_PRECONDITION_FAILED: pin % has % current candidates and target_match=%',
        v_pin.id, v_match_count, v_target_is_match;
    end if;
    if v_nearest_boundary_metres is null or v_nearest_boundary_metres <= 3.0 then
      raise exception 'BOUNDARY_PRECONDITION_FAILED: pin % nearest current boundary is % metres',
        v_pin.id, v_nearest_boundary_metres;
    end if;

    v_before := to_jsonb(v_pin);

    insert into public.pin_block_link_repair_audit (
      run_id, pin_id, vineyard_id, target_paddock_id, repair_basis,
      status, before_row, after_row
    ) values (
      v_run_id, v_pin.id, v_vineyard_id, v_target_id,
      'Jonathan-reviewed unique current-polygon containment; no boundary flag; no snapped coordinates; historical accuracy not proven',
      'applied', v_before, v_before
    );

    update public.pins p
       set paddock_id = v_target_id,
           sync_version = p.sync_version + 1
     where p.id = v_pin.id
       and p.vineyard_id = v_vineyard_id
       and p.paddock_id is null
       and p.deleted_at is null
       and not p.is_completed
       and to_jsonb(p) = v_before
     returning to_jsonb(p) into v_after;

    if v_after is null then
      raise exception 'CONCURRENT_PIN_CHANGE: pin % changed after it was locked/revalidated', v_pin.id;
    end if;

    if (v_after - array['paddock_id', 'updated_at', 'sync_version']::text[])
       is distinct from
       (v_before - array['paddock_id', 'updated_at', 'sync_version']::text[]) then
      raise exception 'BUSINESS_FIELD_GUARD_FAILED: update changed a non-authorized field on pin %', v_pin.id;
    end if;
    if (v_after->>'paddock_id')::uuid <> v_target_id
       or (v_after->>'sync_version')::integer <> (v_before->>'sync_version')::integer + 1 then
      raise exception 'SYNC_MARKER_GUARD_FAILED: pin % did not receive the exact link/version transition', v_pin.id;
    end if;

    update public.pin_block_link_repair_audit
       set after_row = v_after
     where run_id = v_run_id
       and pin_id = v_pin.id
       and after_row = v_before;
    get diagnostics v_locked_count = row_count;
    if v_locked_count <> 1 then
      raise exception 'AUDIT_FINALIZATION_FAILED: expected 1 audit row for pin %, changed %', v_pin.id, v_locked_count;
    end if;

    v_changed_count := v_changed_count + 1;
  end loop;

  if v_changed_count <> 3 then
    raise exception 'EXPECTED_ROW_COUNT_FAILED: expected 3 pin changes, changed %', v_changed_count;
  end if;
end;
$repair$;

commit;

-- Compact post-commit receipt. Run the separate verification file for the full
-- business-field comparison and joined block names.
select
  run_id,
  status,
  count(*)::integer as audited_pin_count,
  min(applied_at) as first_applied_at,
  max(applied_at) as last_applied_at
from public.pin_block_link_repair_audit
where run_id = 'a778659b-1a13-4e56-bc1b-f1a340bcb5da'::uuid
group by run_id, status;

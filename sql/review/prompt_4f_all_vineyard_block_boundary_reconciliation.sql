-- SELECT ONLY: all-vineyard block-link and current-boundary reconciliation.
-- Run once and export the complete result grid as JSON or CSV before review.
-- Includes active and completed pins; excludes soft-deleted pins.
-- Does not assign a nearest block, redraw a boundary, recover row/path/side/facing,
-- create objects, or modify any database row.
--
-- Classification precedence and labels are unchanged from Prompt 4B:
-- insufficient evidence -> overlap/boundary ambiguity -> supported assignment ->
-- conflicting assignment -> unique missing link -> outside all blocks.
--
-- IMPORTANT: `usable_current_polygon` means only that the JSON has at least three
-- in-range numeric vertices. It does not prove a physically correct boundary,
-- historical accuracy, non-self-intersection, correct winding, or complete coverage.
with
params as (
  select 3.0::double precision as boundary_review_metres
),
repair_runs(run_id, vineyard_id, vineyard_name, expected_count) as (
  values
    ('a778659b-1a13-4e56-bc1b-f1a340bcb5da'::uuid, 'fe952afe-437f-4be7-8cbf-fdd8e630411c'::uuid, 'Stockmans Ridge'::text, 3::integer),
    ('0993626f-daf3-4a6b-a5f2-95239302ac51'::uuid, 'fefcbf2e-29ab-4828-828c-c1035fddfb69'::uuid, 'Hill Park'::text, 75::integer),
    ('514aaaa4-7abe-411a-80c1-e6f9f4e5f076'::uuid, '00bb9a18-28da-4ba7-9136-b2c5a1b56fb5'::uuid, 'Estellar Estate'::text, 1::integer),
    ('891c96f1-7a54-4858-a0a1-b0865eb5de00'::uuid, '2c1d6be9-b5e4-42ec-a328-5c734ef87bf1'::uuid, 'Tamburlaine Boomey'::text, 1::integer),
    ('0aa13b8d-0ff7-48cb-92f5-91e94fc593f7'::uuid, 'a18654f6-13ed-4438-998b-7a7e1d89181a'::uuid, 'Tamburlaine Borenore'::text, 2::integer)
),
segment_stats as (
  select s.pin_id, count(*)::integer as segment_count
  from public.pin_row_segments s
  group by s.pin_id
),
scoped_pins as materialized (
  select
    p.*,
    coalesce(ss.segment_count, 0) as segment_count,
    case
      when p.location_scope = 'point' then 'intentional_manual_point'
      when p.location_scope = 'block' then 'intentional_manual_block'
      when p.location_scope = 'row' and coalesce(ss.segment_count, 0) > 0
        then 'intentional_manual_row_or_segment'
      when p.location_scope = 'row' then 'intentional_manual_row_missing_segments'
      when coalesce(ss.segment_count, 0) > 0 then 'segments_with_unknown_scope'
      else 'unknown_origin'
    end as placement_origin,
    p.latitude is not null and p.longitude is not null
      and p.latitude between -90 and 90 and p.longitude between -180 and 180
      as has_valid_base_coordinate,
    p.snapped_latitude is not null and p.snapped_longitude is not null
      and p.snapped_latitude between -90 and 90
      and p.snapped_longitude between -180 and 180
      as has_valid_snapped_coordinate
  from public.pins p
  left join segment_stats ss on ss.pin_id = p.id
  where p.deleted_at is null
),
all_blocks as materialized (
  select pd.* from public.paddocks pd
),
block_inventory as materialized (
  select
    pd.id,
    pd.vineyard_id,
    pd.name,
    pd.polygon_points,
    pd.rows,
    pd.created_at,
    pd.updated_at,
    pd.sync_version,
    case
      when pd.polygon_points is null then 'missing_polygon_points'
      when jsonb_typeof(pd.polygon_points) <> 'array' then 'polygon_points_not_array'
      when jsonb_array_length(pd.polygon_points) < 3 then 'fewer_than_three_vertices'
      when exists (
        select 1 from jsonb_array_elements(pd.polygon_points) vertex(value)
        where not (
          case
            when jsonb_typeof(vertex.value->'latitude') = 'number'
             and jsonb_typeof(vertex.value->'longitude') = 'number'
              then (vertex.value->>'latitude')::numeric between -90 and 90
               and (vertex.value->>'longitude')::numeric between -180 and 180
            else false
          end
        )
      ) then 'invalid_vertex'
      else 'usable_current_polygon'
    end as geometry_status
  from all_blocks pd
  where pd.deleted_at is null
),
valid_blocks as materialized (
  select
    bi.*,
    jsonb_array_length(bi.polygon_points) as vertex_count,
    (select avg((v.value->>'latitude')::double precision)
       from jsonb_array_elements(bi.polygon_points) v(value)) as centroid_latitude
  from block_inventory bi
  where bi.geometry_status = 'usable_current_polygon'
),
block_geometry_summary as (
  select
    vineyard_id,
    count(*)::integer as active_block_count,
    count(*) filter (where geometry_status = 'usable_current_polygon')::integer as valid_polygon_count,
    count(*) filter (where geometry_status <> 'usable_current_polygon')::integer as excluded_polygon_count,
    jsonb_agg(jsonb_build_object(
      'block_id', id, 'block_name', name, 'geometry_status', geometry_status
    ) order by name, id) filter (where geometry_status <> 'usable_current_polygon') as excluded_block_geometry
  from block_inventory
  group by vineyard_id
),
deleted_block_summary as (
  select
    vineyard_id,
    count(*)::integer as deleted_block_count,
    jsonb_agg(jsonb_build_object(
      'block_id', id, 'block_name', name, 'deleted_at', deleted_at,
      'has_polygon_points', polygon_points is not null
    ) order by name, id) as deleted_blocks
  from all_blocks
  where deleted_at is not null
  group by vineyard_id
),
base_matches as (
  select sp.id as pin_id, vb.id as block_id, vb.name as block_name
  from scoped_pins sp
  join valid_blocks vb on vb.vineyard_id = sp.vineyard_id
  where sp.has_valid_base_coordinate
    and public._pin_point_in_polygon(sp.latitude, sp.longitude, vb.polygon_points)
),
base_candidates as (
  select
    pin_id,
    count(*)::integer as match_count,
    array_agg(block_id order by block_id) as candidate_ids,
    jsonb_agg(jsonb_build_object('block_id', block_id, 'block_name', block_name)
      order by block_name, block_id) as candidates
  from base_matches
  group by pin_id
),
snapped_matches as (
  select sp.id as pin_id, vb.id as block_id, vb.name as block_name
  from scoped_pins sp
  join valid_blocks vb on vb.vineyard_id = sp.vineyard_id
  where sp.has_valid_snapped_coordinate
    and public._pin_point_in_polygon(sp.snapped_latitude, sp.snapped_longitude, vb.polygon_points)
),
snapped_candidates as (
  select
    pin_id,
    count(*)::integer as match_count,
    array_agg(block_id order by block_id) as candidate_ids,
    jsonb_agg(jsonb_build_object('block_id', block_id, 'block_name', block_name)
      order by block_name, block_id) as candidates
  from snapped_matches
  group by pin_id
),
boundary_edges as materialized (
  select
    vb.id as block_id,
    vb.vineyard_id,
    vb.centroid_latitude,
    (vb.polygon_points->i->>'latitude')::double precision as a_lat,
    (vb.polygon_points->i->>'longitude')::double precision as a_lon,
    (vb.polygon_points->((i + 1) % vb.vertex_count)->>'latitude')::double precision as b_lat,
    (vb.polygon_points->((i + 1) % vb.vertex_count)->>'longitude')::double precision as b_lon
  from valid_blocks vb
  cross join lateral generate_series(0, vb.vertex_count - 1) i
),
base_edge_distances as (
  select
    sp.id as pin_id,
    sqrt(power(m.px - (m.ax + m.t * m.dx), 2)
      + power(m.py - (m.ay + m.t * m.dy), 2)) as distance_metres
  from scoped_pins sp
  join boundary_edges be on be.vineyard_id = sp.vineyard_id
  cross join lateral (
    select
      sp.longitude * scale.m_per_lon as px,
      sp.latitude * 111320.0 as py,
      be.a_lon * scale.m_per_lon as ax,
      be.a_lat * 111320.0 as ay,
      (be.b_lon - be.a_lon) * scale.m_per_lon as dx,
      (be.b_lat - be.a_lat) * 111320.0 as dy,
      case
        when power((be.b_lon - be.a_lon) * scale.m_per_lon, 2)
           + power((be.b_lat - be.a_lat) * 111320.0, 2) = 0 then 0.0
        else greatest(0.0, least(1.0,
          (((sp.longitude - be.a_lon) * scale.m_per_lon)
            * ((be.b_lon - be.a_lon) * scale.m_per_lon)
           + ((sp.latitude - be.a_lat) * 111320.0)
            * ((be.b_lat - be.a_lat) * 111320.0))
          / (power((be.b_lon - be.a_lon) * scale.m_per_lon, 2)
            + power((be.b_lat - be.a_lat) * 111320.0, 2))))
      end as t
    from (select 111320.0 * cos(be.centroid_latitude * pi() / 180.0) as m_per_lon) scale
  ) m
  where sp.has_valid_base_coordinate
),
base_boundary_stats as (
  select pin_id, min(distance_metres) as nearest_boundary_metres
  from base_edge_distances
  group by pin_id
),
coordinate_disagreement as (
  select
    sp.id as pin_id,
    case when sp.has_valid_base_coordinate and sp.has_valid_snapped_coordinate then
      sqrt(
        power((sp.snapped_longitude - sp.longitude) * 111320.0
          * cos(((sp.latitude + sp.snapped_latitude) / 2.0) * pi() / 180.0), 2)
        + power((sp.snapped_latitude - sp.latitude) * 111320.0, 2)
      )
    end as base_to_snapped_metres
  from scoped_pins sp
),
assembled as (
  select
    sp.*,
    v.name as vineyard_name,
    v.deleted_at as vineyard_deleted_at,
    current_block.name as current_block_name,
    current_block.vineyard_id as current_block_vineyard_id,
    current_block.deleted_at as current_block_deleted_at,
    coalesce(bc.match_count, 0) as candidate_match_count,
    coalesce(bc.candidate_ids, array[]::uuid[]) as candidate_ids,
    coalesce(bc.candidates, '[]'::jsonb) as candidates,
    coalesce(sc.match_count, 0) as snapped_candidate_match_count,
    coalesce(sc.candidate_ids, array[]::uuid[]) as snapped_candidate_ids,
    coalesce(sc.candidates, '[]'::jsonb) as snapped_candidates,
    bbs.nearest_boundary_metres,
    cd.base_to_snapped_metres,
    coalesce(bgs.active_block_count, 0) as active_block_count,
    coalesce(bgs.valid_polygon_count, 0) as valid_polygon_count,
    coalesce(bgs.excluded_polygon_count, 0) as excluded_polygon_count,
    bgs.excluded_block_geometry,
    x.boundary_review_metres,
    sp.has_valid_snapped_coordinate
      and coalesce(bc.candidate_ids, array[]::uuid[])
        is distinct from coalesce(sc.candidate_ids, array[]::uuid[])
      as base_and_snapped_candidates_disagree
  from scoped_pins sp
  cross join params x
  left join public.vineyards v on v.id = sp.vineyard_id
  left join block_geometry_summary bgs on bgs.vineyard_id = sp.vineyard_id
  left join public.paddocks current_block on current_block.id = sp.paddock_id
  left join base_candidates bc on bc.pin_id = sp.id
  left join snapped_candidates sc on sc.pin_id = sp.id
  left join base_boundary_stats bbs on bbs.pin_id = sp.id
  left join coordinate_disagreement cd on cd.pin_id = sp.id
),
classified as materialized (
  select
    a.*,
    case
      when not a.has_valid_base_coordinate then 'insufficient geometry/evidence'
      when a.valid_polygon_count = 0 then 'insufficient geometry/evidence'
      when a.candidate_match_count > 1
        or a.nearest_boundary_metres <= a.boundary_review_metres
        or a.base_and_snapped_candidates_disagree
        then 'overlapping/boundary ambiguity'
      when a.paddock_id is not null
        and a.candidate_match_count = 1
        and a.paddock_id = any(a.candidate_ids)
        then 'existing assignment supported'
      when a.paddock_id is not null then 'conflicting existing assignment'
      when a.candidate_match_count = 1 then 'missing link with unique candidate'
      when a.candidate_match_count = 0 then 'outside all blocks'
      else 'insufficient geometry/evidence'
    end as classification
  from assembled a
),
vineyard_scope as (
  select id as vineyard_id, name as vineyard_name, deleted_at as vineyard_deleted_at
  from public.vineyards
  union
  select distinct p.vineyard_id, null::text, null::timestamptz
  from scoped_pins p
  where not exists (select 1 from public.vineyards v where v.id = p.vineyard_id)
),
vineyard_summary as (
  select
    vs.vineyard_id,
    coalesce(max(vs.vineyard_name), max(c.vineyard_name), '[missing vineyard row]') as vineyard_name,
    max(vs.vineyard_deleted_at) as vineyard_deleted_at,
    count(c.id)::integer as total_pin_count,
    count(c.id) filter (where not c.is_completed)::integer as active_pin_count,
    count(c.id) filter (where c.is_completed)::integer as completed_pin_count,
    count(c.id) filter (where c.classification = 'existing assignment supported')::integer as supported_assignment_count,
    count(c.id) filter (where c.classification = 'missing link with unique candidate')::integer as missing_link_unique_candidate_count,
    count(c.id) filter (where c.classification = 'outside all blocks')::integer as outside_block_pin_count,
    count(c.id) filter (where c.classification = 'overlapping/boundary ambiguity')::integer as boundary_coordinate_ambiguity_count,
    count(c.id) filter (where c.classification = 'conflicting existing assignment')::integer as conflicting_assignment_count,
    count(c.id) filter (where c.classification = 'insufficient geometry/evidence')::integer as insufficient_geometry_count,
    coalesce(max(bgs.active_block_count), 0)::integer as active_block_count,
    coalesce(max(bgs.valid_polygon_count), 0)::integer as valid_polygon_count,
    coalesce(max(bgs.excluded_polygon_count), 0)::integer as excluded_polygon_count,
    coalesce(max(dbs.deleted_block_count), 0)::integer as deleted_block_count,
    max(dbs.deleted_blocks::text)::jsonb as deleted_blocks
  from vineyard_scope vs
  left join classified c on c.vineyard_id = vs.vineyard_id
  left join block_geometry_summary bgs on bgs.vineyard_id = vs.vineyard_id
  left join deleted_block_summary dbs on dbs.vineyard_id = vs.vineyard_id
  group by vs.vineyard_id
),
assigned_block_pin_stats as (
  select
    bi.id as block_id,
    count(sp.id)::integer as assigned_pin_count,
    count(sp.id) filter (where not sp.is_completed)::integer as assigned_active_pin_count,
    count(sp.id) filter (where sp.is_completed)::integer as assigned_completed_pin_count
  from block_inventory bi
  left join scoped_pins sp on sp.paddock_id = bi.id
  group by bi.id
),
contained_block_pin_stats as (
  select bi.id as block_id, count(bm.pin_id)::integer as current_coordinate_containment_count
  from block_inventory bi
  left join base_matches bm on bm.block_id = bi.id
  group by bi.id
),
block_pin_stats as (
  select
    a.block_id,
    a.assigned_pin_count,
    a.assigned_active_pin_count,
    a.assigned_completed_pin_count,
    c.current_coordinate_containment_count
  from assigned_block_pin_stats a
  join contained_block_pin_stats c using (block_id)
),
repair_audits as materialized (
  select rr.*, a.pin_id, a.vineyard_id as audit_vineyard_id,
    a.target_paddock_id, a.status, a.before_row, a.after_row,
    a.applied_at, a.rollback_after_row, a.rolled_back_at
  from repair_runs rr
  left join public.pin_block_link_repair_audit a on a.run_id = rr.run_id
),
repair_checks as materialized (
  select
    ra.*,
    p.id as current_pin_id,
    p.vineyard_id as current_vineyard_id,
    p.paddock_id as current_block_id,
    p.deleted_at as current_pin_deleted_at,
    p.sync_version as current_sync_version,
    p.updated_at as current_updated_at,
    pd.name as approved_target_current_name,
    pd.vineyard_id as approved_target_current_vineyard_id,
    pd.deleted_at as approved_target_deleted_at,
    coalesce(
      ra.pin_id is not null
      and ra.audit_vineyard_id = rr.vineyard_id
      and ra.status = 'applied'
      and ra.rollback_after_row is null
      and ra.rolled_back_at is null
      and ra.before_row->>'paddock_id' is null
      and (ra.after_row->>'paddock_id')::uuid = ra.target_paddock_id
      and (ra.after_row->>'sync_version')::integer
        = (ra.before_row->>'sync_version')::integer + 1
      and (ra.after_row - array['paddock_id','updated_at','sync_version']::text[])
        = (ra.before_row - array['paddock_id','updated_at','sync_version']::text[]),
      false
    ) as audit_transition_valid,
    coalesce(to_jsonb(p) = ra.after_row, false) as current_matches_audited_after,
    coalesce(p.paddock_id = ra.target_paddock_id, false) as current_matches_approved_target,
    coalesce(pd.id = ra.target_paddock_id
      and pd.vineyard_id = rr.vineyard_id and pd.deleted_at is null, false)
      as approved_target_block_valid
  from repair_audits ra
  join repair_runs rr on rr.run_id = ra.run_id
  left join public.pins p on p.id = ra.pin_id
  left join public.paddocks pd on pd.id = ra.target_paddock_id
),
repair_run_summary as (
  select
    rr.*,
    count(rc.pin_id)::integer as audited_count,
    count(rc.pin_id) filter (where rc.audit_transition_valid)::integer as valid_audit_transition_count,
    count(rc.pin_id) filter (where rc.current_matches_audited_after)::integer as exact_after_image_count,
    count(rc.pin_id) filter (
      where rc.audit_transition_valid and rc.current_matches_approved_target
        and rc.approved_target_block_valid
    )::integer as current_approved_target_count,
    count(rc.pin_id) filter (
      where rc.audit_transition_valid and not rc.current_matches_audited_after
        and rc.current_matches_approved_target
    )::integer as later_edit_same_target_count,
    count(rc.pin_id) filter (
      where rc.audit_transition_valid and not rc.current_matches_approved_target
    )::integer as later_reassignment_or_missing_count
  from repair_runs rr
  left join repair_checks rc on rc.run_id = rr.run_id
  group by rr.run_id, rr.vineyard_id, rr.vineyard_name, rr.expected_count
),
output_rows as (
  select
    10 as section_order,
    vs.vineyard_name as vineyard_sort,
    vs.vineyard_id,
    null::text as item_sort,
    'vineyard_summary'::text as result_type,
    jsonb_build_object(
      'vineyard_id', vs.vineyard_id,
      'vineyard_name', vs.vineyard_name,
      'vineyard_deleted_at', vs.vineyard_deleted_at,
      'total_pin_count', vs.total_pin_count,
      'active_pin_count', vs.active_pin_count,
      'completed_pin_count', vs.completed_pin_count,
      'existing assignment supported', vs.supported_assignment_count,
      'missing link with unique candidate', vs.missing_link_unique_candidate_count,
      'outside all blocks', vs.outside_block_pin_count,
      'overlapping/boundary ambiguity', vs.boundary_coordinate_ambiguity_count,
      'conflicting existing assignment', vs.conflicting_assignment_count,
      'insufficient geometry/evidence', vs.insufficient_geometry_count,
      'classification_count_check', vs.supported_assignment_count
        + vs.missing_link_unique_candidate_count + vs.outside_block_pin_count
        + vs.boundary_coordinate_ambiguity_count + vs.conflicting_assignment_count
        + vs.insufficient_geometry_count = vs.total_pin_count,
      'active_block_count', vs.active_block_count,
      'valid_polygon_count', vs.valid_polygon_count,
      'excluded_polygon_count', vs.excluded_polygon_count,
      'deleted_block_count', vs.deleted_block_count,
      'deleted_blocks_evidence', vs.deleted_blocks,
      'zero_active_blocks_resolution_needed', case when vs.total_pin_count > 0 and vs.active_block_count = 0 then
        'Jonathan must confirm whether this vineyard should have blocks and provide authoritative block IDs, names and boundary vertices; deleted definitions are listed, but unmigrated definitions cannot be inferred from this database.'
      end,
      'baseline_comparison_note', 'Recalculated current snapshot; prior 126 ambiguities, 10 conflicts, 235 outside and 692 insufficient are context only.'
    ) as record
  from vineyard_summary vs

  union all

  select
    20,
    v.name,
    bi.vineyard_id,
    bi.name || ' ' || bi.id::text,
    'active_block_inventory',
    jsonb_build_object(
      'block_id', bi.id,
      'block_name', bi.name,
      'vineyard_id', bi.vineyard_id,
      'vineyard_name', v.name,
      'vineyard_deleted_at', v.deleted_at,
      'geometry_status', bi.geometry_status,
      'current_polygon_points_evidence', bi.polygon_points,
      'vertex_count', case when bi.geometry_status = 'usable_current_polygon'
        then jsonb_array_length(bi.polygon_points) end,
      'distinct_vertex_count', case when bi.geometry_status = 'usable_current_polygon' then
        (select count(distinct (x.value->>'latitude', x.value->>'longitude'))::integer
         from jsonb_array_elements(bi.polygon_points) x(value)) end,
      'minimum_latitude', case when bi.geometry_status = 'usable_current_polygon' then
        (select min((x.value->>'latitude')::double precision)
         from jsonb_array_elements(bi.polygon_points) x(value)) end,
      'maximum_latitude', case when bi.geometry_status = 'usable_current_polygon' then
        (select max((x.value->>'latitude')::double precision)
         from jsonb_array_elements(bi.polygon_points) x(value)) end,
      'minimum_longitude', case when bi.geometry_status = 'usable_current_polygon' then
        (select min((x.value->>'longitude')::double precision)
         from jsonb_array_elements(bi.polygon_points) x(value)) end,
      'maximum_longitude', case when bi.geometry_status = 'usable_current_polygon' then
        (select max((x.value->>'longitude')::double precision)
         from jsonb_array_elements(bi.polygon_points) x(value)) end,
      'row_geometry_json_present', bi.rows is not null,
      'assigned_pin_count', bps.assigned_pin_count,
      'assigned_active_pin_count', bps.assigned_active_pin_count,
      'assigned_completed_pin_count', bps.assigned_completed_pin_count,
      'current_coordinate_containment_count', bps.current_coordinate_containment_count,
      'created_at', bi.created_at,
      'updated_at', bi.updated_at,
      'sync_version', bi.sync_version,
      'geometry_limitations', case
        when bi.geometry_status <> 'usable_current_polygon' then
          'Excluded from containment because the current boundary JSON is missing or malformed.'
        else
          'Passed minimum JSON structure checks only. This does not prove the physical boundary is correct, historical, complete, non-self-intersecting, or correctly wound.'
      end,
      'authoritative_information_needed', case
        when bi.geometry_status <> 'usable_current_polygon' then
          'Jonathan must provide or approve the block identity and authoritative ordered boundary vertices from the vineyard source of truth.'
        when bps.assigned_pin_count = 0 and bps.current_coordinate_containment_count = 0 then
          'Confirm this active no-pin block still exists physically and that its current boundary and vineyard ownership are authoritative.'
      end
    )
  from block_inventory bi
  left join public.vineyards v on v.id = bi.vineyard_id
  left join block_pin_stats bps on bps.block_id = bi.id

  union all

  select
    30,
    rrs.vineyard_name,
    rrs.vineyard_id,
    rrs.run_id::text,
    'repair_run_summary',
    jsonb_build_object(
      'run_id', rrs.run_id,
      'vineyard_id', rrs.vineyard_id,
      'vineyard_name', rrs.vineyard_name,
      'expected_count', rrs.expected_count,
      'audited_count', rrs.audited_count,
      'valid_audit_transition_count', rrs.valid_audit_transition_count,
      'exact_after_image_count', rrs.exact_after_image_count,
      'current_approved_target_count', rrs.current_approved_target_count,
      'later_edit_same_target_count', rrs.later_edit_same_target_count,
      'later_reassignment_or_missing_count', rrs.later_reassignment_or_missing_count,
      'all_expected_audits_present', rrs.audited_count = rrs.expected_count,
      'approved_links_still_targeted', rrs.audited_count = rrs.expected_count
        and rrs.valid_audit_transition_count = rrs.expected_count
        and rrs.current_approved_target_count = rrs.expected_count,
      'exact_original_post_repair_state', rrs.audited_count = rrs.expected_count
        and rrs.exact_after_image_count = rrs.expected_count,
      'interpretation', 'A later row edit is not labelled a repair failure. Same approved target is separated from later reassignment; both require audit review if the exact after-image changed.'
    )
  from repair_run_summary rrs

  union all

  select
    40,
    rc.vineyard_name,
    rc.vineyard_id,
    coalesce(rc.pin_id::text, rc.run_id::text),
    'repair_detail',
    jsonb_build_object(
      'run_id', rc.run_id,
      'pin_id', rc.pin_id,
      'expected_vineyard_id', rc.vineyard_id,
      'audit_vineyard_id', rc.audit_vineyard_id,
      'approved_target_block_id', rc.target_paddock_id,
      'approved_target_current_name', rc.approved_target_current_name,
      'audit_status', rc.status,
      'applied_at', rc.applied_at,
      'audit_transition_valid', rc.audit_transition_valid,
      'current_pin_id', rc.current_pin_id,
      'current_vineyard_id', rc.current_vineyard_id,
      'current_block_id', rc.current_block_id,
      'current_pin_deleted_at', rc.current_pin_deleted_at,
      'current_sync_version', rc.current_sync_version,
      'current_updated_at', rc.current_updated_at,
      'approved_target_current_vineyard_id', rc.approved_target_current_vineyard_id,
      'approved_target_deleted_at', rc.approved_target_deleted_at,
      'current_matches_audited_after', rc.current_matches_audited_after,
      'current_matches_approved_target', rc.current_matches_approved_target,
      'approved_target_block_valid', rc.approved_target_block_valid,
      'reconciliation_status', case
        when rc.pin_id is null then 'repair_audit_missing'
        when not rc.audit_transition_valid then 'repair_audit_definition_failure'
        when rc.current_pin_id is null then 'current_pin_missing_requires_review'
        when not rc.approved_target_block_valid then 'approved_target_block_changed_requires_review'
        when rc.current_matches_audited_after then 'approved_repair_intact_exact_after_image'
        when rc.current_matches_approved_target then 'later_edit_same_approved_target_not_repair_failure'
        else 'later_reassignment_deletion_or_other_edit_requires_review_not_automatically_repair_failure'
      end,
      'specific_information_needed', case
        when rc.pin_id is null or not rc.audit_transition_valid then
          'Return the complete audit row and original APPLY/VERIFY result; do not rerun APPLY.'
        when rc.current_pin_id is null then
          'Confirm whether this pin was legitimately hard-deleted and provide the later audit or operator action.'
        when not rc.approved_target_block_valid then
          'Confirm the approved block lifecycle and vineyard ownership; provide the authoritative replacement only if the block was legitimately changed.'
        when not rc.current_matches_audited_after then
          'Provide the later pin change audit/operator intent and timestamp. Preserve it if legitimate; do not overwrite it with the repair after-image.'
        when rc.approved_target_current_vineyard_id is distinct from rc.vineyard_id
          or rc.approved_target_deleted_at is not null then
          'Confirm the approved block still exists under the approved vineyard and provide authoritative block lifecycle evidence.'
      end
    )
  from repair_checks rc

  union all

  select
    50,
    c.vineyard_name,
    c.vineyard_id,
    c.id::text,
    'remaining_exception_detail',
    jsonb_build_object(
      'pin_id', c.id,
      'vineyard_id', c.vineyard_id,
      'vineyard_name', c.vineyard_name,
      'vineyard_deleted_at', c.vineyard_deleted_at,
      'pin_type', c.button_name,
      'pin_mode', c.mode,
      'completion_state', case when c.is_completed then 'completed' else 'active' end,
      'pin_capture_time', c.created_at,
      'stored_latitude', c.latitude,
      'stored_longitude', c.longitude,
      'stored_snapped_latitude', c.snapped_latitude,
      'stored_snapped_longitude', c.snapped_longitude,
      'stored_snapped_to_row', c.snapped_to_row,
      'base_to_snapped_metres', round(c.base_to_snapped_metres::numeric, 2),
      'stored_heading_degrees_evidence_only', c.heading,
      'current_block_id', c.paddock_id,
      'current_block_name', c.current_block_name,
      'current_block_vineyard_id', c.current_block_vineyard_id,
      'current_block_deleted_at', c.current_block_deleted_at,
      'placement_origin', c.placement_origin,
      'stored_location_scope', c.location_scope,
      'row_segment_count', c.segment_count,
      'classification', c.classification,
      'candidate_match_count', c.candidate_match_count,
      'candidate_blocks', c.candidates,
      'snapped_candidate_match_count', c.snapped_candidate_match_count,
      'snapped_candidate_blocks', c.snapped_candidates,
      'base_and_snapped_candidates_disagree', c.base_and_snapped_candidates_disagree,
      'nearest_current_boundary_metres', round(c.nearest_boundary_metres::numeric, 2),
      'within_3m_current_boundary_review_band', c.nearest_boundary_metres <= c.boundary_review_metres,
      'active_block_count', c.active_block_count,
      'valid_polygon_count', c.valid_polygon_count,
      'excluded_polygon_count', c.excluded_polygon_count,
      'excluded_block_geometry', c.excluded_block_geometry,
      'evidence', array_remove(array[
        case when not c.has_valid_base_coordinate then 'base coordinate missing, partial, or out of range' end,
        case when c.has_valid_base_coordinate then 'base coordinate tested against current same-vineyard valid polygons' end,
        case when c.has_valid_snapped_coordinate then 'separate valid snapped coordinate exists; base-coordinate provenance remains unverified' end,
        case when c.base_and_snapped_candidates_disagree then 'base and snapped coordinates resolve to different candidate sets' end,
        case when c.nearest_boundary_metres <= c.boundary_review_metres then 'base coordinate is within the 3m current-boundary review band' end,
        case when c.candidate_match_count > 1 then 'base coordinate is contained by multiple current polygons' end,
        case when c.paddock_id is not null and c.current_block_name is null then 'stored block relationship does not resolve to a readable block' end,
        case when c.current_block_vineyard_id is not null and c.current_block_vineyard_id <> c.vineyard_id then 'stored block belongs to another vineyard' end,
        case when c.current_block_deleted_at is not null then 'stored block is soft-deleted' end,
        case when lower(coalesce(c.button_name, '')) = 'blackberries' then 'Blackberries pin may legitimately be outside mapped production blocks' end,
        case when c.placement_origin <> 'unknown_origin' then 'manual placement intent exists and must be preserved' end,
        'only current boundaries were tested; no boundary history exists here',
        'nearest-block assignment is prohibited',
        'row/path/side/facing were not inferred'
      ]::text[], null),
      'exclusion_reason', case
        when c.placement_origin <> 'unknown_origin' then
          'Manual placement intent: withhold automatic proposal and preserve coordinate provenance.'
        when c.classification = 'overlapping/boundary ambiguity' then
          'Current polygons overlap, the coordinate is within 3m of a boundary, or base/snapped candidate sets disagree.'
        when c.classification = 'conflicting existing assignment' then
          'Stored assignment conflicts with current same-vineyard containment or its referenced block is unavailable.'
        when c.classification = 'outside all blocks' and lower(coalesce(c.button_name, '')) = 'blackberries' then
          'Possibly legitimate outside-block pin; never force it into the nearest production block.'
        when c.classification = 'outside all blocks' then
          'Coordinate is outside every structurally valid current same-vineyard polygon.'
        when c.classification = 'missing link with unique candidate' then
          'Unique current containment exists but remains review evidence, not historical proof.'
        else
          'Coordinate or current active-block geometry is insufficient for block reconciliation.'
      end,
      'specific_information_needed', case
        when c.active_block_count = 0 then
          'Authoritative answer whether this vineyard should have blocks; if yes, provide the complete active block IDs, names, ownership and ordered boundary vertices, and identify any deleted or unmigrated definitions.'
        when c.valid_polygon_count = 0 and c.active_block_count > 0 then
          'Authoritative corrected boundary vertices for each malformed active block, preserving block IDs and ownership where valid.'
        when c.classification = 'overlapping/boundary ambiguity' then
          'Authoritative shared boundary/overlap geometry plus confirmation of which stored coordinate is original versus derived or snapped.'
        when c.classification = 'conflicting existing assignment' then
          'Authoritative intended block for this exact pin, evidence for whether the stored assignment was manual, and authoritative current boundary coverage.'
        when c.classification = 'outside all blocks' and c.vineyard_name = 'Tamburlaine Boomey' then
          'Authoritative Tamburlaine Boomey block inventory and complete boundary coverage; confirm whether this coordinate is legitimately outside production blocks or which boundary is missing/mismatched.'
        when c.classification = 'outside all blocks' then
          'Confirm whether the pin is legitimately outside all blocks; otherwise provide the authoritative missing or corrected boundary—never only a nearest block name.'
        when c.classification = 'missing link with unique candidate' then
          'Jonathan must approve the exact pin-to-block relationship after checking original capture evidence and manual intent.'
        else
          'Provide original coordinate provenance and/or authoritative active block definition sufficient to test containment.'
      end
    )
  from classified c
  where c.classification <> 'existing assignment supported'
),
final_rows as (
  select * from output_rows
  union all
  select
    5,
    null::text,
    null::uuid,
    'all_vineyards',
    'reconciliation_totals',
    jsonb_build_object(
      'total_non_deleted_pins', count(*)::integer,
      'active_pins', count(*) filter (where not is_completed)::integer,
      'completed_pins', count(*) filter (where is_completed)::integer,
      'existing assignment supported', count(*) filter (where classification = 'existing assignment supported')::integer,
      'missing link with unique candidate', count(*) filter (where classification = 'missing link with unique candidate')::integer,
      'outside all blocks', count(*) filter (where classification = 'outside all blocks')::integer,
      'overlapping/boundary ambiguity', count(*) filter (where classification = 'overlapping/boundary ambiguity')::integer,
      'conflicting existing assignment', count(*) filter (where classification = 'conflicting existing assignment')::integer,
      'insufficient geometry/evidence', count(*) filter (where classification = 'insufficient geometry/evidence')::integer,
      'prior_baseline', jsonb_build_object(
        'overlapping/boundary ambiguity', 126,
        'conflicting existing assignment', 10,
        'outside all blocks', 235,
        'insufficient geometry/evidence', 692
      ),
      'warning', 'Current polygons and structural validity do not prove correct physical or historical boundaries.'
    )
  from classified

  union all

  select
    6,
    null::text,
    null::uuid,
    'all_repairs',
    'repair_totals',
    jsonb_build_object(
      'expected_repaired_link_count', sum(expected_count)::integer,
      'audited_link_count', sum(audited_count)::integer,
      'valid_audit_transition_count', sum(valid_audit_transition_count)::integer,
      'exact_after_image_count', sum(exact_after_image_count)::integer,
      'current_approved_target_count', sum(current_approved_target_count)::integer,
      'later_edit_same_target_count', sum(later_edit_same_target_count)::integer,
      'later_reassignment_or_missing_count', sum(later_reassignment_or_missing_count)::integer,
      'all_82_approved_targets_still_match', sum(expected_count) = 82
        and sum(audited_count) = 82
        and sum(valid_audit_transition_count) = 82
        and sum(current_approved_target_count) = 82,
      'all_82_exact_after_images_still_match', sum(expected_count) = 82
        and sum(exact_after_image_count) = 82,
      'interpretation', 'A changed after-image is separated from target mismatch so later legitimate edits are not automatically called repair failures.'
    )
  from repair_run_summary
)
select result_type, record
from final_rows
order by section_order, vineyard_sort nulls first, vineyard_id, item_sort nulls first;

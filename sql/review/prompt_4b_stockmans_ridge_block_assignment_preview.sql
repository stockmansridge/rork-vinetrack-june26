-- Prompt 4D: all-vineyard historical pin block-assignment preview.
--
-- This directly extends the reviewed Prompt 4B Stockmans Ridge query to every
-- vineyard. ONE SELECT statement only. It returns vineyard summary rows followed
-- by review-detail rows. This preview does not modify pins or blocks, create
-- helper objects, infer row/path/side/facing values, or choose a nearest block.
-- `pins.paddock_id` is the existing block relationship; block names are read
-- only from `paddocks.name`.
--
-- Geometry contract:
--   * block boundaries are `paddocks.polygon_points`, a JSONB array of
--     {"latitude": number, "longitude": number};
--   * containment uses the project's existing immutable ray-casting helper,
--     `public._pin_point_in_polygon`;
--   * boundary distance uses the project's equirectangular convention:
--     111320 metres/degree latitude and 111320*cos(centroid latitude)
--     metres/degree longitude;
--   * 3 metres is a conservative REVIEW flag, not a location-accuracy claim.
--
-- Important limitations:
--   * polygon history is not stored by the inspected schema, so this compares
--     pins only with CURRENT non-deleted boundaries;
--   * historical `pins.latitude`/`longitude` may already have been snapped;
--   * unique current containment is a proposed relationship for human review,
--     not proof of the original capture block;
--   * heading and trip order are deliberately not used for block attribution.
with
params as (
  select 3.0::double precision as boundary_review_metres
),
segment_stats as (
  select s.pin_id, count(*)::integer as segment_count
  from public.pin_row_segments s
  group by s.pin_id
),
scoped_pins as materialized (
  select
    p.id,
    p.vineyard_id,
    p.paddock_id,
    p.mode,
    p.button_name,
    p.is_completed,
    p.latitude,
    p.longitude,
    p.snapped_latitude,
    p.snapped_longitude,
    p.snapped_to_row,
    p.heading,
    p.location_scope,
    p.created_at,
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
    (
      p.latitude is not null
      and p.longitude is not null
      and p.latitude between -90 and 90
      and p.longitude between -180 and 180
    ) as has_valid_base_coordinate,
    (
      p.snapped_latitude is not null
      and p.snapped_longitude is not null
      and p.snapped_latitude between -90 and 90
      and p.snapped_longitude between -180 and 180
    ) as has_valid_snapped_coordinate
  from public.pins p
  left join segment_stats ss on ss.pin_id = p.id
  where p.deleted_at is null
),
block_inventory as materialized (
  select
    pd.id,
    pd.vineyard_id,
    pd.name,
    pd.polygon_points,
    case
      when pd.polygon_points is null then 'missing_polygon_points'
      when jsonb_typeof(pd.polygon_points) <> 'array' then 'polygon_points_not_array'
      when jsonb_array_length(pd.polygon_points) < 3 then 'fewer_than_three_vertices'
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
      ) then 'invalid_vertex'
      else 'usable_current_polygon'
    end as geometry_status
  from public.paddocks pd
  where pd.deleted_at is null
),
valid_blocks as materialized (
  select
    bi.id,
    bi.vineyard_id,
    bi.name,
    bi.polygon_points,
    jsonb_array_length(bi.polygon_points) as vertex_count,
    (
      select avg((vertex.value->>'latitude')::double precision)
      from jsonb_array_elements(bi.polygon_points) vertex(value)
    ) as centroid_latitude
  from block_inventory bi
  where bi.geometry_status = 'usable_current_polygon'
),
block_geometry_summary as (
  select
    vineyard_id,
    count(*)::integer as active_block_count,
    count(*) filter (where geometry_status = 'usable_current_polygon')::integer
      as valid_polygon_count,
    count(*) filter (where geometry_status <> 'usable_current_polygon')::integer
      as excluded_polygon_count,
    jsonb_agg(
      jsonb_build_object(
        'block_id', id,
        'block_name', name,
        'geometry_status', geometry_status
      ) order by name, id
    ) filter (where geometry_status <> 'usable_current_polygon')
      as excluded_block_geometry
  from block_inventory
  group by vineyard_id
),
base_matches as (
  select sp.id as pin_id, vb.id as block_id, vb.name as block_name
  from scoped_pins sp
  cross join valid_blocks vb
  where vb.vineyard_id = sp.vineyard_id
    and sp.has_valid_base_coordinate
    and public._pin_point_in_polygon(
      sp.latitude,
      sp.longitude,
      vb.polygon_points
    )
),
base_candidates as (
  select
    bm.pin_id,
    count(*)::integer as match_count,
    array_agg(bm.block_id order by bm.block_id) as candidate_ids,
    jsonb_agg(
      jsonb_build_object('block_id', bm.block_id, 'block_name', bm.block_name)
      order by bm.block_name, bm.block_id
    ) as candidates
  from base_matches bm
  group by bm.pin_id
),
snapped_matches as (
  select sp.id as pin_id, vb.id as block_id, vb.name as block_name
  from scoped_pins sp
  cross join valid_blocks vb
  where vb.vineyard_id = sp.vineyard_id
    and sp.has_valid_snapped_coordinate
    and public._pin_point_in_polygon(
      sp.snapped_latitude,
      sp.snapped_longitude,
      vb.polygon_points
    )
),
snapped_candidates as (
  select
    sm.pin_id,
    count(*)::integer as match_count,
    array_agg(sm.block_id order by sm.block_id) as candidate_ids,
    jsonb_agg(
      jsonb_build_object('block_id', sm.block_id, 'block_name', sm.block_name)
      order by sm.block_name, sm.block_id
    ) as candidates
  from snapped_matches sm
  group by sm.pin_id
),
boundary_edges as materialized (
  select
    vb.id as block_id,
    vb.vineyard_id,
    vb.centroid_latitude,
    edge_index,
    (vb.polygon_points->edge_index->>'latitude')::double precision as a_lat,
    (vb.polygon_points->edge_index->>'longitude')::double precision as a_lon,
    (
      vb.polygon_points->((edge_index + 1) % vb.vertex_count)->>'latitude'
    )::double precision as b_lat,
    (
      vb.polygon_points->((edge_index + 1) % vb.vertex_count)->>'longitude'
    )::double precision as b_lon
  from valid_blocks vb
  cross join lateral generate_series(0, vb.vertex_count - 1) edge_index
),
base_edge_distances as (
  select
    sp.id as pin_id,
    be.block_id,
    sqrt(
      power(metric.px - (metric.ax + metric.t * metric.dx), 2)
      + power(metric.py - (metric.ay + metric.t * metric.dy), 2)
    ) as distance_metres
  from scoped_pins sp
  cross join boundary_edges be
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
          (
            ((sp.longitude - be.a_lon) * scale.m_per_lon)
              * ((be.b_lon - be.a_lon) * scale.m_per_lon)
            + ((sp.latitude - be.a_lat) * 111320.0)
              * ((be.b_lat - be.a_lat) * 111320.0)
          ) / (
            power((be.b_lon - be.a_lon) * scale.m_per_lon, 2)
            + power((be.b_lat - be.a_lat) * 111320.0, 2)
          )
        ))
      end as t
    from (
      select 111320.0 * cos(be.centroid_latitude * pi() / 180.0) as m_per_lon
    ) scale
  ) metric
  where be.vineyard_id = sp.vineyard_id
    and sp.has_valid_base_coordinate
),
base_boundary_stats as (
  select pin_id, min(distance_metres) as nearest_boundary_metres
  from base_edge_distances
  group by pin_id
),
snapped_edge_distances as (
  select
    sp.id as pin_id,
    sqrt(
      power(metric.px - (metric.ax + metric.t * metric.dx), 2)
      + power(metric.py - (metric.ay + metric.t * metric.dy), 2)
    ) as distance_metres
  from scoped_pins sp
  cross join boundary_edges be
  cross join lateral (
    select
      sp.snapped_longitude * scale.m_per_lon as px,
      sp.snapped_latitude * 111320.0 as py,
      be.a_lon * scale.m_per_lon as ax,
      be.a_lat * 111320.0 as ay,
      (be.b_lon - be.a_lon) * scale.m_per_lon as dx,
      (be.b_lat - be.a_lat) * 111320.0 as dy,
      case
        when power((be.b_lon - be.a_lon) * scale.m_per_lon, 2)
             + power((be.b_lat - be.a_lat) * 111320.0, 2) = 0 then 0.0
        else greatest(0.0, least(1.0,
          (
            ((sp.snapped_longitude - be.a_lon) * scale.m_per_lon)
              * ((be.b_lon - be.a_lon) * scale.m_per_lon)
            + ((sp.snapped_latitude - be.a_lat) * 111320.0)
              * ((be.b_lat - be.a_lat) * 111320.0)
          ) / (
            power((be.b_lon - be.a_lon) * scale.m_per_lon, 2)
            + power((be.b_lat - be.a_lat) * 111320.0, 2)
          )
        ))
      end as t
    from (
      select 111320.0 * cos(be.centroid_latitude * pi() / 180.0) as m_per_lon
    ) scale
  ) metric
  where be.vineyard_id = sp.vineyard_id
    and sp.has_valid_snapped_coordinate
),
snapped_boundary_stats as (
  select pin_id, min(distance_metres) as nearest_boundary_metres
  from snapped_edge_distances
  group by pin_id
),
coordinate_disagreement as (
  select
    sp.id as pin_id,
    case
      when sp.has_valid_base_coordinate and sp.has_valid_snapped_coordinate then
        sqrt(
          power(
            (sp.snapped_longitude - sp.longitude)
              * 111320.0 * cos(((sp.latitude + sp.snapped_latitude) / 2.0) * pi() / 180.0),
            2
          )
          + power((sp.snapped_latitude - sp.latitude) * 111320.0, 2)
        )
      else null
    end as base_to_snapped_metres
  from scoped_pins sp
),
assembled as (
  select
    sp.*,
    vineyard.name as vineyard_name,
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
    sbs.nearest_boundary_metres as snapped_nearest_boundary_metres,
    cd.base_to_snapped_metres,
    coalesce(bgs.active_block_count, 0) as active_block_count,
    coalesce(bgs.valid_polygon_count, 0) as valid_polygon_count,
    coalesce(bgs.excluded_polygon_count, 0) as excluded_polygon_count,
    bgs.excluded_block_geometry,
    x.boundary_review_metres,
    (
      sp.has_valid_snapped_coordinate
      and coalesce(bc.candidate_ids, array[]::uuid[])
          is distinct from coalesce(sc.candidate_ids, array[]::uuid[])
    ) as base_and_snapped_candidates_disagree
  from scoped_pins sp
  cross join params x
  left join block_geometry_summary bgs on bgs.vineyard_id = sp.vineyard_id
  left join public.vineyards vineyard on vineyard.id = sp.vineyard_id
  left join public.paddocks current_block on current_block.id = sp.paddock_id
  left join base_candidates bc on bc.pin_id = sp.id
  left join snapped_candidates sc on sc.pin_id = sp.id
  left join base_boundary_stats bbs on bbs.pin_id = sp.id
  left join snapped_boundary_stats sbs on sbs.pin_id = sp.id
  left join coordinate_disagreement cd on cd.pin_id = sp.id
),
classified as (
  select
    a.*,
    case
      when not a.has_valid_base_coordinate
        then 'insufficient geometry/evidence'
      when a.valid_polygon_count = 0
        then 'insufficient geometry/evidence'
      when a.candidate_match_count > 1
        or a.nearest_boundary_metres <= a.boundary_review_metres
        or a.base_and_snapped_candidates_disagree
        then 'overlapping/boundary ambiguity'
      when a.paddock_id is not null
        and a.candidate_match_count = 1
        and a.paddock_id = any(a.candidate_ids)
        then 'existing assignment supported'
      when a.paddock_id is not null
        then 'conflicting existing assignment'
      when a.candidate_match_count = 1
        then 'missing link with unique candidate'
      when a.candidate_match_count = 0
        then 'outside all blocks'
      else 'insufficient geometry/evidence'
    end as classification
  from assembled a
),
vineyard_summary as (
  select
    c.vineyard_id,
    max(c.vineyard_name) as vineyard_name,
    count(*)::integer as total_pin_count,
    count(*) filter (where not c.is_completed)::integer as active_pin_count,
    count(*) filter (where c.is_completed)::integer as completed_pin_count,
    count(*) filter (where c.classification = 'existing assignment supported')::integer
      as supported_assignment_count,
    count(*) filter (where c.classification = 'missing link with unique candidate')::integer
      as missing_link_unique_candidate_count,
    count(*) filter (where c.classification = 'outside all blocks')::integer
      as outside_block_pin_count,
    count(*) filter (where c.classification = 'overlapping/boundary ambiguity')::integer
      as boundary_coordinate_ambiguity_count,
    count(*) filter (where c.classification = 'conflicting existing assignment')::integer
      as conflicting_assignment_count,
    count(*) filter (where c.classification = 'insufficient geometry/evidence')::integer
      as insufficient_geometry_count
  from classified c
  group by c.vineyard_id
)
select
  'vineyard_summary'::text as result_type,
  s.vineyard_id,
  s.vineyard_name,
  s.total_pin_count,
  s.active_pin_count,
  s.completed_pin_count,
  s.supported_assignment_count,
  s.missing_link_unique_candidate_count,
  s.outside_block_pin_count,
  s.boundary_coordinate_ambiguity_count,
  s.conflicting_assignment_count,
  s.insufficient_geometry_count,
  null::uuid as pin_id,
  null::text as pin_type,
  null::text as pin_mode,
  null::text as completion_state,
  null::double precision as stored_latitude,
  null::double precision as stored_longitude,
  null::double precision as stored_heading_degrees_evidence_only,
  null::uuid as current_block_id,
  null::text as current_block_name,
  null::uuid as proposed_block_id,
  null::text as proposed_block_name,
  null::uuid[] as candidate_block_ids,
  null::jsonb as candidate_blocks,
  null::integer as candidate_match_count,
  null::text as classification,
  null::text as placement_origin,
  null::text as stored_location_scope,
  null::integer as segment_count,
  null::double precision as stored_snapped_latitude,
  null::double precision as stored_snapped_longitude,
  null::boolean as stored_snapped_to_row,
  null::uuid[] as snapped_candidate_block_ids,
  null::jsonb as snapped_candidate_blocks,
  null::integer as snapped_candidate_match_count,
  null::numeric as base_to_snapped_metres,
  null::boolean as base_and_snapped_candidates_disagree,
  null::numeric as nearest_current_boundary_metres,
  null::numeric as snapped_nearest_current_boundary_metres,
  null::boolean as is_near_boundary,
  null::timestamptz as pin_capture_time,
  null::integer as active_block_count,
  null::integer as valid_polygon_count,
  null::integer as excluded_polygon_count,
  null::jsonb as excluded_block_geometry,
  null::text[] as evidence,
  null::text as exclusion_or_review_reason,
  'row/path/side/facing recovery remains outstanding and is not calculated here'::text
    as remaining_work
from vineyard_summary s

union all

select
  'review_detail'::text as result_type,
  c.vineyard_id,
  c.vineyard_name,
  null::integer as total_pin_count,
  null::integer as active_pin_count,
  null::integer as completed_pin_count,
  null::integer as supported_assignment_count,
  null::integer as missing_link_unique_candidate_count,
  null::integer as outside_block_pin_count,
  null::integer as boundary_coordinate_ambiguity_count,
  null::integer as conflicting_assignment_count,
  null::integer as insufficient_geometry_count,
  c.id as pin_id,
  c.button_name as pin_type,
  c.mode as pin_mode,
  case when c.is_completed then 'completed' else 'active' end as completion_state,
  c.latitude as stored_latitude,
  c.longitude as stored_longitude,
  c.heading as stored_heading_degrees_evidence_only,
  c.paddock_id as current_block_id,
  c.current_block_name,
  case
    when c.classification = 'missing link with unique candidate'
     and c.placement_origin = 'unknown_origin' then c.candidate_ids[1]
    else null
  end as proposed_block_id,
  case
    when c.classification = 'missing link with unique candidate'
     and c.placement_origin = 'unknown_origin' then proposed_block.name
    else null
  end as proposed_block_name,
  c.candidate_ids as candidate_block_ids,
  c.candidates as candidate_blocks,
  c.candidate_match_count,
  c.classification,
  c.placement_origin,
  c.location_scope as stored_location_scope,
  c.segment_count,
  c.snapped_latitude as stored_snapped_latitude,
  c.snapped_longitude as stored_snapped_longitude,
  c.snapped_to_row as stored_snapped_to_row,
  c.snapped_candidate_ids as snapped_candidate_block_ids,
  c.snapped_candidates as snapped_candidate_blocks,
  c.snapped_candidate_match_count,
  round(c.base_to_snapped_metres::numeric, 2) as base_to_snapped_metres,
  c.base_and_snapped_candidates_disagree,
  round(c.nearest_boundary_metres::numeric, 2) as nearest_current_boundary_metres,
  round(c.snapped_nearest_boundary_metres::numeric, 2)
    as snapped_nearest_current_boundary_metres,
  (c.nearest_boundary_metres <= c.boundary_review_metres) as is_near_boundary,
  c.created_at as pin_capture_time,
  c.active_block_count,
  c.valid_polygon_count,
  c.excluded_polygon_count,
  c.excluded_block_geometry,
  array_remove(array[
    case when c.latitude is null or c.longitude is null
      then 'base_coordinate_missing_or_partial' end,
    case when not c.has_valid_base_coordinate
      and c.latitude is not null and c.longitude is not null
      then 'base_coordinate_out_of_range' end,
    case when c.has_valid_base_coordinate
      then 'base_coordinate_tested_against_current_same_vineyard_polygons' end,
    case when c.snapped_latitude is not null or c.snapped_longitude is not null
      then 'snapped_coordinate_stored_separately; provenance of base coordinate remains unverified' end,
    case when c.base_and_snapped_candidates_disagree
      then 'base_and_snapped_coordinates_resolve_to_different_candidate_sets' end,
    case when c.nearest_boundary_metres <= c.boundary_review_metres
      then 'base_coordinate_within_3m_review_band_of_a_current_boundary' end,
    case when c.candidate_match_count > 1
      then 'base_coordinate_contained_by_multiple_current_polygons' end,
    case when c.paddock_id is not null and c.current_block_name is null
      then 'stored_block_relationship_does_not_resolve_to_a_readable_block' end,
    case when c.current_block_vineyard_id is not null
                  and c.current_block_vineyard_id <> c.vineyard_id
      then 'stored_block_belongs_to_another_vineyard' end,
    case when c.current_block_deleted_at is not null
      then 'stored_block_is_soft_deleted' end,
    case when lower(coalesce(c.button_name, '')) = 'blackberries'
      then 'Blackberries type may legitimately be outside mapped blocks' end,
    case when c.placement_origin <> 'unknown_origin'
      then 'manual placement intent preserved; no proposal emitted automatically' end,
    'boundary history unavailable; only current non-deleted same-vineyard polygons were tested',
    'heading and trip ordering were not used for block attribution',
    'unique containment is review evidence, not automatic or historical proof'
  ]::text[], null) as evidence,
  case
    when c.placement_origin <> 'unknown_origin'
      then 'deliberate manual placement: proposed block withheld; review intent separately'
    when lower(coalesce(c.button_name, '')) = 'blackberries'
         and c.classification = 'outside all blocks'
      then 'possible legitimate outside-block Blackberries pin; do not force to nearest block'
    when c.classification = 'missing link with unique candidate'
      then 'review proposed block relationship; current containment is not historical proof'
    when c.classification = 'conflicting existing assignment'
      then 'existing relationship conflicts with current same-vineyard containment; separate manual review required'
    when c.classification = 'overlapping/boundary ambiguity'
      then 'ambiguous geometry or coordinate provenance; exclude from automatic repair'
    when c.classification = 'outside all blocks'
      then 'outside every valid current same-vineyard polygon; do not assign nearest block'
    else 'insufficient coordinate or current polygon evidence'
  end as exclusion_or_review_reason,
  'row/path/side/facing recovery remains outstanding and is not calculated here'
    as remaining_work
from classified c
left join valid_blocks proposed_block
  on proposed_block.id = c.candidate_ids[1]
 and proposed_block.vineyard_id = c.vineyard_id
where c.classification <> 'existing assignment supported'
order by
  vineyard_name nulls last,
  vineyard_id,
  result_type desc,
  classification nulls first,
  completion_state nulls first,
  pin_type nulls last,
  pin_capture_time,
  pin_id;

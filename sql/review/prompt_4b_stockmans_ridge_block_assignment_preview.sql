-- Prompt 4B: Stockmans Ridge historical pin block-assignment preview.
--
-- ONE SELECT statement only. This preview does not modify pins or blocks, create
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
  select
    'fe952afe-437f-4be7-8cbf-fdd8e630411c'::uuid as vineyard_id,
    3.0::double precision as boundary_review_metres
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
  join params x on x.vineyard_id = p.vineyard_id
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
              then (vertex.value->>'latitude')::double precision between -90 and 90
               and (vertex.value->>'longitude')::double precision between -180 and 180
            else false
          end
        )
      ) then 'invalid_vertex'
      else 'usable_current_polygon'
    end as geometry_status
  from public.paddocks pd
  join params x on x.vineyard_id = pd.vineyard_id
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
),
base_matches as (
  select sp.id as pin_id, vb.id as block_id, vb.name as block_name
  from scoped_pins sp
  cross join valid_blocks vb
  where sp.has_valid_base_coordinate
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
  where sp.has_valid_snapped_coordinate
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
  where sp.has_valid_base_coordinate
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
  where sp.has_valid_snapped_coordinate
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
    bgs.active_block_count,
    bgs.valid_polygon_count,
    bgs.excluded_polygon_count,
    bgs.excluded_block_geometry,
    x.boundary_review_metres,
    (
      sp.has_valid_snapped_coordinate
      and coalesce(bc.candidate_ids, array[]::uuid[])
          is distinct from coalesce(sc.candidate_ids, array[]::uuid[])
    ) as base_and_snapped_candidates_disagree
  from scoped_pins sp
  cross join params x
  cross join block_geometry_summary bgs
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
)
select
  c.id as pin_id,
  c.button_name as pin_type,
  c.mode as pin_mode,
  c.is_completed,
  case when c.is_completed then 'completed' else 'active' end as completion_state,
  c.latitude as stored_latitude,
  c.longitude as stored_longitude,
  c.heading as stored_heading_degrees_evidence_only,
  c.paddock_id as current_block_id,
  c.current_block_name,
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
    'boundary history unavailable; only current non-deleted polygons were tested',
    'heading and trip ordering were not used for block attribution',
    'unique containment is review evidence, not automatic proof'
  ]::text[], null) as evidence,
  case
    when c.classification = 'existing assignment supported'
      then 'no relationship repair needed'
    when c.placement_origin <> 'unknown_origin'
      then 'deliberate manual placement: never approve automatically; review intent separately'
    when lower(coalesce(c.button_name, '')) = 'blackberries'
         and c.classification = 'outside all blocks'
      then 'possible legitimate outside-block Blackberries pin; do not force to nearest block'
    when c.classification = 'missing link with unique candidate'
      then 'review proposed block relationship; no automatic proof'
    when c.classification = 'conflicting existing assignment'
      then 'existing relationship conflicts with current containment; separate manual review required'
    when c.classification = 'overlapping/boundary ambiguity'
      then 'ambiguous geometry or coordinate evidence; exclude from automatic repair'
    when c.classification = 'outside all blocks'
      then 'outside every valid current polygon; do not assign nearest block'
    else 'insufficient coordinate or current polygon evidence'
  end as exclusion_or_review_reason,
  'row/path/side/facing recovery remains outstanding and is not calculated here'
    as remaining_work
from classified c
order by
  c.classification,
  c.is_completed,
  c.button_name nulls last,
  c.created_at,
  c.id;

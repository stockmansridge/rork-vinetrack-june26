-- Prompt 4A: read-only assessment of stored pin-location evidence.
--
-- Every executable statement in this file is SELECT-only. This file does not
-- create helper objects, propose replacement values, or modify any record.
-- Populated fields are reported as stored evidence, not as verified truth.
-- In particular, row_number is retained only as legacy evidence: this report
-- never converts it to a driving path and never adds 0.5.

-- ---------------------------------------------------------------------------
-- Result 1: minimal live-schema preflight.
--
-- Run this first. Every row should report is_present = true before running the
-- following results. Return this result if the live schema differs; do not edit
-- the later queries by guessing replacement names.
-- ---------------------------------------------------------------------------
with expected(table_name, column_name) as (
  values
    ('pins', 'id'),
    ('pins', 'vineyard_id'),
    ('pins', 'paddock_id'),
    ('pins', 'trip_id'),
    ('pins', 'mode'),
    ('pins', 'button_name'),
    ('pins', 'location_scope'),
    ('pins', 'is_completed'),
    ('pins', 'latitude'),
    ('pins', 'longitude'),
    ('pins', 'heading'),
    ('pins', 'row_number'),
    ('pins', 'side'),
    ('pins', 'driving_row_number'),
    ('pins', 'pin_row_number'),
    ('pins', 'pin_side'),
    ('pins', 'along_row_distance_m'),
    ('pins', 'snapped_latitude'),
    ('pins', 'snapped_longitude'),
    ('pins', 'snapped_to_row'),
    ('pins', 'created_at'),
    ('pins', 'client_updated_at'),
    ('pins', 'deleted_at'),
    ('vineyards', 'id'),
    ('vineyards', 'name'),
    ('paddocks', 'id'),
    ('paddocks', 'vineyard_id'),
    ('paddocks', 'name'),
    ('paddocks', 'rows'),
    ('paddocks', 'deleted_at'),
    ('trips', 'id'),
    ('trips', 'vineyard_id'),
    ('trips', 'paddock_id'),
    ('trips', 'paddock_ids'),
    ('trips', 'tracking_pattern'),
    ('trips', 'start_time'),
    ('trips', 'end_time'),
    ('trips', 'current_row_number'),
    ('trips', 'next_row_number'),
    ('trips', 'row_sequence'),
    ('trips', 'path_points'),
    ('trips', 'completed_paths'),
    ('trips', 'deleted_at'),
    ('pin_row_segments', 'pin_id'),
    ('pin_row_segments', 'row_number'),
    ('pin_row_segments', 'segment_number')
)
select
  e.table_name,
  e.column_name,
  (c.column_name is not null) as is_present,
  c.data_type,
  c.is_nullable
from expected e
left join information_schema.columns c
  on c.table_schema = 'public'
 and c.table_name = e.table_name
 and c.column_name = e.column_name
order by e.table_name, e.column_name;

-- ---------------------------------------------------------------------------
-- Result 2: summary by vineyard.
--
-- Deleted pins are counted separately and are never recovery candidates.
-- Explicit point/row/segment/block choices are separated from records whose
-- origin cannot be established from stored capture evidence. Missing counts
-- describe storage completeness only; they are not correctness claims.
-- ---------------------------------------------------------------------------
with segment_rows as (
  select
    s.pin_id,
    s.row_number,
    count(distinct s.segment_number)::integer as segments_on_row
  from public.pin_row_segments s
  group by s.pin_id, s.row_number
),
segment_stats as (
  select
    sr.pin_id,
    sum(sr.segments_on_row)::integer as segment_count,
    count(*)::integer as selected_row_count,
    bool_or(sr.segments_on_row < 4) as has_partial_row
  from segment_rows sr
  group by sr.pin_id
),
classified as (
  select
    p.*,
    coalesce(ss.segment_count, 0) as segment_count,
    coalesce(ss.selected_row_count, 0) as selected_row_count,
    coalesce(ss.has_partial_row, false) as has_partial_row,
    case
      when p.location_scope = 'point' then 'intentional_manual_point'
      when p.location_scope = 'block' then 'intentional_manual_block'
      when p.location_scope = 'row' and coalesce(ss.segment_count, 0) = 0
        then 'intentional_manual_row_missing_segments'
      when p.location_scope = 'row' and coalesce(ss.has_partial_row, false)
        then 'intentional_manual_segment'
      when p.location_scope = 'row' then 'intentional_manual_row'
      else 'unknown_origin'
    end as capture_origin,
    (p.driving_row_number is null) as missing_driving_path,
    (p.pin_row_number is null) as missing_attached_row,
    (p.pin_side is null) as missing_attachment_side,
    (p.heading is null) as missing_heading,
    (
      p.driving_row_number is null
      or p.pin_row_number is null
      or p.pin_side is null
      or p.heading is null
    ) as has_missing_location_fact
  from public.pins p
  left join segment_stats ss on ss.pin_id = p.id
)
select
  c.vineyard_id,
  v.name as vineyard_name,
  count(*) as all_pin_records,
  count(*) filter (where c.deleted_at is null and not c.is_completed) as active_pins,
  count(*) filter (where c.deleted_at is null and c.is_completed) as completed_pins,
  count(*) filter (where c.deleted_at is not null) as deleted_pins_excluded,
  count(*) filter (
    where c.deleted_at is null and c.capture_origin = 'intentional_manual_point'
  ) as intentional_manual_point_pins,
  count(*) filter (
    where c.deleted_at is null and c.capture_origin = 'intentional_manual_row'
  ) as intentional_manual_row_pins,
  count(*) filter (
    where c.deleted_at is null and c.capture_origin = 'intentional_manual_segment'
  ) as intentional_manual_segment_pins,
  count(*) filter (
    where c.deleted_at is null
      and c.capture_origin = 'intentional_manual_row_missing_segments'
  ) as intentional_manual_row_missing_segments_pins,
  count(*) filter (
    where c.deleted_at is null and c.capture_origin = 'intentional_manual_block'
  ) as intentional_manual_block_pins,
  count(*) filter (
    where c.deleted_at is null and c.capture_origin = 'unknown_origin'
  ) as unknown_origin_pins,
  count(*) filter (
    where c.deleted_at is null and c.has_missing_location_fact
  ) as all_nondeleted_incomplete_pins,
  count(*) filter (
    where c.deleted_at is null
      and c.capture_origin = 'unknown_origin'
      and c.has_missing_location_fact
  ) as unknown_origin_recovery_candidates,
  count(*) filter (
    where c.deleted_at is null
      and not c.is_completed
      and c.capture_origin = 'unknown_origin'
      and c.has_missing_location_fact
  ) as active_unknown_origin_recovery_candidates,
  count(*) filter (
    where c.deleted_at is null
      and c.is_completed
      and c.capture_origin = 'unknown_origin'
      and c.has_missing_location_fact
  ) as completed_unknown_origin_recovery_candidates,
  count(*) filter (
    where c.deleted_at is null
      and c.capture_origin = 'unknown_origin'
      and c.missing_driving_path
  ) as candidates_missing_driving_path,
  count(*) filter (
    where c.deleted_at is null
      and c.capture_origin = 'unknown_origin'
      and c.missing_attached_row
  ) as candidates_missing_attached_row,
  count(*) filter (
    where c.deleted_at is null
      and c.capture_origin = 'unknown_origin'
      and c.missing_attachment_side
  ) as candidates_missing_attachment_side,
  count(*) filter (
    where c.deleted_at is null
      and c.capture_origin = 'unknown_origin'
      and c.pin_side is null
      and c.side is null
  ) as candidates_missing_any_side_evidence,
  count(*) filter (
    where c.deleted_at is null
      and c.capture_origin = 'unknown_origin'
      and c.missing_heading
  ) as candidates_missing_heading,
  count(*) filter (
    where c.deleted_at is null
      and c.capture_origin = 'unknown_origin'
      and c.pin_row_number is not null
      and c.driving_row_number is null
  ) as candidates_with_attached_row_but_missing_path,
  count(*) filter (
    where c.deleted_at is null
      and c.capture_origin = 'unknown_origin'
      and not c.has_missing_location_fact
  ) as unknown_origin_all_four_populated_unverified
from classified c
left join public.vineyards v on v.id = c.vineyard_id
group by c.vineyard_id, v.name
order by v.name nulls last, c.vineyard_id;

-- ---------------------------------------------------------------------------
-- Result 3: non-deleted incomplete records and evidence conflicts.
--
-- is_recovery_candidate is true only for unknown-origin, non-deleted records
-- missing at least one of path/attached-row/side/heading. Explicit manual
-- records remain visible for separation but are not automatic recovery
-- candidates. No proposed replacement value is calculated anywhere.
-- ---------------------------------------------------------------------------
with segment_rows as (
  select
    s.pin_id,
    s.row_number,
    count(distinct s.segment_number)::integer as segments_on_row,
    array_agg(distinct s.segment_number order by s.segment_number) as segment_numbers
  from public.pin_row_segments s
  group by s.pin_id, s.row_number
),
segment_stats as (
  select
    sr.pin_id,
    sum(sr.segments_on_row)::integer as segment_count,
    count(*)::integer as selected_row_count,
    bool_or(sr.segments_on_row < 4) as has_partial_row,
    jsonb_agg(
      jsonb_build_object(
        'row_number', sr.row_number,
        'segment_numbers', sr.segment_numbers
      )
      order by sr.row_number
    ) as selected_segments
  from segment_rows sr
  group by sr.pin_id
),
geometry_rows as (
  select
    pd.id as paddock_id,
    count(*) filter (
      where jsonb_typeof(e.value->'number') = 'number'
        and jsonb_typeof(e.value->'startPoint'->'latitude') = 'number'
        and jsonb_typeof(e.value->'startPoint'->'longitude') = 'number'
        and jsonb_typeof(e.value->'endPoint'->'latitude') = 'number'
        and jsonb_typeof(e.value->'endPoint'->'longitude') = 'number'
    )::integer as valid_geometry_row_count,
    array_agg(
      distinct (e.value->>'number')::numeric
      order by (e.value->>'number')::numeric
    ) filter (
      where jsonb_typeof(e.value->'number') = 'number'
        and jsonb_typeof(e.value->'startPoint'->'latitude') = 'number'
        and jsonb_typeof(e.value->'startPoint'->'longitude') = 'number'
        and jsonb_typeof(e.value->'endPoint'->'latitude') = 'number'
        and jsonb_typeof(e.value->'endPoint'->'longitude') = 'number'
    ) as geometry_row_numbers
  from public.paddocks pd
  left join lateral jsonb_array_elements(
    case when jsonb_typeof(pd.rows) = 'array' then pd.rows else '[]'::jsonb end
  ) e(value) on true
  group by pd.id
),
base as (
  select
    p.*,
    v.name as vineyard_name,
    pd.id as found_paddock_id,
    pd.vineyard_id as paddock_vineyard_id,
    pd.name as paddock_name,
    pd.deleted_at as paddock_deleted_at,
    pd.rows as paddock_rows,
    coalesce(gr.valid_geometry_row_count, 0) as valid_geometry_row_count,
    gr.geometry_row_numbers,
    t.id as found_trip_id,
    t.vineyard_id as trip_vineyard_id,
    t.paddock_id as trip_paddock_id,
    t.paddock_ids as trip_paddock_ids,
    t.tracking_pattern,
    t.start_time as trip_start_time,
    t.end_time as trip_end_time,
    t.current_row_number as trip_current_row_number,
    t.next_row_number as trip_next_row_number,
    t.row_sequence as trip_row_sequence,
    t.deleted_at as trip_deleted_at,
    case when jsonb_typeof(t.path_points) = 'array'
      then jsonb_array_length(t.path_points) else 0 end as trip_path_point_count,
    case when jsonb_typeof(t.completed_paths) = 'array'
      then jsonb_array_length(t.completed_paths) else 0 end as trip_completed_path_count,
    coalesce(ss.segment_count, 0) as segment_count,
    coalesce(ss.selected_row_count, 0) as selected_row_count,
    coalesce(ss.has_partial_row, false) as has_partial_row,
    ss.selected_segments,
    case
      when p.location_scope = 'point' then 'intentional_manual_point'
      when p.location_scope = 'block' then 'intentional_manual_block'
      when p.location_scope = 'row' and coalesce(ss.segment_count, 0) = 0
        then 'intentional_manual_row_missing_segments'
      when p.location_scope = 'row' and coalesce(ss.has_partial_row, false)
        then 'intentional_manual_segment'
      when p.location_scope = 'row' then 'intentional_manual_row'
      else 'unknown_origin'
    end as capture_origin,
    (p.driving_row_number is null) as missing_driving_path,
    (p.pin_row_number is null) as missing_attached_row,
    (p.pin_side is null) as missing_attachment_side,
    (p.heading is null) as missing_heading,
    (
      p.driving_row_number is null
      or p.pin_row_number is null
      or p.pin_side is null
      or p.heading is null
    ) as has_missing_location_fact
  from public.pins p
  left join public.vineyards v on v.id = p.vineyard_id
  left join public.paddocks pd on pd.id = p.paddock_id
  left join geometry_rows gr on gr.paddock_id = pd.id
  left join public.trips t on t.id = p.trip_id
  left join segment_stats ss on ss.pin_id = p.id
  where p.deleted_at is null
),
assessed as (
  select
    b.*,
    array_remove(array[
      case when (b.latitude is null) <> (b.longitude is null)
        then 'partial_raw_coordinate' end,
      case when (b.snapped_latitude is null) <> (b.snapped_longitude is null)
        then 'partial_snapped_coordinate' end,
      case when coalesce(b.snapped_to_row, false)
                  and (b.snapped_latitude is null or b.snapped_longitude is null)
        then 'snapped_flag_without_snapped_coordinate' end,
      case when coalesce(b.snapped_to_row, false) and b.pin_row_number is null
        then 'snapped_flag_without_attached_row' end,
      case when b.heading is not null and (b.heading < 0 or b.heading >= 360)
        then 'heading_out_of_range' end,
      case when b.pin_side is not null
                  and lower(btrim(b.pin_side)) not in ('left', 'right')
        then 'invalid_attachment_side' end,
      case when b.side is not null
                  and lower(btrim(b.side)) not in ('left', 'right')
        then 'invalid_legacy_side' end,
      case when b.pin_side is not null and b.side is not null
                  and lower(btrim(b.pin_side)) <> lower(btrim(b.side))
        then 'legacy_and_attachment_side_conflict' end,
      case when b.paddock_id is not null and b.found_paddock_id is null
        then 'linked_block_not_found' end,
      case when b.paddock_vineyard_id is not null
                  and b.paddock_vineyard_id <> b.vineyard_id
        then 'block_vineyard_conflict' end,
      case when b.trip_id is not null and b.found_trip_id is null
        then 'linked_trip_not_found' end,
      case when b.trip_vineyard_id is not null
                  and b.trip_vineyard_id <> b.vineyard_id
        then 'trip_vineyard_conflict' end,
      case when b.location_scope is not null
                  and b.location_scope not in ('point', 'row', 'block')
        then 'unknown_stored_location_scope' end,
      case when b.location_scope = 'row' and b.segment_count = 0
        then 'row_scope_without_segments' end,
      case when b.location_scope is distinct from 'row' and b.segment_count > 0
        then 'segments_on_non_row_scope' end,
      case when b.location_scope in ('row', 'block')
                  and (b.driving_row_number is not null
                    or b.pin_row_number is not null
                    or b.pin_side is not null
                    or b.heading is not null)
        then 'manual_non_point_has_attachment_fields' end,
      case when b.created_at is not null and b.trip_start_time is not null
                  and b.created_at < b.trip_start_time
        then 'capture_before_linked_trip_start' end,
      case when b.created_at is not null and b.trip_end_time is not null
                  and b.created_at > b.trip_end_time
        then 'capture_after_linked_trip_end' end
    ]::text[], null) as evidence_conflicts
  from base b
)
select
  a.id as pin_id,
  a.vineyard_id,
  a.vineyard_name,
  a.paddock_id as block_id,
  a.paddock_name as block_name,
  a.trip_id,
  a.mode,
  a.button_name,
  a.is_completed,
  case when a.is_completed then 'completed' else 'active' end as pin_lifecycle,
  a.capture_origin,
  (
    a.capture_origin = 'unknown_origin'
    and a.has_missing_location_fact
  ) as is_recovery_candidate,
  case
    when a.capture_origin <> 'unknown_origin'
      then 'excluded_intentional_manual_placement'
    when not a.has_missing_location_fact
      then 'populated_but_not_verified'
    when cardinality(a.evidence_conflicts) > 0
      then 'review_conflicting_evidence'
    when a.latitude is null or a.longitude is null
      then 'insufficient_missing_coordinates'
    when a.paddock_id is null
      then 'insufficient_missing_block_linkage'
    when a.valid_geometry_row_count = 0
      then 'insufficient_missing_block_row_geometry'
    else 'stored_evidence_available_unverified'
  end as assessment_bucket,
  a.missing_driving_path,
  a.missing_attached_row,
  a.missing_attachment_side,
  a.missing_heading,
  case
    when a.driving_row_number is not null
      and a.pin_row_number is not null
      and a.pin_side is not null
      and a.heading is not null then 'all_four_populated_unverified'
    when a.driving_row_number is null
      and a.pin_row_number is null
      and a.pin_side is null
      and a.heading is null then 'all_four_missing'
    when a.pin_row_number is not null and a.driving_row_number is null
      then 'attached_row_present_driving_path_missing'
    else 'partially_populated'
  end as attachment_population_state,
  a.latitude as stored_latitude,
  a.longitude as stored_longitude,
  a.snapped_latitude as stored_snapped_latitude,
  a.snapped_longitude as stored_snapped_longitude,
  coalesce(a.snapped_to_row, false) as stored_snapped_to_row,
  case
    when a.latitude is null or a.longitude is null then 'raw_coordinate_missing'
    when a.snapped_latitude is not null and a.snapped_longitude is not null
      and a.latitude = a.snapped_latitude and a.longitude = a.snapped_longitude
      then 'raw_and_snapped_coordinates_identical_provenance_unverified'
    when a.snapped_latitude is not null and a.snapped_longitude is not null
      then 'raw_and_snapped_coordinates_both_stored_provenance_unverified'
    else 'only_raw_columns_populated_may_already_be_snapped_historically'
  end as coordinate_evidence_status,
  a.driving_row_number as stored_driving_row_number,
  a.pin_row_number as stored_pin_row_number,
  a.pin_side as stored_pin_side,
  a.along_row_distance_m as stored_along_row_distance_m,
  a.heading as stored_heading_degrees,
  a.row_number as legacy_row_number_evidence_only,
  a.side as legacy_side_evidence_only,
  a.location_scope as stored_location_scope,
  a.segment_count,
  a.selected_row_count,
  a.selected_segments,
  a.created_at as capture_timestamp,
  a.client_updated_at,
  a.found_paddock_id is not null as linked_block_exists,
  a.paddock_deleted_at is not null as linked_block_is_deleted,
  a.valid_geometry_row_count,
  a.geometry_row_numbers,
  case
    when a.paddock_id is null then 'no_block_linkage'
    when a.found_paddock_id is null then 'linked_block_not_found'
    when a.paddock_vineyard_id <> a.vineyard_id then 'block_vineyard_conflict'
    when a.paddock_deleted_at is not null then 'linked_block_deleted'
    when jsonb_typeof(a.paddock_rows) is distinct from 'array'
      then 'block_rows_not_an_array'
    when a.valid_geometry_row_count = 0 then 'no_valid_row_geometry'
    when a.driving_row_number is not null
      and array_position(a.geometry_row_numbers, floor(a.driving_row_number)) is not null
      and array_position(a.geometry_row_numbers, ceil(a.driving_row_number)) is not null
      then 'geometry_exists_for_stored_path_bounds_unverified'
    when a.pin_row_number is not null
      and array_position(a.geometry_row_numbers, a.pin_row_number) is not null
      then 'geometry_exists_for_stored_attached_row_only_unverified'
    else 'geometry_available_without_exact_stored_match'
  end as geometry_evidence_status,
  a.found_trip_id is not null as linked_trip_exists,
  a.trip_deleted_at is not null as linked_trip_is_deleted,
  a.trip_vineyard_id,
  a.trip_paddock_id,
  a.trip_paddock_ids,
  a.tracking_pattern as trip_tracking_pattern,
  a.trip_start_time,
  a.trip_end_time,
  a.trip_current_row_number,
  a.trip_next_row_number,
  a.trip_row_sequence,
  a.trip_path_point_count,
  a.trip_completed_path_count,
  (
    a.trip_path_point_count > 0
    or a.trip_completed_path_count > 0
    or a.trip_row_sequence is not null
  ) as trip_has_route_evidence,
  a.evidence_conflicts,
  case
    when cardinality(a.evidence_conflicts) > 0
      then 'Conflicts require review; no field is verified by this report.'
    when a.capture_origin <> 'unknown_origin'
      then 'Explicit manual placement; missing attachment facts can be intentional.'
    when a.has_missing_location_fact
      then 'Candidate for evidence review only; no reconstruction is proposed.'
    else 'Stored fields are populated but correctness has not been verified.'
  end as assessment_note
from assessed a
where a.has_missing_location_fact
   or cardinality(a.evidence_conflicts) > 0
order by
  a.vineyard_name nulls last,
  a.is_completed,
  a.created_at,
  a.id;

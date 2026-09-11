-- Stockmans Ridge 10–11 September pin-attachment candidate preview (READ ONLY).
-- Requires the geometry helpers from sql/043. This file performs SELECTs only:
-- no UPDATE, INSERT, DELETE, DDL, transaction or guessed heading.
-- A candidate comes from the raw coordinate's nearest mapped adjacent-row
-- centreline pair plus the pin's stored heading and side. Legacy row_number is
-- shown as evidence only and never converted to an aisle.

with target_pins as (
  select
    p.id as pin_id, p.created_at, p.paddock_id, pd.name as block_name,
    p.latitude, p.longitude, p.heading,
    lower(coalesce(p.pin_side, p.side)) as recorded_side,
    p.row_number as legacy_recorded_row,
    p.pin_row_number as stored_attached_row,
    p.driving_row_number as stored_driving_aisle,
    p.snapped_latitude, p.snapped_longitude, p.snapped_to_row,
    pd.rows
  from public.pins p
  left join public.paddocks pd on pd.id = p.paddock_id
  where p.vineyard_id = 'fe952afe-437f-4be7-8cbf-fdd8e630411c'::uuid
    and p.deleted_at is null
    and p.created_at >= '2026-09-10 00:00:00+10'::timestamptz
    and p.created_at <  '2026-09-12 00:00:00+10'::timestamptz
), lower_rows as (
  select t.*, (r->>'number')::int as lower_row
  from target_pins t
  cross join lateral jsonb_array_elements(coalesce(t.rows, '[]'::jsonb)) r
  where nullif(r->>'number', '') is not null
    and exists (
      select 1 from jsonb_array_elements(coalesce(t.rows, '[]'::jsonb)) r2
      where nullif(r2->>'number', '')::int = nullif(r->>'number', '')::int + 1
    )
), candidates as (
  select l.*, s.snapped_lat, s.snapped_lon, s.along_metres,
    sqrt(
      power((s.snapped_lat - l.latitude) * 111320.0, 2) +
      power((s.snapped_lon - l.longitude) * 111320.0 * cos(l.latitude * pi() / 180.0), 2)
    ) as distance_to_aisle_m,
    public._pin_attached_vine_row(
      l.rows, l.lower_row, s.snapped_lat, s.snapped_lon, l.heading, l.recorded_side
    ) as candidate_attached_row
  from lower_rows l
  cross join lateral public._pin_snap_to_path(
    l.latitude, l.longitude, l.rows, l.lower_row
  ) s
  where s.snapped_lat is not null and s.snapped_lon is not null
), ranked as (
  select c.*,
    row_number() over (partition by pin_id order by distance_to_aisle_m, lower_row) as candidate_rank,
    lead(distance_to_aisle_m) over (partition by pin_id order by distance_to_aisle_m, lower_row) as next_distance_m
  from candidates c
), preview as (
  select t.*,
    r.lower_row::numeric + 0.5 as candidate_driving_aisle,
    r.candidate_attached_row,
    r.snapped_lat as candidate_snapped_latitude,
    r.snapped_lon as candidate_snapped_longitude,
    r.along_metres as candidate_along_row_distance_m,
    r.distance_to_aisle_m,
    r.next_distance_m,
    case
      when t.latitude is null or t.longitude is null then 'missing_coordinates'
      when t.paddock_id is null then 'missing_block'
      when t.rows is null or jsonb_typeof(t.rows) is distinct from 'array' then 'missing_mapped_rows'
      when t.heading is null or t.heading < 0 or t.heading > 360 then 'missing_or_invalid_heading'
      when t.recorded_side not in ('left','right') then 'missing_or_invalid_side'
      when r.lower_row is null then 'no_adjacent_mapped_rows'
      when r.candidate_attached_row is null then 'side_geometry_unresolved'
      when r.next_distance_m is not null and r.next_distance_m - r.distance_to_aisle_m < 1.0 then 'conflict_near_tie'
      when t.stored_attached_row is not null and t.stored_attached_row <> r.candidate_attached_row then 'conflict_existing_attachment'
      when t.stored_driving_aisle is not null and t.stored_driving_aisle <> r.lower_row::numeric + 0.5 then 'conflict_existing_aisle'
      else 'candidate_for_review'
    end as review_status
  from target_pins t
  left join ranked r on r.pin_id = t.pin_id and r.candidate_rank = 1
)
select
  pin_id, created_at, block_name, latitude, longitude, heading, recorded_side,
  legacy_recorded_row, stored_attached_row, stored_driving_aisle,
  candidate_driving_aisle, candidate_attached_row,
  candidate_snapped_latitude, candidate_snapped_longitude,
  candidate_along_row_distance_m, distance_to_aisle_m, next_distance_m,
  review_status
from preview
order by
  case review_status when 'candidate_for_review' then 0 when 'conflict_near_tie' then 1 else 2 end,
  created_at, pin_id;

-- Exact evidence rows called out in the review remain visible in the result:
-- 4a4dad42-9bce-4b9d-846d-8c9e83b9205b (stored heading/side, no attachment)
-- 711a0fd9-ab5e-47dd-88e9-96981885e9e9 (legacy recorded row only; never +0.5)

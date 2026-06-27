-- ---------------------------------------------------------------------------
-- 043 — Pin attachment GEOMETRY preview (READ ONLY).
--
-- Purpose
--   Produces the full geometry-resolved preview for the pins backfill,
--   matching the output of scripts/preview_pin_attachment.ts. Use this when
--   the TS script can't be executed (no service-role env locally).
--
--   For each open legacy pin where pin_row_number IS NULL, this proposes:
--     * proposed_driving_row_number  = legacy row_number + 0.5
--     * proposed_pin_row_number      = the actual vine row the pin is
--                                      attached to, computed from path
--                                      geometry (rows N and N+1) + heading
--                                      + operator-POV side.
--     * proposed_pin_side            = legacy side (kept; already POV-correct)
--     * proposed_snapped_latitude/long  = pin projected onto the path
--                                         mid-line between rows N and N+1.
--     * proposed_along_row_distance_m   = distance along that mid-line.
--     * confidence + reason          = high / medium / low with explanation.
--
-- This script does NOT modify any data. The conservative UPDATE for
-- high-confidence rows is held until the preview output has been reviewed.
--
-- Geometry model matches iOS PinAttachmentResolver and the TS preview:
--   equirectangular metres anchored at the local centroid latitude.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Helper: midpoint of two lat/lon points.
-- ---------------------------------------------------------------------------
create or replace function public._pin_midpoint(
  a_lat double precision, a_lon double precision,
  b_lat double precision, b_lon double precision,
  out lat double precision, out lon double precision
) language plpgsql immutable as $function$
begin
  lat := (a_lat + b_lat) / 2.0;
  lon := (a_lon + b_lon) / 2.0;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Helper: bearing in degrees (0..360) from point A to point B.
-- ---------------------------------------------------------------------------
create or replace function public._pin_bearing_degrees(
  a_lat double precision, a_lon double precision,
  b_lat double precision, b_lon double precision
) returns double precision
language plpgsql immutable as $function$
declare
  lat1 double precision := a_lat * pi() / 180.0;
  lat2 double precision := b_lat * pi() / 180.0;
  d_lon double precision := (b_lon - a_lon) * pi() / 180.0;
  y double precision;
  x double precision;
  brg double precision;
begin
  y := sin(d_lon) * cos(lat2);
  x := cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(d_lon);
  brg := atan2(y, x) * 180.0 / pi();
  return ((((brg::numeric % 360) + 360) % 360))::double precision;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Helper: signed angular difference (a - b) wrapped into (-180, 180].
-- ---------------------------------------------------------------------------
create or replace function public._pin_signed_angular_diff(
  a double precision, b double precision
) returns double precision
language plpgsql immutable as $function$
declare diff double precision;
begin
  diff := (a - b)::numeric % 360;
  if diff > 180 then diff := diff - 360; end if;
  if diff <= -180 then diff := diff + 360; end if;
  return diff;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Helper: project a pin onto the mid-line between rows N (lower) and N+1
-- (upper). Returns the snapped lat/lon and along-line distance in metres.
-- Returns NULLs when geometry is missing or degenerate.
-- ---------------------------------------------------------------------------
create or replace function public._pin_snap_to_path(
  p_lat double precision, p_lon double precision,
  p_rows jsonb, p_lower_number int,
  out snapped_lat double precision,
  out snapped_lon double precision,
  out along_metres double precision,
  out path_bearing double precision
) language plpgsql immutable as $function$
declare
  n int;
  i int;
  num int;
  r1_s_lat double precision; r1_s_lon double precision;
  r1_e_lat double precision; r1_e_lon double precision;
  r2_s_lat double precision; r2_s_lon double precision;
  r2_e_lat double precision; r2_e_lon double precision;
  start_lat double precision; start_lon double precision;
  end_lat   double precision; end_lon   double precision;
  centroid_lat double precision;
  m_per_lat constant double precision := 111320.0;
  m_per_lon double precision;
  ax double precision; ay double precision;
  bx double precision; by_ double precision;
  px double precision; py double precision;
  dx double precision; dy double precision;
  len_sq double precision;
  length double precision;
  t double precision;
  cx double precision; cy double precision;
begin
  snapped_lat := null;
  snapped_lon := null;
  along_metres := null;
  path_bearing := null;
  if p_rows is null then return; end if;
  n := jsonb_array_length(p_rows);
  if n = 0 then return; end if;

  for i in 0..n-1 loop
    num := nullif(p_rows->i->>'number', '')::int;
    if num is null then continue; end if;
    if num = p_lower_number then
      r1_s_lat := (p_rows->i->'startPoint'->>'latitude')::double precision;
      r1_s_lon := (p_rows->i->'startPoint'->>'longitude')::double precision;
      r1_e_lat := (p_rows->i->'endPoint'  ->>'latitude')::double precision;
      r1_e_lon := (p_rows->i->'endPoint'  ->>'longitude')::double precision;
    elsif num = p_lower_number + 1 then
      r2_s_lat := (p_rows->i->'startPoint'->>'latitude')::double precision;
      r2_s_lon := (p_rows->i->'startPoint'->>'longitude')::double precision;
      r2_e_lat := (p_rows->i->'endPoint'  ->>'latitude')::double precision;
      r2_e_lon := (p_rows->i->'endPoint'  ->>'longitude')::double precision;
    end if;
  end loop;

  if r1_s_lat is null or r1_e_lat is null or r2_s_lat is null or r2_e_lat is null then
    return;
  end if;
  if (r1_s_lat = 0 and r1_s_lon = 0 and r1_e_lat = 0 and r1_e_lon = 0) or
     (r2_s_lat = 0 and r2_s_lon = 0 and r2_e_lat = 0 and r2_e_lon = 0) then
    return;
  end if;

  start_lat := (r1_s_lat + r2_s_lat) / 2.0;
  start_lon := (r1_s_lon + r2_s_lon) / 2.0;
  end_lat   := (r1_e_lat + r2_e_lat) / 2.0;
  end_lon   := (r1_e_lon + r2_e_lon) / 2.0;

  centroid_lat := (start_lat + end_lat + p_lat) / 3.0;
  m_per_lon := 111320.0 * cos(centroid_lat * pi() / 180.0);

  ax := start_lon * m_per_lon;
  ay := start_lat * m_per_lat;
  bx := end_lon   * m_per_lon;
  by_ := end_lat  * m_per_lat;
  px := p_lon * m_per_lon;
  py := p_lat * m_per_lat;
  dx := bx - ax;
  dy := by_ - ay;
  len_sq := dx*dx + dy*dy;
  if len_sq < 1e-6 then return; end if;
  length := sqrt(len_sq);
  t := ((px - ax) * dx + (py - ay) * dy) / len_sq;
  if t < 0 then t := 0; end if;
  if t > 1 then t := 1; end if;
  cx := ax + t * dx;
  cy := ay + t * dy;

  snapped_lat := cy / m_per_lat;
  snapped_lon := cx / m_per_lon;
  along_metres := t * length;
  path_bearing := public._pin_bearing_degrees(start_lat, start_lon, end_lat, end_lon);
end;
$function$;

-- ---------------------------------------------------------------------------
-- Helper: resolve attached vine row given snapped point + heading + side.
-- Returns the actual vine row number (lower or upper) the pin should attach
-- to, or NULL if geometry is insufficient.
-- Mirrors PinAttachmentResolver and the TS preview.
-- ---------------------------------------------------------------------------
create or replace function public._pin_attached_vine_row(
  p_rows jsonb, p_lower_number int,
  p_snapped_lat double precision, p_snapped_lon double precision,
  p_heading double precision, p_side text
) returns int
language plpgsql immutable as $function$
declare
  n int;
  i int;
  num int;
  r1_s_lat double precision; r1_s_lon double precision;
  r1_e_lat double precision; r1_e_lon double precision;
  r2_s_lat double precision; r2_s_lon double precision;
  r2_e_lat double precision; r2_e_lon double precision;
  path_start_lat double precision; path_start_lon double precision;
  path_end_lat   double precision; path_end_lon   double precision;
  path_bearing double precision;
  heading_diff double precision;
  forward double precision;
  left_bearing double precision;
  lower_mid_lat double precision; lower_mid_lon double precision;
  to_lower double precision;
  lower_is_on_left boolean;
  is_left boolean;
begin
  if p_rows is null or p_heading is null or p_side is null then return null; end if;
  if p_snapped_lat is null or p_snapped_lon is null then return null; end if;

  n := jsonb_array_length(p_rows);
  for i in 0..n-1 loop
    num := nullif(p_rows->i->>'number', '')::int;
    if num is null then continue; end if;
    if num = p_lower_number then
      r1_s_lat := (p_rows->i->'startPoint'->>'latitude')::double precision;
      r1_s_lon := (p_rows->i->'startPoint'->>'longitude')::double precision;
      r1_e_lat := (p_rows->i->'endPoint'  ->>'latitude')::double precision;
      r1_e_lon := (p_rows->i->'endPoint'  ->>'longitude')::double precision;
    elsif num = p_lower_number + 1 then
      r2_s_lat := (p_rows->i->'startPoint'->>'latitude')::double precision;
      r2_s_lon := (p_rows->i->'startPoint'->>'longitude')::double precision;
      r2_e_lat := (p_rows->i->'endPoint'  ->>'latitude')::double precision;
      r2_e_lon := (p_rows->i->'endPoint'  ->>'longitude')::double precision;
    end if;
  end loop;
  if r1_s_lat is null or r2_s_lat is null then return null; end if;

  path_start_lat := (r1_s_lat + r2_s_lat) / 2.0;
  path_start_lon := (r1_s_lon + r2_s_lon) / 2.0;
  path_end_lat   := (r1_e_lat + r2_e_lat) / 2.0;
  path_end_lon   := (r1_e_lon + r2_e_lon) / 2.0;

  path_bearing := public._pin_bearing_degrees(path_start_lat, path_start_lon, path_end_lat, path_end_lon);
  heading_diff := public._pin_signed_angular_diff(p_heading, path_bearing);
  if abs(heading_diff) > 90 then
    forward := (path_bearing + 180)::numeric % 360;
  else
    forward := path_bearing;
  end if;
  left_bearing := (((forward - 90)::numeric % 360 + 360) % 360)::double precision;

  lower_mid_lat := (r1_s_lat + r1_e_lat) / 2.0;
  lower_mid_lon := (r1_s_lon + r1_e_lon) / 2.0;
  to_lower := public._pin_bearing_degrees(p_snapped_lat, p_snapped_lon, lower_mid_lat, lower_mid_lon);
  lower_is_on_left := abs(public._pin_signed_angular_diff(to_lower, left_bearing)) < 90;

  is_left := lower(p_side) = 'left';
  if is_left then
    return case when lower_is_on_left then p_lower_number else p_lower_number + 1 end;
  end if;
  return case when lower_is_on_left then p_lower_number + 1 else p_lower_number end;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Preview view: full geometry-resolved proposals for every open legacy pin
-- with pin_row_number IS NULL. Read this from the SQL editor or pg client.
-- ---------------------------------------------------------------------------
create or replace view public.v_pin_attachment_preview as
with base as (
  select
    p.id as pin_id,
    p.vineyard_id,
    p.paddock_id,
    p.button_name,
    p.mode,
    p.row_number    as legacy_row_number,
    p.side          as legacy_side,
    p.heading,
    p.latitude      as current_latitude,
    p.longitude     as current_longitude,
    case when p.row_number is not null then p.row_number::numeric + 0.5 end
                    as proposed_driving_row_number,
    pad.rows        as paddock_rows
  from public.pins p
  left join public.paddocks pad on pad.id = p.paddock_id
  where p.deleted_at is null
    and p.pin_row_number is null
), snapped as (
  select
    b.*,
    s.snapped_lat,
    s.snapped_lon,
    s.along_metres,
    s.path_bearing
  from base b
  left join lateral public._pin_snap_to_path(
    b.current_latitude, b.current_longitude, b.paddock_rows, b.legacy_row_number
  ) s on true
), resolved as (
  select
    s.*,
    public._pin_attached_vine_row(
      s.paddock_rows, s.legacy_row_number,
      s.snapped_lat, s.snapped_lon,
      s.heading, s.legacy_side
    ) as proposed_pin_row_number
  from snapped s
)
select
  pin_id,
  vineyard_id,
  paddock_id,
  button_name,
  mode,
  legacy_row_number,
  legacy_side,
  heading,
  proposed_driving_row_number,
  proposed_pin_row_number,
  legacy_side as proposed_pin_side,
  current_latitude,
  current_longitude,
  snapped_lat as proposed_snapped_latitude,
  snapped_lon as proposed_snapped_longitude,
  along_metres as proposed_along_row_distance_m,
  case
    when legacy_row_number is null then 'low'
    when paddock_id is null        then 'low'
    when heading is null           then 'low'
    when legacy_side is null       then 'low'
    when current_latitude is null or current_longitude is null then 'low'
    when paddock_rows is null      then 'medium'
    when proposed_pin_row_number is null then 'medium'
    when snapped_lat is null       then 'medium'
    else 'high'
  end as confidence,
  case
    when legacy_row_number is null then 'Missing legacy row_number.'
    when paddock_id is null        then 'Missing paddock_id.'
    when heading is null           then 'Missing heading — cannot infer direction of travel.'
    when legacy_side is null       then 'Missing side — cannot infer attached vine row.'
    when current_latitude is null or current_longitude is null
                                   then 'Missing coordinates — cannot snap to row.'
    when paddock_rows is null      then 'Paddock geometry not available.'
    when proposed_pin_row_number is null then 'Adjacent row geometry missing.'
    when snapped_lat is null       then 'Path segment degenerate.'
    else 'Resolved from path geometry + heading + side.'
  end as reason
from resolved;

comment on view public.v_pin_attachment_preview is
  'Read-only preview of the pin attachment backfill. Mirrors '
  'scripts/preview_pin_attachment.ts. No data is updated by this view.';

-- ---------------------------------------------------------------------------
-- Convenience queries (run after the view is created):
--
-- 1) Summary counts by confidence:
--    select confidence, count(*) from public.v_pin_attachment_preview
--    group by confidence order by 1;
--
-- 2) Top reasons for medium / low:
--    select confidence, reason, count(*)
--    from public.v_pin_attachment_preview
--    where confidence in ('medium','low')
--    group by 1,2 order by 3 desc;
--
-- 3) Five sample high-confidence rows with proposed attached vine row +
--    snapped coordinates:
--    select pin_id, paddock_id, legacy_row_number, legacy_side, heading,
--           proposed_driving_row_number, proposed_pin_row_number,
--           proposed_snapped_latitude, proposed_snapped_longitude,
--           proposed_along_row_distance_m
--    from public.v_pin_attachment_preview
--    where confidence = 'high'
--    limit 5;
--
-- 4) Export everything (psql):
--    \copy (select * from public.v_pin_attachment_preview)
--      to 'migration/out/pin_attachment_preview.csv' csv header;
-- ---------------------------------------------------------------------------

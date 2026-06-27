-- Backfill historical pins with paddock_id and row_number inferred from
-- the pin's stored GPS coordinates.
--
-- Strategy:
--   1. Point-in-polygon test against every paddock's polygon_points (same
--      vineyard) to find the containing paddock.
--   2. Project the pin onto every row segment in that paddock and pick the
--      row with the smallest perpendicular distance.
--
-- Coordinate model matches the iOS app (docs/paddock-geometry-spec.md §4):
--   equirectangular metres anchored at the paddock centroid.
--   m_per_deg_lat = 111320, m_per_deg_lon = 111320 * cos(centroidLat).
--
-- Idempotent: only updates pins where paddock_id IS NULL.
-- Pins without latitude/longitude are skipped (cannot be inferred).

-- ---------------------------------------------------------------------------
-- Helper: point-in-polygon (ray casting) on lat/lon decimal degrees.
-- ---------------------------------------------------------------------------
create or replace function public._pin_point_in_polygon(
  p_lat double precision,
  p_lon double precision,
  p_polygon jsonb
) returns boolean
language plpgsql
immutable
as $function$
declare
  n int;
  i int;
  j int;
  xi double precision;
  yi double precision;
  xj double precision;
  yj double precision;
  inside boolean := false;
begin
  if p_polygon is null then return false; end if;
  n := jsonb_array_length(p_polygon);
  if n < 3 then return false; end if;
  j := n - 1;
  for i in 0..n-1 loop
    xi := (p_polygon->i->>'longitude')::double precision;
    yi := (p_polygon->i->>'latitude')::double precision;
    xj := (p_polygon->j->>'longitude')::double precision;
    yj := (p_polygon->j->>'latitude')::double precision;
    if xi is null or yi is null or xj is null or yj is null then
      j := i;
      continue;
    end if;
    if ((yi > p_lat) <> (yj > p_lat))
       and (yj <> yi)
       and (p_lon < (xj - xi) * (p_lat - yi) / (yj - yi) + xi)
    then
      inside := not inside;
    end if;
    j := i;
  end loop;
  return inside;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Helper: nearest row number for a pin inside a paddock.
-- Uses equirectangular metres anchored at p_centroid_lat to match iOS.
-- ---------------------------------------------------------------------------
create or replace function public._pin_nearest_row_number(
  p_lat double precision,
  p_lon double precision,
  p_rows jsonb,
  p_centroid_lat double precision
) returns integer
language plpgsql
immutable
as $function$
declare
  n int;
  i int;
  best_dist double precision := null;
  best_num int := null;
  m_per_lat constant double precision := 111320.0;
  m_per_lon double precision;
  ax double precision; ay double precision;
  bx double precision; by_ double precision;
  px double precision; py double precision;
  dx double precision; dy double precision;
  t double precision;
  cx double precision; cy double precision;
  d double precision;
  row_num int;
  start_lat double precision;
  start_lon double precision;
  end_lat double precision;
  end_lon double precision;
begin
  if p_rows is null then return null; end if;
  n := jsonb_array_length(p_rows);
  if n = 0 then return null; end if;
  m_per_lon := 111320.0 * cos(p_centroid_lat * pi() / 180.0);
  px := p_lon * m_per_lon;
  py := p_lat * m_per_lat;
  for i in 0..n-1 loop
    start_lat := (p_rows->i->'startPoint'->>'latitude')::double precision;
    start_lon := (p_rows->i->'startPoint'->>'longitude')::double precision;
    end_lat   := (p_rows->i->'endPoint'->>'latitude')::double precision;
    end_lon   := (p_rows->i->'endPoint'->>'longitude')::double precision;
    -- Skip dropped/placeholder rows (iOS writes (0,0)–(0,0) for clipped rows).
    if start_lat is null or start_lon is null or end_lat is null or end_lon is null then
      continue;
    end if;
    if start_lat = 0 and start_lon = 0 and end_lat = 0 and end_lon = 0 then
      continue;
    end if;
    ax := start_lon * m_per_lon;
    ay := start_lat * m_per_lat;
    bx := end_lon   * m_per_lon;
    by_ := end_lat  * m_per_lat;
    dx := bx - ax;
    dy := by_ - ay;
    if dx = 0 and dy = 0 then
      cx := ax; cy := ay;
    else
      t := ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy);
      if t < 0 then t := 0; end if;
      if t > 1 then t := 1; end if;
      cx := ax + t * dx;
      cy := ay + t * dy;
    end if;
    d := sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
    row_num := (p_rows->i->>'number')::int;
    if best_dist is null or d < best_dist then
      best_dist := d;
      best_num := row_num;
    end if;
  end loop;
  return best_num;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Dry-run preview (run on its own first to inspect matches before updating):
--
-- with candidates as (
--   select distinct on (p.id)
--     p.id as pin_id,
--     p.vineyard_id,
--     p.latitude,
--     p.longitude,
--     pad.id as paddock_id,
--     pad.name as paddock_name,
--     public._pin_nearest_row_number(
--       p.latitude, p.longitude, pad.rows,
--       (select avg((pt->>'latitude')::double precision)
--          from jsonb_array_elements(pad.polygon_points) pt)
--     ) as row_num
--   from public.pins p
--   join public.paddocks pad
--     on pad.vineyard_id = p.vineyard_id
--    and pad.deleted_at is null
--    and pad.polygon_points is not null
--    and jsonb_array_length(pad.polygon_points) >= 3
--    and public._pin_point_in_polygon(p.latitude, p.longitude, pad.polygon_points)
--   where p.deleted_at is null
--     and p.paddock_id is null
--     and p.latitude is not null
--     and p.longitude is not null
--   order by p.id, pad.id
-- )
-- select * from candidates;
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Backfill update.
-- ---------------------------------------------------------------------------
with candidates as (
  select distinct on (p.id)
    p.id as pin_id,
    pad.id as paddock_id,
    public._pin_nearest_row_number(
      p.latitude, p.longitude, pad.rows,
      (select avg((pt->>'latitude')::double precision)
         from jsonb_array_elements(pad.polygon_points) pt)
    ) as row_num
  from public.pins p
  join public.paddocks pad
    on pad.vineyard_id = p.vineyard_id
   and pad.deleted_at is null
   and pad.polygon_points is not null
   and jsonb_array_length(pad.polygon_points) >= 3
   and public._pin_point_in_polygon(p.latitude, p.longitude, pad.polygon_points)
  where p.deleted_at is null
    and p.paddock_id is null
    and p.latitude is not null
    and p.longitude is not null
  order by p.id, pad.id
)
update public.pins p
set
  paddock_id = c.paddock_id,
  row_number = coalesce(p.row_number, c.row_num)
from candidates c
where p.id = c.pin_id;

-- ---------------------------------------------------------------------------
-- Verification:
--
-- select count(*) filter (where paddock_id is not null) as with_paddock,
--        count(*) filter (where row_number is not null) as with_row,
--        count(*) filter (where latitude is null or longitude is null) as no_gps,
--        count(*) as total
-- from public.pins
-- where deleted_at is null;
-- ---------------------------------------------------------------------------

-- 095_admin_hectares_under_management.sql
--
-- Platform-scale reporting/marketing metric for the Admin / System Admin area:
--   "Total hectares under management"
--
-- Context / data model audit:
--   - public.paddocks has NO stored area_ha column. Block area is derived from
--     `polygon_points` (jsonb array of { "latitude": <num>, "longitude": <num> }).
--   - The iOS app + portal compute area from that polygon using a local
--     equirectangular projection + shoelace formula
--     (see RowInfrastructureCalculator.areaHectares / Paddock.areaHectares).
--     This RPC mirrors that exact formula so the numbers line up.
--   - Active vs inactive is tracked via `deleted_at` on both vineyards and
--     paddocks. There is no separate "archived"/"inactive" flag.
--
-- Inclusion / exclusion rules (per requirements):
--   INCLUDE: paddocks with deleted_at IS NULL belonging to vineyards with
--            deleted_at IS NULL, that have a valid polygon (>= 3 points).
--   EXCLUDE: soft-deleted (archived) paddocks, paddocks in soft-deleted
--            vineyards, paddocks without usable geometry (area treated as 0).
--   Null/blank geometry => 0 ha (no crash, no double counting).
--
-- This is an internal reporting/marketing metric only. It is read-only and does
-- NOT touch vineyard calculations, spray records, billing, row logic, or
-- permissions. Access is gated to platform admins via public.is_admin().

-- =========================================================================
-- Helper: polygon area in hectares (mirrors the app's areaHectares formula)
-- =========================================================================

create or replace function public._paddock_polygon_area_hectares(p_points jsonb)
returns double precision
language plpgsql
immutable
set search_path = public
as $$
declare
  n              integer;
  i              integer;
  j              integer;
  centroid_lat   double precision := 0;
  m_per_deg_lat  constant double precision := 111320.0;
  m_per_deg_lon  double precision;
  area2          double precision := 0;
  lat_i          double precision;
  lon_i          double precision;
  lat_j          double precision;
  lon_j          double precision;
  xi             double precision;
  yi             double precision;
  xj             double precision;
  yj             double precision;
begin
  if p_points is null or jsonb_typeof(p_points) <> 'array' then
    return 0;
  end if;

  n := jsonb_array_length(p_points);
  if n < 3 then
    return 0;
  end if;

  -- Centroid latitude (average of all vertex latitudes).
  for i in 0..n-1 loop
    centroid_lat := centroid_lat
      + coalesce((p_points -> i ->> 'latitude')::double precision, 0);
  end loop;
  centroid_lat := centroid_lat / n;

  m_per_deg_lon := m_per_deg_lat * cos(centroid_lat * pi() / 180.0);

  -- Shoelace over the equirectangular projection.
  for i in 0..n-1 loop
    j := (i + 1) % n;

    lat_i := coalesce((p_points -> i ->> 'latitude')::double precision, 0);
    lon_i := coalesce((p_points -> i ->> 'longitude')::double precision, 0);
    lat_j := coalesce((p_points -> j ->> 'latitude')::double precision, 0);
    lon_j := coalesce((p_points -> j ->> 'longitude')::double precision, 0);

    xi := lon_i * m_per_deg_lon;
    yi := lat_i * m_per_deg_lat;
    xj := lon_j * m_per_deg_lon;
    yj := lat_j * m_per_deg_lat;

    area2 := area2 + (xi * yj - xj * yi);
  end loop;

  -- abs(area)/2 in m^2, then convert to hectares.
  return abs(area2) / 2.0 / 10000.0;
exception
  when others then
    -- Never let a single malformed polygon break the platform metric.
    return 0;
end;
$$;

revoke all on function public._paddock_polygon_area_hectares(jsonb) from public;
grant execute on function public._paddock_polygon_area_hectares(jsonb) to authenticated;

-- =========================================================================
-- admin_platform_scale(): single-row platform scale summary
-- =========================================================================
--
-- Returns:
--   total_hectares_under_management  numeric  -- sum of active block areas (ha)
--   total_vineyards                  bigint   -- active vineyards
--   total_active_paddocks            bigint   -- active paddocks (any geometry)
--   total_paddocks_with_area         bigint   -- active paddocks with valid area
--   average_hectares_per_vineyard    numeric  -- total ha / active vineyards
--
create or replace function public.admin_platform_scale()
returns table (
  total_hectares_under_management numeric,
  total_vineyards                 bigint,
  total_active_paddocks           bigint,
  total_paddocks_with_area        bigint,
  average_hectares_per_vineyard   numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_total_ha          double precision := 0;
  v_total_vineyards   bigint := 0;
  v_active_paddocks   bigint := 0;
  v_paddocks_w_area   bigint := 0;
begin
  if not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  -- Active vineyards (not soft-deleted).
  select count(*)::bigint
    into v_total_vineyards
    from public.vineyards v
   where v.deleted_at is null;

  -- Active blocks/paddocks belonging to active vineyards, with per-block area.
  with active_blocks as (
    select public._paddock_polygon_area_hectares(p.polygon_points) as area_ha
      from public.paddocks p
      join public.vineyards v on v.id = p.vineyard_id
     where p.deleted_at is null
       and v.deleted_at is null
  )
  select
    coalesce(sum(area_ha), 0),
    count(*)::bigint,
    count(*) filter (where area_ha > 0)::bigint
  into v_total_ha, v_active_paddocks, v_paddocks_w_area
  from active_blocks;

  return query
    select
      round(v_total_ha::numeric, 2)                              as total_hectares_under_management,
      v_total_vineyards                                          as total_vineyards,
      v_active_paddocks                                          as total_active_paddocks,
      v_paddocks_w_area                                          as total_paddocks_with_area,
      case
        when v_total_vineyards > 0
          then round((v_total_ha / v_total_vineyards)::numeric, 2)
        else 0
      end                                                        as average_hectares_per_vineyard;
end;
$$;

revoke all on function public.admin_platform_scale() from public;
grant execute on function public.admin_platform_scale() to authenticated;

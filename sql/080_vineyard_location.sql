-- 080_vineyard_location.sql
-- Vineyard-level location fields (latitude, longitude, elevation, timezone)
-- shared between iOS and Lovable.
--
-- Previously these lived only in iOS's local `AppSettings` JSON, which meant:
--   * elevation/lat/long could differ per device or user
--   * a settings reset / reinstall blanked them out
--   * Lovable couldn't read or edit them
--
-- This migration moves them onto `public.vineyards` and exposes a pair of
-- SECURITY DEFINER RPCs so the same membership/role checks apply to iOS,
-- Lovable, and any future client.

alter table public.vineyards
  add column if not exists latitude         double precision,
  add column if not exists longitude        double precision,
  add column if not exists elevation_metres double precision,
  add column if not exists timezone         text;

-- Sanity-check ranges. NULLs are allowed (not yet configured).
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'vineyards_latitude_range_check'
  ) then
    alter table public.vineyards
      add constraint vineyards_latitude_range_check
      check (latitude is null or (latitude between -90 and 90));
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'vineyards_longitude_range_check'
  ) then
    alter table public.vineyards
      add constraint vineyards_longitude_range_check
      check (longitude is null or (longitude between -180 and 180));
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'vineyards_elevation_range_check'
  ) then
    alter table public.vineyards
      add constraint vineyards_elevation_range_check
      check (elevation_metres is null or (elevation_metres between -500 and 9000));
  end if;
end$$;

comment on column public.vineyards.latitude         is 'Vineyard centroid latitude in decimal degrees (WGS84).';
comment on column public.vineyards.longitude        is 'Vineyard centroid longitude in decimal degrees (WGS84).';
comment on column public.vineyards.elevation_metres is 'Vineyard elevation in metres above sea level.';
comment on column public.vineyards.timezone         is 'IANA timezone identifier (e.g. Australia/Sydney). Optional.';

-- RLS on public.vineyards already grants:
--   * SELECT to members
--   * UPDATE to owner/manager
-- so no new policies are required. The RPCs below re-check role explicitly
-- as a defense-in-depth measure (since they run as SECURITY DEFINER).

-- ---------------------------------------------------------------------------
-- get_vineyard_location(p_vineyard_id)
-- Returns the stored location fields for a vineyard the caller is a member of.
-- ---------------------------------------------------------------------------
create or replace function public.get_vineyard_location(
  p_vineyard_id uuid
) returns table (
  vineyard_id      uuid,
  latitude         double precision,
  longitude        double precision,
  elevation_metres double precision,
  timezone         text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member boolean;
begin
  select exists(
    select 1 from public.vineyard_members
     where vineyard_id = p_vineyard_id
       and user_id = auth.uid()
  ) into v_member;
  if not v_member then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;

  return query
    select v.id, v.latitude, v.longitude, v.elevation_metres, v.timezone
      from public.vineyards v
     where v.id = p_vineyard_id;
end$$;

revoke all on function public.get_vineyard_location(uuid) from public;
grant execute on function public.get_vineyard_location(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- set_vineyard_location(p_vineyard_id, p_latitude, p_longitude,
--                        p_elevation_metres, p_timezone)
-- Owner/manager only. Each parameter is independently nullable — passing NULL
-- writes NULL (i.e. "clear this field"). To leave a field untouched, callers
-- should fetch first and pass the existing value.
-- ---------------------------------------------------------------------------
create or replace function public.set_vineyard_location(
  p_vineyard_id     uuid,
  p_latitude        double precision,
  p_longitude       double precision,
  p_elevation_metres double precision,
  p_timezone        text
) returns table (
  vineyard_id      uuid,
  latitude         double precision,
  longitude        double precision,
  elevation_metres double precision,
  timezone         text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  select role::text into v_role
    from public.vineyard_members
   where vineyard_id = p_vineyard_id
     and user_id = auth.uid()
   limit 1;

  if v_role is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  -- Range validation (extra guard on top of the table check constraints).
  if p_latitude is not null and (p_latitude < -90 or p_latitude > 90) then
    raise exception 'latitude out of range';
  end if;
  if p_longitude is not null and (p_longitude < -180 or p_longitude > 180) then
    raise exception 'longitude out of range';
  end if;
  if p_elevation_metres is not null and (p_elevation_metres < -500 or p_elevation_metres > 9000) then
    raise exception 'elevation_metres out of range';
  end if;

  update public.vineyards v
     set latitude         = p_latitude,
         longitude        = p_longitude,
         elevation_metres = p_elevation_metres,
         timezone         = nullif(trim(p_timezone), ''),
         updated_at       = now()
   where v.id = p_vineyard_id;

  return query
    select v.id, v.latitude, v.longitude, v.elevation_metres, v.timezone
      from public.vineyards v
     where v.id = p_vineyard_id;
end$$;

revoke all on function public.set_vineyard_location(uuid, double precision, double precision, double precision, text) from public;
grant execute on function public.set_vineyard_location(uuid, double precision, double precision, double precision, text) to authenticated;

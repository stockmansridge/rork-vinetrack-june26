-- 083_fix_vineyard_location_rpc_ambiguity.sql
-- Fix "column reference \"vineyard_id\" is ambiguous" inside the RPCs added
-- in sql/080.
--
-- Root cause: the `RETURNS TABLE (vineyard_id uuid, ...)` clause exposes
-- `vineyard_id` as an OUT variable inside the plpgsql body. Postgres then
-- can't tell whether `where vineyard_id = p_vineyard_id` (inside the
-- membership-check) refers to the OUT variable or to
-- `public.vineyard_members.vineyard_id`.
--
-- Fix:
--   * `#variable_conflict use_column` so unqualified identifiers resolve to
--     columns (matches the original intent).
--   * Fully qualify every reference (`vm.vineyard_id`, `v.id`, etc).
--   * Keep the same RETURN signature (`vineyard_id`, `latitude`, ...) so iOS
--     and Lovable decoders are unaffected.
--
-- Drops first because `CREATE OR REPLACE FUNCTION` can't change the OUT-name
-- set even if the underlying types match.

drop function if exists public.get_vineyard_location(uuid);
drop function if exists public.set_vineyard_location(uuid, double precision, double precision, double precision, text);

-- ---------------------------------------------------------------------------
-- get_vineyard_location(p_vineyard_id)
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
#variable_conflict use_column
declare
  v_member boolean;
begin
  select exists(
    select 1
      from public.vineyard_members vm
     where vm.vineyard_id = p_vineyard_id
       and vm.user_id     = auth.uid()
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
-- ---------------------------------------------------------------------------
create or replace function public.set_vineyard_location(
  p_vineyard_id      uuid,
  p_latitude         double precision,
  p_longitude        double precision,
  p_elevation_metres double precision,
  p_timezone         text
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
#variable_conflict use_column
declare
  v_role text;
begin
  select vm.role::text into v_role
    from public.vineyard_members vm
   where vm.vineyard_id = p_vineyard_id
     and vm.user_id     = auth.uid()
   limit 1;

  if v_role is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

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

notify pgrst, 'reload schema';

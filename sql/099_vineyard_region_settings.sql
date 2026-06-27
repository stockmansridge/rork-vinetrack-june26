-- 099_vineyard_region_settings.sql
-- Organisation-level international/region settings, shared per vineyard.
--
-- Phase: move the local-only `OrganizationRegionSettings` contract onto
-- `public.vineyards` so all iOS devices in a vineyard and the Lovable portal
-- read the same values.
--
-- NON-BREAKING GUARANTEES:
--   * Purely additive: nine new nullable text columns. No existing rows are
--     rewritten, no defaults are forced, no behaviour changes for current
--     AU/NZ vineyards (every column starts NULL → iOS falls back to AU).
--   * `timezone` is intentionally NOT added here — it already exists from
--     sql/080 and remains the single shared timezone field. The region RPCs
--     read/return it but do not re-add the column.
--   * `country` (full display name) is left untouched. `country_code` is a
--     separate ISO-3166 alpha-2 code.
--   * The set RPC enforces owner/manager, mirroring set_vineyard_location.

-- ---------------------------------------------------------------------------
-- Additive columns (all nullable, no defaults)
-- ---------------------------------------------------------------------------
alter table public.vineyards add column if not exists country_code         text;
alter table public.vineyards add column if not exists currency_code        text;
alter table public.vineyards add column if not exists area_unit            text;
alter table public.vineyards add column if not exists volume_unit          text;
alter table public.vineyards add column if not exists distance_unit        text;
alter table public.vineyards add column if not exists fuel_unit            text;
alter table public.vineyards add column if not exists spray_rate_area_unit text;
alter table public.vineyards add column if not exists date_format          text;
alter table public.vineyards add column if not exists terminology_region   text;

-- ---------------------------------------------------------------------------
-- get_vineyard_region_settings(p_vineyard_id)
-- Any vineyard member may read. Returns timezone (from sql/080) alongside the
-- region fields so callers get one consistent contract. NULLs are returned
-- as-is; the client applies AU defaults for any NULL/empty value.
-- ---------------------------------------------------------------------------
drop function if exists public.get_vineyard_region_settings(uuid);

create or replace function public.get_vineyard_region_settings(
  p_vineyard_id uuid
) returns table (
  vineyard_id          uuid,
  country_code         text,
  currency_code        text,
  timezone             text,
  area_unit            text,
  volume_unit          text,
  distance_unit        text,
  fuel_unit            text,
  spray_rate_area_unit text,
  date_format          text,
  terminology_region   text
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
    select v.id,
           v.country_code,
           v.currency_code,
           v.timezone,
           v.area_unit,
           v.volume_unit,
           v.distance_unit,
           v.fuel_unit,
           v.spray_rate_area_unit,
           v.date_format,
           v.terminology_region
      from public.vineyards v
     where v.id = p_vineyard_id;
end$$;

revoke all on function public.get_vineyard_region_settings(uuid) from public;
grant execute on function public.get_vineyard_region_settings(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- set_vineyard_region_settings(...)
-- Owner/manager only. Writes all region fields atomically. Passing NULL for a
-- field clears it server-side. `timezone` is updated here too so the region
-- editor and the location editor stay consistent. Empty strings are coerced
-- to NULL so the client always falls back to AU defaults for blanks.
-- ---------------------------------------------------------------------------
drop function if exists public.set_vineyard_region_settings(
  uuid, text, text, text, text, text, text, text, text, text, text
);

create or replace function public.set_vineyard_region_settings(
  p_vineyard_id          uuid,
  p_country_code         text,
  p_currency_code        text,
  p_timezone             text,
  p_area_unit            text,
  p_volume_unit          text,
  p_distance_unit        text,
  p_fuel_unit            text,
  p_spray_rate_area_unit text,
  p_date_format          text,
  p_terminology_region   text
) returns table (
  vineyard_id          uuid,
  country_code         text,
  currency_code        text,
  timezone             text,
  area_unit            text,
  volume_unit          text,
  distance_unit        text,
  fuel_unit            text,
  spray_rate_area_unit text,
  date_format          text,
  terminology_region   text
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

  update public.vineyards v
     set country_code         = nullif(trim(p_country_code), ''),
         currency_code        = nullif(trim(p_currency_code), ''),
         timezone             = nullif(trim(p_timezone), ''),
         area_unit            = nullif(trim(p_area_unit), ''),
         volume_unit          = nullif(trim(p_volume_unit), ''),
         distance_unit        = nullif(trim(p_distance_unit), ''),
         fuel_unit            = nullif(trim(p_fuel_unit), ''),
         spray_rate_area_unit = nullif(trim(p_spray_rate_area_unit), ''),
         date_format          = nullif(trim(p_date_format), ''),
         terminology_region   = nullif(trim(p_terminology_region), ''),
         updated_at           = now()
   where v.id = p_vineyard_id;

  return query
    select v.id,
           v.country_code,
           v.currency_code,
           v.timezone,
           v.area_unit,
           v.volume_unit,
           v.distance_unit,
           v.fuel_unit,
           v.spray_rate_area_unit,
           v.date_format,
           v.terminology_region
      from public.vineyards v
     where v.id = p_vineyard_id;
end$$;

revoke all on function public.set_vineyard_region_settings(
  uuid, text, text, text, text, text, text, text, text, text, text
) from public;
grant execute on function public.set_vineyard_region_settings(
  uuid, text, text, text, text, text, text, text, text, text, text
) to authenticated;

notify pgrst, 'reload schema';

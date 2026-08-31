-- 216_vineyard_rainfall_unit.sql
--
-- Adds a vineyard-level rainfall display unit to the Region & Units contract
-- (sql/099, extended by sql/180).
--
-- What this adds:
--   Column public.vineyards.rainfall_unit  ('millimetres' | 'inches' | null)
--   get_vineyard_region_settings           now returns rainfall_unit
--   set_vineyard_region_settings           new 13-parameter overload with
--                                          p_rainfall_unit
--
-- Non-breaking guarantees (same rules as sql/180):
--   * Null/blank means "no explicit preference" — clients fall back to
--     millimetres, so every existing vineyard keeps reading mm exactly as
--     before this migration.
--   * Rainfall records themselves are ALWAYS stored in millimetres
--     (rainfall_daily.rainfall_mm etc.). This setting only changes display
--     and formatting, never stored values.
--   * The 12-parameter set overload from sql/180 is intentionally kept so
--     older app builds keep working — it never touches rainfall_unit, so it
--     cannot clear the preference.

-- ---------------------------------------------------------------- column

alter table public.vineyards add column if not exists rainfall_unit text;

do $$
begin
  alter table public.vineyards
    add constraint vineyards_rainfall_unit_check
    check (rainfall_unit is null or rainfall_unit in ('millimetres', 'inches'));
exception when duplicate_object then null;
end $$;

-- ------------------------------------------------------------- read RPC
-- Recreate with rainfall_unit appended (return type changes).

drop function if exists public.get_vineyard_region_settings(uuid);

create or replace function public.get_vineyard_region_settings(
  p_vineyard_id uuid
) returns table (
  vineyard_id            uuid,
  country_code           text,
  currency_code          text,
  timezone               text,
  area_unit              text,
  volume_unit            text,
  distance_unit          text,
  fuel_unit              text,
  spray_rate_area_unit   text,
  date_format            text,
  terminology_region     text,
  sugar_measurement_unit text,
  rainfall_unit          text
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
           v.terminology_region,
           v.sugar_measurement_unit,
           v.rainfall_unit
      from public.vineyards v
     where v.id = p_vineyard_id;
end$$;

revoke all on function public.get_vineyard_region_settings(uuid) from public;
grant execute on function public.get_vineyard_region_settings(uuid) to authenticated;

-- ------------------------------------------------------------ write RPC
-- New 13-parameter overload. The 12-parameter overload from sql/180 is
-- intentionally kept so older app builds keep working — it never touches
-- rainfall_unit, so it cannot clear the preference.

drop function if exists public.set_vineyard_region_settings(
  uuid, text, text, text, text, text, text, text, text, text, text, text, text
);

create or replace function public.set_vineyard_region_settings(
  p_vineyard_id            uuid,
  p_country_code           text,
  p_currency_code          text,
  p_timezone               text,
  p_area_unit              text,
  p_volume_unit            text,
  p_distance_unit          text,
  p_fuel_unit              text,
  p_spray_rate_area_unit   text,
  p_date_format            text,
  p_terminology_region     text,
  p_sugar_measurement_unit text,
  p_rainfall_unit          text
) returns table (
  vineyard_id            uuid,
  country_code           text,
  currency_code          text,
  timezone               text,
  area_unit              text,
  volume_unit            text,
  distance_unit          text,
  fuel_unit              text,
  spray_rate_area_unit   text,
  date_format            text,
  terminology_region     text,
  sugar_measurement_unit text,
  rainfall_unit          text
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_role     text;
  v_sugar    text;
  v_rainfall text;
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

  v_sugar := nullif(lower(trim(coalesce(p_sugar_measurement_unit, ''))), '');
  if v_sugar is not null and v_sugar not in ('brix', 'baume') then
    raise exception 'sugar_measurement_unit must be ''brix'' or ''baume''';
  end if;

  v_rainfall := nullif(lower(trim(coalesce(p_rainfall_unit, ''))), '');
  if v_rainfall is not null and v_rainfall not in ('millimetres', 'inches') then
    raise exception 'rainfall_unit must be ''millimetres'' or ''inches''';
  end if;

  update public.vineyards v
     set country_code           = nullif(trim(p_country_code), ''),
         currency_code          = nullif(trim(p_currency_code), ''),
         timezone               = nullif(trim(p_timezone), ''),
         area_unit              = nullif(trim(p_area_unit), ''),
         volume_unit            = nullif(trim(p_volume_unit), ''),
         distance_unit          = nullif(trim(p_distance_unit), ''),
         fuel_unit              = nullif(trim(p_fuel_unit), ''),
         spray_rate_area_unit   = nullif(trim(p_spray_rate_area_unit), ''),
         date_format            = nullif(trim(p_date_format), ''),
         terminology_region     = nullif(trim(p_terminology_region), ''),
         sugar_measurement_unit = v_sugar,
         rainfall_unit          = v_rainfall,
         updated_at             = now()
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
           v.terminology_region,
           v.sugar_measurement_unit,
           v.rainfall_unit
      from public.vineyards v
     where v.id = p_vineyard_id;
end$$;

revoke all on function public.set_vineyard_region_settings(
  uuid, text, text, text, text, text, text, text, text, text, text, text, text
) from public;
grant execute on function public.set_vineyard_region_settings(
  uuid, text, text, text, text, text, text, text, text, text, text, text, text
) to authenticated;

notify pgrst, 'reload schema';

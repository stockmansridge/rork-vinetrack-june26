-- =====================================================================
-- 104_current_weather_wind_gust.sql
-- =====================================================================
-- Step 2 of the weather consistency cleanup: expose Davis current gust.
--
-- Goal:
--   * Add a new NULLABLE current-observation field `wind_gust_kmh` so the
--     Lovable portal can show "Current gust" in Live observations.
--   * This is the Davis observed recent gust (mapped from
--     wind_speed_hi_last_10_min by the davis-proxy), NOT WillyWeather /
--     Open-Meteo forecast wind.
--
-- Safety / compatibility guarantees:
--   * Strictly additive. One NEW nullable column on the cache table and one
--     NEW trailing column on the RPC return shape.
--   * No existing column is renamed, dropped, or made NOT NULL.
--   * Forecast logic (WillyWeather / Open-Meteo) is untouched.
--   * Existing current-weather consumers keep working: they simply ignore
--     the new trailing column.
--   * If the Davis payload has no gust data, the value is NULL (never 0).
--   * Fully idempotent and safe to re-run / safe to apply to production.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Additive cache column
-- ---------------------------------------------------------------------
alter table public.vineyard_weather_observations
  add column if not exists wind_gust_kmh double precision;

comment on column public.vineyard_weather_observations.wind_gust_kmh is
  'Current/recent Davis observed wind gust in km/h, mapped from '
  'wind_speed_hi_last_10_min by the davis-proxy. NULL when the station '
  'payload provides no gust/high-wind value. This is observed live data, '
  'NOT WillyWeather / Open-Meteo forecast wind.';

-- ---------------------------------------------------------------------
-- 2. Extend the RPC return shape (new trailing column only)
-- ---------------------------------------------------------------------
-- Recreate with the same body, adding wind_gust_kmh as the last data
-- field before the status columns. Drop first because changing the
-- OUT/return columns of an existing function requires a drop.
drop function if exists public.get_vineyard_current_weather(uuid);

create or replace function public.get_vineyard_current_weather(
  p_vineyard_id uuid
)
returns table (
  source text,
  station_id text,
  station_name text,
  observed_at timestamptz,
  temperature_c double precision,
  humidity_pct double precision,
  wind_speed_kmh double precision,
  wind_direction_deg double precision,
  rain_today_mm double precision,
  rain_rate_mm_per_hr double precision,
  leaf_wetness double precision,
  wind_gust_kmh double precision,
  is_stale boolean,
  status text,
  message text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
  v_integ record;
  v_obs record;
  v_stale_after interval := interval '20 minutes';
begin
  -- Membership check.
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;

  -- Look for an active Davis integration. (Future: other providers.)
  select i.station_id, i.station_name, i.provider, i.is_active,
         (i.api_key is not null and length(i.api_key) > 0
            and i.api_secret is not null and length(i.api_secret) > 0) as has_credentials
    into v_integ
    from public.vineyard_weather_integrations i
   where i.vineyard_id = p_vineyard_id
     and i.provider = 'davis_weatherlink'
   limit 1;

  if not found or v_integ.is_active is not true or v_integ.has_credentials is not true then
    return query
    select
      'davis_weatherlink'::text,
      null::text, null::text, null::timestamptz,
      null::double precision, null::double precision,
      null::double precision, null::double precision,
      null::double precision, null::double precision,
      null::double precision,
      null::double precision,
      false,
      'not_configured'::text,
      'Live weather is not configured for this vineyard.'::text;
    return;
  end if;

  -- Latest cached observation for this vineyard/source.
  select * into v_obs
    from public.vineyard_weather_observations o
   where o.vineyard_id = p_vineyard_id
     and o.source = 'davis_weatherlink'
   order by o.observed_at desc
   limit 1;

  if not found then
    return query
    select
      'davis_weatherlink'::text,
      v_integ.station_id, v_integ.station_name, null::timestamptz,
      null::double precision, null::double precision,
      null::double precision, null::double precision,
      null::double precision, null::double precision,
      null::double precision,
      null::double precision,
      false,
      'no_data'::text,
      'No weather observation cached yet.'::text;
    return;
  end if;

  return query
  select
    v_obs.source,
    coalesce(v_obs.station_id, v_integ.station_id),
    coalesce(v_obs.station_name, v_integ.station_name),
    v_obs.observed_at,
    v_obs.temperature_c,
    v_obs.humidity_pct,
    v_obs.wind_speed_kmh,
    v_obs.wind_direction_deg,
    v_obs.rain_today_mm,
    v_obs.rain_rate_mm_per_hr,
    v_obs.leaf_wetness,
    v_obs.wind_gust_kmh,
    (now() - v_obs.observed_at) > v_stale_after,
    'ok'::text,
    case
      when (now() - v_obs.observed_at) > v_stale_after
        then 'Latest reading is older than 20 minutes.'
      else 'ok'
    end;
end;
$$;

revoke all on function public.get_vineyard_current_weather(uuid) from public;
grant execute on function public.get_vineyard_current_weather(uuid) to authenticated;

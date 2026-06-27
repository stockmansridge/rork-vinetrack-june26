-- 088_wunderground_portal_rpcs.sql
-- Portal-facing convenience RPCs for the Weather Underground (WU) integration.
--
-- These RPCs mirror the iOS Weather Data & Forecasting page exactly so the
-- Lovable portal can read/write the SAME source of truth without re-deriving
-- column layouts. Nothing here changes the underlying storage:
--
--   * Station config lives in public.vineyard_weather_integrations
--     where provider = 'wunderground' (see 021_vineyard_weather_integrations.sql).
--   * WU rainfall rows live in public.rainfall_daily with
--     source = 'wunderground_pws' (see 028_rainfall_daily.sql and
--     029_rainfall_wunderground_source.sql).
--   * Read priority manual > davis_weatherlink > wunderground_pws > open_meteo
--     is enforced inside get_daily_rainfall and is not changed here.
--
-- The actual WU HTTP calls (find nearby stations, fetch daily history) require
-- the WUNDERGROUND_API_KEY secret and stay in the existing edge functions:
--     supabase/functions/weather-nearby-stations
--     supabase/functions/wunderground-proxy
-- The "backfill" RPC below is a planner that returns which dates the proxy
-- should attempt, after subtracting days already covered by Manual or Davis
-- (which must never be overwritten) and after skipping today.
--
-- Permissions follow the existing vineyard role model:
--   * Read RPC: any vineyard member.
--   * Write/remove RPCs: owner OR manager only.
--
-- Migration is additive — no tables, columns, or existing functions changed.

-- ---------------------------------------------------------------------------
-- 1. get_vineyard_wunderground_config
--    Returns the WU station config for a vineyard (no secrets). Thin wrapper
--    around get_vineyard_weather_integration so the portal can call a single
--    well-named RPC instead of remembering provider='wunderground'.
-- ---------------------------------------------------------------------------
create or replace function public.get_vineyard_wunderground_config(
  p_vineyard_id uuid
)
returns table (
  vineyard_id uuid,
  has_station boolean,
  station_id text,
  station_name text,
  station_latitude double precision,
  station_longitude double precision,
  is_active boolean,
  configured_by uuid,
  updated_at timestamptz,
  last_tested_at timestamptz,
  last_test_status text,
  caller_role text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;

  return query
  select
    p_vineyard_id as vineyard_id,
    (i.station_id is not null and length(i.station_id) > 0) as has_station,
    i.station_id,
    i.station_name,
    i.station_latitude,
    i.station_longitude,
    i.is_active,
    i.configured_by,
    i.updated_at,
    i.last_tested_at,
    i.last_test_status,
    v_role as caller_role
  from public.vineyard_weather_integrations i
  where i.vineyard_id = p_vineyard_id
    and i.provider = 'wunderground';

  -- If no row exists yet, surface a single "empty" row so the portal can
  -- bind to a stable result shape.
  if not found then
    return query
    select
      p_vineyard_id, false,
      null::text, null::text,
      null::double precision, null::double precision,
      true, null::uuid, null::timestamptz,
      null::timestamptz, null::text,
      v_role;
  end if;
end;
$$;

revoke all on function public.get_vineyard_wunderground_config(uuid) from public;
grant execute on function public.get_vineyard_wunderground_config(uuid) to authenticated;

comment on function public.get_vineyard_wunderground_config(uuid) is
  'Portal/iOS: read Weather Underground station config for a vineyard. '
  'Vineyard members only. No credentials returned.';

-- ---------------------------------------------------------------------------
-- 2. save_vineyard_wunderground_station
--    Owner/manager only. Upserts the selected WU station for a vineyard.
--    The platform-wide WUNDERGROUND_API_KEY secret lives in the edge function
--    environment, so api_key / api_secret are intentionally not set here.
-- ---------------------------------------------------------------------------
create or replace function public.save_vineyard_wunderground_station(
  p_vineyard_id uuid,
  p_station_id text,
  p_station_name text default null,
  p_station_latitude double precision default null,
  p_station_longitude double precision default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_id uuid;
  v_clean_station_id text;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  v_clean_station_id := nullif(btrim(coalesce(p_station_id, '')), '');
  if v_clean_station_id is null then
    raise exception 'station_id is required' using errcode = '22023';
  end if;

  insert into public.vineyard_weather_integrations as i (
    vineyard_id, provider,
    station_id, station_name,
    station_latitude, station_longitude,
    has_rain,
    configured_by, updated_at,
    is_active
  ) values (
    p_vineyard_id, 'wunderground',
    v_clean_station_id, nullif(btrim(coalesce(p_station_name, '')), ''),
    p_station_latitude, p_station_longitude,
    true,
    auth.uid(), now(),
    true
  )
  on conflict (vineyard_id, provider) do update
  set
    station_id = excluded.station_id,
    station_name = coalesce(excluded.station_name, i.station_name),
    station_latitude = coalesce(excluded.station_latitude, i.station_latitude),
    station_longitude = coalesce(excluded.station_longitude, i.station_longitude),
    has_rain = true,
    configured_by = auth.uid(),
    updated_at = now(),
    is_active = true
  returning i.id into v_id;

  return v_id;
end;
$$;

revoke all on function public.save_vineyard_wunderground_station(
  uuid, text, text, double precision, double precision
) from public;
grant execute on function public.save_vineyard_wunderground_station(
  uuid, text, text, double precision, double precision
) to authenticated;

comment on function public.save_vineyard_wunderground_station(
  uuid, text, text, double precision, double precision
) is
  'Portal/iOS: save the selected Weather Underground PWS station for a '
  'vineyard. Owner/manager only. Does not touch credentials (the WU API key '
  'is a platform secret used by the wunderground-proxy edge function).';

-- ---------------------------------------------------------------------------
-- 3. remove_vineyard_wunderground_station
--    Owner/manager only. Clears the WU station while keeping the row so
--    sensor capability flags / audit fields are not lost. Effectively
--    disables the integration.
-- ---------------------------------------------------------------------------
create or replace function public.remove_vineyard_wunderground_station(
  p_vineyard_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_existed boolean := false;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  update public.vineyard_weather_integrations
     set station_id = null,
         station_name = null,
         station_latitude = null,
         station_longitude = null,
         has_rain = false,
         is_active = false,
         configured_by = auth.uid(),
         updated_at = now()
   where vineyard_id = p_vineyard_id
     and provider = 'wunderground'
  returning true into v_existed;

  return coalesce(v_existed, false);
end;
$$;

revoke all on function public.remove_vineyard_wunderground_station(uuid) from public;
grant execute on function public.remove_vineyard_wunderground_station(uuid)
  to authenticated;

comment on function public.remove_vineyard_wunderground_station(uuid) is
  'Portal/iOS: clear the Weather Underground station for a vineyard. '
  'Owner/manager only. Does not delete historical rainfall_daily rows that '
  'were already written under source = wunderground_pws.';

-- ---------------------------------------------------------------------------
-- 4. plan_wunderground_rainfall_backfill
--    Authorisation gate + planner for WU backfill. Owner/manager only.
--
--    Returns the list of vineyard-local dates that the wunderground-proxy
--    edge function SHOULD fetch for this vineyard, given a window in days
--    (default 14, max 365). Dates that already have a Manual or Davis row
--    are excluded so the proxy never overwrites those higher-priority
--    sources. Today is always skipped because the WU daily summary for an
--    in-progress day is incomplete.
--
--    The edge function still re-validates role and writes only to
--    source = 'wunderground_pws' via upsert_wunderground_rainfall_daily,
--    so this RPC is a planning helper, not the security gate for writes.
-- ---------------------------------------------------------------------------
create or replace function public.plan_wunderground_rainfall_backfill(
  p_vineyard_id uuid,
  p_days integer default 14,
  p_timezone text default 'Australia/Sydney'
)
returns table (
  vineyard_id uuid,
  station_id text,
  station_name text,
  timezone text,
  today_local date,
  days_requested integer,
  dates_to_fetch date[],
  dates_skipped_today date[],
  dates_skipped_manual date[],
  dates_skipped_davis date[],
  dates_already_wu date[]
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
  v_station_id text;
  v_station_name text;
  v_days integer;
  v_tz text;
  v_today date;
  v_from date;
  v_to date;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  v_days := greatest(1, least(365, coalesce(p_days, 14)));
  v_tz := coalesce(nullif(btrim(p_timezone), ''), 'Australia/Sydney');

  begin
    v_today := (now() at time zone v_tz)::date;
  exception when others then
    v_tz := 'Australia/Sydney';
    v_today := (now() at time zone v_tz)::date;
  end;

  -- Window: yesterday back N days. Today is intentionally excluded.
  v_to := v_today - 1;
  v_from := v_today - v_days;

  select i.station_id, i.station_name
    into v_station_id, v_station_name
    from public.vineyard_weather_integrations i
   where i.vineyard_id = p_vineyard_id
     and i.provider = 'wunderground'
   limit 1;

  return query
  with window_days as (
    select gs::date as d
      from generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') gs
  ),
  existing as (
    select r.date, r.source
      from public.rainfall_daily r
     where r.vineyard_id = p_vineyard_id
       and r.deleted_at is null
       and r.date between v_from and v_to
  ),
  classified as (
    select
      w.d,
      bool_or(e.source = 'manual')            as has_manual,
      bool_or(e.source = 'davis_weatherlink') as has_davis,
      bool_or(e.source = 'wunderground_pws')  as has_wu
    from window_days w
    left join existing e on e.date = w.d
    group by w.d
  )
  select
    p_vineyard_id,
    v_station_id,
    v_station_name,
    v_tz,
    v_today,
    v_days,
    coalesce(
      array_agg(c.d order by c.d desc)
        filter (where not c.has_manual and not c.has_davis),
      '{}'::date[]
    ) as dates_to_fetch,
    array[v_today]::date[] as dates_skipped_today,
    coalesce(array_agg(c.d order by c.d desc) filter (where c.has_manual), '{}'::date[]),
    coalesce(array_agg(c.d order by c.d desc) filter (where c.has_davis),  '{}'::date[]),
    coalesce(array_agg(c.d order by c.d desc) filter (where c.has_wu),     '{}'::date[])
  from classified c;
end;
$$;

revoke all on function public.plan_wunderground_rainfall_backfill(uuid, integer, text)
  from public;
grant execute on function public.plan_wunderground_rainfall_backfill(uuid, integer, text)
  to authenticated;

comment on function public.plan_wunderground_rainfall_backfill(uuid, integer, text) is
  'Portal/iOS: plan a Weather Underground rainfall backfill. Owner/manager '
  'only. Returns the list of dates the wunderground-proxy edge function '
  'should fetch, skipping today and any date already covered by Manual or '
  'Davis rows (which must never be overwritten).';

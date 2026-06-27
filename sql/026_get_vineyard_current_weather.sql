-- 026_get_vineyard_current_weather.sql
-- Live Weather RPC + safe cache table.
--
-- Goals:
--   * Portal/browser never sees Davis api_key, api_secret, tokens or
--     auth headers.
--   * Portal calls only public.get_vineyard_current_weather(p_vineyard_id).
--   * The RPC is cache-only: it never triggers an upstream Davis fetch.
--   * The davis-proxy edge function is the only writer of the cache and
--     scrubs credentials/headers before persisting any raw payload.
--
-- Statuses returned by the RPC:
--   * 'not_configured' — no active integration row for the vineyard
--   * 'no_data'        — integration exists but no observation cached yet
--   * 'ok'             — observation present, may also have is_stale=true
--
-- Stale threshold for v1: 20 minutes.

-- ---------------------------------------------------------------------------
-- Cache table
-- ---------------------------------------------------------------------------
create table if not exists public.vineyard_weather_observations (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  source text not null,                       -- e.g. 'davis_weatherlink'
  station_id text,
  station_name text,
  observed_at timestamptz not null,           -- station's reading timestamp
  fetched_at timestamptz not null default now(),

  -- Safe, normalised reading values (metric).
  temperature_c double precision,
  humidity_pct double precision,
  wind_speed_kmh double precision,
  wind_direction_deg double precision,
  rain_today_mm double precision,
  rain_rate_mm_per_hr double precision,
  leaf_wetness double precision,

  -- Optional safe payload. The davis-proxy MUST scrub
  -- credentials and request headers before writing here.
  raw_payload jsonb,

  unique (vineyard_id, source)
);

create index if not exists vineyard_weather_observations_vineyard_idx
  on public.vineyard_weather_observations(vineyard_id);
create index if not exists vineyard_weather_observations_observed_idx
  on public.vineyard_weather_observations(vineyard_id, observed_at desc);

-- Lock the table down. RLS on, no policies => no direct client access.
-- Members read via the RPC; the davis-proxy writes via service-role.
alter table public.vineyard_weather_observations enable row level security;
revoke all on public.vineyard_weather_observations from anon, authenticated;

-- ---------------------------------------------------------------------------
-- get_vineyard_current_weather: cache-only read.
-- ---------------------------------------------------------------------------
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

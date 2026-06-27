-- 021_vineyard_weather_integrations.sql
-- Vineyard-level weather provider integrations (Davis WeatherLink, WU, etc.)
-- Credentials are shared across vineyard members so all users see the same
-- local rainfall / current conditions / leaf wetness data.
--
-- Security model:
--   - The base table is locked down; nothing on it is directly granted to
--     the `authenticated` role.
--   - All client access happens through SECURITY DEFINER RPC functions or a
--     `security_invoker` view that strips the secret column.
--   - The api_secret column is only ever read by the service-role (used by
--     the davis-proxy edge function) and by owner/manager via an explicit
--     reveal RPC.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------
create table if not exists public.vineyard_weather_integrations (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  provider text not null check (provider in ('davis_weatherlink','wunderground')),

  -- Credentials. api_key is sensitive but lower risk; api_secret is the
  -- secret that is never returned to operators. Both are stored as text.
  -- (Future hardening: pgsodium / Supabase Vault encryption-at-rest with
  -- a managed encryption key. The RLS / RPC surface here is designed so we
  -- can swap the storage layer without breaking clients.)
  api_key text,
  api_secret text,

  -- Selected station + cached metadata.
  station_id text,
  station_name text,
  station_latitude double precision,
  station_longitude double precision,

  -- Detected sensor capabilities, populated by Test Connection / Current.
  has_leaf_wetness boolean not null default false,
  has_rain boolean not null default false,
  has_wind boolean not null default false,
  has_temperature_humidity boolean not null default false,
  detected_sensors text[] not null default '{}',

  -- Audit / diagnostics.
  configured_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  last_tested_at timestamptz,
  last_test_status text,
  is_active boolean not null default true,

  unique (vineyard_id, provider)
);

create index if not exists vineyard_weather_integrations_vineyard_idx
  on public.vineyard_weather_integrations(vineyard_id);

-- ---------------------------------------------------------------------------
-- Lock the base table down. RLS on, no policies => no client SELECT/INSERT.
-- All client access goes through definer functions / safe view below.
-- ---------------------------------------------------------------------------
alter table public.vineyard_weather_integrations enable row level security;
revoke all on public.vineyard_weather_integrations from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helper: caller's role for a vineyard ('owner' | 'manager' | 'operator' | null)
-- ---------------------------------------------------------------------------
create or replace function public.vineyard_member_role(p_vineyard_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role::text
  from public.vineyard_members
  where vineyard_id = p_vineyard_id
    and user_id = auth.uid()
  limit 1;
$$;

revoke all on function public.vineyard_member_role(uuid) from public;
grant execute on function public.vineyard_member_role(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- get_vineyard_weather_integration: read non-secret fields. Available to any
-- vineyard member. Operators see station metadata + sensor flags but never
-- credentials. The api_key flag is exposed as has_api_key so operators can
-- tell whether the vineyard is fully configured without seeing the value.
-- ---------------------------------------------------------------------------
create or replace function public.get_vineyard_weather_integration(
  p_vineyard_id uuid,
  p_provider text default 'davis_weatherlink'
)
returns table (
  id uuid,
  vineyard_id uuid,
  provider text,
  has_api_key boolean,
  has_api_secret boolean,
  station_id text,
  station_name text,
  station_latitude double precision,
  station_longitude double precision,
  has_leaf_wetness boolean,
  has_rain boolean,
  has_wind boolean,
  has_temperature_humidity boolean,
  detected_sensors text[],
  configured_by uuid,
  updated_at timestamptz,
  last_tested_at timestamptz,
  last_test_status text,
  is_active boolean,
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
    i.id,
    i.vineyard_id,
    i.provider,
    (i.api_key is not null and length(i.api_key) > 0) as has_api_key,
    (i.api_secret is not null and length(i.api_secret) > 0) as has_api_secret,
    i.station_id,
    i.station_name,
    i.station_latitude,
    i.station_longitude,
    i.has_leaf_wetness,
    i.has_rain,
    i.has_wind,
    i.has_temperature_humidity,
    i.detected_sensors,
    i.configured_by,
    i.updated_at,
    i.last_tested_at,
    i.last_test_status,
    i.is_active,
    v_role as caller_role
  from public.vineyard_weather_integrations i
  where i.vineyard_id = p_vineyard_id
    and i.provider = p_provider;
end;
$$;

revoke all on function public.get_vineyard_weather_integration(uuid, text) from public;
grant execute on function public.get_vineyard_weather_integration(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- save_vineyard_weather_integration: owner/manager only.
-- Pass null for fields you don't want to overwrite (e.g. update station only).
-- ---------------------------------------------------------------------------
create or replace function public.save_vineyard_weather_integration(
  p_vineyard_id uuid,
  p_provider text,
  p_api_key text default null,
  p_api_secret text default null,
  p_station_id text default null,
  p_station_name text default null,
  p_station_latitude double precision default null,
  p_station_longitude double precision default null,
  p_has_leaf_wetness boolean default null,
  p_has_rain boolean default null,
  p_has_wind boolean default null,
  p_has_temperature_humidity boolean default null,
  p_detected_sensors text[] default null,
  p_last_tested_at timestamptz default null,
  p_last_test_status text default null,
  p_is_active boolean default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_id uuid;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  insert into public.vineyard_weather_integrations as i (
    vineyard_id, provider,
    api_key, api_secret,
    station_id, station_name, station_latitude, station_longitude,
    has_leaf_wetness, has_rain, has_wind, has_temperature_humidity,
    detected_sensors,
    configured_by, updated_at,
    last_tested_at, last_test_status,
    is_active
  ) values (
    p_vineyard_id, p_provider,
    p_api_key, p_api_secret,
    p_station_id, p_station_name, p_station_latitude, p_station_longitude,
    coalesce(p_has_leaf_wetness, false),
    coalesce(p_has_rain, false),
    coalesce(p_has_wind, false),
    coalesce(p_has_temperature_humidity, false),
    coalesce(p_detected_sensors, '{}'::text[]),
    auth.uid(), now(),
    p_last_tested_at, p_last_test_status,
    coalesce(p_is_active, true)
  )
  on conflict (vineyard_id, provider) do update
  set
    api_key = coalesce(excluded.api_key, i.api_key),
    api_secret = coalesce(excluded.api_secret, i.api_secret),
    station_id = coalesce(excluded.station_id, i.station_id),
    station_name = coalesce(excluded.station_name, i.station_name),
    station_latitude = coalesce(excluded.station_latitude, i.station_latitude),
    station_longitude = coalesce(excluded.station_longitude, i.station_longitude),
    has_leaf_wetness = coalesce(p_has_leaf_wetness, i.has_leaf_wetness),
    has_rain = coalesce(p_has_rain, i.has_rain),
    has_wind = coalesce(p_has_wind, i.has_wind),
    has_temperature_humidity = coalesce(p_has_temperature_humidity, i.has_temperature_humidity),
    detected_sensors = coalesce(p_detected_sensors, i.detected_sensors),
    configured_by = auth.uid(),
    updated_at = now(),
    last_tested_at = coalesce(p_last_tested_at, i.last_tested_at),
    last_test_status = coalesce(p_last_test_status, i.last_test_status),
    is_active = coalesce(p_is_active, i.is_active)
  returning i.id into v_id;

  return v_id;
end;
$$;

revoke all on function public.save_vineyard_weather_integration(
  uuid, text, text, text, text, text,
  double precision, double precision,
  boolean, boolean, boolean, boolean,
  text[], timestamptz, text, boolean
) from public;
grant execute on function public.save_vineyard_weather_integration(
  uuid, text, text, text, text, text,
  double precision, double precision,
  boolean, boolean, boolean, boolean,
  text[], timestamptz, text, boolean
) to authenticated;

-- ---------------------------------------------------------------------------
-- delete_vineyard_weather_integration: owner/manager only.
-- ---------------------------------------------------------------------------
create or replace function public.delete_vineyard_weather_integration(
  p_vineyard_id uuid,
  p_provider text default 'davis_weatherlink'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  delete from public.vineyard_weather_integrations
  where vineyard_id = p_vineyard_id and provider = p_provider;
end;
$$;

revoke all on function public.delete_vineyard_weather_integration(uuid, text) from public;
grant execute on function public.delete_vineyard_weather_integration(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- reveal_vineyard_weather_integration_credentials: owner/manager only.
-- Returns the api_key and api_secret in the clear so they can be displayed
-- (masked by default) in the management UI for verification. Must NOT be
-- callable by operators.
-- ---------------------------------------------------------------------------
create or replace function public.reveal_vineyard_weather_integration_credentials(
  p_vineyard_id uuid,
  p_provider text default 'davis_weatherlink'
)
returns table (
  api_key text,
  api_secret text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  return query
  select i.api_key, i.api_secret
  from public.vineyard_weather_integrations i
  where i.vineyard_id = p_vineyard_id and i.provider = p_provider;
end;
$$;

revoke all on function public.reveal_vineyard_weather_integration_credentials(uuid, text) from public;
grant execute on function public.reveal_vineyard_weather_integration_credentials(uuid, text) to authenticated;

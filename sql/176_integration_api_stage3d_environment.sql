-- =====================================================================
-- 176_integration_api_stage3d_environment.sql
-- =====================================================================
-- Stage 3D of the Integration Platform: environmental & advisory read API
-- (/v1/weather, /v1/rainfall, /v1/disease-risk on the vinetrack-api
-- gateway).
--
-- This migration is STRICTLY ADDITIVE:
--   * It does NOT alter anything created by SQL 172-175.
--   * It does NOT change any weather provider proxy, disease algorithm,
--     rainfall upsert path, or app-facing RPC.
--   * It does NOT add any write API surface.
--
-- Two objects:
--
--   1. public.integration_environment_cache
--      A tiny server-side freshness/cache table used ONLY by the
--      vinetrack-api gateway (service role) so that public API calls can
--      NEVER multiply upstream weather-provider requests:
--        * kind='forecast'      — normalised daily forecast bundle
--                                 (WillyWeather or Open-Meteo), TTL
--                                 enforced by the gateway (3 hours).
--        * kind='disease_risk'  — computed disease-risk payload
--                                 (Open-Meteo hourly inputs), TTL 30 min,
--                                 stale fallback up to 24 h.
--      One row per (vineyard, kind); payload is the already-normalised
--      external contract (no provider credentials, no raw provider
--      payloads — the gateway builds the payload from normalised fields
--      only).
--
--   2. public.integration_get_rainfall(...)
--      SERVICE-ROLE-ONLY read helper that returns the priority-resolved
--      daily rainfall series for one vineyard with keyset pagination
--      (date DESC, newest first). It reuses the EXACT source-priority
--      contract of public.get_daily_rainfall (sql/028/029/030):
--          manual (1) > davis_weatherlink (2) > wunderground_pws (3)
--                                             > open_meteo (4)
--      Unlike get_daily_rainfall it does NOT generate empty rows for
--      dates without data (an API collection lists observations, not a
--      calendar grid) and it does NOT depend on auth.uid() membership —
--      the vinetrack-api gateway performs the integration five-check
--      validation (SQL 172) BEFORE calling it.
--
-- Idempotent and production-safe. Apply via the Supabase SQL editor,
-- then run sql/tests/176_integration_api_stage3d_environment_tests.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Environment cache table (service-role only)
-- ---------------------------------------------------------------------
create table if not exists public.integration_environment_cache (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  kind text not null check (kind in ('forecast', 'disease_risk')),
  payload jsonb not null,
  fetched_at timestamptz not null default now(),
  unique (vineyard_id, kind)
);

comment on table public.integration_environment_cache is
  'Server-side freshness cache for the vinetrack-api Stage 3D '
  'environmental endpoints. Written and read ONLY by the vinetrack-api '
  'edge function via service role. Prevents public API calls from '
  'multiplying upstream weather-provider requests: forecast is fetched '
  'at most once per vineyard per TTL window, disease risk is computed '
  'at most once per vineyard per TTL window. payload contains only the '
  'normalised external contract — never provider credentials or raw '
  'provider payloads.';

-- Lock down: RLS on, no policies => no direct client access at all.
alter table public.integration_environment_cache enable row level security;
revoke all on public.integration_environment_cache from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Priority-resolved rainfall reader (service-role only)
-- ---------------------------------------------------------------------
-- Keyset pagination: pass p_before = the `date` of the last row from the
-- previous page (exclusive upper bound); rows come back date DESC.
-- p_limit is capped at 1001 (gateway max page 1000 + 1 look-ahead row).
create or replace function public.integration_get_rainfall(
  p_vineyard_id uuid,
  p_from date default null,
  p_to date default null,
  p_before date default null,
  p_limit integer default 101
)
returns table (
  date date,
  rainfall_mm numeric,
  source text,
  station_id text,
  station_name text,
  notes text,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select distinct on (r.date)
    r.date,
    r.rainfall_mm,
    r.source,
    r.station_id,
    r.station_name,
    r.notes,
    r.updated_at
  from public.rainfall_daily r
  where r.vineyard_id = p_vineyard_id
    and r.deleted_at is null
    and (p_from is null or r.date >= p_from)
    and (p_to is null or r.date <= p_to)
    and (p_before is null or r.date < p_before)
  order by
    r.date desc,
    case r.source
      when 'manual' then 1
      when 'davis_weatherlink' then 2
      when 'wunderground_pws' then 3
      when 'open_meteo' then 4
      else 9
    end,
    r.updated_at desc
  limit least(greatest(coalesce(p_limit, 101), 1), 1001);
$$;

comment on function public.integration_get_rainfall(uuid, date, date, date, integer) is
  'Stage 3D vinetrack-api helper: priority-resolved daily rainfall for '
  'one vineyard (manual > davis_weatherlink > wunderground_pws > '
  'open_meteo — the exact contract of get_daily_rainfall in sql/028-030) '
  'with keyset pagination date DESC. SERVICE-ROLE ONLY: the gateway '
  'runs integration_validate_api_request() (SQL 172) before calling. '
  'Returns observed rainfall only — never forecast values.';

revoke all on function public.integration_get_rainfall(uuid, date, date, date, integer) from public;
revoke all on function public.integration_get_rainfall(uuid, date, date, date, integer) from anon;
revoke all on function public.integration_get_rainfall(uuid, date, date, date, integer) from authenticated;
grant execute on function public.integration_get_rainfall(uuid, date, date, date, integer) to service_role;

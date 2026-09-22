-- 248_vineyard_forecast_cache.sql
--
-- HANDOFF TO RORK — apply on the canonical VineTrack (iOS) Supabase project.
-- NOT applied from the Lovable Portal repository.
--
-- Purpose: one provider-neutral, vineyard-level forecast cache shared by the
-- Portal, iOS and Android, so opening a screen does not call the external
-- forecast provider. Default lifetime 30 minutes. The browser never holds the
-- authoritative forecast cache.
--
-- Providers are open-ended text (willyweather, open_meteo, auto, and future
-- services as VineTrack expands into New Zealand and South Africa).

create table if not exists public.vineyard_forecast_cache (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  provider text not null,
  provider_location_ref text,
  timezone text,
  fetched_at timestamptz not null default now(),
  stale_at timestamptz not null,
  provider_updated_at timestamptz,
  schema_version text not null,
  payload jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (vineyard_id, provider)
);

grant select on public.vineyard_forecast_cache to authenticated;
grant all on public.vineyard_forecast_cache to service_role;

alter table public.vineyard_forecast_cache enable row level security;

-- Members of the vineyard may read their vineyard's cached forecast.
create policy "members read vineyard forecast cache"
on public.vineyard_forecast_cache
for select
to authenticated
using (
  exists (
    select 1 from public.vineyard_members m
    where m.vineyard_id = vineyard_forecast_cache.vineyard_id
      and m.user_id = auth.uid()
  )
);

-- Reader: returns the cached forecast plus server-authoritative staleness.
create or replace function public.get_vineyard_forecast_cache(
  p_vineyard_id uuid,
  p_provider text
)
returns table (
  provider text,
  provider_location_ref text,
  timezone text,
  fetched_at timestamptz,
  stale_at timestamptz,
  provider_updated_at timestamptz,
  schema_version text,
  payload jsonb,
  is_stale boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  select c.provider,
         c.provider_location_ref,
         c.timezone,
         c.fetched_at,
         c.stale_at,
         c.provider_updated_at,
         c.schema_version,
         c.payload,
         (c.stale_at <= now()) as is_stale
  from public.vineyard_forecast_cache c
  where c.vineyard_id = p_vineyard_id
    and c.provider = p_provider
$$;

grant execute on function public.get_vineyard_forecast_cache(uuid, text) to authenticated, service_role;

-- Writer: upsert one row per (vineyard, provider). Restricted to vineyard
-- members so a signed-in user can only refresh their own vineyard's cache.
create or replace function public.upsert_vineyard_forecast_cache(
  p_vineyard_id uuid,
  p_provider text,
  p_provider_location_ref text,
  p_timezone text,
  p_provider_updated_at timestamptz,
  p_schema_version text,
  p_payload jsonb,
  p_ttl_minutes integer default 30
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.vineyard_members m
    where m.vineyard_id = p_vineyard_id and m.user_id = auth.uid()
  ) then
    raise exception 'not a member of this vineyard';
  end if;

  insert into public.vineyard_forecast_cache as c (
    vineyard_id, provider, provider_location_ref, timezone,
    fetched_at, stale_at, provider_updated_at, schema_version, payload
  )
  values (
    p_vineyard_id, p_provider, p_provider_location_ref, p_timezone,
    now(), now() + make_interval(mins => greatest(coalesce(p_ttl_minutes, 30), 1)),
    p_provider_updated_at, p_schema_version, p_payload
  )
  on conflict (vineyard_id, provider) do update
    set provider_location_ref = excluded.provider_location_ref,
        timezone = excluded.timezone,
        fetched_at = excluded.fetched_at,
        stale_at = excluded.stale_at,
        provider_updated_at = excluded.provider_updated_at,
        schema_version = excluded.schema_version,
        payload = excluded.payload,
        updated_at = now();
end;
$$;

revoke all on function public.upsert_vineyard_forecast_cache(uuid, text, text, text, timestamptz, text, jsonb, integer) from public;
grant execute on function public.upsert_vineyard_forecast_cache(uuid, text, text, text, timestamptz, text, jsonb, integer) to authenticated, service_role;

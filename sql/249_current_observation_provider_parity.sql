-- Vineyard-wide current observation selection. NULL preserves existing Davis-first
-- behavior; explicit 'none' disables live observations without touching forecasts.
alter table public.vineyards
  add column if not exists current_observation_provider text;

do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.vineyards'::regclass
                 and conname = 'vineyards_current_observation_provider_check') then
    alter table public.vineyards add constraint vineyards_current_observation_provider_check
      check (current_observation_provider in ('none', 'davis_weatherlink', 'wunderground_pws'));
  end if;
end $$;

create or replace function public.set_vineyard_current_observation_provider(
  p_vineyard_id uuid, p_provider text
) returns void
language plpgsql security definer set search_path = public
as $$
begin
  if public.vineyard_member_role(p_vineyard_id) not in ('owner', 'manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;
  if p_provider is null or p_provider not in ('none', 'davis_weatherlink', 'wunderground_pws') then
    raise exception 'Invalid observation provider' using errcode = '22023';
  end if;
  update public.vineyards set current_observation_provider = p_provider where id = p_vineyard_id;
end;
$$;
revoke all on function public.set_vineyard_current_observation_provider(uuid, text) from public;
grant execute on function public.set_vineyard_current_observation_provider(uuid, text) to authenticated;

create or replace function public.get_vineyard_current_observation_provider(p_vineyard_id uuid)
returns text language plpgsql stable security definer set search_path = public
as $$
declare v_selected text;
begin
  if public.vineyard_member_role(p_vineyard_id) is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;
  select current_observation_provider into v_selected from public.vineyards where id = p_vineyard_id;
  return v_selected;
end;
$$;
revoke all on function public.get_vineyard_current_observation_provider(uuid) from public;
grant execute on function public.get_vineyard_current_observation_provider(uuid) to authenticated;

-- Keep the exact response contract from 104, including the 20-minute server clock.
create or replace function public.get_vineyard_current_weather(p_vineyard_id uuid)
returns table (
  source text, station_id text, station_name text, observed_at timestamptz,
  temperature_c double precision, humidity_pct double precision,
  wind_speed_kmh double precision, wind_direction_deg double precision,
  rain_today_mm double precision, rain_rate_mm_per_hr double precision,
  leaf_wetness double precision, wind_gust_kmh double precision,
  is_stale boolean, status text, message text
)
language plpgsql stable security definer set search_path = public
as $$
declare
  v_selected text;
  v_source text;
  v_station_id text;
  v_station_name text;
  v_obs record;
  v_is_stale boolean;
begin
  if public.vineyard_member_role(p_vineyard_id) is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;
  select v.current_observation_provider into v_selected
    from public.vineyards v where v.id = p_vineyard_id;

  -- Existing vineyards without an explicit selection keep Davis priority.
  if v_selected is null then
    select case i.provider when 'wunderground' then 'wunderground_pws' else 'davis_weatherlink' end
      into v_source
      from public.vineyard_weather_integrations i
     where i.vineyard_id = p_vineyard_id and i.is_active
       and ((i.provider = 'davis_weatherlink' and nullif(i.api_key, '') is not null
              and nullif(i.api_secret, '') is not null and nullif(i.station_id, '') is not null)
         or (i.provider = 'wunderground' and nullif(i.station_id, '') is not null))
     order by case i.provider when 'davis_weatherlink' then 0 else 1 end
     limit 1;
  else
    v_source := nullif(v_selected, 'none');
  end if;

  if v_source is not null then
    select i.station_id, i.station_name into v_station_id, v_station_name
      from public.vineyard_weather_integrations i
     where i.vineyard_id = p_vineyard_id
       and i.provider = case v_source when 'wunderground_pws' then 'wunderground' else 'davis_weatherlink' end
       and i.is_active and nullif(i.station_id, '') is not null
       and (v_source = 'wunderground_pws' or
            (nullif(i.api_key, '') is not null and nullif(i.api_secret, '') is not null))
     limit 1;
  end if;

  if v_source is null or v_station_id is null then
    return query select coalesce(v_source, 'none')::text, null::text, null::text, null::timestamptz,
      null::double precision, null::double precision, null::double precision, null::double precision,
      null::double precision, null::double precision, null::double precision, null::double precision,
      false, 'not_configured'::text, 'Live weather is not configured for this vineyard.'::text;
    return;
  end if;

  select * into v_obs from public.vineyard_weather_observations o
   where o.vineyard_id = p_vineyard_id and o.source = v_source
     and (o.station_id = v_station_id or
          (v_source = 'davis_weatherlink' and o.station_id is null))
   order by o.observed_at desc limit 1;
  if not found then
    return query select v_source, v_station_id, v_station_name, null::timestamptz,
      null::double precision, null::double precision, null::double precision, null::double precision,
      null::double precision, null::double precision, null::double precision, null::double precision,
      false, 'no_data'::text, 'No weather observation cached yet.'::text;
    return;
  end if;
  v_is_stale := (now() - v_obs.observed_at) > interval '20 minutes';
  return query select v_source, coalesce(v_obs.station_id, v_station_id)::text,
    coalesce(v_obs.station_name, v_station_name)::text, v_obs.observed_at,
    v_obs.temperature_c, v_obs.humidity_pct, v_obs.wind_speed_kmh, v_obs.wind_direction_deg,
    v_obs.rain_today_mm, v_obs.rain_rate_mm_per_hr, v_obs.leaf_wetness, v_obs.wind_gust_kmh,
    v_is_stale, 'ok'::text,
    case when v_is_stale then 'Latest reading is older than 20 minutes.' else 'ok' end::text;
end;
$$;
revoke all on function public.get_vineyard_current_weather(uuid) from public;
grant execute on function public.get_vineyard_current_weather(uuid) to authenticated;

-- 224: Append-only hourly weather evidence for trips. Run manually in Supabase.
begin;

create table if not exists public.trip_weather_observations (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  sample_slot timestamptz not null,
  observed_at timestamptz null,
  captured_at timestamptz not null default now(),
  source text not null,
  source_kind text not null,
  station_id text null,
  temperature_c double precision null,
  humidity_pct double precision null,
  wind_speed_kmh double precision null,
  wind_gust_kmh double precision null,
  wind_direction_deg double precision null,
  rain_mm double precision null,
  is_stale boolean not null default false,
  constraint trip_weather_observations_trip_slot_unique unique (trip_id, sample_slot),
  constraint trip_weather_observations_source_check check (btrim(source) <> ''),
  constraint trip_weather_observations_source_kind_check check (source_kind in ('observed','modelled','manual','unavailable')),
  constraint trip_weather_observations_temperature_check check (temperature_c is null or temperature_c between -90 and 70),
  constraint trip_weather_observations_humidity_check check (humidity_pct is null or humidity_pct between 0 and 100),
  constraint trip_weather_observations_wind_check check (wind_speed_kmh is null or wind_speed_kmh between 0 and 500),
  constraint trip_weather_observations_gust_check check (wind_gust_kmh is null or wind_gust_kmh between 0 and 500),
  constraint trip_weather_observations_direction_check check (wind_direction_deg is null or wind_direction_deg between 0 and 360),
  constraint trip_weather_observations_rain_check check (rain_mm is null or rain_mm between 0 and 2000),
  constraint trip_weather_observations_time_check check (observed_at is null or observed_at <= captured_at + interval '10 minutes')
);

create index if not exists trip_weather_observations_trip_slot_idx on public.trip_weather_observations(trip_id, sample_slot);
create index if not exists trip_weather_observations_vineyard_observed_idx on public.trip_weather_observations(vineyard_id, observed_at desc);

alter table public.trip_weather_observations enable row level security;
drop policy if exists trip_weather_observations_select_members on public.trip_weather_observations;
create policy trip_weather_observations_select_members on public.trip_weather_observations for select to authenticated
  using (public.is_vineyard_member(vineyard_id));
drop policy if exists trip_weather_observations_no_direct_insert on public.trip_weather_observations;
create policy trip_weather_observations_no_direct_insert on public.trip_weather_observations for insert to authenticated with check (false);
drop policy if exists trip_weather_observations_no_direct_update on public.trip_weather_observations;
create policy trip_weather_observations_no_direct_update on public.trip_weather_observations for update to authenticated using (false);
drop policy if exists trip_weather_observations_no_delete on public.trip_weather_observations;
create policy trip_weather_observations_no_delete on public.trip_weather_observations for delete to authenticated using (false);

revoke all on public.trip_weather_observations from public, anon, authenticated;
grant select on public.trip_weather_observations to authenticated, service_role;

create or replace function public.capture_trip_weather_observation_v1(
  p_trip_id uuid, p_sample_slot timestamptz, p_observed_at timestamptz,
  p_source text, p_source_kind text, p_station_id text default null,
  p_temperature_c double precision default null, p_humidity_pct double precision default null,
  p_wind_speed_kmh double precision default null, p_wind_gust_kmh double precision default null,
  p_wind_direction_deg double precision default null, p_rain_mm double precision default null,
  p_is_stale boolean default false
) returns public.trip_weather_observations
language plpgsql security definer set search_path = public
as $fn$
declare v_trip public.trips; v_result public.trip_weather_observations;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select * into v_trip from public.trips where id = p_trip_id and deleted_at is null;
  if v_trip.id is null then raise exception 'Trip not found' using errcode = 'P0002'; end if;
  if not public.has_vineyard_role(v_trip.vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'Operational vineyard access required' using errcode = '42501';
  end if;
  if not (coalesce(v_trip.trip_function, '') = 'spraying' or exists (
    select 1 from public.spray_records r where r.trip_id = v_trip.id and not r.is_template and r.deleted_at is null
  )) then raise exception 'Trip is not a spray trip' using errcode = '22023'; end if;
  if p_sample_slot is null or p_source_kind not in ('observed','modelled','manual','unavailable') or nullif(btrim(p_source),'') is null then
    raise exception 'Invalid weather observation' using errcode = '22023';
  end if;

  insert into public.trip_weather_observations(
    vineyard_id, trip_id, sample_slot, observed_at, source, source_kind, station_id,
    temperature_c, humidity_pct, wind_speed_kmh, wind_gust_kmh, wind_direction_deg, rain_mm, is_stale
  ) values (
    v_trip.vineyard_id, v_trip.id, p_sample_slot, p_observed_at,
    btrim(p_source), p_source_kind, nullif(btrim(p_station_id), ''), p_temperature_c,
    p_humidity_pct, p_wind_speed_kmh, p_wind_gust_kmh, p_wind_direction_deg, p_rain_mm, coalesce(p_is_stale,false)
  ) on conflict (trip_id, sample_slot) do update set
    observed_at = excluded.observed_at, captured_at = now(), source = excluded.source,
    source_kind = excluded.source_kind, station_id = excluded.station_id,
    temperature_c = excluded.temperature_c, humidity_pct = excluded.humidity_pct,
    wind_speed_kmh = excluded.wind_speed_kmh, wind_gust_kmh = excluded.wind_gust_kmh,
    wind_direction_deg = excluded.wind_direction_deg, rain_mm = excluded.rain_mm,
    is_stale = excluded.is_stale
  returning * into v_result;
  return v_result;
end;
$fn$;

revoke all on function public.capture_trip_weather_observation_v1(uuid,timestamptz,timestamptz,text,text,text,double precision,double precision,double precision,double precision,double precision,double precision,boolean) from public, anon;
grant execute on function public.capture_trip_weather_observation_v1(uuid,timestamptz,timestamptz,text,text,text,double precision,double precision,double precision,double precision,double precision,double precision,boolean) to authenticated;

commit;

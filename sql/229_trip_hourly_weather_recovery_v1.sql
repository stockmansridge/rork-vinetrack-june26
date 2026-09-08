-- 229: Durable hourly weather slots and provenance for Spray Reports.
-- Run manually after SQL 228. Does not alter or rerun SQL 224-228.
begin;

alter table public.trip_weather_observations
  add column if not exists retrieval_mode text not null default 'live',
  add column if not exists provider_record_id text,
  add column if not exists retrieved_at timestamptz not null default now();

alter table public.trip_weather_observations drop constraint if exists trip_weather_observations_retrieval_mode_check;
alter table public.trip_weather_observations add constraint trip_weather_observations_retrieval_mode_check
  check (retrieval_mode in ('live','historical_archive','legacy_snapshot','unavailable'));

create or replace function public.spray_weather_missing_slots_v1(p_trip_id uuid,p_through timestamptz default null)
returns table(sample_slot timestamptz) language plpgsql stable security definer set search_path=public as $fn$
declare t public.trips; through_at timestamptz;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select * into t from public.trips where id=p_trip_id and deleted_at is null;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if not public.is_vineyard_member(t.vineyard_id) then raise exception 'Vineyard membership required' using errcode='42501'; end if;
  if t.start_time is null then return; end if;
  through_at:=least(coalesce(p_through,t.end_time,now()),coalesce(t.end_time,p_through,now()));
  return query
    select candidate.slot from (
      select slot from generate_series(t.start_time,through_at,interval '1 hour') slot
      union
      select t.end_time where t.end_time is not null and t.end_time<=through_at
    ) candidate
    where not exists(select 1 from public.trip_weather_observations w where w.trip_id=t.id and w.sample_slot=candidate.slot and w.source_kind in ('observed','manual'))
    order by candidate.slot;
end $fn$;

-- Elevated provider functions use this after authenticating the initiating user and provider result.
create or replace function public.record_trip_weather_observation_v2(
  p_trip_id uuid,p_sample_slot timestamptz,p_observed_at timestamptz,p_source text,p_source_kind text,p_station_id text,
  p_temperature_c double precision,p_humidity_pct double precision,p_wind_speed_kmh double precision,p_wind_gust_kmh double precision,
  p_wind_direction_deg double precision,p_rain_mm double precision,p_is_stale boolean,p_retrieval_mode text,p_provider_record_id text
) returns public.trip_weather_observations language plpgsql security definer set search_path=public as $fn$
declare t public.trips; result public.trip_weather_observations; existing public.trip_weather_observations;
begin
  select * into t from public.trips where id=p_trip_id and deleted_at is null;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if p_sample_slot<t.start_time or p_sample_slot>coalesce(t.end_time,now())+interval '5 minutes' then raise exception 'Weather slot is outside the trip' using errcode='22023'; end if;
  if p_retrieval_mode not in ('live','historical_archive','legacy_snapshot','unavailable') or p_source_kind not in ('observed','modelled','manual','unavailable') then raise exception 'Invalid weather provenance' using errcode='22023'; end if;
  if p_retrieval_mode='historical_archive' and (p_observed_at is null or p_station_id is null) then raise exception 'Historical observations require original time and station identity' using errcode='22023'; end if;
  select * into existing from public.trip_weather_observations where trip_id=t.id and sample_slot=p_sample_slot for update;
  -- Genuine recorded evidence is immutable against unavailable/modelled retries.
  if existing.id is not null and existing.source_kind in ('observed','manual') and p_source_kind not in ('observed','manual') then return existing; end if;
  -- A live observation cannot replace a historical observation for a different time.
  if p_retrieval_mode='live' and p_observed_at is not null and abs(extract(epoch from (p_observed_at-p_sample_slot)))>1800 then raise exception 'Live observation is too far from its scheduled slot' using errcode='22023'; end if;
  insert into public.trip_weather_observations(vineyard_id,trip_id,sample_slot,observed_at,source,source_kind,station_id,temperature_c,humidity_pct,wind_speed_kmh,wind_gust_kmh,wind_direction_deg,rain_mm,is_stale,retrieval_mode,provider_record_id,retrieved_at)
  values(t.vineyard_id,t.id,p_sample_slot,p_observed_at,btrim(p_source),p_source_kind,nullif(btrim(p_station_id),''),p_temperature_c,p_humidity_pct,p_wind_speed_kmh,p_wind_gust_kmh,p_wind_direction_deg,p_rain_mm,p_is_stale,p_retrieval_mode,nullif(btrim(p_provider_record_id),''),now())
  on conflict(trip_id,sample_slot) do update set observed_at=excluded.observed_at,captured_at=now(),source=excluded.source,source_kind=excluded.source_kind,station_id=excluded.station_id,temperature_c=excluded.temperature_c,humidity_pct=excluded.humidity_pct,wind_speed_kmh=excluded.wind_speed_kmh,wind_gust_kmh=excluded.wind_gust_kmh,wind_direction_deg=excluded.wind_direction_deg,rain_mm=excluded.rain_mm,is_stale=excluded.is_stale,retrieval_mode=excluded.retrieval_mode,provider_record_id=excluded.provider_record_id,retrieved_at=excluded.retrieved_at
  where trip_weather_observations.source_kind not in ('observed','manual') or excluded.source_kind in ('observed','manual')
  returning * into result;
  return coalesce(result,existing);
end $fn$;

-- Existing client RPC remains compatible but can no longer replace genuine evidence with unavailable data.
create or replace function public.capture_trip_weather_observation_v1(
  p_trip_id uuid,p_sample_slot timestamptz,p_observed_at timestamptz,p_source text,p_source_kind text,p_station_id text default null,
  p_temperature_c double precision default null,p_humidity_pct double precision default null,p_wind_speed_kmh double precision default null,
  p_wind_gust_kmh double precision default null,p_wind_direction_deg double precision default null,p_rain_mm double precision default null,p_is_stale boolean default false
) returns public.trip_weather_observations language plpgsql security definer set search_path=public as $fn$
declare t public.trips;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select * into t from public.trips where id=p_trip_id and deleted_at is null;
  if t.id is null or not public.has_vineyard_role(t.vineyard_id,array['owner','manager','supervisor','operator']) then raise exception 'Operational vineyard access required' using errcode='42501'; end if;
  return public.record_trip_weather_observation_v2(p_trip_id,p_sample_slot,p_observed_at,p_source,p_source_kind,p_station_id,p_temperature_c,p_humidity_pct,p_wind_speed_kmh,p_wind_gust_kmh,p_wind_direction_deg,p_rain_mm,p_is_stale,case when p_source_kind='unavailable' then 'unavailable' else 'live' end,null);
end $fn$;

alter function public.get_spray_report_v1(uuid) rename to get_spray_report_v1_pre_weather_provenance_v1;
create or replace function public.get_spray_report_v1(p_trip_id uuid) returns jsonb language plpgsql security definer set search_path=public as $fn$
declare payload jsonb; r public.spray_records; weather_json jsonb;
begin
  payload:=public.get_spray_report_v1_pre_weather_provenance_v1(p_trip_id);
  select * into r from public.spray_records where id=(payload#>>'{identity,sprayRecordId}')::uuid;
  select coalesce(jsonb_agg(jsonb_build_object('sampleSlot',w.sample_slot,'observedAt',w.observed_at,'source',w.source,'sourceKind',w.source_kind,'stationId',w.station_id,'isStale',w.is_stale,'temperatureC',w.temperature_c,'humidityPct',w.humidity_pct,'windSpeedKmh',w.wind_speed_kmh,'windGustKmh',w.wind_gust_kmh,'windDirectionDeg',w.wind_direction_deg,'rainMm',w.rain_mm,'retrievalMode',w.retrieval_mode,'providerRecordId',w.provider_record_id,'retrievedAt',w.retrieved_at) order by w.sample_slot),'[]') into weather_json from public.trip_weather_observations w where w.trip_id=p_trip_id;
  if r.temperature is not null or r.humidity is not null or r.wind_speed is not null or nullif(r.wind_direction,'') is not null then
    weather_json:=jsonb_build_array(jsonb_build_object('sampleSlot',coalesce(r.start_time,r.date),'observedAt',coalesce(r.start_time,r.date),'source','Legacy start snapshot','sourceKind','manual','stationId',null,'isStale',true,'temperatureC',r.temperature,'humidityPct',r.humidity,'windSpeedKmh',r.wind_speed,'windGustKmh',null,'windDirectionDeg',null,'windDirectionText',r.wind_direction,'rainMm',null,'retrievalMode','legacy_snapshot','providerRecordId',null,'retrievedAt',null))||weather_json;
  end if;
  return jsonb_set(payload,'{weather}',weather_json);
end $fn$;

revoke all on function public.spray_weather_missing_slots_v1(uuid,timestamptz) from public,anon;
grant execute on function public.spray_weather_missing_slots_v1(uuid,timestamptz) to authenticated,service_role;
revoke all on function public.record_trip_weather_observation_v2(uuid,timestamptz,timestamptz,text,text,text,double precision,double precision,double precision,double precision,double precision,double precision,boolean,text,text) from public,anon,authenticated;
grant execute on function public.record_trip_weather_observation_v2(uuid,timestamptz,timestamptz,text,text,text,double precision,double precision,double precision,double precision,double precision,double precision,boolean,text,text) to service_role;
revoke all on function public.get_spray_report_v1_pre_weather_provenance_v1(uuid) from public,anon,authenticated;
revoke all on function public.get_spray_report_v1(uuid) from public,anon;
grant execute on function public.get_spray_report_v1(uuid) to authenticated;
commit;

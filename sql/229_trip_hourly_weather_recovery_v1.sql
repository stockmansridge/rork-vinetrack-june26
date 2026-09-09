-- 229: Durable hourly weather slots and provenance for Spray Reports.
-- Run manually after SQL 228. Safe for the earlier SQL 229 draft and does not alter or rerun SQL 224-227.
begin;
select pg_advisory_xact_lock(hashtext('vinetrack:spray-report-229-upgrade'));

alter table public.trip_weather_observations
  add column if not exists retrieval_mode text,
  add column if not exists provider text,
  add column if not exists station_name text,
  add column if not exists provider_record_id text,
  add column if not exists retrieved_at timestamptz;
update public.trip_weather_observations set
  retrieval_mode=case when source_kind='unavailable' then 'unavailable' else 'live' end,
  retrieved_at=captured_at
where retrieval_mode is null or retrieved_at is null;
alter table public.trip_weather_observations alter column retrieval_mode set default 'live';
alter table public.trip_weather_observations alter column retrieval_mode set not null;
alter table public.trip_weather_observations alter column retrieved_at set default now();
alter table public.trip_weather_observations alter column retrieved_at set not null;

create table if not exists public.trip_weather_retrieval_attempts (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  sample_slot timestamptz not null,
  provider text not null,
  station_id text,
  station_name text,
  retrieval_mode text not null,
  outcome text not null,
  observed_at timestamptz,
  source text,
  temperature_c double precision,
  humidity_pct double precision,
  wind_speed_kmh double precision,
  wind_gust_kmh double precision,
  wind_direction_deg double precision,
  rain_mm double precision,
  is_stale boolean,
  provider_record_id text,
  retrieved_at timestamptz not null default now(),
  constraint trip_weather_attempt_mode_check check (retrieval_mode in ('live','historical_archive','legacy_snapshot','unavailable')),
  constraint trip_weather_attempt_outcome_check check (outcome in ('observed','manual','modelled','unavailable','transient_error'))
);
create index if not exists trip_weather_retrieval_attempts_trip_idx on public.trip_weather_retrieval_attempts(trip_id,sample_slot,retrieved_at);
insert into public.trip_weather_retrieval_attempts(vineyard_id,trip_id,sample_slot,provider,station_id,station_name,retrieval_mode,outcome,observed_at,source,temperature_c,humidity_pct,wind_speed_kmh,wind_gust_kmh,wind_direction_deg,rain_mm,is_stale,provider_record_id,retrieved_at)
select w.vineyard_id,w.trip_id,w.sample_slot,coalesce(nullif(w.provider,''),'legacy_unknown'),w.station_id,w.station_name,w.retrieval_mode,w.source_kind,w.observed_at,w.source,w.temperature_c,w.humidity_pct,w.wind_speed_kmh,w.wind_gust_kmh,w.wind_direction_deg,w.rain_mm,w.is_stale,w.provider_record_id,w.retrieved_at
from public.trip_weather_observations w
where not exists (
  select 1 from public.trip_weather_retrieval_attempts a
  where a.trip_id=w.trip_id and a.sample_slot=w.sample_slot and a.retrieved_at=w.retrieved_at
    and a.outcome=w.source_kind and a.retrieval_mode=w.retrieval_mode
    and a.provider=coalesce(nullif(w.provider,''),'legacy_unknown')
    and a.station_id is not distinct from w.station_id
    and a.provider_record_id is not distinct from w.provider_record_id
);
alter table public.trip_weather_retrieval_attempts enable row level security;
drop policy if exists trip_weather_attempts_member_read on public.trip_weather_retrieval_attempts;
create policy trip_weather_attempts_member_read on public.trip_weather_retrieval_attempts for select to authenticated using (public.is_vineyard_member(vineyard_id));
revoke all on public.trip_weather_retrieval_attempts from public,anon,authenticated;
grant select on public.trip_weather_retrieval_attempts to authenticated;
grant select on public.trip_weather_retrieval_attempts to service_role;

create or replace function public.record_trip_weather_retrieval_attempt_v1(
  p_trip_id uuid,p_sample_slot timestamptz,p_provider text,p_station_id text,p_station_name text,p_retrieval_mode text,p_outcome text,p_source text default null
) returns uuid language plpgsql security definer set search_path=public as $fn$
declare t public.trips; new_id uuid;
begin
  if auth.role()<>'service_role' then raise exception 'Service weather authority required' using errcode='42501'; end if;
  select * into t from public.trips where id=p_trip_id and deleted_at is null;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if not (coalesce(t.trip_function,'')='spraying' or exists(select 1 from public.spray_records r where r.trip_id=t.id and not r.is_template and r.deleted_at is null)) then raise exception 'Trip is not a spray trip' using errcode='22023'; end if;
  if p_sample_slot<t.start_time or p_sample_slot>coalesce(t.end_time,now())+interval '5 minutes' or nullif(btrim(p_provider),'') is null or nullif(btrim(p_station_id),'') is null or p_retrieval_mode not in ('live','historical_archive') or p_outcome not in ('unavailable','transient_error') then raise exception 'Invalid weather retrieval attempt' using errcode='22023'; end if;
  insert into public.trip_weather_retrieval_attempts(vineyard_id,trip_id,sample_slot,provider,station_id,station_name,retrieval_mode,outcome,source)
  values(t.vineyard_id,t.id,p_sample_slot,btrim(p_provider),btrim(p_station_id),nullif(btrim(p_station_name),''),p_retrieval_mode,p_outcome,nullif(btrim(p_source),'')) returning id into new_id;
  return new_id;
end $fn$;

alter table public.trip_weather_observations drop constraint if exists trip_weather_observations_retrieval_mode_check;
alter table public.trip_weather_observations add constraint trip_weather_observations_retrieval_mode_check
  check (retrieval_mode in ('live','historical_archive','legacy_snapshot','unavailable'));

create or replace function public.spray_weather_missing_slots_v1(p_trip_id uuid,p_through timestamptz default null)
returns table(sample_slot timestamptz) language plpgsql stable security definer set search_path=public as $fn$
declare t public.trips; through_at timestamptz;
begin
  if auth.role()<>'service_role' and auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select * into t from public.trips where id=p_trip_id and deleted_at is null;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if auth.role()<>'service_role' and not public.is_vineyard_member(t.vineyard_id) then raise exception 'Vineyard membership required' using errcode='42501'; end if;
  if not (coalesce(t.trip_function,'')='spraying' or exists(select 1 from public.spray_records r where r.trip_id=t.id and not r.is_template and r.deleted_at is null)) then raise exception 'Trip is not a spray trip' using errcode='22023'; end if;
  if t.start_time is null then return; end if;
  through_at:=least(coalesce(p_through,t.end_time,now()),coalesce(t.end_time,p_through,now()));
  if through_at<t.start_time then raise exception 'Weather recovery end precedes trip start' using errcode='22023'; end if;
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
  p_wind_direction_deg double precision,p_rain_mm double precision,p_is_stale boolean,p_retrieval_mode text,p_provider_record_id text,
  p_provider text default null,p_station_name text default null
) returns public.trip_weather_observations language plpgsql security definer set search_path=public as $fn$
declare t public.trips; result public.trip_weather_observations; existing public.trip_weather_observations;
begin
  select * into t from public.trips where id=p_trip_id and deleted_at is null;
  if t.id is null then raise exception 'Trip not found' using errcode='P0002'; end if;
  if not (coalesce(t.trip_function,'')='spraying' or exists(select 1 from public.spray_records r where r.trip_id=t.id and not r.is_template and r.deleted_at is null)) then raise exception 'Trip is not a spray trip' using errcode='22023'; end if;
  if p_sample_slot<t.start_time or p_sample_slot>coalesce(t.end_time,now())+interval '5 minutes' then raise exception 'Weather slot is outside the trip' using errcode='22023'; end if;
  if p_retrieval_mode not in ('live','historical_archive','legacy_snapshot','unavailable') or p_source_kind not in ('observed','modelled','manual','unavailable') then raise exception 'Invalid weather provenance' using errcode='22023'; end if;
  if (p_retrieval_mode='historical_archive' and p_source_kind<>'observed') or (p_retrieval_mode='legacy_snapshot' and p_source_kind<>'manual') or (p_retrieval_mode='unavailable' and p_source_kind<>'unavailable') or (p_retrieval_mode='live' and p_source_kind='unavailable') then raise exception 'Weather retrieval mode and outcome do not agree' using errcode='22023'; end if;
  if p_retrieval_mode='historical_archive' and (p_observed_at is null or nullif(btrim(p_station_id),'') is null or nullif(btrim(p_provider),'') is null) then raise exception 'Historical observations require original time, provider, and station identity' using errcode='22023'; end if;
  if p_source_kind in ('observed','manual') and (p_observed_at is null or (p_temperature_c is null and p_humidity_pct is null and p_wind_speed_kmh is null and p_wind_gust_kmh is null and p_wind_direction_deg is null and p_rain_mm is null)) then raise exception 'Observed/manual weather requires a timestamp and at least one measured value' using errcode='22023'; end if;
  if p_source_kind='unavailable' and (p_observed_at is not null or p_temperature_c is not null or p_humidity_pct is not null or p_wind_speed_kmh is not null or p_wind_gust_kmh is not null or p_wind_direction_deg is not null or p_rain_mm is not null) then raise exception 'Unavailable weather cannot contain an observation' using errcode='22023'; end if;
  if p_observed_at is not null and abs(extract(epoch from (p_observed_at-p_sample_slot)))>1800 then raise exception 'Observation is too far from its scheduled slot' using errcode='22023'; end if;
  if (p_temperature_c is not null and (p_temperature_c<>p_temperature_c or p_temperature_c not between -90 and 70)) or (p_humidity_pct is not null and (p_humidity_pct<>p_humidity_pct or p_humidity_pct not between 0 and 100)) or (p_wind_speed_kmh is not null and (p_wind_speed_kmh<>p_wind_speed_kmh or p_wind_speed_kmh not between 0 and 500)) or (p_wind_gust_kmh is not null and (p_wind_gust_kmh<>p_wind_gust_kmh or p_wind_gust_kmh not between 0 and 500)) or (p_wind_direction_deg is not null and (p_wind_direction_deg<>p_wind_direction_deg or p_wind_direction_deg not between 0 and 360)) or (p_rain_mm is not null and (p_rain_mm<>p_rain_mm or p_rain_mm not between 0 and 2000)) then raise exception 'Weather measurement is outside the accepted range' using errcode='22023'; end if;
  insert into public.trip_weather_retrieval_attempts(vineyard_id,trip_id,sample_slot,provider,station_id,station_name,retrieval_mode,outcome,observed_at,source,temperature_c,humidity_pct,wind_speed_kmh,wind_gust_kmh,wind_direction_deg,rain_mm,is_stale,provider_record_id)
  values(t.vineyard_id,t.id,p_sample_slot,coalesce(nullif(btrim(p_provider),''),'legacy_or_manual'),nullif(btrim(p_station_id),''),nullif(btrim(p_station_name),''),p_retrieval_mode,p_source_kind,p_observed_at,btrim(p_source),p_temperature_c,p_humidity_pct,p_wind_speed_kmh,p_wind_gust_kmh,p_wind_direction_deg,p_rain_mm,p_is_stale,nullif(btrim(p_provider_record_id),''));
  select * into existing from public.trip_weather_observations where trip_id=t.id and sample_slot=p_sample_slot for update;
  -- Genuine recorded evidence is immutable against unavailable/modelled retries.
  if existing.id is not null and existing.source_kind in ('observed','manual') and p_source_kind not in ('observed','manual') then return existing; end if;
  insert into public.trip_weather_observations(vineyard_id,trip_id,sample_slot,observed_at,source,source_kind,station_id,temperature_c,humidity_pct,wind_speed_kmh,wind_gust_kmh,wind_direction_deg,rain_mm,is_stale,retrieval_mode,provider,station_name,provider_record_id,retrieved_at)
  values(t.vineyard_id,t.id,p_sample_slot,p_observed_at,btrim(p_source),p_source_kind,nullif(btrim(p_station_id),''),p_temperature_c,p_humidity_pct,p_wind_speed_kmh,p_wind_gust_kmh,p_wind_direction_deg,p_rain_mm,p_is_stale,p_retrieval_mode,nullif(btrim(p_provider),''),nullif(btrim(p_station_name),''),nullif(btrim(p_provider_record_id),''),now())
  on conflict(trip_id,sample_slot) do update set observed_at=excluded.observed_at,captured_at=now(),source=excluded.source,source_kind=excluded.source_kind,station_id=excluded.station_id,temperature_c=excluded.temperature_c,humidity_pct=excluded.humidity_pct,wind_speed_kmh=excluded.wind_speed_kmh,wind_gust_kmh=excluded.wind_gust_kmh,wind_direction_deg=excluded.wind_direction_deg,rain_mm=excluded.rain_mm,is_stale=excluded.is_stale,retrieval_mode=excluded.retrieval_mode,provider=excluded.provider,station_name=excluded.station_name,provider_record_id=excluded.provider_record_id,retrieved_at=excluded.retrieved_at
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
  if not (coalesce(t.trip_function,'')='spraying' or exists(select 1 from public.spray_records r where r.trip_id=t.id and not r.is_template and r.deleted_at is null)) then raise exception 'Trip is not a spray trip' using errcode='22023'; end if;
  return public.record_trip_weather_observation_v2(p_trip_id,p_sample_slot,p_observed_at,p_source,p_source_kind,p_station_id,p_temperature_c,p_humidity_pct,p_wind_speed_kmh,p_wind_gust_kmh,p_wind_direction_deg,p_rain_mm,p_is_stale,case when p_source_kind='unavailable' then 'unavailable' else 'live' end,null,null,null);
end $fn$;

do $upgrade$
begin
  if to_regprocedure('public.get_spray_report_v1_pre_weather_provenance_v1(uuid)') is null then
    alter function public.get_spray_report_v1(uuid) rename to get_spray_report_v1_pre_weather_provenance_v1;
  elsif to_regprocedure('public.get_spray_report_v1(uuid)') is null then
    raise exception 'Weather Spray Report base exists but its public wrapper is missing';
  end if;
end $upgrade$;
create or replace function public.get_spray_report_v1(p_trip_id uuid) returns jsonb language plpgsql security definer set search_path=public as $fn$
declare payload jsonb; r public.spray_records; weather_json jsonb;
begin
  payload:=public.get_spray_report_v1_pre_weather_provenance_v1(p_trip_id);
  select * into r from public.spray_records where id=(payload#>>'{identity,sprayRecordId}')::uuid;
  select coalesce(jsonb_agg(item order by sample_slot),'[]'::jsonb) into weather_json from (
    select w.sample_slot,jsonb_build_object('sampleSlot',w.sample_slot,'observedAt',w.observed_at,'source',w.source,'sourceKind',w.source_kind,'provider',w.provider,'stationId',w.station_id,'stationName',w.station_name,'isStale',w.is_stale,'temperatureC',w.temperature_c,'humidityPct',w.humidity_pct,'windSpeedKmh',w.wind_speed_kmh,'windGustKmh',w.wind_gust_kmh,'windDirectionDeg',w.wind_direction_deg,'rainMm',w.rain_mm,'retrievalMode',w.retrieval_mode,'providerRecordId',w.provider_record_id,'retrievedAt',w.retrieved_at,'retrievalHistory',coalesce((select jsonb_agg(jsonb_build_object('provider',a.provider,'stationId',a.station_id,'stationName',a.station_name,'retrievalMode',a.retrieval_mode,'outcome',a.outcome,'observedAt',a.observed_at,'source',a.source,'temperatureC',a.temperature_c,'humidityPct',a.humidity_pct,'windSpeedKmh',a.wind_speed_kmh,'windGustKmh',a.wind_gust_kmh,'windDirectionDeg',a.wind_direction_deg,'rainMm',a.rain_mm,'isStale',a.is_stale,'providerRecordId',a.provider_record_id,'retrievedAt',a.retrieved_at) order by a.retrieved_at) from public.trip_weather_retrieval_attempts a where a.trip_id=w.trip_id and a.sample_slot=w.sample_slot),'[]'::jsonb)) item
    from public.trip_weather_observations w where w.trip_id=p_trip_id
    union all
    select latest.sample_slot,jsonb_build_object('sampleSlot',latest.sample_slot,'observedAt',null,'source','Weather retrieval pending after transient provider failure','sourceKind','unavailable','provider',latest.provider,'stationId',latest.station_id,'stationName',latest.station_name,'isStale',false,'temperatureC',null,'humidityPct',null,'windSpeedKmh',null,'windGustKmh',null,'windDirectionDeg',null,'rainMm',null,'retrievalMode',latest.retrieval_mode,'providerRecordId',null,'retrievedAt',latest.retrieved_at,'retrievalHistory',(select jsonb_agg(jsonb_build_object('provider',a.provider,'stationId',a.station_id,'stationName',a.station_name,'retrievalMode',a.retrieval_mode,'outcome',a.outcome,'observedAt',a.observed_at,'source',a.source,'temperatureC',a.temperature_c,'humidityPct',a.humidity_pct,'windSpeedKmh',a.wind_speed_kmh,'windGustKmh',a.wind_gust_kmh,'windDirectionDeg',a.wind_direction_deg,'rainMm',a.rain_mm,'isStale',a.is_stale,'providerRecordId',a.provider_record_id,'retrievedAt',a.retrieved_at) order by a.retrieved_at) from public.trip_weather_retrieval_attempts a where a.trip_id=latest.trip_id and a.sample_slot=latest.sample_slot)) item
    from (select distinct on (a.trip_id,a.sample_slot) a.* from public.trip_weather_retrieval_attempts a where a.trip_id=p_trip_id order by a.trip_id,a.sample_slot,a.retrieved_at desc) latest
    where latest.outcome='transient_error' and not exists(select 1 from public.trip_weather_observations w where w.trip_id=latest.trip_id and w.sample_slot=latest.sample_slot)
  ) weather_items;
  if r.temperature is not null or r.humidity is not null or r.wind_speed is not null or nullif(r.wind_direction,'') is not null then
    weather_json:=jsonb_build_array(jsonb_build_object('sampleSlot',coalesce(r.start_time,r.date),'observedAt',coalesce(r.start_time,r.date),'source','Legacy start snapshot','sourceKind','manual','provider',null,'stationId',null,'stationName',null,'isStale',true,'temperatureC',r.temperature,'humidityPct',r.humidity,'windSpeedKmh',r.wind_speed,'windGustKmh',null,'windDirectionDeg',null,'windDirectionText',r.wind_direction,'rainMm',null,'retrievalMode','legacy_snapshot','providerRecordId',null,'retrievedAt',null,'retrievalHistory','[]'::jsonb))||weather_json;
  end if;
  return jsonb_set(payload,'{weather}',weather_json);
end $fn$;

revoke all on function public.spray_weather_missing_slots_v1(uuid,timestamptz) from public,anon;
revoke all on function public.record_trip_weather_retrieval_attempt_v1(uuid,timestamptz,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.record_trip_weather_retrieval_attempt_v1(uuid,timestamptz,text,text,text,text,text,text) to service_role;
grant execute on function public.spray_weather_missing_slots_v1(uuid,timestamptz) to authenticated,service_role;
revoke all on function public.record_trip_weather_observation_v2(uuid,timestamptz,timestamptz,text,text,text,double precision,double precision,double precision,double precision,double precision,double precision,boolean,text,text,text,text) from public,anon,authenticated;
grant execute on function public.record_trip_weather_observation_v2(uuid,timestamptz,timestamptz,text,text,text,double precision,double precision,double precision,double precision,double precision,double precision,boolean,text,text,text,text) to service_role;
revoke all on function public.get_spray_report_v1_pre_weather_provenance_v1(uuid) from public,anon,authenticated;
revoke all on function public.get_spray_report_v1(uuid) from public,anon;
grant execute on function public.get_spray_report_v1(uuid) to authenticated;
commit;

-- Rollback-only contract checks. Run after sql/224_trip_weather_observations.sql.
begin;

do $$ begin
  if to_regclass('public.trip_weather_observations') is null then raise exception 'trip_weather_observations missing'; end if;
  if to_regprocedure('public.capture_trip_weather_observation_v1(uuid,timestamptz,timestamptz,text,text,text,double precision,double precision,double precision,double precision,double precision,double precision,boolean)') is null then
    raise exception 'capture RPC missing';
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.trip_weather_observations'::regclass and conname='trip_weather_observations_trip_slot_unique') then
    raise exception 'trip/slot idempotency constraint missing';
  end if;
  if has_table_privilege('anon','public.trip_weather_observations','select') then raise exception 'anon can read weather'; end if;
  if has_table_privilege('authenticated','public.trip_weather_observations','insert') then raise exception 'authenticated can insert weather directly'; end if;
  if not has_table_privilege('authenticated','public.trip_weather_observations','select') then raise exception 'authenticated cannot read weather through RLS'; end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='trip_weather_observations' and policyname='trip_weather_observations_select_members') then
    raise exception 'member read policy missing';
  end if;
end $$;

rollback;

-- Rollback-only contract checks for SQL 229. Run manually after migration 229.
begin;
do $test$
declare body text;
begin
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='trip_weather_observations' and column_name='retrieval_mode') then raise exception 'T1: retrieval mode missing'; end if;
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='trip_weather_observations' and column_name='provider_record_id') then raise exception 'T2: provider identity missing'; end if;
  if to_regprocedure('public.spray_weather_missing_slots_v1(uuid,timestamp with time zone)') is null then raise exception 'T3: durable missing-slot query missing'; end if;
  if to_regprocedure('public.record_trip_weather_observation_v2(uuid,timestamp with time zone,timestamp with time zone,text,text,text,double precision,double precision,double precision,double precision,double precision,double precision,boolean,text,text)') is null then raise exception 'T4: provider write boundary missing'; end if;
  if has_function_privilege('authenticated','public.record_trip_weather_observation_v2(uuid,timestamp with time zone,timestamp with time zone,text,text,text,double precision,double precision,double precision,double precision,double precision,double precision,boolean,text,text)','execute') then raise exception 'T5: elevated provider write exposed to clients'; end if;
  body:=pg_get_functiondef('public.record_trip_weather_observation_v2(uuid,timestamp with time zone,timestamp with time zone,text,text,text,double precision,double precision,double precision,double precision,double precision,double precision,boolean,text,text)'::regprocedure);
  if body not like '%historical_archive%' or body not like '%original time and station identity%' then raise exception 'T6: historical provenance guard missing'; end if;
  if body not like '%source_kind in (''observed'',''manual'')%' then raise exception 'T7: genuine evidence overwrite guard missing'; end if;
  body:=pg_get_functiondef('public.spray_weather_missing_slots_v1(uuid,timestamp with time zone)'::regprocedure);
  if body not like '%generate_series%' or body not like '%source_kind in (''observed'',''manual'')%' then raise exception 'T8: restart-safe slot recovery missing'; end if;
  body:=pg_get_functiondef('public.get_spray_report_v1(uuid)'::regprocedure);
  if body not like '%stationId%' or body not like '%retrievalMode%' or body not like '%Legacy start snapshot%' then raise exception 'T9: report weather provenance/legacy snapshot missing'; end if;
  raise notice 'SQL 229 contract tests passed (transaction will roll back).';
end $test$;
rollback;

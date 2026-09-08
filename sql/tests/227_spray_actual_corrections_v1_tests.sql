-- Run manually after sql/227_spray_actual_corrections_v1.sql. Rolls back all test work.
begin;

do $test$
begin
  if to_regclass('public.spray_tank_actual_amendments') is null then raise exception 'T1 FAILED: amendment table missing'; end if;
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='spray_tank_actuals' and column_name='correction_version') then raise exception 'T2 FAILED: correction version missing'; end if;
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='spray_tank_actuals' and column_name='water_volume_l' and is_nullable<>'YES') then raise exception 'T3 FAILED: water must allow Not recorded'; end if;
  if to_regprocedure('public.correct_spray_tank_actual_v1(uuid,uuid,uuid,uuid,text,integer,bigint,double precision,jsonb)') is null then raise exception 'T4 FAILED: correction RPC missing'; end if;
  if has_function_privilege('anon','public.correct_spray_tank_actual_v1(uuid,uuid,uuid,uuid,text,integer,bigint,double precision,jsonb)','execute') then raise exception 'T5 FAILED: anon can correct actuals'; end if;
  if not has_function_privilege('authenticated','public.correct_spray_tank_actual_v1(uuid,uuid,uuid,uuid,text,integer,bigint,double precision,jsonb)','execute') then raise exception 'T6 FAILED: authenticated role cannot call correction RPC'; end if;
  if has_table_privilege('authenticated','public.spray_tank_actual_amendments','insert') or has_table_privilege('authenticated','public.spray_tank_actual_amendments','update') or has_table_privilege('authenticated','public.spray_tank_actual_amendments','delete') then raise exception 'T7 FAILED: audit table permits direct writes'; end if;
  if not has_table_privilege('authenticated','public.spray_tank_actual_amendments','select') then raise exception 'T8 FAILED: members cannot read history through RLS'; end if;
  if pg_get_functiondef('public.upsert_spray_tank_actual(uuid,uuid,uuid,uuid,text,integer,double precision,jsonb,timestamp with time zone,timestamp with time zone)'::regprocedure) not like '%correction_version=0%' then raise exception 'T9 FAILED: stale offline replay guard missing'; end if;
  if pg_get_functiondef('public.spray_report_tanks_v1(jsonb,uuid)'::regprocedure) not like '%actualOnly%' then raise exception 'T10 FAILED: canonical actual-only output missing'; end if;
  if pg_get_functiondef('public.get_spray_report_v1(uuid)'::regprocedure) not like '%amendments%' then raise exception 'T11 FAILED: report history missing'; end if;
  if pg_get_functiondef('public.get_spray_report_v1(uuid)'::regprocedure) not like '%actualChemicalTotals%' then raise exception 'T11b FAILED: actual totals missing'; end if;
  if not exists(select 1 from pg_constraint where conrelid='public.spray_tank_actual_amendments'::regclass and conname='spray_actual_amendments_operation_field_unique') then raise exception 'T12 FAILED: idempotency constraint missing'; end if;
  raise notice 'SQL 227 contract checks passed';
end $test$;

rollback;

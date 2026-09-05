-- Rollback-only Phase 5 contract checks. Run after sql/223_spray_tank_actuals.sql.
begin;

do $test$
begin
  if to_regclass('public.spray_tank_actuals') is null then raise exception 'spray_tank_actuals missing'; end if;
  if not exists (
    select 1 from pg_constraint where conrelid = 'public.spray_tank_actuals'::regclass
      and conname = 'spray_tank_actuals_trip_session_unique'
  ) then raise exception 'trip/session unique constraint missing'; end if;
  if not public.validate_spray_tank_actual_chemicals(
    '[{"id":"10000000-0000-4000-8000-000000000001","plannedChemicalId":null,"savedChemicalId":null,"name":"Water conditioner","actualAmountBase":0,"unit":"mL"}]'::jsonb
  ) then raise exception 'confirmed zero should be valid'; end if;
  if public.validate_spray_tank_actual_chemicals(
    '[{"id":"10000000-0000-4000-8000-000000000001","plannedChemicalId":null,"savedChemicalId":null,"name":"Bad","actualAmountBase":-1,"unit":"mL"}]'::jsonb
  ) then raise exception 'negative amount accepted'; end if;
  if public.validate_spray_tank_actual_chemicals('[]'::jsonb) is not true then
    raise exception 'empty confirmed chemical list should be valid';
  end if;
  if has_function_privilege('anon', 'public.upsert_spray_tank_actual(uuid,uuid,uuid,uuid,text,integer,double precision,jsonb,timestamptz,timestamptz)', 'execute') then
    raise exception 'anon can execute actual-use RPC';
  end if;
  if not has_function_privilege('authenticated', 'public.upsert_spray_tank_actual(uuid,uuid,uuid,uuid,text,integer,double precision,jsonb,timestamptz,timestamptz)', 'execute') then
    raise exception 'authenticated role cannot execute actual-use RPC';
  end if;
end;
$test$;

rollback;

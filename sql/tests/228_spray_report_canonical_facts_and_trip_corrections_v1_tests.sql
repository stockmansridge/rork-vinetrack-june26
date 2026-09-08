-- Rollback-only contract checks for SQL 228. Run manually after migration 228.
begin;
do $test$
declare body text;
begin
  if to_regclass('public.spray_trip_corrections') is null or to_regclass('public.spray_trip_correction_amendments') is null then raise exception 'T1: correction authority/history missing'; end if;
  if to_regclass('public.spray_row_assignment_evidence') is null then raise exception 'T2: row evidence missing'; end if;
  if to_regprocedure('public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision)') is null then raise exception 'T3: metadata correction RPC missing'; end if;
  if to_regprocedure('public.recover_spray_row_assignments_v1(uuid,uuid,jsonb)') is null then raise exception 'T4: row recovery RPC missing'; end if;
  if has_table_privilege('authenticated','public.spray_trip_corrections','insert') or has_table_privilege('authenticated','public.spray_trip_correction_amendments','update') or has_table_privilege('authenticated','public.spray_row_assignment_evidence','delete') then raise exception 'T5: direct writes are open'; end if;
  body:=pg_get_functiondef('public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision)'::regprocedure);
  if body not like '%40001%' or body not like '%operation_id%' or body not like '%has_vineyard_role%' then raise exception 'T6: conflict/idempotency/role contract missing'; end if;
  if body not like '%fuel_consumption_l_per_hour%' or body not like '%spray_equipment_id%' then raise exception 'T7: fuel or spray-unit correction missing'; end if;
  body:=pg_get_functiondef('public.recover_spray_row_assignments_v1(uuid,uuid,jsonb)'::regprocedure);
  if body not like '%confidence<0.9%' or body not like '%block_id%' or body not like '%originalEvidence%' then raise exception 'T8: geometry threshold or evidence preservation missing'; end if;
  body:=pg_get_functiondef('public.get_spray_report_v1(uuid)'::regprocedure);
  foreach body in array array['%plannedChemicalTotals%','%tankSessions%','%programStep%','%treatedAreaHa%','%fuelConsumptionSource%','%metadataAmendments%'] loop
    if pg_get_functiondef('public.get_spray_report_v1(uuid)'::regprocedure) not like body then raise exception 'T9: canonical field missing: %',body; end if;
  end loop;
  if has_function_privilege('anon','public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision)','execute') then raise exception 'T10: anon correction execution open'; end if;
  raise notice 'SQL 228 contract tests passed (transaction will roll back).';
end $test$;
rollback;

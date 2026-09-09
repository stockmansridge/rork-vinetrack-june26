-- Rollback-only contract checks for SQL 228. Run manually after migration 228.
begin;
do $test$
declare body text;
begin
  if to_regclass('public.spray_trip_corrections') is null or to_regclass('public.spray_trip_correction_amendments') is null or to_regclass('public.spray_trip_correction_operations') is null then raise exception 'T1: correction authority/history missing'; end if;
  if to_regclass('public.spray_row_assignment_evidence') is null or to_regclass('public.spray_row_recovery_operations') is null then raise exception 'T2: row evidence or operation authority missing'; end if;
  if to_regprocedure('public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision)') is null then raise exception 'T3: metadata correction RPC missing'; end if;
  if to_regprocedure('public.recover_spray_row_assignments_v1(uuid,uuid,uuid,jsonb)') is null then raise exception 'T4: row recovery RPC missing'; end if;
  if has_table_privilege('authenticated','public.spray_trip_corrections','insert') or has_table_privilege('authenticated','public.spray_trip_correction_amendments','update') or has_table_privilege('authenticated','public.spray_row_assignment_evidence','delete') then raise exception 'T5: direct writes are open'; end if;
  body:=pg_get_functiondef('public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision)'::regprocedure);
  if body not like '%40001%' or body not like '%request_fingerprint%' or body not like '%reused for a different request%' or body not like '%has_vineyard_role%' then raise exception 'T6: conflict/idempotency/role contract missing'; end if;
  if body not like '%fuel_consumption_l_per_hour%' or body not like '%spray_equipment_id%' then raise exception 'T7: fuel or spray-unit correction missing'; end if;
  body:=pg_get_functiondef('public.recover_spray_row_assignments_v1(uuid,uuid,uuid,jsonb)'::regprocedure);
  if body not like '%confidence<0.9%' or body not like '%spray-row-recovery-v1%' or body not like '%auth.role()%service_role%' or body not like '%matchingRowIds%' or body not like '%assignment_fingerprint%' or body not like '%must occur exactly once%' then raise exception 'T8: shared derivation, service boundary, geometry threshold, or evidence validation missing'; end if;
  body:=pg_get_functiondef('public.get_spray_report_v1(uuid)'::regprocedure);
  foreach body in array array['%plannedChemicalTotals%','%tankSessions%','%programStep%','%treatedAreaHa%','%fuelConsumptionSource%','%metadataAmendments%'] loop
    if pg_get_functiondef('public.get_spray_report_v1(uuid)'::regprocedure) not like body then raise exception 'T9: canonical field missing: %',body; end if;
  end loop;
  if has_function_privilege('anon','public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision)','execute') then raise exception 'T10: anon correction execution open'; end if;
  if has_function_privilege('authenticated','public.recover_spray_row_assignments_v1(uuid,uuid,uuid,jsonb)','execute') or not has_function_privilege('service_role','public.recover_spray_row_assignments_v1(uuid,uuid,uuid,jsonb)','execute') then raise exception 'T11: row recovery must be service-only'; end if;
  body:=pg_get_functiondef('public.get_spray_report_v1(uuid)'::regprocedure);
  if body not like '%missing_worker_type_rate%' or body not like '%missing_or_ambiguous_chemical_unit_price%' or body not like '%weighted recorded purchases%' then raise exception 'T12: implemented costing or specific missing-data reasons absent'; end if;
  if public.spray_report_safe_number_v1('1e999') is not null or public.spray_report_safe_number_v1('NaN') is not null or public.spray_report_safe_number_v1('not-a-number') is not null or public.spray_report_safe_number_v1('12.5') is distinct from 12.5 then raise exception 'T13: exception-safe legacy number parsing missing'; end if;
  if to_regprocedure('public.recover_spray_row_assignments_v1(uuid,uuid,jsonb)') is not null then raise exception 'T14: obsolete client-write row recovery RPC remains exposed'; end if;
  if exists(select 1 from public.spray_row_assignment_evidence where tank_session_id is null) then raise exception 'T15: row evidence session identity was not normalized'; end if;
  raise notice 'SQL 228 contract tests passed (transaction will roll back).';
end $test$;
rollback;

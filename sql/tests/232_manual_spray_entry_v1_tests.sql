-- Rollback-only contract checks for SQL 232. Run manually only after applying SQL 232.
begin;
do $test$
declare save_body text; delete_body text; report_body text; guard_body text;
begin
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='spray_records' and column_name='entry_source') then raise exception 'T1: spray provenance missing'; end if;
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='trips' and column_name='manual_entry_id') then raise exception 'T2: trip manual identity missing'; end if;
  if to_regclass('public.manual_spray_operations') is null or to_regclass('public.manual_spray_tombstones') is null then raise exception 'T3: retry/deletion authority missing'; end if;
  if to_regprocedure('public.save_manual_spray_v1(uuid,jsonb,integer)') is null then raise exception 'T4: save RPC missing'; end if;
  if to_regprocedure('public.delete_manual_spray_v1(uuid,uuid,uuid,uuid,uuid)') is null then raise exception 'T5: delete RPC missing'; end if;
  if has_function_privilege('anon','public.save_manual_spray_v1(uuid,jsonb,integer)','execute') or has_function_privilege('service_role','public.save_manual_spray_v1(uuid,jsonb,integer)','execute') then raise exception 'T6: save execution exposed outside authenticated clients'; end if;
  if has_table_privilege('authenticated','public.manual_spray_operations','insert') or has_table_privilege('authenticated','public.manual_spray_tombstones','delete') then raise exception 'T7: operation/tombstone direct writes are open'; end if;
  save_body:=pg_get_functiondef('public.save_manual_spray_v1(uuid,jsonb,integer)'::regprocedure);
  foreach guard_body in array array['%owner%' ,'%manager%','%supervisor%','%Operation id was reused%','%Manual spray version conflict%','%manual_spray_tombstones%','%spray_tank_actuals%','%is_active%false%','%tank_sessions%','%physicalForm%','%productCategory%'] loop
    if save_body not like guard_body then raise exception 'T8: save contract clause missing: %',guard_body; end if;
  end loop;
  if save_body like '%array[''owner'',''manager'',''supervisor'',''operator'']%' then raise exception 'T9: Operator was granted manual save'; end if;
  delete_body:=pg_get_functiondef('public.delete_manual_spray_v1(uuid,uuid,uuid,uuid,uuid)'::regprocedure);
  if delete_body not like '%manual_spray_tombstones%' or delete_body not like '%spray_tank_actuals%' or delete_body not like '%entry_source=''manual''%' then raise exception 'T10: coordinated tombstone delete is incomplete'; end if;
  guard_body:=pg_get_functiondef('public.manual_spray_guard_v1()'::regprocedure);
  if guard_body not like '%new.entry_source:=''manual''%' or guard_body not like '%Deleted manual sprays cannot be revived%' then raise exception 'T11: old-client provenance/revival guard missing'; end if;
  report_body:=pg_get_functiondef('public.get_spray_report_v1(uuid)'::regprocedure);
  foreach guard_body in array array['%schemaVersion%','%1.2%','%provenance%','%Manual entry%','%manually_recorded_actual_use%','%Not recorded — manual application%','%plannedWaterLitres%' ] loop
    if report_body not like guard_body then raise exception 'T12: report contract clause missing: %',guard_body; end if;
  end loop;
  if public.manual_spray_number_v1('1.25'::jsonb,'test',true) is distinct from 1.25 then raise exception 'T13: finite-number decoder failed'; end if;
  raise notice 'SQL 232 structural/permission/report contract tests passed (transaction will roll back).';
end $test$;
rollback;

-- 231_pin_location_enrichment_tests.sql — rollback-only contract verification
begin;

do $$
declare body text;
begin
  if to_regclass('public.pin_capture_evidence') is null then raise exception 'T1 evidence table missing'; end if;
  if to_regclass('public.pin_location_geometry_history') is null then raise exception 'T2 geometry history missing'; end if;
  if to_regclass('public.pin_location_enrichment_queue') is null then raise exception 'T3 queue missing'; end if;
  if to_regclass('public.pin_location_enrichment_audit') is null then raise exception 'T4 audit missing'; end if;
  if to_regprocedure('public.fail_pin_location_enrichment(uuid,integer,text,uuid,text)') is null then raise exception 'T5 durable failure RPC missing'; end if;
  if to_regprocedure('public.confirm_saved_pin_location(uuid,integer,uuid,numeric,numeric,text,double precision,double precision,numeric)') is null then raise exception 'T6 confirmation RPC missing'; end if;
  if to_regprocedure('public.reverse_pin_location_enrichment(uuid)') is null then raise exception 'T7 reversal RPC missing'; end if;

  body:=pg_get_functiondef('public.commit_pin_location_enrichment(uuid,integer,text,uuid)'::regprocedure);
  if body not like '%lease_expires_at <= now()%' or body not like '%location_confirmation_revision%' or body not like '%partial_block_only%' or body not like '%conflict_overlapping_blocks%' then
    raise exception 'T8 lease/conflict/partial/manual precedence contract missing';
  end if;
  body:=pg_get_functiondef('public.fail_pin_location_enrichment(uuid,integer,text,uuid,text)'::regprocedure);
  if body not like '%technical_failure_terminal%' or body not like '%power(2%' or body not like '%terminal_at%' then
    raise exception 'T9 durable capped backoff contract missing';
  end if;
  body:=pg_get_functiondef('public.reverse_pin_location_enrichment(uuid)'::regprocedure);
  if body not like '%conflict_later_edit%' or body not like '%after_placement%' then raise exception 'T10 guarded reversal missing'; end if;

  if has_function_privilege('authenticated','public.claim_pin_location_enrichment(integer,integer)','execute') then raise exception 'T11 client can claim jobs'; end if;
  if has_function_privilege('authenticated','public.commit_pin_location_enrichment(uuid,integer,text,uuid)','execute') then raise exception 'T12 client can commit jobs'; end if;
  if has_table_privilege('authenticated','public.pin_location_enrichment_audit','select') then raise exception 'T13 client can read worker audit'; end if;
  if not has_table_privilege('authenticated','public.pin_capture_evidence','insert') then raise exception 'T14 client cannot upload evidence'; end if;
end $$;

rollback;

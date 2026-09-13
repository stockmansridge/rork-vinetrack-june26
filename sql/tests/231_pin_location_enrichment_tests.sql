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
  if to_regprocedure('public.confirm_saved_pin_location_v2(uuid,uuid,integer,integer,uuid,numeric,numeric,text,double precision,double precision,numeric)') is null then raise exception 'T6 durable confirmation RPC missing'; end if;
  if to_regprocedure('public.insert_pin_capture_evidence(jsonb)') is null then raise exception 'T6b immutable insert-or-verify RPC missing'; end if;
  if to_regprocedure('public.reverse_pin_location_enrichment(uuid)') is null then raise exception 'T7 reversal RPC missing'; end if;

  body:=pg_get_functiondef('public.commit_pin_location_enrichment(uuid,integer,text,uuid)'::regprocedure);
  if body !~ 'lease_expires_at[[:space:]]*<=[[:space:]]*now\(\)' then
    raise exception 'T8a expired-lease rejection contract missing';
  end if;
  if position('location_confirmation_revision' in body)=0 then
    raise exception 'T8b manual-confirmation precedence contract missing';
  end if;
  if position('partial_block_only' in body)=0 then
    raise exception 'T8c partial block outcome contract missing';
  end if;
  if position('conflict_overlapping_blocks' in body)=0 then
    raise exception 'T8d overlapping-block conflict contract missing';
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

do $$
declare v_pin uuid:=gen_random_uuid(); v_hash_a text; v_hash_b text; v_claimed integer;
begin
  -- Executable canonical identity: unrelated ids/metadata cannot change it.
  v_hash_a:=public.pin_geometry_identity('[{"id":"a","latitude":-33.0,"longitude":149.0},{"latitude":-33.1,"longitude":149.1},{"latitude":-33.2,"longitude":149.0}]'::jsonb,
    '[{"id":"x","number":1,"startPoint":{"latitude":-33.0,"longitude":149.0},"endPoint":{"latitude":-33.2,"longitude":149.0}}]'::jsonb);
  v_hash_b:=public.pin_geometry_identity('[{"id":"different","latitude":-33.0,"longitude":149.0},{"latitude":-33.1,"longitude":149.1},{"latitude":-33.2,"longitude":149.0}]'::jsonb,
    '[{"id":"different","number":1,"startPoint":{"latitude":-33.0,"longitude":149.0},"endPoint":{"latitude":-33.2,"longitude":149.0},"vineCountOverride":99}]'::jsonb);
  if v_hash_a is distinct from v_hash_b or v_hash_a not like 'pin-geometry-v1:%' then raise exception 'T15 canonical geometry identity includes unrelated metadata'; end if;

  -- Missing heading and unsupported history stays honestly unresolved.
  if public.resolve_pin_row_geometry('[]'::jsonb,'[]'::jsonb,gen_random_uuid(),-33,149,3,null,null,now(),'Left',null,'[]'::jsonb,3) is not null then
    raise exception 'T16 insufficient capture evidence invented a row';
  end if;

  -- Two resolver versions are independent idempotency keys, and an expired
  -- final attempt becomes explicitly terminal rather than remaining stranded.
  insert into public.pin_location_enrichment_queue(pin_id,evidence_revision,resolver_version,attempts,lease_token,lease_expires_at)
  values(v_pin,1,'fixture-v1',8,gen_random_uuid(),now()-interval '1 second'),(v_pin,1,'fixture-v2',0,null,null);
  perform set_config('request.jwt.claims',json_build_object('role','service_role')::text,true);
  select count(*) into v_claimed from public.claim_pin_location_enrichment(10,30);
  if v_claimed<>1 then raise exception 'T17 resolver-version idempotency key was collapsed'; end if;
  if not exists(select 1 from public.pin_location_enrichment_queue where pin_id=v_pin and resolver_version='fixture-v1' and terminal_at is not null) then
    raise exception 'T18 expired final lease was not terminalized';
  end if;
  if not exists(select 1 from public.pin_location_enrichment_audit where pin_id=v_pin and resolver_version='fixture-v1' and outcome='technical_failure_terminal') then
    raise exception 'T19 expired final lease terminal audit missing';
  end if;
end $$;

rollback;

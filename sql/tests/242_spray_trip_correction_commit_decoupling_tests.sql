begin;

do $test$
declare
  body text;
begin
  if to_regprocedure('public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision)') is null then
    raise exception 'T1: correction RPC missing';
  end if;

  body := pg_get_functiondef('public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision)'::regprocedure);
  if body like '%get_spray_report_v1%' then
    raise exception 'T2: correction commit still depends on report reconstruction';
  end if;
  if body not like '%Trip is not a spray trip%' then
    raise exception 'T3: explicit spray-trip validation missing';
  end if;
  if body not like '%has_vineyard_role%' or body not like '%40001%' then
    raise exception 'T4: authorization or stale-version rejection missing';
  end if;
  if body not like '%request_fingerprint%' or body not like '%reused for a different request%' then
    raise exception 'T5: operation idempotency contract missing';
  end if;
  if body not like '%spray_trip_correction_amendments%' or body not like '%spray_trip_correction_operations%' then
    raise exception 'T6: audit history or durable operation record missing';
  end if;
  if body not like '%jsonb_build_object(''correction'',to_jsonb(c))%' then
    raise exception 'T7: direct correction metadata response missing';
  end if;
  if has_table_privilege('authenticated','public.spray_trip_corrections','insert')
     or has_table_privilege('authenticated','public.spray_trip_corrections','update')
     or has_table_privilege('authenticated','public.spray_trip_correction_amendments','insert') then
    raise exception 'T8: protected correction tables permit direct writes';
  end if;
  if has_function_privilege('anon','public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision)','execute') then
    raise exception 'T9: anonymous correction execution open';
  end if;
  if not has_function_privilege('authenticated','public.correct_spray_trip_metadata_v1(uuid,uuid,bigint,uuid,uuid,uuid,uuid,double precision,double precision,double precision)','execute') then
    raise exception 'T10: authenticated correction execution missing';
  end if;

  raise notice 'SQL 242 correction commit-decoupling contract tests passed (transaction will roll back).';
end $test$;

rollback;

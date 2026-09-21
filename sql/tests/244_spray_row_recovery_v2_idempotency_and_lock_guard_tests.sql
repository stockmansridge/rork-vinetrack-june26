begin;

do $test$
declare
  body text;
  operation_pos integer;
  lock_pos integer;
  historical_pos integer;
  geometry_pos integer;
begin
  if to_regprocedure('public.recover_spray_row_assignments_v2(uuid,uuid,uuid,jsonb)') is null then
    raise exception 'T1: V2 recovery RPC missing';
  end if;
  if has_function_privilege('service_role','public.recover_spray_row_assignments_v1(uuid,uuid,uuid,jsonb)','execute') then
    raise exception 'T2: V1 must remain revoked from service_role';
  end if;
  if exists(
       select 1
       from pg_proc p
       cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) privilege
       where p.oid='public.recover_spray_row_assignments_v2(uuid,uuid,uuid,jsonb)'::regprocedure
         and privilege.grantee=0 and privilege.privilege_type='EXECUTE'
     )
     or has_function_privilege('anon','public.recover_spray_row_assignments_v2(uuid,uuid,uuid,jsonb)','execute')
     or has_function_privilege('authenticated','public.recover_spray_row_assignments_v2(uuid,uuid,uuid,jsonb)','execute')
     or not has_function_privilege('service_role','public.recover_spray_row_assignments_v2(uuid,uuid,uuid,jsonb)','execute') then
    raise exception 'T3: V2 must remain service-role-only';
  end if;
  if not exists(
    select 1 from pg_indexes
    where schemaname='public'
      and indexname='spray_row_recovery_operations_trip_fingerprint_v2_uidx'
      and indexdef like '%trip_id, assignment_fingerprint%'
      and indexdef like '%UNIQUE%'
  ) then
    raise exception 'T4: logical trip/fingerprint uniqueness missing';
  end if;
  if to_regclass('public.spray_row_recovery_trip_guard') is null then
    raise exception 'T5: per-trip rate guard missing';
  end if;

  body := pg_get_functiondef('public.recover_spray_row_assignments_v2(uuid,uuid,uuid,jsonb)'::regprocedure);
  operation_pos := strpos(body, 'where operation_id=p_operation_id');
  lock_pos := strpos(body, 'pg_try_advisory_xact_lock');
  historical_pos := strpos(body, 'immutable historical evidence');
  geometry_pos := strpos(body, 'Block identity is not available in this vineyard');
  if operation_pos=0 or lock_pos=0 or operation_pos>=lock_pos then
    raise exception 'T6: operation replay must be checked before the concurrency lock';
  end if;
  if body like '%where id=p_trip_id and deleted_at is null for update%' then
    raise exception 'T7: V2 must not queue on a trip FOR UPDATE lock';
  end if;
  if body not like '%pg_try_advisory_xact_lock%'
     or body not like '%already_in_progress%'
     or body not like '%rate_limited%'
     or body not like '%interval ''2 seconds''%'
     or body not like '%accepted_count >= 5%' then
    raise exception 'T8: concurrency or rate circuit breaker missing';
  end if;
  if historical_pos=0 or geometry_pos=0 or historical_pos>=geometry_pos
     or body not like '%historical_evidence_preserved%'
     or body not like '%Existing historical recovery evidence was preserved unchanged%' then
    raise exception 'T9: historical evidence must be preserved before current-geometry validation';
  end if;
  if body not like '%jsonb_agg(normalized order by%'
     or body not like '%assignment_fingerprint=fingerprint%'
     or body not like '%already_recovered%' then
    raise exception 'T10: canonical logical idempotency missing';
  end if;
end
$test$;

rollback;

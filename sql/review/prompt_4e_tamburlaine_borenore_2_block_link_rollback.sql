-- Prompt 4E — guarded Tamburlaine Borenore conditional ROLLBACK (2 pins)
-- Run only after separate approval. Refuses to overwrite every subsequent edit.
begin transaction isolation level serializable;
do $preflight$ begin if to_regclass('public.pin_block_link_repair_audit') is null then raise exception 'APPLY_NOT_COMMITTED: audit table missing'; end if; end;$preflight$;
do $rollback$
declare
 v_run_id constant uuid:='0aa13b8d-0ff7-48cb-92f5-91e94fc593f7'; v_vineyard_id constant uuid:='a18654f6-13ed-4438-998b-7a7e1d89181a';
 v_expected_count constant integer:=2;
 v_expected constant jsonb:=$expected$[{"pin_id":"9bfe8744-2eaa-46bc-89c9-caace6308487","proposed_block_id":"29475366-3795-47bf-add9-85b259bbcb47","proposed_block_name":"Block 5 Grenache"},{"pin_id":"a56b6275-0f83-472f-b239-0ce0a7fa6c16","proposed_block_id":"29475366-3795-47bf-add9-85b259bbcb47","proposed_block_name":"Block 5 Grenache"}]$expected$::jsonb;
 v_item record; v_current jsonb; v_restored jsonb; v_count integer; v_changed integer:=0;
begin
 perform pg_advisory_xact_lock(hashtextextended(v_run_id::text,0));
 select count(*)::integer into v_count from public.pin_block_link_repair_audit where run_id=v_run_id;
 if v_count<>v_expected_count then raise exception 'AUDIT_PRECONDITION_FAILED: expected %, found %',v_expected_count,v_count; end if;
 if exists(select 1 from jsonb_to_recordset(v_expected)e(pin_id uuid,proposed_block_id uuid)
  left join public.pin_block_link_repair_audit a on a.run_id=v_run_id and a.pin_id=e.pin_id
  where a.pin_id is null or a.vineyard_id<>v_vineyard_id or a.target_paddock_id<>e.proposed_block_id
     or (a.before_row->>'paddock_id') is not null) then raise exception 'AUDIT_MAPPING_MISMATCH'; end if;
 if not exists(select 1 from public.pin_block_link_repair_audit a left join public.pins p on p.id=a.pin_id
  where a.run_id=v_run_id and (a.status<>'rolled_back' or a.rollback_after_row is null or to_jsonb(p) is distinct from a.rollback_after_row)) then
  raise notice 'Run % is already rolled back exactly; no rows changed.',v_run_id; return; end if;
 if exists(select 1 from public.pin_block_link_repair_audit where run_id=v_run_id and (status<>'applied' or rollback_after_row is not null)) then
  raise exception 'AUDIT_PRECONDITION_FAILED: not exact applied state'; end if;
 perform p.id from public.pins p join jsonb_to_recordset(v_expected)e(pin_id uuid) on e.pin_id=p.id order by p.id for update of p;
 get diagnostics v_count=row_count; if v_count<>v_expected_count then raise exception 'PIN_SET_PRECONDITION_FAILED'; end if;
 for v_item in select a.* from jsonb_to_recordset(v_expected)e(pin_id uuid,proposed_block_id uuid)
  join public.pin_block_link_repair_audit a on a.run_id=v_run_id and a.pin_id=e.pin_id order by a.pin_id for update of a loop
  select to_jsonb(p) into v_current from public.pins p where p.id=v_item.pin_id;
  if v_current is distinct from v_item.after_row then raise exception 'SUBSEQUENT_EDIT_REFUSAL: pin %',v_item.pin_id; end if;
  update public.pins p set paddock_id=nullif(v_item.before_row->>'paddock_id','')::uuid,sync_version=p.sync_version+1
   where p.id=v_item.pin_id and p.vineyard_id=v_vineyard_id and p.paddock_id=v_item.target_paddock_id
     and to_jsonb(p)=v_item.after_row returning to_jsonb(p) into v_restored;
  if v_restored is null then raise exception 'ROLLBACK_CONCURRENCY_FAILED: pin %',v_item.pin_id; end if;
  if (v_restored-array['paddock_id','updated_at','sync_version']::text[])
      is distinct from (v_item.before_row-array['paddock_id','updated_at','sync_version']::text[])
     or v_restored->>'paddock_id' is not null
     or (v_restored->>'sync_version')::integer<>(v_item.after_row->>'sync_version')::integer+1 then
    raise exception 'ROLLBACK_FIELD_GUARD_FAILED: pin %',v_item.pin_id; end if;
  update public.pin_block_link_repair_audit set status='rolled_back',rollback_after_row=v_restored,rolled_back_at=clock_timestamp()
   where run_id=v_run_id and pin_id=v_item.pin_id and status='applied' and rollback_after_row is null;
  get diagnostics v_count=row_count; if v_count<>1 then raise exception 'ROLLBACK_AUDIT_FAILED: pin %',v_item.pin_id; end if;
  v_changed:=v_changed+1;
 end loop;
 if v_changed<>v_expected_count then raise exception 'ROLLBACK_COUNT_FAILED'; end if;
end;$rollback$;
commit;
select a.run_id,count(*)::integer audited_pin_count,count(*) filter(where a.status='rolled_back')::integer rolled_back_count,
 bool_and(to_jsonb(p)=a.rollback_after_row) rollback_verified
from public.pin_block_link_repair_audit a left join public.pins p on p.id=a.pin_id
where a.run_id='0aa13b8d-0ff7-48cb-92f5-91e94fc593f7'::uuid group by a.run_id;

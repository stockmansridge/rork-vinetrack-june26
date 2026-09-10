-- Prompt 4E — Tamburlaine Boomey verification (1 pins), READ ONLY
begin transaction isolation level repeatable read read only;
do $preflight$ begin if to_regclass('public.pin_block_link_repair_audit') is null then raise exception 'APPLY_NOT_COMMITTED: audit table missing'; end if; end;$preflight$;
with expected as (
  select * from jsonb_to_recordset($expected$[{"pin_id":"9174dcae-8859-4a6b-ab27-eca1f59084ce","proposed_block_id":"90c9d26e-0f48-4be6-ac23-92707b56d367","proposed_block_name":"Block 7"}]$expected$::jsonb)
    e(pin_id uuid,proposed_block_id uuid,proposed_block_name text)
), checks as (
 select e.*,a.status,a.before_row,a.after_row,p.paddock_id,p.sync_version,p.updated_at,pd.name current_block_name,
  coalesce(a.run_id='891c96f1-7a54-4858-a0a1-b0865eb5de00'::uuid and a.vineyard_id='2c1d6be9-b5e4-42ec-a328-5c734ef87bf1'::uuid
   and a.target_paddock_id=e.proposed_block_id and a.status='applied'
   and (a.before_row->>'paddock_id') is null and (a.after_row->>'paddock_id')::uuid=e.proposed_block_id
   and (a.after_row->>'sync_version')::integer=(a.before_row->>'sync_version')::integer+1
   and (a.after_row-array['paddock_id','updated_at','sync_version']::text[])
       =(a.before_row-array['paddock_id','updated_at','sync_version']::text[])
   and to_jsonb(p)=a.after_row and pd.vineyard_id='2c1d6be9-b5e4-42ec-a328-5c734ef87bf1'::uuid
   and pd.deleted_at is null and pd.name=e.proposed_block_name,false) repair_verified
 from expected e left join public.pin_block_link_repair_audit a on a.run_id='891c96f1-7a54-4858-a0a1-b0865eb5de00'::uuid and a.pin_id=e.pin_id
 left join public.pins p on p.id=e.pin_id left join public.paddocks pd on pd.id=p.paddock_id
), scope as (select count(*)::integer n from public.pin_block_link_repair_audit where run_id='891c96f1-7a54-4858-a0a1-b0865eb5de00'::uuid)
select 'Tamburlaine Boomey'::text vineyard_name,'891c96f1-7a54-4858-a0a1-b0865eb5de00'::uuid run_id,
 count(*)::integer expected_pin_count,scope.n audited_pin_count,
 count(*) filter(where repair_verified)::integer verified_pin_count,
 (count(*)=1 and scope.n=1 and bool_and(repair_verified)) package_verified
from checks cross join scope group by scope.n;

with expected as (select * from jsonb_to_recordset($expected$[{"pin_id":"9174dcae-8859-4a6b-ab27-eca1f59084ce","proposed_block_id":"90c9d26e-0f48-4be6-ac23-92707b56d367","proposed_block_name":"Block 7"}]$expected$::jsonb)e(pin_id uuid,proposed_block_id uuid,proposed_block_name text))
select e.pin_id,e.proposed_block_id expected_block_id,e.proposed_block_name expected_block_name,
 a.status audit_status,p.paddock_id current_block_id,pd.name current_block_name,
 to_jsonb(p)=a.after_row current_matches_audited_after,
 (a.after_row-array['paddock_id','updated_at','sync_version']::text[])=(a.before_row-array['paddock_id','updated_at','sync_version']::text[]) unrelated_fields_unchanged
from expected e left join public.pin_block_link_repair_audit a on a.run_id='891c96f1-7a54-4858-a0a1-b0865eb5de00'::uuid and a.pin_id=e.pin_id
left join public.pins p on p.id=e.pin_id left join public.paddocks pd on pd.id=p.paddock_id order by e.pin_id;
commit;

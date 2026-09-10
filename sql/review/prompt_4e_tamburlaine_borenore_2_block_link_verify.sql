-- Prompt 4E — Tamburlaine Borenore verification (2 pins), READ ONLY
begin transaction isolation level repeatable read read only;
do $preflight$ begin if to_regclass('public.pin_block_link_repair_audit') is null then raise exception 'APPLY_NOT_COMMITTED: audit table missing'; end if; end;$preflight$;
with expected as (
  select * from jsonb_to_recordset($expected$[{"pin_id":"9bfe8744-2eaa-46bc-89c9-caace6308487","proposed_block_id":"29475366-3795-47bf-add9-85b259bbcb47","proposed_block_name":"Block 5 Grenache"},{"pin_id":"a56b6275-0f83-472f-b239-0ce0a7fa6c16","proposed_block_id":"29475366-3795-47bf-add9-85b259bbcb47","proposed_block_name":"Block 5 Grenache"}]$expected$::jsonb)
    e(pin_id uuid,proposed_block_id uuid,proposed_block_name text)
), checks as (
 select e.*,a.status,a.before_row,a.after_row,p.paddock_id,p.sync_version,p.updated_at,pd.name current_block_name,
  coalesce(a.run_id='0aa13b8d-0ff7-48cb-92f5-91e94fc593f7'::uuid and a.vineyard_id='a18654f6-13ed-4438-998b-7a7e1d89181a'::uuid
   and a.target_paddock_id=e.proposed_block_id and a.status='applied'
   and (a.before_row->>'paddock_id') is null and (a.after_row->>'paddock_id')::uuid=e.proposed_block_id
   and (a.after_row->>'sync_version')::integer=(a.before_row->>'sync_version')::integer+1
   and (a.after_row-array['paddock_id','updated_at','sync_version']::text[])
       =(a.before_row-array['paddock_id','updated_at','sync_version']::text[])
   and to_jsonb(p)=a.after_row and pd.vineyard_id='a18654f6-13ed-4438-998b-7a7e1d89181a'::uuid
   and pd.deleted_at is null and pd.name=e.proposed_block_name,false) repair_verified
 from expected e left join public.pin_block_link_repair_audit a on a.run_id='0aa13b8d-0ff7-48cb-92f5-91e94fc593f7'::uuid and a.pin_id=e.pin_id
 left join public.pins p on p.id=e.pin_id left join public.paddocks pd on pd.id=p.paddock_id
), scope as (select count(*)::integer n from public.pin_block_link_repair_audit where run_id='0aa13b8d-0ff7-48cb-92f5-91e94fc593f7'::uuid)
select 'Tamburlaine Borenore'::text vineyard_name,'0aa13b8d-0ff7-48cb-92f5-91e94fc593f7'::uuid run_id,
 count(*)::integer expected_pin_count,scope.n audited_pin_count,
 count(*) filter(where repair_verified)::integer verified_pin_count,
 (count(*)=2 and scope.n=2 and bool_and(repair_verified)) package_verified
from checks cross join scope group by scope.n;

with expected as (select * from jsonb_to_recordset($expected$[{"pin_id":"9bfe8744-2eaa-46bc-89c9-caace6308487","proposed_block_id":"29475366-3795-47bf-add9-85b259bbcb47","proposed_block_name":"Block 5 Grenache"},{"pin_id":"a56b6275-0f83-472f-b239-0ce0a7fa6c16","proposed_block_id":"29475366-3795-47bf-add9-85b259bbcb47","proposed_block_name":"Block 5 Grenache"}]$expected$::jsonb)e(pin_id uuid,proposed_block_id uuid,proposed_block_name text))
select e.pin_id,e.proposed_block_id expected_block_id,e.proposed_block_name expected_block_name,
 a.status audit_status,p.paddock_id current_block_id,pd.name current_block_name,
 to_jsonb(p)=a.after_row current_matches_audited_after,
 (a.after_row-array['paddock_id','updated_at','sync_version']::text[])=(a.before_row-array['paddock_id','updated_at','sync_version']::text[]) unrelated_fields_unchanged
from expected e left join public.pin_block_link_repair_audit a on a.run_id='0aa13b8d-0ff7-48cb-92f5-91e94fc593f7'::uuid and a.pin_id=e.pin_id
left join public.pins p on p.id=e.pin_id left join public.paddocks pd on pd.id=p.paddock_id order by e.pin_id;
commit;

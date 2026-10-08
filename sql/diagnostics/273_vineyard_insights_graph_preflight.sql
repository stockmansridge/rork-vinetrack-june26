-- READ ONLY. Jonathan: run separately BEFORE applying 273, after 272.
-- No automatic repair is authorised. All tenancy/path findings (including
-- historical tombstones) must be investigated before constraint validation.
select 'assessment_visit' as relationship, a.id as child_id, a.vineyard_id as child_vineyard,
       a.scout_visit_id as parent_id, v.vineyard_id as parent_vineyard
from public.scout_block_assessments a left join public.scout_visits v on v.id=a.scout_visit_id
where a.vineyard_id is distinct from v.vineyard_id
union all
select 'assessment_block', a.id,a.vineyard_id,a.paddock_id,p.vineyard_id
from public.scout_block_assessments a left join public.paddocks p on p.id=a.paddock_id
where a.vineyard_id is distinct from p.vineyard_id
union all
select 'observation_assessment',o.id,o.vineyard_id,o.assessment_id,a.vineyard_id
from public.scout_observations o left join public.scout_block_assessments a on a.id=o.assessment_id
where o.vineyard_id is distinct from a.vineyard_id
union all
select 'photo_observation',p.id,p.vineyard_id,p.observation_id,o.vineyard_id
from public.scout_observation_photos p left join public.scout_observations o on o.id=p.observation_id
where p.vineyard_id is distinct from o.vineyard_id
union all
select 'observation_pin',o.id,o.vineyard_id,o.linked_pin_id,p.vineyard_id
from public.scout_observations o left join public.pins p on p.id=o.linked_pin_id
where o.linked_pin_id is not null and o.vineyard_id is distinct from p.vineyard_id
union all
select 'observation_growth',o.id,o.vineyard_id,o.linked_growth_record_id,g.vineyard_id
from public.scout_observations o left join public.growth_stage_records g on g.id=o.linked_growth_record_id
where o.linked_growth_record_id is not null and o.vineyard_id is distinct from g.vineyard_id
order by relationship,child_id;

select id,vineyard_id,observation_id from public.scout_observation_photos
where lower(split_part(storage_path,'/',1)) <> vineyard_id::text
   or lower(split_part(storage_path,'/',2)) <> observation_id::text;

-- Recovery diagnostics, not instructions to delete/relabel evidence.
select a.id as removed_assessment_id,o.id as observation_id
from public.scout_block_assessments a join public.scout_observations o on o.assessment_id=a.id
where a.deleted_at is not null and o.deleted_at is null;

select scout_visit_id,paddock_id,count(*) from public.scout_block_assessments
where deleted_at is null group by scout_visit_id,paddock_id having count(*)>1;
select assessment_id,item_kind,count(*) from public.scout_observations
where deleted_at is null group by assessment_id,item_kind having count(*)>1;

select t.relname,c.conname,pg_get_constraintdef(c.oid) as definition
from pg_constraint c join pg_class t on t.oid=c.conrelid
where c.conrelid in ('public.scout_block_assessments'::regclass,
 'public.scout_observations'::regclass,'public.scout_observation_photos'::regclass)
order by t.relname,c.conname;

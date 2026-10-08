-- NEW migration. Source only; NOT executed.
-- Prerequisites: existing Insights 236/237/240/243 and Prompt 1's 272.
-- PostgreSQL 15+ (column-specific ON DELETE SET NULL).
-- Jonathan must first inspect sql/diagnostics/273_vineyard_insights_graph_preflight.sql.
-- Nonzero tenancy/path findings require an independently reviewed repair; this
-- migration deliberately fails validation rather than guessing historical repairs.
begin;

-- Composite keys make graph tenancy a concurrent database invariant, in both
-- directions. Existing UUID identities, original FKs, cascades and RLS remain.
create unique index insights_visit_tenant_key on public.scout_visits(id,vineyard_id);
create unique index insights_assessment_tenant_key on public.scout_block_assessments(id,vineyard_id);
create unique index insights_observation_tenant_key on public.scout_observations(id,vineyard_id);
create unique index insights_paddock_tenant_key on public.paddocks(id,vineyard_id);
create unique index insights_pin_tenant_key on public.pins(id,vineyard_id);
create unique index insights_growth_tenant_key on public.growth_stage_records(id,vineyard_id);

alter table public.scout_block_assessments
 add constraint insights_assessment_visit_tenant_fk foreign key(scout_visit_id,vineyard_id)
 references public.scout_visits(id,vineyard_id) on delete cascade not valid,
 add constraint insights_assessment_block_tenant_fk foreign key(paddock_id,vineyard_id)
 references public.paddocks(id,vineyard_id) on delete cascade not valid;
alter table public.scout_observations
 add constraint insights_observation_assessment_tenant_fk foreign key(assessment_id,vineyard_id)
 references public.scout_block_assessments(id,vineyard_id) on delete cascade not valid,
 add constraint insights_observation_pin_tenant_fk foreign key(linked_pin_id,vineyard_id)
 references public.pins(id,vineyard_id) on delete set null(linked_pin_id) not valid,
 add constraint insights_observation_growth_tenant_fk foreign key(linked_growth_record_id,vineyard_id)
 references public.growth_stage_records(id,vineyard_id) on delete set null(linked_growth_record_id) not valid;
alter table public.scout_observation_photos
 add constraint insights_photo_observation_tenant_fk foreign key(observation_id,vineyard_id)
 references public.scout_observations(id,vineyard_id) on delete cascade not valid,
 add constraint insights_photo_path_tenant_ck check (
 lower(split_part(storage_path,'/',1))=vineyard_id::text and
 lower(split_part(storage_path,'/',2))=observation_id::text) not valid;

alter table public.scout_block_assessments validate constraint insights_assessment_visit_tenant_fk;
alter table public.scout_block_assessments validate constraint insights_assessment_block_tenant_fk;
alter table public.scout_observations validate constraint insights_observation_assessment_tenant_fk;
alter table public.scout_observations validate constraint insights_observation_pin_tenant_fk;
alter table public.scout_observations validate constraint insights_observation_growth_tenant_fk;
alter table public.scout_observation_photos validate constraint insights_photo_observation_tenant_fk;
alter table public.scout_observation_photos validate constraint insights_photo_path_tenant_ck;

-- Removing an untouched selected block is an explicit assessment tombstone in
-- the existing revision queue, NOT a whole-Scout deletion or inferred omission.
-- Serialise child content writes with removal using the assessment row lock.
create function public._insights_guard_assessment_removal()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare a public.scout_block_assessments%rowtype;
begin
 if tg_table_name='scout_block_assessments' then
  if tg_op='UPDATE' and (new.vineyard_id is distinct from old.vineyard_id
    or new.scout_visit_id is distinct from old.scout_visit_id or new.paddock_id is distinct from old.paddock_id) then
   raise exception 'INSIGHTS_ASSESSMENT_PARENT_IMMUTABLE' using errcode='23514';
  end if;
  if tg_op='UPDATE' and old.deleted_at is not null then
   if new.deleted_at is null then
    raise exception 'INSIGHTS_REMOVED_ASSESSMENT_CANNOT_BE_RESTORED' using errcode='23514';
   end if;
   -- Never move the original removal date during a newer queue replay.
   new.deleted_at:=old.deleted_at;
  elsif new.deleted_at is not null then
   if exists(select 1 from public.scout_observations o where o.assessment_id=new.id
     and o.deleted_at is null and (nullif(btrim(o.notes),'') is not null
       or (o.value_code is not null and o.value_code<>'not_assessed')
       or o.location_status='gps_confirmed' or o.linked_pin_id is not null
       or o.linked_growth_record_id is not null
       or exists(select 1 from public.scout_observation_photos p where p.observation_id=o.id and p.deleted_at is null))) then
    raise exception 'INSIGHTS_BLOCK_CONTAINS_OBSERVATIONS' using errcode='23514';
   end if;
  end if;
  return new;
 end if;
 if tg_table_name='scout_observations' then
  select * into a from public.scout_block_assessments where id=new.assessment_id for update;
 else
  select b.* into a from public.scout_block_assessments b
   join public.scout_observations o on o.assessment_id=b.id where o.id=new.observation_id for update of b;
 end if;
 if not found then raise exception 'INSIGHTS_PARENT_MISSING' using errcode='23503'; end if;
 if tg_table_name='scout_observations' and tg_op='UPDATE' then
  -- FK cleanup must not be treated as a client revision reuse or an attempt
  -- to revive removed evidence. Only disappearing canonical links may differ.
  if (to_jsonb(new)-array['linked_pin_id','linked_growth_record_id','updated_at']::text[])
       is not distinct from (to_jsonb(old)-array['linked_pin_id','linked_growth_record_id','updated_at']::text[])
     and (new.linked_pin_id is not distinct from old.linked_pin_id or
       (new.linked_pin_id is null and not exists(select 1 from public.pins where id=old.linked_pin_id)))
     and (new.linked_growth_record_id is not distinct from old.linked_growth_record_id or
       (new.linked_growth_record_id is null and not exists(select 1 from public.growth_stage_records where id=old.linked_growth_record_id)))
     and (new.linked_pin_id is distinct from old.linked_pin_id or new.linked_growth_record_id is distinct from old.linked_growth_record_id) then
   new.client_revision_id:=gen_random_uuid();
   return new;
  end if;
 end if;
 if a.deleted_at is not null then
  -- Permit cleanup of already-existing metadata, but never new active evidence.
  if tg_op='INSERT' or new.deleted_at is null then
   raise exception 'INSIGHTS_PARENT_ASSESSMENT_REMOVED' using errcode='23514';
  end if;
 end if;
 return new;
end $$;
revoke all on function public._insights_guard_assessment_removal() from public,anon,authenticated;
create trigger aa_insights_assessment_removal before insert or update on public.scout_block_assessments
 for each row execute function public._insights_guard_assessment_removal();
create trigger aa_insights_observation_parent before insert or update on public.scout_observations
 for each row execute function public._insights_guard_assessment_removal();
create trigger aa_insights_photo_parent before insert or update on public.scout_observation_photos
 for each row execute function public._insights_guard_assessment_removal();

-- No permission widening, canonical Growth Stage writes, data backfill, or
-- changes to hard_delete_scout_visit, its ledger or Storage cleanup transaction.
commit;

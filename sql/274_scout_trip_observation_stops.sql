-- REVIEW ONLY: Jonathan must apply before enabling repeated-stop synchronization.
-- Does not edit/rerun 272 or 273. No rows, IDs, links, revisions or permissions are rewritten.
-- Each existing assessment is the legacy stop; new stops use new assessment UUIDs.
-- Old queued rows omit stop_context and therefore preserve it on conflict updates.
-- Existing client revision guards, graph FKs, visit/tenant immutability, deletion ledger and
-- photo cleanup remain authoritative. Observation item uniqueness stays per assessment.
-- Deploy new clients together: old clients can read repeated rows but their block-toggle UI
-- was designed for one stop and should not be used to author new multi-stop trips.
begin;
alter table public.scout_block_assessments
  add column stop_context jsonb;
alter table public.scout_block_assessments
  add constraint scout_stop_context_object_ck check (
    stop_context is null or (
      jsonb_typeof(stop_context) = 'object'
      and stop_context ? 'captured_at' and stop_context ? 'is_draft'
      and jsonb_typeof(stop_context->'captured_at') = 'string'
      and jsonb_typeof(stop_context->'is_draft') = 'boolean'
    )
  );
-- The assessment PK is the stop identity; paddock_id is grouping, not identity.
drop index public.scout_block_assessments_unique_active_idx;
create index scout_block_assessments_active_block_stops_idx
  on public.scout_block_assessments(scout_visit_id,paddock_id,id)
  where deleted_at is null;
comment on column public.scout_block_assessments.stop_context is
  'Per-stop capture, observer, weather and measured GPS snapshot; NULL denotes legacy evidence with unknown stop metadata.';
-- Narrow extension of the 273 guard: a new-style stop can correct its block
-- only before linking canonical Growth Stage evidence. Legacy rows stay immutable.
-- All removal, tenant, child-parent and canonical-FK cleanup rules are retained.
create or replace function public._insights_guard_assessment_removal()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare a public.scout_block_assessments%rowtype;
begin
 if tg_table_name='scout_block_assessments' then
  if tg_op='UPDATE' and (new.vineyard_id is distinct from old.vineyard_id
    or new.scout_visit_id is distinct from old.scout_visit_id) then
   raise exception 'INSIGHTS_ASSESSMENT_PARENT_IMMUTABLE' using errcode='23514';
  end if;
  if tg_op='UPDATE' and new.paddock_id is distinct from old.paddock_id then
   if old.stop_context is null or new.stop_context is null or old.deleted_at is not null
     or exists(select 1 from public.scout_observations o where o.assessment_id=old.id
       and o.deleted_at is null and (o.linked_pin_id is not null or o.linked_growth_record_id is not null)) then
    raise exception 'INSIGHTS_LINKED_STOP_BLOCK_IMMUTABLE' using errcode='23514';
   end if;
  end if;
  if tg_op='UPDATE' and old.deleted_at is not null then
   if new.deleted_at is null then
    raise exception 'INSIGHTS_REMOVED_ASSESSMENT_CANNOT_BE_RESTORED' using errcode='23514';
   end if;
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
  if tg_op='INSERT' or new.deleted_at is null then
   raise exception 'INSIGHTS_PARENT_ASSESSMENT_REMOVED' using errcode='23514';
  end if;
 end if;
 return new;
end $$;
revoke all on function public._insights_guard_assessment_removal() from public,anon,authenticated;
commit;
-- No rollback removing this column/index is safe once repeated-stop records exist.
-- Roll back client exposure instead; retain all captured evidence and queued work.

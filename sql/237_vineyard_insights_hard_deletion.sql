-- 237_vineyard_insights_hard_deletion.sql
-- Vineyard Insights history hard deletion and anti-resurrection contract.
-- NOT APPLIED. Apply only after sql/236_vineyard_insights_round1.sql.

begin;

-- Register the previously shipped Android/iOS catalogue item without changing 236.
insert into public.operational_tool_catalogue (tool_id, display_order, added_in)
values ('resistance_planner', 130, 'sql/237')
on conflict (tool_id) do nothing;

create table public.vineyard_insights_deletions (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete restrict,
  entity_type text not null check (entity_type in ('scout_visit', 'vintage_note')),
  entity_id uuid not null,
  deleted_at timestamptz not null default now(),
  deleted_by uuid not null references auth.users(id),
  operation_id uuid not null unique,
  unique (entity_type, entity_id)
);

create index vineyard_insights_deletions_pull_idx
  on public.vineyard_insights_deletions (vineyard_id, deleted_at, id);

alter table public.vineyard_insights_deletions enable row level security;
create policy vineyard_insights_deletions_select
on public.vineyard_insights_deletions for select to authenticated
using (public.can_use_vineyard_insights(vineyard_id));
revoke all on public.vineyard_insights_deletions from public, anon;
grant select on public.vineyard_insights_deletions to authenticated;

create table public.scout_photo_cleanup_queue (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete restrict,
  scout_visit_id uuid not null,
  photo_id uuid not null,
  storage_path text not null,
  status text not null default 'pending' check (status in ('pending','delivering','completed','failed')),
  attempt_count integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  leased_at timestamptz,
  lease_expires_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (photo_id, storage_path)
);

create index scout_photo_cleanup_queue_delivery_idx
  on public.scout_photo_cleanup_queue (status, next_attempt_at)
  where status in ('pending','failed');
alter table public.scout_photo_cleanup_queue enable row level security;
revoke all on public.scout_photo_cleanup_queue from public, anon, authenticated;

create or replace function public._reject_deleted_vineyard_insights_entity()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_type text := tg_argv[0];
begin
  perform pg_advisory_xact_lock(hashtextextended(v_type || ':' || new.id::text, 0));
  if auth.uid() is not null and (
      (tg_op = 'INSERT' and new.deleted_at is not null)
      or (tg_op = 'UPDATE' and new.deleted_at is distinct from old.deleted_at)
  ) then
    raise exception using errcode = '42501', message = 'HARD_DELETE_RPC_REQUIRED';
  end if;
  if exists (
    select 1 from public.vineyard_insights_deletions d
    where d.entity_type = v_type and d.entity_id = new.id
  ) then
    raise exception using errcode = '23505', message = 'DELETED_ENTITY_CANNOT_BE_RESURRECTED';
  end if;
  return new;
end;
$$;
revoke all on function public._reject_deleted_vineyard_insights_entity() from public, anon, authenticated;

create trigger scout_visits_reject_resurrection
before insert or update on public.scout_visits
for each row execute function public._reject_deleted_vineyard_insights_entity('scout_visit');

create trigger vintage_notes_reject_resurrection
before insert or update on public.vintage_notes
for each row execute function public._reject_deleted_vineyard_insights_entity('vintage_note');

create or replace function public.hard_delete_vintage_note(
  p_vineyard_id uuid,
  p_note_id uuid,
  p_operation_id uuid,
  p_deleted_at timestamptz default now()
) returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_existing public.vineyard_insights_deletions%rowtype;
begin
  if not public.can_use_vineyard_insights(p_vineyard_id) then
    raise exception using errcode = '42501', message = 'NOT_AUTHORISED';
  end if;
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'NOT_AUTHORISED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('vintage_note:' || p_note_id::text, 0));
  select * into v_existing from public.vineyard_insights_deletions
   where operation_id = p_operation_id;
  if found and (v_existing.vineyard_id <> p_vineyard_id or v_existing.entity_type <> 'vintage_note' or v_existing.entity_id <> p_note_id) then
    raise exception using errcode = '22023', message = 'DELETE_OPERATION_CONFLICT';
  end if;
  if not found then
    select * into v_existing from public.vineyard_insights_deletions
     where entity_type = 'vintage_note' and entity_id = p_note_id;
  end if;
  if found then
    if v_existing.vineyard_id <> p_vineyard_id or v_existing.entity_type <> 'vintage_note' or v_existing.entity_id <> p_note_id then
      raise exception using errcode = '22023', message = 'DELETE_OPERATION_CONFLICT';
    end if;
    return true;
  end if;
  if exists (select 1 from public.vintage_notes where id = p_note_id and vineyard_id <> p_vineyard_id) then
    raise exception using errcode = '42501', message = 'WRONG_VINEYARD';
  end if;
  insert into public.vineyard_insights_deletions
    (vineyard_id, entity_type, entity_id, deleted_at, deleted_by, operation_id)
  values (p_vineyard_id, 'vintage_note', p_note_id, now(), auth.uid(), p_operation_id);
  delete from public.vintage_notes where id = p_note_id and vineyard_id = p_vineyard_id;
  return true;
end;
$$;

create or replace function public.hard_delete_scout_visit(
  p_vineyard_id uuid,
  p_visit_id uuid,
  p_operation_id uuid,
  p_deleted_at timestamptz default now()
) returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_existing public.vineyard_insights_deletions%rowtype;
begin
  if not public.can_use_vineyard_insights(p_vineyard_id) then
    raise exception using errcode = '42501', message = 'NOT_AUTHORISED';
  end if;
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'NOT_AUTHORISED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('scout_visit:' || p_visit_id::text, 0));
  select * into v_existing from public.vineyard_insights_deletions
   where operation_id = p_operation_id;
  if found and (v_existing.vineyard_id <> p_vineyard_id or v_existing.entity_type <> 'scout_visit' or v_existing.entity_id <> p_visit_id) then
    raise exception using errcode = '22023', message = 'DELETE_OPERATION_CONFLICT';
  end if;
  if not found then
    select * into v_existing from public.vineyard_insights_deletions
     where entity_type = 'scout_visit' and entity_id = p_visit_id;
  end if;
  if found then
    if v_existing.vineyard_id <> p_vineyard_id or v_existing.entity_type <> 'scout_visit' or v_existing.entity_id <> p_visit_id then
      raise exception using errcode = '22023', message = 'DELETE_OPERATION_CONFLICT';
    end if;
    return true;
  end if;
  if exists (select 1 from public.scout_visits where id = p_visit_id and vineyard_id <> p_vineyard_id) then
    raise exception using errcode = '42501', message = 'WRONG_VINEYARD';
  end if;
  insert into public.vineyard_insights_deletions
    (vineyard_id, entity_type, entity_id, deleted_at, deleted_by, operation_id)
  values (p_vineyard_id, 'scout_visit', p_visit_id, now(), auth.uid(), p_operation_id);

  insert into public.scout_photo_cleanup_queue
    (vineyard_id, scout_visit_id, photo_id, storage_path)
  select p_vineyard_id, p_visit_id, p.id, p.storage_path
  from public.scout_observation_photos p
  join public.scout_observations o on o.id = p.observation_id
  join public.scout_block_assessments a on a.id = o.assessment_id
  where a.scout_visit_id = p_visit_id and p.storage_path is not null
  on conflict (photo_id, storage_path) do nothing;

  -- The declared cascades remove assessments, observations and photo metadata.
  -- Growth Stage pins/records are only referenced by UUID and are intentionally untouched.
  delete from public.scout_visits where id = p_visit_id and vineyard_id = p_vineyard_id;
  return true;
end;
$$;

revoke all on function public.hard_delete_vintage_note(uuid,uuid,uuid,timestamptz) from public, anon;
revoke all on function public.hard_delete_scout_visit(uuid,uuid,uuid,timestamptz) from public, anon;
grant execute on function public.hard_delete_vintage_note(uuid,uuid,uuid,timestamptz) to authenticated;
grant execute on function public.hard_delete_scout_visit(uuid,uuid,uuid,timestamptz) to authenticated;

create or replace function public.claim_scout_photo_cleanup(
  p_vineyard_id uuid,
  p_limit integer default 20
) returns setof public.scout_photo_cleanup_queue
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null or not public.can_use_vineyard_insights(p_vineyard_id) then
    raise exception using errcode = '42501', message = 'NOT_AUTHORISED';
  end if;
  return query with due as (
    select q.id from public.scout_photo_cleanup_queue q
    where q.vineyard_id = p_vineyard_id
      and q.status in ('pending','failed','delivering')
      and q.next_attempt_at <= now()
      and (q.lease_expires_at is null or q.lease_expires_at < now())
    order by q.next_attempt_at, q.id
    for update skip locked limit least(greatest(p_limit, 1), 50)
  ) update public.scout_photo_cleanup_queue q set
      status = 'delivering', lease_token = gen_random_uuid(), leased_at = now(),
      lease_expires_at = now() + interval '90 seconds', attempt_count = q.attempt_count + 1
    from due where q.id = due.id returning q.*;
end $$;

create or replace function public.complete_scout_photo_cleanup(p_id uuid, p_lease_token uuid)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_vineyard uuid;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'NOT_AUTHORISED'; end if;
  select vineyard_id into v_vineyard from public.scout_photo_cleanup_queue
   where id = p_id and lease_token = p_lease_token and lease_expires_at > now() for update;
  if not found then return false; end if;
  if not public.can_use_vineyard_insights(v_vineyard) then
    raise exception using errcode = '42501', message = 'NOT_AUTHORISED';
  end if;
  update public.scout_photo_cleanup_queue set status='completed', completed_at=now(),
    lease_token=null, leased_at=null, lease_expires_at=null, last_error=null where id=p_id;
  return true;
end $$;

create or replace function public.fail_scout_photo_cleanup(
  p_id uuid, p_lease_token uuid, p_error text
) returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_vineyard uuid;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'NOT_AUTHORISED'; end if;
  select vineyard_id into v_vineyard from public.scout_photo_cleanup_queue
   where id = p_id and lease_token = p_lease_token and lease_expires_at > now() for update;
  if not found then return false; end if;
  if not public.can_use_vineyard_insights(v_vineyard) then
    raise exception using errcode = '42501', message = 'NOT_AUTHORISED';
  end if;
  update public.scout_photo_cleanup_queue set status='failed',
    next_attempt_at=now()+make_interval(secs=>least(3600, 30*power(2,least(attempt_count,7))::integer)),
    lease_token=null, leased_at=null, lease_expires_at=null, last_error=left(p_error,500)
    where id=p_id;
  return true;
end $$;

revoke all on function public.claim_scout_photo_cleanup(uuid,integer) from public, anon;
revoke all on function public.complete_scout_photo_cleanup(uuid,uuid) from public, anon;
revoke all on function public.fail_scout_photo_cleanup(uuid,uuid,text) from public, anon;
grant execute on function public.claim_scout_photo_cleanup(uuid,integer) to authenticated;
grant execute on function public.complete_scout_photo_cleanup(uuid,uuid) to authenticated;
grant execute on function public.fail_scout_photo_cleanup(uuid,uuid,text) to authenticated;

-- The legacy soft-delete RPC must not bypass the hard-deletion ledger.
revoke execute on function public.soft_delete_vintage_note(uuid) from authenticated;

-- Direct hard deletion stays impossible; only the two checked transactional RPCs may delete.
revoke delete on public.scout_visits, public.scout_block_assessments,
  public.scout_observations, public.scout_observation_photos, public.vintage_notes
  from authenticated;

commit;

-- 279: Work Task soft-delete cascade + costing eligibility hardening.
-- Applied to production on 2026-10-23 after discovering active child rows
-- beneath soft-deleted Work Tasks.
--
-- Contract:
--   * Work Task deletion is a monotonic tombstone.
--   * Task-owned children are soft-deleted with the parent.
--   * Independent records (Trips / Pruning) are preserved but unlinked.
--   * Stale writes cannot reactivate deleted parents or children.
--   * Effective Work Task labour cost never includes deleted Work Tasks.
--   * Historical cleanup is idempotent.

begin;

create or replace function public._guard_work_task_tombstone()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_stamp timestamptz := clock_timestamp();
begin
  if old.deleted_at is null and new.deleted_at is not null then
    new.client_updated_at := v_stamp;
    new.sync_version := greatest(coalesce(new.sync_version, 0), coalesce(old.sync_version, 0) + 1);
    new.updated_by := coalesce(new.updated_by, auth.uid(), old.updated_by);
  elsif old.deleted_at is not null and new.deleted_at is null then
    new.deleted_at := old.deleted_at;
    new.client_updated_at := v_stamp;
    new.sync_version := greatest(coalesce(new.sync_version, 0), coalesce(old.sync_version, 0) + 1);
    new.updated_by := coalesce(new.updated_by, auth.uid(), old.updated_by);
  end if;
  return new;
end;
$function$;

revoke all on function public._guard_work_task_tombstone() from public, anon, authenticated;

drop trigger if exists work_tasks_guard_tombstone on public.work_tasks;
create trigger work_tasks_guard_tombstone
before update of deleted_at on public.work_tasks
for each row execute function public._guard_work_task_tombstone();

create or replace function public._guard_work_task_child_tombstone()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_parent_deleted timestamptz;
  v_stamp timestamptz := clock_timestamp();
  v_changed boolean := false;
begin
  if tg_op = 'UPDATE' and old.deleted_at is not null and new.deleted_at is null then
    new.deleted_at := old.deleted_at;
    v_changed := true;
  elsif tg_op = 'UPDATE' and old.deleted_at is null and new.deleted_at is not null then
    v_changed := true;
  end if;

  if new.work_task_id is not null then
    select t.deleted_at into v_parent_deleted
    from public.work_tasks t
    where t.id = new.work_task_id;

    if found and v_parent_deleted is not null and new.deleted_at is null then
      new.deleted_at := v_parent_deleted;
      v_changed := true;
    end if;
  end if;

  if v_changed then
    new.client_updated_at := v_stamp;
    if tg_op = 'UPDATE' then
      new.sync_version := greatest(coalesce(new.sync_version, 0), coalesce(old.sync_version, 0) + 1);
    else
      new.sync_version := greatest(coalesce(new.sync_version, 0), 1);
    end if;
    new.updated_by := coalesce(new.updated_by, auth.uid());
  end if;

  return new;
end;
$function$;

revoke all on function public._guard_work_task_child_tombstone() from public, anon, authenticated;

drop trigger if exists work_task_labour_lines_guard_tombstone on public.work_task_labour_lines;
create trigger work_task_labour_lines_guard_tombstone
before insert or update of work_task_id, deleted_at on public.work_task_labour_lines
for each row execute function public._guard_work_task_child_tombstone();

drop trigger if exists work_task_machine_lines_guard_tombstone on public.work_task_machine_lines;
create trigger work_task_machine_lines_guard_tombstone
before insert or update of work_task_id, deleted_at on public.work_task_machine_lines
for each row execute function public._guard_work_task_child_tombstone();

drop trigger if exists work_task_materials_guard_tombstone on public.work_task_materials;
create trigger work_task_materials_guard_tombstone
before insert or update of work_task_id, deleted_at on public.work_task_materials
for each row execute function public._guard_work_task_child_tombstone();

drop trigger if exists work_task_paddocks_guard_tombstone on public.work_task_paddocks;
create trigger work_task_paddocks_guard_tombstone
before insert or update of work_task_id, deleted_at on public.work_task_paddocks
for each row execute function public._guard_work_task_child_tombstone();

drop trigger if exists work_task_piece_rate_rows_guard_tombstone on public.work_task_piece_rate_rows;
create trigger work_task_piece_rate_rows_guard_tombstone
before insert or update of work_task_id, deleted_at on public.work_task_piece_rate_rows
for each row execute function public._guard_work_task_child_tombstone();

create or replace function public._guard_live_work_task_link()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_parent_deleted timestamptz;
  v_stamp timestamptz := clock_timestamp();
begin
  if new.work_task_id is null then return new; end if;

  select t.deleted_at into v_parent_deleted
  from public.work_tasks t
  where t.id = new.work_task_id;

  if not found or v_parent_deleted is not null then
    new.work_task_id := null;
    new.client_updated_at := v_stamp;
    if tg_op = 'UPDATE' then
      new.sync_version := greatest(coalesce(new.sync_version, 0), coalesce(old.sync_version, 0) + 1);
    else
      new.sync_version := greatest(coalesce(new.sync_version, 0), 1);
    end if;
    new.updated_by := coalesce(new.updated_by, auth.uid());
  end if;
  return new;
end;
$function$;

revoke all on function public._guard_live_work_task_link() from public, anon, authenticated;

drop trigger if exists trips_guard_live_work_task_link on public.trips;
create trigger trips_guard_live_work_task_link
before insert or update of work_task_id on public.trips
for each row execute function public._guard_live_work_task_link();

drop trigger if exists pruning_activities_guard_live_work_task_link on public.pruning_activities;
create trigger pruning_activities_guard_live_work_task_link
before insert or update of work_task_id on public.pruning_activities
for each row execute function public._guard_live_work_task_link();

drop trigger if exists pruning_entries_guard_live_work_task_link on public.pruning_entries;
create trigger pruning_entries_guard_live_work_task_link
before insert or update of work_task_id on public.pruning_entries
for each row execute function public._guard_live_work_task_link();

create or replace function public._cascade_soft_deleted_work_task()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_stamp timestamptz := clock_timestamp();
  v_actor uuid := coalesce(new.updated_by, auth.uid());
begin
  update public.work_task_labour_lines
  set deleted_at = new.deleted_at, client_updated_at = v_stamp,
      sync_version = coalesce(sync_version, 0) + 1,
      updated_by = coalesce(v_actor, updated_by)
  where work_task_id = new.id and deleted_at is null;

  update public.work_task_machine_lines
  set deleted_at = new.deleted_at, client_updated_at = v_stamp,
      sync_version = coalesce(sync_version, 0) + 1,
      updated_by = coalesce(v_actor, updated_by)
  where work_task_id = new.id and deleted_at is null;

  update public.work_task_materials
  set deleted_at = new.deleted_at, client_updated_at = v_stamp,
      sync_version = coalesce(sync_version, 0) + 1,
      updated_by = coalesce(v_actor, updated_by)
  where work_task_id = new.id and deleted_at is null;

  update public.work_task_paddocks
  set deleted_at = new.deleted_at, client_updated_at = v_stamp,
      sync_version = coalesce(sync_version, 0) + 1,
      updated_by = coalesce(v_actor, updated_by)
  where work_task_id = new.id and deleted_at is null;

  update public.work_task_piece_rate_rows
  set deleted_at = new.deleted_at, client_updated_at = v_stamp,
      sync_version = coalesce(sync_version, 0) + 1,
      updated_by = coalesce(v_actor, updated_by)
  where work_task_id = new.id and deleted_at is null;

  update public.trips
  set work_task_id = null, client_updated_at = v_stamp,
      sync_version = coalesce(sync_version, 0) + 1,
      updated_by = coalesce(v_actor, updated_by)
  where work_task_id = new.id and deleted_at is null;

  update public.pruning_activities
  set work_task_id = null, client_updated_at = v_stamp,
      sync_version = coalesce(sync_version, 0) + 1,
      updated_by = coalesce(v_actor, updated_by)
  where work_task_id = new.id and deleted_at is null;

  update public.pruning_entries
  set work_task_id = null, client_updated_at = v_stamp,
      sync_version = coalesce(sync_version, 0) + 1,
      updated_by = coalesce(v_actor, updated_by)
  where work_task_id = new.id and deleted_at is null;

  return new;
end;
$function$;

revoke all on function public._cascade_soft_deleted_work_task() from public, anon, authenticated;

drop trigger if exists work_tasks_cascade_soft_delete on public.work_tasks;
create trigger work_tasks_cascade_soft_delete
after update of deleted_at on public.work_tasks
for each row
when (old.deleted_at is null and new.deleted_at is not null)
execute function public._cascade_soft_deleted_work_task();

create or replace function public.soft_delete_work_task(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select vineyard_id into v_vineyard_id
  from public.work_tasks where id = p_id;

  if v_vineyard_id is null then raise exception 'Work task not found'; end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete work task';
  end if;

  update public.work_tasks
  set deleted_at = clock_timestamp(), updated_by = auth.uid()
  where id = p_id and deleted_at is null;
end;
$function$;

-- Idempotent cleanup of historical children below already-deleted Work Tasks.
update public.work_task_labour_lines c
set deleted_at = t.deleted_at, updated_by = coalesce(t.updated_by, c.updated_by)
from public.work_tasks t
where c.work_task_id = t.id and t.deleted_at is not null and c.deleted_at is null;

update public.work_task_machine_lines c
set deleted_at = t.deleted_at, updated_by = coalesce(t.updated_by, c.updated_by)
from public.work_tasks t
where c.work_task_id = t.id and t.deleted_at is not null and c.deleted_at is null;

update public.work_task_materials c
set deleted_at = t.deleted_at, updated_by = coalesce(t.updated_by, c.updated_by)
from public.work_tasks t
where c.work_task_id = t.id and t.deleted_at is not null and c.deleted_at is null;

update public.work_task_paddocks c
set deleted_at = t.deleted_at, updated_by = coalesce(t.updated_by, c.updated_by)
from public.work_tasks t
where c.work_task_id = t.id and t.deleted_at is not null and c.deleted_at is null;

update public.work_task_piece_rate_rows c
set deleted_at = t.deleted_at, updated_by = coalesce(t.updated_by, c.updated_by)
from public.work_tasks t
where c.work_task_id = t.id and t.deleted_at is not null and c.deleted_at is null;

update public.trips r
set work_task_id = null, client_updated_at = clock_timestamp(),
    sync_version = coalesce(r.sync_version, 0) + 1,
    updated_by = coalesce(t.updated_by, r.updated_by)
from public.work_tasks t
where r.work_task_id = t.id and t.deleted_at is not null and r.deleted_at is null;

update public.pruning_activities r
set work_task_id = null, client_updated_at = clock_timestamp(),
    sync_version = coalesce(r.sync_version, 0) + 1,
    updated_by = coalesce(t.updated_by, r.updated_by)
from public.work_tasks t
where r.work_task_id = t.id and t.deleted_at is not null and r.deleted_at is null;

update public.pruning_entries r
set work_task_id = null, client_updated_at = clock_timestamp(),
    sync_version = coalesce(r.sync_version, 0) + 1,
    updated_by = coalesce(t.updated_by, r.updated_by)
from public.work_tasks t
where r.work_task_id = t.id and t.deleted_at is not null and r.deleted_at is null;

create or replace function public.work_task_labour_line_cost(p_work_task_id uuid)
returns numeric
language sql stable security definer
set search_path = public
as $function$
  select sum(l.total_cost::numeric)
  from public.work_task_labour_lines l
  join public.work_tasks t on t.id = l.work_task_id and t.deleted_at is null
  where l.work_task_id = p_work_task_id
    and l.deleted_at is null
    and l.hourly_rate is not null;
$function$;

create or replace function public.work_task_pruning_labour_line_cost(p_work_task_id uuid)
returns numeric
language sql stable security definer
set search_path = public
as $function$
  select sum(l.total_cost::numeric)
  from public.pruning_activities a
  join public.work_tasks t on t.id = a.work_task_id and t.deleted_at is null
  join public.pruning_activity_labour_lines l on l.pruning_activity_id = a.id
  where a.work_task_id = p_work_task_id
    and a.deleted_at is null and l.deleted_at is null
    and l.hourly_rate is not null;
$function$;

create or replace function public.work_task_effective_labour_cost(p_work_task_id uuid)
returns numeric
language sql stable security definer
set search_path = public
as $function$
  select case
    when t.costing_method = 'piece_rate' then t.piece_rate_total_cost
    else coalesce(
      public.work_task_labour_line_cost(t.id),
      public.work_task_pruning_labour_line_cost(t.id)
    )
  end
  from public.work_tasks t
  where t.id = p_work_task_id and t.deleted_at is null;
$function$;

create or replace function public.work_task_labour_cost_source(p_work_task_id uuid)
returns text
language sql stable security definer
set search_path = public
as $function$
  select case
    when t.costing_method = 'piece_rate' then 'piece_rate'
    when public.work_task_labour_line_cost(t.id) is not null then 'labour_lines'
    when public.work_task_pruning_labour_line_cost(t.id) is not null then 'pruning_labour_lines'
    else null
  end
  from public.work_tasks t
  where t.id = p_work_task_id and t.deleted_at is null;
$function$;

create or replace view public.v_work_task_effective_labour_cost as
select
  t.id as work_task_id,
  t.vineyard_id,
  t.costing_method,
  t.piece_rate_per_vine,
  t.piece_vine_count,
  t.piece_rate_total_cost,
  l.labour_line_cost,
  case when t.costing_method = 'piece_rate'
       then t.piece_rate_total_cost
       else coalesce(l.labour_line_cost, pl.pruning_line_cost) end as effective_labour_cost,
  case when t.costing_method = 'piece_rate' then 'piece_rate'
       when l.labour_line_cost is not null then 'labour_lines'
       when pl.pruning_line_cost is not null then 'pruning_labour_lines'
       else null end as labour_cost_source,
  case when t.costing_method = 'piece_rate' then t.piece_rate_per_vine
       else null::numeric end as cost_per_vine,
  pl.pruning_line_cost
from public.work_tasks t
left join lateral (
  select sum(x.total_cost::numeric) as labour_line_cost
  from public.work_task_labour_lines x
  where x.work_task_id = t.id and x.deleted_at is null and x.hourly_rate is not null
) l on true
left join lateral (
  select sum(y.total_cost::numeric) as pruning_line_cost
  from public.pruning_activities a
  join public.pruning_activity_labour_lines y on y.pruning_activity_id = a.id
  where a.work_task_id = t.id and a.deleted_at is null
    and y.deleted_at is null and y.hourly_rate is not null
) pl on true
where t.deleted_at is null;

alter view public.v_work_task_effective_labour_cost set (security_invoker = true);
grant select on public.v_work_task_effective_labour_cost to authenticated;

commit;

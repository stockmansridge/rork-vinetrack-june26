-- Phase 15G: Work tasks, maintenance logs, yield, damage, historical yield sync.
-- Tables: work_tasks, maintenance_logs, yield_estimation_sessions,
--   damage_records, historical_yield_records.
-- RLS: SELECT any vineyard member; INSERT/UPDATE any operational role; DELETE blocked.
-- Soft-delete via per-table RPCs gated to owner/manager/supervisor.

-- =====================================================================
-- work_tasks
-- =====================================================================
create table if not exists public.work_tasks (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  paddock_id uuid null,
  paddock_name text not null default '',
  date timestamptz not null default now(),
  task_type text not null default '',
  duration_hours double precision not null default 0,
  resources jsonb null,
  notes text not null default '',
  is_archived boolean not null default false,
  archived_at timestamptz null,
  archived_by text null,
  is_finalized boolean not null default false,
  finalized_at timestamptz null,
  finalized_by text null,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_work_tasks_vineyard_id on public.work_tasks (vineyard_id);
create index if not exists idx_work_tasks_updated_at on public.work_tasks (updated_at);
create index if not exists idx_work_tasks_deleted_at on public.work_tasks (deleted_at);

create or replace trigger work_tasks_set_updated_at
before update on public.work_tasks
for each row execute function public.set_updated_at();

alter table public.work_tasks enable row level security;

drop policy if exists "work_tasks_select_members" on public.work_tasks;
create policy "work_tasks_select_members"
on public.work_tasks for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "work_tasks_insert_members" on public.work_tasks;
create policy "work_tasks_insert_members"
on public.work_tasks for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "work_tasks_update_members" on public.work_tasks;
create policy "work_tasks_update_members"
on public.work_tasks for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "work_tasks_no_client_hard_delete" on public.work_tasks;
create policy "work_tasks_no_client_hard_delete"
on public.work_tasks for delete
to authenticated
using (false);

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
  select vineyard_id into v_vineyard_id from public.work_tasks where id = p_id;
  if v_vineyard_id is null then raise exception 'Work task not found'; end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete work task';
  end if;
  update public.work_tasks set deleted_at = now(), updated_by = auth.uid() where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_work_task(uuid) from public;
grant execute on function public.soft_delete_work_task(uuid) to authenticated;

-- =====================================================================
-- maintenance_logs
-- =====================================================================
create table if not exists public.maintenance_logs (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  item_name text not null default '',
  hours double precision not null default 0,
  work_completed text not null default '',
  parts_used text not null default '',
  parts_cost double precision not null default 0,
  labour_cost double precision not null default 0,
  date timestamptz not null default now(),
  photo_path text null,
  is_archived boolean not null default false,
  archived_at timestamptz null,
  archived_by text null,
  is_finalized boolean not null default false,
  finalized_at timestamptz null,
  finalized_by text null,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_maintenance_logs_vineyard_id on public.maintenance_logs (vineyard_id);
create index if not exists idx_maintenance_logs_updated_at on public.maintenance_logs (updated_at);
create index if not exists idx_maintenance_logs_deleted_at on public.maintenance_logs (deleted_at);

create or replace trigger maintenance_logs_set_updated_at
before update on public.maintenance_logs
for each row execute function public.set_updated_at();

alter table public.maintenance_logs enable row level security;

drop policy if exists "maintenance_logs_select_members" on public.maintenance_logs;
create policy "maintenance_logs_select_members"
on public.maintenance_logs for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "maintenance_logs_insert_members" on public.maintenance_logs;
create policy "maintenance_logs_insert_members"
on public.maintenance_logs for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "maintenance_logs_update_members" on public.maintenance_logs;
create policy "maintenance_logs_update_members"
on public.maintenance_logs for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "maintenance_logs_no_client_hard_delete" on public.maintenance_logs;
create policy "maintenance_logs_no_client_hard_delete"
on public.maintenance_logs for delete
to authenticated
using (false);

create or replace function public.soft_delete_maintenance_log(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id from public.maintenance_logs where id = p_id;
  if v_vineyard_id is null then raise exception 'Maintenance log not found'; end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete maintenance log';
  end if;
  update public.maintenance_logs set deleted_at = now(), updated_by = auth.uid() where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_maintenance_log(uuid) from public;
grant execute on function public.soft_delete_maintenance_log(uuid) to authenticated;

-- =====================================================================
-- yield_estimation_sessions
-- =====================================================================
create table if not exists public.yield_estimation_sessions (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  payload jsonb not null,
  is_completed boolean not null default false,
  completed_at timestamptz null,
  session_created_at timestamptz null,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_yield_estimation_sessions_vineyard_id on public.yield_estimation_sessions (vineyard_id);
create index if not exists idx_yield_estimation_sessions_updated_at on public.yield_estimation_sessions (updated_at);
create index if not exists idx_yield_estimation_sessions_deleted_at on public.yield_estimation_sessions (deleted_at);

create or replace trigger yield_estimation_sessions_set_updated_at
before update on public.yield_estimation_sessions
for each row execute function public.set_updated_at();

alter table public.yield_estimation_sessions enable row level security;

drop policy if exists "yield_estimation_sessions_select_members" on public.yield_estimation_sessions;
create policy "yield_estimation_sessions_select_members"
on public.yield_estimation_sessions for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "yield_estimation_sessions_insert_members" on public.yield_estimation_sessions;
create policy "yield_estimation_sessions_insert_members"
on public.yield_estimation_sessions for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "yield_estimation_sessions_update_members" on public.yield_estimation_sessions;
create policy "yield_estimation_sessions_update_members"
on public.yield_estimation_sessions for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "yield_estimation_sessions_no_client_hard_delete" on public.yield_estimation_sessions;
create policy "yield_estimation_sessions_no_client_hard_delete"
on public.yield_estimation_sessions for delete
to authenticated
using (false);

create or replace function public.soft_delete_yield_estimation_session(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id from public.yield_estimation_sessions where id = p_id;
  if v_vineyard_id is null then raise exception 'Yield session not found'; end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete yield session';
  end if;
  update public.yield_estimation_sessions set deleted_at = now(), updated_by = auth.uid() where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_yield_estimation_session(uuid) from public;
grant execute on function public.soft_delete_yield_estimation_session(uuid) to authenticated;

-- =====================================================================
-- damage_records
-- =====================================================================
create table if not exists public.damage_records (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  paddock_id uuid not null,
  date timestamptz not null default now(),
  damage_type text not null default 'Frost',
  damage_percent double precision not null default 0,
  polygon_points jsonb null,
  notes text not null default '',
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_damage_records_vineyard_id on public.damage_records (vineyard_id);
create index if not exists idx_damage_records_paddock_id on public.damage_records (paddock_id);
create index if not exists idx_damage_records_updated_at on public.damage_records (updated_at);
create index if not exists idx_damage_records_deleted_at on public.damage_records (deleted_at);

create or replace trigger damage_records_set_updated_at
before update on public.damage_records
for each row execute function public.set_updated_at();

alter table public.damage_records enable row level security;

drop policy if exists "damage_records_select_members" on public.damage_records;
create policy "damage_records_select_members"
on public.damage_records for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "damage_records_insert_members" on public.damage_records;
create policy "damage_records_insert_members"
on public.damage_records for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "damage_records_update_members" on public.damage_records;
create policy "damage_records_update_members"
on public.damage_records for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "damage_records_no_client_hard_delete" on public.damage_records;
create policy "damage_records_no_client_hard_delete"
on public.damage_records for delete
to authenticated
using (false);

create or replace function public.soft_delete_damage_record(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id from public.damage_records where id = p_id;
  if v_vineyard_id is null then raise exception 'Damage record not found'; end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete damage record';
  end if;
  update public.damage_records set deleted_at = now(), updated_by = auth.uid() where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_damage_record(uuid) from public;
grant execute on function public.soft_delete_damage_record(uuid) to authenticated;

-- =====================================================================
-- historical_yield_records
-- =====================================================================
create table if not exists public.historical_yield_records (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  season text not null default '',
  year integer not null default 0,
  archived_at timestamptz not null default now(),
  total_yield_tonnes double precision not null default 0,
  total_area_hectares double precision not null default 0,
  notes text not null default '',
  block_results jsonb null,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_historical_yield_records_vineyard_id on public.historical_yield_records (vineyard_id);
create index if not exists idx_historical_yield_records_updated_at on public.historical_yield_records (updated_at);
create index if not exists idx_historical_yield_records_deleted_at on public.historical_yield_records (deleted_at);

create or replace trigger historical_yield_records_set_updated_at
before update on public.historical_yield_records
for each row execute function public.set_updated_at();

alter table public.historical_yield_records enable row level security;

drop policy if exists "historical_yield_records_select_members" on public.historical_yield_records;
create policy "historical_yield_records_select_members"
on public.historical_yield_records for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "historical_yield_records_insert_members" on public.historical_yield_records;
create policy "historical_yield_records_insert_members"
on public.historical_yield_records for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "historical_yield_records_update_members" on public.historical_yield_records;
create policy "historical_yield_records_update_members"
on public.historical_yield_records for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "historical_yield_records_no_client_hard_delete" on public.historical_yield_records;
create policy "historical_yield_records_no_client_hard_delete"
on public.historical_yield_records for delete
to authenticated
using (false);

create or replace function public.soft_delete_historical_yield_record(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id from public.historical_yield_records where id = p_id;
  if v_vineyard_id is null then raise exception 'Historical yield record not found'; end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete historical yield record';
  end if;
  update public.historical_yield_records set deleted_at = now(), updated_by = auth.uid() where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_historical_yield_record(uuid) from public;
grant execute on function public.soft_delete_historical_yield_record(uuid) to authenticated;

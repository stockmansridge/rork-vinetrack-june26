-- Phase 16: Work tasks multi-day / multi-worker support (additive).
--
-- Adds optional parent fields to public.work_tasks and a new child table
-- public.work_task_labour_lines for per-day, per-worker-type labour entries.
--
-- Design goals:
--   * Strictly additive — no existing column or RLS behaviour is changed.
--   * Mirrors the existing operations sync pattern (soft-delete via RPC,
--     vineyard-membership RLS, sync_version + client_updated_at columns).
--   * Permissions for the new RPC mirror soft_delete_work_task: only
--     owner/manager/supervisor may soft-delete a labour line. Operators
--     can insert/update via the standard RLS policies.

-- =====================================================================
-- work_tasks: additive parent fields
-- =====================================================================
alter table public.work_tasks
  add column if not exists start_date timestamptz null,
  add column if not exists end_date timestamptz null,
  add column if not exists area_ha double precision null,
  add column if not exists description text null,
  add column if not exists status text null;

create index if not exists idx_work_tasks_status on public.work_tasks (status);
create index if not exists idx_work_tasks_start_date on public.work_tasks (start_date);

-- =====================================================================
-- work_task_labour_lines
-- =====================================================================
create table if not exists public.work_task_labour_lines (
  id uuid primary key default gen_random_uuid(),
  work_task_id uuid not null references public.work_tasks(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  work_date date not null,
  operator_category_id uuid null,
  worker_type text not null default '',
  worker_count integer not null default 1,
  hours_per_worker double precision not null default 0,
  hourly_rate double precision null,
  total_hours double precision generated always as
    (coalesce(worker_count, 0)::double precision * coalesce(hours_per_worker, 0)) stored,
  total_cost double precision generated always as
    (coalesce(worker_count, 0)::double precision
      * coalesce(hours_per_worker, 0)
      * coalesce(hourly_rate, 0)) stored,
  notes text not null default '',
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_work_task_labour_lines_work_task_id
  on public.work_task_labour_lines (work_task_id);
create index if not exists idx_work_task_labour_lines_vineyard_work_date
  on public.work_task_labour_lines (vineyard_id, work_date);
create index if not exists idx_work_task_labour_lines_vineyard_id
  on public.work_task_labour_lines (vineyard_id);
create index if not exists idx_work_task_labour_lines_updated_at
  on public.work_task_labour_lines (updated_at);
create index if not exists idx_work_task_labour_lines_deleted_at
  on public.work_task_labour_lines (deleted_at);

create or replace trigger work_task_labour_lines_set_updated_at
before update on public.work_task_labour_lines
for each row execute function public.set_updated_at();

alter table public.work_task_labour_lines enable row level security;

drop policy if exists "work_task_labour_lines_select_members"
  on public.work_task_labour_lines;
create policy "work_task_labour_lines_select_members"
on public.work_task_labour_lines for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "work_task_labour_lines_insert_members"
  on public.work_task_labour_lines;
create policy "work_task_labour_lines_insert_members"
on public.work_task_labour_lines for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "work_task_labour_lines_update_members"
  on public.work_task_labour_lines;
create policy "work_task_labour_lines_update_members"
on public.work_task_labour_lines for update
to authenticated
using (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "work_task_labour_lines_no_client_hard_delete"
  on public.work_task_labour_lines;
create policy "work_task_labour_lines_no_client_hard_delete"
on public.work_task_labour_lines for delete
to authenticated
using (false);

-- =====================================================================
-- soft_delete_work_task_labour_line
-- =====================================================================
-- Mirrors soft_delete_work_task: only owner/manager/supervisor may
-- soft-delete a labour line. Operators may continue to insert/update
-- their own labour lines via standard RLS.
create or replace function public.soft_delete_work_task_labour_line(p_id uuid)
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
    from public.work_task_labour_lines where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Work task labour line not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id,
       array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete work task labour line';
  end if;
  update public.work_task_labour_lines
     set deleted_at = now(), updated_by = auth.uid()
   where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_work_task_labour_line(uuid) from public;
grant execute on function public.soft_delete_work_task_labour_line(uuid)
  to authenticated;

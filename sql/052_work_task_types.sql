-- Phase 17: Shared work task types catalog (additive).
--
-- Adds public.work_task_types so custom Work Task Types created on iOS or
-- in Lovable are shared per-vineyard. The local WorkTaskTypeCatalog.defaults
-- list remains the fallback in clients; this table layers vineyard-specific
-- entries on top.
--
-- Design goals:
--   * Strictly additive — work_tasks.task_type remains a free-text string
--     for backward compatibility. No task_type_id column is introduced yet.
--   * Mirrors the operator_categories sync pattern (vineyard-scoped, soft
--     delete via RPC, sync_version + client_updated_at, RLS via vineyard
--     membership helpers).
--   * Unique active name per vineyard, case-insensitive.

-- =====================================================================
-- work_task_types
-- =====================================================================
create table if not exists public.work_task_types (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null,
  is_default boolean not null default false,
  sort_order integer not null default 0,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

-- Unique active name per vineyard, case-insensitive. Soft-deleted rows are
-- excluded so a name can be re-created later without conflict.
create unique index if not exists uq_work_task_types_active_name_ci
  on public.work_task_types (vineyard_id, lower(name))
  where deleted_at is null;

create index if not exists idx_work_task_types_vineyard_id
  on public.work_task_types (vineyard_id);
create index if not exists idx_work_task_types_updated_at
  on public.work_task_types (updated_at);
create index if not exists idx_work_task_types_deleted_at
  on public.work_task_types (deleted_at);

create or replace trigger work_task_types_set_updated_at
before update on public.work_task_types
for each row execute function public.set_updated_at();

alter table public.work_task_types enable row level security;

-- Select: any vineyard member can read the catalog.
drop policy if exists "work_task_types_select_members"
  on public.work_task_types;
create policy "work_task_types_select_members"
on public.work_task_types for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

-- Insert/update: any role that can currently create work tasks
-- (owner/manager/supervisor/operator). This mirrors work_tasks RLS so the
-- "Add Task Type" affordance is available everywhere the picker is.
drop policy if exists "work_task_types_insert_members"
  on public.work_task_types;
create policy "work_task_types_insert_members"
on public.work_task_types for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "work_task_types_update_members"
  on public.work_task_types;
create policy "work_task_types_update_members"
on public.work_task_types for update
to authenticated
using (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

-- No hard delete from clients — use soft_delete_work_task_type.
drop policy if exists "work_task_types_no_client_hard_delete"
  on public.work_task_types;
create policy "work_task_types_no_client_hard_delete"
on public.work_task_types for delete
to authenticated
using (false);

-- =====================================================================
-- soft_delete_work_task_type
-- =====================================================================
-- Only owner/manager/supervisor may soft-delete a catalog entry. Operators
-- may create/edit but not delete shared task types (matches the existing
-- soft_delete_work_task permission model).
create or replace function public.soft_delete_work_task_type(p_id uuid)
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
    from public.work_task_types where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Work task type not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id,
       array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete work task type';
  end if;
  update public.work_task_types
     set deleted_at = now(),
         updated_by = auth.uid(),
         sync_version = sync_version + 1
   where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_work_task_type(uuid) from public;
grant execute on function public.soft_delete_work_task_type(uuid)
  to authenticated;

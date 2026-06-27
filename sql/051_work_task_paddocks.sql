-- Phase 17: Work task multi-paddock support (additive).
--
-- Adds the join table public.work_task_paddocks so a single work task can
-- reference multiple paddocks. Existing work_tasks.paddock_id remains
-- untouched for backwards compatibility with single-paddock tasks.
--
-- Design goals:
--   * Strictly additive — no existing column or RLS behaviour is changed.
--   * Mirrors the existing operations sync pattern (soft-delete via RPC,
--     vineyard-membership RLS, sync_version + client_updated_at columns).
--   * Permissions for the soft-delete RPC mirror soft_delete_work_task:
--     only owner/manager/supervisor may soft-delete a row. Operators may
--     insert/update via standard RLS policies.

-- =====================================================================
-- work_task_paddocks
-- =====================================================================
create table if not exists public.work_task_paddocks (
  id uuid primary key default gen_random_uuid(),
  work_task_id uuid not null references public.work_tasks(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  paddock_id uuid not null references public.paddocks(id) on delete cascade,
  area_ha double precision null,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

-- One active row per (work_task_id, paddock_id). Soft-deleted rows are
-- excluded so a paddock can be re-added later without conflict.
create unique index if not exists uq_work_task_paddocks_active
  on public.work_task_paddocks (work_task_id, paddock_id)
  where deleted_at is null;

create index if not exists idx_work_task_paddocks_work_task_id
  on public.work_task_paddocks (work_task_id);
create index if not exists idx_work_task_paddocks_paddock_id
  on public.work_task_paddocks (paddock_id);
create index if not exists idx_work_task_paddocks_vineyard_id
  on public.work_task_paddocks (vineyard_id);
create index if not exists idx_work_task_paddocks_updated_at
  on public.work_task_paddocks (updated_at);
create index if not exists idx_work_task_paddocks_deleted_at
  on public.work_task_paddocks (deleted_at);

create or replace trigger work_task_paddocks_set_updated_at
before update on public.work_task_paddocks
for each row execute function public.set_updated_at();

alter table public.work_task_paddocks enable row level security;

drop policy if exists "work_task_paddocks_select_members"
  on public.work_task_paddocks;
create policy "work_task_paddocks_select_members"
on public.work_task_paddocks for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "work_task_paddocks_insert_members"
  on public.work_task_paddocks;
create policy "work_task_paddocks_insert_members"
on public.work_task_paddocks for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "work_task_paddocks_update_members"
  on public.work_task_paddocks;
create policy "work_task_paddocks_update_members"
on public.work_task_paddocks for update
to authenticated
using (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "work_task_paddocks_no_client_hard_delete"
  on public.work_task_paddocks;
create policy "work_task_paddocks_no_client_hard_delete"
on public.work_task_paddocks for delete
to authenticated
using (false);

-- =====================================================================
-- soft_delete_work_task_paddock
-- =====================================================================
-- Mirrors soft_delete_work_task: only owner/manager/supervisor may
-- soft-delete a join row. Operators may continue to insert/update their
-- own join rows via standard RLS.
create or replace function public.soft_delete_work_task_paddock(p_id uuid)
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
    from public.work_task_paddocks where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Work task paddock not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id,
       array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete work task paddock';
  end if;
  update public.work_task_paddocks
     set deleted_at = now(), updated_by = auth.uid()
   where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_work_task_paddock(uuid) from public;
grant execute on function public.soft_delete_work_task_paddock(uuid)
  to authenticated;

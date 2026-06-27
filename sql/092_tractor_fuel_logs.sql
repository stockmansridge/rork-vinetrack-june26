-- =====================================================================
-- 092_tractor_fuel_logs.sql
-- =====================================================================
-- Fuel Usage module — Phase 1.
--
-- Records each time an operator fills a tractor with diesel: litres added
-- and engine hours at the fill. This lets VineTrack derive an hourly fuel
-- usage rate per tractor (calculated client-side in Phase 1) and, later,
-- allocate fuel cost to jobs/trips.
--
-- RLS differs from `fuel_purchases` (owner/manager write-only): because the
-- people who physically fill tractors are operators, any vineyard member may
-- INSERT and SELECT fuel logs. Owners/managers (and optionally the creator,
-- while the row is not deleted) may UPDATE. Client hard delete is blocked;
-- soft delete goes through `soft_delete_tractor_fuel_log(uuid)` which is
-- restricted to owner/manager (mirrors the existing soft-delete pattern).
--
-- Depends on helpers from 001/011:
--   public.set_updated_at()        -- trigger fn
--   public.is_vineyard_member(uuid)
--   public.has_vineyard_role(uuid, text[])
-- =====================================================================

create table if not exists public.tractor_fuel_logs (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  tractor_id uuid null references public.tractors(id) on delete set null,
  fill_datetime timestamptz not null default now(),
  litres_added double precision not null default 0,
  engine_hours double precision null,
  operator_user_id uuid null,
  operator_name text null,
  cost_per_litre double precision null,
  total_cost double precision null,
  filled_to_full boolean null,
  notes text null,
  -- standard sync envelope
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1,

  constraint tractor_fuel_logs_litres_added_nonneg
    check (litres_added >= 0),
  constraint tractor_fuel_logs_engine_hours_nonneg
    check (engine_hours is null or engine_hours >= 0),
  constraint tractor_fuel_logs_cost_per_litre_nonneg
    check (cost_per_litre is null or cost_per_litre >= 0),
  constraint tractor_fuel_logs_total_cost_nonneg
    check (total_cost is null or total_cost >= 0)
);

create index if not exists idx_tractor_fuel_logs_vineyard_id
  on public.tractor_fuel_logs (vineyard_id);
create index if not exists idx_tractor_fuel_logs_tractor_id
  on public.tractor_fuel_logs (tractor_id);
create index if not exists idx_tractor_fuel_logs_fill_datetime
  on public.tractor_fuel_logs (fill_datetime desc);
create index if not exists idx_tractor_fuel_logs_deleted_at
  on public.tractor_fuel_logs (deleted_at);
create index if not exists idx_tractor_fuel_logs_updated_at
  on public.tractor_fuel_logs (updated_at);
create index if not exists idx_tractor_fuel_logs_vineyard_tractor_fill
  on public.tractor_fuel_logs (vineyard_id, tractor_id, fill_datetime desc);

create or replace trigger tractor_fuel_logs_set_updated_at
before update on public.tractor_fuel_logs
for each row execute function public.set_updated_at();

alter table public.tractor_fuel_logs enable row level security;

-- SELECT: any vineyard member may read fuel logs for their vineyards.
drop policy if exists "tractor_fuel_logs_select_members" on public.tractor_fuel_logs;
create policy "tractor_fuel_logs_select_members"
on public.tractor_fuel_logs for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

-- INSERT: any vineyard member (operators included) may record a fuel fill.
drop policy if exists "tractor_fuel_logs_insert_members" on public.tractor_fuel_logs;
create policy "tractor_fuel_logs_insert_members"
on public.tractor_fuel_logs for insert
to authenticated
with check (public.is_vineyard_member(vineyard_id));

-- UPDATE: owners/managers may update any row; in addition, the creator may
-- update their own row while it has not been soft-deleted. The WITH CHECK
-- keeps the row inside the same vineyard and under the same permission set.
drop policy if exists "tractor_fuel_logs_update_managers" on public.tractor_fuel_logs;
create policy "tractor_fuel_logs_update_managers"
on public.tractor_fuel_logs for update
to authenticated
using (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager'])
  or (created_by = auth.uid() and deleted_at is null)
)
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager'])
  or (created_by = auth.uid() and deleted_at is null)
);

-- No client hard delete — use soft_delete_tractor_fuel_log.
drop policy if exists "tractor_fuel_logs_no_client_hard_delete" on public.tractor_fuel_logs;
create policy "tractor_fuel_logs_no_client_hard_delete"
on public.tractor_fuel_logs for delete
to authenticated
using (false);

-- soft_delete_tractor_fuel_log(uuid)
-- Owner/manager only (mirrors soft_delete_fuel_purchase / soft_delete_tractor).
create or replace function public.soft_delete_tractor_fuel_log(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  select vineyard_id into v_vineyard_id from public.tractor_fuel_logs where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Tractor fuel log not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete tractor fuel log';
  end if;
  update public.tractor_fuel_logs
  set deleted_at = now(),
      updated_at = now(),
      updated_by = auth.uid(),
      sync_version = sync_version + 1
  where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_tractor_fuel_log(uuid) from public;
grant execute on function public.soft_delete_tractor_fuel_log(uuid) to authenticated;

-- Phase 5: Trip cost allocations.
--
-- Saved breakdown of trip-level cost across block (paddock) and variety so
-- season / block / variety cost reporting can be calculated once and shared
-- across iOS and Lovable without recomputing on every read.
--
-- Access rules (financial data — owners/managers only):
--   SELECT: owner / manager only.
--   INSERT/UPDATE: owner / manager only.
--   DELETE: blocked at table — soft delete via RPC owner/manager only.
--
-- Supervisors and operators must NOT be able to query this table.

-- =====================================================================
-- trip_cost_allocations
-- =====================================================================
create table if not exists public.trip_cost_allocations (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  season_year integer not null,
  trip_function text null,

  paddock_id uuid null references public.paddocks(id) on delete set null,
  paddock_name text null,

  -- Variety / allocation slice.
  variety text null,
  variety_id uuid null,
  variety_percentage numeric null,
  allocation_area_ha numeric null,

  -- Cost components (already gated to owners/managers via RLS).
  labour_cost numeric null,
  fuel_cost numeric null,
  chemical_cost numeric null,
  input_cost numeric null,
  total_cost numeric null,

  -- Metrics.
  cost_per_ha numeric null,
  yield_tonnes numeric null,
  cost_per_tonne numeric null,

  -- Trace / debug.
  allocation_basis text not null default 'area',
  costing_status text null,
  warnings text[] null,
  calculated_at timestamptz not null default now(),
  source_trip_updated_at timestamptz null,

  -- Standard sync/audit.
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_trip_cost_allocations_vineyard_id on public.trip_cost_allocations (vineyard_id);
create index if not exists idx_trip_cost_allocations_trip_id on public.trip_cost_allocations (trip_id);
create index if not exists idx_trip_cost_allocations_season_year on public.trip_cost_allocations (season_year);
create index if not exists idx_trip_cost_allocations_paddock_id on public.trip_cost_allocations (paddock_id);
create index if not exists idx_trip_cost_allocations_variety on public.trip_cost_allocations (variety);
create index if not exists idx_trip_cost_allocations_deleted_at on public.trip_cost_allocations (deleted_at);
create index if not exists idx_trip_cost_allocations_updated_at on public.trip_cost_allocations (updated_at);

-- Unique active row per (trip, paddock, variety). Recalc soft-deletes the
-- previous allocation rows for the trip and inserts fresh ones, so this
-- constraint guards against duplicates when two clients recalculate at once.
create unique index if not exists uq_trip_cost_allocations_trip_paddock_variety_active
  on public.trip_cost_allocations (trip_id, coalesce(paddock_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(variety, ''))
  where deleted_at is null;

create or replace trigger trip_cost_allocations_set_updated_at
before update on public.trip_cost_allocations
for each row execute function public.set_updated_at();

alter table public.trip_cost_allocations enable row level security;

-- SELECT: owner / manager only. Supervisors and operators get no rows.
drop policy if exists "trip_cost_allocations_select_owner_manager" on public.trip_cost_allocations;
create policy "trip_cost_allocations_select_owner_manager"
on public.trip_cost_allocations for select
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

-- INSERT/UPDATE: owner / manager only.
drop policy if exists "trip_cost_allocations_insert_owner_manager" on public.trip_cost_allocations;
create policy "trip_cost_allocations_insert_owner_manager"
on public.trip_cost_allocations for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "trip_cost_allocations_update_owner_manager" on public.trip_cost_allocations;
create policy "trip_cost_allocations_update_owner_manager"
on public.trip_cost_allocations for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

-- DELETE: blocked at table.
drop policy if exists "trip_cost_allocations_no_client_hard_delete" on public.trip_cost_allocations;
create policy "trip_cost_allocations_no_client_hard_delete"
on public.trip_cost_allocations for delete
to authenticated
using (false);

-- Soft delete RPC. Owners/managers only.
create or replace function public.soft_delete_trip_cost_allocation(p_id uuid)
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
  select vineyard_id into v_vineyard_id from public.trip_cost_allocations where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Trip cost allocation not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete trip cost allocation';
  end if;
  update public.trip_cost_allocations
  set deleted_at = now(), updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_trip_cost_allocation(uuid) from public;
grant execute on function public.soft_delete_trip_cost_allocation(uuid) to authenticated;

-- Bulk soft-delete every active allocation row for a trip. Used by the
-- iOS recalculation flow before inserting a fresh allocation set so stale
-- rows can never linger. Owners/managers only.
create or replace function public.soft_delete_trip_cost_allocations_for_trip(p_trip_id uuid)
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
  select vineyard_id into v_vineyard_id from public.trips where id = p_trip_id;
  if v_vineyard_id is null then
    raise exception 'Trip not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to recalculate trip cost allocations';
  end if;
  update public.trip_cost_allocations
  set deleted_at = now(), updated_by = auth.uid()
  where trip_id = p_trip_id and deleted_at is null;
end;
$function$;

revoke all on function public.soft_delete_trip_cost_allocations_for_trip(uuid) from public;
grant execute on function public.soft_delete_trip_cost_allocations_for_trip(uuid) to authenticated;

-- =====================================================================
-- 097_vineyard_machines.sql
-- =====================================================================
-- Vineyard Machines — Fuel Log foundation (Phase 1).
--
-- Generalises the tractor-only Fuel Log into a "Vineyard Machines" model
-- that can represent tractors, ATVs, side-by-sides, harvesters, utility
-- vehicles and other vineyard machines. This migration is the DATA
-- FOUNDATION only — it does NOT change trip costing, trips.tractor_id,
-- TripCostService, fuel_purchases, or the Fuel Log UI.
--
-- Safety / compatibility guarantees:
--   * Strictly additive. The existing public.tractors table is untouched
--     and continues to work exactly as before.
--   * Existing public.tractor_fuel_logs keep working: tractor_id is
--     retained as the legacy fallback link. A nullable machine_id is added
--     and becomes the preferred link for new fuel logs going forward.
--   * Existing tractors are backfilled into vineyard_machines with
--     machine_type = 'tractor' (one machine per tractor, linked via
--     legacy_tractor_id). Existing fuel logs are backfilled with the
--     matching machine_id.
--   * Fully idempotent and safe to re-run (guarded creates, ON CONFLICT,
--     WHERE-NOT-EXISTS backfills).
--
-- RLS note (matches public.tractors deliberately): write access is limited
-- to owner/manager because vineyard_machines is the successor to the
-- owner/manager-only tractors table. See accompanying report for the
-- equipment_items (owner/manager/supervisor) divergence flag.
--
-- Depends on helpers from 001/011:
--   public.set_updated_at()        -- trigger fn
--   public.is_vineyard_member(uuid)
--   public.has_vineyard_role(uuid, text[])
-- =====================================================================

-- ---------------------------------------------------------------------
-- vineyard_machines
-- ---------------------------------------------------------------------
create table if not exists public.vineyard_machines (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null default '',
  machine_type text not null default 'tractor',
  fuel_tracking_enabled boolean not null default true,
  available_for_job_costing boolean not null default false,
  -- Hourly fuel usage. Default 0 is treated by the app as "not set"
  -- rather than a real 0 L/hr rate. Costing must only use this value when
  -- a machine is deliberately linked to a recorded trip/job AND has an
  -- approved (> 0) default L/hr — enforced later, not in this migration.
  fuel_usage_l_per_hour double precision not null default 0,
  notes text null,
  -- Link back to the originating tractor row when this machine was
  -- backfilled from public.tractors. Null for natively-created machines.
  legacy_tractor_id uuid null references public.tractors(id) on delete set null,
  -- standard sync envelope
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1,

  constraint vineyard_machines_fuel_usage_nonneg
    check (fuel_usage_l_per_hour >= 0),
  constraint vineyard_machines_machine_type_allowed
    check (machine_type in (
      'tractor',
      'atv',
      'side_by_side',
      'harvester',
      'utility_vehicle',
      'other_vineyard_machine'
    ))
);

create index if not exists idx_vineyard_machines_vineyard_id
  on public.vineyard_machines (vineyard_id);
create index if not exists idx_vineyard_machines_updated_at
  on public.vineyard_machines (updated_at);
create index if not exists idx_vineyard_machines_deleted_at
  on public.vineyard_machines (deleted_at);
create index if not exists idx_vineyard_machines_machine_type
  on public.vineyard_machines (machine_type);
-- One backfilled machine per legacy tractor (active rows only). Lets the
-- tractor backfill below be safely re-run without creating duplicates.
create unique index if not exists uq_vineyard_machines_legacy_tractor
  on public.vineyard_machines (legacy_tractor_id)
  where legacy_tractor_id is not null and deleted_at is null;

create or replace trigger vineyard_machines_set_updated_at
before update on public.vineyard_machines
for each row execute function public.set_updated_at();

alter table public.vineyard_machines enable row level security;

-- SELECT: any vineyard member may read machines for their vineyards.
drop policy if exists "vineyard_machines_select_members" on public.vineyard_machines;
create policy "vineyard_machines_select_members"
on public.vineyard_machines for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

-- INSERT: owner/manager only (mirrors public.tractors).
drop policy if exists "vineyard_machines_insert_managers" on public.vineyard_machines;
create policy "vineyard_machines_insert_managers"
on public.vineyard_machines for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

-- UPDATE: owner/manager only (mirrors public.tractors).
drop policy if exists "vineyard_machines_update_managers" on public.vineyard_machines;
create policy "vineyard_machines_update_managers"
on public.vineyard_machines for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

-- No client hard delete — use soft_delete_vineyard_machine.
drop policy if exists "vineyard_machines_no_client_hard_delete" on public.vineyard_machines;
create policy "vineyard_machines_no_client_hard_delete"
on public.vineyard_machines for delete
to authenticated
using (false);

-- soft_delete_vineyard_machine(uuid) — owner/manager only (mirrors soft_delete_tractor).
create or replace function public.soft_delete_vineyard_machine(p_id uuid)
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
  select vineyard_id into v_vineyard_id from public.vineyard_machines where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Vineyard machine not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete vineyard machine';
  end if;
  update public.vineyard_machines
  set deleted_at = now(),
      updated_at = now(),
      updated_by = auth.uid(),
      sync_version = sync_version + 1
  where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_vineyard_machine(uuid) from public;
grant execute on function public.soft_delete_vineyard_machine(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- tractor_fuel_logs.machine_id (preferred link; tractor_id kept as legacy fallback)
-- ---------------------------------------------------------------------
alter table public.tractor_fuel_logs
  add column if not exists machine_id uuid null
    references public.vineyard_machines(id) on delete set null;

create index if not exists idx_tractor_fuel_logs_machine_id
  on public.tractor_fuel_logs (machine_id);

-- ---------------------------------------------------------------------
-- Backfill 1: existing tractors -> vineyard_machines (machine_type = tractor)
-- Idempotent: only inserts a machine for tractors that don't already have
-- an active backfilled machine (matched on legacy_tractor_id).
-- ---------------------------------------------------------------------
insert into public.vineyard_machines (
  vineyard_id,
  name,
  machine_type,
  fuel_tracking_enabled,
  available_for_job_costing,
  fuel_usage_l_per_hour,
  legacy_tractor_id,
  created_by,
  updated_by,
  created_at,
  updated_at
)
select
  t.vineyard_id,
  case
    when coalesce(nullif(trim(t.name), ''), '') <> '' then t.name
    else trim(coalesce(t.brand, '') || ' ' || coalesce(t.model, ''))
  end as name,
  'tractor' as machine_type,
  true as fuel_tracking_enabled,
  -- Match the legacy tractor behaviour: a tractor was usable for trip
  -- costing, so its backfilled machine is available for job costing too.
  true as available_for_job_costing,
  coalesce(t.fuel_usage_l_per_hour, 0) as fuel_usage_l_per_hour,
  t.id as legacy_tractor_id,
  t.created_by,
  t.updated_by,
  coalesce(t.created_at, now()),
  coalesce(t.updated_at, now())
from public.tractors t
where t.deleted_at is null
  and not exists (
    select 1
    from public.vineyard_machines m
    where m.legacy_tractor_id = t.id
      and m.deleted_at is null
  );

-- ---------------------------------------------------------------------
-- Backfill 2: existing tractor_fuel_logs.machine_id from tractor_id
-- via the linked vineyard_machines row. Only fills rows where machine_id
-- is still null and a matching active machine exists.
-- ---------------------------------------------------------------------
update public.tractor_fuel_logs f
set machine_id = m.id
from public.vineyard_machines m
where f.machine_id is null
  and f.tractor_id is not null
  and m.legacy_tractor_id = f.tractor_id
  and m.deleted_at is null;

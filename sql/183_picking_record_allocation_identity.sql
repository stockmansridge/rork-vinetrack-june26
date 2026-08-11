-- =============================================================================
-- 183: Picking record allocation identity (exact planting linkage)
--
-- Block + Variety + Clone + Rootstock is NOT unique — a block can carry two
-- separate plantings of the same variety with the same clone and rootstock
-- (e.g. Stockman's Ridge: two Pinot Noir allocations, both Clone 777 ·
-- Richter 110). Each picking record can now store the STABLE id of the
-- `public.paddocks.variety_allocations[]` entry it was picked from, plus the
-- rootstock display snapshot that was missing from the sql/180 contract.
--
-- Contract summary
--   Column public.picking_records.variety_allocation_id  uuid NULL
--          = paddocks.variety_allocations[].id at entry time. NULL means the
--          pick is not linked to a specific planting (all pre-183 rows, free
--          text varieties, and explicit "Not specified" selections).
--   Column public.picking_records.rootstock  text NULL
--          = point-in-time display snapshot from the allocation (e.g.
--          `Richter 110`), same semantics as the existing `clone` snapshot.
--   View   public.picking_yield_allocation_totals — per-planting totals for
--          Portal / Yield reporting. The sql/180 `picking_yield_totals` view
--          is UNCHANGED (Block + Variety + Vintage granularity is still the
--          canonical actual-yield contract; the supersede rule in
--          docs/vinetrack-picking-log.md §5 is unaffected).
--
-- Snapshot semantics (same rule as paddock_name / variety_name / clone):
-- `variety_allocation_id` is a point-in-time LINK with no foreign key — the
-- allocation lives inside the paddocks JSONB and may be edited or removed
-- later; picking records never change retroactively. Clients resolve the id
-- against the block's current allocations for display and fall back to the
-- stored snapshots when the allocation no longer exists.
--
-- NO BACKFILL — deliberate. Existing rows cannot be attributed to a specific
-- planting without guessing (the motivating vineyard has two allocations that
-- are identical on every snapshot column). Historical picks therefore remain
-- unlinked (`variety_allocation_id IS NULL`); linking happens only through an
-- explicit selection when a record is created or edited.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.picking_records
  add column if not exists variety_allocation_id uuid null;

alter table public.picking_records
  add column if not exists rootstock text null;

comment on column public.picking_records.variety_allocation_id is
  'Stable id of the paddocks.variety_allocations[] entry this pick was recorded against. NULL = not linked (historical rows are never backfilled by guessing).';
comment on column public.picking_records.rootstock is
  'Point-in-time rootstock display snapshot from the allocation (e.g. Richter 110). Reference only, like clone.';

-- Allocation-level reporting path.
create index if not exists idx_picking_records_allocation
  on public.picking_records (vineyard_id, vintage, variety_allocation_id)
  where deleted_at is null and variety_allocation_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Per-planting totals view (security_invoker — caller's RLS applies)
--
-- Linked rows aggregate per allocation id: the id IS the identity, so the
-- totals stay unified even when the clone/rootstock display snapshots vary
-- across rows (they are max() display hints only). Unlinked rows (NULL id)
-- keep the sql/180 variety-name identity so they split per variety, not into
-- one mixed bucket per block — exposed via `unlinked_variety_key`.
-- ---------------------------------------------------------------------------
create or replace view public.picking_yield_allocation_totals
with (security_invoker = on) as
select
  vineyard_id,
  vintage,
  paddock_id,
  variety_allocation_id,
  case
    when variety_allocation_id is null then lower(btrim(variety_name))
  end                                     as unlinked_variety_key,
  max(paddock_name)                       as paddock_name,
  max(variety_name)                       as variety_name,
  max(clone)                              as clone,
  max(rootstock)                          as rootstock,
  count(*)::integer                       as pick_count,
  sum(weight_kg)                          as total_weight_kg,
  sum(weight_kg) / 1000.0                 as actual_yield_tonnes,
  min(picked_at)                          as first_picked_at,
  max(picked_at)                          as last_picked_at,
  sum(grape_value)                        as total_grape_value
from public.picking_records
where deleted_at is null
group by vineyard_id, vintage, paddock_id, variety_allocation_id,
  case
    when variety_allocation_id is null then lower(btrim(variety_name))
  end;

grant select on public.picking_yield_allocation_totals to authenticated;

notify pgrst, 'reload schema';

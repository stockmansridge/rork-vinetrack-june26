-- =============================================================================
-- 184: Picking record PLANTING-GROUP identity
--
-- Supersedes the never-deployed sql/183 single-allocation design. Contract
-- doc: docs/picking-records-allocation-identity-contract.md (shared with the
-- Lovable Portal frontend planting-group model).
--
-- Problem: one block can carry SEVERAL physical `variety_allocations[]`
-- sections that are the same planting in every agronomic sense — same
-- Variety + Clone + Rootstock (e.g. Stockman's Ridge: two Pinot Noir
-- sections, both Clone 777 · Richter 110). A pick is recorded against the
-- PLANTING GROUP, not one arbitrary section: pickers cannot attribute a bin
-- to one of two identical sections, and reporting wants one row per group.
--
-- Contract summary
--   Function public.planting_group_key(variety, clone, rootstock) → text
--            Deterministic group identity: norm(variety)|norm(clone)|
--            norm(rootstock), where norm = lower(trim(collapse whitespace)),
--            '' for NULL. Scoped per block via the row's paddock_id — the
--            reporting identity is (vineyard_id, vintage, paddock_id,
--            planting_group_key). Clients mirror the exact same algorithm.
--   Column public.picking_records.planting_group_key  text NULL
--            The stable group identity. Server-canonicalised on every write
--            (see trigger) so client drift cannot fork a group. NULL =
--            unlinked (all pre-184 rows — never backfilled by guessing —
--            free-text varieties, and explicit "Not specified" selections).
--   Column public.picking_records.variety_allocation_ids  uuid[] NULL
--            The MEMBER allocation ids (paddocks.variety_allocations[].id)
--            of the group at entry time, in block-config order. Point-in-time
--            snapshot, no FK. '{}' is a valid linked value (legacy member
--            allocations without minted ids). NULL = unlinked.
--   Column public.picking_records.rootstock  text NULL
--            Rootstock display snapshot from the group (e.g. `Richter 110`),
--            same point-in-time semantics as the existing `clone` snapshot.
--   View   public.picking_yield_planting_totals — per-group totals for
--            Portal / Yield reporting. The sql/180 `picking_yield_totals`
--            view is UNCHANGED (Block + Variety + Vintage stays the
--            canonical actual-yield contract; because the group key embeds
--            the normalised variety name, group rows nest exactly inside
--            variety rows and the supersede rule in
--            docs/vinetrack-picking-log.md §5 is unaffected).
--
-- Snapshot semantics (same rule as paddock_name / variety_name / clone):
-- the group link is point-in-time with no foreign key — allocations live in
-- the paddocks JSONB and may be edited or removed later; picking records
-- never change retroactively. Clients resolve the group against the block's
-- current allocations for display and fall back to stored snapshots when the
-- group no longer exists.
--
-- NO BACKFILL — deliberate. Existing rows cannot be attributed to a group
-- without guessing whether the person meant the whole group or one section.
-- Historical picks remain unlinked (`planting_group_key IS NULL`); linking
-- happens only through an explicit selection on create or edit.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Remove sql/183 artifacts if they were ever applied (they never were on
--    the live project — these are safe no-ops that keep retries idempotent).
-- ---------------------------------------------------------------------------
drop view if exists public.picking_yield_allocation_totals;
drop index if exists public.idx_picking_records_allocation;
alter table public.picking_records
  drop column if exists variety_allocation_id;

-- ---------------------------------------------------------------------------
-- 1. Shared group-key function (immutable — identical algorithm on iOS,
--    Android and the Portal; see the contract doc §3).
-- ---------------------------------------------------------------------------
create or replace function public.planting_group_key(
  p_variety text,
  p_clone text,
  p_rootstock text
) returns text
language sql
immutable
as $$
  select lower(regexp_replace(btrim(coalesce(p_variety,  '')), '\s+', ' ', 'g'))
    || '|' || lower(regexp_replace(btrim(coalesce(p_clone,    '')), '\s+', ' ', 'g'))
    || '|' || lower(regexp_replace(btrim(coalesce(p_rootstock,'')), '\s+', ' ', 'g'));
$$;

grant execute on function public.planting_group_key(text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Columns
-- ---------------------------------------------------------------------------
alter table public.picking_records
  add column if not exists planting_group_key text null;

alter table public.picking_records
  add column if not exists variety_allocation_ids uuid[] null;

alter table public.picking_records
  add column if not exists rootstock text null;

comment on column public.picking_records.planting_group_key is
  'Stable planting-group identity: planting_group_key(variety_name, clone, rootstock), scoped per paddock_id. Server-canonicalised on write. NULL = unlinked (historical rows are never backfilled by guessing).';
comment on column public.picking_records.variety_allocation_ids is
  'Member paddocks.variety_allocations[].id snapshot of the planting group at entry time (block-config order). ''{}'' = linked group whose member allocations have no minted ids. NULL = unlinked.';
comment on column public.picking_records.rootstock is
  'Point-in-time rootstock display snapshot from the planting group (e.g. Richter 110). Reference only, like clone.';

-- Group-level reporting path.
create index if not exists idx_picking_records_planting_group
  on public.picking_records (vineyard_id, vintage, paddock_id, planting_group_key)
  where deleted_at is null and planting_group_key is not null;

-- "Which picks reference allocation X" lookups (Portal / block editors).
create index if not exists idx_picking_records_allocation_members
  on public.picking_records using gin (variety_allocation_ids)
  where variety_allocation_ids is not null;

-- ---------------------------------------------------------------------------
-- 3. Server-authoritative canonicalisation (extends the sql/180 trigger)
--
-- Linked rows (either group field present) get their key recomputed from the
-- stored snapshots via planting_group_key(), so a client can never fork a
-- group with divergent casing/whitespace, and members coalesce to '{}'.
-- Unlinked rows keep BOTH fields null — a partial write cannot half-link.
-- ---------------------------------------------------------------------------
create or replace function public.picking_records_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, new.picked_at);
  new.sugar_unit := nullif(lower(trim(coalesce(new.sugar_unit, ''))), '');
  if new.sugar_value is null then
    new.sugar_unit := null;
  end if;
  if not new.sold then
    -- unsold picks carry no commercial fields (§7 of the contract)
    new.sold_to := null;
    new.price_per_tonne := null;
  end if;
  new.sold_to := nullif(trim(coalesce(new.sold_to, '')), '');
  -- Planting-group canonicalisation (sql/184)
  if new.planting_group_key is null and new.variety_allocation_ids is null then
    null; -- unlinked: leave both null
  else
    new.planting_group_key := public.planting_group_key(new.variety_name, new.clone, new.rootstock);
    new.variety_allocation_ids := coalesce(new.variety_allocation_ids, '{}'::uuid[]);
  end if;
  return new;
end;
$$;

-- (trigger picking_records_before_write from sql/180 already calls this
--  function BEFORE INSERT OR UPDATE — no trigger change needed.)

-- ---------------------------------------------------------------------------
-- 4. Per-planting-group totals view (security_invoker — caller's RLS applies)
--
-- Linked rows aggregate per (paddock, group key): the key IS the identity,
-- and member_allocation_ids is the distinct union of every member id seen in
-- the group's picks (block config may have changed between picks). Unlinked
-- rows (NULL key) keep the sql/180 variety-name identity so they split per
-- variety, not into one mixed bucket per block — via `unlinked_variety_key`.
-- ---------------------------------------------------------------------------
create or replace view public.picking_yield_planting_totals
with (security_invoker = on) as
with base as (
  select *
  from public.picking_records
  where deleted_at is null
),
totals as (
  select
    vineyard_id,
    vintage,
    paddock_id,
    planting_group_key,
    case
      when planting_group_key is null then lower(btrim(variety_name))
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
  from base
  group by vineyard_id, vintage, paddock_id, planting_group_key,
    case
      when planting_group_key is null then lower(btrim(variety_name))
    end
),
members as (
  select
    b.vineyard_id,
    b.vintage,
    b.paddock_id,
    b.planting_group_key,
    array_agg(distinct m order by m)        as member_allocation_ids
  from base b
  cross join lateral unnest(coalesce(b.variety_allocation_ids, '{}'::uuid[])) as m
  where b.planting_group_key is not null
  group by b.vineyard_id, b.vintage, b.paddock_id, b.planting_group_key
)
select
  t.vineyard_id,
  t.vintage,
  t.paddock_id,
  t.planting_group_key,
  t.unlinked_variety_key,
  t.paddock_name,
  t.variety_name,
  t.clone,
  t.rootstock,
  m.member_allocation_ids,
  t.pick_count,
  t.total_weight_kg,
  t.actual_yield_tonnes,
  t.first_picked_at,
  t.last_picked_at,
  t.total_grape_value
from totals t
left join members m
  on  m.vineyard_id        = t.vineyard_id
  and m.vintage            = t.vintage
  and m.paddock_id         = t.paddock_id
  and m.planting_group_key = t.planting_group_key;

grant select on public.picking_yield_planting_totals to authenticated;

notify pgrst, 'reload schema';

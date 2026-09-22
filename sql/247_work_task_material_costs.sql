-- 247_work_task_material_costs.sql
-- Work Task Material Costs — foundation schema (Round 1).
--
-- Materials CONSUMED while completing a Work Task: posts, wire, gripples,
-- clips, zip ties, netting, irrigation repair parts, vine establishment
-- materials. The whole concept is:
--
--     material + quantity + unit + unit cost = material cost
--
-- This is NOT inventory. There is deliberately no stock on hand, no stock
-- movement, no warehouse, no purchase order, no supplier, no invoice, no
-- receipt, no minimum-stock alert, no SKU/barcode, no GST/tax, and no
-- package-to-unit conversion (a roll is NOT converted to metres here).
--
-- Three concepts, in dependency order:
--
--   A. public.material_catalogue        — global VineTrack base catalogue
--                                         (18 high-level items, NO prices)
--   B. public.vineyard_materials        — per-vineyard library: default unit
--                                         costs for base items + custom items
--   C. public.work_task_materials       — the material lines actually used on
--                                         a Work Task, with FROZEN snapshots
--
-- Strictly additive. Nothing existing is altered: no change to work_tasks,
-- work_task_labour_lines, work_task_machine_lines, work_task_paddocks,
-- work_task_piece_rate_rows, task lifecycle, assignment, status, completion,
-- or any existing RLS policy or RPC. A work task with no material rows costs
-- $0 in materials and needs no row to say so.
--
-- Permissions follow the NORMAL VineTrack vineyard/work-task model:
--   * catalogue          — readable by any authenticated user; no client writes
--   * vineyard_materials — member read; owner/manager/supervisor manage
--                          (the existing vineyard-configuration pattern, as
--                          used by worker types / operator categories)
--   * work_task_materials— member read; owner/manager/supervisor/operator
--                          insert+update (mirrors work_task_labour_lines);
--                          soft-delete RPC restricted to
--                          owner/manager/supervisor
--
-- System Admin is deliberately NOT part of this model. The temporary
-- System-Admin-only exposure during development lives ENTIRELY in the two
-- mobile feature gates (iOS `WorkTaskMaterialCostsAccess`, Android
-- `WorkTaskMaterialCostsAccess`). Removing that gate later requires NO
-- database migration and NO policy change.
--
-- Money: numeric(14, 4) for unit cost and numeric(14, 2) for the line total —
-- never binary floating point. Quantity is numeric(14, 4) so decimal
-- quantities (42.5 m, 0.5 roll) are exact. `total_cost` is a GENERATED STORED
-- column so quantity x unit_cost can never drift from what a client computed.
-- Currency is the vineyard's existing currency (organisation_region_settings
-- .currency_code); no currency is hard-coded here and no currency column is
-- duplicated onto these rows.
--
-- Units: plain non-empty TEXT, NOT an enum. Each / Metre / Roll / Pack / Box /
-- Bag are the suggested values; a future custom unit must not need a
-- migration.

-- =====================================================================
-- A. public.material_catalogue — global, system-owned, read-only
-- =====================================================================
-- Stable `key` is the cross-platform identity shared by Supabase, iOS and
-- Android. The bundled offline fallback catalogue on each client uses these
-- exact keys, so the same material is the same material everywhere. Keys are
-- permanent: retire an item with is_active = false, never by deleting or
-- renaming the key.
create table if not exists public.material_catalogue (
  id uuid primary key default gen_random_uuid(),
  key text not null,
  name text not null,
  category text not null,
  default_unit text not null,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint material_catalogue_key_not_blank check (btrim(key) <> ''),
  constraint material_catalogue_name_not_blank check (btrim(name) <> ''),
  constraint material_catalogue_category_not_blank check (btrim(category) <> ''),
  constraint material_catalogue_default_unit_not_blank check (btrim(default_unit) <> '')
);

create unique index if not exists uq_material_catalogue_key
  on public.material_catalogue (key);
create index if not exists idx_material_catalogue_active_sort
  on public.material_catalogue (is_active, sort_order);

create or replace trigger material_catalogue_set_updated_at
before update on public.material_catalogue
for each row execute function public.set_updated_at();

alter table public.material_catalogue enable row level security;

-- Any signed-in VineTrack user may read the base catalogue: it holds no
-- vineyard data and no prices, and every vineyard's picker needs it.
drop policy if exists "material_catalogue_select_authenticated"
  on public.material_catalogue;
create policy "material_catalogue_select_authenticated"
on public.material_catalogue for select
to authenticated
using (true);

-- The base catalogue is system-owned. No client insert/update/delete policy
-- exists, so with RLS enabled every client write is refused. Seeding and
-- future catalogue changes happen through migrations / service_role only.
drop policy if exists "material_catalogue_no_client_insert"
  on public.material_catalogue;
create policy "material_catalogue_no_client_insert"
on public.material_catalogue for insert
to authenticated
with check (false);

drop policy if exists "material_catalogue_no_client_update"
  on public.material_catalogue;
create policy "material_catalogue_no_client_update"
on public.material_catalogue for update
to authenticated
using (false)
with check (false);

drop policy if exists "material_catalogue_no_client_delete"
  on public.material_catalogue;
create policy "material_catalogue_no_client_delete"
on public.material_catalogue for delete
to authenticated
using (false);

comment on table public.material_catalogue is
  'Global VineTrack base material catalogue (sql/247). System-owned and read-only to clients; deliberately high-level (no post sizes, wire gauges, Gripple models, dripper brands or netting sizes) and deliberately price-free — prices belong to the vineyard in public.vineyard_materials.';

-- ---------------------------------------------------------------------
-- Seed the 18 base items. Idempotent: re-running refreshes name/category/
-- unit/sort order for an existing key and never duplicates a row.
-- ---------------------------------------------------------------------
insert into public.material_catalogue (key, name, category, default_unit, sort_order)
values
  ('material.trellis.line_post',        'Line / Trellis Post',                 'Trellis',                 'Each',   10),
  ('material.trellis.end_post',         'End / Strainer Post',                 'Trellis',                 'Each',   20),
  ('material.trellis.wire',             'Trellis Wire',                        'Trellis',                 'Metre',  30),
  ('material.trellis.anchor',           'Anchor / Stay',                       'Trellis',                 'Each',   40),
  ('material.trellis.gripple',          'Gripple / Wire Joiner-Tensioner',     'Trellis',                 'Each',   50),
  ('material.fastener.trellis_clip',    'Trellis Clip / Staple',               'Fasteners & Training',    'Each',   60),
  ('material.fastener.vine_tie',        'Vine / Wire Tie',                     'Fasteners & Training',    'Each',   70),
  ('material.fastener.zip_tie',         'Cable / Zip Tie',                     'Fasteners & Training',    'Each',   80),
  ('material.netting.post_cap',         'Post / Netting Cap',                  'Netting & Protection',    'Each',   90),
  ('material.netting.bird_netting',     'Bird Netting',                        'Netting & Protection',    'Metre', 100),
  ('material.netting.clip_repair',      'Netting Clip / Repair Material',      'Netting & Protection',    'Each',  110),
  ('material.irrigation.dripline',      'Dripline / Poly Pipe',                'Irrigation',              'Metre', 120),
  ('material.irrigation.dripper',       'Dripper / Emitter',                   'Irrigation',              'Each',  130),
  ('material.irrigation.fitting',       'Irrigation Fitting / Repair Joiner',  'Irrigation',              'Each',  140),
  ('material.establishment.vine_stake', 'Vine Stake',                          'Vine Establishment',      'Each',  150),
  ('material.establishment.vine_guard', 'Vine Guard',                          'Vine Establishment',      'Each',  160),
  ('material.establishment.vine',       'Replacement Vine',                    'Vine Establishment',      'Each',  170),
  ('material.other.miscellaneous',      'Other / Miscellaneous Material',      'Other',                   'Each',  180)
on conflict (key) do update
set name         = excluded.name,
    category     = excluded.category,
    default_unit = excluded.default_unit,
    sort_order   = excluded.sort_order;

-- =====================================================================
-- B. public.vineyard_materials — per-vineyard library
-- =====================================================================
-- Two shapes in one table:
--
--   * an OVERRIDE of a base catalogue item — base_material_id set,
--     is_custom = false. Carries the vineyard's own default unit cost and,
--     where appropriate, its own unit.
--   * a CUSTOM vineyard material — base_material_id null, is_custom = true
--     ("Gripple Plus Medium", "2.4 m Eco Trellis Post").
--
-- A vineyard row is only created when the vineyard actually sets a price or
-- adds a custom item. Clients MERGE catalogue + vineyard rows at read time,
-- so no vineyard is pre-populated with 18 empty rows.
--
-- `default_unit_cost` and `unit` are DEFAULTS used when adding the material to
-- a task. Changing them later never rewrites a Work Task: see section C.
create table if not exists public.vineyard_materials (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  base_material_id uuid null references public.material_catalogue(id) on delete set null,
  name text not null,
  category text not null default '',
  unit text not null,
  default_unit_cost numeric(14, 4) null,
  is_custom boolean not null default false,
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1,
  constraint vineyard_materials_name_not_blank check (btrim(name) <> ''),
  constraint vineyard_materials_unit_not_blank check (btrim(unit) <> ''),
  constraint vineyard_materials_cost_non_negative
    check (default_unit_cost is null or default_unit_cost >= 0),
  -- A base override must point at a catalogue item; a custom material must not.
  constraint vineyard_materials_custom_shape
    check ((is_custom and base_material_id is null) or (not is_custom and base_material_id is not null))
);

-- One live override per (vineyard, base material). A custom material is not
-- constrained by this index (base_material_id is null), so a vineyard may have
-- several custom Gripple variants.
create unique index if not exists uq_vineyard_materials_active_base
  on public.vineyard_materials (vineyard_id, base_material_id)
  where deleted_at is null and base_material_id is not null;

-- One live custom material per name per vineyard, case-insensitive.
create unique index if not exists uq_vineyard_materials_active_custom_name_ci
  on public.vineyard_materials (vineyard_id, lower(name))
  where deleted_at is null and base_material_id is null;

create index if not exists idx_vineyard_materials_vineyard_id
  on public.vineyard_materials (vineyard_id);
create index if not exists idx_vineyard_materials_vineyard_active
  on public.vineyard_materials (vineyard_id, is_active);
create index if not exists idx_vineyard_materials_base_material_id
  on public.vineyard_materials (base_material_id);
create index if not exists idx_vineyard_materials_updated_at
  on public.vineyard_materials (updated_at);
create index if not exists idx_vineyard_materials_deleted_at
  on public.vineyard_materials (deleted_at);

create or replace trigger vineyard_materials_set_updated_at
before update on public.vineyard_materials
for each row execute function public.set_updated_at();

alter table public.vineyard_materials enable row level security;

-- Read: any member of the vineyard. A vineyard's private custom library and
-- its prices are never visible to another vineyard, including through direct
-- PostgREST calls.
drop policy if exists "vineyard_materials_select_members"
  on public.vineyard_materials;
create policy "vineyard_materials_select_members"
on public.vineyard_materials for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

-- Manage: the existing vineyard-CONFIGURATION permission shape. The material
-- library is setup data (like worker types and rates), not day-to-day task
-- entry, so operators consume it but do not edit it.
drop policy if exists "vineyard_materials_insert_managers"
  on public.vineyard_materials;
create policy "vineyard_materials_insert_managers"
on public.vineyard_materials for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor']));

drop policy if exists "vineyard_materials_update_managers"
  on public.vineyard_materials;
create policy "vineyard_materials_update_managers"
on public.vineyard_materials for update
to authenticated
using (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor']))
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor']));

-- No client hard delete: history depends on these rows remaining resolvable.
drop policy if exists "vineyard_materials_no_client_hard_delete"
  on public.vineyard_materials;
create policy "vineyard_materials_no_client_hard_delete"
on public.vineyard_materials for delete
to authenticated
using (false);

comment on table public.vineyard_materials is
  'Per-vineyard material library (sql/247): default unit costs for base catalogue items plus the vineyard''s own custom materials. Prices live here, never on public.material_catalogue. Deactivating or repricing a row never alters an existing work_task_materials snapshot.';

-- =====================================================================
-- C. public.work_task_materials — the Work Task child rows
-- =====================================================================
-- HISTORICAL INTEGRITY IS THE POINT OF THIS TABLE.
--
-- `material_name`, `category`, `unit`, `quantity` and `unit_cost` are a
-- SNAPSHOT taken when the material was placed on the task. `base_material_id`
-- and `vineyard_material_id` are provenance only — both are ON DELETE SET NULL
-- and neither is required to read the row. Repricing, renaming, deactivating
-- or removing a library material can never change, hide or delete a historical
-- Work Task cost:
--
--     Task today:  Trellis Post  3 Each  $12.40  =  $37.20
--     Library later raised to $14.50
--     Task still reads: Trellis Post  3 Each  $12.40  =  $37.20
--
-- `total_cost` is generated (quantity x unit_cost) so the stored total always
-- derives from the stored inputs, on every platform, forever.
--
-- Reporting readiness (no reports are built in this phase): vineyard_id +
-- work_task_id + category + quantity + unit_cost + total_cost + created_at
-- support per-task, per-vineyard, per-category and per-season roll-ups, and
-- joining work_task_paddocks / work_tasks.area_ha gives per-block and
-- per-hectare material cost alongside the existing labour and machine lines.
create table if not exists public.work_task_materials (
  id uuid primary key default gen_random_uuid(),
  work_task_id uuid not null references public.work_tasks(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,

  -- Provenance (nullable, never required to read the row).
  base_material_id uuid null references public.material_catalogue(id) on delete set null,
  vineyard_material_id uuid null references public.vineyard_materials(id) on delete set null,

  -- FROZEN snapshot.
  material_name text not null,
  category text not null default '',
  unit text not null,
  quantity numeric(14, 4) not null default 0,
  unit_cost numeric(14, 4) not null default 0,
  total_cost numeric(14, 2) generated always as
    (round(coalesce(quantity, 0) * coalesce(unit_cost, 0), 2)) stored,

  notes text not null default '',

  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1,

  constraint work_task_materials_name_not_blank check (btrim(material_name) <> ''),
  constraint work_task_materials_unit_not_blank check (btrim(unit) <> ''),
  constraint work_task_materials_quantity_non_negative check (quantity >= 0),
  constraint work_task_materials_unit_cost_non_negative check (unit_cost >= 0)
);

create index if not exists idx_work_task_materials_work_task_id
  on public.work_task_materials (work_task_id);
create index if not exists idx_work_task_materials_vineyard_id
  on public.work_task_materials (vineyard_id);
create index if not exists idx_work_task_materials_vineyard_category
  on public.work_task_materials (vineyard_id, category);
create index if not exists idx_work_task_materials_vineyard_created_at
  on public.work_task_materials (vineyard_id, created_at);
create index if not exists idx_work_task_materials_base_material_id
  on public.work_task_materials (base_material_id);
create index if not exists idx_work_task_materials_vineyard_material_id
  on public.work_task_materials (vineyard_material_id);
create index if not exists idx_work_task_materials_updated_at
  on public.work_task_materials (updated_at);
create index if not exists idx_work_task_materials_deleted_at
  on public.work_task_materials (deleted_at);

create or replace trigger work_task_materials_set_updated_at
before update on public.work_task_materials
for each row execute function public.set_updated_at();

alter table public.work_task_materials enable row level security;

-- Read / write mirror public.work_task_labour_lines exactly, so material lines
-- ultimately inherit the same permission contract as editing the parent task.
drop policy if exists "work_task_materials_select_members"
  on public.work_task_materials;
create policy "work_task_materials_select_members"
on public.work_task_materials for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "work_task_materials_insert_members"
  on public.work_task_materials;
create policy "work_task_materials_insert_members"
on public.work_task_materials for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "work_task_materials_update_members"
  on public.work_task_materials;
create policy "work_task_materials_update_members"
on public.work_task_materials for update
to authenticated
using (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "work_task_materials_no_client_hard_delete"
  on public.work_task_materials;
create policy "work_task_materials_no_client_hard_delete"
on public.work_task_materials for delete
to authenticated
using (false);

comment on table public.work_task_materials is
  'Materials consumed on a Work Task (sql/247). material_name / category / unit / quantity / unit_cost are a FROZEN snapshot owned by the task: later library repricing, renaming, deactivation or removal never alters historical task cost. total_cost is generated as quantity x unit_cost. Not inventory: no stock, supplier, purchase, tax or pack conversion.';

-- =====================================================================
-- soft_delete_vineyard_material
-- =====================================================================
-- Deactivating/removing a library material NEVER touches work_task_materials.
-- There is deliberately no cascade: historical rows stay independently
-- readable from their own snapshot.
create or replace function public.soft_delete_vineyard_material(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id
    from public.vineyard_materials where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Vineyard material not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id,
       array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete vineyard material';
  end if;
  update public.vineyard_materials
     set deleted_at = now(), is_active = false, updated_by = auth.uid()
   where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_vineyard_material(uuid) from public;
revoke all on function public.soft_delete_vineyard_material(uuid) from anon;
grant execute on function public.soft_delete_vineyard_material(uuid) to authenticated;

comment on function public.soft_delete_vineyard_material(uuid) is
  'Soft-delete one vineyard material library row (sql/247). Owner/manager/supervisor only. Deliberately does NOT touch work_task_materials — historical Work Task usage survives.';

-- =====================================================================
-- soft_delete_work_task_material
-- =====================================================================
-- Mirrors soft_delete_work_task_labour_line: only owner/manager/supervisor may
-- remove a material line. Operators may add and edit lines under RLS.
create or replace function public.soft_delete_work_task_material(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id
    from public.work_task_materials where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Work task material not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id,
       array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete work task material';
  end if;
  update public.work_task_materials
     set deleted_at = now(), updated_by = auth.uid()
   where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_work_task_material(uuid) from public;
revoke all on function public.soft_delete_work_task_material(uuid) from anon;
grant execute on function public.soft_delete_work_task_material(uuid) to authenticated;

comment on function public.soft_delete_work_task_material(uuid) is
  'Soft-delete one Work Task material line (sql/247). Owner/manager/supervisor only, mirroring soft_delete_work_task_labour_line.';

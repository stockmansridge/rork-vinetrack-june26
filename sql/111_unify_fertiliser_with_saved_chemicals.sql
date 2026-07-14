-- 111: Unify the Fertiliser Calculator product library with the existing
-- saved chemical/product database (`public.saved_chemicals`, sql/011 + 086 + 087).
--
-- Fertilisers and nutrient products are another category of saved agricultural
-- product, not an independent product type. This migration:
--
--   1. Extends `saved_chemicals` with the fertiliser-specific fields
--      (category, form, pack size/price, N-P-K analysis + basis, inventory,
--      application notes, active flag). All nullable / defaulted so existing
--      spray chemicals are untouched and nutrient values stay optional.
--   2. Migrates any rows already created in `fertiliser_products` (sql/110)
--      into `saved_chemicals`, PRESERVING their ids so every existing
--      `fertiliser_records.product_id` stays valid.
--   3. Re-points `fertiliser_records.product_id` to reference
--      `saved_chemicals(id)` instead of `fertiliser_products(id)`.
--   4. Drops the obsolete `fertiliser_products` table and its soft-delete RPC.
--
-- Product category keys (stored in `product_category`; '' = uncategorised —
-- every pre-existing spray chemical stays uncategorised and keeps working):
--   fungicide, insecticide, herbicide, adjuvant, growthRegulator,
--   foliarNutrient, granularFertiliser, liquidFertiliser, fertigation,
--   compost, manure, biofertiliser, compostTea, seaweed, fishHydrolysate,
--   humicFulvic, soilAmendment, other
--
-- `analysis_basis` explicitly distinguishes elemental N-P-K from oxide
-- (P₂O₅ / K₂O) label values. Nutrient fields are null for ordinary spray
-- chemicals.
--
-- Idempotent: safe to run more than once; runs in a single transaction so a
-- failure leaves no partially migrated schema.
--
-- RLS: unchanged. The existing `saved_chemicals` policies (vineyard-member
-- select, owner/manager insert/update, no client hard delete, soft-delete via
-- `soft_delete_saved_chemicals`, guarded hard delete via
-- `hard_delete_unused_saved_chemical`) now govern fertiliser products too.
-- The catalog-driven FK check inside `hard_delete_unused_saved_chemical`
-- automatically respects the new `fertiliser_records.product_id` FK, so a
-- product used in a fertiliser record can be archived but never hard-deleted.

begin;

-- ---------------------------------------------------------------------------
-- 1. Extend saved_chemicals (only fields that do not already exist)
-- ---------------------------------------------------------------------------
alter table public.saved_chemicals
  add column if not exists product_category text not null default '',
  add column if not exists product_form text not null default '',
  add column if not exists pack_size numeric,
  add column if not exists pack_unit text not null default '',
  add column if not exists price_per_pack numeric,
  add column if not exists density numeric,
  add column if not exists nitrogen_percent numeric,
  add column if not exists phosphorus_percent numeric,
  add column if not exists potassium_percent numeric,
  add column if not exists analysis_basis text not null default 'elemental',
  add column if not exists organic_certified boolean not null default false,
  add column if not exists inventory_quantity numeric,
  add column if not exists inventory_unit text not null default '',
  add column if not exists application_notes text not null default '',
  add column if not exists is_active boolean not null default true;

-- Guarded check constraints (added once; existing rows satisfy the defaults).
do $$
begin
  alter table public.saved_chemicals
    add constraint saved_chemicals_product_form_check
    check (product_form in ('', 'solid', 'liquid'));
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter table public.saved_chemicals
    add constraint saved_chemicals_analysis_basis_check
    check (analysis_basis in ('elemental', 'oxide'));
exception
  when duplicate_object then null;
end $$;

create index if not exists idx_saved_chemicals_product_category
  on public.saved_chemicals (product_category);

-- ---------------------------------------------------------------------------
-- 2. Migrate any existing fertiliser_products rows into saved_chemicals,
--    preserving ids so fertiliser_records.product_id references stay valid.
--    Old category keys map onto the unified key set:
--      foliar        -> foliarNutrient
--      pelletised    -> granularFertiliser
--      conventional  -> granularFertiliser (or liquidFertiliser when liquid)
--      humic         -> humicFulvic
--      (compost, manure, biofertiliser, compostTea, seaweed, fishHydrolysate,
--       other map 1:1; anything unknown falls back to 'other')
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.fertiliser_products') is not null then
    insert into public.saved_chemicals (
      id, vineyard_id, name, manufacturer, unit,
      product_category, product_form, pack_size, pack_unit, price_per_pack,
      density, nitrogen_percent, phosphorus_percent, potassium_percent,
      analysis_basis, organic_certified, inventory_quantity, inventory_unit,
      application_notes, is_active,
      created_by, updated_by, created_at, updated_at,
      deleted_at, client_updated_at
    )
    select
      p.id,
      p.vineyard_id,
      coalesce(p.name, ''),
      coalesce(p.manufacturer, ''),
      case when p.form = 'liquid' then 'Litres' else 'Kg' end,
      case p.category
        when 'foliar'         then 'foliarNutrient'
        when 'pelletised'     then 'granularFertiliser'
        when 'conventional'   then case when p.form = 'liquid'
                                        then 'liquidFertiliser'
                                        else 'granularFertiliser' end
        when 'humic'          then 'humicFulvic'
        when 'compost'        then 'compost'
        when 'manure'         then 'manure'
        when 'biofertiliser'  then 'biofertiliser'
        when 'compostTea'     then 'compostTea'
        when 'seaweed'        then 'seaweed'
        when 'fishHydrolysate' then 'fishHydrolysate'
        else 'other'
      end,
      coalesce(p.form, 'solid'),
      p.pack_size,
      coalesce(p.pack_unit, ''),
      p.price_per_pack,
      p.density,
      p.nitrogen_percent,
      p.phosphorus_percent,
      p.potassium_percent,
      coalesce(p.analysis_basis, 'elemental'),
      coalesce(p.organic_certified, false),
      p.inventory_quantity,
      coalesce(p.inventory_unit, 'packs'),
      coalesce(p.application_notes, ''),
      coalesce(p.is_active, true),
      p.created_by,
      p.updated_by,
      p.created_at,
      p.updated_at,
      p.deleted_at,
      p.client_updated_at
    from public.fertiliser_products p
    on conflict (id) do nothing;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Re-point fertiliser_records.product_id at saved_chemicals(id)
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.fertiliser_records') is not null then
    -- Drop the old FK to fertiliser_products.
    alter table public.fertiliser_records
      drop constraint if exists fertiliser_records_product_id_fkey;

    -- Defensive: null any product reference that did not survive migration
    -- (should be none — step 2 preserves ids). Records keep their
    -- product_name / form / pack_size historical snapshot regardless.
    update public.fertiliser_records r
       set product_id = null
     where r.product_id is not null
       and not exists (
             select 1 from public.saved_chemicals c where c.id = r.product_id
           );

    -- New FK to the shared saved product table. Plain FK (no cascade) so the
    -- guarded hard-delete RPC refuses to delete a product in use.
    if not exists (
      select 1
        from information_schema.table_constraints
       where constraint_name = 'fertiliser_records_product_saved_chemical_fkey'
         and table_name = 'fertiliser_records'
         and table_schema = 'public'
    ) then
      alter table public.fertiliser_records
        add constraint fertiliser_records_product_saved_chemical_fkey
        foreign key (product_id) references public.saved_chemicals(id);
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Remove the obsolete dedicated product table + RPC
-- ---------------------------------------------------------------------------
drop function if exists public.soft_delete_fertiliser_product(uuid);
drop table if exists public.fertiliser_products;

commit;

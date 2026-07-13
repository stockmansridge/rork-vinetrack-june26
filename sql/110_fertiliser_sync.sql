-- 110: Fertiliser Calculator shared sync tables (Phase 2).
--
--   * fertiliser_products            — the shared product library (analysis basis is
--                                      stored explicitly: elemental vs oxide P2O5/K2O).
--   * fertiliser_records             — saved calculations / planned tasks / completed
--                                      application records (record_status lifecycle).
--   * fertiliser_record_allocations  — per-block breakdown of a multi-block record so
--                                      block-level costing and reporting stay accurate.
--
-- Same sync contract as saved_chemicals: client-generated ids, upsert on id,
-- LWW via client_updated_at, soft delete via security-definer RPCs.

-- ---------------------------------------------------------------------------
-- fertiliser_products
-- ---------------------------------------------------------------------------
create table if not exists public.fertiliser_products (
  id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null default '',
  manufacturer text not null default '',
  category text not null default 'conventional',
  form text not null default 'solid' check (form in ('solid','liquid')),
  pack_size numeric not null default 25,
  pack_unit text not null default 'kg',
  price_per_pack numeric,
  density numeric,
  nitrogen_percent numeric,
  phosphorus_percent numeric,
  potassium_percent numeric,
  analysis_basis text not null default 'elemental' check (analysis_basis in ('elemental','oxide')),
  organic_certified boolean not null default false,
  inventory_quantity numeric,
  inventory_unit text not null default 'packs',
  application_notes text not null default '',
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  client_updated_at timestamptz,
  sync_version integer not null default 1
);

create index if not exists fertiliser_products_vineyard_idx on public.fertiliser_products (vineyard_id);
create index if not exists fertiliser_products_updated_idx on public.fertiliser_products (updated_at);

drop trigger if exists fertiliser_products_set_updated_at on public.fertiliser_products;
create trigger fertiliser_products_set_updated_at
  before update on public.fertiliser_products
  for each row execute function public.set_updated_at();

alter table public.fertiliser_products enable row level security;

drop policy if exists "fertiliser_products_select_members" on public.fertiliser_products;
create policy "fertiliser_products_select_members" on public.fertiliser_products
  for select to authenticated
  using (public.is_vineyard_member(vineyard_id));

drop policy if exists "fertiliser_products_insert_members" on public.fertiliser_products;
create policy "fertiliser_products_insert_members" on public.fertiliser_products
  for insert to authenticated
  with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "fertiliser_products_update_members" on public.fertiliser_products;
create policy "fertiliser_products_update_members" on public.fertiliser_products
  for update to authenticated
  using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
  with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "fertiliser_products_no_client_hard_delete" on public.fertiliser_products;
create policy "fertiliser_products_no_client_hard_delete" on public.fertiliser_products
  for delete to authenticated using (false);

-- ---------------------------------------------------------------------------
-- fertiliser_records
-- ---------------------------------------------------------------------------
create table if not exists public.fertiliser_records (
  id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  product_id uuid references public.fertiliser_products(id),
  product_name text not null default '',
  form text not null default 'solid' check (form in ('solid','liquid')),
  calculation_mode text not null default 'perHectare'
    check (calculation_mode in ('perHectare','perVine','nutrientTarget','fertigation')),
  record_status text not null default 'planned'
    check (record_status in ('draft','planned','completed','cancelled')),
  application_date date not null default current_date,
  block_names text[] not null default '{}',
  total_area_ha numeric not null default 0,
  total_vines integer not null default 0,
  application_rate numeric not null default 0,
  application_rate_unit text not null default 'kg/ha',
  total_product_required numeric not null default 0,
  product_unit text not null default 'kg',
  pack_size numeric,
  pack_count numeric,
  estimated_product_cost numeric,
  labour_cost numeric,
  machinery_cost numeric,
  total_job_cost numeric,
  notes text not null default '',
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  client_updated_at timestamptz,
  sync_version integer not null default 1
);

create index if not exists fertiliser_records_vineyard_idx on public.fertiliser_records (vineyard_id);
create index if not exists fertiliser_records_updated_idx on public.fertiliser_records (updated_at);

drop trigger if exists fertiliser_records_set_updated_at on public.fertiliser_records;
create trigger fertiliser_records_set_updated_at
  before update on public.fertiliser_records
  for each row execute function public.set_updated_at();

alter table public.fertiliser_records enable row level security;

drop policy if exists "fertiliser_records_select_members" on public.fertiliser_records;
create policy "fertiliser_records_select_members" on public.fertiliser_records
  for select to authenticated
  using (public.is_vineyard_member(vineyard_id));

drop policy if exists "fertiliser_records_insert_members" on public.fertiliser_records;
create policy "fertiliser_records_insert_members" on public.fertiliser_records
  for insert to authenticated
  with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "fertiliser_records_update_members" on public.fertiliser_records;
create policy "fertiliser_records_update_members" on public.fertiliser_records
  for update to authenticated
  using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
  with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "fertiliser_records_no_client_hard_delete" on public.fertiliser_records;
create policy "fertiliser_records_no_client_hard_delete" on public.fertiliser_records
  for delete to authenticated using (false);

-- ---------------------------------------------------------------------------
-- fertiliser_record_allocations (per-block breakdown; written with the record)
-- ---------------------------------------------------------------------------
create table if not exists public.fertiliser_record_allocations (
  id uuid primary key,
  fertiliser_record_id uuid not null references public.fertiliser_records(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  paddock_id uuid not null,
  area_ha numeric not null default 0,
  vine_count integer not null default 0,
  application_rate numeric not null default 0,
  product_required numeric not null default 0,
  allocated_cost numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists fertiliser_record_allocations_record_idx
  on public.fertiliser_record_allocations (fertiliser_record_id);
create index if not exists fertiliser_record_allocations_vineyard_idx
  on public.fertiliser_record_allocations (vineyard_id);
create index if not exists fertiliser_record_allocations_updated_idx
  on public.fertiliser_record_allocations (updated_at);

drop trigger if exists fertiliser_record_allocations_set_updated_at on public.fertiliser_record_allocations;
create trigger fertiliser_record_allocations_set_updated_at
  before update on public.fertiliser_record_allocations
  for each row execute function public.set_updated_at();

alter table public.fertiliser_record_allocations enable row level security;

drop policy if exists "fertiliser_record_allocations_select_members" on public.fertiliser_record_allocations;
create policy "fertiliser_record_allocations_select_members" on public.fertiliser_record_allocations
  for select to authenticated
  using (public.is_vineyard_member(vineyard_id));

drop policy if exists "fertiliser_record_allocations_insert_members" on public.fertiliser_record_allocations;
create policy "fertiliser_record_allocations_insert_members" on public.fertiliser_record_allocations
  for insert to authenticated
  with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "fertiliser_record_allocations_update_members" on public.fertiliser_record_allocations;
create policy "fertiliser_record_allocations_update_members" on public.fertiliser_record_allocations
  for update to authenticated
  using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
  with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "fertiliser_record_allocations_no_client_hard_delete" on public.fertiliser_record_allocations;
create policy "fertiliser_record_allocations_no_client_hard_delete" on public.fertiliser_record_allocations
  for delete to authenticated using (false);

-- ---------------------------------------------------------------------------
-- Soft-delete RPCs
-- ---------------------------------------------------------------------------
create or replace function public.soft_delete_fertiliser_product(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_vineyard uuid;
begin
  select vineyard_id into v_vineyard from public.fertiliser_products where id = p_id;
  if v_vineyard is null then
    return;
  end if;
  if not public.has_vineyard_role(v_vineyard, array['owner','manager','supervisor']) then
    raise exception 'not allowed';
  end if;

  update public.fertiliser_products
  set deleted_at = now(), updated_by = auth.uid(), updated_at = now()
  where id = p_id and deleted_at is null;
end;
$$;

revoke all on function public.soft_delete_fertiliser_product(uuid) from public;
grant execute on function public.soft_delete_fertiliser_product(uuid) to authenticated;

create or replace function public.soft_delete_fertiliser_record(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_vineyard uuid;
begin
  select vineyard_id into v_vineyard from public.fertiliser_records where id = p_id;
  if v_vineyard is null then
    return;
  end if;
  if not public.has_vineyard_role(v_vineyard, array['owner','manager','supervisor']) then
    raise exception 'not allowed';
  end if;

  update public.fertiliser_records
  set deleted_at = now(), updated_by = auth.uid(), updated_at = now()
  where id = p_id and deleted_at is null;
end;
$$;

revoke all on function public.soft_delete_fertiliser_record(uuid) from public;
grant execute on function public.soft_delete_fertiliser_record(uuid) to authenticated;

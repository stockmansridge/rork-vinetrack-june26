-- Phase 15C: Spray management data sync.
-- Tables: saved_chemicals, saved_spray_presets, spray_equipment, tractors,
-- fuel_purchases, operator_categories. RLS enforces vineyard membership and
-- role-based mutation. Soft-delete via per-table RPCs.

-- =====================================================================
-- saved_chemicals
-- =====================================================================
create table if not exists public.saved_chemicals (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null default '',
  rate_per_ha double precision not null default 0,
  unit text not null default 'Litres',
  chemical_group text not null default '',
  use text not null default '',
  manufacturer text not null default '',
  restrictions text not null default '',
  notes text not null default '',
  crop text not null default '',
  problem text not null default '',
  active_ingredient text not null default '',
  rates jsonb null,
  purchase jsonb null,
  label_url text not null default '',
  mode_of_action text not null default '',
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_saved_chemicals_vineyard_id on public.saved_chemicals (vineyard_id);
create index if not exists idx_saved_chemicals_updated_at on public.saved_chemicals (updated_at);
create index if not exists idx_saved_chemicals_deleted_at on public.saved_chemicals (deleted_at);

create or replace trigger saved_chemicals_set_updated_at
before update on public.saved_chemicals
for each row execute function public.set_updated_at();

alter table public.saved_chemicals enable row level security;

drop policy if exists "saved_chemicals_select_members" on public.saved_chemicals;
create policy "saved_chemicals_select_members"
on public.saved_chemicals for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "saved_chemicals_insert_managers" on public.saved_chemicals;
create policy "saved_chemicals_insert_managers"
on public.saved_chemicals for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "saved_chemicals_update_managers" on public.saved_chemicals;
create policy "saved_chemicals_update_managers"
on public.saved_chemicals for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "saved_chemicals_no_client_hard_delete" on public.saved_chemicals;
create policy "saved_chemicals_no_client_hard_delete"
on public.saved_chemicals for delete
to authenticated
using (false);

create or replace function public.soft_delete_saved_chemical(p_id uuid)
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
  select vineyard_id into v_vineyard_id from public.saved_chemicals where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Saved chemical not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete saved chemical';
  end if;
  update public.saved_chemicals
  set deleted_at = now(), updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_saved_chemical(uuid) from public;
grant execute on function public.soft_delete_saved_chemical(uuid) to authenticated;

-- =====================================================================
-- saved_spray_presets
-- =====================================================================
create table if not exists public.saved_spray_presets (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null default '',
  water_volume double precision not null default 0,
  spray_rate_per_ha double precision not null default 0,
  concentration_factor double precision not null default 1,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_saved_spray_presets_vineyard_id on public.saved_spray_presets (vineyard_id);
create index if not exists idx_saved_spray_presets_updated_at on public.saved_spray_presets (updated_at);
create index if not exists idx_saved_spray_presets_deleted_at on public.saved_spray_presets (deleted_at);

create or replace trigger saved_spray_presets_set_updated_at
before update on public.saved_spray_presets
for each row execute function public.set_updated_at();

alter table public.saved_spray_presets enable row level security;

drop policy if exists "saved_spray_presets_select_members" on public.saved_spray_presets;
create policy "saved_spray_presets_select_members"
on public.saved_spray_presets for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "saved_spray_presets_insert_managers" on public.saved_spray_presets;
create policy "saved_spray_presets_insert_managers"
on public.saved_spray_presets for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "saved_spray_presets_update_managers" on public.saved_spray_presets;
create policy "saved_spray_presets_update_managers"
on public.saved_spray_presets for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "saved_spray_presets_no_client_hard_delete" on public.saved_spray_presets;
create policy "saved_spray_presets_no_client_hard_delete"
on public.saved_spray_presets for delete
to authenticated
using (false);

create or replace function public.soft_delete_saved_spray_preset(p_id uuid)
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
  select vineyard_id into v_vineyard_id from public.saved_spray_presets where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Saved spray preset not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete saved spray preset';
  end if;
  update public.saved_spray_presets
  set deleted_at = now(), updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_saved_spray_preset(uuid) from public;
grant execute on function public.soft_delete_saved_spray_preset(uuid) to authenticated;

-- =====================================================================
-- spray_equipment
-- =====================================================================
create table if not exists public.spray_equipment (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null default '',
  tank_capacity_litres double precision not null default 0,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_spray_equipment_vineyard_id on public.spray_equipment (vineyard_id);
create index if not exists idx_spray_equipment_updated_at on public.spray_equipment (updated_at);
create index if not exists idx_spray_equipment_deleted_at on public.spray_equipment (deleted_at);

create or replace trigger spray_equipment_set_updated_at
before update on public.spray_equipment
for each row execute function public.set_updated_at();

alter table public.spray_equipment enable row level security;

drop policy if exists "spray_equipment_select_members" on public.spray_equipment;
create policy "spray_equipment_select_members"
on public.spray_equipment for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "spray_equipment_insert_managers" on public.spray_equipment;
create policy "spray_equipment_insert_managers"
on public.spray_equipment for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "spray_equipment_update_managers" on public.spray_equipment;
create policy "spray_equipment_update_managers"
on public.spray_equipment for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "spray_equipment_no_client_hard_delete" on public.spray_equipment;
create policy "spray_equipment_no_client_hard_delete"
on public.spray_equipment for delete
to authenticated
using (false);

create or replace function public.soft_delete_spray_equipment(p_id uuid)
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
  select vineyard_id into v_vineyard_id from public.spray_equipment where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Spray equipment not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete spray equipment';
  end if;
  update public.spray_equipment
  set deleted_at = now(), updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_spray_equipment(uuid) from public;
grant execute on function public.soft_delete_spray_equipment(uuid) to authenticated;

-- =====================================================================
-- tractors
-- =====================================================================
create table if not exists public.tractors (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null default '',
  brand text not null default '',
  model text not null default '',
  model_year integer null,
  fuel_usage_l_per_hour double precision not null default 0,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_tractors_vineyard_id on public.tractors (vineyard_id);
create index if not exists idx_tractors_updated_at on public.tractors (updated_at);
create index if not exists idx_tractors_deleted_at on public.tractors (deleted_at);

create or replace trigger tractors_set_updated_at
before update on public.tractors
for each row execute function public.set_updated_at();

alter table public.tractors enable row level security;

drop policy if exists "tractors_select_members" on public.tractors;
create policy "tractors_select_members"
on public.tractors for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "tractors_insert_managers" on public.tractors;
create policy "tractors_insert_managers"
on public.tractors for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "tractors_update_managers" on public.tractors;
create policy "tractors_update_managers"
on public.tractors for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "tractors_no_client_hard_delete" on public.tractors;
create policy "tractors_no_client_hard_delete"
on public.tractors for delete
to authenticated
using (false);

create or replace function public.soft_delete_tractor(p_id uuid)
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
  select vineyard_id into v_vineyard_id from public.tractors where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Tractor not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete tractor';
  end if;
  update public.tractors
  set deleted_at = now(), updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_tractor(uuid) from public;
grant execute on function public.soft_delete_tractor(uuid) to authenticated;

-- =====================================================================
-- fuel_purchases
-- =====================================================================
create table if not exists public.fuel_purchases (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  volume_litres double precision not null default 0,
  total_cost double precision not null default 0,
  date timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_fuel_purchases_vineyard_id on public.fuel_purchases (vineyard_id);
create index if not exists idx_fuel_purchases_updated_at on public.fuel_purchases (updated_at);
create index if not exists idx_fuel_purchases_deleted_at on public.fuel_purchases (deleted_at);

create or replace trigger fuel_purchases_set_updated_at
before update on public.fuel_purchases
for each row execute function public.set_updated_at();

alter table public.fuel_purchases enable row level security;

drop policy if exists "fuel_purchases_select_members" on public.fuel_purchases;
create policy "fuel_purchases_select_members"
on public.fuel_purchases for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "fuel_purchases_insert_managers" on public.fuel_purchases;
create policy "fuel_purchases_insert_managers"
on public.fuel_purchases for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "fuel_purchases_update_managers" on public.fuel_purchases;
create policy "fuel_purchases_update_managers"
on public.fuel_purchases for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "fuel_purchases_no_client_hard_delete" on public.fuel_purchases;
create policy "fuel_purchases_no_client_hard_delete"
on public.fuel_purchases for delete
to authenticated
using (false);

create or replace function public.soft_delete_fuel_purchase(p_id uuid)
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
  select vineyard_id into v_vineyard_id from public.fuel_purchases where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Fuel purchase not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete fuel purchase';
  end if;
  update public.fuel_purchases
  set deleted_at = now(), updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_fuel_purchase(uuid) from public;
grant execute on function public.soft_delete_fuel_purchase(uuid) to authenticated;

-- =====================================================================
-- operator_categories
-- =====================================================================
create table if not exists public.operator_categories (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null default '',
  cost_per_hour double precision not null default 0,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_operator_categories_vineyard_id on public.operator_categories (vineyard_id);
create index if not exists idx_operator_categories_updated_at on public.operator_categories (updated_at);
create index if not exists idx_operator_categories_deleted_at on public.operator_categories (deleted_at);

create or replace trigger operator_categories_set_updated_at
before update on public.operator_categories
for each row execute function public.set_updated_at();

alter table public.operator_categories enable row level security;

drop policy if exists "operator_categories_select_members" on public.operator_categories;
create policy "operator_categories_select_members"
on public.operator_categories for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "operator_categories_insert_managers" on public.operator_categories;
create policy "operator_categories_insert_managers"
on public.operator_categories for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "operator_categories_update_managers" on public.operator_categories;
create policy "operator_categories_update_managers"
on public.operator_categories for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "operator_categories_no_client_hard_delete" on public.operator_categories;
create policy "operator_categories_no_client_hard_delete"
on public.operator_categories for delete
to authenticated
using (false);

create or replace function public.soft_delete_operator_category(p_id uuid)
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
  select vineyard_id into v_vineyard_id from public.operator_categories where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Operator category not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete operator category';
  end if;
  update public.operator_categories
  set deleted_at = now(), updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_operator_category(uuid) from public;
grant execute on function public.soft_delete_operator_category(uuid) to authenticated;

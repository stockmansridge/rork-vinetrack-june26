-- Phase 18: Shared "Other" equipment items catalog (additive).
--
-- Adds public.equipment_items for vineyard-scoped general-purpose equipment
-- assets (quad bike, ute, trailer, pump, generator, compressor, slasher,
-- mulcher, irrigation pump, workshop tool, etc.) that are not tractors and
-- not spray equipment. Used as a setup-backed selector source for the
-- Maintenance page Item / Machine picker, replacing the previous free-text
-- "Custom" affordance.
--
-- Design goals mirror operator_categories / work_task_types:
--   * Strictly additive — maintenance_logs continues to store item_name as
--     free text for backward compatibility. No equipment_item_id column on
--     maintenance_logs in this migration.
--   * Vineyard-scoped, soft delete via deleted_at, sync_version +
--     client_updated_at, RLS via vineyard membership helpers.
--   * Unique active name per vineyard, case-insensitive.

create table if not exists public.equipment_items (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null,
  category text not null default 'other',
  make text null,
  model text null,
  serial_number text null,
  notes text not null default '',
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create unique index if not exists uq_equipment_items_active_name_ci
  on public.equipment_items (vineyard_id, lower(name))
  where deleted_at is null;

create index if not exists idx_equipment_items_vineyard_id
  on public.equipment_items (vineyard_id);
create index if not exists idx_equipment_items_updated_at
  on public.equipment_items (updated_at);
create index if not exists idx_equipment_items_deleted_at
  on public.equipment_items (deleted_at);

create or replace trigger equipment_items_set_updated_at
before update on public.equipment_items
for each row execute function public.set_updated_at();

alter table public.equipment_items enable row level security;

drop policy if exists "equipment_items_select_members"
  on public.equipment_items;
create policy "equipment_items_select_members"
on public.equipment_items for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "equipment_items_insert_members"
  on public.equipment_items;
create policy "equipment_items_insert_members"
on public.equipment_items for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor']));

drop policy if exists "equipment_items_update_members"
  on public.equipment_items;
create policy "equipment_items_update_members"
on public.equipment_items for update
to authenticated
using (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor']))
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor']));

drop policy if exists "equipment_items_no_client_hard_delete"
  on public.equipment_items;
create policy "equipment_items_no_client_hard_delete"
on public.equipment_items for delete
to authenticated
using (false);

create or replace function public.soft_delete_equipment_item(p_id uuid)
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
    from public.equipment_items where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Equipment item not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id,
       array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete equipment item';
  end if;
  update public.equipment_items
     set deleted_at = now(),
         updated_by = auth.uid(),
         sync_version = sync_version + 1
   where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_equipment_item(uuid) from public;
grant execute on function public.soft_delete_equipment_item(uuid)
  to authenticated;

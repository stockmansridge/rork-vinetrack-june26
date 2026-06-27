-- Phase 4C: Trip costing — Saved Inputs library.
-- Reusable vineyard inputs (seed, fertiliser, compost, biological,
-- soil amendments, etc.) so seeding/spreading/fertilising trips can
-- snapshot a cost-per-unit at the time of recording and TripCostService
-- can calculate seed/input cost reliably.
--
-- Access rules:
--   SELECT: vineyard members
--   INSERT/UPDATE: owner/manager
--   DELETE: blocked at table — soft delete via RPC owner/manager only.

-- =====================================================================
-- saved_inputs
-- =====================================================================
create table if not exists public.saved_inputs (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null default '',
  input_type text not null default 'other',
  unit text not null default 'kg',
  cost_per_unit numeric null,
  supplier text null,
  notes text null,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_saved_inputs_vineyard_id on public.saved_inputs (vineyard_id);
create index if not exists idx_saved_inputs_updated_at on public.saved_inputs (updated_at);
create index if not exists idx_saved_inputs_deleted_at on public.saved_inputs (deleted_at);
create index if not exists idx_saved_inputs_input_type on public.saved_inputs (input_type);

-- Unique active name per vineyard, case-insensitive.
create unique index if not exists uq_saved_inputs_vineyard_name_active
  on public.saved_inputs (vineyard_id, lower(name))
  where deleted_at is null;

create or replace trigger saved_inputs_set_updated_at
before update on public.saved_inputs
for each row execute function public.set_updated_at();

alter table public.saved_inputs enable row level security;

drop policy if exists "saved_inputs_select_members" on public.saved_inputs;
create policy "saved_inputs_select_members"
on public.saved_inputs for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "saved_inputs_insert_managers" on public.saved_inputs;
create policy "saved_inputs_insert_managers"
on public.saved_inputs for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "saved_inputs_update_managers" on public.saved_inputs;
create policy "saved_inputs_update_managers"
on public.saved_inputs for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "saved_inputs_no_client_hard_delete" on public.saved_inputs;
create policy "saved_inputs_no_client_hard_delete"
on public.saved_inputs for delete
to authenticated
using (false);

create or replace function public.soft_delete_saved_input(p_id uuid)
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
  select vineyard_id into v_vineyard_id from public.saved_inputs where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Saved input not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete saved input';
  end if;
  update public.saved_inputs
  set deleted_at = now(), updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_saved_input(uuid) from public;
grant execute on function public.soft_delete_saved_input(uuid) to authenticated;

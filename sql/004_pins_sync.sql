-- Phase 10B: Pins operational sync.
-- Normalized pins table with RLS based on vineyard_members roles.

create table if not exists public.pins (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  paddock_id uuid null,
  trip_id uuid null,
  mode text null,
  category text null,
  priority text null,
  status text null,
  button_name text null,
  button_color text null,
  title text null,
  notes text null,
  latitude double precision null,
  longitude double precision null,
  heading double precision null,
  row_number integer null,
  side text null,
  growth_stage_code text null,
  is_completed boolean not null default false,
  completed_by text null,
  completed_at timestamptz null,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_pins_vineyard_id on public.pins (vineyard_id);
create index if not exists idx_pins_paddock_id on public.pins (paddock_id);
create index if not exists idx_pins_trip_id on public.pins (trip_id);
create index if not exists idx_pins_updated_at on public.pins (updated_at);
create index if not exists idx_pins_deleted_at on public.pins (deleted_at);
create index if not exists idx_pins_created_by on public.pins (created_by);

create or replace trigger pins_set_updated_at
before update on public.pins
for each row execute function public.set_updated_at();

alter table public.pins enable row level security;

drop policy if exists "pins_select_members" on public.pins;
create policy "pins_select_members"
on public.pins for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "pins_insert_members" on public.pins;
create policy "pins_insert_members"
on public.pins for insert
to authenticated
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
);

-- Update is allowed for any role; soft-delete (setting deleted_at) is enforced
-- via the `soft_delete_pin` RPC. Operators may still update non-deleted rows
-- but the RPC blocks them from setting deleted_at.
drop policy if exists "pins_update_members" on public.pins;
create policy "pins_update_members"
on public.pins for update
to authenticated
using (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
)
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
);

drop policy if exists "pins_no_client_hard_delete" on public.pins;
create policy "pins_no_client_hard_delete"
on public.pins for delete
to authenticated
using (false);

create or replace function public.soft_delete_pin(p_pin_id uuid)
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

  select vineyard_id into v_vineyard_id
  from public.pins
  where id = p_pin_id;

  if v_vineyard_id is null then
    raise exception 'Pin not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager', 'supervisor']) then
    raise exception 'Insufficient permissions to delete pin';
  end if;

  update public.pins
  set deleted_at = now(),
      updated_by = auth.uid()
  where id = p_pin_id;
end;
$function$;

revoke all on function public.soft_delete_pin(uuid) from public;
grant execute on function public.soft_delete_pin(uuid) to authenticated;

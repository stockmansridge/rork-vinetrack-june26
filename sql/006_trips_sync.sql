-- Phase 10D: Trips operational sync.
-- Normalized trips table with RLS based on vineyard_members roles.

create table if not exists public.trips (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,

  paddock_id uuid null references public.paddocks(id) on delete set null,
  paddock_ids jsonb null,
  paddock_name text null,

  tracking_pattern text null,
  start_time timestamptz null,
  end_time timestamptz null,
  is_active boolean not null default false,
  is_paused boolean not null default false,

  total_distance double precision null,
  current_path_distance double precision null,
  current_row_number double precision null,
  next_row_number double precision null,
  sequence_index integer null,
  row_sequence jsonb null,

  path_points jsonb null,
  completed_paths jsonb null,
  skipped_paths jsonb null,
  pin_ids jsonb null,
  tank_sessions jsonb null,
  active_tank_number integer null,
  total_tanks integer null,
  pause_timestamps jsonb null,
  resume_timestamps jsonb null,
  is_filling_tank boolean null,
  filling_tank_number integer null,

  person_name text null,

  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_trips_vineyard_id on public.trips (vineyard_id);
create index if not exists idx_trips_paddock_id on public.trips (paddock_id);
create index if not exists idx_trips_updated_at on public.trips (updated_at);
create index if not exists idx_trips_deleted_at on public.trips (deleted_at);
create index if not exists idx_trips_start_time on public.trips (start_time);
create index if not exists idx_trips_created_by on public.trips (created_by);

create or replace trigger trips_set_updated_at
before update on public.trips
for each row execute function public.set_updated_at();

alter table public.trips enable row level security;

drop policy if exists "trips_select_members" on public.trips;
create policy "trips_select_members"
on public.trips for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "trips_insert_members" on public.trips;
create policy "trips_insert_members"
on public.trips for insert
to authenticated
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
);

-- Update is allowed for any operational role; soft-delete (setting deleted_at)
-- is enforced via the `soft_delete_trip` RPC which blocks operators.
drop policy if exists "trips_update_members" on public.trips;
create policy "trips_update_members"
on public.trips for update
to authenticated
using (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
)
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
);

drop policy if exists "trips_no_client_hard_delete" on public.trips;
create policy "trips_no_client_hard_delete"
on public.trips for delete
to authenticated
using (false);

create or replace function public.soft_delete_trip(p_trip_id uuid)
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
  from public.trips
  where id = p_trip_id;

  if v_vineyard_id is null then
    raise exception 'Trip not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager', 'supervisor']) then
    raise exception 'Insufficient permissions to delete trip';
  end if;

  update public.trips
  set deleted_at = now(),
      updated_by = auth.uid()
  where id = p_trip_id;
end;
$function$;

revoke all on function public.soft_delete_trip(uuid) from public;
grant execute on function public.soft_delete_trip(uuid) to authenticated;

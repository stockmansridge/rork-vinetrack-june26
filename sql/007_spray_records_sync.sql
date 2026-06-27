-- Phase 10E: Spray records operational sync.
-- Normalized spray_records table with RLS based on vineyard_members roles.

create table if not exists public.spray_records (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,

  trip_id uuid null,
  date timestamptz null,
  start_time timestamptz null,
  end_time timestamptz null,

  temperature double precision null,
  wind_speed double precision null,
  wind_direction text null,
  humidity double precision null,

  spray_reference text null,
  notes text null,
  number_of_fans_jets text null,
  average_speed double precision null,

  equipment_type text null,
  tractor text null,
  tractor_gear text null,

  is_template boolean not null default false,
  operation_type text null,

  tanks jsonb null,

  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_spray_records_vineyard_id on public.spray_records (vineyard_id);
create index if not exists idx_spray_records_trip_id on public.spray_records (trip_id);
create index if not exists idx_spray_records_updated_at on public.spray_records (updated_at);
create index if not exists idx_spray_records_deleted_at on public.spray_records (deleted_at);
create index if not exists idx_spray_records_date on public.spray_records (date);
create index if not exists idx_spray_records_created_by on public.spray_records (created_by);

create or replace trigger spray_records_set_updated_at
before update on public.spray_records
for each row execute function public.set_updated_at();

alter table public.spray_records enable row level security;

drop policy if exists "spray_records_select_members" on public.spray_records;
create policy "spray_records_select_members"
on public.spray_records for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "spray_records_insert_members" on public.spray_records;
create policy "spray_records_insert_members"
on public.spray_records for insert
to authenticated
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
);

-- Update is allowed for any operational role; soft-delete (setting deleted_at)
-- is enforced via the `soft_delete_spray_record` RPC which blocks operators.
drop policy if exists "spray_records_update_members" on public.spray_records;
create policy "spray_records_update_members"
on public.spray_records for update
to authenticated
using (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
)
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
);

drop policy if exists "spray_records_no_client_hard_delete" on public.spray_records;
create policy "spray_records_no_client_hard_delete"
on public.spray_records for delete
to authenticated
using (false);

create or replace function public.soft_delete_spray_record(p_spray_record_id uuid)
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
  from public.spray_records
  where id = p_spray_record_id;

  if v_vineyard_id is null then
    raise exception 'Spray record not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager', 'supervisor']) then
    raise exception 'Insufficient permissions to delete spray record';
  end if;

  update public.spray_records
  set deleted_at = now(),
      updated_by = auth.uid()
  where id = p_spray_record_id;
end;
$function$;

revoke all on function public.soft_delete_spray_record(uuid) from public;
grant execute on function public.soft_delete_spray_record(uuid) to authenticated;

-- Phase 10C: Paddocks operational sync.
-- Normalized paddocks table with RLS based on vineyard_members roles.

create table if not exists public.paddocks (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null,
  row_direction double precision null,
  row_width double precision null,
  row_offset double precision null,
  vine_spacing double precision null,
  vine_count_override integer null,
  row_length_override double precision null,
  flow_per_emitter double precision null,
  emitter_spacing double precision null,
  budburst_date timestamptz null,
  flowering_date timestamptz null,
  veraison_date timestamptz null,
  harvest_date timestamptz null,
  planting_year integer null,
  calculation_mode_override text null,
  reset_mode_override text null,
  polygon_points jsonb null,
  rows jsonb null,
  variety_allocations jsonb null,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_paddocks_vineyard_id on public.paddocks (vineyard_id);
create index if not exists idx_paddocks_name on public.paddocks (name);
create index if not exists idx_paddocks_updated_at on public.paddocks (updated_at);
create index if not exists idx_paddocks_deleted_at on public.paddocks (deleted_at);

create or replace trigger paddocks_set_updated_at
before update on public.paddocks
for each row execute function public.set_updated_at();

alter table public.paddocks enable row level security;

drop policy if exists "paddocks_select_members" on public.paddocks;
create policy "paddocks_select_members"
on public.paddocks for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "paddocks_insert_members" on public.paddocks;
create policy "paddocks_insert_members"
on public.paddocks for insert
to authenticated
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
);

-- Update is allowed for any operational role; soft-delete (setting deleted_at)
-- is enforced via the `soft_delete_paddock` RPC which blocks operators.
drop policy if exists "paddocks_update_members" on public.paddocks;
create policy "paddocks_update_members"
on public.paddocks for update
to authenticated
using (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
)
with check (
  public.has_vineyard_role(vineyard_id, array['owner', 'manager', 'supervisor', 'operator'])
);

drop policy if exists "paddocks_no_client_hard_delete" on public.paddocks;
create policy "paddocks_no_client_hard_delete"
on public.paddocks for delete
to authenticated
using (false);

create or replace function public.soft_delete_paddock(p_paddock_id uuid)
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
  from public.paddocks
  where id = p_paddock_id;

  if v_vineyard_id is null then
    raise exception 'Paddock not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager', 'supervisor']) then
    raise exception 'Insufficient permissions to delete paddock';
  end if;

  update public.paddocks
  set deleted_at = now(),
      updated_by = auth.uid()
  where id = p_paddock_id;
end;
$function$;

revoke all on function public.soft_delete_paddock(uuid) from public;
grant execute on function public.soft_delete_paddock(uuid) to authenticated;

-- 037_vineyard_trip_functions.sql
-- Phase: Vineyard-scoped custom Trip Functions.
--
-- Storage model (approved):
--   * Built-in trip functions (Slashing, Mulching, Harrowing, Mowing, Spraying,
--     Fertilising, Undervine weeding, Inter-row cultivation, Pruning,
--     Shoot thinning, Canopy work, Irrigation check, Repairs, Seeding, Other)
--     are NOT stored in this table. They live in the iOS TripFunction enum.
--   * Custom trip functions ARE stored in this table, scoped per vineyard.
--   * On a trip row, custom functions are stored as:
--         trips.trip_function = 'custom:<slug>'
--         trips.trip_title    = '<display label>'
--   * Built-in trip functions on a trip row remain stored as their raw enum
--     value (e.g. 'harrowing', 'seeding') with trip_title optional.
--   * The slug is the stable identifier and MUST NOT change when the label is
--     renamed. The label is the user-visible display string and may change.
--
-- Safe / additive:
--   * No changes to public.trips
--   * No changes to existing trip RLS or trip RPCs
--   * No backfill required
--   * Older clients that don't know about this table will continue to work
--     because they only ever see custom values via trips.trip_function /
--     trips.trip_title which already exist.

-- =====================================================================
-- vineyard_trip_functions
-- =====================================================================
create table if not exists public.vineyard_trip_functions (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,

  label text not null,
  slug text not null,

  is_active boolean not null default true,
  sort_order integer not null default 0,

  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,

  constraint vineyard_trip_functions_label_not_blank
    check (length(btrim(label)) > 0),
  constraint vineyard_trip_functions_slug_format
    check (slug ~ '^[a-z0-9][a-z0-9_-]*$' and length(slug) <= 64)
);

comment on table public.vineyard_trip_functions is
  'Vineyard-scoped custom Trip Functions. Built-in trip functions are NOT '
  'stored here; they live in the iOS TripFunction enum. On a trip, a custom '
  'function is stored as trips.trip_function = ''custom:<slug>'' and the '
  'display label is stored in trips.trip_title.';
comment on column public.vineyard_trip_functions.slug is
  'Stable identifier used in trips.trip_function as ''custom:<slug>''. Must '
  'not change when the label is renamed. Lowercase a-z, 0-9, _ or - only.';
comment on column public.vineyard_trip_functions.label is
  'Display label shown in the trip function dropdown. Also written into '
  'trips.trip_title when this function is selected for a trip.';
comment on column public.vineyard_trip_functions.is_active is
  'false = hidden from the trip function dropdown but kept for historical '
  'trips that already reference it.';
comment on column public.vineyard_trip_functions.deleted_at is
  'Soft-delete marker. Hard delete is blocked by RLS; use the archive RPC '
  'or set is_active=false / deleted_at via update.';

-- =====================================================================
-- Indexes
-- =====================================================================
-- Lookup: list active functions for a vineyard, ordered for display.
create index if not exists idx_vineyard_trip_functions_active_sorted
  on public.vineyard_trip_functions (vineyard_id, is_active, sort_order)
  where deleted_at is null;

create index if not exists idx_vineyard_trip_functions_vineyard_id
  on public.vineyard_trip_functions (vineyard_id);

create index if not exists idx_vineyard_trip_functions_updated_at
  on public.vineyard_trip_functions (updated_at);

create index if not exists idx_vineyard_trip_functions_deleted_at
  on public.vineyard_trip_functions (deleted_at);

-- Unique active slug per vineyard (ignoring soft-deleted rows). Allows the
-- same slug to be reused after archive without a hard delete.
create unique index if not exists uq_vineyard_trip_functions_vineyard_slug_active
  on public.vineyard_trip_functions (vineyard_id, slug)
  where deleted_at is null;

-- =====================================================================
-- updated_at trigger
-- =====================================================================
create or replace trigger vineyard_trip_functions_set_updated_at
before update on public.vineyard_trip_functions
for each row execute function public.set_updated_at();

-- =====================================================================
-- RLS
-- Access:
--   * SELECT: any vineyard member (Owner, Manager, Supervisor, Operator)
--   * INSERT/UPDATE: Owner / Manager only (rename, archive, restore, reorder)
--   * DELETE: blocked at the RLS layer. Use archive (deleted_at + is_active=false).
-- =====================================================================
alter table public.vineyard_trip_functions enable row level security;

drop policy if exists "vineyard_trip_functions_select_members"
  on public.vineyard_trip_functions;
create policy "vineyard_trip_functions_select_members"
on public.vineyard_trip_functions for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "vineyard_trip_functions_insert_managers"
  on public.vineyard_trip_functions;
create policy "vineyard_trip_functions_insert_managers"
on public.vineyard_trip_functions for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "vineyard_trip_functions_update_managers"
  on public.vineyard_trip_functions;
create policy "vineyard_trip_functions_update_managers"
on public.vineyard_trip_functions for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "vineyard_trip_functions_no_client_hard_delete"
  on public.vineyard_trip_functions;
create policy "vineyard_trip_functions_no_client_hard_delete"
on public.vineyard_trip_functions for delete
to authenticated
using (false);

-- =====================================================================
-- RPC: archive_vineyard_trip_function
-- Soft-delete: sets is_active=false and deleted_at=now(). Owner/Manager only.
-- Existing trips already referencing this function via
-- trips.trip_function = 'custom:<slug>' are NOT modified.
-- =====================================================================
create or replace function public.archive_vineyard_trip_function(p_id uuid)
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
  from public.vineyard_trip_functions
  where id = p_id;

  if v_vineyard_id is null then
    raise exception 'Trip function not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to archive trip function';
  end if;

  update public.vineyard_trip_functions
  set is_active = false,
      deleted_at = coalesce(deleted_at, now()),
      updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.archive_vineyard_trip_function(uuid) from public;
grant execute on function public.archive_vineyard_trip_function(uuid) to authenticated;

-- =====================================================================
-- RPC: restore_vineyard_trip_function
-- Reverses archive. Owner/Manager only. If another active row already exists
-- with the same vineyard_id + slug, the restore fails (uq partial index).
-- =====================================================================
create or replace function public.restore_vineyard_trip_function(p_id uuid)
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
  from public.vineyard_trip_functions
  where id = p_id;

  if v_vineyard_id is null then
    raise exception 'Trip function not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to restore trip function';
  end if;

  update public.vineyard_trip_functions
  set is_active = true,
      deleted_at = null,
      updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.restore_vineyard_trip_function(uuid) from public;
grant execute on function public.restore_vineyard_trip_function(uuid) to authenticated;

-- =====================================================================
-- Smoke-test queries (run manually after applying):
--
--   -- 1) Table exists and is empty
--   select count(*) from public.vineyard_trip_functions;
--
--   -- 2) RLS read for a member (run as an authenticated user)
--   select id, label, slug, is_active, sort_order
--   from public.vineyard_trip_functions
--   where vineyard_id = '<your-vineyard-id>'
--     and deleted_at is null
--   order by sort_order, label;
--
--   -- 3) Insert as owner/manager
--   insert into public.vineyard_trip_functions
--     (vineyard_id, label, slug, sort_order, created_by, updated_by)
--   values
--     ('<your-vineyard-id>', 'Rolling', 'rolling', 0, auth.uid(), auth.uid());
--
--   -- 4) Duplicate active slug should fail
--   insert into public.vineyard_trip_functions
--     (vineyard_id, label, slug, created_by, updated_by)
--   values
--     ('<your-vineyard-id>', 'Rolling 2', 'rolling', auth.uid(), auth.uid());
--   -- expect: duplicate key value violates unique constraint
--   --         "uq_vineyard_trip_functions_vineyard_slug_active"
--
--   -- 5) Archive then restore
--   select public.archive_vineyard_trip_function('<row-id>');
--   select public.restore_vineyard_trip_function('<row-id>');
--
--   -- 6) Hard delete should fail
--   delete from public.vineyard_trip_functions where id = '<row-id>';
--   -- expect: 0 rows / RLS blocks delete
-- =====================================================================

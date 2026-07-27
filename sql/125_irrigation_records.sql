-- =============================================================================
-- 125: Irrigation Records — Phase 1 shared schema, calculations and RPCs.
--
-- Source of truth for iOS, Android and the future Lovable Portal. Clients must
-- NEVER implement separate authoritative calculation logic — offline previews
-- mirror `_irrigation_allocate` / `irrigation_total_volume` byte-for-byte and
-- the server recomputes on save.
--
-- FEATURE GATE (Phase 1): the entire feature is restricted to VineTrack System
-- Administrators via ONE central capability function:
--
--     public.has_irrigation_records_access(p_vineyard_id uuid)
--
-- Initial behaviour: is_system_admin() AND is_vineyard_member(). Releasing the
-- feature to normal vineyard roles later means changing ONLY this function
-- body (e.g. to has_vineyard_role(...)); no table, policy or RPC rebuild.
--
-- REUSED EXISTING FIELDS (audited — no duplicates created):
--   * Blocks               -> public.paddocks (deleted_at is null = active)
--   * Block area           -> derived: _paddock_polygon_area_hectares(polygon_points) × 10000 m²
--   * Vine count           -> paddocks.vine_count_override (no validated server
--                             derivation exists; NEVER invented from area)
--   * Vine spacing         -> paddocks.vine_spacing
--   * Row spacing          -> paddocks.row_width
--   * Dripper output (L/h) -> paddocks.flow_per_emitter
--   * Dripper spacing (m)  -> paddocks.emitter_spacing
--   * Variety              -> paddocks.variety_allocations (dominant by percent)
--   * Vintage              -> resolve_vineyard_vintage_year (SQL 108/119), frozen at record time
--   * Units                -> canonical litres / L/h / m² / mm / minutes; display
--                             conversion is a client concern (SQL 099 region settings)
--
-- NEW canonical field added to the shared block model (did not exist):
--   * paddocks.irrigation_efficiency_percent
--
-- CANONICAL STORAGE UNITS: litres, litres/hour, m², mm, whole minutes.
-- 1 litre over 1 m² = 1 mm irrigation depth.
--
-- Missing data rule: calculations that cannot be completed return NULL and a
-- warning — zero is NEVER substituted.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Central feature capability
-- ---------------------------------------------------------------------------
create or replace function public.has_irrigation_records_access(p_vineyard_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    -- Phase 1 gate: System Administrators only (who are members of the vineyard).
    -- FUTURE RELEASE: replace this body with the role matrix, e.g.
    --   select public.has_vineyard_role(p_vineyard_id,
    --          array['owner','manager','supervisor','operator'])
    -- No other object needs to change.
    select public.is_system_admin() and public.is_vineyard_member(p_vineyard_id);
$$;

revoke all on function public.has_irrigation_records_access(uuid) from public, anon;
grant execute on function public.has_irrigation_records_access(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 1. Shared block model: irrigation efficiency (canonical, block-level)
-- ---------------------------------------------------------------------------
alter table public.paddocks
  add column if not exists irrigation_efficiency_percent double precision null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'paddocks_irrigation_efficiency_range'
  ) then
    alter table public.paddocks
      add constraint paddocks_irrigation_efficiency_range
      check (irrigation_efficiency_percent is null
             or (irrigation_efficiency_percent > 0 and irrigation_efficiency_percent <= 100));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------

create table if not exists public.irrigation_systems (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null,
  water_source text null,
  controller_provider text null,
  controller_name text null,
  external_controller_id text null,
  default_unit_system text null,
  is_active boolean not null default true,
  notes text null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),

  constraint irrigation_systems_name_not_blank check (length(trim(name)) > 0)
);

-- Case-insensitive unique name among ACTIVE systems of a vineyard.
create unique index if not exists irrigation_systems_active_name_uq
  on public.irrigation_systems (vineyard_id, lower(trim(name)))
  where is_active;

create index if not exists irrigation_systems_vineyard_idx
  on public.irrigation_systems (vineyard_id);

create table if not exists public.irrigation_valves (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  irrigation_system_id uuid not null references public.irrigation_systems(id) on delete cascade,
  name text not null,
  valve_number text null,
  external_station_id text null,
  configured_flow_litres_per_hour numeric null,
  measured_flow_litres_per_hour numeric null,
  is_active boolean not null default true,
  notes text null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),

  constraint irrigation_valves_name_not_blank check (length(trim(name)) > 0),
  constraint irrigation_valves_configured_flow_positive
    check (configured_flow_litres_per_hour is null or configured_flow_litres_per_hour > 0),
  constraint irrigation_valves_measured_flow_positive
    check (measured_flow_litres_per_hour is null or measured_flow_litres_per_hour > 0)
);

create unique index if not exists irrigation_valves_active_name_uq
  on public.irrigation_valves (irrigation_system_id, lower(trim(name)))
  where is_active;

create index if not exists irrigation_valves_vineyard_idx
  on public.irrigation_valves (vineyard_id);
create index if not exists irrigation_valves_system_idx
  on public.irrigation_valves (irrigation_system_id);

create table if not exists public.irrigation_valve_blocks (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  valve_id uuid not null references public.irrigation_valves(id) on delete cascade,
  block_id uuid not null references public.paddocks(id) on delete cascade,
  allocation_method text not null default 'manual_percentage',
  allocation_percentage numeric null,
  serviced_area_m2 numeric null,
  serviced_vine_count integer null,
  serviced_emitter_count integer null,
  row_start integer null,
  row_end integer null,
  configured_flow_litres_per_hour numeric null,
  effective_from date null,
  effective_to date null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),

  constraint irrigation_valve_blocks_method_check
    check (allocation_method in ('manual_percentage','emitter_count','vine_count','irrigated_area')),
  constraint irrigation_valve_blocks_percentage_range
    check (allocation_percentage is null or (allocation_percentage > 0 and allocation_percentage <= 100)),
  constraint irrigation_valve_blocks_area_positive
    check (serviced_area_m2 is null or serviced_area_m2 > 0),
  constraint irrigation_valve_blocks_vines_positive
    check (serviced_vine_count is null or serviced_vine_count > 0),
  constraint irrigation_valve_blocks_emitters_positive
    check (serviced_emitter_count is null or serviced_emitter_count > 0)
);

-- Duplicate ACTIVE valve+block combinations are not allowed.
create unique index if not exists irrigation_valve_blocks_active_uq
  on public.irrigation_valve_blocks (valve_id, block_id)
  where is_active;

create index if not exists irrigation_valve_blocks_vineyard_idx
  on public.irrigation_valve_blocks (vineyard_id);
create index if not exists irrigation_valve_blocks_valve_idx
  on public.irrigation_valve_blocks (valve_id);
create index if not exists irrigation_valve_blocks_block_idx
  on public.irrigation_valve_blocks (block_id);

create table if not exists public.irrigation_sessions (
  id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  irrigation_system_id uuid not null references public.irrigation_systems(id),
  valve_id uuid not null references public.irrigation_valves(id),
  irrigation_run_id uuid null,            -- reserved: multi-valve runs (future)
  session_date date not null,
  vintage_year integer not null,          -- frozen at record time (SQL 119 rule)
  started_at timestamptz null,
  finished_at timestamptz null,
  duration_minutes integer not null,
  calculation_method text not null,
  flow_litres_per_hour numeric null,
  meter_start_litres numeric null,
  meter_finish_litres numeric null,
  total_volume_litres numeric not null,
  effective_volume_litres numeric null,
  original_value numeric null,
  original_unit text null,
  irrigation_efficiency_percent numeric null,
  status text not null default 'completed',
  source_type text not null,
  external_source_id text null,           -- reserved: controller/import (future)
  import_batch_id uuid null,              -- reserved: CSV import (future)
  notes text null,
  configuration_snapshot jsonb not null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  deleted_at timestamptz null,
  reversed_by_session_id uuid null,

  constraint irrigation_sessions_duration_positive check (duration_minutes > 0),
  constraint irrigation_sessions_duration_sane check (duration_minutes <= 10080),
  constraint irrigation_sessions_volume_positive check (total_volume_litres > 0),
  constraint irrigation_sessions_method_check
    check (calculation_method in ('configured_flow','session_flow','total_volume','meter_readings')),
  constraint irrigation_sessions_status_check
    check (status in ('completed','corrected','reversed',
                      'planned','running','cancelled','imported','estimated')),
  constraint irrigation_sessions_source_check
    check (source_type in ('manual_ios','manual_android','manual_portal',
                           'csv_import','controller_api','system_generated'))
);

create index if not exists irrigation_sessions_vineyard_date_idx
  on public.irrigation_sessions (vineyard_id, session_date desc);
create index if not exists irrigation_sessions_vintage_idx
  on public.irrigation_sessions (vineyard_id, vintage_year);
create index if not exists irrigation_sessions_valve_idx
  on public.irrigation_sessions (valve_id);
create index if not exists irrigation_sessions_deleted_idx
  on public.irrigation_sessions (deleted_at);

create table if not exists public.irrigation_session_blocks (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.irrigation_sessions(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  valve_id uuid not null references public.irrigation_valves(id),
  block_id uuid not null references public.paddocks(id),
  variety_id uuid null,
  variety_name text null,
  allocation_method text not null,
  allocation_percentage numeric not null,
  allocated_volume_litres numeric not null,
  effective_volume_litres numeric null,
  serviced_area_m2 numeric null,
  serviced_vine_count integer null,
  water_litres_per_vine numeric null,
  water_litres_per_hectare numeric null,
  irrigation_depth_mm numeric null,
  effective_irrigation_depth_mm numeric null,
  created_at timestamptz not null default now()
);

create index if not exists irrigation_session_blocks_session_idx
  on public.irrigation_session_blocks (session_id);
create index if not exists irrigation_session_blocks_block_idx
  on public.irrigation_session_blocks (vineyard_id, block_id);
create index if not exists irrigation_session_blocks_valve_idx
  on public.irrigation_session_blocks (vineyard_id, valve_id);

-- Per-feature audit (pruning_entry_audit pattern: jsonb old/new, RPC-only writes)
create table if not exists public.irrigation_audit (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  action text not null,
  entity_type text not null,
  entity_id uuid not null,
  old_values jsonb null,
  new_values jsonb null,
  created_at timestamptz not null default now()
);

create index if not exists irrigation_audit_vineyard_idx
  on public.irrigation_audit (vineyard_id, created_at desc);
create index if not exists irrigation_audit_entity_idx
  on public.irrigation_audit (entity_type, entity_id);

-- updated_at triggers (set_updated_at from SQL 001)
create or replace trigger irrigation_systems_set_updated_at
before update on public.irrigation_systems
for each row execute function public.set_updated_at();

create or replace trigger irrigation_valves_set_updated_at
before update on public.irrigation_valves
for each row execute function public.set_updated_at();

create or replace trigger irrigation_valve_blocks_set_updated_at
before update on public.irrigation_valve_blocks
for each row execute function public.set_updated_at();

create or replace trigger irrigation_sessions_set_updated_at
before update on public.irrigation_sessions
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. RLS — SELECT via the central capability; ALL writes via definer RPCs only.
--    (Hiding navigation is not the security boundary — these policies are.)
-- ---------------------------------------------------------------------------
alter table public.irrigation_systems enable row level security;
alter table public.irrigation_valves enable row level security;
alter table public.irrigation_valve_blocks enable row level security;
alter table public.irrigation_sessions enable row level security;
alter table public.irrigation_session_blocks enable row level security;
alter table public.irrigation_audit enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['irrigation_systems','irrigation_valves','irrigation_valve_blocks',
                           'irrigation_sessions','irrigation_session_blocks','irrigation_audit']
  loop
    execute format('drop policy if exists "%s_select_feature" on public.%I', t, t);
    execute format(
      'create policy "%s_select_feature" on public.%I for select to authenticated
       using (public.has_irrigation_records_access(vineyard_id))', t, t);
    -- No insert/update/delete policies: client writes are denied by default;
    -- every mutation goes through the security-definer RPCs below.
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Pure calculation core (immutable — unit-tested by the asserts in §9;
--    mirrored by IrrigationLocalCalculator.swift / IrrigationLocalCalculator.kt)
-- ---------------------------------------------------------------------------

-- Total session volume in litres from the chosen method.
create or replace function public.irrigation_total_volume(
  p_method text,
  p_flow_litres_per_hour numeric,
  p_duration_minutes integer,
  p_meter_start_litres numeric,
  p_meter_finish_litres numeric,
  p_total_volume_litres numeric
) returns numeric
language plpgsql
immutable
as $$
begin
  if p_duration_minutes is null or p_duration_minutes <= 0 then
    raise exception 'invalid_duration: duration must be a positive whole number of minutes';
  end if;

  if p_method in ('configured_flow', 'session_flow') then
    if p_flow_litres_per_hour is null or p_flow_litres_per_hour <= 0 then
      raise exception 'invalid_flow: flow rate must be greater than zero';
    end if;
    return round(p_flow_litres_per_hour * p_duration_minutes / 60.0, 3);
  elsif p_method = 'meter_readings' then
    if p_meter_start_litres is null or p_meter_finish_litres is null then
      raise exception 'invalid_meter: both meter readings are required';
    end if;
    if p_meter_finish_litres - p_meter_start_litres <= 0 then
      raise exception 'invalid_meter: finishing meter reading must be greater than the starting reading';
    end if;
    return round(p_meter_finish_litres - p_meter_start_litres, 3);
  elsif p_method = 'total_volume' then
    if p_total_volume_litres is null or p_total_volume_litres <= 0 then
      raise exception 'invalid_volume: total volume must be greater than zero';
    end if;
    return round(p_total_volume_litres, 3);
  end if;

  raise exception 'invalid_method: unknown calculation method %', p_method;
end;
$$;

-- Allocate a total volume across resolved block allocations and compute the
-- per-block metrics. Pure: takes the resolved configuration as jsonb.
-- Input elements: block_id, block_name, variety_id, variety_name,
--   allocation_method, allocation_percentage, serviced_area_m2,
--   serviced_vine_count, serviced_emitter_count, efficiency_percent.
-- Missing area / vine count / efficiency -> NULL metric + warning (never zero).
create or replace function public._irrigation_allocate(
  p_total_volume_litres numeric,
  p_allocations jsonb
) returns jsonb
language plpgsql
immutable
as $$
declare
  v_alloc jsonb;
  v_blocks jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_pct numeric;
  v_pct_sum numeric := 0;
  v_area numeric;
  v_vines integer;
  v_eff numeric;
  v_allocated numeric;
  v_effective numeric;
  v_effective_sum numeric := 0;
  v_all_have_eff boolean := true;
  v_eff_weighted numeric := 0;
  v_name text;
begin
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) = 0 then
    raise exception 'no_block_allocations: the valve has no active block connections';
  end if;

  for v_alloc in select * from jsonb_array_elements(p_allocations) loop
    v_pct := nullif(v_alloc->>'allocation_percentage', '')::numeric;
    if v_pct is null or v_pct <= 0 then
      raise exception 'invalid_allocation: block allocation percentage is missing or not positive';
    end if;
    v_pct_sum := v_pct_sum + v_pct;
  end loop;

  if abs(v_pct_sum - 100) > 0.05 then
    raise exception 'allocations_not_100: active block allocations total % percent instead of 100 percent', round(v_pct_sum, 2);
  end if;

  for v_alloc in select * from jsonb_array_elements(p_allocations) loop
    v_pct   := (v_alloc->>'allocation_percentage')::numeric;
    v_area  := nullif(v_alloc->>'serviced_area_m2', '')::numeric;
    v_vines := nullif(v_alloc->>'serviced_vine_count', '')::integer;
    v_eff   := nullif(v_alloc->>'efficiency_percent', '')::numeric;
    v_name  := coalesce(v_alloc->>'block_name', 'Block');

    v_allocated := round(p_total_volume_litres * v_pct / 100.0, 3);

    if v_eff is not null and v_eff > 0 then
      v_effective := round(v_allocated * v_eff / 100.0, 3);
      v_effective_sum := v_effective_sum + v_effective;
      v_eff_weighted := v_eff_weighted + (v_pct * v_eff);
    else
      v_effective := null;
      v_all_have_eff := false;
      v_warnings := v_warnings || to_jsonb(format(
        'Effective water could not be calculated because %s does not have an irrigation efficiency.', v_name));
    end if;

    if v_vines is null or v_vines <= 0 then
      v_warnings := v_warnings || to_jsonb(format(
        'Water per vine could not be calculated because %s does not have a serviced vine count.', v_name));
    end if;
    if v_area is null or v_area <= 0 then
      v_warnings := v_warnings || to_jsonb(format(
        'Water per hectare and irrigation depth could not be calculated because %s does not have a serviced area.', v_name));
    end if;

    v_blocks := v_blocks || jsonb_build_object(
      'block_id', v_alloc->>'block_id',
      'block_name', v_name,
      'variety_id', v_alloc->>'variety_id',
      'variety_name', v_alloc->>'variety_name',
      'allocation_method', coalesce(v_alloc->>'allocation_method', 'manual_percentage'),
      'allocation_percentage', v_pct,
      'allocated_volume_litres', v_allocated,
      'effective_volume_litres', v_effective,
      'serviced_area_m2', v_area,
      'serviced_vine_count', v_vines,
      'water_litres_per_vine',
        case when v_vines is not null and v_vines > 0
             then round(v_allocated / v_vines, 3) else null end,
      'water_litres_per_hectare',
        case when v_area is not null and v_area > 0
             then round(v_allocated / (v_area / 10000.0), 2) else null end,
      'irrigation_depth_mm',
        case when v_area is not null and v_area > 0
             then round(v_allocated / v_area, 3) else null end,
      'effective_irrigation_depth_mm',
        case when v_area is not null and v_area > 0 and v_effective is not null
             then round(v_effective / v_area, 3) else null end
    );
  end loop;

  return jsonb_build_object(
    'total_volume_litres', round(p_total_volume_litres, 3),
    'effective_volume_litres', case when v_all_have_eff then round(v_effective_sum, 3) else null end,
    'irrigation_efficiency_percent', case when v_all_have_eff then round(v_eff_weighted / 100.0, 2) else null end,
    'blocks', v_blocks,
    'warnings', v_warnings
  );
end;
$$;

revoke all on function public.irrigation_total_volume(text, numeric, integer, numeric, numeric, numeric) from public, anon;
grant execute on function public.irrigation_total_volume(text, numeric, integer, numeric, numeric, numeric) to authenticated;
revoke all on function public._irrigation_allocate(numeric, jsonb) from public, anon;
grant execute on function public._irrigation_allocate(numeric, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Configuration resolution
-- ---------------------------------------------------------------------------

-- Resolve the ACTIVE block allocations of a valve into the pure-calculation
-- input shape. Resolution order (shared contract):
--   serviced area : valve-block override -> derived paddock polygon area -> null
--   vine count    : valve-block override -> paddocks.vine_count_override -> null
--   emitters      : valve-block override -> null (never invented)
--   efficiency    : paddocks.irrigation_efficiency_percent -> null
--   variety       : dominant paddocks.variety_allocations entry by percent
-- Percentages: manual_percentage uses the stored value; emitter_count /
-- vine_count / irrigated_area derive the percentage from the serviced values
-- across ALL active connections of the valve.
create or replace function public._irrigation_valve_allocations(p_valve_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r record;
  v_rows jsonb := '[]'::jsonb;
  v_row jsonb;
  v_out jsonb := '[]'::jsonb;
  v_total_emitters numeric := 0;
  v_total_vines numeric := 0;
  v_total_area numeric := 0;
  v_pct numeric;
  v_method text;
begin
  for r in
    select vb.id as valve_block_id,
           vb.block_id,
           vb.allocation_method,
           vb.allocation_percentage,
           coalesce(vb.serviced_area_m2,
                    nullif(public._paddock_polygon_area_hectares(p.polygon_points) * 10000.0, 0)) as area_m2,
           coalesce(vb.serviced_vine_count, p.vine_count_override) as vine_count,
           vb.serviced_emitter_count,
           vb.configured_flow_litres_per_hour as block_flow,
           p.name as block_name,
           p.irrigation_efficiency_percent as efficiency_percent,
           p.flow_per_emitter as dripper_output_lph,
           p.emitter_spacing as dripper_spacing_m,
           p.vine_spacing,
           p.row_width as row_spacing,
           (
             select alloc->>'varietyId'
             from jsonb_array_elements(
               case when jsonb_typeof(p.variety_allocations) = 'array'
                    then p.variety_allocations else '[]'::jsonb end) alloc
             order by coalesce((alloc->>'percent')::numeric, 0) desc
             limit 1
           ) as variety_id_text,
           (
             select coalesce(alloc->>'name', alloc->>'varietyName')
             from jsonb_array_elements(
               case when jsonb_typeof(p.variety_allocations) = 'array'
                    then p.variety_allocations else '[]'::jsonb end) alloc
             order by coalesce((alloc->>'percent')::numeric, 0) desc
             limit 1
           ) as variety_name
    from public.irrigation_valve_blocks vb
    join public.paddocks p on p.id = vb.block_id and p.deleted_at is null
    where vb.valve_id = p_valve_id
      and vb.is_active
    order by p.name
  loop
    v_total_emitters := v_total_emitters + coalesce(r.serviced_emitter_count, 0);
    v_total_vines    := v_total_vines + coalesce(r.vine_count, 0);
    v_total_area     := v_total_area + coalesce(r.area_m2, 0);

    v_rows := v_rows || jsonb_build_object(
      'valve_block_id', r.valve_block_id,
      'block_id', r.block_id,
      'block_name', r.block_name,
      'variety_id', r.variety_id_text,
      'variety_name', r.variety_name,
      'allocation_method', r.allocation_method,
      'stored_percentage', r.allocation_percentage,
      'serviced_area_m2', r.area_m2,
      'serviced_vine_count', r.vine_count,
      'serviced_emitter_count', r.serviced_emitter_count,
      'block_flow_lph', r.block_flow,
      'efficiency_percent', r.efficiency_percent,
      'dripper_output_lph', r.dripper_output_lph,
      'dripper_spacing_m', r.dripper_spacing_m,
      'vine_spacing_m', r.vine_spacing,
      'row_spacing_m', r.row_spacing
    );
  end loop;

  for v_row in select * from jsonb_array_elements(v_rows) loop
    v_method := v_row->>'allocation_method';
    if v_method = 'manual_percentage' then
      v_pct := nullif(v_row->>'stored_percentage', '')::numeric;
    elsif v_method = 'emitter_count' then
      if v_total_emitters > 0 and nullif(v_row->>'serviced_emitter_count', '') is not null then
        v_pct := round((v_row->>'serviced_emitter_count')::numeric / v_total_emitters * 100.0, 4);
      else
        v_pct := null;
      end if;
    elsif v_method = 'vine_count' then
      if v_total_vines > 0 and nullif(v_row->>'serviced_vine_count', '') is not null then
        v_pct := round((v_row->>'serviced_vine_count')::numeric / v_total_vines * 100.0, 4);
      else
        v_pct := null;
      end if;
    elsif v_method = 'irrigated_area' then
      if v_total_area > 0 and nullif(v_row->>'serviced_area_m2', '') is not null then
        v_pct := round((v_row->>'serviced_area_m2')::numeric / v_total_area * 100.0, 4);
      else
        v_pct := null;
      end if;
    else
      v_pct := null;
    end if;

    v_out := v_out || (v_row || jsonb_build_object('allocation_percentage', v_pct));
  end loop;

  return v_out;
end;
$$;

revoke all on function public._irrigation_valve_allocations(uuid) from public, anon, authenticated;

-- Internal audit writer.
create or replace function public._irrigation_audit(
  p_vineyard_id uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_old jsonb,
  p_new jsonb
) returns void
language sql
security definer
set search_path = public
as $$
  insert into public.irrigation_audit (vineyard_id, user_id, action, entity_type, entity_id, old_values, new_values)
  values (p_vineyard_id, auth.uid(), p_action, p_entity_type, p_entity_id, p_old, p_new);
$$;

revoke all on function public._irrigation_audit(uuid, text, text, uuid, jsonb, jsonb) from public, anon, authenticated;

-- Gate helper used at the top of every RPC.
create or replace function public._irrigation_require_access(p_vineyard_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_vineyard_id is null then
    raise exception 'invalid_vineyard: vineyard is required';
  end if;
  if not public.has_irrigation_records_access(p_vineyard_id) then
    raise exception 'irrigation_access_denied: Irrigation Records is not available for this account';
  end if;
end;
$$;

revoke all on function public._irrigation_require_access(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Setup RPCs
-- ---------------------------------------------------------------------------

create or replace function public.list_irrigation_systems(
  p_vineyard_id uuid,
  p_include_inactive boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._irrigation_require_access(p_vineyard_id);
  return coalesce((
    select jsonb_agg(to_jsonb(s) order by s.name)
    from public.irrigation_systems s
    where s.vineyard_id = p_vineyard_id
      and (p_include_inactive or s.is_active)
  ), '[]'::jsonb);
end;
$$;

create or replace function public.create_irrigation_system(
  p_id uuid,
  p_vineyard_id uuid,
  p_name text,
  p_water_source text default null,
  p_controller_provider text default null,
  p_controller_name text default null,
  p_external_controller_id text default null,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.irrigation_systems;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  if nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'invalid_name: a system name is required';
  end if;

  -- Idempotent retry: same id already exists -> return it.
  select * into v_row from public.irrigation_systems where id = p_id;
  if found then
    return to_jsonb(v_row);
  end if;

  if exists (
    select 1 from public.irrigation_systems
    where vineyard_id = p_vineyard_id and is_active
      and lower(trim(name)) = lower(trim(p_name))
  ) then
    raise exception 'duplicate_name: an active irrigation system with this name already exists';
  end if;

  insert into public.irrigation_systems
    (id, vineyard_id, name, water_source, controller_provider, controller_name,
     external_controller_id, notes, created_by, updated_by)
  values
    (coalesce(p_id, gen_random_uuid()), p_vineyard_id, trim(p_name), p_water_source,
     p_controller_provider, p_controller_name, p_external_controller_id, p_notes,
     auth.uid(), auth.uid())
  returning * into v_row;

  perform public._irrigation_audit(p_vineyard_id, 'create', 'irrigation_system', v_row.id, null, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;

create or replace function public.update_irrigation_system(
  p_id uuid,
  p_name text default null,
  p_water_source text default null,
  p_controller_provider text default null,
  p_controller_name text default null,
  p_external_controller_id text default null,
  p_notes text default null,
  p_is_active boolean default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.irrigation_systems;
  v_row public.irrigation_systems;
begin
  select * into v_old from public.irrigation_systems where id = p_id;
  if not found then
    raise exception 'not_found: irrigation system not found';
  end if;
  perform public._irrigation_require_access(v_old.vineyard_id);

  if p_name is not null and nullif(trim(p_name), '') is null then
    raise exception 'invalid_name: a system name is required';
  end if;
  if p_name is not null and exists (
    select 1 from public.irrigation_systems
    where vineyard_id = v_old.vineyard_id and is_active and id <> p_id
      and lower(trim(name)) = lower(trim(p_name))
  ) then
    raise exception 'duplicate_name: an active irrigation system with this name already exists';
  end if;

  update public.irrigation_systems
  set name = coalesce(nullif(trim(coalesce(p_name, '')), ''), name),
      water_source = coalesce(p_water_source, water_source),
      controller_provider = coalesce(p_controller_provider, controller_provider),
      controller_name = coalesce(p_controller_name, controller_name),
      external_controller_id = coalesce(p_external_controller_id, external_controller_id),
      notes = coalesce(p_notes, notes),
      is_active = coalesce(p_is_active, is_active),
      updated_by = auth.uid()
  where id = p_id
  returning * into v_row;

  perform public._irrigation_audit(v_old.vineyard_id,
    case when p_is_active is not null and p_is_active <> v_old.is_active
         then case when p_is_active then 'activate' else 'inactivate' end
         else 'update' end,
    'irrigation_system', p_id, to_jsonb(v_old), to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;

create or replace function public.list_irrigation_valves(
  p_vineyard_id uuid,
  p_include_inactive boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._irrigation_require_access(p_vineyard_id);
  return coalesce((
    select jsonb_agg(
      to_jsonb(v) || jsonb_build_object(
        'system_name', s.name,
        'active_block_count', (
          select count(*) from public.irrigation_valve_blocks vb
          where vb.valve_id = v.id and vb.is_active
        )
      ) order by s.name, v.name)
    from public.irrigation_valves v
    join public.irrigation_systems s on s.id = v.irrigation_system_id
    where v.vineyard_id = p_vineyard_id
      and (p_include_inactive or v.is_active)
  ), '[]'::jsonb);
end;
$$;

create or replace function public.create_irrigation_valve(
  p_id uuid,
  p_vineyard_id uuid,
  p_irrigation_system_id uuid,
  p_name text,
  p_valve_number text default null,
  p_configured_flow_litres_per_hour numeric default null,
  p_measured_flow_litres_per_hour numeric default null,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.irrigation_valves;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  if nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'invalid_name: a valve name is required';
  end if;
  if not exists (
    select 1 from public.irrigation_systems
    where id = p_irrigation_system_id and vineyard_id = p_vineyard_id
  ) then
    raise exception 'invalid_system: the irrigation system does not belong to this vineyard';
  end if;
  if p_configured_flow_litres_per_hour is not null and p_configured_flow_litres_per_hour <= 0 then
    raise exception 'invalid_flow: configured flow must be greater than zero';
  end if;
  if p_measured_flow_litres_per_hour is not null and p_measured_flow_litres_per_hour <= 0 then
    raise exception 'invalid_flow: measured flow must be greater than zero';
  end if;

  select * into v_row from public.irrigation_valves where id = p_id;
  if found then
    return to_jsonb(v_row);
  end if;

  if exists (
    select 1 from public.irrigation_valves
    where irrigation_system_id = p_irrigation_system_id and is_active
      and lower(trim(name)) = lower(trim(p_name))
  ) then
    raise exception 'duplicate_name: an active valve with this name already exists in this system';
  end if;

  insert into public.irrigation_valves
    (id, vineyard_id, irrigation_system_id, name, valve_number,
     configured_flow_litres_per_hour, measured_flow_litres_per_hour, notes,
     created_by, updated_by)
  values
    (coalesce(p_id, gen_random_uuid()), p_vineyard_id, p_irrigation_system_id, trim(p_name),
     p_valve_number, p_configured_flow_litres_per_hour, p_measured_flow_litres_per_hour,
     p_notes, auth.uid(), auth.uid())
  returning * into v_row;

  perform public._irrigation_audit(p_vineyard_id, 'create', 'irrigation_valve', v_row.id, null, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;

create or replace function public.update_irrigation_valve(
  p_id uuid,
  p_name text default null,
  p_valve_number text default null,
  p_configured_flow_litres_per_hour numeric default null,
  p_measured_flow_litres_per_hour numeric default null,
  p_notes text default null,
  p_is_active boolean default null,
  p_clear_configured_flow boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.irrigation_valves;
  v_row public.irrigation_valves;
begin
  select * into v_old from public.irrigation_valves where id = p_id;
  if not found then
    raise exception 'not_found: valve not found';
  end if;
  perform public._irrigation_require_access(v_old.vineyard_id);

  if p_configured_flow_litres_per_hour is not null and p_configured_flow_litres_per_hour <= 0 then
    raise exception 'invalid_flow: configured flow must be greater than zero';
  end if;
  if p_measured_flow_litres_per_hour is not null and p_measured_flow_litres_per_hour <= 0 then
    raise exception 'invalid_flow: measured flow must be greater than zero';
  end if;
  if p_name is not null and exists (
    select 1 from public.irrigation_valves
    where irrigation_system_id = v_old.irrigation_system_id and is_active and id <> p_id
      and lower(trim(name)) = lower(trim(p_name))
  ) then
    raise exception 'duplicate_name: an active valve with this name already exists in this system';
  end if;

  update public.irrigation_valves
  set name = coalesce(nullif(trim(coalesce(p_name, '')), ''), name),
      valve_number = coalesce(p_valve_number, valve_number),
      -- Measured flow never silently replaces configured flow: configured flow
      -- changes only when the user explicitly saves a new configured value.
      configured_flow_litres_per_hour = case
        when p_clear_configured_flow then null
        else coalesce(p_configured_flow_litres_per_hour, configured_flow_litres_per_hour) end,
      measured_flow_litres_per_hour = coalesce(p_measured_flow_litres_per_hour, measured_flow_litres_per_hour),
      notes = coalesce(p_notes, notes),
      is_active = coalesce(p_is_active, is_active),
      updated_by = auth.uid()
  where id = p_id
  returning * into v_row;

  perform public._irrigation_audit(v_old.vineyard_id,
    case when p_is_active is not null and p_is_active <> v_old.is_active
         then case when p_is_active then 'activate' else 'inactivate' end
         else 'update' end,
    'irrigation_valve', p_id, to_jsonb(v_old), to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;

create or replace function public.list_irrigation_valve_blocks(
  p_vineyard_id uuid,
  p_valve_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._irrigation_require_access(p_vineyard_id);
  return coalesce((
    select jsonb_agg(
      to_jsonb(vb) || jsonb_build_object('block_name', p.name)
      order by p.name)
    from public.irrigation_valve_blocks vb
    join public.paddocks p on p.id = vb.block_id
    where vb.vineyard_id = p_vineyard_id
      and vb.is_active
      and (p_valve_id is null or vb.valve_id = p_valve_id)
  ), '[]'::jsonb);
end;
$$;

-- Atomically replace the ACTIVE block set of a valve.
-- p_blocks: [{ "block_id": uuid, "allocation_method": text,
--              "allocation_percentage": numeric?, "serviced_area_m2": numeric?,
--              "serviced_vine_count": int?, "serviced_emitter_count": int?,
--              "row_start": int?, "row_end": int?,
--              "configured_flow_litres_per_hour": numeric? }]
-- Validates every block belongs to the vineyard and the resolved allocation
-- totals 100% (unless p_blocks is empty, which disconnects the valve).
create or replace function public.set_irrigation_valve_blocks(
  p_vineyard_id uuid,
  p_valve_id uuid,
  p_blocks jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_valve public.irrigation_valves;
  v_el jsonb;
  v_block_id uuid;
  v_old jsonb;
  v_resolved jsonb;
  v_pct_sum numeric := 0;
  v_pct numeric;
begin
  perform public._irrigation_require_access(p_vineyard_id);

  select * into v_valve from public.irrigation_valves where id = p_valve_id;
  if not found or v_valve.vineyard_id <> p_vineyard_id then
    raise exception 'invalid_valve: the valve does not belong to this vineyard';
  end if;

  v_old := public._irrigation_valve_allocations(p_valve_id);

  -- Historical configurations are preserved: rows are deactivated, not deleted
  -- (and every saved session carries its own configuration snapshot).
  update public.irrigation_valve_blocks
  set is_active = false,
      effective_to = current_date,
      updated_by = auth.uid()
  where valve_id = p_valve_id and is_active;

  if p_blocks is not null and jsonb_typeof(p_blocks) = 'array' then
    for v_el in select * from jsonb_array_elements(p_blocks) loop
      begin
        v_block_id := (v_el->>'block_id')::uuid;
      exception when others then
        raise exception 'invalid_block: a block id is missing or malformed';
      end;
      if not exists (
        select 1 from public.paddocks
        where id = v_block_id and vineyard_id = p_vineyard_id and deleted_at is null
      ) then
        raise exception 'invalid_block: block does not belong to this vineyard or is inactive';
      end if;

      insert into public.irrigation_valve_blocks
        (vineyard_id, valve_id, block_id, allocation_method, allocation_percentage,
         serviced_area_m2, serviced_vine_count, serviced_emitter_count,
         row_start, row_end, configured_flow_litres_per_hour,
         effective_from, created_by, updated_by)
      values
        (p_vineyard_id, p_valve_id, v_block_id,
         coalesce(nullif(v_el->>'allocation_method', ''), 'manual_percentage'),
         nullif(v_el->>'allocation_percentage', '')::numeric,
         nullif(v_el->>'serviced_area_m2', '')::numeric,
         nullif(v_el->>'serviced_vine_count', '')::integer,
         nullif(v_el->>'serviced_emitter_count', '')::integer,
         nullif(v_el->>'row_start', '')::integer,
         nullif(v_el->>'row_end', '')::integer,
         nullif(v_el->>'configured_flow_litres_per_hour', '')::numeric,
         current_date, auth.uid(), auth.uid());
    end loop;

    -- Validate the resolved active set totals 100%.
    if jsonb_array_length(p_blocks) > 0 then
      v_resolved := public._irrigation_valve_allocations(p_valve_id);
      for v_el in select * from jsonb_array_elements(v_resolved) loop
        v_pct := nullif(v_el->>'allocation_percentage', '')::numeric;
        if v_pct is null or v_pct <= 0 then
          raise exception 'invalid_allocation: every connected block needs a positive allocation (or the serviced values required by its allocation method)';
        end if;
        v_pct_sum := v_pct_sum + v_pct;
      end loop;
      if abs(v_pct_sum - 100) > 0.05 then
        raise exception 'allocations_not_100: block allocations total % percent instead of 100 percent', round(v_pct_sum, 2);
      end if;
    end if;
  end if;

  perform public._irrigation_audit(p_vineyard_id, 'set_blocks', 'irrigation_valve', p_valve_id,
    jsonb_build_object('allocations', v_old),
    jsonb_build_object('allocations', public._irrigation_valve_allocations(p_valve_id)));

  return public.list_irrigation_valve_blocks(p_vineyard_id, p_valve_id);
end;
$$;

-- Setup wizard status: required + recommended checklist (§5/§6 of the spec).
create or replace function public.get_irrigation_setup_status(p_vineyard_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_month integer;
  v_day integer;
  v_active_blocks integer;
  v_systems integer;
  v_valves integer;
  v_valve record;
  v_valves_json jsonb := '[]'::jsonb;
  v_allocated_valves integer := 0;
  v_flow_valves integer := 0;
  v_alloc jsonb;
  v_el jsonb;
  v_sum numeric;
  v_ok boolean;
  v_blocks_area integer;
  v_blocks_vines integer;
  v_blocks_spacing integer;
  v_blocks_dripper_out integer;
  v_blocks_dripper_sp integer;
  v_blocks_eff integer;
begin
  perform public._irrigation_require_access(p_vineyard_id);

  select v.season_start_month::integer, v.season_start_day::integer
  into v_month, v_day
  from public.vineyards v where v.id = p_vineyard_id;

  select count(*) into v_active_blocks
  from public.paddocks where vineyard_id = p_vineyard_id and deleted_at is null;

  select count(*) into v_systems
  from public.irrigation_systems where vineyard_id = p_vineyard_id and is_active;

  select count(*) into v_valves
  from public.irrigation_valves where vineyard_id = p_vineyard_id and is_active;

  for v_valve in
    select v.id, v.name, v.configured_flow_litres_per_hour
    from public.irrigation_valves v
    where v.vineyard_id = p_vineyard_id and v.is_active
    order by v.name
  loop
    v_alloc := public._irrigation_valve_allocations(v_valve.id);
    v_sum := 0;
    v_ok := jsonb_array_length(v_alloc) > 0;
    for v_el in select * from jsonb_array_elements(v_alloc) loop
      if nullif(v_el->>'allocation_percentage', '') is null then
        v_ok := false;
      else
        v_sum := v_sum + (v_el->>'allocation_percentage')::numeric;
      end if;
    end loop;
    if v_ok and abs(v_sum - 100) > 0.05 then
      v_ok := false;
    end if;
    if v_ok then
      v_allocated_valves := v_allocated_valves + 1;
    end if;
    if v_valve.configured_flow_litres_per_hour is not null then
      v_flow_valves := v_flow_valves + 1;
    end if;
    v_valves_json := v_valves_json || jsonb_build_object(
      'valve_id', v_valve.id,
      'valve_name', v_valve.name,
      'block_count', jsonb_array_length(v_alloc),
      'allocation_total', round(v_sum, 2),
      'allocation_ok', v_ok,
      'has_configured_flow', v_valve.configured_flow_litres_per_hour is not null
    );
  end loop;

  select
    count(*) filter (where coalesce(public._paddock_polygon_area_hectares(polygon_points), 0) > 0),
    count(*) filter (where vine_count_override is not null and vine_count_override > 0),
    count(*) filter (where vine_spacing is not null and vine_spacing > 0),
    count(*) filter (where flow_per_emitter is not null and flow_per_emitter > 0),
    count(*) filter (where emitter_spacing is not null and emitter_spacing > 0),
    count(*) filter (where irrigation_efficiency_percent is not null)
  into v_blocks_area, v_blocks_vines, v_blocks_spacing,
       v_blocks_dripper_out, v_blocks_dripper_sp, v_blocks_eff
  from public.paddocks
  where vineyard_id = p_vineyard_id and deleted_at is null;

  return jsonb_build_object(
    'vineyard_id', p_vineyard_id,
    'season', jsonb_build_object(
      'configured', v_month is not null,
      'season_start_month', coalesce(v_month, 7),
      'season_start_day', coalesce(v_day, 1),
      'current_vintage_year', public.resolve_vineyard_vintage_year(p_vineyard_id, current_date)
    ),
    'required', jsonb_build_object(
      'season_settings_ok', true,  -- SQL 108 guarantees a default; surfaced above for review
      'active_block_count', v_active_blocks,
      'blocks_ok', v_active_blocks > 0,
      'active_system_count', v_systems,
      'systems_ok', v_systems > 0,
      'active_valve_count', v_valves,
      'valves_ok', v_valves > 0,
      'fully_allocated_valve_count', v_allocated_valves,
      'allocations_ok', v_allocated_valves > 0,
      'valves_with_configured_flow', v_flow_valves
    ),
    'recommended', jsonb_build_object(
      'total_active_blocks', v_active_blocks,
      'blocks_with_area', v_blocks_area,
      'blocks_with_vine_count', v_blocks_vines,
      'blocks_with_vine_spacing', v_blocks_spacing,
      'blocks_with_dripper_output', v_blocks_dripper_out,
      'blocks_with_dripper_spacing', v_blocks_dripper_sp,
      'blocks_with_efficiency', v_blocks_eff
    ),
    'valves', v_valves_json,
    'is_operational', v_active_blocks > 0 and v_systems > 0 and v_valves > 0 and v_allocated_valves > 0
  );
end;
$$;

-- Can this valve record a session right now, and which methods are available?
create or replace function public.validate_irrigation_configuration(
  p_vineyard_id uuid,
  p_valve_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_valve public.irrigation_valves;
  v_alloc jsonb;
  v_el jsonb;
  v_sum numeric := 0;
  v_issues jsonb := '[]'::jsonb;
  v_alloc_ok boolean := true;
begin
  perform public._irrigation_require_access(p_vineyard_id);

  select * into v_valve from public.irrigation_valves where id = p_valve_id;
  if not found or v_valve.vineyard_id <> p_vineyard_id then
    raise exception 'invalid_valve: the valve does not belong to this vineyard';
  end if;

  if not v_valve.is_active then
    v_issues := v_issues || to_jsonb('This valve is inactive.'::text);
  end if;
  if not exists (
    select 1 from public.irrigation_systems
    where id = v_valve.irrigation_system_id and is_active
  ) then
    v_issues := v_issues || to_jsonb('The irrigation system for this valve is inactive.'::text);
  end if;

  v_alloc := public._irrigation_valve_allocations(p_valve_id);
  if jsonb_array_length(v_alloc) = 0 then
    v_alloc_ok := false;
    v_issues := v_issues || to_jsonb('This valve has no active block connections.'::text);
  else
    for v_el in select * from jsonb_array_elements(v_alloc) loop
      if nullif(v_el->>'allocation_percentage', '') is null then
        v_alloc_ok := false;
      else
        v_sum := v_sum + (v_el->>'allocation_percentage')::numeric;
      end if;
    end loop;
    if v_alloc_ok and abs(v_sum - 100) > 0.05 then
      v_alloc_ok := false;
      v_issues := v_issues || to_jsonb(format('Block allocations total %s%% instead of 100%%.', round(v_sum, 2))::text);
    elsif not v_alloc_ok then
      v_issues := v_issues || to_jsonb('One or more block allocations cannot be resolved.'::text);
    end if;
  end if;

  return jsonb_build_object(
    'valve_id', p_valve_id,
    'valve_name', v_valve.name,
    'can_record', v_valve.is_active and v_alloc_ok and jsonb_array_length(v_issues) = 0,
    'has_configured_flow', v_valve.configured_flow_litres_per_hour is not null,
    'configured_flow_litres_per_hour', v_valve.configured_flow_litres_per_hour,
    'measured_flow_litres_per_hour', v_valve.measured_flow_litres_per_hour,
    'requires_volume_entry', v_valve.configured_flow_litres_per_hour is null,
    'allocations', v_alloc,
    'allocation_total', round(v_sum, 2),
    'issues', v_issues
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Recording RPCs
-- ---------------------------------------------------------------------------

-- Internal: resolve flow + total + allocation + snapshot for a live valve.
create or replace function public._irrigation_compute(
  p_vineyard_id uuid,
  p_valve_id uuid,
  p_duration_minutes integer,
  p_calculation_method text,
  p_flow_litres_per_hour numeric,
  p_meter_start_litres numeric,
  p_meter_finish_litres numeric,
  p_total_volume_litres numeric
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_valve public.irrigation_valves;
  v_system public.irrigation_systems;
  v_alloc jsonb;
  v_flow_used numeric;
  v_total numeric;
  v_result jsonb;
  v_snapshot jsonb;
begin
  select * into v_valve from public.irrigation_valves where id = p_valve_id;
  if not found or v_valve.vineyard_id <> p_vineyard_id then
    raise exception 'invalid_valve: the valve does not belong to this vineyard';
  end if;
  if not v_valve.is_active then
    raise exception 'inactive_valve: this valve is inactive';
  end if;
  select * into v_system from public.irrigation_systems where id = v_valve.irrigation_system_id;
  if not v_system.is_active then
    raise exception 'inactive_system: the irrigation system for this valve is inactive';
  end if;

  -- Flow resolution: the valve's saved CONFIGURED flow is the operational
  -- value (a measured flow only participates once explicitly saved as
  -- configured). session_flow uses the value entered for this session.
  if p_calculation_method = 'configured_flow' then
    v_flow_used := v_valve.configured_flow_litres_per_hour;
    if v_flow_used is null then
      raise exception 'missing_configured_flow: this valve has no configured flow rate — enter a session flow, total volume or meter readings instead';
    end if;
  elsif p_calculation_method = 'session_flow' then
    v_flow_used := p_flow_litres_per_hour;
  else
    v_flow_used := null;
  end if;

  v_total := public.irrigation_total_volume(
    p_calculation_method, v_flow_used, p_duration_minutes,
    p_meter_start_litres, p_meter_finish_litres, p_total_volume_litres);

  v_alloc := public._irrigation_valve_allocations(p_valve_id);
  v_result := public._irrigation_allocate(v_total, v_alloc);

  v_snapshot := jsonb_build_object(
    'calculation_version', 1,
    'irrigation_system_id', v_system.id,
    'irrigation_system_name', v_system.name,
    'valve_id', v_valve.id,
    'valve_name', v_valve.name,
    'valve_configured_flow_lph', v_valve.configured_flow_litres_per_hour,
    'flow_lph_used', v_flow_used,
    'calculation_method', p_calculation_method,
    'unit_context', jsonb_build_object(
      'volume', 'litres', 'flow', 'litres_per_hour',
      'area', 'square_metres', 'depth', 'millimetres', 'duration', 'minutes'),
    'blocks', v_alloc
  );

  return v_result || jsonb_build_object(
    'irrigation_system_id', v_system.id,
    'irrigation_system_name', v_system.name,
    'valve_id', v_valve.id,
    'valve_name', v_valve.name,
    'flow_litres_per_hour_used', v_flow_used,
    'configuration_snapshot', v_snapshot
  );
end;
$$;

revoke all on function public._irrigation_compute(uuid, uuid, integer, text, numeric, numeric, numeric, numeric) from public, anon, authenticated;

create or replace function public.calculate_irrigation_preview(
  p_vineyard_id uuid,
  p_valve_id uuid,
  p_session_date date,
  p_duration_minutes integer,
  p_calculation_method text,
  p_flow_litres_per_hour numeric default null,
  p_meter_start_litres numeric default null,
  p_meter_finish_litres numeric default null,
  p_total_volume_litres numeric default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_result := public._irrigation_compute(
    p_vineyard_id, p_valve_id, p_duration_minutes, p_calculation_method,
    p_flow_litres_per_hour, p_meter_start_litres, p_meter_finish_litres, p_total_volume_litres);
  return v_result || jsonb_build_object(
    'session_date', p_session_date,
    'duration_minutes', p_duration_minutes,
    'vintage_year', public.resolve_vineyard_vintage_year(p_vineyard_id, coalesce(p_session_date, current_date))
  );
end;
$$;

-- Internal: session row + blocks as one jsonb payload.
create or replace function public._irrigation_session_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select to_jsonb(s)
         || jsonb_build_object(
              'system_name', sys.name,
              'valve_name', v.name,
              'blocks', coalesce((
                select jsonb_agg(to_jsonb(sb) || jsonb_build_object('block_name', p.name)
                                 order by p.name)
                from public.irrigation_session_blocks sb
                join public.paddocks p on p.id = sb.block_id
                where sb.session_id = s.id
              ), '[]'::jsonb))
  from public.irrigation_sessions s
  join public.irrigation_systems sys on sys.id = s.irrigation_system_id
  join public.irrigation_valves v on v.id = s.valve_id
  where s.id = p_id;
$$;

revoke all on function public._irrigation_session_json(uuid) from public, anon, authenticated;

-- Save a manual irrigation session. The CLIENT generates p_id before
-- submission; retries with the same id are idempotent and never duplicate.
create or replace function public.record_irrigation_session(
  p_id uuid,
  p_vineyard_id uuid,
  p_irrigation_system_id uuid,
  p_valve_id uuid,
  p_session_date date,
  p_duration_minutes integer,
  p_calculation_method text,
  p_flow_litres_per_hour numeric default null,
  p_meter_start_litres numeric default null,
  p_meter_finish_litres numeric default null,
  p_total_volume_litres numeric default null,
  p_started_at timestamptz default null,
  p_finished_at timestamptz default null,
  p_notes text default null,
  p_source_type text default 'manual_portal',
  p_original_value numeric default null,
  p_original_unit text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.irrigation_sessions;
  v_calc jsonb;
  v_vintage integer;
  v_block jsonb;
  v_session public.irrigation_sessions;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  if p_id is null then
    raise exception 'invalid_id: the client must generate the session id';
  end if;

  -- Idempotent offline retry: same id -> return the stored result unchanged.
  select * into v_existing from public.irrigation_sessions where id = p_id;
  if found then
    return public._irrigation_session_json(p_id) || jsonb_build_object('duplicate', true);
  end if;

  if p_session_date is null then
    raise exception 'invalid_date: a session date is required';
  end if;
  if p_source_type not in ('manual_ios','manual_android','manual_portal') then
    raise exception 'invalid_source: unsupported source type for manual recording';
  end if;
  if not exists (
    select 1 from public.irrigation_valves
    where id = p_valve_id and irrigation_system_id = p_irrigation_system_id
  ) then
    raise exception 'invalid_valve: the valve does not belong to the selected irrigation system';
  end if;

  v_calc := public._irrigation_compute(
    p_vineyard_id, p_valve_id, p_duration_minutes, p_calculation_method,
    p_flow_litres_per_hour, p_meter_start_litres, p_meter_finish_litres, p_total_volume_litres);

  v_vintage := public.resolve_vineyard_vintage_year(p_vineyard_id, p_session_date);

  insert into public.irrigation_sessions (
    id, vineyard_id, irrigation_system_id, valve_id, session_date, vintage_year,
    started_at, finished_at, duration_minutes, calculation_method,
    flow_litres_per_hour, meter_start_litres, meter_finish_litres,
    total_volume_litres, effective_volume_litres, original_value, original_unit,
    irrigation_efficiency_percent, status, source_type, notes,
    configuration_snapshot, created_by, updated_by
  ) values (
    p_id, p_vineyard_id, p_irrigation_system_id, p_valve_id, p_session_date, v_vintage,
    p_started_at, p_finished_at, p_duration_minutes, p_calculation_method,
    (v_calc->>'flow_litres_per_hour_used')::numeric, p_meter_start_litres, p_meter_finish_litres,
    (v_calc->>'total_volume_litres')::numeric,
    nullif(v_calc->>'effective_volume_litres', '')::numeric,
    p_original_value, p_original_unit,
    nullif(v_calc->>'irrigation_efficiency_percent', '')::numeric,
    'completed', p_source_type, p_notes,
    v_calc->'configuration_snapshot', auth.uid(), auth.uid()
  )
  on conflict (id) do nothing;

  -- Raced replay: someone inserted the same id between our check and insert.
  select * into v_session from public.irrigation_sessions where id = p_id;
  if v_session.created_by is distinct from auth.uid()
     or exists (select 1 from public.irrigation_session_blocks where session_id = p_id) then
    return public._irrigation_session_json(p_id) || jsonb_build_object('duplicate', true);
  end if;

  for v_block in select * from jsonb_array_elements(v_calc->'blocks') loop
    insert into public.irrigation_session_blocks (
      session_id, vineyard_id, valve_id, block_id, variety_id, variety_name,
      allocation_method, allocation_percentage, allocated_volume_litres,
      effective_volume_litres, serviced_area_m2, serviced_vine_count,
      water_litres_per_vine, water_litres_per_hectare,
      irrigation_depth_mm, effective_irrigation_depth_mm
    ) values (
      p_id, p_vineyard_id, p_valve_id,
      (v_block->>'block_id')::uuid,
      nullif(v_block->>'variety_id', '')::uuid,
      nullif(v_block->>'variety_name', ''),
      v_block->>'allocation_method',
      (v_block->>'allocation_percentage')::numeric,
      (v_block->>'allocated_volume_litres')::numeric,
      nullif(v_block->>'effective_volume_litres', '')::numeric,
      nullif(v_block->>'serviced_area_m2', '')::numeric,
      nullif(v_block->>'serviced_vine_count', '')::integer,
      nullif(v_block->>'water_litres_per_vine', '')::numeric,
      nullif(v_block->>'water_litres_per_hectare', '')::numeric,
      nullif(v_block->>'irrigation_depth_mm', '')::numeric,
      nullif(v_block->>'effective_irrigation_depth_mm', '')::numeric
    );
  end loop;

  perform public._irrigation_audit(p_vineyard_id, 'create', 'irrigation_session', p_id,
    null, public._irrigation_session_json(p_id));

  return public._irrigation_session_json(p_id)
         || jsonb_build_object('duplicate', false, 'warnings', coalesce(v_calc->'warnings', '[]'::jsonb));
end;
$$;

-- Edit a session. By default the SAVED configuration snapshot is reused so an
-- old record is never silently recalculated with the newest valve setup;
-- applying the current configuration requires the explicit flag.
create or replace function public.update_irrigation_session(
  p_id uuid,
  p_session_date date default null,
  p_duration_minutes integer default null,
  p_calculation_method text default null,
  p_flow_litres_per_hour numeric default null,
  p_meter_start_litres numeric default null,
  p_meter_finish_litres numeric default null,
  p_total_volume_litres numeric default null,
  p_started_at timestamptz default null,
  p_finished_at timestamptz default null,
  p_notes text default null,
  p_use_current_configuration boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.irrigation_sessions;
  v_old_json jsonb;
  v_date date;
  v_duration integer;
  v_method text;
  v_flow numeric;
  v_meter_start numeric;
  v_meter_finish numeric;
  v_volume numeric;
  v_flow_used numeric;
  v_total numeric;
  v_allocs jsonb;
  v_result jsonb;
  v_snapshot jsonb;
  v_vintage integer;
  v_block jsonb;
begin
  select * into v_old from public.irrigation_sessions where id = p_id;
  if not found then
    raise exception 'not_found: irrigation session not found';
  end if;
  perform public._irrigation_require_access(v_old.vineyard_id);
  if v_old.status = 'reversed' or v_old.deleted_at is not null then
    raise exception 'session_reversed: a reversed session cannot be edited';
  end if;

  v_old_json := public._irrigation_session_json(p_id);

  v_date := coalesce(p_session_date, v_old.session_date);
  v_duration := coalesce(p_duration_minutes, v_old.duration_minutes);
  v_method := coalesce(p_calculation_method, v_old.calculation_method);
  v_flow := coalesce(p_flow_litres_per_hour, v_old.flow_litres_per_hour);
  v_meter_start := coalesce(p_meter_start_litres, v_old.meter_start_litres);
  v_meter_finish := coalesce(p_meter_finish_litres, v_old.meter_finish_litres);
  v_volume := coalesce(p_total_volume_litres, v_old.total_volume_litres);

  if p_use_current_configuration then
    -- Explicit user action: recalculate against today's valve configuration.
    v_result := public._irrigation_compute(
      v_old.vineyard_id, v_old.valve_id, v_duration, v_method,
      case when v_method = 'session_flow' then v_flow else null end,
      v_meter_start, v_meter_finish, v_volume);
    v_flow_used := nullif(v_result->>'flow_litres_per_hour_used', '')::numeric;
    v_snapshot := v_result->'configuration_snapshot';
  else
    -- Default: reuse the frozen snapshot configuration.
    v_allocs := v_old.configuration_snapshot->'blocks';
    if v_method = 'configured_flow' then
      v_flow_used := coalesce(
        nullif(v_old.configuration_snapshot->>'valve_configured_flow_lph', '')::numeric,
        v_old.flow_litres_per_hour);
      if v_flow_used is null then
        raise exception 'missing_configured_flow: the saved configuration has no flow rate — choose another calculation method';
      end if;
    elsif v_method = 'session_flow' then
      v_flow_used := v_flow;
    else
      v_flow_used := null;
    end if;
    v_total := public.irrigation_total_volume(
      v_method, v_flow_used, v_duration, v_meter_start, v_meter_finish, v_volume);
    v_result := public._irrigation_allocate(v_total, v_allocs);
    v_snapshot := v_old.configuration_snapshot
      || jsonb_build_object('flow_lph_used', v_flow_used, 'calculation_method', v_method);
  end if;

  v_vintage := case
    when v_date is distinct from v_old.session_date
      then public.resolve_vineyard_vintage_year(v_old.vineyard_id, v_date)
    else v_old.vintage_year end;

  update public.irrigation_sessions
  set session_date = v_date,
      vintage_year = v_vintage,
      started_at = coalesce(p_started_at, started_at),
      finished_at = coalesce(p_finished_at, finished_at),
      duration_minutes = v_duration,
      calculation_method = v_method,
      flow_litres_per_hour = v_flow_used,
      meter_start_litres = v_meter_start,
      meter_finish_litres = v_meter_finish,
      total_volume_litres = (v_result->>'total_volume_litres')::numeric,
      effective_volume_litres = nullif(v_result->>'effective_volume_litres', '')::numeric,
      irrigation_efficiency_percent = nullif(v_result->>'irrigation_efficiency_percent', '')::numeric,
      status = 'corrected',
      notes = coalesce(p_notes, notes),
      configuration_snapshot = v_snapshot,
      updated_by = auth.uid()
  where id = p_id;

  -- Replace the allocation rows (prior values preserved in irrigation_audit).
  delete from public.irrigation_session_blocks where session_id = p_id;
  for v_block in select * from jsonb_array_elements(v_result->'blocks') loop
    insert into public.irrigation_session_blocks (
      session_id, vineyard_id, valve_id, block_id, variety_id, variety_name,
      allocation_method, allocation_percentage, allocated_volume_litres,
      effective_volume_litres, serviced_area_m2, serviced_vine_count,
      water_litres_per_vine, water_litres_per_hectare,
      irrigation_depth_mm, effective_irrigation_depth_mm
    ) values (
      p_id, v_old.vineyard_id, v_old.valve_id,
      (v_block->>'block_id')::uuid,
      nullif(v_block->>'variety_id', '')::uuid,
      nullif(v_block->>'variety_name', ''),
      coalesce(v_block->>'allocation_method', 'manual_percentage'),
      (v_block->>'allocation_percentage')::numeric,
      (v_block->>'allocated_volume_litres')::numeric,
      nullif(v_block->>'effective_volume_litres', '')::numeric,
      nullif(v_block->>'serviced_area_m2', '')::numeric,
      nullif(v_block->>'serviced_vine_count', '')::integer,
      nullif(v_block->>'water_litres_per_vine', '')::numeric,
      nullif(v_block->>'water_litres_per_hectare', '')::numeric,
      nullif(v_block->>'irrigation_depth_mm', '')::numeric,
      nullif(v_block->>'effective_irrigation_depth_mm', '')::numeric
    );
  end loop;

  perform public._irrigation_audit(v_old.vineyard_id, 'edit', 'irrigation_session', p_id,
    v_old_json, public._irrigation_session_json(p_id));

  return public._irrigation_session_json(p_id)
         || jsonb_build_object('warnings', coalesce(v_result->'warnings', '[]'::jsonb));
end;
$$;

-- Reverse (never hard delete). Allocation rows are preserved for audit views.
create or replace function public.reverse_irrigation_session(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.irrigation_sessions;
begin
  select * into v_old from public.irrigation_sessions where id = p_id;
  if not found then
    raise exception 'not_found: irrigation session not found';
  end if;
  perform public._irrigation_require_access(v_old.vineyard_id);

  if v_old.status = 'reversed' then
    return public._irrigation_session_json(p_id);  -- idempotent
  end if;

  update public.irrigation_sessions
  set status = 'reversed',
      deleted_at = now(),
      updated_by = auth.uid()
  where id = p_id;

  perform public._irrigation_audit(v_old.vineyard_id, 'reverse', 'irrigation_session', p_id,
    to_jsonb(v_old), public._irrigation_session_json(p_id));

  return public._irrigation_session_json(p_id);
end;
$$;

create or replace function public.get_irrigation_session(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vineyard uuid;
begin
  select vineyard_id into v_vineyard from public.irrigation_sessions where id = p_id;
  if v_vineyard is null then
    raise exception 'not_found: irrigation session not found';
  end if;
  perform public._irrigation_require_access(v_vineyard);
  return public._irrigation_session_json(p_id);
end;
$$;

create or replace function public.list_irrigation_sessions(
  p_vineyard_id uuid,
  p_vintage_year integer default null,
  p_from_date date default null,
  p_to_date date default null,
  p_irrigation_system_id uuid default null,
  p_valve_id uuid default null,
  p_block_id uuid default null,
  p_status text default null,
  p_source_type text default null,
  p_include_reversed boolean default false,
  p_limit integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sessions jsonb;
  v_total integer;
begin
  perform public._irrigation_require_access(p_vineyard_id);

  select count(*) into v_total
  from public.irrigation_sessions s
  where s.vineyard_id = p_vineyard_id
    and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
    and (p_vintage_year is null or s.vintage_year = p_vintage_year)
    and (p_from_date is null or s.session_date >= p_from_date)
    and (p_to_date is null or s.session_date <= p_to_date)
    and (p_irrigation_system_id is null or s.irrigation_system_id = p_irrigation_system_id)
    and (p_valve_id is null or s.valve_id = p_valve_id)
    and (p_status is null or s.status = p_status)
    and (p_source_type is null or s.source_type = p_source_type)
    and (p_block_id is null or exists (
      select 1 from public.irrigation_session_blocks sb
      where sb.session_id = s.id and sb.block_id = p_block_id));

  select coalesce(jsonb_agg(row_json), '[]'::jsonb) into v_sessions
  from (
    select public._irrigation_session_json(s.id) as row_json
    from public.irrigation_sessions s
    where s.vineyard_id = p_vineyard_id
      and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
      and (p_vintage_year is null or s.vintage_year = p_vintage_year)
      and (p_from_date is null or s.session_date >= p_from_date)
      and (p_to_date is null or s.session_date <= p_to_date)
      and (p_irrigation_system_id is null or s.irrigation_system_id = p_irrigation_system_id)
      and (p_valve_id is null or s.valve_id = p_valve_id)
      and (p_status is null or s.status = p_status)
      and (p_source_type is null or s.source_type = p_source_type)
      and (p_block_id is null or exists (
        select 1 from public.irrigation_session_blocks sb
        where sb.session_id = s.id and sb.block_id = p_block_id))
    order by s.session_date desc, s.created_at desc
    limit greatest(coalesce(p_limit, 50), 1)
    offset greatest(coalesce(p_offset, 0), 0)
  ) rows;

  return jsonb_build_object('sessions', v_sessions, 'total_count', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Phase 1 reporting foundations
--    All summaries aggregate the SAVED session block rows (never recalculated
--    from current setup). Reversed sessions are excluded unless requested.
--    Cumulative per-vine / per-hectare figures are WEIGHTED:
--        total allocated volume on covered blocks ÷ total covered vines/area
--    using each block's latest serviced values, never an average of averages.
-- ---------------------------------------------------------------------------

create or replace function public.get_irrigation_vintage_summary(
  p_vineyard_id uuid,
  p_vintage_year integer default null,
  p_include_reversed boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vintage integer;
  v_totals record;
  v_month record;
  v_pervine record;
  v_perarea record;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));

  select coalesce(sum(s.total_volume_litres), 0) as total_volume,
         sum(s.effective_volume_litres) as effective_volume,
         coalesce(sum(s.duration_minutes), 0) as runtime_minutes,
         count(*) as session_count,
         round(avg(s.duration_minutes), 1) as avg_duration
  into v_totals
  from public.irrigation_sessions s
  where s.vineyard_id = p_vineyard_id and s.vintage_year = v_vintage
    and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null));

  select coalesce(sum(s.total_volume_litres), 0) as month_volume,
         count(*) as month_sessions,
         coalesce(sum(s.duration_minutes), 0) as month_runtime
  into v_month
  from public.irrigation_sessions s
  where s.vineyard_id = p_vineyard_id
    and s.status <> 'reversed' and s.deleted_at is null
    and date_trunc('month', s.session_date) = date_trunc('month', current_date);

  -- Weighted per-vine: volume on blocks with vine data ÷ distinct covered vines.
  with live as (
    select sb.block_id, sb.allocated_volume_litres, sb.serviced_vine_count, sb.serviced_area_m2,
           s.session_date
    from public.irrigation_session_blocks sb
    join public.irrigation_sessions s on s.id = sb.session_id
    where s.vineyard_id = p_vineyard_id and s.vintage_year = v_vintage
      and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
  ),
  latest as (
    select distinct on (block_id) block_id, serviced_vine_count, serviced_area_m2
    from live order by block_id, session_date desc
  )
  select
    (select sum(l.allocated_volume_litres) from live l
      where l.serviced_vine_count is not null and l.serviced_vine_count > 0) as vine_volume,
    (select sum(serviced_vine_count) from latest
      where serviced_vine_count is not null and serviced_vine_count > 0) as total_vines
  into v_pervine;

  with live as (
    select sb.block_id, sb.allocated_volume_litres, sb.serviced_area_m2, s.session_date
    from public.irrigation_session_blocks sb
    join public.irrigation_sessions s on s.id = sb.session_id
    where s.vineyard_id = p_vineyard_id and s.vintage_year = v_vintage
      and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
  ),
  latest as (
    select distinct on (block_id) block_id, serviced_area_m2
    from live order by block_id, session_date desc
  )
  select
    (select sum(l.allocated_volume_litres) from live l
      where l.serviced_area_m2 is not null and l.serviced_area_m2 > 0) as area_volume,
    (select sum(serviced_area_m2) from latest
      where serviced_area_m2 is not null and serviced_area_m2 > 0) as total_area
  into v_perarea;

  return jsonb_build_object(
    'vineyard_id', p_vineyard_id,
    'vintage_year', v_vintage,
    'total_volume_litres', v_totals.total_volume,
    'effective_volume_litres', v_totals.effective_volume,
    'total_runtime_minutes', v_totals.runtime_minutes,
    'session_count', v_totals.session_count,
    'average_session_minutes', v_totals.avg_duration,
    'month_volume_litres', v_month.month_volume,
    'month_session_count', v_month.month_sessions,
    'month_runtime_minutes', v_month.month_runtime,
    'water_litres_per_vine',
      case when v_pervine.total_vines is not null and v_pervine.total_vines > 0
           then round(v_pervine.vine_volume / v_pervine.total_vines, 3) else null end,
    'irrigation_depth_mm',
      case when v_perarea.total_area is not null and v_perarea.total_area > 0
           then round(v_perarea.area_volume / v_perarea.total_area, 3) else null end
  );
end;
$$;

create or replace function public.get_irrigation_valve_summary(
  p_vineyard_id uuid,
  p_vintage_year integer default null,
  p_include_reversed boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vintage integer;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'valve_id', v.id,
      'valve_name', v.name,
      'system_name', sys.name,
      'total_volume_litres', t.total_volume,
      'total_runtime_minutes', t.runtime,
      'session_count', t.sessions,
      'last_irrigation_date', t.last_date
    ) order by v.name)
    from (
      select s.valve_id,
             sum(s.total_volume_litres) as total_volume,
             sum(s.duration_minutes) as runtime,
             count(*) as sessions,
             max(s.session_date) as last_date
      from public.irrigation_sessions s
      where s.vineyard_id = p_vineyard_id and s.vintage_year = v_vintage
        and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
      group by s.valve_id
    ) t
    join public.irrigation_valves v on v.id = t.valve_id
    join public.irrigation_systems sys on sys.id = v.irrigation_system_id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_irrigation_block_summary(
  p_vineyard_id uuid,
  p_vintage_year integer default null,
  p_include_reversed boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vintage integer;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  return coalesce((
    with live as (
      select sb.*, s.session_date
      from public.irrigation_session_blocks sb
      join public.irrigation_sessions s on s.id = sb.session_id
      where s.vineyard_id = p_vineyard_id and s.vintage_year = v_vintage
        and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
    ),
    latest as (
      select distinct on (block_id) block_id, serviced_vine_count, serviced_area_m2
      from live order by block_id, session_date desc
    )
    select jsonb_agg(jsonb_build_object(
      'block_id', g.block_id,
      'block_name', p.name,
      'total_volume_litres', g.total_volume,
      'effective_volume_litres', g.effective_volume,
      'session_count', g.sessions,
      'last_irrigation_date', g.last_date,
      'water_litres_per_vine',
        case when lt.serviced_vine_count is not null and lt.serviced_vine_count > 0
             then round(g.total_volume / lt.serviced_vine_count, 3) else null end,
      'water_litres_per_hectare',
        case when lt.serviced_area_m2 is not null and lt.serviced_area_m2 > 0
             then round(g.total_volume / (lt.serviced_area_m2 / 10000.0), 2) else null end,
      'irrigation_depth_mm',
        case when lt.serviced_area_m2 is not null and lt.serviced_area_m2 > 0
             then round(g.total_volume / lt.serviced_area_m2, 3) else null end
    ) order by p.name)
    from (
      select block_id,
             sum(allocated_volume_litres) as total_volume,
             sum(effective_volume_litres) as effective_volume,
             count(distinct session_id) as sessions,
             max(session_date) as last_date
      from live
      group by block_id
    ) g
    join latest lt on lt.block_id = g.block_id
    join public.paddocks p on p.id = g.block_id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_irrigation_variety_summary(
  p_vineyard_id uuid,
  p_vintage_year integer default null,
  p_include_reversed boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vintage integer;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  return coalesce((
    with live as (
      select coalesce(sb.variety_name, 'Unassigned') as variety,
             sb.block_id, sb.allocated_volume_litres,
             sb.serviced_vine_count, sb.serviced_area_m2, s.session_date
      from public.irrigation_session_blocks sb
      join public.irrigation_sessions s on s.id = sb.session_id
      where s.vineyard_id = p_vineyard_id and s.vintage_year = v_vintage
        and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
    ),
    latest as (
      -- One row per block: latest serviced values, so vines/area are never
      -- double-counted across aggregated sessions.
      select distinct on (block_id) block_id, variety, serviced_vine_count, serviced_area_m2
      from live order by block_id, session_date desc
    ),
    variety_scale as (
      select variety,
             sum(serviced_vine_count) filter (where serviced_vine_count > 0) as total_vines,
             sum(serviced_area_m2) filter (where serviced_area_m2 > 0) as total_area
      from latest group by variety
    )
    select jsonb_agg(jsonb_build_object(
      'variety_name', g.variety,
      'total_volume_litres', g.total_volume,
      'total_serviced_area_m2', sc.total_area,
      'total_serviced_vines', sc.total_vines,
      'average_water_litres_per_hectare',
        case when sc.total_area is not null and sc.total_area > 0
             then round(g.area_volume / (sc.total_area / 10000.0), 2) else null end,
      'average_water_litres_per_vine',
        case when sc.total_vines is not null and sc.total_vines > 0
             then round(g.vine_volume / sc.total_vines, 3) else null end,
      'irrigation_depth_mm',
        case when sc.total_area is not null and sc.total_area > 0
             then round(g.area_volume / sc.total_area, 3) else null end
    ) order by g.variety)
    from (
      select variety,
             sum(allocated_volume_litres) as total_volume,
             sum(allocated_volume_litres) filter (where serviced_area_m2 > 0) as area_volume,
             sum(allocated_volume_litres) filter (where serviced_vine_count > 0) as vine_volume
      from live group by variety
    ) g
    join variety_scale sc on sc.variety = g.variety
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_irrigation_daily_summary(
  p_vineyard_id uuid,
  p_vintage_year integer default null,
  p_include_reversed boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vintage integer;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'date', d.session_date,
      'total_volume_litres', d.total_volume,
      'runtime_minutes', d.runtime,
      'session_count', d.sessions
    ) order by d.session_date desc)
    from (
      select s.session_date,
             sum(s.total_volume_litres) as total_volume,
             sum(s.duration_minutes) as runtime,
             count(*) as sessions
      from public.irrigation_sessions s
      where s.vineyard_id = p_vineyard_id and s.vintage_year = v_vintage
        and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
      group by s.session_date
    ) d
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_irrigation_monthly_summary(
  p_vineyard_id uuid,
  p_vintage_year integer default null,
  p_include_reversed boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vintage integer;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  return coalesce((
    with live as (
      select date_trunc('month', s.session_date)::date as month,
             s.id, s.total_volume_litres, s.duration_minutes
      from public.irrigation_sessions s
      where s.vineyard_id = p_vineyard_id and s.vintage_year = v_vintage
        and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
    )
    select jsonb_agg(jsonb_build_object(
      'month', m.month,
      'total_volume_litres', m.total_volume,
      'runtime_minutes', m.runtime,
      'session_count', m.sessions,
      'irrigation_depth_mm', md.depth_mm
    ) order by m.month desc)
    from (
      select month,
             sum(total_volume_litres) as total_volume,
             sum(duration_minutes) as runtime,
             count(*) as sessions
      from live group by month
    ) m
    left join lateral (
      -- Weighted month depth: month volume on covered blocks ÷ covered area.
      select case when sum(lt.serviced_area_m2) > 0
                  then round(sum(mv.month_volume) / sum(lt.serviced_area_m2), 3)
                  else null end as depth_mm
      from (
        select sb.block_id, sum(sb.allocated_volume_litres) as month_volume
        from public.irrigation_session_blocks sb
        join public.irrigation_sessions s on s.id = sb.session_id
        where s.vineyard_id = p_vineyard_id and s.vintage_year = v_vintage
          and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
          and date_trunc('month', s.session_date)::date = m.month
          and sb.serviced_area_m2 > 0
        group by sb.block_id
      ) mv
      join (
        select distinct on (sb.block_id) sb.block_id, sb.serviced_area_m2
        from public.irrigation_session_blocks sb
        join public.irrigation_sessions s on s.id = sb.session_id
        where s.vineyard_id = p_vineyard_id and s.vintage_year = v_vintage
          and sb.serviced_area_m2 > 0
        order by sb.block_id, s.session_date desc
      ) lt on lt.block_id = mv.block_id
    ) md on true
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Grants
-- ---------------------------------------------------------------------------
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'list_irrigation_systems(uuid, boolean)',
    'create_irrigation_system(uuid, uuid, text, text, text, text, text, text)',
    'update_irrigation_system(uuid, text, text, text, text, text, text, boolean)',
    'list_irrigation_valves(uuid, boolean)',
    'create_irrigation_valve(uuid, uuid, uuid, text, text, numeric, numeric, text)',
    'update_irrigation_valve(uuid, text, text, numeric, numeric, text, boolean, boolean)',
    'list_irrigation_valve_blocks(uuid, uuid)',
    'set_irrigation_valve_blocks(uuid, uuid, jsonb)',
    'get_irrigation_setup_status(uuid)',
    'validate_irrigation_configuration(uuid, uuid)',
    'calculate_irrigation_preview(uuid, uuid, date, integer, text, numeric, numeric, numeric, numeric)',
    'record_irrigation_session(uuid, uuid, uuid, uuid, date, integer, text, numeric, numeric, numeric, numeric, timestamptz, timestamptz, text, text, numeric, text)',
    'update_irrigation_session(uuid, date, integer, text, numeric, numeric, numeric, numeric, timestamptz, timestamptz, text, boolean)',
    'reverse_irrigation_session(uuid)',
    'get_irrigation_session(uuid)',
    'list_irrigation_sessions(uuid, integer, date, date, uuid, uuid, uuid, text, text, boolean, integer, integer)',
    'get_irrigation_vintage_summary(uuid, integer, boolean)',
    'get_irrigation_valve_summary(uuid, integer, boolean)',
    'get_irrigation_block_summary(uuid, integer, boolean)',
    'get_irrigation_variety_summary(uuid, integer, boolean)',
    'get_irrigation_daily_summary(uuid, integer, boolean)',
    'get_irrigation_monthly_summary(uuid, integer, boolean)'
  ]
  loop
    execute format('revoke all on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Validation — the migration ABORTS if any calculation rule fails.
--     (Mirrors the required Phase 1 automated calculation tests.)
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  b0 jsonb;
  b1 jsonb;
  v_failed boolean;
begin
  -- Flow × duration: whole hours (2,000 L/h × 3.5 h = 7,000 L)
  assert public.irrigation_total_volume('configured_flow', 2000, 210, null, null, null) = 7000,
    'configured flow 2000 L/h × 210 min must equal 7000 L';
  -- Partial hour (1,000 L/h × 90 min = 1,500 L)
  assert public.irrigation_total_volume('session_flow', 1000, 90, null, null, null) = 1500,
    'session flow 1000 L/h × 90 min must equal 1500 L';
  -- Meter difference
  assert public.irrigation_total_volume('meter_readings', null, 60, 5000, 8600, null) = 3600,
    'meter 5000 → 8600 must equal 3600 L';
  -- Manual total volume
  assert public.irrigation_total_volume('total_volume', null, 60, null, null, 4200) = 4200,
    'manual total volume must be preserved';

  -- Zero flow rejected
  v_failed := false;
  begin
    perform public.irrigation_total_volume('session_flow', 0, 60, null, null, null);
  exception when others then v_failed := true; end;
  assert v_failed, 'zero flow must be rejected';

  -- Negative flow rejected
  v_failed := false;
  begin
    perform public.irrigation_total_volume('session_flow', -5, 60, null, null, null);
  exception when others then v_failed := true; end;
  assert v_failed, 'negative flow must be rejected';

  -- Zero duration rejected
  v_failed := false;
  begin
    perform public.irrigation_total_volume('configured_flow', 2000, 0, null, null, null);
  exception when others then v_failed := true; end;
  assert v_failed, 'zero duration must be rejected';

  -- Negative meter difference rejected
  v_failed := false;
  begin
    perform public.irrigation_total_volume('meter_readings', null, 60, 8600, 5000, null);
  exception when others then v_failed := true; end;
  assert v_failed, 'negative meter difference must be rejected';

  -- Two-block allocation with decimal percentages, per-vine, per-hectare,
  -- depth, effective volume, and missing-data NULL (never zero) handling.
  v := public._irrigation_allocate(7000, jsonb_build_array(
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000001',
      'block_name', 'Block A', 'allocation_method', 'manual_percentage',
      'allocation_percentage', 60, 'serviced_area_m2', 20000,
      'serviced_vine_count', 2000, 'efficiency_percent', 90),
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000002',
      'block_name', 'Block B', 'allocation_method', 'manual_percentage',
      'allocation_percentage', 40, 'serviced_area_m2', null,
      'serviced_vine_count', null, 'efficiency_percent', null)
  ));
  b0 := v->'blocks'->0;
  b1 := v->'blocks'->1;
  assert (b0->>'allocated_volume_litres')::numeric = 4200, 'Block A allocation must be 4200 L';
  assert (b1->>'allocated_volume_litres')::numeric = 2800, 'Block B allocation must be 2800 L';
  assert (b0->>'water_litres_per_vine')::numeric = 2.1, 'Block A water per vine must be 2.1 L';
  assert (b0->>'water_litres_per_hectare')::numeric = 2100, 'Block A water per hectare must be 2100 L/ha';
  assert (b0->>'irrigation_depth_mm')::numeric = 0.21, 'Block A depth must be 0.21 mm';
  assert (b0->>'effective_volume_litres')::numeric = 3780, 'Block A effective volume must be 3780 L';
  assert b1->>'water_litres_per_vine' is null, 'missing vine count must yield NULL, not zero';
  assert b1->>'water_litres_per_hectare' is null, 'missing area must yield NULL, not zero';
  assert v->>'effective_volume_litres' is null, 'session effective must be NULL when any efficiency is missing';
  assert jsonb_array_length(v->'warnings') >= 2, 'missing data must produce warnings';

  -- Decimal percentages accepted (33.33 / 66.67)
  v := public._irrigation_allocate(1000, jsonb_build_array(
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000001',
      'block_name', 'A', 'allocation_percentage', 33.33),
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000002',
      'block_name', 'B', 'allocation_percentage', 66.67)
  ));
  assert (v->'blocks'->0->>'allocated_volume_litres')::numeric = 333.3, 'decimal percentage allocation failed';

  -- Allocation below 100% rejected
  v_failed := false;
  begin
    perform public._irrigation_allocate(1000, jsonb_build_array(
      jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000001',
        'block_name', 'A', 'allocation_percentage', 60)));
  exception when others then v_failed := true; end;
  assert v_failed, 'allocation below 100 percent must be rejected';

  -- Allocation above 100% rejected
  v_failed := false;
  begin
    perform public._irrigation_allocate(1000, jsonb_build_array(
      jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000001',
        'block_name', 'A', 'allocation_percentage', 60),
      jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000002',
        'block_name', 'B', 'allocation_percentage', 60)));
  exception when others then v_failed := true; end;
  assert v_failed, 'allocation above 100 percent must be rejected';

  -- Empty allocation set rejected
  v_failed := false;
  begin
    perform public._irrigation_allocate(1000, '[]'::jsonb);
  exception when others then v_failed := true; end;
  assert v_failed, 'empty allocation set must be rejected';
end $$;

-- Make PostgREST pick up all new functions immediately.
notify pgrst, 'reload schema';

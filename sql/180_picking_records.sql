-- =============================================================================
-- 180: Detailed Picking Log (Record Actual Yield — Detailed mode)
--
-- Adds the canonical shared contract for individual picking records so a
-- Block + Variety + Vintage can have MANY picks in one vintage, plus the
-- vineyard-level grape sugar measurement preference (Brix / Baumé).
--
-- Consumed by iOS, Android and the Lovable portal. Nothing here changes the
-- existing Basic actual-yield workflow (historical_yield_records is untouched).
--
-- Contract summary
--   Table  public.picking_records          — one row per individual pick
--   View   public.picking_yield_totals     — SUM(weight_kg)/1000 per
--                                            vineyard + vintage + block + variety
--   RPC    soft_delete_picking_record(p_id uuid)
--   Column public.vineyards.sugar_measurement_unit  ('brix' | 'baume' | null)
--   RPCs   get/set_vineyard_region_settings extended with the sugar unit
--          (legacy 11-parameter set overload kept for older clients)
--
-- Vintage is SERVER-AUTHORITATIVE: a BEFORE trigger derives it from picked_at
-- via public.resolve_vineyard_vintage_year (sql/119), so a client-supplied
-- vintage is never trusted. Clients mirror the same maths for offline display.
--
-- Historical measurement integrity: every record stores BOTH sugar_value and
-- the sugar_unit used at entry time. Changing the vineyard preference later
-- only changes the default for NEW entries — it never reinterprets old rows.
--
-- grape_value is a GENERATED column: (weight_kg / 1000) * price_per_tonne for
-- sold records. Clients must NOT include grape_value in inserts/upserts.
--
-- Aggregation precedence (documented for all clients):
--   If picking records exist for a Block + Variety + Vintage, their summed
--   weight IS the actual yield for that combination. A Basic manually entered
--   actual for the same combination is superseded — never added on top.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. picking_records table
-- ---------------------------------------------------------------------------
-- paddock_id intentionally has NO foreign key (matching the block_results
-- contract in historical_yield_records): paddock_name/variety_name are
-- point-in-time snapshots so records survive later block reconfiguration.
create table if not exists public.picking_records (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  picked_at date not null,
  vintage integer not null default 0,           -- server-derived, see trigger
  paddock_id uuid not null,
  paddock_name text not null default '',
  variety_id uuid null,
  variety_key text null,                        -- stable catalog key (paddock allocation contract)
  variety_name text not null default '',
  clone text null,                              -- display string, per PaddockVarietyAllocation.clone
  weight_kg double precision not null,
  sugar_value double precision null,
  sugar_unit text null,                         -- 'brix' | 'baume', unit used AT ENTRY TIME
  ph double precision null,
  ta_g_l double precision null,
  purpose text not null default '',
  sold boolean not null default false,
  sold_to text null,
  price_per_tonne double precision null,
  grape_value double precision generated always as (
    case
      when sold and price_per_tonne is not null
      then (weight_kg / 1000.0) * price_per_tonne
    end
  ) stored,
  notes text not null default '',
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

do $$
begin
  alter table public.picking_records
    add constraint picking_records_weight_positive check (weight_kg > 0);
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.picking_records
    add constraint picking_records_sugar_unit_check
    check (sugar_unit is null or sugar_unit in ('brix', 'baume'));
exception when duplicate_object then null;
end $$;

do $$
begin
  -- a sugar value is meaningless without the unit it was measured in
  alter table public.picking_records
    add constraint picking_records_sugar_value_requires_unit
    check (sugar_value is null or sugar_unit is not null);
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.picking_records
    add constraint picking_records_price_non_negative
    check (price_per_tonne is null or price_per_tonne >= 0);
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.picking_records
    add constraint picking_records_ph_range
    check (ph is null or (ph > 0 and ph < 14));
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.picking_records
    add constraint picking_records_ta_non_negative
    check (ta_g_l is null or ta_g_l >= 0);
exception when duplicate_object then null;
end $$;

create index if not exists idx_picking_records_vineyard_picked
  on public.picking_records (vineyard_id, picked_at desc);
create index if not exists idx_picking_records_updated_at
  on public.picking_records (updated_at);
create index if not exists idx_picking_records_deleted_at
  on public.picking_records (deleted_at);
-- aggregation path: actual yield per block + variety + vintage
create index if not exists idx_picking_records_aggregation
  on public.picking_records (vineyard_id, vintage, paddock_id)
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- 2. Server-authoritative vintage + input normalisation
-- ---------------------------------------------------------------------------
create or replace function public.picking_records_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, new.picked_at);
  new.sugar_unit := nullif(lower(trim(coalesce(new.sugar_unit, ''))), '');
  if new.sugar_value is null then
    new.sugar_unit := null;
  end if;
  if not new.sold then
    -- unsold picks carry no commercial fields (§7 of the contract)
    new.sold_to := null;
    new.price_per_tonne := null;
  end if;
  new.sold_to := nullif(trim(coalesce(new.sold_to, '')), '');
  return new;
end;
$$;

create or replace trigger picking_records_before_write
before insert or update on public.picking_records
for each row execute function public.picking_records_before_write();

create or replace trigger picking_records_set_updated_at
before update on public.picking_records
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. RLS — identical shape to historical_yield_records
-- ---------------------------------------------------------------------------
alter table public.picking_records enable row level security;

drop policy if exists "picking_records_select_members" on public.picking_records;
create policy "picking_records_select_members"
on public.picking_records for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "picking_records_insert_members" on public.picking_records;
create policy "picking_records_insert_members"
on public.picking_records for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "picking_records_update_members" on public.picking_records;
create policy "picking_records_update_members"
on public.picking_records for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "picking_records_no_client_hard_delete" on public.picking_records;
create policy "picking_records_no_client_hard_delete"
on public.picking_records for delete
to authenticated
using (false);

-- ---------------------------------------------------------------------------
-- 4. Soft delete RPC
-- ---------------------------------------------------------------------------
create or replace function public.soft_delete_picking_record(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id from public.picking_records where id = p_id;
  if v_vineyard_id is null then raise exception 'Picking record not found'; end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete picking record';
  end if;
  update public.picking_records
     set deleted_at = now(), updated_by = auth.uid()
   where id = p_id;
end;
$$;
revoke all on function public.soft_delete_picking_record(uuid) from public;
grant execute on function public.soft_delete_picking_record(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Aggregated actual yield per Block + Variety + Vintage
--    security_invoker so the caller's RLS applies to the base table.
-- ---------------------------------------------------------------------------
create or replace view public.picking_yield_totals
with (security_invoker = on) as
select
  vineyard_id,
  vintage,
  paddock_id,
  variety_name,
  max(paddock_name)                       as paddock_name,
  count(*)::integer                       as pick_count,
  sum(weight_kg)                          as total_weight_kg,
  sum(weight_kg) / 1000.0                 as actual_yield_tonnes,
  min(picked_at)                          as first_picked_at,
  max(picked_at)                          as last_picked_at,
  sum(grape_value)                        as total_grape_value
from public.picking_records
where deleted_at is null
group by vineyard_id, vintage, paddock_id, variety_name;

grant select on public.picking_yield_totals to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Vineyard sugar measurement preference (regional settings extension)
-- ---------------------------------------------------------------------------
alter table public.vineyards add column if not exists sugar_measurement_unit text;

do $$
begin
  alter table public.vineyards
    add constraint vineyards_sugar_measurement_unit_check
    check (sugar_measurement_unit is null or sugar_measurement_unit in ('brix', 'baume'));
exception when duplicate_object then null;
end $$;

-- Recreate the read RPC with the sugar unit appended (return type changes).
drop function if exists public.get_vineyard_region_settings(uuid);

create or replace function public.get_vineyard_region_settings(
  p_vineyard_id uuid
) returns table (
  vineyard_id            uuid,
  country_code           text,
  currency_code          text,
  timezone               text,
  area_unit              text,
  volume_unit            text,
  distance_unit          text,
  fuel_unit              text,
  spray_rate_area_unit   text,
  date_format            text,
  terminology_region     text,
  sugar_measurement_unit text
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_member boolean;
begin
  select exists(
    select 1
      from public.vineyard_members vm
     where vm.vineyard_id = p_vineyard_id
       and vm.user_id     = auth.uid()
  ) into v_member;

  if not v_member then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;

  return query
    select v.id,
           v.country_code,
           v.currency_code,
           v.timezone,
           v.area_unit,
           v.volume_unit,
           v.distance_unit,
           v.fuel_unit,
           v.spray_rate_area_unit,
           v.date_format,
           v.terminology_region,
           v.sugar_measurement_unit
      from public.vineyards v
     where v.id = p_vineyard_id;
end$$;

revoke all on function public.get_vineyard_region_settings(uuid) from public;
grant execute on function public.get_vineyard_region_settings(uuid) to authenticated;

-- New 12-parameter write overload. The legacy 11-parameter overload from
-- sql/099 is intentionally kept so older app builds keep working — it never
-- touches sugar_measurement_unit, so it cannot clear the preference.
drop function if exists public.set_vineyard_region_settings(
  uuid, text, text, text, text, text, text, text, text, text, text, text
);

create or replace function public.set_vineyard_region_settings(
  p_vineyard_id            uuid,
  p_country_code           text,
  p_currency_code          text,
  p_timezone               text,
  p_area_unit              text,
  p_volume_unit            text,
  p_distance_unit          text,
  p_fuel_unit              text,
  p_spray_rate_area_unit   text,
  p_date_format            text,
  p_terminology_region     text,
  p_sugar_measurement_unit text
) returns table (
  vineyard_id            uuid,
  country_code           text,
  currency_code          text,
  timezone               text,
  area_unit              text,
  volume_unit            text,
  distance_unit          text,
  fuel_unit              text,
  spray_rate_area_unit   text,
  date_format            text,
  terminology_region     text,
  sugar_measurement_unit text
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_role  text;
  v_sugar text;
begin
  select vm.role::text into v_role
    from public.vineyard_members vm
   where vm.vineyard_id = p_vineyard_id
     and vm.user_id     = auth.uid()
   limit 1;

  if v_role is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  v_sugar := nullif(lower(trim(coalesce(p_sugar_measurement_unit, ''))), '');
  if v_sugar is not null and v_sugar not in ('brix', 'baume') then
    raise exception 'sugar_measurement_unit must be ''brix'' or ''baume''';
  end if;

  update public.vineyards v
     set country_code           = nullif(trim(p_country_code), ''),
         currency_code          = nullif(trim(p_currency_code), ''),
         timezone               = nullif(trim(p_timezone), ''),
         area_unit              = nullif(trim(p_area_unit), ''),
         volume_unit            = nullif(trim(p_volume_unit), ''),
         distance_unit          = nullif(trim(p_distance_unit), ''),
         fuel_unit              = nullif(trim(p_fuel_unit), ''),
         spray_rate_area_unit   = nullif(trim(p_spray_rate_area_unit), ''),
         date_format            = nullif(trim(p_date_format), ''),
         terminology_region     = nullif(trim(p_terminology_region), ''),
         sugar_measurement_unit = v_sugar,
         updated_at             = now()
   where v.id = p_vineyard_id;

  return query
    select v.id,
           v.country_code,
           v.currency_code,
           v.timezone,
           v.area_unit,
           v.volume_unit,
           v.distance_unit,
           v.fuel_unit,
           v.spray_rate_area_unit,
           v.date_format,
           v.terminology_region,
           v.sugar_measurement_unit
      from public.vineyards v
     where v.id = p_vineyard_id;
end$$;

revoke all on function public.set_vineyard_region_settings(
  uuid, text, text, text, text, text, text, text, text, text, text, text
) from public;
grant execute on function public.set_vineyard_region_settings(
  uuid, text, text, text, text, text, text, text, text, text, text, text
) to authenticated;

notify pgrst, 'reload schema';

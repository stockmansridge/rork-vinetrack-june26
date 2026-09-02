-- =============================================================================
-- 222: Vintage assignment for the remaining dated operational records.
--
-- SQL 119 established the canonical vintage rule and applied it to work_tasks
-- and pruning_entries. SQL 125/166/180/184/221 extended it to irrigation
-- sessions, pruning activities, picking records, damage records and yield
-- estimation sessions.
--
-- This migration closes the remaining gap found by the platform-wide Vintage
-- audit. Eight dated operational tables carried a reliable vineyard-local
-- event date but NO vintage, so every vintage-scoped list, total, chart and
-- export over them had to be recomputed client-side (or, more often, could
-- not be filtered by vintage at all):
--
--     pins                  created_at        (when the pin was dropped)
--     trips                 start_time        (falls back to created_at)
--     spray_records         date              (falls back to start_time, created_at)
--     growth_stage_records  observed_at
--     maintenance_logs      date
--     fuel_purchases        date
--     tractor_fuel_logs     fill_datetime
--     fertiliser_records    application_date  (already a DATE — no tz shift)
--
-- NOT IN SCOPE — undated configuration/master data never receives a vintage:
--   paddocks, equipment_items, tractors, vineyard_machines, spray_equipment,
--   saved_chemicals, master_chemicals, saved_inputs, saved_spray_presets,
--   vineyards, vineyard_* settings and every catalogue table.
--
-- ALSO NOT IN SCOPE:
--   spray_jobs      — planned_date is a FORWARD PLAN, not an event that
--                     happened. The spray_records it produces are the
--                     operational records and they are covered here.
--   trip_cost_allocations — already carries season_year derived from its trip;
--                     it is a costing rollup, not an independently dated record.
--   historical_yield_records — `year` already IS the vintage of the archive.
--
-- CONTRACT (identical to sql/221 §A, which is the current house rule):
--   * INSERT: the server resolves the vintage from the vineyard-local event
--     date. A plausible client-supplied vintage is preserved; an absent or
--     implausible one is resolved server-side rather than rejected, so a
--     queued offline replay from an un-updated build can never wedge.
--   * UPDATE that moves the event date WITHOUT restating the vintage:
--     re-resolve from the new date (audit requirement 10).
--   * UPDATE that touches anything else: the stored vintage is preserved, so
--     an unrelated edit never moves a record between vintages (audit
--     requirement 9), and later Operational Preference changes can never
--     rewrite historical reporting.
--   * A client that deliberately restates the vintage in the same write as a
--     date change is trusted — that is an explicit user restatement.
--
-- SQL 221's Yield/Damage contract is NOT touched by this migration. No object
-- created by 221 is dropped, altered or replaced here.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Shared helper — vineyard-local calendar date of an instant
--
-- Every trigger below funnels through this so the timezone rule can never
-- drift between tables. Identical semantics to sql/119 §4 and sql/221 §A:
-- the vineyard's timezone, falling back to UTC when it is unset or blank.
-- ---------------------------------------------------------------------------
create or replace function public._vineyard_local_date(
  p_vineyard_id uuid,
  p_ts timestamptz
) returns date
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tz text;
begin
  if p_ts is null then
    return null;
  end if;
  select v.timezone into v_tz from public.vineyards v where v.id = p_vineyard_id;
  return (p_ts at time zone coalesce(nullif(v_tz, ''), 'UTC'))::date;
end;
$$;

revoke all on function public._vineyard_local_date(uuid, timestamptz) from public, anon;
grant execute on function public._vineyard_local_date(uuid, timestamptz) to authenticated;

comment on function public._vineyard_local_date(uuid, timestamptz) is
  'Vineyard-local calendar date of an instant, using vineyards.timezone with a UTC fallback. Shared basis for every vintage trigger so the timezone rule cannot drift between tables. (SQL 222)';

-- ---------------------------------------------------------------------------
-- 2. Columns + indexes
--
-- The column is named `vintage` on all eight tables, matching the newer
-- convention established by picking_records (180) and damage_records (221).
-- The older `vintage_year` spelling on work_tasks/pruning_entries/
-- irrigation_sessions is deliberately NOT renamed — renaming it would break
-- every existing client and report for no behavioural gain.
-- ---------------------------------------------------------------------------
alter table public.pins                 add column if not exists vintage integer null;
alter table public.trips                add column if not exists vintage integer null;
alter table public.spray_records        add column if not exists vintage integer null;
alter table public.growth_stage_records add column if not exists vintage integer null;
alter table public.maintenance_logs     add column if not exists vintage integer null;
alter table public.fuel_purchases       add column if not exists vintage integer null;
alter table public.tractor_fuel_logs    add column if not exists vintage integer null;
alter table public.fertiliser_records   add column if not exists vintage integer null;

comment on column public.pins.vintage is
  'Season (vintage) this pin belongs to, resolved from created_at (the moment the pin was dropped) in vineyard-local time. Server-authoritative. (SQL 222)';
comment on column public.trips.vintage is
  'Season (vintage) this trip belongs to, resolved from coalesce(start_time, created_at) in vineyard-local time. Server-authoritative. (SQL 222)';
comment on column public.spray_records.vintage is
  'Season (vintage) this spray belongs to, resolved from coalesce(date, start_time, created_at) in vineyard-local time. Server-authoritative. (SQL 222)';
comment on column public.growth_stage_records.vintage is
  'Season (vintage) this observation belongs to, resolved from observed_at in vineyard-local time. Server-authoritative. (SQL 222)';
comment on column public.maintenance_logs.vintage is
  'Season (vintage) this maintenance log belongs to, resolved from date in vineyard-local time. Server-authoritative. (SQL 222)';
comment on column public.fuel_purchases.vintage is
  'Season (vintage) this fuel purchase belongs to, resolved from date in vineyard-local time. Server-authoritative. (SQL 222)';
comment on column public.tractor_fuel_logs.vintage is
  'Season (vintage) this fuel log belongs to, resolved from fill_datetime in vineyard-local time. Server-authoritative. (SQL 222)';
comment on column public.fertiliser_records.vintage is
  'Season (vintage) this application belongs to, resolved from application_date (already a vineyard-local DATE — no timezone shift). Server-authoritative. (SQL 222)';

create index if not exists pins_vineyard_vintage_idx
  on public.pins (vineyard_id, vintage) where deleted_at is null;
create index if not exists trips_vineyard_vintage_idx
  on public.trips (vineyard_id, vintage) where deleted_at is null;
create index if not exists spray_records_vineyard_vintage_idx
  on public.spray_records (vineyard_id, vintage) where deleted_at is null;
create index if not exists growth_stage_records_vineyard_vintage_idx
  on public.growth_stage_records (vineyard_id, vintage) where deleted_at is null;
create index if not exists maintenance_logs_vineyard_vintage_idx
  on public.maintenance_logs (vineyard_id, vintage) where deleted_at is null;
create index if not exists fuel_purchases_vineyard_vintage_idx
  on public.fuel_purchases (vineyard_id, vintage) where deleted_at is null;
create index if not exists tractor_fuel_logs_vineyard_vintage_idx
  on public.tractor_fuel_logs (vineyard_id, vintage) where deleted_at is null;
create index if not exists fertiliser_records_vineyard_vintage_idx
  on public.fertiliser_records (vineyard_id, vintage) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- 3. Trigger functions
--
-- One per table (rather than a single dynamic function) so each is type-safe
-- against its own row shape and readable in isolation. They share the exact
-- decision structure; only the basis expression differs.
-- ---------------------------------------------------------------------------

-- pins ----------------------------------------------------------------------
create or replace function public.pins_resolve_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_basis           date;
  v_max             integer := extract(year from now())::integer + 5;
  v_basis_changed   boolean := false;
  v_vintage_changed boolean := false;
begin
  v_basis := public._vineyard_local_date(new.vineyard_id, new.created_at);

  if tg_op = 'UPDATE' then
    v_basis_changed := new.created_at is distinct from old.created_at
                    or new.vineyard_id is distinct from old.vineyard_id;
    v_vintage_changed := new.vintage is distinct from old.vintage;
    if v_basis_changed and not v_vintage_changed then
      new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
      return new;
    end if;
  end if;

  if new.vintage is null or new.vintage < 2000 or new.vintage > v_max then
    new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
  end if;
  return new;
end;
$fn$;

drop trigger if exists pins_resolve_vintage on public.pins;
create trigger pins_resolve_vintage
  before insert or update on public.pins
  for each row execute function public.pins_resolve_vintage();

-- trips ---------------------------------------------------------------------
create or replace function public.trips_resolve_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_basis           date;
  v_max             integer := extract(year from now())::integer + 5;
  v_basis_changed   boolean := false;
  v_vintage_changed boolean := false;
begin
  v_basis := public._vineyard_local_date(
    new.vineyard_id, coalesce(new.start_time, new.created_at));

  if tg_op = 'UPDATE' then
    v_basis_changed :=
         coalesce(new.start_time, new.created_at)
           is distinct from coalesce(old.start_time, old.created_at)
      or new.vineyard_id is distinct from old.vineyard_id;
    v_vintage_changed := new.vintage is distinct from old.vintage;
    if v_basis_changed and not v_vintage_changed then
      new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
      return new;
    end if;
  end if;

  if new.vintage is null or new.vintage < 2000 or new.vintage > v_max then
    new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
  end if;
  return new;
end;
$fn$;

drop trigger if exists trips_resolve_vintage on public.trips;
create trigger trips_resolve_vintage
  before insert or update on public.trips
  for each row execute function public.trips_resolve_vintage();

-- spray_records -------------------------------------------------------------
create or replace function public.spray_records_resolve_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_basis           date;
  v_max             integer := extract(year from now())::integer + 5;
  v_basis_changed   boolean := false;
  v_vintage_changed boolean := false;
begin
  -- `date` is nullable on this table (sql/007), so the recorded start time and
  -- finally the row's creation instant stand in for it.
  v_basis := public._vineyard_local_date(
    new.vineyard_id, coalesce(new.date, new.start_time, new.created_at));

  if tg_op = 'UPDATE' then
    v_basis_changed :=
         coalesce(new.date, new.start_time, new.created_at)
           is distinct from coalesce(old.date, old.start_time, old.created_at)
      or new.vineyard_id is distinct from old.vineyard_id;
    v_vintage_changed := new.vintage is distinct from old.vintage;
    if v_basis_changed and not v_vintage_changed then
      new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
      return new;
    end if;
  end if;

  if new.vintage is null or new.vintage < 2000 or new.vintage > v_max then
    new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
  end if;
  return new;
end;
$fn$;

drop trigger if exists spray_records_resolve_vintage on public.spray_records;
create trigger spray_records_resolve_vintage
  before insert or update on public.spray_records
  for each row execute function public.spray_records_resolve_vintage();

-- growth_stage_records ------------------------------------------------------
create or replace function public.growth_stage_records_resolve_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_basis           date;
  v_max             integer := extract(year from now())::integer + 5;
  v_basis_changed   boolean := false;
  v_vintage_changed boolean := false;
begin
  v_basis := public._vineyard_local_date(new.vineyard_id, new.observed_at);

  if tg_op = 'UPDATE' then
    v_basis_changed := new.observed_at is distinct from old.observed_at
                    or new.vineyard_id is distinct from old.vineyard_id;
    v_vintage_changed := new.vintage is distinct from old.vintage;
    if v_basis_changed and not v_vintage_changed then
      new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
      return new;
    end if;
  end if;

  if new.vintage is null or new.vintage < 2000 or new.vintage > v_max then
    new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
  end if;
  return new;
end;
$fn$;

drop trigger if exists growth_stage_records_resolve_vintage on public.growth_stage_records;
create trigger growth_stage_records_resolve_vintage
  before insert or update on public.growth_stage_records
  for each row execute function public.growth_stage_records_resolve_vintage();

-- maintenance_logs ----------------------------------------------------------
create or replace function public.maintenance_logs_resolve_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_basis           date;
  v_max             integer := extract(year from now())::integer + 5;
  v_basis_changed   boolean := false;
  v_vintage_changed boolean := false;
begin
  v_basis := public._vineyard_local_date(new.vineyard_id, new.date);

  if tg_op = 'UPDATE' then
    v_basis_changed := new.date is distinct from old.date
                    or new.vineyard_id is distinct from old.vineyard_id;
    v_vintage_changed := new.vintage is distinct from old.vintage;
    if v_basis_changed and not v_vintage_changed then
      new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
      return new;
    end if;
  end if;

  if new.vintage is null or new.vintage < 2000 or new.vintage > v_max then
    new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
  end if;
  return new;
end;
$fn$;

drop trigger if exists maintenance_logs_resolve_vintage on public.maintenance_logs;
create trigger maintenance_logs_resolve_vintage
  before insert or update on public.maintenance_logs
  for each row execute function public.maintenance_logs_resolve_vintage();

-- fuel_purchases ------------------------------------------------------------
create or replace function public.fuel_purchases_resolve_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_basis           date;
  v_max             integer := extract(year from now())::integer + 5;
  v_basis_changed   boolean := false;
  v_vintage_changed boolean := false;
begin
  v_basis := public._vineyard_local_date(new.vineyard_id, new.date);

  if tg_op = 'UPDATE' then
    v_basis_changed := new.date is distinct from old.date
                    or new.vineyard_id is distinct from old.vineyard_id;
    v_vintage_changed := new.vintage is distinct from old.vintage;
    if v_basis_changed and not v_vintage_changed then
      new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
      return new;
    end if;
  end if;

  if new.vintage is null or new.vintage < 2000 or new.vintage > v_max then
    new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
  end if;
  return new;
end;
$fn$;

drop trigger if exists fuel_purchases_resolve_vintage on public.fuel_purchases;
create trigger fuel_purchases_resolve_vintage
  before insert or update on public.fuel_purchases
  for each row execute function public.fuel_purchases_resolve_vintage();

-- tractor_fuel_logs ---------------------------------------------------------
create or replace function public.tractor_fuel_logs_resolve_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_basis           date;
  v_max             integer := extract(year from now())::integer + 5;
  v_basis_changed   boolean := false;
  v_vintage_changed boolean := false;
begin
  v_basis := public._vineyard_local_date(new.vineyard_id, new.fill_datetime);

  if tg_op = 'UPDATE' then
    v_basis_changed := new.fill_datetime is distinct from old.fill_datetime
                    or new.vineyard_id is distinct from old.vineyard_id;
    v_vintage_changed := new.vintage is distinct from old.vintage;
    if v_basis_changed and not v_vintage_changed then
      new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
      return new;
    end if;
  end if;

  if new.vintage is null or new.vintage < 2000 or new.vintage > v_max then
    new.vintage := public.resolve_vineyard_vintage_year(new.vineyard_id, v_basis);
  end if;
  return new;
end;
$fn$;

drop trigger if exists tractor_fuel_logs_resolve_vintage on public.tractor_fuel_logs;
create trigger tractor_fuel_logs_resolve_vintage
  before insert or update on public.tractor_fuel_logs
  for each row execute function public.tractor_fuel_logs_resolve_vintage();

-- fertiliser_records --------------------------------------------------------
-- application_date is already a DATE captured in the vineyard's own calendar,
-- so it is fed to the resolver directly — converting it through a timezone
-- would shift it by a day for vineyards east or west of UTC.
create or replace function public.fertiliser_records_resolve_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_max             integer := extract(year from now())::integer + 5;
  v_basis_changed   boolean := false;
  v_vintage_changed boolean := false;
begin
  if tg_op = 'UPDATE' then
    v_basis_changed := new.application_date is distinct from old.application_date
                    or new.vineyard_id is distinct from old.vineyard_id;
    v_vintage_changed := new.vintage is distinct from old.vintage;
    if v_basis_changed and not v_vintage_changed then
      new.vintage := public.resolve_vineyard_vintage_year(
        new.vineyard_id, new.application_date);
      return new;
    end if;
  end if;

  if new.vintage is null or new.vintage < 2000 or new.vintage > v_max then
    new.vintage := public.resolve_vineyard_vintage_year(
      new.vineyard_id, new.application_date);
  end if;
  return new;
end;
$fn$;

drop trigger if exists fertiliser_records_resolve_vintage on public.fertiliser_records;
create trigger fertiliser_records_resolve_vintage
  before insert or update on public.fertiliser_records
  for each row execute function public.fertiliser_records_resolve_vintage();

-- ---------------------------------------------------------------------------
-- 4. Validation — the migration ABORTS if the shared rule has drifted
-- ---------------------------------------------------------------------------
do $validate$
begin
  -- The 222 helper must agree with the 119 resolver it wraps.
  assert public.resolve_vintage_year(date '2026-06-30', 7, 1) = 2026,
    'SQL 222: 119 resolver changed meaning (30 Jun 2026, 1 Jul start)';
  assert public.resolve_vintage_year(date '2026-07-01', 7, 1) = 2027,
    'SQL 222: 119 resolver changed meaning (1 Jul 2026, 1 Jul start)';

  -- Every column exists.
  assert (select count(*) from information_schema.columns
           where table_schema = 'public'
             and column_name = 'vintage'
             and table_name in ('pins','trips','spray_records','growth_stage_records',
                                'maintenance_logs','fuel_purchases','tractor_fuel_logs',
                                'fertiliser_records')) = 8,
    'SQL 222: expected all eight vintage columns to exist';

  -- Every trigger is installed.
  assert (select count(*) from pg_trigger
           where not tgisinternal
             and tgname in ('pins_resolve_vintage','trips_resolve_vintage',
                            'spray_records_resolve_vintage','growth_stage_records_resolve_vintage',
                            'maintenance_logs_resolve_vintage','fuel_purchases_resolve_vintage',
                            'tractor_fuel_logs_resolve_vintage','fertiliser_records_resolve_vintage')) = 8,
    'SQL 222: expected all eight vintage triggers to exist';

  -- SQL 221's contract must still be intact — this migration never touches it.
  assert (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and p.proname in ('damage_records_resolve_vintage',
                               'yield_estimation_sessions_resolve_vintage',
                               'get_season_yield_base_overview')) >= 3,
    'SQL 222: SQL 221 Yield/Damage objects must still exist';
end
$validate$;

-- ---------------------------------------------------------------------------
-- 5. Backfill existing rows
--
-- ONLY the vintage column is written. Ids, dates, sync fields and
-- client_updated_at are untouched, and updated_at is deliberately NOT bumped
-- so this migration cannot look like a user edit to the sync layer or start a
-- device-wide re-download (same reasoning as sql/221).
-- ---------------------------------------------------------------------------
do $backfill$
declare
  r          record;
  v_sql      text;
  v_before   integer;
  v_after    integer;
  v_specs    text[][] := array[
    ['pins',                 'p.created_at'],
    ['trips',                'coalesce(p.start_time, p.created_at)'],
    ['spray_records',        'coalesce(p.date, p.start_time, p.created_at)'],
    ['growth_stage_records', 'p.observed_at'],
    ['maintenance_logs',     'p.date'],
    ['fuel_purchases',       'p.date'],
    ['tractor_fuel_logs',    'p.fill_datetime']
  ];
  i integer;
begin
  -- timestamptz-based tables share one shaped statement.
  for i in 1 .. array_length(v_specs, 1) loop
    execute format('select count(*) from public.%I where vintage is null', v_specs[i][1])
      into v_before;

    v_sql := format(
      'update public.%I p
          set vintage = public.resolve_vineyard_vintage_year(
                          p.vineyard_id,
                          (%s at time zone coalesce(nullif(v.timezone, ''''), ''UTC''))::date)
         from public.vineyards v
        where v.id = p.vineyard_id
          and p.vintage is null
          and %s is not null',
      v_specs[i][1], v_specs[i][2], v_specs[i][2]);
    execute v_sql;

    execute format('select count(*) from public.%I where vintage is null', v_specs[i][1])
      into v_after;
    raise notice 'SQL 222 · %: % rows needed a vintage, % still null',
      v_specs[i][1], v_before, v_after;
  end loop;

  -- fertiliser_records uses its DATE column directly (no timezone shift).
  select count(*) into v_before from public.fertiliser_records where vintage is null;
  update public.fertiliser_records f
     set vintage = public.resolve_vineyard_vintage_year(f.vineyard_id, f.application_date)
   where f.vintage is null
     and f.application_date is not null;
  select count(*) into v_after from public.fertiliser_records where vintage is null;
  raise notice 'SQL 222 · fertiliser_records: % rows needed a vintage, % still null',
    v_before, v_after;
end
$backfill$;

-- ---------------------------------------------------------------------------
-- 6. Tighten to NOT NULL only where the backfill genuinely left nothing
--
-- A row whose event date is itself null (possible on spray_records, whose
-- `date` has always been nullable) keeps a null vintage rather than being
-- forced into a wrong season. Those tables simply stay nullable.
-- ---------------------------------------------------------------------------
do $tighten$
declare
  t text;
  v_remaining integer;
begin
  foreach t in array array['pins','trips','spray_records','growth_stage_records',
                           'maintenance_logs','fuel_purchases','tractor_fuel_logs',
                           'fertiliser_records']
  loop
    execute format('select count(*) from public.%I where vintage is null', t)
      into v_remaining;
    if v_remaining > 0 then
      raise notice 'SQL 222 · %.vintage LEFT NULLABLE — % rows unresolved', t, v_remaining;
    else
      begin
        execute format('alter table public.%I alter column vintage set not null', t);
        raise notice 'SQL 222 · %.vintage set NOT NULL', t;
      exception when others then
        raise notice 'SQL 222 · %.vintage NOT NULL skipped: %', t, sqlerrm;
      end;
    end if;
  end loop;
end
$tighten$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 7. Verification (run manually; read-only)
-- ---------------------------------------------------------------------------
-- Distribution per table for one vineyard:
-- select 'pins' as source, vintage, count(*) from public.pins
--   where vineyard_id = '...' and deleted_at is null group by vintage
-- union all
-- select 'spray_records', vintage, count(*) from public.spray_records
--   where vineyard_id = '...' and deleted_at is null group by vintage
-- order by 1, 2;
--
-- Rows that could not be resolved (expected only where the event date is null):
-- select id, date, start_time, created_at from public.spray_records
--  where vintage is null and deleted_at is null limit 20;

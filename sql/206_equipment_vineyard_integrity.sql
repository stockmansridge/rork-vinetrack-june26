-- =============================================================================
-- 206: EQUIPMENT / VINEYARD INTEGRITY — audit + prevention. NO data migration.
--
-- Companion to the iOS vineyard-isolation fix (scoped equipment accessors,
-- re-scoping on vineyard switch, authoritative full-pull reconciliation).
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- ---------------------------------------------------------------------------
-- The equipment model is transitional on purpose: legacy `public.tractors`,
-- canonical `public.vineyard_machines`, the `legacy_tractor_id` bridge, and
-- historical tables carrying `tractor_id`, `machine_id`, or both. That model is
-- still load-bearing — `trips.tractor_id` drives trip costing (sql/057),
-- `tractor_fuel_logs.tractor_id` is the legacy fuel link (sql/092),
-- `spray_records`, `spray_jobs`, `maintenance_logs` and `equipment_items` all
-- resolve through it, and so do several iOS paths. Retiring it now would break
-- history for no user-visible gain.
--
-- So this migration creates NO column, migrates NO row, deletes NO tractor,
-- nulls NO historical reference, converts NO Trip / Spray Job / Fuel Log, and
-- creates NO machine row. Nothing here can duplicate a JH Testing or Stockmans
-- record, because nothing here inserts.
--
-- ---------------------------------------------------------------------------
-- WHAT IT DOES
-- ---------------------------------------------------------------------------
-- 1. `public.vt_equipment_integrity_report()` — a read-only, auditable report
--    of every cross-vineyard or logically inconsistent equipment link. This is
--    how a defect gets PROVEN before anyone repairs data. Run it, read it,
--    then decide. It mutates nothing and is safe to run on production.
--
-- 2. Two prevention guards that stop NEW cross-vineyard links being written:
--      * `vineyard_machines.legacy_tractor_id` must point at a tractor in the
--        SAME vineyard as the machine.
--      * `tractor_fuel_logs.machine_id` / `.tractor_id` must point at
--        equipment in the SAME vineyard as the log.
--
--    Both guards fire ONLY when the referencing column is actually being set
--    or changed (or on INSERT). A row that is already inconsistent can still be
--    read, still be soft-deleted, and still have its other columns updated —
--    the guard adds no new way for existing production data to become
--    un-editable, and no historical reference stops resolving.
--
-- 3. No repair statements are executed. If the report returns a non-zero count
--    the correction is a separate, deliberate action — see the block at the end
--    of this file for the exact, idempotent statement to run under review.
--
-- Depends on: sql/011 (tractors), sql/092 (tractor_fuel_logs),
--             sql/097 (vineyard_machines, legacy_tractor_id, machine_id).
-- =============================================================================

begin;

-- Refuse to run against a schema that predates the model being audited: a
-- report that silently checks nothing is worse than no report.
do $$
begin
  if to_regclass('public.tractors') is null then
    raise exception 'sql/011 not applied — public.tractors is missing.';
  end if;
  if to_regclass('public.vineyard_machines') is null then
    raise exception 'sql/097 not applied — public.vineyard_machines is missing.';
  end if;
  if to_regclass('public.tractor_fuel_logs') is null then
    raise exception 'sql/092 not applied — public.tractor_fuel_logs is missing.';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'vineyard_machines'
       and column_name = 'legacy_tractor_id'
  ) then
    raise exception 'sql/097 not applied — vineyard_machines.legacy_tractor_id is missing.';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'tractor_fuel_logs'
       and column_name = 'machine_id'
  ) then
    raise exception 'sql/097 not applied — tractor_fuel_logs.machine_id is missing.';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- 1. The audit report.
--
-- SECURITY DEFINER with a pinned search_path: every table it reads is
-- RLS-protected, and an integrity audit that can only see one vineyard cannot
-- detect a CROSS-vineyard link by construction — the same class of blindness
-- sql/197 repaired. Execute is granted to service_role only; this is an
-- operator tool, not an app surface, and it deliberately returns ids from
-- vineyards the caller may not be a member of.
--
-- Read-only by construction: the body is a single SELECT-only UNION.
-- ---------------------------------------------------------------------------
create or replace function public.vt_equipment_integrity_report()
returns table (
  check_name       text,
  severity         text,
  offending_count  bigint,
  sample_ids       uuid[]
)
language sql
stable
security definer
set search_path = public
as $$
  -- C1. An ACTIVE machine whose legacy tractor lives in another vineyard.
  --     This is the link that lets a Fuel Log or Trip in vineyard B resolve
  --     equipment owned by vineyard A.
  select
    'machine_legacy_tractor_cross_vineyard'::text,
    'error'::text,
    count(*)::bigint,
    (array_agg(m.id order by m.id))[1:20]
  from public.vineyard_machines m
  join public.tractors t on t.id = m.legacy_tractor_id
  where m.deleted_at is null
    and t.vineyard_id is distinct from m.vineyard_id

  union all
  -- C2. An ACTIVE machine pointing at a tractor row that no longer exists.
  --     Not an error on its own (the FK is ON DELETE SET NULL, so this can
  --     only happen through a direct write), but it means the legacy grouping
  --     for that machine's fuel logs is dangling.
  select
    'machine_legacy_tractor_missing'::text,
    'warning'::text,
    count(*)::bigint,
    (array_agg(m.id order by m.id))[1:20]
  from public.vineyard_machines m
  where m.deleted_at is null
    and m.legacy_tractor_id is not null
    and not exists (select 1 from public.tractors t where t.id = m.legacy_tractor_id)

  union all
  -- C3. Two or more ACTIVE machines claiming the same legacy tractor. The
  --     sql/097 backfill creates exactly one, so a duplicate means a second
  --     backfill ran against a differently-shaped row set. Reported, never
  --     auto-merged: choosing which machine's fuel history survives is a
  --     commercial decision, not a migration's.
  select
    'duplicate_active_machines_per_legacy_tractor'::text,
    'error'::text,
    count(*)::bigint,
    (array_agg(d.legacy_tractor_id order by d.legacy_tractor_id))[1:20]
  from (
    select m.legacy_tractor_id
    from public.vineyard_machines m
    where m.deleted_at is null
      and m.legacy_tractor_id is not null
    group by m.legacy_tractor_id
    having count(*) > 1
  ) d

  union all
  -- C4. A fuel log whose machine belongs to a different vineyard than the log.
  select
    'fuel_log_machine_cross_vineyard'::text,
    'error'::text,
    count(*)::bigint,
    (array_agg(f.id order by f.id))[1:20]
  from public.tractor_fuel_logs f
  join public.vineyard_machines m on m.id = f.machine_id
  where f.deleted_at is null
    and m.vineyard_id is distinct from f.vineyard_id

  union all
  -- C5. A fuel log whose legacy tractor belongs to a different vineyard.
  select
    'fuel_log_tractor_cross_vineyard'::text,
    'error'::text,
    count(*)::bigint,
    (array_agg(f.id order by f.id))[1:20]
  from public.tractor_fuel_logs f
  join public.tractors t on t.id = f.tractor_id
  where f.deleted_at is null
    and t.vineyard_id is distinct from f.vineyard_id

  union all
  -- C6. A fuel log carrying BOTH links, where they disagree about which
  --     physical machine was filled. Warning, not error: a native machine may
  --     legitimately carry a stale legacy tractor_id from an earlier edit, and
  --     both ids still resolve inside the log's own vineyard. Flagged so the
  --     L/hr grouping can be reviewed, never rewritten automatically.
  select
    'fuel_log_machine_tractor_disagree'::text,
    'warning'::text,
    count(*)::bigint,
    (array_agg(f.id order by f.id))[1:20]
  from public.tractor_fuel_logs f
  join public.vineyard_machines m on m.id = f.machine_id
  where f.deleted_at is null
    and f.tractor_id is not null
    and m.legacy_tractor_id is distinct from f.tractor_id

  union all
  -- C7. A trip whose machine belongs to a different vineyard than the trip.
  --     Read-only: trips.machine_id (sql/098) feeds costing.
  select
    'trip_machine_cross_vineyard'::text,
    'error'::text,
    count(*)::bigint,
    (array_agg(tr.id order by tr.id))[1:20]
  from public.trips tr
  join public.vineyard_machines m on m.id = tr.machine_id
  where m.vineyard_id is distinct from tr.vineyard_id

  union all
  -- C8. A trip whose legacy tractor belongs to a different vineyard.
  select
    'trip_tractor_cross_vineyard'::text,
    'error'::text,
    count(*)::bigint,
    (array_agg(tr.id order by tr.id))[1:20]
  from public.trips tr
  join public.tractors t on t.id = tr.tractor_id
  where t.vineyard_id is distinct from tr.vineyard_id
$$;

comment on function public.vt_equipment_integrity_report() is
  'Read-only cross-vineyard integrity audit for tractors / vineyard_machines / tractor_fuel_logs / trips (sql/206). Returns one row per check with a count and up to 20 sample ids. SECURITY DEFINER because every source table is RLS-protected and a cross-vineyard defect is undetectable from inside one vineyard. Mutates nothing; service_role only.';

revoke all on function public.vt_equipment_integrity_report() from public;
grant execute on function public.vt_equipment_integrity_report() to service_role;

-- ---------------------------------------------------------------------------
-- 2a. Prevention: a machine's legacy tractor must live in the same vineyard.
--
-- Fires on INSERT, and on UPDATE only when `legacy_tractor_id` or
-- `vineyard_id` actually changes. That restraint is the whole safety story:
-- an already-inconsistent production row keeps working — it can be read, soft
-- deleted, renamed, re-rated, and synced — so this guard can never strand
-- existing data or break a historical reference. It only refuses to create a
-- NEW cross-vineyard link.
--
-- SECURITY DEFINER for the sql/197 reason: `tractors` is RLS-protected, and
-- under caller rights the lookup would return zero rows for a vineyard the
-- caller is not a member of, silently ACCEPTING exactly the write it exists to
-- refuse.
-- ---------------------------------------------------------------------------
create or replace function public.vineyard_machines_validate_legacy_tractor()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tractor_vineyard uuid;
begin
  if new.legacy_tractor_id is null then
    return new;
  end if;

  select t.vineyard_id
    into v_tractor_vineyard
    from public.tractors t
   where t.id = new.legacy_tractor_id;

  -- A missing tractor row is NOT rejected. The FK is ON DELETE SET NULL, and
  -- turning this into an existence check would make the guard a second foreign
  -- key that could block legitimate writes during a delete race.
  if v_tractor_vineyard is null then
    return new;
  end if;

  if v_tractor_vineyard is distinct from new.vineyard_id then
    raise exception
      'vineyard_machines.legacy_tractor_id % belongs to a different vineyard than the machine',
      new.legacy_tractor_id
      using errcode = '23514';
  end if;

  return new;
end$$;

comment on function public.vineyard_machines_validate_legacy_tractor() is
  'Refuses a NEW cross-vineyard vineyard_machines.legacy_tractor_id link (sql/206). Only evaluated when legacy_tractor_id or vineyard_id changes, so pre-existing inconsistent rows stay fully editable and historical references keep resolving. A legacy_tractor_id matching no tractor row is allowed — this is a vineyard check, not a foreign key.';

drop trigger if exists trg_vineyard_machines_validate_legacy_tractor on public.vineyard_machines;
create trigger trg_vineyard_machines_validate_legacy_tractor
before insert or update of legacy_tractor_id, vineyard_id on public.vineyard_machines
for each row
execute function public.vineyard_machines_validate_legacy_tractor();

-- ---------------------------------------------------------------------------
-- 2b. Prevention: a fuel log's equipment must live in the log's vineyard.
--
-- Same restraint: INSERT, or UPDATE of the referencing columns only. This is
-- the server-side mirror of the iOS fix that stopped `legacyTractorId` being
-- resolved without a vineyard filter in the Fuel Log form.
-- ---------------------------------------------------------------------------
create or replace function public.tractor_fuel_logs_validate_equipment_vineyard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vineyard uuid;
begin
  if new.machine_id is not null then
    select m.vineyard_id into v_vineyard
      from public.vineyard_machines m
     where m.id = new.machine_id;

    if v_vineyard is not null and v_vineyard is distinct from new.vineyard_id then
      raise exception
        'tractor_fuel_logs.machine_id % belongs to a different vineyard than the fuel log',
        new.machine_id
        using errcode = '23514';
    end if;
  end if;

  if new.tractor_id is not null then
    select t.vineyard_id into v_vineyard
      from public.tractors t
     where t.id = new.tractor_id;

    if v_vineyard is not null and v_vineyard is distinct from new.vineyard_id then
      raise exception
        'tractor_fuel_logs.tractor_id % belongs to a different vineyard than the fuel log',
        new.tractor_id
        using errcode = '23514';
    end if;
  end if;

  return new;
end$$;

comment on function public.tractor_fuel_logs_validate_equipment_vineyard() is
  'Refuses a NEW cross-vineyard tractor_fuel_logs.machine_id / .tractor_id link (sql/206). Only evaluated when those columns or vineyard_id change, so existing rows stay editable. Both links may still be present together and may still disagree about which machine was filled — that is a reportable warning (see vt_equipment_integrity_report C6), not a write error, because legacy rows legitimately carry both.';

drop trigger if exists trg_tractor_fuel_logs_validate_equipment_vineyard on public.tractor_fuel_logs;
create trigger trg_tractor_fuel_logs_validate_equipment_vineyard
before insert or update of machine_id, tractor_id, vineyard_id on public.tractor_fuel_logs
for each row
execute function public.tractor_fuel_logs_validate_equipment_vineyard();

-- ---------------------------------------------------------------------------
-- 3. Prove the postcondition inside the same transaction that created it.
-- ---------------------------------------------------------------------------
do $$
declare
  v_missing text;
begin
  select string_agg(x, ', ')
    into v_missing
    from (
      select 'vt_equipment_integrity_report' as x
       where to_regprocedure('public.vt_equipment_integrity_report()') is null
      union all
      select 'trg_vineyard_machines_validate_legacy_tractor'
       where not exists (
         select 1 from pg_trigger
          where tgrelid = 'public.vineyard_machines'::regclass
            and tgname = 'trg_vineyard_machines_validate_legacy_tractor'
            and not tgisinternal)
      union all
      select 'trg_tractor_fuel_logs_validate_equipment_vineyard'
       where not exists (
         select 1 from pg_trigger
          where tgrelid = 'public.tractor_fuel_logs'::regclass
            and tgname = 'trg_tractor_fuel_logs_validate_equipment_vineyard'
            and not tgisinternal)
    ) s;

  if v_missing is not null then
    raise exception 'SQL 206 FAILED: missing objects: %', v_missing;
  end if;

  raise notice 'SQL 206: equipment integrity report + two vineyard guards installed. No data was migrated.';
end$$;

commit;

-- =============================================================================
-- AFTER APPLYING
--
-- 1. Run the audit (as service_role / owner, outside any transaction):
--
--      select * from public.vt_equipment_integrity_report();
--
--    Expected on healthy data: every `offending_count` is 0.
--
-- 2. If — and only if — C1 returns a non-zero count, the correction below is
--    the narrowly targeted, idempotent repair. It is NOT run automatically and
--    is NOT part of this migration:
--
--      -- Detach ONLY the cross-vineyard legacy links. Nothing is deleted; the
--      -- machine, the tractor, and every fuel log / trip that references
--      -- either of them are untouched and keep resolving.
--      update public.vineyard_machines m
--         set legacy_tractor_id = null,
--             updated_at = now()
--        from public.tractors t
--       where t.id = m.legacy_tractor_id
--         and m.deleted_at is null
--         and t.vineyard_id is distinct from m.vineyard_id;
--
--    Re-running it is a no-op once the report is clean, which is what makes it
--    idempotent. Take a count before and after and record both.
--
-- 3. Deliberately NOT included, and to be handled as separate decisions:
--      * the Stockmans `fuel_usage_l_per_hour = 1.20361083249749` value. We know
--        how it was produced (a fill-to-fill L/hr written straight into the
--        configured rate) and the code path is now guarded, but correcting live
--        production data is its own reviewed action, not an app release.
--      * merging duplicate machines reported by C3.
--      * any retirement of the legacy tractor architecture.
--
-- 4. No redeploy of supabase/functions/* and no client change is required:
--    no column, view or API-visible field changed.
--
-- ROLLBACK (guards only; the report is inert and can be left in place):
--   begin;
--     drop trigger if exists trg_vineyard_machines_validate_legacy_tractor on public.vineyard_machines;
--     drop trigger if exists trg_tractor_fuel_logs_validate_equipment_vineyard on public.tractor_fuel_logs;
--   commit;
-- END 206
-- =============================================================================

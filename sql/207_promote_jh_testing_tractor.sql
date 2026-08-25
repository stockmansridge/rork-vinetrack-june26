-- =============================================================================
-- 207: Promote the JH Testing "new holand t4.85n" machine into a real tractor,
--      and extend the equipment integrity report with a native-orphan check.
--
-- Companion to the iOS change that removes Tractor from the Vineyard Machines
-- creation picker. sql/206 stopped NEW cross-vineyard links; this file repairs
-- ONE known record that predates the tightened UI, and adds the check that
-- finds any others.
--
-- ---------------------------------------------------------------------------
-- THE DEFECT BEING REPAIRED (a proven one, not a tidy-up)
-- ---------------------------------------------------------------------------
-- vineyard_machines 70861e55-2f9c-4a1a-af52-e1a8fe8bffe5 in JH Testing is a
-- real tractor, but it was created through the Vineyard Machines path, so:
--     machine_type      = 'tractor'
--     legacy_tractor_id = null
-- and JH Testing has NO row in public.tractors at all. The consequence is
-- user-visible: the tractor does not appear under Manage Tractors, and it
-- cannot take part in the legacy `trips.tractor_id` costing path that every
-- other tractor uses.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES *NOT* DO
-- ---------------------------------------------------------------------------
--   * It does NOT delete or recreate the machine. The existing machine id is
--     preserved exactly, so every Fuel Log, Trip and costing row that already
--     references it keeps resolving.
--   * It does NOT create a second vineyard_machines row.
--   * It does NOT rewrite historical rows. The existing JH fuel log keeps its
--     machine_id and its null tractor_id. Back-filling tractor_id would be a
--     rewrite of history for no proven requirement — the machine link is the
--     canonical one and it is unchanged.
--   * It does NOT invent a fuel consumption figure. The machine records 0
--     ("not set"), so the tractor is created with 0 and stays honestly
--     unknown. The iOS Tractor form was changed in the same release to let a
--     tractor with no known rate be saved and edited without fabricating one.
--   * It does NOT touch Stockmans Ridge, or any vineyard other than JH
--     Testing. Every statement is filtered by explicit primary keys.
--   * It does NOT convert any other native tractor-machine. Those are only
--     REPORTED (check C9) for review.
--
-- Depends on: sql/011 (tractors), sql/092 (tractor_fuel_logs),
--             sql/097 (vineyard_machines), sql/105 (serial/vin), sql/206.
-- =============================================================================

begin;

do $$
begin
  if to_regprocedure('public.vt_equipment_integrity_report()') is null then
    raise exception 'sql/206 not applied — run sql/206_equipment_vineyard_integrity.sql first.';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- 1. Extend the audit: native tractor-typed machines with no backing tractor.
--
-- This REPLACES the sql/206 definition and is now the single source of truth
-- for the report. It adds C9 and leaves C1–C8 byte-identical.
--
-- WARNING severity, deliberately. Such a row is not corrupt — it reads and
-- syncs perfectly well — it is mis-classified. Historical/native records like
-- this may legitimately exist, and deciding whether one is really a tractor is
-- a judgement about a physical asset that only the grower can make. So it is
-- surfaced for review and never auto-converted.
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
  -- C2. CANARY for vineyard_machines_legacy_tractor_id_fkey (sql/097).
  --     Structurally impossible while that FK exists; a non-zero count means
  --     it was dropped, and C1 can no longer be trusted either.
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
  -- C3. CANARY for uq_vineyard_machines_legacy_tractor (sql/097). Reported,
  --     never auto-merged: choosing which machine's fuel history survives is
  --     a commercial decision, not a migration's.
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
  --     physical machine was filled. Warning: both ids still resolve inside
  --     the log's own vineyard.
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

  union all
  -- C9 (sql/207). An ACTIVE tractor-typed machine with no backing tractor row.
  --     The asset is a tractor to the user but is invisible under Tractors and
  --     unavailable to legacy trip costing. Warning, and reviewed one by one:
  --     only the grower knows whether the physical asset is really a tractor.
  select
    'native_tractor_machine_unlinked'::text,
    'warning'::text,
    count(*)::bigint,
    (array_agg(m.id order by m.id))[1:20]
  from public.vineyard_machines m
  where m.deleted_at is null
    and m.machine_type = 'tractor'
    and m.legacy_tractor_id is null
$$;

comment on function public.vt_equipment_integrity_report() is
  'Read-only cross-vineyard integrity audit for tractors / vineyard_machines / tractor_fuel_logs / trips (sql/206, extended by sql/207 with C9 native_tractor_machine_unlinked). Returns one row per check with a count and up to 20 sample ids. SECURITY DEFINER because every source table is RLS-protected and a cross-vineyard defect is undetectable from inside one vineyard. Mutates nothing; service_role only.';

revoke all on function public.vt_equipment_integrity_report() from public;
grant execute on function public.vt_equipment_integrity_report() to service_role;

-- ---------------------------------------------------------------------------
-- 2. The JH Testing promotion.
--
-- Idempotent by construction, in three ways:
--   * it exits early once the machine has ANY legacy_tractor_id;
--   * it adopts an existing matching JH tractor rather than adding a second;
--   * the new tractor uses a FIXED id, so a re-run cannot mint another.
-- ---------------------------------------------------------------------------
do $$
declare
  -- Deterministic id for the promoted tractor. Fixed (not gen_random_uuid())
  -- so this migration is exactly reproducible and a second run cannot create
  -- a second tractor even if the guards above were somehow bypassed.
  c_tractor_id  constant uuid := '207e0001-2f9c-4a1a-af52-e1a8fe8bffe5';
  c_vineyard_id constant uuid := '59973ced-1fb9-42ec-a66d-9eaad3172824';
  c_machine_id  constant uuid := '70861e55-2f9c-4a1a-af52-e1a8fe8bffe5';
  c_brand       constant text := 'New Holland';
  c_model       constant text := 'T4.85N';
  c_name        constant text := 'New Holland T4.85N';

  v_machine            public.vineyard_machines%rowtype;
  v_tractor_id         uuid;
  v_tractors_before    bigint;
  v_tractors_after     bigint;
  v_machines_before    bigint;
  v_machines_after     bigint;
  v_fuel_logs_before   bigint;
  v_fuel_logs_after    bigint;
  v_other_vineyards    bigint;
begin
  select count(*) into v_tractors_before  from public.tractors;
  select count(*) into v_machines_before  from public.vineyard_machines;
  select count(*) into v_fuel_logs_before
    from public.tractor_fuel_logs where machine_id = c_machine_id;

  select * into v_machine
    from public.vineyard_machines
   where id = c_machine_id;

  -- Not this database (a fork, a fresh environment, a restored subset).
  -- Skip quietly: a repair for a row that does not exist is not a failure.
  if not found then
    raise notice 'sql/207: machine % not present — nothing to promote.', c_machine_id;
    return;
  end if;

  -- Refuse to act on a row that is not the one this migration was written
  -- for. Being wrong about the target is the only way this file could damage
  -- data, so it is checked rather than assumed.
  if v_machine.vineyard_id is distinct from c_vineyard_id then
    raise exception
      'sql/207 ABORTED: machine % belongs to vineyard %, expected JH Testing %.',
      c_machine_id, v_machine.vineyard_id, c_vineyard_id;
  end if;

  if v_machine.legacy_tractor_id is not null then
    raise notice
      'sql/207: machine % is already linked to tractor % — no change.',
      c_machine_id, v_machine.legacy_tractor_id;
    return;
  end if;

  if v_machine.deleted_at is not null then
    raise notice
      'sql/207: machine % is archived — leaving it alone.', c_machine_id;
    return;
  end if;

  if v_machine.machine_type is distinct from 'tractor' then
    raise notice
      'sql/207: machine % is typed % , not tractor — leaving it alone.',
      c_machine_id, v_machine.machine_type;
    return;
  end if;

  -- Adopt an equivalent tractor if one already exists in JH Testing (for
  -- example the grower added it by hand before this migration ran), so the
  -- promotion can never produce two tractors for one physical machine.
  select t.id into v_tractor_id
    from public.tractors t
   where t.vineyard_id = c_vineyard_id
     and t.deleted_at is null
     and (
       t.id = c_tractor_id
       or (lower(trim(t.brand)) = lower(c_brand) and lower(trim(t.model)) = lower(c_model))
       or lower(trim(t.name)) = lower(c_name)
     )
   order by (t.id = c_tractor_id) desc, t.created_at
   limit 1;

  if v_tractor_id is null then
    insert into public.tractors (
      id, vineyard_id, name, brand, model, model_year,
      -- 0 means "not set" to both the app and the costing path. The machine
      -- records 0, so the tractor records 0. No figure is invented here.
      fuel_usage_l_per_hour,
      serial_number, vin_number,
      created_by, updated_by
    )
    values (
      c_tractor_id, c_vineyard_id, c_name, c_brand, c_model, null,
      coalesce(v_machine.fuel_usage_l_per_hour, 0),
      v_machine.serial_number, v_machine.vin_number,
      v_machine.created_by, v_machine.updated_by
    );
    v_tractor_id := c_tractor_id;
    raise notice 'sql/207: created tractor % (% %) for JH Testing.',
      v_tractor_id, c_brand, c_model;
  else
    raise notice 'sql/207: adopting existing JH Testing tractor %.', v_tractor_id;
  end if;

  -- Link the EXISTING machine. The id, and therefore every Fuel Log / Trip /
  -- costing reference to it, is untouched. This UPDATE is also validated by
  -- the sql/206 guard, which proves the new link is same-vineyard.
  update public.vineyard_machines
     set legacy_tractor_id = v_tractor_id,
         machine_type      = 'tractor',
         updated_at        = now()
   where id = c_machine_id
     and legacy_tractor_id is null;

  -- ---- postconditions, inside the same transaction ------------------------
  select count(*) into v_tractors_after  from public.tractors;
  select count(*) into v_machines_after  from public.vineyard_machines;
  select count(*) into v_fuel_logs_after
    from public.tractor_fuel_logs where machine_id = c_machine_id;

  if v_tractors_after > v_tractors_before + 1 then
    raise exception 'sql/207 FAILED: created % tractors, expected at most 1.',
      v_tractors_after - v_tractors_before;
  end if;

  if v_machines_after <> v_machines_before then
    raise exception 'sql/207 FAILED: the machine count changed (% -> %).',
      v_machines_before, v_machines_after;
  end if;

  if v_fuel_logs_after <> v_fuel_logs_before then
    raise exception 'sql/207 FAILED: fuel logs referencing machine % changed (% -> %).',
      c_machine_id, v_fuel_logs_before, v_fuel_logs_after;
  end if;

  if not exists (
    select 1 from public.vineyard_machines
     where id = c_machine_id
       and legacy_tractor_id = v_tractor_id
       and machine_type = 'tractor'
       and deleted_at is null
  ) then
    raise exception 'sql/207 FAILED: machine % was not linked to tractor %.',
      c_machine_id, v_tractor_id;
  end if;

  -- Nothing outside JH Testing may have been touched.
  select count(*) into v_other_vineyards
    from public.tractors
   where id = v_tractor_id
     and vineyard_id is distinct from c_vineyard_id;
  if v_other_vineyards <> 0 then
    raise exception 'sql/207 FAILED: the promoted tractor is not in JH Testing.';
  end if;

  raise notice
    'sql/207: JH Testing machine % promoted — tractor %, fuel rate % L/hr (0 = not set). Fuel logs untouched (%).',
    c_machine_id, v_tractor_id, coalesce(v_machine.fuel_usage_l_per_hour, 0), v_fuel_logs_after;
end$$;

-- ---------------------------------------------------------------------------
-- 3. Prove the report gained its new check.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from public.vt_equipment_integrity_report()
     where check_name = 'native_tractor_machine_unlinked'
  ) then
    raise exception 'sql/207 FAILED: check C9 is missing from the report.';
  end if;
  raise notice 'sql/207: applied.';
end$$;

commit;

-- =============================================================================
-- AFTER APPLYING
--
-- 1. Confirm the JH promotion:
--
--      select m.id as machine_id, m.name, m.machine_type, m.legacy_tractor_id,
--             t.name as tractor_name, t.brand, t.model, t.fuel_usage_l_per_hour
--        from public.vineyard_machines m
--        left join public.tractors t on t.id = m.legacy_tractor_id
--       where m.id = '70861e55-2f9c-4a1a-af52-e1a8fe8bffe5';
--
--    Expected: one row, legacy_tractor_id set, machine id unchanged.
--
-- 2. Confirm the fuel log was NOT rewritten:
--
--      select id, machine_id, tractor_id, litres_added, engine_hours
--        from public.tractor_fuel_logs
--       where machine_id = '70861e55-2f9c-4a1a-af52-e1a8fe8bffe5';
--
--    Expected: same rows, same machine_id, tractor_id still null.
--
-- 3. Find any OTHER native tractor-machines, and review them individually —
--    do not convert them in bulk:
--
--      select m.id, v.name as vineyard, m.name, m.fuel_usage_l_per_hour,
--             (select count(*) from public.tractor_fuel_logs f
--               where f.machine_id = m.id and f.deleted_at is null) as fuel_logs
--        from public.vineyard_machines m
--        join public.vineyards v on v.id = m.vineyard_id
--       where m.deleted_at is null
--         and m.machine_type = 'tractor'
--         and m.legacy_tractor_id is null
--       order by v.name, m.name;
--
-- 4. Re-run the full audit; C1–C8 should be 0 and C9 should have dropped by
--    one (JH Testing no longer appears):
--
--      select * from public.vt_equipment_integrity_report();
--
-- NOTE ON sql/206: this file redefines vt_equipment_integrity_report(). If
-- sql/206 is ever re-run on its own it will revert the function to the 8-check
-- version and silently drop C9 — re-run sql/207 immediately afterwards.
--
-- ROLLBACK (undoes the promotion; the machine id and all history are
-- unaffected either way):
--   begin;
--     update public.vineyard_machines
--        set legacy_tractor_id = null
--      where id = '70861e55-2f9c-4a1a-af52-e1a8fe8bffe5';
--     delete from public.tractors
--      where id = '207e0001-2f9c-4a1a-af52-e1a8fe8bffe5';
--   commit;
-- END 207
-- =============================================================================

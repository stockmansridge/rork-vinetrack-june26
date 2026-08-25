-- =============================================================================
-- 208: Promote the campesi "Kubota M092-N" machine into a real tractor.
--
-- The second and final active native tractor-machine identified by check C9
-- (`native_tractor_machine_unlinked`, added in sql/207). Same defect, same
-- repair shape as the JH Testing promotion — a real tractor that was created
-- through the Vineyard Machines path, so it has:
--     machine_type      = 'tractor'
--     legacy_tractor_id = null
-- and campesi has NO row in public.tractors at all. The consequence is
-- user-visible: the tractor is missing from Manage Tractors and cannot take
-- part in the legacy `trips.tractor_id` costing path.
--
-- ---------------------------------------------------------------------------
-- AUDITED DEPENDENCIES (all zero — this asset has no history yet)
-- ---------------------------------------------------------------------------
--   trips by machine_id           : 0
--   tractor_fuel_logs by machine_id: 0
--   spray_records by machine_id   : 0
--   campesi tractors              : 0
--
-- Zero dependencies make this the LOWEST-risk promotion possible, but the
-- migration still preserves the machine id rather than recreating the row.
-- A count audited at one moment is not a guarantee: a fuel log could be
-- written between the audit and the migration, and delete/recreate would
-- orphan it. Preserving the id is correct regardless of the counts.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES *NOT* DO
-- ---------------------------------------------------------------------------
--   * No delete/recreate. The machine id 1fd13cc9-… is preserved exactly.
--   * No second vineyard_machines row.
--   * No historical rewrite. Nothing sets tractor_id on any existing row.
--   * No invented data. Year, and any serial/VIN not already on the machine,
--     stay null. The 7.5 L/hr rate is carried across unchanged.
--   * No change to JH Testing (sql/207) or Stockmans Ridge. Every statement is
--     filtered by explicit primary keys.
--   * No change to vt_equipment_integrity_report() — sql/207 owns that
--     function. This file only reads it.
--
-- Depends on: sql/011 (tractors), sql/097 (vineyard_machines), sql/105
--             (serial/vin), sql/206 (guards), sql/207 (C9 + JH promotion).
-- =============================================================================

begin;

do $$
begin
  if to_regprocedure('public.vt_equipment_integrity_report()') is null then
    raise exception 'sql/206 not applied — run sql/206_equipment_vineyard_integrity.sql first.';
  end if;
  if not exists (
    select 1 from public.vt_equipment_integrity_report()
     where check_name = 'native_tractor_machine_unlinked'
  ) then
    raise exception
      'sql/207 not applied (or sql/206 was re-run after it) — C9 is missing. Run sql/207 first.';
  end if;
end$$;

do $$
declare
  -- Deterministic id, following the sql/207 pattern: the migration number as
  -- the leading group, then the tail of the machine id. Fixed rather than
  -- gen_random_uuid() so the migration is exactly reproducible and a second
  -- run cannot mint a second tractor even if the guards below were bypassed.
  c_tractor_id  constant uuid := '208e0001-7fee-42d1-8ff6-e8179a5e10a7';
  c_vineyard_id constant uuid := '3d43e144-fba8-4b05-9c22-c36548023935';
  c_machine_id  constant uuid := '1fd13cc9-7fee-42d1-8ff6-e8179a5e10a7';
  c_brand       constant text := 'Kubota';
  c_model       constant text := 'M092-N';
  c_name        constant text := 'Kubota M092-N';

  v_machine          public.vineyard_machines%rowtype;
  v_tractor_id       uuid;
  v_tractors_before  bigint;
  v_tractors_after   bigint;
  v_machines_before  bigint;
  v_machines_after   bigint;
  v_trips_before     bigint;
  v_trips_after      bigint;
  v_logs_before      bigint;
  v_logs_after       bigint;
  v_rate             double precision;
begin
  select count(*) into v_tractors_before from public.tractors;
  select count(*) into v_machines_before from public.vineyard_machines;
  select count(*) into v_trips_before from public.trips where machine_id = c_machine_id;
  select count(*) into v_logs_before  from public.tractor_fuel_logs where machine_id = c_machine_id;

  select * into v_machine from public.vineyard_machines where id = c_machine_id;

  -- Not this database (a fork, a fresh environment, a restored subset).
  -- Skip quietly: a repair for a row that does not exist is not a failure.
  if not found then
    raise notice 'sql/208: machine % not present — nothing to promote.', c_machine_id;
    return;
  end if;

  -- Being wrong about the target is the only way this file could damage data,
  -- so it is checked rather than assumed.
  if v_machine.vineyard_id is distinct from c_vineyard_id then
    raise exception
      'sql/208 ABORTED: machine % belongs to vineyard %, expected campesi %.',
      c_machine_id, v_machine.vineyard_id, c_vineyard_id;
  end if;

  if v_machine.legacy_tractor_id is not null then
    raise notice 'sql/208: machine % is already linked to tractor % — no change.',
      c_machine_id, v_machine.legacy_tractor_id;
    return;
  end if;

  if v_machine.deleted_at is not null then
    raise notice 'sql/208: machine % is archived — leaving it alone.', c_machine_id;
    return;
  end if;

  if v_machine.machine_type is distinct from 'tractor' then
    raise notice 'sql/208: machine % is typed %, not tractor — leaving it alone.',
      c_machine_id, v_machine.machine_type;
    return;
  end if;

  -- Adopt an equivalent campesi tractor if one has appeared since the audit
  -- (for example the grower added it by hand, or the new Portal RPC created
  -- one), so the promotion can never produce two tractors for one physical
  -- machine.
  select t.id into v_tractor_id
    from public.tractors t
   where t.vineyard_id = c_vineyard_id
     and t.deleted_at is null
     and (
       t.id = c_tractor_id
       or (lower(btrim(t.brand)) = lower(c_brand) and lower(btrim(t.model)) = lower(c_model))
       or lower(btrim(t.name)) = lower(c_name)
     )
     -- Never adopt a tractor that already backs a different active machine.
     and not exists (
       select 1 from public.vineyard_machines m
        where m.legacy_tractor_id = t.id
          and m.deleted_at is null
          and m.id <> c_machine_id
     )
   order by (t.id = c_tractor_id) desc, t.created_at
   limit 1;

  if v_tractor_id is null then
    insert into public.tractors (
      id, vineyard_id, name, brand, model,
      -- No year is invented. The audit gave brand, model and rate only.
      model_year,
      -- fuel_usage_l_per_hour is NOT NULL; the schema convention is that 0
      -- means "not set". This machine records a real 7.5, so 7.5 is carried
      -- across unchanged. Nothing is estimated.
      fuel_usage_l_per_hour,
      -- Carried across if present, never fabricated.
      serial_number, vin_number,
      created_by, updated_by
    )
    values (
      c_tractor_id, c_vineyard_id, c_name, c_brand, c_model,
      null,
      coalesce(v_machine.fuel_usage_l_per_hour, 0),
      v_machine.serial_number, v_machine.vin_number,
      v_machine.created_by, v_machine.updated_by
    );
    v_tractor_id := c_tractor_id;
    raise notice 'sql/208: created tractor % (% %) for campesi.', v_tractor_id, c_brand, c_model;
  else
    raise notice 'sql/208: adopting existing campesi tractor %.', v_tractor_id;
  end if;

  -- Link the EXISTING machine. The id — and therefore any Trip, Fuel Log or
  -- Spray Record that references it now or later — is untouched. This UPDATE
  -- is also validated by the sql/206 guard, which proves the link is
  -- same-vineyard.
  update public.vineyard_machines
     set legacy_tractor_id = v_tractor_id,
         machine_type      = 'tractor',
         updated_at        = now()
   where id = c_machine_id
     and legacy_tractor_id is null;

  -- ---- postconditions, inside the same transaction ------------------------
  select count(*) into v_tractors_after from public.tractors;
  select count(*) into v_machines_after from public.vineyard_machines;
  select count(*) into v_trips_after from public.trips where machine_id = c_machine_id;
  select count(*) into v_logs_after  from public.tractor_fuel_logs where machine_id = c_machine_id;

  if v_tractors_after > v_tractors_before + 1 then
    raise exception 'sql/208 FAILED: created % tractors, expected at most 1.',
      v_tractors_after - v_tractors_before;
  end if;

  if v_machines_after <> v_machines_before then
    raise exception 'sql/208 FAILED: the machine count changed (% -> %).',
      v_machines_before, v_machines_after;
  end if;

  if v_trips_after <> v_trips_before or v_logs_after <> v_logs_before then
    raise exception
      'sql/208 FAILED: historical references moved (trips % -> %, fuel logs % -> %).',
      v_trips_before, v_trips_after, v_logs_before, v_logs_after;
  end if;

  select m.fuel_usage_l_per_hour into v_rate
    from public.vineyard_machines m where m.id = c_machine_id;
  if v_rate is distinct from coalesce(v_machine.fuel_usage_l_per_hour, 0) then
    raise exception 'sql/208 FAILED: the machine fuel rate changed (% -> %).',
      v_machine.fuel_usage_l_per_hour, v_rate;
  end if;

  if not exists (
    select 1
      from public.vineyard_machines m
      join public.tractors t on t.id = m.legacy_tractor_id
     where m.id = c_machine_id
       and m.machine_type = 'tractor'
       and m.deleted_at is null
       and t.vineyard_id = m.vineyard_id
       and t.vineyard_id = c_vineyard_id
  ) then
    raise exception 'sql/208 FAILED: machine % was not linked to a campesi tractor.', c_machine_id;
  end if;

  raise notice
    'sql/208: campesi machine % promoted — tractor %, % L/hr preserved, history untouched.',
    c_machine_id, v_tractor_id, v_rate;
end$$;

-- ---------------------------------------------------------------------------
-- Report the remaining orphans. Informational: this migration promotes ONE
-- reviewed asset and deliberately converts nothing else.
-- ---------------------------------------------------------------------------
do $$
declare
  v_c9 bigint;
begin
  select offending_count into v_c9
    from public.vt_equipment_integrity_report()
   where check_name = 'native_tractor_machine_unlinked';

  if v_c9 = 0 then
    raise notice 'sql/208: applied. C9 native_tractor_machine_unlinked is now 0.';
  else
    raise notice
      'sql/208: applied. C9 still reports % unlinked native tractor-machine(s) — review each before converting.',
      v_c9;
  end if;
end$$;

commit;

-- =============================================================================
-- AFTER APPLYING
--
-- 1. Confirm the promotion:
--
--      select m.id as machine_id, m.name, m.machine_type, m.legacy_tractor_id,
--             m.fuel_usage_l_per_hour as machine_rate,
--             t.name as tractor_name, t.brand, t.model,
--             t.fuel_usage_l_per_hour as tractor_rate
--        from public.vineyard_machines m
--        left join public.tractors t on t.id = m.legacy_tractor_id
--       where m.id = '1fd13cc9-7fee-42d1-8ff6-e8179a5e10a7';
--
--    Expected: one row, legacy_tractor_id set, both rates 7.5, machine id
--    unchanged.
--
-- 2. Confirm C9 is clear:
--
--      select * from public.vt_equipment_integrity_report();
--
--    Expected: every offending_count = 0, including
--    native_tractor_machine_unlinked.
--
-- ROLLBACK (the machine id and all history are unaffected either way):
--   begin;
--     update public.vineyard_machines
--        set legacy_tractor_id = null
--      where id = '1fd13cc9-7fee-42d1-8ff6-e8179a5e10a7';
--     delete from public.tractors
--      where id = '208e0001-7fee-42d1-8ff6-e8179a5e10a7';
--   commit;
-- END 208
-- =============================================================================

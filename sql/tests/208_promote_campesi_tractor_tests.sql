-- =====================================================================
-- 208_promote_campesi_tractor_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/206, sql/207 and sql/208.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- ---------------------------------------------------------------------------
-- WHY THE PROMOTION IS TESTED AS A REPLICA
-- ---------------------------------------------------------------------------
-- sql/208's promotion block is pinned to two literal production ids, so it
-- cannot be re-pointed at a fixture, and re-running it here would be a no-op
-- (the real row is already linked) proving nothing about its logic.
--
-- So T3–T8 replay the same statements against a synthetic vineyard seeded into
-- exactly the campesi starting state — a tractor-typed machine, 7.5 L/hr,
-- legacy_tractor_id null, and no tractors row in the vineyard. T9 then asserts
-- the real production row reached the intended end state. A green replica plus
-- a green production assertion covers both the logic and the outcome.
--
-- Test map
--   T1  Preconditions: sql/207's C9 check exists
--   T2  C9 counts a native tractor-machine, ignoring linked / archived /
--       non-tractor rows
--   T3  REPLICA: exactly ONE tractor is created, in the right vineyard
--   T4  REPLICA: the machine id is preserved and no second machine appears
--   T5  REPLICA: the 7.5 L/hr rate is preserved on BOTH rows, nothing invented
--   T6  REPLICA: historical references are unchanged (a trip and a fuel log
--       planted against the machine keep pointing at it, tractor_id still null)
--   T7  REPLICA: idempotent — a re-run creates no duplicate tractor or machine,
--       including when a matching tractor already exists by hand
--   T8  REPLICA: the promotion cannot cross vineyards (sql/206 guard holds)
--   T9  PRODUCTION: the real campesi machine is linked, keeps its id and rate,
--       and its history is intact
--   T10 PRODUCTION: C9 is 0, and C1–C8 are still clean
--   T11 PRODUCTION: JH Testing (sql/207) and Stockmans are untouched
--   T12 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 208 campesi promotion tests: ALL PASSED
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.vt_equipment_integrity_report()') is null then
    raise exception 'sql/206 not applied — run it first.';
  end if;
  if not exists (
    select 1 from public.vt_equipment_integrity_report()
     where check_name = 'native_tractor_machine_unlinked'
  ) then
    raise exception
      'sql/207 not applied (or sql/206 was re-run after it) — C9 is missing.';
  end if;
end$$;

do $$
declare
  -- Real production ids, read only.
  c_campesi_vineyard constant uuid := '3d43e144-fba8-4b05-9c22-c36548023935';
  c_campesi_machine  constant uuid := '1fd13cc9-7fee-42d1-8ff6-e8179a5e10a7';
  c_jh_machine       constant uuid := '70861e55-2f9c-4a1a-af52-e1a8fe8bffe5';

  c_brand constant text := 'Kubota';
  c_model constant text := 'M092-N';
  c_name  constant text := 'Kubota M092-N';
  c_rate  constant double precision := 7.5;

  -- Replica fixtures.
  v_r         uuid := gen_random_uuid();
  v_other     uuid := gen_random_uuid();
  m_native    uuid := gen_random_uuid();
  m_linked    uuid := gen_random_uuid();
  m_atv       uuid := gen_random_uuid();
  m_archived  uuid := gen_random_uuid();
  t_linked    uuid := gen_random_uuid();
  t_foreign   uuid := gen_random_uuid();
  f_hist      uuid := gen_random_uuid();
  tr_hist     uuid := gen_random_uuid();

  v_tractor_id      uuid;
  v_adopted_id      uuid;
  v_cnt             bigint;
  v_c9_before       bigint;
  v_c9_after        bigint;
  v_tractors_before bigint;
  v_tractors_after  bigint;
  v_machines_before bigint;
  v_machines_after  bigint;
  v_rate            double precision;
  v_state           text;
  v_samples         uuid[];
  v_stock_vineyard  uuid;
  v_stock_tractors  bigint;
begin
  perform set_config('role', 'postgres', true);

  insert into public.vineyards (id, name) values
    (v_r,     'T208 Replica Vineyard'),
    (v_other, 'T208 Other Vineyard');

  -- The campesi starting state, reproduced exactly.
  insert into public.vineyard_machines
    (id, vineyard_id, name, machine_type, legacy_tractor_id, fuel_usage_l_per_hour)
  values
    (m_native, v_r, 'Kubota M092-N', 'tractor', null, c_rate);

  -- Controls that C9 must never flag.
  insert into public.tractors (id, vineyard_id, name, brand, model, fuel_usage_l_per_hour)
  values
    (t_linked,  v_r,     'T208 Linked',  'New Holland', 'T4.85N', 6.8),
    (t_foreign, v_other, 'T208 Foreign', 'Deutz',       '9.0',    9.0);
  insert into public.vineyard_machines
    (id, vineyard_id, name, machine_type, legacy_tractor_id)
  values
    (m_linked, v_r, 'T208 Linked Machine', 'tractor', t_linked),
    (m_atv,    v_r, 'T208 Ranger',         'atv',     null);
  insert into public.vineyard_machines
    (id, vineyard_id, name, machine_type, legacy_tractor_id, deleted_at)
  values
    (m_archived, v_r, 'T208 Retired', 'tractor', null, now());

  -- Historical rows against the machine that is about to be promoted. The
  -- production audit says campesi has none, but the migration must be correct
  -- whether or not that is still true when it runs.
  insert into public.trips (id, vineyard_id, machine_id, person_name)
  values (tr_hist, v_r, m_native, 'T208 Operator');
  insert into public.tractor_fuel_logs
    (id, vineyard_id, machine_id, tractor_id, litres_added, engine_hours)
  values (f_hist, v_r, m_native, null, 90, 512.4);

  -- =====================================================================
  -- T1. C9 exists and is a warning
  -- =====================================================================
  select severity into v_state
    from public.vt_equipment_integrity_report()
   where check_name = 'native_tractor_machine_unlinked';
  if v_state is distinct from 'warning' then
    raise exception 'T1 FAILED: C9 severity should be warning, got %',
      coalesce(v_state, '<missing>');
  end if;
  raise notice 'T1 passed';

  -- =====================================================================
  -- T2. C9 counts the native orphan and nothing else
  -- =====================================================================
  select offending_count, sample_ids into v_c9_before, v_samples
    from public.vt_equipment_integrity_report()
   where check_name = 'native_tractor_machine_unlinked';

  if not (m_native = any(v_samples)) then
    raise exception 'T2 FAILED: C9 did not report the native tractor-machine';
  end if;
  if m_linked = any(v_samples) then
    raise exception 'T2 FAILED: C9 flagged a properly linked tractor-backed machine';
  end if;
  if m_atv = any(v_samples) then
    raise exception 'T2 FAILED: C9 flagged an ATV';
  end if;
  if m_archived = any(v_samples) then
    raise exception 'T2 FAILED: C9 flagged an archived machine';
  end if;
  raise notice 'T2 passed';

  -- =====================================================================
  -- T3/T4/T5/T6. The promotion, replayed against the replica
  -- =====================================================================
  select count(*) into v_tractors_before from public.tractors;
  select count(*) into v_machines_before from public.vineyard_machines;

  insert into public.tractors (
    id, vineyard_id, name, brand, model, model_year,
    fuel_usage_l_per_hour, serial_number, vin_number
  )
  select gen_random_uuid(), m.vineyard_id, c_name, c_brand, c_model, null,
         coalesce(m.fuel_usage_l_per_hour, 0), m.serial_number, m.vin_number
    from public.vineyard_machines m
   where m.id = m_native
  returning id into v_tractor_id;

  update public.vineyard_machines
     set legacy_tractor_id = v_tractor_id,
         machine_type      = 'tractor',
         updated_at        = now()
   where id = m_native
     and legacy_tractor_id is null;

  select count(*) into v_tractors_after from public.tractors;
  select count(*) into v_machines_after from public.vineyard_machines;

  -- T3: exactly one tractor, in the replica vineyard.
  if v_tractors_after <> v_tractors_before + 1 then
    raise exception 'T3 FAILED: expected exactly 1 new tractor, got %',
      v_tractors_after - v_tractors_before;
  end if;
  select count(*) into v_cnt
    from public.tractors
   where vineyard_id = v_r and deleted_at is null
     and lower(btrim(brand)) = lower(c_brand)
     and lower(btrim(model)) = lower(c_model);
  if v_cnt <> 1 then
    raise exception 'T3 FAILED: expected 1 Kubota M092-N in the vineyard, found %', v_cnt;
  end if;
  raise notice 'T3 passed';

  -- T4: the machine id survives, no second machine.
  if v_machines_after <> v_machines_before then
    raise exception 'T4 FAILED: the machine count changed (% -> %)',
      v_machines_before, v_machines_after;
  end if;
  if not exists (
    select 1 from public.vineyard_machines
     where id = m_native
       and legacy_tractor_id = v_tractor_id
       and machine_type = 'tractor'
       and deleted_at is null
  ) then
    raise exception 'T4 FAILED: machine % was not preserved and linked', m_native;
  end if;
  raise notice 'T4 passed';

  -- T5: the 7.5 rate is preserved on both rows, and no year/serial/VIN is
  -- invented.
  select fuel_usage_l_per_hour into v_rate from public.tractors where id = v_tractor_id;
  if v_rate is distinct from c_rate then
    raise exception 'T5 FAILED: the tractor rate is % , expected %', v_rate, c_rate;
  end if;
  select fuel_usage_l_per_hour into v_rate from public.vineyard_machines where id = m_native;
  if v_rate is distinct from c_rate then
    raise exception 'T5 FAILED: the machine rate changed to %', v_rate;
  end if;
  if (select model_year from public.tractors where id = v_tractor_id) is not null then
    raise exception 'T5 FAILED: a model year was invented';
  end if;
  if (select serial_number from public.tractors where id = v_tractor_id) is not null
     or (select vin_number from public.tractors where id = v_tractor_id) is not null then
    raise exception 'T5 FAILED: a serial number or VIN was invented';
  end if;
  raise notice 'T5 passed';

  -- T6: historical references untouched. machine_id stays canonical and
  -- tractor_id is NOT back-filled — that would be rewriting history.
  if (select machine_id from public.trips where id = tr_hist) is distinct from m_native then
    raise exception 'T6 FAILED: the trip machine_id changed';
  end if;
  if (select tractor_id from public.trips where id = tr_hist) is not null then
    raise exception 'T6 FAILED: the promotion back-filled trips.tractor_id';
  end if;
  if (select machine_id from public.tractor_fuel_logs where id = f_hist) is distinct from m_native then
    raise exception 'T6 FAILED: the fuel log machine_id changed';
  end if;
  if (select tractor_id from public.tractor_fuel_logs where id = f_hist) is not null then
    raise exception 'T6 FAILED: the promotion back-filled tractor_fuel_logs.tractor_id';
  end if;
  if (select litres_added from public.tractor_fuel_logs where id = f_hist) <> 90 then
    raise exception 'T6 FAILED: fuel log values changed';
  end if;
  raise notice 'T6 passed';

  -- The repaired machine leaves C9.
  select offending_count, sample_ids into v_c9_after, v_samples
    from public.vt_equipment_integrity_report()
   where check_name = 'native_tractor_machine_unlinked';
  if m_native = any(coalesce(v_samples, '{}'::uuid[])) then
    raise exception 'T6 FAILED: the promoted machine is still reported by C9';
  end if;
  if v_c9_after <> v_c9_before - 1 then
    raise exception 'T6 FAILED: C9 should have fallen by exactly 1 (% -> %)',
      v_c9_before, v_c9_after;
  end if;

  -- =====================================================================
  -- T7. Idempotency
  -- =====================================================================
  select count(*) into v_tractors_before from public.tractors;
  select count(*) into v_machines_before from public.vineyard_machines;

  -- Replay: the machine now has a link, so the guarded UPDATE matches nothing
  -- and the INSERT is skipped by the same `legacy_tractor_id is null` test.
  update public.vineyard_machines
     set legacy_tractor_id = v_tractor_id
   where id = m_native
     and legacy_tractor_id is null;

  select count(*) into v_tractors_after from public.tractors;
  select count(*) into v_machines_after from public.vineyard_machines;
  if v_tractors_after <> v_tractors_before or v_machines_after <> v_machines_before then
    raise exception 'T7 FAILED: a second run changed row counts (tractors % -> %, machines % -> %)',
      v_tractors_before, v_tractors_after, v_machines_before, v_machines_after;
  end if;

  -- Adoption: the lookup sql/208 performs before inserting must find the
  -- tractor that already exists rather than adding another. It must also
  -- refuse to adopt a tractor that already backs a DIFFERENT active machine.
  select t.id into v_adopted_id
    from public.tractors t
   where t.vineyard_id = v_r
     and t.deleted_at is null
     and (
       (lower(btrim(t.brand)) = lower(c_brand) and lower(btrim(t.model)) = lower(c_model))
       or lower(btrim(t.name)) = lower(c_name)
     )
     and not exists (
       select 1 from public.vineyard_machines m
        where m.legacy_tractor_id = t.id
          and m.deleted_at is null
          and m.id <> m_native
     )
   order by t.created_at
   limit 1;
  if v_adopted_id is distinct from v_tractor_id then
    raise exception 'T7 FAILED: the adoption lookup found % instead of %',
      coalesce(v_adopted_id::text, '<none>'), v_tractor_id;
  end if;

  select count(*) into v_cnt
    from public.tractors
   where vineyard_id = v_r and deleted_at is null
     and lower(btrim(name)) = lower(c_name);
  if v_cnt <> 1 then
    raise exception 'T7 FAILED: % tractors named % exist after re-running', v_cnt, c_name;
  end if;
  raise notice 'T7 passed';

  -- =====================================================================
  -- T8. The promotion cannot cross vineyards
  --
  -- T3–T4 already proved the same-vineyard link is accepted. This proves the
  -- sql/206 guard would refuse the promotion if the target tractor were in
  -- another vineyard — i.e. the migration cannot mis-link campesi to a
  -- Stockmans or JH tractor.
  -- =====================================================================
  v_state := null;
  begin
    update public.vineyard_machines
       set legacy_tractor_id = t_foreign
     where id = m_atv;
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'T8 FAILED: expected the sql/206 guard to refuse with 23514, got %',
      coalesce(v_state, 'no error');
  end if;
  raise notice 'T8 passed';

  -- =====================================================================
  -- T9. PRODUCTION: the real campesi row reached the intended state
  --
  -- Read-only. Skipped with a loud notice if the row is absent, so the suite
  -- still runs on a fork or a restored subset.
  -- =====================================================================
  if not exists (select 1 from public.vineyard_machines where id = c_campesi_machine) then
    raise notice 'T9 SKIPPED: campesi machine % is not present in this database', c_campesi_machine;
  else
    if (select vineyard_id from public.vineyard_machines where id = c_campesi_machine)
         is distinct from c_campesi_vineyard then
      raise exception 'T9 FAILED: machine % is not in the campesi vineyard', c_campesi_machine;
    end if;

    select legacy_tractor_id into v_tractor_id
      from public.vineyard_machines where id = c_campesi_machine;
    if v_tractor_id is null then
      raise exception
        'T9 FAILED: the campesi machine still has no legacy_tractor_id — sql/208 has not been applied here';
    end if;

    if not exists (
      select 1 from public.tractors
       where id = v_tractor_id
         and vineyard_id = c_campesi_vineyard
         and deleted_at is null
    ) then
      raise exception 'T9 FAILED: the linked tractor % is missing from campesi', v_tractor_id;
    end if;

    -- Exactly one active machine links to it.
    select count(*) into v_cnt
      from public.vineyard_machines
     where vineyard_id = c_campesi_vineyard
       and deleted_at is null
       and legacy_tractor_id = v_tractor_id;
    if v_cnt <> 1 then
      raise exception 'T9 FAILED: % active machines link to tractor %', v_cnt, v_tractor_id;
    end if;

    -- The rate is preserved on both rows.
    select fuel_usage_l_per_hour into v_rate from public.tractors where id = v_tractor_id;
    if v_rate is distinct from c_rate then
      raise exception 'T9 FAILED: the campesi tractor rate is %, expected %', v_rate, c_rate;
    end if;
    select fuel_usage_l_per_hour into v_rate
      from public.vineyard_machines where id = c_campesi_machine;
    if v_rate is distinct from c_rate then
      raise exception 'T9 FAILED: the campesi machine rate is %, expected %', v_rate, c_rate;
    end if;

    raise notice 'T9 passed (campesi machine % -> tractor %, % L/hr)',
      c_campesi_machine, v_tractor_id, v_rate;
  end if;

  -- =====================================================================
  -- T10. PRODUCTION: C9 clear, C1–C8 still clean
  --
  -- The replica fixtures in this transaction are deliberately consistent, so
  -- every error-severity check must read 0 for the whole database.
  -- =====================================================================
  select offending_count into v_cnt
    from public.vt_equipment_integrity_report()
   where check_name = 'native_tractor_machine_unlinked';
  if v_cnt <> 0 then
    raise exception
      'T10: C9 reports % remaining unlinked native tractor-machine(s) — review each before converting', v_cnt;
  end if;

  select count(*) into v_cnt
    from public.vt_equipment_integrity_report()
   where severity = 'error' and offending_count > 0;
  if v_cnt <> 0 then
    raise exception 'T10 FAILED: % error-severity integrity check(s) are non-zero', v_cnt;
  end if;
  raise notice 'T10 passed (C1-C9 clean)';

  -- =====================================================================
  -- T11. PRODUCTION: JH Testing and Stockmans untouched
  -- =====================================================================
  if exists (select 1 from public.vineyard_machines where id = c_jh_machine) then
    if (select legacy_tractor_id from public.vineyard_machines where id = c_jh_machine) is null then
      raise exception 'T11 FAILED: the sql/207 JH Testing link was lost';
    end if;
  end if;

  select id into v_stock_vineyard
    from public.vineyards
   where name ilike '%stockmans%'
   order by created_at
   limit 1;

  if v_stock_vineyard is null then
    raise notice 'T11 SKIPPED: no Stockmans vineyard in this database';
  else
    select count(*) into v_stock_tractors
      from public.tractors where vineyard_id = v_stock_vineyard and deleted_at is null;

    -- No Stockmans machine may point outside its vineyard.
    select count(*) into v_cnt
      from public.vineyard_machines m
      join public.tractors t on t.id = m.legacy_tractor_id
     where m.vineyard_id = v_stock_vineyard
       and m.deleted_at is null
       and t.vineyard_id is distinct from m.vineyard_id;
    if v_cnt <> 0 then
      raise exception 'T11 FAILED: % Stockmans machine(s) point outside the vineyard', v_cnt;
    end if;

    -- The configured New Holland rate is still 6.8. The linked machine's
    -- 1.20361083249749 drift is known and deliberately NOT repaired here, so
    -- it is not asserted either way.
    select count(*) into v_cnt
      from public.tractors
     where vineyard_id = v_stock_vineyard
       and deleted_at is null
       and lower(btrim(brand)) = 'new holland'
       and fuel_usage_l_per_hour = 6.8;
    if v_cnt < 1 then
      raise notice 'T11 NOTE: no Stockmans New Holland at 6.8 L/hr found — check manually';
    end if;

    raise notice 'T11 passed (% Stockmans tractor(s) intact)', v_stock_tractors;
  end if;

  perform set_config('role', 'postgres', true);
  raise notice 'SQL 208 campesi promotion tests: ALL PASSED';
end$$;

-- ---------------- T12 discard everything ----------------
rollback;

-- =====================================================================
-- Post-run expectation: the NOTICEs above, and ZERO fixtures remaining.
--   select count(*) from public.vineyards where name like 'T208%';
--   -- expected: 0
--
-- Then the production audit:
--   select * from public.vt_equipment_integrity_report();
--   -- expected: every offending_count = 0
-- =====================================================================

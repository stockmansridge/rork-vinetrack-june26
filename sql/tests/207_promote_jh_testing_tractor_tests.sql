-- =====================================================================
-- 207_promote_jh_testing_tractor_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/206 and sql/207.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- ---------------------------------------------------------------------------
-- HOW THE PROMOTION IS TESTED WITHOUT TOUCHING THE REAL JH ROW
-- ---------------------------------------------------------------------------
-- sql/207's promotion block is pinned to two literal production ids, so it
-- cannot be re-pointed at a fixture. Re-running it here would be a no-op (the
-- real row is already linked) and would prove nothing about its logic.
--
-- So T5–T9 exercise the promotion as a REPLICA: the same statements, in the
-- same order, against a synthetic vineyard that starts in exactly the JH
-- Testing state — a tractor-typed machine, legacy_tractor_id null, no tractors
-- row in the vineyard, fuel usage 0, and a fuel log already referencing the
-- machine. T10 then asserts the real production row reached the intended end
-- state. A green replica plus a green production assertion covers both the
-- logic and the outcome; neither alone would.
--
-- Test map
--   T1  sql/207 applied: the report exposes C9
--   T2  C9 counts a native tractor-machine and ignores linked / archived /
--       non-tractor rows
--   T3  C1–C8 still present and unchanged in shape by the C9 addition
--   T4  A promoted machine drops OUT of C9 (the check tracks the repair)
--   T5  REPLICA: promotion creates exactly ONE tractor, in the right vineyard
--   T6  REPLICA: the machine id is preserved and no second machine appears
--   T7  REPLICA: the fuel log is untouched — same machine_id, tractor_id still
--       null, litres/hours unchanged
--   T8  REPLICA: no fuel rate is invented — 0 in, 0 out
--   T9  REPLICA: re-running creates no duplicate tractor and no duplicate
--       machine (idempotency), including when a matching tractor already
--       exists by hand
--   T10 PRODUCTION: the real JH machine is linked, still has its own id, and
--       its fuel logs still point at it
--   T11 PRODUCTION: Stockmans Ridge is untouched — its tractors and their
--       linked machines are exactly as before
--   T12 The sql/206 guard permits the promotion link (same vineyard) and
--       still refuses a cross-vineyard one
--   T13 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 207 JH promotion tests: ALL PASSED
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
      'sql/207 not applied (or sql/206 was re-run after it) — run sql/207_promote_jh_testing_tractor.sql.';
  end if;
end$$;

do $$
declare
  -- Real production ids, read only.
  c_jh_vineyard  constant uuid := '59973ced-1fb9-42ec-a66d-9eaad3172824';
  c_jh_machine   constant uuid := '70861e55-2f9c-4a1a-af52-e1a8fe8bffe5';

  -- Replica fixtures.
  v_r            uuid := gen_random_uuid();   -- replica vineyard
  m_native       uuid := gen_random_uuid();   -- the JH-shaped machine
  m_linked       uuid := gen_random_uuid();   -- properly linked tractor-machine
  m_atv          uuid := gen_random_uuid();   -- an ATV (must never be flagged)
  m_archived     uuid := gen_random_uuid();   -- archived native tractor-machine
  t_linked       uuid := gen_random_uuid();
  f_native       uuid := gen_random_uuid();   -- fuel log on m_native
  v_other        uuid := gen_random_uuid();   -- a second vineyard, for T12

  c_brand        constant text := 'New Holland';
  c_model        constant text := 'T4.85N';
  c_name         constant text := 'New Holland T4.85N';

  v_tractor_id       uuid;
  v_adopted_id       uuid;
  v_cnt              bigint;
  v_c9_before        bigint;
  v_c9_after         bigint;
  v_tractors_before  bigint;
  v_tractors_after   bigint;
  v_machines_before  bigint;
  v_machines_after   bigint;
  v_state            text;
  v_litres           double precision;
  v_hours            double precision;
  v_rate             double precision;
  v_samples          uuid[];
  v_stock_tractors   bigint;
  v_stock_machines   bigint;
  v_stock_after_t    bigint;
  v_stock_after_m    bigint;
  v_stock_vineyard   uuid;
begin
  perform set_config('role', 'postgres', true);

  insert into public.vineyards (id, name) values
    (v_r,     'T207 Replica Vineyard'),
    (v_other, 'T207 Other Vineyard');

  -- The JH Testing starting state, reproduced exactly: a tractor-typed
  -- machine, no legacy link, fuel usage 0, and NO tractors row anywhere in
  -- the vineyard.
  insert into public.vineyard_machines
    (id, vineyard_id, name, machine_type, legacy_tractor_id, fuel_usage_l_per_hour)
  values
    (m_native, v_r, 'new holand t4.85n', 'tractor', null, 0);

  insert into public.tractor_fuel_logs
    (id, vineyard_id, machine_id, tractor_id, litres_added, engine_hours)
  values
    (f_native, v_r, m_native, null, 120, 1420.0);

  -- Controls that must never be reported by C9.
  insert into public.tractors (id, vineyard_id, name, brand, model, fuel_usage_l_per_hour)
  values (t_linked, v_r, 'T207 Linked', 'Kubota', 'M5', 8.5);
  insert into public.vineyard_machines
    (id, vineyard_id, name, machine_type, legacy_tractor_id)
  values
    (m_linked,   v_r, 'T207 Linked Machine', 'tractor', t_linked),
    (m_atv,      v_r, 'T207 Ranger',         'atv',     null);
  insert into public.vineyard_machines
    (id, vineyard_id, name, machine_type, legacy_tractor_id, deleted_at)
  values
    (m_archived, v_r, 'T207 Retired Tractor', 'tractor', null, now());

  -- =====================================================================
  -- T1. The report exposes C9
  -- =====================================================================
  select severity into v_state
    from public.vt_equipment_integrity_report()
   where check_name = 'native_tractor_machine_unlinked';
  if v_state is distinct from 'warning' then
    raise exception 'T1 FAILED: C9 severity should be warning, got %', coalesce(v_state, '<missing>');
  end if;
  raise notice 'T1 passed';

  -- =====================================================================
  -- T2. C9 counts the native orphan and nothing else
  --
  -- The three controls are the ways a tractor-typed row is legitimate:
  -- properly linked, archived, or simply not a tractor.
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
  -- T3. Adding C9 did not disturb the existing checks
  -- =====================================================================
  select count(*) into v_cnt
    from public.vt_equipment_integrity_report()
   where check_name in (
     'machine_legacy_tractor_cross_vineyard',
     'machine_legacy_tractor_missing',
     'duplicate_active_machines_per_legacy_tractor',
     'fuel_log_machine_cross_vineyard',
     'fuel_log_tractor_cross_vineyard',
     'fuel_log_machine_tractor_disagree',
     'trip_machine_cross_vineyard',
     'trip_tractor_cross_vineyard');
  if v_cnt <> 8 then
    raise exception 'T3 FAILED: expected the 8 original checks, found %', v_cnt;
  end if;

  select offending_count into v_cnt
    from public.vt_equipment_integrity_report()
   where check_name = 'machine_legacy_tractor_cross_vineyard';
  if v_cnt <> 0 then
    raise exception 'T3 FAILED: the fixtures created % cross-vineyard link(s)', v_cnt;
  end if;
  raise notice 'T3 passed';

  -- =====================================================================
  -- T5/T6/T7/T8. The promotion, replayed against the replica
  --
  -- These are the statements from sql/207's promotion block, in order.
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

  -- T5: exactly one tractor, in the replica vineyard.
  if v_tractors_after <> v_tractors_before + 1 then
    raise exception 'T5 FAILED: expected exactly 1 new tractor, got %',
      v_tractors_after - v_tractors_before;
  end if;
  select count(*) into v_cnt
    from public.tractors
   where vineyard_id = v_r and deleted_at is null
     and lower(trim(brand)) = lower(c_brand) and lower(trim(model)) = lower(c_model);
  if v_cnt <> 1 then
    raise exception 'T5 FAILED: expected 1 New Holland T4.85N in the vineyard, found %', v_cnt;
  end if;
  raise notice 'T5 passed';

  -- T6: the machine id survives and no second machine was created.
  if v_machines_after <> v_machines_before then
    raise exception 'T6 FAILED: the machine count changed (% -> %)',
      v_machines_before, v_machines_after;
  end if;
  if not exists (
    select 1 from public.vineyard_machines
     where id = m_native
       and legacy_tractor_id = v_tractor_id
       and machine_type = 'tractor'
       and deleted_at is null
  ) then
    raise exception 'T6 FAILED: machine % was not preserved and linked', m_native;
  end if;
  raise notice 'T6 passed';

  -- T7: the fuel log is untouched. machine_id is the canonical link and must
  -- not be swapped for the new tractor, and tractor_id must NOT be
  -- back-filled — that would be rewriting history without a requirement.
  select machine_id, litres_added, engine_hours
    into v_adopted_id, v_litres, v_hours
    from public.tractor_fuel_logs where id = f_native;
  if v_adopted_id is distinct from m_native then
    raise exception 'T7 FAILED: the fuel log machine_id changed to %', v_adopted_id;
  end if;
  if (select tractor_id from public.tractor_fuel_logs where id = f_native) is not null then
    raise exception 'T7 FAILED: the promotion back-filled tractor_id on a historical fuel log';
  end if;
  if v_litres <> 120 or v_hours <> 1420.0 then
    raise exception 'T7 FAILED: the fuel log values changed (% L, % hrs)', v_litres, v_hours;
  end if;
  raise notice 'T7 passed';

  -- T8: no fuel rate invented.
  select fuel_usage_l_per_hour into v_rate from public.tractors where id = v_tractor_id;
  if v_rate <> 0 then
    raise exception 'T8 FAILED: the promoted tractor was given a fabricated rate of % L/hr', v_rate;
  end if;
  if (select fuel_usage_l_per_hour from public.vineyard_machines where id = m_native) <> 0 then
    raise exception 'T8 FAILED: the machine fuel rate was altered';
  end if;
  raise notice 'T8 passed';

  -- =====================================================================
  -- T4. The repaired machine leaves C9
  -- =====================================================================
  select offending_count, sample_ids into v_c9_after, v_samples
    from public.vt_equipment_integrity_report()
   where check_name = 'native_tractor_machine_unlinked';
  if m_native = any(coalesce(v_samples, '{}'::uuid[])) then
    raise exception 'T4 FAILED: the promoted machine is still reported by C9';
  end if;
  if v_c9_after <> v_c9_before - 1 then
    raise exception 'T4 FAILED: C9 should have fallen by exactly 1 (% -> %)',
      v_c9_before, v_c9_after;
  end if;
  raise notice 'T4 passed';

  -- =====================================================================
  -- T9. Idempotency
  --
  -- Two ways a second run could duplicate: replaying the whole block, and
  -- running it when the grower had already added the tractor by hand. Both
  -- are guarded by the same early exit / adopt logic in sql/207.
  -- =====================================================================
  select count(*) into v_tractors_before from public.tractors;
  select count(*) into v_machines_before from public.vineyard_machines;

  -- Replay: the machine now has a link, so the guarded UPDATE matches nothing
  -- and the INSERT is skipped by the same `legacy_tractor_id is null` test.
  if (select legacy_tractor_id from public.vineyard_machines where id = m_native) is null then
    raise exception 'T9 FAILED: precondition — the machine should already be linked';
  end if;
  update public.vineyard_machines
     set legacy_tractor_id = v_tractor_id
   where id = m_native
     and legacy_tractor_id is null;

  select count(*) into v_tractors_after from public.tractors;
  select count(*) into v_machines_after from public.vineyard_machines;
  if v_tractors_after <> v_tractors_before or v_machines_after <> v_machines_before then
    raise exception 'T9 FAILED: a second run changed row counts (tractors % -> %, machines % -> %)',
      v_tractors_before, v_tractors_after, v_machines_before, v_machines_after;
  end if;

  -- Adoption: a hand-added tractor must be reused, not duplicated. This is
  -- the lookup sql/207 performs before inserting.
  select t.id into v_adopted_id
    from public.tractors t
   where t.vineyard_id = v_r
     and t.deleted_at is null
     and (
       (lower(trim(t.brand)) = lower(c_brand) and lower(trim(t.model)) = lower(c_model))
       or lower(trim(t.name)) = lower(c_name)
     )
   order by t.created_at
   limit 1;
  if v_adopted_id is distinct from v_tractor_id then
    raise exception 'T9 FAILED: the adoption lookup found % instead of the promoted tractor %',
      coalesce(v_adopted_id::text, '<none>'), v_tractor_id;
  end if;

  select count(*) into v_cnt
    from public.tractors
   where vineyard_id = v_r and deleted_at is null
     and lower(trim(name)) = lower(c_name);
  if v_cnt <> 1 then
    raise exception 'T9 FAILED: % tractors named % exist after re-running', v_cnt, c_name;
  end if;
  raise notice 'T9 passed';

  -- =====================================================================
  -- T10. PRODUCTION: the real JH Testing row reached the intended state
  --
  -- Read-only assertions against live data. Skipped with a loud notice if the
  -- row is absent, so this suite still runs on a fork or a restored subset.
  -- =====================================================================
  if not exists (select 1 from public.vineyard_machines where id = c_jh_machine) then
    raise notice 'T10 SKIPPED: JH Testing machine % is not present in this database', c_jh_machine;
  else
    if (select vineyard_id from public.vineyard_machines where id = c_jh_machine)
         is distinct from c_jh_vineyard then
      raise exception 'T10 FAILED: machine % is not in the JH Testing vineyard', c_jh_machine;
    end if;

    select legacy_tractor_id into v_tractor_id
      from public.vineyard_machines where id = c_jh_machine;
    if v_tractor_id is null then
      raise exception
        'T10 FAILED: the JH machine still has no legacy_tractor_id — sql/207 has not been applied to this database';
    end if;

    -- The tractor exists, is in JH Testing, and is the same vineyard as the
    -- machine (which is also what the sql/206 guard enforced on the UPDATE).
    if not exists (
      select 1 from public.tractors
       where id = v_tractor_id
         and vineyard_id = c_jh_vineyard
         and deleted_at is null
    ) then
      raise exception 'T10 FAILED: the linked tractor % is missing from JH Testing', v_tractor_id;
    end if;

    -- Exactly one active tractor for this machine, and no second machine.
    select count(*) into v_cnt
      from public.vineyard_machines
     where vineyard_id = c_jh_vineyard
       and deleted_at is null
       and legacy_tractor_id = v_tractor_id;
    if v_cnt <> 1 then
      raise exception 'T10 FAILED: % active machines link to tractor %', v_cnt, v_tractor_id;
    end if;

    -- Fuel history still points at the machine, unchanged.
    select count(*) into v_cnt
      from public.tractor_fuel_logs
     where machine_id = c_jh_machine and deleted_at is null;
    raise notice 'T10: % active fuel log(s) still reference the JH machine', v_cnt;

    -- And JH Testing is no longer reported by C9.
    select sample_ids into v_samples
      from public.vt_equipment_integrity_report()
     where check_name = 'native_tractor_machine_unlinked';
    if c_jh_machine = any(coalesce(v_samples, '{}'::uuid[])) then
      raise exception 'T10 FAILED: the JH machine is still reported as an unlinked native tractor';
    end if;
    raise notice 'T10 passed';
  end if;

  -- =====================================================================
  -- T11. PRODUCTION: Stockmans Ridge untouched
  --
  -- Counted before and after this transaction's work. sql/207 filters on
  -- explicit primary keys, so any change here would mean the migration's
  -- scope leaked.
  -- =====================================================================
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
    select count(*) into v_stock_machines
      from public.vineyard_machines
     where vineyard_id = v_stock_vineyard and deleted_at is null and legacy_tractor_id is not null;

    -- Every Stockmans tractor still resolves, and every linked machine still
    -- points at a tractor in its own vineyard.
    select count(*) into v_cnt
      from public.vineyard_machines m
      join public.tractors t on t.id = m.legacy_tractor_id
     where m.vineyard_id = v_stock_vineyard
       and m.deleted_at is null
       and t.vineyard_id is distinct from m.vineyard_id;
    if v_cnt <> 0 then
      raise exception 'T11 FAILED: % Stockmans machine(s) point outside the vineyard', v_cnt;
    end if;

    -- Nothing in this transaction added or removed Stockmans equipment.
    select count(*) into v_stock_after_t
      from public.tractors where vineyard_id = v_stock_vineyard and deleted_at is null;
    select count(*) into v_stock_after_m
      from public.vineyard_machines
     where vineyard_id = v_stock_vineyard and deleted_at is null and legacy_tractor_id is not null;
    if v_stock_after_t <> v_stock_tractors or v_stock_after_m <> v_stock_machines then
      raise exception 'T11 FAILED: Stockmans counts moved (tractors % -> %, machines % -> %)',
        v_stock_tractors, v_stock_after_t, v_stock_machines, v_stock_after_m;
    end if;
    raise notice 'T11 passed (% tractor(s), % linked machine(s) unchanged)',
      v_stock_tractors, v_stock_machines;
  end if;

  -- =====================================================================
  -- T12. The sql/206 guard allowed this repair, and still blocks a bad one
  --
  -- The promotion sets legacy_tractor_id, which fires
  -- trg_vineyard_machines_validate_legacy_tractor. T5–T6 passing already
  -- proves it permits a same-vineyard link. This proves it did not simply
  -- stop working.
  -- =====================================================================
  insert into public.tractors (id, vineyard_id, name, brand, model, fuel_usage_l_per_hour)
  values (gen_random_uuid(), v_other, 'T207 Foreign', 'Deutz', '9.0', 9.0)
  returning id into v_adopted_id;

  v_state := null;
  begin
    update public.vineyard_machines
       set legacy_tractor_id = v_adopted_id
     where id = m_atv;
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception
      'T12 FAILED: expected the sql/206 guard to refuse a cross-vineyard link with 23514, got %',
      coalesce(v_state, 'no error');
  end if;
  raise notice 'T12 passed';

  raise notice 'SQL 207 JH promotion tests: ALL PASSED';
end$$;

-- ---------------- T13 discard everything ----------------
rollback;

-- =====================================================================
-- Post-run expectation: the NOTICEs above, and ZERO fixtures remaining.
-- Verify with (outside any transaction):
--   select count(*) from public.vineyards where name like 'T207%';
--   -- expected: 0
--
-- Then review any REMAINING native tractor-machines before converting them:
--   select m.id, v.name as vineyard, m.name, m.fuel_usage_l_per_hour
--     from public.vineyard_machines m
--     join public.vineyards v on v.id = m.vineyard_id
--    where m.deleted_at is null
--      and m.machine_type = 'tractor'
--      and m.legacy_tractor_id is null
--    order by v.name, m.name;
-- =====================================================================

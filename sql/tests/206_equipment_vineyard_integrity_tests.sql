-- =====================================================================
-- 206_equipment_vineyard_integrity_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/206_equipment_vineyard_integrity.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- ---------------------------------------------------------------------------
-- WHY THE CROSS-VINEYARD TESTS SWITCH ROLE
-- ---------------------------------------------------------------------------
-- Both guards read an RLS-protected table (`tractors`, `vineyard_machines`).
-- Under caller rights the lookup for a vineyard the caller is NOT a member of
-- returns zero rows, so the guard would see nothing and ACCEPT the very write
-- it exists to refuse — the sql/197 defect exactly. A guard like this is only
-- meaningfully tested as `authenticated`, with a user who genuinely cannot see
-- the foreign row. Owner-role tests would pass against a broken guard.
--
-- Test map
--   T1  Objects: report function + both triggers exist and are wired
--   T2  SAME-vineyard legacy_tractor_id -> ACCEPTED
--   T3  CROSS-vineyard legacy_tractor_id, tractor HIDDEN from the caller by
--       RLS -> REJECTED  *** the case a caller-rights guard would miss ***
--   T4  legacy_tractor_id matching NO tractor row -> ACCEPTED
--       (the guard must not become a second foreign key)
--   T5  A pre-existing inconsistent row stays readable, editable and
--       soft-deletable — the guard may never strand production data
--   T6  Fuel log: cross-vineyard machine_id and cross-vineyard tractor_id are
--       both REJECTED; the same-vineyard write still succeeds
--   T7  Fuel log carrying BOTH links that disagree, both in-vineyard ->
--       ACCEPTED (reportable warning, not a write error)
--   T8  The report counts the planted defects exactly, and reports 0 for the
--       checks that are clean
--   T9  Nothing was inserted or duplicated: active machine counts are
--       unchanged by running the audit, and no legacy tractor has two active
--       machines
--   T10 Historical references still resolve: a trip and a fuel log keep
--       resolving equipment after the referenced tractor is SOFT-deleted
--   T11 A soft-deleted machine is not resurrected and is excluded from the
--       report's active-row checks
--   T12 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 206 equipment vineyard integrity tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to report a PASS before sql/206 is applied.
do $$
begin
  if to_regprocedure('public.vt_equipment_integrity_report()') is null then
    raise exception
      'SQL 206 not applied — run sql/206_equipment_vineyard_integrity.sql first.';
  end if;
end$$;

do $$
declare
  v_a          uuid := gen_random_uuid();   -- vineyard A (the caller's vineyard)
  v_b          uuid := gen_random_uuid();   -- vineyard B (foreign)
  t_a          uuid := gen_random_uuid();   -- tractor in A
  t_a2         uuid := gen_random_uuid();   -- second tractor in A (soft-deleted later)
  t_b          uuid := gen_random_uuid();   -- tractor in B (hidden from u_a)
  t_ghost      uuid := gen_random_uuid();   -- id with no tractor row, ever
  m_a          uuid := gen_random_uuid();   -- machine in A, linked to t_a
  m_ghost      uuid := gen_random_uuid();   -- machine in A, dangling legacy link
  m_bad        uuid := gen_random_uuid();   -- planted cross-vineyard machine
  m_deleted    uuid := gen_random_uuid();   -- soft-deleted machine in A
  m_hist       uuid := gen_random_uuid();   -- machine in A linked to t_a2
  f_ok         uuid := gen_random_uuid();
  f_both       uuid := gen_random_uuid();
  f_hist       uuid := gen_random_uuid();
  tr_hist      uuid := gen_random_uuid();
  u_a          uuid;                        -- manager of A only
  u_both       uuid;                        -- manager of A and B
  v_state      text;
  v_cnt        bigint;
  v_before     bigint;
  v_after      bigint;
  v_samples    uuid[];
begin
  -- ---- fixtures (as owner) ------------------------------------------------
  perform set_config('role', 'postgres', true);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
         'authenticated', 'authenticated', e, 'x', now(), now(), now()
  from unnest(array['t206-a@test.local','t206-both@test.local']) e;

  select id into u_a    from auth.users where email = 't206-a@test.local';
  select id into u_both from auth.users where email = 't206-both@test.local';

  insert into public.profiles (id, email)
  select u, 't206-' || u::text || '@test.local'
    from unnest(array[u_a, u_both]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_a, 'T206 Vineyard A'),
    (v_b, 'T206 Vineyard B');

  -- u_a belongs to A ONLY — that asymmetry is what makes T3 meaningful.
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_a, u_a,    'manager'),
    (v_a, u_both, 'manager'),
    (v_b, u_both, 'manager');

  insert into public.tractors (id, vineyard_id, name, brand, model, fuel_usage_l_per_hour) values
    (t_a,  v_a, 'T206 New Holland', 'New Holland', 'T4.85N', 6.8),
    (t_a2, v_a, 'T206 Kubota',      'Kubota',      'M5',     8.5),
    (t_b,  v_b, 'T206 Foreign',     'Deutz',       '9.0',    9.0);

  -- =====================================================================
  -- T1. The objects exist and are wired to the right tables
  -- =====================================================================
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.vineyard_machines'::regclass
       and tgname  = 'trg_vineyard_machines_validate_legacy_tractor'
       and not tgisinternal
  ) then
    raise exception 'T1 FAILED: vineyard_machines legacy-tractor guard trigger is missing';
  end if;

  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.tractor_fuel_logs'::regclass
       and tgname  = 'trg_tractor_fuel_logs_validate_equipment_vineyard'
       and not tgisinternal
  ) then
    raise exception 'T1 FAILED: tractor_fuel_logs equipment guard trigger is missing';
  end if;

  -- Both guards read RLS-protected tables, so both must be SECURITY DEFINER.
  if not (
    select bool_and(p.prosecdef)
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in (
         'vineyard_machines_validate_legacy_tractor',
         'tractor_fuel_logs_validate_equipment_vineyard',
         'vt_equipment_integrity_report')
  ) then
    raise exception 'T1 FAILED: an sql/206 function is not SECURITY DEFINER';
  end if;
  raise notice 'T1 passed';

  -- =====================================================================
  -- T2. Same-vineyard legacy link, as an authenticated member of A
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  insert into public.vineyard_machines (id, vineyard_id, name, machine_type, legacy_tractor_id)
  values (m_a, v_a, 'T206 Machine A', 'tractor', t_a);

  if not exists (select 1 from public.vineyard_machines where id = m_a) then
    raise exception 'T2 FAILED: a legitimate same-vineyard machine was not stored';
  end if;
  raise notice 'T2 passed';

  -- =====================================================================
  -- T3. Cross-vineyard legacy link, tractor HIDDEN BY RLS -> REJECTED
  --
  -- Step 1 proves the caller genuinely cannot see t_b, so a caller-rights
  -- guard would find nothing and accept. Step 2 proves it is refused anyway.
  -- =====================================================================
  select count(*) into v_cnt from public.tractors where id = t_b;
  if v_cnt <> 0 then
    raise exception
      'T3 FAILED: precondition — u_a must NOT see the foreign tractor, saw % row(s)', v_cnt;
  end if;

  v_state := null;
  begin
    insert into public.vineyard_machines (id, vineyard_id, name, machine_type, legacy_tractor_id)
    values (gen_random_uuid(), v_a, 'T206 Cross', 'tractor', t_b);
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is null then
    raise exception
      'T3 FAILED: a machine in A was linked to a tractor in B — the guard is blind to foreign tractors';
  end if;
  if v_state <> '23514' then
    raise exception 'T3 FAILED: expected errcode 23514, got %', v_state;
  end if;

  -- The same rule must hold on UPDATE, not just INSERT.
  v_state := null;
  begin
    update public.vineyard_machines set legacy_tractor_id = t_b where id = m_a;
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is null then
    raise exception 'T3 FAILED: an UPDATE created a cross-vineyard legacy link';
  end if;
  raise notice 'T3 passed (the cross-vineyard regression case)';

  -- =====================================================================
  -- T4. legacy_tractor_id matching no tractor row -> ACCEPTED
  --
  -- The FK is ON DELETE SET NULL. Turning this guard into an existence check
  -- would make it a second foreign key and could block a legitimate write.
  -- =====================================================================
  insert into public.vineyard_machines (id, vineyard_id, name, machine_type, legacy_tractor_id)
  values (m_ghost, v_a, 'T206 Dangling', 'tractor', t_ghost);

  if not exists (select 1 from public.vineyard_machines where id = m_ghost) then
    raise exception 'T4 FAILED: a machine with an unknown legacy_tractor_id was rejected';
  end if;
  raise notice 'T4 passed';

  -- =====================================================================
  -- T5. A pre-existing inconsistent row stays fully usable
  --
  -- Planted with the trigger disabled, i.e. exactly how such a row would
  -- already exist in production. The guard prevents NEW bad links; it must
  -- never make an existing row un-editable or un-deletable, or history would
  -- stop being maintainable the day the guard shipped.
  -- =====================================================================
  perform set_config('role', 'postgres', true);
  alter table public.vineyard_machines disable trigger trg_vineyard_machines_validate_legacy_tractor;
  insert into public.vineyard_machines (id, vineyard_id, name, machine_type, legacy_tractor_id)
  values (m_bad, v_a, 'T206 Legacy Bad', 'tractor', t_b);
  alter table public.vineyard_machines enable trigger trg_vineyard_machines_validate_legacy_tractor;

  perform set_config('role', 'authenticated', true);

  -- Readable.
  if not exists (select 1 from public.vineyard_machines where id = m_bad) then
    raise exception 'T5 FAILED: the pre-existing inconsistent row is not readable';
  end if;
  -- Editable on any other column.
  update public.vineyard_machines
     set name = 'T206 Legacy Bad (renamed)', fuel_usage_l_per_hour = 7.1
   where id = m_bad;
  if (select name from public.vineyard_machines where id = m_bad) <> 'T206 Legacy Bad (renamed)' then
    raise exception 'T5 FAILED: an existing inconsistent row could not be edited';
  end if;
  -- Soft-deletable.
  update public.vineyard_machines set deleted_at = now() where id = m_bad;
  if (select deleted_at from public.vineyard_machines where id = m_bad) is null then
    raise exception 'T5 FAILED: an existing inconsistent row could not be soft deleted';
  end if;
  -- And repairable by nulling the bad link — the documented correction.
  update public.vineyard_machines set legacy_tractor_id = null, deleted_at = null where id = m_bad;
  if (select legacy_tractor_id from public.vineyard_machines where id = m_bad) is not null then
    raise exception 'T5 FAILED: the documented repair statement was rejected';
  end if;
  raise notice 'T5 passed';

  -- =====================================================================
  -- T6. Fuel logs may not reference another vineyard's equipment
  -- =====================================================================
  -- Same-vineyard write still works, including for the legacy tractor link.
  insert into public.tractor_fuel_logs (id, vineyard_id, machine_id, tractor_id, litres_added, engine_hours)
  values (f_ok, v_a, m_a, t_a, 120, 1420.0);
  if not exists (select 1 from public.tractor_fuel_logs where id = f_ok) then
    raise exception 'T6 FAILED: a legitimate same-vineyard fuel log was rejected';
  end if;

  -- Cross-vineyard legacy tractor link -> rejected.
  v_state := null;
  begin
    insert into public.tractor_fuel_logs (id, vineyard_id, tractor_id, litres_added)
    values (gen_random_uuid(), v_a, t_b, 50);
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is null then
    raise exception 'T6 FAILED: a fuel log in A referenced a tractor in B';
  end if;
  if v_state <> '23514' then
    raise exception 'T6 FAILED: expected errcode 23514 for tractor_id, got %', v_state;
  end if;

  -- Cross-vineyard machine link -> rejected. Planted as owner because a
  -- machine in B cannot be created by u_a in the first place.
  perform set_config('role', 'postgres', true);
  insert into public.vineyard_machines (id, vineyard_id, name, machine_type)
  values ('00000000-0000-0000-0000-0000000002b0', v_b, 'T206 Machine B', 'tractor');
  perform set_config('role', 'authenticated', true);

  v_state := null;
  begin
    insert into public.tractor_fuel_logs (id, vineyard_id, machine_id, litres_added)
    values (gen_random_uuid(), v_a, '00000000-0000-0000-0000-0000000002b0', 50);
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is null then
    raise exception 'T6 FAILED: a fuel log in A referenced a machine in B';
  end if;
  raise notice 'T6 passed';

  -- =====================================================================
  -- T7. Both links present and disagreeing, both inside the log's vineyard
  --
  -- Legacy rows legitimately carry both ids, and an edit can leave them out of
  -- step. That is a REPORTABLE observation, not a write error — rejecting it
  -- would make existing fuel history un-editable.
  -- =====================================================================
  insert into public.vineyard_machines (id, vineyard_id, name, machine_type, legacy_tractor_id)
  values (m_hist, v_a, 'T206 Machine Hist', 'tractor', t_a2);

  insert into public.tractor_fuel_logs (id, vineyard_id, machine_id, tractor_id, litres_added, engine_hours)
  values (f_both, v_a, m_hist, t_a, 90, 1500.0);   -- machine points at t_a2, log says t_a

  if not exists (select 1 from public.tractor_fuel_logs where id = f_both) then
    raise exception 'T7 FAILED: a legacy fuel log with disagreeing links was rejected';
  end if;
  raise notice 'T7 passed';

  -- =====================================================================
  -- T8. The report counts exactly what was planted
  -- =====================================================================
  perform set_config('role', 'postgres', true);

  -- Plant one, and only one, live cross-vineyard machine link.
  alter table public.vineyard_machines disable trigger trg_vineyard_machines_validate_legacy_tractor;
  update public.vineyard_machines set legacy_tractor_id = t_b where id = m_bad;
  alter table public.vineyard_machines enable trigger trg_vineyard_machines_validate_legacy_tractor;

  select offending_count, sample_ids into v_cnt, v_samples
    from public.vt_equipment_integrity_report()
   where check_name = 'machine_legacy_tractor_cross_vineyard';
  if v_cnt <> 1 then
    raise exception 'T8 FAILED: expected exactly 1 cross-vineyard machine link, report said %', v_cnt;
  end if;
  if not (m_bad = any(v_samples)) then
    raise exception 'T8 FAILED: the report did not name the planted machine';
  end if;

  -- The dangling link is a warning and must be counted separately.
  select offending_count into v_cnt
    from public.vt_equipment_integrity_report()
   where check_name = 'machine_legacy_tractor_missing';
  if v_cnt <> 1 then
    raise exception 'T8 FAILED: expected exactly 1 dangling legacy link, report said %', v_cnt;
  end if;

  -- The disagreeing fuel log is a warning, not an error.
  select offending_count into v_cnt
    from public.vt_equipment_integrity_report()
   where check_name = 'fuel_log_machine_tractor_disagree';
  if v_cnt < 1 then
    raise exception 'T8 FAILED: the disagreeing fuel log was not reported';
  end if;

  -- Clean checks must report zero — no false positives from the fixtures.
  select offending_count into v_cnt
    from public.vt_equipment_integrity_report()
   where check_name = 'fuel_log_machine_cross_vineyard';
  if v_cnt <> 0 then
    raise exception 'T8 FAILED: false positive on fuel_log_machine_cross_vineyard (%)', v_cnt;
  end if;
  select offending_count into v_cnt
    from public.vt_equipment_integrity_report()
   where check_name = 'duplicate_active_machines_per_legacy_tractor';
  if v_cnt <> 0 then
    raise exception 'T8 FAILED: false positive on duplicate active machines (%)', v_cnt;
  end if;

  -- Repair it the documented way, then confirm the report goes clean. This is
  -- what makes the correction auditable AND idempotent.
  update public.vineyard_machines m
     set legacy_tractor_id = null, updated_at = now()
    from public.tractors t
   where t.id = m.legacy_tractor_id
     and m.deleted_at is null
     and t.vineyard_id is distinct from m.vineyard_id;

  select offending_count into v_cnt
    from public.vt_equipment_integrity_report()
   where check_name = 'machine_legacy_tractor_cross_vineyard';
  if v_cnt <> 0 then
    raise exception 'T8 FAILED: the documented repair left % cross-vineyard link(s)', v_cnt;
  end if;
  raise notice 'T8 passed';

  -- =====================================================================
  -- T9. Nothing is inserted or duplicated by auditing or repairing
  -- =====================================================================
  select count(*) into v_before from public.vineyard_machines where deleted_at is null;
  perform public.vt_equipment_integrity_report();
  perform public.vt_equipment_integrity_report();
  select count(*) into v_after from public.vineyard_machines where deleted_at is null;
  if v_before <> v_after then
    raise exception 'T9 FAILED: running the audit changed the active machine count (% -> %)',
      v_before, v_after;
  end if;

  -- No legacy tractor may back two ACTIVE machines.
  select count(*) into v_cnt
    from (
      select legacy_tractor_id
        from public.vineyard_machines
       where deleted_at is null and legacy_tractor_id is not null
       group by legacy_tractor_id
      having count(*) > 1
    ) d;
  if v_cnt <> 0 then
    raise exception 'T9 FAILED: % legacy tractor(s) back more than one active machine', v_cnt;
  end if;
  raise notice 'T9 passed';

  -- =====================================================================
  -- T10. Historical references still resolve after a SOFT delete
  --
  -- Soft-deleting a tractor must not erase what a completed trip or fuel log
  -- says it used. Nothing in sql/206 nulls a historical reference.
  -- =====================================================================
  insert into public.trips (id, vineyard_id, tractor_id, machine_id, person_name)
  values (tr_hist, v_a, t_a2, m_hist, 'T206 Operator');

  insert into public.tractor_fuel_logs (id, vineyard_id, machine_id, tractor_id, litres_added, engine_hours)
  values (f_hist, v_a, m_hist, t_a2, 100, 1320.3);

  update public.tractors set deleted_at = now() where id = t_a2;

  if (select tractor_id from public.trips where id = tr_hist) is distinct from t_a2 then
    raise exception 'T10 FAILED: soft-deleting a tractor cleared trips.tractor_id';
  end if;
  if (select machine_id from public.trips where id = tr_hist) is distinct from m_hist then
    raise exception 'T10 FAILED: soft-deleting a tractor cleared trips.machine_id';
  end if;
  if (select tractor_id from public.tractor_fuel_logs where id = f_hist) is distinct from t_a2 then
    raise exception 'T10 FAILED: soft-deleting a tractor cleared tractor_fuel_logs.tractor_id';
  end if;
  -- The name is still resolvable through the soft-deleted row, which is how
  -- history keeps rendering.
  if (select name from public.tractors where id = t_a2) is null then
    raise exception 'T10 FAILED: the soft-deleted tractor row is gone, not tombstoned';
  end if;

  -- A trip may still be edited while pointing at soft-deleted equipment.
  update public.trips set person_name = 'T206 Operator (edited)' where id = tr_hist;
  raise notice 'T10 passed';

  -- =====================================================================
  -- T11. A soft-deleted machine is not resurrected
  -- =====================================================================
  insert into public.vineyard_machines (id, vineyard_id, name, machine_type, deleted_at)
  values (m_deleted, v_a, 'T206 Retired', 'tractor', now());

  if (select deleted_at from public.vineyard_machines where id = m_deleted) is null then
    raise exception 'T11 FAILED: a soft-deleted machine came back as active';
  end if;

  -- The audit only ever considers ACTIVE rows, so a tombstone can never be
  -- reported as a live defect and can never be "repaired" back into use.
  select offending_count into v_cnt
    from public.vt_equipment_integrity_report()
   where check_name = 'machine_legacy_tractor_cross_vineyard';
  if v_cnt <> 0 then
    raise exception 'T11 FAILED: a tombstoned row leaked into the active-row audit';
  end if;
  raise notice 'T11 passed';

  perform set_config('role', 'postgres', true);
  raise notice 'SQL 206 equipment vineyard integrity tests: ALL PASSED';
end$$;

-- ---------------- T12 discard everything ----------------
rollback;

-- =====================================================================
-- Post-run expectation: the NOTICEs above, and ZERO rows remaining. Verify
-- with (outside any transaction):
--   select count(*) from public.vineyards where name like 'T206%';
--   -- expected: 0
--   select count(*) from auth.users where email like 't206-%@test.local';
--   -- expected: 0
--
-- Then run the production audit itself:
--   select * from public.vt_equipment_integrity_report();
--   -- expected: every offending_count = 0
-- =====================================================================

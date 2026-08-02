-- =====================================================================
-- 163_pruning_season_backfill_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/163_pruning_season_backfill.sql and BEFORE running the
-- real backfill.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production pruning row is created, changed or deleted. The fixtures
-- reproduce the exact live shape found by the sql/162 audit: 2026-dated
-- work stored under season rows stamped 2027, with no live 2026 row.
--
-- IMPORTANT: every backfill call in this suite passes p_vineyard_id, so it
-- only ever plans or corrects the two throw-away fixture vineyards. An
-- unfiltered call also picks up the LIVE production mismatches (8 at the
-- time of writing, per the sql/162 audit) and every count below would drift
-- with the real data. T0 records the production baseline and T16 proves the
-- suite never moved it.
--
-- Test map
--   T0  Production baseline recorded (never touched by this suite)
--   T1  Tooling exists: log table, function, security definer, grants
--   T2  Non-admins and anonymous callers are rejected
--   T3  DRY RUN changes nothing and returns the full plan (fixture vineyard 1)
--   T4  A vineyard-filtered run corrects only that vineyard
--   T5  APPLY corrects every remaining fixture entry; remaining = 0
--   T6  Entries land on the canonical deterministic id for year(entry_date)
--   T7  The block's pruning setup is copied onto the new season row
--   T8  An entry's quarters travel with it
--   T9  A quarter the target already holds is released, never duplicated,
--       and the entry's totals are recomputed
--   T10 Reversed entries of an emptied season follow it (audit history)
--   T11 Emptied 2027 season rows are soft-deleted
--   T12 The same-date season split is gone
--   T13 A correctly-assigned entry is left untouched
--   T14 Reversal log and audit rows are written
--   T15 Re-running is a no-op
--   T16 Production mismatches unchanged by the whole suite
--   T17 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 163 pruning season backfill tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 161 + 163 are applied.
do $$
begin
  if to_regprocedure('public.derive_pruning_season_id(uuid, uuid, integer)') is null then
    raise exception 'SQL 161 not applied — run sql/161_pruning_season_canonical_assignment.sql first.';
  end if;
  if to_regprocedure('public.backfill_pruning_season_assignment(boolean, uuid)') is null then
    raise exception 'SQL 163 not applied — run sql/163_pruning_season_backfill.sql first.';
  end if;
end$$;

do $$
declare
  u_admin  uuid;
  u_mgr    uuid;
  v1       uuid := gen_random_uuid();
  v2       uuid := gen_random_uuid();
  b_cf     uuid := gen_random_uuid();
  b_sb     uuid := gen_random_uuid();
  b_pn     uuid := gen_random_uuid();
  b_con    uuid := gen_random_uuid();
  b_f      uuid := gen_random_uuid();
  s_cf27   uuid := gen_random_uuid();
  s_sb27   uuid := gen_random_uuid();
  s_pn26   uuid := gen_random_uuid();
  s_con26  uuid := gen_random_uuid();
  s_con27  uuid := gen_random_uuid();
  s_f27    uuid := gen_random_uuid();
  e1       uuid := gen_random_uuid();
  e2       uuid := gen_random_uuid();
  e3       uuid := gen_random_uuid();
  e4       uuid := gen_random_uuid();
  e5       uuid := gen_random_uuid();
  e_good   uuid := gen_random_uuid();
  e_bad    uuid := gen_random_uuid();
  e_f      uuid := gen_random_uuid();
  c_cf26   uuid;
  c_f26    uuid;
  r        jsonb;
  n        integer;
  y        integer;
  sid      uuid;
  num      numeric;
  ok       boolean;
  v_base   integer;
begin
  -- ---- T0. Production baseline (recorded before any fixture exists) ------
  select count(*) into v_base
  from public.pruning_entries e
  join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.deleted_at is null
    and s.season_year is distinct from extract(year from e.entry_date)::integer;
  raise notice 'T0 baseline: % live production mismatch(es) — this suite never touches them', v_base;

  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t163-admin@test.local','t163-mgr@test.local']) e;
  select id into u_admin from auth.users where email = 't163-admin@test.local';
  select id into u_mgr   from auth.users where email = 't163-mgr@test.local';

  insert into public.profiles (id, email)
  values (u_admin, 't163-admin@test.local'), (u_mgr, 't163-mgr@test.local')
  on conflict (id) do nothing;

  insert into public.system_admins (user_id, email, is_active)
  values (u_admin, 't163-admin@test.local', true)
  on conflict (user_id) do update set is_active = true;

  insert into public.vineyards (id, name) values
    (v1, 'T163 Split Vineyard'),
    (v2, 'T163 Filter Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v1, u_admin, 'owner'), (v1, u_mgr, 'manager'),
    (v2, u_admin, 'owner');

  insert into public.paddocks (id, vineyard_id, name) values
    (b_cf,  v1, 'T163 Cab Franc'),
    (b_sb,  v1, 'T163 Sauv Blanc'),
    (b_pn,  v1, 'T163 Pinot Noir'),
    (b_con, v1, 'T163 Conflict Block'),
    (b_f,   v2, 'T163 Filter Block');

  -- The defect: 2027-stamped season rows holding 2026 work.
  insert into public.pruning_seasons (
    id, vineyard_id, paddock_id, season_year, due_date, pruning_method,
    assigned_crew, working_days, manual_row_count, estimated_labour_hours, notes, status
  ) values
    (s_cf27, v1, b_cf, 2027, date '2026-09-30', 'cane', 'T163 Crew A',
     '{1,2,3,4,5,6}', 42, 120, 'T163 block setup', 'active'),
    (s_sb27, v1, b_sb, 2027, null, 'spur', '', '{1,2,3,4,5}', null, null, '', 'active'),
    (s_con27, v1, b_con, 2027, null, 'spur', '', '{1,2,3,4,5}', null, null, '', 'active'),
    (s_f27,  v2, b_f,  2027, null, 'spur', '', '{1,2,3,4,5}', null, null, '', 'active');
  -- Correctly-assigned rows that must be left alone / reused as targets.
  insert into public.pruning_seasons (id, vineyard_id, paddock_id, season_year)
  values (s_pn26, v1, b_pn, 2026), (s_con26, v1, b_con, 2026);

  insert into public.pruning_entries (
    id, vineyard_id, pruning_season_id, paddock_id, entry_date, worker_or_crew,
    row_equivalents_completed, estimated_vines_completed, created_by, deleted_at
  ) values
    (e1,     v1, s_cf27,  b_cf,  date '2026-08-02', 'T163 crew', 0.5,  100, u_mgr, null),
    (e2,     v1, s_cf27,  b_cf,  date '2026-07-29', 'T163 crew', 0.25,  50, u_mgr, null),
    (e3,     v1, s_sb27,  b_sb,  date '2026-08-02', 'T163 crew', 0.25,  30, u_mgr, null),
    (e4,     v1, s_pn26,  b_pn,  date '2026-07-20', 'T163 crew', 0.25,  20, u_mgr, null),
    (e5,     v1, s_cf27,  b_cf,  date '2026-07-20', 'T163 crew', 0,      0, u_mgr, now()),
    (e_good, v1, s_con26, b_con, date '2026-07-10', 'T163 crew', 0.25,  10, u_mgr, null),
    (e_bad,  v1, s_con27, b_con, date '2026-07-11', 'T163 crew', 0.5,   40, u_mgr, null),
    (e_f,    v2, s_f27,   b_f,   date '2026-07-05', 'T163 crew', 0.25,  15, u_mgr, null);

  insert into public.pruning_row_segments (
    vineyard_id, pruning_season_id, paddock_id, row_number, segment_number,
    completed, completed_at, completed_by, pruning_entry_id
  ) values
    (v1, s_cf27,  b_cf,  1, 1, true, now(), 'T163 crew', e1),
    (v1, s_cf27,  b_cf,  1, 2, true, now(), 'T163 crew', e1),
    (v1, s_cf27,  b_cf,  2, 1, true, now(), 'T163 crew', e2),
    (v1, s_sb27,  b_sb,  1, 1, true, now(), 'T163 crew', e3),
    (v1, s_pn26,  b_pn,  1, 1, true, now(), 'T163 crew', e4),
    (v1, s_con26, b_con, 5, 1, true, now(), 'T163 crew', e_good),
    (v1, s_con27, b_con, 5, 1, true, now(), 'T163 crew', e_bad),   -- conflicts
    (v1, s_con27, b_con, 6, 1, true, now(), 'T163 crew', e_bad),   -- moves
    (v2, s_f27,   b_f,   1, 1, true, now(), 'T163 crew', e_f);

  c_cf26 := public.derive_pruning_season_id(v1, b_cf, 2026);
  c_f26  := public.derive_pruning_season_id(v2, b_f,  2026);

  -- ---- T1. Tooling, security definer, fixed search_path, grants ----------
  assert to_regclass('public.pruning_season_backfill_log') is not null,
    'T1 the reversal log table must exist';

  select p.prosecdef into ok
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'backfill_pruning_season_assignment';
  assert ok, 'T1 the backfill must be security definer';

  select coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=public%' into ok
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'backfill_pruning_season_assignment';
  assert ok, 'T1 the backfill must pin search_path';

  assert not has_function_privilege('anon',
    'public.backfill_pruning_season_assignment(boolean, uuid)', 'execute'),
    'T1 anon must NOT execute the backfill';
  assert has_function_privilege('authenticated',
    'public.backfill_pruning_season_assignment(boolean, uuid)', 'execute'),
    'T1 authenticated must be able to call it (admin check is inside)';
  raise notice 'T1 passed: log table, security definer, fixed search_path, grants';

  -- ---- T2. Only System Administrators may run it -------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  ok := false;
  begin
    perform public.backfill_pruning_season_assignment(true);
  exception when others then ok := true;
  end;
  assert ok, 'T2 a vineyard manager must not run the backfill';

  perform set_config('request.jwt.claims', null, true);
  ok := false;
  begin
    perform public.backfill_pruning_season_assignment(true);
  exception when others then ok := true;
  end;
  assert ok, 'T2 an anonymous caller must be rejected';
  raise notice 'T2 passed: non-admin and anonymous callers rejected';

  -- Act as the System Administrator from here on.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);

  -- ---- T3. Dry run changes nothing ---------------------------------------
  -- Scoped to fixture vineyard 1: e1, e2, e3 and e_bad. (e4 is already
  -- correct, e5 is reversed, e_f belongs to vineyard 2.)
  r := public.backfill_pruning_season_assignment(true, v1);
  assert (r->>'dry_run')::boolean, 'T3 an explicit dry run must report dry_run';
  assert (r->>'entries_corrected')::integer = 4,
    'T3 the plan must list all 4 live vineyard-1 mismatches, got ' || (r->>'entries_corrected');
  assert (r->>'remaining_mismatches')::integer = 4,
    'T3 a dry run must not fix anything, remaining ' || (r->>'remaining_mismatches');
  assert jsonb_array_length(r->'plan') = 4, 'T3 the plan array must be returned for review';
  -- The no-argument form must also be a dry run (read-only, whole database).
  assert (public.backfill_pruning_season_assignment()->>'dry_run')::boolean,
    'T3 the default must be a dry run';
  select pruning_season_id into sid from public.pruning_entries where id = e1;
  assert sid = s_cf27, 'T3 no entry may move during a dry run';
  select count(*) into n from public.pruning_seasons where id in (c_cf26, c_f26);
  assert n = 0, 'T3 no season row may be created during a dry run';
  select count(*) into n from public.pruning_season_backfill_log
  where vineyard_id in (v1, v2);
  assert n = 0, 'T3 a dry run must not write to the reversal log';
  raise notice 'T3 passed: dry run is read-only and returns the full plan';

  -- ---- T4. Vineyard-filtered run -----------------------------------------
  r := public.backfill_pruning_season_assignment(false, v2);
  assert (r->>'entries_corrected')::integer = 1,
    'T4 the filter must correct only vineyard 2, got ' || (r->>'entries_corrected');
  select pruning_season_id into sid from public.pruning_entries where id = e_f;
  assert sid = c_f26, 'T4 the filtered entry must move to its canonical 2026 season';
  select pruning_season_id into sid from public.pruning_entries where id = e1;
  assert sid = s_cf27, 'T4 vineyard 1 must be untouched by a filtered run';
  raise notice 'T4 passed: a vineyard-filtered run corrects only that vineyard';

  -- ---- T5. Apply ----------------------------------------------------------
  r := public.backfill_pruning_season_assignment(false, v1);
  assert (r->>'entries_corrected')::integer = 4,
    'T5 the remaining 4 entries must be corrected, got ' || (r->>'entries_corrected');
  assert (r->>'remaining_mismatches')::integer = 0,
    'T5 no mismatch may remain, got ' || (r->>'remaining_mismatches');
  raise notice 'T5 passed: every mis-assigned entry corrected';

  -- ---- T6. Canonical deterministic ids ------------------------------------
  select pruning_season_id into sid from public.pruning_entries where id = e1;
  assert sid = c_cf26, 'T6 e1 must sit on the canonical 2026 Cab Franc season';
  select pruning_season_id into sid from public.pruning_entries where id = e2;
  assert sid = c_cf26, 'T6 both Cab Franc entries share one 2026 season';
  select s.season_year into y
  from public.pruning_entries e join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.id = e3;
  assert y = 2026, 'T6 the Sauv Blanc entry must be season 2026, got ' || y;
  select count(*) into n
  from public.pruning_entries e join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.vineyard_id = v1 and e.deleted_at is null
    and extract(year from e.entry_date)::integer <> s.season_year;
  assert n = 0, 'T6 season_year = year(entry_date) must hold for every entry, offenders ' || n;
  raise notice 'T6 passed: entries land on the canonical id for the year of the work';

  -- ---- T7. Block setup copied onto the new season row ---------------------
  select due_date is not distinct from date '2026-09-30'
     and pruning_method = 'cane'
     and assigned_crew = 'T163 Crew A'
     and working_days = '{1,2,3,4,5,6}'::integer[]
     and manual_row_count = 42
     and estimated_labour_hours = 120
     and notes = 'T163 block setup'
    into ok
  from public.pruning_seasons where id = c_cf26;
  assert ok, 'T7 the block pruning setup must be carried onto the canonical row';
  raise notice 'T7 passed: due date, crew, working days, row count, hours and notes copied';

  -- ---- T8. Quarters travel with the entry ---------------------------------
  select count(*) into n
  from public.pruning_row_segments
  where pruning_entry_id = e1 and pruning_season_id = c_cf26 and completed;
  assert n = 2, 'T8 both of e1''s quarters must move with it, got ' || n;
  select count(*) into n from public.pruning_row_segments
  where pruning_season_id = s_cf27 and completed;
  assert n = 0, 'T8 no completed quarter may be left behind, got ' || n;
  select row_equivalents_completed into num from public.pruning_entries where id = e1;
  assert num = 0.5, 'T8 row equivalents preserved, got ' || num;
  raise notice 'T8 passed: quarters follow their entry';

  -- ---- T9. Conflicting quarter released, never duplicated -----------------
  select count(*) into n
  from public.pruning_row_segments
  where pruning_season_id = s_con26 and row_number = 5 and segment_number = 1;
  assert n = 1, 'T9 the target season must still hold exactly one row 5 quarter 1, got ' || n;
  select pruning_entry_id into sid
  from public.pruning_row_segments
  where pruning_season_id = s_con26 and row_number = 5 and segment_number = 1;
  assert sid = e_good, 'T9 the original owner must keep its quarter';
  select count(*) into n
  from public.pruning_row_segments where pruning_entry_id = e_bad and completed;
  assert n = 1, 'T9 the conflicting quarter must be released, leaving 1, got ' || n;
  select estimated_vines_completed into n from public.pruning_entries where id = e_bad;
  assert n = 20, 'T9 vines must be rescaled from 40 to 20 after losing half the quarters, got ' || n;
  select row_equivalents_completed into num from public.pruning_entries where id = e_bad;
  assert num = 0.25, 'T9 row equivalents recomputed, got ' || num;
  assert (r->>'quarters_released')::integer = 1,
    'T9 the release must be reported, got ' || (r->>'quarters_released');
  raise notice 'T9 passed: conflicting quarter released and reported, totals recomputed';

  -- ---- T10. Reversed entries follow their season --------------------------
  select pruning_season_id into sid from public.pruning_entries where id = e5;
  assert sid = c_cf26, 'T10 a reversed 2026 entry must follow the season it belonged to';
  select deleted_at is not null into ok from public.pruning_entries where id = e5;
  assert ok, 'T10 a reversed entry must stay reversed';
  assert (r->>'reversed_entries_moved')::integer = 1,
    'T10 the reversed move must be reported, got ' || (r->>'reversed_entries_moved');
  raise notice 'T10 passed: reversed entries keep their audit place in the right season';

  -- ---- T11. Emptied 2027 rows soft-deleted --------------------------------
  select count(*) into n from public.pruning_seasons
  where id in (s_cf27, s_sb27, s_con27) and deleted_at is null;
  assert n = 0, 'T11 every emptied 2027 season must be soft-deleted, live ' || n;
  select count(*) into n from public.pruning_seasons
  where vineyard_id = v1 and paddock_id = b_cf and season_year = 2026 and deleted_at is null;
  assert n = 1, 'T11 exactly one live 2026 Cab Franc season, found ' || n;
  raise notice 'T11 passed: emptied season rows retired, unique slot freed';

  -- ---- T12. The same-date split is gone -----------------------------------
  select count(*) into n from (
    select e.entry_date
    from public.pruning_entries e join public.pruning_seasons s on s.id = e.pruning_season_id
    where e.vineyard_id = v1 and e.deleted_at is null
    group by e.entry_date
    having count(distinct s.season_year) > 1
  ) t;
  assert n = 0, 'T12 no date may span two season years any more, offenders ' || n;
  raise notice 'T12 passed: 2 Aug 2026 now sits in a single season year';

  -- ---- T13. A correct entry is untouched -----------------------------------
  select pruning_season_id into sid from public.pruning_entries where id = e4;
  assert sid = s_pn26, 'T13 an already-correct entry must not be moved';
  select count(*) into n from public.pruning_season_backfill_log where pruning_entry_id = e4;
  assert n = 0, 'T13 an untouched entry must not appear in the reversal log';
  raise notice 'T13 passed: correctly-assigned entries left alone';

  -- ---- T14. Reversal log and audit history ---------------------------------
  select count(*) into n from public.pruning_season_backfill_log
  where vineyard_id in (v1, v2);
  assert n = 6, 'T14 one log row per moved entry (5 live + 1 reversed), got ' || n;
  select previous_season_id = s_cf27 and new_season_id = c_cf26
     and previous_season_year = 2027 and new_season_year = 2026
    into ok
  from public.pruning_season_backfill_log where pruning_entry_id = e1;
  assert ok, 'T14 the log must record the exact before/after season for a revert';
  select count(*) into n from public.pruning_entry_audit
  where event_type = 'pruning_entry_season_corrected'
    and vineyard_id in (v1, v2);
  assert n = 5, 'T14 one audit row per corrected live entry, got ' || n;
  select detail->>'reason' = 'sql_163_reviewed_backfill'
     and (detail->>'previous_season_year')::integer = 2027
     and (detail->>'season_year')::integer = 2026
    into ok
  from public.pruning_entry_audit
  where pruning_entry_id = e1 and event_type = 'pruning_entry_season_corrected'
  limit 1;
  assert ok, 'T14 the audit detail must record the before/after season year';
  raise notice 'T14 passed: reversal log and audit history written';

  -- ---- T15. Re-running is a no-op -------------------------------------------
  r := public.backfill_pruning_season_assignment(false, v1);
  assert (r->>'entries_corrected')::integer = 0,
    'T15 a second run must find nothing, got ' || (r->>'entries_corrected');
  assert (r->>'remaining_mismatches')::integer = 0, 'T15 still zero mismatches';
  select count(*) into n from public.pruning_season_backfill_log
  where vineyard_id in (v1, v2);
  assert n = 6, 'T15 a no-op run must not add log rows, got ' || n;
  raise notice 'T15 passed: the backfill is idempotent';

  -- ---- T16. Live production data untouched ---------------------------------
  select count(*) into n
  from public.pruning_entries e
  join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.deleted_at is null
    and e.vineyard_id not in (v1, v2)
    and s.season_year is distinct from extract(year from e.entry_date)::integer;
  assert n = v_base,
    'T16 production mismatches must be unchanged: baseline ' || v_base || ', now ' || n;
  select count(*) into n from public.pruning_season_backfill_log
  where vineyard_id not in (v1, v2);
  assert n = 0, 'T16 no production entry may be logged by this suite, got ' || n;
  raise notice 'T16 passed: the % production mismatch(es) are untouched by the suite', v_base;

  raise notice 'SQL 163 pruning season backfill tests: ALL PASSED';
end$$;

rollback;

-- T17. Post-rollback proof: nothing survived. backfill_log_rows is 0 until
-- the real correction is run for the first time.
select
  (select count(*) from auth.users where email like 't163-%@test.local')  as leftover_users,
  (select count(*) from public.vineyards where name like 'T163 %')        as leftover_vineyards,
  (select count(*) from public.paddocks where name like 'T163 %')         as leftover_paddocks,
  (select count(*) from public.pruning_season_backfill_log)               as backfill_log_rows;

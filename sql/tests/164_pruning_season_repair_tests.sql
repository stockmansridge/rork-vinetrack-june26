-- =====================================================================
-- 164_pruning_season_repair_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/164_pruning_season_repair.sql and BEFORE repairing any
-- production row.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production pruning row is created, changed or deleted.
--
-- IMPORTANT: every repair call that WRITES is scoped to a throw-away
-- fixture vineyard (p_vineyard_id or p_entry_ids), so the suite can never
-- correct real data. T0 records the production baseline and T13 proves the
-- suite never moved it. (The one unscoped call in T3 is a DRY RUN, which
-- reads only.)
--
-- Test map
--   T0  Production baseline recorded (never touched by this suite)
--   T1  Objects, security definer, fixed search_path, grants
--   T2  Non-admin and anonymous callers rejected
--   T3  DRY RUN changes nothing and returns the before-and-after list
--   T4  An entry-id scoped run corrects only the listed entry
--   T5  APPLY corrects the season link and PRESERVES everything else
--   T6  Entries land on the canonical deterministic id for year(entry_date)
--   T7  A quarter collision is SKIPPED, never released
--   T8  Reversed entries are excluded unless explicitly included
--   T9  Re-running is a no-op
--   T10 A client-submitted wrong season is ignored AND logged
--   T11 An edit across the year boundary re-points the season (Dec -> Jan)
--   T12 verify_pruning_season_enforcement reports the live write path
--   T13 Production rows unchanged by the whole suite
--   T14 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 164 pruning season repair tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 161 + 164 are applied.
do $$
begin
  if to_regprocedure('public.derive_pruning_season_id(uuid, uuid, integer)') is null then
    raise exception 'SQL 161 not applied — run sql/161_pruning_season_canonical_assignment.sql first.';
  end if;
  if to_regprocedure('public.repair_pruning_entry_seasons(boolean, uuid, uuid[], boolean)') is null then
    raise exception 'SQL 164 not applied — run sql/164_pruning_season_repair.sql first.';
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
  b_ok     uuid := gen_random_uuid();
  b_con    uuid := gen_random_uuid();
  b_f      uuid := gen_random_uuid();
  s_cf27   uuid := gen_random_uuid();
  s_sb27   uuid := gen_random_uuid();
  s_ok26   uuid := gen_random_uuid();
  s_con26  uuid := gen_random_uuid();
  s_con27  uuid := gen_random_uuid();
  s_f27    uuid := gen_random_uuid();
  e1       uuid := gen_random_uuid();
  e2       uuid := gen_random_uuid();
  e_ok     uuid := gen_random_uuid();
  e_rev    uuid := gen_random_uuid();
  e_good   uuid := gen_random_uuid();
  e_con    uuid := gen_random_uuid();
  e_f      uuid := gen_random_uuid();
  e_new1   uuid := gen_random_uuid();
  e_new2   uuid := gen_random_uuid();
  e_dec    uuid := gen_random_uuid();
  c_cf26   uuid;
  c_sb26   uuid;
  r        jsonb;
  n        integer;
  y        integer;
  sid      uuid;
  num      numeric;
  ok       boolean;
  txt      text;
  ts_created timestamptz;
  v_base   integer;
begin
  -- ---- T0. Production baseline -------------------------------------------
  select count(*) into v_base
  from public.pruning_entries e
  left join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.deleted_at is null
    and s.season_year is distinct from extract(year from e.entry_date)::integer;
  raise notice 'T0 baseline: % live production mismatch(es) — this suite never repairs them', v_base;

  -- ---- fixtures ------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t164-admin@test.local','t164-mgr@test.local']) e;
  select id into u_admin from auth.users where email = 't164-admin@test.local';
  select id into u_mgr   from auth.users where email = 't164-mgr@test.local';

  insert into public.profiles (id, email)
  values (u_admin, 't164-admin@test.local'), (u_mgr, 't164-mgr@test.local')
  on conflict (id) do nothing;

  insert into public.system_admins (user_id, email, is_active)
  values (u_admin, 't164-admin@test.local', true)
  on conflict (user_id) do update set is_active = true;

  insert into public.vineyards (id, name) values
    (v1, 'T164 Repair Vineyard'),
    (v2, 'T164 Filter Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v1, u_admin, 'owner'), (v1, u_mgr, 'manager'),
    (v2, u_admin, 'owner'), (v2, u_mgr, 'manager');

  insert into public.paddocks (id, vineyard_id, name) values
    (b_cf,  v1, 'T164 Cab Franc'),
    (b_sb,  v1, 'T164 Sauv Blanc'),
    (b_ok,  v1, 'T164 Correct Block'),
    (b_con, v1, 'T164 Conflict Block'),
    (b_f,   v2, 'T164 Filter Block');

  -- The live defect: 2027-stamped season rows holding 2026 winter pruning.
  insert into public.pruning_seasons (id, vineyard_id, paddock_id, season_year) values
    (s_cf27,  v1, b_cf,  2027),
    (s_sb27,  v1, b_sb,  2027),
    (s_ok26,  v1, b_ok,  2026),
    (s_con26, v1, b_con, 2026),
    (s_con27, v1, b_con, 2027),
    (s_f27,   v2, b_f,   2027);

  -- Vintage 2027 is CORRECT for winter 2026 and must survive the repair.
  insert into public.pruning_entries (
    id, vineyard_id, pruning_season_id, paddock_id, entry_date, worker_or_crew,
    labour_hours, pruning_method, notes, row_equivalents_completed,
    estimated_vines_completed, vintage_year, created_by, deleted_at
  ) values
    (e1,     v1, s_cf27,  b_cf,  date '2026-08-02', 'T164 crew A', 8,   'cane', 'rows 42-44', 0.75, 120, 2027, u_mgr, null),
    (e2,     v1, s_sb27,  b_sb,  date '2026-08-02', 'T164 crew B', 6.5, 'spur', 'rows 66-67', 0.50,  60, 2027, u_mgr, null),
    (e_ok,   v1, s_ok26,  b_ok,  date '2026-07-10', 'T164 crew A', 4,   'spur', '',           0.25,  20, 2027, u_mgr, null),
    (e_rev,  v1, s_cf27,  b_cf,  date '2026-07-20', 'T164 crew A', 2,   'spur', 'reversed',   0,      0, 2027, u_mgr, now()),
    (e_good, v1, s_con26, b_con, date '2026-07-11', 'T164 crew C', 3,   'spur', '',           0.25,  10, 2027, u_mgr, null),
    (e_con,  v1, s_con27, b_con, date '2026-07-11', 'T164 crew C', 5,   'spur', '',           0.50,  40, 2027, u_mgr, null),
    (e_f,    v2, s_f27,   b_f,   date '2026-07-05', 'T164 crew D', 4,   'spur', '',           0.25,  15, 2027, u_mgr, null);

  insert into public.pruning_row_segments (
    vineyard_id, pruning_season_id, paddock_id, row_number, segment_number,
    completed, completed_at, completed_by, pruning_entry_id
  ) values
    (v1, s_cf27,  b_cf,  42, 1, true, now(), 'T164 crew A', e1),
    (v1, s_cf27,  b_cf,  43, 1, true, now(), 'T164 crew A', e1),
    (v1, s_cf27,  b_cf,  44, 1, true, now(), 'T164 crew A', e1),
    (v1, s_sb27,  b_sb,  66, 1, true, now(), 'T164 crew B', e2),
    (v1, s_sb27,  b_sb,  67, 1, true, now(), 'T164 crew B', e2),
    (v1, s_ok26,  b_ok,   1, 1, true, now(), 'T164 crew A', e_ok),
    (v1, s_con26, b_con,  5, 1, true, now(), 'T164 crew C', e_good),
    (v1, s_con27, b_con,  5, 1, true, now(), 'T164 crew C', e_con),   -- collides
    (v1, s_con27, b_con,  6, 1, true, now(), 'T164 crew C', e_con),
    (v2, s_f27,   b_f,    1, 1, true, now(), 'T164 crew D', e_f);

  c_cf26 := public.derive_pruning_season_id(v1, b_cf, 2026);
  c_sb26 := public.derive_pruning_season_id(v1, b_sb, 2026);

  -- ---- T1. Objects, security, grants ---------------------------------------
  assert to_regclass('public.pruning_season_mismatch_log') is not null,
    'T1 the mismatch log table must exist';
  assert to_regprocedure(
    'public.resolve_pruning_season_for_date(uuid, uuid, date, uuid, timestamptz, boolean)') is not null,
    'T1 the shared resolver core must exist';
  assert to_regprocedure('public.verify_pruning_season_enforcement()') is not null,
    'T1 the verification function must exist';

  select p.prosecdef into ok
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'repair_pruning_entry_seasons';
  assert ok, 'T1 the repair must be security definer';

  select coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=public%' into ok
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'repair_pruning_entry_seasons';
  assert ok, 'T1 the repair must pin search_path';

  assert not has_function_privilege('anon',
    'public.repair_pruning_entry_seasons(boolean, uuid, uuid[], boolean)', 'execute'),
    'T1 anon must NOT execute the repair';
  assert has_function_privilege('authenticated',
    'public.repair_pruning_entry_seasons(boolean, uuid, uuid[], boolean)', 'execute'),
    'T1 authenticated must reach it (the admin check is inside)';
  assert not has_function_privilege('authenticated',
    'public.resolve_pruning_season_for_date(uuid, uuid, date, uuid, timestamptz, boolean)', 'execute'),
    'T1 the unauthenticated core must only be reachable through the wrapper';
  assert has_function_privilege('authenticated',
    'public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz)', 'execute'),
    'T1 the SQL 161 wrapper signature must still be granted to clients';
  raise notice 'T1 passed: objects, security definer, fixed search_path, grants';

  -- ---- T2. Only System Administrators may repair ---------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  ok := false;
  begin
    perform * from public.repair_pruning_entry_seasons(true, v1);
  exception when others then ok := true;
  end;
  assert ok, 'T2 a vineyard manager must not run the repair';

  ok := false;
  begin
    perform public.verify_pruning_season_enforcement();
  exception when others then ok := true;
  end;
  assert ok, 'T2 a vineyard manager must not read the enforcement report';

  perform set_config('request.jwt.claims', null, true);
  ok := false;
  begin
    perform * from public.repair_pruning_entry_seasons(true, v1);
  exception when others then ok := true;
  end;
  assert ok, 'T2 an anonymous caller must be rejected';
  raise notice 'T2 passed: non-admin and anonymous callers rejected';

  -- Act as the System Administrator from here on.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);

  -- ---- T3. Dry run changes nothing -----------------------------------------
  drop table if exists t164_out;
  create temp table t164_out as select * from public.repair_pruning_entry_seasons(true, v1);

  select count(*) into n from t164_out;
  assert n = 3, 'T3 the plan must list e1, e2 and the conflicting e_con, got ' || n;
  select count(*) into n from t164_out where action = 'planned';
  assert n = 2, 'T3 exactly two entries are repairable, got ' || n;
  select count(*) into n from t164_out where action = 'skipped';
  assert n = 1, 'T3 the colliding entry must be reported as skipped, got ' || n;
  select count(*) into n from t164_out
  where action = 'planned' and (old_season_year <> 2027 or new_season_year <> 2026 or vintage_year <> 2027);
  assert n = 0, 'T3 every planned row must read 2027 -> 2026 with vintage 2027 unchanged';
  select new_season_id into sid from t164_out where entry_id = e1;
  assert sid = c_cf26, 'T3 the plan must name the canonical deterministic 2026 season id';
  select rows_covered into txt from t164_out where entry_id = e1;
  assert txt = '42–44', 'T3 the report must identify the record by its rows, got ' || coalesce(txt, 'null');
  select count(*) into n from t164_out where action = 'source_season_now_empty';
  assert n = 0, 'T3 a dry run moves nothing, so no season can be reported empty';

  -- Nothing may have changed.
  select count(*) into n from public.pruning_seasons where id in (c_cf26, c_sb26);
  assert n = 0, 'T3 a dry run must not create a season row';
  select pruning_season_id into sid from public.pruning_entries where id = e1;
  assert sid = s_cf27, 'T3 no entry may move during a dry run';
  select count(*) into n from public.pruning_season_backfill_log where vineyard_id in (v1, v2);
  assert n = 0, 'T3 a dry run must not write the reversal log';

  -- The default (no arguments) is a read-only dry run over the whole database.
  select count(*) into n from public.repair_pruning_entry_seasons();
  assert n >= 3, 'T3 the default form must be callable and see at least the fixtures, got ' || n;
  select count(*) into n from public.pruning_seasons where id in (c_cf26, c_sb26);
  assert n = 0, 'T3 the default form must still create nothing';
  raise notice 'T3 passed: dry run is read-only and returns the before/after list';

  -- ---- T4. Entry-id scoped run ---------------------------------------------
  drop table if exists t164_out;
  create temp table t164_out as
    select * from public.repair_pruning_entry_seasons(false, null, array[e2]::uuid[]);

  select count(*) into n from t164_out where action = 'repaired';
  assert n = 1, 'T4 exactly the listed entry must be repaired, got ' || n;
  select pruning_season_id into sid from public.pruning_entries where id = e2;
  assert sid = c_sb26, 'T4 e2 must sit on the canonical 2026 Sauv Blanc season';
  select pruning_season_id into sid from public.pruning_entries where id = e1;
  assert sid = s_cf27, 'T4 an unlisted entry must not move';
  select count(*) into n from public.pruning_row_segments
  where pruning_entry_id = e2 and pruning_season_id = c_sb26 and completed;
  assert n = 2, 'T4 both quarters must follow the entry, still completed, got ' || n;
  select vintage_year into y from public.pruning_entries where id = e2;
  assert y = 2027, 'T4 vintage 2027 must be preserved, got ' || y;
  raise notice 'T4 passed: an entry-id scoped repair touches only those entries';

  -- ---- T5. Apply + preservation --------------------------------------------
  select created_at into ts_created from public.pruning_entries where id = e1;
  drop table if exists t164_out;
  create temp table t164_out as select * from public.repair_pruning_entry_seasons(false, v1);

  select count(*) into n from t164_out where action = 'repaired';
  assert n = 1, 'T5 e1 must be repaired, got ' || n;
  select count(*) into n from t164_out where action = 'skipped';
  assert n = 1, 'T5 the colliding entry must still be skipped, got ' || n;
  select count(*) into n from t164_out where action = 'source_season_now_empty';
  assert n = 1, 'T5 the emptied 2027 Cab Franc row must be reported, got ' || n;

  select pruning_season_id into sid from public.pruning_entries where id = e1;
  assert sid = c_cf26, 'T5 e1 must sit on the canonical 2026 season';

  -- Everything else about the record is identical.
  select vintage_year = 2027
     and entry_date = date '2026-08-02'
     and worker_or_crew = 'T164 crew A'
     and labour_hours = 8
     and pruning_method = 'cane'
     and notes = 'rows 42-44'
     and row_equivalents_completed = 0.75
     and estimated_vines_completed = 120
     and created_by = u_mgr
     and created_at = ts_created
     and work_task_id is null
     and paddock_id = b_cf
     and deleted_at is null
    into ok
  from public.pruning_entries where id = e1;
  assert ok, 'T5 only the season link may change — vintage, totals, worker, creator, times preserved';

  select updated_at > ts_created into ok from public.pruning_entries where id = e1;
  assert ok, 'T5 the normal update timestamp must move';

  select count(*) into n from public.pruning_row_segments
  where pruning_entry_id = e1 and pruning_season_id = c_cf26 and completed;
  assert n = 3, 'T5 all three quarters must follow the entry, got ' || n;
  select count(*) into n from public.pruning_row_segments
  where pruning_entry_id = e1 and completed_by = 'T164 crew A';
  assert n = 3, 'T5 quarter attribution must be untouched, got ' || n;
  select count(*) into n from public.pruning_row_segments
  where pruning_season_id = s_cf27 and pruning_entry_id = e1;
  assert n = 0, 'T5 no quarter may be left behind in the old season, got ' || n;

  select count(*) into n from public.pruning_season_backfill_log where pruning_entry_id = e1;
  assert n = 1, 'T5 one reversal-log row per repaired entry, got ' || n;
  select previous_season_id = s_cf27 and previous_season_year = 2027
     and new_season_id = c_cf26 and new_season_year = 2026
     and quarters_before = 3 and quarters_after = 3 and quarters_released = 0
    into ok
  from public.pruning_season_backfill_log where pruning_entry_id = e1;
  assert ok, 'T5 the log must record the exact before/after with no quarter released';
  select count(*) into n from public.pruning_entry_audit
  where pruning_entry_id = e1 and event_type = 'pruning_entry_season_corrected';
  assert n = 1, 'T5 the correction must be audited, got ' || n;
  select detail->>'reason' = 'sql_164_targeted_repair'
     and (detail->>'vintage_year_preserved')::integer = 2027
    into ok
  from public.pruning_entry_audit
  where pruning_entry_id = e1 and event_type = 'pruning_entry_season_corrected' limit 1;
  assert ok, 'T5 the audit detail must record the preserved vintage';
  raise notice 'T5 passed: season link repaired, every other field preserved';

  -- ---- T6. Canonical target + invariant ------------------------------------
  select s.season_year into y
  from public.pruning_entries e join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.id = e1;
  assert y = 2026, 'T6 the stored season row must be 2026, got ' || y;
  select count(*) into n from public.pruning_seasons
  where vineyard_id = v1 and paddock_id = b_cf and season_year = 2026 and deleted_at is null;
  assert n = 1, 'T6 exactly one live 2026 Cab Franc season, found ' || n;
  select pruning_season_id into sid from public.pruning_entries where id = e_ok;
  assert sid = s_ok26, 'T6 an already-correct entry must never be touched';
  select count(*) into n from public.pruning_season_backfill_log where pruning_entry_id = e_ok;
  assert n = 0, 'T6 an untouched entry must not be logged';
  raise notice 'T6 passed: canonical deterministic id, correct entries left alone';

  -- ---- T7. Collision is skipped, never released ----------------------------
  select pruning_season_id into sid from public.pruning_entries where id = e_con;
  assert sid = s_con27, 'T7 a colliding entry must not move';
  select count(*) into n from public.pruning_row_segments
  where pruning_entry_id = e_con and completed;
  assert n = 2, 'T7 both of its quarters must stay completed and attributed, got ' || n;
  select pruning_entry_id into sid from public.pruning_row_segments
  where pruning_season_id = s_con26 and row_number = 5 and segment_number = 1;
  assert sid = e_good, 'T7 the canonical season''s own quarter must keep its owner';
  select estimated_vines_completed into n from public.pruning_entries where id = e_con;
  assert n = 40, 'T7 vines must not be rescaled by a skipped entry, got ' || n;
  select row_equivalents_completed into num from public.pruning_entries where id = e_con;
  assert num = 0.50, 'T7 row equivalents must not be recomputed, got ' || num;
  select count(*) into n from public.pruning_season_backfill_log where pruning_entry_id = e_con;
  assert n = 0, 'T7 a skipped entry must not be logged as repaired';
  select note into txt from t164_out where entry_id = e_con;
  assert txt like '%already recorded in the canonical season%',
    'T7 the reason must be explicit, got ' || coalesce(txt, 'null');
  raise notice 'T7 passed: a quarter collision is reported for review, nothing released';

  -- ---- T8. Reversed entries excluded by default ----------------------------
  select pruning_season_id into sid from public.pruning_entries where id = e_rev;
  assert sid = s_cf27, 'T8 a reversed entry must be left alone by default';
  select count(*) into n
  from public.repair_pruning_entry_seasons(true, v1, null, true)
  where action = 'planned' and entry_id = e_rev;
  assert n = 1, 'T8 opting in must plan the reversed entry, got ' || n;

  perform * from public.repair_pruning_entry_seasons(false, null, array[e_rev]::uuid[], true);
  select pruning_season_id into sid from public.pruning_entries where id = e_rev;
  assert sid = c_cf26, 'T8 the reversed entry must follow the season of its work year';
  select deleted_at is not null into ok from public.pruning_entries where id = e_rev;
  assert ok, 'T8 a reversed entry must stay reversed';
  raise notice 'T8 passed: reversed audit history only moves when explicitly included';

  -- ---- T9. Idempotent ------------------------------------------------------
  drop table if exists t164_out;
  create temp table t164_out as select * from public.repair_pruning_entry_seasons(false, v1);
  select count(*) into n from t164_out where action = 'repaired';
  assert n = 0, 'T9 a second run must repair nothing, got ' || n;
  select count(*) into n from t164_out where action = 'skipped';
  assert n = 1, 'T9 the collision must still be reported, got ' || n;
  select count(*) into n from public.pruning_season_backfill_log where vineyard_id = v1;
  assert n = 3, 'T9 a no-op run must not add log rows (e1, e2, e_rev), got ' || n;
  raise notice 'T9 passed: the repair is idempotent';

  -- ---- T10. A wrong client season is ignored AND logged --------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);

  r := public.record_pruning_entry(
    p_id => e_new1, p_vineyard_id => v1, p_season_id => s_cf27,       -- the 2027 row
    p_paddock_id => b_cf, p_season_year => 2027, p_entry_date => date '2026-08-10',
    p_worker => 'T164 crew A', p_segments => '[{"row":80,"segment":1}]'::jsonb);
  assert (r->>'season_year')::integer = 2026,
    'T10 August 2026 work must be season 2026, got ' || coalesce(r->>'season_year', 'null');
  assert (r->>'season_id')::uuid = c_cf26, 'T10 the canonical season must be stored';
  assert (r->>'season_corrected')::boolean, 'T10 the correction must be reported to the client';
  select vintage_year into y from public.pruning_entries where id = e_new1;
  assert y = public.resolve_vineyard_vintage_year(v1, date '2026-08-10'),
    'T10 the vintage must still come from the SQL 119 resolver';

  select occurrences, submitted_season_year, canonical_season_year
    into n, y, num
  from public.pruning_season_mismatch_log
  where vineyard_id = v1 and paddock_id = b_cf and entry_date = date '2026-08-10'
    and submitted_season_id = s_cf27;
  assert n = 1, 'T10 the mismatch must be logged once, got ' || coalesce(n::text, 'null');
  assert y = 2027, 'T10 the submitted season year must be recorded, got ' || coalesce(y::text, 'null');
  assert num = 2026, 'T10 the canonical season year must be recorded, got ' || coalesce(num::text, 'null');

  -- A second submission of the same wrong season increments, never duplicates.
  perform public.record_pruning_entry(
    p_id => e_new2, p_vineyard_id => v1, p_season_id => s_cf27,
    p_paddock_id => b_cf, p_season_year => 2027, p_entry_date => date '2026-08-10',
    p_worker => 'T164 crew A', p_segments => '[{"row":81,"segment":1}]'::jsonb);
  select count(*), max(occurrences) into n, y
  from public.pruning_season_mismatch_log
  where vineyard_id = v1 and paddock_id = b_cf and entry_date = date '2026-08-10'
    and submitted_season_id = s_cf27;
  assert n = 1, 'T10 the log must deduplicate, rows ' || n;
  assert y = 2, 'T10 the occurrence counter must increment, got ' || y;
  raise notice 'T10 passed: a stale client season is ignored, corrected and logged';

  -- ---- T11. Edit across the year boundary ----------------------------------
  perform public.record_pruning_entry(
    p_id => e_dec, p_vineyard_id => v1, p_season_id => c_sb26,
    p_paddock_id => b_sb, p_season_year => 2026, p_entry_date => date '2026-12-31',
    p_worker => 'T164 crew B', p_segments => '[{"row":90,"segment":1}]'::jsonb);
  select s.season_year into y
  from public.pruning_entries e join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.id = e_dec;
  assert y = 2026, 'T11 31 Dec 2026 work is season 2026, got ' || y;

  r := public.update_pruning_entry(
    p_entry_id => e_dec, p_entry_date => date '2027-01-01', p_worker => 'T164 crew B',
    p_segments => '[{"row":90,"segment":1}]'::jsonb, p_client_updated_at => now());
  assert (r->>'season_changed')::boolean, 'T11 a year-crossing edit must re-point the season';
  assert (r->>'season_year')::integer = 2027, 'T11 the entry now belongs to season 2027';
  select count(*) into n
  from public.pruning_row_segments g
  join public.pruning_entries e on e.id = g.pruning_entry_id
  where g.pruning_entry_id = e_dec and g.pruning_season_id = e.pruning_season_id;
  assert n = 1, 'T11 the quarter must travel with the entry, got ' || n;
  raise notice 'T11 passed: 31 Dec 2026 -> 1 Jan 2027 moves the entry to season 2027';

  -- ---- T12. Live enforcement report ----------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);
  r := public.verify_pruning_season_enforcement();
  assert (r->>'shared_core_present')::boolean, 'T12 the shared resolver core must be reported present';
  assert (r->>'mismatch_log_present')::boolean, 'T12 the mismatch log must be reported present';
  assert jsonb_array_length(r->'entry_writers') >= 2,
    'T12 the report must list the routines that write pruning_entries';
  select count(*) into n
  from jsonb_array_elements(r->'entry_writers') w
  where w->>'routine' like 'record_pruning_entry(%'
    and (w->>'sets_season_link')::boolean
    and (w->>'resolves_season_server_side')::boolean;
  assert n >= 1, 'T12 record_pruning_entry must resolve the season server-side';
  select count(*) into n
  from jsonb_array_elements(r->'entry_writers') w
  where w->>'routine' like 'update_pruning_entry(%'
    and (w->>'sets_season_link')::boolean
    and (w->>'resolves_season_server_side')::boolean;
  assert n >= 1, 'T12 update_pruning_entry must resolve the season server-side';
  assert (r->'mismatch_log'->>'rows')::integer >= 1, 'T12 the report must surface the logged mismatch';

  -- A superseded signature of a write RPC left installed is still reachable by
  -- an older build. Surfaced loudly rather than failing the suite, because it
  -- is a property of the deployed database, not of this migration.
  if jsonb_array_length(r->'unprotected_writers') > 0 then
    raise notice 'T12 ATTENTION: % routine(s) write the season link WITHOUT the resolver: %',
      jsonb_array_length(r->'unprotected_writers'), r->'unprotected_writers';
  else
    raise notice 'T12 passed: every client-reachable season writer resolves server-side';
  end if;

  -- ---- T13. Production untouched -------------------------------------------
  select count(*) into n
  from public.pruning_entries e
  left join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.deleted_at is null
    and e.vineyard_id not in (v1, v2)
    and s.season_year is distinct from extract(year from e.entry_date)::integer;
  assert n = v_base,
    'T13 production mismatches must be unchanged: baseline ' || v_base || ', now ' || n;
  select count(*) into n from public.pruning_season_backfill_log
  where vineyard_id not in (v1, v2);
  assert n = 0, 'T13 no production entry may be repaired by this suite, got ' || n;
  raise notice 'T13 passed: the % production mismatch(es) are untouched', v_base;

  raise notice 'SQL 164 pruning season repair tests: ALL PASSED';
end$$;

rollback;

-- T14. Post-rollback proof: nothing survived.
select
  (select count(*) from auth.users where email like 't164-%@test.local') as leftover_users,
  (select count(*) from public.vineyards where name like 'T164 %')       as leftover_vineyards,
  (select count(*) from public.paddocks where name like 'T164 %')        as leftover_paddocks,
  (select count(*) from public.pruning_season_mismatch_log)              as mismatch_log_rows;

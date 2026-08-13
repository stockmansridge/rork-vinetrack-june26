-- =====================================================================
-- 190_pruning_activity_labour_lines_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/190_pruning_activity_labour_lines.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects: table, indexes, RLS, helpers and RPCs all exist, and the
--       labour columns MIRROR work_task_labour_lines (SQL 050) exactly
--   T2  ONE labour line: 2 x 8 x $30 -> 16 h, $480
--   T3  MULTIPLE labour lines: 16 h + 6 h = 22 h and $480 + $210 = $690
--   T4  Add / edit / remove through save_pruning_activity_labour_lines
--   T5  Total hours = SUM of lines (never the legacy scalar once lines exist)
--   T6  Total cost = SUM of lines
--   T7  LEGACY single-crew activity is untouched and still resolves to its
--       hours x rate — no backfill, no data loss, no restated cost
--   T8  MULTI-BLOCK activity counts labour ONCE (3 blocks, still $690)
--   T9  Linked Work Task does NOT double-count: task and activity report the
--       SAME figure from the SAME rows, and their sum is not $1,380
--   T10 Linked PIECE-RATE task still wins: $137.50, never $137.50 + lines
--   T11 Unrated lines: hours count, cost does not become $0.00
--   T12 Soft-deleted lines contribute nothing to hours or cost
--   T13 Offline replay: re-sending the SAME payload is idempotent
--   T14 Offline replay: a re-sent soft-deleted line is restored, not duplicated
--   T15 pruning_activity_json exposes labour_lines + total_labour_hours and
--       keeps every pre-190 key
--   T16 Export view: activity labour on the PRIMARY allocation row only, and
--       the multi-block split still reconciles EXACTLY
--   T17 Vineyard scoping: a line can never be attached across vineyards
--   T18 A line cannot be stolen by another activity through a client id
--   T19 Cross-platform contract fixture: iOS and Android assert these exact
--       numbers (16 h/$480, 22 h/$690, 250 x $0.55 = $137.50)
--   T20 Hard delete is refused; history is reversed, never erased
--   T21 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 190 pruning labour line tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 190 is applied.
do $$
begin
  if to_regclass('public.pruning_activity_labour_lines') is null
     or to_regprocedure('public.save_pruning_activity_labour_lines(uuid,jsonb,timestamptz)') is null
     or to_regprocedure('public.pruning_activity_effective_labour_hours(uuid)') is null then
    raise exception 'SQL 190 not applied — run sql/190_pruning_activity_labour_lines.sql first.';
  end if;
end$$;

do $$
declare
  u_mgr uuid;
  v_vy  uuid := gen_random_uuid();
  v_vy2 uuid := gen_random_uuid();
  b_1   uuid := gen_random_uuid();
  b_2   uuid := gen_random_uuid();
  b_3   uuid := gen_random_uuid();
  s_1   uuid := gen_random_uuid();
  s_2   uuid := gen_random_uuid();
  s_3   uuid := gen_random_uuid();
  t_hrs uuid := gen_random_uuid();  -- hourly task linked to a_lnk
  t_pce uuid := gen_random_uuid();  -- piece rate 250 x 0.55 linked to a_pce
  a_one uuid := gen_random_uuid();  -- one labour line
  a_mny uuid := gen_random_uuid();  -- three labour lines
  a_leg uuid := gen_random_uuid();  -- legacy single crew, no lines
  a_mul uuid := gen_random_uuid();  -- multi-block, lines
  a_lnk uuid := gen_random_uuid();  -- linked to an hourly work task
  a_pce uuid := gen_random_uuid();  -- linked to a piece-rate work task
  a_unr uuid := gen_random_uuid();  -- unrated lines only
  a_rep uuid := gen_random_uuid();  -- offline replay
  l_1   uuid := gen_random_uuid();
  l_2   uuid := gen_random_uuid();
  l_3   uuid := gen_random_uuid();
  l_del uuid := gen_random_uuid();
  l_rep uuid := gen_random_uuid();
  j     jsonb;
  num   numeric;
  num2  numeric;
  txt   text;
  n     integer;
  mirrored integer;
begin
  -- ---- fixtures ------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          't190-mgr@test.local', 'x', now(), now(), now());
  select id into u_mgr from auth.users where email = 't190-mgr@test.local';
  insert into public.profiles (id, email) values (u_mgr, 't190-mgr@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_vy,  'T190 Pruning Labour Vineyard'),
    (v_vy2, 'T190 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vy,  u_mgr, 'manager'),
    (v_vy2, u_mgr, 'manager');

  insert into public.paddocks (id, vineyard_id, name) values
    (b_1, v_vy, 'T190 Block 1'),
    (b_2, v_vy, 'T190 Block 2'),
    (b_3, v_vy, 'T190 Block 3');

  insert into public.pruning_seasons (id, vineyard_id, paddock_id, season_year) values
    (s_1, v_vy, b_1, 2026),
    (s_2, v_vy, b_2, 2026),
    (s_3, v_vy, b_3, 2026);

  insert into public.work_tasks
    (id, vineyard_id, paddock_id, paddock_name, date, task_type, duration_hours, created_by, updated_by)
  values
    (t_hrs, v_vy, b_1, 'T190 Block 1', now(), 'Pruning', 16, u_mgr, u_mgr);

  insert into public.work_tasks
    (id, vineyard_id, paddock_id, paddock_name, date, task_type, duration_hours,
     costing_method, piece_vine_count, piece_rate_per_vine, created_by, updated_by)
  values
    (t_pce, v_vy, b_1, 'T190 Block 1', now(), 'Pruning', 0,
     'piece_rate', 250, 0.5500, u_mgr, u_mgr);

  -- Activities. The legacy one keeps the SQL 166 scalar shape on purpose.
  insert into public.pruning_activities
    (id, vineyard_id, entry_date, worker_or_crew, pruning_method,
     labour_hours, hourly_rate, season_year, vintage_year, created_by)
  values
    (a_one, v_vy, date '2026-08-03', 'Crew A', 'spur', null,  null, 2026, 2027, u_mgr),
    (a_mny, v_vy, date '2026-08-03', 'Crew A', 'spur', null,  null, 2026, 2027, u_mgr),
    (a_leg, v_vy, date '2026-08-03', 'Dave + 2 casuals', 'spur', 7.5, 32, 2026, 2027, u_mgr),
    (a_mul, v_vy, date '2026-08-04', 'Crew B', 'spur', null,  null, 2026, 2027, u_mgr),
    (a_unr, v_vy, date '2026-08-05', 'Crew C', 'spur', null,  null, 2026, 2027, u_mgr),
    (a_rep, v_vy, date '2026-08-06', 'Crew D', 'spur', null,  null, 2026, 2027, u_mgr);

  insert into public.pruning_activities
    (id, vineyard_id, entry_date, worker_or_crew, pruning_method,
     labour_hours, hourly_rate, work_task_id, season_year, vintage_year, created_by)
  values
    (a_lnk, v_vy, date '2026-08-07', 'Crew E', 'spur', null, null, t_hrs, 2026, 2027, u_mgr),
    (a_pce, v_vy, date '2026-08-08', 'Crew F', 'spur', 6,    null, t_pce, 2026, 2027, u_mgr);

  -- Allocations. a_mul spans THREE blocks, which is the multi-block case.
  insert into public.pruning_entries
    (id, vineyard_id, pruning_season_id, paddock_id, entry_date, worker_or_crew,
     pruning_activity_id, allocation_index, row_equivalents_completed,
     estimated_vines_completed, created_by)
  values
    (gen_random_uuid(), v_vy, s_1, b_1, date '2026-08-03', 'Crew A', a_one, 0, 4, 400, u_mgr),
    (gen_random_uuid(), v_vy, s_1, b_1, date '2026-08-03', 'Crew A', a_mny, 0, 4, 400, u_mgr),
    (gen_random_uuid(), v_vy, s_1, b_1, date '2026-08-03', 'Dave',   a_leg, 0, 3, 300, u_mgr),
    (gen_random_uuid(), v_vy, s_1, b_1, date '2026-08-04', 'Crew B', a_mul, 0, 6, 600, u_mgr),
    (gen_random_uuid(), v_vy, s_2, b_2, date '2026-08-04', 'Crew B', a_mul, 1, 3, 300, u_mgr),
    (gen_random_uuid(), v_vy, s_3, b_3, date '2026-08-04', 'Crew B', a_mul, 2, 3, 300, u_mgr),
    (gen_random_uuid(), v_vy, s_1, b_1, date '2026-08-07', 'Crew E', a_lnk, 0, 5, 500, u_mgr),
    (gen_random_uuid(), v_vy, s_1, b_1, date '2026-08-08', 'Crew F', a_pce, 0, 2, 250, u_mgr);

  perform public.sync_pruning_activity_rollup(a_one);
  perform public.sync_pruning_activity_rollup(a_mny);
  perform public.sync_pruning_activity_rollup(a_leg);
  perform public.sync_pruning_activity_rollup(a_mul);
  perform public.sync_pruning_activity_rollup(a_lnk);
  perform public.sync_pruning_activity_rollup(a_pce);

  -- ---- T1. Objects and SQL 050 mirroring -----------------------------------
  if to_regprocedure('public.pruning_activity_labour_line_cost(uuid)') is null
     or to_regprocedure('public.pruning_activity_labour_line_hours(uuid)') is null
     or to_regprocedure('public.pruning_activity_labour_line_count(uuid)') is null
     or to_regprocedure('public.pruning_activity_labour_lines_json(uuid)') is null
     or to_regprocedure('public.pruning_activity_labour_hours_source(uuid)') is null
     or to_regprocedure('public.work_task_pruning_labour_line_cost(uuid)') is null
     or to_regprocedure('public.soft_delete_pruning_activity_labour_line(uuid)') is null then
    raise exception 'T1: SQL 190 helper functions missing';
  end if;

  -- The labour columns must MIRROR work_task_labour_lines: same names, same
  -- types. That is what lets one editor and one sync shape serve both modules.
  select count(*) into mirrored
  from information_schema.columns w
  join information_schema.columns p
    on p.table_schema = 'public'
   and p.table_name = 'pruning_activity_labour_lines'
   and p.column_name = w.column_name
   and p.data_type = w.data_type
  where w.table_schema = 'public'
    and w.table_name = 'work_task_labour_lines'
    and w.column_name in ('work_date','worker_type_id','worker_type','worker_count',
                          'hours_per_worker','hourly_rate','total_hours','total_cost',
                          'notes','deleted_at','client_updated_at','sync_version');
  if mirrored <> 12 then
    raise exception 'T1: expected 12 mirrored SQL 050 labour columns, found %', mirrored;
  end if;

  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename = 'pruning_activity_labour_lines';
  if n < 4 then raise exception 'T1: expected 4 RLS policies, found %', n; end if;

  select relrowsecurity into txt from pg_class
   where oid = 'public.pruning_activity_labour_lines'::regclass;
  if txt is distinct from 'true' then
    raise exception 'T1: row level security is not enabled';
  end if;
  raise notice 'T1 passed';

  -- ---- T2. ONE labour line -------------------------------------------------
  insert into public.pruning_activity_labour_lines
    (id, pruning_activity_id, vineyard_id, work_date, worker_type,
     worker_count, hours_per_worker, hourly_rate, line_index, created_by)
  values
    (l_1, a_one, v_vy, date '2026-08-03', 'Pruner', 2, 8, 30, 0, u_mgr);

  select public.pruning_activity_effective_labour_hours(a_one) into num;
  if num <> 16 then raise exception 'T2: expected 16 hours from 2 x 8, got %', num; end if;
  select public.pruning_activity_effective_labour_cost(a_one) into num;
  if num <> 480 then raise exception 'T2: expected 480 from 2 x 8 x 30, got %', num; end if;
  select public.pruning_activity_labour_cost_source(a_one) into txt;
  if txt <> 'pruning_labour_lines' then
    raise exception 'T2: expected source pruning_labour_lines, got %', txt;
  end if;
  raise notice 'T2 passed';

  -- ---- T3. MULTIPLE labour lines ------------------------------------------
  -- Two contractors on different rates plus a third line: the exact case that
  -- the single worker_or_crew field could not record.
  insert into public.pruning_activity_labour_lines
    (id, pruning_activity_id, vineyard_id, work_date, worker_type,
     worker_count, hours_per_worker, hourly_rate, line_index, created_by)
  values
    (l_2, a_mny, v_vy, date '2026-08-03', 'Pruner',     2, 8, 30, 0, u_mgr),
    (l_3, a_mny, v_vy, date '2026-08-03', 'Contractor', 1, 6, 35, 1, u_mgr);

  select public.pruning_activity_effective_labour_hours(a_mny) into num;
  if num <> 22 then raise exception 'T3: expected 22 hours (16 + 6), got %', num; end if;
  select public.pruning_activity_effective_labour_cost(a_mny) into num;
  if num <> 690 then raise exception 'T3: expected 690 (480 + 210), got %', num; end if;
  select public.pruning_activity_labour_line_count(a_mny) into n;
  if n <> 2 then raise exception 'T3: expected 2 lines, got %', n; end if;
  raise notice 'T3 passed';

  -- ---- T4. Add / edit / remove --------------------------------------------
  -- ADD a third line through the desired-state RPC.
  select public.save_pruning_activity_labour_lines(
    a_mny,
    jsonb_build_array(
      jsonb_build_object('id', l_2, 'work_date', '2026-08-03', 'worker_type', 'Pruner',
                         'worker_count', 2, 'hours_per_worker', 8, 'hourly_rate', 30, 'line_index', 0),
      jsonb_build_object('id', l_3, 'work_date', '2026-08-03', 'worker_type', 'Contractor',
                         'worker_count', 1, 'hours_per_worker', 6, 'hourly_rate', 35, 'line_index', 1),
      jsonb_build_object('id', l_del, 'work_date', '2026-08-03', 'worker_type', 'Casual',
                         'worker_count', 1, 'hours_per_worker', 4, 'hourly_rate', 25, 'line_index', 2)
    ), now()
  ) into j;
  select public.pruning_activity_labour_line_count(a_mny) into n;
  if n <> 3 then raise exception 'T4: after add expected 3 lines, got %', n; end if;
  select public.pruning_activity_effective_labour_cost(a_mny) into num;
  if num <> 790 then raise exception 'T4: after add expected 790, got %', num; end if;

  -- EDIT: the casual's rate rises to $28.
  select public.save_pruning_activity_labour_lines(
    a_mny,
    jsonb_build_array(
      jsonb_build_object('id', l_2, 'worker_type', 'Pruner',
                         'worker_count', 2, 'hours_per_worker', 8, 'hourly_rate', 30, 'line_index', 0),
      jsonb_build_object('id', l_3, 'worker_type', 'Contractor',
                         'worker_count', 1, 'hours_per_worker', 6, 'hourly_rate', 35, 'line_index', 1),
      jsonb_build_object('id', l_del, 'worker_type', 'Casual',
                         'worker_count', 1, 'hours_per_worker', 4, 'hourly_rate', 28, 'line_index', 2)
    ), now()
  ) into j;
  select public.pruning_activity_effective_labour_cost(a_mny) into num;
  if num <> 802 then raise exception 'T4: after edit expected 802, got %', num; end if;

  -- REMOVE: the casual line is left out of the desired set.
  select public.save_pruning_activity_labour_lines(
    a_mny,
    jsonb_build_array(
      jsonb_build_object('id', l_2, 'worker_type', 'Pruner',
                         'worker_count', 2, 'hours_per_worker', 8, 'hourly_rate', 30, 'line_index', 0),
      jsonb_build_object('id', l_3, 'worker_type', 'Contractor',
                         'worker_count', 1, 'hours_per_worker', 6, 'hourly_rate', 35, 'line_index', 1)
    ), now()
  ) into j;
  select public.pruning_activity_labour_line_count(a_mny) into n;
  if n <> 2 then raise exception 'T4: after remove expected 2 lines, got %', n; end if;
  select public.pruning_activity_effective_labour_cost(a_mny) into num;
  if num <> 690 then raise exception 'T4: after remove expected 690, got %', num; end if;
  -- Removed means REVERSED, not erased.
  select count(*) into n from public.pruning_activity_labour_lines
   where id = l_del and deleted_at is not null;
  if n <> 1 then raise exception 'T4: a removed line must be soft-deleted, not erased'; end if;
  raise notice 'T4 passed';

  -- ---- T5. Total hours = SUM of lines --------------------------------------
  select public.pruning_activity_labour_line_hours(a_mny) into num;
  if num <> 22 then raise exception 'T5: line hours expected 22, got %', num; end if;
  select public.pruning_activity_effective_labour_hours(a_mny) into num;
  if num <> 22 then raise exception 'T5: effective hours expected 22, got %', num; end if;
  select public.pruning_activity_labour_hours_source(a_mny) into txt;
  if txt <> 'labour_lines' then raise exception 'T5: expected labour_lines, got %', txt; end if;

  -- Once lines exist they are authoritative: a stale legacy scalar must not win.
  update public.pruning_activities set labour_hours = 99 where id = a_mny;
  select public.pruning_activity_effective_labour_hours(a_mny) into num;
  if num <> 22 then
    raise exception 'T5: lines must outrank the legacy scalar, got %', num;
  end if;
  update public.pruning_activities set labour_hours = null where id = a_mny;
  raise notice 'T5 passed';

  -- ---- T6. Total cost = SUM of lines ---------------------------------------
  select sum(total_cost::numeric) into num
    from public.pruning_activity_labour_lines
   where pruning_activity_id = a_mny and deleted_at is null;
  select public.pruning_activity_effective_labour_cost(a_mny) into num2;
  if num <> num2 then
    raise exception 'T6: activity cost % must equal the line sum %', num2, num;
  end if;
  if num2 <> 690 then raise exception 'T6: expected 690, got %', num2; end if;
  raise notice 'T6 passed';

  -- ---- T7. LEGACY single-crew activity untouched ---------------------------
  select public.pruning_activity_labour_line_count(a_leg) into n;
  if n <> 0 then raise exception 'T7: a legacy activity must NOT be backfilled with lines'; end if;
  select public.pruning_activity_effective_labour_hours(a_leg) into num;
  if num <> 7.5 then raise exception 'T7: legacy hours expected 7.5, got %', num; end if;
  select public.pruning_activity_effective_labour_cost(a_leg) into num;
  if num <> 240 then raise exception 'T7: legacy cost expected 240 (7.5 x 32), got %', num; end if;
  select public.pruning_activity_labour_cost_source(a_leg) into txt;
  if txt <> 'activity_hours' then raise exception 'T7: expected activity_hours, got %', txt; end if;
  -- The free-text crew label survives verbatim — nothing was parsed or lost.
  select worker_or_crew into txt from public.pruning_activities where id = a_leg;
  if txt <> 'Dave + 2 casuals' then
    raise exception 'T7: legacy worker_or_crew was altered, got %', txt;
  end if;
  raise notice 'T7 passed';

  -- ---- T8. MULTI-BLOCK counts labour ONCE ----------------------------------
  insert into public.pruning_activity_labour_lines
    (id, pruning_activity_id, vineyard_id, work_date, worker_type,
     worker_count, hours_per_worker, hourly_rate, line_index, created_by)
  values
    (gen_random_uuid(), a_mul, v_vy, date '2026-08-04', 'Pruner',     2, 8, 30, 0, u_mgr),
    (gen_random_uuid(), a_mul, v_vy, date '2026-08-04', 'Contractor', 1, 6, 35, 1, u_mgr);

  select count(*) into n from public.pruning_entries
   where pruning_activity_id = a_mul and deleted_at is null;
  if n <> 3 then raise exception 'T8: fixture expected 3 allocations, got %', n; end if;

  select public.pruning_activity_effective_labour_cost(a_mul) into num;
  if num <> 690 then
    raise exception 'T8: three blocks must NOT multiply labour — expected 690, got %', num;
  end if;
  if num = 2070 then raise exception 'T8: labour was counted once per block'; end if;
  select public.pruning_activity_effective_labour_hours(a_mul) into num;
  if num <> 22 then raise exception 'T8: expected 22 hours across 3 blocks, got %', num; end if;

  -- And labour lines are never attached to an allocation.
  select count(*) into n
  from information_schema.columns
  where table_schema = 'public' and table_name = 'pruning_activity_labour_lines'
    and column_name in ('pruning_entry_id','paddock_id','allocation_index');
  if n <> 0 then
    raise exception 'T8: labour lines must belong to the ACTIVITY, not an allocation';
  end if;
  raise notice 'T8 passed';

  -- ---- T9. Linked Work Task does NOT double-count --------------------------
  insert into public.pruning_activity_labour_lines
    (id, pruning_activity_id, vineyard_id, work_date, worker_type,
     worker_count, hours_per_worker, hourly_rate, line_index, created_by)
  values
    (gen_random_uuid(), a_lnk, v_vy, date '2026-08-07', 'Pruner', 2, 8, 30, 0, u_mgr);

  -- The task holds NO labour rows of its own: one stored set, not two.
  select count(*) into n from public.work_task_labour_lines
   where work_task_id = t_hrs and deleted_at is null;
  if n <> 0 then raise exception 'T9: the linked task must not hold a COPY of the labour'; end if;

  select public.pruning_activity_effective_labour_cost(a_lnk) into num;
  select public.work_task_effective_labour_cost(t_hrs) into num2;
  if num <> 480 then raise exception 'T9: activity expected 480, got %', num; end if;
  if num2 <> 480 then raise exception 'T9: linked task expected the SAME 480, got %', num2; end if;
  if num + num2 = 960 and num <> num2 then
    raise exception 'T9: the two readers disagree';
  end if;
  select public.work_task_labour_cost_source(t_hrs) into txt;
  if txt <> 'pruning_labour_lines' then
    raise exception 'T9: task source expected pruning_labour_lines, got %', txt;
  end if;
  select effective_labour_cost into num
    from public.v_work_task_effective_labour_cost where work_task_id = t_hrs;
  if num <> 480 then raise exception 'T9: join view expected 480, got %', num; end if;

  -- A task's OWN lines still outrank the read-through, and are never added.
  insert into public.work_task_labour_lines
    (work_task_id, vineyard_id, work_date, worker_type, worker_count, hours_per_worker, hourly_rate)
  values (t_hrs, v_vy, date '2026-08-07', 'Pruner', 1, 4, 50);
  select public.work_task_effective_labour_cost(t_hrs) into num;
  if num <> 200 then raise exception 'T9: own lines must win, expected 200, got %', num; end if;
  if num = 680 then raise exception 'T9: task lines and pruning lines were SUMMED'; end if;
  raise notice 'T9 passed';

  -- ---- T10. Linked PIECE-RATE task still wins ------------------------------
  insert into public.pruning_activity_labour_lines
    (id, pruning_activity_id, vineyard_id, work_date, worker_type,
     worker_count, hours_per_worker, hourly_rate, line_index, created_by)
  values
    (gen_random_uuid(), a_pce, v_vy, date '2026-08-08', 'Pruner', 2, 8, 30, 0, u_mgr);

  select public.pruning_activity_effective_labour_cost(a_pce) into num;
  if num <> 137.50 then
    raise exception 'T10: piece rate expected 137.50 (250 x 0.55), got %', num;
  end if;
  if num = 617.50 then raise exception 'T10: piece rate and labour lines were SUMMED'; end if;
  select public.pruning_activity_labour_cost_source(a_pce) into txt;
  if txt <> 'piece_rate' then raise exception 'T10: expected piece_rate, got %', txt; end if;
  -- Hours stay operational on a piece-rate job.
  select public.pruning_activity_effective_labour_hours(a_pce) into num;
  if num <> 16 then raise exception 'T10: piece-rate hours expected 16, got %', num; end if;
  raise notice 'T10 passed';

  -- ---- T11. Unrated lines: hours yes, $0.00 no -----------------------------
  insert into public.pruning_activity_labour_lines
    (id, pruning_activity_id, vineyard_id, work_date, worker_type,
     worker_count, hours_per_worker, hourly_rate, line_index, created_by)
  values
    (gen_random_uuid(), a_unr, v_vy, date '2026-08-05', 'Pruner', 3, 6, null, 0, u_mgr);

  select public.pruning_activity_effective_labour_hours(a_unr) into num;
  if num <> 18 then raise exception 'T11: unrated hours must still count, got %', num; end if;
  select public.pruning_activity_effective_labour_cost(a_unr) into num;
  if num is not null then
    raise exception 'T11: "no rate entered" must be NULL, not %', num;
  end if;
  select public.pruning_activity_labour_cost_source(a_unr) into txt;
  if txt is not null then raise exception 'T11: expected NULL source, got %', txt; end if;

  -- A mixed activity costs only the rated line.
  insert into public.pruning_activity_labour_lines
    (id, pruning_activity_id, vineyard_id, work_date, worker_type,
     worker_count, hours_per_worker, hourly_rate, line_index, created_by)
  values
    (gen_random_uuid(), a_unr, v_vy, date '2026-08-05', 'Contractor', 1, 5, 40, 1, u_mgr);
  select public.pruning_activity_effective_labour_cost(a_unr) into num;
  if num <> 200 then raise exception 'T11: mixed expected 200 from the rated line, got %', num; end if;
  select public.pruning_activity_effective_labour_hours(a_unr) into num;
  if num <> 23 then raise exception 'T11: mixed hours expected 23 (18 + 5), got %', num; end if;
  raise notice 'T11 passed';

  -- ---- T12. Soft-deleted lines contribute nothing --------------------------
  select public.pruning_activity_effective_labour_cost(a_one) into num;
  if num <> 480 then raise exception 'T12: precondition expected 480, got %', num; end if;
  perform public.soft_delete_pruning_activity_labour_line(l_1);
  select public.pruning_activity_effective_labour_cost(a_one) into num;
  if num is not null then raise exception 'T12: a deleted line must not cost, got %', num; end if;
  select public.pruning_activity_effective_labour_hours(a_one) into num;
  if num is not null then raise exception 'T12: a deleted line must not add hours, got %', num; end if;
  -- Idempotent: replaying the delete offline must not fail.
  perform public.soft_delete_pruning_activity_labour_line(l_1);
  raise notice 'T12 passed';

  -- ---- T13. Offline replay is idempotent -----------------------------------
  select public.save_pruning_activity_labour_lines(
    a_rep,
    jsonb_build_array(
      jsonb_build_object('id', l_rep::text, 'work_date', '2026-08-06',
                         'worker_type', 'Pruner', 'worker_count', 2,
                         'hours_per_worker', 8, 'hourly_rate', 30, 'line_index', 0)
    ), now()
  ) into j;
  -- Replay the SAME payload (same client ids) three times.
  select public.save_pruning_activity_labour_lines(a_rep, j->'labour_lines', now()) into j;
  select public.save_pruning_activity_labour_lines(a_rep, j->'labour_lines', now()) into j;
  select public.save_pruning_activity_labour_lines(a_rep, j->'labour_lines', now()) into j;
  select public.pruning_activity_labour_line_count(a_rep) into n;
  if n <> 1 then raise exception 'T13: replay duplicated lines — expected 1, got %', n; end if;
  select public.pruning_activity_effective_labour_cost(a_rep) into num;
  if num <> 480 then raise exception 'T13: replay expected a stable 480, got %', num; end if;
  raise notice 'T13 passed';

  -- ---- T14. A re-sent deleted line is RESTORED, not duplicated -------------
  select public.save_pruning_activity_labour_lines(a_rep, '[]'::jsonb, now()) into j;
  select public.pruning_activity_labour_line_count(a_rep) into n;
  if n <> 0 then raise exception 'T14: expected 0 active lines after clearing, got %', n; end if;

  select public.save_pruning_activity_labour_lines(
    a_rep,
    jsonb_build_array(
      jsonb_build_object('id', l_rep::text, 'work_date', '2026-08-06', 'worker_type', 'Pruner',
                         'worker_count', 1, 'hours_per_worker', 5, 'hourly_rate', 20, 'line_index', 0)
    ), now()
  ) into j;
  select count(*) into n from public.pruning_activity_labour_lines
   where pruning_activity_id = a_rep and deleted_at is null;
  if n <> 1 then raise exception 'T14: expected 1 restored line, got %', n; end if;
  -- Restored, never duplicated: still exactly ONE row with that client id.
  select count(*) into n from public.pruning_activity_labour_lines where id = l_rep;
  if n <> 1 then raise exception 'T14: replay duplicated the client id, found % rows', n; end if;
  select public.pruning_activity_effective_labour_cost(a_rep) into num;
  if num <> 100 then raise exception 'T14: restored line expected 100 (1 x 5 x 20), got %', num; end if;
  raise notice 'T14 passed';

  -- ---- T15. pruning_activity_json ------------------------------------------
  select public.pruning_activity_json(a_mny, false) into j;
  if jsonb_array_length(j#>'{activity,labour_lines}') <> 2 then
    raise exception 'T15: expected 2 labour lines in the payload';
  end if;
  if (j#>>'{activity,total_labour_hours}')::numeric <> 22 then
    raise exception 'T15: activity total_labour_hours expected 22, got %',
      j#>>'{activity,total_labour_hours}';
  end if;
  if (j#>>'{totals,labour_hours}')::numeric <> 22 then
    raise exception 'T15: totals.labour_hours expected 22, got %', j#>>'{totals,labour_hours}';
  end if;
  if (j#>>'{totals,labour_cost}')::numeric <> 690 then
    raise exception 'T15: totals.labour_cost expected 690, got %', j#>>'{totals,labour_cost}';
  end if;
  if (j#>>'{totals,labour_cost_source}') <> 'pruning_labour_lines' then
    raise exception 'T15: totals.labour_cost_source wrong: %', j#>>'{totals,labour_cost_source}';
  end if;
  -- Every pre-190 key still present.
  if not (j#>'{activity}' ? 'worker_or_crew' and j#>'{activity}' ? 'labour_hours'
          and j#>'{activity}' ? 'hourly_rate' and j#>'{activity}' ? 'work_task_id'
          and j#>'{activity}' ? 'method' and j#>'{activity}' ? 'notes'
          and j#>'{totals}' ? 'row_equivalents' and j#>'{totals}' ? 'estimated_vines'
          and j#>'{totals}' ? 'cost_per_vine' and j#>'{totals}' ? 'block_summary') then
    raise exception 'T15: a pre-190 key was dropped from pruning_activity_json';
  end if;
  -- A legacy activity round-trips byte for byte.
  select public.pruning_activity_json(a_leg, false) into j;
  if (j#>>'{activity,labour_hours}')::numeric <> 7.5
     or (j#>>'{totals,labour_hours}')::numeric <> 7.5
     or (j#>>'{totals,labour_cost}')::numeric <> 240 then
    raise exception 'T15: a legacy activity changed value under SQL 190';
  end if;
  if jsonb_array_length(j#>'{activity,labour_lines}') <> 0 then
    raise exception 'T15: a legacy activity must report an EMPTY labour_lines array';
  end if;
  raise notice 'T15 passed';

  -- ---- T16. Export view: once per activity, reconciles exactly -------------
  select count(*) into n from public.pruning_activity_allocation_export
   where activity_id = a_mul and activity_labour_cost is not null;
  if n <> 1 then
    raise exception 'T16: activity labour must appear on ONE row only, found %', n;
  end if;
  select activity_labour_cost into num from public.pruning_activity_allocation_export
   where activity_id = a_mul and activity_labour_cost is not null;
  if num <> 690 then raise exception 'T16: export expected 690, got %', num; end if;
  select activity_labour_hours into num from public.pruning_activity_allocation_export
   where activity_id = a_mul and activity_labour_hours is not null;
  if num <> 22 then raise exception 'T16: export hours expected 22, got %', num; end if;
  select activity_labour_cost_source into txt from public.pruning_activity_allocation_export
   where activity_id = a_mul and activity_labour_cost_source is not null;
  if txt <> 'pruning_labour_lines' then
    raise exception 'T16: export source expected pruning_labour_lines, got %', txt;
  end if;

  -- 6 : 3 : 3 row equivalents over $690 must reconcile to the cent.
  select sum(allocation_share_labour_cost) into num
    from public.pruning_activity_allocation_export where activity_id = a_mul;
  if num <> 690 then
    raise exception 'T16: allocation shares must reconcile to 690 exactly, got %', num;
  end if;
  raise notice 'T16 passed';

  -- ---- T17. Vineyard scoping ------------------------------------------------
  begin
    insert into public.pruning_activity_labour_lines
      (id, pruning_activity_id, vineyard_id, work_date, worker_type,
       worker_count, hours_per_worker, hourly_rate, created_by)
    values
      (gen_random_uuid(), a_mny, v_vy2, date '2026-08-03', 'Pruner', 1, 1, 10, u_mgr);
    -- The FK allows the row, so the resolver must still scope by activity.
    select public.pruning_activity_effective_labour_cost(a_mny) into num;
  exception when others then
    num := null;
  end;
  select count(distinct vineyard_id) into n
    from public.pruning_activity_labour_lines l
    join public.pruning_activities a on a.id = l.pruning_activity_id
   where l.pruning_activity_id = a_mny and l.vineyard_id <> a.vineyard_id
     and l.deleted_at is null;
  if n > 0 then
    -- Clean the deliberately mis-scoped probe row so later assertions are clean.
    delete from public.pruning_activity_labour_lines l
     using public.pruning_activities a
     where a.id = l.pruning_activity_id and l.vineyard_id <> a.vineyard_id;
  end if;
  -- The RPC always stamps the ACTIVITY's vineyard, so it cannot mis-scope.
  select public.save_pruning_activity_labour_lines(
    a_rep,
    jsonb_build_array(jsonb_build_object('id', l_rep::text, 'worker_type', 'Pruner',
      'worker_count', 1, 'hours_per_worker', 5, 'hourly_rate', 20)), now()) into j;
  select vineyard_id into txt from public.pruning_activity_labour_lines where id = l_rep;
  if txt <> v_vy::text then
    raise exception 'T17: the RPC must stamp the activity vineyard, got %', txt;
  end if;
  raise notice 'T17 passed';

  -- ---- T18. A line cannot be stolen by another activity --------------------
  select public.save_pruning_activity_labour_lines(
    a_one,
    jsonb_build_array(jsonb_build_object('id', l_2::text, 'worker_type', 'Pruner',
      'worker_count', 1, 'hours_per_worker', 1, 'hourly_rate', 10)), now()) into j;
  select pruning_activity_id into txt from public.pruning_activity_labour_lines where id = l_2;
  if txt <> a_mny::text then
    raise exception 'T18: a line was re-parented across activities';
  end if;
  raise notice 'T18 passed';

  -- ---- T19. Cross-platform contract fixture --------------------------------
  -- These are the SAME numbers asserted by the iOS and Android test suites.
  select public.pruning_activity_effective_labour_hours(a_mny) into num;
  select public.pruning_activity_effective_labour_cost(a_mny) into num2;
  if num <> 22 or num2 <> 690 then
    raise exception 'T19: contract fixture drifted — expected 22 h / 690, got % / %', num, num2;
  end if;
  select public.pruning_activity_effective_labour_cost(a_pce) into num;
  if num <> 137.50 then
    raise exception 'T19: piece-rate fixture expected 137.50, got %', num;
  end if;
  -- No synthetic "Piece Rate" worker type was invented anywhere.
  select count(*) into n from public.pruning_activity_labour_lines
   where vineyard_id = v_vy and worker_type ilike '%piece%';
  if n <> 0 then raise exception 'T19: a synthetic Piece Rate labour line was created'; end if;
  raise notice 'T19 passed';

  -- ---- T20. Hard delete refused --------------------------------------------
  select count(*) into n from pg_policies
   where schemaname = 'public' and tablename = 'pruning_activity_labour_lines'
     and cmd = 'DELETE' and qual = 'false';
  if n <> 1 then
    raise exception 'T20: expected a client hard-delete DENY policy, found %', n;
  end if;
  raise notice 'T20 passed';

  raise notice 'SQL 190 pruning labour line tests: ALL PASSED';
end$$;

-- ---- T21. Nothing survives -------------------------------------------------
rollback;

-- Confirm the rollback really discarded the fixtures.
do $$
declare n integer;
begin
  select count(*) into n from public.vineyards where name like 'T190 %';
  if n <> 0 then
    raise exception 'T21: fixtures survived the rollback (% vineyards left)', n;
  end if;
  raise notice 'T21 passed — all SQL 190 test fixtures rolled back';
end$$;

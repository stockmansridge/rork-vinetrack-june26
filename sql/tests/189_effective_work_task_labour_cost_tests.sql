-- =====================================================================
-- 189_effective_work_task_labour_cost_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/189_effective_work_task_labour_cost.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects: the five helper functions and the join view exist
--   T2  Piece Rate: 250 vines x $0.55 = $137.50 with ZERO labour lines
--       and ZERO hours — never NULL, never $0.00
--   T3  Hourly regression: 2 workers x 8 h x $30 = $480
--   T4  Legacy task (costing_method never set by the client) still
--       resolves from its labour lines
--   T5  ONE cost source: a piece-rate job with operational labour lines
--       stays $137.50 and is never $137.50 + $480
--   T6  Soft-deleted labour lines contribute nothing
--   T7  "Not specified" is NULL, not $0.00 (no lines / unrated lines)
--   T8  An unknown task id resolves to NULL rather than raising
--   T9  pruning_activity_json: activity.labour_cost AND totals.labour_cost
--       carry the piece-rate cost, plus the SQL 188 contract keys
--   T10 pruning_activity_json: an UNLINKED activity keeps its legacy
--       hours x rate value exactly
--   T11 pruning_activity_json: a linked HOURLY task reports its lines, and
--       a linked task with no costed line falls back to the activity's own
--       hours x rate — so no pre-189 record changes value
--   T12 pruning_activity_allocation_export: activity_labour_cost is the
--       effective cost, on the PRIMARY allocation row only
--   T13 Multi-block allocation reconciles EXACTLY ($1,000 -> $600 + $400)
--   T14 Rounding residual reconciles exactly ($100 across three equal
--       allocations -> 33.34 + 33.33 + 33.33)
--   T15 Every pre-189 export column is still present (backwards compatible)
--   T16 A skipped allocation still carries no labour cost
--   T17 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 189 effective labour cost tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 189 is applied.
do $$
begin
  if to_regprocedure('public.work_task_effective_labour_cost(uuid)') is null
     or to_regprocedure('public.pruning_activity_effective_labour_cost(uuid)') is null
     or to_regclass('public.v_work_task_effective_labour_cost') is null then
    raise exception 'SQL 189 not applied — run sql/189_effective_work_task_labour_cost.sql first.';
  end if;
end$$;

do $$
declare
  u_mgr uuid;
  v_vy  uuid := gen_random_uuid();
  b_1   uuid := gen_random_uuid();
  b_2   uuid := gen_random_uuid();
  b_3   uuid := gen_random_uuid();
  s_1   uuid := gen_random_uuid();
  s_2   uuid := gen_random_uuid();
  s_3   uuid := gen_random_uuid();
  t_pce uuid := gen_random_uuid();  -- piece rate, 250 x 0.55
  t_hrs uuid := gen_random_uuid();  -- hourly, 2 x 8 x 30
  t_leg uuid := gen_random_uuid();  -- legacy, costing_method never set
  t_nil uuid := gen_random_uuid();  -- hourly, no lines at all
  t_unr uuid := gen_random_uuid();  -- hourly, lines without a rate
  t_hst uuid := gen_random_uuid();  -- piece rate WITH operational hours
  t_big uuid := gen_random_uuid();  -- piece rate, 2000 x 0.50 = 1000
  t_thr uuid := gen_random_uuid();  -- piece rate, 200 x 0.50 = 100
  a_pce uuid := gen_random_uuid();
  a_unl uuid := gen_random_uuid();
  a_hrs uuid := gen_random_uuid();
  a_fbk uuid := gen_random_uuid();
  a_mul uuid := gen_random_uuid();
  a_thr uuid := gen_random_uuid();
  a_skp uuid := gen_random_uuid();
  j     jsonb;
  num   numeric;
  txt   text;
  n     integer;
begin
  -- ---- fixtures ------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't189-mgr@test.local', 'x', now(), now(), now());
  select id into u_mgr from auth.users where email = 't189-mgr@test.local';
  insert into public.profiles (id, email) values (u_mgr, 't189-mgr@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values (v_vy, 'T189 Effective Cost Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values (v_vy, u_mgr, 'manager');

  insert into public.paddocks (id, vineyard_id, name) values
    (b_1, v_vy, 'T189 Block 1'),
    (b_2, v_vy, 'T189 Block 2'),
    (b_3, v_vy, 'T189 Block 3');

  insert into public.pruning_seasons (id, vineyard_id, paddock_id, season_year) values
    (s_1, v_vy, b_1, 2026),
    (s_2, v_vy, b_2, 2026),
    (s_3, v_vy, b_3, 2026);

  -- Work tasks. Every one is created the way a client creates it.
  insert into public.work_tasks
    (id, vineyard_id, paddock_id, paddock_name, date, task_type, duration_hours, created_by, updated_by)
  values
    (t_leg, v_vy, b_1, 'T189 Block 1', now(), 'Pruning', 5,  u_mgr, u_mgr),
    (t_hrs, v_vy, b_1, 'T189 Block 1', now(), 'Pruning', 16, u_mgr, u_mgr),
    (t_nil, v_vy, b_1, 'T189 Block 1', now(), 'Pruning', 0,  u_mgr, u_mgr),
    (t_unr, v_vy, b_1, 'T189 Block 1', now(), 'Pruning', 4,  u_mgr, u_mgr);

  -- THE piece-rate job from the contract: 250 vines at $0.55, no labour
  -- lines, no hours.
  insert into public.work_tasks
    (id, vineyard_id, paddock_id, paddock_name, date, task_type, duration_hours,
     costing_method, piece_vine_count, piece_rate_per_vine, created_by, updated_by)
  values
    (t_pce, v_vy, b_1, 'T189 Block 1', now(), 'Pruning', 0,
     'piece_rate', 250, 0.5500, u_mgr, u_mgr),
    (t_hst, v_vy, b_1, 'T189 Block 1', now(), 'Pruning', 16,
     'piece_rate', 250, 0.5500, u_mgr, u_mgr),
    (t_big, v_vy, b_1, 'T189 Block 1', now(), 'Pruning', 0,
     'piece_rate', 2000, 0.5000, u_mgr, u_mgr),
    (t_thr, v_vy, b_1, 'T189 Block 1', now(), 'Pruning', 0,
     'piece_rate', 200, 0.5000, u_mgr, u_mgr);

  -- Hourly lines: 2 workers x 8 hours x $30 = $480.
  insert into public.work_task_labour_lines
    (work_task_id, vineyard_id, work_date, worker_type, worker_count, hours_per_worker, hourly_rate)
  values (t_hrs, v_vy, current_date, 'Pruner', 2, 8, 30);

  -- Legacy task: created by a client that never sends costing_method.
  insert into public.work_task_labour_lines
    (work_task_id, vineyard_id, work_date, worker_type, worker_count, hours_per_worker, hourly_rate)
  values (t_leg, v_vy, current_date, 'Pruner', 1, 5, 40);

  -- Hours recorded on a piece-rate job: operational history, never a cost.
  insert into public.work_task_labour_lines
    (work_task_id, vineyard_id, work_date, worker_type, worker_count, hours_per_worker, hourly_rate)
  values (t_hst, v_vy, current_date, 'Pruner', 2, 8, 30);

  -- Unrated line: hours only, no rate.
  insert into public.work_task_labour_lines
    (work_task_id, vineyard_id, work_date, worker_type, worker_count, hours_per_worker, hourly_rate)
  values (t_unr, v_vy, current_date, 'Pruner', 3, 6, null);

  -- ---- T1. Objects ---------------------------------------------------------
  if to_regprocedure('public.work_task_labour_line_cost(uuid)') is null
     or to_regprocedure('public.work_task_labour_cost_source(uuid)') is null
     or to_regprocedure('public.pruning_activity_labour_cost_source(uuid)') is null then
    raise exception 'T1: SQL 189 helper functions missing';
  end if;
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'v_work_task_effective_labour_cost'
    and column_name in ('work_task_id','costing_method','piece_rate_total_cost',
                        'labour_line_cost','effective_labour_cost','labour_cost_source','cost_per_vine');
  if n <> 7 then raise exception 'T1: join view expected 7 key columns, found %', n; end if;
  raise notice 'T1 passed';

  -- ---- T2. Piece Rate: 250 x $0.55 = $137.50, zero lines, zero hours -------
  select public.work_task_effective_labour_cost(t_pce) into num;
  if num is null then
    raise exception 'T2: a valid piece-rate job must never resolve to NULL';
  end if;
  if num <> 137.50 then
    raise exception 'T2: expected 137.50 from 250 x 0.55, got %', num;
  end if;

  select public.work_task_labour_cost_source(t_pce) into txt;
  if txt <> 'piece_rate' then raise exception 'T2: expected source piece_rate, got %', txt; end if;

  -- The task genuinely has NO labour lines — the cost is not coming from one.
  select count(*) into n from public.work_task_labour_lines
   where work_task_id = t_pce and deleted_at is null;
  if n <> 0 then raise exception 'T2: fixture must have zero labour lines, found %', n; end if;

  -- No synthetic labour line, worker type or hours was fabricated anywhere.
  select count(*) into n from public.work_task_labour_lines
   where vineyard_id = v_vy and worker_type ilike '%piece%';
  if n <> 0 then raise exception 'T2: a synthetic Piece Rate labour line was created'; end if;

  select effective_labour_cost into num
    from public.v_work_task_effective_labour_cost where work_task_id = t_pce;
  if num <> 137.50 then raise exception 'T2: view expected 137.50, got %', num; end if;

  select cost_per_vine into num
    from public.v_work_task_effective_labour_cost where work_task_id = t_pce;
  if num <> 0.5500 then raise exception 'T2: cost per vine expected 0.55, got %', num; end if;
  raise notice 'T2 passed';

  -- ---- T3. Hourly regression: 2 x 8 x $30 = $480 ---------------------------
  select public.work_task_effective_labour_cost(t_hrs) into num;
  if num <> 480 then raise exception 'T3: hourly expected 480, got %', num; end if;
  select public.work_task_labour_cost_source(t_hrs) into txt;
  if txt <> 'labour_lines' then raise exception 'T3: expected source labour_lines, got %', txt; end if;
  select effective_labour_cost into num
    from public.v_work_task_effective_labour_cost where work_task_id = t_hrs;
  if num <> 480 then raise exception 'T3: view expected 480, got %', num; end if;
  raise notice 'T3 passed';

  -- ---- T4. Legacy task, costing_method never set ---------------------------
  select costing_method into txt from public.work_tasks where id = t_leg;
  if txt <> 'hourly' then raise exception 'T4: legacy task must default to hourly, got %', txt; end if;
  select public.work_task_effective_labour_cost(t_leg) into num;
  if num <> 200 then raise exception 'T4: legacy expected 200 from its lines, got %', num; end if;
  raise notice 'T4 passed';

  -- ---- T5. ONE cost source -------------------------------------------------
  -- A piece-rate job with real recorded hours stays on its agreement.
  select public.work_task_effective_labour_cost(t_hst) into num;
  if num <> 137.50 then
    raise exception 'T5: piece rate with hours expected 137.50, got %', num;
  end if;
  if num = 617.50 then
    raise exception 'T5: piece rate and labour lines were SUMMED';
  end if;
  -- The hourly figure is still visible for audit, just never the cost.
  select public.work_task_labour_line_cost(t_hst) into num;
  if num <> 480 then raise exception 'T5: labour line audit total expected 480, got %', num; end if;
  select labour_line_cost into num
    from public.v_work_task_effective_labour_cost where work_task_id = t_hst;
  if num <> 480 then
    raise exception 'T5: the hourly side must stay visible for audit, got %', num;
  end if;
  select effective_labour_cost into num
    from public.v_work_task_effective_labour_cost where work_task_id = t_hst;
  if num <> 137.50 then raise exception 'T5: view expected 137.50, got %', num; end if;
  raise notice 'T5 passed';

  -- ---- T6. Soft-deleted lines contribute nothing ---------------------------
  insert into public.work_task_labour_lines
    (work_task_id, vineyard_id, work_date, worker_type, worker_count, hours_per_worker,
     hourly_rate, deleted_at)
  values (t_hrs, v_vy, current_date, 'Pruner', 10, 10, 100, now());
  select public.work_task_effective_labour_cost(t_hrs) into num;
  if num <> 480 then
    raise exception 'T6: a soft-deleted line changed the cost (expected 480, got %)', num;
  end if;
  raise notice 'T6 passed';

  -- ---- T7. "Not specified" is NULL, never $0.00 ----------------------------
  select public.work_task_effective_labour_cost(t_nil) into num;
  if num is not null then
    raise exception 'T7: a task with no labour must be NULL, got %', num;
  end if;
  select public.work_task_labour_cost_source(t_nil) into txt;
  if txt is not null then raise exception 'T7: expected NULL source, got %', txt; end if;

  -- Hours without a rate are history, not a $0.00 cost.
  select public.work_task_effective_labour_cost(t_unr) into num;
  if num is not null then
    raise exception 'T7: unrated lines must resolve to NULL, got %', num;
  end if;

  -- An unpriced piece-rate job is "not specified" too, never 0.
  update public.work_tasks set piece_rate_per_vine = null where id = t_thr;
  select public.work_task_effective_labour_cost(t_thr) into num;
  if num is not null then
    raise exception 'T7: an unpriced piece-rate job must be NULL, got %', num;
  end if;
  update public.work_tasks set piece_rate_per_vine = 0.5000 where id = t_thr;
  raise notice 'T7 passed';

  -- ---- T8. Unknown task ----------------------------------------------------
  select public.work_task_effective_labour_cost(gen_random_uuid()) into num;
  if num is not null then raise exception 'T8: unknown task must be NULL, got %', num; end if;
  raise notice 'T8 passed';

  -- ---- pruning activity fixtures -------------------------------------------
  -- Linked piece-rate activity, ZERO hours and ZERO labour lines.
  insert into public.pruning_activities (id, vineyard_id, entry_date) values (a_pce, v_vy, current_date);
  insert into public.pruning_entries
    (id, vineyard_id, pruning_season_id, paddock_id, entry_date, pruning_activity_id,
     allocation_index, row_equivalents_completed, estimated_vines_completed)
  values (gen_random_uuid(), v_vy, s_1, b_1, current_date, a_pce, 0, 10, 250);
  update public.pruning_activities
     set work_task_id = t_pce, labour_hours = null, hourly_rate = null
   where id = a_pce;

  -- UNLINKED legacy activity: 6.5 h x $40 = $260.
  insert into public.pruning_activities (id, vineyard_id, entry_date) values (a_unl, v_vy, current_date);
  insert into public.pruning_entries
    (id, vineyard_id, pruning_season_id, paddock_id, entry_date, pruning_activity_id,
     allocation_index, row_equivalents_completed, estimated_vines_completed)
  values (gen_random_uuid(), v_vy, s_1, b_1, current_date, a_unl, 0, 8, 400);
  update public.pruning_activities
     set work_task_id = null, labour_hours = 6.5, hourly_rate = 40
   where id = a_unl;

  -- Linked HOURLY activity with costed lines.
  insert into public.pruning_activities (id, vineyard_id, entry_date) values (a_hrs, v_vy, current_date);
  insert into public.pruning_entries
    (id, vineyard_id, pruning_season_id, paddock_id, entry_date, pruning_activity_id,
     allocation_index, row_equivalents_completed, estimated_vines_completed)
  values (gen_random_uuid(), v_vy, s_1, b_1, current_date, a_hrs, 0, 12, 600);
  update public.pruning_activities
     set work_task_id = t_hrs, labour_hours = 16, hourly_rate = 25
   where id = a_hrs;

  -- Linked task with NO costed line, but the activity carries hours x rate:
  -- the pre-189 value must survive.
  insert into public.pruning_activities (id, vineyard_id, entry_date) values (a_fbk, v_vy, current_date);
  insert into public.pruning_entries
    (id, vineyard_id, pruning_season_id, paddock_id, entry_date, pruning_activity_id,
     allocation_index, row_equivalents_completed, estimated_vines_completed)
  values (gen_random_uuid(), v_vy, s_1, b_1, current_date, a_fbk, 0, 4, 200);
  update public.pruning_activities
     set work_task_id = t_nil, labour_hours = 4, hourly_rate = 35
   where id = a_fbk;

  -- ---- T9. pruning_activity_json carries the piece-rate cost ---------------
  j := public.pruning_activity_json(a_pce, false);
  if (j -> 'activity' ->> 'labour_cost')::numeric <> 137.50 then
    raise exception 'T9: activity.labour_cost expected 137.50, got %',
      (j -> 'activity' ->> 'labour_cost');
  end if;
  if (j -> 'totals' ->> 'labour_cost')::numeric <> 137.50 then
    raise exception 'T9: totals.labour_cost expected 137.50, got %',
      (j -> 'totals' ->> 'labour_cost');
  end if;
  if (j -> 'activity' ->> 'labour_cost_source') <> 'piece_rate' then
    raise exception 'T9: labour_cost_source expected piece_rate, got %',
      (j -> 'activity' ->> 'labour_cost_source');
  end if;
  if (j -> 'activity' ->> 'costing_method') <> 'piece_rate'
     or (j -> 'activity' ->> 'piece_vine_count')::integer <> 250
     or (j -> 'activity' ->> 'piece_rate_per_vine')::numeric <> 0.55
     or (j -> 'activity' ->> 'piece_rate_total_cost')::numeric <> 137.50 then
    raise exception 'T9: SQL 188 contract keys missing or wrong in activity';
  end if;
  if (j -> 'totals' ->> 'cost_per_vine')::numeric <> 0.55 then
    raise exception 'T9: totals.cost_per_vine expected 0.55, got %',
      (j -> 'totals' ->> 'cost_per_vine');
  end if;
  -- Zero hours on the job must not have become $0.00 anywhere.
  if (j -> 'activity' ->> 'labour_hours') is not null then
    raise exception 'T9: fixture should carry no hours';
  end if;
  -- Every pre-189 key is still present.
  if not (j -> 'activity' ? 'labour_hours' and j -> 'activity' ? 'hourly_rate'
          and j -> 'activity' ? 'is_skipped' and j -> 'activity' ? 'work_task_id'
          and j -> 'totals' ? 'row_equivalents' and j -> 'totals' ? 'estimated_vines'
          and j ? 'allocations') then
    raise exception 'T9: a pre-189 key disappeared from pruning_activity_json';
  end if;
  raise notice 'T9 passed';

  -- ---- T10. Unlinked activity keeps its legacy value -----------------------
  j := public.pruning_activity_json(a_unl, false);
  if (j -> 'activity' ->> 'labour_cost')::numeric <> 260 then
    raise exception 'T10: unlinked activity expected 260 (6.5 x 40), got %',
      (j -> 'activity' ->> 'labour_cost');
  end if;
  if (j -> 'activity' ->> 'labour_cost_source') <> 'activity_hours' then
    raise exception 'T10: expected source activity_hours, got %',
      (j -> 'activity' ->> 'labour_cost_source');
  end if;
  if (j -> 'activity' ->> 'costing_method') is not null then
    raise exception 'T10: an unlinked activity must not report a costing method';
  end if;
  raise notice 'T10 passed';

  -- ---- T11. Linked hourly, and the no-line fallback ------------------------
  j := public.pruning_activity_json(a_hrs, false);
  if (j -> 'activity' ->> 'labour_cost')::numeric <> 480 then
    raise exception 'T11: linked hourly expected 480 from its lines, got %',
      (j -> 'activity' ->> 'labour_cost');
  end if;
  if (j -> 'activity' ->> 'labour_cost_source') <> 'labour_lines' then
    raise exception 'T11: expected source labour_lines, got %',
      (j -> 'activity' ->> 'labour_cost_source');
  end if;

  j := public.pruning_activity_json(a_fbk, false);
  if (j -> 'activity' ->> 'labour_cost')::numeric <> 140 then
    raise exception 'T11: fallback expected 140 (4 x 35) so no pre-189 value changes, got %',
      (j -> 'activity' ->> 'labour_cost');
  end if;
  if (j -> 'activity' ->> 'labour_cost_source') <> 'activity_hours' then
    raise exception 'T11: fallback source expected activity_hours, got %',
      (j -> 'activity' ->> 'labour_cost_source');
  end if;
  raise notice 'T11 passed';

  -- ---- multi-block fixtures ------------------------------------------------
  -- $1,000 piece-rate job across two blocks, 60 / 40 by row equivalents.
  insert into public.pruning_activities (id, vineyard_id, entry_date) values (a_mul, v_vy, current_date);
  insert into public.pruning_entries
    (id, vineyard_id, pruning_season_id, paddock_id, entry_date, pruning_activity_id,
     allocation_index, row_equivalents_completed, estimated_vines_completed)
  values
    (gen_random_uuid(), v_vy, s_1, b_1, current_date, a_mul, 0, 6, 1200),
    (gen_random_uuid(), v_vy, s_2, b_2, current_date, a_mul, 1, 4, 800);
  update public.pruning_activities
     set work_task_id = t_big, labour_hours = null, hourly_rate = null
   where id = a_mul;

  -- $100 across three EQUAL allocations — the rounding residual case.
  insert into public.pruning_activities (id, vineyard_id, entry_date) values (a_thr, v_vy, current_date);
  insert into public.pruning_entries
    (id, vineyard_id, pruning_season_id, paddock_id, entry_date, pruning_activity_id,
     allocation_index, row_equivalents_completed, estimated_vines_completed)
  values
    (gen_random_uuid(), v_vy, s_1, b_1, current_date, a_thr, 0, 1, 100),
    (gen_random_uuid(), v_vy, s_2, b_2, current_date, a_thr, 1, 1, 100),
    (gen_random_uuid(), v_vy, s_3, b_3, current_date, a_thr, 2, 1, 100);
  update public.pruning_activities
     set work_task_id = t_thr, labour_hours = null, hourly_rate = null
   where id = a_thr;

  -- A skipped allocation: out of rotation, never labour.
  insert into public.pruning_activities (id, vineyard_id, entry_date) values (a_skp, v_vy, current_date);
  insert into public.pruning_entries
    (id, vineyard_id, pruning_season_id, paddock_id, entry_date, pruning_activity_id,
     allocation_index, row_equivalents_completed, estimated_vines_completed, is_skipped)
  values (gen_random_uuid(), v_vy, s_1, b_1, current_date, a_skp, 0, 3, 150, true);

  -- The export view is security_invoker: read it as the member.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- ---- T12. Export view reports the EFFECTIVE cost -------------------------
  select count(*) into n from public.pruning_activity_allocation_export
   where activity_id = a_pce and activity_labour_cost is not null;
  if n <> 1 then
    raise exception 'T12: expected exactly 1 row carrying activity_labour_cost, found %', n;
  end if;
  select activity_labour_cost into num from public.pruning_activity_allocation_export
   where activity_id = a_pce and activity_labour_cost is not null;
  if num <> 137.50 then
    raise exception 'T12: export activity_labour_cost expected 137.50, got %', num;
  end if;
  select activity_labour_cost_source into txt
    from public.pruning_activity_allocation_export
   where activity_id = a_pce and activity_labour_cost is not null;
  if txt <> 'piece_rate' then
    raise exception 'T12: export activity_labour_cost_source expected piece_rate, got %', txt;
  end if;
  select activity_costing_method into txt from public.pruning_activity_allocation_export
   where activity_id = a_pce and activity_labour_cost is not null;
  if txt <> 'piece_rate' then
    raise exception 'T12: export activity_costing_method expected piece_rate, got %', txt;
  end if;
  select activity_piece_vine_count into n from public.pruning_activity_allocation_export
   where activity_id = a_pce and activity_labour_cost is not null;
  if n <> 250 then raise exception 'T12: export piece vine count expected 250, got %', n; end if;
  raise notice 'T12 passed';

  -- ---- T13. Multi-block allocation reconciles EXACTLY ----------------------
  select sum(allocation_share_labour_cost) into num
    from public.pruning_activity_allocation_export where activity_id = a_mul;
  if num <> 1000.00 then
    raise exception 'T13: allocations must reconcile to 1000.00, got %', num;
  end if;
  select allocation_share_labour_cost into num
    from public.pruning_activity_allocation_export
   where activity_id = a_mul and paddock_id = b_1;
  if num <> 600.00 then raise exception 'T13: block A expected 600.00, got %', num; end if;
  select allocation_share_labour_cost into num
    from public.pruning_activity_allocation_export
   where activity_id = a_mul and paddock_id = b_2;
  if num <> 400.00 then raise exception 'T13: block B expected 400.00, got %', num; end if;

  -- The allocated total equals the activity total on the primary row.
  select activity_labour_cost into num from public.pruning_activity_allocation_export
   where activity_id = a_mul and activity_labour_cost is not null;
  if num <> 1000.00 then raise exception 'T13: activity total expected 1000.00, got %', num; end if;
  raise notice 'T13 passed';

  -- ---- T14. Rounding residual reconciles exactly ---------------------------
  select sum(allocation_share_labour_cost) into num
    from public.pruning_activity_allocation_export where activity_id = a_thr;
  if num <> 100.00 then
    raise exception 'T14: three-way split must reconcile to 100.00, got %', num;
  end if;
  select allocation_share_labour_cost into num
    from public.pruning_activity_allocation_export
   where activity_id = a_thr and allocation_index = 0;
  if num <> 33.34 then
    raise exception 'T14: the rounding residual belongs on the primary row (expected 33.34), got %', num;
  end if;
  raise notice 'T14 passed';

  -- ---- T15. Backwards compatibility of the export view ---------------------
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'pruning_activity_allocation_export'
    and column_name in (
      'activity_id','vineyard_id','activity_date','worker_or_crew','method','block_summary',
      'allocation_id','allocation_index','paddock_id','block','pruning_season_id','season_year',
      'vintage_year','rows','quarters','row_equivalents','completion_row_equivalents',
      'pruned_row_equivalents','skipped_row_equivalents','vines','vines_pruned','vines_skipped',
      'is_skipped','activity_labour_hours','activity_hourly_rate','activity_labour_cost',
      'allocation_share_of_row_equivalents','allocation_share_labour_hours_informational',
      'work_task_id','status','created_by','created_at','updated_at');
  if n <> 33 then
    raise exception 'T15: expected all 33 pre-189 export columns, found %', n;
  end if;
  raise notice 'T15 passed';

  -- ---- T16. A skipped allocation carries no labour -------------------------
  select count(*) into n from public.pruning_activity_allocation_export
   where activity_id = a_skp
     and (activity_labour_cost is not null or allocation_share_labour_cost is not null);
  if n <> 0 then raise exception 'T16: a skipped allocation must carry no labour cost'; end if;
  raise notice 'T16 passed';

  perform set_config('role', 'postgres', true);
  raise notice 'SQL 189 effective labour cost tests: ALL PASSED';
end$$;

-- ---- T17. Discard everything -------------------------------------------------
rollback;

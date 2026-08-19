-- =============================================================================
-- Tests for sql/200_pruning_work_task_repair.sql (run AFTER applying 200).
-- Style matches sql/tests/190: temporary fixtures inside a rolled-back
-- transaction, assertions via DO blocks. Requires an empty scratch schema or a
-- disposable database — NEVER run against production data.
--
-- The SQL editor runs with no JWT, so auth.uid() is NULL and
-- set_work_task_pruning_activity would raise 'Authentication required'. The
-- fixture therefore creates a test manager, adds vineyard membership, and
-- simulates the session via request.jwt.claims — exactly the sql/tests/190
-- pattern. Superuser inserts bypass RLS; only auth.uid() is simulated, which
-- is all the RPC checks (has_vineyard_role reads the membership row).
-- =============================================================================

begin;

-- Fixture identities
-- vineyard V, activity A (two blocks), tasks T1 (hourly), T2 (hourly), T3
-- (piece rate), plus a legacy activity L with 190-lines and no task.
--
-- NOTE: these tests intentionally use the SAME assertion pattern as
-- sql/tests/190_pruning_activity_labour_lines_tests.sql. Fixture UUIDs are
-- valid v4-shaped hex constants.

do $$
declare
  v_vineyard uuid := '11111111-1111-4111-8111-111111111111';
  v_user uuid;
  v_activity uuid := '22222222-2222-4222-8222-222222222222';
  v_legacy uuid := '33333333-3333-4333-8333-333333333333';
  v_t1 uuid := '44444444-4444-4444-8444-444444444444';
  v_t2 uuid := '55555555-5555-4555-8555-555555555555';
  v_t3 uuid := '66666666-6666-4666-8666-666666666666';
  v_off_activity uuid := '77777777-7777-4777-8777-777777777777';
  v_off_a uuid := '88888888-8888-4888-8888-888888888888';
  v_off_b uuid := '99999999-9999-4999-8999-999999999999';
  v_cost numeric;
  v_hours numeric;
  v_count integer;
  v_source text;
  v_json jsonb;
begin
  -- ---- fixture manager + simulated session ---------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          't200-mgr@test.local', 'x', now(), now(), now())
  on conflict do nothing;
  select id into v_user from auth.users where email = 't200-mgr@test.local';
  insert into public.profiles (id, email) values (v_user, 't200-mgr@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values (v_vineyard, 'Repair Test Vineyard')
  on conflict (id) do nothing;
  insert into public.vineyard_members (vineyard_id, user_id, role)
  values (v_vineyard, v_user, 'manager')
  on conflict do nothing;

  -- Simulate an authenticated session so auth.uid() resolves inside the RPC.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  if auth.uid() is distinct from v_user then
    raise exception 'Fixture: auth.uid() did not resolve to the test manager (got %). The RPC tests cannot run without a simulated session.', auth.uid();
  end if;

  -- Activity A: operational only (no scalars, no 190-lines).
  insert into public.pruning_activities (
    id, vineyard_id, entry_date, worker_or_crew, pruning_method,
    season_year, created_by
  ) values (
    v_activity, v_vineyard, date '2026-08-04', 'Sauv Blanc crews', 'spur',
    2026, v_user
  ) on conflict (id) do nothing;

  -- T1: Victoria Labour Hire — 2 × 7 h × $35 = 14 h / $490.
  insert into public.work_tasks (id, vineyard_id, date, task_type, pruning_activity_id, created_by)
  values (v_t1, v_vineyard, timestamptz '2026-08-04T09:00:00Z', 'Pruning', v_activity, v_user)
  on conflict (id) do nothing;
  insert into public.work_task_labour_lines (
    id, work_task_id, vineyard_id, work_date, worker_type, worker_count,
    hours_per_worker, hourly_rate
  ) values (
    'aaaaaaa1-0000-4000-8000-000000000001', v_t1, v_vineyard, date '2026-08-04',
    'Victoria Labour Hire', 2, 7, 35
  ) on conflict (id) do nothing;

  -- T2: Permanent Staff — 1 × 8 h × $40 = 8 h / $320.
  insert into public.work_tasks (id, vineyard_id, date, task_type, pruning_activity_id, created_by)
  values (v_t2, v_vineyard, timestamptz '2026-08-04T09:00:00Z', 'Pruning', v_activity, v_user)
  on conflict (id) do nothing;
  insert into public.work_task_labour_lines (
    id, work_task_id, vineyard_id, work_date, worker_type, worker_count,
    hours_per_worker, hourly_rate
  ) values (
    'aaaaaaa1-0000-4000-8000-000000000002', v_t2, v_vineyard, date '2026-08-04',
    'Permanent Staff', 1, 8, 40
  ) on conflict (id) do nothing;

  -- T1 (§22 "one Work Task") ------------------------------------------------
  -- Temporarily unlink T2/T3 by asserting on the aggregate with only T1 first:
  v_cost := public.pruning_activity_work_tasks_labour_cost(v_activity);
  v_hours := public.pruning_activity_work_tasks_labour_hours(v_activity);
  if v_cost is distinct from 810::numeric then
    -- With T1+T2 present the aggregate must already be 490+320.
    raise exception 'T-agg: expected 810, got %', v_cost;
  end if;
  if v_hours is distinct from 22::numeric then
    raise exception 'T-agg-hours: expected 22, got %', v_hours;
  end if;

  v_count := public.pruning_activity_work_task_count(v_activity);
  if v_count <> 2 then
    raise exception 'T-count: expected 2 linked tasks, got %', v_count;
  end if;

  -- Effective chain resolves through WORK TASKS.
  v_cost := public.pruning_activity_effective_labour_cost(v_activity);
  v_source := public.pruning_activity_labour_cost_source(v_activity);
  if v_cost is distinct from 810::numeric or v_source <> 'work_tasks' then
    raise exception 'T-effective: expected 810/work_tasks, got %/%', v_cost, v_source;
  end if;

  -- T3: piece-rate task joins — snapshot total adds; hours stay task-history.
  insert into public.work_tasks (
    id, vineyard_id, date, task_type, pruning_activity_id,
    costing_method, piece_rate_per_vine, piece_vine_count, created_by
  ) values (
    v_t3, v_vineyard, timestamptz '2026-08-05T09:00:00Z', 'Pruning', v_activity,
    'piece_rate', 0.5, 200, v_user
  ) on conflict (id) do nothing;

  v_cost := public.pruning_activity_effective_labour_cost(v_activity);
  if v_cost is distinct from 910::numeric then
    raise exception 'T-piece: expected 810 + 100 = 910, got %', v_cost;
  end if;

  -- Unlink T2 (§22 "unlink"): aggregate decreases; task survives standalone.
  perform public.set_work_task_pruning_activity(v_t2, null);
  v_cost := public.pruning_activity_effective_labour_cost(v_activity);
  if v_cost is distinct from 590::numeric then
    raise exception 'T-unlink: expected 490 + 100 = 590 after unlink, got %', v_cost;
  end if;
  if not exists (select 1 from public.work_tasks where id = v_t2 and deleted_at is null) then
    raise exception 'T-unlink: task must remain a valid standalone record';
  end if;

  -- Legacy activity L (§22 "legacy labour, no task"): 190-lines still resolve.
  insert into public.pruning_activities (
    id, vineyard_id, entry_date, worker_or_crew, pruning_method, season_year, created_by
  ) values (
    v_legacy, v_vineyard, date '2025-07-01', 'Dave + 2 casuals', 'spur', 2025, v_user
  ) on conflict (id) do nothing;
  insert into public.pruning_activity_labour_lines (
    id, pruning_activity_id, vineyard_id, work_date, worker_type, worker_count,
    hours_per_worker, hourly_rate
  ) values (
    'aaaaaaa1-0000-4000-8000-000000000003', v_legacy, v_vineyard, date '2025-07-01',
    'Casuals', 3, 6, 30
  ) on conflict (id) do nothing;

  v_cost := public.pruning_activity_effective_labour_cost(v_legacy);
  v_source := public.pruning_activity_labour_cost_source(v_legacy);
  if v_cost is distinct from 540::numeric or v_source <> 'pruning_labour_lines' then
    raise exception 'T-legacy: expected 540/pruning_labour_lines, got %/%', v_cost, v_source;
  end if;

  -- Legacy A-class (§22 "legacy labour + linked task"): Work Task wins once a
  -- linked task carries its own cost — no addition of the two.
  perform public.set_work_task_pruning_activity(v_t2, v_legacy);
  v_cost := public.pruning_activity_effective_labour_cost(v_legacy);
  v_source := public.pruning_activity_labour_cost_source(v_legacy);
  if v_cost is distinct from 320::numeric or v_source <> 'work_tasks' then
    raise exception 'T-authority: expected 320/work_tasks (task outranks legacy lines, never 860), got %/%', v_cost, v_source;
  end if;

  -- JSON exposes the linked-task set and derived totals.
  v_json := public.pruning_activity_json(v_activity, false);
  if (v_json->'activity'->>'work_task_count')::int <> 2 then
    raise exception 'T-json: expected work_task_count 2, got %', v_json->'activity'->>'work_task_count';
  end if;
  if (v_json->'totals'->>'labour_cost')::numeric is distinct from 590::numeric then
    raise exception 'T-json-totals: expected derived 590, got %', v_json->'totals'->>'labour_cost';
  end if;

  -- OFFLINE LINKAGE (repair closeout fixture) --------------------------------
  -- Activity exists; device OFFLINE; Work Task A and Work Task B are created
  -- from it. The queued creates replay as plain INSERTs that CARRY
  -- pruning_activity_id — exactly the two inserts below. After sync the
  -- server must hold BOTH tasks with the same link and aggregate them as TWO
  -- linked Work Tasks; a retried replay (duplicate key) must change nothing.
  insert into public.pruning_activities (
    id, vineyard_id, entry_date, worker_or_crew, pruning_method, season_year, created_by
  ) values (
    v_off_activity, v_vineyard, date '2026-08-10', 'Offline crew', 'spur', 2026, v_user
  ) on conflict (id) do nothing;

  insert into public.work_tasks (id, vineyard_id, date, task_type, pruning_activity_id, created_by)
  values
    (v_off_a, v_vineyard, timestamptz '2026-08-10T09:00:00Z', 'Pruning', v_off_activity, v_user),
    (v_off_b, v_vineyard, timestamptz '2026-08-10T13:00:00Z', 'Pruning', v_off_activity, v_user)
  on conflict (id) do nothing;
  insert into public.work_task_labour_lines (
    id, work_task_id, vineyard_id, work_date, worker_type, worker_count,
    hours_per_worker, hourly_rate
  ) values
    ('aaaaaaa1-0000-4000-8000-000000000004', v_off_a, v_vineyard, date '2026-08-10', 'Victoria Labour Hire', 2, 7, 35),
    ('aaaaaaa1-0000-4000-8000-000000000005', v_off_b, v_vineyard, date '2026-08-10', 'Permanent Staff', 1, 8, 40)
  on conflict (id) do nothing;

  -- Retried replay of Task A (the duplicate/409 rule): idempotent no-op.
  insert into public.work_tasks (id, vineyard_id, date, task_type, pruning_activity_id, created_by)
  values (v_off_a, v_vineyard, timestamptz '2026-08-10T09:00:00Z', 'Pruning', v_off_activity, v_user)
  on conflict (id) do nothing;

  select count(*) into v_count from public.pruning_activity_work_task_ids(v_off_activity) f(id);
  if v_count <> 2 then
    raise exception 'T-offline: expected BOTH offline-created tasks linked after replay, got %', v_count;
  end if;
  if not exists (select 1 from public.pruning_activity_work_task_ids(v_off_activity) f(id) where f.id = v_off_a)
     or not exists (select 1 from public.pruning_activity_work_task_ids(v_off_activity) f(id) where f.id = v_off_b) then
    raise exception 'T-offline: a replayed task id is missing from the linked set';
  end if;
  v_cost := public.pruning_activity_effective_labour_cost(v_off_activity);
  v_hours := public.pruning_activity_effective_labour_hours(v_off_activity);
  v_source := public.pruning_activity_labour_cost_source(v_off_activity);
  if v_cost is distinct from 810::numeric or v_hours is distinct from 22::numeric or v_source <> 'work_tasks' then
    raise exception 'T-offline: expected 810 / 22 h / work_tasks, got % / % / %', v_cost, v_hours, v_source;
  end if;

  raise notice 'sql/200 repair tests: ALL PASS';
end $$;

rollback;

-- =====================================================================
-- 188_piece_rate_pruning_costing_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/188_piece_rate_pruning_costing.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects: work_tasks costing columns + generated total, the
--       piece-rate row table, its indexes, RLS and the soft-delete RPC
--   T2  Every EXISTING work task defaults to 'hourly' and its piece-rate
--       total is NULL — legacy behaviour is untouched
--   T3  costing_method is constrained to the two known values
--   T4  Piece-rate total is generated: 2,238 vines x $1.27 = $2,842.26,
--       rounded to cents exactly as both mobile clients round
--   T5  Exactly ONE cost source: an hourly job ignores the piece columns,
--       a piece-rate job ignores its labour lines' generated total, and
--       the two are never summed
--   T6  Hours survive on a piece-rate job as operational history
--   T7  HISTORICAL PROTECTION: editing paddocks.rows (incl. a per-row
--       vineCountOverride) after the fact does NOT re-cost a saved job
--   T8  Switching a task back to 'hourly' nulls the generated piece total
--   T9  Negative rate / negative quantity are rejected by check constraints
--   T10 work_task_piece_rate_rows: member RLS, one active row per
--       (task, block, row), soft delete via the RPC, no client hard delete
--   T11 An outsider can neither read nor write another vineyard's rows
--   T12 paddocks.rows[].vineCountOverride round-trips through JSONB
--   T13 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 188 piece rate pruning costing tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 188 is applied.
do $$
begin
  if to_regclass('public.work_task_piece_rate_rows') is null
     or to_regprocedure('public.soft_delete_work_task_piece_rate_row(uuid)') is null
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'work_tasks'
         and column_name = 'piece_rate_total_cost') then
    raise exception 'SQL 188 not applied — run sql/188_piece_rate_pruning_costing.sql first.';
  end if;
end$$;

do $$
declare
  u_mgr uuid;
  u_op  uuid;
  u_out uuid;
  v_vy  uuid := gen_random_uuid();
  v_vy2 uuid := gen_random_uuid();
  b_1   uuid := gen_random_uuid();
  row_a uuid := gen_random_uuid();
  row_b uuid := gen_random_uuid();
  row_c uuid := gen_random_uuid();
  t_leg uuid := gen_random_uuid();  -- legacy/hourly task
  t_pce uuid := gen_random_uuid();  -- piece-rate task
  t_oth uuid := gen_random_uuid();  -- other vineyard's task
  pr_1  uuid := gen_random_uuid();
  pr_2  uuid := gen_random_uuid();
  r     record;
  n     integer;
  num   numeric;
  v_failed boolean;
begin
  -- ---- fixtures ------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t188-mgr@test.local','t188-op@test.local','t188-out@test.local']) e;
  select id into u_mgr from auth.users where email = 't188-mgr@test.local';
  select id into u_op  from auth.users where email = 't188-op@test.local';
  select id into u_out from auth.users where email = 't188-out@test.local';

  insert into public.profiles (id, email)
  select u, 't188-' || u::text || '@test.local' from unnest(array[u_mgr, u_op, u_out]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_vy,  'T188 Piece Rate Vineyard'),
    (v_vy2, 'T188 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vy,  u_mgr, 'manager'),
    (v_vy,  u_op,  'operator'),
    (v_vy2, u_out, 'manager');

  -- A block with three mapped rows. Row C carries a MANUAL per-row count,
  -- which is what a real operator sets after walking the row.
  insert into public.paddocks (id, vineyard_id, name, vine_spacing, rows)
  values (b_1, v_vy, 'T188 Block 1', 1.8, jsonb_build_array(
    jsonb_build_object('id', row_a, 'number', 1),
    jsonb_build_object('id', row_b, 'number', 2),
    jsonb_build_object('id', row_c, 'number', 3, 'vineCountOverride', 746)
  ));

  -- ---- T1. Objects ---------------------------------------------------------
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'work_tasks'
    and column_name in ('costing_method','piece_rate_per_vine','piece_vine_count','piece_rate_total_cost');
  if n <> 4 then raise exception 'T1: expected 4 costing columns on work_tasks, found %', n; end if;

  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'work_task_piece_rate_rows'
    and column_name in ('work_task_id','vineyard_id','paddock_id','paddock_row_id','row_number','vine_count','deleted_at');
  if n <> 7 then raise exception 'T1: expected 7 snapshot columns, found %', n; end if;

  -- piece_rate_total_cost MUST be generated — a writable column could be set
  -- to something other than quantity x rate.
  select is_generated into r from information_schema.columns
  where table_schema = 'public' and table_name = 'work_tasks'
    and column_name = 'piece_rate_total_cost';
  if r.is_generated <> 'ALWAYS' then
    raise exception 'T1: piece_rate_total_cost must be a generated column';
  end if;

  if not exists (select 1 from pg_indexes where schemaname = 'public'
                 and indexname = 'uq_work_task_piece_rate_rows_active') then
    raise exception 'T1: active-row unique index missing';
  end if;

  if not (select relrowsecurity from pg_class
          where oid = 'public.work_task_piece_rate_rows'::regclass) then
    raise exception 'T1: RLS not enabled on work_task_piece_rate_rows';
  end if;
  raise notice 'T1 passed';

  -- ---- T2. Legacy rows are untouched ---------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- A task created by an OLD client that knows nothing about SQL 188.
  insert into public.work_tasks
    (id, vineyard_id, paddock_id, paddock_name, date, task_type, duration_hours, created_by, updated_by)
  values
    (t_leg, v_vy, b_1, 'T188 Block 1', now(), 'Pruning', 16, u_mgr, u_mgr);

  select * into r from public.work_tasks where id = t_leg;
  if r.costing_method <> 'hourly' then
    raise exception 'T2: legacy task must default to hourly, got %', r.costing_method;
  end if;
  if r.piece_rate_total_cost is not null then
    raise exception 'T2: an hourly task must have NULL piece_rate_total_cost';
  end if;
  raise notice 'T2 passed';

  -- ---- T3. costing_method is constrained ------------------------------------
  v_failed := false;
  begin
    update public.work_tasks set costing_method = 'per_bin' where id = t_leg;
  exception when check_violation then
    v_failed := true;
  end;
  if not v_failed then raise exception 'T3: unknown costing_method must be rejected'; end if;
  raise notice 'T3 passed';

  -- ---- T4. The generated piece-rate total ------------------------------------
  -- THE worked example carried by both mobile clients and the docs.
  insert into public.work_tasks
    (id, vineyard_id, paddock_id, paddock_name, date, task_type, duration_hours,
     costing_method, piece_rate_per_vine, piece_vine_count, created_by, updated_by)
  values
    (t_pce, v_vy, b_1, 'T188 Block 1', now(), 'Pruning', 24,
     'piece_rate', 1.2700, 2238, u_mgr, u_mgr);

  select piece_rate_total_cost into num from public.work_tasks where id = t_pce;
  if num is distinct from 2842.26::numeric then
    raise exception 'T4: expected 2842.26 (2238 x 1.27), got %', num;
  end if;
  raise notice 'T4 passed';

  -- ---- T5. Exactly one cost source ------------------------------------------
  -- Labour lines exist on BOTH tasks. Their generated total_cost is the hourly
  -- arithmetic and must never be added to the piece-rate total.
  insert into public.work_task_labour_lines
    (work_task_id, vineyard_id, work_date, worker_type, worker_count, hours_per_worker, hourly_rate, created_by, updated_by)
  values
    (t_leg, v_vy, current_date, 'Crew', 2, 8, 32, u_mgr, u_mgr),
    (t_pce, v_vy, current_date, 'Crew', 3, 8, 32, u_mgr, u_mgr);

  -- Hourly job: labour lines are the cost (2 x 8 x 32 = 512).
  select sum(total_cost) into num from public.work_task_labour_lines
   where work_task_id = t_leg and deleted_at is null;
  if num is distinct from 512::numeric then
    raise exception 'T5: hourly labour cost expected 512, got %', num;
  end if;
  select piece_rate_total_cost into num from public.work_tasks where id = t_leg;
  if num is not null then
    raise exception 'T5: an hourly task must not carry a piece-rate total';
  end if;

  -- Piece-rate job: its labour lines still compute an hourly figure (768), but
  -- the job's labour cost is the piece-rate total and NOTHING is summed.
  select sum(total_cost) into num from public.work_task_labour_lines
   where work_task_id = t_pce and deleted_at is null;
  if num is distinct from 768::numeric then
    raise exception 'T5: labour lines must keep computing hourly arithmetic, got %', num;
  end if;
  select piece_rate_total_cost into num from public.work_tasks where id = t_pce;
  if num is distinct from 2842.26::numeric then
    raise exception 'T5: piece-rate total must be unaffected by labour lines, got %', num;
  end if;
  -- The two numbers are genuinely distinct — a consumer summing them would be
  -- reporting 3,610.26, which is not what anyone agreed to pay.
  if 2842.26::numeric + 768::numeric = 2842.26::numeric then
    raise exception 'T5: fixture is degenerate';
  end if;
  raise notice 'T5 passed';

  -- ---- T6. Hours survive as operational history ------------------------------
  select sum(total_hours) into num from public.work_task_labour_lines
   where work_task_id = t_pce and deleted_at is null;
  if num is distinct from 24::numeric then
    raise exception 'T6: piece-rate job must keep its 24 person-hours, got %', num;
  end if;
  raise notice 'T6 passed';

  -- ---- T7. HISTORICAL PROTECTION ---------------------------------------------
  -- Snapshot the per-row detail the job was priced on.
  insert into public.work_task_piece_rate_rows
    (id, work_task_id, vineyard_id, paddock_id, paddock_row_id, row_number, vine_count, created_by, updated_by)
  values
    (pr_1, t_pce, v_vy, b_1, row_a, 1, 746, u_mgr, u_mgr),
    (pr_2, t_pce, v_vy, b_1, row_b, 2, 746, u_mgr, u_mgr);
  insert into public.work_task_piece_rate_rows
    (work_task_id, vineyard_id, paddock_id, paddock_row_id, row_number, vine_count, created_by, updated_by)
  values
    (t_pce, v_vy, b_1, row_c, 3, 746, u_mgr, u_mgr);

  select sum(vine_count) into num from public.work_task_piece_rate_rows
   where work_task_id = t_pce and deleted_at is null;
  if num is distinct from 2238::numeric then
    raise exception 'T7: snapshot rows must total 2238, got %', num;
  end if;

  -- Six months later the block is re-mapped and every row's manual count is
  -- raised. The COMPLETED job must not move a cent.
  update public.paddocks
     set rows = jsonb_build_array(
       jsonb_build_object('id', row_a, 'number', 1, 'vineCountOverride', 900),
       jsonb_build_object('id', row_b, 'number', 2, 'vineCountOverride', 900),
       jsonb_build_object('id', row_c, 'number', 3, 'vineCountOverride', 900))
   where id = b_1;

  select piece_vine_count into n from public.work_tasks where id = t_pce;
  if n <> 2238 then
    raise exception 'T7: snapshotted quantity changed to % after a block edit', n;
  end if;
  select piece_rate_total_cost into num from public.work_tasks where id = t_pce;
  if num is distinct from 2842.26::numeric then
    raise exception 'T7: completed job re-costed to % after a block edit', num;
  end if;
  select sum(vine_count) into num from public.work_task_piece_rate_rows
   where work_task_id = t_pce and deleted_at is null;
  if num is distinct from 2238::numeric then
    raise exception 'T7: per-row snapshot changed to % after a block edit', num;
  end if;
  raise notice 'T7 passed';

  -- ---- T8. Switching back to hourly nulls the piece total ---------------------
  update public.work_tasks set costing_method = 'hourly' where id = t_pce;
  select piece_rate_total_cost into num from public.work_tasks where id = t_pce;
  if num is not null then
    raise exception 'T8: piece total must be NULL once the task is hourly, got %', num;
  end if;
  -- The agreement itself is retained, so switching back restores the same value.
  update public.work_tasks set costing_method = 'piece_rate' where id = t_pce;
  select piece_rate_total_cost into num from public.work_tasks where id = t_pce;
  if num is distinct from 2842.26::numeric then
    raise exception 'T8: switching back must restore 2842.26, got %', num;
  end if;
  raise notice 'T8 passed';

  -- ---- T9. Implausible values are rejected ------------------------------------
  v_failed := false;
  begin
    update public.work_tasks set piece_rate_per_vine = -1 where id = t_pce;
  exception when check_violation then
    v_failed := true;
  end;
  if not v_failed then raise exception 'T9: a negative rate must be rejected'; end if;

  v_failed := false;
  begin
    update public.work_tasks set piece_vine_count = -1 where id = t_pce;
  exception when check_violation then
    v_failed := true;
  end;
  if not v_failed then raise exception 'T9: a negative vine count must be rejected'; end if;

  v_failed := false;
  begin
    insert into public.work_task_piece_rate_rows
      (work_task_id, vineyard_id, paddock_id, paddock_row_id, row_number, vine_count)
    values (t_pce, v_vy, b_1, gen_random_uuid(), 9, -5);
  exception when check_violation then
    v_failed := true;
  end;
  if not v_failed then raise exception 'T9: a negative snapshot count must be rejected'; end if;
  raise notice 'T9 passed';

  -- ---- T10. Snapshot table behaviour ------------------------------------------
  -- One ACTIVE snapshot per (task, block, row).
  v_failed := false;
  begin
    insert into public.work_task_piece_rate_rows
      (work_task_id, vineyard_id, paddock_id, paddock_row_id, row_number, vine_count)
    values (t_pce, v_vy, b_1, row_a, 1, 500);
  exception when unique_violation then
    v_failed := true;
  end;
  if not v_failed then raise exception 'T10: duplicate active snapshot row must be rejected'; end if;

  -- Clients may never hard-delete; the RPC soft-deletes.
  perform set_config('role', 'authenticated', true);
  delete from public.work_task_piece_rate_rows where id = pr_1;
  if not exists (select 1 from public.work_task_piece_rate_rows where id = pr_1) then
    raise exception 'T10: client hard delete must be blocked by RLS';
  end if;

  perform public.soft_delete_work_task_piece_rate_row(pr_1);
  select deleted_at into r from public.work_task_piece_rate_rows where id = pr_1;
  if r.deleted_at is null then
    raise exception 'T10: soft delete RPC did not set deleted_at';
  end if;

  -- With the row soft-deleted, the same (task, block, row) can be re-added.
  insert into public.work_task_piece_rate_rows
    (work_task_id, vineyard_id, paddock_id, paddock_row_id, row_number, vine_count)
  values (t_pce, v_vy, b_1, row_a, 1, 800);

  -- An operator is a member and can read the snapshot.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  select count(*) into n from public.work_task_piece_rate_rows
   where work_task_id = t_pce and deleted_at is null;
  if n <> 3 then raise exception 'T10: member expected 3 active rows, found %', n; end if;
  raise notice 'T10 passed';

  -- ---- T11. Outsiders are blocked ---------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_out::text, 'role', 'authenticated')::text, true);

  select count(*) into n from public.work_task_piece_rate_rows where vineyard_id = v_vy;
  if n <> 0 then raise exception 'T11: outsider read % snapshot rows', n; end if;

  v_failed := false;
  begin
    insert into public.work_task_piece_rate_rows
      (work_task_id, vineyard_id, paddock_id, paddock_row_id, row_number, vine_count)
    values (t_pce, v_vy, b_1, gen_random_uuid(), 77, 100);
  exception when insufficient_privilege then
    v_failed := true;
  end;
  if not v_failed then raise exception 'T11: outsider insert must be blocked by RLS'; end if;

  v_failed := false;
  begin
    perform public.soft_delete_work_task_piece_rate_row(pr_2);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then raise exception 'T11: outsider soft delete must be rejected'; end if;
  raise notice 'T11 passed';

  -- ---- T12. vineCountOverride round-trips through JSONB -------------------------
  perform set_config('role', 'postgres', true);
  select (elem ->> 'vineCountOverride')::integer into n
    from public.paddocks p,
         lateral jsonb_array_elements(p.rows) elem
   where p.id = b_1 and (elem ->> 'id')::uuid = row_c;
  if n <> 900 then
    raise exception 'T12: vineCountOverride expected 900 after the edit, got %', n;
  end if;

  -- Absent means "use the calculated estimate" — never zero.
  update public.paddocks
     set rows = jsonb_build_array(jsonb_build_object('id', row_a, 'number', 1))
   where id = b_1;
  select count(*) into n
    from public.paddocks p,
         lateral jsonb_array_elements(p.rows) elem
   where p.id = b_1 and elem ? 'vineCountOverride';
  if n <> 0 then raise exception 'T12: a cleared override must be absent, not 0'; end if;
  raise notice 'T12 passed';

  raise notice 'SQL 188 piece rate pruning costing tests: ALL PASSED';
end$$;

-- ---- T13. Discard everything -------------------------------------------------
rollback;

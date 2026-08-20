-- =============================================================================
-- Tests for sql/201_spray_job_plan_provenance.sql (run AFTER applying 201).
-- Style matches sql/tests/200: temporary fixtures inside a rolled-back
-- transaction, assertions via one DO block. Requires a scratch/disposable
-- database — NEVER run against production data.
--
-- The SQL editor runs with no JWT, so auth.uid() is NULL and
-- spray_job_resistance_link_state would raise 'Authentication required'. The
-- fixture therefore creates a test manager, adds vineyard membership, and
-- simulates the session via request.jwt.claims — exactly the sql/tests/200
-- pattern. Superuser inserts bypass RLS; the sql/201 triggers are SECURITY
-- DEFINER so they fire and enforce regardless.
--
-- Success = a single NOTICE: 'sql/201 provenance tests: ALL PASS'.
-- =============================================================================

begin;

do $$
declare
  v_vy1 uuid := '11111111-2222-4333-8444-555555555501';
  v_vy2 uuid := '11111111-2222-4333-8444-555555555502';
  v_user uuid;
  v_block_a uuid := 'aaaaaaa1-0000-4000-8000-000000000201';
  v_block_b uuid := 'aaaaaaa1-0000-4000-8000-000000000202';
  v_plan uuid := 'bbbbbbb1-0000-4000-8000-000000000201';
  v_plan_future uuid := 'bbbbbbb1-0000-4000-8000-000000000202';
  v_plan_foreign uuid := 'bbbbbbb1-0000-4000-8000-000000000203';
  v_j_legacy uuid := 'ccccccc1-0000-4000-8000-000000000201';
  v_j1 uuid := 'ccccccc1-0000-4000-8000-000000000202';
  v_j2 uuid := 'ccccccc1-0000-4000-8000-000000000203';
  v_j3 uuid := 'ccccccc1-0000-4000-8000-000000000204';
  v_j4 uuid := 'ccccccc1-0000-4000-8000-000000000205';
  v_j_bad uuid := 'ccccccc1-0000-4000-8000-000000000206';
  v_r1 uuid := 'ddddddd1-0000-4000-8000-000000000201';
  v_pos1_snapshot jsonb := jsonb_build_object(
    'id', 'pos-1',
    'products', jsonb_build_array(jsonb_build_object(
      'id', 'prod-1', 'group_codes', jsonb_build_array('3'), 'source', 'group')),
    'note', 'first cover spray'
  );
  v_pos2_snapshot jsonb := jsonb_build_object(
    'id', 'pos-2',
    'products', jsonb_build_array(jsonb_build_object(
      'id', 'prod-2', 'group_codes', jsonb_build_array('11'), 'source', 'group'))
  );
  v_rev_before bigint;
  v_rev_after bigint;
  v_count integer;
  v_state text;
  v_failed boolean;
  v_snapshot jsonb;
  v_cov record;
begin
  -- ---- fixture manager + simulated session ---------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          't201-mgr@test.local', 'x', now(), now(), now())
  on conflict do nothing;
  select id into v_user from auth.users where email = 't201-mgr@test.local';
  insert into public.profiles (id, email) values (v_user, 't201-mgr@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_vy1, 'Provenance Test Vineyard A'),
    (v_vy2, 'Provenance Test Vineyard B')
  on conflict (id) do nothing;
  insert into public.vineyard_members (vineyard_id, user_id, role)
  values (v_vy1, v_user, 'manager')
  on conflict do nothing;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated')::text,
    true
  );
  if auth.uid() is distinct from v_user then
    raise exception 'fixture: simulated session did not take (auth.uid() = %)', auth.uid();
  end if;

  insert into public.paddocks (id, vineyard_id, name) values
    (v_block_a, v_vy1, 'Block A'),
    (v_block_b, v_vy1, 'Block B')
  on conflict (id) do nothing;

  -- Plan P in vineyard A: pos-1 = FRAC 3, pos-2 = FRAC 11 (sql/196 shape).
  insert into public.resistance_plans (id, vineyard_id, season_id, disease, block_ids, positions)
  values (
    v_plan, v_vy1, '2026/27', 'powdery_mildew', array[v_block_a, v_block_b],
    jsonb_build_array(v_pos1_snapshot, v_pos2_snapshot)
  );
  select server_revision into v_rev_before from public.resistance_plans where id = v_plan;

  -- T1: legacy unlinked job stays valid; link state 'none'. ------------------
  insert into public.spray_jobs (id, vineyard_id, name, status, created_by)
  values (v_j_legacy, v_vy1, 'Legacy ad-hoc job', 'planned', v_user);
  if public.spray_job_resistance_link_state(v_j_legacy) <> 'none' then
    raise exception 'T1: legacy job should report link state none';
  end if;

  -- T2: valid Plan Position -> Job with frozen snapshot. ---------------------
  insert into public.spray_jobs (
    id, vineyard_id, name, status, target, created_by,
    resistance_plan_id, resistance_position_id,
    resistance_position_snapshot, resistance_plan_source_revision
  ) values (
    v_j1, v_vy1, 'Powdery 2026/27 — Spray 1 (Block A)', 'planned',
    'powdery_mildew', v_user,
    v_plan, 'pos-1', v_pos1_snapshot, v_rev_before
  );
  if public.spray_job_resistance_link_state(v_j1) <> 'linked' then
    raise exception 'T2: expected linked state for J1';
  end if;
  select resistance_position_snapshot into v_snapshot
  from public.spray_jobs where id = v_j1;
  if v_snapshot #>> '{products,0,group_codes,0}' <> '3' then
    raise exception 'T2: snapshot did not freeze FRAC 3';
  end if;

  -- T4: one position -> multiple jobs (no uniqueness on plan+position). ------
  insert into public.spray_jobs (
    id, vineyard_id, name, status, created_by,
    resistance_plan_id, resistance_position_id,
    resistance_position_snapshot, resistance_plan_source_revision
  ) values (
    v_j2, v_vy1, 'Powdery 2026/27 — Spray 1 (Block B)', 'planned', v_user,
    v_plan, 'pos-1', v_pos1_snapshot, v_rev_before
  );
  select count(*) into v_count
  from public.resistance_position_spray_job_ids(v_plan, 'pos-1') t(id);
  if v_count <> 2 then
    raise exception 'T4: expected 2 jobs on pos-1, got %', v_count;
  end if;

  -- Proposed coverage: J1 -> Block A, J2 -> Block B.
  insert into public.spray_job_paddocks (spray_job_id, paddock_id) values
    (v_j1, v_block_a), (v_j2, v_block_b);

  -- T9a: pre-completion re-link is allowed (J2 has no record yet). -----------
  update public.spray_jobs
  set resistance_position_id = 'pos-2', resistance_position_snapshot = v_pos2_snapshot
  where id = v_j2;
  update public.spray_jobs
  set resistance_position_id = 'pos-1', resistance_position_snapshot = v_pos1_snapshot
  where id = v_j2;

  -- T8a: completion writes spray_records.spray_job_id (Job -> Record link),
  -- with sql/195 block attribution for Block A only (partial execution).
  insert into public.spray_records (id, vineyard_id, date, spray_job_id, application_blocks, created_by)
  values (
    v_r1, v_vy1, now(), v_j1,
    jsonb_build_array(jsonb_build_object('blockId', v_block_a::text)),
    v_user
  );
  if (select block_ids from public.spray_records where id = v_r1) <> array[v_block_a] then
    raise exception 'T8a: block_ids not derived from application_blocks';
  end if;

  -- T11: job + record activity must NOT bump the plan revision. --------------
  select server_revision into v_rev_after from public.resistance_plans where id = v_plan;
  if v_rev_after is distinct from v_rev_before then
    raise exception 'T11: job/record activity bumped plan revision % -> %', v_rev_before, v_rev_after;
  end if;

  -- T3: cross-vineyard link rejected (job in B -> plan in A). ----------------
  v_failed := false;
  begin
    insert into public.spray_jobs (
      id, vineyard_id, name, created_by,
      resistance_plan_id, resistance_position_id, resistance_position_snapshot
    ) values (
      v_j_bad, v_vy2, 'Wrong vineyard job', v_user,
      v_plan, 'pos-1', v_pos1_snapshot
    );
  exception when others then
    v_failed := true;
    if position('different vineyard' in sqlerrm) = 0 then raise; end if;
  end;
  if not v_failed then
    raise exception 'T3: cross-vineyard plan link was accepted';
  end if;

  -- T6: link shape is all-or-nothing and self-consistent. --------------------
  v_failed := false;
  begin  -- position id without plan id
    insert into public.spray_jobs (id, vineyard_id, name, resistance_position_id)
    values (v_j_bad, v_vy1, 'Shape: orphan position', 'pos-1');
  exception when others then
    v_failed := true;
    if position('spray_jobs_resistance_link_shape' in sqlerrm) = 0 then raise; end if;
  end;
  if not v_failed then raise exception 'T6a: orphan position id accepted'; end if;

  v_failed := false;
  begin  -- linked without snapshot
    insert into public.spray_jobs (id, vineyard_id, name, resistance_plan_id, resistance_position_id)
    values (v_j_bad, v_vy1, 'Shape: no snapshot', v_plan, 'pos-1');
  exception when others then
    v_failed := true;
    if position('spray_jobs_resistance_link_shape' in sqlerrm) = 0 then raise; end if;
  end;
  if not v_failed then raise exception 'T6b: link without frozen snapshot accepted'; end if;

  v_failed := false;
  begin  -- snapshot of a DIFFERENT position
    insert into public.spray_jobs (
      id, vineyard_id, name,
      resistance_plan_id, resistance_position_id, resistance_position_snapshot
    ) values (v_j_bad, v_vy1, 'Shape: mismatched snapshot', v_plan, 'pos-1', v_pos2_snapshot);
  exception when others then
    v_failed := true;
    if position('spray_jobs_resistance_link_shape' in sqlerrm) = 0 then raise; end if;
  end;
  if not v_failed then raise exception 'T6c: mismatched snapshot accepted'; end if;

  -- T5: editing the PLAN does not rewrite the frozen job snapshot. -----------
  update public.resistance_plans
  set positions = jsonb_build_array(
    jsonb_build_object('id', 'pos-1', 'products', jsonb_build_array(
      jsonb_build_object('id', 'prod-1', 'group_codes', jsonb_build_array('11'), 'source', 'group'))),
    v_pos2_snapshot
  )
  where id = v_plan;
  select resistance_position_snapshot into v_snapshot
  from public.spray_jobs where id = v_j1;
  if v_snapshot #>> '{products,0,group_codes,0}' <> '3' then
    raise exception 'T5: plan edit rewrote the frozen job snapshot (original intent lost)';
  end if;

  -- T9b: provenance is FROZEN once a live record references the job. ---------
  v_failed := false;
  begin  -- re-link attempt
    update public.spray_jobs
    set resistance_position_id = 'pos-2', resistance_position_snapshot = v_pos2_snapshot
    where id = v_j1;
  exception when others then
    v_failed := true;
    if position('frozen' in sqlerrm) = 0 then raise; end if;
  end;
  if not v_failed then raise exception 'T9b: completed job provenance was re-linked'; end if;

  v_failed := false;
  begin  -- unlink attempt
    update public.spray_jobs
    set resistance_plan_id = null, resistance_position_id = null,
        resistance_position_snapshot = null, resistance_plan_source_revision = null
    where id = v_j1;
  exception when others then
    v_failed := true;
    if position('frozen' in sqlerrm) = 0 then raise; end if;
  end;
  if not v_failed then raise exception 'T9c: completed job provenance was unlinked'; end if;

  -- Normal (non-provenance) edits stay allowed after completion.
  update public.spray_jobs set notes = 'operator note' where id = v_j1;

  -- T10: derived multi-block partial coverage. -------------------------------
  select * into v_cov from public.resistance_position_coverage(v_plan, 'pos-1');
  if v_cov.spray_job_count <> 2 then
    raise exception 'T10: expected 2 jobs, got %', v_cov.spray_job_count;
  end if;
  if not (v_cov.proposed_paddock_ids @> array[v_block_a, v_block_b]
          and array_length(v_cov.proposed_paddock_ids, 1) = 2) then
    raise exception 'T10: proposed coverage should be blocks A+B, got %', v_cov.proposed_paddock_ids;
  end if;
  if v_cov.completed_block_ids <> array[v_block_a] then
    raise exception 'T10: completed coverage should be block A only, got %', v_cov.completed_block_ids;
  end if;

  -- T7: offline ordering — job syncs BEFORE its plan. -------------------------
  insert into public.spray_jobs (
    id, vineyard_id, name, created_by,
    resistance_plan_id, resistance_position_id, resistance_position_snapshot
  ) values (
    v_j3, v_vy1, 'Offline-first job', v_user,
    v_plan_future, 'pos-off',
    jsonb_build_object('id', 'pos-off', 'products', jsonb_build_array(
      jsonb_build_object('id', 'prod-off', 'group_codes', jsonb_build_array('7'), 'source', 'group')))
  ) on conflict (id) do nothing;
  if public.spray_job_resistance_link_state(v_j3) <> 'pending_plan' then
    raise exception 'T7: expected pending_plan before the plan lands';
  end if;

  -- Retried replay of the same queued create: idempotent no-op.
  insert into public.spray_jobs (id, vineyard_id, name, resistance_plan_id,
                                 resistance_position_id, resistance_position_snapshot)
  values (v_j3, v_vy1, 'Offline-first job (retry)', v_plan_future, 'pos-off',
          jsonb_build_object('id', 'pos-off'))
  on conflict (id) do nothing;
  select count(*) into v_count from public.spray_jobs where id = v_j3;
  if v_count <> 1 then raise exception 'T7: replay duplicated the job'; end if;

  -- The plan lands later, same vineyard: link resolves.
  insert into public.resistance_plans (id, vineyard_id, season_id, disease, positions)
  values (v_plan_future, v_vy1, '2026/27', 'downy_mildew', jsonb_build_array(
    jsonb_build_object('id', 'pos-off', 'products', jsonb_build_array(
      jsonb_build_object('id', 'prod-off', 'group_codes', jsonb_build_array('7'), 'source', 'group')))));
  if public.spray_job_resistance_link_state(v_j3) <> 'linked' then
    raise exception 'T7: link did not resolve after the plan landed';
  end if;
  select count(*) into v_count
  from public.resistance_position_spray_job_ids(v_plan_future, 'pos-off') t(id);
  if v_count <> 1 then raise exception 'T7: resolved position should list the offline job'; end if;

  -- T8b: a pending link whose plan lands in ANOTHER vineyard stays inert. ----
  insert into public.spray_jobs (
    id, vineyard_id, name,
    resistance_plan_id, resistance_position_id, resistance_position_snapshot
  ) values (
    v_j4, v_vy1, 'Pending link, foreign plan',
    v_plan_foreign, 'pos-x', jsonb_build_object('id', 'pos-x')
  );
  insert into public.resistance_plans (id, vineyard_id, season_id, disease, positions)
  values (v_plan_foreign, v_vy2, '2026/27', 'botrytis', jsonb_build_array(
    jsonb_build_object('id', 'pos-x')));
  if public.spray_job_resistance_link_state(v_j4) <> 'cross_vineyard_invalid' then
    raise exception 'T8b: foreign late plan should mark the link cross_vineyard_invalid';
  end if;
  select count(*) into v_count
  from public.resistance_position_spray_job_ids(v_plan_foreign, 'pos-x') t(id);
  if v_count <> 0 then
    raise exception 'T8b: cross-vineyard link must never resolve, got % job(s)', v_count;
  end if;

  -- T12: sql/033 guard retained — a record may not link a foreign job. -------
  v_failed := false;
  begin
    insert into public.spray_records (id, vineyard_id, date, spray_job_id)
    values ('ddddddd1-0000-4000-8000-000000000202', v_vy2, now(), v_j1);
  exception when others then
    v_failed := true;
    if position('different vineyard' in sqlerrm) = 0 then raise; end if;
  end;
  if not v_failed then
    raise exception 'T12: record in vineyard B linked a job in vineyard A';
  end if;

  raise notice 'sql/201 provenance tests: ALL PASS';
end $$;

rollback;

-- =====================================================================
-- 167_pruning_allocation_id_resolution_tests.sql — rollback-only
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/167_pruning_allocation_id_resolution.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production pruning row is created, changed or deleted.
--
-- Test map
--   T1  Objects, signature, security definer, search_path, grants
--   T2  resolve_pruning_allocation_id: derived fallback, determinism, guards
--   T3  A migrated LEGACY allocation keeps its ORIGINAL id (never the derived one)
--   T4  Update payload INCLUDES the legacy allocation id  -> source "supplied"
--   T5  Update payload OMITS the id                       -> source "existing"
--       (the regression: it used to derive a second id and fail/lose the block)
--   T6  Adding a SECOND block: legacy stays, the new block derives its id
--   T7  Repeated identical update is idempotent (ids, counts, quarters stable)
--   T8  A supplied id owned by ANOTHER activity is rejected and never reassigned
--   T9  A supplied id owned by another BLOCK of the same activity is rejected
--   T10 An unused random id for an already-allocated block is rejected, and a
--       duplicate live (activity, block) allocation is impossible at any level
--   T11 Remove then re-add a block without an id revives the SAME allocation row
--   INV Cross-cutting invariants
--   T12 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 167 allocation id resolution tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 167 is applied.
do $$
begin
  if to_regprocedure('public.resolve_pruning_allocation_id(uuid, uuid, uuid)') is null then
    raise exception 'SQL 167 not applied — run sql/167_pruning_allocation_id_resolution.sql first.';
  end if;
end$$;

do $$
declare
  u_mgr    uuid;
  v_vy     uuid := gen_random_uuid();
  b_cab    uuid := gen_random_uuid();
  b_sauv   uuid := gen_random_uuid();
  b_pinot  uuid := gen_random_uuid();
  e_leg    uuid := gen_random_uuid();   -- legacy single-block entry == its activity
  a_other  uuid := gen_random_uuid();   -- a second, unrelated activity
  alloc_derived_cab  uuid;
  alloc_derived_sauv uuid;
  alloc_other        uuid;
  alloc_sauv         uuid;
  ghost    uuid := gen_random_uuid();   -- an id that exists nowhere
  r        jsonb;
  c        jsonb;
  res      jsonb;
  n        integer;
  num      numeric;
  ok       boolean;
  aid      uuid;
  t0       timestamptz := now() - interval '2 hours';
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated', 't167-mgr@test.local', 'x', now(), now(), now());
  select id into u_mgr from auth.users where email = 't167-mgr@test.local';

  insert into public.profiles (id, email) values (u_mgr, 't167-mgr@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values (v_vy, 'T167 Allocation Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values (v_vy, u_mgr, 'manager');

  insert into public.paddocks (id, vineyard_id, name) values
    (b_cab,   v_vy, 'T167 Cab Franc'),
    (b_sauv,  v_vy, 'T167 Sauvignon Blanc'),
    (b_pinot, v_vy, 'T167 Pinot Noir');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);

  -- ---- T1. Objects, security, grants -------------------------------------
  select count(*) into n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'resolve_pruning_allocation_id' and p.pronargs = 3;
  assert n = 1, 'T1 resolve_pruning_allocation_id(uuid, uuid, uuid) must exist, found ' || n;

  select p.prosecdef into ok
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'resolve_pruning_allocation_id';
  assert ok, 'T1 the resolver must be security definer';

  select coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=public%' into ok
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'resolve_pruning_allocation_id';
  assert ok, 'T1 the resolver must pin search_path';

  assert not has_function_privilege('anon',
    'public.resolve_pruning_allocation_id(uuid, uuid, uuid)', 'execute'),
    'T1 anon must NOT execute the resolver';
  assert has_function_privilege('authenticated',
    'public.resolve_pruning_allocation_id(uuid, uuid, uuid)', 'execute'),
    'T1 authenticated must execute the resolver';
  assert not has_function_privilege('anon',
    'public.apply_pruning_activity_allocation(uuid, uuid, date, text, text, text, integer, timestamptz, jsonb, integer)', 'execute'),
    'T1 the allocation helper must stay internal';
  assert exists (
    select 1 from pg_indexes
    where schemaname = 'public' and indexname = 'pruning_entries_activity_block_unique'),
    'T1 the one-allocation-per-(activity, block) index must exist';
  raise notice 'T1 passed: resolver installed, secured and still internal where it should be';

  -- ---- T2. Resolver: derived fallback, determinism, guards -----------------
  res := public.resolve_pruning_allocation_id(a_other, b_cab, null);
  assert res->>'source' = 'derived', 'T2 an unknown pair must fall through to derived';
  assert (res->>'allocation_id')::uuid = public.derive_pruning_allocation_id(a_other, b_cab),
    'T2 the derived id must match derive_pruning_allocation_id';
  assert res->>'rejected_allocation_id' is null, 'T2 nothing is rejected when nothing was supplied';
  assert public.resolve_pruning_allocation_id(a_other, b_cab)->>'allocation_id'
       = public.resolve_pruning_allocation_id(a_other, b_cab)->>'allocation_id',
    'T2 resolution must be deterministic';

  -- A supplied id that exists nowhere is accepted for a block with no allocation.
  res := public.resolve_pruning_allocation_id(a_other, b_cab, ghost);
  assert res->>'source' = 'supplied', 'T2 a free id is usable for an unallocated block';
  assert (res->>'allocation_id')::uuid = ghost, 'T2 the free supplied id must be honoured';

  ok := false;
  begin
    perform public.resolve_pruning_allocation_id(null, b_cab, null);
  exception when others then ok := true;
  end;
  assert ok, 'T2 a null activity id must be refused';

  ok := false;
  begin
    perform public.resolve_pruning_allocation_id(a_other, null, null);
  exception when others then ok := true;
  end;
  assert ok, 'T2 a null block id must be refused';
  raise notice 'T2 passed: derived fallback, determinism and argument guards';

  -- ---- T3. A migrated legacy allocation keeps its ORIGINAL id --------------
  r := public.record_pruning_entry(
    p_id => e_leg, p_vineyard_id => v_vy,
    p_season_id => public.derive_pruning_season_id(v_vy, b_cab, 2026),
    p_paddock_id => b_cab, p_season_year => 2026, p_entry_date => date '2026-07-15',
    p_worker => 'Legacy build', p_labour_hours => 8, p_estimated_vines => 200,
    p_client_updated_at => t0,
    p_segments => '[{"row":40,"segment":1},{"row":40,"segment":2}]'::jsonb);
  assert (r->>'season_year')::integer = 2026, 'T3 SQL 161 season rule still applies';

  select pruning_activity_id into aid from public.pruning_entries where id = e_leg;
  assert aid = e_leg, 'T3 a legacy entry owns an activity keyed by its own id';

  alloc_derived_cab := public.derive_pruning_allocation_id(e_leg, b_cab);
  assert alloc_derived_cab <> e_leg,
    'T3 the legacy allocation id is NOT the derived id — this is the whole bug';

  res := public.resolve_pruning_allocation_id(e_leg, b_cab, null);
  assert res->>'source' = 'existing',
    'T3 the resolver must find the legacy allocation, got ' || (res->>'source');
  assert (res->>'allocation_id')::uuid = e_leg,
    'T3 the resolver must return the ORIGINAL legacy id';
  raise notice 'T3 passed: legacy allocation resolved by (activity, block), not by derivation';

  -- ---- T4. Update payload INCLUDES the legacy allocation id ----------------
  r := public.update_pruning_activity(
    p_activity_id => e_leg,
    p_activity => jsonb_build_object('entry_date', '2026-07-15',
      'worker_or_crew', 'Legacy build', 'labour_hours', 8),
    p_allocations => jsonb_build_array(
      jsonb_build_object('id', e_leg, 'paddock_id', b_cab, 'estimated_vines', 200,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 40, 'segment', 1),
          jsonb_build_object('row', 40, 'segment', 2)))),
    p_client_updated_at => t0 + interval '10 minutes');

  assert r->>'error' is null, 'T4 the update must succeed, got ' || coalesce(r->>'error', '-');
  assert (r#>>'{allocation_results,0,allocation_id}')::uuid = e_leg, 'T4 the legacy id is kept';
  assert r#>>'{allocation_results,0,allocation_id_source}' = 'supplied',
    'T4 a valid supplied id is used as supplied, got ' || (r#>>'{allocation_results,0,allocation_id_source}');
  assert r#>>'{allocation_results,0,rejected_allocation_id}' is null, 'T4 nothing rejected';
  assert jsonb_array_length(r->'removed_allocations') = 0, 'T4 no allocation may be removed';

  select count(*) into n from public.pruning_entries
  where pruning_activity_id = e_leg and paddock_id = b_cab;
  assert n = 1, 'T4 exactly ONE allocation row for (activity, block), got ' || n;
  select count(*) into n from public.pruning_entries where id = alloc_derived_cab;
  assert n = 0, 'T4 the derived id must never materialise';
  assert (r#>>'{canonical,totals,quarters}')::integer = 2, 'T4 the two quarters survive';
  raise notice 'T4 passed: an explicit legacy allocation id is honoured';

  -- ---- T5. Update payload OMITS the id (the regression) --------------------
  r := public.update_pruning_activity(
    p_activity_id => e_leg,
    p_activity => jsonb_build_object('entry_date', '2026-07-15',
      'worker_or_crew', 'Legacy build', 'labour_hours', 8.5),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 200,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 40, 'segment', 1),
          jsonb_build_object('row', 40, 'segment', 2)))),
    p_client_updated_at => t0 + interval '20 minutes');

  assert r->>'error' is null, 'T5 an id-less update must succeed, got ' || coalesce(r->>'error', '-');
  assert (r#>>'{allocation_results,0,allocation_id}')::uuid = e_leg,
    'T5 the existing legacy allocation must be reused';
  assert r#>>'{allocation_results,0,allocation_id_source}' = 'existing',
    'T5 source must be "existing", got ' || (r#>>'{allocation_results,0,allocation_id_source}');
  assert jsonb_array_length(r->'removed_allocations') = 0,
    'T5 the block must NOT be treated as removed';

  select count(*) into n from public.pruning_entries
  where pruning_activity_id = e_leg and paddock_id = b_cab;
  assert n = 1, 'T5 still exactly ONE allocation row for (activity, block), got ' || n;
  select count(*) into n from public.pruning_entries where id = alloc_derived_cab;
  assert n = 0, 'T5 no forked derived allocation';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = e_leg and deleted_at is null;
  assert n = 1, 'T5 one live allocation, got ' || n;
  assert (r#>>'{canonical,totals,quarters}')::integer = 2, 'T5 quarters preserved';
  select labour_hours into num from public.pruning_activities where id = e_leg;
  assert num = 8.5, 'T5 labour edited on the parent, got ' || coalesce(num::text, 'null');
  raise notice 'T5 passed: an omitted allocation id resolves to the existing allocation';

  -- ---- T6. Adding a SECOND block ------------------------------------------
  alloc_derived_sauv := public.derive_pruning_allocation_id(e_leg, b_sauv);
  r := public.update_pruning_activity(
    p_activity_id => e_leg,
    p_activity => jsonb_build_object('entry_date', '2026-07-15', 'labour_hours', 8.5),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 200,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 40, 'segment', 1),
          jsonb_build_object('row', 40, 'segment', 2))),
      jsonb_build_object('paddock_id', b_sauv, 'estimated_vines', 300,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 66, 'segment', 1),
          jsonb_build_object('row', 66, 'segment', 2),
          jsonb_build_object('row', 67, 'segment', 1)))),
    p_client_updated_at => t0 + interval '30 minutes');

  assert r->>'error' is null, 'T6 adding a block must succeed';
  assert (r#>>'{allocation_results,0,allocation_id}')::uuid = e_leg, 'T6 legacy block untouched';
  assert r#>>'{allocation_results,0,allocation_id_source}' = 'existing', 'T6 legacy source';
  assert (r#>>'{allocation_results,1,allocation_id}')::uuid = alloc_derived_sauv,
    'T6 a genuinely new block derives its allocation id';
  assert r#>>'{allocation_results,1,allocation_id_source}' = 'derived',
    'T6 the new block source must be "derived", got ' || (r#>>'{allocation_results,1,allocation_id_source}');
  assert (r#>>'{canonical,totals,allocation_count}')::integer = 2, 'T6 two allocations';
  assert (r#>>'{canonical,totals,quarters}')::integer = 5, 'T6 2 + 3 quarters';
  assert r#>>'{canonical,totals,block_summary}' = 'T167 Cab Franc + T167 Sauvignon Blanc',
    'T6 block summary, got ' || (r#>>'{canonical,totals,block_summary}');
  alloc_sauv := alloc_derived_sauv;

  -- Labour still exists exactly once, on the parent and its primary mirror.
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = e_leg and deleted_at is null and labour_hours is not null;
  assert n = 1, 'T6 labour is mirrored on exactly one allocation, got ' || n;
  raise notice 'T6 passed: a second block is added without disturbing the legacy allocation';

  -- ---- T7. Repeated identical update is idempotent ------------------------
  for i in 1..3 loop
    r := public.update_pruning_activity(
      p_activity_id => e_leg,
      p_activity => jsonb_build_object('entry_date', '2026-07-15', 'labour_hours', 8.5),
      p_allocations => jsonb_build_array(
        jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 200,
          'segments', jsonb_build_array(
            jsonb_build_object('row', 40, 'segment', 1),
            jsonb_build_object('row', 40, 'segment', 2))),
        jsonb_build_object('paddock_id', b_sauv, 'estimated_vines', 300,
          'segments', jsonb_build_array(
            jsonb_build_object('row', 66, 'segment', 1),
            jsonb_build_object('row', 66, 'segment', 2),
            jsonb_build_object('row', 67, 'segment', 1)))),
      p_client_updated_at => t0 + interval '40 minutes' + (i * interval '1 minute'));
    assert r->>'error' is null, 'T7 replay ' || i || ' must succeed';
    assert (r#>>'{allocation_results,0,allocation_id}')::uuid = e_leg,
      'T7 replay ' || i || ' keeps the legacy allocation id';
    assert (r#>>'{allocation_results,1,allocation_id}')::uuid = alloc_sauv,
      'T7 replay ' || i || ' keeps the second allocation id';
    assert jsonb_array_length(r->'removed_allocations') = 0,
      'T7 replay ' || i || ' must not remove anything';
  end loop;

  select count(*) into n from public.pruning_entries where pruning_activity_id = e_leg;
  assert n = 2, 'T7 three replays produced no extra allocation rows, got ' || n;
  select count(*) into n from public.pruning_row_segments s
  join public.pruning_entries e on e.id = s.pruning_entry_id
  where e.pruning_activity_id = e_leg and e.deleted_at is null;
  assert n = 5, 'T7 quarters are stable across replays, got ' || n;
  select total_quarters into n from public.pruning_activities where id = e_leg;
  assert n = 5, 'T7 the roll-up is stable, got ' || n;
  raise notice 'T7 passed: repeated identical updates are fully idempotent';

  -- ---- T8. A supplied id owned by ANOTHER activity is rejected -------------
  r := public.record_pruning_activity(
    p_activity_id => a_other, p_vineyard_id => v_vy,
    p_activity => jsonb_build_object('entry_date', '2026-07-20',
      'worker_or_crew', 'Other crew', 'labour_hours', 3),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 100,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 90, 'segment', 1),
          jsonb_build_object('row', 90, 'segment', 2)))),
    p_client_updated_at => t0 + interval '50 minutes');
  alloc_other := (r#>>'{allocation_results,0,allocation_id}')::uuid;
  assert alloc_other is not null, 'T8 the second activity must have an allocation';

  res := public.resolve_pruning_allocation_id(e_leg, b_cab, alloc_other);
  assert res->>'rejected_reason' = 'belongs_to_another_activity',
    'T8 the resolver must reject a foreign activity id, got ' || coalesce(res->>'rejected_reason', 'null');
  assert (res->>'allocation_id')::uuid = e_leg, 'T8 resolution falls back to the real allocation';

  r := public.update_pruning_activity(
    p_activity_id => e_leg,
    p_activity => jsonb_build_object('entry_date', '2026-07-15', 'labour_hours', 8.5),
    p_allocations => jsonb_build_array(
      jsonb_build_object('id', alloc_other, 'paddock_id', b_cab, 'estimated_vines', 200,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 40, 'segment', 1),
          jsonb_build_object('row', 40, 'segment', 2))),
      jsonb_build_object('id', alloc_sauv, 'paddock_id', b_sauv, 'estimated_vines', 300,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 66, 'segment', 1),
          jsonb_build_object('row', 66, 'segment', 2),
          jsonb_build_object('row', 67, 'segment', 1)))),
    p_client_updated_at => t0 + interval '55 minutes');

  assert r->>'error' is null, 'T8 the save must not fail because of a bad client id';
  assert (r#>>'{allocation_results,0,allocation_id}')::uuid = e_leg,
    'T8 the foreign id must not be adopted';
  assert (r#>>'{allocation_results,0,rejected_allocation_id}')::uuid = alloc_other,
    'T8 the rejection must be reported back to the client';
  assert r#>>'{allocation_results,0,rejected_allocation_id_reason}' = 'belongs_to_another_activity',
    'T8 the rejection reason must be reported';

  -- The other activity is completely untouched.
  select pruning_activity_id into aid from public.pruning_entries where id = alloc_other;
  assert aid = a_other, 'T8 the other activity keeps its allocation';
  select count(*) into n from public.pruning_entries
  where id = alloc_other and deleted_at is null and paddock_id = b_cab;
  assert n = 1, 'T8 the other allocation stays live on its own block';
  select count(*) into n from public.pruning_row_segments where pruning_entry_id = alloc_other;
  assert n = 2, 'T8 the other activity keeps its two quarters, got ' || n;
  select total_quarters into n from public.pruning_activities where id = a_other;
  assert n = 2, 'T8 the other activity roll-up is unchanged, got ' || n;
  raise notice 'T8 passed: a foreign allocation id is rejected, reported and never reassigned';

  -- ---- T9. A supplied id from another BLOCK of the same activity -----------
  res := public.resolve_pruning_allocation_id(e_leg, b_cab, alloc_sauv);
  assert res->>'rejected_reason' = 'belongs_to_another_block',
    'T9 a cross-block id must be rejected, got ' || coalesce(res->>'rejected_reason', 'null');
  assert (res->>'allocation_id')::uuid = e_leg, 'T9 resolution stays on the right block';

  r := public.update_pruning_activity(
    p_activity_id => e_leg,
    p_activity => jsonb_build_object('entry_date', '2026-07-15', 'labour_hours', 8.5),
    p_allocations => jsonb_build_array(
      jsonb_build_object('id', alloc_sauv, 'paddock_id', b_cab, 'estimated_vines', 200,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 40, 'segment', 1),
          jsonb_build_object('row', 40, 'segment', 2))),
      jsonb_build_object('paddock_id', b_sauv, 'estimated_vines', 300,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 66, 'segment', 1),
          jsonb_build_object('row', 66, 'segment', 2),
          jsonb_build_object('row', 67, 'segment', 1)))),
    p_client_updated_at => t0 + interval '60 minutes');

  assert r->>'error' is null, 'T9 the save must still succeed';
  assert (r#>>'{allocation_results,0,allocation_id}')::uuid = e_leg, 'T9 Cab Franc keeps its row';
  assert r#>>'{allocation_results,0,rejected_allocation_id_reason}' = 'belongs_to_another_block',
    'T9 the cross-block rejection must be reported';
  assert (r#>>'{allocation_results,1,allocation_id}')::uuid = alloc_sauv, 'T9 Sauv Blanc keeps its row';
  select paddock_id into aid from public.pruning_entries where id = alloc_sauv;
  assert aid = b_sauv, 'T9 an allocation must never be moved to another block';
  select count(*) into n from public.pruning_row_segments where pruning_entry_id = alloc_sauv;
  assert n = 3, 'T9 the Sauvignon Blanc quarters are intact, got ' || n;
  raise notice 'T9 passed: a cross-block allocation id is rejected without moving quarters';

  -- ---- T10. No duplicate live (activity, block) allocation is possible -----
  res := public.resolve_pruning_allocation_id(e_leg, b_cab, ghost);
  assert res->>'rejected_reason' = 'block_already_has_allocation',
    'T10 a free id must be refused when the block already has one, got '
      || coalesce(res->>'rejected_reason', 'null');
  assert (res->>'allocation_id')::uuid = e_leg, 'T10 the existing allocation wins';

  r := public.update_pruning_activity(
    p_activity_id => e_leg,
    p_activity => jsonb_build_object('entry_date', '2026-07-15', 'labour_hours', 8.5),
    p_allocations => jsonb_build_array(
      jsonb_build_object('id', ghost, 'paddock_id', b_cab, 'estimated_vines', 200,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 40, 'segment', 1),
          jsonb_build_object('row', 40, 'segment', 2))),
      jsonb_build_object('id', alloc_sauv, 'paddock_id', b_sauv, 'estimated_vines', 300,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 66, 'segment', 1),
          jsonb_build_object('row', 66, 'segment', 2),
          jsonb_build_object('row', 67, 'segment', 1)))),
    p_client_updated_at => t0 + interval '70 minutes');
  assert (r#>>'{allocation_results,0,allocation_id}')::uuid = e_leg,
    'T10 a stray client id must not fork the allocation';
  select count(*) into n from public.pruning_entries where id = ghost;
  assert n = 0, 'T10 the stray id must not exist as a row';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = e_leg and paddock_id = b_cab and deleted_at is null;
  assert n = 1, 'T10 one live allocation per (activity, block), got ' || n;

  -- …and the database itself refuses a hand-written duplicate.
  ok := false;
  begin
    insert into public.pruning_entries (
      id, vineyard_id, pruning_season_id, paddock_id, entry_date, worker_or_crew,
      pruning_method, notes, vintage_year, created_by, pruning_activity_id, allocation_index
    ) values (
      gen_random_uuid(), v_vy,
      public.resolve_pruning_season(v_vy, b_cab, date '2026-07-15', null, now()),
      b_cab, date '2026-07-15', 'Duplicate attempt', 'spur', '', 2027, u_mgr, e_leg, 9
    );
  exception when others then ok := true;
  end;
  assert ok, 'T10 the unique index must refuse a second live (activity, block) allocation';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = e_leg and paddock_id = b_cab and deleted_at is null;
  assert n = 1, 'T10 still one live allocation after the refused insert, got ' || n;
  raise notice 'T10 passed: duplicate live allocations are impossible via RPC and via SQL';

  -- ---- T11. Remove then re-add a block without an id -----------------------
  r := public.update_pruning_activity(
    p_activity_id => e_leg,
    p_activity => jsonb_build_object('entry_date', '2026-07-15', 'labour_hours', 8.5),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 200,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 40, 'segment', 1),
          jsonb_build_object('row', 40, 'segment', 2)))),
    p_client_updated_at => t0 + interval '80 minutes');
  assert jsonb_array_length(r->'removed_allocations') = 1, 'T11 Sauvignon Blanc is removed';
  assert (r#>>'{canonical,totals,allocation_count}')::integer = 1, 'T11 one allocation left';
  select deleted_at is not null into ok from public.pruning_entries where id = alloc_sauv;
  assert ok, 'T11 the removed allocation is soft-deleted';
  select count(*) into n from public.pruning_row_segments where pruning_entry_id = alloc_sauv;
  assert n = 0, 'T11 the removed block released its quarters, got ' || n;
  select labour_hours into num from public.pruning_activities where id = e_leg;
  assert num = 8.5, 'T11 removing a block must not lose labour, got ' || coalesce(num::text, 'null');

  r := public.update_pruning_activity(
    p_activity_id => e_leg,
    p_activity => jsonb_build_object('entry_date', '2026-07-15', 'labour_hours', 8.5),
    p_allocations => jsonb_build_array(
      jsonb_build_object('paddock_id', b_cab, 'estimated_vines', 200,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 40, 'segment', 1),
          jsonb_build_object('row', 40, 'segment', 2))),
      jsonb_build_object('paddock_id', b_sauv, 'estimated_vines', 300,
        'segments', jsonb_build_array(
          jsonb_build_object('row', 66, 'segment', 1),
          jsonb_build_object('row', 66, 'segment', 2)))),
    p_client_updated_at => t0 + interval '90 minutes');
  assert (r#>>'{allocation_results,1,allocation_id}')::uuid = alloc_sauv,
    'T11 re-adding the block must revive its OWN allocation row';
  select count(*) into n from public.pruning_entries
  where pruning_activity_id = e_leg and paddock_id = b_sauv;
  assert n = 1, 'T11 revival must not leave an orphan duplicate, got ' || n;
  select count(*) into n from public.pruning_row_segments where pruning_entry_id = alloc_sauv;
  assert n = 2, 'T11 the revived block re-claims its quarters, got ' || n;
  raise notice 'T11 passed: remove then re-add revives the same allocation row';

  -- ---- Cross-cutting invariants ------------------------------------------
  select count(*) into n from (
    select pruning_activity_id, paddock_id from public.pruning_entries
    where vineyard_id = v_vy and pruning_activity_id is not null and deleted_at is null
    group by 1, 2 having count(*) > 1
  ) t;
  assert n = 0, 'INV no (activity, block) pair may hold two live allocations, offenders ' || n;

  select count(*) into n from (
    select pruning_activity_id from public.pruning_entries
    where vineyard_id = v_vy and deleted_at is null and labour_hours is not null
    group by 1 having count(*) > 1
  ) t;
  assert n = 0, 'INV labour may never be mirrored on two live allocations, offenders ' || n;

  select count(*) into n
  from public.pruning_entries e
  join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.vineyard_id = v_vy and extract(year from e.entry_date)::integer <> s.season_year;
  assert n = 0, 'INV season_year must equal year(entry_date) everywhere, offenders ' || n;

  select count(*) into n from public.pruning_entries
  where vineyard_id = v_vy and pruning_activity_id is null;
  assert n = 0, 'INV every allocation keeps a parent activity, offenders ' || n;

  c := public.get_pruning_activity(e_leg);
  assert (c#>>'{totals,allocation_count}')::integer = 2, 'INV the activity reads back with two blocks';
  assert (c#>>'{activity,vintage_year}')::integer is not null, 'INV vintage still resolved';
  assert (c#>>'{allocations,0,id}')::uuid = e_leg, 'INV the legacy allocation id is stable for ever';

  raise notice 'SQL 167 allocation id resolution tests: ALL PASSED';
end$$;

rollback;

-- T12. Post-rollback proof: nothing survived.
select
  (select count(*) from auth.users where email = 't167-mgr@test.local')      as leftover_users,
  (select count(*) from public.vineyards where name like 'T167 %')           as leftover_vineyards,
  (select count(*) from public.paddocks where name like 'T167 %')            as leftover_paddocks,
  (select count(*) from public.pruning_activities
    where worker_or_crew in ('Legacy build','Other crew','Duplicate attempt')) as leftover_activities,
  (select count(*) from public.pruning_entries
    where worker_or_crew in ('Legacy build','Other crew','Duplicate attempt')) as leftover_allocations;

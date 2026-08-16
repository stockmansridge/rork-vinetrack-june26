-- =====================================================================
-- 196_resistance_plans_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/196_resistance_plans.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects: table, both validators, all four triggers, the RPCs, the
--       indexes and every RLS policy exist
--   T2  INSERT round-trip as a manager; positions and block_ids survive
--   T3  ORDERED POSITIONS: array order is preserved exactly as written,
--       including after a reorder update — order is the domain fact
--   T4  STABLE POSITION IDS: a reorder changes sequence, not identity
--   T5  positions must be a JSON ARRAY (object / scalar / string rejected)
--   T6  Malformed positions rejected: element not an object, missing id,
--       blank id, DUPLICATE position id, products not an array, product
--       missing id, group_codes not an array, non-string group code,
--       unknown source
--   T7  An EMPTY position (no chemistry yet) is ALLOWED — a half-built
--       plan must be savable
--   T8  block_ids: null ok, empty ok, NULL ELEMENT rejected, DUPLICATE
--       rejected
--   T9  CROSS-VINEYARD block rejected at write time
--   T10 A block id matching NO paddock is allowed, and SURVIVES the block
--       being deleted — the plan is not erased to satisfy an FK
--   T11 RULESET METADATA required once positions exist; exempt while empty
--   T12 Jurisdiction constrained; disease NOT pinned to today's two
--       (a future disease saves without a migration)
--   T13 MULTIPLE PLANS per vineyard, including SAME season + disease with
--       different ids (a grower may legitimately keep two)
--   T14 VINEYARD ISOLATION under RLS: a member of vineyard B cannot read,
--       update or soft-delete vineyard A's plan
--   T15 TEAM VISIBILITY: a second member of the SAME vineyard reads and
--       updates the plan the manager created (not creator-scoped)
--   T16 created_by is WRITE-ONCE; updated_by follows the editor
--   T17 STALE-WRITE GUARD: an older client_updated_at replay is skipped,
--       equal is applied, newer is applied
--   T18 SOFT DELETE via RPC; the row is tombstoned, not removed
--   T19 CLIENT HARD DELETE IS DENIED by policy
--   T20 RESTORE clears the tombstone
--   T21 NO CASCADE: soft-deleting AND hard-deleting a plan leaves spray
--       records, saved chemicals and spray targets untouched
--   T22 No FK exists from resistance_plans into operational data
--   T23 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 196 resistance plans tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 196 is applied.
do $$
begin
  if to_regclass('public.resistance_plans') is null
     or to_regprocedure('public.resistance_plan_positions_are_valid(jsonb)') is null
     or to_regprocedure('public.resistance_plan_block_ids_are_valid(uuid[])') is null
     or to_regprocedure('public.soft_delete_resistance_plan(uuid)') is null
     or to_regprocedure('public.restore_resistance_plan(uuid)') is null then
    raise exception 'SQL 196 not applied — run sql/196_resistance_plans.sql first.';
  end if;
end$$;

do $$
declare
  v_vy      uuid := gen_random_uuid();
  v_vy2     uuid := gen_random_uuid();
  b_a       uuid := gen_random_uuid();
  b_b       uuid := gen_random_uuid();
  b_gone    uuid := gen_random_uuid();
  u_mgr     uuid;
  u_op      uuid;
  u_out     uuid;
  p1        uuid := gen_random_uuid();
  p2        uuid := gen_random_uuid();
  p3        uuid := gen_random_uuid();
  sr1       uuid := gen_random_uuid();
  ch1       uuid := gen_random_uuid();
  r         record;
  n         integer;
  v_failed  boolean;
  v_ids     text[];
  v_pos     jsonb;
  v_t1      timestamptz := now() - interval '2 hours';
  v_t2      timestamptz := now() - interval '1 hour';
  v_base    timestamptz;

  -- A realistic plan document: 3 -> 7 -> 11, one product per position, the
  -- middle one fulfilled by a real Chemical Store product.
  v_positions jsonb := jsonb_build_array(
    jsonb_build_object(
      'id', 'pos-1',
      'products', jsonb_build_array(jsonb_build_object(
        'id', 'prod-1', 'group_codes', jsonb_build_array('3'), 'source', 'group')),
      'note', 'early season'
    ),
    jsonb_build_object(
      'id', 'pos-2',
      'products', jsonb_build_array(jsonb_build_object(
        'id', 'prod-2', 'group_codes', jsonb_build_array('7'),
        'source', 'saved_chemical', 'saved_chemical_id', 'chem-abc',
        'product_name', 'Test Fungicide', 'chemical_availability', 'available_verified'))
    ),
    jsonb_build_object(
      'id', 'pos-3',
      'products', jsonb_build_array(jsonb_build_object(
        'id', 'prod-3', 'group_codes', jsonb_build_array('11'), 'source', 'group')),
      'target_date_epoch_ms', 1790000000000::bigint,
      'growth_stage', 'flowering'
    )
  );
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
         'authenticated', 'authenticated', e, 'x', now(), now(), now()
  from unnest(array['t196-mgr@test.local','t196-op@test.local','t196-out@test.local']) e;

  select id into u_mgr from auth.users where email = 't196-mgr@test.local';
  select id into u_op  from auth.users where email = 't196-op@test.local';
  select id into u_out from auth.users where email = 't196-out@test.local';

  insert into public.profiles (id, email)
  select u, 't196-' || u::text || '@test.local' from unnest(array[u_mgr, u_op, u_out]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_vy,  'T196 Plan Vineyard'),
    (v_vy2, 'T196 Other Vineyard');

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vy,  u_mgr, 'manager'),
    (v_vy,  u_op,  'operator'),
    (v_vy2, u_out, 'manager');

  insert into public.paddocks (id, vineyard_id, name) values
    (b_a,    v_vy,  'Block A'),
    (b_b,    v_vy,  'Block B'),
    (b_gone, v_vy2, 'Foreign Block');

  -- =====================================================================
  -- T1. Objects
  -- =====================================================================
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'resistance_plans'
    and column_name in ('id','vineyard_id','season_id','season_start_year','disease',
                        'jurisdiction','crop','block_ids','positions','notes',
                        'ruleset_id','ruleset_version','created_by','updated_by',
                        'created_at','updated_at','deleted_at','client_updated_at',
                        'sync_version');
  if n <> 19 then raise exception 'T1: expected 19 canonical columns, found %', n; end if;

  foreach v_pos in array array[
    to_jsonb('resistance_plans_validate_block_vineyard'::text),
    to_jsonb('resistance_plans_attribution_guard'::text),
    to_jsonb('resistance_plans_stale_write_guard'::text),
    to_jsonb('resistance_plans_set_updated_at'::text)
  ] loop
    if not exists (
      select 1 from pg_trigger
      where tgrelid = 'public.resistance_plans'::regclass
        and tgname = (v_pos #>> '{}')) then
      raise exception 'T1: trigger % missing', v_pos #>> '{}';
    end if;
  end loop;

  select count(*) into n from pg_indexes
  where schemaname = 'public'
    and indexname in ('idx_resistance_plans_vineyard',
                      'idx_resistance_plans_vineyard_live',
                      'idx_resistance_plans_season_disease',
                      'idx_resistance_plans_deleted_at',
                      'idx_resistance_plans_block_ids');
  if n <> 5 then raise exception 'T1: expected 5 indexes, found %', n; end if;

  select count(*) into n from pg_policies
  where schemaname = 'public' and tablename = 'resistance_plans'
    and policyname in ('resistance_plans_select_members',
                       'resistance_plans_insert_members',
                       'resistance_plans_update_members',
                       'resistance_plans_no_client_hard_delete');
  if n <> 4 then raise exception 'T1: expected 4 RLS policies, found %', n; end if;

  if not exists (
    select 1 from pg_class where relname = 'resistance_plans' and relrowsecurity) then
    raise exception 'T1: RLS not enabled';
  end if;
  raise notice 'T1 passed';

  -- =====================================================================
  -- T2. INSERT round-trip as the manager
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  insert into public.resistance_plans
    (id, vineyard_id, season_id, season_start_year, disease, jurisdiction, crop,
     block_ids, positions, notes, ruleset_id, ruleset_version, client_updated_at)
  values
    (p1, v_vy, '2026/27', 2026, 'powdery_mildew', 'AU', 'grape',
     array[b_a, b_b], v_positions, 'Season plan',
     'AU_GRAPE_POWDERY_2026_07_22', '2026.07.22', v_t1);

  select * into r from public.resistance_plans where id = p1;
  if r.season_id <> '2026/27' then raise exception 'T2: season_id lost'; end if;
  if r.block_ids <> array[b_a, b_b] then raise exception 'T2: block_ids lost'; end if;
  if jsonb_array_length(r.positions) <> 3 then raise exception 'T2: positions lost'; end if;
  if r.ruleset_version <> '2026.07.22' then raise exception 'T2: ruleset_version lost'; end if;
  if r.deleted_at is not null then raise exception 'T2: new plan must not be tombstoned'; end if;
  raise notice 'T2 passed';

  -- =====================================================================
  -- T3 / T4. Ordered positions and stable position ids
  -- =====================================================================
  select array_agg(elem->>'id' order by ord)
    into v_ids
  from jsonb_array_elements((select positions from public.resistance_plans where id = p1))
       with ordinality as t(elem, ord);
  if v_ids <> array['pos-1','pos-2','pos-3'] then
    raise exception 'T3: stored order wrong (%)', v_ids;
  end if;

  -- Reorder: move pos-3 to the front, as the client does on "Move Up".
  update public.resistance_plans
     set positions = jsonb_build_array(
           v_positions->2, v_positions->0, v_positions->1),
         client_updated_at = v_t2
   where id = p1;

  select array_agg(elem->>'id' order by ord)
    into v_ids
  from jsonb_array_elements((select positions from public.resistance_plans where id = p1))
       with ordinality as t(elem, ord);
  if v_ids <> array['pos-3','pos-1','pos-2'] then
    raise exception 'T3: reorder not preserved (%)', v_ids;
  end if;

  -- Identity survived the reorder: same three ids, no regeneration.
  if not (v_ids @> array['pos-1','pos-2','pos-3']
          and array_length(v_ids, 1) = 3) then
    raise exception 'T4: position ids were not stable across reorder (%)', v_ids;
  end if;
  -- The moved position kept its payload, not just its id.
  select positions->0 into v_pos from public.resistance_plans where id = p1;
  if v_pos->>'growth_stage' <> 'flowering' then
    raise exception 'T4: moved position lost its content';
  end if;

  -- Restore canonical order for later tests.
  update public.resistance_plans set positions = v_positions, client_updated_at = v_t2
   where id = p1;
  raise notice 'T3 passed';
  raise notice 'T4 passed';

  -- =====================================================================
  -- T5. positions must be a JSON array
  -- =====================================================================
  foreach v_pos in array array[
    '{"id":"pos-1"}'::jsonb,
    '42'::jsonb,
    '"not-an-array"'::jsonb,
    'true'::jsonb
  ] loop
    v_failed := false;
    begin
      insert into public.resistance_plans
        (vineyard_id, season_id, disease, positions, ruleset_id, ruleset_version)
      values (v_vy, '2026/27', 'powdery_mildew', v_pos, 'R', '1');
    exception when check_violation then v_failed := true;
    end;
    if not v_failed then
      raise exception 'T5: non-array positions accepted (%)', v_pos;
    end if;
  end loop;
  raise notice 'T5 passed';

  -- =====================================================================
  -- T6. Malformed positions rejected
  -- =====================================================================
  foreach v_pos in array array[
    -- element not an object
    '["pos-1"]'::jsonb,
    -- missing id
    '[{"products":[]}]'::jsonb,
    -- blank id
    '[{"id":"   "}]'::jsonb,
    -- DUPLICATE position id
    '[{"id":"pos-1"},{"id":"pos-1"}]'::jsonb,
    -- products not an array
    '[{"id":"pos-1","products":{"id":"p"}}]'::jsonb,
    -- product element not an object
    '[{"id":"pos-1","products":["p"]}]'::jsonb,
    -- product missing id
    '[{"id":"pos-1","products":[{"group_codes":["3"]}]}]'::jsonb,
    -- group_codes not an array
    '[{"id":"pos-1","products":[{"id":"p","group_codes":"3"}]}]'::jsonb,
    -- non-string group code
    '[{"id":"pos-1","products":[{"id":"p","group_codes":[3]}]}]'::jsonb,
    -- unknown source
    '[{"id":"pos-1","products":[{"id":"p","source":"telepathy"}]}]'::jsonb
  ] loop
    v_failed := false;
    begin
      insert into public.resistance_plans
        (vineyard_id, season_id, disease, positions, ruleset_id, ruleset_version)
      values (v_vy, '2026/27', 'powdery_mildew', v_pos, 'R', '1');
    exception when check_violation then v_failed := true;
    end;
    if not v_failed then
      raise exception 'T6: malformed positions accepted (%)', v_pos;
    end if;
  end loop;
  raise notice 'T6 passed';

  -- =====================================================================
  -- T7. An empty position is allowed (work in progress)
  -- =====================================================================
  insert into public.resistance_plans
    (id, vineyard_id, season_id, disease, positions, ruleset_id, ruleset_version)
  values (p2, v_vy, '2026/27', 'downy_mildew',
          '[{"id":"pos-blank","products":[]}]'::jsonb, 'R', '1');
  if not exists (select 1 from public.resistance_plans where id = p2) then
    raise exception 'T7: half-built plan was refused';
  end if;
  -- also: a position with no products key at all
  update public.resistance_plans set positions = '[{"id":"pos-blank"}]'::jsonb where id = p2;
  raise notice 'T7 passed';

  -- =====================================================================
  -- T8. block_ids null / empty / null element / duplicate
  -- =====================================================================
  update public.resistance_plans set block_ids = null where id = p2;
  update public.resistance_plans set block_ids = '{}'::uuid[] where id = p2;

  v_failed := false;
  begin
    update public.resistance_plans set block_ids = array[b_a, null]::uuid[] where id = p2;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T8: NULL block element accepted'; end if;

  v_failed := false;
  begin
    update public.resistance_plans set block_ids = array[b_a, b_a] where id = p2;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T8: duplicate block accepted'; end if;
  raise notice 'T8 passed';

  -- =====================================================================
  -- T9. Cross-vineyard block rejected at write time
  -- =====================================================================
  v_failed := false;
  begin
    update public.resistance_plans set block_ids = array[b_a, b_gone] where id = p2;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T9: foreign vineyard block accepted'; end if;
  raise notice 'T9 passed';

  -- =====================================================================
  -- T10. Unknown block id allowed, and survives block deletion
  -- =====================================================================
  perform set_config('role', 'postgres', true);
  declare
    b_temp uuid := gen_random_uuid();
  begin
    insert into public.paddocks (id, vineyard_id, name) values (b_temp, v_vy, 'Doomed Block');
    perform set_config('role', 'authenticated', true);

    update public.resistance_plans set block_ids = array[b_a, b_temp] where id = p1;

    perform set_config('role', 'postgres', true);
    delete from public.paddocks where id = b_temp;
    perform set_config('role', 'authenticated', true);

    select * into r from public.resistance_plans where id = p1;
    if r.block_ids is null or not (r.block_ids @> array[b_temp]) then
      raise exception 'T10: plan lost the block id when the block was deleted';
    end if;
    if array_length(r.block_ids, 1) <> 2 then
      raise exception 'T10: plan block set was mutated by block deletion';
    end if;
  end;

  -- A totally unknown id (never a paddock) is also fine.
  update public.resistance_plans set block_ids = array[b_a, gen_random_uuid()] where id = p1;
  update public.resistance_plans set block_ids = array[b_a, b_b] where id = p1;
  raise notice 'T10 passed';

  -- =====================================================================
  -- T11. Ruleset metadata mandatory once planned, exempt while empty
  -- =====================================================================
  insert into public.resistance_plans (id, vineyard_id, season_id, disease, positions)
  values (p3, v_vy, '2027/28', 'powdery_mildew', '[]'::jsonb);
  if not exists (select 1 from public.resistance_plans where id = p3) then
    raise exception 'T11: empty plan without ruleset was refused';
  end if;

  v_failed := false;
  begin
    update public.resistance_plans
       set positions = '[{"id":"pos-x","products":[{"id":"p","group_codes":["3"],"source":"group"}]}]'::jsonb
     where id = p3;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T11: planned chemistry accepted with no ruleset stamped';
  end if;

  -- Blank strings are not a stamp either.
  v_failed := false;
  begin
    update public.resistance_plans
       set positions = '[{"id":"pos-x"}]'::jsonb, ruleset_id = '  ', ruleset_version = '  '
     where id = p3;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T11: blank ruleset stamp accepted'; end if;

  update public.resistance_plans
     set positions = '[{"id":"pos-x"}]'::jsonb,
         ruleset_id = 'AU_GRAPE_POWDERY_2026_07_22', ruleset_version = '2026.07.22'
   where id = p3;
  raise notice 'T11 passed';

  -- =====================================================================
  -- T12. Jurisdiction constrained; disease deliberately NOT pinned
  -- =====================================================================
  v_failed := false;
  begin
    update public.resistance_plans set jurisdiction = 'Narnia' where id = p3;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T12: unknown jurisdiction accepted'; end if;

  -- A future disease must save WITHOUT a migration.
  update public.resistance_plans set disease = 'botrytis' where id = p3;
  if (select disease from public.resistance_plans where id = p3) <> 'botrytis' then
    raise exception 'T12: future disease was rejected — schema is gating clients';
  end if;
  update public.resistance_plans set disease = 'powdery_mildew' where id = p3;

  -- Blank / upper-case disease still rejected.
  foreach v_pos in array array[to_jsonb(''::text), to_jsonb('Powdery_Mildew'::text)] loop
    v_failed := false;
    begin
      update public.resistance_plans set disease = (v_pos #>> '{}') where id = p3;
    exception when check_violation then v_failed := true;
    end;
    if not v_failed then raise exception 'T12: bad disease value accepted (%)', v_pos; end if;
  end loop;
  raise notice 'T12 passed';

  -- =====================================================================
  -- T13. Multiple plans, including same season + disease
  -- =====================================================================
  select count(*) into n from public.resistance_plans where vineyard_id = v_vy;
  if n < 3 then raise exception 'T13: expected at least 3 plans, found %', n; end if;

  -- Same vineyard, same season, same disease, different id — legitimate.
  insert into public.resistance_plans
    (vineyard_id, season_id, disease, positions, ruleset_id, ruleset_version)
  values (v_vy, '2026/27', 'powdery_mildew',
          '[{"id":"alt-1"}]'::jsonb, 'AU_GRAPE_POWDERY_2026_07_22', '2026.07.22');

  select count(*) into n from public.resistance_plans
  where vineyard_id = v_vy and season_id = '2026/27' and disease = 'powdery_mildew';
  if n < 2 then
    raise exception 'T13: a second plan for the same season+disease was blocked';
  end if;
  raise notice 'T13 passed';

  -- =====================================================================
  -- T14. Vineyard isolation under RLS
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_out::text, 'role', 'authenticated')::text, true);

  select count(*) into n from public.resistance_plans where id = p1;
  if n <> 0 then raise exception 'T14: outsider can READ another vineyard''s plan'; end if;

  update public.resistance_plans set notes = 'hijacked' where id = p1;
  if found then raise exception 'T14: outsider UPDATE reported success'; end if;

  v_failed := false;
  begin
    perform public.soft_delete_resistance_plan(p1);
  exception when others then v_failed := true;
  end;
  if not v_failed then
    raise exception 'T14: outsider soft-deleted another vineyard''s plan';
  end if;

  -- Insert into a vineyard they are not a member of is refused.
  v_failed := false;
  begin
    insert into public.resistance_plans (vineyard_id, season_id, disease)
    values (v_vy, '2026/27', 'powdery_mildew');
  exception when insufficient_privilege then v_failed := true;
  end;
  if not v_failed then raise exception 'T14: outsider INSERT into foreign vineyard allowed'; end if;
  raise notice 'T14 passed';

  -- =====================================================================
  -- T15. Team visibility — a colleague opens the manager's plan
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);

  select * into r from public.resistance_plans where id = p1;
  if r.id is null then
    raise exception 'T15: a vineyard member could not read a colleague''s plan';
  end if;
  if jsonb_array_length(r.positions) <> 3 then
    raise exception 'T15: colleague sees a different document';
  end if;

  update public.resistance_plans
     set notes = 'operator adjusted', client_updated_at = now()
   where id = p1;
  if (select notes from public.resistance_plans where id = p1) <> 'operator adjusted' then
    raise exception 'T15: colleague could not update the shared plan';
  end if;
  raise notice 'T15 passed';

  -- =====================================================================
  -- T16. created_by write-once, updated_by follows the editor
  -- =====================================================================
  select * into r from public.resistance_plans where id = p1;
  if r.created_by <> u_mgr then
    raise exception 'T16: created_by is % not the original author %', r.created_by, u_mgr;
  end if;
  if r.updated_by <> u_op then
    raise exception 'T16: updated_by did not follow the editor (%)', r.updated_by;
  end if;

  -- Even an explicit attempt to rewrite authorship is ignored.
  update public.resistance_plans set created_by = u_op where id = p1;
  if (select created_by from public.resistance_plans where id = p1) <> u_mgr then
    raise exception 'T16: created_by was overwritten';
  end if;
  raise notice 'T16 passed';

  -- =====================================================================
  -- T17. Stale-write guard (the conflict strategy)
  --
  -- Timestamps are derived from what is ACTUALLY STORED, not from the fixture
  -- constants. T15 writes client_updated_at = now(), and in Postgres now() is
  -- TRANSACTION-START time, so it is newer than both v_t1 and v_t2. A
  -- hard-coded v_t2 "newer edit" here was therefore itself stale and was
  -- correctly skipped by the guard — which then failed the NEXT assertion and
  -- blamed the replay, making a working guard look broken. Anchoring on the
  -- stored value keeps this case independent of what earlier cases left behind.
  -- =====================================================================
  select client_updated_at into v_base
  from public.resistance_plans where id = p1;
  if v_base is null then
    raise exception 'T17: precondition — client_updated_at must be set to test staleness';
  end if;

  update public.resistance_plans
     set notes = 'newer edit', client_updated_at = v_base + interval '1 minute'
   where id = p1;
  -- Asserted separately so a skipped SET-UP write can never be misreported as
  -- a guard failure below.
  if (select notes from public.resistance_plans where id = p1) <> 'newer edit' then
    raise exception 'T17: precondition — the newer edit was itself skipped';
  end if;

  -- Older replay from a device that was offline: SKIPPED, silently.
  update public.resistance_plans
     set notes = 'stale offline replay', client_updated_at = v_base - interval '2 hours'
   where id = p1;
  if (select notes from public.resistance_plans where id = p1) <> 'newer edit' then
    raise exception 'T17: a stale offline replay overwrote a newer edit';
  end if;

  -- Equal timestamp (idempotent re-send) is applied.
  update public.resistance_plans
     set notes = 'same-stamp resend', client_updated_at = v_base + interval '1 minute'
   where id = p1;
  if (select notes from public.resistance_plans where id = p1) <> 'same-stamp resend' then
    raise exception 'T17: an idempotent re-send was rejected';
  end if;

  -- Newer wins.
  update public.resistance_plans
     set notes = 'newest', client_updated_at = v_base + interval '2 minutes'
   where id = p1;
  if (select notes from public.resistance_plans where id = p1) <> 'newest' then
    raise exception 'T17: a newer write was skipped';
  end if;
  raise notice 'T17 passed';

  -- =====================================================================
  -- T18. Soft delete via RPC
  -- =====================================================================
  perform public.soft_delete_resistance_plan(p2);
  select * into r from public.resistance_plans where id = p2;
  if r.id is null then raise exception 'T18: soft delete removed the row'; end if;
  if r.deleted_at is null then raise exception 'T18: tombstone not set'; end if;

  select count(*) into n from public.resistance_plans
  where vineyard_id = v_vy and deleted_at is null and id = p2;
  if n <> 0 then raise exception 'T18: deleted plan still appears in the live list'; end if;
  raise notice 'T18 passed';

  -- =====================================================================
  -- T19. Client hard delete denied
  -- =====================================================================
  delete from public.resistance_plans where id = p3;
  if not exists (select 1 from public.resistance_plans where id = p3) then
    raise exception 'T19: client hard delete succeeded — deletes cannot propagate';
  end if;
  raise notice 'T19 passed';

  -- =====================================================================
  -- T20. Restore
  -- =====================================================================
  perform public.restore_resistance_plan(p2);
  if (select deleted_at from public.resistance_plans where id = p2) is not null then
    raise exception 'T20: restore did not clear the tombstone';
  end if;
  raise notice 'T20 passed';

  -- =====================================================================
  -- T21 / T22. NO CASCADE into operational data
  -- =====================================================================
  perform set_config('role', 'postgres', true);

  insert into public.saved_chemicals (id, vineyard_id, name)
  values (ch1, v_vy, 'T196 Chemical');

  -- Chemical lines live in the `tanks` JSONB (sql/007) — there is no `chemicals`
  -- column on spray_records. Only the columns this test actually needs are set:
  -- the point is that the ROW survives, not what it contains.
  insert into public.spray_records (id, vineyard_id, date, tanks)
  values (sr1, v_vy, now(), '[]'::jsonb);

  -- Soft delete, then a genuine hard delete as a privileged role: neither may
  -- touch history. A plan is advisory; history is what happened.
  update public.resistance_plans set deleted_at = now() where id = p1;
  delete from public.resistance_plans where id = p1;

  if not exists (select 1 from public.spray_records where id = sr1) then
    raise exception 'T21: deleting a plan destroyed a spray record';
  end if;
  if not exists (select 1 from public.saved_chemicals where id = ch1) then
    raise exception 'T21: deleting a plan destroyed a saved chemical';
  end if;
  if not exists (select 1 from public.paddocks where id = b_a) then
    raise exception 'T21: deleting a plan destroyed a block';
  end if;

  -- Structural proof, not just a behavioural one: the only outbound FKs are to
  -- vineyards and auth.users. Nothing points into operational data.
  select count(*) into n
  from pg_constraint c
  where c.conrelid = 'public.resistance_plans'::regclass
    and c.contype = 'f'
    and c.confrelid not in ('public.vineyards'::regclass, 'auth.users'::regclass);
  if n <> 0 then
    raise exception 'T22: resistance_plans has % FK(s) into other data', n;
  end if;

  -- And nothing anywhere references resistance_plans, so no other table can be
  -- cascaded into by a plan delete.
  select count(*) into n
  from pg_constraint c
  where c.confrelid = 'public.resistance_plans'::regclass and c.contype = 'f';
  if n <> 0 then
    raise exception 'T22: % table(s) hold an FK to resistance_plans', n;
  end if;
  raise notice 'T21 passed';
  raise notice 'T22 passed';

  perform set_config('role', 'postgres', true);
  raise notice 'SQL 196 resistance plans tests: ALL PASSED';
end$$;

-- T23. Discard everything.
rollback;

-- =====================================================================
-- 197_fix_spray_block_vineyard_guard_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/197_fix_spray_block_vineyard_guard.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- ---------------------------------------------------------------------------
-- WHY THIS SUITE SWITCHES ROLE, AND WHY THAT IS THE WHOLE POINT
-- ---------------------------------------------------------------------------
-- The sql/195 suite tested this exact guard and PASSED against a live
-- vulnerability. It ran as the table owner, and a table owner BYPASSES RLS, so
-- the guard's internal `select ... from public.paddocks` saw every paddock and
-- correctly rejected the foreign block.
--
-- Real callers are `authenticated` with RLS ACTIVE. For them the same lookup was
-- filtered by the paddocks SELECT policy, returned no row, and the foreign block
-- was accepted. The bug lived entirely in the gap between the role the tests
-- used and the role production uses.
--
-- RULE: a validation function that reads ANOTHER RLS-protected table can only be
-- tested under `set role authenticated` with a user who genuinely lacks access
-- to the row being validated against. Owner-role tests prove nothing about it.
--
-- Test map
--   T1  Objects: guard is SECURITY DEFINER, keeps a pinned search_path, and the
--       pre-existing sql/195 trigger still resolves to it
--   T2  SAME-VINEYARD block, authenticated member of A -> ACCEPTED
--   T3  CROSS-VINEYARD VISIBLE block (caller is a member of BOTH) -> REJECTED
--       (this is the only case the sql/195 suite could ever have caught)
--   T4  CROSS-VINEYARD HIDDEN block (caller is a member of A ONLY) -> REJECTED
--       *** THE REGRESSION CASE sql/195 MISSED ***
--       Proves first that RLS genuinely hides the foreign paddock from this
--       caller, then that the write is rejected anyway
--   T5  NO INFORMATION LEAK: the rejection names neither the foreign vineyard's
--       id, nor its name, nor the foreign block's name
--   T6  UNKNOWN/DELETED block id (matches no paddock row) -> ACCEPTED, identity
--       retained. The security fix must not become a foreign-key requirement
--   T7  MIXED valid A block + hidden foreign block -> WHOLE write rejected,
--       nothing partially persisted
--   T8  HISTORICAL attribution survives: a record keeps its block id after that
--       paddock is deleted, stays readable, and stays updatable
--   T9  Same-vineyard write still works for a non-manager working role
--       (the fix must not narrow who may write)
--   T10 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 197 spray block vineyard guard tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 197 is applied, so a PASS can never be
-- reported against the unrepaired function.
do $$
declare
  v_secdef boolean;
begin
  if to_regprocedure('public.spray_records_validate_block_vineyard()') is null then
    raise exception 'SQL 195 not applied — run sql/195_spray_block_attribution.sql first.';
  end if;

  select p.prosecdef into v_secdef
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'spray_records_validate_block_vineyard';

  if not coalesce(v_secdef, false) then
    raise exception
      'SQL 197 not applied — run sql/197_fix_spray_block_vineyard_guard.sql first (guard is still caller-rights).';
  end if;
end$$;

do $$
declare
  v_a        uuid := gen_random_uuid();   -- vineyard A (the caller's vineyard)
  v_b        uuid := gen_random_uuid();   -- vineyard B (foreign)
  b_a        uuid := gen_random_uuid();   -- block in A
  b_a2       uuid := gen_random_uuid();   -- second block in A
  b_b        uuid := gen_random_uuid();   -- block in B  (hidden from u_a)
  b_ghost    uuid := gen_random_uuid();   -- id with no paddock row, ever
  u_a        uuid;                        -- manager of A only
  u_both     uuid;                        -- manager of A and B
  u_op       uuid;                        -- operator of A only
  r_same     uuid := gen_random_uuid();
  r_ghost    uuid := gen_random_uuid();
  r_mixed    uuid := gen_random_uuid();
  r_hist     uuid := gen_random_uuid();
  r_op       uuid := gen_random_uuid();
  v_b_name   text := 'T197 Foreign Vineyard B';
  v_bb_name  text := 'T197 Foreign Block B';
  v_ids      uuid[];
  v_cnt      integer;
  v_state    text;
  v_msg      text;
  v_trigfn   oid;
  v_config   text[];
  v_secdef   boolean;
begin
  -- ---- fixtures (as owner) ------------------------------------------------
  perform set_config('role', 'postgres', true);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
         'authenticated', 'authenticated', e, 'x', now(), now(), now()
  from unnest(array['t197-a@test.local','t197-both@test.local','t197-op@test.local']) e;

  select id into u_a    from auth.users where email = 't197-a@test.local';
  select id into u_both from auth.users where email = 't197-both@test.local';
  select id into u_op   from auth.users where email = 't197-op@test.local';

  insert into public.profiles (id, email)
  select u, 't197-' || u::text || '@test.local'
    from unnest(array[u_a, u_both, u_op]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_a, 'T197 Vineyard A'),
    (v_b, v_b_name);

  -- u_a and u_op belong to A ONLY. u_both belongs to A and B.
  -- The asymmetry between u_a and u_both is what separates T3 from T4.
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_a, u_a,    'manager'),
    (v_a, u_op,   'operator'),
    (v_a, u_both, 'manager'),
    (v_b, u_both, 'manager');

  insert into public.paddocks (id, vineyard_id, name) values
    (b_a,  v_a, 'T197 Block A'),
    (b_a2, v_a, 'T197 Block A2'),
    (b_b,  v_b, v_bb_name);

  -- =====================================================================
  -- T1. The repair is actually in place
  -- =====================================================================
  select p.prosecdef, p.proconfig
    into v_secdef, v_config
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'spray_records_validate_block_vineyard';

  if not coalesce(v_secdef, false) then
    raise exception 'T1 FAILED: guard is not SECURITY DEFINER';
  end if;

  if v_config is null or not (v_config @> array['search_path=public']) then
    raise exception 'T1 FAILED: guard has no pinned search_path (proconfig = %)',
      coalesce(v_config::text, '<null>');
  end if;

  -- CREATE OR REPLACE must have preserved the OID the sql/195 trigger points at.
  select t.tgfoid into v_trigfn
    from pg_trigger t
   where t.tgrelid = 'public.spray_records'::regclass
     and t.tgname  = 'trg_spray_records_validate_block_vineyard'
     and not t.tgisinternal;

  if v_trigfn is null then
    raise exception 'T1 FAILED: sql/195 guard trigger is missing';
  end if;
  if v_trigfn is distinct from 'public.spray_records_validate_block_vineyard()'::regprocedure::oid then
    raise exception 'T1 FAILED: sql/195 trigger does not call the repaired guard';
  end if;

  -- The derivation trigger must be untouched by this repair.
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.spray_records'::regclass
       and tgname  = 'trg_spray_records_derive_block_ids'
       and not tgisinternal
  ) then
    raise exception 'T1 FAILED: sql/195 derivation trigger was disturbed';
  end if;
  raise notice 'T1 passed';

  -- =====================================================================
  -- T2. Same-vineyard block, as an authenticated member of A -> ACCEPTED
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type, tanks, application_blocks
  ) values (
    r_same, v_a, now(), 'T197 same-vineyard', 'Foliar Spray', '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('blockId', b_a::text, 'blockName', 'T197 Block A'))
  );

  select block_ids into v_ids from public.spray_records where id = r_same;
  if v_ids is distinct from array[b_a] then
    raise exception 'T2 FAILED: legitimate same-vineyard attribution not stored, got %',
      coalesce(v_ids::text, '<null>');
  end if;
  raise notice 'T2 passed';

  -- =====================================================================
  -- T3. Cross-vineyard block the caller CAN see -> REJECTED
  --
  -- u_both is a member of B, so RLS does not hide b_b from them. This is the
  -- ONLY variant the owner-role sql/195 suite was capable of exercising, and it
  -- passed even before the repair.
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_both::text, 'role', 'authenticated')::text, true);

  -- Precondition: this caller really can see the foreign paddock.
  select count(*) into v_cnt from public.paddocks where id = b_b;
  if v_cnt <> 1 then
    raise exception 'T3 FAILED: precondition — u_both should see the foreign block, saw % row(s)', v_cnt;
  end if;

  v_state := null;
  begin
    insert into public.spray_records (
      id, vineyard_id, date, spray_reference, operation_type, tanks, application_blocks
    ) values (
      gen_random_uuid(), v_a, now(), 'T197 cross visible', 'Foliar Spray', '[]'::jsonb,
      jsonb_build_array(jsonb_build_object('blockId', b_b::text))
    );
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is null then
    raise exception 'T3 FAILED: a visible cross-vineyard block was accepted';
  end if;
  if v_state <> '23514' then
    raise exception 'T3 FAILED: expected errcode 23514, got %', v_state;
  end if;
  raise notice 'T3 passed';

  -- =====================================================================
  -- T4. Cross-vineyard block HIDDEN BY RLS -> REJECTED
  --
  -- *** THE REGRESSION CASE. This is the defect sql/197 repairs. ***
  --
  -- u_a is NOT a member of B. Before the repair the guard ran as u_a, its
  -- lookup was filtered to zero rows by the paddocks SELECT policy, v_foreign
  -- stayed NULL, and this INSERT SUCCEEDED.
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);

  -- Step 1 — prove RLS genuinely hides the foreign paddock from THIS caller.
  -- Without this assertion the test could pass for the wrong reason (e.g. if
  -- the fixture accidentally made u_a a member of B).
  select count(*) into v_cnt from public.paddocks where id = b_b;
  if v_cnt <> 0 then
    raise exception
      'T4 FAILED: precondition — u_a must NOT be able to see the foreign block, saw % row(s)', v_cnt;
  end if;

  -- Step 2 — the guard must reject it anyway, i.e. it must see what the caller
  -- cannot. That is only possible with SECURITY DEFINER.
  v_state := null; v_msg := null;
  begin
    insert into public.spray_records (
      id, vineyard_id, date, spray_reference, operation_type, tanks, application_blocks
    ) values (
      gen_random_uuid(), v_a, now(), 'T197 cross hidden', 'Foliar Spray', '[]'::jsonb,
      jsonb_build_array(jsonb_build_object('blockId', b_b::text))
    );
  exception when others then
    v_state := sqlstate;
    v_msg   := sqlerrm;
  end;
  if v_state is null then
    raise exception
      'T4 FAILED: a cross-vineyard block HIDDEN BY RLS was accepted — the guard is still blind to foreign paddocks';
  end if;
  if v_state <> '23514' then
    raise exception 'T4 FAILED: expected errcode 23514, got %', v_state;
  end if;
  raise notice 'T4 passed (the sql/195 regression case)';

  -- =====================================================================
  -- T5. No information leakage in the rejection
  --
  -- The elevated read may decide accept/reject and nothing else. Echoing the
  -- caller's OWN submitted block id is fine; disclosing anything about the
  -- foreign vineyard is not.
  -- =====================================================================
  if v_msg is null then
    raise exception 'T5 FAILED: no error message captured from T4';
  end if;
  if position(v_b::text in v_msg) > 0 then
    raise exception 'T5 FAILED: rejection leaked the foreign vineyard id: %', v_msg;
  end if;
  if position(v_b_name in v_msg) > 0 then
    raise exception 'T5 FAILED: rejection leaked the foreign vineyard name: %', v_msg;
  end if;
  if position(v_bb_name in v_msg) > 0 then
    raise exception 'T5 FAILED: rejection leaked the foreign block name: %', v_msg;
  end if;
  raise notice 'T5 passed';

  -- =====================================================================
  -- T6. Unknown / deleted block id -> ACCEPTED (sql/195 semantics preserved)
  --
  -- The repair must NOT have turned the guard into an existence check. A
  -- completed spray is a compliance document: it keeps saying which block it
  -- treated even when that block no longer exists anywhere.
  -- =====================================================================
  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type, tanks, application_blocks
  ) values (
    r_ghost, v_a, now(), 'T197 unknown id', 'Foliar Spray', '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('blockId', b_ghost::text, 'blockName', 'Deleted block'))
  );

  select block_ids into v_ids from public.spray_records where id = r_ghost;
  if v_ids is distinct from array[b_ghost] then
    raise exception 'T6 FAILED: an unknown block id was not retained, got %',
      coalesce(v_ids::text, '<null>');
  end if;
  raise notice 'T6 passed';

  -- =====================================================================
  -- T7. Mixed valid + hidden-foreign -> the WHOLE write is rejected
  --
  -- Partial acceptance would be worse than either outcome: it would silently
  -- rewrite what the operator said they treated.
  -- =====================================================================
  v_state := null;
  begin
    insert into public.spray_records (
      id, vineyard_id, date, spray_reference, operation_type, tanks, application_blocks
    ) values (
      r_mixed, v_a, now(), 'T197 mixed', 'Foliar Spray', '[]'::jsonb,
      jsonb_build_array(
        jsonb_build_object('blockId', b_a::text),
        jsonb_build_object('blockId', b_b::text)   -- hidden from u_a
      )
    );
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is null then
    raise exception 'T7 FAILED: a write mixing a valid and a hidden foreign block was accepted';
  end if;
  if exists (select 1 from public.spray_records where id = r_mixed) then
    raise exception 'T7 FAILED: the rejected mixed write persisted a row';
  end if;

  -- The same write WITHOUT the foreign block must still succeed, proving the
  -- rejection was caused by the foreign block and not by multi-block writes.
  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type, tanks, application_blocks
  ) values (
    r_mixed, v_a, now(), 'T197 mixed clean', 'Foliar Spray', '[]'::jsonb,
    jsonb_build_array(
      jsonb_build_object('blockId', b_a::text),
      jsonb_build_object('blockId', b_a2::text)
    )
  );
  select block_ids into v_ids from public.spray_records where id = r_mixed;
  if v_ids is distinct from array[b_a, b_a2] then
    raise exception 'T7 FAILED: a legitimate two-block write was not stored in order, got %',
      coalesce(v_ids::text, '<null>');
  end if;
  raise notice 'T7 passed';

  -- =====================================================================
  -- T8. Historical attribution survives the block being deleted
  -- =====================================================================
  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type, tanks, application_blocks
  ) values (
    r_hist, v_a, now(), 'T197 historical', 'Foliar Spray', '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('blockId', b_a2::text, 'blockName', 'T197 Block A2'))
  );

  perform set_config('role', 'postgres', true);
  delete from public.paddocks where id = b_a2;
  perform set_config('role', 'authenticated', true);

  -- Still readable, still attributed.
  select block_ids into v_ids from public.spray_records where id = r_hist;
  if v_ids is distinct from array[b_a2] then
    raise exception 'T8 FAILED: deleting a block erased historical attribution, got %',
      coalesce(v_ids::text, '<null>');
  end if;

  -- Still updatable: a later edit must not be blocked by the now-missing block.
  update public.spray_records
     set notes = 'T197 edited after block deletion'
   where id = r_hist;

  -- And re-writing the attribution itself, with the deleted id, must still pass
  -- (it now matches no paddock row, which is the ALLOWED case).
  update public.spray_records
     set application_blocks =
           jsonb_build_array(jsonb_build_object('blockId', b_a2::text, 'blockName', 'T197 Block A2'))
   where id = r_hist;

  select block_ids into v_ids from public.spray_records where id = r_hist;
  if v_ids is distinct from array[b_a2] then
    raise exception 'T8 FAILED: re-writing attribution with a deleted block id failed, got %',
      coalesce(v_ids::text, '<null>');
  end if;
  raise notice 'T8 passed';

  -- =====================================================================
  -- T9. The fix did not narrow who may write
  --
  -- SECURITY DEFINER elevates the GUARD's read, not the caller's rights. An
  -- operator (a working role, not a manager) must still be able to record a
  -- spray for their own vineyard.
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);

  insert into public.spray_records (
    id, vineyard_id, date, spray_reference, operation_type, tanks, application_blocks
  ) values (
    r_op, v_a, now(), 'T197 operator write', 'Foliar Spray', '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('blockId', b_a::text))
  );

  select count(*) into v_cnt from public.spray_records where id = r_op;
  if v_cnt <> 1 then
    raise exception 'T9 FAILED: an operator could no longer record a spray for their own vineyard';
  end if;

  -- ...and is still stopped from referencing the foreign vineyard.
  v_state := null;
  begin
    insert into public.spray_records (
      id, vineyard_id, date, spray_reference, operation_type, tanks, application_blocks
    ) values (
      gen_random_uuid(), v_a, now(), 'T197 operator foreign', 'Foliar Spray', '[]'::jsonb,
      jsonb_build_array(jsonb_build_object('blockId', b_b::text))
    );
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is null then
    raise exception 'T9 FAILED: an operator persisted a hidden cross-vineyard block';
  end if;
  raise notice 'T9 passed';

  perform set_config('role', 'postgres', true);
  raise notice 'SQL 197 spray block vineyard guard tests: ALL PASSED';
end$$;

-- ---------------- T10 discard everything ----------------
rollback;

-- =====================================================================
-- Post-run expectation: the NOTICEs above, and ZERO rows remaining. Verify
-- with (outside any transaction):
--   select count(*) from public.spray_records where spray_reference like 'T197%';
--   -- expected: 0
--   select count(*) from auth.users where email like 't197-%@test.local';
--   -- expected: 0
-- =====================================================================

-- =====================================================================
-- 184_picking_record_planting_group_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/184_picking_record_planting_groups.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map (contract: docs/picking-records-allocation-identity-contract.md)
--   T1  Objects: planting_group_key() function, the three columns,
--       both indexes, the picking_yield_planting_totals view — and the
--       superseded sql/183 artifacts are ABSENT
--   T2  planting_group_key() algorithm — lower/trim/collapse-whitespace,
--       NULL → '' (must match the client-side mirrors byte for byte)
--   T3  Server canonicalisation — client key drift is recomputed from the
--       stored snapshots; member ids are preserved verbatim, in order
--   T4  Linked write with NULL member ids coalesces to '{}' (linked,
--       no minted ids ≠ unlinked)
--   T5  Unlinked write keeps BOTH fields NULL (no half-link)
--   T6  View: linked picks aggregate per group with the distinct member
--       union across picks; unlinked picks split per variety
--   T7  Reconciliation: view rows partition the vineyard's total weight
--       exactly (no row lost, none double-counted)
--   T8  All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 184 planting-group tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 184 is applied.
do $$
begin
  if to_regprocedure('public.planting_group_key(text,text,text)') is null then
    raise exception 'SQL 184 not applied — run sql/184_picking_record_planting_groups.sql first.';
  end if;
  if to_regclass('public.picking_yield_planting_totals') is null then
    raise exception 'SQL 184 view missing — run sql/184_picking_record_planting_groups.sql first.';
  end if;
end$$;

do $$
declare
  u_a  uuid;
  v_vy uuid := gen_random_uuid();
  b_a  uuid := gen_random_uuid();          -- block
  a1   uuid := gen_random_uuid();          -- planting-group member allocation ids
  a2   uuid := gen_random_uuid();
  p1   uuid := gen_random_uuid();          -- linked pick, members [a1, a2]
  p2   uuid := gen_random_uuid();          -- linked pick, same group, members [a2]
  p3   uuid := gen_random_uuid();          -- linked pick, no minted ids → '{}'
  p4   uuid := gen_random_uuid();          -- unlinked pick, Pinot Noir
  p5   uuid := gen_random_uuid();          -- unlinked pick, Chardonnay
  r    record;
  n    integer;
  ids  uuid[];
  w    numeric;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't184-a@test.local', 'x', now(), now(), now());
  select id into u_a from auth.users where email = 't184-a@test.local';

  insert into public.profiles (id, email) values (u_a, 't184-a@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values (v_vy, 'T184 Planting Group Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values (v_vy, u_a, 'manager');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);

  -- ---- T1. Objects present / sql/183 artifacts absent ---------------------
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'picking_records'
    and column_name in ('planting_group_key', 'variety_allocation_ids', 'rootstock');
  if n <> 3 then raise exception 'T1: expected 3 sql/184 columns, found %', n; end if;

  select count(*) into n from pg_indexes
  where schemaname = 'public' and tablename = 'picking_records'
    and indexname in ('idx_picking_records_planting_group',
                      'idx_picking_records_allocation_members');
  if n <> 2 then raise exception 'T1: expected 2 sql/184 indexes, found %', n; end if;

  -- Superseded sql/183 design must not exist anywhere.
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'picking_records'
               and column_name = 'variety_allocation_id') then
    raise exception 'T1: sql/183 column variety_allocation_id still present';
  end if;
  if to_regclass('public.picking_yield_allocation_totals') is not null then
    raise exception 'T1: sql/183 view picking_yield_allocation_totals still present';
  end if;
  raise notice 'T1 passed';

  -- ---- T2. Group-key algorithm (client mirrors must match byte for byte) --
  if public.planting_group_key('  Pinot   Noir ', 'MV6', 'Richter   110')
     <> 'pinot noir|mv6|richter 110' then
    raise exception 'T2: normalisation mismatch (got %)',
      public.planting_group_key('  Pinot   Noir ', 'MV6', 'Richter   110');
  end if;
  if public.planting_group_key(null, null, null) <> '||' then
    raise exception 'T2: NULL parts must normalise to empty (got %)',
      public.planting_group_key(null, null, null);
  end if;
  if public.planting_group_key('Shiraz', '', null) <> 'shiraz||' then
    raise exception 'T2: empty/NULL clone+rootstock mismatch';
  end if;
  raise notice 'T2 passed';

  -- ---- T3. Canonicalisation: client drift cannot fork a group -------------
  -- The client sends a deliberately wrong key; the trigger must recompute it
  -- from the stored snapshots and keep the member ids verbatim, in order.
  insert into public.picking_records
    (id, vineyard_id, picked_at, paddock_id, paddock_name,
     variety_name, clone, rootstock, weight_kg,
     planting_group_key, variety_allocation_ids)
  values
    (p1, v_vy, '2027-02-10', b_a, 'T184 Block',
     'Pinot Noir', '777', 'Richter 110', 1000,
     'CLIENT|DRIFT|KEY', array[a1, a2]);

  select planting_group_key, variety_allocation_ids into r
  from public.picking_records where id = p1;
  if r.planting_group_key <> public.planting_group_key('Pinot Noir', '777', 'Richter 110') then
    raise exception 'T3: key not server-canonicalised (got %)', r.planting_group_key;
  end if;
  if r.variety_allocation_ids <> array[a1, a2] then
    raise exception 'T3: member ids not preserved verbatim/in order';
  end if;

  -- Same group written by another device with drifting casing/whitespace and
  -- a changed block config (only a2 remains a member) → same key, own ids.
  insert into public.picking_records
    (id, vineyard_id, picked_at, paddock_id, paddock_name,
     variety_name, clone, rootstock, weight_kg,
     planting_group_key, variety_allocation_ids)
  values
    (p2, v_vy, '2027-02-12', b_a, 'T184 Block',
     ' pinot  NOIR ', ' 777', 'RICHTER 110 ', 2000,
     null, array[a2]);

  select planting_group_key into r from public.picking_records where id = p2;
  if r.planting_group_key <> (select planting_group_key from public.picking_records where id = p1) then
    raise exception 'T3: casing/whitespace drift forked the group';
  end if;
  raise notice 'T3 passed';

  -- ---- T4. Linked with no minted ids → '{}' (not NULL) ---------------------
  insert into public.picking_records
    (id, vineyard_id, picked_at, paddock_id, paddock_name,
     variety_name, clone, rootstock, weight_kg,
     planting_group_key, variety_allocation_ids)
  values
    (p3, v_vy, '2027-02-14', b_a, 'T184 Block',
     'Shiraz', null, '1103 Paulsen', 500,
     'sentinel-to-mark-linked', null);

  select planting_group_key, variety_allocation_ids into r
  from public.picking_records where id = p3;
  if r.planting_group_key <> public.planting_group_key('Shiraz', null, '1103 Paulsen') then
    raise exception 'T4: linked key not recomputed';
  end if;
  if r.variety_allocation_ids is null or r.variety_allocation_ids <> '{}'::uuid[] then
    raise exception 'T4: NULL member ids on a linked row must coalesce to {}';
  end if;
  raise notice 'T4 passed';

  -- ---- T5. Unlinked keeps BOTH fields NULL ---------------------------------
  insert into public.picking_records
    (id, vineyard_id, picked_at, paddock_id, paddock_name, variety_name, weight_kg)
  values
    (p4, v_vy, '2027-02-15', b_a, 'T184 Block', 'Pinot Noir', 3000),
    (p5, v_vy, '2027-02-15', b_a, 'T184 Block', 'Chardonnay', 400);

  select planting_group_key, variety_allocation_ids into r
  from public.picking_records where id = p4;
  if r.planting_group_key is not null or r.variety_allocation_ids is not null then
    raise exception 'T5: unlinked row was half-linked';
  end if;
  raise notice 'T5 passed';

  -- ---- T6. View: group aggregation + member union + unlinked splits -------
  -- Pinot group row: 2 picks, 3000 kg, member union {a1, a2}.
  select pick_count, total_weight_kg, member_allocation_ids into r
  from public.picking_yield_planting_totals
  where vineyard_id = v_vy
    and planting_group_key = public.planting_group_key('Pinot Noir', '777', 'Richter 110');
  if r.pick_count <> 2 or r.total_weight_kg <> 3000 then
    raise exception 'T6: pinot group totals wrong (count %, weight %)', r.pick_count, r.total_weight_kg;
  end if;
  select array_agg(x order by x) into ids from unnest(array[a1, a2]) x;
  if r.member_allocation_ids <> ids then
    raise exception 'T6: member union across picks wrong';
  end if;

  -- Shiraz group row: 1 pick, no minted member ids.
  select pick_count, member_allocation_ids into r
  from public.picking_yield_planting_totals
  where vineyard_id = v_vy
    and planting_group_key = public.planting_group_key('Shiraz', null, '1103 Paulsen');
  if r.pick_count <> 1 then raise exception 'T6: shiraz group row missing'; end if;

  -- Unlinked picks split per variety (not one mixed bucket per block).
  select count(*) into n from public.picking_yield_planting_totals
  where vineyard_id = v_vy and planting_group_key is null;
  if n <> 2 then raise exception 'T6: expected 2 unlinked variety rows, found %', n; end if;

  select total_weight_kg into r from public.picking_yield_planting_totals
  where vineyard_id = v_vy and unlinked_variety_key = 'pinot noir';
  if r.total_weight_kg <> 3000 then
    raise exception 'T6: unlinked pinot bucket must NOT absorb the linked group';
  end if;
  raise notice 'T6 passed';

  -- ---- T7. Partition/reconcile: view rows sum to the table exactly --------
  select sum(total_weight_kg) into w
  from public.picking_yield_planting_totals where vineyard_id = v_vy;
  if w <> 1000 + 2000 + 500 + 3000 + 400 then
    raise exception 'T7: view does not partition the vineyard total (got %)', w;
  end if;
  select count(*) into n from public.picking_yield_planting_totals where vineyard_id = v_vy;
  if n <> 4 then raise exception 'T7: expected 4 view rows, found %', n; end if;

  perform set_config('request.jwt.claims', null, true);
  raise notice 'SQL 184 planting-group tests: ALL PASSED';
end$$;

-- ---- T8. Discard every fixture -------------------------------------------
rollback;

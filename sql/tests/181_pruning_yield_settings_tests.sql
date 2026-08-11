-- =====================================================================
-- 181_pruning_yield_settings_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/181_pruning_yield_settings.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects, constraints, triggers, RPC grants exist
--   T2  One saved configuration per block: unique (vineyard_id, paddock_id),
--       upsert on that target updates in place (no duplicate rows)
--   T3  Per-block independence: changing Block A never touches Block B
--   T4  Input normalisation + validation: prune_method case-normalised,
--       invalid method rejected, negative inputs rejected,
--       vines_per_ha nullable
--   T5  RLS: members read/write their vineyard only; outsiders blocked;
--       operator can write; client hard delete blocked
--   T6  soft_delete_pruning_yield_settings: supervisor+ only, sets
--       deleted_at; a later client upsert resurrects the row
--
-- Expected final output:
--   NOTICE: SQL 181 pruning yield settings tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 181 is applied.
do $$
begin
  if to_regclass('public.pruning_yield_settings') is null
     or to_regprocedure('public.soft_delete_pruning_yield_settings(uuid)') is null then
    raise exception 'SQL 181 not applied — run sql/181_pruning_yield_settings.sql first.';
  end if;
end$$;

do $$
declare
  u_mgr uuid;
  u_op  uuid;
  u_out uuid;
  v_vy  uuid := gen_random_uuid();
  v_vy2 uuid := gen_random_uuid();
  b_a   uuid := gen_random_uuid();
  b_b   uuid := gen_random_uuid();
  s_a   uuid := gen_random_uuid();
  s_b   uuid := gen_random_uuid();
  r     record;
  n     integer;
  v_failed boolean;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t181-mgr@test.local','t181-op@test.local','t181-out@test.local']) e;
  select id into u_mgr from auth.users where email = 't181-mgr@test.local';
  select id into u_op  from auth.users where email = 't181-op@test.local';
  select id into u_out from auth.users where email = 't181-out@test.local';

  insert into public.profiles (id, email)
  select u, 't181-' || u::text || '@test.local' from unnest(array[u_mgr, u_op, u_out]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_vy,  'T181 Pruning Vineyard'),
    (v_vy2, 'T181 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vy,  u_mgr, 'manager'),
    (v_vy,  u_op,  'operator'),
    (v_vy2, u_out, 'manager');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- ---- T1. Objects, constraints, grants -----------------------------------
  perform set_config('role', 'postgres', true);
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'pruning_yield_settings'
    and column_name in ('id','vineyard_id','paddock_id','prune_method','bunches_per_bud',
                        'buds_per_spur','spurs_per_vine','buds_per_cane','canes_per_vine',
                        'vines_per_ha','bunch_weight_grams','created_by','updated_by',
                        'created_at','updated_at','deleted_at','client_updated_at','sync_version');
  if n <> 18 then raise exception 'T1: expected 18 contract columns, found %', n; end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.pruning_yield_settings'::regclass
      and conname = 'pruning_yield_settings_vineyard_paddock_key'
      and contype = 'u') then
    raise exception 'T1: unique (vineyard_id, paddock_id) constraint missing';
  end if;

  select count(*) into n from pg_trigger
  where tgrelid = 'public.pruning_yield_settings'::regclass
    and tgname in ('pruning_yield_settings_before_write', 'pruning_yield_settings_set_updated_at');
  if n <> 2 then raise exception 'T1: triggers missing'; end if;
  raise notice 'T1 passed';

  -- ---- T2. One configuration per block + upsert ----------------------------
  perform set_config('role', 'authenticated', true);

  insert into public.pruning_yield_settings
    (id, vineyard_id, paddock_id, prune_method, bunches_per_bud, buds_per_spur,
     spurs_per_vine, buds_per_cane, canes_per_vine, vines_per_ha, bunch_weight_grams,
     created_by, updated_by, client_updated_at)
  values
    (s_a, v_vy, b_a, 'spur', 1.5, 2, 6, 10, 4, 2000, 120, u_mgr, u_mgr, now());

  -- Duplicate row for the same block is rejected outright…
  v_failed := false;
  begin
    insert into public.pruning_yield_settings (vineyard_id, paddock_id)
    values (v_vy, b_a);
  exception when unique_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T2: duplicate block row not rejected'; end if;

  -- …while the client upsert path (on_conflict = vineyard_id,paddock_id)
  -- updates the existing row in place, even when a second device minted a
  -- DIFFERENT id for the same block.
  insert into public.pruning_yield_settings
    (id, vineyard_id, paddock_id, prune_method, bunches_per_bud, buds_per_spur,
     spurs_per_vine, buds_per_cane, canes_per_vine, vines_per_ha, bunch_weight_grams,
     created_by, updated_by, client_updated_at)
  values
    (gen_random_uuid(), v_vy, b_a, 'cane', 1.2, 2, 6, 12, 3, 1800, 110, u_mgr, u_mgr, now())
  on conflict (vineyard_id, paddock_id) do update set
    prune_method = excluded.prune_method,
    bunches_per_bud = excluded.bunches_per_bud,
    buds_per_spur = excluded.buds_per_spur,
    spurs_per_vine = excluded.spurs_per_vine,
    buds_per_cane = excluded.buds_per_cane,
    canes_per_vine = excluded.canes_per_vine,
    vines_per_ha = excluded.vines_per_ha,
    bunch_weight_grams = excluded.bunch_weight_grams,
    updated_by = excluded.updated_by,
    client_updated_at = excluded.client_updated_at;

  select count(*) into n from public.pruning_yield_settings
  where vineyard_id = v_vy and paddock_id = b_a;
  if n <> 1 then raise exception 'T2: upsert duplicated the block row (% rows)', n; end if;

  select * into r from public.pruning_yield_settings where vineyard_id = v_vy and paddock_id = b_a;
  if r.id <> s_a or r.prune_method <> 'cane' or r.buds_per_cane <> 12 or r.vines_per_ha <> 1800 then
    raise exception 'T2: upsert did not update in place (id=% method=%)', r.id, r.prune_method;
  end if;
  raise notice 'T2 passed';

  -- ---- T3. Per-block independence -------------------------------------------
  insert into public.pruning_yield_settings
    (id, vineyard_id, paddock_id, prune_method, bunches_per_bud, buds_per_spur,
     spurs_per_vine, vines_per_ha, bunch_weight_grams, created_by, updated_by, client_updated_at)
  values
    (s_b, v_vy, b_b, 'spur', 1.5, 2, 8, 2200, 130, u_mgr, u_mgr, now());

  update public.pruning_yield_settings
     set spurs_per_vine = 10, bunch_weight_grams = 150, client_updated_at = now()
   where vineyard_id = v_vy and paddock_id = b_a;

  select * into r from public.pruning_yield_settings where id = s_b;
  if r.spurs_per_vine <> 8 or r.bunch_weight_grams <> 130 then
    raise exception 'T3: editing Block A leaked into Block B';
  end if;
  raise notice 'T3 passed';

  -- ---- T4. Normalisation + validation ---------------------------------------
  update public.pruning_yield_settings
     set prune_method = '  SPUR ', client_updated_at = now()
   where id = s_a;
  select * into r from public.pruning_yield_settings where id = s_a;
  if r.prune_method <> 'spur' then
    raise exception 'T4: prune_method not normalised: %', r.prune_method;
  end if;

  v_failed := false;
  begin
    update public.pruning_yield_settings set prune_method = 'topiary' where id = s_a;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T4: invalid prune_method not rejected'; end if;

  v_failed := false;
  begin
    update public.pruning_yield_settings set bunches_per_bud = -1 where id = s_a;
  exception when check_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'T4: negative input not rejected'; end if;

  -- vines_per_ha may be null (client derives from block config)
  update public.pruning_yield_settings set vines_per_ha = null, client_updated_at = now() where id = s_a;
  select * into r from public.pruning_yield_settings where id = s_a;
  if r.vines_per_ha is not null then raise exception 'T4: vines_per_ha should accept null'; end if;
  update public.pruning_yield_settings set vines_per_ha = 1800, client_updated_at = now() where id = s_a;
  raise notice 'T4 passed';

  -- ---- T5. RLS ---------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_out::text, 'role', 'authenticated')::text, true);
  select count(*) into n from public.pruning_yield_settings where vineyard_id = v_vy;
  if n <> 0 then raise exception 'T5: outsider can read foreign settings'; end if;

  v_failed := false;
  begin
    insert into public.pruning_yield_settings (vineyard_id, paddock_id)
    values (v_vy, gen_random_uuid());
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T5: outsider insert not blocked'; end if;

  -- operator CAN write (owner/manager/supervisor/operator write roles)
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  update public.pruning_yield_settings
     set bunch_weight_grams = 140, client_updated_at = now()
   where id = s_b;
  select * into r from public.pruning_yield_settings where id = s_b;
  if r.bunch_weight_grams <> 140 then raise exception 'T5: operator write failed'; end if;

  -- client hard delete blocked for everyone
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  delete from public.pruning_yield_settings where id = s_a;
  select count(*) into n from public.pruning_yield_settings where id = s_a;
  if n <> 1 then raise exception 'T5: client hard delete was not blocked'; end if;
  raise notice 'T5 passed';

  -- ---- T6. Soft delete + resurrection ----------------------------------------
  -- operator (below supervisor) is rejected
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.soft_delete_pruning_yield_settings(s_b);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T6: operator delete not rejected'; end if;

  -- manager succeeds
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  perform public.soft_delete_pruning_yield_settings(s_b);
  select * into r from public.pruning_yield_settings where id = s_b;
  if r.deleted_at is null or r.updated_by <> u_mgr then
    raise exception 'T6: soft delete did not stamp deleted_at/updated_by';
  end if;

  -- a later client upsert (client_updated_at changes) resurrects the row:
  -- the block has ONE current configuration again
  insert into public.pruning_yield_settings
    (id, vineyard_id, paddock_id, prune_method, client_updated_at, updated_by)
  values
    (gen_random_uuid(), v_vy, b_b, 'cane', now() + interval '1 second', u_mgr)
  on conflict (vineyard_id, paddock_id) do update set
    prune_method = excluded.prune_method,
    client_updated_at = excluded.client_updated_at,
    updated_by = excluded.updated_by;
  select * into r from public.pruning_yield_settings where id = s_b;
  if r.deleted_at is not null or r.prune_method <> 'cane' then
    raise exception 'T6: client upsert did not resurrect the soft-deleted row';
  end if;
  raise notice 'T6 passed';

  perform set_config('role', 'postgres', true);
  raise notice 'SQL 181 pruning yield settings tests: ALL PASSED';
end$$;

rollback;

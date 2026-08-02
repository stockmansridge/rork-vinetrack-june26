-- =====================================================================
-- 160_delete_damage_record_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project
-- (tbafuqwruefgkbyxrxyb) AFTER applying sql/160_delete_damage_record.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production damage record is created, changed or deleted.
--
-- Test map
--   T1  Schema: deleted_by exists, nullable, uuid, FK to auth.users
--   T2  Function signatures, security definer, fixed search_path, grants
--   T3  can_manage_vineyard_damage: Owner / co-Owner / Manager / SysAdmin
--   T4  can_manage_vineyard_damage: Supervisor / Operator / non-member
--   T5  Manager deletes a record in their own vineyard (happy path)
--   T6  Row is retained; deleted_at + deleted_by populated with the caller
--   T7  Record disappears from standard damage history
--   T8  Record no longer contributes to yield / damage summaries
--   T9  Supervisor  -> damage_delete_permission_denied
--   T10 Operator    -> damage_delete_permission_denied
--   T11 Non-member  -> damage_delete_permission_denied
--   T12 Manager of another vineyard -> denied (and cannot probe existence)
--   T13 Repeated delete -> damage_record_already_deleted
--   T14 Unknown id / wrong vineyard -> damage_record_not_found
--   T15 Owner, co-Owner and System Administrator may delete
--   T16 Anonymous caller rejected
--   T17 Mobile soft_delete_damage_record still works and stamps deleted_by
--   T18 No hard delete happened anywhere
--   T19 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 160 delete damage record tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 160 is applied.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'damage_records'
       and column_name = 'deleted_by'
  ) then
    raise exception 'SQL 160 not applied — damage_records.deleted_by missing.';
  end if;
  if to_regprocedure('public.can_manage_vineyard_damage(uuid)') is null
     or to_regprocedure('public.delete_damage_record(uuid, uuid)') is null then
    raise exception 'SQL 160 not applied — run sql/160_delete_damage_record.sql first.';
  end if;
end$$;

do $$
declare
  u_owner   uuid;  -- owner of record of vA
  u_coown   uuid;  -- co-Owner of vA (role = 'owner', not owner of record)
  u_mgr     uuid;  -- manager    vA
  u_sup     uuid;  -- supervisor vA
  u_op      uuid;  -- operator   vA
  u_admin   uuid;  -- active System Administrator, member of nothing
  u_outside uuid;  -- member of nothing
  u_bmgr    uuid;  -- manager of vB only

  v_a uuid;  -- vineyard under test
  v_b uuid;  -- unrelated vineyard

  pad_a uuid := gen_random_uuid();  -- damage_records.paddock_id has no FK
  pad_b uuid := gen_random_uuid();

  d_mgr   uuid;  -- deleted by the manager
  d_own   uuid;  -- deleted by the owner of record
  d_co    uuid;  -- deleted by the co-Owner
  d_admin uuid;  -- deleted by the system admin
  d_keep  uuid;  -- never deleted (control)
  d_soft  uuid;  -- deleted through the mobile soft-delete RPC
  d_b     uuid;  -- lives in vB

  r         jsonb;
  err       text;
  state     text;
  n         integer;
  total_before integer;
  pct       double precision;
  ts        timestamptz;
  actor     uuid;
begin
  -- =====================================================================
  -- Fixtures
  -- =====================================================================
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array[
    't160-owner@test.local',   't160-coown@test.local', 't160-mgr@test.local',
    't160-sup@test.local',     't160-op@test.local',    't160-admin@test.local',
    't160-outside@test.local', 't160-bmgr@test.local'
  ]) e;

  select id into u_owner   from auth.users where email = 't160-owner@test.local';
  select id into u_coown   from auth.users where email = 't160-coown@test.local';
  select id into u_mgr     from auth.users where email = 't160-mgr@test.local';
  select id into u_sup     from auth.users where email = 't160-sup@test.local';
  select id into u_op      from auth.users where email = 't160-op@test.local';
  select id into u_admin   from auth.users where email = 't160-admin@test.local';
  select id into u_outside from auth.users where email = 't160-outside@test.local';
  select id into u_bmgr    from auth.users where email = 't160-bmgr@test.local';

  insert into public.profiles (id, email)
  select u, 't160-' || u::text || '@test.local'
  from unnest(array[u_owner, u_coown, u_mgr, u_sup, u_op, u_admin, u_outside, u_bmgr]) u
  on conflict (id) do nothing;

  insert into public.system_admins (user_id, is_active) values (u_admin, true)
  on conflict do nothing;

  insert into public.vineyards (id, name, owner_id) values
    (gen_random_uuid(), 'T160 Damage vineyard',   u_owner),
    (gen_random_uuid(), 'T160 Other vineyard',    u_bmgr);
  select id into v_a from public.vineyards where name = 'T160 Damage vineyard';
  select id into v_b from public.vineyards where name = 'T160 Other vineyard';

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_a, u_owner, 'owner'),   (v_a, u_coown, 'owner'),
    (v_a, u_mgr,   'manager'), (v_a, u_sup,   'supervisor'),
    (v_a, u_op,    'operator'),
    (v_b, u_bmgr,  'owner');

  insert into public.damage_records (id, vineyard_id, paddock_id, damage_type, damage_percent, notes, created_by)
  values
    (gen_random_uuid(), v_a, pad_a, 'Frost', 10, 'T160 manager target', u_owner),
    (gen_random_uuid(), v_a, pad_a, 'Hail',  20, 'T160 owner target',   u_owner),
    (gen_random_uuid(), v_a, pad_a, 'Wind',  30, 'T160 coowner target', u_owner),
    (gen_random_uuid(), v_a, pad_a, 'Frost', 40, 'T160 admin target',   u_owner),
    (gen_random_uuid(), v_a, pad_a, 'Hail',  50, 'T160 control keep',   u_owner),
    (gen_random_uuid(), v_a, pad_a, 'Wind',  60, 'T160 mobile soft',    u_owner),
    (gen_random_uuid(), v_b, pad_b, 'Frost', 70, 'T160 other vineyard', u_bmgr);

  select id into d_mgr   from public.damage_records where notes = 'T160 manager target';
  select id into d_own   from public.damage_records where notes = 'T160 owner target';
  select id into d_co    from public.damage_records where notes = 'T160 coowner target';
  select id into d_admin from public.damage_records where notes = 'T160 admin target';
  select id into d_keep  from public.damage_records where notes = 'T160 control keep';
  select id into d_soft  from public.damage_records where notes = 'T160 mobile soft';
  select id into d_b     from public.damage_records where notes = 'T160 other vineyard';

  select count(*) into total_before from public.damage_records where notes like 'T160 %';
  assert total_before = 7, 'fixture: 7 damage records expected, found ' || total_before;

  -- =====================================================================
  -- T1. Schema
  -- =====================================================================
  select count(*) into n
  from information_schema.columns
  where table_schema = 'public' and table_name = 'damage_records'
    and column_name = 'deleted_by' and data_type = 'uuid' and is_nullable = 'YES';
  assert n = 1, 'T1a deleted_by must exist as nullable uuid';

  assert exists (
    select 1 from information_schema.table_constraints
     where table_schema = 'public' and table_name = 'damage_records'
       and constraint_name = 'damage_records_deleted_by_fkey'
       and constraint_type = 'FOREIGN KEY'
  ), 'T1b deleted_by FK to auth.users must exist';

  assert exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'damage_records'
       and column_name = 'deleted_at'
  ), 'T1c existing soft-delete column retained';
  raise notice 'T1 passed: deleted_by added, deleted_at soft-delete model retained';

  -- =====================================================================
  -- T2. Function definition, isolation and grants
  -- =====================================================================
  assert (select p.prosecdef from pg_proc p where p.oid = 'public.delete_damage_record(uuid, uuid)'::regprocedure),
    'T2a delete_damage_record must be security definer';
  assert (select p.prosecdef from pg_proc p where p.oid = 'public.can_manage_vineyard_damage(uuid)'::regprocedure),
    'T2b can_manage_vineyard_damage must be security definer';
  assert (select p.proconfig from pg_proc p where p.oid = 'public.delete_damage_record(uuid, uuid)'::regprocedure)
         @> array['search_path=public'],
    'T2c delete_damage_record must pin search_path=public';
  assert (select p.proconfig from pg_proc p where p.oid = 'public.can_manage_vineyard_damage(uuid)'::regprocedure)
         @> array['search_path=public'],
    'T2d can_manage_vineyard_damage must pin search_path=public';

  assert has_function_privilege('authenticated', 'public.delete_damage_record(uuid, uuid)', 'execute'),
    'T2e authenticated must be able to execute delete_damage_record';
  assert has_function_privilege('authenticated', 'public.can_manage_vineyard_damage(uuid)', 'execute'),
    'T2f authenticated must be able to execute can_manage_vineyard_damage';
  assert not has_function_privilege('anon', 'public.delete_damage_record(uuid, uuid)', 'execute'),
    'T2g anon must NOT be able to execute delete_damage_record';
  assert not has_function_privilege('public', 'public.delete_damage_record(uuid, uuid)', 'execute'),
    'T2h PUBLIC must NOT be able to execute delete_damage_record';
  raise notice 'T2 passed: security definer, fixed search_path, authenticated-only grants';

  -- =====================================================================
  -- T3. Helper allows Owner / co-Owner / Manager / System Administrator
  -- =====================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_owner::text, 'role', 'authenticated')::text, true);
  assert public.can_manage_vineyard_damage(v_a), 'T3a owner of record may manage damage';
  perform set_config('request.jwt.claims', json_build_object('sub', u_coown::text, 'role', 'authenticated')::text, true);
  assert public.can_manage_vineyard_damage(v_a), 'T3b co-Owner may manage damage';
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  assert public.can_manage_vineyard_damage(v_a), 'T3c manager may manage damage';
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);
  assert public.can_manage_vineyard_damage(v_a), 'T3d system administrator may manage damage';
  raise notice 'T3 passed: owner, co-owner, manager, system admin allowed';

  -- =====================================================================
  -- T4. Helper denies Supervisor / Operator / non-member / cross-vineyard
  -- =====================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_sup::text, 'role', 'authenticated')::text, true);
  assert not public.can_manage_vineyard_damage(v_a), 'T4a supervisor denied';
  perform set_config('request.jwt.claims', json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  assert not public.can_manage_vineyard_damage(v_a), 'T4b operator denied';
  perform set_config('request.jwt.claims', json_build_object('sub', u_outside::text, 'role', 'authenticated')::text, true);
  assert not public.can_manage_vineyard_damage(v_a), 'T4c non-member denied';
  perform set_config('request.jwt.claims', json_build_object('sub', u_bmgr::text, 'role', 'authenticated')::text, true);
  assert not public.can_manage_vineyard_damage(v_a), 'T4d manager of another vineyard denied';
  assert public.can_manage_vineyard_damage(v_b),     'T4e ...but allowed in their own vineyard';
  perform set_config('request.jwt.claims', null, true);
  assert not public.can_manage_vineyard_damage(v_a), 'T4f anonymous denied';
  raise notice 'T4 passed: supervisor, operator, non-member, cross-vineyard, anonymous denied';

  -- =====================================================================
  -- T5. Manager deletes a damage record in their own vineyard
  -- =====================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  r := public.delete_damage_record(v_a, d_mgr);
  assert (r->>'damage_record_id')::uuid = d_mgr,  'T5a payload returns the record id';
  assert (r->>'vineyard_id')::uuid      = v_a,    'T5b payload returns the vineyard id';
  assert (r->>'deleted_by')::uuid       = u_mgr,  'T5c payload attributes the caller';
  assert r ? 'deleted_at',                        'T5d payload returns deleted_at';
  raise notice 'T5 passed: manager delete succeeded';

  -- =====================================================================
  -- T6. Row retained, deleted_at + deleted_by populated
  -- =====================================================================
  select deleted_at, deleted_by into ts, actor
  from public.damage_records where id = d_mgr;
  assert ts is not null,       'T6a deleted_at populated';
  assert actor = u_mgr,        'T6b deleted_by is the manager who deleted it';
  assert exists (select 1 from public.damage_records where id = d_mgr),
    'T6c the row itself is retained (soft delete, not a hard delete)';
  assert (select updated_by from public.damage_records where id = d_mgr) = u_mgr,
    'T6d updated_by stamped, matching the existing soft-delete convention';
  raise notice 'T6 passed: row retained with deleted_at/deleted_by/updated_by';

  -- =====================================================================
  -- T7. Gone from standard damage history
  -- =====================================================================
  select count(*) into n
  from public.damage_records
  where vineyard_id = v_a and deleted_at is null;
  assert n = 5, 'T7a five live records remain in vA, found ' || n;
  assert not exists (
    select 1 from public.damage_records
     where vineyard_id = v_a and deleted_at is null and id = d_mgr
  ), 'T7b deleted record excluded from the standard history query';
  raise notice 'T7 passed: excluded from standard damage history';

  -- =====================================================================
  -- T8. No longer contributes to yield / damage summaries
  -- =====================================================================
  select coalesce(sum(damage_percent), 0) into pct
  from public.damage_records
  where vineyard_id = v_a and deleted_at is null;
  assert pct = 200, 'T8 damage summary must drop the 10% deleted record (expected 200, got ' || pct || ')';
  raise notice 'T8 passed: deleted record no longer contributes to damage/yield summaries';

  -- =====================================================================
  -- T9. Supervisor denied
  -- =====================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_sup::text, 'role', 'authenticated')::text, true);
  err := null;
  begin
    r := public.delete_damage_record(v_a, d_keep);
  exception when others then err := sqlerrm; state := sqlstate;
  end;
  assert err = 'damage_delete_permission_denied', 'T9a supervisor error was: ' || coalesce(err, 'none');
  assert state = '42501', 'T9b supervisor errcode was: ' || coalesce(state, 'none');
  assert (select deleted_at from public.damage_records where id = d_keep) is null,
    'T9c the record must be untouched';
  raise notice 'T9 passed: supervisor -> damage_delete_permission_denied';

  -- =====================================================================
  -- T10. Operator denied
  -- =====================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  err := null;
  begin
    r := public.delete_damage_record(v_a, d_keep);
  exception when others then err := sqlerrm;
  end;
  assert err = 'damage_delete_permission_denied', 'T10 operator error was: ' || coalesce(err, 'none');
  raise notice 'T10 passed: operator -> damage_delete_permission_denied';

  -- =====================================================================
  -- T11. Non-member (read-only / no membership) denied
  -- =====================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_outside::text, 'role', 'authenticated')::text, true);
  err := null;
  begin
    r := public.delete_damage_record(v_a, d_keep);
  exception when others then err := sqlerrm;
  end;
  assert err = 'damage_delete_permission_denied', 'T11 non-member error was: ' || coalesce(err, 'none');
  raise notice 'T11 passed: non-member -> damage_delete_permission_denied';

  -- =====================================================================
  -- T12. Manager from another vineyard denied, and cannot probe existence
  -- =====================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_bmgr::text, 'role', 'authenticated')::text, true);
  err := null;
  begin
    r := public.delete_damage_record(v_a, d_keep);
  exception when others then err := sqlerrm;
  end;
  assert err = 'damage_delete_permission_denied', 'T12a cross-vineyard manager error was: ' || coalesce(err, 'none');

  -- A real id and a fake id must be indistinguishable to an unauthorised caller.
  err := null;
  begin
    r := public.delete_damage_record(v_a, gen_random_uuid());
  exception when others then err := sqlerrm;
  end;
  assert err = 'damage_delete_permission_denied',
    'T12b unauthorised callers must not learn whether a record exists (got ' || coalesce(err, 'none') || ')';
  raise notice 'T12 passed: cross-vineyard manager denied without leaking record existence';

  -- =====================================================================
  -- T13. Repeated delete
  -- =====================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  err := null; state := null;
  begin
    r := public.delete_damage_record(v_a, d_mgr);
  exception when others then err := sqlerrm; state := sqlstate;
  end;
  assert err = 'damage_record_already_deleted', 'T13a repeat delete error was: ' || coalesce(err, 'none');
  assert state = '22023', 'T13b repeat delete errcode was: ' || coalesce(state, 'none');
  assert (select deleted_by from public.damage_records where id = d_mgr) = u_mgr,
    'T13c the original deleter attribution must not be overwritten';
  raise notice 'T13 passed: repeated delete -> damage_record_already_deleted';

  -- =====================================================================
  -- T14. Unknown id and wrong-vineyard id
  -- =====================================================================
  err := null; state := null;
  begin
    r := public.delete_damage_record(v_a, gen_random_uuid());
  exception when others then err := sqlerrm; state := sqlstate;
  end;
  assert err = 'damage_record_not_found', 'T14a unknown id error was: ' || coalesce(err, 'none');
  assert state = 'P0002', 'T14b unknown id errcode was: ' || coalesce(state, 'none');

  err := null;
  begin
    r := public.delete_damage_record(v_a, d_b);   -- record belongs to vB
  exception when others then err := sqlerrm;
  end;
  assert err = 'damage_record_not_found', 'T14c wrong-vineyard id error was: ' || coalesce(err, 'none');
  assert (select deleted_at from public.damage_records where id = d_b) is null,
    'T14d the other vineyard record must be untouched';

  err := null;
  begin
    r := public.delete_damage_record(v_a, null);
  exception when others then err := sqlerrm;
  end;
  assert err = 'damage_record_not_found', 'T14e null id error was: ' || coalesce(err, 'none');
  raise notice 'T14 passed: unknown / wrong-vineyard / null id -> damage_record_not_found';

  -- =====================================================================
  -- T15. Owner, co-Owner and System Administrator may delete
  -- =====================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_owner::text, 'role', 'authenticated')::text, true);
  r := public.delete_damage_record(v_a, d_own);
  assert (select deleted_by from public.damage_records where id = d_own) = u_owner, 'T15a owner delete attributed';

  perform set_config('request.jwt.claims', json_build_object('sub', u_coown::text, 'role', 'authenticated')::text, true);
  r := public.delete_damage_record(v_a, d_co);
  assert (select deleted_by from public.damage_records where id = d_co) = u_coown, 'T15b co-owner delete attributed';

  perform set_config('request.jwt.claims', json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);
  r := public.delete_damage_record(v_a, d_admin);
  assert (select deleted_by from public.damage_records where id = d_admin) = u_admin, 'T15c system admin delete attributed';
  raise notice 'T15 passed: owner, co-owner and system administrator deletes succeed and are attributed';

  -- =====================================================================
  -- T16. Anonymous caller rejected
  -- =====================================================================
  perform set_config('request.jwt.claims', null, true);
  err := null; state := null;
  begin
    r := public.delete_damage_record(v_a, d_keep);
  exception when others then err := sqlerrm; state := sqlstate;
  end;
  assert err = 'damage_delete_permission_denied', 'T16a anonymous error was: ' || coalesce(err, 'none');
  assert state = '42501', 'T16b anonymous errcode was: ' || coalesce(state, 'none');
  assert (select deleted_at from public.damage_records where id = d_keep) is null, 'T16c control record untouched';
  raise notice 'T16 passed: anonymous callers rejected';

  -- =====================================================================
  -- T17. Mobile soft-delete RPC unchanged in behaviour, now stamps deleted_by
  -- =====================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  perform public.soft_delete_damage_record(d_soft);   -- operators keep this path (sql/049)
  select deleted_at, deleted_by into ts, actor from public.damage_records where id = d_soft;
  assert ts is not null,  'T17a mobile soft delete still sets deleted_at';
  assert actor = u_op,    'T17b mobile soft delete now stamps deleted_by';
  raise notice 'T17 passed: iOS/Android soft-delete path intact and attributed';

  -- =====================================================================
  -- T18. Nothing was hard-deleted
  -- =====================================================================
  select count(*) into n from public.damage_records where notes like 'T160 %';
  assert n = total_before, 'T18 all ' || total_before || ' rows retained, found ' || n;
  select count(*) into n from public.damage_records where notes like 'T160 %' and deleted_at is not null;
  assert n = 5, 'T18b five records soft-deleted, found ' || n;
  raise notice 'T18 passed: soft delete only, no rows removed';

  -- =====================================================================
  -- T19. Fixtures exist only inside this transaction
  -- =====================================================================
  assert (select count(*) from auth.users where email like 't160-%@test.local') = 8,
    'T19a fixtures present inside the transaction';
  raise notice 'T19: fixtures will be discarded by the final ROLLBACK';

  raise notice 'SQL 160 delete damage record tests: ALL PASSED';
end$$;

rollback;

-- Post-rollback proof: every count must be 0.
select
  (select count(*) from auth.users where email like 't160-%@test.local')     as leftover_users,
  (select count(*) from public.vineyards where name like 'T160 %')           as leftover_vineyards,
  (select count(*) from public.damage_records where notes like 'T160 %')     as leftover_damage_records;

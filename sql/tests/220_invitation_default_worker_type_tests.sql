-- =====================================================================
-- 220_invitation_default_worker_type_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying
-- sql/220_invitation_default_worker_type_all_roles.sql.
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
--
-- Test map (mirrors the cross-platform behavioural checklist)
--   T1  Supervisor + worker type → invitation stores that worker type UUID
--   T2  Manager + worker type → worker type UUID retained
--   T3  Operator + worker type → existing behaviour still works
--   T4  Every role with NO worker type → allowed, worker_type_id is null
--       (operator invitations no longer require one)
--   T5  Invalid worker types are rejected for ANY role (deleted and
--       cross-vineyard), never silently nulled
--   T6  Accepting an invitation with a worker type gives the new member the
--       same worker_type_id via accept_invitation alone (no second write)
--   T7  Re-inviting the same email with a different worker type sends /
--       stores the new UUID (prior pending row cancelled)
--   T8  All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 220 invitation default worker type tests: ALL PASSED
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.create_invitation(uuid,text,text,uuid,timestamptz)') is null then
    raise exception 'create_invitation missing — apply sql/220 first.';
  end if;
end$$;

do $$
declare
  u_owner uuid; u_invitee uuid;
  v1 uuid := gen_random_uuid();          -- test vineyard
  v2 uuid := gen_random_uuid();          -- other vineyard (cross-vineyard fixture)
  wt_active uuid := gen_random_uuid();   -- active worker type in v1
  wt_second uuid := gen_random_uuid();   -- second active worker type in v1
  wt_deleted uuid := gen_random_uuid();  -- soft-deleted worker type in v1
  wt_foreign uuid := gen_random_uuid();  -- worker type in v2
  inv record;
  n integer;
  v_caught boolean;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't220-owner@test.local', 'x', now(), now(), now()),
         (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          't220-invitee@test.local', 'x', now(), now(), now());
  select id into u_owner from auth.users where email = 't220-owner@test.local';
  select id into u_invitee from auth.users where email = 't220-invitee@test.local';
  insert into public.profiles (id, email)
  values (u_owner, 't220-owner@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values (v1, 'T220 Vineyard'), (v2, 'T220 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values (v1, u_owner, 'owner');

  insert into public.worker_types (id, vineyard_id, name, cost_per_hour) values
    (wt_active, v1, 'T220 Vineyard Manager Type', 45),
    (wt_second, v1, 'T220 Second Type', 38),
    (wt_foreign, v2, 'T220 Foreign Type', 40);
  insert into public.worker_types (id, vineyard_id, name, cost_per_hour, deleted_at)
  values (wt_deleted, v1, 'T220 Deleted Type', 30, now());

  -- Act as the vineyard owner for all create_invitation calls.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated', 'email', 't220-owner@test.local')::text, true);

  -- ---- T1. Supervisor + worker type ---------------------------------------
  select * into inv from public.create_invitation(v1, 't220-sup@test.local', 'supervisor', wt_active, null);
  if inv.worker_type_id is distinct from wt_active then
    raise exception 'T1: supervisor invitation lost the worker type (got %)', inv.worker_type_id;
  end if;
  raise notice 'T1 passed';

  -- ---- T2. Manager + worker type ------------------------------------------
  select * into inv from public.create_invitation(v1, 't220-mgr@test.local', 'manager', wt_active, null);
  if inv.worker_type_id is distinct from wt_active then
    raise exception 'T2: manager invitation lost the worker type (got %)', inv.worker_type_id;
  end if;
  raise notice 'T2 passed';

  -- ---- T3. Operator + worker type (existing behaviour) --------------------
  select * into inv from public.create_invitation(v1, 't220-op@test.local', 'operator', wt_active, null);
  if inv.worker_type_id is distinct from wt_active then
    raise exception 'T3: operator invitation lost the worker type (got %)', inv.worker_type_id;
  end if;
  raise notice 'T3 passed';

  -- ---- T4. Every role, no worker type → allowed with null -----------------
  select * into inv from public.create_invitation(v1, 't220-sup-null@test.local', 'supervisor', null, null);
  if inv.worker_type_id is not null then raise exception 'T4: supervisor null case stored %', inv.worker_type_id; end if;
  select * into inv from public.create_invitation(v1, 't220-mgr-null@test.local', 'manager', null, null);
  if inv.worker_type_id is not null then raise exception 'T4: manager null case stored %', inv.worker_type_id; end if;
  select * into inv from public.create_invitation(v1, 't220-op-null@test.local', 'operator', null, null);
  if inv.worker_type_id is not null then raise exception 'T4: operator null case stored %', inv.worker_type_id; end if;
  raise notice 'T4 passed (operator no longer requires a worker type)';

  -- ---- T5. Invalid worker types rejected for ANY role ---------------------
  -- Deleted worker type, manager role.
  v_caught := false;
  begin
    perform public.create_invitation(v1, 't220-bad1@test.local', 'manager', wt_deleted, null);
  exception when others then
    v_caught := true;
    if position('Worker type not found' in sqlerrm) = 0 then
      raise exception 'T5: unexpected error for deleted worker type: %', sqlerrm;
    end if;
  end;
  if not v_caught then raise exception 'T5: deleted worker type was accepted for manager'; end if;

  -- Cross-vineyard worker type, supervisor role.
  v_caught := false;
  begin
    perform public.create_invitation(v1, 't220-bad2@test.local', 'supervisor', wt_foreign, null);
  exception when others then
    v_caught := true;
    if position('Worker type not found' in sqlerrm) = 0 then
      raise exception 'T5: unexpected error for cross-vineyard worker type: %', sqlerrm;
    end if;
  end;
  if not v_caught then raise exception 'T5: cross-vineyard worker type was accepted for supervisor'; end if;

  -- Nothing was silently inserted with a null worker type.
  select count(*) into n from public.invitations
  where vineyard_id = v1 and email in ('t220-bad1@test.local', 't220-bad2@test.local');
  if n <> 0 then raise exception 'T5: invalid worker type produced % invitation rows (silent retry?)', n; end if;
  raise notice 'T5 passed';

  -- ---- T6. Acceptance copies the worker type (no second write) ------------
  select * into inv from public.create_invitation(v1, 't220-invitee@test.local', 'supervisor', wt_active, null);
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_invitee, 'role', 'authenticated', 'email', 't220-invitee@test.local')::text, true);
  perform public.accept_invitation(inv.id);
  select count(*) into n from public.vineyard_members
  where vineyard_id = v1 and user_id = u_invitee and role = 'supervisor' and worker_type_id = wt_active;
  if n <> 1 then raise exception 'T6: accepted supervisor did not receive worker_type_id %', wt_active; end if;
  raise notice 'T6 passed';

  -- ---- T7. Different worker type on re-invite ------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated', 'email', 't220-owner@test.local')::text, true);
  select * into inv from public.create_invitation(v1, 't220-mgr@test.local', 'manager', wt_second, null);
  if inv.worker_type_id is distinct from wt_second then
    raise exception 'T7: re-invite did not store the new worker type (got %)', inv.worker_type_id;
  end if;
  select count(*) into n from public.invitations
  where vineyard_id = v1 and email = 't220-mgr@test.local' and status = 'pending';
  if n <> 1 then raise exception 'T7: expected exactly 1 pending row after re-invite, found %', n; end if;
  raise notice 'T7 passed';

  perform set_config('request.jwt.claims', '', true);
  raise notice 'SQL 220 invitation default worker type tests: ALL PASSED';
end$$;

rollback;

-- =====================================================================
-- 145_licence_pool_tests.sql — Phase 2C.1 global licence-pool tests
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/145 (and 143/144).
-- Everything runs inside ONE transaction that is ROLLED BACK — no
-- production data is touched. Expected final output:
--   NOTICE: SQL 145 licence pool tests: ALL PASSED
--
-- NOTE on concurrency: true parallel racing cannot run inside a single
-- transaction. The over-allocation guard is structural — a FOR UPDATE
-- row lock on the subscription plus an in-transaction seat recheck plus
-- the partial unique index uniq_vinetrack_user_licences_active_user.
-- T8 verifies the lock exists and the recheck rejects a full pool.
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.admin_available_licence_pools(text, uuid, text, uuid, boolean, integer, integer)') is null then
    raise exception 'SQL 145 not applied — run sql/145_global_admin_licence_pools.sql first.';
  end if;
end$$;

do $$
declare
  u_admin    uuid;
  u_owner    uuid;  -- team pool owner
  u_ent      uuid;  -- enterprise contract owner
  u_solo     uuid;  -- solo store subscriber
  u_member1  uuid;
  u_member2  uuid;
  plan_team  uuid;
  plan_ent   uuid;
  plan_solo  uuid;
  plan_internal uuid;
  s_team     uuid;
  s_ent      uuid;
  s_solo     uuid;
  s_internal uuid;
  s_expired  uuid;
  s_future   uuid;
  lic_id     uuid;
  n          bigint;
  r          record;
  ok         boolean;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't145-admin@test.local',   'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't145-owner@test.local',   'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't145-ent@test.local',     'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't145-solo@test.local',    'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't145-member1@test.local', 'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't145-member2@test.local', 'x', now(), now() - interval '1 year', now());
  select id into u_admin   from auth.users where email = 't145-admin@test.local';
  select id into u_owner   from auth.users where email = 't145-owner@test.local';
  select id into u_ent     from auth.users where email = 't145-ent@test.local';
  select id into u_solo    from auth.users where email = 't145-solo@test.local';
  select id into u_member1 from auth.users where email = 't145-member1@test.local';
  select id into u_member2 from auth.users where email = 't145-member2@test.local';

  select id into plan_team     from public.vinetrack_plans where code = 'team';
  select id into plan_ent      from public.vinetrack_plans where code = 'enterprise';
  select id into plan_solo     from public.vinetrack_plans where code = 'solo';
  select id into plan_internal from public.vinetrack_plans where code = 'internal_unlimited';
  if plan_team is null or plan_ent is null or plan_solo is null then
    raise exception 'plan catalogue missing team/enterprise/solo';
  end if;

  insert into public.system_admins (user_id, is_active) values (u_admin, true)
  on conflict do nothing;

  -- Team pool: 2 seats, active.
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included, seats_purchased,
     started_at, current_period_start, current_period_end)
  values (u_owner, plan_team, 'stripe', 'active', 2, 0,
          now() - interval '1 day', now() - interval '1 day', now() + interval '300 days')
  returning id into s_team;

  -- Enterprise contract (manual grant shape, SQL 141): 5 seats, open-ended.
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included,
     manual_grant_type, manual_grant_reason, started_at)
  values (u_ent, plan_ent, 'manual', 'manual', 5,
          'enterprise_contract', 'Test enterprise contract', now() - interval '1 day')
  returning id into s_ent;

  -- Solo Apple store subscription (must NEVER appear as a pool).
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     current_period_start, current_period_end, started_at, seats_included)
  values (u_solo, plan_solo, 'apple', 'ios', 'production', 'active',
          now() - interval '1 day', now() + interval '30 days', now() - interval '1 day', 1)
  returning id into s_solo;

  -- Internal Unlimited (must NEVER appear as a pool).
  if plan_internal is not null then
    insert into public.vinetrack_subscriptions
      (owner_user_id, plan_id, billing_provider, status, seats_included,
       unlimited_licences, manual_grant_type, manual_grant_reason, started_at)
    values (u_admin, plan_internal, 'manual', 'manual', 0,
            true, 'internal_unlimited', 'Test internal', now() - interval '1 day')
    returning id into s_internal;
  end if;

  -- Expired Team pool (period elapsed, no grace).
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included,
     started_at, current_period_start, current_period_end)
  values (u_owner, plan_team, 'stripe', 'active', 3,
          now() - interval '400 days', now() - interval '400 days', now() - interval '1 day')
  returning id into s_expired;

  -- Future-starting Team pool.
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included,
     started_at, current_period_start, current_period_end)
  values (u_owner, plan_team, 'stripe', 'active', 3,
          now() + interval '10 days', now() + interval '10 days', now() + interval '300 days')
  returning id into s_future;

  -- ---- T1. Non-admin cannot list pools -----------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner::text, 'role', 'authenticated')::text, true);
  ok := false;
  begin
    perform * from public.admin_available_licence_pools();
  exception when insufficient_privilege then
    ok := true;
  end;
  assert ok, 'T1: non-admin must get 42501';
  raise notice 'T1 passed: non-admin rejected';

  -- ---- T2. Admin sees team + enterprise pools; solo/apple/internal excluded
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);

  select count(*) into n from public.admin_available_licence_pools(p_limit => 200) p
  where p.subscription_id = s_team;
  assert n = 1, 'T2a: team pool listed';
  select count(*) into n from public.admin_available_licence_pools(p_limit => 200) p
  where p.subscription_id = s_ent;
  assert n = 1, 'T2b: enterprise contract pool listed';
  select count(*) into n from public.admin_available_licence_pools(p_limit => 200) p
  where p.subscription_id = s_solo;
  assert n = 0, 'T2c: solo Apple subscription must never be a pool';
  if s_internal is not null then
    select count(*) into n from public.admin_available_licence_pools(p_limit => 200) p
    where p.subscription_id = s_internal;
    assert n = 0, 'T2d: Internal Unlimited must never be a pool';
  end if;
  raise notice 'T2 passed: eligibility filter correct';

  -- ---- T3. Seat maths + billing_source -----------------------------------
  select * into r from public.admin_available_licence_pools(p_limit => 200) p
  where p.subscription_id = s_team;
  assert r.licence_limit = 2 and r.assigned_licences = 0 and r.available_licences = 2,
    'T3a: team pool 2 of 2 available';
  assert r.is_assignable = true and r.not_assignable_reason is null, 'T3b: assignable';
  assert r.billing_source = 'portal_subscription', 'T3c: billing_source portal_subscription';
  select * into r from public.admin_available_licence_pools(p_limit => 200) p
  where p.subscription_id = s_ent;
  assert r.billing_source = 'enterprise_contract', 'T3d: billing_source enterprise_contract';
  raise notice 'T3 passed: seat maths and billing_source';

  -- ---- T4. Expired / future pools are non-assignable ----------------------
  select * into r from public.admin_available_licence_pools(p_limit => 200) p
  where p.subscription_id = s_expired;
  assert r.is_assignable = false and r.not_assignable_reason = 'expired',
    'T4a: expired pool flagged';
  select * into r from public.admin_available_licence_pools(p_limit => 200) p
  where p.subscription_id = s_future;
  assert r.is_assignable = false and r.not_assignable_reason = 'not_started',
    'T4b: future pool flagged';
  raise notice 'T4 passed: expired/future pools non-assignable';

  -- ---- T5. Assignment from an available pool + access recalculation ------
  lic_id := public.admin_assign_licence(s_team, u_member1, 'Seat for member1');
  assert lic_id is not null, 'T5a: assignment returns licence id';
  select count(*) into n from public.vinetrack_user_licences
  where subscription_id = s_team and status = 'active';
  assert n = 1, 'T5b: one active licence';
  -- Recipient's effective access recalculated (licence outranks trial).
  select count(*) into n from public.vinetrack_entitlement_state es
  where es.user_id = u_member1 and es.has_access = true;
  assert n = 1, 'T5c: recipient entitlement state refreshed to granted';
  -- Audit record written.
  select count(*) into n from public.vinetrack_billing_events
  where subscription_id = s_team and event_type = 'licence_assigned';
  assert n = 1, 'T5d: licence_assigned audit event';
  raise notice 'T5 passed: assignment + recalculation + audit';

  -- ---- T6. Duplicate active assignment is idempotent (no extra seat) -----
  lic_id := public.admin_assign_licence(s_team, u_member1, 'Duplicate attempt');
  select count(*) into n from public.vinetrack_user_licences
  where subscription_id = s_team and user_id = u_member1;
  assert n = 1, 'T6: duplicate assignment reuses the same licence row';
  raise notice 'T6 passed: duplicate assignment cannot double-consume';

  -- ---- T7. Revoked assignments free their seat ----------------------------
  perform public.admin_remove_licence(lic_id, 'Freeing the seat');
  select * into r from public.admin_available_licence_pools(p_limit => 200) p
  where p.subscription_id = s_team;
  assert r.assigned_licences = 0 and r.available_licences = 2,
    'T7a: revoked licence does not consume a seat';
  -- Removal recalculates the recipient (back to trial-expired/denied etc.).
  select count(*) into n from public.vinetrack_billing_events
  where subscription_id = s_team and event_type = 'licence_removed';
  assert n = 1, 'T7b: licence_removed audit event';
  raise notice 'T7 passed: removal restores the seat and audits';

  -- ---- T8. Full pool rejects assignment (in-transaction recheck) ---------
  perform public.admin_assign_licence(s_team, u_member1, 'Seat 1');
  perform public.admin_assign_licence(s_team, u_member2, 'Seat 2');
  ok := false;
  begin
    perform public.admin_assign_licence(s_team, u_owner, 'Over-allocation attempt');
  exception when others then
    ok := (sqlerrm like '%no_seats_available%');
  end;
  assert ok, 'T8a: full pool must reject with no_seats_available';
  select count(*) into n from public.vinetrack_user_licences
  where subscription_id = s_team and status = 'active';
  assert n = 2, 'T8b: capacity never exceeded';
  -- The FOR UPDATE lock is the concurrency guard; verify it is present in
  -- the function definition (structural assertion).
  assert (select prosrc from pg_proc where proname = 'admin_assign_licence'
          and pronamespace = 'public'::regnamespace) ilike '%for update%',
    'T8c: admin_assign_licence must lock the pool row (FOR UPDATE)';
  raise notice 'T8 passed: full pool rejected; row lock present';

  -- ---- T9. Assignment on expired / future / store pools rejected ---------
  ok := false;
  begin
    perform public.admin_assign_licence(s_expired, u_member1, 'Expired pool attempt');
  exception when others then
    ok := (sqlerrm like '%pool_expired%');
  end;
  assert ok, 'T9a: expired pool rejects with pool_expired';
  ok := false;
  begin
    perform public.admin_assign_licence(s_future, u_member1, 'Future pool attempt');
  exception when others then
    ok := (sqlerrm like '%pool_not_started%');
  end;
  assert ok, 'T9b: future pool rejects with pool_not_started';
  ok := false;
  begin
    perform public.admin_assign_licence(s_solo, u_member1, 'Store sub attempt');
  exception when others then
    ok := (sqlerrm like '%store_subscription_not_licence_assignable%');
  end;
  assert ok, 'T9c: store subscription rejects assignment';
  raise notice 'T9 passed: expired/future/store pools reject assignment';

  -- ---- T10. Reason is mandatory -------------------------------------------
  ok := false;
  begin
    perform public.admin_assign_licence(s_ent, u_member1, '   ');
  exception when others then
    ok := (sqlerrm like '%reason_required%');
  end;
  assert ok, 'T10: empty reason rejected';
  raise notice 'T10 passed: reason required';

  -- ---- T11. p_has_available_seats filter ----------------------------------
  perform public.admin_assign_licence(s_ent, u_member1, 'Ent seat 1');
  select count(*) into n
  from public.admin_available_licence_pools(p_has_available_seats => true, p_limit => 200) p
  where p.subscription_id = s_team;
  assert n = 0, 'T11a: full team pool excluded by available-seats filter';
  select count(*) into n
  from public.admin_available_licence_pools(p_has_available_seats => true, p_limit => 200) p
  where p.subscription_id = s_ent;
  assert n = 1, 'T11b: enterprise pool (4 of 5 free) included';
  raise notice 'T11 passed: available-seats filter';

  -- ---- T12. Search + owner filter -----------------------------------------
  select count(*) into n
  from public.admin_available_licence_pools(p_search => 't145-ent@test.local', p_limit => 200) p
  where p.subscription_id = s_ent;
  assert n = 1, 'T12a: search by owner email';
  select count(*) into n
  from public.admin_available_licence_pools(p_billing_owner_user_id => u_owner, p_limit => 200) p
  where p.subscription_id in (s_team, s_expired, s_future);
  assert n = 3, 'T12b: owner filter returns all of the owner''s pools';
  raise notice 'T12 passed: search and owner filters';

  raise notice 'SQL 145 licence pool tests: ALL PASSED';
end$$;

rollback;

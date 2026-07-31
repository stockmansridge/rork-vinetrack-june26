-- =====================================================================
-- 157_solo_vs_team_funding_tests.sql — Phase 2F.1 rollback-only tests
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/155, sql/156 and
-- sql/157. Everything runs inside ONE transaction that is ROLLED BACK —
-- no production data is touched. Expected final output:
--   NOTICE: SQL 157 Solo vs Team vineyard funding tests: ALL PASSED
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public._plan_funds_vineyard(text, text, text)') is null
     or to_regprocedure('public._vineyard_owner_ids(uuid)') is null then
    raise exception 'SQL 157 not applied — run sql/157_solo_vs_team_vineyard_funding.sql first.';
  end if;
end$$;

do $$
declare
  u_admin    uuid;  -- System Admin
  u_solo     uuid;  -- owns vS — ACTIVE Solo subscription, trial expired
  u_smgr     uuid;  -- manager  vS — must NOT inherit Solo
  u_sop      uuid;  -- operator vS — must NOT inherit Solo
  u_trialown uuid;  -- owns vT — ACTIVE account trial (created 1 month ago)
  u_tmem     uuid;  -- operator vT — inherits the Owner trial
  u_teamown  uuid;  -- owns vTeam (anchored Team) and vTeam2 (unanchored)
  u_teammem  uuid;  -- manager  vTeam
  u_team2mem uuid;  -- manager  vTeam2
  u_entown   uuid;  -- owns vEnt — Enterprise subscription (unanchored)
  u_entmem   uuid;  -- operator vEnt
  u_lic      uuid;  -- ASSIGNED licence on the Team sub; owns vLic
  u_licmem   uuid;  -- operator vLic — must NOT inherit an assigned licence
  u_gowner   uuid;  -- owns vG + vUG — no entitlement of their own
  u_gmem     uuid;  -- operator vG  — vineyard-wide grant
  u_ug1      uuid;  -- operator vUG — USER-scoped grant target
  u_ug2      uuid;  -- operator vUG — must NOT inherit the user grant
  u_expsolo  uuid;  -- EXPIRED Solo; also a member of the funded vTeam

  v_s uuid; v_t uuid; v_team uuid; v_team2 uuid; v_ent uuid;
  v_lic uuid; v_g uuid; v_ug uuid;

  plan_solo uuid; plan_team uuid; plan_ent uuid;
  s_solo uuid; s_team uuid; s_team2 uuid; s_ent uuid; s_expsolo uuid;
  g_vineyard uuid; g_user uuid;

  r  record;
  ve record;
  j  jsonb;
  x  jsonb;
  ok boolean;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-admin@test.local',    'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-solo@test.local',     'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-smgr@test.local',     'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-sop@test.local',      'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-trialown@test.local', 'x', now(), now() - interval '1 month',  now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-tmem@test.local',     'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-teamown@test.local',  'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-teammem@test.local',  'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-team2mem@test.local', 'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-entown@test.local',   'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-entmem@test.local',   'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-lic@test.local',      'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-licmem@test.local',   'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-gowner@test.local',   'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-gmem@test.local',     'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-ug1@test.local',      'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-ug2@test.local',      'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't157-expsolo@test.local',  'x', now(), now() - interval '2 years', now());

  select id into u_admin    from auth.users where email = 't157-admin@test.local';
  select id into u_solo     from auth.users where email = 't157-solo@test.local';
  select id into u_smgr     from auth.users where email = 't157-smgr@test.local';
  select id into u_sop      from auth.users where email = 't157-sop@test.local';
  select id into u_trialown from auth.users where email = 't157-trialown@test.local';
  select id into u_tmem     from auth.users where email = 't157-tmem@test.local';
  select id into u_teamown  from auth.users where email = 't157-teamown@test.local';
  select id into u_teammem  from auth.users where email = 't157-teammem@test.local';
  select id into u_team2mem from auth.users where email = 't157-team2mem@test.local';
  select id into u_entown   from auth.users where email = 't157-entown@test.local';
  select id into u_entmem   from auth.users where email = 't157-entmem@test.local';
  select id into u_lic      from auth.users where email = 't157-lic@test.local';
  select id into u_licmem   from auth.users where email = 't157-licmem@test.local';
  select id into u_gowner   from auth.users where email = 't157-gowner@test.local';
  select id into u_gmem     from auth.users where email = 't157-gmem@test.local';
  select id into u_ug1      from auth.users where email = 't157-ug1@test.local';
  select id into u_ug2      from auth.users where email = 't157-ug2@test.local';
  select id into u_expsolo  from auth.users where email = 't157-expsolo@test.local';

  insert into public.profiles (id, email, full_name)
  select u.id, u.email, 'T157 ' || split_part(u.email, '@', 1)
  from auth.users u where u.email like 't157-%@test.local'
  on conflict (id) do nothing;

  insert into public.system_admins (user_id, is_active) values (u_admin, true)
  on conflict do nothing;

  insert into public.vineyards (id, name, owner_id) values
    (gen_random_uuid(), 'T157 Solo vineyard',        u_solo),
    (gen_random_uuid(), 'T157 Trial vineyard',       u_trialown),
    (gen_random_uuid(), 'T157 Team vineyard',        u_teamown),
    (gen_random_uuid(), 'T157 Team vineyard two',    u_teamown),
    (gen_random_uuid(), 'T157 Enterprise vineyard',  u_entown),
    (gen_random_uuid(), 'T157 Licensee vineyard',    u_lic),
    (gen_random_uuid(), 'T157 Granted vineyard',     u_gowner),
    (gen_random_uuid(), 'T157 User grant vineyard',  u_gowner);
  select id into v_s     from public.vineyards where name = 'T157 Solo vineyard';
  select id into v_t     from public.vineyards where name = 'T157 Trial vineyard';
  select id into v_team  from public.vineyards where name = 'T157 Team vineyard';
  select id into v_team2 from public.vineyards where name = 'T157 Team vineyard two';
  select id into v_ent   from public.vineyards where name = 'T157 Enterprise vineyard';
  select id into v_lic   from public.vineyards where name = 'T157 Licensee vineyard';
  select id into v_g     from public.vineyards where name = 'T157 Granted vineyard';
  select id into v_ug    from public.vineyards where name = 'T157 User grant vineyard';

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_s,     u_solo,     'owner'),   (v_s,     u_smgr,     'manager'),
    (v_s,     u_sop,      'operator'),
    (v_t,     u_trialown, 'owner'),   (v_t,     u_tmem,     'operator'),
    (v_team,  u_teamown,  'owner'),   (v_team,  u_teammem,  'manager'),
    (v_team,  u_expsolo,  'operator'),
    (v_team2, u_teamown,  'owner'),   (v_team2, u_team2mem, 'manager'),
    (v_ent,   u_entown,   'owner'),   (v_ent,   u_entmem,   'operator'),
    (v_lic,   u_lic,      'owner'),   (v_lic,   u_licmem,   'operator'),
    (v_g,     u_gowner,   'owner'),   (v_g,     u_gmem,     'operator'),
    (v_ug,    u_gowner,   'owner'),   (v_ug,    u_ug1,      'operator'),
    (v_ug,    u_ug2,      'operator');

  select id into plan_solo from public.vinetrack_plans where code = 'solo';
  select id into plan_team from public.vinetrack_plans where code = 'team';
  select id into plan_ent  from public.vinetrack_plans where code = 'enterprise';
  if plan_solo is null or plan_team is null or plan_ent is null then
    raise exception 'plan catalogue missing solo/team/enterprise';
  end if;

  -- ACTIVE Solo subscription, anchored (informationally) to the Solo vineyard.
  insert into public.vinetrack_subscriptions
    (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
     seats_included, started_at, current_period_start, current_period_end)
  values (u_solo, v_s, plan_solo, 'stripe', 'active', 1,
          now() - interval '1 day', now() - interval '1 day', now() + interval '300 days')
  returning id into s_solo;

  -- ACTIVE Team subscription ANCHORED to the Team vineyard (5 seats).
  insert into public.vinetrack_subscriptions
    (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
     seats_included, started_at, current_period_start, current_period_end)
  values (u_teamown, v_team, plan_team, 'stripe', 'active', 5,
          now() - interval '1 day', now() - interval '1 day', now() + interval '300 days')
  returning id into s_team;

  -- ACTIVE Team subscription with NO anchor (owner-backed funding path).
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status,
     seats_included, started_at, current_period_start, current_period_end)
  values (u_teamown, plan_team, 'stripe', 'active', 5,
          now() - interval '1 day', now() - interval '1 day', now() + interval '300 days')
  returning id into s_team2;

  -- ACTIVE Enterprise subscription with NO anchor.
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status,
     seats_included, started_at, current_period_start, current_period_end)
  values (u_entown, plan_ent, 'stripe', 'active', 25,
          now() - interval '1 day', now() - interval '1 day', now() + interval '300 days')
  returning id into s_ent;

  -- EXPIRED Solo subscription (own entitlement gone).
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status,
     seats_included, started_at, current_period_start, current_period_end)
  values (u_expsolo, plan_solo, 'stripe', 'active', 1,
          now() - interval '400 days', now() - interval '400 days', now() - interval '30 days')
  returning id into s_expsolo;

  -- ASSIGNED licence on the anchored Team subscription for u_lic.
  insert into public.vinetrack_user_licences
    (subscription_id, user_id, vineyard_id, status, assigned_by)
  values (s_team, u_lic, v_team, 'active', u_teamown);

  -- =======================================================================
  -- T1. Solo Owner can enter their OWN vineyard.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_solo::text, 'role', 'authenticated',
                      'email', 't157-solo@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true, 'T1a: Solo owner has access';
  assert public._plan_funds_vineyard(r.plan_code, r.plan_tier, r.billing_provider) = false,
    'T1b: the Solo plan is not a vineyard-funding plan';

  j := public.get_my_vineyard_access_matrix();
  select v into x from jsonb_array_elements(j->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_s;
  assert (x->>'has_vineyard_access')::boolean = true,
    'T1c: Solo owner can enter their vineyard';
  assert x->>'vineyard_access_source' = 'account',
    'T1d: entry is funded by their own account, not the vineyard';
  raise notice 'T1 passed: Solo Owner enters their own vineyard';

  -- =======================================================================
  -- T2/T3. Solo NEVER funds the Manager or the Operator.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_smgr::text, 'role', 'authenticated',
                      'email', 't157-smgr@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false,
    'T2a: Manager does NOT inherit the Owner''s Solo subscription';
  j := public.get_my_vineyard_access_matrix();
  select v into x from jsonb_array_elements(j->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_s;
  assert (x->>'has_vineyard_access')::boolean = false, 'T2b: matrix row denied';
  assert x->>'vineyard_access_reason' = 'owner_plan_not_vineyard_funding',
    'T2c: reason explains the Owner plan is user-only';
  assert j->'account'->>'account_access_state' = 'restricted',
    'T2d: restricted account state (not signed out, invitations preserved)';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_sop::text, 'role', 'authenticated',
                      'email', 't157-sop@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false,
    'T3a: Operator does NOT inherit the Owner''s Solo subscription';
  raise notice 'T2/T3 passed: Solo does not fund Manager or Operator';

  -- =======================================================================
  -- T4. Solo entitlement never appears as vineyard FUNDING.
  -- =======================================================================
  select * into ve from public._vineyard_entitlement_for(v_s);
  assert ve.has_entitlement = false, 'T4a: Solo vineyard is unfunded';
  assert ve.access_source = 'none',  'T4b: no funding source';
  assert ve.reason_code = 'owner_plan_not_vineyard_funding',
    'T4c: funding reason distinguishes user-only Owner entitlement';
  assert public._plan_funds_vineyard('solo', 'solo', 'stripe') = false,
    'T4d: solo plan predicate false';
  assert public._plan_funds_vineyard('legacy_monthly', 'legacy', 'apple') = false,
    'T4e: legacy single-user store plan predicate false';
  assert public._plan_funds_vineyard('team', 'team', 'stripe') = true,
    'T4f: team plan predicate true';
  assert public._plan_funds_vineyard('enterprise', 'enterprise', 'stripe') = true,
    'T4g: enterprise plan predicate true';
  assert public._plan_funds_vineyard('internal_unlimited', 'internal', 'manual') = false,
    'T4h: manual grants fund only through explicit vineyard scope';
  raise notice 'T4 passed: Solo never appears as vineyard funding';

  -- =======================================================================
  -- T5. Active Owner ACCOUNT TRIAL still funds active members.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_tmem::text, 'role', 'authenticated',
                      'email', 't157-tmem@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.access_source = 'vineyard',
    'T5a: member evaluates under the Owner account trial';
  assert r.vineyard_id = v_t, 'T5b: funded vineyard returned';
  j := public.get_my_vineyard_access_matrix();
  select v into x from jsonb_array_elements(j->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_t;
  assert x->>'vineyard_access_source' = 'owner_trial', 'T5c: source owner_trial';
  assert (x->>'is_trial')::boolean = true,             'T5d: flagged as trial';
  raise notice 'T5 passed: Owner account trial funds members';

  -- =======================================================================
  -- T6. Team subscription funds members (anchored AND owner-backed).
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_teammem::text, 'role', 'authenticated',
                      'email', 't157-teammem@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.access_source = 'vineyard',
    'T6a: Team member has vineyard-backed access';
  j := public.get_my_vineyard_access_matrix();
  select v into x from jsonb_array_elements(j->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_team;
  assert x->>'vineyard_access_source' = 'vineyard_subscription',
    'T6b: anchored Team subscription funds the vineyard';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_team2mem::text, 'role', 'authenticated',
                      'email', 't157-team2mem@test.local')::text, true);
  j := public.get_my_vineyard_access(v_team2);
  assert (j->>'has_vineyard_access')::boolean = true,
    'T6c: unanchored Team subscription funds the Owner''s vineyard';
  assert j->>'vineyard_access_source' = 'owner_subscription',
    'T6d: source owner_subscription';
  raise notice 'T6 passed: Team subscription funds members';

  -- =======================================================================
  -- T7. Enterprise subscription funds members.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_entmem::text, 'role', 'authenticated',
                      'email', 't157-entmem@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.access_source = 'vineyard',
    'T7a: Enterprise member has access';
  j := public.get_my_vineyard_access(v_ent);
  assert j->>'vineyard_access_source' = 'owner_subscription',
    'T7b: Enterprise Owner subscription funds the vineyard';
  raise notice 'T7 passed: Enterprise subscription funds members';

  -- =======================================================================
  -- T8. An ASSIGNED licence entitles only its assignee.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_lic::text, 'role', 'authenticated',
                      'email', 't157-lic@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.reason_code = 'assigned_licence',
    'T8a: licensee has their own access';
  j := public.get_my_vineyard_access(v_lic);
  assert (j->>'has_vineyard_access')::boolean = true
     and j->>'vineyard_access_source' = 'account',
    'T8b: licensee enters their own vineyard on their own entitlement';

  select * into ve from public._vineyard_entitlement_for(v_lic);
  assert ve.has_entitlement = false,
    'T8c: an assigned licence does NOT fund the licensee''s vineyard';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_licmem::text, 'role', 'authenticated',
                      'email', 't157-licmem@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false,
    'T8d: the licensee''s Operator inherits nothing';
  raise notice 'T8 passed: assigned licence grants only its assignee';

  -- =======================================================================
  -- T9. Vineyard-wide grant funds ALL active members.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated',
                      'email', 't157-admin@test.local')::text, true);
  g_vineyard := public.admin_create_billing_grant(
    u_gowner, 'complimentary_team', 'Phase 2F.1 vineyard-wide test',
    null, null, v_g, 'vineyard');
  assert g_vineyard is not null, 'T9a: vineyard-scoped grant created';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_gmem::text, 'role', 'authenticated',
                      'email', 't157-gmem@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.access_source = 'vineyard',
    'T9b: every active member inherits the vineyard-wide grant';
  j := public.get_my_vineyard_access(v_g);
  assert j->>'vineyard_access_source' = 'vineyard_grant',
    'T9c: source vineyard_grant';
  assert (j->>'is_vineyard_wide')::boolean = true, 'T9d: flagged vineyard-wide';
  raise notice 'T9 passed: vineyard-wide grant funds all active members';

  -- =======================================================================
  -- T10. USER-scoped grant funds only the target user.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated',
                      'email', 't157-admin@test.local')::text, true);
  g_user := public.admin_create_billing_grant(
    u_ug1, 'internal_unlimited', 'Phase 2F.1 user-scoped test',
    null, null, v_ug, 'user');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_ug1::text, 'role', 'authenticated',
                      'email', 't157-ug1@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.reason_code = 'internal_unlimited',
    'T10a: user-scoped grant grants its target';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_ug2::text, 'role', 'authenticated',
                      'email', 't157-ug2@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false,
    'T10b: a fellow member never inherits a user-scoped grant';
  raise notice 'T10 passed: user-scoped grant targets one account';

  -- =======================================================================
  -- T11. An EXPIRED Solo never affects another active vineyard.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_expsolo::text, 'role', 'authenticated',
                      'email', 't157-expsolo@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.access_source = 'vineyard'
     and r.vineyard_id = v_team,
    'T11a: expired Solo still enters the Team-funded vineyard';
  j := public.get_my_vineyard_access_matrix();
  assert j->'account'->>'account_access_state' = 'vineyard_only',
    'T11b: vineyard_only state (never a global paywall)';
  assert (j->'account'->>'accessible_vineyard_count')::int = 1,
    'T11c: exactly the funded vineyard is accessible';
  raise notice 'T11 passed: expired Solo does not block a funded vineyard';

  -- =======================================================================
  -- T12. Matrix, single-vineyard RPC and admin diagnostics agree.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_smgr::text, 'role', 'authenticated',
                      'email', 't157-smgr@test.local')::text, true);
  j := public.get_my_vineyard_access(v_s);
  select v into x from jsonb_array_elements(
    public.get_my_vineyard_access_matrix()->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_s;
  assert (j->>'has_vineyard_access') = (x->>'has_vineyard_access')
     and (j->>'vineyard_access_reason') = (x->>'vineyard_access_reason')
     and (j->>'vineyard_access_source') = (x->>'vineyard_access_source'),
    'T12a: single-vineyard RPC matches the matrix row';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated',
                      'email', 't157-admin@test.local')::text, true);
  j := public.admin_explain_vineyard_access(u_smgr, v_s);
  assert (j->'decision'->>'has_vineyard_access')::boolean = false
     and j->'decision'->>'reason_code' = x->>'vineyard_access_reason'
     and j->'decision'->>'access_source' = x->>'vineyard_access_source',
    'T12b: admin diagnostics match the member''s matrix row';
  assert j->'vineyard_entitlement'->>'funding_reason_code'
         = 'owner_plan_not_vineyard_funding',
    'T12c: diagnostics name the Solo funding gap';
  assert (j->'account_access'->>'plan_funds_vineyard')::boolean = false,
    'T12d: member plan cannot fund a vineyard';

  j := public.admin_explain_vineyard_access(u_solo, v_s);
  assert (j->'decision'->>'has_vineyard_access')::boolean = true
     and (j->'decision'->>'account_funds_vineyard')::boolean = true,
    'T12e: the Solo Owner enters on their own account entitlement';
  assert jsonb_array_length(j->'inheriting_members') = 0,
    'T12f: nobody inherits a Solo subscription';

  j := public.admin_explain_vineyard_access(u_gmem, v_g);
  assert jsonb_array_length(j->'inheriting_members') >= 2,
    'T12g: vineyard-wide grant lists inheriting members';
  raise notice 'T12 passed: matrix, single RPC and diagnostics agree';

  -- =======================================================================
  -- T13. Non-admins still cannot read the diagnostics.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_smgr::text, 'role', 'authenticated',
                      'email', 't157-smgr@test.local')::text, true);
  ok := false;
  begin
    perform public.admin_explain_vineyard_access(u_solo, v_s);
  exception when insufficient_privilege then
    ok := true;
  end;
  assert ok, 'T13a: non-admin diagnostics rejected';
  raise notice 'T13 passed: diagnostics remain System Admin only';

  raise notice 'SQL 157 Solo vs Team vineyard funding tests: ALL PASSED';
end$$;

rollback;

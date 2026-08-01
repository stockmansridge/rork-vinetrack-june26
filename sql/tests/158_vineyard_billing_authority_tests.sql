-- =====================================================================
-- 158_vineyard_billing_authority_tests.sql — Phase 2F.2 rollback-only tests
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/155, 156, 157 and 158.
-- Everything runs inside ONE transaction that is ROLLED BACK at the end —
-- no production data is created, changed or deleted.
--
-- Covers the additive presentation key returned by
--   get_my_vineyard_access_matrix()
--   get_my_vineyard_access(p_vineyard_id)
--
--   is_billing_authority
--     = membership_role = 'owner'
--       AND ( I am the vineyard's owner of record (vineyards.owner_id)
--             OR I own the entitlement currently funding the vineyard )
--
-- Test map
--   T1  Vineyard owner of record            -> true
--   T2  Co-Owner without subscription       -> false
--   T3  Owner of the active funding sub     -> true (not owner of record)
--   T4  Co-Owner never learns WHO the billing authority is
--   T5  Manager                             -> false
--   T6  Supervisor                          -> false
--   T7  Operator                            -> false
--   T8  Assigned-licence holder             -> false (true only where they
--                                              independently satisfy the rule)
--   T9  Vineyard-scoped grant does NOT make every Owner an authority
--   T10 User-scoped grant does not affect billing authority
--   T11 Team subscription: only its owner (plus owner of record) -> true
--   T12 Enterprise subscription follows the same rule
--   T13 Expired / revoked funding never creates billing authority
--   T14 Matrix and single-vineyard RPC always agree
--   T15 Pre-existing keys and access decisions are unchanged
--   T16 Anonymous callers rejected
--   T17 Non-members cannot read vineyard authority details
--   T18 All test data rolled back
--
-- Expected final output:
--   NOTICE: SQL 158 vineyard billing authority tests: ALL PASSED
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.get_my_vineyard_access_matrix()') is null
     or to_regprocedure('public.get_my_vineyard_access(uuid)') is null
     or to_regprocedure('public._vineyard_entitlement_for(uuid)') is null then
    raise exception 'SQL 158 not applied — run sql/158_vineyard_billing_authority.sql first.';
  end if;
end$$;

do $$
declare
  u_admin    uuid;  -- System Admin
  -- vA: funded Team vineyard, owner of record ALSO owns the subscription
  u_owner    uuid;  -- owner of record of vA + owns the funding Team sub
  u_coown    uuid;  -- co-Owner of vA, owns nothing
  u_mgr      uuid;  -- manager    vA
  u_sup      uuid;  -- supervisor vA
  u_op       uuid;  -- operator   vA
  u_lic      uuid;  -- operator   vA with an ASSIGNED licence; owner of vLic
  -- vB: funded by a co-Owner who is NOT the owner of record
  u_bowner   uuid;  -- owner of record of vB, owns nothing
  u_funder   uuid;  -- co-Owner of vB, owns the funding Team subscription
  u_bco      uuid;  -- co-Owner of vB, owns nothing
  u_bop      uuid;  -- operator   vB
  -- vE: Enterprise, funded by a co-Owner
  u_eowner   uuid;  -- owner of record of vE
  u_efunder  uuid;  -- co-Owner of vE, owns the Enterprise subscription
  u_eop      uuid;  -- operator   vE
  -- vG: vineyard-scoped grant
  u_gowner   uuid;  -- owner of record of vG (grant anchor)
  u_gco      uuid;  -- co-Owner of vG
  u_gop      uuid;  -- operator   vG
  -- vU: user-scoped grant
  u_uowner   uuid;  -- owner of record of vU
  u_uco      uuid;  -- co-Owner of vU, target of a USER-scoped grant
  u_uop      uuid;  -- operator   vU
  -- vX: expired funding
  u_xowner   uuid;  -- owner of record of vX
  u_xco      uuid;  -- co-Owner of vX, owns an EXPIRED Team subscription
  u_outside  uuid;  -- member of nothing

  v_a uuid; v_b uuid; v_e uuid; v_g uuid; v_u uuid; v_x uuid; v_lic uuid;

  plan_team uuid; plan_ent uuid;
  s_a uuid; s_b uuid; s_e uuid; s_x uuid;
  g_vineyard uuid; g_user uuid;

  j  jsonb;     -- single-vineyard RPC payload
  m  jsonb;     -- matrix payload
  x  jsonb;     -- one matrix row
  ve record;    -- _vineyard_entitlement_for row (funding source of truth)
  ok boolean;
  keys text[] := array[
    'vineyard_id', 'vineyard_name', 'membership_role', 'membership_status',
    'has_vineyard_access', 'vineyard_access_reason', 'vineyard_access_source',
    'plan_code', 'subscription_status', 'starts_at', 'expires_at', 'is_trial',
    'is_vineyard_wide', 'is_billing_owner', 'can_manage_billing',
    'is_billing_authority', 'can_enter_vineyard', 'requires_billing_attention',
    'last_verified_at'
  ];
begin
  -- =======================================================================
  -- Fixtures. Every account is created 2 years ago so that NO account trial
  -- is active — billing authority must be proven by subscriptions/ownership.
  -- =======================================================================
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now() - interval '2 years', now()
  from unnest(array[
    't158-admin@test.local',
    't158-owner@test.local',   't158-coown@test.local',  't158-mgr@test.local',
    't158-sup@test.local',     't158-op@test.local',     't158-lic@test.local',
    't158-bowner@test.local',  't158-funder@test.local','t158-bco@test.local',
    't158-bop@test.local',
    't158-eowner@test.local',  't158-efunder@test.local','t158-eop@test.local',
    't158-gowner@test.local',  't158-gco@test.local',    't158-gop@test.local',
    't158-uowner@test.local',  't158-uco@test.local',    't158-uop@test.local',
    't158-xowner@test.local',  't158-xco@test.local',
    't158-outside@test.local'
  ]) e;

  select id into u_admin   from auth.users where email = 't158-admin@test.local';
  select id into u_owner   from auth.users where email = 't158-owner@test.local';
  select id into u_coown   from auth.users where email = 't158-coown@test.local';
  select id into u_mgr     from auth.users where email = 't158-mgr@test.local';
  select id into u_sup     from auth.users where email = 't158-sup@test.local';
  select id into u_op      from auth.users where email = 't158-op@test.local';
  select id into u_lic     from auth.users where email = 't158-lic@test.local';
  select id into u_bowner  from auth.users where email = 't158-bowner@test.local';
  select id into u_funder  from auth.users where email = 't158-funder@test.local';
  select id into u_bco     from auth.users where email = 't158-bco@test.local';
  select id into u_bop     from auth.users where email = 't158-bop@test.local';
  select id into u_eowner  from auth.users where email = 't158-eowner@test.local';
  select id into u_efunder from auth.users where email = 't158-efunder@test.local';
  select id into u_eop     from auth.users where email = 't158-eop@test.local';
  select id into u_gowner  from auth.users where email = 't158-gowner@test.local';
  select id into u_gco     from auth.users where email = 't158-gco@test.local';
  select id into u_gop     from auth.users where email = 't158-gop@test.local';
  select id into u_uowner  from auth.users where email = 't158-uowner@test.local';
  select id into u_uco     from auth.users where email = 't158-uco@test.local';
  select id into u_uop     from auth.users where email = 't158-uop@test.local';
  select id into u_xowner  from auth.users where email = 't158-xowner@test.local';
  select id into u_xco     from auth.users where email = 't158-xco@test.local';
  select id into u_outside from auth.users where email = 't158-outside@test.local';

  insert into public.profiles (id, email, full_name)
  select u.id, u.email, 'T158 ' || split_part(u.email, '@', 1)
  from auth.users u where u.email like 't158-%@test.local'
  on conflict (id) do nothing;

  insert into public.system_admins (user_id, is_active) values (u_admin, true)
  on conflict do nothing;

  insert into public.vineyards (id, name, owner_id) values
    (gen_random_uuid(), 'T158 Authority vineyard',   u_owner),
    (gen_random_uuid(), 'T158 Co-funded vineyard',   u_bowner),
    (gen_random_uuid(), 'T158 Enterprise vineyard',  u_eowner),
    (gen_random_uuid(), 'T158 Granted vineyard',     u_gowner),
    (gen_random_uuid(), 'T158 User grant vineyard',  u_uowner),
    (gen_random_uuid(), 'T158 Expired vineyard',     u_xowner),
    (gen_random_uuid(), 'T158 Licensee vineyard',    u_lic);
  select id into v_a   from public.vineyards where name = 'T158 Authority vineyard';
  select id into v_b   from public.vineyards where name = 'T158 Co-funded vineyard';
  select id into v_e   from public.vineyards where name = 'T158 Enterprise vineyard';
  select id into v_g   from public.vineyards where name = 'T158 Granted vineyard';
  select id into v_u   from public.vineyards where name = 'T158 User grant vineyard';
  select id into v_x   from public.vineyards where name = 'T158 Expired vineyard';
  select id into v_lic from public.vineyards where name = 'T158 Licensee vineyard';

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_a,   u_owner,   'owner'),  (v_a,   u_coown,   'owner'),
    (v_a,   u_mgr,     'manager'),(v_a,   u_sup,     'supervisor'),
    (v_a,   u_op,      'operator'),(v_a,  u_lic,     'operator'),
    (v_b,   u_bowner,  'owner'),  (v_b,   u_funder,  'owner'),
    (v_b,   u_bco,     'owner'),  (v_b,   u_bop,     'operator'),
    (v_e,   u_eowner,  'owner'),  (v_e,   u_efunder, 'owner'),
    (v_e,   u_eop,     'operator'),
    (v_g,   u_gowner,  'owner'),  (v_g,   u_gco,     'owner'),
    (v_g,   u_gop,     'operator'),
    (v_u,   u_uowner,  'owner'),  (v_u,   u_uco,     'owner'),
    (v_u,   u_uop,     'operator'),
    (v_x,   u_xowner,  'owner'),  (v_x,   u_xco,     'owner'),
    (v_lic, u_lic,     'owner');

  select id into plan_team from public.vinetrack_plans where code = 'team';
  select id into plan_ent  from public.vinetrack_plans where code = 'enterprise';
  if plan_team is null or plan_ent is null then
    raise exception 'plan catalogue missing team/enterprise';
  end if;

  -- vA: ACTIVE Team subscription owned by the owner of record, anchored to vA.
  insert into public.vinetrack_subscriptions
    (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
     seats_included, started_at, current_period_start, current_period_end)
  values (u_owner, v_a, plan_team, 'stripe', 'active', 5,
          now() - interval '1 day', now() - interval '1 day', now() + interval '300 days')
  returning id into s_a;

  -- vB: ACTIVE Team subscription owned by a CO-OWNER, anchored to vB.
  insert into public.vinetrack_subscriptions
    (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
     seats_included, started_at, current_period_start, current_period_end)
  values (u_funder, v_b, plan_team, 'stripe', 'active', 5,
          now() - interval '1 day', now() - interval '1 day', now() + interval '300 days')
  returning id into s_b;

  -- vE: ACTIVE Enterprise subscription owned by a CO-OWNER, NOT anchored
  --     (funds through the Owner-subscription path).
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status,
     seats_included, started_at, current_period_start, current_period_end)
  values (u_efunder, plan_ent, 'stripe', 'active', 25,
          now() - interval '1 day', now() - interval '1 day', now() + interval '300 days')
  returning id into s_e;

  -- vX: EXPIRED Team subscription owned by a co-Owner, anchored to vX.
  insert into public.vinetrack_subscriptions
    (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
     seats_included, started_at, current_period_start, current_period_end)
  values (u_xco, v_x, plan_team, 'stripe', 'active', 5,
          now() - interval '400 days', now() - interval '400 days', now() - interval '30 days')
  returning id into s_x;

  -- ASSIGNED licence for u_lic on the vA Team subscription.
  insert into public.vinetrack_user_licences
    (subscription_id, user_id, vineyard_id, status, assigned_by)
  values (s_a, u_lic, v_a, 'active', u_owner);

  -- Manual grants (System Admin context).
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated',
                      'email', 't158-admin@test.local')::text, true);
  g_vineyard := public.admin_create_billing_grant(
    u_gowner, 'complimentary_team', 'SQL 158 vineyard-scope authority test',
    null, null, v_g, 'vineyard');
  g_user := public.admin_create_billing_grant(
    u_uco, 'internal_unlimited', 'SQL 158 user-scope authority test',
    null, null, v_u, 'user');
  assert g_vineyard is not null and g_user is not null, 'fixture: grants created';

  -- =======================================================================
  -- T1. The vineyard OWNER OF RECORD is a billing authority.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner::text, 'role', 'authenticated',
                      'email', 't158-owner@test.local')::text, true);
  j := public.get_my_vineyard_access(v_a);
  assert (j->>'is_billing_authority')::boolean = true,
    'T1a: owner of record is the billing authority';
  assert (j->>'is_billing_owner')::boolean = true,
    'T1b: they also own the funding subscription';
  assert (j->>'can_manage_billing')::boolean = true, 'T1c: owner role';
  raise notice 'T1 passed: vineyard owner of record is a billing authority';

  -- =======================================================================
  -- T2. A CO-OWNER who owns no entitlement is NOT a billing authority.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_coown::text, 'role', 'authenticated',
                      'email', 't158-coown@test.local')::text, true);
  j := public.get_my_vineyard_access(v_a);
  assert j->>'membership_role' = 'owner',            'T2a: owner role';
  assert (j->>'can_manage_billing')::boolean = true, 'T2b: legacy key unchanged';
  assert (j->>'is_billing_authority')::boolean = false,
    'T2c: co-Owner without subscription ownership is NOT the billing authority';
  raise notice 'T2 passed: co-Owner without ownership returns false';

  -- =======================================================================
  -- T3. The OWNER OF THE FUNDING SUBSCRIPTION is a billing authority even
  --     when they are not the vineyard owner of record.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_funder::text, 'role', 'authenticated',
                      'email', 't158-funder@test.local')::text, true);
  j := public.get_my_vineyard_access(v_b);
  assert (j->>'has_vineyard_access')::boolean = true, 'T3a: vineyard is funded';
  select * into ve from public._vineyard_entitlement_for(v_b);
  assert ve.access_source = 'vineyard_subscription' and ve.billing_owner_user_id = u_funder,
    'T3a2: the co-Owner''s Team subscription is what funds the vineyard';
  assert (j->>'is_billing_owner')::boolean = true,    'T3b: funding sub is theirs';
  assert (j->>'is_billing_authority')::boolean = true,
    'T3c: owner of the active funding subscription is a billing authority';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_bowner::text, 'role', 'authenticated',
                      'email', 't158-bowner@test.local')::text, true);
  assert (public.get_my_vineyard_access(v_b)->>'is_billing_authority')::boolean = true,
    'T3d: the owner of record remains an authority alongside the funder';
  raise notice 'T3 passed: owner of the funding subscription returns true';

  -- =======================================================================
  -- T4. A co-Owner never learns WHO the billing authority is.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_bco::text, 'role', 'authenticated',
                      'email', 't158-bco@test.local')::text, true);
  j := public.get_my_vineyard_access(v_b);
  assert (j->>'is_billing_authority')::boolean = false,
    'T4a: non-funding co-Owner is not an authority';
  assert (j->>'is_billing_owner')::boolean = false, 'T4b: not the billing owner';
  assert not (j ? 'billing_owner_user_id'),  'T4c: billing owner id never exposed';
  assert not (j ? 'billing_owner_email'),    'T4d: billing owner email never exposed';
  assert not (j ? 'subscription_id'),        'T4e: funding subscription id not exposed';
  assert position(u_funder::text in j::text) = 0,
    'T4f: the funding Owner''s identity does not appear anywhere in the payload';
  m := public.get_my_vineyard_access_matrix();
  assert position(u_funder::text in m::text) = 0,
    'T4g: the matrix does not leak the billing authority''s identity either';
  raise notice 'T4 passed: billing-authority identity is never disclosed';

  -- =======================================================================
  -- T5/T6/T7. Manager, Supervisor and Operator are never authorities.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated',
                      'email', 't158-mgr@test.local')::text, true);
  j := public.get_my_vineyard_access(v_a);
  assert j->>'membership_role' = 'manager',          'T5a: manager role';
  assert (j->>'has_vineyard_access')::boolean = true,'T5b: Team funds the member';
  assert (j->>'is_billing_authority')::boolean = false, 'T5c: manager -> false';
  assert (j->>'can_manage_billing')::boolean = false,   'T5d: legacy key false too';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_sup::text, 'role', 'authenticated',
                      'email', 't158-sup@test.local')::text, true);
  j := public.get_my_vineyard_access(v_a);
  assert j->>'membership_role' = 'supervisor',          'T6a: supervisor role';
  assert (j->>'is_billing_authority')::boolean = false, 'T6b: supervisor -> false';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated',
                      'email', 't158-op@test.local')::text, true);
  j := public.get_my_vineyard_access(v_a);
  assert j->>'membership_role' = 'operator',            'T7a: operator role';
  assert (j->>'is_billing_authority')::boolean = false, 'T7b: operator -> false';
  raise notice 'T5/T6/T7 passed: manager, supervisor and operator return false';

  -- =======================================================================
  -- T8. An ASSIGNED LICENCE never confers billing authority — but the same
  --     user is still an authority on the vineyard they own of record.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_lic::text, 'role', 'authenticated',
                      'email', 't158-lic@test.local')::text, true);
  j := public.get_my_vineyard_access(v_a);
  assert (j->>'has_vineyard_access')::boolean = true,   'T8a: licence entitles them';
  assert (j->>'is_billing_authority')::boolean = false,
    'T8b: an assigned licence does NOT make the holder a billing authority';
  j := public.get_my_vineyard_access(v_lic);
  assert (j->>'is_billing_authority')::boolean = true,
    'T8c: they independently satisfy the rule on their own vineyard';
  assert (j->>'has_vineyard_access')::boolean = true,
    'T8d: unchanged access decision (own entitlement, unfunded vineyard)';
  raise notice 'T8 passed: assigned licence alone is not billing authority';

  -- =======================================================================
  -- T9. A VINEYARD-SCOPED grant does not make every Owner an authority.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_gowner::text, 'role', 'authenticated',
                      'email', 't158-gowner@test.local')::text, true);
  j := public.get_my_vineyard_access(v_g);
  assert (j->>'has_vineyard_access')::boolean = true
     and j->>'vineyard_access_source' = 'vineyard_grant',
    'T9a: the vineyard-wide grant funds the vineyard';
  assert (j->>'is_billing_authority')::boolean = true,
    'T9b: the grant anchor (also owner of record) is an authority';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_gco::text, 'role', 'authenticated',
                      'email', 't158-gco@test.local')::text, true);
  j := public.get_my_vineyard_access(v_g);
  assert (j->>'has_vineyard_access')::boolean = true,
    'T9c: the co-Owner inherits the vineyard-wide grant';
  assert (j->>'is_billing_authority')::boolean = false,
    'T9d: a vineyard-scoped grant does NOT make every Owner an authority';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_gop::text, 'role', 'authenticated',
                      'email', 't158-gop@test.local')::text, true);
  assert (public.get_my_vineyard_access(v_g)->>'is_billing_authority')::boolean = false,
    'T9e: granted operator is not an authority';
  raise notice 'T9 passed: vineyard-scoped grant confers no extra authority';

  -- =======================================================================
  -- T10. A USER-SCOPED grant does not affect billing authority at all.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_uco::text, 'role', 'authenticated',
                      'email', 't158-uco@test.local')::text, true);
  j := public.get_my_vineyard_access(v_u);
  assert (j->>'has_vineyard_access')::boolean = true
     and j->>'vineyard_access_source' = 'account',
    'T10a: the user-scoped grant entitles the target account only';
  assert (j->>'is_billing_authority')::boolean = false,
    'T10b: a user-scoped grant never creates billing authority';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_uowner::text, 'role', 'authenticated',
                      'email', 't158-uowner@test.local')::text, true);
  j := public.get_my_vineyard_access(v_u);
  assert (j->>'has_vineyard_access')::boolean = false,
    'T10c: the vineyard itself stays unfunded (unchanged decision)';
  assert (j->>'is_billing_authority')::boolean = true,
    'T10d: its owner of record is still the responsible Owner';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_uop::text, 'role', 'authenticated',
                      'email', 't158-uop@test.local')::text, true);
  assert (public.get_my_vineyard_access(v_u)->>'is_billing_authority')::boolean = false,
    'T10e: fellow member unaffected by the user-scoped grant';
  raise notice 'T10 passed: user-scoped grant does not affect billing authority';

  -- =======================================================================
  -- T11. Team subscription: only its owner (and the owner of record) -> true.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_bop::text, 'role', 'authenticated',
                      'email', 't158-bop@test.local')::text, true);
  assert (public.get_my_vineyard_access(v_b)->>'is_billing_authority')::boolean = false,
    'T11a: Team-funded operator is not an authority';

  -- Only u_funder (subscription owner) and u_bowner (owner of record) may be
  -- authorities on vB; every other Owner/member must be false.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_bco::text, 'role', 'authenticated',
                      'email', 't158-bco@test.local')::text, true);
  assert (public.get_my_vineyard_access(v_b)->>'is_billing_authority')::boolean = false,
    'T11b: a third co-Owner is never made an authority by someone else''s Team sub';
  raise notice 'T11 passed: Team subscription authority is limited to its owner';

  -- =======================================================================
  -- T12. Enterprise subscription follows exactly the same rule.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_efunder::text, 'role', 'authenticated',
                      'email', 't158-efunder@test.local')::text, true);
  j := public.get_my_vineyard_access(v_e);
  assert (j->>'has_vineyard_access')::boolean = true,
    'T12a: the Enterprise Owner can enter the vineyard';
  select * into ve from public._vineyard_entitlement_for(v_e);
  assert ve.access_source = 'owner_subscription' and ve.billing_owner_user_id = u_efunder,
    'T12a2: the Enterprise subscription funds the vineyard';
  assert (j->>'is_billing_authority')::boolean = true,
    'T12b: the Enterprise subscription owner is the billing authority';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_eop::text, 'role', 'authenticated',
                      'email', 't158-eop@test.local')::text, true);
  assert (public.get_my_vineyard_access(v_e)->>'is_billing_authority')::boolean = false,
    'T12c: Enterprise-funded operator is not an authority';
  raise notice 'T12 passed: Enterprise follows the same rule';

  -- =======================================================================
  -- T13. EXPIRED or REVOKED funding never creates billing authority.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_xco::text, 'role', 'authenticated',
                      'email', 't158-xco@test.local')::text, true);
  j := public.get_my_vineyard_access(v_x);
  assert (j->>'has_vineyard_access')::boolean = false,
    'T13a: the expired Team subscription funds nothing';
  assert (j->>'is_billing_owner')::boolean = false, 'T13b: no funding owner';
  assert (j->>'is_billing_authority')::boolean = false,
    'T13c: an EXPIRED subscription never creates billing authority';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_xowner::text, 'role', 'authenticated',
                      'email', 't158-xowner@test.local')::text, true);
  j := public.get_my_vineyard_access(v_x);
  assert (j->>'has_vineyard_access')::boolean = false, 'T13d: still denied';
  assert (j->>'is_billing_authority')::boolean = true,
    'T13e: the owner of record remains the Owner who must fix billing';

  -- Revoke the vineyard-scoped grant on vG and re-check.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated',
                      'email', 't158-admin@test.local')::text, true);
  perform public.admin_revoke_billing_grant(g_vineyard, 'SQL 158 revocation test');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_gco::text, 'role', 'authenticated',
                      'email', 't158-gco@test.local')::text, true);
  j := public.get_my_vineyard_access(v_g);
  assert (j->>'has_vineyard_access')::boolean = false,
    'T13f: revocation removes the vineyard-wide access';
  assert (j->>'is_billing_authority')::boolean = false,
    'T13g: revoked funding does not promote the co-Owner';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_gowner::text, 'role', 'authenticated',
                      'email', 't158-gowner@test.local')::text, true);
  j := public.get_my_vineyard_access(v_g);
  assert (j->>'has_vineyard_access')::boolean = false, 'T13h: grant anchor denied too';
  assert (j->>'is_billing_authority')::boolean = true,
    'T13i: the owner of record is still the responsible Owner after revocation';
  raise notice 'T13 passed: expired/revoked funding creates no authority';

  -- =======================================================================
  -- T14. The matrix row and the single-vineyard RPC always agree.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_coown::text, 'role', 'authenticated',
                      'email', 't158-coown@test.local')::text, true);
  j := public.get_my_vineyard_access(v_a);
  select v into x from jsonb_array_elements(
    public.get_my_vineyard_access_matrix()->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_a;
  assert (j->>'is_billing_authority') = (x->>'is_billing_authority')
     and (j->>'is_billing_owner')     = (x->>'is_billing_owner')
     and (j->>'can_manage_billing')   = (x->>'can_manage_billing')
     and (j->>'has_vineyard_access')  = (x->>'has_vineyard_access')
     and (j->>'vineyard_access_reason') = (x->>'vineyard_access_reason')
     and (j->>'vineyard_access_source') = (x->>'vineyard_access_source'),
    'T14a: co-Owner — matrix row matches the single-vineyard RPC';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_funder::text, 'role', 'authenticated',
                      'email', 't158-funder@test.local')::text, true);
  j := public.get_my_vineyard_access(v_b);
  select v into x from jsonb_array_elements(
    public.get_my_vineyard_access_matrix()->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_b;
  assert (j->>'is_billing_authority') = (x->>'is_billing_authority')
     and (x->>'is_billing_authority')::boolean = true,
    'T14b: funding Owner — matrix row matches and is true';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_xowner::text, 'role', 'authenticated',
                      'email', 't158-xowner@test.local')::text, true);
  j := public.get_my_vineyard_access(v_x);
  select v into x from jsonb_array_elements(
    public.get_my_vineyard_access_matrix()->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_x;
  assert (j->>'is_billing_authority') = (x->>'is_billing_authority')
     and (j->>'requires_billing_attention') = (x->>'requires_billing_attention'),
    'T14c: denied vineyard — matrix row matches the single-vineyard RPC';
  raise notice 'T14 passed: matrix and single-vineyard RPC agree';

  -- =======================================================================
  -- T15. Pre-existing keys and access decisions are unchanged.
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner::text, 'role', 'authenticated',
                      'email', 't158-owner@test.local')::text, true);
  m := public.get_my_vineyard_access_matrix();
  select v into x from jsonb_array_elements(m->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_a;
  assert (select count(*) from unnest(keys) k where not (x ? k)) = 0,
    'T15a: every SQL 156/157 matrix key is still present';
  assert (select count(*) from jsonb_object_keys(x) k where k <> all (keys)) = 0,
    'T15b: no key other than is_billing_authority was added to the matrix row';
  j := public.get_my_vineyard_access(v_a);
  assert (select count(*) from unnest(keys) k where not (j ? k)) = 0,
    'T15c: every key is still present on the single-vineyard RPC';
  assert (select count(*) from jsonb_object_keys(j) k where k <> all (keys)) = 0,
    'T15d: single-vineyard RPC exposes exactly the documented keys';
  assert m->'account' ? 'account_access_state'
     and m->'account' ? 'has_any_accessible_vineyard'
     and m->'account' ? 'accessible_vineyard_count'
     and m->'account' ? 'pending_invitation_count'
     and m->'account' ? 'can_create_vineyard',
    'T15e: the account summary contract is unchanged';
  assert m->'account'->>'account_access_state' = 'full',
    'T15f: unchanged account state for an entitled Owner';
  assert (x->>'has_vineyard_access')::boolean = true
     and (x->>'can_enter_vineyard')::boolean = true
     and (x->>'requires_billing_attention')::boolean = false,
    'T15g: unchanged access decision for the funded vineyard';

  -- The member-level decisions are untouched by SQL 158 as well.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated',
                      'email', 't158-op@test.local')::text, true);
  select v into x from jsonb_array_elements(
    public.get_my_vineyard_access_matrix()->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_a;
  assert (x->>'has_vineyard_access')::boolean = true
     and x->>'vineyard_access_source' = 'vineyard_subscription',
    'T15h: Team-funded operator decision unchanged';
  raise notice 'T15 passed: existing fields and decisions unchanged';

  -- =======================================================================
  -- T17. Non-members cannot read vineyard authority details.
  --      (Run before T16, which clears the JWT for the rest of the block.)
  -- =======================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_outside::text, 'role', 'authenticated',
                      'email', 't158-outside@test.local')::text, true);
  j := public.get_my_vineyard_access(v_a);
  assert (j->>'has_vineyard_access')::boolean = false
     and j->>'vineyard_access_reason' = 'not_a_member',
    'T17a: non-member safely denied';
  assert not (j ? 'is_billing_authority'),
    'T17b: billing authority is never disclosed to a non-member';
  assert not (j ? 'is_billing_owner') and not (j ? 'can_manage_billing'),
    'T17c: no billing keys for a non-member';
  assert not (j ? 'vineyard_name') and not (j ? 'membership_role'),
    'T17d: no vineyard identity leaked';
  assert position(u_owner::text in j::text) = 0,
    'T17e: the Owner''s identity is not leaked';
  m := public.get_my_vineyard_access_matrix();
  assert jsonb_array_length(m->'vineyards') = 0,
    'T17f: the matrix lists no vineyards for a non-member';
  raise notice 'T17 passed: non-members learn nothing about authority';

  -- =======================================================================
  -- T16. Anonymous callers are rejected by both RPCs.
  -- =======================================================================
  perform set_config('request.jwt.claims', null, true);
  ok := false;
  begin
    perform public.get_my_vineyard_access_matrix();
  exception when others then
    ok := true;
  end;
  assert ok, 'T16a: anonymous matrix call rejected';
  ok := false;
  begin
    perform public.get_my_vineyard_access(v_a);
  exception when others then
    ok := true;
  end;
  assert ok, 'T16b: anonymous single-vineyard call rejected';
  raise notice 'T16 passed: authentication required';

  -- =======================================================================
  -- T18. All test data exists only inside this transaction.
  -- =======================================================================
  assert (select count(*) from auth.users where email like 't158-%@test.local') = 23,
    'T18a: fixtures present inside the transaction';
  assert (select count(*) from public.vineyards where name like 'T158 %') = 7,
    'T18b: fixture vineyards present inside the transaction';
  raise notice 'T18: fixtures will be discarded by the final ROLLBACK';

  raise notice 'SQL 158 vineyard billing authority tests: ALL PASSED';
end$$;

rollback;

-- Post-rollback proof: both counts must be 0.
select
  (select count(*) from auth.users where email like 't158-%@test.local') as leftover_users,
  (select count(*) from public.vineyards where name like 'T158 %')       as leftover_vineyards;

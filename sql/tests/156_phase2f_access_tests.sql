-- =====================================================================
-- 156_phase2f_access_tests.sql — Phase 2F vineyard-scoped access tests
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/155 and sql/156.
-- Everything runs inside ONE transaction that is ROLLED BACK — no
-- production data is touched. Expected final output:
--   NOTICE: SQL 155/156 Phase 2F access tests: ALL PASSED
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.admin_create_billing_grant(uuid, text, text, timestamptz, timestamptz, uuid, text)') is null then
    raise exception 'SQL 155 not applied — run sql/155_billing_grant_scope.sql first.';
  end if;
  if to_regprocedure('public.get_my_vineyard_access_matrix()') is null
     or to_regprocedure('public._vineyard_entitlement_for(uuid)') is null then
    raise exception 'SQL 156 not applied — run sql/156_vineyard_access_matrix.sql first.';
  end if;
end$$;

do $$
declare
  u_admin    uuid;  -- System Admin
  u_ownera   uuid;  -- owns vA, vD, vE — trial EXPIRED (created 2y ago)
  u_ownerb   uuid;  -- owns vB — active anchored Team subscription
  u_trialown uuid;  -- owns vC — ACTIVE account trial (created 1 month ago)
  u_member   uuid;  -- operator vA + manager vB — own trial expired
  u_cmember  uuid;  -- operator vC — own trial expired
  u_dmember  uuid;  -- manager vD — own trial expired
  u_newmem   uuid;  -- joins vD AFTER the vineyard grant
  u_e1       uuid;  -- operator vE — receives USER-scoped grant
  u_e2       uuid;  -- operator vE — must NOT inherit u_e1's user grant
  v_a uuid; v_b uuid; v_c uuid; v_d uuid; v_e uuid; v_f uuid;
  plan_team uuid;
  s_team uuid;
  g_vineyard uuid;  -- vineyard-scoped grant on vD
  g_user     uuid;  -- user-scoped grant for u_e1
  r  record;
  j  jsonb;
  x  jsonb;
  n  bigint;
  ok boolean;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't156-admin@test.local',    'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't156-ownera@test.local',   'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't156-ownerb@test.local',   'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't156-trialown@test.local', 'x', now(), now() - interval '1 month', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't156-member@test.local',   'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't156-cmember@test.local',  'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't156-dmember@test.local',  'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't156-newmem@test.local',   'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't156-e1@test.local',       'x', now(), now() - interval '2 years', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't156-e2@test.local',       'x', now(), now() - interval '2 years', now());
  select id into u_admin    from auth.users where email = 't156-admin@test.local';
  select id into u_ownera   from auth.users where email = 't156-ownera@test.local';
  select id into u_ownerb   from auth.users where email = 't156-ownerb@test.local';
  select id into u_trialown from auth.users where email = 't156-trialown@test.local';
  select id into u_member   from auth.users where email = 't156-member@test.local';
  select id into u_cmember  from auth.users where email = 't156-cmember@test.local';
  select id into u_dmember  from auth.users where email = 't156-dmember@test.local';
  select id into u_newmem   from auth.users where email = 't156-newmem@test.local';
  select id into u_e1       from auth.users where email = 't156-e1@test.local';
  select id into u_e2       from auth.users where email = 't156-e2@test.local';

  insert into public.profiles (id, email, full_name)
  select u.id, u.email, 'T156 ' || split_part(u.email, '@', 1)
  from auth.users u where u.email like 't156-%@test.local'
  on conflict (id) do nothing;

  insert into public.system_admins (user_id, is_active) values (u_admin, true)
  on conflict do nothing;

  insert into public.vineyards (id, name, owner_id) values
    (gen_random_uuid(), 'T156 Vineyard A (expired)',  u_ownera),
    (gen_random_uuid(), 'T156 Vineyard B (team)',     u_ownerb),
    (gen_random_uuid(), 'T156 Vineyard C (trial)',    u_trialown),
    (gen_random_uuid(), 'T156 Vineyard D (grant)',    u_ownera),
    (gen_random_uuid(), 'T156 Vineyard E (bare)',     u_ownera),
    (gen_random_uuid(), 'T156 Vineyard F (orphan)',   null);
  select id into v_a from public.vineyards where name = 'T156 Vineyard A (expired)';
  select id into v_b from public.vineyards where name = 'T156 Vineyard B (team)';
  select id into v_c from public.vineyards where name = 'T156 Vineyard C (trial)';
  select id into v_d from public.vineyards where name = 'T156 Vineyard D (grant)';
  select id into v_e from public.vineyards where name = 'T156 Vineyard E (bare)';
  select id into v_f from public.vineyards where name = 'T156 Vineyard F (orphan)';

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_a, u_ownera, 'owner'),   (v_a, u_member, 'operator'),
    (v_b, u_ownerb, 'owner'),   (v_b, u_member, 'manager'),
    (v_c, u_trialown, 'owner'), (v_c, u_cmember, 'operator'),
    (v_d, u_ownera, 'owner'),   (v_d, u_dmember, 'manager'),
    (v_e, u_e1, 'operator'),    (v_e, u_e2, 'operator'),
    (v_f, u_e2, 'operator');

  select id into plan_team from public.vinetrack_plans where code = 'team';
  if plan_team is null then
    raise exception 'plan catalogue missing team';
  end if;

  -- Active Team subscription ANCHORED to vB (funds vB for its members).
  insert into public.vinetrack_subscriptions
    (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
     seats_included, started_at, current_period_start, current_period_end)
  values (u_ownerb, v_b, plan_team, 'stripe', 'active', 5,
          now() - interval '1 day', now() - interval '1 day', now() + interval '300 days')
  returning id into s_team;

  -- ---- T1. Grant scope validation -----------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated',
                      'email', 't156-admin@test.local')::text, true);

  ok := false;
  begin
    perform public.admin_create_billing_grant(
      u_e1, 'complimentary_solo', 'bad combo', null, null, v_e, 'vineyard');
  exception when others then
    ok := (sqlerrm like '%grant_scope_not_allowed_for_type%');
  end;
  assert ok, 'T1a: complimentary_solo + vineyard scope rejected';

  ok := false;
  begin
    perform public.admin_create_billing_grant(
      u_e1, 'complimentary_team', 'bad combo', null, null, v_e, 'user');
  exception when others then
    ok := (sqlerrm like '%grant_scope_not_allowed_for_type%');
  end;
  assert ok, 'T1b: complimentary_team + user scope rejected';

  ok := false;
  begin
    perform public.admin_create_billing_grant(
      u_ownera, 'internal_unlimited', 'no vineyard', null, null, null, 'vineyard');
  exception when others then
    ok := (sqlerrm like '%vineyard_required_for_vineyard_scope%');
  end;
  assert ok, 'T1c: vineyard scope without vineyard rejected';

  ok := false;
  begin
    perform public.admin_create_billing_grant(
      u_ownera, 'internal_unlimited', 'bad scope', null, null, v_d, 'both');
  exception when others then
    ok := (sqlerrm like '%invalid_grant_scope%');
  end;
  assert ok, 'T1d: unknown scope rejected';
  raise notice 'T1 passed: grant scope validation';

  -- ---- T2. Vineyard-scoped grant funds every active member ---------------
  g_vineyard := public.admin_create_billing_grant(
    u_ownera, 'internal_unlimited', 'Vineyard-wide test grant',
    null, null, v_d, 'vineyard');
  assert g_vineyard is not null, 'T2a: vineyard grant created';

  -- Member entitlement state refreshed immediately by the mutation.
  select count(*) into n from public.vinetrack_entitlement_state es
  where es.user_id = u_dmember and es.has_access = true;
  assert n = 1, 'T2b: member entitlement state refreshed to granted';

  -- The member resolves access through the shared resolver.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_dmember::text, 'role', 'authenticated',
                      'email', 't156-dmember@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true,          'T2c: member has access';
  assert r.access_source = 'vineyard',          'T2d: access_source vineyard';
  assert r.reason_code = 'vineyard_entitlement','T2e: reason vineyard_entitlement';
  assert r.vineyard_id = v_d,                   'T2f: funded vineyard id returned';
  assert r.subscription_id is null,             'T2g: funding subscription id hidden from member';
  raise notice 'T2 passed: vineyard-wide grant funds active members';

  -- ---- T3. Newly accepted member inherits an active vineyard grant -------
  insert into public.vineyard_members (vineyard_id, user_id, role)
  values (v_d, u_newmem, 'operator');
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_newmem::text, 'role', 'authenticated',
                      'email', 't156-newmem@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.access_source = 'vineyard',
    'T3a: new member inherits the vineyard grant';
  raise notice 'T3 passed: new member inherits vineyard grant';

  -- ---- T4. Removed member loses access through that vineyard -------------
  delete from public.vineyard_members
  where vineyard_id = v_d and user_id = u_newmem;
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false,
    'T4a: removed member loses vineyard-backed access';
  raise notice 'T4 passed: removed member loses access';

  -- ---- T5. User-scoped grant never unlocks fellow members ----------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated',
                      'email', 't156-admin@test.local')::text, true);
  g_user := public.admin_create_billing_grant(
    u_e1, 'internal_unlimited', 'User-scoped with informational vineyard',
    null, null, v_e, 'user');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_e1::text, 'role', 'authenticated',
                      'email', 't156-e1@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.reason_code = 'internal_unlimited',
    'T5a: user-scoped grant grants the target user';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_e2::text, 'role', 'authenticated',
                      'email', 't156-e2@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false,
    'T5b: user-scoped grant with primary vineyard must NOT unlock other members (scope never inferred)';
  raise notice 'T5 passed: user scope never inferred from primary vineyard';

  -- ---- T6. Owner account trial funds the owned vineyard's members --------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_cmember::text, 'role', 'authenticated',
                      'email', 't156-cmember@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.access_source = 'vineyard',
    'T6a: owner-trial-backed vineyard grants its member';
  j := public.get_my_vineyard_access_matrix();
  select v into x from jsonb_array_elements(j->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_c;
  assert (x->>'has_vineyard_access')::boolean = true,       'T6b: matrix row accessible';
  assert x->>'vineyard_access_source' = 'owner_trial',      'T6c: source owner_trial';
  assert (x->>'is_trial')::boolean = true,                  'T6d: flagged as trial';
  raise notice 'T6 passed: owner trial backs the vineyard';

  -- ---- T7. Expired vineyard A + funded vineyard B: no global paywall -----
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_member::text, 'role', 'authenticated',
                      'email', 't156-member@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.access_source = 'vineyard'
     and r.vineyard_id = v_b,
    'T7a: resolver grants via funded vineyard B (never global denial)';

  j := public.get_my_vineyard_access_matrix();
  assert j->'account'->>'account_access_state' = 'vineyard_only',
    'T7b: account_access_state vineyard_only';
  assert (j->'account'->>'has_any_accessible_vineyard')::boolean = true,
    'T7c: has_any_accessible_vineyard true';
  assert (j->'account'->>'accessible_vineyard_count')::int = 1,
    'T7d: exactly one accessible vineyard';
  select v into x from jsonb_array_elements(j->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_a;
  assert (x->>'has_vineyard_access')::boolean = false
     and x->>'vineyard_access_reason' = 'no_vineyard_entitlement',
    'T7e: expired vineyard A row denied';
  select v into x from jsonb_array_elements(j->'vineyards') v
  where (v->>'vineyard_id')::uuid = v_b;
  assert (x->>'has_vineyard_access')::boolean = true
     and x->>'vineyard_access_source' = 'vineyard_subscription',
    'T7f: team-funded vineyard B row accessible';
  raise notice 'T7 passed: mixed access matrix — expired A never blocks B';

  -- ---- T8. Only expired vineyards -> restricted, not signed out ----------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_e2::text, 'role', 'authenticated',
                      'email', 't156-e2@test.local')::text, true);
  j := public.get_my_vineyard_access_matrix();
  assert j->'account'->>'account_access_state' = 'restricted',
    'T8a: restricted account state';
  assert (j->'account'->>'accessible_vineyard_count')::int = 0,
    'T8b: zero accessible vineyards';
  assert (j->'account'->>'vineyard_count')::int = 2,
    'T8c: memberships still listed (vE + vF)';
  raise notice 'T8 passed: restricted state (memberships preserved)';

  -- ---- T9. Pending invitations survive a restricted account --------------
  insert into public.invitations (vineyard_id, email, role, status, invited_by)
  values (v_b, 't156-e2@test.local', 'operator', 'pending', u_ownerb);

  select count(*) into n from public.list_my_pending_invitations();
  assert n = 1, 'T9a: pending invitation visible';
  select count(*) into n from public.list_my_pending_invitations() i
  where i.vineyard_name = 'T156 Vineyard B (team)';
  assert n = 1, 'T9b: invitation carries the vineyard name (non-member)';
  j := public.get_my_vineyard_access_matrix();
  assert (j->'account'->>'pending_invitation_count')::int = 1,
    'T9c: matrix reports the pending invitation';
  raise notice 'T9 passed: invitations remain visible with vineyard identity';

  -- ---- T10. Non-member single-vineyard check leaks nothing ---------------
  j := public.get_my_vineyard_access(v_c);
  assert (j->>'has_vineyard_access')::boolean = false
     and j->>'vineyard_access_reason' = 'not_a_member',
    'T10a: non-member safely denied';
  assert not (j ? 'vineyard_name'), 'T10b: vineyard name not leaked';
  raise notice 'T10 passed: non-member denial leaks nothing';

  -- ---- T11. Anonymous callers rejected ------------------------------------
  perform set_config('request.jwt.claims', null, true);
  ok := false;
  begin
    perform public.get_my_vineyard_access_matrix();
  exception when others then
    ok := true;
  end;
  assert ok, 'T11a: anonymous matrix call rejected';
  ok := false;
  begin
    perform public.get_my_vineyard_access(v_b);
  exception when others then
    ok := true;
  end;
  assert ok, 'T11b: anonymous single-vineyard call rejected';
  raise notice 'T11 passed: authentication required';

  -- ---- T12. Diagnostics: explain + inheriting members ---------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_member::text, 'role', 'authenticated',
                      'email', 't156-member@test.local')::text, true);
  ok := false;
  begin
    perform public.admin_explain_vineyard_access(u_dmember, v_d);
  exception when insufficient_privilege then
    ok := true;
  end;
  assert ok, 'T12a: non-admin cannot use diagnostics';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated',
                      'email', 't156-admin@test.local')::text, true);
  j := public.admin_explain_vineyard_access(u_dmember, v_d);
  assert (j->'decision'->>'has_vineyard_access')::boolean = true,
    'T12b: explain decision true';
  assert j->'vineyard_entitlement'->>'access_source' = 'vineyard_grant',
    'T12c: funding source vineyard_grant';
  assert jsonb_array_length(j->'inheriting_members') >= 2,
    'T12d: inheriting members listed';
  raise notice 'T12 passed: access diagnostics';

  -- ---- T13. admin_list_user_vineyards never returns NULL is_owner --------
  select count(*) into n from public.admin_list_user_vineyards(u_e2) v
  where v.is_owner is null or v.member_count is null;
  assert n = 0, 'T13a: no NULL is_owner/member_count (iOS strict decoder)';
  select count(*) into n from public.admin_list_user_vineyards(u_e2) v
  where v.id = v_f and v.is_owner = false;
  assert n = 1, 'T13b: orphaned-owner vineyard returns is_owner=false';
  raise notice 'T13 passed: admin_list_user_vineyards contract safe';

  -- ---- T14. Grants list exposes scope --------------------------------------
  select count(*) into n from public.admin_list_billing_grants() g
  where g.subscription_id = g_vineyard
    and g.grant_scope = 'vineyard'
    and g.licences_display = 'Vineyard-wide';
  assert n = 1, 'T14a: vineyard grant listed with scope';
  select count(*) into n from public.admin_list_billing_grants() g
  where g.subscription_id = g_user and g.grant_scope = 'user';
  assert n = 1, 'T14b: user grant listed with scope';
  raise notice 'T14 passed: grants list scope';

  -- ---- T15. Pre-existing rows default to user scope ------------------------
  select count(*) into n from public.vinetrack_subscriptions
  where id = s_team and grant_scope = 'user';
  assert n = 1, 'T15: rows created without scope default to user (no silent conversion)';
  raise notice 'T15 passed: existing grants remain user-scoped';

  -- ---- T16. Revoking a vineyard grant recalculates every member ----------
  perform public.admin_revoke_billing_grant(g_vineyard, 'Phase 2F test revoke');
  select count(*) into n from public.vinetrack_entitlement_state es
  where es.user_id = u_dmember and es.has_access = false;
  assert n = 1, 'T16a: member entitlement state recalculated to denied';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_dmember::text, 'role', 'authenticated',
                      'email', 't156-dmember@test.local')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false,
    'T16b: revoked vineyard grant no longer funds members';
  raise notice 'T16 passed: revocation recalculates affected members';

  raise notice 'SQL 155/156 Phase 2F access tests: ALL PASSED';
end$$;

rollback;

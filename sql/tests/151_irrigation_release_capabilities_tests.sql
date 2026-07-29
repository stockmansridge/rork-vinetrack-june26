-- =====================================================================
-- 151_irrigation_release_capabilities_tests.sql — public-release tests
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/151. Everything runs
-- inside ONE transaction that is ROLLED BACK — no production data is
-- touched. Expected final output:
--   NOTICE: SQL 151 irrigation capability tests: ALL PASSED
--
-- NOTE: the SQL editor runs as postgres (RLS is bypassed), so these tests
-- exercise the RPC-level capability checks and the capability matrix —
-- which are the security boundary. RLS policies reuse the same
-- irrigation_capability()/has_irrigation_records_access() functions
-- asserted here.
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 151 is applied.
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'irrigation_capability'
  ) then
    raise exception 'SQL 151 not applied — run sql/151_irrigation_public_release_capabilities.sql first.';
  end if;
end$$;

do $$
declare
  v_yard   uuid;
  v_other  uuid;  -- vineyard the callers are NOT members of
  u_sys    uuid;  -- system admin, member with the LOWEST role (operator)
  u_owner  uuid;
  u_mgr    uuid;
  u_sup    uuid;
  u_op     uuid;
  u_none   uuid;  -- authenticated, never a member
  u_rev    uuid;  -- membership revoked mid-test
  caps     jsonb;
  r        jsonb;
  ok       boolean;

  -- impersonate helper inlined via set_config each time
  procedure_placeholder int;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t151-sys@test.local','t151-owner@test.local','t151-mgr@test.local',
                    't151-sup@test.local','t151-op@test.local','t151-none@test.local',
                    't151-rev@test.local']) e;
  select id into u_sys   from auth.users where email = 't151-sys@test.local';
  select id into u_owner from auth.users where email = 't151-owner@test.local';
  select id into u_mgr   from auth.users where email = 't151-mgr@test.local';
  select id into u_sup   from auth.users where email = 't151-sup@test.local';
  select id into u_op    from auth.users where email = 't151-op@test.local';
  select id into u_none  from auth.users where email = 't151-none@test.local';
  select id into u_rev   from auth.users where email = 't151-rev@test.local';

  insert into public.profiles (id, email)
  select u, 't151-' || u::text || '@test.local'
  from unnest(array[u_sys, u_owner, u_mgr, u_sup, u_op, u_none, u_rev]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name, owner_id)
  values (gen_random_uuid(), 'T151 Capability Test Vineyard', u_owner)
  returning id into v_yard;
  insert into public.vineyards (id, name, owner_id)
  values (gen_random_uuid(), 'T151 Other Vineyard', u_owner)
  returning id into v_other;

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_yard, u_sys,   'operator'),   -- lowest role: admin override must win
    (v_yard, u_owner, 'owner'),
    (v_yard, u_mgr,   'manager'),
    (v_yard, u_sup,   'supervisor'),
    (v_yard, u_op,    'operator'),
    (v_yard, u_rev,   'manager');

  insert into public.system_admins (user_id, email, is_active)
  values (u_sys, 't151-sys@test.local', true);

  -- ---- T1. Owner: full matrix -------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner::text, 'role', 'authenticated')::text, true);
  caps := public.get_irrigation_capabilities(v_yard);
  assert (caps->>'role') = 'owner',                                  'T1 role';
  assert (caps->>'can_view_irrigation_records')::boolean,            'T1 view';
  assert (caps->>'can_record_irrigation')::boolean,                  'T1 record';
  assert (caps->>'can_edit_irrigation')::boolean,                    'T1 edit';
  assert (caps->>'can_reverse_irrigation')::boolean,                 'T1 reverse';
  assert (caps->>'can_manage_irrigation_setup')::boolean,            'T1 setup';
  assert (caps->>'can_view_irrigation_reports')::boolean,            'T1 reports';
  assert (caps->>'can_import_irrigation')::boolean,                  'T1 import';
  assert (caps->>'can_reverse_irrigation_import')::boolean,          'T1 reverse import';
  -- Owner can actually mutate setup:
  r := public.create_irrigation_system(gen_random_uuid(), v_yard, 'T151 System', 'bore');
  assert (r->>'name') = 'T151 System',                               'T1 create system';
  raise notice 'T1 passed: Owner has the full matrix and can mutate setup';

  -- ---- T2. Manager: full matrix (default recommendation incl. imports) ---
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  caps := public.get_irrigation_capabilities(v_yard);
  assert (caps->>'can_manage_irrigation_setup')::boolean,            'T2 setup';
  assert (caps->>'can_import_irrigation')::boolean,                  'T2 import';
  assert (caps->>'can_reverse_irrigation_import')::boolean,          'T2 reverse import';
  assert (caps->>'can_edit_irrigation')::boolean,                    'T2 edit';
  raise notice 'T2 passed: Manager matches Owner (imports + reversal included)';

  -- ---- T3. Supervisor: record/reports/reverse yes; setup/import/edit no --
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_sup::text, 'role', 'authenticated')::text, true);
  caps := public.get_irrigation_capabilities(v_yard);
  assert (caps->>'can_view_irrigation_records')::boolean,            'T3 view';
  assert (caps->>'can_record_irrigation')::boolean,                  'T3 record';
  assert (caps->>'can_view_irrigation_reports')::boolean,            'T3 reports';
  assert (caps->>'can_reverse_irrigation')::boolean,                 'T3 reverse (work-record convention)';
  assert not (caps->>'can_edit_irrigation')::boolean,                'T3 no edit';
  assert not (caps->>'can_manage_irrigation_setup')::boolean,        'T3 no setup';
  assert not (caps->>'can_import_irrigation')::boolean,              'T3 no import';
  assert not (caps->>'can_reverse_irrigation_import')::boolean,      'T3 no import reversal';
  -- Direct RPC calls are denied server-side (not just hidden UI):
  begin
    perform public.create_irrigation_system(gen_random_uuid(), v_yard, 'Nope');
    raise exception 'T3: supervisor setup mutation must be rejected';
  exception when others then
    if sqlerrm not like 'irrigation_permission_denied%' then raise; end if;
  end;
  begin
    perform public.create_irrigation_import_batch(
      gen_random_uuid(), v_yard, 'galcon_gsi', 'x.xlsx', 'deadbeef');
    raise exception 'T3: supervisor import must be rejected';
  exception when others then
    if sqlerrm not like 'import_access_denied%' then raise; end if;
  end;
  -- Supervisor CAN read setup lists (view capability):
  perform public.list_irrigation_systems(v_yard);
  raise notice 'T3 passed: Supervisor gets record/reports/reverse, denied setup/import';

  -- ---- T4. Operator: view + record only ----------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);
  caps := public.get_irrigation_capabilities(v_yard);
  assert (caps->>'can_view_irrigation_records')::boolean,            'T4 view';
  assert (caps->>'can_record_irrigation')::boolean,                  'T4 record';
  assert not (caps->>'can_edit_irrigation')::boolean,                'T4 no edit';
  assert not (caps->>'can_reverse_irrigation')::boolean,             'T4 no reverse';
  assert not (caps->>'can_manage_irrigation_setup')::boolean,        'T4 no setup';
  assert not (caps->>'can_view_irrigation_reports')::boolean,        'T4 no reports';
  assert not (caps->>'can_import_irrigation')::boolean,              'T4 no import';
  -- Reports RPC denies the operator server-side:
  begin
    perform public.get_irrigation_vintage_summary(v_yard);
    raise exception 'T4: operator reports must be rejected';
  exception when others then
    if sqlerrm not like 'irrigation_permission_denied%' then raise; end if;
  end;
  begin
    perform public.get_irrigation_vintage_overview(v_yard);
    raise exception 'T4: operator Phase 2B report must be rejected';
  exception when others then
    if sqlerrm not like 'irrigation_permission_denied%' then raise; end if;
  end;
  begin
    perform public.create_irrigation_system(gen_random_uuid(), v_yard, 'Nope');
    raise exception 'T4: operator setup mutation must be rejected';
  exception when others then
    if sqlerrm not like 'irrigation_permission_denied%' then raise; end if;
  end;
  -- Edit/reverse helper checks (the same helper every session RPC calls):
  perform set_config('app.irrigation_capability', 'edit_irrigation', true);
  begin
    perform public._irrigation_require_access(v_yard);
    raise exception 'T4: operator edit must be rejected';
  exception when others then
    if sqlerrm not like 'irrigation_permission_denied%' then raise; end if;
  end;
  perform set_config('app.irrigation_capability', 'reverse_irrigation', true);
  begin
    perform public._irrigation_require_access(v_yard);
    raise exception 'T4: operator reverse must be rejected';
  exception when others then
    if sqlerrm not like 'irrigation_permission_denied%' then raise; end if;
  end;
  perform set_config('app.irrigation_capability', '', true);
  -- Operator can still open records and sessions (view + record):
  perform public.list_irrigation_systems(v_yard);
  perform public.list_irrigation_sessions(v_yard);
  raise notice 'T4 passed: Operator records + views, denied reports/setup/edit/reverse';

  -- ---- T5. No membership: nothing ----------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_none::text, 'role', 'authenticated')::text, true);
  assert not public.has_irrigation_records_access(v_yard),           'T5 gate false';
  caps := public.get_irrigation_capabilities(v_yard);
  assert not (caps->>'can_view_irrigation_records')::boolean,        'T5 no view';
  assert not (caps->>'can_record_irrigation')::boolean,              'T5 no record';
  begin
    perform public.list_irrigation_systems(v_yard);
    raise exception 'T5: non-member must be rejected';
  exception when others then
    if sqlerrm not like 'irrigation_access_denied%' then raise; end if;
  end;
  raise notice 'T5 passed: non-member fully denied (irrigation_access_denied)';

  -- ---- T6. Revoked membership: falls back to nothing ----------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_rev::text, 'role', 'authenticated')::text, true);
  assert public.has_irrigation_records_access(v_yard),               'T6 pre-revoke true';
  delete from public.vineyard_members where vineyard_id = v_yard and user_id = u_rev;
  assert not public.has_irrigation_records_access(v_yard),           'T6 post-revoke false';
  begin
    perform public.get_irrigation_setup_status(v_yard);
    raise exception 'T6: revoked member must be rejected';
  exception when others then
    if sqlerrm not like 'irrigation_access_denied%' then raise; end if;
  end;
  raise notice 'T6 passed: revoked membership loses all access immediately';

  -- ---- T7. System Administrator: full access despite operator role --------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_sys::text, 'role', 'authenticated')::text, true);
  caps := public.get_irrigation_capabilities(v_yard);
  assert (caps->>'is_system_admin')::boolean,                        'T7 admin flag';
  assert (caps->>'can_manage_irrigation_setup')::boolean,            'T7 setup override';
  assert (caps->>'can_import_irrigation')::boolean,                  'T7 import override';
  assert (caps->>'can_view_irrigation_reports')::boolean,            'T7 reports override';
  assert (caps->>'can_edit_irrigation')::boolean,                    'T7 edit override';
  -- ...but NOT on a vineyard they are not a member of (Phase 1 semantics kept):
  caps := public.get_irrigation_capabilities(v_other);
  assert not (caps->>'can_view_irrigation_records')::boolean,        'T7 non-member vineyard denied';
  raise notice 'T7 passed: System Admin keeps full access (member vineyards only)';

  -- ---- T8. Unknown capability + null vineyard deny ------------------------
  assert not public.irrigation_capability(v_yard, 'made_up'),        'T8 unknown cap denies';
  assert not public.irrigation_capability(null, 'view_irrigation_records'), 'T8 null vineyard denies';
  raise notice 'T8 passed: unknown capability and null vineyard deny';

  raise notice 'SQL 151 irrigation capability tests: ALL PASSED';
end$$;

rollback;

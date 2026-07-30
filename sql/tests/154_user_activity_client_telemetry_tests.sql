-- =====================================================================
-- 154_user_activity_client_telemetry_tests.sql
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/154. Everything runs
-- inside ONE transaction that is ROLLED BACK — no production data is
-- touched. Expected final output:
--   NOTICE: SQL 154 client telemetry tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 154 is applied.
do $$
begin
  if to_regclass('public.vinetrack_user_clients') is null then
    raise exception 'SQL 154 not applied — run sql/154_user_activity_client_telemetry.sql first.';
  end if;
  if to_regprocedure('public.record_my_client_activity(uuid, text, text, text, text, text, text, text, text, text, text, uuid)') is null then
    raise exception 'SQL 154 not applied — heartbeat RPC missing.';
  end if;
  if to_regprocedure('public.admin_list_user_login_activity(text, text, text, timestamptz, timestamptz, text)') is null then
    raise exception 'SQL 154 not applied — updated activity RPC missing.';
  end if;
end$$;

do $$
declare
  v_yard    uuid;
  v_other   uuid;   -- vineyard user A does NOT belong to
  u_a       uuid;   -- ordinary member of v_yard
  u_b       uuid;   -- second account sharing a device with u_a
  u_admin   uuid;   -- system admin
  c_ios     uuid := gen_random_uuid();
  c_android uuid := gen_random_uuid();
  c_web     uuid := gen_random_uuid();
  c_shared  uuid := gen_random_uuid();  -- same installation, two accounts
  r         jsonb;
  n         integer;
  t0        timestamptz;
  ok        boolean;
  rec       record;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t154-a@test.local','t154-b@test.local','t154-admin@test.local']) e;
  select id into u_a     from auth.users where email = 't154-a@test.local';
  select id into u_b     from auth.users where email = 't154-b@test.local';
  select id into u_admin from auth.users where email = 't154-admin@test.local';

  insert into public.profiles (id, email)
  select u, 't154-' || u::text || '@test.local'
  from unnest(array[u_a, u_b, u_admin]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name, owner_id)
  values (gen_random_uuid(), 'T154 Telemetry Vineyard', u_a)
  returning id into v_yard;
  insert into public.vineyards (id, name, owner_id)
  values (gen_random_uuid(), 'T154 Foreign Vineyard', u_b)
  returning id into v_other;

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_yard, u_a, 'owner');

  insert into public.system_admins (user_id, email, is_active)
  values (u_admin, 't154-admin@test.local', true);

  -- ---- T1. Anonymous heartbeat denied ------------------------------------
  perform set_config('request.jwt.claims', null, true);
  ok := false;
  begin
    r := public.record_my_client_activity(
      c_ios, 'ios', 'ios', 'iPhone', 'iPhone16,2', 'iOS', '18.6', '2.8.7', '20');
  exception when others then
    ok := true;
  end;
  assert ok, 'T1 anonymous heartbeat must be denied';
  raise notice 'T1 passed: anonymous heartbeat denied';

  -- ---- T2. iOS heartbeat creates a client --------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  r := public.record_my_client_activity(
    c_ios, 'ios', 'ios', 'iPhone', 'iPhone16,2', 'iOS', '18.6', '2.8.7', '20',
    null, null, v_yard);
  assert (r->>'ok')::boolean, 'T2 heartbeat ok';
  select count(*) into n from public.vinetrack_user_clients
  where user_id = u_a and client_instance_id = c_ios;
  assert n = 1, 'T2 exactly one client row';
  select last_vineyard_id into rec from public.vinetrack_user_clients
  where user_id = u_a and client_instance_id = c_ios;
  assert rec.last_vineyard_id = v_yard, 'T2 member vineyard stored';
  raise notice 'T2 passed: iOS heartbeat creates a client (vineyard stored)';

  -- ---- T3. Repeated heartbeat updates, preserves first_seen_at -----------
  select first_seen_at into t0 from public.vinetrack_user_clients
  where user_id = u_a and client_instance_id = c_ios;
  r := public.record_my_client_activity(
    c_ios, 'ios', 'ios', 'iPhone', 'iPhone16,2', 'iOS', '18.6', '2.8.8', '21');
  select count(*) into n from public.vinetrack_user_clients
  where user_id = u_a and client_instance_id = c_ios;
  assert n = 1, 'T3 no duplicate row';
  select * into rec from public.vinetrack_user_clients
  where user_id = u_a and client_instance_id = c_ios;
  assert rec.first_seen_at = t0,          'T3 first_seen_at preserved';
  assert rec.app_version = '2.8.8',       'T3 app_version updated';
  assert rec.app_build = '21',            'T3 app_build updated';
  assert rec.last_vineyard_id = v_yard,   'T3 vineyard kept when omitted';
  raise notice 'T3 passed: repeated heartbeat upserts (first_seen preserved, version updated)';

  -- ---- T4. Android + portal heartbeats create separate clients -----------
  r := public.record_my_client_activity(
    c_android, 'android', 'android', 'Phone', 'Samsung SM-S928B', 'Android', '16', '0.0.6', '6');
  r := public.record_my_client_activity(
    c_web, 'portal-web', 'web', 'Desktop', 'Desktop', 'Windows', '11', '1.0.0', null,
    'Chrome', '126');
  select count(*) into n from public.vinetrack_user_clients where user_id = u_a;
  assert n = 3, 'T4 three separate clients';
  select browser_name into rec from public.vinetrack_user_clients
  where user_id = u_a and client_instance_id = c_web;
  assert rec.browser_name = 'Chrome', 'T4 portal browser stored';
  select browser_name into rec from public.vinetrack_user_clients
  where user_id = u_a and client_instance_id = c_android;
  assert rec.browser_name is null, 'T4 native client stores no browser';
  raise notice 'T4 passed: separate devices create separate clients (browser only for portal)';

  -- ---- T5. Invalid app/platform values rejected --------------------------
  ok := false;
  begin
    r := public.record_my_client_activity(
      gen_random_uuid(), 'windows-phone', 'web', null, null, null, null, null, null);
  exception when others then ok := true; end;
  assert ok, 'T5 unknown app_type rejected';
  ok := false;
  begin
    r := public.record_my_client_activity(
      gen_random_uuid(), 'ios', 'android', null, null, null, null, null, null);
  exception when others then ok := true; end;
  assert ok, 'T5 mismatched app/platform pair rejected';
  raise notice 'T5 passed: invalid app/platform values rejected';

  -- ---- T6. Overlong / control-char metadata sanitised ---------------------
  r := public.record_my_client_activity(
    c_ios, 'ios', 'ios', 'iPhone',
    repeat('x', 500) || chr(10) || 'evil',
    'iOS' || chr(9), '18.6', '2.8.8', '21');
  select device_model, os_name into rec from public.vinetrack_user_clients
  where user_id = u_a and client_instance_id = c_ios;
  assert length(rec.device_model) <= 80,            'T6 device_model length-limited';
  assert rec.device_model !~ '[[:cntrl:]]',         'T6 control chars stripped';
  assert rec.os_name = 'iOS',                        'T6 os_name trimmed';
  raise notice 'T6 passed: overlong/malformed metadata sanitised';

  -- ---- T7. Foreign vineyard ID rejected (not stored) ----------------------
  r := public.record_my_client_activity(
    c_android, 'android', 'android', 'Phone', 'Samsung SM-S928B', 'Android', '16', '0.0.6', '6',
    null, null, v_other);
  select last_vineyard_id into rec from public.vinetrack_user_clients
  where user_id = u_a and client_instance_id = c_android;
  assert rec.last_vineyard_id is null, 'T7 foreign vineyard not stored';
  raise notice 'T7 passed: foreign vineyard ID rejected';

  -- ---- T8. Same installation, second account → isolated row ---------------
  r := public.record_my_client_activity(
    c_shared, 'ios', 'ios', 'iPhone', 'iPhone16,2', 'iOS', '18.6', '2.8.8', '21');
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_b::text, 'role', 'authenticated')::text, true);
  r := public.record_my_client_activity(
    c_shared, 'ios', 'ios', 'iPhone', 'iPhone16,2', 'iOS', '18.6', '2.8.8', '21');
  select count(*) into n from public.vinetrack_user_clients
  where client_instance_id = c_shared;
  assert n = 2, 'T8 two isolated user/client rows for the shared installation';
  raise notice 'T8 passed: shared device stays isolated per account';

  -- ---- T9. Retention: newest 10 clients kept ------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_b::text, 'role', 'authenticated')::text, true);
  for n in 1..12 loop
    r := public.record_my_client_activity(
      gen_random_uuid(), 'android', 'android', 'Phone', 'Pixel ' || n::text,
      'Android', '16', '0.0.6', '6');
  end loop;
  select count(*) into n from public.vinetrack_user_clients where user_id = u_b;
  assert n = 10, format('T9 expected 10 clients after 13 heartbeats, found %s', n);
  raise notice 'T9 passed: per-user history bounded to 10 clients';

  -- ---- T10. Non-admin cannot read activity or client history --------------
  ok := false;
  begin
    perform * from public.admin_list_user_login_activity();
  exception when others then ok := true; end;
  assert ok, 'T10 non-admin denied on activity list';
  ok := false;
  begin
    perform * from public.admin_user_client_activity(u_a);
  exception when others then ok := true; end;
  assert ok, 'T10 non-admin denied on client history';
  raise notice 'T10 passed: non-admin denied on both admin RPCs';

  -- ---- T11. Admin list shows the most recent client -----------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);
  select * into rec from public.admin_list_user_login_activity()
  where user_id = u_a;
  assert rec.client_count = 4,                      'T11 client_count';
  assert rec.last_app_type = 'ios',                 'T11 most recent app_type (c_shared iOS was last)';
  assert rec.last_platform = 'ios',                 'T11 platform';
  assert rec.last_os_name = 'iOS',                  'T11 os_name';
  assert rec.last_client_seen_at is not null,       'T11 last seen set';
  raise notice 'T11 passed: activity list returns the most recent client + count';

  -- ---- T12. Users with no heartbeat show NULL client fields ---------------
  select * into rec from public.admin_list_user_login_activity()
  where user_id = u_admin;
  assert rec.last_app_type is null,        'T12 no heartbeat → null app_type (Not recorded)';
  assert rec.client_count = 0,             'T12 client_count 0';
  raise notice 'T12 passed: no-heartbeat users show Not recorded semantics';

  -- ---- T13. Server-side filters --------------------------------------------
  select count(*) into n from public.admin_list_user_login_activity(p_app_type => 'ios')
  where user_id in (u_a, u_b, u_admin);
  assert n = 1, 'T13 app_type filter keeps only the iOS-latest user';
  select count(*) into n from public.admin_list_user_login_activity(p_platform => 'android')
  where user_id in (u_a, u_b, u_admin);
  assert n = 1, 'T13 platform filter';
  select count(*) into n from public.admin_list_user_login_activity(p_os_name => 'android')
  where user_id in (u_a, u_b, u_admin);
  assert n = 1, 'T13 os_name filter (case-insensitive)';
  select count(*) into n from public.admin_list_user_login_activity(p_seen_since => now() + interval '1 hour')
  where user_id in (u_a, u_b, u_admin);
  assert n = 0, 'T13 seen_since range filter';
  raise notice 'T13 passed: server-side filters work';

  -- ---- T14. Client history detail: redaction + is_current ------------------
  n := 0;
  for rec in select * from public.admin_user_client_activity(u_a) loop
    n := n + 1;
    assert rec.client_reference like 'client-%',                    'T14 redacted reference format';
    assert position(c_ios::text in rec.client_reference) = 0,      'T14 raw installation UUID never returned';
    if n = 1 then
      assert rec.is_current, 'T14 newest client flagged is_current';
    else
      assert not rec.is_current, 'T14 older clients not current';
    end if;
  end loop;
  assert n = 4, 'T14 all clients listed';
  -- Older client remains in history after newer activity:
  select count(*) into n from public.admin_user_client_activity(u_a) h
  where h.app_type = 'android';
  assert n = 1, 'T14 older Android client retained in history';
  raise notice 'T14 passed: detail history redacts references and flags is_current';

  -- ---- T15. No prohibited hardware identifier columns ----------------------
  assert not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'vinetrack_user_clients'
      and column_name in ('imei', 'serial_number', 'mac_address', 'advertising_id', 'ip_address', 'latitude', 'longitude')
  ), 'T15 no prohibited identifier columns';
  raise notice 'T15 passed: no prohibited hardware identifier is stored';

  -- ---- T16. Retention helper is admin-only and prunes stale clients --------
  update public.vinetrack_user_clients
  set last_seen_at = now() - interval '30 months'
  where user_id = u_b and device_model = 'Pixel 3';
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  ok := false;
  begin
    n := public.prune_stale_user_clients();
  exception when others then ok := true; end;
  assert ok, 'T16 non-admin denied on prune';
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);
  n := public.prune_stale_user_clients();
  assert n = 1, 'T16 exactly the stale client pruned';
  raise notice 'T16 passed: 24-month retention prune (admin only)';

  raise notice 'SQL 154 client telemetry tests: ALL PASSED';
end$$;

rollback;

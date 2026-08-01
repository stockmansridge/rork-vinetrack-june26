-- =====================================================================
-- 159_operational_tool_preferences_tests.sql
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/159. Everything runs
-- inside ONE transaction that is ROLLED BACK — no production data is
-- touched. Expected final output:
--   NOTICE: SQL 159 operational tool preferences tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 159 is applied.
do $$
begin
  if to_regclass('public.operational_tool_catalogue') is null then
    raise exception 'SQL 159 not applied — catalogue table missing.';
  end if;
  if to_regclass('public.user_operational_tool_preferences') is null then
    raise exception 'SQL 159 not applied — preference table missing.';
  end if;
  if to_regprocedure('public.get_my_operational_tool_preferences()') is null
     or to_regprocedure('public.set_my_operational_tool_preferences(text[], text[], integer)') is null
     or to_regprocedure('public.reset_my_operational_tool_preferences()') is null then
    raise exception 'SQL 159 not applied — preference RPCs missing.';
  end if;
end$$;

do $$
declare
  u_a    uuid;   -- primary test user
  u_b    uuid;   -- second user (isolation)
  r      jsonb;
  n      integer;
  ok     boolean;
  t0     timestamptz;
  arr    text[];
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t159-a@test.local','t159-b@test.local']) e;
  select id into u_a from auth.users where email = 't159-a@test.local';
  select id into u_b from auth.users where email = 't159-b@test.local';

  insert into public.profiles (id, email)
  select u, 't159-' || u::text || '@test.local' from unnest(array[u_a, u_b]) u
  on conflict (id) do nothing;

  -- ---- T1. Catalogue matches the live 12-tile grid ------------------------
  select count(*) into n from public.operational_tool_catalogue where is_active;
  assert n = 12, 'T1 twelve active catalogue tools, found ' || n;
  select array_agg(tool_id order by display_order) into arr
  from public.operational_tool_catalogue where is_active;
  assert arr = array[
    'work_tasks','equipment_maintenance','fuel_log','irrigation_advisor',
    'disease_risk','yield_records','growth_stages','optimal_ripeness',
    'cost_reports','fertiliser_calculator','pruning_tracker','irrigation_records'
  ], 'T1 default order must match the iOS/Android grid';
  raise notice 'T1 passed: catalogue seeded in VineTrack default order';

  -- ---- T2. Anonymous access denied ---------------------------------------
  perform set_config('request.jwt.claims', null, true);
  ok := false;
  begin
    r := public.get_my_operational_tool_preferences();
  exception when others then ok := true;
  end;
  assert ok, 'T2 anonymous read must be denied';
  ok := false;
  begin
    r := public.set_my_operational_tool_preferences(array['work_tasks'], '{}'::text[], 1);
  exception when others then ok := true;
  end;
  assert ok, 'T2 anonymous write must be denied';
  ok := false;
  begin
    r := public.reset_my_operational_tool_preferences();
  exception when others then ok := true;
  end;
  assert ok, 'T2 anonymous reset must be denied';
  raise notice 'T2 passed: anonymous read/write/reset denied';

  -- ---- T3. New user: no preference, no row created ------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  r := public.get_my_operational_tool_preferences();
  assert (r->>'has_preference')::boolean = false, 'T3 new user has no preference';
  assert r->'visible_tool_ids' = '[]'::jsonb,     'T3 empty visible list';
  assert r->'hidden_tool_ids'  = '[]'::jsonb,     'T3 empty hidden list';
  assert jsonb_array_length(r->'catalogue_tool_ids') = 12, 'T3 catalogue returned';
  select count(*) into n from public.user_operational_tool_preferences where user_id = u_a;
  assert n = 0, 'T3 reading must NOT create a row';
  raise notice 'T3 passed: new user gets the default layout and no row is created';

  -- ---- T4. Save a reordered + partially hidden layout ---------------------
  r := public.set_my_operational_tool_preferences(
    array['irrigation_records','work_tasks','pruning_tracker','fuel_log'],
    array['cost_reports','optimal_ripeness'],
    1);
  assert (r->>'has_preference')::boolean, 'T4 preference saved';
  assert r->'visible_tool_ids' =
    '["irrigation_records","work_tasks","pruning_tracker","fuel_log"]'::jsonb,
    'T4 visible order preserved exactly';
  assert r->'hidden_tool_ids' = '["cost_reports","optimal_ripeness"]'::jsonb,
    'T4 hidden list preserved';
  select count(*) into n from public.user_operational_tool_preferences where user_id = u_a;
  assert n = 1, 'T4 exactly one row';
  raise notice 'T4 passed: reorder + hide saved with order preserved';

  -- ---- T5. Re-save updates rather than duplicating ------------------------
  select updated_at into t0 from public.user_operational_tool_preferences where user_id = u_a;
  perform pg_sleep(0.01);
  r := public.set_my_operational_tool_preferences(
    array['work_tasks','irrigation_records'], array['fuel_log'], 1);
  select count(*) into n from public.user_operational_tool_preferences where user_id = u_a;
  assert n = 1, 'T5 no duplicate row';
  assert r->'visible_tool_ids' = '["work_tasks","irrigation_records"]'::jsonb, 'T5 layout replaced';
  assert (select updated_at from public.user_operational_tool_preferences where user_id = u_a) > t0,
    'T5 updated_at advanced';
  raise notice 'T5 passed: re-save upserts the same row';

  -- ---- T6. Restoring a hidden tool (client appends to the end) ------------
  r := public.set_my_operational_tool_preferences(
    array['work_tasks','irrigation_records','fuel_log'], '{}'::text[], 1);
  assert r->'hidden_tool_ids' = '[]'::jsonb, 'T6 hidden list cleared';
  assert r->'visible_tool_ids' = '["work_tasks","irrigation_records","fuel_log"]'::jsonb,
    'T6 restored tool appended at the end';
  raise notice 'T6 passed: restore clears the hidden entry and keeps the order';

  -- ---- T7. Empty visible list with hidden tools is rejected ---------------
  ok := false;
  begin
    r := public.set_my_operational_tool_preferences(
      '{}'::text[], array['work_tasks','fuel_log'], 1);
  exception when others then ok := true;
  end;
  assert ok, 'T7 hiding every tool must be rejected';
  assert (select visible_tool_ids from public.user_operational_tool_preferences where user_id = u_a)
         = array['work_tasks','irrigation_records','fuel_log'],
    'T7 previous valid layout untouched after rejection';
  raise notice 'T7 passed: at least one visible tool is enforced';

  -- ---- T8. Duplicates rejected -------------------------------------------
  ok := false;
  begin
    r := public.set_my_operational_tool_preferences(
      array['work_tasks','work_tasks'], '{}'::text[], 1);
  exception when others then ok := true;
  end;
  assert ok, 'T8 duplicate visible IDs must be rejected';
  raise notice 'T8 passed: duplicate tool IDs rejected';

  -- ---- T9. A tool in both lists is rejected -------------------------------
  ok := false;
  begin
    r := public.set_my_operational_tool_preferences(
      array['work_tasks','fuel_log'], array['fuel_log'], 1);
  exception when others then ok := true;
  end;
  assert ok, 'T9 tool in both lists must be rejected';
  raise notice 'T9 passed: a tool cannot be visible and hidden';

  -- ---- T10. Unknown tool IDs ignored safely -------------------------------
  r := public.set_my_operational_tool_preferences(
    array['work_tasks','not_a_real_tool','fuel_log','seeder_records'],
    array['definitely_removed_tool','cost_reports'],
    1);
  assert r->'visible_tool_ids' = '["work_tasks","fuel_log"]'::jsonb,
    'T10 unknown visible IDs dropped, order preserved';
  assert r->'hidden_tool_ids' = '["cost_reports"]'::jsonb,
    'T10 unknown hidden IDs dropped';
  raise notice 'T10 passed: unknown/retired tool IDs are ignored, not stored';

  -- ---- T11. Case/whitespace normalisation ---------------------------------
  r := public.set_my_operational_tool_preferences(
    array['  Work_Tasks ', 'FUEL_LOG'], '{}'::text[], 1);
  assert r->'visible_tool_ids' = '["work_tasks","fuel_log"]'::jsonb,
    'T11 IDs lowercased and trimmed';
  raise notice 'T11 passed: tool IDs normalised';

  -- ---- T12. Unsupported preference version rejected -----------------------
  ok := false;
  begin
    r := public.set_my_operational_tool_preferences(array['work_tasks'], '{}'::text[], 2);
  exception when others then ok := true;
  end;
  assert ok, 'T12 unsupported version must be rejected';
  raise notice 'T12 passed: unsupported preference version rejected';

  -- ---- T13. Oversized payload rejected ------------------------------------
  ok := false;
  begin
    select array_agg('tool_' || g::text) into arr from generate_series(1, 65) g;
    r := public.set_my_operational_tool_preferences(arr, '{}'::text[], 1);
  exception when others then ok := true;
  end;
  assert ok, 'T13 oversized payload must be rejected';
  raise notice 'T13 passed: oversized payload rejected';

  -- ---- T14. Reset removes the row (default layout returns) ----------------
  r := public.set_my_operational_tool_preferences(
    array['work_tasks'], array['fuel_log'], 1);
  r := public.reset_my_operational_tool_preferences();
  assert (r->>'has_preference')::boolean = false, 'T14 reset returns the default layout';
  select count(*) into n from public.user_operational_tool_preferences where user_id = u_a;
  assert n = 0, 'T14 reset deletes the row';
  raise notice 'T14 passed: reset restores the VineTrack default';

  -- ---- T15. Preferences are per-user and isolated -------------------------
  r := public.set_my_operational_tool_preferences(
    array['work_tasks','fuel_log'], array['cost_reports'], 1);
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_b::text, 'role', 'authenticated')::text, true);
  r := public.get_my_operational_tool_preferences();
  assert (r->>'has_preference')::boolean = false,
    'T15 second user must not inherit another user''s layout';
  r := public.set_my_operational_tool_preferences(array['disease_risk'], '{}'::text[], 1);
  assert r->'visible_tool_ids' = '["disease_risk"]'::jsonb, 'T15 second user saves its own layout';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  r := public.get_my_operational_tool_preferences();
  assert r->'visible_tool_ids' = '["work_tasks","fuel_log"]'::jsonb,
    'T15 first user layout unaffected by the second user';
  raise notice 'T15 passed: layouts are user-scoped and isolated';

  -- ---- T16. Reset affects only the calling user ---------------------------
  r := public.reset_my_operational_tool_preferences();
  select count(*) into n from public.user_operational_tool_preferences where user_id = u_b;
  assert n = 1, 'T16 other user''s layout survives a reset';
  raise notice 'T16 passed: reset is caller-scoped';

  -- ---- T17. Layout is NOT vineyard-scoped ---------------------------------
  -- Structural guarantee: the table is keyed by user_id only and has no
  -- vineyard column, so switching vineyards cannot change the layout.
  select count(*) into n
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'user_operational_tool_preferences'
    and column_name like '%vineyard%';
  assert n = 0, 'T17 preference table must have no vineyard column';
  raise notice 'T17 passed: the layout follows the user, not the vineyard';

  -- ---- T18. RLS blocks cross-user table access ----------------------------
  select count(*) into n from pg_policies
  where schemaname = 'public' and tablename = 'user_operational_tool_preferences';
  assert n >= 4, 'T18 RLS policies present (select/insert/update/delete)';
  assert (select relrowsecurity from pg_class
          where oid = 'public.user_operational_tool_preferences'::regclass),
    'T18 row level security enabled';
  raise notice 'T18 passed: RLS enabled with own-row policies';

  -- ---- T19. Hiding a tool grants/revokes nothing --------------------------
  -- The preference table references no permission, role, entitlement or
  -- vineyard object; it is presentation state only.
  select count(*) into n
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'user_operational_tool_preferences'
    and column_name not in ('user_id','visible_tool_ids','hidden_tool_ids',
                            'preference_version','created_at','updated_at');
  assert n = 0, 'T19 no extra columns — presentation state only';
  raise notice 'T19 passed: preferences carry no access semantics';

  raise notice 'SQL 159 operational tool preferences tests: ALL PASSED';
end$$;

rollback;

-- Post-rollback leftover check — both counts must be 0.
select
  (select count(*) from auth.users where email like 't159-%@test.local')        as leftover_users,
  (select count(*) from public.user_operational_tool_preferences p
     join auth.users u on u.id = p.user_id
    where u.email like 't159-%@test.local')                                     as leftover_prefs;

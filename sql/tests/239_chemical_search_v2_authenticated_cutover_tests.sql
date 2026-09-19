-- Focused authorization tests for SQL 239. Run after applying SQL 239.
-- All feature-flag changes are rolled back.

begin;

do $$
declare
  v_flag_enabled boolean;
  v_failed boolean;
  v_function regprocedure := 'public.search_master_chemicals_v2(text,integer)'::regprocedure;
begin
  if has_function_privilege('anon', v_function, 'EXECUTE') then
    raise exception 'T239.1: anon must not have EXECUTE';
  end if;

  if not has_function_privilege('authenticated', v_function, 'EXECUTE') then
    raise exception 'T239.2: authenticated must have EXECUTE';
  end if;

  if exists (
    select 1
    from pg_proc p
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
    where p.oid = v_function
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  ) then
    raise exception 'T239.3: PUBLIC must not have EXECUTE';
  end if;

  select is_enabled into v_flag_enabled
  from public.system_feature_flags
  where key = 'chemical_search_v2';

  perform set_config('request.jwt.claims', '{}', true);
  v_failed := false;
  begin
    perform * from public.search_master_chemicals_v2('grape', 1);
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'T239.4: unauthenticated caller was not rejected';
  end if;

  update public.system_feature_flags
  set is_enabled = true
  where key = 'chemical_search_v2';
  perform set_config(
    'request.jwt.claims',
    '{"sub":"10000000-0000-4000-8000-000000000239","role":"authenticated"}',
    true
  );
  perform * from public.search_master_chemicals_v2('grape', 1);

  update public.system_feature_flags
  set is_enabled = false
  where key = 'chemical_search_v2';
  v_failed := false;
  begin
    perform * from public.search_master_chemicals_v2('grape', 1);
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'T239.5: authenticated caller succeeded while flag was off';
  end if;

  update public.system_feature_flags
  set is_enabled = v_flag_enabled
  where key = 'chemical_search_v2';

  if exists (
    select 1
    from pg_get_functiondef(v_function) body
    where body like '%is_system_admin()%'
  ) then
    raise exception 'T239.6: RPC still requires System Admin';
  end if;

  raise notice 'SQL 239 focused authorization tests: ALL PASSED';
end $$;

rollback;

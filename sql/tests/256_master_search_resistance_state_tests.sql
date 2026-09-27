-- Run after SQL 256 against an isolated validation database. All fixtures and
-- feature-flag changes are rolled back. Never use production for fixture tests.
begin;

do $$
declare
  v_function regprocedure := 'public.search_master_chemicals_v2(text,integer)'::regprocedure;
  v_id uuid;
  v_row record;
  v_count integer;
  v_rejected boolean;
  v_case record;
begin
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where p.oid = v_function and n.nspname = 'public'
      and p.prosecdef and p.provolatile = 's'
      and p.proconfig @> array['search_path=public']::text[]
  ) then
    raise exception 'T256.1: SECURITY DEFINER, stable or search_path changed';
  end if;
  if has_function_privilege('anon', v_function, 'EXECUTE')
    or not has_function_privilege('authenticated', v_function, 'EXECUTE')
    or exists (
      select 1 from pg_proc p,
        lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
      where p.oid = v_function and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
    ) then
    raise exception 'T256.2: RPC grants changed';
  end if;
  if not exists (
    select 1 from pg_get_function_result(v_function) result
    where result like '%activity_groups text[]%activity_group_scheme text%resistance_classification_state text%registered_uses jsonb%'
      and result like '%regulator_label_url text%search_rank integer%'
  ) then
    raise exception 'T256.3: RPC return contract or field position changed';
  end if;

  update public.system_feature_flags set is_enabled = true where key = 'chemical_search_v2';
  perform set_config('request.jwt.claims', '{}', true);
  v_rejected := false;
  begin
    perform * from public.search_master_chemicals_v2('T256 Resistance Fixture', 5);
  exception when sqlstate '42501' then v_rejected := true;
  end;
  if not v_rejected then raise exception 'T256.4: unauthenticated search was allowed'; end if;

  perform set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000256","role":"authenticated"}', true);
  update public.system_feature_flags set is_enabled = false where key = 'chemical_search_v2';
  v_rejected := false;
  begin
    perform * from public.search_master_chemicals_v2('T256 Resistance Fixture', 5);
  exception when sqlstate '42501' then v_rejected := true;
  end;
  if not v_rejected then raise exception 'T256.5: disabled flag allowed search'; end if;
  update public.system_feature_flags set is_enabled = true where key = 'chemical_search_v2';

  -- Deliberately contradictory arrays/states prove the RPC reads SQL 210's
  -- column verbatim instead of computing a value from the group array.
  for v_case in select * from (values
    ('classified', array['10']::text[], 'hrac', '[{"name":"Glufosinate-ammonium","activity_group":{"scheme":"hrac","code":"10"}}]'::jsonb),
    ('unresolved', array['10']::text[], 'hrac', '[]'::jsonb),
    ('unresolved', array[]::text[], null::text, '[]'::jsonb),
    ('not_applicable', array[]::text[], 'not_applicable', '[]'::jsonb)
  ) as c(state, groups, scheme, actives) loop
    v_id := gen_random_uuid();
    -- The synthetic search caller is not an auth.users row. Clear its claim
    -- while inserting so the version-history trigger records changed_by NULL;
    -- restore it before exercising the authenticated RPC.
    perform set_config('request.jwt.claims', '{}', true);
    insert into public.master_chemicals (
      id, registration_country, registration_scheme, registration_number,
      registered_product_name, review_status, source_kind, verification_status,
      active_ingredients, activity_groups, activity_group_scheme,
      resistance_classification_state, registered_uses
    ) values (
      v_id, 'AU', 'apvma', v_id::text,
      'T256 Resistance Fixture ' || v_case.state, 'approved', 'official_register', 'verified',
      v_case.actives, v_case.groups, v_case.scheme, v_case.state,
      '[{"crop":"Grapes"}]'::jsonb
    );
    perform set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000256","role":"authenticated"}', true);
    select * into v_row from public.search_master_chemicals_v2('T256 Resistance Fixture', 25)
      where id = v_id;
    if not found or v_row.resistance_classification_state is distinct from v_case.state
      or v_row.activity_groups is distinct from v_case.groups
      or v_row.activity_group_scheme is distinct from v_case.scheme then
      raise exception 'T256.6: Master RPC did not preserve % / % / %', v_case.state, v_case.groups, v_case.scheme;
    end if;
  end loop;
  select count(*) into v_count from public.search_master_chemicals_v2('T256 Resistance Fixture', 25)
    where registered_product_name like 'T256 Resistance Fixture %';
  if v_count <> 4 then raise exception 'T256.7: search result count changed: %', v_count; end if;
  raise notice 'SQL 256 RPC contract, auth, feature gate, and four state/group fixtures: ALL PASSED';
end $$;

rollback;

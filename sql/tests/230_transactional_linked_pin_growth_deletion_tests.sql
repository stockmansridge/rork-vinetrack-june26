-- Rollback-only verification for SQL 230. Run manually after migration 230.
begin;

do $test$
declare
  v_vineyard uuid := gen_random_uuid();
  v_owner uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
  v_pin uuid := gen_random_uuid();
  v_growth uuid := gen_random_uuid();
  v_pin_retry uuid := gen_random_uuid();
  v_growth_retry uuid := gen_random_uuid();
  v_pin_operator uuid := gen_random_uuid();
  v_before timestamptz;
  v_version integer;
  v_failed boolean := false;
begin
  perform set_config('role', 'postgres', true);

  if to_regprocedure('public.delete_linked_pin_growth_v1(uuid,uuid)') is null then
    raise exception 'T1: canonical linked delete RPC missing';
  end if;
  if to_regprocedure('public.soft_delete_pin(uuid)') is null
     or to_regprocedure('public.soft_delete_growth_stage_record(uuid)') is null then
    raise exception 'T1: legacy delete wrappers missing';
  end if;
  if not has_function_privilege('authenticated', 'public.soft_delete_pin(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.soft_delete_growth_stage_record(uuid)', 'execute') then
    raise exception 'T1: legacy authenticated grants changed';
  end if;
  if has_function_privilege('anon', 'public.delete_linked_pin_growth_v1(uuid,uuid)', 'execute') then
    raise exception 'T1: anonymous canonical delete access';
  end if;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values
    (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     't230-owner@test.local', 'x', now(), now(), now()),
    (v_operator, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     't230-operator@test.local', 'x', now(), now(), now());
  insert into public.profiles (id, email) values
    (v_owner, 't230-owner@test.local'),
    (v_operator, 't230-operator@test.local')
  on conflict (id) do nothing;
  insert into public.vineyards (id, name) values (v_vineyard, 'T230 Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vineyard, v_owner, 'owner'),
    (v_vineyard, v_operator, 'operator');
  insert into public.pins (id, vineyard_id, mode, growth_stage_code) values
    (v_pin, v_vineyard, 'Growth', 'EL4'),
    (v_pin_retry, v_vineyard, 'Growth', 'EL12'),
    (v_pin_operator, v_vineyard, 'Repairs', null);
  insert into public.growth_stage_records (
    id, vineyard_id, pin_id, stage_code, observed_at
  ) values
    (v_growth, v_vineyard, v_pin, 'EL4', now()),
    (v_growth_retry, v_vineyard, v_pin_retry, 'EL12', now());

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- T2: either old entry point removes the linked pair atomically.
  perform public.soft_delete_pin(v_pin);
  if exists(select 1 from public.pins where id = v_pin and deleted_at is null)
     or exists(select 1 from public.growth_stage_records where id = v_growth and deleted_at is null) then
    raise exception 'T2: pin wrapper did not tombstone linked pair';
  end if;
  if exists(select 1 from public.v_growth_stage_observations where pin_id = v_pin) then
    raise exception 'T2: deleted linked observation resurrected in compatibility view';
  end if;

  perform public.soft_delete_growth_stage_record(v_growth_retry);
  if exists(select 1 from public.pins where id = v_pin_retry and deleted_at is null)
     or exists(select 1 from public.growth_stage_records where id = v_growth_retry and deleted_at is null) then
    raise exception 'T2: growth wrapper did not tombstone linked pair';
  end if;

  -- T3: repeat is idempotent: timestamp and version do not move.
  select deleted_at, sync_version into v_before, v_version from public.pins where id = v_pin_retry;
  perform public.soft_delete_growth_stage_record(v_growth_retry);
  if exists(
    select 1 from public.pins
     where id = v_pin_retry
       and (deleted_at is distinct from v_before or sync_version is distinct from v_version)
  ) then
    raise exception 'T3: repeated delete changed pin tombstone/version';
  end if;

  -- T4: a stale client write cannot clear a tombstone.
  update public.pins set deleted_at = null, notes = 'stale queued update' where id = v_pin_retry;
  if exists(select 1 from public.pins where id = v_pin_retry and deleted_at is null) then
    raise exception 'T4: stale pin write cleared tombstone';
  end if;

  -- T5: operators cannot delete operational records.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_operator::text, 'role', 'authenticated')::text, true);
  begin
    perform public.delete_linked_pin_growth_v1(v_pin_operator, null);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then raise exception 'T5: operator delete was not refused'; end if;
  if exists(select 1 from public.pins where id = v_pin_operator and deleted_at is not null) then
    raise exception 'T5: refused operator delete mutated the pin';
  end if;

  raise notice 'SQL 230 transactional linked deletion tests: ALL PASSED';
end
$test$;

rollback;

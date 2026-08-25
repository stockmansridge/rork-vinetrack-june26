-- =====================================================================
-- 209_portal_tractor_rpcs_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/206, sql/207, sql/208 and sql/209.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- ---------------------------------------------------------------------------
-- WHY EVERY TEST RUNS AS `authenticated`
-- ---------------------------------------------------------------------------
-- These RPCs are SECURITY DEFINER, so running them as owner would prove
-- nothing about authorisation — every check would pass for the wrong reason.
-- Each test switches to a real user with a real vineyard_members role, so the
-- role checks, the cross-vineyard refusals and the RLS-blind mirror lookup are
-- all exercised the way the Portal will hit them.
--
-- Test map
--   T1  Objects exist, are SECURITY DEFINER, and are granted to authenticated
--   T2  Unauthenticated calls are refused
--   T3  Owner can create; exactly ONE tractor + ONE mirror result
--   T4  The mirror's operational contract: machine_type='tractor',
--       fuel_tracking_enabled, available_for_job_costing, legacy_tractor_id
--   T5  Manager can create
--   T6  A supervisor (insufficient role) cannot create, update or archive
--   T7  A non-member cannot create in someone else's vineyard
--   T8  Update changes BOTH sides atomically
--   T9  Repeated updates never create a second mirror
--   T10 Update cannot cross vineyards (wrong vineyard for the tractor id)
--   T11 A cross-vineyard MIRROR is refused, and the failure leaves NEITHER
--       side written — the atomicity guarantee
--   T12 Self-repair: an active tractor with no mirror gains one, and an
--       ARCHIVED mirror is not resurrected
--   T13 No fabricated fuel rate: null -> 0, and a 0-rate tractor stays editable
--   T14 The grower's operational switches are not reset by an update
--   T15 Archive soft-deletes BOTH rows, and never hard deletes
--   T16 Archive leaves historical references untouched and still resolvable
--   T17 C1–C9 remain clean throughout
--   T18 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 209 portal tractor RPC tests: ALL PASSED
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure(
    'public.portal_upsert_tractor(uuid, text, text, text, integer, double precision, text, text, uuid, timestamptz)'
  ) is null then
    raise exception 'sql/209 not applied — run sql/209_portal_tractor_rpcs.sql first.';
  end if;
  if to_regprocedure('public.portal_archive_tractor(uuid)') is null then
    raise exception 'sql/209 not applied — portal_archive_tractor is missing.';
  end if;
end$$;

do $$
declare
  v_a        uuid := gen_random_uuid();   -- vineyard A
  v_b        uuid := gen_random_uuid();   -- vineyard B (foreign)
  u_owner    uuid;
  u_manager  uuid;
  u_super    uuid;                        -- supervisor: member, wrong role
  u_stranger uuid;                        -- member of B only

  v_t        uuid;   -- tractor id
  v_m        uuid;   -- machine id
  v_t2       uuid;
  v_m2       uuid;
  v_t_zero   uuid;
  v_m_zero   uuid;
  v_t_repair uuid;
  v_m_repair uuid;
  v_created  boolean;
  v_mirror_new boolean;

  tr_hist    uuid := gen_random_uuid();
  f_hist     uuid := gen_random_uuid();

  v_state    text;
  v_cnt      bigint;
  v_rate     double precision;
  v_name     text;
  v_before_t bigint;
  v_before_m bigint;
  v_deleted  timestamptz;
begin
  -- ---- fixtures (as owner) ------------------------------------------------
  perform set_config('role', 'postgres', true);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
         'authenticated', 'authenticated', e, 'x', now(), now(), now()
  from unnest(array['t209-owner@test.local','t209-manager@test.local',
                    't209-super@test.local','t209-stranger@test.local']) e;

  select id into u_owner    from auth.users where email = 't209-owner@test.local';
  select id into u_manager  from auth.users where email = 't209-manager@test.local';
  select id into u_super    from auth.users where email = 't209-super@test.local';
  select id into u_stranger from auth.users where email = 't209-stranger@test.local';

  insert into public.profiles (id, email)
  select u, 't209-' || u::text || '@test.local'
    from unnest(array[u_owner, u_manager, u_super, u_stranger]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_a, 'T209 Vineyard A'),
    (v_b, 'T209 Vineyard B');

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_a, u_owner,    'owner'),
    (v_a, u_manager,  'manager'),
    (v_a, u_super,    'supervisor'),
    (v_b, u_stranger, 'owner');

  -- =====================================================================
  -- T1. Objects, security and grants
  -- =====================================================================
  if not (
    select bool_and(p.prosecdef)
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('portal_upsert_tractor', 'portal_archive_tractor')
  ) then
    raise exception 'T1 FAILED: an sql/209 RPC is not SECURITY DEFINER';
  end if;

  -- Definer functions that write must pin search_path, or a caller-controlled
  -- path can redirect them to another schema's tables.
  if exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('portal_upsert_tractor', 'portal_archive_tractor')
       and (p.proconfig is null
            or not (p.proconfig @> array['search_path=public']))
  ) then
    raise exception 'T1 FAILED: an sql/209 RPC does not pin search_path';
  end if;

  if has_function_privilege('public', 'public.portal_archive_tractor(uuid)', 'execute') then
    raise exception 'T1 FAILED: portal_archive_tractor is executable by PUBLIC';
  end if;
  if not has_function_privilege('authenticated', 'public.portal_archive_tractor(uuid)', 'execute') then
    raise exception 'T1 FAILED: authenticated cannot execute portal_archive_tractor';
  end if;
  raise notice 'T1 passed';

  -- =====================================================================
  -- T2. Unauthenticated calls are refused
  --
  -- `authenticated` with no JWT claims: auth.uid() is null. A definer function
  -- must not treat that as a trusted caller.
  -- =====================================================================
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'authenticated', true);

  v_state := null;
  begin
    perform public.portal_upsert_tractor(
      p_vineyard_id => v_a, p_name => 'T209 Anon', p_brand => 'Kubota', p_model => 'M5');
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '28000' then
    raise exception 'T2 FAILED: expected 28000 for an unauthenticated upsert, got %',
      coalesce(v_state, 'no error');
  end if;
  raise notice 'T2 passed';

  -- =====================================================================
  -- T3. Owner can create — exactly one tractor and one mirror
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  select count(*) into v_before_t from public.tractors;
  select count(*) into v_before_m from public.vineyard_machines;

  select tractor_id, machine_id, was_created, mirror_was_created
    into v_t, v_m, v_created, v_mirror_new
    from public.portal_upsert_tractor(
      p_vineyard_id           => v_a,
      p_name                  => 'Kubota M092-N',
      p_brand                 => 'Kubota',
      p_model                 => 'M092-N',
      p_fuel_usage_l_per_hour => 7.5
    );

  if v_t is null or v_m is null then
    raise exception 'T3 FAILED: the RPC did not return both ids';
  end if;
  if not v_created or not v_mirror_new then
    raise exception 'T3 FAILED: create did not report was_created / mirror_was_created';
  end if;

  select count(*) into v_cnt from public.tractors;
  if v_cnt <> v_before_t + 1 then
    raise exception 'T3 FAILED: expected exactly 1 new tractor, got %', v_cnt - v_before_t;
  end if;
  select count(*) into v_cnt from public.vineyard_machines;
  if v_cnt <> v_before_m + 1 then
    raise exception 'T3 FAILED: expected exactly 1 new machine, got %', v_cnt - v_before_m;
  end if;
  raise notice 'T3 passed';

  -- =====================================================================
  -- T4. The mirror's operational contract
  --
  -- These flags are what make a tractor usable: fuel tracking puts it in the
  -- Fuel Log picker, job costing makes it selectable for trip costing. The
  -- sql/097 backfill set both true for tractor mirrors; the RPC must match.
  -- =====================================================================
  if not exists (
    select 1 from public.vineyard_machines m
     where m.id = v_m
       and m.vineyard_id = v_a
       and m.machine_type = 'tractor'
       and m.fuel_tracking_enabled
       and m.available_for_job_costing
       and m.legacy_tractor_id = v_t
       and m.deleted_at is null
       and m.fuel_usage_l_per_hour = 7.5
  ) then
    raise exception 'T4 FAILED: the mirror does not satisfy the tractor contract';
  end if;

  -- The descriptive identity lives on the tractor. vineyard_machines has no
  -- brand/model/model_year columns and none were added.
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'vineyard_machines'
       and column_name in ('brand', 'model', 'model_year')
  ) then
    raise exception 'T4 FAILED: descriptive tractor columns were duplicated onto vineyard_machines';
  end if;

  if not exists (
    select 1 from public.tractors t
     where t.id = v_t and t.brand = 'Kubota' and t.model = 'M092-N'
       and t.fuel_usage_l_per_hour = 7.5 and t.vineyard_id = v_a
  ) then
    raise exception 'T4 FAILED: the tractor row is wrong';
  end if;
  raise notice 'T4 passed';

  -- =====================================================================
  -- T5. A manager can create too
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_manager::text, 'role', 'authenticated')::text, true);

  select tractor_id, machine_id into v_t2, v_m2
    from public.portal_upsert_tractor(
      p_vineyard_id           => v_a,
      p_brand                 => 'New Holland',
      p_model                 => 'T4.85N',
      p_fuel_usage_l_per_hour => 6.8
    );
  -- Name falls back to "Brand Model" so the Portal need not duplicate the rule.
  if (select t.name from public.tractors t where t.id = v_t2) <> 'New Holland T4.85N' then
    raise exception 'T5 FAILED: the name fallback did not produce "New Holland T4.85N"';
  end if;
  if (select m.legacy_tractor_id from public.vineyard_machines m where m.id = v_m2) is distinct from v_t2 then
    raise exception 'T5 FAILED: the manager-created mirror is not linked';
  end if;
  raise notice 'T5 passed';

  -- =====================================================================
  -- T6. A supervisor cannot create, update or archive
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_super::text, 'role', 'authenticated')::text, true);

  v_state := null;
  begin
    perform public.portal_upsert_tractor(
      p_vineyard_id => v_a, p_brand => 'Deutz', p_model => '5090');
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    raise exception 'T6 FAILED: a supervisor created a tractor (sqlstate %)',
      coalesce(v_state, 'no error');
  end if;

  v_state := null;
  begin
    perform public.portal_upsert_tractor(
      p_vineyard_id => v_a, p_tractor_id => v_t,
      p_brand => 'Kubota', p_model => 'HACKED');
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    raise exception 'T6 FAILED: a supervisor updated a tractor (sqlstate %)',
      coalesce(v_state, 'no error');
  end if;

  v_state := null;
  begin
    perform public.portal_archive_tractor(v_t);
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    raise exception 'T6 FAILED: a supervisor archived a tractor (sqlstate %)',
      coalesce(v_state, 'no error');
  end if;

  if (select t.model from public.tractors t where t.id = v_t) <> 'M092-N' then
    raise exception 'T6 FAILED: a rejected supervisor write still changed the row';
  end if;
  raise notice 'T6 passed';

  -- =====================================================================
  -- T7. A non-member cannot reach vineyard A at all
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_stranger::text, 'role', 'authenticated')::text, true);

  v_state := null;
  begin
    perform public.portal_upsert_tractor(
      p_vineyard_id => v_a, p_brand => 'Fendt', p_model => '211V');
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    raise exception 'T7 FAILED: a non-member created a tractor in vineyard A (sqlstate %)',
      coalesce(v_state, 'no error');
  end if;
  raise notice 'T7 passed';

  -- =====================================================================
  -- T8. Update changes BOTH sides atomically
  -- =====================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner::text, 'role', 'authenticated')::text, true);

  select count(*) into v_before_m from public.vineyard_machines;

  select tractor_id, machine_id, was_created, mirror_was_created
    into v_t2, v_m2, v_created, v_mirror_new
    from public.portal_upsert_tractor(
      p_vineyard_id           => v_a,
      p_tractor_id            => v_t,
      p_name                  => 'Kubota M092-N Cab',
      p_brand                 => 'Kubota',
      p_model                 => 'M092-N Cab',
      p_model_year            => 2019,
      p_fuel_usage_l_per_hour => 8.1,
      p_serial_number         => 'SN-209'
    );

  if v_t2 is distinct from v_t or v_m2 is distinct from v_m then
    raise exception 'T8 FAILED: the update returned different ids (% / %)', v_t2, v_m2;
  end if;
  if v_created or v_mirror_new then
    raise exception 'T8 FAILED: an update reported itself as a creation';
  end if;

  if not exists (
    select 1 from public.tractors t
     where t.id = v_t and t.name = 'Kubota M092-N Cab' and t.model = 'M092-N Cab'
       and t.model_year = 2019 and t.fuel_usage_l_per_hour = 8.1
       and t.serial_number = 'SN-209'
  ) then
    raise exception 'T8 FAILED: the tractor side did not update';
  end if;
  if not exists (
    select 1 from public.vineyard_machines m
     where m.id = v_m and m.name = 'Kubota M092-N Cab'
       and m.fuel_usage_l_per_hour = 8.1 and m.serial_number = 'SN-209'
       and m.machine_type = 'tractor' and m.legacy_tractor_id = v_t
  ) then
    raise exception 'T8 FAILED: the machine side did not update in step';
  end if;

  -- Incremental sync must see both rows move.
  if (select t.client_updated_at from public.tractors t where t.id = v_t) is null
     or (select m.client_updated_at from public.vineyard_machines m where m.id = v_m) is null then
    raise exception 'T8 FAILED: client_updated_at was not set — iOS conflict resolution needs it';
  end if;
  raise notice 'T8 passed';

  -- =====================================================================
  -- T9. Repeated updates never create a second mirror
  -- =====================================================================
  perform public.portal_upsert_tractor(
    p_vineyard_id => v_a, p_tractor_id => v_t, p_brand => 'Kubota', p_model => 'M092-N Cab');
  perform public.portal_upsert_tractor(
    p_vineyard_id => v_a, p_tractor_id => v_t, p_brand => 'Kubota', p_model => 'M092-N Cab');

  select count(*) into v_cnt from public.vineyard_machines;
  if v_cnt <> v_before_m then
    raise exception 'T9 FAILED: repeated updates changed the machine count (% -> %)',
      v_before_m, v_cnt;
  end if;
  select count(*) into v_cnt
    from public.vineyard_machines m
   where m.legacy_tractor_id = v_t and m.deleted_at is null;
  if v_cnt <> 1 then
    raise exception 'T9 FAILED: % active mirrors exist for one tractor', v_cnt;
  end if;
  raise notice 'T9 passed';

  -- =====================================================================
  -- T10. Update cannot cross vineyards
  --
  -- The caller is an owner of A. Passing A's tractor id with B's vineyard id
  -- must not re-home the asset, even though the caller is authorised in A.
  -- =====================================================================
  v_state := null;
  begin
    perform public.portal_upsert_tractor(
      p_vineyard_id => v_b, p_tractor_id => v_t, p_brand => 'Kubota', p_model => 'Stolen');
  exception when others then
    v_state := sqlstate;
  end;
  -- 42501 (not a member of B) or 23514 (vineyard mismatch) are both correct
  -- refusals; silently succeeding is not.
  if v_state is null then
    raise exception 'T10 FAILED: a tractor was moved to another vineyard';
  end if;
  if (select t.vineyard_id from public.tractors t where t.id = v_t) is distinct from v_a then
    raise exception 'T10 FAILED: the tractor changed vineyard';
  end if;
  if (select t.model from public.tractors t where t.id = v_t) = 'Stolen' then
    raise exception 'T10 FAILED: a refused cross-vineyard update still wrote';
  end if;
  raise notice 'T10 passed';

  -- =====================================================================
  -- T11. A cross-vineyard MIRROR is refused, and NEITHER side is written
  --
  -- This is the atomicity guarantee. The mirror is planted with the sql/206
  -- trigger disabled, exactly how such a row could already exist. The RPC must
  -- refuse to adopt it, and the tractor-side UPDATE it performed first must be
  -- rolled back with it — a caller must never end up with half a tractor.
  -- =====================================================================
  perform set_config('role', 'postgres', true);
  alter table public.vineyard_machines disable trigger trg_vineyard_machines_validate_legacy_tractor;
  update public.vineyard_machines set vineyard_id = v_b where id = v_m;
  alter table public.vineyard_machines enable trigger trg_vineyard_machines_validate_legacy_tractor;
  perform set_config('role', 'authenticated', true);

  select t.name into v_name from public.tractors t where t.id = v_t;

  v_state := null;
  begin
    perform public.portal_upsert_tractor(
      p_vineyard_id => v_a, p_tractor_id => v_t,
      p_name => 'T209 Should Not Persist', p_brand => 'Kubota', p_model => 'M092-N Cab');
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'T11 FAILED: expected 23514 for a cross-vineyard mirror, got %',
      coalesce(v_state, 'no error — the mirror was adopted');
  end if;

  if (select t.name from public.tractors t where t.id = v_t) is distinct from v_name then
    raise exception
      'T11 FAILED: the tractor side persisted after the mirror side failed — the write is not atomic';
  end if;
  -- And no replacement mirror was created alongside the foreign one.
  select count(*) into v_cnt
    from public.vineyard_machines m
   where m.legacy_tractor_id = v_t and m.deleted_at is null;
  if v_cnt <> 1 then
    raise exception 'T11 FAILED: the failed call left % mirrors', v_cnt;
  end if;

  -- Restore the fixture.
  perform set_config('role', 'postgres', true);
  alter table public.vineyard_machines disable trigger trg_vineyard_machines_validate_legacy_tractor;
  update public.vineyard_machines set vineyard_id = v_a where id = v_m;
  alter table public.vineyard_machines enable trigger trg_vineyard_machines_validate_legacy_tractor;
  perform set_config('role', 'authenticated', true);
  raise notice 'T11 passed';

  -- =====================================================================
  -- T12. Self-repair, and archived mirrors are not resurrected
  --
  -- An active tractor with no mirror is the sql/207 defect inverted: it would
  -- be invisible to the Fuel Log. The RPC repairs the tractor it is writing.
  -- =====================================================================
  perform set_config('role', 'postgres', true);
  insert into public.tractors (id, vineyard_id, name, brand, model, fuel_usage_l_per_hour)
  values (gen_random_uuid(), v_a, 'T209 Mirrorless', 'Deutz', '5090', 9.2)
  returning id into v_t_repair;
  perform set_config('role', 'authenticated', true);

  select machine_id, mirror_was_created into v_m_repair, v_mirror_new
    from public.portal_upsert_tractor(
      p_vineyard_id           => v_a,
      p_tractor_id            => v_t_repair,
      p_brand                 => 'Deutz',
      p_model                 => '5090',
      p_fuel_usage_l_per_hour => 9.2
    );

  if not v_mirror_new or v_m_repair is null then
    raise exception 'T12 FAILED: the missing mirror was not self-repaired';
  end if;
  if not exists (
    select 1 from public.vineyard_machines m
     where m.id = v_m_repair and m.legacy_tractor_id = v_t_repair
       and m.machine_type = 'tractor'
       and m.fuel_tracking_enabled and m.available_for_job_costing
  ) then
    raise exception 'T12 FAILED: the self-repaired mirror is malformed';
  end if;

  -- An ARCHIVED mirror must not be resurrected: archiving was a decision.
  perform set_config('role', 'postgres', true);
  update public.vineyard_machines set deleted_at = now() where id = v_m_repair;
  perform set_config('role', 'authenticated', true);

  select machine_id, mirror_was_created into v_m2, v_mirror_new
    from public.portal_upsert_tractor(
      p_vineyard_id => v_a, p_tractor_id => v_t_repair,
      p_brand => 'Deutz', p_model => '5090', p_fuel_usage_l_per_hour => 9.2);

  if v_m2 = v_m_repair then
    raise exception 'T12 FAILED: an archived mirror was resurrected';
  end if;
  if not v_mirror_new then
    raise exception 'T12 FAILED: a fresh mirror was not created alongside the archived one';
  end if;
  if (select m.deleted_at from public.vineyard_machines m where m.id = v_m_repair) is null then
    raise exception 'T12 FAILED: the archived mirror was un-archived';
  end if;
  raise notice 'T12 passed';

  -- =====================================================================
  -- T13. No fabricated fuel rate, and a 0-rate tractor stays editable
  --
  -- fuel_usage_l_per_hour is NOT NULL, and 0 is the schema's "not set". A
  -- promoted or imported tractor with an unknown rate must be creatable and
  -- editable without anyone inventing a consumption figure.
  -- =====================================================================
  select tractor_id, machine_id into v_t_zero, v_m_zero
    from public.portal_upsert_tractor(
      p_vineyard_id           => v_a,
      p_brand                 => 'Massey Ferguson',
      p_model                 => '3708',
      p_fuel_usage_l_per_hour => null      -- unknown
    );

  select t.fuel_usage_l_per_hour into v_rate from public.tractors t where t.id = v_t_zero;
  if v_rate is distinct from 0 then
    raise exception 'T13 FAILED: an unknown rate became % instead of 0', v_rate;
  end if;
  select m.fuel_usage_l_per_hour into v_rate from public.vineyard_machines m where m.id = v_m_zero;
  if v_rate is distinct from 0 then
    raise exception 'T13 FAILED: the mirror invented a rate of %', v_rate;
  end if;

  -- Editing another field must not require supplying a rate.
  perform public.portal_upsert_tractor(
    p_vineyard_id => v_a, p_tractor_id => v_t_zero,
    p_brand => 'Massey Ferguson', p_model => '3708', p_model_year => 2020);
  select t.fuel_usage_l_per_hour into v_rate from public.tractors t where t.id = v_t_zero;
  if v_rate is distinct from 0 then
    raise exception 'T13 FAILED: editing a 0-rate tractor changed its rate to %', v_rate;
  end if;
  if (select t.model_year from public.tractors t where t.id = v_t_zero) <> 2020 then
    raise exception 'T13 FAILED: a 0-rate tractor could not be edited';
  end if;

  -- A negative rate is refused outright.
  v_state := null;
  begin
    perform public.portal_upsert_tractor(
      p_vineyard_id => v_a, p_tractor_id => v_t_zero,
      p_brand => 'Massey Ferguson', p_model => '3708',
      p_fuel_usage_l_per_hour => -1);
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'T13 FAILED: a negative fuel rate was accepted';
  end if;
  raise notice 'T13 passed';

  -- =====================================================================
  -- T14. An update does not reset the grower's operational switches
  --
  -- Forcing the flags true on every write is a full-row-replace defect: it
  -- would silently re-enable fuel tracking someone deliberately turned off.
  -- =====================================================================
  perform set_config('role', 'postgres', true);
  update public.vineyard_machines
     set fuel_tracking_enabled = false,
         available_for_job_costing = false,
         notes = 'T209 keep me'
   where id = v_m;
  perform set_config('role', 'authenticated', true);

  perform public.portal_upsert_tractor(
    p_vineyard_id => v_a, p_tractor_id => v_t,
    p_brand => 'Kubota', p_model => 'M092-N Cab', p_fuel_usage_l_per_hour => 8.1);

  if (select m.fuel_tracking_enabled from public.vineyard_machines m where m.id = v_m) then
    raise exception 'T14 FAILED: an update silently re-enabled fuel tracking';
  end if;
  if (select m.available_for_job_costing from public.vineyard_machines m where m.id = v_m) then
    raise exception 'T14 FAILED: an update silently re-enabled job costing';
  end if;
  if (select m.notes from public.vineyard_machines m where m.id = v_m) is distinct from 'T209 keep me' then
    raise exception 'T14 FAILED: an update erased machine notes';
  end if;
  raise notice 'T14 passed';

  -- =====================================================================
  -- T15/T16. Archive
  -- =====================================================================
  -- Historical rows against the tractor and its mirror.
  perform set_config('role', 'postgres', true);
  insert into public.trips (id, vineyard_id, tractor_id, machine_id, person_name)
  values (tr_hist, v_a, v_t, v_m, 'T209 Operator');
  insert into public.tractor_fuel_logs
    (id, vineyard_id, machine_id, tractor_id, litres_added, engine_hours)
  values (f_hist, v_a, v_m, v_t, 110, 980.5);
  perform set_config('role', 'authenticated', true);

  select count(*) into v_before_t from public.tractors;
  select count(*) into v_before_m from public.vineyard_machines;

  select tractor_id, machine_id, archived_at into v_t2, v_m2, v_deleted
    from public.portal_archive_tractor(v_t);

  if v_t2 is distinct from v_t or v_m2 is distinct from v_m then
    raise exception 'T15 FAILED: archive returned the wrong ids';
  end if;
  if v_deleted is null then
    raise exception 'T15 FAILED: archive did not report a timestamp';
  end if;

  -- BOTH sides soft-deleted…
  if (select t.deleted_at from public.tractors t where t.id = v_t) is null then
    raise exception 'T15 FAILED: the tractor was not soft-deleted';
  end if;
  if (select m.deleted_at from public.vineyard_machines m where m.id = v_m) is null then
    raise exception 'T15 FAILED: the machine mirror was not soft-deleted';
  end if;
  -- …and NOTHING hard-deleted.
  select count(*) into v_cnt from public.tractors;
  if v_cnt <> v_before_t then
    raise exception 'T15 FAILED: archive removed tractor rows (% -> %)', v_before_t, v_cnt;
  end if;
  select count(*) into v_cnt from public.vineyard_machines;
  if v_cnt <> v_before_m then
    raise exception 'T15 FAILED: archive removed machine rows (% -> %)', v_before_m, v_cnt;
  end if;
  raise notice 'T15 passed';

  -- T16: history untouched and still resolvable through the archived rows.
  if (select tr.tractor_id from public.trips tr where tr.id = tr_hist) is distinct from v_t
     or (select tr.machine_id from public.trips tr where tr.id = tr_hist) is distinct from v_m then
    raise exception 'T16 FAILED: archive cleared the trip references';
  end if;
  if (select f.machine_id from public.tractor_fuel_logs f where f.id = f_hist) is distinct from v_m
     or (select f.tractor_id from public.tractor_fuel_logs f where f.id = f_hist) is distinct from v_t then
    raise exception 'T16 FAILED: archive cleared the fuel log references';
  end if;
  if (select f.litres_added from public.tractor_fuel_logs f where f.id = f_hist) <> 110 then
    raise exception 'T16 FAILED: archive altered fuel log values';
  end if;
  -- The archived rows are tombstones, not gone, so history still renders.
  if (select t.name from public.tractors t where t.id = v_t) is null then
    raise exception 'T16 FAILED: the archived tractor row is gone, not tombstoned';
  end if;

  -- Archiving twice is harmless.
  perform public.portal_archive_tractor(v_t);

  -- An unknown tractor is a clean not-found, not a silent success.
  v_state := null;
  begin
    perform public.portal_archive_tractor(gen_random_uuid());
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from 'P0002' then
    raise exception 'T16 FAILED: archiving an unknown tractor returned %',
      coalesce(v_state, 'no error');
  end if;
  raise notice 'T16 passed';

  -- =====================================================================
  -- T17. The integrity checks stay clean
  --
  -- Everything these RPCs created must satisfy C1-C9. In particular the
  -- mirrors must never register as C9 orphans — that would mean the RPC is
  -- reproducing the very defect sql/207 and sql/208 repaired.
  -- =====================================================================
  perform set_config('role', 'postgres', true);

  select count(*) into v_cnt
    from public.vt_equipment_integrity_report()
   where severity = 'error' and offending_count > 0;
  if v_cnt <> 0 then
    raise exception 'T17 FAILED: % error-severity integrity check(s) are non-zero', v_cnt;
  end if;

  select offending_count into v_cnt
    from public.vt_equipment_integrity_report()
   where check_name = 'native_tractor_machine_unlinked';
  if v_cnt <> 0 then
    raise exception 'T17 FAILED: the RPCs left % unlinked native tractor-machine(s)', v_cnt;
  end if;
  raise notice 'T17 passed';

  raise notice 'SQL 209 portal tractor RPC tests: ALL PASSED';
end$$;

-- ---------------- T18 discard everything ----------------
rollback;

-- =====================================================================
-- Post-run expectation: the NOTICEs above, and ZERO fixtures remaining.
-- Verify with (outside any transaction):
--   select count(*) from public.vineyards where name like 'T209%';
--   -- expected: 0
--   select count(*) from auth.users where email like 't209-%@test.local';
--   -- expected: 0
-- =====================================================================

-- 226_register_spray_report_route_asset_v1_tests.sql — rollback-only verification.
-- Run manually after sql/226_register_spray_report_route_asset_v1.sql.
-- Every fixture and assertion is discarded by the final rollback.
begin;

create or replace function public._t226_login(p_user_id uuid)
returns void
language plpgsql
as $function$
begin
  perform set_config('role', 'postgres', true);
  if p_user_id is null then
    perform set_config('request.jwt.claims', '', true);
  else
    perform set_config(
      'request.jwt.claims',
      json_build_object('sub', p_user_id::text, 'role', 'authenticated')::text,
      true
    );
  end if;
  perform set_config('role', 'authenticated', true);
end;
$function$;

do $tests$
declare
  v_vineyard uuid := gen_random_uuid();
  v_other_vineyard uuid := gen_random_uuid();
  v_trip uuid := gen_random_uuid();
  v_other_trip uuid := gen_random_uuid();
  v_member uuid;
  v_stranger uuid;
  v_path text;
  v_competing_path text;
  v_sha text := repeat('a', 64);
  v_route_hash text := repeat('b', 64);
  v_competing_sha text := repeat('c', 64);
  v_competing_hash text := repeat('d', 64);
  v_result jsonb;
  v_result_again jsonb;
  v_state text;
  v_count bigint;
begin
  perform set_config('role', 'postgres', true);

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 't226-member@test.local', 'x', now(), now(), now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 't226-stranger@test.local', 'x', now(), now(), now());

  select id into v_member from auth.users where email = 't226-member@test.local';
  select id into v_stranger from auth.users where email = 't226-stranger@test.local';

  insert into public.profiles (id, email) values
    (v_member, 't226-member@test.local'),
    (v_stranger, 't226-stranger@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_vineyard, 'T226 Route Vineyard'),
    (v_other_vineyard, 'T226 Other Vineyard');

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vineyard, v_member, 'operator'),
    (v_other_vineyard, v_stranger, 'owner');

  insert into public.trips (id, vineyard_id, is_active, created_by) values
    (v_trip, v_vineyard, false, v_member),
    (v_other_trip, v_other_vineyard, false, v_stranger);

  v_path := v_trip::text || '/canonical-route.png';
  v_competing_path := v_trip::text || '/competing-route.png';

  insert into storage.objects (bucket_id, name) values
    ('trip-report-assets', v_path),
    ('trip-report-assets', v_competing_path);

  -- T1: structure, grants, immutable uniqueness, and direct-write closure.
  if to_regprocedure('public.register_spray_report_route_asset_v1(uuid,text,text,text,text,text)') is null then
    raise exception 'T1 FAILED: controlled route registration RPC is missing';
  end if;
  if to_regprocedure('public.upsert_trip_report_route_asset_v1(uuid,text,text,text)') is not null then
    raise exception 'T1 FAILED: overwrite-capable SQL 225 RPC still exists';
  end if;
  if has_function_privilege('public', 'public.register_spray_report_route_asset_v1(uuid,text,text,text,text,text)', 'execute')
     or has_function_privilege('anon', 'public.register_spray_report_route_asset_v1(uuid,text,text,text,text,text)', 'execute') then
    raise exception 'T1 FAILED: unauthenticated role can execute route registration';
  end if;
  if not has_function_privilege('authenticated', 'public.register_spray_report_route_asset_v1(uuid,text,text,text,text,text)', 'execute') then
    raise exception 'T1 FAILED: authenticated role cannot execute route registration';
  end if;
  if has_table_privilege('authenticated', 'public.trip_report_assets', 'insert')
     or has_table_privilege('authenticated', 'public.trip_report_assets', 'update')
     or has_table_privilege('authenticated', 'public.trip_report_assets', 'delete') then
    raise exception 'T1 FAILED: authenticated retains a direct metadata write privilege';
  end if;
  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and tablename = 'trip_report_assets'
      and indexname = 'trip_report_assets_one_canonical_route_per_trip'
      and indexdef ilike 'create unique index%'
  ) then
    raise exception 'T1 FAILED: one-canonical-route concurrency index is missing';
  end if;

  -- T2: a role with no JWT cannot use the SECURITY DEFINER function.
  perform public._t226_login(null);
  v_state := null;
  begin
    perform public.register_spray_report_route_asset_v1(
      v_trip, 'trip-report-assets', v_path, v_sha, v_route_hash,
      'spray-route-red-green-v1'
    );
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '28000' then
    raise exception 'T2 FAILED: expected unauthenticated SQLSTATE 28000, got %', coalesce(v_state, 'no error');
  end if;

  -- T3: a non-member cannot register another vineyard's trip.
  perform public._t226_login(v_stranger);
  v_state := null;
  begin
    perform public.register_spray_report_route_asset_v1(
      v_trip, 'trip-report-assets', v_path, v_sha, v_route_hash,
      'spray-route-red-green-v1'
    );
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    raise exception 'T3 FAILED: expected cross-vineyard SQLSTATE 42501, got %', coalesce(v_state, 'no error');
  end if;

  -- T4: bucket, style, path, digest, and uploaded-object validation.
  perform public._t226_login(v_member);
  v_state := null;
  begin
    perform public.register_spray_report_route_asset_v1(
      v_trip, 'public-assets', v_path, v_sha, v_route_hash,
      'spray-route-red-green-v1'
    );
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '22023' then raise exception 'T4 FAILED: unapproved bucket accepted'; end if;

  v_state := null;
  begin
    perform public.register_spray_report_route_asset_v1(
      v_trip, 'trip-report-assets', v_path, v_sha, v_route_hash,
      'unapproved-style'
    );
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '22023' then raise exception 'T4 FAILED: unapproved style accepted'; end if;

  v_state := null;
  begin
    perform public.register_spray_report_route_asset_v1(
      v_trip, 'trip-report-assets', v_other_trip::text || '/wrong-trip.png', v_sha, v_route_hash,
      'spray-route-red-green-v1'
    );
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '22023' then raise exception 'T4 FAILED: cross-trip path accepted'; end if;

  v_state := null;
  begin
    perform public.register_spray_report_route_asset_v1(
      v_trip, 'trip-report-assets', v_trip::text || '/../escape.png', v_sha, v_route_hash,
      'spray-route-red-green-v1'
    );
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '22023' then raise exception 'T4 FAILED: traversal path accepted'; end if;

  v_state := null;
  begin
    perform public.register_spray_report_route_asset_v1(
      v_trip, 'trip-report-assets', v_trip::text || '/missing.png', v_sha, v_route_hash,
      'spray-route-red-green-v1'
    );
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from 'P0002' then raise exception 'T4 FAILED: missing storage object accepted'; end if;

  -- T5: an authenticated vineyard member registers and receives canonical fields.
  select public.register_spray_report_route_asset_v1(
    v_trip, 'trip-report-assets', v_path, v_sha, v_route_hash,
    'spray-route-red-green-v1'
  ) into v_result;

  if v_result is distinct from jsonb_build_object(
    'bucket', 'trip-report-assets',
    'objectPath', v_path,
    'sha256', v_sha,
    'routeHash', v_route_hash,
    'styleVersion', 'spray-route-red-green-v1'
  ) then
    raise exception 'T5 FAILED: unexpected canonical response %', v_result;
  end if;

  select count(*) into v_count
  from public.trip_report_assets
  where trip_id = v_trip;
  if v_count <> 1 then raise exception 'T5 FAILED: expected one metadata row, found %', v_count; end if;

  -- T6: retries and competing exporters return the first immutable winner.
  select public.register_spray_report_route_asset_v1(
    v_trip, 'trip-report-assets', v_path, v_sha, v_route_hash,
    'spray-route-red-green-v1'
  ) into v_result_again;
  if v_result_again is distinct from v_result then
    raise exception 'T6 FAILED: identical retry did not return the canonical winner';
  end if;

  select public.register_spray_report_route_asset_v1(
    v_trip, 'trip-report-assets', v_competing_path, v_competing_sha, v_competing_hash,
    'spray-route-red-green-v1'
  ) into v_result_again;
  if v_result_again is distinct from v_result then
    raise exception 'T6 FAILED: competing proposal replaced or bypassed the winner';
  end if;

  select count(*) into v_count
  from public.trip_report_assets
  where trip_id = v_trip;
  if v_count <> 1 then raise exception 'T6 FAILED: retry/competition created % rows', v_count; end if;

  -- T7: the unique index is the database-level race safety net. This models a
  -- privileged concurrent writer arriving outside the row-locking RPC.
  perform set_config('role', 'postgres', true);
  v_state := null;
  begin
    insert into public.trip_report_assets (
      vineyard_id, trip_id, object_path, sha256, route_hash, created_by
    ) values (
      v_vineyard, v_trip, v_competing_path, v_competing_sha, v_competing_hash, v_member
    );
  exception when unique_violation then v_state := sqlstate;
  end;
  if v_state is distinct from '23505' then
    raise exception 'T7 FAILED: database allowed a second canonical route under competition';
  end if;

  -- T8: RLS reveals metadata to the vineyard member and hides it from strangers.
  perform public._t226_login(v_member);
  select count(*) into v_count from public.trip_report_assets where trip_id = v_trip;
  if v_count <> 1 then raise exception 'T8 FAILED: member cannot read canonical metadata'; end if;
  select count(*) into v_count
  from storage.objects
  where bucket_id = 'trip-report-assets' and name = v_path;
  if v_count <> 1 then raise exception 'T8 FAILED: member cannot read registered private route object'; end if;
  select count(*) into v_count
  from storage.objects
  where bucket_id = 'trip-report-assets' and name = v_competing_path;
  if v_count <> 0 then raise exception 'T8 FAILED: member can read unregistered private route object'; end if;

  perform public._t226_login(v_stranger);
  select count(*) into v_count from public.trip_report_assets where trip_id = v_trip;
  if v_count <> 0 then raise exception 'T8 FAILED: stranger can read canonical metadata'; end if;
  select count(*) into v_count
  from storage.objects
  where bucket_id = 'trip-report-assets' and name = v_path;
  if v_count <> 0 then raise exception 'T8 FAILED: stranger can read registered private route object'; end if;

  -- T9: direct authenticated writes remain blocked even for a vineyard member.
  perform public._t226_login(v_member);
  v_state := null;
  begin
    insert into public.trip_report_assets (
      vineyard_id, trip_id, object_path, sha256, route_hash, created_by
    ) values (
      v_vineyard, v_trip, v_competing_path, v_competing_sha, v_competing_hash, v_member
    );
  exception when others then v_state := sqlstate;
  end;
  if v_state is null then raise exception 'T9 FAILED: authenticated member wrote metadata directly'; end if;

  raise notice 'SQL 226 controlled Spray Report route asset tests: ALL PASSED';
end;
$tests$;

rollback;

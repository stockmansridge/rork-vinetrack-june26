-- Dry-run acceptance for sql/281_trip_activity_cancellation_v1.sql.
-- Run AFTER the 281 body in the SAME transaction. It ALWAYS ends with an exception,
-- so every fixture row (and, when run together with 281, the 281 objects) roll back.
-- Success is reported as: DRYRUN_OK passed=<n> failures=<none>.
-- Fixtures live in vineyard 59973ced-1fb9-42ec-a66d-9eaad3172824 (JH Testing incident
-- vineyard), acting as its owner. The original Trip 3bfb7f81-... is never touched.
do $$
declare
  v_v uuid := '59973ced-1fb9-42ec-a66d-9eaad3172824';
  v_u uuid;
  t1 uuid := gen_random_uuid(); s1 uuid := gen_random_uuid(); op1 uuid := gen_random_uuid();
  t2 uuid := gen_random_uuid();
  t3 uuid := gen_random_uuid(); s3 uuid := gen_random_uuid(); a3 uuid := gen_random_uuid(); op3 uuid := gen_random_uuid();
  r jsonb; r2 jsonb; passed int := 0; failures text := '';
  procedure_name text;
begin
  select user_id into v_u from public.vineyard_members where vineyard_id = v_v and role = 'owner' limit 1;
  if v_u is null then raise exception 'DRYRUN_SETUP_NO_OWNER'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_u::text, true);
  if public.vineyard_role(v_v) is distinct from 'owner' then raise exception 'DRYRUN_SETUP_ROLE %', public.vineyard_role(v_v); end if;

  insert into public.trips (id, vineyard_id, start_time, is_active, created_by, trip_function)
    values (t1, v_v, now(), true, v_u, 'spraying');
  insert into public.spray_records (id, vineyard_id, trip_id, date, created_by) values (s1, v_v, t1, now(), v_u);

  -- 1. Not-applied cancellation of an active test Trip.
  r := public.cancel_trip_activity_v1(op1, t1, v_v, 'not_applied', '{"local_pending_operations":2}'::jsonb);
  if r->>'status' = 'CANCELLED_ACKED' and r->>'trip_id' = t1::text and r->>'operation_id' = op1::text
     and (r->'removed_counts'->>'spray_records')::int = 1 and r->>'replayed' = 'false'
     and exists (select 1 from public.trips where id = t1 and deleted_at is not null)
     and exists (select 1 from public.spray_records where id = s1 and deleted_at is not null)
  then passed := passed + 1; else failures := failures || ' 1:' || r::text; end if;

  -- 2. Identical replay returns the same receipt.
  r2 := public.cancel_trip_activity_v1(op1, t1, v_v, 'not_applied', '{}'::jsonb);
  if r2->>'server_revision' = r->>'server_revision' and r2->>'replayed' = 'true' then passed := passed + 1;
  else failures := failures || ' 2'; end if;

  -- 3. A new operation for the same Trip is rejected.
  begin
    perform public.cancel_trip_activity_v1(gen_random_uuid(), t1, v_v, 'not_applied', '{}'::jsonb);
    failures := failures || ' 3:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCEL_ALREADY_CANCELLED_OTHER_OPERATION' then passed := passed + 1; else failures := failures || ' 3:' || sqlerrm; end if;
  end;

  -- 4. Same operation id with different classification is rejected.
  begin
    perform public.cancel_trip_activity_v1(op1, t1, v_v, 'applied', '{"x":1}'::jsonb, '{"x":1}'::jsonb);
    failures := failures || ' 4:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCEL_OPERATION_CONFLICT' then passed := passed + 1; else failures := failures || ' 4:' || sqlerrm; end if;
  end;

  -- 5. Old client revives the Trip (update deleted_at=null).
  begin
    update public.trips set deleted_at = null where id = t1;
    failures := failures || ' 5:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLED_TOMBSTONE' then passed := passed + 1; else failures := failures || ' 5:' || sqlerrm; end if;
  end;

  -- 6. Old client re-inserts the Trip after a later hard delete (simulated by insert of same id).
  begin
    insert into public.trips (id, vineyard_id, start_time, is_active, created_by) values (t1, v_v, now(), true, v_u)
      on conflict (id) do update set is_active = true;
    failures := failures || ' 6:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLED_TOMBSTONE' then passed := passed + 1; else failures := failures || ' 6:' || sqlerrm; end if;
  end;

  -- 7. Old client re-uploads the linked spray record.
  begin
    update public.spray_records set deleted_at = null where id = s1;
    failures := failures || ' 7:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLED_TOMBSTONE' then passed := passed + 1; else failures := failures || ' 7:' || sqlerrm; end if;
  end;

  -- 8. New spray record pointing at the cancelled Trip.
  begin
    insert into public.spray_records (id, vineyard_id, trip_id, date, created_by) values (gen_random_uuid(), v_v, t1, now(), v_u);
    failures := failures || ' 8:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLED_TOMBSTONE' then passed := passed + 1; else failures := failures || ' 8:' || sqlerrm; end if;
  end;

  -- 9. Receipts are immutable.
  begin
    update public.trip_activity_cancellation_receipts set actor_role = 'x' where operation_id = op1;
    failures := failures || ' 9:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLATION_RECORD_IMMUTABLE' then passed := passed + 1; else failures := failures || ' 9:' || sqlerrm; end if;
  end;

  -- 10. Unrelated Trip is unaffected by the guard.
  insert into public.trips (id, vineyard_id, start_time, is_active, created_by) values (t2, v_v, now(), true, v_u);
  update public.trips set total_distance = 12.5 where id = t2;
  if exists (select 1 from public.trips where id = t2 and total_distance = 12.5 and deleted_at is null) then passed := passed + 1;
  else failures := failures || ' 10'; end if;

  -- 11. Server tank actual present: not_applied is held; applied requires facts, then archives.
  insert into public.trips (id, vineyard_id, start_time, is_active, created_by, tank_sessions)
    values (t3, v_v, now(), true, v_u, '[{"id":"dryrun-session-1","tank_number":1}]'::jsonb);
  insert into public.spray_records (id, vineyard_id, trip_id, date, created_by) values (s3, v_v, t3, now(), v_u);
  insert into public.spray_tank_actuals (id, vineyard_id, spray_record_id, trip_id, tank_session_id, tank_number, water_volume_l, chemicals, confirmed_at, client_updated_at)
    values (a3, v_v, s3, t3, 'dryrun-session-1', 1, 400, '[]'::jsonb, now(), now());
  begin
    perform public.cancel_trip_activity_v1(op3, t3, v_v, 'not_applied', '{}'::jsonb);
    failures := failures || ' 11a:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCEL_SERVER_ACTUALS_REQUIRE_APPLIED_REVIEW' then passed := passed + 1; else failures := failures || ' 11a:' || sqlerrm; end if;
  end;
  begin
    perform public.cancel_trip_activity_v1(op3, t3, v_v, 'applied', '{}'::jsonb, null);
    failures := failures || ' 11b:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCEL_COMPLIANCE_FACTS_REQUIRED' then passed := passed + 1; else failures := failures || ' 11b:' || sqlerrm; end if;
  end;
  r := public.cancel_trip_activity_v1(op3, t3, v_v, 'applied', '{}'::jsonb,
    '{"tanks":[{"tank_number":1,"water_volume_l":400,"chemicals":[]}]}'::jsonb);
  if r->>'compliance_archive_id' is not null and (r->'removed_counts'->>'spray_tank_actuals')::int = 1
     and exists (select 1 from public.trip_compliance_archive where operation_id = op3
       and jsonb_array_length(facts->'server_tank_actuals') = 1 and retain_until >= (now() + interval '3 years')::date)
     and exists (select 1 from public.spray_tank_actuals where id = a3 and deleted_at is not null)
  then passed := passed + 1; else failures := failures || ' 11c:' || r::text; end if;

  -- 12. Late actual upload for the cancelled Trip is rejected.
  begin
    insert into public.spray_tank_actuals (id, vineyard_id, spray_record_id, trip_id, tank_session_id, tank_number, water_volume_l, chemicals, confirmed_at, client_updated_at)
      values (gen_random_uuid(), v_v, s3, t3, 'dryrun-session-1', 1, 1, '[]'::jsonb, now(), now());
    failures := failures || ' 12:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLED_TOMBSTONE' then passed := passed + 1; else failures := failures || ' 12:' || sqlerrm; end if;
  end;

  -- 13. Non-member is refused with no receipt.
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  begin
    perform public.cancel_trip_activity_v1(gen_random_uuid(), t2, v_v, 'not_applied', '{}'::jsonb);
    failures := failures || ' 13:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCEL_FORBIDDEN' then passed := passed + 1; else failures := failures || ' 13:' || sqlerrm; end if;
  end;

  -- 14. Unauthenticated is refused.
  perform set_config('request.jwt.claims', '{}', true);
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.cancel_trip_activity_v1(gen_random_uuid(), t2, v_v, 'not_applied', '{}'::jsonb);
    failures := failures || ' 14:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCEL_AUTH_REQUIRED' then passed := passed + 1; else failures := failures || ' 14:' || sqlerrm; end if;
  end;

  raise exception 'DRYRUN_OK passed=% failures=%', passed, coalesce(nullif(failures, ''), 'none');
end $$;

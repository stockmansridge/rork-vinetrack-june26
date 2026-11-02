-- Single-statement rolled-back dry run: 281 body + acceptance, always raises.
do $wrap$ begin
execute $q281$

create table if not exists public.trip_activity_cancellation_receipts (
  operation_id uuid primary key,
  trip_id uuid not null unique,
  vineyard_id uuid not null,
  actor_user_id uuid not null,
  actor_role text not null,
  application_classification text not null check (application_classification in ('not_applied','applied')),
  compliance_archive_id uuid,
  spray_record_ids uuid[] not null default '{}',
  removed_counts jsonb not null,
  client_baseline jsonb not null default '{}'::jsonb,
  status text not null default 'CANCELLED_ACKED' check (status = 'CANCELLED_ACKED'),
  server_revision bigint generated always as identity unique,
  cancelled_at timestamptz not null default now()
);
create index if not exists trip_activity_cancellation_receipts_vineyard_idx
  on public.trip_activity_cancellation_receipts (vineyard_id);
create index if not exists trip_activity_cancellation_receipts_spray_idx
  on public.trip_activity_cancellation_receipts using gin (spray_record_ids);

create table if not exists public.trip_compliance_archive (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null unique,
  trip_id uuid not null,
  vineyard_id uuid not null,
  source text not null check (source = 'applied_trip_cancellation'),
  facts jsonb not null,
  retain_until date not null,
  created_by uuid not null,
  created_at timestamptz not null default now()
);
create index if not exists trip_compliance_archive_vineyard_idx on public.trip_compliance_archive (vineyard_id);

alter table public.trip_activity_cancellation_receipts enable row level security;
alter table public.trip_compliance_archive enable row level security;

drop policy if exists trip_cancel_receipts_member_read on public.trip_activity_cancellation_receipts;
create policy trip_cancel_receipts_member_read on public.trip_activity_cancellation_receipts
  for select to authenticated using (public.is_vineyard_member(vineyard_id));
drop policy if exists trip_compliance_archive_manager_read on public.trip_compliance_archive;
create policy trip_compliance_archive_manager_read on public.trip_compliance_archive
  for select to authenticated using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor']));

revoke all on public.trip_activity_cancellation_receipts from public, anon, authenticated;
revoke all on public.trip_compliance_archive from public, anon, authenticated;
grant select on public.trip_activity_cancellation_receipts to authenticated;
grant select on public.trip_compliance_archive to authenticated;

create or replace function public.trip_cancellation_immutable_v1() returns trigger
language plpgsql set search_path = pg_catalog, public as $fn$
begin
  raise exception 'TRIP_CANCELLATION_RECORD_IMMUTABLE' using errcode = '55000';
end $fn$;
drop trigger if exists trip_cancel_receipts_immutable on public.trip_activity_cancellation_receipts;
create trigger trip_cancel_receipts_immutable before update or delete on public.trip_activity_cancellation_receipts
  for each row execute function public.trip_cancellation_immutable_v1();
drop trigger if exists trip_compliance_archive_immutable on public.trip_compliance_archive;
create trigger trip_compliance_archive_immutable before update or delete on public.trip_compliance_archive
  for each row execute function public.trip_cancellation_immutable_v1();

create or replace function public.guard_cancelled_trip_v1() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $fn$
declare v_trip uuid;
begin
  if tg_table_name = 'trips' then
    v_trip := new.id;
  else
    v_trip := new.trip_id;
  end if;
  if (v_trip is not null and exists (select 1 from public.trip_activity_cancellation_receipts r where r.trip_id = v_trip))
     or (tg_table_name = 'spray_records' and exists (
       select 1 from public.trip_activity_cancellation_receipts r where r.spray_record_ids @> array[new.id])) then
    raise exception 'TRIP_CANCELLED_TOMBSTONE' using errcode = 'P0001',
      detail = 'This Trip was cancelled with a durable receipt. It cannot be recreated or changed.';
  end if;
  return new;
end $fn$;
revoke all on function public.guard_cancelled_trip_v1() from public, anon, authenticated;
revoke all on function public.trip_cancellation_immutable_v1() from public, anon, authenticated;

drop trigger if exists aa0_trip_cancellation_tombstone_guard on public.trips;
create trigger aa0_trip_cancellation_tombstone_guard before insert or update on public.trips
  for each row execute function public.guard_cancelled_trip_v1();
drop trigger if exists aa0_trip_cancellation_tombstone_guard on public.spray_records;
create trigger aa0_trip_cancellation_tombstone_guard before insert or update on public.spray_records
  for each row execute function public.guard_cancelled_trip_v1();
drop trigger if exists aa0_trip_cancellation_tombstone_guard on public.spray_tank_actuals;
create trigger aa0_trip_cancellation_tombstone_guard before insert or update on public.spray_tank_actuals
  for each row execute function public.guard_cancelled_trip_v1();
drop trigger if exists aa0_trip_cancellation_tombstone_guard on public.trip_cost_allocations;
create trigger aa0_trip_cancellation_tombstone_guard before insert or update on public.trip_cost_allocations
  for each row execute function public.guard_cancelled_trip_v1();

create or replace function public.trip_cancellation_receipt_json_v1(r public.trip_activity_cancellation_receipts)
returns jsonb language sql immutable set search_path = pg_catalog, public as $fn$
  select jsonb_build_object(
    'contract', 'vinetrack.trip-activity-cancellation', 'schemaVersion', 1,
    'status', r.status, 'operation_id', r.operation_id, 'trip_id', r.trip_id, 'vineyard_id', r.vineyard_id,
    'application_classification', r.application_classification, 'compliance_archive_id', r.compliance_archive_id,
    'spray_record_ids', to_jsonb(r.spray_record_ids), 'removed_counts', r.removed_counts,
    'server_revision', r.server_revision, 'cancelled_at', r.cancelled_at);
$fn$;
revoke all on function public.trip_cancellation_receipt_json_v1(public.trip_activity_cancellation_receipts) from public, anon;

create or replace function public.cancel_trip_activity_v1(
  p_operation_id uuid,
  p_trip_id uuid,
  p_vineyard_id uuid,
  p_application text,
  p_client_baseline jsonb default '{}'::jsonb,
  p_compliance_facts jsonb default null
) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $fn$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_trip public.trips;
  v_existing public.trip_activity_cancellation_receipts;
  v_receipt public.trip_activity_cancellation_receipts;
  v_spray uuid[];
  v_archive uuid;
  n_actuals integer := 0; n_spray integer := 0; n_cost integer := 0;
begin
  if v_uid is null then raise exception 'TRIP_CANCEL_AUTH_REQUIRED' using errcode = '42501'; end if;
  if p_operation_id is null or p_trip_id is null or p_vineyard_id is null then
    raise exception 'TRIP_CANCEL_INVALID_IDENTITY' using errcode = '22023';
  end if;
  if p_application is null or p_application not in ('not_applied', 'applied') then
    raise exception 'TRIP_CANCEL_CLASSIFICATION_REQUIRED' using errcode = '22023';
  end if;
  if p_client_baseline is null or jsonb_typeof(p_client_baseline) <> 'object' then
    raise exception 'TRIP_CANCEL_INVALID_BASELINE' using errcode = '22023';
  end if;
  v_role := public.vineyard_role(p_vineyard_id);
  if v_role is null or v_role not in ('owner', 'manager', 'supervisor') then
    raise exception 'TRIP_CANCEL_FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_existing from public.trip_activity_cancellation_receipts where operation_id = p_operation_id;
  if found then
    if v_existing.trip_id <> p_trip_id or v_existing.vineyard_id <> p_vineyard_id
       or v_existing.application_classification <> p_application then
      raise exception 'TRIP_CANCEL_OPERATION_CONFLICT' using errcode = '23505';
    end if;
    return public.trip_cancellation_receipt_json_v1(v_existing) || jsonb_build_object('replayed', true);
  end if;
  if exists (select 1 from public.trip_activity_cancellation_receipts where trip_id = p_trip_id) then
    raise exception 'TRIP_CANCEL_ALREADY_CANCELLED_OTHER_OPERATION' using errcode = '23505';
  end if;

  select * into v_trip from public.trips where id = p_trip_id for update;
  if not found or v_trip.vineyard_id <> p_vineyard_id then
    raise exception 'TRIP_CANCEL_TRIP_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_trip.deleted_at is not null then raise exception 'TRIP_CANCEL_TRIP_ALREADY_DELETED' using errcode = '55000'; end if;
  if v_trip.end_time is not null then raise exception 'TRIP_CANCEL_TRIP_COMPLETED' using errcode = '55000'; end if;
  if coalesce(v_trip.entry_source, '') = 'manual' then
    raise exception 'TRIP_CANCEL_MANUAL_ENTRY_UNSUPPORTED' using errcode = '0A000';
  end if;

  select coalesce(array_agg(id order by id), '{}') into v_spray
    from public.spray_records where trip_id = p_trip_id and vineyard_id = p_vineyard_id and deleted_at is null;
  if exists (select 1 from public.spray_records where id = any (v_spray) and coalesce(entry_source, '') = 'manual') then
    raise exception 'TRIP_CANCEL_MANUAL_ENTRY_UNSUPPORTED' using errcode = '0A000';
  end if;

  if p_application = 'not_applied' then
    if exists (select 1 from public.spray_tank_actuals where trip_id = p_trip_id and deleted_at is null) then
      raise exception 'TRIP_CANCEL_SERVER_ACTUALS_REQUIRE_APPLIED_REVIEW' using errcode = '55000';
    end if;
  else
    if p_compliance_facts is null or jsonb_typeof(p_compliance_facts) <> 'object' or p_compliance_facts = '{}'::jsonb then
      raise exception 'TRIP_CANCEL_COMPLIANCE_FACTS_REQUIRED' using errcode = '22023';
    end if;
    insert into public.trip_compliance_archive (operation_id, trip_id, vineyard_id, source, facts, retain_until, created_by)
    values (p_operation_id, p_trip_id, p_vineyard_id, 'applied_trip_cancellation',
      jsonb_build_object(
        'client_application_facts', p_compliance_facts,
        'server_trip', to_jsonb(v_trip),
        'server_spray_records', coalesce((select jsonb_agg(to_jsonb(s)) from public.spray_records s where s.id = any (v_spray)), '[]'::jsonb),
        'server_tank_actuals', coalesce((select jsonb_agg(to_jsonb(a)) from public.spray_tank_actuals a
          where a.trip_id = p_trip_id and a.deleted_at is null), '[]'::jsonb),
        'actor_user_id', v_uid, 'actor_role', v_role, 'archived_at', now()),
      (now() + interval '3 years')::date, v_uid)
    returning id into v_archive;
  end if;

  update public.spray_tank_actuals set deleted_at = now() where trip_id = p_trip_id and deleted_at is null;
  get diagnostics n_actuals = row_count;
  update public.trip_cost_allocations set deleted_at = now(), updated_by = v_uid where trip_id = p_trip_id and deleted_at is null;
  get diagnostics n_cost = row_count;
  update public.spray_records set deleted_at = now(), updated_by = v_uid where id = any (v_spray) and deleted_at is null;
  get diagnostics n_spray = row_count;
  update public.trips set deleted_at = now(), updated_by = v_uid where id = p_trip_id;

  insert into public.trip_activity_cancellation_receipts (operation_id, trip_id, vineyard_id, actor_user_id, actor_role,
    application_classification, compliance_archive_id, spray_record_ids, removed_counts, client_baseline)
  values (p_operation_id, p_trip_id, p_vineyard_id, v_uid, v_role, p_application, v_archive, v_spray,
    jsonb_build_object('trip', 1, 'spray_records', n_spray, 'spray_tank_actuals', n_actuals, 'trip_cost_allocations', n_cost),
    p_client_baseline)
  returning * into v_receipt;

  return public.trip_cancellation_receipt_json_v1(v_receipt) || jsonb_build_object('replayed', false);
end $fn$;

revoke all on function public.cancel_trip_activity_v1(uuid, uuid, uuid, text, jsonb, jsonb) from public, anon;
grant execute on function public.cancel_trip_activity_v1(uuid, uuid, uuid, text, jsonb, jsonb) to authenticated;

$q281$;
execute $qt281$
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

  r := public.cancel_trip_activity_v1(op1, t1, v_v, 'not_applied', '{"local_pending_operations":2}'::jsonb);
  if r->>'status' = 'CANCELLED_ACKED' and r->>'trip_id' = t1::text and r->>'operation_id' = op1::text
     and (r->'removed_counts'->>'spray_records')::int = 1 and r->>'replayed' = 'false'
     and exists (select 1 from public.trips where id = t1 and deleted_at is not null)
     and exists (select 1 from public.spray_records where id = s1 and deleted_at is not null)
  then passed := passed + 1; else failures := failures || ' 1:' || r::text; end if;

  r2 := public.cancel_trip_activity_v1(op1, t1, v_v, 'not_applied', '{}'::jsonb);
  if r2->>'server_revision' = r->>'server_revision' and r2->>'replayed' = 'true' then passed := passed + 1;
  else failures := failures || ' 2'; end if;

  begin
    perform public.cancel_trip_activity_v1(gen_random_uuid(), t1, v_v, 'not_applied', '{}'::jsonb);
    failures := failures || ' 3:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCEL_ALREADY_CANCELLED_OTHER_OPERATION' then passed := passed + 1; else failures := failures || ' 3:' || sqlerrm; end if;
  end;

  begin
    perform public.cancel_trip_activity_v1(op1, t1, v_v, 'applied', '{"x":1}'::jsonb, '{"x":1}'::jsonb);
    failures := failures || ' 4:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCEL_OPERATION_CONFLICT' then passed := passed + 1; else failures := failures || ' 4:' || sqlerrm; end if;
  end;

  begin
    update public.trips set deleted_at = null where id = t1;
    failures := failures || ' 5:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLED_TOMBSTONE' then passed := passed + 1; else failures := failures || ' 5:' || sqlerrm; end if;
  end;

  begin
    insert into public.trips (id, vineyard_id, start_time, is_active, created_by) values (t1, v_v, now(), true, v_u)
      on conflict (id) do update set is_active = true;
    failures := failures || ' 6:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLED_TOMBSTONE' then passed := passed + 1; else failures := failures || ' 6:' || sqlerrm; end if;
  end;

  begin
    update public.spray_records set deleted_at = null where id = s1;
    failures := failures || ' 7:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLED_TOMBSTONE' then passed := passed + 1; else failures := failures || ' 7:' || sqlerrm; end if;
  end;

  begin
    insert into public.spray_records (id, vineyard_id, trip_id, date, created_by) values (gen_random_uuid(), v_v, t1, now(), v_u);
    failures := failures || ' 8:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLED_TOMBSTONE' then passed := passed + 1; else failures := failures || ' 8:' || sqlerrm; end if;
  end;

  begin
    update public.trip_activity_cancellation_receipts set actor_role = 'x' where operation_id = op1;
    failures := failures || ' 9:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLATION_RECORD_IMMUTABLE' then passed := passed + 1; else failures := failures || ' 9:' || sqlerrm; end if;
  end;

  insert into public.trips (id, vineyard_id, start_time, is_active, created_by) values (t2, v_v, now(), true, v_u);
  update public.trips set total_distance = 12.5 where id = t2;
  if exists (select 1 from public.trips where id = t2 and total_distance = 12.5 and deleted_at is null) then passed := passed + 1;
  else failures := failures || ' 10'; end if;

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

  begin
    insert into public.spray_tank_actuals (id, vineyard_id, spray_record_id, trip_id, tank_session_id, tank_number, water_volume_l, chemicals, confirmed_at, client_updated_at)
      values (gen_random_uuid(), v_v, s3, t3, 'dryrun-session-1', 1, 1, '[]'::jsonb, now(), now());
    failures := failures || ' 12:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCELLED_TOMBSTONE' then passed := passed + 1; else failures := failures || ' 12:' || sqlerrm; end if;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  begin
    perform public.cancel_trip_activity_v1(gen_random_uuid(), t2, v_v, 'not_applied', '{}'::jsonb);
    failures := failures || ' 13:not_raised';
  exception when others then
    if sqlerrm = 'TRIP_CANCEL_FORBIDDEN' then passed := passed + 1; else failures := failures || ' 13:' || sqlerrm; end if;
  end;

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

$qt281$;
end $wrap$;

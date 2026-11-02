-- 281: Trip activity cancellation v1 (P0 3.1.9, Phase A)
--
-- Contract: docs/sync/TRIP_DELETION_CASCADE_CONTRACT_V1.md and
-- docs/sync/P0_TRIP_START_END_CANCELLATION_ACCEPTANCE_GATE_20261102.md section 5.
--
-- Additive only. Creates:
--   * trip_activity_cancellation_receipts: durable, immutable anti-resurrection
--     receipt kept OUTSIDE the Trip FK graph (survives any later hard delete).
--   * trip_compliance_archive: immutable, access-controlled pesticide-application
--     record for cancellations of a Trip where chemical WAS applied (NSW EPA >= 3y).
--   * cancel_trip_activity_v1(...): authenticated, owner/manager/supervisor,
--     vineyard-scoped, all-or-nothing, idempotent by operation id. Soft-removes
--     the Trip's exclusively owned operational rows (tank actuals, cost
--     allocations, linked spray records) and the Trip itself, then writes the receipt.
--   * Tombstone guards on trips / spray_records / spray_tank_actuals /
--     trip_cost_allocations: once a receipt exists, ANY insert or update for that
--     Trip (including older 3.1.8 clients and the occurrence RPCs) is rejected with
--     TRIP_CANCELLED_TOMBSTONE. Nothing is revived, nothing is hard-deleted.
--
-- It never fabricates tank sessions, never changes existing rows on deploy, never
-- changes ownership or grants of existing functions, and leaves shared master data
-- (vineyard, blocks, equipment, chemicals, people, Spray Jobs, Work Tasks) untouched.

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

-- Receipts and archive rows are immutable once written.
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

-- Anti-resurrection guard. SECURITY DEFINER so the receipt lookup is not hidden by RLS.
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

  -- Idempotent replay of the SAME operation returns the SAME receipt.
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
    -- A missing row is never treated as a successful deletion.
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
    -- Confirmed tank contents on the server mean evidence is ambiguous: hold, never erase.
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

  -- Children first: the tank-actual writer requires a live parent Trip.
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

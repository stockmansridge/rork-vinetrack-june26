-- Protected nullable Trip labour snapshot; no historical data update or backfill.
-- Existing trip_cost_allocations SELECT/INSERT/UPDATE remain owner/manager only;
-- DELETE remains blocked. The operational trips table is not changed.
begin;

alter table public.trip_cost_allocations
  add column if not exists worker_user_id uuid null,
  add column if not exists worker_type_id uuid null,
  add column if not exists worker_type_name_snapshot text null,
  add column if not exists hourly_rate_snapshot numeric null,
  add column if not exists labour_hours numeric null,
  add column if not exists rate_captured_at timestamptz null;

-- A single protected start marker per Trip, distinct from block/variety slices.
-- The existing slice uniqueness and financial policies are unchanged.
create unique index if not exists uq_trip_labour_snapshot_active
  on public.trip_cost_allocations (trip_id)
  where allocation_basis = 'labour_snapshot' and deleted_at is null;

-- Write-only scoped entry point: operators may record their OWN trip's start
-- snapshot but cannot SELECT financial allocations via this function or RLS.
-- First writer wins; an already-finalised snapshot cannot be replaced.
create or replace function public.capture_trip_labour_start_v1(
  p_trip_id uuid, p_worker_user_id uuid, p_worker_type_id uuid,
  p_worker_type_name text, p_hourly_rate numeric, p_captured_at timestamptz
) returns void language plpgsql security definer set search_path = public as $fn$
declare t public.trips%rowtype; s public.trip_cost_allocations%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select * into t from public.trips where id = p_trip_id and deleted_at is null for update;
  if t.id is null or not public.has_vineyard_role(t.vineyard_id, array['owner','manager','supervisor','operator'])
     or (auth.uid() <> t.operator_user_id and not public.has_vineyard_role(t.vineyard_id, array['owner','manager'])) then
    raise exception 'Trip labour capture not permitted' using errcode = '42501';
  end if;
  -- Never create a new snapshot for trips that predate this contract.
  if t.created_at < timestamptz '2026-09-27 00:00:00+00' then
    raise exception 'Historical Trip cannot be snapshotted' using errcode = '22023';
  end if;
  if p_worker_user_id is distinct from t.operator_user_id or p_captured_at is null
     or t.start_time is null or abs(extract(epoch from (p_captured_at - t.start_time))) > 1
     or (p_worker_type_id is null and p_hourly_rate is not null)
     or p_hourly_rate < 0 or p_hourly_rate > 10000
     or (p_worker_type_id is not null and not exists (
        select 1 from public.worker_types wt where wt.id = p_worker_type_id and wt.vineyard_id = t.vineyard_id
     )) then
    raise exception 'Invalid Trip labour start snapshot' using errcode = '22023';
  end if;
  select * into s from public.trip_cost_allocations
    where trip_id = p_trip_id and allocation_basis = 'labour_snapshot' and deleted_at is null;
  if s.id is not null then
    if s.worker_user_id is distinct from p_worker_user_id
       or s.worker_type_id is distinct from p_worker_type_id
       or s.hourly_rate_snapshot is distinct from p_hourly_rate
       or s.worker_type_name_snapshot is distinct from nullif(btrim(p_worker_type_name), '')
       or abs(extract(epoch from (s.rate_captured_at - p_captured_at))) > 1 then
      raise exception 'Trip labour start snapshot already captured' using errcode = '23505';
    end if;
    return;
  end if;
  -- Never retrofit a legacy trip that already has saved costs.
  if exists (select 1 from public.trip_cost_allocations where trip_id = p_trip_id and deleted_at is null) then
    raise exception 'Trip already has cost allocations' using errcode = '23505';
  end if;
  insert into public.trip_cost_allocations (
    vineyard_id, trip_id, season_year, trip_function, allocation_basis, costing_status,
    worker_user_id, worker_type_id, worker_type_name_snapshot, hourly_rate_snapshot,
    rate_captured_at, created_by, updated_by
  ) values (
    t.vineyard_id, t.id, public.resolve_vineyard_vintage_year(t.vineyard_id, t.start_time::date), t.trip_function,
    'labour_snapshot', 'unavailable', p_worker_user_id, p_worker_type_id,
    nullif(btrim(p_worker_type_name), ''), p_hourly_rate, p_captured_at, auth.uid(), auth.uid()
  );
end;
$fn$;

revoke all on function public.capture_trip_labour_start_v1(uuid,uuid,uuid,text,numeric,timestamptz) from public;
grant execute on function public.capture_trip_labour_start_v1(uuid,uuid,uuid,text,numeric,timestamptz) to authenticated;

-- Authoritative hours come from the saved Trip clocks (including pauses), not
-- a caller-supplied duration or today's worker type. Idempotent after finish.
create or replace function public.finalise_trip_labour_v1(p_trip_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
declare t public.trips%rowtype; s public.trip_cost_allocations%rowtype; v_hours numeric; v_cost numeric;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select * into t from public.trips where id = p_trip_id and deleted_at is null for update;
  if t.id is null or not public.has_vineyard_role(t.vineyard_id, array['owner','manager','supervisor','operator'])
     or (auth.uid() <> t.operator_user_id and not public.has_vineyard_role(t.vineyard_id, array['owner','manager'])) then
    raise exception 'Trip labour finalisation not permitted' using errcode = '42501';
  end if;
  if t.end_time is null or t.is_active then
    raise exception 'Trip is not finalised' using errcode = '22023';
  end if;
  select * into s from public.trip_cost_allocations
    where trip_id = p_trip_id and allocation_basis = 'labour_snapshot' and deleted_at is null for update;
  if s.id is null then raise exception 'No Trip start snapshot' using errcode = '22023'; end if;
  if s.labour_hours is not null then return; end if;
  v_hours := public.spray_report_active_seconds_v1(t.start_time, t.end_time, t.pause_timestamps, t.resume_timestamps)::numeric / 3600;
  v_cost := case when s.hourly_rate_snapshot is not null then round(s.hourly_rate_snapshot * v_hours, 2) else null end;
  update public.trip_cost_allocations set labour_hours = v_hours,
    labour_cost = v_cost, total_cost = v_cost,
    costing_status = case when v_cost is null then 'unavailable' else 'complete' end,
    calculated_at = now(), source_trip_updated_at = t.updated_at, updated_by = auth.uid()
  where id = s.id;
end;
$fn$;

revoke all on function public.finalise_trip_labour_v1(uuid) from public;
grant execute on function public.finalise_trip_labour_v1(uuid) to authenticated;
commit;

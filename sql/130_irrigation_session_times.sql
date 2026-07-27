-- ============================================================================
-- SQL 130 — Irrigation session start/end times with authoritative duration
-- ============================================================================
-- Phase 1 recording enhancement. `irrigation_sessions.started_at` and
-- `finished_at` already exist (SQL 125) and were stored unvalidated. This
-- migration makes the time pair authoritative over the entered duration:
--
--   * start-only sessions remain allowed (start + duration workflow);
--   * an end time without a start time is rejected;
--   * when both times are present the derived duration
--       round(epoch(finished - started) / 60)
--     must be > 0, <= 10080 minutes (the existing 7-day table constraint is
--     retained — it already allows runs longer than 24 h, so that rule is
--     kept rather than tightened), and must equal p_duration_minutes exactly.
--     Conflicting values are rejected with `duration_mismatch`, never saved
--     silently.
--
-- Overnight sessions: clients construct absolute timestamptz values from the
-- LOCAL session date + wall-clock times in the user's timezone, adding one
-- day to the end when it is earlier than (or equal to) the start. The server
-- therefore only requires finished_at > started_at. session_date remains the
-- client-supplied local date, so the local date relationship is preserved
-- even though timestamptz is stored normalised.
--
-- update_irrigation_session gains `p_clear_times` (default false) so an edit
-- can explicitly remove stored times; the old null-means-keep contract is
-- unchanged for every existing caller.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Shared time validation helper
-- ---------------------------------------------------------------------------

create or replace function public._irrigation_validate_session_times(
  p_started_at timestamptz,
  p_finished_at timestamptz,
  p_duration_minutes integer
) returns void
language plpgsql
immutable
as $$
declare
  v_derived integer;
begin
  if p_started_at is null and p_finished_at is null then
    return;  -- duration-only workflow
  end if;
  if p_finished_at is not null and p_started_at is null then
    raise exception 'invalid_times: an end time requires a start time';
  end if;
  if p_finished_at is null then
    return;  -- start + duration workflow: start-only is allowed
  end if;
  if p_finished_at <= p_started_at then
    raise exception 'invalid_times: the end time must be after the start time — overnight sessions must end on the following day';
  end if;
  v_derived := round(extract(epoch from (p_finished_at - p_started_at)) / 60.0)::integer;
  if v_derived <= 0 then
    raise exception 'invalid_duration: irrigation duration must be greater than zero';
  end if;
  if v_derived > 10080 then
    raise exception 'invalid_duration: irrigation duration exceeds the allowed maximum of 7 days (10,080 minutes)';
  end if;
  if p_duration_minutes is not null and p_duration_minutes <> v_derived then
    raise exception 'duration_mismatch: the entered duration (% min) does not match the start and end times (% min)',
      p_duration_minutes, v_derived;
  end if;
end;
$$;

grant execute on function public._irrigation_validate_session_times(timestamptz, timestamptz, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. record_irrigation_session — same signature, time validation added
-- ---------------------------------------------------------------------------

create or replace function public.record_irrigation_session(
  p_id uuid,
  p_vineyard_id uuid,
  p_irrigation_system_id uuid,
  p_valve_id uuid,
  p_session_date date,
  p_duration_minutes integer,
  p_calculation_method text,
  p_flow_litres_per_hour numeric default null,
  p_meter_start_litres numeric default null,
  p_meter_finish_litres numeric default null,
  p_total_volume_litres numeric default null,
  p_started_at timestamptz default null,
  p_finished_at timestamptz default null,
  p_notes text default null,
  p_source_type text default 'manual_portal',
  p_original_value numeric default null,
  p_original_unit text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.irrigation_sessions;
  v_calc jsonb;
  v_vintage integer;
  v_block jsonb;
  v_session public.irrigation_sessions;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  if p_id is null then
    raise exception 'invalid_id: the client must generate the session id';
  end if;

  -- Idempotent offline retry: same id -> return the stored result unchanged.
  select * into v_existing from public.irrigation_sessions where id = p_id;
  if found then
    return public._irrigation_session_json(p_id) || jsonb_build_object('duplicate', true);
  end if;

  if p_session_date is null then
    raise exception 'invalid_date: a session date is required';
  end if;
  if p_source_type not in ('manual_ios','manual_android','manual_portal') then
    raise exception 'invalid_source: unsupported source type for manual recording';
  end if;
  if not exists (
    select 1 from public.irrigation_valves
    where id = p_valve_id and irrigation_system_id = p_irrigation_system_id
  ) then
    raise exception 'invalid_valve: the valve does not belong to the selected irrigation system';
  end if;

  -- SQL 130: when both times are supplied their difference is authoritative
  -- and must match the entered duration; conflicts are never saved silently.
  perform public._irrigation_validate_session_times(p_started_at, p_finished_at, p_duration_minutes);

  v_calc := public._irrigation_compute(
    p_vineyard_id, p_valve_id, p_duration_minutes, p_calculation_method,
    p_flow_litres_per_hour, p_meter_start_litres, p_meter_finish_litres, p_total_volume_litres);

  v_vintage := public.resolve_vineyard_vintage_year(p_vineyard_id, p_session_date);

  insert into public.irrigation_sessions (
    id, vineyard_id, irrigation_system_id, valve_id, session_date, vintage_year,
    started_at, finished_at, duration_minutes, calculation_method,
    flow_litres_per_hour, meter_start_litres, meter_finish_litres,
    total_volume_litres, effective_volume_litres, original_value, original_unit,
    irrigation_efficiency_percent, status, source_type, notes,
    configuration_snapshot, created_by, updated_by
  ) values (
    p_id, p_vineyard_id, p_irrigation_system_id, p_valve_id, p_session_date, v_vintage,
    p_started_at, p_finished_at, p_duration_minutes, p_calculation_method,
    (v_calc->>'flow_litres_per_hour_used')::numeric, p_meter_start_litres, p_meter_finish_litres,
    (v_calc->>'total_volume_litres')::numeric,
    nullif(v_calc->>'effective_volume_litres', '')::numeric,
    p_original_value, p_original_unit,
    nullif(v_calc->>'irrigation_efficiency_percent', '')::numeric,
    'completed', p_source_type, p_notes,
    v_calc->'configuration_snapshot', auth.uid(), auth.uid()
  )
  on conflict (id) do nothing;

  -- Raced replay: someone inserted the same id between our check and insert.
  select * into v_session from public.irrigation_sessions where id = p_id;
  if v_session.created_by is distinct from auth.uid()
     or exists (select 1 from public.irrigation_session_blocks where session_id = p_id) then
    return public._irrigation_session_json(p_id) || jsonb_build_object('duplicate', true);
  end if;

  for v_block in select * from jsonb_array_elements(v_calc->'blocks') loop
    insert into public.irrigation_session_blocks (
      session_id, vineyard_id, valve_id, block_id, variety_id, variety_name,
      allocation_method, allocation_percentage, allocated_volume_litres,
      effective_volume_litres, serviced_area_m2, serviced_vine_count,
      water_litres_per_vine, water_litres_per_hectare,
      irrigation_depth_mm, effective_irrigation_depth_mm
    ) values (
      p_id, p_vineyard_id, p_valve_id,
      (v_block->>'block_id')::uuid,
      nullif(v_block->>'variety_id', '')::uuid,
      nullif(v_block->>'variety_name', ''),
      v_block->>'allocation_method',
      (v_block->>'allocation_percentage')::numeric,
      (v_block->>'allocated_volume_litres')::numeric,
      nullif(v_block->>'effective_volume_litres', '')::numeric,
      nullif(v_block->>'serviced_area_m2', '')::numeric,
      nullif(v_block->>'serviced_vine_count', '')::integer,
      nullif(v_block->>'water_litres_per_vine', '')::numeric,
      nullif(v_block->>'water_litres_per_hectare', '')::numeric,
      nullif(v_block->>'irrigation_depth_mm', '')::numeric,
      nullif(v_block->>'effective_irrigation_depth_mm', '')::numeric
    );
  end loop;

  perform public._irrigation_audit(p_vineyard_id, 'create', 'irrigation_session', p_id,
    null, public._irrigation_session_json(p_id));

  return public._irrigation_session_json(p_id)
         || jsonb_build_object('duplicate', false, 'warnings', coalesce(v_calc->'warnings', '[]'::jsonb));
end;
$$;

grant execute on function public.record_irrigation_session(uuid, uuid, uuid, uuid, date, integer, text, numeric, numeric, numeric, numeric, timestamptz, timestamptz, text, text, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. update_irrigation_session — adds p_clear_times + time validation
-- ---------------------------------------------------------------------------
-- The signature gains one trailing defaulted parameter, so the old function
-- must be dropped first (create or replace would create an ambiguous
-- overload). Existing callers that omit p_clear_times are unaffected.

drop function if exists public.update_irrigation_session(
  uuid, date, integer, text, numeric, numeric, numeric, numeric,
  timestamptz, timestamptz, text, boolean);

create or replace function public.update_irrigation_session(
  p_id uuid,
  p_session_date date default null,
  p_duration_minutes integer default null,
  p_calculation_method text default null,
  p_flow_litres_per_hour numeric default null,
  p_meter_start_litres numeric default null,
  p_meter_finish_litres numeric default null,
  p_total_volume_litres numeric default null,
  p_started_at timestamptz default null,
  p_finished_at timestamptz default null,
  p_notes text default null,
  p_use_current_configuration boolean default false,
  p_clear_times boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.irrigation_sessions;
  v_old_json jsonb;
  v_date date;
  v_duration integer;
  v_method text;
  v_flow numeric;
  v_meter_start numeric;
  v_meter_finish numeric;
  v_volume numeric;
  v_flow_used numeric;
  v_total numeric;
  v_allocs jsonb;
  v_result jsonb;
  v_snapshot jsonb;
  v_vintage integer;
  v_block jsonb;
  v_started timestamptz;
  v_finished timestamptz;
begin
  select * into v_old from public.irrigation_sessions where id = p_id;
  if not found then
    raise exception 'not_found: irrigation session not found';
  end if;
  perform public._irrigation_require_access(v_old.vineyard_id);
  if v_old.status = 'reversed' or v_old.deleted_at is not null then
    raise exception 'session_reversed: a reversed session cannot be edited';
  end if;

  v_old_json := public._irrigation_session_json(p_id);

  v_date := coalesce(p_session_date, v_old.session_date);
  v_duration := coalesce(p_duration_minutes, v_old.duration_minutes);
  v_method := coalesce(p_calculation_method, v_old.calculation_method);
  v_flow := coalesce(p_flow_litres_per_hour, v_old.flow_litres_per_hour);
  v_meter_start := coalesce(p_meter_start_litres, v_old.meter_start_litres);
  v_meter_finish := coalesce(p_meter_finish_litres, v_old.meter_finish_litres);
  v_volume := coalesce(p_total_volume_litres, v_old.total_volume_litres);

  -- SQL 130: resolve the final time pair (null still means "keep"; clearing
  -- is an explicit action) and validate it against the final duration so a
  -- stale stored time pair can never silently conflict with a new duration.
  if p_clear_times then
    v_started := null;
    v_finished := null;
  else
    v_started := coalesce(p_started_at, v_old.started_at);
    v_finished := coalesce(p_finished_at, v_old.finished_at);
  end if;
  perform public._irrigation_validate_session_times(v_started, v_finished, v_duration);

  if p_use_current_configuration then
    -- Explicit user action: recalculate against today's valve configuration.
    v_result := public._irrigation_compute(
      v_old.vineyard_id, v_old.valve_id, v_duration, v_method,
      case when v_method = 'session_flow' then v_flow else null end,
      v_meter_start, v_meter_finish, v_volume);
    v_flow_used := nullif(v_result->>'flow_litres_per_hour_used', '')::numeric;
    v_snapshot := v_result->'configuration_snapshot';
  else
    -- Default: reuse the frozen snapshot configuration.
    v_allocs := v_old.configuration_snapshot->'blocks';
    if v_method = 'configured_flow' then
      v_flow_used := coalesce(
        nullif(v_old.configuration_snapshot->>'valve_configured_flow_lph', '')::numeric,
        v_old.flow_litres_per_hour);
      if v_flow_used is null then
        raise exception 'missing_configured_flow: the saved configuration has no flow rate — choose another calculation method';
      end if;
    elsif v_method = 'session_flow' then
      v_flow_used := v_flow;
    else
      v_flow_used := null;
    end if;
    v_total := public.irrigation_total_volume(
      v_method, v_flow_used, v_duration, v_meter_start, v_meter_finish, v_volume);
    v_result := public._irrigation_allocate(v_total, v_allocs);
    v_snapshot := v_old.configuration_snapshot
      || jsonb_build_object('flow_lph_used', v_flow_used, 'calculation_method', v_method);
  end if;

  v_vintage := case
    when v_date is distinct from v_old.session_date
      then public.resolve_vineyard_vintage_year(v_old.vineyard_id, v_date)
    else v_old.vintage_year end;

  update public.irrigation_sessions
  set session_date = v_date,
      vintage_year = v_vintage,
      started_at = v_started,
      finished_at = v_finished,
      duration_minutes = v_duration,
      calculation_method = v_method,
      flow_litres_per_hour = v_flow_used,
      meter_start_litres = v_meter_start,
      meter_finish_litres = v_meter_finish,
      total_volume_litres = (v_result->>'total_volume_litres')::numeric,
      effective_volume_litres = nullif(v_result->>'effective_volume_litres', '')::numeric,
      irrigation_efficiency_percent = nullif(v_result->>'irrigation_efficiency_percent', '')::numeric,
      status = 'corrected',
      notes = coalesce(p_notes, notes),
      configuration_snapshot = v_snapshot,
      updated_by = auth.uid()
  where id = p_id;

  -- Replace the allocation rows (prior values preserved in irrigation_audit).
  delete from public.irrigation_session_blocks where session_id = p_id;
  for v_block in select * from jsonb_array_elements(v_result->'blocks') loop
    insert into public.irrigation_session_blocks (
      session_id, vineyard_id, valve_id, block_id, variety_id, variety_name,
      allocation_method, allocation_percentage, allocated_volume_litres,
      effective_volume_litres, serviced_area_m2, serviced_vine_count,
      water_litres_per_vine, water_litres_per_hectare,
      irrigation_depth_mm, effective_irrigation_depth_mm
    ) values (
      p_id, v_old.vineyard_id, v_old.valve_id,
      (v_block->>'block_id')::uuid,
      nullif(v_block->>'variety_id', '')::uuid,
      nullif(v_block->>'variety_name', ''),
      coalesce(v_block->>'allocation_method', 'manual_percentage'),
      (v_block->>'allocation_percentage')::numeric,
      (v_block->>'allocated_volume_litres')::numeric,
      nullif(v_block->>'effective_volume_litres', '')::numeric,
      nullif(v_block->>'serviced_area_m2', '')::numeric,
      nullif(v_block->>'serviced_vine_count', '')::integer,
      nullif(v_block->>'water_litres_per_vine', '')::numeric,
      nullif(v_block->>'water_litres_per_hectare', '')::numeric,
      nullif(v_block->>'irrigation_depth_mm', '')::numeric,
      nullif(v_block->>'effective_irrigation_depth_mm', '')::numeric
    );
  end loop;

  perform public._irrigation_audit(v_old.vineyard_id, 'edit', 'irrigation_session', p_id,
    v_old_json, public._irrigation_session_json(p_id));

  return public._irrigation_session_json(p_id)
         || jsonb_build_object('warnings', coalesce(v_result->'warnings', '[]'::jsonb));
end;
$$;

grant execute on function public.update_irrigation_session(uuid, date, integer, text, numeric, numeric, numeric, numeric, timestamptz, timestamptz, text, boolean, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Regression tests — mirror of the iOS/Android time-parity fixtures
-- ---------------------------------------------------------------------------

do $$
declare
  v_failed boolean;
begin
  -- Same-day session: 08:30 -> 11:45 = 195 min (3 hr 15 min).
  perform public._irrigation_validate_session_times(
    '2026-01-05 08:30+11'::timestamptz, '2026-01-05 11:45+11'::timestamptz, 195);

  -- Partial hour: 10:00 -> 11:30 = 90 min.
  perform public._irrigation_validate_session_times(
    '2026-01-05 10:00+11'::timestamptz, '2026-01-05 11:30+11'::timestamptz, 90);

  -- Overnight session (client adds one day to the end): 22:00 -> 02:00 = 240 min.
  perform public._irrigation_validate_session_times(
    '2026-01-05 22:00+11'::timestamptz, '2026-01-06 02:00+11'::timestamptz, 240);

  -- Start-only (start + duration workflow) and duration-only are allowed.
  perform public._irrigation_validate_session_times(
    '2026-01-05 08:30+11'::timestamptz, null, 300);
  perform public._irrigation_validate_session_times(null, null, 60);

  -- Zero-minute session (equal start and end) rejected.
  v_failed := false;
  begin
    perform public._irrigation_validate_session_times(
      '2026-01-05 08:30+11'::timestamptz, '2026-01-05 08:30+11'::timestamptz, null);
  exception when others then v_failed := true; end;
  assert v_failed, 'equal start and end must be rejected';

  -- End before start (negative duration) rejected — clients must roll
  -- overnight ends to the following day before submitting.
  v_failed := false;
  begin
    perform public._irrigation_validate_session_times(
      '2026-01-05 22:00+11'::timestamptz, '2026-01-05 02:00+11'::timestamptz, 240);
  exception when others then v_failed := true; end;
  assert v_failed, 'an end before the start must be rejected';

  -- Conflicting manual duration rejected, never saved silently.
  v_failed := false;
  begin
    perform public._irrigation_validate_session_times(
      '2026-01-05 08:30+11'::timestamptz, '2026-01-05 11:45+11'::timestamptz, 200);
  exception when others then v_failed := true; end;
  assert v_failed, 'a conflicting manual duration must be rejected';

  -- End time without a start time rejected.
  v_failed := false;
  begin
    perform public._irrigation_validate_session_times(
      null, '2026-01-05 11:45+11'::timestamptz, 195);
  exception when others then v_failed := true; end;
  assert v_failed, 'an end time without a start time must be rejected';

  -- Session longer than the retained 7-day maximum rejected.
  v_failed := false;
  begin
    perform public._irrigation_validate_session_times(
      '2026-01-05 08:00+11'::timestamptz, '2026-01-13 09:00+11'::timestamptz, null);
  exception when others then v_failed := true; end;
  assert v_failed, 'a session longer than 7 days must be rejected';

  raise notice 'SQL 130 session time validation tests passed';
end $$;

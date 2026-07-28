-- ============================================================================
-- SQL 131 — Resolve configured irrigation flow from valve and row setup
-- ============================================================================
-- A valve can now automatically determine its operational flow rate from the
-- best available configured source. Resolution priority (System-Administrator
-- gated feature, unchanged):
--
--   1. Explicit measured valve flow      (irrigation_valves.measured_flow_litres_per_hour)
--   2. Explicit configured valve flow    (irrigation_valves.configured_flow_litres_per_hour)
--   3. Sum of connected block/row emitter flow
--        rows method:      saved SELECTED emitter count (irrigation_valve_rows,
--                          complete-only — never a partial sum)
--                          × paddocks.flow_per_emitter, per block, then summed
--        non-row methods:  a valid block-specific configured flow
--                          (irrigation_valve_blocks.configured_flow_litres_per_hour),
--                          otherwise serviced_emitter_count × flow_per_emitter
--   4. Unavailable — when ANY required connected component is missing the
--      whole resolution is unavailable. A partial total is never returned.
--
-- The stored valve flow values are NEVER silently replaced; the source is
-- returned separately:
--   resolved_flow_litres_per_hour numeric | null
--   resolved_flow_source          measured_valve_flow | configured_valve_flow |
--                                 row_emitter_flow | block_emitter_flow | unavailable
--   resolved_flow_is_estimated    false (explicit valve flow) / true (derived) / null
--   resolved_flow_warning         first warning text | null
--   resolved_flow_warnings        all warnings
--   resolved_flow_emitter_count   total emitters used (only when every
--                                 contributing block used emitters)
--   resolved_flow_blocks          per-block detail: emitter count,
--                                 flow-per-emitter and block flow used
--
-- Missing block emitter output is NULL, never zero. `flow_per_emitter` is
-- double precision in paddocks — every caller casts to numeric (SQL 128 rule).
--
-- Updated RPCs (public signatures unchanged unless noted):
--   validate_irrigation_configuration  + configured_flow_available,
--                                        resolved_flow_* fields;
--                                        requires_volume_entry now reflects the
--                                        RESOLVED flow, not just the stored one
--   calculate_irrigation_preview       (via _irrigation_compute) configured_flow
--                                        uses the shared resolver; returns
--                                        flow_source / flow_is_estimated /
--                                        flow_explanation
--   record_irrigation_session          (via _irrigation_compute) snapshot gains
--                                        the full `resolved_flow` object
--   update_irrigation_session          snapshot edits of configured_flow
--                                        sessions reuse the FROZEN resolved
--                                        flow — historical sessions keep the
--                                        flow used at recording time
--   get_irrigation_setup_status        per-valve automatic_flow_ready +
--                                        resolved_flow_* fields;
--                                        required.valves_with_automatic_flow
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Pure resolution core (immutable — regression-tested below and mirrored
--    by IrrigationLocalCalculator.resolveFlow in Swift and
--    IrrigationLocalCalc.resolveFlow in Kotlin)
-- ---------------------------------------------------------------------------
-- p_blocks: [{ block_id, block_name, allocation_method,
--              emitter_count            (complete saved count, null if unknown),
--              flow_per_emitter_lph     (null when missing/invalid),
--              block_configured_flow_lph (non-rows methods only) }]

create or replace function public._irrigation_resolve_flow(
  p_measured_flow_lph numeric,
  p_configured_flow_lph numeric,
  p_blocks jsonb
) returns jsonb
language plpgsql
immutable
as $$
declare
  v_el jsonb;
  v_name text;
  v_method text;
  v_emitters numeric;
  v_fpe numeric;
  v_block_cfg numeric;
  v_block_flow numeric;
  v_total numeric := 0;
  v_total_emitters numeric := 0;
  v_all_emitters boolean := true;
  v_all_rows boolean := true;
  v_any boolean := false;
  v_warnings jsonb := '[]'::jsonb;
  v_components jsonb := '[]'::jsonb;
begin
  -- Priority 1: explicit measured valve flow.
  if p_measured_flow_lph is not null and p_measured_flow_lph > 0 then
    return jsonb_build_object(
      'resolved_flow_litres_per_hour', p_measured_flow_lph,
      'resolved_flow_source', 'measured_valve_flow',
      'resolved_flow_is_estimated', false,
      'resolved_flow_warning', null,
      'resolved_flow_warnings', '[]'::jsonb,
      'resolved_flow_emitter_count', null,
      'resolved_flow_blocks', '[]'::jsonb);
  end if;

  -- Priority 2: explicit configured valve flow.
  if p_configured_flow_lph is not null and p_configured_flow_lph > 0 then
    return jsonb_build_object(
      'resolved_flow_litres_per_hour', p_configured_flow_lph,
      'resolved_flow_source', 'configured_valve_flow',
      'resolved_flow_is_estimated', false,
      'resolved_flow_warning', null,
      'resolved_flow_warnings', '[]'::jsonb,
      'resolved_flow_emitter_count', null,
      'resolved_flow_blocks', '[]'::jsonb);
  end if;

  -- Priority 3: derive from the saved connected-block configuration.
  if p_blocks is null or jsonb_array_length(p_blocks) = 0 then
    v_warnings := v_warnings || to_jsonb(
      'Automatic flow is unavailable because this valve has no active block connections.'::text);
  else
    for v_el in select * from jsonb_array_elements(p_blocks) loop
      v_name := coalesce(nullif(v_el->>'block_name', ''), 'a connected block');
      v_method := v_el->>'allocation_method';
      v_emitters := nullif(v_el->>'emitter_count', '')::numeric;
      v_fpe := nullif(v_el->>'flow_per_emitter_lph', '')::numeric;
      v_block_cfg := nullif(v_el->>'block_configured_flow_lph', '')::numeric;
      if coalesce(v_method, '') <> 'rows' then
        v_all_rows := false;
      end if;

      if coalesce(v_method, '') <> 'rows' and v_block_cfg is not null and v_block_cfg > 0 then
        -- Valid block-specific configured flow (non-row connections).
        v_block_flow := round(v_block_cfg, 3);
        v_all_emitters := false;
        v_total := v_total + v_block_flow;
        v_any := true;
        v_components := v_components || jsonb_build_object(
          'block_id', v_el->'block_id',
          'block_name', v_el->>'block_name',
          'basis', 'block_configured_flow',
          'emitter_count', null,
          'flow_per_emitter_lph', null,
          'block_flow_lph', v_block_flow);
      elsif v_emitters is not null and v_emitters > 0
            and v_fpe is not null and v_fpe > 0 then
        -- block flow = saved selected emitter count × block flow per emitter.
        v_block_flow := round(v_emitters * v_fpe, 3);
        v_total_emitters := v_total_emitters + v_emitters;
        v_total := v_total + v_block_flow;
        v_any := true;
        v_components := v_components || jsonb_build_object(
          'block_id', v_el->'block_id',
          'block_name', v_el->>'block_name',
          'basis', 'emitter_flow',
          'emitter_count', v_emitters,
          'flow_per_emitter_lph', v_fpe,
          'block_flow_lph', v_block_flow);
      else
        -- Missing component: the WHOLE valve resolution becomes unavailable —
        -- a misleading partial total is never returned as the configured flow.
        if v_fpe is null or v_fpe <= 0 then
          v_warnings := v_warnings || to_jsonb(format(
            'Automatic flow is unavailable because %s does not have a valid flow-per-emitter value.', v_name));
        end if;
        if v_emitters is null or v_emitters <= 0 then
          v_warnings := v_warnings || to_jsonb(format(
            'Automatic flow is unavailable because %s does not have a complete saved emitter count.', v_name));
        end if;
      end if;
    end loop;
  end if;

  if jsonb_array_length(v_warnings) > 0 or not v_any then
    if jsonb_array_length(v_warnings) = 0 then
      v_warnings := v_warnings || to_jsonb(
        'Automatic flow is unavailable because the connected blocks cannot be safely calculated.'::text);
    end if;
    return jsonb_build_object(
      'resolved_flow_litres_per_hour', null,
      'resolved_flow_source', 'unavailable',
      'resolved_flow_is_estimated', null,
      'resolved_flow_warning', v_warnings->>0,
      'resolved_flow_warnings', v_warnings,
      'resolved_flow_emitter_count', null,
      'resolved_flow_blocks', v_components);
  end if;

  return jsonb_build_object(
    'resolved_flow_litres_per_hour', round(v_total, 3),
    'resolved_flow_source',
      case when v_all_rows then 'row_emitter_flow' else 'block_emitter_flow' end,
    'resolved_flow_is_estimated', true,
    'resolved_flow_warning', null,
    'resolved_flow_warnings', '[]'::jsonb,
    'resolved_flow_emitter_count',
      case when v_all_emitters and v_total_emitters > 0 then v_total_emitters::integer end,
    'resolved_flow_blocks', v_components);
end;
$$;

grant execute on function public._irrigation_resolve_flow(numeric, numeric, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Table-backed wrapper — gathers the saved valve configuration
-- ---------------------------------------------------------------------------
create or replace function public._irrigation_resolve_valve_flow(p_valve_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_valve public.irrigation_valves;
  v_blocks jsonb;
begin
  select * into v_valve from public.irrigation_valves where id = p_valve_id;
  if not found then
    return public._irrigation_resolve_flow(null, null, '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'block_id', vb.block_id,
    'block_name', p.name,
    'allocation_method', vb.allocation_method,
    -- rows: complete-only sum of the SAVED selected row emitter counts
    -- (never re-estimated here — SQL 127 snapshot values are authoritative);
    -- other methods: the saved serviced emitter count.
    'emitter_count',
      case when vb.allocation_method = 'rows' then (
        select case when count(*) > 0
                     and count(*) filter (where vr.emitter_count is null) = 0
                    then sum(vr.emitter_count)::numeric end
        from public.irrigation_valve_rows vr
        where vr.valve_id = vb.valve_id
          and vr.block_id = vb.block_id
          and vr.is_active)
      else vb.serviced_emitter_count::numeric end,
    -- flow_per_emitter is double precision — cast to numeric (SQL 128 rule);
    -- invalid (<= 0) values are treated as missing, never as zero.
    'flow_per_emitter_lph',
      (case when p.flow_per_emitter is not null and p.flow_per_emitter > 0
            then p.flow_per_emitter end)::numeric,
    'block_configured_flow_lph',
      case when vb.allocation_method = 'rows' then null
           else vb.configured_flow_litres_per_hour end
  ) order by p.name), '[]'::jsonb)
  into v_blocks
  from public.irrigation_valve_blocks vb
  join public.paddocks p on p.id = vb.block_id and p.deleted_at is null
  where vb.valve_id = p_valve_id
    and vb.is_active;

  return public._irrigation_resolve_flow(
    v_valve.measured_flow_litres_per_hour,
    v_valve.configured_flow_litres_per_hour,
    v_blocks);
end;
$$;

revoke all on function public._irrigation_resolve_valve_flow(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. _irrigation_compute — configured_flow uses the shared resolver
-- ---------------------------------------------------------------------------
-- Same contract as sql/126, plus:
--   * calculation_method 'configured_flow' resolves via
--     _irrigation_resolve_valve_flow instead of requiring the stored valve
--     configured flow directly;
--   * the result and snapshot carry flow_source / flow_is_estimated /
--     flow_explanation and (snapshot) the full `resolved_flow` object so
--     historical sessions freeze the resolved flow used at recording time.
create or replace function public._irrigation_compute(
  p_vineyard_id uuid,
  p_valve_id uuid,
  p_duration_minutes integer,
  p_calculation_method text,
  p_flow_litres_per_hour numeric,
  p_meter_start_litres numeric,
  p_meter_finish_litres numeric,
  p_total_volume_litres numeric
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_valve public.irrigation_valves;
  v_system public.irrigation_systems;
  v_alloc jsonb;
  v_flow_used numeric;
  v_total numeric;
  v_result jsonb;
  v_snapshot jsonb;
  v_resolved jsonb;
  v_flow_source text;
  v_flow_is_estimated boolean;
  v_flow_explanation text;
begin
  select * into v_valve from public.irrigation_valves where id = p_valve_id;
  if not found or v_valve.vineyard_id <> p_vineyard_id then
    raise exception 'invalid_valve: the valve does not belong to this vineyard';
  end if;
  if not v_valve.is_active then
    raise exception 'inactive_valve: this valve is inactive';
  end if;
  select * into v_system from public.irrigation_systems where id = v_valve.irrigation_system_id;
  if not v_system.is_active then
    raise exception 'inactive_system: the irrigation system for this valve is inactive';
  end if;

  if p_calculation_method = 'configured_flow' then
    -- SQL 131: measured valve flow → configured valve flow → connected
    -- emitter flow → unavailable. The stored valve values are not replaced.
    v_resolved := public._irrigation_resolve_valve_flow(p_valve_id);
    v_flow_used := nullif(v_resolved->>'resolved_flow_litres_per_hour', '')::numeric;
    if v_flow_used is null then
      raise exception 'missing_configured_flow: no valid configured flow source exists for this valve — configure a valve flow or block emitter outputs, or enter a session flow, total volume or meter readings instead';
    end if;
    v_flow_source := v_resolved->>'resolved_flow_source';
    v_flow_is_estimated := (v_resolved->>'resolved_flow_is_estimated')::boolean;
    v_flow_explanation := case v_flow_source
      when 'measured_valve_flow' then 'Measured valve flow'
      when 'configured_valve_flow' then 'Configured valve flow'
      when 'row_emitter_flow' then
        case when nullif(v_resolved->>'resolved_flow_emitter_count', '') is not null
             then format('Derived from %s connected row emitters × block emitter output',
                         v_resolved->>'resolved_flow_emitter_count')
             else 'Derived from connected row emitters × block emitter output' end
      when 'block_emitter_flow' then
        case when nullif(v_resolved->>'resolved_flow_emitter_count', '') is not null
             then format('Derived from %s connected block emitters × block emitter output',
                         v_resolved->>'resolved_flow_emitter_count')
             else 'Derived from the connected block flow configuration' end
      end;
  elsif p_calculation_method = 'session_flow' then
    v_flow_used := p_flow_litres_per_hour;
    v_resolved := null;
    v_flow_source := 'session_flow';
    v_flow_is_estimated := false;
    v_flow_explanation := 'Flow entered for this session';
  else
    v_flow_used := null;
    v_resolved := null;
    v_flow_source := null;
    v_flow_is_estimated := null;
    v_flow_explanation := null;
  end if;

  v_total := public.irrigation_total_volume(
    p_calculation_method, v_flow_used, p_duration_minutes,
    p_meter_start_litres, p_meter_finish_litres, p_total_volume_litres);

  v_alloc := public._irrigation_valve_allocations(p_valve_id);
  v_result := public._irrigation_allocate(v_total, v_alloc);

  -- Rows method transparency: equal-row fallback is an ESTIMATE (SQL 126).
  if exists (
    select 1 from jsonb_array_elements(v_alloc) e
    where e->>'allocation_method' = 'rows' and e->>'weighting_basis' = 'equal_rows'
  ) then
    v_result := jsonb_set(v_result, '{warnings}',
      coalesce(v_result->'warnings', '[]'::jsonb) || to_jsonb(
        'Water allocation is being estimated from the number of selected rows because emitter, vine-count and row-length information is incomplete.'::text));
  end if;

  v_snapshot := jsonb_build_object(
    'calculation_version', 1,
    'irrigation_system_id', v_system.id,
    'irrigation_system_name', v_system.name,
    'valve_id', v_valve.id,
    'valve_name', v_valve.name,
    'valve_configured_flow_lph', v_valve.configured_flow_litres_per_hour,
    'valve_measured_flow_lph', v_valve.measured_flow_litres_per_hour,
    'flow_lph_used', v_flow_used,
    'flow_source', v_flow_source,
    'flow_is_estimated', v_flow_is_estimated,
    -- Full resolver output (source, emitter count used, flow per emitter by
    -- block, warnings) — frozen so setup edits never alter this session.
    'resolved_flow', v_resolved,
    'calculation_method', p_calculation_method,
    'unit_context', jsonb_build_object(
      'volume', 'litres', 'flow', 'litres_per_hour',
      'area', 'square_metres', 'depth', 'millimetres', 'duration', 'minutes'),
    'blocks', v_alloc
  );

  return v_result || jsonb_build_object(
    'irrigation_system_id', v_system.id,
    'irrigation_system_name', v_system.name,
    'valve_id', v_valve.id,
    'valve_name', v_valve.name,
    'flow_litres_per_hour_used', v_flow_used,
    'flow_source', v_flow_source,
    'flow_is_estimated', v_flow_is_estimated,
    'flow_explanation', v_flow_explanation,
    'configuration_snapshot', v_snapshot
  );
end;
$$;

revoke all on function public._irrigation_compute(uuid, uuid, integer, text, numeric, numeric, numeric, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. validate_irrigation_configuration — clients no longer decide
--    configured-flow availability themselves
-- ---------------------------------------------------------------------------
create or replace function public.validate_irrigation_configuration(
  p_vineyard_id uuid,
  p_valve_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_valve public.irrigation_valves;
  v_alloc jsonb;
  v_el jsonb;
  v_sum numeric := 0;
  v_issues jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_alloc_ok boolean := true;
  v_basis text;
  v_conflict record;
  v_resolved jsonb;
  v_flow_available boolean;
begin
  perform public._irrigation_require_access(p_vineyard_id);

  select * into v_valve from public.irrigation_valves where id = p_valve_id;
  if not found or v_valve.vineyard_id <> p_vineyard_id then
    raise exception 'invalid_valve: the valve does not belong to this vineyard';
  end if;

  if not v_valve.is_active then
    v_issues := v_issues || to_jsonb('This valve is inactive.'::text);
  end if;
  if not exists (
    select 1 from public.irrigation_systems
    where id = v_valve.irrigation_system_id and is_active
  ) then
    v_issues := v_issues || to_jsonb('The irrigation system for this valve is inactive.'::text);
  end if;

  v_alloc := public._irrigation_valve_allocations(p_valve_id);
  if jsonb_array_length(v_alloc) = 0 then
    v_alloc_ok := false;
    v_issues := v_issues || to_jsonb('This valve has no active block connections.'::text);
  else
    for v_el in select * from jsonb_array_elements(v_alloc) loop
      if nullif(v_el->>'allocation_percentage', '') is null then
        v_alloc_ok := false;
      else
        v_sum := v_sum + (v_el->>'allocation_percentage')::numeric;
      end if;
      if v_el->>'allocation_method' = 'rows' and v_basis is null then
        v_basis := v_el->>'weighting_basis';
      end if;
    end loop;
    if v_alloc_ok and abs(v_sum - 100) > 0.05 then
      v_alloc_ok := false;
      v_issues := v_issues || to_jsonb(format('Block allocations total %s%% instead of 100%%.', round(v_sum, 2))::text);
    elsif not v_alloc_ok then
      v_issues := v_issues || to_jsonb('One or more block allocations cannot be resolved.'::text);
    end if;
  end if;

  if v_basis = 'equal_rows' then
    v_warnings := v_warnings || to_jsonb(
      'Water allocation is being estimated from the number of selected rows because emitter, vine-count and row-length information is incomplete.'::text);
  end if;

  for v_conflict in
    select distinct p.name as block_name, vr.row_number, v2.name as valve_name
    from public.irrigation_valve_rows vr
    join public.irrigation_valve_rows mine
      on mine.valve_id = p_valve_id and mine.is_active and mine.row_id = vr.row_id
    join public.irrigation_valves v2 on v2.id = vr.valve_id and v2.is_active
    join public.paddocks p on p.id = vr.block_id
    where vr.is_active and vr.valve_id <> p_valve_id
    order by p.name, vr.row_number
  loop
    v_warnings := v_warnings || to_jsonb(format('%s Row %s is also connected to Valve %s.',
      v_conflict.block_name, v_conflict.row_number, v_conflict.valve_name));
  end loop;

  -- SQL 131: shared configured-flow resolution.
  v_resolved := public._irrigation_resolve_valve_flow(p_valve_id);
  v_flow_available := nullif(v_resolved->>'resolved_flow_litres_per_hour', '') is not null;
  if not v_flow_available then
    v_warnings := v_warnings || coalesce(v_resolved->'resolved_flow_warnings', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'valve_id', p_valve_id,
    'valve_name', v_valve.name,
    'can_record', v_valve.is_active and v_alloc_ok and jsonb_array_length(v_issues) = 0,
    'has_configured_flow', v_valve.configured_flow_litres_per_hour is not null,
    'configured_flow_litres_per_hour', v_valve.configured_flow_litres_per_hour,
    'measured_flow_litres_per_hour', v_valve.measured_flow_litres_per_hour,
    -- A valve supports the configured_flow method when ANY valid resolved
    -- source exists; volume entry is only REQUIRED when none does.
    'configured_flow_available', v_flow_available,
    'requires_volume_entry', not v_flow_available,
    'resolved_flow_litres_per_hour', nullif(v_resolved->>'resolved_flow_litres_per_hour', '')::numeric,
    'resolved_flow_source', v_resolved->>'resolved_flow_source',
    'resolved_flow_is_estimated', (v_resolved->>'resolved_flow_is_estimated')::boolean,
    'resolved_flow_warning', v_resolved->>'resolved_flow_warning',
    'resolved_flow_emitter_count', nullif(v_resolved->>'resolved_flow_emitter_count', '')::integer,
    'resolved_flow_blocks', coalesce(v_resolved->'resolved_flow_blocks', '[]'::jsonb),
    'allocations', v_alloc,
    'allocation_total', round(v_sum, 2),
    'weighting_basis', v_basis,
    'issues', v_issues,
    'warnings', v_warnings
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. get_irrigation_setup_status — automatic-flow readiness per valve
-- ---------------------------------------------------------------------------
create or replace function public.get_irrigation_setup_status(p_vineyard_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_month integer;
  v_day integer;
  v_active_blocks integer;
  v_systems integer;
  v_valves integer;
  v_valve record;
  v_valves_json jsonb := '[]'::jsonb;
  v_allocated_valves integer := 0;
  v_flow_valves integer := 0;
  v_auto_flow_valves integer := 0;
  v_alloc jsonb;
  v_el jsonb;
  v_sum numeric;
  v_ok boolean;
  v_uses_rows boolean;
  v_row_count integer;
  v_rows_basis text;
  v_rows_vines integer;
  v_rows_emitters integer;
  v_rows_saved_at timestamptz;
  v_method text;
  v_resolved jsonb;
  v_auto_ready boolean;
  v_blocks_area integer;
  v_blocks_vines integer;
  v_blocks_spacing integer;
  v_blocks_dripper_out integer;
  v_blocks_dripper_sp integer;
  v_blocks_eff integer;
begin
  perform public._irrigation_require_access(p_vineyard_id);

  select v.season_start_month::integer, v.season_start_day::integer
  into v_month, v_day
  from public.vineyards v where v.id = p_vineyard_id;

  select count(*) into v_active_blocks
  from public.paddocks where vineyard_id = p_vineyard_id and deleted_at is null;

  select count(*) into v_systems
  from public.irrigation_systems where vineyard_id = p_vineyard_id and is_active;

  select count(*) into v_valves
  from public.irrigation_valves where vineyard_id = p_vineyard_id and is_active;

  for v_valve in
    select v.id, v.name, v.configured_flow_litres_per_hour
    from public.irrigation_valves v
    where v.vineyard_id = p_vineyard_id and v.is_active
    order by v.name
  loop
    v_alloc := public._irrigation_valve_allocations(v_valve.id);
    v_sum := 0;
    v_ok := jsonb_array_length(v_alloc) > 0;
    v_uses_rows := false;
    v_method := null;
    for v_el in select * from jsonb_array_elements(v_alloc) loop
      if nullif(v_el->>'allocation_percentage', '') is null then
        v_ok := false;
      else
        v_sum := v_sum + (v_el->>'allocation_percentage')::numeric;
      end if;
      if v_el->>'allocation_method' = 'rows' then
        v_uses_rows := true;
      end if;
      if v_method is null then
        v_method := v_el->>'allocation_method';
      end if;
    end loop;
    if v_uses_rows then
      v_method := 'rows';
    end if;
    if v_ok and abs(v_sum - 100) > 0.05 then
      v_ok := false;
    end if;
    if v_ok then
      v_allocated_valves := v_allocated_valves + 1;
    end if;
    if v_valve.configured_flow_litres_per_hour is not null then
      v_flow_valves := v_flow_valves + 1;
    end if;

    -- SQL 131: a valve is ready for automatic duration-based recording when
    -- it has a valid explicit valve flow OR sufficient connected-emitter
    -- configuration to resolve flow automatically.
    v_resolved := public._irrigation_resolve_valve_flow(v_valve.id);
    v_auto_ready := nullif(v_resolved->>'resolved_flow_litres_per_hour', '') is not null;
    if v_auto_ready then
      v_auto_flow_valves := v_auto_flow_valves + 1;
    end if;

    select count(*),
           min(vr.weighting_basis),
           case when count(*) > 0 and count(*) filter (where vr.vine_count is null) = 0
                then sum(vr.vine_count)::integer end,
           case when count(*) > 0 and count(*) filter (where vr.emitter_count is null) = 0
                then sum(vr.emitter_count)::integer end,
           max(vr.updated_at)
    into v_row_count, v_rows_basis, v_rows_vines, v_rows_emitters, v_rows_saved_at
    from public.irrigation_valve_rows vr
    where vr.valve_id = v_valve.id and vr.is_active;

    v_valves_json := v_valves_json || jsonb_build_object(
      'valve_id', v_valve.id,
      'valve_name', v_valve.name,
      'block_count', jsonb_array_length(v_alloc),
      'allocation_total', round(v_sum, 2),
      'allocation_ok', v_ok,
      'has_configured_flow', v_valve.configured_flow_litres_per_hour is not null,
      'automatic_flow_ready', v_auto_ready,
      'resolved_flow_litres_per_hour', nullif(v_resolved->>'resolved_flow_litres_per_hour', '')::numeric,
      'resolved_flow_source', v_resolved->>'resolved_flow_source',
      'resolved_flow_is_estimated', (v_resolved->>'resolved_flow_is_estimated')::boolean,
      'resolved_flow_emitter_count', nullif(v_resolved->>'resolved_flow_emitter_count', '')::integer,
      'allocation_method', v_method,
      'uses_rows', v_uses_rows,
      'row_count', v_row_count,
      'weighting_basis', v_rows_basis,
      'selected_vine_count', v_rows_vines,
      'selected_emitter_count', v_rows_emitters,
      'rows_saved_at', v_rows_saved_at
    );
  end loop;

  select
    count(*) filter (where coalesce(public._paddock_polygon_area_hectares(polygon_points), 0) > 0),
    count(*) filter (where vine_count_override is not null and vine_count_override > 0),
    count(*) filter (where vine_spacing is not null and vine_spacing > 0),
    count(*) filter (where flow_per_emitter is not null and flow_per_emitter > 0),
    count(*) filter (where emitter_spacing is not null and emitter_spacing > 0),
    count(*) filter (where irrigation_efficiency_percent is not null)
  into v_blocks_area, v_blocks_vines, v_blocks_spacing,
       v_blocks_dripper_out, v_blocks_dripper_sp, v_blocks_eff
  from public.paddocks
  where vineyard_id = p_vineyard_id and deleted_at is null;

  return jsonb_build_object(
    'vineyard_id', p_vineyard_id,
    'season', jsonb_build_object(
      'configured', v_month is not null,
      'season_start_month', coalesce(v_month, 7),
      'season_start_day', coalesce(v_day, 1),
      'current_vintage_year', public.resolve_vineyard_vintage_year(p_vineyard_id, current_date)
    ),
    'required', jsonb_build_object(
      'season_settings_ok', true,
      'active_block_count', v_active_blocks,
      'blocks_ok', v_active_blocks > 0,
      'active_system_count', v_systems,
      'systems_ok', v_systems > 0,
      'active_valve_count', v_valves,
      'valves_ok', v_valves > 0,
      'fully_allocated_valve_count', v_allocated_valves,
      'allocations_ok', v_allocated_valves > 0,
      'valves_with_configured_flow', v_flow_valves,
      'valves_with_automatic_flow', v_auto_flow_valves
    ),
    'recommended', jsonb_build_object(
      'total_active_blocks', v_active_blocks,
      'blocks_with_area', v_blocks_area,
      'blocks_with_vine_count', v_blocks_vines,
      'blocks_with_vine_spacing', v_blocks_spacing,
      'blocks_with_dripper_output', v_blocks_dripper_out,
      'blocks_with_dripper_spacing', v_blocks_dripper_sp,
      'blocks_with_efficiency', v_blocks_eff
    ),
    'valves', v_valves_json,
    'is_operational', v_active_blocks > 0 and v_systems > 0 and v_valves > 0 and v_allocated_valves > 0
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. update_irrigation_session — snapshot edits keep the FROZEN resolved flow
-- ---------------------------------------------------------------------------
-- Same signature and behaviour as sql/130, with one fix: when editing a
-- configured_flow session against its saved snapshot, the flow now resolves
-- from (in order) the snapshot's frozen resolved flow, the snapshot's frozen
-- valve configured flow, then — only when the session already used
-- configured_flow — the flow stored on the session. Historical sessions
-- recorded with an emitter-derived flow therefore stay editable and keep the
-- exact flow used at recording time.
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
  -- is an explicit action) and validate it against the final duration.
  if p_clear_times then
    v_started := null;
    v_finished := null;
  else
    v_started := coalesce(p_started_at, v_old.started_at);
    v_finished := coalesce(p_finished_at, v_old.finished_at);
  end if;
  perform public._irrigation_validate_session_times(v_started, v_finished, v_duration);

  if p_use_current_configuration then
    -- Explicit user action: recalculate against today's valve configuration
    -- (configured_flow re-resolves via the SQL 131 resolver inside compute).
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
        nullif(v_old.configuration_snapshot->'resolved_flow'->>'resolved_flow_litres_per_hour', '')::numeric,
        nullif(v_old.configuration_snapshot->>'valve_configured_flow_lph', '')::numeric,
        case when v_old.calculation_method = 'configured_flow'
             then v_old.flow_litres_per_hour end);
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

-- ---------------------------------------------------------------------------
-- 7. Grants (unchanged signatures — re-granted defensively)
-- ---------------------------------------------------------------------------
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'validate_irrigation_configuration(uuid, uuid)',
    'get_irrigation_setup_status(uuid)',
    'calculate_irrigation_preview(uuid, uuid, date, integer, text, numeric, numeric, numeric, numeric)',
    'update_irrigation_session(uuid, date, integer, text, numeric, numeric, numeric, numeric, timestamptz, timestamptz, text, boolean, boolean)'
  ]
  loop
    execute format('revoke all on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Regression tests — the migration ABORTS if any resolution rule fails.
--    (Mirrored by IrrigationLocalCalculator.resolveFlow in Swift and
--     IrrigationLocalCalc.resolveFlow in Kotlin.)
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v_rows_block jsonb := jsonb_build_object(
    'block_id', '00000000-0000-0000-0000-000000000001',
    'block_name', 'Pinot Noir',
    'allocation_method', 'rows',
    'emitter_count', 7931,
    'flow_per_emitter_lph', 1.6,
    'block_configured_flow_lph', null);
begin
  -- Priority 1: explicit measured valve flow wins over everything.
  v := public._irrigation_resolve_flow(9000, 8000, jsonb_build_array(v_rows_block));
  assert v->>'resolved_flow_source' = 'measured_valve_flow', 'measured valve flow must be priority 1';
  assert (v->>'resolved_flow_litres_per_hour')::numeric = 9000, 'measured flow value must be returned unchanged';
  assert (v->>'resolved_flow_is_estimated')::boolean = false, 'an explicit measured flow is not an estimate';

  -- Priority 2: explicit configured valve flow.
  v := public._irrigation_resolve_flow(null, 8000, jsonb_build_array(v_rows_block));
  assert v->>'resolved_flow_source' = 'configured_valve_flow', 'configured valve flow must be priority 2';
  assert (v->>'resolved_flow_litres_per_hour')::numeric = 8000, 'configured flow value must be returned unchanged';

  -- Invalid explicit values are skipped, never treated as a flow of zero.
  v := public._irrigation_resolve_flow(0, -5, jsonb_build_array(v_rows_block));
  assert v->>'resolved_flow_source' = 'row_emitter_flow', 'invalid explicit flows must fall through to derivation';

  -- Priority 3 (W1 example): 7,931 emitters × 1.6 L/h = 12,689.6 L/h.
  v := public._irrigation_resolve_flow(null, null, jsonb_build_array(v_rows_block));
  assert (v->>'resolved_flow_litres_per_hour')::numeric = 12689.6, 'W1: 7931 × 1.6 must equal 12689.6';
  assert v->>'resolved_flow_source' = 'row_emitter_flow', 'row-connected valves derive via row_emitter_flow';
  assert (v->>'resolved_flow_is_estimated')::boolean = true, 'derived flow must be flagged as estimated';
  assert (v->>'resolved_flow_emitter_count')::integer = 7931, 'total emitters used must be surfaced';

  -- W1 preview maths: 12,689.6 L/h × 3 h = 38,068.8 L.
  assert public.irrigation_total_volume('configured_flow', 12689.6, 180, null, null, null) = 38068.8,
    'W1: 12689.6 L/h for 3 hours must total 38068.8 L';

  -- Blocks with DIFFERENT emitter outputs are calculated separately, then summed.
  v := public._irrigation_resolve_flow(null, null, jsonb_build_array(
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000001',
      'block_name', 'Pinot Noir', 'allocation_method', 'rows',
      'emitter_count', 4000, 'flow_per_emitter_lph', 1.6),
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000002',
      'block_name', 'Primitivo', 'allocation_method', 'rows',
      'emitter_count', 2000, 'flow_per_emitter_lph', 2.0)));
  assert (v->>'resolved_flow_litres_per_hour')::numeric = 10400,
    'per-block outputs must sum: 4000×1.6 + 2000×2.0 = 10400';
  assert (v->>'resolved_flow_emitter_count')::integer = 6000, 'emitter totals must sum across blocks';

  -- Missing flow-per-emitter → unavailable with a named-block warning.
  v := public._irrigation_resolve_flow(null, null, jsonb_build_array(
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000001',
      'block_name', 'Pinot Noir', 'allocation_method', 'rows',
      'emitter_count', 7931, 'flow_per_emitter_lph', null)));
  assert v->>'resolved_flow_source' = 'unavailable', 'missing emitter output must make flow unavailable';
  assert v->>'resolved_flow_litres_per_hour' is null, 'unavailable flow must be NULL, never zero';
  assert v->>'resolved_flow_warning' like '%Pinot Noir does not have a valid flow-per-emitter value%',
    'the warning must name the incomplete block';

  -- One incomplete block → NO misleading partial total.
  v := public._irrigation_resolve_flow(null, null, jsonb_build_array(
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000001',
      'block_name', 'Pinot Noir', 'allocation_method', 'rows',
      'emitter_count', 4000, 'flow_per_emitter_lph', 1.6),
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000002',
      'block_name', 'Primitivo', 'allocation_method', 'rows',
      'emitter_count', null, 'flow_per_emitter_lph', 2.0)));
  assert v->>'resolved_flow_source' = 'unavailable',
    'a partial total must never be returned as the full configured flow';
  assert v->>'resolved_flow_warning' like '%Primitivo does not have a complete saved emitter count%',
    'the warning must identify the block missing its emitter count';

  -- Manual-percentage configurations with emitter data derive via block_emitter_flow.
  v := public._irrigation_resolve_flow(null, null, jsonb_build_array(
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000001',
      'block_name', 'Pinot Noir', 'allocation_method', 'manual_percentage',
      'emitter_count', 5000, 'flow_per_emitter_lph', 1.6)));
  assert v->>'resolved_flow_source' = 'block_emitter_flow',
    'non-row methods with emitter data must use block_emitter_flow';
  assert (v->>'resolved_flow_litres_per_hour')::numeric = 8000, '5000 × 1.6 must equal 8000';

  -- A valid block-specific configured flow also counts (non-row methods).
  v := public._irrigation_resolve_flow(null, null, jsonb_build_array(
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000001',
      'block_name', 'Pinot Noir', 'allocation_method', 'manual_percentage',
      'emitter_count', null, 'flow_per_emitter_lph', null,
      'block_configured_flow_lph', 5000),
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000002',
      'block_name', 'Primitivo', 'allocation_method', 'manual_percentage',
      'emitter_count', 4000, 'flow_per_emitter_lph', 1.6)));
  assert (v->>'resolved_flow_litres_per_hour')::numeric = 11400,
    'block-specific flow + emitter-derived flow must sum: 5000 + 6400 = 11400';
  assert v->>'resolved_flow_emitter_count' is null,
    'the emitter total is only surfaced when EVERY contributing block used emitters';

  -- Allocation percentages alone must never produce a flow.
  v := public._irrigation_resolve_flow(null, null, jsonb_build_array(
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000001',
      'block_name', 'Pinot Noir', 'allocation_method', 'manual_percentage',
      'emitter_count', null, 'flow_per_emitter_lph', 1.6)));
  assert v->>'resolved_flow_source' = 'unavailable',
    'a manual percentage without emitter data must not derive a flow';

  -- No connected blocks → unavailable.
  v := public._irrigation_resolve_flow(null, null, '[]'::jsonb);
  assert v->>'resolved_flow_source' = 'unavailable', 'no block connections must be unavailable';
  assert v->>'resolved_flow_warning' like '%no active block connections%',
    'the no-connections warning must be explicit';

  raise notice 'SQL 131 configured-flow resolution tests passed';
end $$;

-- Make PostgREST pick up the changed functions immediately.
notify pgrst, 'reload schema';

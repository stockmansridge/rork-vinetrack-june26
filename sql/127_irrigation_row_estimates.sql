-- =============================================================================
-- 127: Irrigation Records — estimated vines and emitters for irrigation rows.
--
-- SQL 126 selects real mapped vineyard rows (paddocks.rows jsonb:
-- { id, number, startPoint, endPoint }) but could not display vines/emitters
-- because no per-row values are stored. SQL 127 adds SHARED, server-calculated
-- estimates so all platforms show identical values, clearly labelled.
--
-- AUDITED CANONICAL SOURCES (no new Vineyard Setup fields created):
--   * Mapped rows ......................... paddocks.rows (jsonb, sql/112 identity)
--   * Block vine count .................... paddocks.vine_count_override
--   * Vine spacing (m) .................... paddocks.vine_spacing
--   * Emitter spacing (m) ................. paddocks.emitter_spacing
--   * Dripper output (L/h) ................ paddocks.flow_per_emitter
--   * Row width (m) ....................... paddocks.row_width
--   * Block area .......................... derived: _paddock_polygon_area_hectares
--   * Irrigation efficiency ............... paddocks.irrigation_efficiency_percent
--   * Variety ............................. paddocks.variety_allocations
--   NO exact per-block emitter total exists anywhere in the schema, so emitter
--   values are ALWAYS estimates (row length ÷ emitter spacing) in this phase.
--
-- CALCULATION RULES (authoritative here; clients only display):
--   Vines, preferred — reconcile to the configured block vine count:
--     estimated row vines = block vine count × row length ÷ Σ valid row lengths
--     Deterministic rounding: floor every proportional value, then distribute
--     the remaining units by largest fractional part (ties → earliest row in
--     row_number, row_id order). The whole-row values sum EXACTLY to the
--     configured block total. basis = 'block_total_proportional'.
--   Vines, fallback — row length ÷ vine spacing, rounded half away from zero
--     with a minimum of one vine per mapped row. basis = 'row_length_spacing'.
--   Emitters — row length ÷ emitter spacing, same rounding rule.
--     basis = 'row_length_spacing'.
--   Missing length or missing source → NULL + basis 'unavailable' (never zero).
--
-- WEIGHTING HONESTY (why estimates must not overstate precision):
--   Estimates derived from row length ÷ constant spacing are mathematically
--   just row-length weighting in another unit. The common valve basis now
--   resolves as:
--     1. emitter_count — only when EVERY selected row's emitter basis is 'exact'
--     2. vine_count    — only when EVERY selected row's vine basis is 'exact'
--                        or 'block_total_proportional' (reconciled block totals
--                        embed per-block vine density, a materially independent
--                        input)
--     3. row_length    — every selected row has a valid mapped length
--     4. equal_rows    — fallback, always labelled as an estimate
--   Rows passed WITHOUT basis metadata keep the legacy 'exact' interpretation
--   so the SQL 126 fixtures and client mirrors remain valid.
--
-- HISTORY: saved valve-row links snapshot the calculated values + basis.
-- Changing Vineyard Setup later never alters a saved valve configuration until
-- rows are explicitly saved again; sessions stay frozen by their
-- configuration_snapshot (unchanged from sql/125/126).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Snapshot basis metadata on irrigation_valve_rows
-- ---------------------------------------------------------------------------
alter table public.irrigation_valve_rows
  add column if not exists vine_count_basis text null,
  add column if not exists emitter_count_basis text null,
  add column if not exists vine_count_is_estimated boolean null,
  add column if not exists emitter_count_is_estimated boolean null;

alter table public.irrigation_valve_rows
  drop constraint if exists irrigation_valve_rows_vine_basis_check;
alter table public.irrigation_valve_rows
  add constraint irrigation_valve_rows_vine_basis_check
  check (vine_count_basis is null or vine_count_basis in
         ('exact','block_total_proportional','row_length_spacing','unavailable'));

alter table public.irrigation_valve_rows
  drop constraint if exists irrigation_valve_rows_emitter_basis_check;
alter table public.irrigation_valve_rows
  add constraint irrigation_valve_rows_emitter_basis_check
  check (emitter_count_basis is null or emitter_count_basis in
         ('exact','block_total_proportional','row_length_spacing','unavailable'));

-- ---------------------------------------------------------------------------
-- 2. Pure cores (immutable, assert-tested in §10)
-- ---------------------------------------------------------------------------

-- Spacing estimate: round half away from zero, minimum ONE per mapped row.
-- NULL (never zero) when length or spacing is missing/invalid.
create or replace function public._irrigation_spacing_estimate(
  p_length_metres numeric,
  p_spacing_metres numeric
) returns integer
language sql
immutable
as $$
  select case
    when p_length_metres is null or p_length_metres <= 0
      or p_spacing_metres is null or p_spacing_metres <= 0 then null
    else greatest(1, round(p_length_metres / p_spacing_metres))::integer
  end
$$;

revoke all on function public._irrigation_spacing_estimate(numeric, numeric) from public, anon;
grant execute on function public._irrigation_spacing_estimate(numeric, numeric) to authenticated;

-- Largest-remainder reconciliation: distributes p_total whole units across
-- p_weights (jsonb numeric array, DETERMINISTIC caller order — row_number then
-- row_id). Null/zero weights receive null. The non-null outputs sum EXACTLY
-- to p_total. Ties in fractional part resolve to the EARLIEST ordinal so
-- repeated calls always return identical results.
create or replace function public._irrigation_reconcile_counts(
  p_total integer,
  p_weights jsonb
) returns jsonb
language plpgsql
immutable
as $$
declare
  v_n integer;
  v_i integer;
  v_w numeric;
  v_sum numeric := 0;
  v_weights numeric[] := '{}';
  v_floors integer[] := '{}';
  v_fracs numeric[] := '{}';
  v_raw numeric;
  v_remainder integer;
  v_pick integer;
  v_best numeric;
  v_out jsonb := '[]'::jsonb;
begin
  if p_weights is null or jsonb_typeof(p_weights) <> 'array' then
    return '[]'::jsonb;
  end if;
  v_n := jsonb_array_length(p_weights);
  if v_n = 0 then
    return '[]'::jsonb;
  end if;

  for v_i in 0 .. v_n - 1 loop
    v_w := nullif(p_weights->>v_i, '')::numeric;
    if v_w is not null and v_w > 0 then
      v_weights := v_weights || v_w;
      v_sum := v_sum + v_w;
    else
      v_weights := v_weights || null::numeric;
    end if;
  end loop;

  if p_total is null or p_total <= 0 or v_sum <= 0 then
    for v_i in 1 .. v_n loop
      v_out := v_out || 'null'::jsonb;
    end loop;
    return v_out;
  end if;

  v_remainder := p_total;
  for v_i in 1 .. v_n loop
    if v_weights[v_i] is null then
      v_floors := v_floors || null::integer;
      v_fracs := v_fracs || (-1)::numeric;
    else
      v_raw := p_total * v_weights[v_i] / v_sum;
      v_floors := v_floors || floor(v_raw)::integer;
      v_fracs := v_fracs || (v_raw - floor(v_raw));
      v_remainder := v_remainder - floor(v_raw)::integer;
    end if;
  end loop;

  while v_remainder > 0 loop
    v_pick := null;
    v_best := -2;
    for v_i in 1 .. v_n loop
      if v_floors[v_i] is not null and v_fracs[v_i] > v_best then
        v_best := v_fracs[v_i];
        v_pick := v_i;
      end if;
    end loop;
    exit when v_pick is null;
    v_floors[v_pick] := v_floors[v_pick] + 1;
    v_fracs[v_pick] := -1;
    v_remainder := v_remainder - 1;
  end loop;

  for v_i in 1 .. v_n loop
    v_out := v_out || coalesce(to_jsonb(v_floors[v_i]), 'null'::jsonb);
  end loop;
  return v_out;
end;
$$;

revoke all on function public._irrigation_reconcile_counts(integer, jsonb) from public, anon;
grant execute on function public._irrigation_reconcile_counts(integer, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. _irrigation_paddock_rows now returns shared estimates + basis metadata
-- ---------------------------------------------------------------------------
-- Same signature and identity/length rules as sql/126, plus per row:
--   vine_count, vine_count_basis, vine_count_is_estimated,
--   emitter_count, emitter_count_basis, emitter_count_is_estimated,
--   geometry_warning (text when the mapped start/end points are incomplete).
-- list_irrigation_available_rows and set_irrigation_valve_rows consume this
-- directly, so every platform receives identical values.
create or replace function public._irrigation_paddock_rows(
  p_vineyard_id uuid,
  p_block_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_block record;
  v_rows jsonb;
  v_weights jsonb;
  v_counts jsonb := null;
  v_row jsonb;
  v_i integer;
  v_len numeric;
  v_vine integer;
  v_vine_basis text;
  v_emit integer;
  v_emit_basis text;
  v_out jsonb := '[]'::jsonb;
begin
  for v_block in
    select p.id, p.name, p.rows as rows_json,
           p.vine_count_override, p.vine_spacing, p.emitter_spacing
    from public.paddocks p
    where p.vineyard_id = p_vineyard_id
      and p.deleted_at is null
      and (p_block_id is null or p.id = p_block_id)
    order by p.name
  loop
    -- Real configured rows only (sql/112 identity rule); deterministic order
    -- row_number then row_id — the SAME order the reconciliation uses.
    select coalesce(jsonb_agg(jsonb_build_object(
             'row_id', r.row_id,
             'block_id', v_block.id,
             'block_name', v_block.name,
             'row_number', r.row_number,
             'row_label', 'Row ' || r.row_number::text,
             'row_length_metres', r.length_m,
             'is_active', true
           ) order by r.row_number, r.row_id), '[]'::jsonb),
           coalesce(jsonb_agg(to_jsonb(r.length_m) order by r.row_number, r.row_id), '[]'::jsonb)
    into v_rows, v_weights
    from (
      select (elem->>'id')::uuid as row_id,
             (elem->>'number')::integer as row_number,
             case
               when jsonb_typeof(elem->'startPoint'->'latitude') = 'number'
                and jsonb_typeof(elem->'startPoint'->'longitude') = 'number'
                and jsonb_typeof(elem->'endPoint'->'latitude') = 'number'
                and jsonb_typeof(elem->'endPoint'->'longitude') = 'number'
               then nullif(round(sqrt(
                      power(((elem->'endPoint'->>'latitude')::numeric
                             - (elem->'startPoint'->>'latitude')::numeric) * 111320.0, 2)
                    + power(((elem->'endPoint'->>'longitude')::numeric
                             - (elem->'startPoint'->>'longitude')::numeric) * 111320.0
                            * cos(radians((elem->'startPoint'->>'latitude')::double precision))::numeric, 2)
                    )::numeric, 2), 0)
               else null
             end as length_m
      from jsonb_array_elements(coalesce(v_block.rows_json, '[]'::jsonb)) elem
      where jsonb_typeof(elem->'number') = 'number'
        and (elem->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    ) r;

    if jsonb_array_length(v_rows) = 0 then
      continue;
    end if;

    -- Preferred vine method: reconcile mapped-length proportions to the
    -- configured block vine count (sum equals the block total EXACTLY).
    v_counts := null;
    if coalesce(v_block.vine_count_override, 0) > 0 then
      v_counts := public._irrigation_reconcile_counts(v_block.vine_count_override, v_weights);
    end if;

    for v_i in 0 .. jsonb_array_length(v_rows) - 1 loop
      v_row := v_rows->v_i;
      v_len := nullif(v_row->>'row_length_metres', '')::numeric;

      if v_counts is not null and nullif(v_counts->>v_i, '') is not null then
        v_vine := (v_counts->>v_i)::integer;
        v_vine_basis := 'block_total_proportional';
      elsif public._irrigation_spacing_estimate(v_len, v_block.vine_spacing) is not null then
        v_vine := public._irrigation_spacing_estimate(v_len, v_block.vine_spacing);
        v_vine_basis := 'row_length_spacing';
      else
        v_vine := null;
        v_vine_basis := 'unavailable';
      end if;

      v_emit := public._irrigation_spacing_estimate(v_len, v_block.emitter_spacing);
      v_emit_basis := case when v_emit is null then 'unavailable' else 'row_length_spacing' end;

      v_out := v_out || (v_row || jsonb_build_object(
        'vine_count', v_vine,
        'vine_count_basis', v_vine_basis,
        'vine_count_is_estimated', case when v_vine is null then null else true end,
        'emitter_count', v_emit,
        'emitter_count_basis', v_emit_basis,
        'emitter_count_is_estimated', case when v_emit is null then null else true end,
        'geometry_warning', case when v_len is null then
          format('%s Row %s has incomplete mapped geometry. Row length, estimated vines and estimated emitters are unavailable.',
                 v_block.name, v_row->>'row_number')
          else null end
      ));
    end loop;
  end loop;

  return v_out;
end;
$$;

revoke all on function public._irrigation_paddock_rows(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Honest weighting-basis resolution in _irrigation_rows_weighting
-- ---------------------------------------------------------------------------
-- Same contract as sql/126 plus:
--   * emitter_count basis requires emitter_count_basis = 'exact' on EVERY row
--     (spacing-derived estimates are row-length weighting in another unit);
--   * vine_count basis requires vine_count_basis in
--     ('exact','block_total_proportional') on EVERY row;
--   * rows without basis metadata keep the legacy 'exact' interpretation;
--   * blocks gain 'selected_row_length_metres' (sum of valid lengths).
create or replace function public._irrigation_rows_weighting(p_rows jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_row jsonb;
  v_basis text;
  v_all_emitters boolean := true;
  v_all_vines boolean := true;
  v_all_lengths boolean := true;
  v_weight numeric;
  v_total numeric := 0;
  v_rows_out jsonb := '[]'::jsonb;
  v_block record;
  v_blocks_out jsonb := '[]'::jsonb;
  v_pct numeric;
  v_pct_sum numeric := 0;
  v_count integer;
  v_index integer := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'no_rows_selected: at least one row must be selected';
  end if;

  if (select count(*) from jsonb_array_elements(p_rows) e
      where nullif(e->>'row_id', '') is not null)
     <> (select count(distinct e->>'row_id') from jsonb_array_elements(p_rows) e
         where nullif(e->>'row_id', '') is not null) then
    raise exception 'duplicate_row: the same row cannot be selected twice for one valve';
  end if;

  -- Resolve ONE common weighting basis for the whole valve (§ header).
  for v_row in select * from jsonb_array_elements(p_rows) loop
    if coalesce(nullif(v_row->>'emitter_count', '')::numeric, 0) <= 0
       or coalesce(nullif(v_row->>'emitter_count_basis', ''), 'exact') <> 'exact' then
      v_all_emitters := false;
    end if;
    if coalesce(nullif(v_row->>'vine_count', '')::numeric, 0) <= 0
       or coalesce(nullif(v_row->>'vine_count_basis', ''), 'exact')
          not in ('exact', 'block_total_proportional') then
      v_all_vines := false;
    end if;
    if coalesce(nullif(v_row->>'row_length_metres', '')::numeric, 0) <= 0 then
      v_all_lengths := false;
    end if;
  end loop;

  v_basis := case
    when v_all_emitters then 'emitter_count'
    when v_all_vines then 'vine_count'
    when v_all_lengths then 'row_length'
    else 'equal_rows' end;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_weight := case v_basis
      when 'emitter_count' then (v_row->>'emitter_count')::numeric
      when 'vine_count' then (v_row->>'vine_count')::numeric
      when 'row_length' then (v_row->>'row_length_metres')::numeric
      else 1 end;
    v_total := v_total + v_weight;
    v_rows_out := v_rows_out || (v_row || jsonb_build_object(
      'row_weight', v_weight,
      'weighting_basis', v_basis));
  end loop;

  if v_total <= 0 then
    raise exception 'invalid_row_weights: the selected rows have no usable weighting information';
  end if;

  select count(distinct e->>'block_id') into v_count
  from jsonb_array_elements(v_rows_out) e;

  for v_block in
    select e->>'block_id' as block_id,
           max(e->>'block_name') as block_name,
           count(*) as row_count,
           sum((e->>'row_weight')::numeric) as block_weight,
           case when count(*) filter (where coalesce(nullif(e->>'vine_count', '')::numeric, 0) <= 0) = 0
                then sum((e->>'vine_count')::numeric)::integer else null end as vines,
           case when count(*) filter (where coalesce(nullif(e->>'emitter_count', '')::numeric, 0) <= 0) = 0
                then sum((e->>'emitter_count')::numeric)::integer else null end as emitters,
           sum(nullif(e->>'row_length_metres', '')::numeric) as sel_length,
           min((e->>'row_number')::integer) as row_start,
           max((e->>'row_number')::integer) as row_end
    from jsonb_array_elements(v_rows_out) e
    group by e->>'block_id'
    order by e->>'block_id'
  loop
    v_index := v_index + 1;
    if v_index < v_count then
      v_pct := round(v_block.block_weight / v_total * 100.0, 4);
      v_pct_sum := v_pct_sum + v_pct;
    else
      v_pct := round(100 - v_pct_sum, 4);
    end if;

    v_blocks_out := v_blocks_out || jsonb_build_object(
      'block_id', v_block.block_id,
      'block_name', v_block.block_name,
      'row_count', v_block.row_count,
      'block_weight', v_block.block_weight,
      'allocation_percentage', v_pct,
      'serviced_vine_count', v_block.vines,
      'serviced_emitter_count', v_block.emitters,
      'selected_row_length_metres', v_block.sel_length,
      'row_start', v_block.row_start,
      'row_end', v_block.row_end
    );
  end loop;

  return jsonb_build_object(
    'weighting_basis', v_basis,
    'total_weight', v_total,
    'rows', v_rows_out,
    'blocks', v_blocks_out
  );
end;
$$;

revoke all on function public._irrigation_rows_weighting(jsonb) from public, anon;
grant execute on function public._irrigation_rows_weighting(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. set_irrigation_valve_rows — snapshot the estimates + block summaries
-- ---------------------------------------------------------------------------
-- Additions to the sql/126 contract (same signature):
--   * saved rows snapshot vine/emitter values AND their basis metadata;
--   * per-row geometry warnings for selected rows with incomplete mapping;
--   * response gains 'block_summaries' (coverage vs water share, §12) and
--     'saved_at' so clients can reload without retaining the save response.
create or replace function public.set_irrigation_valve_rows(
  p_vineyard_id uuid,
  p_valve_id uuid,
  p_row_ids uuid[]
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_valve public.irrigation_valves;
  v_available jsonb;
  v_selected jsonb := '[]'::jsonb;
  v_found jsonb;
  v_row_id uuid;
  v_row jsonb;
  v_block jsonb;
  v_weighting jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_conflict record;
  v_old jsonb;
  v_summaries jsonb := '[]'::jsonb;
  v_total_rows integer;
  v_total_len numeric;
  v_sel_rows integer;
  v_sel_len numeric;
  v_block_warnings jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);

  select * into v_valve from public.irrigation_valves where id = p_valve_id;
  if not found or v_valve.vineyard_id <> p_vineyard_id then
    raise exception 'invalid_valve: the valve does not belong to this vineyard';
  end if;

  v_old := jsonb_build_object(
    'rows', public.list_irrigation_valve_rows(p_vineyard_id, p_valve_id),
    'allocations', public._irrigation_valve_allocations(p_valve_id));

  if p_row_ids is not null
     and array_length(p_row_ids, 1) is not null
     and array_length(p_row_ids, 1) <> (select count(distinct r) from unnest(p_row_ids) r) then
    raise exception 'duplicate_row: the same row cannot be selected twice for one valve';
  end if;

  -- Historical links are deactivated, never deleted (sessions carry snapshots).
  update public.irrigation_valve_rows
  set is_active = false, updated_by = auth.uid()
  where valve_id = p_valve_id and is_active;

  -- Empty selection disconnects the valve entirely.
  if p_row_ids is null or array_length(p_row_ids, 1) is null then
    update public.irrigation_valve_blocks
    set is_active = false, effective_to = current_date, updated_by = auth.uid()
    where valve_id = p_valve_id and is_active;

    perform public._irrigation_audit(p_vineyard_id, 'set_rows', 'irrigation_valve', p_valve_id,
      v_old, jsonb_build_object('rows', '[]'::jsonb, 'allocations', '[]'::jsonb));

    return jsonb_build_object(
      'weighting_basis', null,
      'rows', '[]'::jsonb,
      'blocks', '[]'::jsonb,
      'block_summaries', '[]'::jsonb,
      'warnings', '[]'::jsonb,
      'saved_at', now());
  end if;

  -- Every selected row must be a real, active row of THIS vineyard.
  -- v_available carries the SQL 127 estimates + basis metadata.
  v_available := public._irrigation_paddock_rows(p_vineyard_id, null);
  foreach v_row_id in array p_row_ids loop
    select e into v_found
    from jsonb_array_elements(v_available) e
    where (e->>'row_id')::uuid = v_row_id
    limit 1;
    if v_found is null then
      raise exception 'invalid_row: a selected row does not belong to this vineyard or is no longer available';
    end if;
    v_selected := v_selected || v_found;
  end loop;

  v_weighting := public._irrigation_rows_weighting(v_selected);

  -- Warn (never block) when a row is also supplied by another ACTIVE valve.
  for v_conflict in
    select distinct p.name as block_name, vr.row_number, v2.name as valve_name
    from public.irrigation_valve_rows vr
    join public.irrigation_valves v2 on v2.id = vr.valve_id and v2.is_active
    join public.paddocks p on p.id = vr.block_id
    where vr.is_active
      and vr.valve_id <> p_valve_id
      and vr.row_id = any(p_row_ids)
    order by p.name, vr.row_number
  loop
    v_warnings := v_warnings || to_jsonb(format('%s Row %s is also connected to Valve %s.',
      v_conflict.block_name, v_conflict.row_number, v_conflict.valve_name));
  end loop;

  -- Geometry warnings for selected rows with incomplete mapped points.
  for v_row in select * from jsonb_array_elements(v_selected) loop
    if nullif(v_row->>'geometry_warning', '') is not null then
      v_warnings := v_warnings || to_jsonb(v_row->>'geometry_warning');
    end if;
  end loop;

  if v_weighting->>'weighting_basis' = 'equal_rows' then
    v_warnings := v_warnings || to_jsonb(
      'Water allocation is being estimated from the number of selected rows because emitter, vine-count and row-length information is incomplete.'::text);
  end if;

  -- Insert the new explicit row links WITH the estimate snapshot + basis.
  for v_row in select * from jsonb_array_elements(v_weighting->'rows') loop
    insert into public.irrigation_valve_rows
      (vineyard_id, valve_id, block_id, row_id, row_number, row_label,
       vine_count, emitter_count, row_length_metres,
       vine_count_basis, emitter_count_basis,
       vine_count_is_estimated, emitter_count_is_estimated,
       weighting_basis, row_weight, created_by, updated_by)
    values
      (p_vineyard_id, p_valve_id,
       (v_row->>'block_id')::uuid,
       (v_row->>'row_id')::uuid,
       (v_row->>'row_number')::integer,
       v_row->>'row_label',
       nullif(v_row->>'vine_count', '')::integer,
       nullif(v_row->>'emitter_count', '')::integer,
       nullif(v_row->>'row_length_metres', '')::numeric,
       nullif(v_row->>'vine_count_basis', ''),
       nullif(v_row->>'emitter_count_basis', ''),
       nullif(v_row->>'vine_count_is_estimated', '')::boolean,
       nullif(v_row->>'emitter_count_is_estimated', '')::boolean,
       v_row->>'weighting_basis',
       (v_row->>'row_weight')::numeric,
       auth.uid(), auth.uid());
  end loop;

  -- Replace the derived block connections (reporting aggregates by block).
  update public.irrigation_valve_blocks
  set is_active = false, effective_to = current_date, updated_by = auth.uid()
  where valve_id = p_valve_id and is_active;

  for v_block in select * from jsonb_array_elements(v_weighting->'blocks') loop
    insert into public.irrigation_valve_blocks
      (vineyard_id, valve_id, block_id, allocation_method, allocation_percentage,
       serviced_vine_count, serviced_emitter_count, row_start, row_end,
       effective_from, created_by, updated_by)
    values
      (p_vineyard_id, p_valve_id,
       (v_block->>'block_id')::uuid,
       'rows',
       (v_block->>'allocation_percentage')::numeric,
       nullif(v_block->>'serviced_vine_count', '')::integer,
       nullif(v_block->>'serviced_emitter_count', '')::integer,
       nullif(v_block->>'row_start', '')::integer,
       nullif(v_block->>'row_end', '')::integer,
       current_date, auth.uid(), auth.uid());
  end loop;

  -- Block summaries (§12): coverage is DISPLAY context, allocation_percentage
  -- remains the server-authoritative share of the valve's water.
  for v_block in select * from jsonb_array_elements(v_weighting->'blocks') loop
    select count(*), sum(nullif(e->>'row_length_metres', '')::numeric)
    into v_total_rows, v_total_len
    from jsonb_array_elements(v_available) e
    where e->>'block_id' = v_block->>'block_id';

    select count(*), sum(nullif(e->>'row_length_metres', '')::numeric),
           coalesce(jsonb_agg(e->>'geometry_warning')
                    filter (where nullif(e->>'geometry_warning', '') is not null), '[]'::jsonb)
    into v_sel_rows, v_sel_len, v_block_warnings
    from jsonb_array_elements(v_weighting->'rows') e
    where e->>'block_id' = v_block->>'block_id';

    v_summaries := v_summaries || jsonb_build_object(
      'block_id', v_block->>'block_id',
      'block_name', v_block->>'block_name',
      'selected_row_count', v_sel_rows,
      'total_block_row_count', v_total_rows,
      'selected_row_length_metres', v_sel_len,
      'total_block_row_length_metres', v_total_len,
      'selected_vine_count', nullif(v_block->>'serviced_vine_count', '')::integer,
      'selected_emitter_count', nullif(v_block->>'serviced_emitter_count', '')::integer,
      'row_coverage_percent', case when coalesce(v_total_rows, 0) > 0
        then round(v_sel_rows::numeric / v_total_rows * 100.0, 2) end,
      'length_coverage_percent', case when coalesce(v_total_len, 0) > 0 and v_sel_len is not null
        then round(v_sel_len / v_total_len * 100.0, 2) end,
      'allocation_percentage', nullif(v_block->>'allocation_percentage', '')::numeric,
      'weighting_basis', v_weighting->>'weighting_basis',
      'warnings', v_block_warnings
    );
  end loop;

  perform public._irrigation_audit(p_vineyard_id, 'set_rows', 'irrigation_valve', p_valve_id,
    v_old,
    jsonb_build_object(
      'rows', public.list_irrigation_valve_rows(p_vineyard_id, p_valve_id),
      'allocations', public._irrigation_valve_allocations(p_valve_id),
      'weighting_basis', v_weighting->>'weighting_basis'));

  return jsonb_build_object(
    'weighting_basis', v_weighting->>'weighting_basis',
    'rows', v_weighting->'rows',
    'blocks', public.list_irrigation_valve_blocks(p_vineyard_id, p_valve_id),
    'block_summaries', v_summaries,
    'warnings', v_warnings,
    'saved_at', now());
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. list_irrigation_valve_rows — saved snapshot values + saved_at
-- ---------------------------------------------------------------------------
-- Returns SAVED snapshot values (never newly calculated live values); the new
-- basis columns flow through to_jsonb automatically. 'saved_at' exposes the
-- snapshot timestamp so clients can show when the configuration was saved.
create or replace function public.list_irrigation_valve_rows(
  p_vineyard_id uuid,
  p_valve_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._irrigation_require_access(p_vineyard_id);
  return coalesce((
    select jsonb_agg(
      to_jsonb(vr) || jsonb_build_object('block_name', p.name, 'saved_at', vr.updated_at)
      order by p.name, vr.row_number)
    from public.irrigation_valve_rows vr
    join public.paddocks p on p.id = vr.block_id
    where vr.vineyard_id = p_vineyard_id
      and vr.is_active
      and (p_valve_id is null or vr.valve_id = p_valve_id)
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Session snapshots carry the estimate basis metadata
-- ---------------------------------------------------------------------------
-- _irrigation_valve_allocations rows-method elements now include the saved
-- basis fields, so every session configuration_snapshot freezes HOW each row
-- value was obtained (record/update/get session RPCs are unchanged).
create or replace function public._irrigation_valve_allocations(p_valve_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r record;
  v_rows jsonb := '[]'::jsonb;
  v_row jsonb;
  v_out jsonb := '[]'::jsonb;
  v_total_emitters numeric := 0;
  v_total_vines numeric := 0;
  v_total_area numeric := 0;
  v_pct numeric;
  v_method text;
begin
  for r in
    select vb.id as valve_block_id,
           vb.block_id,
           vb.allocation_method,
           vb.allocation_percentage,
           coalesce(vb.serviced_area_m2,
                    nullif(public._paddock_polygon_area_hectares(p.polygon_points) * 10000.0, 0)) as area_m2,
           coalesce(vb.serviced_vine_count, p.vine_count_override) as vine_count,
           vb.serviced_emitter_count,
           vb.configured_flow_litres_per_hour as block_flow,
           vb.row_start,
           vb.row_end,
           p.name as block_name,
           p.irrigation_efficiency_percent as efficiency_percent,
           p.flow_per_emitter as dripper_output_lph,
           p.emitter_spacing as dripper_spacing_m,
           p.vine_spacing,
           p.row_width as row_spacing,
           (
             select alloc->>'varietyId'
             from jsonb_array_elements(
               case when jsonb_typeof(p.variety_allocations) = 'array'
                    then p.variety_allocations else '[]'::jsonb end) alloc
             order by coalesce((alloc->>'percent')::numeric, 0) desc
             limit 1
           ) as variety_id_text,
           (
             select coalesce(alloc->>'name', alloc->>'varietyName')
             from jsonb_array_elements(
               case when jsonb_typeof(p.variety_allocations) = 'array'
                    then p.variety_allocations else '[]'::jsonb end) alloc
             order by coalesce((alloc->>'percent')::numeric, 0) desc
             limit 1
           ) as variety_name,
           case when vb.allocation_method = 'rows' then (
             select jsonb_agg(jsonb_build_object(
               'row_id', vr.row_id,
               'row_number', vr.row_number,
               'row_label', vr.row_label,
               'vine_count', vr.vine_count,
               'vine_count_basis', vr.vine_count_basis,
               'vine_count_is_estimated', vr.vine_count_is_estimated,
               'emitter_count', vr.emitter_count,
               'emitter_count_basis', vr.emitter_count_basis,
               'emitter_count_is_estimated', vr.emitter_count_is_estimated,
               'row_length_metres', vr.row_length_metres,
               'row_weight', vr.row_weight,
               'weighting_basis', vr.weighting_basis
             ) order by vr.row_number)
             from public.irrigation_valve_rows vr
             where vr.valve_id = vb.valve_id and vr.block_id = vb.block_id and vr.is_active
           ) else null end as rows_json,
           case when vb.allocation_method = 'rows' then (
             select min(vr.weighting_basis)
             from public.irrigation_valve_rows vr
             where vr.valve_id = vb.valve_id and vr.block_id = vb.block_id and vr.is_active
           ) else null end as weighting_basis
    from public.irrigation_valve_blocks vb
    join public.paddocks p on p.id = vb.block_id and p.deleted_at is null
    where vb.valve_id = p_valve_id
      and vb.is_active
    order by p.name
  loop
    v_total_emitters := v_total_emitters + coalesce(r.serviced_emitter_count, 0);
    v_total_vines    := v_total_vines + coalesce(r.vine_count, 0);
    v_total_area     := v_total_area + coalesce(r.area_m2, 0);

    v_rows := v_rows || (jsonb_build_object(
      'valve_block_id', r.valve_block_id,
      'block_id', r.block_id,
      'block_name', r.block_name,
      'variety_id', r.variety_id_text,
      'variety_name', r.variety_name,
      'allocation_method', r.allocation_method,
      'stored_percentage', r.allocation_percentage,
      'serviced_area_m2', r.area_m2,
      'serviced_vine_count', r.vine_count,
      'serviced_emitter_count', r.serviced_emitter_count,
      'block_flow_lph', r.block_flow,
      'efficiency_percent', r.efficiency_percent,
      'dripper_output_lph', r.dripper_output_lph,
      'dripper_spacing_m', r.dripper_spacing_m,
      'vine_spacing_m', r.vine_spacing,
      'row_spacing_m', r.row_spacing)
      || case when r.allocation_method = 'rows'
              then jsonb_build_object(
                'rows', coalesce(r.rows_json, '[]'::jsonb),
                'weighting_basis', r.weighting_basis,
                'row_start', r.row_start,
                'row_end', r.row_end)
              else '{}'::jsonb end);
  end loop;

  for v_row in select * from jsonb_array_elements(v_rows) loop
    v_method := v_row->>'allocation_method';
    if v_method = 'manual_percentage' or v_method = 'rows' then
      v_pct := nullif(v_row->>'stored_percentage', '')::numeric;
    elsif v_method = 'emitter_count' then
      if v_total_emitters > 0 and nullif(v_row->>'serviced_emitter_count', '') is not null then
        v_pct := round((v_row->>'serviced_emitter_count')::numeric / v_total_emitters * 100.0, 4);
      else
        v_pct := null;
      end if;
    elsif v_method = 'vine_count' then
      if v_total_vines > 0 and nullif(v_row->>'serviced_vine_count', '') is not null then
        v_pct := round((v_row->>'serviced_vine_count')::numeric / v_total_vines * 100.0, 4);
      else
        v_pct := null;
      end if;
    elsif v_method = 'irrigated_area' then
      if v_total_area > 0 and nullif(v_row->>'serviced_area_m2', '') is not null then
        v_pct := round((v_row->>'serviced_area_m2')::numeric / v_total_area * 100.0, 4);
      else
        v_pct := null;
      end if;
    else
      v_pct := null;
    end if;

    v_out := v_out || (v_row || jsonb_build_object('allocation_percentage', v_pct));
  end loop;

  return v_out;
end;
$$;

revoke all on function public._irrigation_valve_allocations(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. get_irrigation_setup_status — reloadable valve configuration summary
-- ---------------------------------------------------------------------------
-- Each valve entry gains allocation_method, weighting_basis, selected vine and
-- emitter totals (complete-only, never partial sums presented as totals) and
-- rows_saved_at, so clients can leave and reopen without retaining the last
-- save response (§13).
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
      'valves_with_configured_flow', v_flow_valves
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
-- 9. Grants (unchanged signatures — re-granted defensively)
-- ---------------------------------------------------------------------------
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'list_irrigation_available_rows(uuid, uuid)',
    'list_irrigation_valve_rows(uuid, uuid)',
    'set_irrigation_valve_rows(uuid, uuid, uuid[])',
    'get_irrigation_setup_status(uuid)'
  ]
  loop
    execute format('revoke all on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Validation — the migration ABORTS if any estimate rule fails.
--     (Basis rules mirrored by IrrigationRowWeighting.swift and
--      IrrigationLocalCalc.rowBasis in Kotlin.)
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  v2 jsonb;
begin
  -- Spacing estimate: documented rounding (half away from zero, minimum 1).
  assert public._irrigation_spacing_estimate(215.01, 0.5) = 430, '215.01 m ÷ 0.5 m must estimate 430';
  assert public._irrigation_spacing_estimate(215.01, 2.1) = 102, '215.01 m ÷ 2.1 m must round 102.39 → 102';
  assert public._irrigation_spacing_estimate(100, 2.1) = 48, '100 m ÷ 2.1 m must round 47.62 → 48';
  assert public._irrigation_spacing_estimate(1.0, 3.0) = 1, 'a mapped row estimates at least one unit';
  assert public._irrigation_spacing_estimate(null, 2.0) is null, 'missing length must return NULL, not zero';
  assert public._irrigation_spacing_estimate(100, null) is null, 'missing spacing must return NULL, not zero';
  assert public._irrigation_spacing_estimate(100, 0) is null, 'zero spacing must return NULL, not zero';

  -- Reconciliation: proportional by length, sum EXACTLY equals block total.
  v := public._irrigation_reconcile_counts(100, '[215.01, 215.01]'::jsonb);
  assert v = '[50, 50]'::jsonb, 'equal lengths must split the block total evenly';

  v := public._irrigation_reconcile_counts(100, '[1, 1, 1]'::jsonb);
  assert v = '[34, 33, 33]'::jsonb, 'remainder must go to the earliest row on ties';

  v := public._irrigation_reconcile_counts(103, '[100, 50, 50]'::jsonb);
  assert v = '[51, 26, 26]'::jsonb, 'largest fractional parts receive the remainder deterministically';
  assert (v->>0)::integer + (v->>1)::integer + (v->>2)::integer = 103,
    'reconciled row vines must sum exactly to the configured block total';

  -- Unequal lengths receive unequal vine counts.
  v := public._irrigation_reconcile_counts(150, '[200, 100]'::jsonb);
  assert v = '[100, 50]'::jsonb, 'longer rows must receive proportionally more vines';

  -- One-row block gets the whole total.
  v := public._irrigation_reconcile_counts(104, '[200]'::jsonb);
  assert v = '[104]'::jsonb, 'a single valid row absorbs the entire block total';

  -- Missing lengths are excluded and stay NULL (never zero).
  v := public._irrigation_reconcile_counts(100, '[100, null, 100]'::jsonb);
  assert v = '[50, null, 50]'::jsonb, 'rows without length must stay NULL while valid rows reconcile';

  -- No usable weights → all NULL.
  v := public._irrigation_reconcile_counts(100, '[null, null]'::jsonb);
  assert v = '[null, null]'::jsonb, 'no valid lengths must produce all NULLs';

  -- Deterministic: identical input → identical output.
  v := public._irrigation_reconcile_counts(103, '[100, 50, 50]'::jsonb);
  v2 := public._irrigation_reconcile_counts(103, '[100, 50, 50]'::jsonb);
  assert v = v2, 'reconciliation must be deterministic across repeated calls';

  -- WEIGHTING HONESTY -------------------------------------------------------

  -- Spacing-derived emitters are just row-length weighting → basis row_length.
  v := public._irrigation_rows_weighting(jsonb_build_array(
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a001',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A', 'row_number', 1,
      'emitter_count', 430, 'emitter_count_basis', 'row_length_spacing',
      'vine_count', 103, 'vine_count_basis', 'row_length_spacing',
      'row_length_metres', 215.01),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000b001',
      'block_id', '00000000-0000-0000-0000-000000000002', 'block_name', 'B', 'row_number', 1,
      'emitter_count', 143, 'emitter_count_basis', 'row_length_spacing',
      'vine_count', 34, 'vine_count_basis', 'row_length_spacing',
      'row_length_metres', 71.67)
  ));
  assert v->>'weighting_basis' = 'row_length',
    'spacing-derived emitter estimates must NOT flip the basis to emitter_count';
  assert (v->'blocks'->0->>'allocation_percentage')::numeric = 75,
    'row-length basis must weight by mapped length (215.01 / 286.68 = 75%)';
  assert (v->'blocks'->0->>'serviced_emitter_count')::integer = 430,
    'estimated emitters remain visible even when the basis is row length';

  -- Reconciled block-total vines ARE a materially independent basis.
  v := public._irrigation_rows_weighting(jsonb_build_array(
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a001',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A', 'row_number', 1,
      'vine_count', 120, 'vine_count_basis', 'block_total_proportional',
      'emitter_count', 200, 'emitter_count_basis', 'row_length_spacing',
      'row_length_metres', 100),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000b001',
      'block_id', '00000000-0000-0000-0000-000000000002', 'block_name', 'B', 'row_number', 1,
      'vine_count', 40, 'vine_count_basis', 'block_total_proportional',
      'emitter_count', 200, 'emitter_count_basis', 'row_length_spacing',
      'row_length_metres', 100)
  ));
  assert v->>'weighting_basis' = 'vine_count',
    'reconciled block-total vines must be used as the vine basis';
  assert (v->'blocks'->0->>'allocation_percentage')::numeric = 75,
    'vine basis must weight 120 / 160 = 75%';

  -- Exact emitters (independently configured) still win.
  v := public._irrigation_rows_weighting(jsonb_build_array(
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a001',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A', 'row_number', 1,
      'emitter_count', 300, 'emitter_count_basis', 'exact', 'row_length_metres', 100),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000b001',
      'block_id', '00000000-0000-0000-0000-000000000002', 'block_name', 'B', 'row_number', 1,
      'emitter_count', 100, 'emitter_count_basis', 'exact', 'row_length_metres', 100)
  ));
  assert v->>'weighting_basis' = 'emitter_count', 'exact emitter counts must use the emitter basis';
  assert (v->'blocks'->0->>'allocation_percentage')::numeric = 75, 'exact emitters weight 300/400 = 75%';

  -- Legacy rows without basis metadata keep the SQL 126 interpretation.
  v := public._irrigation_rows_weighting(jsonb_build_array(
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a001',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A', 'row_number', 1,
      'emitter_count', 130, 'vine_count', 65, 'row_length_metres', 100),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000b001',
      'block_id', '00000000-0000-0000-0000-000000000002', 'block_name', 'B', 'row_number', 1,
      'emitter_count', 70, 'vine_count', 35, 'row_length_metres', 60)
  ));
  assert v->>'weighting_basis' = 'emitter_count',
    'rows without basis metadata must keep the legacy exact interpretation';

  -- One row with missing length + spacing-derived data → equal_rows fallback.
  v := public._irrigation_rows_weighting(jsonb_build_array(
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a001',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A', 'row_number', 1,
      'emitter_count', 200, 'emitter_count_basis', 'row_length_spacing',
      'vine_count', 50, 'vine_count_basis', 'row_length_spacing',
      'row_length_metres', 100),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000b001',
      'block_id', '00000000-0000-0000-0000-000000000002', 'block_name', 'B', 'row_number', 69,
      'vine_count_basis', 'unavailable', 'emitter_count_basis', 'unavailable')
  ));
  assert v->>'weighting_basis' = 'equal_rows',
    'a selected row with missing mapped length must fall back to equal rows';
  assert (v->'blocks'->0->>'allocation_percentage')::numeric = 50,
    'equal-rows fallback weighs each selected row as 1';
  assert v->'blocks'->1->>'serviced_vine_count' is null,
    'missing per-row values must stay NULL in block sums, never zero';

  -- Selected length sums surface for coverage display.
  assert (v->'blocks'->0->>'selected_row_length_metres')::numeric = 100,
    'blocks must expose the sum of valid selected row lengths';
  assert v->'blocks'->1->>'selected_row_length_metres' is null,
    'blocks with no valid lengths must expose NULL, not zero';
end $$;

-- Make PostgREST pick up the changed functions immediately.
notify pgrst, 'reload schema';

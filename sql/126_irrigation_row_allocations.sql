-- =============================================================================
-- 126: Irrigation Records — row-based valve allocation ("rows" method).
--
-- Adds the `rows` allocation method to the SQL 125 shared irrigation schema:
-- users select the exact vineyard rows a valve supplies and the SERVER derives
-- the block connections, hydraulic weights and allocation percentages.
--
-- ROW IDENTITY (audited — reuses the existing VineTrack row model):
--   * Actual vineyard rows live in `paddocks.rows` — a jsonb array of
--     { id, number, startPoint, endPoint }. There is NO dedicated row table.
--   * The stable identity is the element's uuid `id` (the same convention the
--     Pruning Tracker adopted in sql/112 with `pruning_row_segments.paddock_row_id`).
--   * `irrigation_valve_rows.row_id` is therefore a LOGICAL uuid reference
--     (no FK target exists); uniqueness + RPC-only writes keep it consistent.
--   * Rows can be non-sequential (1,2,5,8), start above 1, or be reordered —
--     selections are stored as explicit per-row links, never as ranges.
--
-- WEIGHTING (shared contract — mirrored by IrrigationRowWeighting.swift and
-- IrrigationLocalCalc.rowWeighting in Kotlin; the SQL below is authoritative):
--   One COMMON basis is resolved for the whole valve so units are never mixed:
--     1. emitter_count — only if EVERY selected row has an emitter count
--     2. vine_count    — only if EVERY selected row has a vine count
--     3. row_length    — only if EVERY selected row has a length
--     4. equal_rows    — fallback (each selected row weighs 1)
--   block_weight = Σ row weights of that block
--   allocation_percentage = block_weight ÷ total weight × 100 (4 dp; the last
--   block — ordered by block_id text — absorbs the rounding remainder so the
--   total is EXACTLY 100).
--   Per-row vine/emitter data does not exist in the current row model, so the
--   linking table carries nullable override columns for later; in practice the
--   basis today resolves to row_length (geometry) or equal_rows.
--
-- HISTORY: saved sessions snapshot the selected rows (id, number, label,
-- counts, length, weight, basis, block percentage) inside
-- configuration_snapshot.blocks[].rows — changing a valve's rows later never
-- alters previous sessions or reports (session_blocks stay the report source).
-- record/update/get session RPCs need no signature change: they resolve
-- through `_irrigation_valve_allocations`, which now understands `rows`.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Allow the new method on valve-block connections
-- ---------------------------------------------------------------------------
alter table public.irrigation_valve_blocks
  drop constraint if exists irrigation_valve_blocks_method_check;

alter table public.irrigation_valve_blocks
  add constraint irrigation_valve_blocks_method_check
  check (allocation_method in
         ('manual_percentage','emitter_count','vine_count','irrigated_area','rows'));

-- ---------------------------------------------------------------------------
-- 2. Normalised valve→row linking table (no comma-separated lists)
-- ---------------------------------------------------------------------------
create table if not exists public.irrigation_valve_rows (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  valve_id uuid not null references public.irrigation_valves(id) on delete cascade,
  block_id uuid not null references public.paddocks(id) on delete cascade,
  -- Logical reference to the paddocks.rows jsonb element id (no FK target).
  row_id uuid null,
  row_number integer not null,
  row_label text null,
  vine_count integer null,
  emitter_count integer null,
  row_length_metres numeric null,
  -- Snapshot of the weighting applied when this link was saved.
  weighting_basis text null,
  row_weight numeric null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),

  constraint irrigation_valve_rows_vines_positive
    check (vine_count is null or vine_count > 0),
  constraint irrigation_valve_rows_emitters_positive
    check (emitter_count is null or emitter_count > 0),
  constraint irrigation_valve_rows_length_positive
    check (row_length_metres is null or row_length_metres > 0),
  constraint irrigation_valve_rows_basis_check
    check (weighting_basis is null or weighting_basis in
           ('emitter_count','vine_count','row_length','equal_rows','mixed'))
);

-- The same vineyard row can never be linked twice to the same ACTIVE valve.
create unique index if not exists irrigation_valve_rows_active_uq
  on public.irrigation_valve_rows (valve_id, row_id)
  where is_active and row_id is not null;

create index if not exists irrigation_valve_rows_vineyard_idx
  on public.irrigation_valve_rows (vineyard_id);
create index if not exists irrigation_valve_rows_valve_idx
  on public.irrigation_valve_rows (valve_id);
create index if not exists irrigation_valve_rows_block_idx
  on public.irrigation_valve_rows (block_id);
create index if not exists irrigation_valve_rows_row_idx
  on public.irrigation_valve_rows (row_id);

create or replace trigger irrigation_valve_rows_set_updated_at
before update on public.irrigation_valve_rows
for each row execute function public.set_updated_at();

alter table public.irrigation_valve_rows enable row level security;

drop policy if exists "irrigation_valve_rows_select_feature" on public.irrigation_valve_rows;
create policy "irrigation_valve_rows_select_feature" on public.irrigation_valve_rows
  for select to authenticated
  using (public.has_irrigation_records_access(vineyard_id));
-- No insert/update/delete policies: all writes go through the definer RPCs.

-- ---------------------------------------------------------------------------
-- 3. Pure weighting core (immutable — assert-tested in §9, mirrored by the
--    iOS/Android local calculators for provisional previews only)
-- ---------------------------------------------------------------------------
-- Input: jsonb array of selected rows:
--   { row_id, block_id, block_name, row_number, row_label,
--     vine_count, emitter_count, row_length_metres }
-- Output:
--   { weighting_basis, total_weight,
--     rows:   input rows each + row_weight,
--     blocks: [{ block_id, block_name, row_count, block_weight,
--                allocation_percentage, serviced_vine_count,
--                serviced_emitter_count, row_start, row_end }] }
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
  v_blocks jsonb;
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

  -- Duplicate rows within the same selection are not allowed.
  if (select count(*) from jsonb_array_elements(p_rows) e
      where nullif(e->>'row_id', '') is not null)
     <> (select count(distinct e->>'row_id') from jsonb_array_elements(p_rows) e
         where nullif(e->>'row_id', '') is not null) then
    raise exception 'duplicate_row: the same row cannot be selected twice for one valve';
  end if;

  -- Resolve ONE common weighting basis for the whole valve (§ header).
  for v_row in select * from jsonb_array_elements(p_rows) loop
    if coalesce(nullif(v_row->>'emitter_count', '')::numeric, 0) <= 0 then v_all_emitters := false; end if;
    if coalesce(nullif(v_row->>'vine_count', '')::numeric, 0) <= 0 then v_all_vines := false; end if;
    if coalesce(nullif(v_row->>'row_length_metres', '')::numeric, 0) <= 0 then v_all_lengths := false; end if;
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

  -- Deterministic block order (block_id text asc) shared with the clients:
  -- the LAST block absorbs the rounding remainder so the total is exactly 100.
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
-- 4. Internal: the vineyard's REAL configured rows from paddocks.rows
-- ---------------------------------------------------------------------------
-- Only rows with a valid uuid id are selectable (sql/112 identity rule).
-- Row length is derived from the stored start/end coordinates (2 dp) so all
-- clients receive identical values instead of re-deriving them.
create or replace function public._irrigation_paddock_rows(
  p_vineyard_id uuid,
  p_block_id uuid default null
) returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'row_id', r.row_id,
    'block_id', r.block_id,
    'block_name', r.block_name,
    'row_number', r.row_number,
    'row_label', 'Row ' || r.row_number::text,
    'vine_count', null,
    'emitter_count', null,
    'row_length_metres', r.length_m,
    'is_active', true
  ) order by r.block_name, r.row_number), '[]'::jsonb)
  from (
    select p.id as block_id,
           p.name as block_name,
           (elem->>'id')::uuid as row_id,
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
    from public.paddocks p
    cross join lateral jsonb_array_elements(coalesce(p.rows, '[]'::jsonb)) elem
    where p.vineyard_id = p_vineyard_id
      and p.deleted_at is null
      and (p_block_id is null or p.id = p_block_id)
      and jsonb_typeof(elem->'number') = 'number'
      and (elem->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) r
$$;

revoke all on function public._irrigation_paddock_rows(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. RPC: list_irrigation_available_rows
-- ---------------------------------------------------------------------------
create or replace function public.list_irrigation_available_rows(
  p_vineyard_id uuid,
  p_block_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rows jsonb;
  v_out jsonb := '[]'::jsonb;
  v_row jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_rows := public._irrigation_paddock_rows(p_vineyard_id, p_block_id);

  for v_row in select * from jsonb_array_elements(v_rows) loop
    v_out := v_out || (v_row || jsonb_build_object(
      'connected_valve_ids', coalesce((
        select jsonb_agg(distinct vr.valve_id)
        from public.irrigation_valve_rows vr
        join public.irrigation_valves v on v.id = vr.valve_id and v.is_active
        where vr.row_id = (v_row->>'row_id')::uuid and vr.is_active
      ), '[]'::jsonb),
      'connected_valve_names', coalesce((
        select jsonb_agg(distinct v.name)
        from public.irrigation_valve_rows vr
        join public.irrigation_valves v on v.id = vr.valve_id and v.is_active
        where vr.row_id = (v_row->>'row_id')::uuid and vr.is_active
      ), '[]'::jsonb)
    ));
  end loop;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. RPC: list_irrigation_valve_rows
-- ---------------------------------------------------------------------------
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
      to_jsonb(vr) || jsonb_build_object('block_name', p.name)
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
-- 7. RPC: set_irrigation_valve_rows — atomic replace of a valve's row links
--    AND the derived block connections (allocation_method = 'rows').
-- ---------------------------------------------------------------------------
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
begin
  perform public._irrigation_require_access(p_vineyard_id);

  select * into v_valve from public.irrigation_valves where id = p_valve_id;
  if not found or v_valve.vineyard_id <> p_vineyard_id then
    raise exception 'invalid_valve: the valve does not belong to this vineyard';
  end if;

  v_old := jsonb_build_object(
    'rows', public.list_irrigation_valve_rows(p_vineyard_id, p_valve_id),
    'allocations', public._irrigation_valve_allocations(p_valve_id));

  -- Duplicate row ids in one request are rejected.
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
      'warnings', '[]'::jsonb);
  end if;

  -- Every selected row must be a real, active row of THIS vineyard.
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

  -- Server-authoritative weighting (raises on duplicates / empty selections).
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

  if v_weighting->>'weighting_basis' = 'equal_rows' then
    v_warnings := v_warnings || to_jsonb(
      'Water allocation is being estimated from the number of selected rows because emitter, vine-count and row-length information is incomplete.'::text);
  end if;

  -- Insert the new explicit row links (rows 1,2,5,8 stay four links — the
  -- row_start/row_end summary on the block connection is never proof of range).
  for v_row in select * from jsonb_array_elements(v_weighting->'rows') loop
    insert into public.irrigation_valve_rows
      (vineyard_id, valve_id, block_id, row_id, row_number, row_label,
       vine_count, emitter_count, row_length_metres,
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
    'warnings', v_warnings);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Teach the shared configuration resolution about `rows`
-- ---------------------------------------------------------------------------
-- Same contract as sql/125, plus:
--   * allocation_method 'rows' resolves to the server-calculated stored
--     percentage (computed by set_irrigation_valve_rows),
--   * rows-method elements carry `rows` (the explicit row snapshot) and
--     `weighting_basis`, which flow into every session configuration_snapshot.
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
               'emitter_count', vr.emitter_count,
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
      -- rows: server-calculated at set_irrigation_valve_rows time.
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
-- 9. Surface row context in validation / preview / recording
-- ---------------------------------------------------------------------------

-- Equal-row estimates must never be presented as exact hydraulics:
-- `_irrigation_compute` (used by preview, record and current-config edits)
-- appends the estimation warning whenever the valve resolves via equal_rows.
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
    v_flow_used := v_valve.configured_flow_litres_per_hour;
    if v_flow_used is null then
      raise exception 'missing_configured_flow: this valve has no configured flow rate — enter a session flow, total volume or meter readings instead';
    end if;
  elsif p_calculation_method = 'session_flow' then
    v_flow_used := p_flow_litres_per_hour;
  else
    v_flow_used := null;
  end if;

  v_total := public.irrigation_total_volume(
    p_calculation_method, v_flow_used, p_duration_minutes,
    p_meter_start_litres, p_meter_finish_litres, p_total_volume_litres);

  v_alloc := public._irrigation_valve_allocations(p_valve_id);
  v_result := public._irrigation_allocate(v_total, v_alloc);

  -- Rows method transparency: equal-row fallback is an ESTIMATE.
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
    'flow_lph_used', v_flow_used,
    'calculation_method', p_calculation_method,
    'unit_context', jsonb_build_object(
      'volume', 'litres', 'flow', 'litres_per_hour',
      'area', 'square_metres', 'depth', 'millimetres', 'duration', 'minutes'),
    -- v_alloc includes per-block rows + weighting_basis for rows-method valves,
    -- so every saved session freezes the exact rows it was calculated from.
    'blocks', v_alloc
  );

  return v_result || jsonb_build_object(
    'irrigation_system_id', v_system.id,
    'irrigation_system_name', v_system.name,
    'valve_id', v_valve.id,
    'valve_name', v_valve.name,
    'flow_litres_per_hour_used', v_flow_used,
    'configuration_snapshot', v_snapshot
  );
end;
$$;

revoke all on function public._irrigation_compute(uuid, uuid, integer, text, numeric, numeric, numeric, numeric) from public, anon, authenticated;

-- validate_irrigation_configuration: unchanged checks, plus rows context —
-- weighting basis, per-block rows (already inside allocations) and warnings
-- (equal-row estimate + rows shared with other active valves).
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

  return jsonb_build_object(
    'valve_id', p_valve_id,
    'valve_name', v_valve.name,
    'can_record', v_valve.is_active and v_alloc_ok and jsonb_array_length(v_issues) = 0,
    'has_configured_flow', v_valve.configured_flow_litres_per_hour is not null,
    'configured_flow_litres_per_hour', v_valve.configured_flow_litres_per_hour,
    'measured_flow_litres_per_hour', v_valve.measured_flow_litres_per_hour,
    'requires_volume_entry', v_valve.configured_flow_litres_per_hour is null,
    'allocations', v_alloc,
    'allocation_total', round(v_sum, 2),
    'weighting_basis', v_basis,
    'issues', v_issues,
    'warnings', v_warnings
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Setup status: per-valve rows visibility
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
  v_alloc jsonb;
  v_el jsonb;
  v_sum numeric;
  v_ok boolean;
  v_uses_rows boolean;
  v_row_count integer;
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
    for v_el in select * from jsonb_array_elements(v_alloc) loop
      if nullif(v_el->>'allocation_percentage', '') is null then
        v_ok := false;
      else
        v_sum := v_sum + (v_el->>'allocation_percentage')::numeric;
      end if;
      if v_el->>'allocation_method' = 'rows' then
        v_uses_rows := true;
      end if;
    end loop;
    if v_ok and abs(v_sum - 100) > 0.05 then
      v_ok := false;
    end if;
    if v_ok then
      v_allocated_valves := v_allocated_valves + 1;
    end if;
    if v_valve.configured_flow_litres_per_hour is not null then
      v_flow_valves := v_flow_valves + 1;
    end if;

    select count(*) into v_row_count
    from public.irrigation_valve_rows vr
    where vr.valve_id = v_valve.id and vr.is_active;

    v_valves_json := v_valves_json || jsonb_build_object(
      'valve_id', v_valve.id,
      'valve_name', v_valve.name,
      'block_count', jsonb_array_length(v_alloc),
      'allocation_total', round(v_sum, 2),
      'allocation_ok', v_ok,
      'has_configured_flow', v_valve.configured_flow_litres_per_hour is not null,
      'uses_rows', v_uses_rows,
      'row_count', v_row_count
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
-- 11. Grants
-- ---------------------------------------------------------------------------
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'list_irrigation_available_rows(uuid, uuid)',
    'list_irrigation_valve_rows(uuid, uuid)',
    'set_irrigation_valve_rows(uuid, uuid, uuid[])',
    'validate_irrigation_configuration(uuid, uuid)',
    'get_irrigation_setup_status(uuid)'
  ]
  loop
    execute format('revoke all on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 12. Validation — the migration ABORTS if any weighting rule fails.
--     (Mirrored by IrrigationCalculatorFixtureTests.swift and
--      IrrigationCalculatorFixtureTest.kt.)
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
  b0 jsonb;
  b1 jsonb;
  v_failed boolean;
begin
  -- Emitter basis: A(130 + 70) vs B(100) → 66.6667 / 33.3333, total EXACTLY 100.
  v := public._irrigation_rows_weighting(jsonb_build_array(
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a001',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'Block 1A',
      'row_number', 1, 'row_label', 'Row 1', 'emitter_count', 130, 'vine_count', 65, 'row_length_metres', 100),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a002',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'Block 1A',
      'row_number', 2, 'row_label', 'Row 2', 'emitter_count', 70, 'vine_count', 35, 'row_length_metres', 60),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000b001',
      'block_id', '00000000-0000-0000-0000-000000000002', 'block_name', 'Block 1B',
      'row_number', 1, 'row_label', 'Row 1', 'emitter_count', 100, 'vine_count', 50, 'row_length_metres', 80)
  ));
  assert v->>'weighting_basis' = 'emitter_count', 'complete emitter data must use the emitter basis';
  b0 := v->'blocks'->0;
  b1 := v->'blocks'->1;
  assert (b0->>'allocation_percentage')::numeric = 66.6667, 'Block 1A must be 66.6667%';
  assert (b1->>'allocation_percentage')::numeric = 33.3333, 'Block 1B must absorb the remainder to 33.3333%';
  assert (b0->>'allocation_percentage')::numeric + (b1->>'allocation_percentage')::numeric = 100,
    'row-based block percentages must total exactly 100';
  assert (b0->>'serviced_emitter_count')::integer = 200, 'Block 1A serviced emitters must sum to 200';
  assert (b0->>'serviced_vine_count')::integer = 100, 'Block 1A serviced vines must sum to 100';

  -- Mixed emitters (one missing) but complete vines → vine basis, never mixed units.
  v := public._irrigation_rows_weighting(jsonb_build_array(
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a001',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A',
      'row_number', 1, 'emitter_count', 130, 'vine_count', 60, 'row_length_metres', 100),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000b001',
      'block_id', '00000000-0000-0000-0000-000000000002', 'block_name', 'B',
      'row_number', 1, 'vine_count', 40, 'row_length_metres', 80)
  ));
  assert v->>'weighting_basis' = 'vine_count', 'incomplete emitters with complete vines must use the vine basis';
  assert (v->'blocks'->0->>'allocation_percentage')::numeric = 60, 'vine-basis Block A must be 60%';
  assert v->'blocks'->1->>'serviced_emitter_count' is null, 'incomplete block emitters must be NULL, not zero';

  -- Lengths only → row_length basis.
  v := public._irrigation_rows_weighting(jsonb_build_array(
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a001',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A',
      'row_number', 1, 'row_length_metres', 150),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000b001',
      'block_id', '00000000-0000-0000-0000-000000000002', 'block_name', 'B',
      'row_number', 1, 'row_length_metres', 50)
  ));
  assert v->>'weighting_basis' = 'row_length', 'lengths only must use the row-length basis';
  assert (v->'blocks'->0->>'allocation_percentage')::numeric = 75, 'length-basis Block A must be 75%';

  -- No usable data → equal rows: A has 3 rows, B has 1 row → 75 / 25.
  -- Non-sequential selection 1,2,5,8 stays four explicit rows (start/end are summaries).
  v := public._irrigation_rows_weighting(jsonb_build_array(
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a001',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A', 'row_number', 1),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a002',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A', 'row_number', 2),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a003',
      'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A', 'row_number', 5),
    jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000b001',
      'block_id', '00000000-0000-0000-0000-000000000002', 'block_name', 'B', 'row_number', 8)
  ));
  assert v->>'weighting_basis' = 'equal_rows', 'no data must fall back to equal rows';
  assert (v->'blocks'->0->>'allocation_percentage')::numeric = 75, 'equal-rows Block A must be 75%';
  assert (v->'blocks'->0->>'row_count')::integer = 3, 'Block A must keep 3 explicit row links';
  assert (v->'blocks'->0->>'row_start')::integer = 1 and (v->'blocks'->0->>'row_end')::integer = 5,
    'row_start/row_end are min/max summaries only';

  -- Duplicate rows rejected.
  v_failed := false;
  begin
    perform public._irrigation_rows_weighting(jsonb_build_array(
      jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a001',
        'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A', 'row_number', 1),
      jsonb_build_object('row_id', '00000000-0000-0000-0000-00000000a001',
        'block_id', '00000000-0000-0000-0000-000000000001', 'block_name', 'A', 'row_number', 1)
    ));
  exception when others then v_failed := true; end;
  assert v_failed, 'duplicate rows in one selection must be rejected';

  -- Empty selection rejected.
  v_failed := false;
  begin
    perform public._irrigation_rows_weighting('[]'::jsonb);
  exception when others then v_failed := true; end;
  assert v_failed, 'empty row selection must be rejected';

  -- The rows-method percentages flow through the untouched allocation core.
  v := public._irrigation_allocate(7000, jsonb_build_array(
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000001',
      'block_name', 'Block 1A', 'allocation_method', 'rows',
      'allocation_percentage', 66.6667, 'serviced_vine_count', 100),
    jsonb_build_object('block_id', '00000000-0000-0000-0000-000000000002',
      'block_name', 'Block 1B', 'allocation_method', 'rows',
      'allocation_percentage', 33.3333)
  ));
  assert (v->'blocks'->0->>'allocated_volume_litres')::numeric = 4666.669,
    'rows-method allocation must flow through _irrigation_allocate unchanged';
end $$;

-- Make PostgREST pick up the new/changed functions immediately.
notify pgrst, 'reload schema';

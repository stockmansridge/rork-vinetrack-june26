-- =============================================================================
-- 128: Irrigation spacing estimate — function signature fix.
--
-- LIVE FAILURE:
--   function public._irrigation_spacing_estimate(numeric, double precision)
--   does not exist
--   raised inside _irrigation_paddock_rows, which is consumed by
--   list_irrigation_available_rows and set_irrigation_valve_rows. The whole
--   available-rows RPC therefore fails and no SQL 127 estimates load.
--
-- AUDIT (sql/127 §2 + sql/005):
--   * Helper as shipped by SQL 127:
--       public._irrigation_spacing_estimate(p_length_metres numeric,
--                                           p_spacing_metres numeric)
--       returns integer, language sql, immutable.
--   * Callers (the ONLY ones in the schema, all inside
--     _irrigation_paddock_rows):
--       _irrigation_spacing_estimate(v_len, v_block.vine_spacing)
--       _irrigation_spacing_estimate(v_len, v_block.emitter_spacing)
--     v_len is numeric, but paddocks.vine_spacing and paddocks.emitter_spacing
--     are DOUBLE PRECISION (sql/005_paddocks_sync.sql).
--   * ROOT CAUSE: float8 -> numeric is an ASSIGNMENT-context cast in
--     PostgreSQL, not an implicit one, so function resolution cannot match
--     (numeric, double precision) against (numeric, numeric) at runtime.
--     SQL 127's own assert block passed because numeric literals were used.
--
-- FIX (no formula change):
--   1. Keep ONE canonical implementation: (numeric, numeric), numeric
--      internally for predictable round-half-away-from-zero rounding.
--   2. Add thin delegating overloads for every mixed signature, including the
--      exact live failing one (numeric, double precision). No overload owns
--      its own calculation logic.
--   3. Recreate _irrigation_paddock_rows with explicit ::numeric casts at the
--      SELECT and at every call site so resolution never depends on implicit
--      casting again. Output contract is UNCHANGED from sql/127.
--   4. Regression asserts for every signature + the SQL 127 rounding and
--      missing-data rules (null, never zero or an exception).
--   5. Apply-time diagnostics (RAISE NOTICE): per-vineyard smoke test of the
--      corrected row pipeline and a Pinot Noir Row 69 geometry report.
--
-- No public RPC signatures or returned JSON fields change; Portal, iOS and
-- Android SQL 127 wiring stays valid. Clients only need to reload.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Canonical helper — (numeric, numeric), formula identical to SQL 127:
--    round half away from zero, minimum ONE per mapped row, NULL (never zero)
--    when length or spacing is missing, zero or negative.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 2. Compatibility overloads — delegate ONLY, no duplicated calculation.
--    (numeric, double precision) is the exact live failing signature.
-- ---------------------------------------------------------------------------
create or replace function public._irrigation_spacing_estimate(
  p_length_metres numeric,
  p_spacing_metres double precision
) returns integer
language sql
immutable
as $$
  select public._irrigation_spacing_estimate(p_length_metres, p_spacing_metres::numeric)
$$;

create or replace function public._irrigation_spacing_estimate(
  p_length_metres double precision,
  p_spacing_metres numeric
) returns integer
language sql
immutable
as $$
  select public._irrigation_spacing_estimate(p_length_metres::numeric, p_spacing_metres)
$$;

create or replace function public._irrigation_spacing_estimate(
  p_length_metres double precision,
  p_spacing_metres double precision
) returns integer
language sql
immutable
as $$
  select public._irrigation_spacing_estimate(p_length_metres::numeric, p_spacing_metres::numeric)
$$;

revoke all on function public._irrigation_spacing_estimate(numeric, double precision) from public, anon;
grant execute on function public._irrigation_spacing_estimate(numeric, double precision) to authenticated;
revoke all on function public._irrigation_spacing_estimate(double precision, numeric) from public, anon;
grant execute on function public._irrigation_spacing_estimate(double precision, numeric) to authenticated;
revoke all on function public._irrigation_spacing_estimate(double precision, double precision) from public, anon;
grant execute on function public._irrigation_spacing_estimate(double precision, double precision) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. _irrigation_paddock_rows — identical contract to sql/127, with explicit
--    ::numeric casts on the double-precision spacing columns at the SELECT
--    and at every helper call site. list_irrigation_available_rows and
--    set_irrigation_valve_rows consume this unchanged.
-- ---------------------------------------------------------------------------
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
           p.vine_count_override,
           p.vine_spacing::numeric as vine_spacing,
           p.emitter_spacing::numeric as emitter_spacing
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
      elsif public._irrigation_spacing_estimate(v_len, v_block.vine_spacing::numeric) is not null then
        v_vine := public._irrigation_spacing_estimate(v_len, v_block.vine_spacing::numeric);
        v_vine_basis := 'row_length_spacing';
      else
        v_vine := null;
        v_vine_basis := 'unavailable';
      end if;

      v_emit := public._irrigation_spacing_estimate(v_len, v_block.emitter_spacing::numeric);
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
-- 4. Regression asserts — every signature, SQL 127 rounding rule retained.
--    The migration ABORTS here if any resolution or calculation regresses.
-- ---------------------------------------------------------------------------
do $$
begin
  -- Canonical (numeric, numeric)
  assert public._irrigation_spacing_estimate(215.0::numeric, 1.0::numeric) = 215,
    '215.0 m / 1.0 m (numeric, numeric) must estimate 215';
  assert public._irrigation_spacing_estimate(215.0::numeric, 0.5::numeric) = 430,
    '215.0 m / 0.5 m (numeric, numeric) must estimate 430';

  -- Exact live failing signature (numeric, double precision)
  assert public._irrigation_spacing_estimate(215.0::numeric, 1.0::double precision) = 215,
    '215.0 m / 1.0 m (numeric, float8) must estimate 215';
  assert public._irrigation_spacing_estimate(215.0::numeric, 0.5::double precision) = 430,
    '215.0 m / 0.5 m (numeric, float8) must estimate 430';

  -- Reverse mixed signature (double precision, numeric)
  assert public._irrigation_spacing_estimate(215.0::double precision, 1.0::numeric) = 215,
    '215.0 m / 1.0 m (float8, numeric) must estimate 215';
  assert public._irrigation_spacing_estimate(215.0::double precision, 0.5::numeric) = 430,
    '215.0 m / 0.5 m (float8, numeric) must estimate 430';

  -- Both double precision
  assert public._irrigation_spacing_estimate(215.0::double precision, 0.5::double precision) = 430,
    '215.0 m / 0.5 m (float8, float8) must estimate 430';

  -- SQL 127 rounding rule retained: round half away from zero, min one/row.
  assert public._irrigation_spacing_estimate(215.01::numeric, 2.1::double precision) = 102,
    '215.01 m / 2.1 m must round 102.39 -> 102 through the float8 overload';
  assert public._irrigation_spacing_estimate(100::numeric, 2.1::double precision) = 48,
    '100 m / 2.1 m must round 47.62 -> 48 through the float8 overload';
  assert public._irrigation_spacing_estimate(1.0::numeric, 3.0::double precision) = 1,
    'a mapped row estimates at least one unit';

  -- Missing/invalid inputs stay NULL — never zero, never an exception.
  assert public._irrigation_spacing_estimate(null::numeric, 2.0::double precision) is null,
    'missing length must return NULL';
  assert public._irrigation_spacing_estimate(100::numeric, null::double precision) is null,
    'missing spacing must return NULL';
  assert public._irrigation_spacing_estimate(100::numeric, 0::double precision) is null,
    'zero spacing must return NULL';
  assert public._irrigation_spacing_estimate(100::numeric, (-1.5)::double precision) is null,
    'negative spacing must return NULL';
  assert public._irrigation_spacing_estimate((-5)::numeric, 2.0::double precision) is null,
    'invalid (negative) length must return NULL';

  raise notice 'SQL 128: all spacing-estimate signature and rounding asserts passed.';
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Apply-time live validation — smoke-runs the corrected pipeline against
--    every vineyard that has mapped rows (the exact path
--    list_irrigation_available_rows uses), so a resolution failure like the
--    live one can never ship silently again. Read-only; NOTICE output only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_vineyard record;
  v_rows jsonb;
  v_count integer;
  v_with_len integer;
  v_with_vines integer;
  v_with_emitters integer;
begin
  for v_vineyard in
    select distinct p.vineyard_id
    from public.paddocks p
    where p.deleted_at is null
      and p.rows is not null
      and jsonb_typeof(p.rows) = 'array'
      and jsonb_array_length(p.rows) > 0
    limit 25
  loop
    v_rows := public._irrigation_paddock_rows(v_vineyard.vineyard_id, null);
    select count(*),
           count(*) filter (where nullif(e->>'row_length_metres', '') is not null),
           count(*) filter (where nullif(e->>'vine_count', '') is not null),
           count(*) filter (where nullif(e->>'emitter_count', '') is not null)
    into v_count, v_with_len, v_with_vines, v_with_emitters
    from jsonb_array_elements(v_rows) e;

    raise notice 'SQL 128 smoke: vineyard % -> % mapped rows (% with length, % with vine estimates, % with emitter estimates).',
      v_vineyard.vineyard_id, v_count, v_with_len, v_with_vines, v_with_emitters;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Pinot Noir Row 69 diagnostic — geometry audit + corrected-pipeline
--    output, printed at apply time. Read-only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_block record;
  v_elem jsonb;
  v_start_ok boolean;
  v_end_ok boolean;
  v_calc jsonb;
begin
  for v_block in
    select p.id, p.vineyard_id, p.name, p.rows as rows_json
    from public.paddocks p
    where p.deleted_at is null
      and p.name ilike '%pinot%'
      and p.rows is not null
      and jsonb_typeof(p.rows) = 'array'
  loop
    select elem into v_elem
    from jsonb_array_elements(v_block.rows_json) elem
    where (elem->>'number')::text = '69'
    limit 1;

    if v_elem is null then
      raise notice 'SQL 128 Row 69: block "%" (%) has no mapped row 69.', v_block.name, v_block.id;
      continue;
    end if;

    v_start_ok := jsonb_typeof(v_elem->'startPoint'->'latitude') = 'number'
              and jsonb_typeof(v_elem->'startPoint'->'longitude') = 'number';
    v_end_ok := jsonb_typeof(v_elem->'endPoint'->'latitude') = 'number'
            and jsonb_typeof(v_elem->'endPoint'->'longitude') = 'number';

    select e into v_calc
    from jsonb_array_elements(public._irrigation_paddock_rows(v_block.vineyard_id, v_block.id)) e
    where e->>'row_number' = '69'
    limit 1;

    raise notice 'SQL 128 Row 69 diagnostic — block "%" (%): row_id=%, startPoint valid=%, endPoint valid=%, row_length_metres=%, vine_count=% (basis %), emitter_count=% (basis %), warning=%',
      v_block.name, v_block.id,
      coalesce(v_elem->>'id', '<missing>'),
      v_start_ok, v_end_ok,
      coalesce(v_calc->>'row_length_metres', 'null'),
      coalesce(v_calc->>'vine_count', 'null'),
      coalesce(v_calc->>'vine_count_basis', 'null'),
      coalesce(v_calc->>'emitter_count', 'null'),
      coalesce(v_calc->>'emitter_count_basis', 'null'),
      coalesce(v_calc->>'geometry_warning', 'none');
  end loop;
end;
$$;

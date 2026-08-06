-- =====================================================================
-- 171_pin_placement_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/171_pin_placement_contract.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production pin is created, changed or deleted.
--
-- Test map
--   T1  Objects exist: summary function, pin_placements, resolve fn, pins_export
--   T2  Row summary formatting matches the mobile contract byte-for-byte
--   T3  Block-scope pin with paddock_id and NO row is assigned (basis block)
--   T4  Row-scope pin with segments and NO base row number is assigned
--       (basis row_segments) and its row_summary derives from segments
--   T5  Point pin with coordinates and NO block is assigned (point_coordinates)
--   T6  Snapped point with block and row is assigned (snapped_point)
--   T7  Legacy pin (no scope) with block, no row values -> legacy_block, no warning
--   T8  Legacy pin (no scope) with coordinates, no block -> point_coordinates
--   T9  Genuinely empty pin -> unassigned + 'unassigned_location'
--   T10 Deleted segments do not count: stored row scope with zero live
--       segments falls back (metadata incomplete, never amber unassigned)
--   T11 Exact path-row values preserved; no side is invented (null stays null)
--   T12 pins_export returns the same placement as pin_placements
--   T13 All fixtures discarded by the final ROLLBACK
--
-- Expected final output:
--   NOTICE: SQL 171 pin placement tests: ALL PASSED
-- =====================================================================

begin;

do $$
declare
  v_vineyard uuid := gen_random_uuid();
  v_block uuid := gen_random_uuid();
  v_pin_block uuid := gen_random_uuid();
  v_pin_row uuid := gen_random_uuid();
  v_pin_point uuid := gen_random_uuid();
  v_pin_snapped uuid := gen_random_uuid();
  v_pin_legacy_block uuid := gen_random_uuid();
  v_pin_legacy_point uuid := gen_random_uuid();
  v_pin_empty uuid := gen_random_uuid();
  v_pin_row_nosegs uuid := gen_random_uuid();
  r record;
  e record;
  v_text text;
begin
  -- ---------------------------------------------------------------
  -- T1: objects exist
  -- ---------------------------------------------------------------
  perform 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pin_row_selection_summary';
  if not found then raise exception 'T1: pin_row_selection_summary missing'; end if;
  perform 1 from pg_views where schemaname = 'public' and viewname = 'pin_placements';
  if not found then raise exception 'T1: pin_placements view missing'; end if;
  perform 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'resolve_pin_placement';
  if not found then raise exception 'T1: resolve_pin_placement missing'; end if;
  perform 1 from pg_views where schemaname = 'public' and viewname = 'pins_export';
  if not found then raise exception 'T1: pins_export view missing'; end if;
  raise notice 'T1 passed';

  -- ---------------------------------------------------------------
  -- T2: row summary formatting (mirror of ManualIssueContract tests)
  -- ---------------------------------------------------------------
  v_text := public.pin_row_selection_summary(
    '[{"row":2,"segment":1},{"row":2,"segment":2},{"row":2,"segment":3},{"row":2,"segment":4},
      {"row":3,"segment":1},{"row":3,"segment":2},{"row":3,"segment":3},{"row":3,"segment":4},
      {"row":4,"segment":1},{"row":4,"segment":2},{"row":4,"segment":3},{"row":4,"segment":4},
      {"row":6,"segment":1},{"row":6,"segment":2},{"row":6,"segment":3},{"row":6,"segment":4}]'::jsonb);
  if v_text is distinct from 'Rows 2–4, 6' then
    raise exception 'T2: whole-row ranges, got %', v_text;
  end if;

  v_text := public.pin_row_selection_summary(
    '[{"row":8,"segment":1},{"row":8,"segment":2},{"row":8,"segment":3},{"row":8,"segment":4}]'::jsonb);
  if v_text is distinct from 'Row 8' then
    raise exception 'T2: single whole row, got %', v_text;
  end if;

  v_text := public.pin_row_selection_summary(
    '[{"row":5,"segment":1},{"row":5,"segment":2}]'::jsonb);
  if v_text is distinct from 'Row 5 (sections 1–2)' then
    raise exception 'T2: contiguous sections, got %', v_text;
  end if;

  v_text := public.pin_row_selection_summary(
    '[{"row":2,"segment":1},{"row":2,"segment":2},{"row":2,"segment":3},{"row":2,"segment":4},
      {"row":3,"segment":1},{"row":3,"segment":2},{"row":3,"segment":3},{"row":3,"segment":4},
      {"row":5,"segment":1},{"row":5,"segment":2}]'::jsonb);
  if v_text is distinct from 'Rows 2–3 · Row 5 (sections 1–2)' then
    raise exception 'T2: mixed summary, got %', v_text;
  end if;

  v_text := public.pin_row_selection_summary(
    '[{"row":5,"segment":1},{"row":5,"segment":3}]'::jsonb);
  if v_text is distinct from 'Row 5 (sections 1, 3)' then
    raise exception 'T2: non-contiguous sections, got %', v_text;
  end if;

  if public.pin_row_selection_summary('[]'::jsonb) is not null then
    raise exception 'T2: empty selection must be null';
  end if;
  raise notice 'T2 passed';

  -- ---------------------------------------------------------------
  -- Fixtures
  -- ---------------------------------------------------------------
  insert into public.vineyards (id, name) values (v_vineyard, 'Placement Test Vineyard');
  insert into public.paddocks (id, vineyard_id, name) values (v_block, v_vineyard, 'Placement Block A');

  -- T3 fixture: block scope, no row anywhere
  insert into public.pins (id, vineyard_id, paddock_id, mode, button_name, button_color,
                           latitude, longitude, location_scope, is_completed)
  values (v_pin_block, v_vineyard, v_block, 'Repairs', 'Broken Post', 'brown',
          -34.5, 148.5, 'block', false);

  -- T4 fixture: row scope, segments only — NO row number on the base row
  insert into public.pins (id, vineyard_id, paddock_id, mode, button_name, button_color,
                           latitude, longitude, location_scope, is_completed)
  values (v_pin_row, v_vineyard, v_block, 'Repairs', 'Broken Wire', 'orange',
          -34.5, 148.5, 'row', false);
  insert into public.pin_row_segments (pin_id, row_number, segment_number) values
    (v_pin_row, 41, 1), (v_pin_row, 41, 2), (v_pin_row, 41, 3), (v_pin_row, 41, 4),
    (v_pin_row, 42, 1), (v_pin_row, 42, 2), (v_pin_row, 42, 3), (v_pin_row, 42, 4),
    (v_pin_row, 43, 1), (v_pin_row, 43, 2), (v_pin_row, 43, 3), (v_pin_row, 43, 4);

  -- T5 fixture: point scope, coordinates only, no block
  insert into public.pins (id, vineyard_id, mode, button_name, button_color,
                           latitude, longitude, location_scope, is_completed)
  values (v_pin_point, v_vineyard, 'Repairs', 'Irrigation', 'blue',
          -34.51, 148.51, 'point', false);

  -- T6 fixture: snapped point with block and rows; exact path row 19.5; NO side
  insert into public.pins (id, vineyard_id, paddock_id, mode, button_name, button_color,
                           latitude, longitude, location_scope, snapped_to_row,
                           driving_row_number, pin_row_number, snapped_latitude,
                           snapped_longitude, along_row_distance_m, is_completed)
  values (v_pin_snapped, v_vineyard, v_block, 'Growth', 'Powdery', 'darkgreen',
          -34.52, 148.52, 'point', true, 19.5, 19, -34.5201, 148.5201, 42.7, false);

  -- T7 fixture: legacy (no scope), block only, no row values
  insert into public.pins (id, vineyard_id, paddock_id, mode, button_name, button_color,
                           latitude, longitude, is_completed)
  values (v_pin_legacy_block, v_vineyard, v_block, 'Repairs', 'Other', 'gray',
          -34.53, 148.53, false);

  -- T8 fixture: legacy (no scope), coordinates only
  insert into public.pins (id, vineyard_id, mode, button_name, button_color,
                           latitude, longitude, is_completed)
  values (v_pin_legacy_point, v_vineyard, 'Growth', 'Blackberries', 'darkgreen',
          -34.54, 148.54, false);

  -- T9 fixture: genuinely empty — no block, no segments, no coordinates
  insert into public.pins (id, vineyard_id, mode, button_name, button_color, is_completed)
  values (v_pin_empty, v_vineyard, 'Repairs', 'Empty', 'gray', false);

  -- T10 fixture: stored row scope whose segments were deleted (scope change
  -- replay), block + coordinates remain
  insert into public.pins (id, vineyard_id, paddock_id, mode, button_name, button_color,
                           latitude, longitude, location_scope, is_completed)
  values (v_pin_row_nosegs, v_vineyard, v_block, 'Repairs', 'Vine Issue', 'green',
          -34.55, 148.55, 'row', false);

  -- ---------------------------------------------------------------
  -- T3: block-scope pin with paddock_id and no row is assigned
  -- ---------------------------------------------------------------
  select * into r from public.pin_placements where pin_id = v_pin_block;
  if not r.is_location_assigned then raise exception 'T3: block pin must be assigned'; end if;
  if r.location_assignment_basis is distinct from 'block' then
    raise exception 'T3: basis, got %', r.location_assignment_basis;
  end if;
  if r.location_warning_code is not null then
    raise exception 'T3: warning must be null, got %', r.location_warning_code;
  end if;
  if r.paddock_name is distinct from 'Placement Block A' then
    raise exception 'T3: block name must be visible, got %', r.paddock_name;
  end if;
  raise notice 'T3 passed';

  -- ---------------------------------------------------------------
  -- T4: row-scope pin with segments, no base row number, is assigned
  -- ---------------------------------------------------------------
  select * into r from public.pin_placements where pin_id = v_pin_row;
  if not r.is_location_assigned then raise exception 'T4: row pin must be assigned'; end if;
  if r.location_assignment_basis is distinct from 'row_segments' then
    raise exception 'T4: basis, got %', r.location_assignment_basis;
  end if;
  if r.location_warning_code is not null then
    raise exception 'T4: warning must be null, got %', r.location_warning_code;
  end if;
  if r.row_summary is distinct from 'Rows 41–43' then
    raise exception 'T4: row summary, got %', r.row_summary;
  end if;
  if not r.has_row_segments then raise exception 'T4: has_row_segments'; end if;
  raise notice 'T4 passed';

  -- ---------------------------------------------------------------
  -- T5: point pin with coordinates and no block is assigned
  -- ---------------------------------------------------------------
  select * into r from public.pin_placements where pin_id = v_pin_point;
  if not r.is_location_assigned then raise exception 'T5: point pin must be assigned'; end if;
  if r.location_assignment_basis is distinct from 'point_coordinates' then
    raise exception 'T5: basis, got %', r.location_assignment_basis;
  end if;
  if r.location_warning_code is not null then
    raise exception 'T5: warning must be null, got %', r.location_warning_code;
  end if;
  raise notice 'T5 passed';

  -- ---------------------------------------------------------------
  -- T6: snapped point with block and row is assigned; exact values kept
  -- ---------------------------------------------------------------
  select * into r from public.pin_placements where pin_id = v_pin_snapped;
  if not r.is_location_assigned then raise exception 'T6: snapped pin must be assigned'; end if;
  if r.location_assignment_basis is distinct from 'snapped_point' then
    raise exception 'T6: basis, got %', r.location_assignment_basis;
  end if;
  if r.driving_row_number is distinct from 19.5 then
    raise exception 'T6: exact path row must be preserved, got %', r.driving_row_number;
  end if;
  if r.pin_side is not null then
    raise exception 'T6: no side must be invented, got %', r.pin_side;
  end if;
  if r.location_warning_code is not null then
    raise exception 'T6: warning must be null, got %', r.location_warning_code;
  end if;
  raise notice 'T6 passed';

  -- ---------------------------------------------------------------
  -- T7: legacy block-only pin -> legacy_block, assigned, no warning
  -- ---------------------------------------------------------------
  select * into r from public.pin_placements where pin_id = v_pin_legacy_block;
  if not r.is_location_assigned then raise exception 'T7: legacy block pin must be assigned'; end if;
  if r.location_assignment_basis is distinct from 'legacy_block' then
    raise exception 'T7: basis, got %', r.location_assignment_basis;
  end if;
  if r.location_scope is distinct from 'block' then
    raise exception 'T7: derived scope, got %', r.location_scope;
  end if;
  if r.location_warning_code is not null then
    raise exception 'T7: warning must be null, got %', r.location_warning_code;
  end if;
  raise notice 'T7 passed';

  -- ---------------------------------------------------------------
  -- T8: legacy coordinate-only pin -> point_coordinates, assigned
  -- ---------------------------------------------------------------
  select * into r from public.pin_placements where pin_id = v_pin_legacy_point;
  if not r.is_location_assigned then raise exception 'T8: legacy point pin must be assigned'; end if;
  if r.location_assignment_basis is distinct from 'point_coordinates' then
    raise exception 'T8: basis, got %', r.location_assignment_basis;
  end if;
  if r.location_warning_code is not null then
    raise exception 'T8: warning must be null, got %', r.location_warning_code;
  end if;
  raise notice 'T8 passed';

  -- ---------------------------------------------------------------
  -- T9: genuinely empty pin -> unassigned + warning
  -- ---------------------------------------------------------------
  select * into r from public.pin_placements where pin_id = v_pin_empty;
  if r.is_location_assigned then raise exception 'T9: empty pin must be unassigned'; end if;
  if r.location_assignment_basis is distinct from 'unassigned' then
    raise exception 'T9: basis, got %', r.location_assignment_basis;
  end if;
  if r.location_warning_code is distinct from 'unassigned_location' then
    raise exception 'T9: warning, got %', r.location_warning_code;
  end if;
  raise notice 'T9 passed';

  -- ---------------------------------------------------------------
  -- T10: stored row scope with zero live segments falls back safely —
  -- block stays visible, metadata flagged, never the amber unassigned
  -- ---------------------------------------------------------------
  select * into r from public.pin_placements where pin_id = v_pin_row_nosegs;
  if not r.is_location_assigned then
    raise exception 'T10: fallback must still be assigned';
  end if;
  if r.location_warning_code is distinct from 'location_metadata_incomplete' then
    raise exception 'T10: warning, got %', r.location_warning_code;
  end if;
  if r.paddock_name is distinct from 'Placement Block A' then
    raise exception 'T10: block name must remain visible, got %', r.paddock_name;
  end if;
  -- And deleting T4''s segments flips it to the same safe fallback.
  delete from public.pin_row_segments where pin_id = v_pin_row;
  select * into r from public.pin_placements where pin_id = v_pin_row;
  if r.has_row_segments then raise exception 'T10: deleted segments must not count'; end if;
  if r.location_assignment_basis = 'row_segments' then
    raise exception 'T10: basis must no longer be row_segments';
  end if;
  if r.location_warning_code is distinct from 'location_metadata_incomplete' then
    raise exception 'T10: post-delete warning, got %', r.location_warning_code;
  end if;
  raise notice 'T10 passed';

  -- ---------------------------------------------------------------
  -- T11 covered inside T6 (exact 19.5 + null side). Re-assert on export.
  -- T12: pins_export mirrors pin_placements exactly
  -- ---------------------------------------------------------------
  for e in
    select pp.pin_id,
           pp.location_scope as v_scope, pe.location_scope as e_scope,
           pp.is_location_assigned as v_assigned, pe.is_location_assigned as e_assigned,
           pp.location_assignment_basis as v_basis, pe.location_assignment_basis as e_basis,
           pp.paddock_id as v_block, pe.block_id as e_block,
           pp.paddock_name as v_block_name, pe.block_name as e_block_name,
           pp.row_summary as v_summary, pe.row_summary as e_summary,
           pp.location_warning_code as v_warn, pe.location_warning_code as e_warn,
           pp.driving_row_number as v_driving, pe.driving_row_number as e_driving,
           pp.pin_side as v_side, pe.pin_side as e_side
    from public.pin_placements pp
    join public.pins_export pe on pe.pin_id = pp.pin_id
    where pp.vineyard_id = v_vineyard
  loop
    if e.v_scope is distinct from e.e_scope
       or e.v_assigned is distinct from e.e_assigned
       or e.v_basis is distinct from e.e_basis
       or e.v_block is distinct from e.e_block
       or e.v_block_name is distinct from e.e_block_name
       or e.v_summary is distinct from e.e_summary
       or e.v_warn is distinct from e.e_warn
       or e.v_driving is distinct from e.e_driving
       or e.v_side is distinct from e.e_side then
      raise exception 'T12: export/placement mismatch for %', e.pin_id;
    end if;
  end loop;
  raise notice 'T11/T12 passed';

  raise notice 'SQL 171 pin placement tests: ALL PASSED (fixtures rolled back)';
end $$;

rollback;

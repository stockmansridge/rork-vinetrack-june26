-- =============================================================================
-- 129: Backfill estimated vines and emitters onto EXISTING irrigation row
--      snapshots saved before SQL 127/128.
--
-- WHY:
--   irrigation_valve_rows records saved under SQL 126 predate the estimate
--   pipeline, so vine_count, emitter_count and every SQL 127 basis column are
--   NULL. The available-row list (live pipeline) shows estimates, but saved
--   configurations such as Stockmans Ridge "Pinot Noir W1" show no totals in
--   Current Configuration. This migration backfills the saved snapshots using
--   the SAME shared pipeline (_irrigation_paddock_rows -> reconciliation +
--   spacing estimates) — no new calculation logic is introduced.
--
-- WHAT IT TOUCHES (and what it never touches):
--   * UPDATES public.irrigation_valve_rows — only ACTIVE links whose basis
--     metadata is missing. Fills vine_count / emitter_count /
--     row_length_metres ONLY where currently NULL; existing non-null values
--     are preserved and marked basis 'exact' (legacy interpretation, SQL 127).
--   * UPDATES public.irrigation_valve_blocks.serviced_vine_count /
--     serviced_emitter_count — only for allocation_method = 'rows', only
--     where currently NULL, and only with complete-row sums (a partial sum is
--     never presented as a block total).
--   * PRESERVES: selected row IDs, row numbers, valves, blocks,
--     allocation_percentage, weighting_basis, row_weight, effective dates.
--   * NEVER TOUCHES: irrigation_sessions, irrigation_session_blocks or any
--     configuration_snapshot (guarded by a checksum assert in §3).
--
-- MISSING GEOMETRY (e.g. Pinot Noir Row 69):
--   Rows the live pipeline cannot measure keep row_length_metres = NULL,
--   vine_count = NULL, emitter_count = NULL and receive basis 'unavailable'.
--   NULL is never replaced with zero. The backfill continues with other rows.
--
-- IDEMPOTENCY:
--   The affected-row filter is "active AND (vine_count_basis IS NULL OR
--   emitter_count_basis IS NULL)". Every processed row leaves with BOTH bases
--   set (a real basis or 'unavailable'), so a second execution selects zero
--   rows: no value changes, no link changes, no duplicate audit entries.
--   §3 asserts this invariant at apply time.
--
-- AUDIT:
--   ONE irrigation_audit entry per affected valve,
--   action = 'irrigation_row_estimates_backfilled', including valve ID, rows
--   updated, rows still unavailable and the resulting complete-only estimated
--   vine/emitter totals. irrigation_audit.user_id is NOT NULL, and auth.uid()
--   is NULL when a migration runs from the SQL editor, so the writer falls
--   back to the valve's updated_by/created_by; if no user can be attributed
--   the audit row is skipped with a NOTICE rather than failing the backfill.
--
-- REQUIRES: SQL 127 (basis columns + reconciliation) and SQL 128 (spacing
-- helper overloads) already applied — asserted in §1 before any change.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Preconditions — abort BEFORE touching data if 127/128 are not applied.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public._irrigation_paddock_rows(uuid, uuid)') is null then
    raise exception 'SQL 129 requires SQL 126/127: public._irrigation_paddock_rows is missing';
  end if;
  if to_regprocedure('public._irrigation_reconcile_counts(integer, jsonb)') is null then
    raise exception 'SQL 129 requires SQL 127: public._irrigation_reconcile_counts is missing';
  end if;
  if to_regprocedure('public._irrigation_spacing_estimate(numeric, double precision)') is null then
    raise exception 'SQL 129 requires SQL 128: apply sql/128_irrigation_spacing_estimate_fix.sql first (spacing-helper overloads missing)';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'irrigation_valve_rows'
      and column_name = 'vine_count_basis'
  ) then
    raise exception 'SQL 129 requires SQL 127: irrigation_valve_rows.vine_count_basis is missing';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Backfill — one transaction, per-valve loop, shared SQL 127/128 pipeline.
-- ---------------------------------------------------------------------------
do $$
declare
  -- Historical-session integrity guard (before/after checksums).
  v_sessions_before text;
  v_sessions_after text;
  v_session_blocks_before text;
  v_session_blocks_after text;

  v_valve record;
  v_link record;

  -- Per-block cache of the live pipeline output.
  v_cache_block uuid := null;
  v_avail jsonb := null;
  v_found jsonb;

  v_len numeric;
  v_vine integer;
  v_vine_basis text;
  v_vine_est boolean;
  v_emit integer;
  v_emit_basis text;
  v_emit_est boolean;

  v_rows_updated integer;
  v_rows_unavailable integer;
  v_total_rows integer;
  v_vine_total integer;
  v_emit_total integer;
  v_blocks_updated integer;

  v_valves_affected integer := 0;
  v_rows_updated_all integer := 0;
  v_rows_unavailable_all integer := 0;

  v_audit_user uuid;
  v_remaining integer;
begin
  -- Snapshot historical-session state BEFORE any change.
  select coalesce(md5(string_agg(s.id::text || '|' || s.updated_at::text || '|'
           || coalesce(md5(s.configuration_snapshot::text), ''), ',' order by s.id)), 'empty')
  into v_sessions_before
  from public.irrigation_sessions s;

  select coalesce(md5(string_agg(sb.id::text, ',' order by sb.id)), 'empty')
  into v_session_blocks_before
  from public.irrigation_session_blocks sb;

  for v_valve in
    select distinct v.id as valve_id, v.vineyard_id, v.name,
           v.created_by, v.updated_by
    from public.irrigation_valve_rows vr
    join public.irrigation_valves v on v.id = vr.valve_id
    where vr.is_active
      and (vr.vine_count_basis is null or vr.emitter_count_basis is null)
    order by v.name, v.id
  loop
    v_valves_affected := v_valves_affected + 1;
    v_rows_updated := 0;

    for v_link in
      select *
      from public.irrigation_valve_rows
      where valve_id = v_valve.valve_id
        and is_active
        and (vine_count_basis is null or emitter_count_basis is null)
      order by block_id, row_number, row_id
    loop
      -- Resolve the block's rows through the SHARED pipeline (cached per block).
      if v_cache_block is distinct from v_link.block_id then
        v_avail := public._irrigation_paddock_rows(v_valve.vineyard_id, v_link.block_id);
        v_cache_block := v_link.block_id;
      end if;

      v_found := null;
      if v_link.row_id is not null then
        select e into v_found
        from jsonb_array_elements(coalesce(v_avail, '[]'::jsonb)) e
        where (e->>'row_id')::uuid = v_link.row_id
        limit 1;
      end if;

      v_len := coalesce(v_link.row_length_metres,
                        nullif(v_found->>'row_length_metres', '')::numeric);

      -- Vines: preserve any existing saved value ('exact', legacy rule);
      -- otherwise take the pipeline estimate; otherwise 'unavailable'.
      if v_link.vine_count_basis is not null then
        v_vine := v_link.vine_count;
        v_vine_basis := v_link.vine_count_basis;
        v_vine_est := v_link.vine_count_is_estimated;
      elsif v_link.vine_count is not null then
        v_vine := v_link.vine_count;
        v_vine_basis := 'exact';
        v_vine_est := false;
      elsif v_found is not null and nullif(v_found->>'vine_count', '') is not null then
        v_vine := (v_found->>'vine_count')::integer;
        v_vine_basis := coalesce(nullif(v_found->>'vine_count_basis', ''), 'row_length_spacing');
        v_vine_est := true;
      else
        v_vine := null;
        v_vine_basis := 'unavailable';
        v_vine_est := null;
      end if;

      -- Emitters: same preservation rules.
      if v_link.emitter_count_basis is not null then
        v_emit := v_link.emitter_count;
        v_emit_basis := v_link.emitter_count_basis;
        v_emit_est := v_link.emitter_count_is_estimated;
      elsif v_link.emitter_count is not null then
        v_emit := v_link.emitter_count;
        v_emit_basis := 'exact';
        v_emit_est := false;
      elsif v_found is not null and nullif(v_found->>'emitter_count', '') is not null then
        v_emit := (v_found->>'emitter_count')::integer;
        v_emit_basis := coalesce(nullif(v_found->>'emitter_count_basis', ''), 'row_length_spacing');
        v_emit_est := true;
      else
        v_emit := null;
        v_emit_basis := 'unavailable';
        v_emit_est := null;
      end if;

      -- weighting_basis, row_weight, row identity and activation are PRESERVED.
      update public.irrigation_valve_rows
      set vine_count = v_vine,
          vine_count_basis = v_vine_basis,
          vine_count_is_estimated = v_vine_est,
          emitter_count = v_emit,
          emitter_count_basis = v_emit_basis,
          emitter_count_is_estimated = v_emit_est,
          row_length_metres = v_len
      where id = v_link.id;

      v_rows_updated := v_rows_updated + 1;
    end loop;

    -- Derived block connections: fill serviced totals ONLY where NULL and
    -- ONLY with complete-row sums (never a partial sum presented as a total).
    update public.irrigation_valve_blocks vb
    set serviced_vine_count = coalesce(vb.serviced_vine_count, agg.vines),
        serviced_emitter_count = coalesce(vb.serviced_emitter_count, agg.emitters)
    from (
      select vr.block_id,
             case when count(*) filter (where vr.vine_count is null) = 0
                  then sum(vr.vine_count)::integer end as vines,
             case when count(*) filter (where vr.emitter_count is null) = 0
                  then sum(vr.emitter_count)::integer end as emitters
      from public.irrigation_valve_rows vr
      where vr.valve_id = v_valve.valve_id and vr.is_active
      group by vr.block_id
    ) agg
    where vb.valve_id = v_valve.valve_id
      and vb.block_id = agg.block_id
      and vb.is_active
      and vb.allocation_method = 'rows'
      and (vb.serviced_vine_count is null or vb.serviced_emitter_count is null)
      and (agg.vines is not null or agg.emitters is not null);
    get diagnostics v_blocks_updated = row_count;

    -- Resulting valve totals (complete-only, matching get_irrigation_setup_status).
    select count(*),
           count(*) filter (where vine_count is null or emitter_count is null),
           case when count(*) > 0 and count(*) filter (where vine_count is null) = 0
                then sum(vine_count)::integer end,
           case when count(*) > 0 and count(*) filter (where emitter_count is null) = 0
                then sum(emitter_count)::integer end
    into v_total_rows, v_rows_unavailable, v_vine_total, v_emit_total
    from public.irrigation_valve_rows
    where valve_id = v_valve.valve_id and is_active;

    v_rows_updated_all := v_rows_updated_all + v_rows_updated;
    v_rows_unavailable_all := v_rows_unavailable_all + v_rows_unavailable;

    -- ONE audit entry per affected valve. auth.uid() is NULL in the SQL
    -- editor, and irrigation_audit.user_id is NOT NULL — fall back to the
    -- valve's own attribution; skip with a NOTICE if none exists.
    v_audit_user := coalesce(auth.uid(), v_valve.updated_by, v_valve.created_by);
    if v_audit_user is null then
      select user_id into v_audit_user
      from public.irrigation_audit
      where vineyard_id = v_valve.vineyard_id
      order by created_at desc
      limit 1;
    end if;

    if v_audit_user is null then
      raise notice 'SQL 129: audit entry SKIPPED for valve "%" (%) — no attributable user found.',
        v_valve.name, v_valve.valve_id;
    else
      insert into public.irrigation_audit
        (vineyard_id, user_id, action, entity_type, entity_id, old_values, new_values)
      values
        (v_valve.vineyard_id, v_audit_user,
         'irrigation_row_estimates_backfilled', 'irrigation_valve', v_valve.valve_id,
         jsonb_build_object('rows_missing_estimates', v_rows_updated),
         jsonb_build_object(
           'valve_id', v_valve.valve_id,
           'rows_updated', v_rows_updated,
           'rows_still_unavailable', v_rows_unavailable,
           'blocks_updated', v_blocks_updated,
           'estimated_vine_total', v_vine_total,
           'estimated_emitter_total', v_emit_total));
    end if;

    raise notice 'SQL 129: valve "%" (%) — % rows backfilled, % still unavailable, % block connections updated, vine total %, emitter total %.',
      v_valve.name, v_valve.valve_id, v_rows_updated, v_rows_unavailable,
      v_blocks_updated, coalesce(v_vine_total::text, 'null'), coalesce(v_emit_total::text, 'null');
  end loop;

  -- Idempotency invariant: every active link now carries BOTH bases, so a
  -- second execution selects zero rows and changes nothing.
  select count(*) into v_remaining
  from public.irrigation_valve_rows
  where is_active
    and (vine_count_basis is null or emitter_count_basis is null);
  assert v_remaining = 0,
    format('SQL 129: %s active valve-row links still lack basis metadata after the backfill', v_remaining);

  -- Historical-session integrity: nothing in irrigation_sessions or
  -- irrigation_session_blocks may have changed.
  select coalesce(md5(string_agg(s.id::text || '|' || s.updated_at::text || '|'
           || coalesce(md5(s.configuration_snapshot::text), ''), ',' order by s.id)), 'empty')
  into v_sessions_after
  from public.irrigation_sessions s;

  select coalesce(md5(string_agg(sb.id::text, ',' order by sb.id)), 'empty')
  into v_session_blocks_after
  from public.irrigation_session_blocks sb;

  assert v_sessions_after = v_sessions_before,
    'SQL 129: irrigation_sessions changed during the backfill — aborting';
  assert v_session_blocks_after = v_session_blocks_before,
    'SQL 129: irrigation_session_blocks changed during the backfill — aborting';

  raise notice 'SQL 129 summary: % valve(s) affected, % row link(s) backfilled, % row link(s) remain unavailable (missing geometry/source data). Historical sessions unchanged.',
    v_valves_affected, v_rows_updated_all, v_rows_unavailable_all;

  if v_valves_affected = 0 then
    raise notice 'SQL 129: nothing to backfill — every active valve-row link already carries estimate metadata (idempotent re-run).';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Apply-time validation — Pinot Noir W1 report (read-only, NOTICE output).
--    Queries the tables directly (RPCs enforce the signed-in feature gate,
--    which is unavailable inside a migration).
-- ---------------------------------------------------------------------------
do $$
declare
  v_valve record;
  v_rows integer;
  v_row_min integer;
  v_row_max integer;
  v_blocks integer;
  v_basis text;
  v_vines integer;
  v_emitters integer;
  v_unavailable integer;
  v_alloc_total numeric;
  v_alloc_blocks integer;
begin
  for v_valve in
    select v.id, v.name, v.vineyard_id
    from public.irrigation_valves v
    where v.is_active and v.name ilike '%pinot%w1%'
    order by v.name
  loop
    select count(*),
           min(row_number), max(row_number),
           count(distinct block_id),
           min(weighting_basis),
           case when count(*) > 0 and count(*) filter (where vine_count is null) = 0
                then sum(vine_count)::integer end,
           case when count(*) > 0 and count(*) filter (where emitter_count is null) = 0
                then sum(emitter_count)::integer end,
           count(*) filter (where vine_count is null or emitter_count is null)
    into v_rows, v_row_min, v_row_max, v_blocks, v_basis,
         v_vines, v_emitters, v_unavailable
    from public.irrigation_valve_rows
    where valve_id = v_valve.id and is_active;

    select round(coalesce(sum(allocation_percentage), 0), 2), count(*)
    into v_alloc_total, v_alloc_blocks
    from public.irrigation_valve_blocks
    where valve_id = v_valve.id and is_active;

    raise notice 'SQL 129 validation — "%" (%): saved rows % (rows %–%), connected blocks % (active connections %), weighting basis %, water allocation total %%%, estimated vines %, estimated emitters %, rows without estimates %.',
      v_valve.name, v_valve.id,
      coalesce(v_rows, 0), coalesce(v_row_min::text, '—'), coalesce(v_row_max::text, '—'),
      coalesce(v_blocks, 0), coalesce(v_alloc_blocks, 0),
      coalesce(v_basis, 'null'), v_alloc_total,
      coalesce(v_vines::text, 'null'), coalesce(v_emitters::text, 'null'),
      coalesce(v_unavailable, 0);
  end loop;

  if not found then
    raise notice 'SQL 129 validation: no active valve matching "Pinot Noir W1" found in this database.';
  end if;
end;
$$;

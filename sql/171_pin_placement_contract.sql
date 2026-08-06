-- 171: Canonical pin placement contract.
--
-- The portal treated a pin as "assigned" only when BOTH paddock_id AND a row
-- number existed on the base pins row. That is wrong: block-scope pins, row-
-- scope pins (whose selection lives in pin_row_segments), and older pins
-- assigned to a block but never snapped to a row were all reported as
-- unassigned. This migration adds ONE server-authoritative placement
-- resolution that iOS, Android, the portal and exports all follow.
--
-- Canonical assignment rules:
--   * point : assigned when it has valid coordinates. Block and snapped row
--             are OPTIONAL associations — a null paddock_id never makes a
--             point pin unassigned.
--   * row   : assigned when paddock_id exists AND at least one live row
--             segment exists in pin_row_segments. No pin_row_number /
--             driving_row_number / row_number is required on the base row.
--   * block : assigned when paddock_id exists. No row information required.
--   * legacy (no location_scope): derived at read time —
--             segments -> row; paddock + row/snap values -> snapped point;
--             paddock only -> block (basis 'legacy_block');
--             coordinates only -> point; nothing usable -> unassigned.
--
-- Historical pins are NEVER rewritten; placement is derived at read time.
-- sql/170 write behaviour is unchanged and remains valid: the read contract
-- understands the structured location model instead of copying row values
-- onto the base pins row.
--
-- location_assignment_basis values:
--   point_coordinates | snapped_point | row_segments | block | legacy_block
--   | unassigned
-- location_warning_code values:
--   null                          -> valid point / row / block assignment
--   'location_metadata_incomplete'-> a STORED scope's structured data is
--                                    missing but a safe fallback assignment
--                                    exists (never the amber warning)
--   'unassigned_location'         -> genuinely no usable location
--
-- pin_row_segments has no soft-delete column: segments are hard-deleted
-- atomically with scope changes (sql/169/170), and a soft-deleted PARENT pin
-- carries pins.deleted_at, which consumers filter. Should a deleted_at column
-- ever be added to pin_row_segments, the aggregation below must exclude it.

-- ---------------------------------------------------------------------------
-- 1. Canonical row summary (byte-identical to the mobile contract)
-- ---------------------------------------------------------------------------

-- Formats a canonical [{"row": int, "segment": 1..4}] selection exactly like
-- ManualIssueContract.rowSelectionSummary on iOS/Android:
--   whole rows collapse into ranges  -> "Rows 2–4, 6"
--   a single whole row               -> "Row 8"
--   partial rows list their sections -> "Row 5 (sections 1–2)"
--   whole rows first, joined " · "   -> "Rows 2–3 · Row 5 (sections 1, 3)"
-- Returns null for an empty/absent selection.
create or replace function public.pin_row_selection_summary(p_segments jsonb)
returns text
language plpgsql
immutable
set search_path = public
as $function$
declare
  v_whole integer[];
  v_partial integer[];
  v_row integer;
  v_quarters integer[];
  v_ranges text[] := '{}';
  v_parts text[] := '{}';
  v_start integer;
  v_prev integer;
  v_sections text;
  v_label text;
begin
  if p_segments is null or jsonb_typeof(p_segments) <> 'array'
     or jsonb_array_length(p_segments) = 0 then
    return null;
  end if;

  select coalesce(array_agg(row_n order by row_n) filter (where seg_count = 4), '{}'),
         coalesce(array_agg(row_n order by row_n) filter (where seg_count < 4), '{}')
    into v_whole, v_partial
  from (
    select row_n, count(*)::integer as seg_count
    from (
      select distinct (e->>'row')::integer as row_n,
                      (e->>'segment')::integer as seg_n
      from jsonb_array_elements(p_segments) e
    ) d
    group by row_n
  ) g;

  if array_length(v_whole, 1) is not null then
    v_start := v_whole[1];
    v_prev := v_whole[1];
    for i in 2 .. coalesce(array_length(v_whole, 1), 1) loop
      v_row := v_whole[i];
      if v_row = v_prev + 1 then
        v_prev := v_row;
      else
        v_ranges := v_ranges || (case when v_start = v_prev then v_start::text
                                      else v_start::text || '–' || v_prev::text end);
        v_start := v_row;
        v_prev := v_row;
      end if;
    end loop;
    v_ranges := v_ranges || (case when v_start = v_prev then v_start::text
                                  else v_start::text || '–' || v_prev::text end);
    v_label := case when array_length(v_whole, 1) = 1 then 'Row' else 'Rows' end;
    v_parts := v_parts || (v_label || ' ' || array_to_string(v_ranges, ', '));
  end if;

  if array_length(v_partial, 1) is not null then
    foreach v_row in array v_partial loop
      select coalesce(array_agg(seg_n order by seg_n), '{}')
        into v_quarters
      from (
        select distinct (e->>'segment')::integer as seg_n
        from jsonb_array_elements(p_segments) e
        where (e->>'row')::integer = v_row
      ) q;
      if array_length(v_quarters, 1) > 1
         and v_quarters[array_length(v_quarters, 1)] - v_quarters[1]
             = array_length(v_quarters, 1) - 1 then
        v_sections := v_quarters[1]::text || '–' || v_quarters[array_length(v_quarters, 1)]::text;
      else
        v_sections := array_to_string(v_quarters, ', ');
      end if;
      v_label := case when array_length(v_quarters, 1) = 1 then 'section' else 'sections' end;
      v_parts := v_parts || ('Row ' || v_row::text || ' (' || v_label || ' ' || v_sections || ')');
    end loop;
  end if;

  if array_length(v_parts, 1) is null then
    return null;
  end if;
  return array_to_string(v_parts, ' · ');
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Set-based placement view (lists / maps — no per-pin round trips)
-- ---------------------------------------------------------------------------

drop view if exists public.pins_export;
drop view if exists public.pin_placements;
create view public.pin_placements
with (security_invoker = true)
as
select
  p.id as pin_id,
  p.vineyard_id,
  p.mode,
  p.location_scope as stored_location_scope,
  eff.effective_scope as location_scope,
  b.basis as location_assignment_basis,
  (b.basis <> 'unassigned') as is_location_assigned,
  p.paddock_id,
  pk.name as paddock_name,
  public.pin_row_selection_summary(seg.segments) as row_summary,
  (seg.segment_count > 0) as has_row_segments,
  seg.segments,
  p.latitude,
  p.longitude,
  coalesce(p.snapped_to_row, false) as snapped_to_row,
  p.driving_row_number,
  p.pin_row_number,
  p.pin_side,
  p.along_row_distance_m,
  case
    when b.basis = 'unassigned' then 'unassigned_location'
    when eff.scope_stored and eff.effective_scope = 'row' and b.basis <> 'row_segments'
      then 'location_metadata_incomplete'
    when eff.scope_stored and eff.effective_scope = 'block' and b.basis <> 'block'
      then 'location_metadata_incomplete'
    else null
  end as location_warning_code,
  p.deleted_at
from public.pins p
left join public.paddocks pk on pk.id = p.paddock_id
cross join lateral (
  select
    coalesce(jsonb_agg(jsonb_build_object('row', s.row_number, 'segment', s.segment_number)
                       order by s.row_number, s.segment_number), '[]'::jsonb) as segments,
    count(*)::integer as segment_count
  from public.pin_row_segments s
  where s.pin_id = p.id
) seg
cross join lateral (
  select
    (p.latitude is not null and p.longitude is not null) as has_coords,
    (p.paddock_id is not null) as has_block,
    (seg.segment_count > 0) as has_segments,
    (p.pin_row_number is not null or p.driving_row_number is not null
       or p.row_number is not null) as has_row_values,
    coalesce(p.snapped_to_row, false) as is_snapped
) f
cross join lateral (
  select
    (p.location_scope in ('point','row','block')) as scope_stored,
    case
      when p.location_scope in ('point','row','block') then p.location_scope
      when f.has_segments then 'row'
      when f.has_block and f.has_row_values then 'point'
      when f.has_block then 'block'
      when f.has_coords then 'point'
      else null
    end as effective_scope
) eff
cross join lateral (
  select case
    -- row scope: block + live segments is the canonical assignment; a stored
    -- row scope missing its structured data falls back to the best safe
    -- assignment instead of being called unassigned.
    when eff.effective_scope = 'row' and f.has_block and f.has_segments then 'row_segments'
    when eff.effective_scope = 'row' and f.has_coords and (f.is_snapped or f.has_row_values) then 'snapped_point'
    when eff.effective_scope = 'row' and f.has_coords then 'point_coordinates'
    when eff.effective_scope = 'row' and f.has_block then 'block'
    -- block scope: paddock_id alone is a full assignment; 'legacy_block'
    -- marks a derived (pre-location_scope) block assignment.
    when eff.effective_scope = 'block' and f.has_block and eff.scope_stored then 'block'
    when eff.effective_scope = 'block' and f.has_block then 'legacy_block'
    when eff.effective_scope = 'block' and f.has_coords then 'point_coordinates'
    -- point scope: valid coordinates are a full assignment; snapping and an
    -- inferred block are optional detail, never requirements.
    when eff.effective_scope = 'point' and f.has_coords
         and (f.is_snapped or (f.has_block and f.has_row_values)) then 'snapped_point'
    when eff.effective_scope = 'point' and f.has_coords then 'point_coordinates'
    else 'unassigned'
  end as basis
) b;

grant select on public.pin_placements to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Single-pin resolver (detail screens / portal spot checks)
-- ---------------------------------------------------------------------------

create or replace function public.resolve_pin_placement(p_pin_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $function$
declare
  v_vineyard uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: authentication required';
  end if;
  select vineyard_id into v_vineyard from public.pins where id = p_pin_id;
  if not found then
    raise exception 'PIN_NOT_FOUND: %', p_pin_id;
  end if;
  if not public.is_vineyard_member(v_vineyard) then
    raise exception 'PERMISSION_DENIED: not a member of this vineyard';
  end if;
  select to_jsonb(pp) into v_result
  from public.pin_placements pp
  where pp.pin_id = p_pin_id;
  return v_result;
end;
$function$;

revoke all on function public.resolve_pin_placement(uuid) from public;
grant execute on function public.resolve_pin_placement(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Export view — every pin mode, with the canonical placement columns
-- ---------------------------------------------------------------------------

-- CSV / Excel / PDF / portal reporting source. Block-scope pins export their
-- block; row-scope pins export the segment-derived row summary; point pins
-- without a block export their coordinates WITHOUT being marked unassigned.
-- Exact path-row values (e.g. driving_row_number 19.5) are preserved
-- unchanged, and pin_side is exported only when it genuinely exists.
create view public.pins_export
with (security_invoker = true)
as
select
  p.id as pin_id,
  p.vineyard_id,
  v.name as vineyard_name,
  p.mode,
  coalesce(nullif(btrim(p.title), ''), nullif(btrim(p.button_name), '')) as title,
  p.button_color,
  p.category,
  p.status,
  p.is_completed,
  pp.location_scope,
  pp.is_location_assigned,
  pp.location_assignment_basis,
  pp.paddock_id as block_id,
  pp.paddock_name as block_name,
  pp.row_summary,
  pp.has_row_segments,
  pp.latitude,
  pp.longitude,
  pp.snapped_to_row,
  pp.driving_row_number,
  pp.pin_row_number,
  pp.pin_side,
  pp.along_row_distance_m,
  pp.location_warning_code,
  p.growth_stage_code,
  p.notes,
  p.created_by,
  p.created_at,
  p.completed_at,
  p.completed_by,
  p.deleted_at
from public.pins p
join public.pin_placements pp on pp.pin_id = p.id
left join public.vineyards v on v.id = p.vineyard_id;

grant select on public.pins_export to authenticated;

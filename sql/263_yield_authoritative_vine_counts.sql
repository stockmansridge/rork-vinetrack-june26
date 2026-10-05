-- SQL 263: Yield-only physical vine resolution and sync-safe reconciliation.
-- Requires SQL 221. Prepared for MANUAL application; no production execution.
-- Does not write paddocks overrides, pruning density, sessions or historical snapshots.
begin;

-- NULL means no VALID manual row override: preserve SQL 221's density fallback.
-- Geometry and rounding match Paddock.rowLengthMetres / PaddockRowVineCount:
-- 111320 m/latitude degree, cos(polygon centroid latitude), per-row half-away rounding.
create or replace function public._yield_row_effective_vine_count(
  p_rows jsonb, p_polygon jsonb, p_spacing double precision
) returns double precision
language plpgsql immutable set search_path = public
as $fn$
declare
  r jsonb;
  v_manual double precision;
  v_total double precision := 0;
  v_has_manual boolean := false;
  v_centroid double precision;
  v_lat1 double precision;
  v_lat2 double precision;
  v_lon1 double precision;
  v_lon2 double precision;
  v_length double precision;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then return null; end if;
  if jsonb_typeof(p_polygon) = 'array' then
    select avg(public._season_alloc_number(pt, array['latitude'])) into v_centroid
    from jsonb_array_elements(p_polygon) pt;
  end if;
  for r in select jsonb_array_elements(p_rows) loop
    v_manual := case when jsonb_typeof(r -> 'vineCountOverride') = 'number'
      then public._season_alloc_number(r, array['vineCountOverride']) else null end;
    -- Same whole-positive 1..100000 row override contract as both mobile apps.
    if v_manual > 0 and v_manual <= 100000 and v_manual = trunc(v_manual) then
      v_has_manual := true;
      v_total := v_total + v_manual;
      continue;
    end if;
    if p_spacing is null or p_spacing <= 0 or p_spacing >= 'Infinity'::double precision then
      continue;
    end if;
    v_lat1 := public._season_alloc_number(r -> 'startPoint', array['latitude']);
    v_lat2 := public._season_alloc_number(r -> 'endPoint', array['latitude']);
    v_lon1 := public._season_alloc_number(r -> 'startPoint', array['longitude']);
    v_lon2 := public._season_alloc_number(r -> 'endPoint', array['longitude']);
    if v_lat1 is null or v_lat2 is null or v_lon1 is null or v_lon2 is null then continue; end if;
    v_length := sqrt(power((v_lat2 - v_lat1) * 111320.0, 2)
      + power((v_lon2 - v_lon1) * 111320.0 * cos(radians(coalesce(v_centroid, v_lat1))), 2));
    if v_length > 0 then v_total := v_total + floor(v_length / p_spacing + 0.5); end if;
  end loop;
  return case when v_has_manual then v_total else null end;
end;
$fn$;
revoke all on function public._yield_row_effective_vine_count(jsonb,jsonb,double precision) from public, anon, authenticated;

-- Patch only the vine-input branch of the installed SQL 221 helper. Keep its
-- planting-group reconciliation, warnings, formula, signatures and ACL intact.
-- Fail closed on an unexpected definition instead of replacing unrelated work.
do $patch$
declare
  v_def text := pg_get_functiondef('public._pruning_block_estimate(uuid,uuid)'::regprocedure);
  v_select text := 'select p.id, p.name, p.polygon_points, p.vine_count_override, p.variety_allocations';
  v_branch text := '  elsif v_has_settings and coalesce(s.vines_per_ha, 0) > 0 and v_area > 0 then';
begin
  if position('public._yield_row_effective_vine_count(b.rows' in v_def) = 0 then
    if position(v_select in v_def) = 0 or position(v_branch in v_def) = 0 then
      raise exception 'SQL 263: unexpected _pruning_block_estimate definition; review before applying';
    end if;
    v_def := replace(v_def, v_select, v_select || ', p.rows, p.vine_spacing');
    v_def := replace(v_def, v_branch, $new$  elsif public._yield_row_effective_vine_count(b.rows, b.polygon_points, b.vine_spacing) is not null then
    v_vines := public._yield_row_effective_vine_count(b.rows, b.polygon_points, b.vine_spacing);
    v_vine_basis := 'row_effective_vine_count';
$new$ || v_branch);
    execute v_def;
  end if;
end;
$patch$;
revoke all on function public._pruning_block_estimate(uuid,uuid) from public, anon, authenticated;

-- Serialize pruning refreshes and lock the existing estimate BEFORE checking
-- priority, so a concurrent manual/bunch-count promotion cannot be demoted.
do $patch$
declare
  v_def text := pg_get_functiondef('public._refresh_pruning_yield_estimates(uuid,integer)'::regprocedure);
  v_start text := E'begin\n  for r in';
  v_select text := E'         and e.deleted_at is null\n       limit 1;';
  v_insert text := E'        );\n\n        v_inserted := v_inserted + 1;';
begin
  if position('yield-pruning-refresh:' in v_def) = 0 then
    if position(v_start in v_def) = 0 or position(v_select in v_def) = 0 or position(v_insert in v_def) = 0 then
      raise exception 'SQL 263: unexpected pruning refresh definition; review before applying';
    end if;
    v_def := replace(v_def, v_start, E'begin\n  perform pg_advisory_xact_lock(hashtextextended(''yield-pruning-refresh:'' || p_vineyard_id::text, 0));\n  for r in');
    v_def := replace(v_def, v_select, E'         and e.deleted_at is null\n       limit 1 for update;');
    -- A higher-priority writer may insert while no row existed at the SELECT.
    -- Never overwrite that insert, and do not fail an offline paddock replay.
    v_def := replace(v_def, v_insert, E'        ) on conflict (vineyard_id, vintage, paddock_id, planting_group_key) where deleted_at is null do nothing;\n\n        get diagnostics v_n = row_count;\n        v_inserted := v_inserted + v_n;\n        if v_n = 0 then v_skipped := v_skipped + 1; end if;');
    execute v_def;
  end if;
end;
$patch$;
revoke all on function public._refresh_pruning_yield_estimates(uuid,integer) from public, anon, authenticated;

-- Statement transition tables coalesce bulk/offline-sync edits to ONE refresh
-- per affected vineyard, using the vineyard's own local CURRENT vintage.
create or replace function public._yield_refresh_after_vine_change()
returns trigger language plpgsql security definer set search_path = public
as $fn$
declare
  v_id uuid;
  v_ids uuid[];
  v_tz text;
  v_vintage integer;
begin
  if tg_op = 'UPDATE' then
    select array_agg(distinct n.vineyard_id order by n.vineyard_id) into v_ids
    from yield_new_paddocks n join yield_old_paddocks o on o.id = n.id
    where n.deleted_at is null and (
      n.vine_count_override is distinct from o.vine_count_override
      or n.rows is distinct from o.rows
      or n.vine_spacing is distinct from o.vine_spacing
      or n.polygon_points is distinct from o.polygon_points
    );
  else
    select array_agg(distinct n.vineyard_id order by n.vineyard_id) into v_ids
    from yield_new_paddocks n where n.deleted_at is null;
  end if;
  foreach v_id in array coalesce(v_ids, '{}'::uuid[]) loop
    select timezone into v_tz from public.vineyards where id = v_id;
    if not found then continue; end if;
    v_vintage := public.resolve_vineyard_vintage_year(v_id,
      (now() at time zone coalesce(nullif(v_tz,''),'UTC'))::date);
    perform public._refresh_pruning_yield_estimates(v_id, v_vintage);
  end loop;
  return null;
end;
$fn$;
revoke all on function public._yield_refresh_after_vine_change() from public, anon, authenticated;

drop trigger if exists yield_refresh_paddock_vines_updated on public.paddocks;
create trigger yield_refresh_paddock_vines_updated after update on public.paddocks
referencing old table as yield_old_paddocks new table as yield_new_paddocks
for each statement execute function public._yield_refresh_after_vine_change();
drop trigger if exists yield_refresh_paddock_vines_inserted on public.paddocks;
create trigger yield_refresh_paddock_vines_inserted after insert on public.paddocks
referencing new table as yield_new_paddocks
for each statement execute function public._yield_refresh_after_vine_change();

-- Reconcile existing CURRENT pruning estimates once on manual application.
-- The unchanged rank guard skips manual/bunch_count; no prior vintage is touched.
do $reconcile$
declare v record; v_vintage integer;
begin
  for v in select distinct s.vineyard_id, w.timezone
    from public.pruning_yield_settings s join public.vineyards w on w.id = s.vineyard_id
    where s.deleted_at is null order by s.vineyard_id
  loop
    v_vintage := public.resolve_vineyard_vintage_year(v.vineyard_id,
      (now() at time zone coalesce(nullif(v.timezone,''),'UTC'))::date);
    perform public._refresh_pruning_yield_estimates(v.vineyard_id, v_vintage);
  end loop;
end;
$reconcile$;
commit;

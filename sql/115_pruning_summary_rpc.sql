-- 115: Pruning Tracker — authoritative cross-platform summary RPC.
--
-- Problem: Lovable, iOS and Android each aggregated the vineyard pruning
-- summary independently and drifted (5% / 3% / 4% progress, 22,704 vs 22,598
-- total vines, 1,123 vs 1,126 vines/day, 15 vs 14 July projections).
--
-- This migration adds `get_pruning_vineyard_summary`, which implements THE
-- calculation contract (documented in docs/pruning-fertiliser-sync.md) that
-- the iOS `PruningCalculator` and Android `PruningCalculator` now mirror:
--
--   * Block vine total  = vine_count_override, else
--                         trunc((row_length_override ?? Σ row lengths) / vine_spacing).
--     Row lengths use equirectangular distance with the polygon-centroid
--     latitude (row start latitude when no polygon) — identical to both apps.
--   * Row vines         = block vines distributed by row-length weights
--                         (rows without geometry get the average mapped
--                         length, or an equal share when nothing is mapped).
--   * Quarter vines     = that row's EXACT vines / 4 (full precision).
--   * Vines pruned      = round(Σ exact quarter vines) — rounded ONCE at the
--                         vineyard level, never per quarter / row / block.
--   * Overall progress  = completed row equivalents ÷ total row equivalents
--                         (row-equivalent based, NOT vine-weighted);
--                         display % = round(fraction × 100), half up.
--   * Vines/day         = Σ exact vines per day-with-entries ÷ number of
--                         days-with-entries (whole period; days without
--                         entries never count against the rate).
--   * Vines/labour hour = Σ exact vines of entries with labour_hours > 0
--                         ÷ Σ labour hours (person-hours).
--   * Block rate        = mean row equivalents/day over the 3 most recent
--                         days-with-entries (whole period when fewer).
--   * Projection        = walk calendar days from `as_of` (TODAY counts when
--                         it is a working day) through the season's working
--                         days until ceil(remaining ÷ rate) work days pass.
--                         Vineyard projection = latest block projection.
--   * Status            = complete / not started / ahead (>3 days early) /
--                         on track (≤3 days late... within 3) / at risk
--                         (1–3 late) / behind (>3 late).
--   * Blocks included   = ALL non-deleted paddocks of the vineyard
--                         (including blocks with no season row).
--   * Season            = coalesce(p_season_year, year of `as_of` in the
--                         vineyard's IANA timezone, UTC fallback).
--
-- The portal must call this RPC (or replicate it exactly) instead of its own
-- aggregation. Mobile clients keep their mirrored offline calculators.

-- ---------------------------------------------------------------------------
-- Helper: deterministic id for paddock rows stored without an `id`.
-- Byte-identical to Java `UUID.nameUUIDFromBytes` / iOS `PaddockRowIdentity`:
-- MD5 v3 of "vinetrack-paddock-row|{number}|{slat %.6f}|{slon %.6f}|{elat %.6f}|{elon %.6f}"
-- (empty string for missing coordinates).
-- ---------------------------------------------------------------------------
create or replace function public.derive_paddock_row_id(
  p_number integer,
  p_slat double precision,
  p_slon double precision,
  p_elat double precision,
  p_elon double precision
) returns uuid
language plpgsql immutable
as $$
declare
  v_name text;
  v_bytes bytea;
begin
  v_name := 'vinetrack-paddock-row|' || coalesce(p_number, 0)::text
    || '|' || coalesce(to_char(round(p_slat::numeric, 6), 'FM999999999999990.000000'), '')
    || '|' || coalesce(to_char(round(p_slon::numeric, 6), 'FM999999999999990.000000'), '')
    || '|' || coalesce(to_char(round(p_elat::numeric, 6), 'FM999999999999990.000000'), '')
    || '|' || coalesce(to_char(round(p_elon::numeric, 6), 'FM999999999999990.000000'), '');
  v_bytes := decode(md5(v_name), 'hex');
  v_bytes := set_byte(v_bytes, 6, ((get_byte(v_bytes, 6) & 15) | 48));   -- version 3
  v_bytes := set_byte(v_bytes, 8, ((get_byte(v_bytes, 8) & 63) | 128));  -- IETF variant
  return encode(v_bytes, 'hex')::uuid;
end;
$$;

revoke all on function public.derive_paddock_row_id(integer, double precision, double precision, double precision, double precision) from public;
grant execute on function public.derive_paddock_row_id(integer, double precision, double precision, double precision, double precision) to authenticated;

-- ---------------------------------------------------------------------------
-- RPC: get_pruning_vineyard_summary
--
-- SECURITY INVOKER: RLS on paddocks / pruning_* applies to the caller, and an
-- explicit membership check rejects non-members up front. Returns the
-- vineyard summary plus a per-block breakdown (the audit comparison table).
-- ---------------------------------------------------------------------------
create or replace function public.get_pruning_vineyard_summary(
  p_vineyard_id uuid,
  p_season_year integer default null,
  p_today date default null
) returns jsonb
language plpgsql
as $$
declare
  v_tz text;
  v_today date;
  v_year integer;

  -- vineyard aggregates
  v_total_eq double precision := 0;
  v_completed_eq double precision := 0;
  v_vines_total bigint := 0;
  v_vines_pruned_exact double precision := 0;
  v_blocks_complete integer := 0;
  v_blocks_at_risk integer := 0;
  v_projected date := null;
  v_hours double precision := 0;
  v_vines_for_hours double precision := 0;

  -- per-paddock working vars
  p record;
  s record;
  e record;
  v_centroid_lat double precision;
  v_sum_len double precision;
  v_avg_len double precision;
  v_total_weight double precision;
  v_eff_len double precision;
  v_spacing double precision;
  v_block_vines double precision;
  v_season_id uuid;
  v_working integer[];
  v_manual_count integer;
  v_due date;
  v_row_count integer;
  v_b_completed_quarters integer;
  v_b_vines_pruned double precision;
  v_b_completed_eq double precision;
  v_b_total_eq double precision;
  v_rate double precision;
  v_remaining double precision;
  v_b_projected date;
  v_status text;
  v_days_late integer;
  v_days_needed integer;
  v_walk date;
  v_iter integer;

  v_vines_per_day double precision;
  v_fraction double precision;
  v_blocks jsonb := '[]'::jsonb;
begin
  if not public.is_vineyard_member(p_vineyard_id) then
    raise exception 'not allowed';
  end if;

  select timezone into v_tz from public.vineyards where id = p_vineyard_id;
  v_today := coalesce(p_today, (now() at time zone coalesce(nullif(v_tz, ''), 'UTC'))::date);
  v_year := coalesce(p_season_year, extract(year from v_today)::integer);

  -- Per-row working set: real configured rows (with derived ids when the
  -- stored json has none) OR manual fallback rows 1…manual_row_count.
  drop table if exists _prs_rows;
  create temp table _prs_rows (
    paddock_id uuid,
    ord integer,
    row_id uuid,
    row_number integer,
    vines double precision
  );

  -- Day → exact vines across the vineyard (for vines/day).
  drop table if exists _prs_days;
  create temp table _prs_days (day date, vines double precision);

  for p in
    select pd.id, pd.name, pd.vine_spacing, pd.vine_count_override,
           pd.row_length_override, pd.polygon_points, pd.rows
    from public.paddocks pd
    where pd.vineyard_id = p_vineyard_id
      and pd.deleted_at is null
    order by pd.name
  loop
    -- Season for this block + year (may be absent).
    select ps.id, ps.working_days, ps.manual_row_count, ps.due_date
    into v_season_id, v_working, v_manual_count, v_due
    from public.pruning_seasons ps
    where ps.vineyard_id = p_vineyard_id
      and ps.paddock_id = p.id
      and ps.season_year = v_year
      and ps.deleted_at is null
    limit 1;
    if not found then
      v_season_id := null;
      v_working := array[1,2,3,4,5];
      v_manual_count := null;
      v_due := null;
    end if;

    -- Row geometry → lengths → weights → per-row vines.
    select avg((pt->>'latitude')::double precision)
    into v_centroid_lat
    from jsonb_array_elements(coalesce(p.polygon_points, '[]'::jsonb)) pt
    where jsonb_typeof(pt->'latitude') = 'number';

    delete from _prs_rows where paddock_id = p.id; -- safety on rerun

    with raw as (
      select
        row_number() over () as ord,
        case
          when (elem->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            then (elem->>'id')::uuid
          else public.derive_paddock_row_id(
            coalesce(nullif(elem->>'number', '')::integer, 0),
            (elem->'startPoint'->>'latitude')::double precision,
            (elem->'startPoint'->>'longitude')::double precision,
            (elem->'endPoint'->>'latitude')::double precision,
            (elem->'endPoint'->>'longitude')::double precision
          )
        end as row_id,
        coalesce(nullif(elem->>'number', '')::integer, 0) as row_number,
        (elem->'startPoint'->>'latitude')::double precision as slat,
        (elem->'startPoint'->>'longitude')::double precision as slon,
        (elem->'endPoint'->>'latitude')::double precision as elat,
        (elem->'endPoint'->>'longitude')::double precision as elon
      from jsonb_array_elements(coalesce(p.rows, '[]'::jsonb)) elem
    ),
    measured as (
      select ord, row_id, row_number,
        case
          when slat is null or slon is null or elat is null or elon is null then 0
          else sqrt(
            pow((elat - slat) * 111320.0, 2)
            + pow((elon - slon) * 111320.0 * cos(radians(coalesce(v_centroid_lat, slat))), 2)
          )
        end as len
      from raw
    )
    insert into _prs_rows (paddock_id, ord, row_id, row_number, vines)
    select p.id, m.ord, m.row_id, m.row_number, m.len
    from measured m;

    select coalesce(sum(vines), 0) into v_sum_len from _prs_rows where paddock_id = p.id;
    select avg(vines) into v_avg_len from _prs_rows where paddock_id = p.id and vines > 0;

    v_spacing := coalesce(p.vine_spacing, 1.0);
    v_eff_len := coalesce(p.row_length_override, v_sum_len);
    v_block_vines := coalesce(
      p.vine_count_override::double precision,
      case when v_spacing > 0 then trunc(v_eff_len / v_spacing) else 0 end
    );

    select count(*) into v_row_count from _prs_rows where paddock_id = p.id;

    if v_row_count > 0 then
      -- Replace the temporary "vines = length" values with weighted vines.
      update _prs_rows r
      set vines = case
        when w.total_weight > 0 then v_block_vines * w.weight / w.total_weight
        else 0
      end
      from (
        select ord,
          case when vines > 0 then vines else coalesce(nullif(v_avg_len, 0), 1) end as weight,
          sum(case when vines > 0 then vines else coalesce(nullif(v_avg_len, 0), 1) end) over () as total_weight
        from _prs_rows where paddock_id = p.id
      ) w
      where r.paddock_id = p.id and r.ord = w.ord;
    elsif coalesce(v_manual_count, 0) > 0 then
      -- Manual fallback rows: 1…count, equal vine share, no stable ids.
      v_row_count := v_manual_count;
      insert into _prs_rows (paddock_id, ord, row_id, row_number, vines)
      select p.id, gs, null, gs, v_block_vines / v_manual_count
      from generate_series(1, v_manual_count) gs;
    else
      v_row_count := 0;
    end if;

    -- Completed quarters, matched exactly like the apps: a segment with a
    -- row id only matches that row; a segment without one matches the FIRST
    -- row (stored order) with that number; unmatched quarters are excluded.
    v_b_completed_quarters := 0;
    v_b_vines_pruned := 0;
    if v_season_id is not null and v_row_count > 0 then
      select count(rv.vines), coalesce(sum(rv.vines), 0) / 4.0
      into v_b_completed_quarters, v_b_vines_pruned
      from public.pruning_row_segments seg
      cross join lateral (
        select r.vines
        from _prs_rows r
        where r.paddock_id = p.id
          and (
            (seg.paddock_row_id is not null and r.row_id = seg.paddock_row_id)
            or (seg.paddock_row_id is null and r.row_number = seg.row_number)
          )
        order by r.ord
        limit 1
      ) rv
      where seg.pruning_season_id = v_season_id
        and seg.completed = true;
    end if;

    v_b_completed_eq := v_b_completed_quarters / 4.0;
    v_b_total_eq := v_row_count;

    -- Rolling rate: mean row equivalents/day over the 3 most recent
    -- days-with-entries (whole period when fewer days exist).
    v_rate := null;
    if v_season_id is not null then
      select avg(day_eq) into v_rate
      from (
        select en.entry_date, sum(en.row_equivalents_completed)::double precision as day_eq
        from public.pruning_entries en
        where en.pruning_season_id = v_season_id and en.deleted_at is null
        group by en.entry_date
        order by en.entry_date desc
        limit 3
      ) t;

      -- Per-entry EXACT vines feed the vineyard day map + labour totals.
      for e in
        select en.id, en.entry_date, en.labour_hours,
          coalesce((
            select sum(rv.vines) / 4.0
            from public.pruning_row_segments seg
            cross join lateral (
              select r.vines
              from _prs_rows r
              where r.paddock_id = p.id
                and (
                  (seg.paddock_row_id is not null and r.row_id = seg.paddock_row_id)
                  or (seg.paddock_row_id is null and r.row_number = seg.row_number)
                )
              order by r.ord
              limit 1
            ) rv
            where seg.pruning_entry_id = en.id and seg.completed = true
          ), 0) as exact_vines
        from public.pruning_entries en
        where en.pruning_season_id = v_season_id and en.deleted_at is null
      loop
        insert into _prs_days (day, vines) values (e.entry_date, e.exact_vines);
        if e.labour_hours is not null and e.labour_hours > 0 then
          v_hours := v_hours + e.labour_hours;
          v_vines_for_hours := v_vines_for_hours + e.exact_vines;
        end if;
      end loop;
    end if;

    -- Projection: walk working days from as_of (today counts when working).
    v_remaining := greatest(v_b_total_eq - v_b_completed_eq, 0);
    v_b_projected := null;
    if v_rate is not null and v_rate > 0 and v_remaining > 0 then
      v_days_needed := ceil(v_remaining / v_rate)::integer;
      v_walk := v_today;
      v_iter := 0;
      while v_iter < 3660 loop
        if (extract(isodow from v_walk)::integer) = any (coalesce(nullif(v_working, '{}'), array[1,2,3,4,5])) then
          v_days_needed := v_days_needed - 1;
          if v_days_needed <= 0 then
            v_b_projected := v_walk;
            exit;
          end if;
        end if;
        v_walk := v_walk + 1;
        v_iter := v_iter + 1;
      end loop;
    end if;

    -- Status (same thresholds as both apps).
    if v_b_total_eq > 0 and v_b_completed_eq >= v_b_total_eq - 0.0001 then
      v_status := 'complete';
    elsif v_b_completed_eq <= 0 then
      v_status := 'notStarted';
    elsif v_b_projected is null or v_due is null then
      v_status := 'onTrack';
    else
      v_days_late := v_b_projected - v_due;
      v_status := case
        when v_days_late < -3 then 'ahead'
        when v_days_late <= 0 then 'onTrack'
        when v_days_late <= 3 then 'atRisk'
        else 'behind'
      end;
    end if;

    -- Vineyard aggregates.
    v_completed_eq := v_completed_eq + v_b_completed_eq;
    v_total_eq := v_total_eq + v_b_total_eq;
    v_vines_pruned_exact := v_vines_pruned_exact + v_b_vines_pruned;
    v_vines_total := v_vines_total + v_block_vines::bigint;
    if v_status = 'complete' then v_blocks_complete := v_blocks_complete + 1; end if;
    if v_status in ('behind', 'atRisk') then v_blocks_at_risk := v_blocks_at_risk + 1; end if;
    if v_b_projected is not null and (v_projected is null or v_b_projected > v_projected) then
      v_projected := v_b_projected;
    end if;

    v_blocks := v_blocks || jsonb_build_object(
      'paddock_id', p.id,
      'name', p.name,
      'season_id', v_season_id,
      'row_count', v_row_count,
      'total_row_equivalents', v_b_total_eq,
      'completed_row_equivalents', v_b_completed_eq,
      'total_vines', v_block_vines::bigint,
      'vines_pruned_exact', v_b_vines_pruned,
      'vines_pruned', round(v_b_vines_pruned)::bigint,
      'rate_row_eq_per_day', v_rate,
      'projected_completion_date', v_b_projected,
      'due_date', v_due,
      'status', v_status
    );
  end loop;

  -- Vineyard vines/day: mean of per-day exact totals over days-with-entries.
  select sum(day_total) / count(*)
  into v_vines_per_day
  from (
    select day, sum(vines) as day_total
    from _prs_days
    group by day
  ) d;

  v_fraction := case when v_total_eq > 0 then least(v_completed_eq / v_total_eq, 1.0) else 0 end;

  return jsonb_build_object(
    'vineyard_id', p_vineyard_id,
    'season_year', v_year,
    'as_of_date', v_today,
    'total_row_equivalents', v_total_eq,
    'completed_row_equivalents', v_completed_eq,
    'completion_fraction', v_fraction,
    'display_percent', round(v_fraction * 100)::integer,
    'total_vines', v_vines_total,
    'vines_pruned_exact', v_vines_pruned_exact,
    'vines_pruned', round(v_vines_pruned_exact)::bigint,
    'vines_remaining', greatest(v_vines_total - round(v_vines_pruned_exact)::bigint, 0),
    'vines_per_day_exact', v_vines_per_day,
    'vines_per_day', case when v_vines_per_day is null then null else round(v_vines_per_day)::bigint end,
    'vines_per_labour_hour_exact', case when v_hours > 0 then v_vines_for_hours / v_hours else null end,
    'vines_per_labour_hour', case when v_hours > 0 then round(v_vines_for_hours / v_hours)::bigint else null end,
    'labour_hours', v_hours,
    'projected_completion_date', v_projected,
    'blocks_complete', v_blocks_complete,
    'blocks_at_risk', v_blocks_at_risk,
    'blocks', v_blocks
  );
end;
$$;

revoke all on function public.get_pruning_vineyard_summary(uuid, integer, date) from public;
grant execute on function public.get_pruning_vineyard_summary(uuid, integer, date) to authenticated;

-- =============================================================================
-- 149_irrigation_rainfall_coverage_fix.sql
-- Phase 2B fix — rainfall coverage must exclude future dates
-- =============================================================================
-- PURPOSE
--   SQL 147 compared rainfall coverage against the FULL report period,
--   including vineyard-local dates that have not occurred yet. For a current
--   vintage (e.g. 2026-07-01 .. 2027-06-30 on 2026-07-29) the reports warned
--   "Rainfall data is missing for 336 of 365 day(s)" even though every one of
--   the 29 elapsed days had a valid rainfall record. Future dates must never
--   be classified as missing rainfall.
--
-- EXISTING BEHAVIOUR BEING CORRECTED (all introduced by SQL 147)
--   * _irrigation_rainfall_warnings: days_total = p_to - p_from + 1 counted
--     future days as expected days.
--   * get_irrigation_vintage_overview: rainfall_data_complete and the
--     data-quality input compared observed days against the full vintage.
--   * _irrigation_period_rows (daily/weekly/monthly + rainfall summary rows):
--     per-row rainfall_data_complete counted future days.
--   * get_irrigation_rainfall_summary (vintage grouping) and
--     get_irrigation_vintage_trends: same full-period comparison.
--
-- FIX DESIGN — one shared coverage helper, no duplicated date logic:
--   * _irrigation_local_today(vineyard)        vineyard-LOCAL today (never UTC)
--   * _irrigation_rainfall_best(...)           now capped at local today, so a
--     forecast/future rainfall row can never count as an observed day or leak
--     into rainfall sums anywhere (overview, block, variety, valve, periods).
--   * _irrigation_rainfall_coverage(...)       report period vs coverage period:
--       rainfall_coverage_start = period_start          (null if fully future)
--       rainfall_coverage_end   = least(period_end, local_today)
--       expected_days           = elapsed local days only (0 if fully future)
--       observed_days           = days with ANY valid rainfall record —
--                                 a recorded 0.0 mm day IS a complete day
--                                 (coverage is existence-based, never mm > 0)
--       missing_days            = expected - observed
--       future_days             = days after local today
--       data_complete           = missing_days = 0; NULL when nothing is
--                                 expected yet ("not yet applicable")
--   * _irrigation_rainfall_warnings rebuilt on the coverage helper: warnings
--     fire only for genuinely missing ELAPSED days.
--   * Data-quality scoring receives data_complete (null → not penalised), so
--     an in-progress vintage with full elapsed coverage can score 'complete'.
--
-- OBJECTS ADDED
--   public._irrigation_local_today(uuid)
--   public._irrigation_rainfall_coverage(uuid, date, date)
-- OBJECTS REPLACED (signatures unchanged; response fields are ADDITIVE)
--   public._irrigation_rainfall_best(uuid, date, date)
--   public._irrigation_rainfall_warnings(uuid, date, date)
--   public.get_irrigation_vintage_overview(...)
--   public._irrigation_period_rows(...)
--   public.get_irrigation_rainfall_summary(...)
--   public.get_irrigation_vintage_trends(...)
--   (daily/weekly/monthly reports and the block/variety/valve/water-source
--    warnings are fixed transitively through the shared helpers)
--
-- BACKWARD COMPATIBILITY
--   * No parameter changes; released clients keep working.
--   * New response fields: rainfall_expected_days, rainfall_observed_days,
--     rainfall_missing_days, rainfall_future_days, rainfall_coverage_start,
--     rainfall_coverage_end — additive only.
--   * rainfall_data_complete may now be JSON null for not-yet-elapsed periods.
--     iOS decodes it as Bool? and Android as Boolean? (both react only to
--     == false), so null is safe on released builds.
--   * No tables are created/changed; historical sessions and snapshots are
--     untouched. No data is written.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Vineyard-local today (uses the vineyard timezone, never the UTC date)
-- ---------------------------------------------------------------------------

create or replace function public._irrigation_local_today(p_vineyard_id uuid)
returns date
language sql
stable
set search_path = public
as $$
  select (now() at time zone public._irrigation_report_timezone(p_vineyard_id))::date;
$$;

-- ---------------------------------------------------------------------------
-- 2. Best rainfall per local vineyard date — now capped at local today so a
--    future/forecast row can never count as an observed day or inflate sums.
--    (manual > davis_weatherlink > open_meteo, unchanged from SQL 147.)
-- ---------------------------------------------------------------------------

create or replace function public._irrigation_rainfall_best(
  p_vineyard_id uuid,
  p_from date,
  p_to date
)
returns table (day date, rainfall_mm numeric)
language sql
stable
set search_path = public
as $$
  select r.date, r.rainfall_mm
  from (
    select rd.date, rd.rainfall_mm,
           row_number() over (
             partition by rd.date
             order by case rd.source
                        when 'manual' then 1
                        when 'davis_weatherlink' then 2
                        when 'open_meteo' then 3
                        else 9
                      end,
                      rd.updated_at desc) as rn
    from public.rainfall_daily rd
    where rd.vineyard_id = p_vineyard_id
      and rd.deleted_at is null
      and rd.date between p_from
                      and least(p_to, public._irrigation_local_today(p_vineyard_id))
  ) r
  where r.rn = 1;
$$;

-- ---------------------------------------------------------------------------
-- 3. Shared rainfall coverage helper — the single source of expected /
--    observed / missing / future day maths for every Phase 2B report.
-- ---------------------------------------------------------------------------

create or replace function public._irrigation_rainfall_coverage(
  p_vineyard_id uuid,
  p_from date,
  p_to date
)
returns table (
  coverage_start date,
  coverage_end date,
  expected_days integer,
  observed_days integer,
  missing_days integer,
  future_days integer,
  data_complete boolean
)
language sql
stable
set search_path = public
as $$
  with t as (
    select public._irrigation_local_today(p_vineyard_id) as today
  ),
  span as (
    select t.today,
           greatest(least(p_to, t.today) - p_from + 1, 0) as expected,
           greatest(p_to - p_from + 1, 0) as total_days
    from t
  ),
  obs as (
    -- _irrigation_rainfall_best is already capped at local today; a recorded
    -- 0.0 mm day counts as observed (existence-based, never rainfall_mm > 0).
    select count(*)::integer as observed
    from public._irrigation_rainfall_best(p_vineyard_id, p_from, p_to)
  )
  select
    case when s.expected > 0 then p_from else null end,
    case when s.expected > 0 then least(p_to, s.today) else null end,
    s.expected,
    least(o.observed, s.expected),
    greatest(s.expected - o.observed, 0),
    greatest(s.total_days - s.expected, 0),
    case when s.expected = 0 then null
         else (o.observed >= s.expected) end
  from span s cross join obs o;
$$;

-- ---------------------------------------------------------------------------
-- 4. Rainfall warnings — only genuinely missing ELAPSED local dates warn.
--    Future-only periods (expected 0) return no warning at all.
-- ---------------------------------------------------------------------------

create or replace function public._irrigation_rainfall_warnings(
  p_vineyard_id uuid,
  p_from date,
  p_to date
)
returns jsonb
language sql
stable
set search_path = public
as $$
  select case
    when coalesce(c.expected_days, 0) = 0 then '[]'::jsonb
    when c.observed_days = 0 then jsonb_build_array(jsonb_build_object(
      'code', 'missing_rainfall', 'severity', 'warning',
      'message', format('No rainfall data is recorded for the %s elapsed day(s) in this period.',
                        c.expected_days),
      'affected_count', c.expected_days))
    when c.missing_days > 0 then jsonb_build_array(jsonb_build_object(
      'code', 'partial_rainfall_coverage', 'severity', 'warning',
      'message', format('Rainfall data is missing for %s of %s elapsed day(s) in this period.',
                        c.missing_days, c.expected_days),
      'affected_count', c.missing_days))
    else '[]'::jsonb
  end
  from public._irrigation_rainfall_coverage(p_vineyard_id, p_from, p_to) c;
$$;

-- ---------------------------------------------------------------------------
-- 5. Vintage overview — coverage-based completeness + additive count fields.
--    Identical to SQL 147 except the rainfall coverage block and payload.
-- ---------------------------------------------------------------------------

create or replace function public.get_irrigation_vintage_overview(
  p_vineyard_id uuid,
  p_vintage_year integer default null,
  p_date_from date default null,
  p_date_to date default null,
  p_system_id uuid default null,
  p_water_source text default null,
  p_valve_id uuid default null,
  p_block_id uuid default null,
  p_variety_id uuid default null,
  p_source_type text default null,
  p_source_group text default null,
  p_calculation_method text default null,
  p_measurement_group text default null,
  p_include_estimated boolean default true,
  p_include_imported boolean default true,
  p_include_reversed boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vintage integer;
  v_start date;
  v_end date;
  v_tot record;
  v_cov record;
  v_area record;
  v_top_day record;
  v_top_month record;
  v_prev record;
  v_prev_area record;
  v_stats record;
  v_rcov record;
  v_warnings jsonb;
  v_filters jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  select vp.period_start, vp.period_end into v_start, v_end
  from public._irrigation_vintage_period(p_vineyard_id, v_vintage) vp;

  -- Volume / runtime / classification totals
  select
    count(*)::integer as sessions,
    coalesce(sum(s.total_litres), 0) as total,
    count(*) filter (where s.effective_litres is null) as eff_missing,
    sum(s.effective_litres) as eff_sum,
    coalesce(sum(s.total_litres) filter (where s.measurement_group = 'directly_reported'), 0) as reported,
    coalesce(sum(s.total_litres) filter (where s.measurement_group = 'directly_measured'), 0) as measured,
    coalesce(sum(s.total_litres) filter (where s.measurement_group = 'calculated'), 0) as calculated,
    coalesce(sum(s.total_litres) filter (where s.measurement_group = 'estimated'), 0) as estimated,
    coalesce(sum(s.total_litres) filter (where s.source_group = 'manual'), 0) as manual,
    coalesce(sum(s.total_litres) filter (where s.source_group = 'controller_import'), 0) as imported,
    coalesce(sum(s.duration_minutes), 0)::integer as runtime,
    round(avg(s.duration_minutes), 1) as avg_minutes,
    max(s.duration_minutes) as longest,
    min(s.duration_minutes) as shortest,
    round(avg(s.total_litres), 1) as avg_litres,
    min(s.session_date) as first_date,
    max(s.session_date) as last_date
  into v_tot
  from public._irrigation_report_sessions(
    p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed) s;

  -- Coverage
  select count(distinct s.system_id)::integer as systems,
         count(distinct s.water_source) filter (where s.water_source is not null)::integer as sources,
         count(distinct s.valve_id)::integer as valves
  into v_cov
  from public._irrigation_report_sessions(
    p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed) s;

  -- Weighted normalisation from SAVED block rows (§9/§10):
  --   depth = litres allocated to area-covered blocks ÷ latest covered area
  --   per-vine = litres on vine-covered blocks ÷ latest covered vines
  -- calculation_basis: latest_saved_serviced_values_weighted (documented for
  -- varying coverage: vine/area exposure weighting, never averaged averages).
  with b as (
    select * from public._irrigation_report_blocks(
      p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed)
  ),
  latest as (
    select distinct on (block_id) block_id, serviced_area_m2, serviced_vine_count
    from b order by block_id, session_date desc
  )
  select
    count(distinct b.block_id)::integer as blocks,
    count(distinct b.variety_name) filter (where b.variety_name is not null)::integer as varieties,
    (select sum(l.serviced_area_m2) from latest l where l.serviced_area_m2 > 0) as area_m2,
    (select sum(l.serviced_vine_count) from latest l where l.serviced_vine_count > 0) as vines,
    sum(b.allocated_litres) filter (where b.serviced_area_m2 > 0) as area_volume,
    sum(b.allocated_litres) filter (where b.serviced_vine_count > 0) as vine_volume,
    sum(b.effective_litres) filter (where b.serviced_area_m2 > 0) as eff_area_volume,
    count(*) filter (where b.serviced_area_m2 > 0 and b.effective_litres is null) as eff_area_missing
  into v_area
  from b;

  -- Highest-use timing
  select s.session_date, sum(s.total_litres) as litres
  into v_top_day
  from public._irrigation_report_sessions(
    p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed) s
  group by s.session_date
  order by sum(s.total_litres) desc, s.session_date
  limit 1;

  select to_char(date_trunc('month', s.session_date), 'YYYY-MM') as month,
         sum(s.total_litres) as litres
  into v_top_month
  from public._irrigation_report_sessions(
    p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed) s
  group by 1
  order by sum(s.total_litres) desc, 1
  limit 1;

  -- Previous vintage (same non-date filters; frozen vintage_year = v-1)
  select count(*)::integer as sessions,
         coalesce(sum(s.total_litres), 0) as total,
         coalesce(sum(s.duration_minutes), 0)::integer as runtime
  into v_prev
  from public._irrigation_report_sessions(
    p_vineyard_id, v_vintage - 1, null, null, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed) s;

  with b as (
    select * from public._irrigation_report_blocks(
      p_vineyard_id, v_vintage - 1, null, null, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed)
  ),
  latest as (
    select distinct on (block_id) block_id, serviced_area_m2
    from b order by block_id, session_date desc
  )
  select
    (select sum(l.serviced_area_m2) from latest l where l.serviced_area_m2 > 0) as area_m2,
    sum(b.allocated_litres) filter (where b.serviced_area_m2 > 0) as area_volume
  into v_prev_area
  from b;

  -- Warnings + quality
  select * into v_stats from public._irrigation_report_stats(
    p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed);

  -- Rainfall coverage over the vintage period — SQL 149: elapsed days only,
  -- future days never count as expected or missing.
  select * into v_rcov
  from public._irrigation_rainfall_coverage(p_vineyard_id, v_start, v_end);

  v_warnings := public._irrigation_warnings_from_stats(
                  v_stats.total_sessions, v_stats.sessions_without_allocation,
                  v_stats.sessions_missing_area, v_stats.sessions_missing_vines,
                  v_stats.sessions_missing_efficiency, v_stats.sessions_estimated,
                  v_stats.blocks_missing_variety)
                || public._irrigation_rainfall_warnings(p_vineyard_id, v_start, v_end);

  v_filters := jsonb_build_object(
    'vintage_year', v_vintage, 'date_from', p_date_from, 'date_to', p_date_to,
    'system_id', p_system_id, 'water_source', p_water_source,
    'valve_id', p_valve_id, 'block_id', p_block_id, 'variety_id', p_variety_id,
    'source_type', p_source_type, 'source_group', p_source_group,
    'calculation_method', p_calculation_method, 'measurement_group', p_measurement_group,
    'include_estimated', p_include_estimated, 'include_imported', p_include_imported,
    'include_reversed', p_include_reversed);

  return public._irrigation_report_envelope(
    'vintage_overview', p_vineyard_id, v_vintage, v_start, v_end, v_filters,
    jsonb_build_object(
      'total_irrigation_litres', v_tot.total,
      'effective_irrigation_litres',
        case when v_tot.sessions > 0 and v_tot.eff_missing = 0 then round(v_tot.eff_sum, 1) else null end,
      'directly_reported_litres', v_tot.reported,
      'directly_measured_litres', v_tot.measured,
      'calculated_litres', v_tot.calculated,
      'estimated_litres', v_tot.estimated,
      'manual_litres', v_tot.manual,
      'imported_litres', v_tot.imported,
      'average_session_litres', v_tot.avg_litres,
      'total_runtime_minutes', v_tot.runtime,
      'session_count', v_tot.sessions,
      'average_session_minutes', v_tot.avg_minutes,
      'longest_session_minutes', v_tot.longest,
      'shortest_session_minutes', v_tot.shortest,
      'systems_used', v_cov.systems,
      'water_sources_used', v_cov.sources,
      'valves_used', v_cov.valves,
      'blocks_irrigated', coalesce(v_area.blocks, 0),
      'varieties_irrigated', coalesce(v_area.varieties, 0),
      'serviced_area_hectares',
        case when v_area.area_m2 > 0 then round(v_area.area_m2 / 10000.0, 4) else null end,
      'serviced_vines', v_area.vines,
      'litres_per_hectare',
        case when v_area.area_m2 > 0
             then round(v_area.area_volume / (v_area.area_m2 / 10000.0), 2) else null end,
      'litres_per_vine',
        case when v_area.vines > 0
             then round(v_area.vine_volume / v_area.vines, 3) else null end,
      'irrigation_depth_mm',
        case when v_area.area_m2 > 0
             then round(v_area.area_volume / v_area.area_m2, 3) else null end,
      'effective_irrigation_depth_mm',
        case when v_area.area_m2 > 0 and coalesce(v_area.eff_area_missing, 0) = 0
                  and v_area.eff_area_volume is not null
             then round(v_area.eff_area_volume / v_area.area_m2, 3) else null end,
      'normalisation_basis', 'latest_saved_serviced_values_weighted',
      'first_irrigation_date', v_tot.first_date,
      'last_irrigation_date', v_tot.last_date,
      'days_since_last_irrigation',
        case when v_tot.last_date is not null then (current_date - v_tot.last_date) else null end,
      'highest_use_date', v_top_day.session_date,
      'highest_use_date_litres', v_top_day.litres,
      'highest_use_month', v_top_month.month,
      'highest_use_month_litres', v_top_month.litres,
      'previous_vintage_year', v_vintage - 1,
      'previous_total_litres', v_prev.total,
      'volume_difference_litres', v_tot.total - v_prev.total,
      'volume_difference_percent', public._irrigation_pct_diff(v_tot.total, v_prev.total),
      'previous_depth_mm',
        case when v_prev_area.area_m2 > 0
             then round(v_prev_area.area_volume / v_prev_area.area_m2, 3) else null end,
      'depth_difference_mm',
        case when v_area.area_m2 > 0 and v_prev_area.area_m2 > 0
             then round(v_area.area_volume / v_area.area_m2
                        - v_prev_area.area_volume / v_prev_area.area_m2, 3) else null end,
      'previous_runtime_minutes', v_prev.runtime,
      'runtime_difference_minutes', v_tot.runtime - v_prev.runtime,
      'previous_session_count', v_prev.sessions,
      'session_count_difference', v_tot.sessions - v_prev.sessions)
    -- Split into a second jsonb_build_object: PostgreSQL caps function calls
    -- at 100 arguments, and the full payload is 53 pairs = 106 arguments.
    || jsonb_build_object(
      'rainfall_mm', (select round(sum(rb.rainfall_mm), 1)
                      from public._irrigation_rainfall_best(p_vineyard_id, v_start, v_end) rb),
      'rainfall_data_complete', v_rcov.data_complete,
      'rainfall_expected_days', v_rcov.expected_days,
      'rainfall_observed_days', v_rcov.observed_days,
      'rainfall_missing_days', v_rcov.missing_days,
      'rainfall_future_days', v_rcov.future_days,
      'rainfall_coverage_start', v_rcov.coverage_start,
      'rainfall_coverage_end', v_rcov.coverage_end,
      'data_quality', public._irrigation_data_quality(
        v_stats.total_sessions, v_stats.sessions_missing_area,
        v_stats.sessions_missing_vines, v_stats.sessions_missing_efficiency,
        v_rcov.data_complete),
      'warnings', v_warnings));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Period rows (daily/weekly/monthly + rainfall summary source) — per-row
--    rainfall completeness now counts elapsed days only; fully-future rows
--    return rainfall_data_complete = null ("not yet applicable") and null
--    rainfall values, and never warn or lower coverage.
-- ---------------------------------------------------------------------------

create or replace function public._irrigation_period_rows(
  p_group_by text,                -- 'day' | 'week' | 'month'
  p_include_zero_periods boolean,
  p_vineyard_id uuid,
  p_vintage_year integer,
  p_from date,
  p_to date,
  p_date_from date,
  p_date_to date,
  p_system_id uuid,
  p_water_source text,
  p_valve_id uuid,
  p_block_id uuid,
  p_variety_id uuid,
  p_source_type text,
  p_source_group text,
  p_calculation_method text,
  p_measurement_group text,
  p_include_estimated boolean,
  p_include_imported boolean,
  p_include_reversed boolean
) returns jsonb
language sql
stable
set search_path = public
as $$
  with t as (
    select public._irrigation_local_today(p_vineyard_id) as today
  ),
  s as (
    select * from public._irrigation_report_sessions(
      p_vineyard_id, p_vintage_year, p_date_from, p_date_to, p_system_id,
      p_water_source, p_valve_id, p_block_id, p_variety_id, p_source_type,
      p_source_group, p_calculation_method, p_measurement_group,
      p_include_estimated, p_include_imported, p_include_reversed)
  ),
  b as (
    select * from public._irrigation_report_blocks(
      p_vineyard_id, p_vintage_year, p_date_from, p_date_to, p_system_id,
      p_water_source, p_valve_id, p_block_id, p_variety_id, p_source_type,
      p_source_group, p_calculation_method, p_measurement_group,
      p_include_estimated, p_include_imported, p_include_reversed)
  ),
  periods as (
    -- Calendar periods for the requested range, PLUS any period that contains
    -- a filtered session (protects reconciliation if season settings changed
    -- after a session's vintage was frozen).
    select case p_group_by
             when 'day' then gs::date
             when 'week' then date_trunc('week', gs)::date
             else date_trunc('month', gs)::date
           end as pstart
    from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') gs
    union
    select case p_group_by
             when 'day' then s.session_date
             when 'week' then date_trunc('week', s.session_date)::date
             else date_trunc('month', s.session_date)::date
           end
    from s
  ),
  bounds as (
    select pstart,
           case p_group_by
             when 'day' then pstart
             when 'week' then pstart + 6
             else (pstart + interval '1 month' - interval '1 day')::date
           end as pend
    from periods
  ),
  sess as (
    select case p_group_by
             when 'day' then s.session_date
             when 'week' then date_trunc('week', s.session_date)::date
             else date_trunc('month', s.session_date)::date
           end as pstart,
           count(*)::integer as sessions,
           sum(s.total_litres) as total,
           count(*) filter (where s.effective_litres is null) as eff_missing,
           sum(s.effective_litres) as eff_sum,
           sum(s.duration_minutes)::integer as runtime,
           sum(s.total_litres) filter (where s.source_group = 'manual') as manual,
           sum(s.total_litres) filter (where s.source_group = 'controller_import') as imported,
           sum(s.total_litres) filter (where s.measurement_group = 'estimated') as estimated,
           sum(s.total_litres) filter (where s.measurement_group = 'directly_reported') as reported,
           count(distinct s.valve_id)::integer as valves
    from s
    group by 1
  ),
  depth as (
    select pstart,
           count(distinct block_id)::integer as blocks,
           case when sum(area) > 0 then round(sum(vol) / sum(area), 3) else null end as depth_mm,
           case when sum(area) > 0 and sum(eff_missing) = 0 and sum(evol) is not null
                then round(sum(evol) / sum(area), 3) else null end as eff_depth_mm
    from (
      select case p_group_by
               when 'day' then b.session_date
               when 'week' then date_trunc('week', b.session_date)::date
               else date_trunc('month', b.session_date)::date
             end as pstart,
             b.block_id,
             sum(b.allocated_litres) filter (where b.serviced_area_m2 is not null) as vol,
             sum(b.effective_litres) filter (where b.serviced_area_m2 is not null) as evol,
             count(*) filter (where b.serviced_area_m2 is not null
                                and b.effective_litres is null) as eff_missing,
             max(b.serviced_area_m2) as area
      from b
      group by 1, 2
    ) per_block
    group by pstart
  ),
  rain as (
    -- _irrigation_rainfall_best is capped at local today (SQL 149), so future
    -- periods have no rain rows here and rainfall_mm stays null for them.
    select case p_group_by
             when 'day' then rb.day
             when 'week' then date_trunc('week', rb.day)::date
             else date_trunc('month', rb.day)::date
           end as pstart,
           sum(rb.rainfall_mm) as rainfall_mm,
           count(*)::integer as rain_days
    from public._irrigation_rainfall_best(p_vineyard_id, p_from, p_to) rb
    group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'period_key', case p_group_by
                      when 'day' then to_char(bd.pstart, 'YYYY-MM-DD')
                      when 'week' then to_char(bd.pstart, 'IYYY-"W"IW')
                      else to_char(bd.pstart, 'YYYY-MM')
                    end,
      'period_start', bd.pstart,
      'period_end', least(bd.pend, p_to),
      'week_number', case when p_group_by = 'week'
                          then extract(week from bd.pstart)::integer else null end,
      'total_litres', coalesce(ss.total, 0),
      'effective_litres',
        case when coalesce(ss.sessions, 0) > 0 and coalesce(ss.eff_missing, 0) = 0
             then round(ss.eff_sum, 1) else null end,
      'runtime_minutes', coalesce(ss.runtime, 0),
      'session_count', coalesce(ss.sessions, 0),
      'manual_litres', coalesce(ss.manual, 0),
      'imported_litres', coalesce(ss.imported, 0),
      'estimated_litres', coalesce(ss.estimated, 0),
      'directly_reported_litres', coalesce(ss.reported, 0),
      'valves_used', coalesce(ss.valves, 0),
      'blocks_irrigated', coalesce(dd.blocks, 0),
      'irrigation_depth_mm', dd.depth_mm,
      'effective_depth_mm', dd.eff_depth_mm,
      'rainfall_mm', rn.rainfall_mm,
      'rainfall_data_complete',
        case when cov.expected_days = 0 then null
             else (coalesce(rn.rain_days, 0) >= cov.expected_days) end,
      'rainfall_expected_days', cov.expected_days,
      'rainfall_observed_days', least(coalesce(rn.rain_days, 0), cov.expected_days),
      'rainfall_missing_days', greatest(cov.expected_days - coalesce(rn.rain_days, 0), 0),
      'rainfall_future_days', cov.future_days,
      'combined_water_input_mm',
        case when rn.rainfall_mm is not null and dd.depth_mm is not null
             then round(rn.rainfall_mm + dd.depth_mm, 3)
             when rn.rainfall_mm is not null and coalesce(ss.sessions, 0) = 0
             then round(rn.rainfall_mm, 3)
             else null end
    ) order by bd.pstart), '[]'::jsonb)
  from bounds bd
  cross join t
  cross join lateral (
    -- Elapsed vs future day split for THIS row's effective range
    -- [greatest(pstart, p_from) .. least(pend, p_to)], cut at local today.
    select greatest(least(bd.pend, p_to, t.today)
                    - greatest(bd.pstart, p_from) + 1, 0) as expected_days,
           greatest((least(bd.pend, p_to) - greatest(bd.pstart, p_from) + 1)
                    - greatest(least(bd.pend, p_to, t.today)
                               - greatest(bd.pstart, p_from) + 1, 0), 0) as future_days
  ) cov
  left join sess ss on ss.pstart = bd.pstart
  left join depth dd on dd.pstart = bd.pstart
  left join rain rn on rn.pstart = bd.pstart
  where p_include_zero_periods or coalesce(ss.sessions, 0) > 0;
$$;

-- ---------------------------------------------------------------------------
-- 7. Rainfall summary — coverage-based completeness for the vintage grouping
--    and pass-through of the new per-row coverage fields for day/week/month.
-- ---------------------------------------------------------------------------

create or replace function public.get_irrigation_rainfall_summary(
  p_vineyard_id uuid,
  p_vintage_year integer default null,
  p_group_by text default 'month',      -- day | week | month | vintage
  p_date_from date default null,
  p_date_to date default null,
  p_system_id uuid default null,
  p_water_source text default null,
  p_valve_id uuid default null,
  p_block_id uuid default null,
  p_variety_id uuid default null,
  p_source_type text default null,
  p_source_group text default null,
  p_calculation_method text default null,
  p_measurement_group text default null,
  p_include_estimated boolean default true,
  p_include_imported boolean default true,
  p_include_reversed boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vintage integer;
  v_start date;
  v_end date;
  v_from date;
  v_to date;
  v_rows jsonb;
  v_filters jsonb;
  v_group text;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_group := lower(coalesce(p_group_by, 'month'));
  if v_group not in ('day','week','month','vintage') then
    raise exception 'p_group_by must be day, week, month or vintage' using errcode = '22023';
  end if;

  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  select vp.period_start, vp.period_end into v_start, v_end
  from public._irrigation_vintage_period(p_vineyard_id, v_vintage) vp;
  v_from := coalesce(p_date_from, v_start);
  v_to := coalesce(p_date_to, v_end);

  if v_group = 'vintage' then
    -- One row over the whole period: the depth is computed directly from the
    -- saved block rows (latest covered area weighting, same as the overview) —
    -- never a sum of unweighted sub-period depths.
    with b as (
      select * from public._irrigation_report_blocks(
        p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
        p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
        p_calculation_method, p_measurement_group, p_include_estimated,
        p_include_imported, p_include_reversed)
    ),
    latest as (
      select distinct on (block_id) block_id, serviced_area_m2
      from b order by block_id, session_date desc
    ),
    depth as (
      select
        (select sum(l.serviced_area_m2) from latest l where l.serviced_area_m2 > 0) as area_m2,
        sum(b.allocated_litres) filter (where b.serviced_area_m2 > 0) as area_vol,
        sum(b.effective_litres) filter (where b.serviced_area_m2 > 0) as eff_vol,
        count(*) filter (where b.serviced_area_m2 > 0 and b.effective_litres is null) as eff_missing
      from b
    ),
    rain as (
      select sum(rb.rainfall_mm) as rainfall_mm
      from public._irrigation_rainfall_best(p_vineyard_id, v_from, v_to) rb
    ),
    cov as (
      select * from public._irrigation_rainfall_coverage(p_vineyard_id, v_from, v_to)
    )
    select jsonb_build_array(jsonb_build_object(
        'period_key', 'V' || v_vintage::text,
        'period_start', v_from,
        'period_end', v_to,
        'rainfall_mm', rn.rainfall_mm,
        'gross_irrigation_depth_mm',
          case when d.area_m2 > 0 then round(d.area_vol / d.area_m2, 3) else null end,
        'effective_irrigation_depth_mm',
          case when d.area_m2 > 0 and coalesce(d.eff_missing, 0) = 0 and d.eff_vol is not null
               then round(d.eff_vol / d.area_m2, 3) else null end,
        'combined_water_input_mm',
          case when rn.rainfall_mm is not null and d.area_m2 > 0
               then round(rn.rainfall_mm + d.area_vol / d.area_m2, 3) else null end,
        'irrigation_percent_of_combined',
          case when rn.rainfall_mm is not null and d.area_m2 > 0
                    and (rn.rainfall_mm + d.area_vol / d.area_m2) > 0
               then round((d.area_vol / d.area_m2) / (rn.rainfall_mm + d.area_vol / d.area_m2) * 100.0, 1)
               else null end,
        'rainfall_percent_of_combined',
          case when rn.rainfall_mm is not null and d.area_m2 > 0
                    and (rn.rainfall_mm + d.area_vol / d.area_m2) > 0
               then round(rn.rainfall_mm / (rn.rainfall_mm + d.area_vol / d.area_m2) * 100.0, 1)
               else null end,
        'rainfall_data_complete', c.data_complete,
        'rainfall_expected_days', c.expected_days,
        'rainfall_observed_days', c.observed_days,
        'rainfall_missing_days', c.missing_days,
        'rainfall_future_days', c.future_days,
        'rainfall_coverage_start', c.coverage_start,
        'rainfall_coverage_end', c.coverage_end))
    into v_rows
    from depth d cross join rain rn cross join cov c;
  else
  with base as (
    select value as r
    from jsonb_array_elements(public._irrigation_period_rows(
      v_group, true,
      p_vineyard_id, v_vintage, v_from, v_to, p_date_from, p_date_to,
      p_system_id, p_water_source, p_valve_id, p_block_id, p_variety_id,
      p_source_type, p_source_group, p_calculation_method, p_measurement_group,
      p_include_estimated, p_include_imported, p_include_reversed))
  ),
  grouped as (
    select r->>'period_key' as period_key,
           (r->>'period_start')::date as period_start,
           (r->>'period_end')::date as period_end,
           (r->>'rainfall_mm')::numeric as rainfall_mm,
           (r->>'irrigation_depth_mm')::numeric as gross_depth,
           (r->>'effective_depth_mm')::numeric as eff_depth,
           (r->>'rainfall_data_complete')::boolean as rain_complete,
           (r->>'rainfall_expected_days')::integer as rain_expected,
           (r->>'rainfall_observed_days')::integer as rain_observed,
           (r->>'rainfall_missing_days')::integer as rain_missing,
           (r->>'rainfall_future_days')::integer as rain_future
    from base
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'period_key', period_key,
      'period_start', period_start,
      'period_end', period_end,
      'rainfall_mm', rainfall_mm,
      'gross_irrigation_depth_mm', gross_depth,
      'effective_irrigation_depth_mm', eff_depth,
      'combined_water_input_mm',
        case when rainfall_mm is not null and gross_depth is not null
             then round(rainfall_mm + gross_depth, 3)
             when rainfall_mm is not null and gross_depth is null then null
             else null end,
      'irrigation_percent_of_combined',
        case when rainfall_mm is not null and gross_depth is not null
                  and (rainfall_mm + gross_depth) > 0
             then round(gross_depth / (rainfall_mm + gross_depth) * 100.0, 1) else null end,
      'rainfall_percent_of_combined',
        case when rainfall_mm is not null and gross_depth is not null
                  and (rainfall_mm + gross_depth) > 0
             then round(rainfall_mm / (rainfall_mm + gross_depth) * 100.0, 1) else null end,
      'rainfall_data_complete', rain_complete,
      'rainfall_expected_days', rain_expected,
      'rainfall_observed_days', rain_observed,
      'rainfall_missing_days', rain_missing,
      'rainfall_future_days', rain_future
    ) order by period_start), '[]'::jsonb)
  into v_rows
  from grouped;
  end if;

  v_filters := jsonb_build_object(
    'vintage_year', v_vintage, 'group_by', v_group,
    'date_from', p_date_from, 'date_to', p_date_to,
    'system_id', p_system_id, 'water_source', p_water_source,
    'valve_id', p_valve_id, 'block_id', p_block_id, 'variety_id', p_variety_id,
    'source_type', p_source_type, 'source_group', p_source_group,
    'calculation_method', p_calculation_method, 'measurement_group', p_measurement_group,
    'include_estimated', p_include_estimated, 'include_imported', p_include_imported,
    'include_reversed', p_include_reversed);

  return public._irrigation_report_envelope(
    'rainfall_summary', p_vineyard_id, v_vintage, v_start, v_end, v_filters,
    jsonb_build_object(
      'group_by', v_group,
      'rows', v_rows,
      'warnings', public._irrigation_rainfall_warnings(p_vineyard_id, v_from, v_to)));
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Multi-vintage trends — coverage-based completeness per vintage; future
--    dates in the current vintage no longer reduce the data-quality score.
-- ---------------------------------------------------------------------------

create or replace function public.get_irrigation_vintage_trends(
  p_vineyard_id uuid,
  p_vintage_year integer default null,    -- latest vintage in the range
  p_vintage_count integer default 5,      -- 1..10
  p_system_id uuid default null,
  p_water_source text default null,
  p_valve_id uuid default null,
  p_block_id uuid default null,
  p_variety_id uuid default null,
  p_source_type text default null,
  p_source_group text default null,
  p_calculation_method text default null,
  p_measurement_group text default null,
  p_include_estimated boolean default true,
  p_include_imported boolean default true,
  p_include_reversed boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_latest integer;
  v_count integer;
  v_vintage integer;
  v_start date;
  v_end date;
  v_rows jsonb := '[]'::jsonb;
  v_tot record;
  v_area record;
  v_stats record;
  v_rain numeric;
  v_rcov record;
  v_filters jsonb;
  i integer;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_latest := coalesce(p_vintage_year,
                       public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  v_count := least(greatest(coalesce(p_vintage_count, 5), 1), 10);

  for i in reverse (v_count - 1)..0 loop
    v_vintage := v_latest - i;
    select vp.period_start, vp.period_end into v_start, v_end
    from public._irrigation_vintage_period(p_vineyard_id, v_vintage) vp;

    select count(*)::integer as sessions,
           coalesce(sum(s.total_litres), 0) as total,
           count(*) filter (where s.effective_litres is null) as eff_missing,
           sum(s.effective_litres) as eff_sum,
           coalesce(sum(s.total_litres) filter (where s.source_group = 'manual'), 0) as manual,
           coalesce(sum(s.total_litres) filter (where s.source_group = 'controller_import'), 0) as imported,
           coalesce(sum(s.total_litres) filter (where s.measurement_group = 'estimated'), 0) as estimated,
           coalesce(sum(s.total_litres) filter (where s.measurement_group = 'directly_reported'), 0) as reported,
           coalesce(sum(s.duration_minutes), 0)::integer as runtime
    into v_tot
    from public._irrigation_report_sessions(
      p_vineyard_id, v_vintage, null, null, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed) s;

    with b as (
      select * from public._irrigation_report_blocks(
        p_vineyard_id, v_vintage, null, null, p_system_id, p_water_source,
        p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
        p_calculation_method, p_measurement_group, p_include_estimated,
        p_include_imported, p_include_reversed)
    ),
    latest as (
      select distinct on (block_id) block_id, serviced_area_m2, serviced_vine_count
      from b order by block_id, session_date desc
    )
    select
      (select sum(l.serviced_area_m2) from latest l where l.serviced_area_m2 > 0) as area_m2,
      (select sum(l.serviced_vine_count) from latest l where l.serviced_vine_count > 0) as vines,
      sum(b.allocated_litres) filter (where b.serviced_area_m2 > 0) as area_vol,
      sum(b.allocated_litres) filter (where b.serviced_vine_count > 0) as vine_vol,
      sum(b.effective_litres) filter (where b.serviced_area_m2 > 0) as eff_area_vol,
      count(*) filter (where b.serviced_area_m2 > 0 and b.effective_litres is null) as eff_area_missing
    into v_area
    from b;

    select * into v_stats from public._irrigation_report_stats(
      p_vineyard_id, v_vintage, null, null, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed);

    select round(sum(rb.rainfall_mm), 1) into v_rain
    from public._irrigation_rainfall_best(p_vineyard_id, v_start, v_end) rb;
    select * into v_rcov
    from public._irrigation_rainfall_coverage(p_vineyard_id, v_start, v_end);

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'vintage_year', v_vintage,
      'period_start', v_start,
      'period_end', v_end,
      'total_litres', v_tot.total,
      'effective_litres',
        case when v_tot.sessions > 0 and v_tot.eff_missing = 0
             then round(v_tot.eff_sum, 1) else null end,
      'manual_litres', v_tot.manual,
      'imported_litres', v_tot.imported,
      'estimated_litres', v_tot.estimated,
      'directly_reported_litres', v_tot.reported,
      'runtime_minutes', v_tot.runtime,
      'session_count', v_tot.sessions,
      'serviced_area_hectares',
        case when v_area.area_m2 > 0 then round(v_area.area_m2 / 10000.0, 4) else null end,
      'litres_per_hectare',
        case when v_area.area_m2 > 0
             then round(v_area.area_vol / (v_area.area_m2 / 10000.0), 2) else null end,
      'litres_per_vine',
        case when v_area.vines > 0 then round(v_area.vine_vol / v_area.vines, 3) else null end,
      'irrigation_depth_mm',
        case when v_area.area_m2 > 0 then round(v_area.area_vol / v_area.area_m2, 3) else null end,
      'effective_depth_mm',
        case when v_area.area_m2 > 0 and coalesce(v_area.eff_area_missing, 0) = 0
                  and v_area.eff_area_vol is not null
             then round(v_area.eff_area_vol / v_area.area_m2, 3) else null end,
      'rainfall_mm', v_rain,
      'rainfall_data_complete', v_rcov.data_complete,
      'rainfall_expected_days', v_rcov.expected_days,
      'rainfall_observed_days', v_rcov.observed_days,
      'rainfall_missing_days', v_rcov.missing_days,
      'rainfall_future_days', v_rcov.future_days,
      'combined_water_input_mm',
        case when v_rain is not null and v_area.area_m2 > 0
             then round(v_rain + v_area.area_vol / v_area.area_m2, 3) else null end,
      'data_quality', public._irrigation_data_quality(
        v_stats.total_sessions, v_stats.sessions_missing_area,
        v_stats.sessions_missing_vines, v_stats.sessions_missing_efficiency,
        v_rcov.data_complete),
      'warnings',
        public._irrigation_warnings_from_stats(
          v_stats.total_sessions, v_stats.sessions_without_allocation,
          v_stats.sessions_missing_area, v_stats.sessions_missing_vines,
          v_stats.sessions_missing_efficiency, v_stats.sessions_estimated,
          v_stats.blocks_missing_variety)
        || public._irrigation_rainfall_warnings(p_vineyard_id, v_start, v_end)));
  end loop;

  select vp.period_start into v_start
  from public._irrigation_vintage_period(p_vineyard_id, v_latest - v_count + 1) vp;
  select vp.period_end into v_end
  from public._irrigation_vintage_period(p_vineyard_id, v_latest) vp;

  v_filters := jsonb_build_object(
    'vintage_year', v_latest, 'vintage_count', v_count,
    'system_id', p_system_id, 'water_source', p_water_source,
    'valve_id', p_valve_id, 'block_id', p_block_id, 'variety_id', p_variety_id,
    'source_type', p_source_type, 'source_group', p_source_group,
    'calculation_method', p_calculation_method, 'measurement_group', p_measurement_group,
    'include_estimated', p_include_estimated, 'include_imported', p_include_imported,
    'include_reversed', p_include_reversed);

  return public._irrigation_report_envelope(
    'vintage_trends', p_vineyard_id, v_latest, v_start, v_end, v_filters,
    jsonb_build_object('rows', v_rows, 'warnings', '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Grants — new helpers are locked down like every other _irrigation_*
--    helper; replaced functions keep their SQL 147 ACLs (create or replace
--    preserves grants).
-- ---------------------------------------------------------------------------

revoke all on function public._irrigation_local_today(uuid)
  from public, anon, authenticated;
revoke all on function public._irrigation_rainfall_coverage(uuid, date, date)
  from public, anon, authenticated;

-- =============================================================================
-- VERIFICATION (run after applying)
--   1) select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--      where n.nspname = 'public'
--        and proname in ('_irrigation_local_today','_irrigation_rainfall_coverage');
--      -- expect 2 rows.
--   2) Run sql/tests/149_irrigation_rainfall_coverage_tests.sql (single
--      transaction, always rolled back). Expect:
--      NOTICE: SQL 149 rainfall coverage tests: ALL PASSED
--   3) Stockmans Ridge spot check (current vintage on any date mid-vintage):
--      select (r->>'rainfall_expected_days')::int  as expected,
--             (r->>'rainfall_missing_days')::int   as missing,
--             (r->>'rainfall_future_days')::int    as future,
--             r->'warnings'
--      from get_irrigation_vintage_overview('<vineyard-id>') r(r);
--      -- expected = elapsed days only; future days never appear in warnings.
--
-- ROLLBACK
--   Re-run sections 3 (rainfall best), 4 (rainfall warnings), 6 (vintage
--   overview), 7 (period rows), 12 (rainfall summary) and 13 (vintage trends)
--   of sql/147_irrigation_phase_2b_reporting.sql to restore the previous
--   definitions, then:
--     drop function if exists public._irrigation_rainfall_coverage(uuid, date, date);
--     drop function if exists public._irrigation_local_today(uuid);
--   No tables or data are touched by this migration.
-- =============================================================================

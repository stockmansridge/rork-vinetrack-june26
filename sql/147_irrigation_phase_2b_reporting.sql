-- =============================================================================
-- 147_irrigation_phase_2b_reporting.sql
-- Irrigation Records Phase 2B — Advanced Reporting, Rainfall Comparison and
-- Multi-Vintage Analysis.
--
-- PURPOSE
--   A complete server-authoritative irrigation reporting layer:
--     * Vintage overview (with previous-vintage comparison)
--     * Daily / Weekly / Monthly summaries (with rainfall + depth)
--     * Valve / Block / Variety / Water-source reports
--     * Calculation-method and record-source (platform) analysis
--     * Rainfall vs irrigation comparison (day/week/month/vintage)
--     * Multi-vintage trends (up to 10 vintages) with data-quality scores
--     * Session drill-down contract (list_irrigation_report_sessions)
--
-- AUDIT RESULTS THIS BUILDS ON (do not duplicate these sources)
--   * Rainfall source ......... public.rainfall_daily (SQL 028). Best source
--     per local date: manual > davis_weatherlink > open_meteo. One row per
--     day; a missing day means "no data", never zero.
--   * Vintage resolver ........ public.resolve_vineyard_vintage_year (SQL 119)
--     + vineyards.season_start_month/day (SQL 108, default 1 July).
--     Vintage period: [season start in (vintage-1), day before season start
--     in vintage]. No second resolver is created here.
--   * Efficiency .............. paddocks.irrigation_efficiency_percent is the
--     ONLY efficiency source (block level). It is frozen per session
--     (irrigation_sessions.irrigation_efficiency_percent) and per block row
--     (irrigation_session_blocks.effective_volume_litres). Priority order:
--     frozen block-level value only — there is no system/valve/vineyard
--     efficiency. Sessions missing frozen efficiency report NULL effective
--     values + a structured warning. Historical sessions are NEVER rewritten.
--   * Sessions ................ canonical irrigation_sessions +
--     irrigation_session_blocks with frozen serviced area/vines/depth.
--     Imported Galcon sessions: source_type='galcon_gsi_import',
--     calculation_method='controller_reported_volume' (SQL 142).
--
-- SOURCE CLASSIFICATION (§3)
--   source_type  -> source_group
--     manual_ios / manual_android / manual_portal        -> manual
--     galcon_gsi_import / controller_api / csv_import    -> controller_import
--     system_generated                                   -> system
--
-- CALCULATION CLASSIFICATION (§4)
--   calculation_method            flow_is_estimated  -> measurement_group
--     total_volume                       —              directly_reported
--     controller_reported_volume         —              directly_reported
--     meter_readings                     —              directly_measured
--     session_flow                       —              calculated
--     configured_flow                  false            calculated
--     configured_flow                  true             estimated
--   flow_is_estimated is the frozen snapshot flag written by SQL 131
--   (emitter-derived automatic flow). Missing flag (pre-131 rows) -> false.
--   Galcon controller-reported volume is NEVER classified as a meter reading.
--
-- COMPATIBILITY
--   The Phase 1 summary RPCs (get_irrigation_vintage_summary,
--   get_irrigation_valve_summary, get_irrigation_block_summary,
--   get_irrigation_variety_summary, get_irrigation_daily_summary,
--   get_irrigation_monthly_summary) are NOT touched: released mobile builds
--   keep working. Phase 2B lives in a new, uniformly enveloped namespace.
--
-- EXPORT CONTRACT (§27)
--   Every RPC below returns raw metric numerics inside a stable envelope
--   (report, vineyard_id, vintage_year, period_start, period_end, timezone,
--   generated_at, unit_context, filters_applied, rows/totals, warnings).
--   The same RPCs are the export RPCs — no formatted display strings.
--
-- SECURITY (§32)
--   Every public RPC calls public._irrigation_require_access() which enforces
--   has_irrigation_records_access() = is_system_admin() AND vineyard member.
--   Helpers are revoked from anon/authenticated. Hidden navigation is not the
--   security boundary — these checks are.
--
-- ROLLBACK — see the commented block at the end of this file.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Classification helpers (immutable, pure)
-- ---------------------------------------------------------------------------

create or replace function public._irrigation_source_group(p_source_type text)
returns text
language sql
immutable
as $$
  select case
    when p_source_type in ('manual_ios','manual_android','manual_portal') then 'manual'
    when p_source_type in ('galcon_gsi_import','controller_api','csv_import') then 'controller_import'
    else 'system'
  end;
$$;

create or replace function public._irrigation_source_label(p_source_type text)
returns text
language sql
immutable
as $$
  select case p_source_type
    when 'manual_ios' then 'Manual (iOS)'
    when 'manual_android' then 'Manual (Android)'
    when 'manual_portal' then 'Manual (Portal)'
    when 'galcon_gsi_import' then 'Galcon GSI import'
    when 'controller_api' then 'Controller API'
    when 'csv_import' then 'CSV import'
    when 'system_generated' then 'System generated'
    else coalesce(initcap(replace(p_source_type, '_', ' ')), 'Unknown')
  end;
$$;

create or replace function public._irrigation_calc_label(p_method text)
returns text
language sql
immutable
as $$
  select case p_method
    when 'configured_flow' then 'Configured valve flow × duration'
    when 'session_flow' then 'Session flow override × duration'
    when 'total_volume' then 'Total volume entered'
    when 'meter_readings' then 'Meter readings'
    when 'controller_reported_volume' then 'Controller-reported volume'
    else coalesce(initcap(replace(p_method, '_', ' ')), 'Unknown')
  end;
$$;

create or replace function public._irrigation_measurement_group(
  p_method text,
  p_flow_estimated boolean
)
returns text
language sql
immutable
as $$
  select case
    when p_method in ('total_volume','controller_reported_volume') then 'directly_reported'
    when p_method = 'meter_readings' then 'directly_measured'
    when p_method = 'configured_flow' and coalesce(p_flow_estimated, false) then 'estimated'
    else 'calculated'
  end;
$$;

create or replace function public._irrigation_measurement_label(p_group text)
returns text
language sql
immutable
as $$
  select case p_group
    when 'directly_reported' then 'Directly reported'
    when 'directly_measured' then 'Directly measured'
    when 'calculated' then 'Calculated'
    when 'estimated' then 'Estimated'
    else coalesce(initcap(p_group), 'Unknown')
  end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Vintage period + report context helpers
-- ---------------------------------------------------------------------------

-- Safe season-boundary date (handles 29 Feb season starts in non-leap years).
create or replace function public._irrigation_safe_season_date(
  p_year integer, p_month integer, p_day integer
)
returns date
language sql
immutable
as $$
  select make_date(p_year, p_month,
    least(p_day,
      extract(day from (make_date(p_year, p_month, 1)
        + interval '1 month' - interval '1 day'))::integer));
$$;

-- Vintage period from the SHARED season settings (SQL 108/119 rules):
--   period_start = season start date in (vintage - 1)
--   period_end   = day before season start date in vintage
create or replace function public._irrigation_vintage_period(
  p_vineyard_id uuid,
  p_vintage_year integer
)
returns table (period_start date, period_end date)
language sql
stable
security definer
set search_path = public
as $$
  select
    public._irrigation_safe_season_date(p_vintage_year - 1,
      coalesce(v.season_start_month::integer, 7),
      coalesce(v.season_start_day::integer, 1)),
    public._irrigation_safe_season_date(p_vintage_year,
      coalesce(v.season_start_month::integer, 7),
      coalesce(v.season_start_day::integer, 1)) - 1
  from (select 1) one
  left join public.vineyards v on v.id = p_vineyard_id;
$$;

-- Report timezone: the vineyard's controller-import timezone where saved,
-- otherwise the project default. session_date/rainfall dates are already
-- LOCAL vineyard dates, so this is informational unit context.
create or replace function public._irrigation_report_timezone(p_vineyard_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select s.timezone from public.irrigation_import_provider_settings s
      where s.vineyard_id = p_vineyard_id and s.timezone is not null
      order by s.updated_at desc limit 1),
    'Australia/Sydney');
$$;

-- Canonical metric unit context (§30). Clients convert for display only.
create or replace function public._irrigation_report_unit_context()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'volume', 'litres',
    'flow', 'litres_per_hour',
    'area', 'hectares',
    'area_detail', 'square_metres',
    'depth', 'millimetres',
    'rainfall', 'millimetres',
    'duration', 'minutes');
$$;

-- Standard report envelope (§5). Raw values only; payload keys are merged in.
create or replace function public._irrigation_report_envelope(
  p_report text,
  p_vineyard_id uuid,
  p_vintage_year integer,
  p_period_start date,
  p_period_end date,
  p_filters jsonb,
  p_payload jsonb
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'report', p_report,
    'vineyard_id', p_vineyard_id,
    'vintage_year', p_vintage_year,
    'period_start', p_period_start,
    'period_end', p_period_end,
    'timezone', public._irrigation_report_timezone(p_vineyard_id),
    'generated_at', now(),
    'unit_context', public._irrigation_report_unit_context(),
    'filters_applied', coalesce(jsonb_strip_nulls(p_filters), '{}'::jsonb)
  ) || coalesce(p_payload, '{}'::jsonb);
$$;

-- ---------------------------------------------------------------------------
-- 3. Shared filtered datasets (§34 step 2 — single filter/exclusion source)
--    Plain invoker functions: only callable via the SECURITY DEFINER report
--    RPCs (execute revoked from clients below).
-- ---------------------------------------------------------------------------

create or replace function public._irrigation_report_sessions(
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
)
returns table (
  session_id uuid,
  session_date date,
  vintage_year integer,
  system_id uuid,
  system_name text,
  water_source text,
  valve_id uuid,
  duration_minutes integer,
  total_litres numeric,
  effective_litres numeric,
  calculation_method text,
  measurement_group text,
  source_type text,
  source_group text,
  created_at timestamptz
)
language sql
stable
set search_path = public
as $$
  select
    s.id,
    s.session_date,
    s.vintage_year,
    s.irrigation_system_id,
    sys.name,
    sys.water_source,
    s.valve_id,
    s.duration_minutes,
    s.total_volume_litres,
    s.effective_volume_litres,
    s.calculation_method,
    public._irrigation_measurement_group(s.calculation_method,
      coalesce((s.configuration_snapshot->>'flow_is_estimated')::boolean, false)),
    s.source_type,
    public._irrigation_source_group(s.source_type),
    s.created_at
  from public.irrigation_sessions s
  join public.irrigation_systems sys on sys.id = s.irrigation_system_id
  where s.vineyard_id = p_vineyard_id
    and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
    and (p_vintage_year is null or s.vintage_year = p_vintage_year)
    and (p_date_from is null or s.session_date >= p_date_from)
    and (p_date_to is null or s.session_date <= p_date_to)
    and (p_system_id is null or s.irrigation_system_id = p_system_id)
    and (p_water_source is null or sys.water_source = p_water_source)
    and (p_valve_id is null or s.valve_id = p_valve_id)
    and (p_source_type is null or s.source_type = p_source_type)
    and (p_source_group is null
         or public._irrigation_source_group(s.source_type) = p_source_group)
    and (p_calculation_method is null or s.calculation_method = p_calculation_method)
    and (p_include_imported
         or public._irrigation_source_group(s.source_type) <> 'controller_import')
    and (p_measurement_group is null
         or public._irrigation_measurement_group(s.calculation_method,
              coalesce((s.configuration_snapshot->>'flow_is_estimated')::boolean, false))
            = p_measurement_group)
    and (p_include_estimated
         or public._irrigation_measurement_group(s.calculation_method,
              coalesce((s.configuration_snapshot->>'flow_is_estimated')::boolean, false))
            <> 'estimated')
    and (p_block_id is null or exists (
      select 1 from public.irrigation_session_blocks sb
      where sb.session_id = s.id and sb.block_id = p_block_id))
    and (p_variety_id is null or exists (
      select 1 from public.irrigation_session_blocks sb
      where sb.session_id = s.id and sb.variety_id = p_variety_id));
$$;

-- SAVED session-block rows for the same filtered set. When p_block_id /
-- p_variety_id is set, only the matching block rows are returned (the
-- allocation view), while the sessions dataset returns whole sessions.
create or replace function public._irrigation_report_blocks(
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
)
returns table (
  session_id uuid,
  session_date date,
  vintage_year integer,
  valve_id uuid,
  block_id uuid,
  variety_id uuid,
  variety_name text,
  allocated_litres numeric,
  effective_litres numeric,
  serviced_area_m2 numeric,
  serviced_vine_count integer,
  duration_minutes integer,
  source_type text,
  source_group text,
  calculation_method text,
  measurement_group text
)
language sql
stable
set search_path = public
as $$
  select
    rs.session_id,
    rs.session_date,
    rs.vintage_year,
    sb.valve_id,
    sb.block_id,
    sb.variety_id,
    sb.variety_name,
    sb.allocated_volume_litres,
    sb.effective_volume_litres,
    sb.serviced_area_m2,
    sb.serviced_vine_count,
    rs.duration_minutes,
    rs.source_type,
    rs.source_group,
    rs.calculation_method,
    rs.measurement_group
  from public._irrigation_report_sessions(
         p_vineyard_id, p_vintage_year, p_date_from, p_date_to, p_system_id,
         p_water_source, p_valve_id, p_block_id, p_variety_id, p_source_type,
         p_source_group, p_calculation_method, p_measurement_group,
         p_include_estimated, p_include_imported, p_include_reversed) rs
  join public.irrigation_session_blocks sb on sb.session_id = rs.session_id
  where (p_block_id is null or sb.block_id = p_block_id)
    and (p_variety_id is null or sb.variety_id = p_variety_id);
$$;

-- Best rainfall per local vineyard date (SQL 028 priority):
--   manual > davis_weatherlink > open_meteo. Only days WITH data.
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
      and rd.date between p_from and p_to
  ) r
  where r.rn = 1;
$$;

-- ---------------------------------------------------------------------------
-- 4. Warnings + data-quality (§24/§25)
-- ---------------------------------------------------------------------------

-- Structured completeness stats for a filtered set (one pass, reused by
-- warnings + data-quality scoring).
create or replace function public._irrigation_report_stats(
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
)
returns table (
  total_sessions integer,
  sessions_without_allocation integer,
  sessions_missing_area integer,
  sessions_missing_vines integer,
  sessions_missing_efficiency integer,
  sessions_estimated integer,
  blocks_missing_variety integer
)
language sql
stable
set search_path = public
as $$
  with s as (
    select * from public._irrigation_report_sessions(
      p_vineyard_id, p_vintage_year, p_date_from, p_date_to, p_system_id,
      p_water_source, p_valve_id, p_block_id, p_variety_id, p_source_type,
      p_source_group, p_calculation_method, p_measurement_group,
      p_include_estimated, p_include_imported, p_include_reversed)
  ),
  b as (
    select sb.session_id, sb.block_id, sb.variety_id,
           sb.serviced_area_m2, sb.serviced_vine_count
    from public.irrigation_session_blocks sb
    where sb.session_id in (select s.session_id from s)
  ),
  per_session as (
    select s.session_id,
           s.effective_litres,
           s.measurement_group,
           count(b.block_id) as block_rows,
           count(*) filter (where b.block_id is not null
                              and b.serviced_area_m2 is null) as area_null,
           count(*) filter (where b.block_id is not null
                              and b.serviced_vine_count is null) as vines_null
    from s
    left join b on b.session_id = s.session_id
    group by s.session_id, s.effective_litres, s.measurement_group
  )
  select
    count(*)::integer,
    count(*) filter (where block_rows = 0)::integer,
    count(*) filter (where block_rows = 0 or area_null > 0)::integer,
    count(*) filter (where block_rows = 0 or vines_null > 0)::integer,
    count(*) filter (where effective_litres is null)::integer,
    count(*) filter (where measurement_group = 'estimated')::integer,
    (select count(distinct b2.block_id) from b b2 where b2.variety_id is null)::integer
  from per_session;
$$;

-- Structured warning entries from the stats above (§24 shape).
create or replace function public._irrigation_warnings_from_stats(
  p_total integer,
  p_no_alloc integer,
  p_area integer,
  p_vines integer,
  p_efficiency integer,
  p_estimated integer,
  p_variety_blocks integer
)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_agg(w), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'code', 'incomplete_historical_configuration', 'severity', 'warning',
      'message', format('%s irrigation session(s) have no saved block allocation.', p_no_alloc),
      'affected_count', p_no_alloc) as w
    where p_no_alloc > 0
    union all
    select jsonb_build_object(
      'code', 'missing_serviced_area', 'severity', 'warning',
      'message', format('Serviced area is unavailable for %s irrigation session(s).', p_area),
      'affected_count', p_area)
    where p_area > 0
    union all
    select jsonb_build_object(
      'code', 'missing_serviced_vines', 'severity', 'warning',
      'message', format('Serviced vine counts are unavailable for %s irrigation session(s).', p_vines),
      'affected_count', p_vines)
    where p_vines > 0
    union all
    select jsonb_build_object(
      'code', 'missing_irrigation_efficiency', 'severity', 'warning',
      'message', format('Effective irrigation could not be calculated for %s session(s) without a frozen irrigation efficiency.', p_efficiency),
      'affected_count', p_efficiency)
    where p_efficiency > 0
    union all
    select jsonb_build_object(
      'code', 'estimated_flow_used', 'severity', 'info',
      'message', format('%s session(s) use emitter-derived estimated flow.', p_estimated),
      'affected_count', p_estimated)
    where p_estimated > 0
    union all
    select jsonb_build_object(
      'code', 'unknown_variety', 'severity', 'info',
      'message', format('%s block(s) in this report have no variety assignment.', p_variety_blocks),
      'affected_count', p_variety_blocks)
    where p_variety_blocks > 0
  ) entries;
$$;

-- Rainfall coverage warnings for [p_from, p_to].
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
  with cov as (
    select (p_to - p_from + 1) as days_total,
           (select count(*) from public._irrigation_rainfall_best(p_vineyard_id, p_from, p_to)) as days_with_data
  )
  select case
    when days_total <= 0 then '[]'::jsonb
    when days_with_data = 0 then jsonb_build_array(jsonb_build_object(
      'code', 'missing_rainfall', 'severity', 'warning',
      'message', 'No rainfall data is recorded for this period.',
      'affected_count', days_total))
    when days_with_data < days_total then jsonb_build_array(jsonb_build_object(
      'code', 'partial_rainfall_coverage', 'severity', 'warning',
      'message', format('Rainfall data is missing for %s of %s day(s) in this period.',
                        days_total - days_with_data, days_total),
      'affected_count', days_total - days_with_data))
    else '[]'::jsonb
  end
  from cov;
$$;

-- Data-quality score (§25). Rules (documented, not a fake percentage):
--   limited          no sessions, or < 40% of sessions fully allocated with
--                    saved area, vines and efficiency
--   partial          >= 40% complete on the weakest dimension
--   mostly_complete  >= 80% complete on the weakest dimension, or everything
--                    complete but rainfall coverage incomplete
--   complete         100% area + vines + efficiency AND full rainfall coverage
--                    (rainfall ignored when p_rainfall_complete is null)
create or replace function public._irrigation_data_quality(
  p_total integer,
  p_area_missing integer,
  p_vines_missing integer,
  p_efficiency_missing integer,
  p_rainfall_complete boolean
)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_total, 0) = 0 then 'limited'
    else (
      with r as (
        select least(
          (p_total - coalesce(p_area_missing, 0))::numeric / p_total,
          (p_total - coalesce(p_vines_missing, 0))::numeric / p_total,
          (p_total - coalesce(p_efficiency_missing, 0))::numeric / p_total
        ) as ratio
      )
      select case
        when ratio >= 0.999 and coalesce(p_rainfall_complete, true) then 'complete'
        when ratio >= 0.8 then 'mostly_complete'
        when ratio >= 0.4 then 'partial'
        else 'limited'
      end
      from r)
  end;
$$;

-- Null-safe percentage difference (§7: null when the base is zero/null).
create or replace function public._irrigation_pct_diff(p_current numeric, p_previous numeric)
returns numeric
language sql
immutable
as $$
  select case
    when p_previous is null or p_previous = 0 or p_current is null then null
    else round((p_current - p_previous) / p_previous * 100.0, 1)
  end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Indexes (report access paths; sessions are also covered by the Phase 1
--    (vineyard_id, session_date) and (vineyard_id, vintage_year) indexes)
-- ---------------------------------------------------------------------------

create index if not exists irrigation_sessions_vineyard_vintage_date_idx
  on public.irrigation_sessions (vineyard_id, vintage_year, session_date);

create index if not exists irrigation_sessions_vineyard_source_idx
  on public.irrigation_sessions (vineyard_id, source_type);

-- ---------------------------------------------------------------------------
-- 6. get_irrigation_vintage_overview (§7)
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
  v_rain_days integer;
  v_days integer;
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

  v_days := greatest(v_end - v_start + 1, 1);
  select count(*)::integer into v_rain_days
  from public._irrigation_rainfall_best(p_vineyard_id, v_start, v_end);

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
      'session_count_difference', v_tot.sessions - v_prev.sessions,
      'rainfall_mm', (select round(sum(rb.rainfall_mm), 1)
                      from public._irrigation_rainfall_best(p_vineyard_id, v_start, v_end) rb),
      'rainfall_data_complete', (v_rain_days = v_days),
      'data_quality', public._irrigation_data_quality(
        v_stats.total_sessions, v_stats.sessions_missing_area,
        v_stats.sessions_missing_vines, v_stats.sessions_missing_efficiency,
        (v_rain_days = v_days)),
      'warnings', v_warnings));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Period summaries — daily (§13), weekly (§14), monthly (§15)
--    One shared implementation; the RPCs choose the grouping.
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
  with s as (
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
        coalesce(rn.rain_days, 0) = (least(bd.pend, p_to) - greatest(bd.pstart, p_from) + 1),
      'combined_water_input_mm',
        case when rn.rainfall_mm is not null and dd.depth_mm is not null
             then round(rn.rainfall_mm + dd.depth_mm, 3)
             when rn.rainfall_mm is not null and coalesce(ss.sessions, 0) = 0
             then round(rn.rainfall_mm, 3)
             else null end
    ) order by bd.pstart), '[]'::jsonb)
  from bounds bd
  left join sess ss on ss.pstart = bd.pstart
  left join depth dd on dd.pstart = bd.pstart
  left join rain rn on rn.pstart = bd.pstart
  where p_include_zero_periods or coalesce(ss.sessions, 0) > 0;
$$;

-- Shared driver for the three period RPCs.
create or replace function public._irrigation_period_report(
  p_report text,
  p_group_by text,
  p_include_zero_periods boolean,
  p_vineyard_id uuid,
  p_vintage_year integer,
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
  v_stats record;
  v_filters jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  select vp.period_start, vp.period_end into v_start, v_end
  from public._irrigation_vintage_period(p_vineyard_id, v_vintage) vp;
  v_from := coalesce(p_date_from, v_start);
  v_to := coalesce(p_date_to, v_end);
  if v_from > v_to then
    raise exception 'Invalid date range' using errcode = '22023';
  end if;

  v_rows := public._irrigation_period_rows(
    p_group_by, p_include_zero_periods, p_vineyard_id, v_vintage, v_from, v_to,
    p_date_from, p_date_to, p_system_id, p_water_source, p_valve_id, p_block_id,
    p_variety_id, p_source_type, p_source_group, p_calculation_method,
    p_measurement_group, p_include_estimated, p_include_imported, p_include_reversed);

  select * into v_stats from public._irrigation_report_stats(
    p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed);

  v_filters := jsonb_build_object(
    'vintage_year', v_vintage, 'date_from', p_date_from, 'date_to', p_date_to,
    'system_id', p_system_id, 'water_source', p_water_source,
    'valve_id', p_valve_id, 'block_id', p_block_id, 'variety_id', p_variety_id,
    'source_type', p_source_type, 'source_group', p_source_group,
    'calculation_method', p_calculation_method, 'measurement_group', p_measurement_group,
    'include_estimated', p_include_estimated, 'include_imported', p_include_imported,
    'include_reversed', p_include_reversed, 'include_zero_periods', p_include_zero_periods);

  return public._irrigation_report_envelope(
    p_report, p_vineyard_id, v_vintage, v_start, v_end, v_filters,
    jsonb_build_object(
      'group_by', p_group_by,
      'rows', v_rows,
      'warnings',
        public._irrigation_warnings_from_stats(
          v_stats.total_sessions, v_stats.sessions_without_allocation,
          v_stats.sessions_missing_area, v_stats.sessions_missing_vines,
          v_stats.sessions_missing_efficiency, v_stats.sessions_estimated,
          v_stats.blocks_missing_variety)
        || public._irrigation_rainfall_warnings(p_vineyard_id, v_from, v_to)));
end;
$$;

create or replace function public.get_irrigation_daily_report(
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
  p_include_reversed boolean default false,
  p_include_zero_days boolean default false
) returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public._irrigation_period_report(
    'daily_summary', 'day', p_include_zero_days,
    p_vineyard_id, p_vintage_year, p_date_from, p_date_to, p_system_id,
    p_water_source, p_valve_id, p_block_id, p_variety_id, p_source_type,
    p_source_group, p_calculation_method, p_measurement_group,
    p_include_estimated, p_include_imported, p_include_reversed);
$$;

-- Week definition: ISO weeks (Monday start), consistent for Australia (§14).
create or replace function public.get_irrigation_weekly_summary(
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
  p_include_reversed boolean default false,
  p_include_zero_weeks boolean default false
) returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public._irrigation_period_report(
    'weekly_summary', 'week', p_include_zero_weeks,
    p_vineyard_id, p_vintage_year, p_date_from, p_date_to, p_system_id,
    p_water_source, p_valve_id, p_block_id, p_variety_id, p_source_type,
    p_source_group, p_calculation_method, p_measurement_group,
    p_include_estimated, p_include_imported, p_include_reversed);
$$;

-- Monthly report: every month in the vintage (zero months included by
-- default), with previous-vintage month comparison (§15).
create or replace function public.get_irrigation_monthly_report(
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
  v_base jsonb;
  v_vintage integer;
  v_prev_start date;
  v_prev_end date;
  v_rows jsonb;
begin
  v_base := public._irrigation_period_report(
    'monthly_summary', 'month', true,
    p_vineyard_id, p_vintage_year, p_date_from, p_date_to, p_system_id,
    p_water_source, p_valve_id, p_block_id, p_variety_id, p_source_type,
    p_source_group, p_calculation_method, p_measurement_group,
    p_include_estimated, p_include_imported, p_include_reversed);

  v_vintage := (v_base->>'vintage_year')::integer;
  select vp.period_start, vp.period_end into v_prev_start, v_prev_end
  from public._irrigation_vintage_period(p_vineyard_id, v_vintage - 1) vp;

  -- Append previous-vintage comparison per month (same calendar month, one
  -- vintage earlier), plus month labels + per-ha/per-vine normalisation.
  with rows_in as (
    select value as r from jsonb_array_elements(v_base->'rows')
  ),
  prev as (
    select date_trunc('month', b.session_date)::date as pstart,
           sum(b.allocated_litres) filter (where b.serviced_area_m2 is not null) as vol,
           null::numeric as unused
    from public._irrigation_report_blocks(
      p_vineyard_id, v_vintage - 1, null, null, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed) b
    group by 1
  ),
  prev_sessions as (
    select date_trunc('month', s.session_date)::date as pstart,
           sum(s.total_litres) as total
    from public._irrigation_report_sessions(
      p_vineyard_id, v_vintage - 1, null, null, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed) s
    group by 1
  ),
  prev_depth as (
    select pstart,
           case when sum(area) > 0 then round(sum(vol) / sum(area), 3) else null end as depth_mm
    from (
      select date_trunc('month', b.session_date)::date as pstart, b.block_id,
             sum(b.allocated_litres) filter (where b.serviced_area_m2 is not null) as vol,
             max(b.serviced_area_m2) as area
      from public._irrigation_report_blocks(
        p_vineyard_id, v_vintage - 1, null, null, p_system_id, p_water_source,
        p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
        p_calculation_method, p_measurement_group, p_include_estimated,
        p_include_imported, p_include_reversed) b
      group by 1, 2
    ) pb
    group by pstart
  ),
  cur_norm as (
    select pstart,
           case when sum(area) > 0
                then round(sum(vol) / (sum(area) / 10000.0), 2) else null end as lph,
           case when sum(vines) > 0
                then round(sum(vvol) / sum(vines), 3) else null end as lpv,
           case when sum(area) > 0
                then round(sum(area) / 10000.0, 4) else null end as area_ha
    from (
      select date_trunc('month', b.session_date)::date as pstart, b.block_id,
             sum(b.allocated_litres) filter (where b.serviced_area_m2 is not null) as vol,
             sum(b.allocated_litres) filter (where b.serviced_vine_count is not null) as vvol,
             max(b.serviced_area_m2) as area,
             max(b.serviced_vine_count) as vines
      from public._irrigation_report_blocks(
        p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
        p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
        p_calculation_method, p_measurement_group, p_include_estimated,
        p_include_imported, p_include_reversed) b
      group by 1, 2
    ) cb
    group by pstart
  )
  select jsonb_agg(
    ri.r
    || jsonb_build_object(
      'month_key', ri.r->>'period_key',
      'month_label', to_char((ri.r->>'period_start')::date, 'FMMonth YYYY'),
      'month_start', ri.r->'period_start',
      'month_end', ri.r->'period_end',
      'serviced_area_hectares', cn.area_ha,
      'litres_per_hectare', cn.lph,
      'litres_per_vine', cn.lpv,
      'previous_vintage_total_litres', coalesce(ps.total, 0),
      'previous_vintage_depth_mm', pd.depth_mm,
      'difference_litres', (ri.r->>'total_litres')::numeric - coalesce(ps.total, 0),
      'difference_percent',
        public._irrigation_pct_diff((ri.r->>'total_litres')::numeric, ps.total))
    order by (ri.r->>'period_start')::date)
  into v_rows
  from rows_in ri
  left join cur_norm cn on cn.pstart = (ri.r->>'period_start')::date
  left join prev_sessions ps
    on ps.pstart = ((ri.r->>'period_start')::date - interval '1 year')::date
  left join prev_depth pd
    on pd.pstart = ((ri.r->>'period_start')::date - interval '1 year')::date;

  return v_base || jsonb_build_object('rows', coalesce(v_rows, '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Valve report (§16)
-- ---------------------------------------------------------------------------

create or replace function public.get_irrigation_valve_report(
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
  v_rows jsonb;
  v_grand numeric;
  v_stats record;
  v_filters jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  select vp.period_start, vp.period_end into v_start, v_end
  from public._irrigation_vintage_period(p_vineyard_id, v_vintage) vp;

  with s as (
    select * from public._irrigation_report_sessions(
      p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed)
  ),
  g as (
    select s.valve_id,
           count(*)::integer as sessions,
           sum(s.total_litres) as total,
           count(*) filter (where s.effective_litres is null) as eff_missing,
           sum(s.effective_litres) as eff_sum,
           sum(s.duration_minutes)::integer as runtime,
           round(avg(s.duration_minutes), 1) as avg_minutes,
           sum(s.total_litres) filter (where s.source_group = 'manual') as manual,
           sum(s.total_litres) filter (where s.source_group = 'controller_import') as imported,
           sum(s.total_litres) filter (where s.measurement_group = 'estimated') as estimated,
           sum(s.total_litres) filter (where s.measurement_group = 'directly_reported') as reported,
           min(s.session_date) as first_use,
           max(s.session_date) as last_use
    from s
    group by s.valve_id
  ),
  blocks as (
    select b.valve_id, count(distinct b.block_id)::integer as blocks_supplied
    from public._irrigation_report_blocks(
      p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed) b
    group by b.valve_id
  ),
  config as (
    select vb.valve_id,
           case when count(distinct vb.allocation_method) = 1
                then min(vb.allocation_method)
                when count(*) > 0 then 'mixed' else null end as allocation_method,
           sum(vb.row_end - vb.row_start + 1)
             filter (where vb.row_start is not null and vb.row_end is not null) as rows_supplied
    from public.irrigation_valve_blocks vb
    where vb.vineyard_id = p_vineyard_id and vb.is_active
    group by vb.valve_id
  )
  select coalesce(sum(g.total), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'valve_id', v.id,
           'valve_name', v.name,
           'valve_number', v.valve_number,
           'system_id', v.irrigation_system_id,
           'system_name', sys.name,
           'water_source', sys.water_source,
           'allocation_method', c.allocation_method,
           'automatic_flow_source',
             case when v.measured_flow_litres_per_hour is not null then 'measured_valve_flow'
                  when v.configured_flow_litres_per_hour is not null then 'configured_valve_flow'
                  else null end,
           'session_count', g.sessions,
           'total_litres', g.total,
           'effective_litres',
             case when g.sessions > 0 and g.eff_missing = 0 then round(g.eff_sum, 1) else null end,
           'runtime_minutes', g.runtime,
           'average_session_minutes', g.avg_minutes,
           'average_flow_litres_per_hour',
             case when g.runtime > 0 then round(g.total / (g.runtime / 60.0), 1) else null end,
           'manual_litres', coalesce(g.manual, 0),
           'imported_litres', coalesce(g.imported, 0),
           'estimated_litres', coalesce(g.estimated, 0),
           'directly_reported_litres', coalesce(g.reported, 0),
           'blocks_supplied', coalesce(bl.blocks_supplied, 0),
           'rows_supplied', c.rows_supplied,
           'first_use', g.first_use,
           'last_use', g.last_use,
           'days_since_last_use', (current_date - g.last_use),
           'percent_of_vineyard_total', null,
           'warnings', case when g.eff_missing > 0 then jsonb_build_array(jsonb_build_object(
               'code', 'missing_irrigation_efficiency', 'severity', 'warning',
               'message', format('%s session(s) on this valve have no frozen efficiency.', g.eff_missing),
               'affected_count', g.eff_missing)) else '[]'::jsonb end
         ) order by v.name), '[]'::jsonb)
  into v_grand, v_rows
  from g
  join public.irrigation_valves v on v.id = g.valve_id
  join public.irrigation_systems sys on sys.id = v.irrigation_system_id
  left join blocks bl on bl.valve_id = g.valve_id
  left join config c on c.valve_id = g.valve_id;

  -- Fill percent_of_vineyard_total now that the grand total is known.
  if v_grand > 0 then
    select jsonb_agg(
      r || jsonb_build_object('percent_of_vineyard_total',
        round((r->>'total_litres')::numeric / v_grand * 100.0, 1))
      order by r->>'valve_name')
    into v_rows
    from jsonb_array_elements(v_rows) r;
  end if;

  select * into v_stats from public._irrigation_report_stats(
    p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed);

  v_filters := jsonb_build_object(
    'vintage_year', v_vintage, 'date_from', p_date_from, 'date_to', p_date_to,
    'system_id', p_system_id, 'water_source', p_water_source,
    'valve_id', p_valve_id, 'block_id', p_block_id, 'variety_id', p_variety_id,
    'source_type', p_source_type, 'source_group', p_source_group,
    'calculation_method', p_calculation_method, 'measurement_group', p_measurement_group,
    'include_estimated', p_include_estimated, 'include_imported', p_include_imported,
    'include_reversed', p_include_reversed);

  return public._irrigation_report_envelope(
    'valve_summary', p_vineyard_id, v_vintage, v_start, v_end, v_filters,
    jsonb_build_object(
      'total_litres', v_grand,
      'rows', coalesce(v_rows, '[]'::jsonb),
      'warnings', public._irrigation_warnings_from_stats(
        v_stats.total_sessions, v_stats.sessions_without_allocation,
        v_stats.sessions_missing_area, v_stats.sessions_missing_vines,
        v_stats.sessions_missing_efficiency, v_stats.sessions_estimated,
        v_stats.blocks_missing_variety)));
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Block report (§17)
-- ---------------------------------------------------------------------------

create or replace function public.get_irrigation_block_report(
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
  v_from date;
  v_to date;
  v_rows jsonb;
  v_rain numeric;
  v_stats record;
  v_filters jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  select vp.period_start, vp.period_end into v_start, v_end
  from public._irrigation_vintage_period(p_vineyard_id, v_vintage) vp;
  v_from := coalesce(p_date_from, v_start);
  v_to := coalesce(p_date_to, v_end);

  select round(sum(rb.rainfall_mm), 1) into v_rain
  from public._irrigation_rainfall_best(p_vineyard_id, v_from, v_to) rb;

  with b as (
    select * from public._irrigation_report_blocks(
      p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed)
  ),
  latest as (
    select distinct on (block_id) block_id, variety_id, variety_name,
           serviced_area_m2, serviced_vine_count
    from b order by block_id, session_date desc
  ),
  runtime as (
    select block_id, sum(duration_minutes)::integer as runtime
    from (select distinct b.block_id, b.session_id, b.duration_minutes from b) x
    group by block_id
  ),
  g as (
    select b.block_id,
           count(distinct b.session_id)::integer as sessions,
           sum(b.allocated_litres) as total,
           count(*) filter (where b.effective_litres is null) as eff_missing,
           sum(b.effective_litres) as eff_sum,
           sum(b.allocated_litres) filter (where b.serviced_area_m2 is not null) as area_vol,
           sum(b.effective_litres) filter (where b.serviced_area_m2 is not null) as eff_area_vol,
           count(*) filter (where b.serviced_area_m2 is not null
                              and b.effective_litres is null) as eff_area_missing,
           sum(b.allocated_litres) filter (where b.serviced_vine_count is not null) as vine_vol,
           sum(b.allocated_litres) filter (where b.source_group = 'manual') as manual,
           sum(b.allocated_litres) filter (where b.source_group = 'controller_import') as imported,
           sum(b.allocated_litres) filter (where b.measurement_group = 'estimated') as estimated,
           min(b.session_date) as first_date,
           max(b.session_date) as last_date
    from b
    group by b.block_id
  ),
  prev as (
    select pb.block_id, sum(pb.allocated_litres) as total
    from public._irrigation_report_blocks(
      p_vineyard_id, v_vintage - 1, null, null, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed) pb
    group by pb.block_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'block_id', g.block_id,
      'block_name', p.name,
      'variety_id', lt.variety_id,
      'variety_name', lt.variety_name,
      'session_count', g.sessions,
      'total_litres', g.total,
      'effective_litres',
        case when g.eff_missing = 0 then round(g.eff_sum, 1) else null end,
      'runtime_minutes', rt.runtime,
      'serviced_area_hectares',
        case when lt.serviced_area_m2 > 0 then round(lt.serviced_area_m2 / 10000.0, 4) else null end,
      'serviced_vines', lt.serviced_vine_count,
      'litres_per_hectare',
        case when lt.serviced_area_m2 > 0
             then round(g.area_vol / (lt.serviced_area_m2 / 10000.0), 2) else null end,
      'litres_per_vine',
        case when lt.serviced_vine_count > 0
             then round(g.vine_vol / lt.serviced_vine_count, 3) else null end,
      'irrigation_depth_mm',
        case when lt.serviced_area_m2 > 0
             then round(g.area_vol / lt.serviced_area_m2, 3) else null end,
      'effective_depth_mm',
        case when lt.serviced_area_m2 > 0 and g.eff_area_missing = 0 and g.eff_area_vol is not null
             then round(g.eff_area_vol / lt.serviced_area_m2, 3) else null end,
      'rainfall_mm', v_rain,
      'combined_water_input_mm',
        case when v_rain is not null and lt.serviced_area_m2 > 0
             then round(v_rain + g.area_vol / lt.serviced_area_m2, 3) else null end,
      'manual_litres', coalesce(g.manual, 0),
      'imported_litres', coalesce(g.imported, 0),
      'estimated_litres', coalesce(g.estimated, 0),
      'first_irrigation_date', g.first_date,
      'last_irrigation_date', g.last_date,
      'days_since_last_irrigation', (current_date - g.last_date),
      'previous_vintage_litres', coalesce(pv.total, 0),
      'difference_litres', g.total - coalesce(pv.total, 0),
      'difference_percent', public._irrigation_pct_diff(g.total, pv.total),
      'warnings', case when lt.serviced_area_m2 is null then jsonb_build_array(jsonb_build_object(
          'code', 'missing_serviced_area', 'severity', 'warning',
          'message', 'This block has no saved serviced area; depth and per-hectare figures are unavailable.',
          'affected_count', g.sessions)) else '[]'::jsonb end
    ) order by p.name), '[]'::jsonb)
  into v_rows
  from g
  join latest lt on lt.block_id = g.block_id
  left join runtime rt on rt.block_id = g.block_id
  left join prev pv on pv.block_id = g.block_id
  join public.paddocks p on p.id = g.block_id;

  select * into v_stats from public._irrigation_report_stats(
    p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed);

  v_filters := jsonb_build_object(
    'vintage_year', v_vintage, 'date_from', p_date_from, 'date_to', p_date_to,
    'system_id', p_system_id, 'water_source', p_water_source,
    'valve_id', p_valve_id, 'block_id', p_block_id, 'variety_id', p_variety_id,
    'source_type', p_source_type, 'source_group', p_source_group,
    'calculation_method', p_calculation_method, 'measurement_group', p_measurement_group,
    'include_estimated', p_include_estimated, 'include_imported', p_include_imported,
    'include_reversed', p_include_reversed);

  return public._irrigation_report_envelope(
    'block_summary', p_vineyard_id, v_vintage, v_start, v_end, v_filters,
    jsonb_build_object(
      'rows', v_rows,
      'warnings',
        public._irrigation_warnings_from_stats(
          v_stats.total_sessions, v_stats.sessions_without_allocation,
          v_stats.sessions_missing_area, v_stats.sessions_missing_vines,
          v_stats.sessions_missing_efficiency, v_stats.sessions_estimated,
          v_stats.blocks_missing_variety)
        || public._irrigation_rainfall_warnings(p_vineyard_id, v_from, v_to)));
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Variety report (§18) — weighted aggregation, never averaged averages.
-- ---------------------------------------------------------------------------

create or replace function public.get_irrigation_variety_report(
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
  v_from date;
  v_to date;
  v_rows jsonb;
  v_rain numeric;
  v_stats record;
  v_filters jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  select vp.period_start, vp.period_end into v_start, v_end
  from public._irrigation_vintage_period(p_vineyard_id, v_vintage) vp;
  v_from := coalesce(p_date_from, v_start);
  v_to := coalesce(p_date_to, v_end);

  select round(sum(rb.rainfall_mm), 1) into v_rain
  from public._irrigation_rainfall_best(p_vineyard_id, v_from, v_to) rb;

  with b as (
    select coalesce(bb.variety_name, 'Unassigned') as variety,
           bb.variety_id, bb.session_id, bb.session_date, bb.block_id,
           bb.allocated_litres, bb.effective_litres, bb.serviced_area_m2,
           bb.serviced_vine_count, bb.source_group, bb.measurement_group
    from public._irrigation_report_blocks(
      p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed) bb
  ),
  latest as (
    select distinct on (block_id) block_id, variety,
           serviced_area_m2, serviced_vine_count
    from b order by block_id, session_date desc
  ),
  scale as (
    select variety,
           sum(serviced_area_m2) filter (where serviced_area_m2 > 0) as area_m2,
           sum(serviced_vine_count) filter (where serviced_vine_count > 0) as vines
    from latest
    group by variety
  ),
  g as (
    select b.variety,
           min(b.variety_id::text)::uuid as variety_id,
           count(distinct b.block_id)::integer as blocks,
           count(distinct b.session_id)::integer as sessions,
           sum(b.allocated_litres) as total,
           count(*) filter (where b.effective_litres is null) as eff_missing,
           sum(b.effective_litres) as eff_sum,
           sum(b.allocated_litres) filter (where b.serviced_area_m2 is not null) as area_vol,
           sum(b.effective_litres) filter (where b.serviced_area_m2 is not null) as eff_area_vol,
           count(*) filter (where b.serviced_area_m2 is not null
                              and b.effective_litres is null) as eff_area_missing,
           sum(b.allocated_litres) filter (where b.serviced_vine_count is not null) as vine_vol,
           sum(b.allocated_litres) filter (where b.source_group = 'manual') as manual,
           sum(b.allocated_litres) filter (where b.source_group = 'controller_import') as imported
    from b
    group by b.variety
  ),
  prev as (
    select coalesce(pb.variety_name, 'Unassigned') as variety,
           sum(pb.allocated_litres) as total
    from public._irrigation_report_blocks(
      p_vineyard_id, v_vintage - 1, null, null, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed) pb
    group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'variety_id', g.variety_id,
      'variety_name', g.variety,
      'block_count', g.blocks,
      'session_count', g.sessions,
      'total_litres', g.total,
      'effective_litres',
        case when g.eff_missing = 0 then round(g.eff_sum, 1) else null end,
      'serviced_area_hectares',
        case when sc.area_m2 > 0 then round(sc.area_m2 / 10000.0, 4) else null end,
      'serviced_vines', sc.vines,
      'litres_per_hectare',
        case when sc.area_m2 > 0 then round(g.area_vol / (sc.area_m2 / 10000.0), 2) else null end,
      'litres_per_vine',
        case when sc.vines > 0 then round(g.vine_vol / sc.vines, 3) else null end,
      'irrigation_depth_mm',
        case when sc.area_m2 > 0 then round(g.area_vol / sc.area_m2, 3) else null end,
      'effective_depth_mm',
        case when sc.area_m2 > 0 and g.eff_area_missing = 0 and g.eff_area_vol is not null
             then round(g.eff_area_vol / sc.area_m2, 3) else null end,
      'rainfall_mm', v_rain,
      'combined_water_input_mm',
        case when v_rain is not null and sc.area_m2 > 0
             then round(v_rain + g.area_vol / sc.area_m2, 3) else null end,
      'manual_litres', coalesce(g.manual, 0),
      'imported_litres', coalesce(g.imported, 0),
      'previous_vintage_litres', coalesce(pv.total, 0),
      'difference_litres', g.total - coalesce(pv.total, 0),
      'difference_percent', public._irrigation_pct_diff(g.total, pv.total),
      'warnings', case when g.variety = 'Unassigned' then jsonb_build_array(jsonb_build_object(
          'code', 'unknown_variety', 'severity', 'info',
          'message', 'These blocks have no variety assignment; totals reconcile to the block report, not to a variety.',
          'affected_count', g.blocks)) else '[]'::jsonb end
    ) order by g.variety), '[]'::jsonb)
  into v_rows
  from g
  join scale sc on sc.variety = g.variety
  left join prev pv on pv.variety = g.variety;

  select * into v_stats from public._irrigation_report_stats(
    p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed);

  v_filters := jsonb_build_object(
    'vintage_year', v_vintage, 'date_from', p_date_from, 'date_to', p_date_to,
    'system_id', p_system_id, 'water_source', p_water_source,
    'valve_id', p_valve_id, 'block_id', p_block_id, 'variety_id', p_variety_id,
    'source_type', p_source_type, 'source_group', p_source_group,
    'calculation_method', p_calculation_method, 'measurement_group', p_measurement_group,
    'include_estimated', p_include_estimated, 'include_imported', p_include_imported,
    'include_reversed', p_include_reversed);

  return public._irrigation_report_envelope(
    'variety_summary', p_vineyard_id, v_vintage, v_start, v_end, v_filters,
    jsonb_build_object(
      'rows', v_rows,
      'warnings',
        public._irrigation_warnings_from_stats(
          v_stats.total_sessions, v_stats.sessions_without_allocation,
          v_stats.sessions_missing_area, v_stats.sessions_missing_vines,
          v_stats.sessions_missing_efficiency, v_stats.sessions_estimated,
          v_stats.blocks_missing_variety)
        || public._irrigation_rainfall_warnings(p_vineyard_id, v_from, v_to)));
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. Water-source (§19), calculation-source (§20), record-source (§21)
-- ---------------------------------------------------------------------------

create or replace function public.get_irrigation_water_source_summary(
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
  v_rows jsonb;
  v_grand numeric;
  v_unspecified integer;
  v_filters jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  select vp.period_start, vp.period_end into v_start, v_end
  from public._irrigation_vintage_period(p_vineyard_id, v_vintage) vp;

  with s as (
    select * from public._irrigation_report_sessions(
      p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed)
  ),
  g as (
    select coalesce(s.water_source, 'unspecified') as water_source,
           (s.water_source is null) as is_unspecified,
           count(distinct s.system_id)::integer as systems,
           count(distinct s.valve_id)::integer as valves,
           count(*)::integer as sessions,
           sum(s.total_litres) as total,
           count(*) filter (where s.effective_litres is null) as eff_missing,
           sum(s.effective_litres) as eff_sum,
           sum(s.duration_minutes)::integer as runtime,
           sum(s.total_litres) filter (where s.source_group = 'manual') as manual,
           sum(s.total_litres) filter (where s.source_group = 'controller_import') as imported,
           sum(s.total_litres) filter (where s.measurement_group = 'estimated') as estimated,
           sum(s.total_litres) filter (where s.measurement_group = 'directly_reported') as reported,
           min(s.session_date) as first_use,
           max(s.session_date) as last_use
    from s
    group by 1, 2
  )
  select coalesce(sum(g.total), 0),
         coalesce(sum(g.sessions) filter (where g.is_unspecified), 0)::integer,
         coalesce(jsonb_agg(jsonb_build_object(
           'water_source', g.water_source,
           'system_count', g.systems,
           'valve_count', g.valves,
           'session_count', g.sessions,
           'total_litres', g.total,
           'effective_litres',
             case when g.eff_missing = 0 then round(g.eff_sum, 1) else null end,
           'runtime_minutes', g.runtime,
           'percent_of_vineyard_total', null,
           'manual_litres', coalesce(g.manual, 0),
           'imported_litres', coalesce(g.imported, 0),
           'estimated_litres', coalesce(g.estimated, 0),
           'directly_reported_litres', coalesce(g.reported, 0),
           'first_use', g.first_use,
           'last_use', g.last_use,
           'warnings', '[]'::jsonb
         ) order by g.water_source), '[]'::jsonb)
  into v_grand, v_unspecified, v_rows
  from g;

  if v_grand > 0 then
    select jsonb_agg(
      r || jsonb_build_object('percent_of_vineyard_total',
        round((r->>'total_litres')::numeric / v_grand * 100.0, 1))
      order by r->>'water_source')
    into v_rows
    from jsonb_array_elements(v_rows) r;
  end if;

  v_filters := jsonb_build_object(
    'vintage_year', v_vintage, 'date_from', p_date_from, 'date_to', p_date_to,
    'system_id', p_system_id, 'water_source', p_water_source,
    'valve_id', p_valve_id, 'block_id', p_block_id, 'variety_id', p_variety_id,
    'source_type', p_source_type, 'source_group', p_source_group,
    'calculation_method', p_calculation_method, 'measurement_group', p_measurement_group,
    'include_estimated', p_include_estimated, 'include_imported', p_include_imported,
    'include_reversed', p_include_reversed);

  return public._irrigation_report_envelope(
    'water_source_summary', p_vineyard_id, v_vintage, v_start, v_end, v_filters,
    jsonb_build_object(
      'total_litres', v_grand,
      'rows', coalesce(v_rows, '[]'::jsonb),
      'warnings', case when v_unspecified > 0 then jsonb_build_array(jsonb_build_object(
        'code', 'missing_water_source', 'severity', 'warning',
        'message', format('%s session(s) belong to irrigation systems without a water source.', v_unspecified),
        'affected_count', v_unspecified)) else '[]'::jsonb end));
end;
$$;

create or replace function public.get_irrigation_calculation_source_summary(
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
  v_rows jsonb;
  v_grand numeric;
  v_filters jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  select vp.period_start, vp.period_end into v_start, v_end
  from public._irrigation_vintage_period(p_vineyard_id, v_vintage) vp;

  with s as (
    select * from public._irrigation_report_sessions(
      p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed)
  ),
  g as (
    select s.calculation_method, s.measurement_group,
           count(*)::integer as sessions,
           sum(s.total_litres) as total,
           sum(s.duration_minutes)::integer as runtime
    from s
    group by 1, 2
  )
  select coalesce(sum(g.total), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'calculation_method', g.calculation_method,
           'calculation_label', public._irrigation_calc_label(g.calculation_method),
           'measurement_group', g.measurement_group,
           'measurement_label', public._irrigation_measurement_label(g.measurement_group),
           'session_count', g.sessions,
           'total_litres', g.total,
           'percent_of_total_litres', null,
           'runtime_minutes', g.runtime
         ) order by g.calculation_method, g.measurement_group), '[]'::jsonb)
  into v_grand, v_rows
  from g;

  if v_grand > 0 then
    select jsonb_agg(
      r || jsonb_build_object('percent_of_total_litres',
        round((r->>'total_litres')::numeric / v_grand * 100.0, 1))
      order by r->>'calculation_method')
    into v_rows
    from jsonb_array_elements(v_rows) r;
  end if;

  v_filters := jsonb_build_object(
    'vintage_year', v_vintage, 'date_from', p_date_from, 'date_to', p_date_to,
    'system_id', p_system_id, 'water_source', p_water_source,
    'valve_id', p_valve_id, 'block_id', p_block_id, 'variety_id', p_variety_id,
    'source_type', p_source_type, 'source_group', p_source_group,
    'calculation_method', p_calculation_method, 'measurement_group', p_measurement_group,
    'include_estimated', p_include_estimated, 'include_imported', p_include_imported,
    'include_reversed', p_include_reversed);

  return public._irrigation_report_envelope(
    'calculation_source_summary', p_vineyard_id, v_vintage, v_start, v_end, v_filters,
    jsonb_build_object('total_litres', v_grand,
                       'rows', coalesce(v_rows, '[]'::jsonb),
                       'warnings', '[]'::jsonb));
end;
$$;

create or replace function public.get_irrigation_record_source_summary(
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
  v_rows jsonb;
  v_grand numeric;
  v_filters jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  select vp.period_start, vp.period_end into v_start, v_end
  from public._irrigation_vintage_period(p_vineyard_id, v_vintage) vp;

  with s as (
    select * from public._irrigation_report_sessions(
      p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed)
  ),
  g as (
    select s.source_type, s.source_group,
           count(*)::integer as sessions,
           sum(s.total_litres) as total,
           min(s.created_at) as first_recorded,
           max(s.created_at) as last_recorded
    from s
    group by 1, 2
  )
  select coalesce(sum(g.total), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'source_type', g.source_type,
           'source_label', public._irrigation_source_label(g.source_type),
           'source_group', g.source_group,
           'session_count', g.sessions,
           'total_litres', g.total,
           'percent_of_total_litres', null,
           'first_recorded_at', g.first_recorded,
           'last_recorded_at', g.last_recorded
         ) order by g.source_type), '[]'::jsonb)
  into v_grand, v_rows
  from g;

  if v_grand > 0 then
    select jsonb_agg(
      r || jsonb_build_object('percent_of_total_litres',
        round((r->>'total_litres')::numeric / v_grand * 100.0, 1))
      order by r->>'source_type')
    into v_rows
    from jsonb_array_elements(v_rows) r;
  end if;

  v_filters := jsonb_build_object(
    'vintage_year', v_vintage, 'date_from', p_date_from, 'date_to', p_date_to,
    'system_id', p_system_id, 'water_source', p_water_source,
    'valve_id', p_valve_id, 'block_id', p_block_id, 'variety_id', p_variety_id,
    'source_type', p_source_type, 'source_group', p_source_group,
    'calculation_method', p_calculation_method, 'measurement_group', p_measurement_group,
    'include_estimated', p_include_estimated, 'include_imported', p_include_imported,
    'include_reversed', p_include_reversed);

  return public._irrigation_report_envelope(
    'record_source_summary', p_vineyard_id, v_vintage, v_start, v_end, v_filters,
    jsonb_build_object('total_litres', v_grand,
                       'rows', coalesce(v_rows, '[]'::jsonb),
                       'warnings', '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. Rainfall vs irrigation comparison (§12)
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
      select sum(rb.rainfall_mm) as rainfall_mm, count(*)::integer as rain_days
      from public._irrigation_rainfall_best(p_vineyard_id, v_from, v_to) rb
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
        'rainfall_data_complete', coalesce(rn.rain_days, 0) = (v_to - v_from + 1)))
    into v_rows
    from depth d cross join rain rn;
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
           (r->>'rainfall_data_complete')::boolean as rain_complete
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
      'rainfall_data_complete', rain_complete
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
-- 13. Multi-vintage trends (§22)
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
  v_rain_days integer;
  v_days integer;
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
    v_days := greatest(v_end - v_start + 1, 1);

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

    select round(sum(rb.rainfall_mm), 1), count(*)::integer
    into v_rain, v_rain_days
    from public._irrigation_rainfall_best(p_vineyard_id, v_start, v_end) rb;

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
      'combined_water_input_mm',
        case when v_rain is not null and v_area.area_m2 > 0
             then round(v_rain + v_area.area_vol / v_area.area_m2, 3) else null end,
      'data_quality', public._irrigation_data_quality(
        v_stats.total_sessions, v_stats.sessions_missing_area,
        v_stats.sessions_missing_vines, v_stats.sessions_missing_efficiency,
        (v_rain_days = v_days)),
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
-- 14. Drill-down contract (§23) — reuses the existing session-detail model.
-- ---------------------------------------------------------------------------

create or replace function public.list_irrigation_report_sessions(
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
  p_include_reversed boolean default false,
  p_limit integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vintage integer;
  v_total integer;
  v_sessions jsonb;
  v_limit integer;
begin
  perform public._irrigation_require_access(p_vineyard_id);
  v_vintage := coalesce(p_vintage_year,
                        public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
  v_limit := least(greatest(coalesce(p_limit, 50), 1), 200);

  select count(*)::integer into v_total
  from public._irrigation_report_sessions(
    p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed);

  select coalesce(jsonb_agg(row_json), '[]'::jsonb) into v_sessions
  from (
    select public._irrigation_session_json(rs.session_id)
           || jsonb_build_object(
                'source_group', rs.source_group,
                'source_label', public._irrigation_source_label(rs.source_type),
                'measurement_group', rs.measurement_group,
                'calculation_label', public._irrigation_calc_label(rs.calculation_method))
           as row_json
    from public._irrigation_report_sessions(
      p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed) rs
    order by rs.session_date desc, rs.created_at desc
    limit v_limit
    offset greatest(coalesce(p_offset, 0), 0)
  ) rows;

  return jsonb_build_object(
    'sessions', v_sessions,
    'total_count', v_total,
    'vintage_year', v_vintage,
    'generated_at', now());
end;
$$;

-- ---------------------------------------------------------------------------
-- 15. Grants — RPCs to authenticated (each self-gates on System Admin +
--     membership); helpers locked down.
-- ---------------------------------------------------------------------------

do $$
declare
  fn text;
begin
  foreach fn in array array[
    '_irrigation_source_group(text)',
    '_irrigation_source_label(text)',
    '_irrigation_calc_label(text)',
    '_irrigation_measurement_group(text, boolean)',
    '_irrigation_measurement_label(text)',
    '_irrigation_safe_season_date(integer, integer, integer)',
    '_irrigation_vintage_period(uuid, integer)',
    '_irrigation_report_timezone(uuid)',
    '_irrigation_report_unit_context()',
    '_irrigation_report_envelope(text, uuid, integer, date, date, jsonb, jsonb)',
    '_irrigation_report_sessions(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    '_irrigation_report_blocks(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    '_irrigation_rainfall_best(uuid, date, date)',
    '_irrigation_report_stats(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    '_irrigation_warnings_from_stats(integer, integer, integer, integer, integer, integer, integer)',
    '_irrigation_rainfall_warnings(uuid, date, date)',
    '_irrigation_data_quality(integer, integer, integer, integer, boolean)',
    '_irrigation_pct_diff(numeric, numeric)',
    '_irrigation_period_rows(text, boolean, uuid, integer, date, date, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    '_irrigation_period_report(text, text, boolean, uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)'
  ]
  loop
    execute format('revoke all on function public.%s from public, anon, authenticated', fn);
  end loop;

  foreach fn in array array[
    'get_irrigation_vintage_overview(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    'get_irrigation_daily_report(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean, boolean)',
    'get_irrigation_weekly_summary(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean, boolean)',
    'get_irrigation_monthly_report(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    'get_irrigation_valve_report(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    'get_irrigation_block_report(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    'get_irrigation_variety_report(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    'get_irrigation_water_source_summary(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    'get_irrigation_calculation_source_summary(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    'get_irrigation_record_source_summary(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    'get_irrigation_rainfall_summary(uuid, integer, text, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    'get_irrigation_vintage_trends(uuid, integer, integer, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean)',
    'list_irrigation_report_sessions(uuid, integer, date, date, uuid, text, uuid, uuid, uuid, text, text, text, text, boolean, boolean, boolean, integer, integer)'
  ]
  loop
    execute format('revoke all on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;

-- =============================================================================
-- VERIFICATION (run after applying)
--   select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and proname in (
--     'get_irrigation_vintage_overview','get_irrigation_daily_report',
--     'get_irrigation_weekly_summary','get_irrigation_monthly_report',
--     'get_irrigation_valve_report','get_irrigation_block_report',
--     'get_irrigation_variety_report','get_irrigation_water_source_summary',
--     'get_irrigation_calculation_source_summary',
--     'get_irrigation_record_source_summary','get_irrigation_rainfall_summary',
--     'get_irrigation_vintage_trends','list_irrigation_report_sessions');
--   -- expect 13 rows. Then run sql/tests/147_irrigation_reporting_tests.sql
--   -- (single transaction, always rolled back).
--
-- ROLLBACK
--   Drop the 13 RPCs and the helpers listed in §15 (drop function public.<sig>),
--   then: drop index if exists irrigation_sessions_vineyard_vintage_date_idx;
--         drop index if exists irrigation_sessions_vineyard_source_idx;
--   No tables are created and no data is written by this migration —
--   historical sessions and snapshots are untouched.
-- =============================================================================

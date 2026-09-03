-- ============================================================================
-- 222 — Irrigation reporting scope: one selected vintage, or ALL vintages
--
-- STATUS: REVIEW ONLY. NOT APPLIED. Deliberately parked outside the applied
-- `sql/` sequence so it cannot be run by accident. Move it to
-- `sql/222_irrigation_report_scope.sql` only after sign-off.
--
-- ---------------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------------
-- Every other reporting surface in the app filters a season client-side: the
-- rows are already local, so "All vintages" simply means "apply no date
-- restriction". Irrigation is the one exception — its reports are server-paged
-- and server-computed (SQL 147), and each public report RPC begins with
--
--     v_vintage := coalesce(p_vintage_year,
--                           public.resolve_vineyard_vintage_year(...));
--
-- so a NULL vintage means "the current vintage", never "all of them". There is
-- no value the client can pass today that means all vintages, which is why the
-- Android Irrigation Records screen currently withholds the "All vintages"
-- chip rather than showing one vintage's numbers under an All heading.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES — AND WHAT IT DELIBERATELY DOES NOT
-- ---------------------------------------------------------------------------
-- Adds ONE new function. It does not touch a single existing one.
--
--   * No existing RPC is replaced, dropped, or given a new parameter, so the
--     NULL => current-vintage behaviour older clients depend on is bit-for-bit
--     unchanged. An older build that never learns this function exists keeps
--     working exactly as it does today.
--   * No new columns. No triggers. No backfills. No data is written or moved.
--   * No new access path: it calls the same `_irrigation_require_access()`
--     gate every other irrigation report RPC calls, and reads through the same
--     private `_irrigation_report_sessions()` dataset, so filters, exclusions
--     (reversed / deleted / estimated / imported) and RLS are identical.
--
-- The one thing it adds is an EXPLICIT scope argument:
--
--     p_scope = 'vintage'  -> a single vintage (p_vintage_year, or the current
--                             vintage when null — same rule as today)
--     p_scope = 'all'      -> no vintage restriction at all
--
-- 'all' is expressed by passing NULL down to `_irrigation_report_sessions`,
-- whose own `p_vintage_year is null` branch already means "no restriction".
-- That branch exists and is exercised today; nothing new is being invented at
-- the dataset level.
--
-- ---------------------------------------------------------------------------
-- WHY A TOTALS+BREAKDOWN SHAPE RATHER THAN 13 WRAPPERS
-- ---------------------------------------------------------------------------
-- SQL 147 exposes ~13 public report RPCs. Adding an all-vintages variant of
-- each would be thirteen new functions to keep in step forever. The screen
-- needs two things from an all-vintages view — headline totals, and a
-- per-vintage breakdown to show WHERE the water went — so this returns exactly
-- those, in the standard SQL 147 envelope. Per-valve/block/variety drilldowns
-- stay vintage-scoped, which is what an operator actually drills into.
--
-- It also returns `available_vintages`: every vintage that genuinely holds
-- non-deleted sessions for this vineyard, computed BEFORE any vintage filter
-- is applied. That is what drives the selector, and it is the server-side
-- counterpart of the client rule that selecting 2027 must never remove 2026
-- from the list.
--
-- ---------------------------------------------------------------------------
-- ROLLBACK
-- ---------------------------------------------------------------------------
--   drop function if exists public.get_irrigation_report_scope(
--     uuid, text, integer, date, date, uuid, text, uuid, uuid, uuid,
--     text, text, text, text, boolean, boolean, boolean);
-- Nothing else to undo — no state is created.
-- ============================================================================

begin;

create or replace function public.get_irrigation_report_scope(
  p_vineyard_id uuid,
  -- 'vintage' (default — today's behaviour) or 'all'.
  p_scope text default 'vintage',
  -- Honoured only when p_scope = 'vintage'. Null keeps the existing
  -- "current vintage" rule so this argument behaves like every other RPC's.
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
as $function$
declare
  v_scope text;
  v_vintage integer;      -- null when scope = 'all'
  v_start date;           -- null when scope = 'all'
  v_end date;             -- null when scope = 'all'
  v_tot record;
  v_available integer[];
  v_by_vintage jsonb;
  v_filters jsonb;
begin
  perform public._irrigation_require_access(p_vineyard_id);

  v_scope := lower(coalesce(nullif(btrim(p_scope), ''), 'vintage'));
  if v_scope not in ('vintage', 'all') then
    raise exception 'INVALID_SCOPE: p_scope must be ''vintage'' or ''all'', got %', p_scope;
  end if;

  if v_scope = 'vintage' then
    -- Identical resolution to every existing report RPC.
    v_vintage := coalesce(p_vintage_year,
                          public.resolve_vineyard_vintage_year(p_vineyard_id, current_date));
    select vp.period_start, vp.period_end into v_start, v_end
    from public._irrigation_vintage_period(p_vineyard_id, v_vintage) vp;
  end if;
  -- scope = 'all': v_vintage stays null, which _irrigation_report_sessions
  -- reads as "no vintage restriction". v_start/v_end stay null so the envelope
  -- reports an unbounded period rather than a misleading single-season range.

  -- Vintages that actually hold sessions, computed WITHOUT the vintage filter
  -- so the selector keeps offering every season regardless of which one is
  -- currently applied. Other filters (valve, block, source…) are intentionally
  -- NOT applied here either: the option list describes the surface, not the
  -- current query.
  select coalesce(array_agg(distinct s.vintage_year order by s.vintage_year desc), '{}')
  into v_available
  from public._irrigation_report_sessions(
    p_vineyard_id, null, null, null, null, null,
    null, null, null, null, null,
    null, null, true, true, p_include_reversed) s
  where s.vintage_year is not null;

  -- Headline totals for the requested scope.
  select
    count(*)::integer as sessions,
    coalesce(sum(s.total_litres), 0) as total_litres,
    sum(s.effective_litres) as effective_litres,
    count(*) filter (where s.effective_litres is null) as effective_missing,
    coalesce(sum(s.duration_minutes), 0)::integer as runtime_minutes,
    round(avg(s.total_litres), 1) as avg_litres,
    round(avg(s.duration_minutes), 1) as avg_minutes,
    min(s.session_date) as first_date,
    max(s.session_date) as last_date,
    count(distinct s.vintage_year)::integer as vintages_covered
  into v_tot
  from public._irrigation_report_sessions(
    p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
    p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
    p_calculation_method, p_measurement_group, p_include_estimated,
    p_include_imported, p_include_reversed) s;

  -- Per-vintage breakdown. Under 'vintage' scope this is a single row, which
  -- keeps the payload shape stable for the client either way.
  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.vintage_year desc), '[]'::jsonb)
  into v_by_vintage
  from (
    select
      s.vintage_year,
      count(*)::integer as sessions,
      coalesce(sum(s.total_litres), 0) as total_litres,
      sum(s.effective_litres) as effective_litres,
      coalesce(sum(s.duration_minutes), 0)::integer as runtime_minutes,
      min(s.session_date) as first_date,
      max(s.session_date) as last_date
    from public._irrigation_report_sessions(
      p_vineyard_id, v_vintage, p_date_from, p_date_to, p_system_id, p_water_source,
      p_valve_id, p_block_id, p_variety_id, p_source_type, p_source_group,
      p_calculation_method, p_measurement_group, p_include_estimated,
      p_include_imported, p_include_reversed) s
    where s.vintage_year is not null
    group by s.vintage_year
  ) t;

  v_filters := jsonb_build_object(
    'scope', v_scope,
    'vintage_year', v_vintage,
    'date_from', p_date_from,
    'date_to', p_date_to,
    'system_id', p_system_id,
    'water_source', p_water_source,
    'valve_id', p_valve_id,
    'block_id', p_block_id,
    'variety_id', p_variety_id,
    'source_type', p_source_type,
    'source_group', p_source_group,
    'calculation_method', p_calculation_method,
    'measurement_group', p_measurement_group,
    'include_estimated', p_include_estimated,
    'include_imported', p_include_imported,
    'include_reversed', p_include_reversed
  );

  return public._irrigation_report_envelope(
    'scope', p_vineyard_id, v_vintage, v_start, v_end, v_filters,
    jsonb_build_object(
      'scope', v_scope,
      'available_vintages', to_jsonb(v_available),
      'totals', jsonb_build_object(
        'sessions', coalesce(v_tot.sessions, 0),
        'total_litres', coalesce(v_tot.total_litres, 0),
        -- Null (not zero) when any session is missing an effective volume, so
        -- the apps render "—" rather than an understated total.
        'effective_litres', case when coalesce(v_tot.effective_missing, 0) > 0
                                 then null else v_tot.effective_litres end,
        'effective_is_complete', coalesce(v_tot.effective_missing, 0) = 0,
        'runtime_minutes', coalesce(v_tot.runtime_minutes, 0),
        'avg_litres', v_tot.avg_litres,
        'avg_minutes', v_tot.avg_minutes,
        'first_date', v_tot.first_date,
        'last_date', v_tot.last_date,
        'vintages_covered', coalesce(v_tot.vintages_covered, 0)
      ),
      'by_vintage', v_by_vintage
    )
  );
end;
$function$;

comment on function public.get_irrigation_report_scope(
  uuid, text, integer, date, date, uuid, text, uuid, uuid, uuid,
  text, text, text, text, boolean, boolean, boolean
) is
  'Additive irrigation reporting scope (222). p_scope=''vintage'' resolves a '
  'single vintage exactly as the SQL 147 report RPCs do (null => current); '
  'p_scope=''all'' applies no vintage restriction. Also returns every vintage '
  'holding sessions, computed before any vintage filter, to drive the season '
  'selector. Adds no columns, triggers or backfills and changes no existing '
  'function.';

revoke all on function public.get_irrigation_report_scope(
  uuid, text, integer, date, date, uuid, text, uuid, uuid, uuid,
  text, text, text, text, boolean, boolean, boolean
) from public;

grant execute on function public.get_irrigation_report_scope(
  uuid, text, integer, date, date, uuid, text, uuid, uuid, uuid,
  text, text, text, text, boolean, boolean, boolean
) to authenticated;

commit;

-- ============================================================================
-- Post-apply verification (run manually; read-only)
-- ============================================================================
-- 1. Existing behaviour untouched — these must return exactly what they
--    returned before this migration:
--      select public.get_irrigation_vintage_overview('<vineyard>'::uuid);
--      select public.get_irrigation_vintage_overview('<vineyard>'::uuid, 2027);
--
-- 2. Single vintage through the new function agrees with the old one:
--      select public.get_irrigation_report_scope('<vineyard>'::uuid, 'vintage', 2027)
--             -> 'totals' ->> 'total_litres';
--
-- 3. All vintages is a strict superset, and covers more than one season:
--      select public.get_irrigation_report_scope('<vineyard>'::uuid, 'all')
--             -> 'totals' ->> 'vintages_covered';
--
-- 4. The option list survives a filter — selecting 2027 must still offer 2026:
--      select public.get_irrigation_report_scope('<vineyard>'::uuid, 'vintage', 2027)
--             -> 'available_vintages';
--
-- 5. A bad scope is rejected rather than silently treated as current:
--      select public.get_irrigation_report_scope('<vineyard>'::uuid, 'nonsense');
--      -- expects: INVALID_SCOPE
-- ============================================================================

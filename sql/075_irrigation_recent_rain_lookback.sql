-- 075_irrigation_recent_rain_lookback.sql
-- Shared vineyard-level recent-rain lookback setting AND a shared
-- resolution contract for "recent rain (mm)" used by the Irrigation
-- Advisor on iOS and Lovable.
--
-- Why:
--   Lovable was showing "Recent rain — No recent rain value supplied —
--   assuming 0 mm" because there was no shared, vineyard-level source
--   of truth for either the lookback window or the resolved rainfall
--   total. iOS resolved this locally via Davis -> rainfall_daily ->
--   open_meteo -> 0 mm, but Lovable had no equivalent path.
--
-- This migration adds:
--   1. vineyards.irrigation_recent_rain_lookback_hours
--      Shared lookback window in HOURS (Lovable wanted hours, iOS uses
--      days; 24/48/168/336 hours map cleanly to 1/2/7/14 days).
--   2. get/set RPCs for the lookback.
--   3. public.get_vineyard_recent_rainfall(p_vineyard_id, p_lookback_hours)
--      Returns ONE row with the resolved rainfall total AND a
--      source_label / resolution_path describing how it was derived.
--      Both clients MUST use this to keep behaviour identical.
--
-- Resolution hierarchy (highest priority first):
--   1. manual            — manager-corrected days override everything
--   2. davis_weatherlink — primary auto source
--   3. open_meteo        — historical/archive fallback
--   4. zero_fallback     — soft 0 mm so the recommendation NEVER blocks
--
-- A "soft" 0 mm fallback must never block the recommendation — Lovable
-- and iOS should treat zero_fallback exactly as 0 mm with a clear
-- "no recent rain data available" label.

-- ---------------------------------------------------------------------------
-- 1. Vineyard column + constraint
-- ---------------------------------------------------------------------------
alter table public.vineyards
  add column if not exists irrigation_recent_rain_lookback_hours integer
    not null default 168; -- 7 days

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'vineyards_irrigation_recent_rain_lookback_hours_check'
  ) then
    alter table public.vineyards
      add constraint vineyards_irrigation_recent_rain_lookback_hours_check
      check (irrigation_recent_rain_lookback_hours in (24, 48, 168, 336));
  end if;
end$$;

comment on column public.vineyards.irrigation_recent_rain_lookback_hours is
  'Vineyard-level default recent-rain lookback window for the Irrigation '
  'Advisor, in HOURS. Allowed: 24 (24h), 48 (48h), 168 (7d), 336 (14d). '
  'Shared by iOS and Lovable. iOS converts to days as (hours/24).';

-- ---------------------------------------------------------------------------
-- 2. Get / set RPCs for the lookback setting
-- ---------------------------------------------------------------------------
create or replace function public.get_vineyard_recent_rain_lookback_hours(
  p_vineyard_id uuid
) returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
  v_hours integer;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;

  select irrigation_recent_rain_lookback_hours into v_hours
    from public.vineyards
   where id = p_vineyard_id;

  return coalesce(v_hours, 168);
end$$;

revoke all on function public.get_vineyard_recent_rain_lookback_hours(uuid) from public;
grant execute on function public.get_vineyard_recent_rain_lookback_hours(uuid) to authenticated;

create or replace function public.set_vineyard_recent_rain_lookback_hours(
  p_vineyard_id uuid,
  p_hours integer
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  if p_hours not in (24, 48, 168, 336) then
    raise exception 'Invalid lookback hours (allowed: 24, 48, 168, 336): %', p_hours
      using errcode = '22023';
  end if;

  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  update public.vineyards
     set irrigation_recent_rain_lookback_hours = p_hours,
         updated_at = now()
   where id = p_vineyard_id;

  return p_hours;
end$$;

revoke all on function public.set_vineyard_recent_rain_lookback_hours(uuid, integer) from public;
grant execute on function public.set_vineyard_recent_rain_lookback_hours(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Shared resolver: get_vineyard_recent_rainfall
--
-- Returns ONE row describing the resolved recent-rain total and the
-- exact resolution path used. Both iOS and Lovable MUST call this so
-- the Irrigation Advisor agrees on the value AND the user-facing label.
--
-- p_lookback_hours may be null — in that case the vineyard's saved
-- setting is used. The window covers the last N hours up to now(),
-- aligned to calendar days in the vineyard's timezone via the
-- existing get_daily_rainfall RPC (date-resolution storage).
--
-- Output columns:
--   recent_rain_mm     numeric   — total mm in window (never null)
--   lookback_hours     integer   — effective hours used
--   covered_from       date      — first day in window
--   covered_to         date      — last day in window (today)
--   source             text      — primary source code (see below)
--   source_label       text      — short user-facing label
--   resolution_path    text      — verbose path tag for diagnostics
--   fallback_used      boolean   — true if any zero_fallback days
--   days_with_data     integer   — days with a rainfall row
--   days_missing       integer   — days defaulted to 0 mm
--   davis_days         integer
--   manual_days        integer
--   open_meteo_days    integer
--   today_from_cache   boolean   — today filled from current-weather cache
--
-- source codes (highest priority observed in the window):
--   'manual' | 'davis_weatherlink' | 'open_meteo' | 'mixed' | 'zero_fallback'
--
-- resolution_path values (verbose, stable strings — clients display as-is):
--   'rainfall_daily.manual'
--   'rainfall_daily.davis_weatherlink'
--   'rainfall_daily.open_meteo'
--   'rainfall_daily.mixed'
--   'rainfall_daily+current_weather_cache'   (today filled from cache)
--   'zero_fallback'                          (no data, soft 0 mm)
-- ---------------------------------------------------------------------------
create or replace function public.get_vineyard_recent_rainfall(
  p_vineyard_id uuid,
  p_lookback_hours integer default null
)
returns table (
  recent_rain_mm numeric,
  lookback_hours integer,
  covered_from date,
  covered_to date,
  source text,
  source_label text,
  resolution_path text,
  fallback_used boolean,
  days_with_data integer,
  days_missing integer,
  davis_days integer,
  manual_days integer,
  open_meteo_days integer,
  today_from_cache boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
  v_hours integer;
  v_days integer;
  v_from date;
  v_to date := current_date;
  v_total numeric := 0;
  v_with_data integer := 0;
  v_missing integer := 0;
  v_manual integer := 0;
  v_davis integer := 0;
  v_om integer := 0;
  v_today_cache boolean := false;
  v_today_mm numeric;
  v_today_has_row boolean := false;
  v_source text;
  v_label text;
  v_path text;
  v_fallback boolean := false;
  v_distinct_sources integer := 0;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;

  if p_lookback_hours is null then
    select irrigation_recent_rain_lookback_hours into v_hours
      from public.vineyards where id = p_vineyard_id;
    v_hours := coalesce(v_hours, 168);
  else
    v_hours := p_lookback_hours;
  end if;

  if v_hours not in (24, 48, 168, 336) then
    -- be forgiving: clamp to nearest allowed bucket
    if v_hours <= 36 then v_hours := 24;
    elsif v_hours <= 96 then v_hours := 48;
    elsif v_hours <= 252 then v_hours := 168;
    else v_hours := 336;
    end if;
  end if;

  v_days := greatest(1, ceil(v_hours / 24.0)::int);
  v_from := v_to - (v_days - 1);

  -- Aggregate daily rows via the existing prioritised view.
  select
    coalesce(sum(coalesce(r.rainfall_mm, 0)), 0)               as total,
    count(*) filter (where r.rainfall_mm is not null)::int     as with_data,
    count(*) filter (where r.rainfall_mm is null)::int         as missing,
    count(*) filter (where r.source = 'manual')::int           as manual_n,
    count(*) filter (where r.source = 'davis_weatherlink')::int as davis_n,
    count(*) filter (where r.source = 'open_meteo')::int       as om_n
    into v_total, v_with_data, v_missing, v_manual, v_davis, v_om
  from public.get_daily_rainfall(p_vineyard_id, v_from, v_to) r;

  -- If today has no rainfall_daily row, try the current-weather cache.
  select (r.rainfall_mm is not null) into v_today_has_row
    from public.get_daily_rainfall(p_vineyard_id, v_to, v_to) r
    limit 1;

  if not coalesce(v_today_has_row, false) then
    select w.rain_today_mm into v_today_mm
      from public.vineyard_weather_observations w
     where w.vineyard_id = p_vineyard_id
       and w.source = 'davis_weatherlink'
     limit 1;
    if v_today_mm is not null and v_today_mm >= 0 then
      v_total := v_total + v_today_mm;
      v_with_data := v_with_data + 1;
      v_missing := greatest(0, v_missing - 1);
      v_davis := v_davis + 1;
      v_today_cache := true;
    end if;
  end if;

  -- Determine primary source.
  v_distinct_sources :=
      (case when v_manual > 0 then 1 else 0 end)
    + (case when v_davis  > 0 then 1 else 0 end)
    + (case when v_om     > 0 then 1 else 0 end);

  if v_with_data = 0 then
    v_source := 'zero_fallback';
    v_label  := 'No recent rainfall data — assuming 0 mm';
    v_path   := 'zero_fallback';
    v_fallback := true;
  elsif v_distinct_sources > 1 then
    v_source := 'mixed';
    v_label  := 'Rainfall: vineyard history (mixed sources)';
    v_path   := case when v_today_cache
                     then 'rainfall_daily+current_weather_cache'
                     else 'rainfall_daily.mixed' end;
  elsif v_manual > 0 then
    v_source := 'manual';
    v_label  := 'Rainfall: manual entries';
    v_path   := 'rainfall_daily.manual';
  elsif v_davis > 0 then
    v_source := 'davis_weatherlink';
    v_label  := 'Rainfall: Davis WeatherLink';
    v_path   := case when v_today_cache
                     then 'rainfall_daily+current_weather_cache'
                     else 'rainfall_daily.davis_weatherlink' end;
  elsif v_om > 0 then
    v_source := 'open_meteo';
    v_label  := 'Rainfall: Open-Meteo Archive';
    v_path   := 'rainfall_daily.open_meteo';
  else
    v_source := 'zero_fallback';
    v_label  := 'No recent rainfall data — assuming 0 mm';
    v_path   := 'zero_fallback';
    v_fallback := true;
  end if;

  recent_rain_mm   := round(v_total::numeric, 2);
  lookback_hours   := v_hours;
  covered_from     := v_from;
  covered_to       := v_to;
  source           := v_source;
  source_label     := v_label;
  resolution_path  := v_path;
  fallback_used    := v_fallback;
  days_with_data   := v_with_data;
  days_missing     := v_missing;
  davis_days       := v_davis;
  manual_days      := v_manual;
  open_meteo_days  := v_om;
  today_from_cache := v_today_cache;
  return next;
end$$;

revoke all on function public.get_vineyard_recent_rainfall(uuid, integer) from public;
grant execute on function public.get_vineyard_recent_rainfall(uuid, integer) to authenticated;

comment on function public.get_vineyard_recent_rainfall(uuid, integer) is
  'Shared Irrigation Advisor recent-rain resolver. Returns total mm plus '
  'source / resolution_path / fallback_used. iOS and Lovable MUST both '
  'consume this RPC so the user-facing label and value agree. A '
  'zero_fallback row is a SOFT fallback — clients must NOT block the '
  'recommendation when fallback_used is true.';

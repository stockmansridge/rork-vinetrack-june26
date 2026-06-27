-- 029_rainfall_wunderground_source.sql
-- Stage 1 of Weather Underground rainfall persistence.
--
-- Adds 'wunderground_pws' as an allowed source for public.rainfall_daily and
-- slots it into get_daily_rainfall priority between Davis and Open-Meteo:
--
--     manual = 1
--     davis_weatherlink = 2
--     wunderground_pws = 3
--     open_meteo = 4
--
-- Also introduces upsert_wunderground_rainfall_daily, callable only by
-- service_role (the future wunderground-proxy edge function). It writes
-- exclusively to source = 'wunderground_pws' rows; manual and Davis rows
-- are never read or modified.
--
-- This migration does NOT:
--   * create the wunderground-proxy edge function
--   * change iOS code
--   * change Weather Underground settings UI
--   * backfill or touch any existing rows

-- ---------------------------------------------------------------------------
-- 1. Extend the source CHECK constraint to include 'wunderground_pws'.
--    Postgres lets us drop and recreate the named check constraint without
--    rewriting the table.
-- ---------------------------------------------------------------------------
do $$
declare
  v_conname text;
begin
  select conname
    into v_conname
    from pg_constraint
   where conrelid = 'public.rainfall_daily'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%source%'
     and pg_get_constraintdef(oid) ilike '%davis_weatherlink%'
   limit 1;

  if v_conname is not null then
    execute format('alter table public.rainfall_daily drop constraint %I', v_conname);
  end if;
end$$;

alter table public.rainfall_daily
  add constraint rainfall_daily_source_check
  check (source in ('manual','davis_weatherlink','wunderground_pws','open_meteo'));

-- ---------------------------------------------------------------------------
-- 2. Replace get_daily_rainfall to add wunderground_pws between Davis and
--    Open-Meteo. Signature is unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.get_daily_rainfall(
  p_vineyard_id uuid,
  p_from_date date,
  p_to_date date
)
returns table (
  date date,
  rainfall_mm numeric,
  source text,
  station_id text,
  station_name text,
  notes text,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;

  if p_from_date is null or p_to_date is null or p_from_date > p_to_date then
    raise exception 'Invalid date range' using errcode = '22023';
  end if;

  if (p_to_date - p_from_date) > 3650 then
    raise exception 'Date range too large (max 10 years)' using errcode = '22023';
  end if;

  return query
  with days as (
    select gs::date as d
      from generate_series(p_from_date::timestamp, p_to_date::timestamp, interval '1 day') gs
  ),
  ranked as (
    select
      r.date,
      r.rainfall_mm,
      r.source,
      r.station_id,
      r.station_name,
      r.notes,
      r.updated_at,
      row_number() over (
        partition by r.date
        order by case r.source
                   when 'manual' then 1
                   when 'davis_weatherlink' then 2
                   when 'wunderground_pws' then 3
                   when 'open_meteo' then 4
                   else 9
                 end,
                 r.updated_at desc
      ) as rn
    from public.rainfall_daily r
    where r.vineyard_id = p_vineyard_id
      and r.deleted_at is null
      and r.date between p_from_date and p_to_date
  )
  select
    d.d as date,
    rk.rainfall_mm,
    rk.source,
    rk.station_id,
    rk.station_name,
    rk.notes,
    rk.updated_at
  from days d
  left join ranked rk on rk.date = d.d and rk.rn = 1
  order by d.d;
end;
$$;

revoke all on function public.get_daily_rainfall(uuid, date, date) from public;
grant execute on function public.get_daily_rainfall(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. upsert_wunderground_rainfall_daily: SERVICE-ROLE ONLY.
--    The future wunderground-proxy edge function will call this to persist
--    a single (vineyard, date, station) WU rainfall total. Re-running the
--    same day overwrites the WU row only.
--
--    Manual ('manual') and Davis ('davis_weatherlink') rows are never read
--    or modified here — they live as separate rows under different sources.
--    Source priority is enforced at read time by get_daily_rainfall.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_wunderground_rainfall_daily(
  p_vineyard_id uuid,
  p_date date,
  p_rainfall_mm numeric,
  p_station_id text,
  p_station_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_station text := coalesce(p_station_id, '');
begin
  if p_rainfall_mm is null or p_rainfall_mm < 0 then
    raise exception 'rainfall_mm must be >= 0' using errcode = '22023';
  end if;
  if p_vineyard_id is null or p_date is null then
    raise exception 'vineyard_id and date are required' using errcode = '22023';
  end if;

  -- Update existing WU row for this (vineyard, date, station). We scope
  -- strictly to source = 'wunderground_pws' so manual and Davis rows are
  -- untouchable from this entry point.
  update public.rainfall_daily
     set rainfall_mm = p_rainfall_mm,
         station_name = coalesce(p_station_name, station_name),
         updated_at = now(),
         deleted_at = null
   where vineyard_id = p_vineyard_id
     and date = p_date
     and source = 'wunderground_pws'
     and coalesce(station_id, '') = v_station
   returning id into v_id;

  if v_id is not null then
    return v_id;
  end if;

  insert into public.rainfall_daily (
    vineyard_id, date, rainfall_mm, source, station_id, station_name
  ) values (
    p_vineyard_id, p_date, p_rainfall_mm, 'wunderground_pws',
    nullif(p_station_id, ''), p_station_name
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.upsert_wunderground_rainfall_daily(uuid, date, numeric, text, text) from public;
revoke all on function public.upsert_wunderground_rainfall_daily(uuid, date, numeric, text, text) from authenticated;
-- Service-role bypasses RLS/grants anyway, but be explicit.
grant execute on function public.upsert_wunderground_rainfall_daily(uuid, date, numeric, text, text) to service_role;

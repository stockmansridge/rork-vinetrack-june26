-- 028_rainfall_daily.sql
-- Persistent vineyard-level daily rainfall history.
--
-- Goals:
--   * Persist rainfall by vineyard/date/source/station so the iOS Rain
--     Calendar and the Lovable portal can show long history without
--     repeatedly hitting Davis.
--   * Davis WeatherLink (server-side via davis-proxy) is the primary
--     auto source. open_meteo and any other ambient providers are
--     second-class. Manual entries from the portal are the tie-breaker
--     winner so a manager-corrected day always overrides Davis.
--   * No Davis credentials are stored here. davis-proxy writes via
--     service role; portal/app never read this table directly.
--
-- Source-priority for get_daily_rainfall:
--     manual > davis_weatherlink > open_meteo  (alphabetical fallback after).
--
-- Statuses (returned in the rpc rows):
--   * always one row per date in [from_date, to_date]; rainfall_mm is null
--     when no source has any data for that day.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------
create table if not exists public.rainfall_daily (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  date date not null,
  rainfall_mm numeric(8,2) not null check (rainfall_mm >= 0),
  source text not null check (source in ('manual','davis_weatherlink','open_meteo')),
  station_id text,
  station_name text,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

-- Unique per vineyard/date/source/station. station_id is part of the key
-- so two Davis stations on the same vineyard don't collide. Manual rows
-- have station_id null and are de-duped by (vineyard, date, 'manual').
-- Postgres treats null as distinct in unique constraints by default, so
-- we use a partial unique index per source family to get the right
-- behaviour.
create unique index if not exists rainfall_daily_manual_unique
  on public.rainfall_daily (vineyard_id, date)
  where source = 'manual' and deleted_at is null;

create unique index if not exists rainfall_daily_provider_unique
  on public.rainfall_daily (vineyard_id, date, source, coalesce(station_id, ''))
  where source <> 'manual' and deleted_at is null;

create index if not exists rainfall_daily_vineyard_date_idx
  on public.rainfall_daily (vineyard_id, date desc);

-- Lock down. RLS on, no policies => no direct client access.
alter table public.rainfall_daily enable row level security;
revoke all on public.rainfall_daily from anon, authenticated;

-- ---------------------------------------------------------------------------
-- get_daily_rainfall: vineyard members can read.
-- Returns one row per date in [from_date, to_date], picking the highest
-- priority non-deleted source per date.
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

  -- Cap range to avoid runaway queries.
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
      case r.source
        when 'manual' then 1
        when 'davis_weatherlink' then 2
        when 'open_meteo' then 3
        else 9
      end as prio,
      row_number() over (
        partition by r.date
        order by case r.source
                   when 'manual' then 1
                   when 'davis_weatherlink' then 2
                   when 'open_meteo' then 3
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
-- upsert_manual_rainfall: owner/manager only. Writes a manual override.
-- Manual rows are independent from Davis rows (different source) so this
-- never destroys Davis data.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_manual_rainfall(
  p_vineyard_id uuid,
  p_date date,
  p_rainfall_mm numeric,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_id uuid;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;
  if p_rainfall_mm is null or p_rainfall_mm < 0 then
    raise exception 'rainfall_mm must be >= 0' using errcode = '22023';
  end if;

  -- Revive any soft-deleted manual row for this day.
  update public.rainfall_daily
     set rainfall_mm = p_rainfall_mm,
         notes = p_notes,
         updated_by = auth.uid(),
         updated_at = now(),
         deleted_at = null
   where vineyard_id = p_vineyard_id
     and date = p_date
     and source = 'manual'
   returning id into v_id;

  if v_id is not null then
    return v_id;
  end if;

  insert into public.rainfall_daily (
    vineyard_id, date, rainfall_mm, source, station_id, station_name,
    notes, created_by, updated_by
  ) values (
    p_vineyard_id, p_date, p_rainfall_mm, 'manual', null, null,
    p_notes, auth.uid(), auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.upsert_manual_rainfall(uuid, date, numeric, text) from public;
grant execute on function public.upsert_manual_rainfall(uuid, date, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- archive_manual_rainfall: owner/manager only. Soft-deletes a manual row,
-- which means the auto sources (Davis / open_meteo) become visible again
-- via get_daily_rainfall.
-- ---------------------------------------------------------------------------
create or replace function public.archive_manual_rainfall(
  p_vineyard_id uuid,
  p_date date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  v_role := public.vineyard_member_role(p_vineyard_id);
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  update public.rainfall_daily
     set deleted_at = now(),
         updated_by = auth.uid(),
         updated_at = now()
   where vineyard_id = p_vineyard_id
     and date = p_date
     and source = 'manual'
     and deleted_at is null;
end;
$$;

revoke all on function public.archive_manual_rainfall(uuid, date) from public;
grant execute on function public.archive_manual_rainfall(uuid, date) to authenticated;

-- ---------------------------------------------------------------------------
-- upsert_davis_rainfall_daily: SERVICE-ROLE ONLY.
-- davis-proxy calls this to persist Davis rainfall for one (vineyard,date,
-- station). Re-running for the same day overwrites the Davis row (rain
-- accumulates through the day). Manual rows are a different source and
-- are NOT touched.
--
-- We deliberately do not require a vineyard membership check here because
-- the only caller is the davis-proxy edge function authenticated with the
-- service-role key. The function is revoked from public/authenticated.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_davis_rainfall_daily(
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

  update public.rainfall_daily
     set rainfall_mm = p_rainfall_mm,
         station_name = coalesce(p_station_name, station_name),
         updated_at = now(),
         deleted_at = null
   where vineyard_id = p_vineyard_id
     and date = p_date
     and source = 'davis_weatherlink'
     and coalesce(station_id, '') = v_station
   returning id into v_id;

  if v_id is not null then
    return v_id;
  end if;

  insert into public.rainfall_daily (
    vineyard_id, date, rainfall_mm, source, station_id, station_name
  ) values (
    p_vineyard_id, p_date, p_rainfall_mm, 'davis_weatherlink',
    nullif(p_station_id, ''), p_station_name
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.upsert_davis_rainfall_daily(uuid, date, numeric, text, text) from public;
revoke all on function public.upsert_davis_rainfall_daily(uuid, date, numeric, text, text) from authenticated;
-- Service-role bypasses this anyway, but be explicit.
grant execute on function public.upsert_davis_rainfall_daily(uuid, date, numeric, text, text) to service_role;

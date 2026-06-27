-- 030_rainfall_open_meteo_source.sql
-- Stage 4a of rainfall persistence: Open-Meteo as lowest-priority gap-fill.
--
-- Open-Meteo is broad fallback rainfall data (no on-vineyard station). It
-- must NEVER overwrite Manual, Davis or Weather Underground rows.
--
-- Source priority (read by get_daily_rainfall) is unchanged:
--     manual            = 1
--     davis_weatherlink = 2
--     wunderground_pws  = 3
--     open_meteo        = 4
--
-- This migration:
--   1. Confirms rainfall_daily.source already allows 'open_meteo' (it does;
--      added in 029). Re-asserts the CHECK constraint idempotently.
--   2. Confirms get_daily_rainfall already gives Open-Meteo lowest priority
--      (it does; defined in 029). No change required.
--   3. Adds upsert_open_meteo_rainfall_daily — service-role only — that
--      writes ONLY to source = 'open_meteo' rows AND ONLY when no
--      better-priority row already exists for that vineyard/date.
--   4. Adds days_with_better_rainfall_source helper so the open-meteo-proxy
--      edge function can cheaply skip days that already have a Manual,
--      Davis or Weather Underground row.
--
-- This migration does NOT:
--   * create the open-meteo-proxy edge function
--   * change iOS code
--   * touch existing rows
--   * change Manual / Davis / Weather Underground behaviour

-- ---------------------------------------------------------------------------
-- 1. Re-assert the source CHECK constraint idempotently. Should already be
--    in place from 029; this is a safe no-op if so.
-- ---------------------------------------------------------------------------
do $$
declare
  v_conname text;
  v_def text;
begin
  select conname, pg_get_constraintdef(oid)
    into v_conname, v_def
    from pg_constraint
   where conrelid = 'public.rainfall_daily'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%source%'
   limit 1;

  if v_conname is not null and v_def not ilike '%open_meteo%' then
    execute format('alter table public.rainfall_daily drop constraint %I', v_conname);
    v_conname := null;
  end if;

  if v_conname is null then
    alter table public.rainfall_daily
      add constraint rainfall_daily_source_check
      check (source in ('manual','davis_weatherlink','wunderground_pws','open_meteo'));
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- 2. days_with_better_rainfall_source(p_vineyard_id, p_from_date, p_to_date)
--    Returns the set of dates in [from,to] that already have a non-deleted
--    Manual, Davis, or Weather Underground rainfall row. Used by the
--    open-meteo-proxy edge function to skip those days entirely.
--
--    SERVICE-ROLE ONLY (the proxy authenticates with the service-role key).
--    Not granted to authenticated/anon — vineyard members read rainfall
--    via get_daily_rainfall instead.
-- ---------------------------------------------------------------------------
create or replace function public.days_with_better_rainfall_source(
  p_vineyard_id uuid,
  p_from_date date,
  p_to_date date
)
returns table (date date)
language sql
stable
security definer
set search_path = public
as $$
  select distinct r.date
    from public.rainfall_daily r
   where r.vineyard_id = p_vineyard_id
     and r.deleted_at is null
     and r.date between p_from_date and p_to_date
     and r.source in ('manual','davis_weatherlink','wunderground_pws')
   order by r.date;
$$;

revoke all on function public.days_with_better_rainfall_source(uuid, date, date) from public;
revoke all on function public.days_with_better_rainfall_source(uuid, date, date) from authenticated;
grant execute on function public.days_with_better_rainfall_source(uuid, date, date) to service_role;

-- ---------------------------------------------------------------------------
-- 3. upsert_open_meteo_rainfall_daily — SERVICE-ROLE ONLY.
--    The open-meteo-proxy edge function calls this once per missing day.
--
--    Returns:
--      - 'inserted' / 'updated' when an Open-Meteo row was written
--      - 'skipped_better_source' when Manual / Davis / WU already exists
--        for that vineyard+date (defensive double-check at write time, in
--        case a better source was added between the proxy's pre-check and
--        the write)
--
--    Open-Meteo rows are vineyard-scoped (no station_id). station_id is
--    coalesced to '' so the existing rainfall_daily_provider_unique partial
--    index keeps one Open-Meteo row per (vineyard,date).
--
--    This function NEVER reads, modifies or deletes Manual, Davis, or
--    Weather Underground rows.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_open_meteo_rainfall_daily(
  p_vineyard_id uuid,
  p_date date,
  p_rainfall_mm numeric
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_better boolean;
begin
  if p_vineyard_id is null or p_date is null then
    raise exception 'vineyard_id and date are required' using errcode = '22023';
  end if;
  if p_rainfall_mm is null or p_rainfall_mm < 0 then
    raise exception 'rainfall_mm must be >= 0' using errcode = '22023';
  end if;

  -- Defensive guard: never write Open-Meteo if a better source exists.
  select exists (
    select 1
      from public.rainfall_daily
     where vineyard_id = p_vineyard_id
       and date = p_date
       and deleted_at is null
       and source in ('manual','davis_weatherlink','wunderground_pws')
  ) into v_better;
  if v_better then
    return 'skipped_better_source';
  end if;

  -- Try to update an existing Open-Meteo row for this vineyard+date.
  update public.rainfall_daily
     set rainfall_mm = p_rainfall_mm,
         updated_at = now(),
         deleted_at = null
   where vineyard_id = p_vineyard_id
     and date = p_date
     and source = 'open_meteo'
   returning id into v_id;

  if v_id is not null then
    return 'updated';
  end if;

  insert into public.rainfall_daily (
    vineyard_id, date, rainfall_mm, source, station_id, station_name
  ) values (
    p_vineyard_id, p_date, p_rainfall_mm, 'open_meteo', null, 'Open-Meteo'
  );

  return 'inserted';
end;
$$;

revoke all on function public.upsert_open_meteo_rainfall_daily(uuid, date, numeric) from public;
revoke all on function public.upsert_open_meteo_rainfall_daily(uuid, date, numeric) from authenticated;
grant execute on function public.upsert_open_meteo_rainfall_daily(uuid, date, numeric) to service_role;

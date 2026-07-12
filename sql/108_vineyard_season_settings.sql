-- =============================================================================
-- 108: Shared vineyard-level Season Settings
--
-- Adds season_start_month / season_start_day to public.vineyards so every
-- member of a vineyard shares one season boundary (previously each device
-- stored its own local copy — iOS per-vineyard JSON, Android a single global
-- SharedPreferences value).
--
-- Contract (used by iOS, Android, and later the portal):
--   get_vineyard_season_settings(p_vineyard_id uuid)
--     -> (vineyard_id, season_start_month, season_start_day, updated_at)
--     Any vineyard member may read.
--   set_vineyard_season_settings(p_vineyard_id uuid,
--                                p_season_start_month integer,
--                                p_season_start_day integer)
--     -> same row shape. Owner/manager only. Validates real month/day
--     combinations (Feb <= 29; Apr/Jun/Sep/Nov <= 30; otherwise <= 31).
--
-- Season calculation (shared by all clients — documented here for the portal):
--   if date >= season start date in that calendar year: vintage = year + 1
--   else:                                                vintage = year
--   season range: start = season start date in (vintage - 1),
--                 end   = day before season start date in vintage.
-- =============================================================================

-- 1. Columns (default 1 July — matches both apps' existing default)
alter table public.vineyards
  add column if not exists season_start_month smallint not null default 7,
  add column if not exists season_start_day smallint not null default 1;

-- 2. Validation constraints
do $$
begin
  alter table public.vineyards
    add constraint vineyards_season_start_month_check
    check (season_start_month between 1 and 12);
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.vineyards
    add constraint vineyards_season_start_day_check
    check (season_start_day between 1 and 31);
exception when duplicate_object then null;
end $$;

-- 3. Read RPC — any vineyard member
create or replace function public.get_vineyard_season_settings(p_vineyard_id uuid)
returns table (
  vineyard_id uuid,
  season_start_month integer,
  season_start_day integer,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_vineyard_member(p_vineyard_id) then
    raise exception 'not a member of this vineyard';
  end if;

  return query
  select v.id,
         v.season_start_month::integer,
         v.season_start_day::integer,
         v.updated_at
  from public.vineyards v
  where v.id = p_vineyard_id
    and v.deleted_at is null;
end;
$$;

-- 4. Write RPC — owner/manager only, with month/day combination validation
create or replace function public.set_vineyard_season_settings(
  p_vineyard_id uuid,
  p_season_start_month integer,
  p_season_start_day integer
)
returns table (
  vineyard_id uuid,
  season_start_month integer,
  season_start_day integer,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max_day integer;
begin
  if not public.has_vineyard_role(p_vineyard_id, array['owner', 'manager']) then
    raise exception 'only vineyard owners and managers can change the shared season settings';
  end if;

  if p_season_start_month is null
     or p_season_start_month < 1
     or p_season_start_month > 12 then
    raise exception 'season start month must be between 1 and 12';
  end if;

  v_max_day := case p_season_start_month
    when 2 then 29
    when 4 then 30
    when 6 then 30
    when 9 then 30
    when 11 then 30
    else 31
  end;

  if p_season_start_day is null
     or p_season_start_day < 1
     or p_season_start_day > v_max_day then
    raise exception 'season start day must be between 1 and % for the selected month', v_max_day;
  end if;

  update public.vineyards v
  set season_start_month = p_season_start_month,
      season_start_day = p_season_start_day
  where v.id = p_vineyard_id
    and v.deleted_at is null;

  if not found then
    raise exception 'vineyard not found';
  end if;

  return query
  select v.id,
         v.season_start_month::integer,
         v.season_start_day::integer,
         v.updated_at
  from public.vineyards v
  where v.id = p_vineyard_id;
end;
$$;

-- 5. Grants
revoke all on function public.get_vineyard_season_settings(uuid) from public, anon;
revoke all on function public.set_vineyard_season_settings(uuid, integer, integer) from public, anon;
grant execute on function public.get_vineyard_season_settings(uuid) to authenticated;
grant execute on function public.set_vineyard_season_settings(uuid, integer, integer) to authenticated;

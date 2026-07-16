-- =============================================================================
-- 119: Vintage assignment for pruning records and linked Work Tasks.
--
-- MODELLING GAP (exposed by the season-year investigation): pruning performed
-- in July 2026 is stored under the TECHNICAL pruning calendar year 2026
-- (pruning_seasons.season_year — the grouping key mobile sync depends on),
-- but for production and cost reporting it belongs to VINTAGE 2027.
--
-- This migration separates the two concepts WITHOUT touching season_year:
--
--   pruning_seasons.season_year  = technical pruning/calendar grouping
--                                  (unchanged — current mobile sync depends on it)
--   pruning_entries.vintage_year = production and costing vintage, resolved
--                                  from the entry date + the vineyard's shared
--                                  season-start setting (SQL 108), frozen at
--                                  the time the work was recorded
--   work_tasks.vintage_year      = costing vintage of the task, resolved from
--                                  the task date the same way
--
-- WHY vintage_year IS NOT ADDED TO pruning_seasons: a technical season groups
-- entries by calendar year, so with a mid-year season start (e.g. 1 July) one
-- season row legitimately contains entries from TWO vintages (Jan–Jun 2026 →
-- Vintage 2026; Jul–Dec 2026 → Vintage 2027). A season-level vintage could
-- therefore disagree with its entries by construction — storing it only on
-- the entries is the only shape where entry and season can never disagree.
--
-- VINTAGE RULE (season-end-year — uses the EXISTING shared Operational
-- Preference vineyards.season_start_month/day from SQL 108; no hemisphere
-- toggle, no separate pruning calendar):
--
--   A season runs from the configured start date to the day before the next
--   start date. The vintage is the calendar year in which the season ENDS.
--
--     1 July start:    15 Jul 2026 → Vintage 2027, 15 Jan 2027 → Vintage 2027
--     1 January start: 15 Feb 2026 → Vintage 2026 (season is contained in one
--                      calendar year, so vintage = calendar year)
--     1 November start: 15 Oct 2026 → Vintage 2026, 15 Nov 2026 → Vintage 2027
--
--   NOTE: this supersedes the simplified comment in SQL 108 ("date >= start →
--   year + 1"), which is only correct for season starts other than 1 January.
--
-- Mirrored client resolvers: iOS `VintageResolver.swift`, Android
-- `VintageResolver.kt`. The DATABASE resolver is authoritative — the
-- record_pruning_entry RPC and the work_tasks trigger never trust an
-- arbitrary client vintage.
--
-- Also in this migration:
--   * record_pruning_entry gains optional p_vintage_year (default null); the
--     server resolves and returns the vintage. The old 16-parameter function
--     is DROPPED first so PostgREST named-argument resolution stays
--     unambiguous; every existing client call shape still resolves via the
--     parameter defaults.
--   * Backfill of ALL existing live pruning entries and work tasks. Entry
--     ids, segment ids, work-task ids, entry dates, technical season ids and
--     completed quarters are untouched — only vintage_year is written.
--   * Validation asserts covering both hemispheres, a non-standard season,
--     and leap-day configuration. The migration ABORTS if any fails.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Pure resolver (immutable — unit-testable, no table access)
-- ---------------------------------------------------------------------------
create or replace function public.resolve_vintage_year(
  p_record_date date,
  p_start_month integer,
  p_start_day integer
) returns integer
language plpgsql
immutable
as $$
declare
  v_year integer := extract(year from p_record_date)::integer;
  v_month integer := least(greatest(coalesce(p_start_month, 7), 1), 12);
  v_day integer := greatest(coalesce(p_start_day, 1), 1);
  v_start date;
begin
  -- 1 January start: the season is contained in a single calendar year and
  -- ends 31 December, so the vintage IS the record's calendar year.
  if v_month = 1 and v_day = 1 then
    return v_year;
  end if;

  -- Clamp the configured day to the month's real length in the record's year
  -- (leap-day safe: a 29 Feb start behaves as 28 Feb in non-leap years).
  v_day := least(
    v_day,
    extract(day from (make_date(v_year, v_month, 1) + interval '1 month' - interval '1 day'))::integer
  );
  v_start := make_date(v_year, v_month, v_day);

  -- Season-end-year rule: on/after this year's start the season ends next
  -- calendar year; before it the season ends this calendar year.
  if p_record_date >= v_start then
    return v_year + 1;
  end if;
  return v_year;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Authoritative vineyard-level resolver (reads SQL 108 season settings)
-- ---------------------------------------------------------------------------
create or replace function public.resolve_vineyard_vintage_year(
  p_vineyard_id uuid,
  p_record_date date
) returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_month integer;
  v_day integer;
begin
  select v.season_start_month::integer, v.season_start_day::integer
  into v_month, v_day
  from public.vineyards v
  where v.id = p_vineyard_id;

  -- Unknown vineyard: fall back to the shared default (1 July) rather than
  -- failing — offline replays must never wedge on a race.
  return public.resolve_vintage_year(p_record_date, coalesce(v_month, 7), coalesce(v_day, 1));
end;
$$;

revoke all on function public.resolve_vintage_year(date, integer, integer) from public, anon;
revoke all on function public.resolve_vineyard_vintage_year(uuid, date) from public, anon;
grant execute on function public.resolve_vintage_year(date, integer, integer) to authenticated;
grant execute on function public.resolve_vineyard_vintage_year(uuid, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Columns + indexes (season_year is NOT replaced or renamed)
-- ---------------------------------------------------------------------------
alter table public.pruning_entries
  add column if not exists vintage_year integer;

alter table public.work_tasks
  add column if not exists vintage_year integer;

create index if not exists pruning_entries_vintage_idx
  on public.pruning_entries (vineyard_id, vintage_year);

create index if not exists work_tasks_vintage_idx
  on public.work_tasks (vineyard_id, vintage_year);

-- ---------------------------------------------------------------------------
-- 4. Work Tasks: server-resolved costing vintage
--
-- BEFORE INSERT/UPDATE trigger. Rules:
--   * INSERT: always resolve from the task date (client values are ignored —
--     an arbitrary client vintage is never trusted).
--   * UPDATE with the task date/vineyard unchanged and a stored vintage
--     unchanged: keep the stored vintage. This freezes historical reporting
--     even if Operational Preferences are later changed.
--   * UPDATE that changes the task date (or tampers with vintage_year, or
--     fills a null): re-resolve server-side — costing follows the work date.
-- ---------------------------------------------------------------------------
create or replace function public.work_tasks_resolve_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tz text;
begin
  if tg_op = 'UPDATE'
     and new.date is not distinct from old.date
     and new.vineyard_id is not distinct from old.vineyard_id
     and new.vintage_year is not null
     and new.vintage_year is not distinct from old.vintage_year then
    return new; -- unrelated edit: preserve the recorded vintage
  end if;

  select v.timezone into v_tz from public.vineyards v where v.id = new.vineyard_id;
  new.vintage_year := public.resolve_vineyard_vintage_year(
    new.vineyard_id,
    (new.date at time zone coalesce(nullif(v_tz, ''), 'UTC'))::date
  );
  return new;
end;
$$;

drop trigger if exists work_tasks_resolve_vintage on public.work_tasks;
create trigger work_tasks_resolve_vintage
  before insert or update on public.work_tasks
  for each row execute function public.work_tasks_resolve_vintage();

-- ---------------------------------------------------------------------------
-- 5. record_pruning_entry — extended, non-breaking
--
-- The 16-parameter SQL 117 version is dropped FIRST (leaving it would create
-- an ambiguous overload for existing 16-key client calls). The replacement
-- keeps the exact SQL 117 body and adds:
--   * optional p_vintage_year (default null) — accepted only when it matches
--     the server resolution; otherwise the server value wins silently so a
--     queued replay can never wedge on a mismatch.
--   * vintage_year stored on the inserted entry; a replay fills a null
--     vintage but NEVER overwrites a stored one (historical reporting is
--     protected if Operational Preferences change later).
--   * 'vintage_year' in the JSON response.
-- Every pre-119 client call shape (12–16 keys) still resolves via defaults.
-- ---------------------------------------------------------------------------
drop function if exists public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb, uuid);

create or replace function public.record_pruning_entry(
  p_id uuid,
  p_vineyard_id uuid,
  p_season_id uuid,
  p_paddock_id uuid,
  p_season_year integer,
  p_entry_date date,
  p_worker text,
  p_labour_hours numeric default null,
  p_start_time timestamptz default null,
  p_finish_time timestamptz default null,
  p_method text default null,
  p_notes text default null,
  p_estimated_vines integer default null,
  p_client_updated_at timestamptz default null,
  p_segments jsonb default '[]'::jsonb,
  p_work_task_id uuid default null,
  p_vintage_year integer default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_requested integer;
  v_attributed integer;
  v_seg jsonb;
  v_row_id uuid;
  v_row_num integer;
  v_label text;
  v_year integer;
  v_season_id uuid;
  v_vintage integer;
begin
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;

  v_year := coalesce(p_season_year, extract(year from p_entry_date)::integer);

  -- Production/costing vintage (SQL 119). Server resolution is authoritative:
  -- a client-provided p_vintage_year is honoured only when it MATCHES the
  -- resolver; any other value is ignored (never an error — replays must not
  -- wedge on a stale client calculation).
  v_vintage := public.resolve_vineyard_vintage_year(p_vineyard_id, p_entry_date);

  -- Canonical season resolution (see SQL 116 header).
  select id into v_season_id
  from public.pruning_seasons
  where id = p_season_id and deleted_at is null;

  if v_season_id is null then
    select id into v_season_id
    from public.pruning_seasons
    where vineyard_id = p_vineyard_id
      and paddock_id = p_paddock_id
      and season_year = v_year
      and deleted_at is null
    limit 1;
  end if;

  if v_season_id is null then
    insert into public.pruning_seasons (id, vineyard_id, paddock_id, season_year, created_by, client_updated_at)
    values (p_season_id, p_vineyard_id, p_paddock_id, v_year, auth.uid(), p_client_updated_at)
    on conflict (id) do update
      set deleted_at = null, updated_at = now()
      where public.pruning_seasons.deleted_at is not null;
    v_season_id := p_season_id;
  end if;

  -- One task per entry: if another live entry already owns this task id
  -- (e.g. a raced replay), record the entry WITHOUT the link rather than
  -- failing the queue or stealing the link.
  if p_work_task_id is not null and exists (
    select 1 from public.pruning_entries
    where work_task_id = p_work_task_id and id <> p_id and deleted_at is null
  ) then
    p_work_task_id := null;
  end if;

  -- Replaying a delete-raced entry: never resurrect.
  if exists (select 1 from public.pruning_entries where id = p_id and deleted_at is not null) then
    return jsonb_build_object('entry_id', p_id, 'requested', 0, 'attributed', 0, 'deleted', true, 'vintage_year', v_vintage);
  end if;

  insert into public.pruning_entries (
    id, vineyard_id, pruning_season_id, paddock_id, entry_date, worker_or_crew,
    labour_hours, start_time, finish_time, pruning_method, notes,
    work_task_id, vintage_year, created_by, client_updated_at
  ) values (
    p_id, p_vineyard_id, v_season_id, p_paddock_id, p_entry_date, coalesce(p_worker, ''),
    p_labour_hours, p_start_time, p_finish_time, coalesce(p_method, 'spur'), coalesce(p_notes, ''),
    p_work_task_id, v_vintage, auth.uid(), p_client_updated_at
  )
  on conflict (id) do nothing;

  -- Replay fills a MISSING vintage only — a stored vintage is never
  -- overwritten, so later Operational Preference changes can't rewrite
  -- historical costing.
  update public.pruning_entries
  set vintage_year = v_vintage, updated_at = now()
  where id = p_id and deleted_at is null and vintage_year is null;

  -- Idempotent link back-fill on replay: only fills an EMPTY link — a replay
  -- can never overwrite an existing (possibly different) linked task.
  -- NOTE: p_work_task_id may reference a work_tasks row that does not exist
  -- yet (offline queues replay in either order) — deliberate, see SQL 114.
  if p_work_task_id is not null then
    update public.pruning_entries
    set work_task_id = p_work_task_id, updated_at = now()
    where id = p_id and deleted_at is null and work_task_id is null;
  end if;

  v_requested := coalesce(jsonb_array_length(p_segments), 0);

  for v_seg in select * from jsonb_array_elements(coalesce(p_segments, '[]'::jsonb))
  loop
    v_row_num := coalesce(nullif(v_seg->>'row', '')::integer, 0);
    v_label := coalesce(nullif(v_seg->>'label', ''), v_row_num::text);
    begin
      v_row_id := nullif(v_seg->>'row_id', '')::uuid;
    exception when others then
      v_row_id := null;
    end;

    -- Legacy clients send only the number — resolve the configured row id
    -- from the paddock's stored rows so both identity schemes converge.
    if v_row_id is null then
      select (elem->>'id')::uuid into v_row_id
      from public.paddocks p
      cross join lateral jsonb_array_elements(coalesce(p.rows, '[]'::jsonb)) elem
      where p.id = p_paddock_id
        and jsonb_typeof(elem->'number') = 'number'
        and (elem->>'number')::integer = v_row_num
        and (elem->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      limit 1;
    end if;

    if v_row_id is not null then
      -- Adopt any legacy fallback quarter for the same number so it can't be
      -- double-counted under both identities.
      update public.pruning_row_segments s
      set paddock_row_id = v_row_id,
          row_label = coalesce(s.row_label, v_label),
          updated_at = now()
      where s.pruning_season_id = v_season_id
        and s.paddock_row_id is null
        and s.row_number = v_row_num
        and not exists (
          select 1 from public.pruning_row_segments x
          where x.pruning_season_id = v_season_id
            and x.paddock_row_id = v_row_id
            and x.segment_number = s.segment_number
        );

      insert into public.pruning_row_segments (
        vineyard_id, pruning_season_id, paddock_id, paddock_row_id,
        row_number, row_label, segment_number,
        completed, completed_at, completed_by, pruning_entry_id
      ) values (
        p_vineyard_id, v_season_id, p_paddock_id, v_row_id,
        v_row_num, v_label, (v_seg->>'segment')::integer,
        true, now(), coalesce(p_worker, ''), p_id
      )
      on conflict (pruning_season_id, paddock_row_id, segment_number) where paddock_row_id is not null
      do update
        set completed = true,
            completed_at = coalesce(public.pruning_row_segments.completed_at, excluded.completed_at),
            completed_by = excluded.completed_by,
            pruning_entry_id = excluded.pruning_entry_id,
            row_number = excluded.row_number,
            row_label = excluded.row_label,
            updated_at = now()
        where public.pruning_row_segments.completed = false;
    else
      insert into public.pruning_row_segments (
        vineyard_id, pruning_season_id, paddock_id,
        row_number, row_label, segment_number,
        completed, completed_at, completed_by, pruning_entry_id
      ) values (
        p_vineyard_id, v_season_id, p_paddock_id,
        v_row_num, v_label, (v_seg->>'segment')::integer,
        true, now(), coalesce(p_worker, ''), p_id
      )
      on conflict (pruning_season_id, row_number, segment_number) where paddock_row_id is null
      do update
        set completed = true,
            completed_at = coalesce(public.pruning_row_segments.completed_at, excluded.completed_at),
            completed_by = excluded.completed_by,
            pruning_entry_id = excluded.pruning_entry_id,
            row_label = excluded.row_label,
            updated_at = now()
        where public.pruning_row_segments.completed = false;
    end if;
  end loop;

  select count(*)::integer into v_attributed
  from public.pruning_row_segments
  where pruning_entry_id = p_id;

  update public.pruning_entries
  set row_equivalents_completed = v_attributed / 4.0,
      estimated_vines_completed = case
        when v_requested > 0 then round(coalesce(p_estimated_vines, 0)::numeric * v_attributed / v_requested)::integer
        else 0
      end,
      updated_at = now()
  where id = p_id;

  return jsonb_build_object(
    'entry_id', p_id,
    'season_id', v_season_id,
    'vintage_year', v_vintage,
    'requested', v_requested,
    'attributed', v_attributed,
    'deleted', false
  );
end;
$$;

revoke all on function public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb, uuid, integer) from public;
grant execute on function public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb, uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Validation — the migration ABORTS if any of these fail
-- ---------------------------------------------------------------------------
do $$
begin
  -- Southern Hemisphere: season start 1 July
  assert public.resolve_vintage_year(date '2026-06-30', 7, 1) = 2026, '1 Jul start: 30 Jun 2026 must be Vintage 2026';
  assert public.resolve_vintage_year(date '2026-07-01', 7, 1) = 2027, '1 Jul start: 1 Jul 2026 must be Vintage 2027';
  assert public.resolve_vintage_year(date '2026-07-15', 7, 1) = 2027, '1 Jul start: 15 Jul 2026 must be Vintage 2027';
  assert public.resolve_vintage_year(date '2027-01-15', 7, 1) = 2027, '1 Jul start: 15 Jan 2027 must be Vintage 2027';

  -- Northern Hemisphere: season start 1 January (season contained in one year)
  assert public.resolve_vintage_year(date '2026-02-15', 1, 1) = 2026, '1 Jan start: 15 Feb 2026 must be Vintage 2026';

  -- Non-standard season: start 1 November
  assert public.resolve_vintage_year(date '2026-10-15', 11, 1) = 2026, '1 Nov start: 15 Oct 2026 must be Vintage 2026';
  assert public.resolve_vintage_year(date '2026-11-15', 11, 1) = 2027, '1 Nov start: 15 Nov 2026 must be Vintage 2027';

  -- Leap-day configuration: 29 Feb start clamps to 28 Feb in non-leap years
  assert public.resolve_vintage_year(date '2026-02-27', 2, 29) = 2026, 'leap cfg: 27 Feb 2026 must be Vintage 2026';
  assert public.resolve_vintage_year(date '2026-02-28', 2, 29) = 2027, 'leap cfg: 28 Feb 2026 must be Vintage 2027';
  assert public.resolve_vintage_year(date '2028-02-28', 2, 29) = 2028, 'leap cfg: 28 Feb 2028 must be Vintage 2028';
  assert public.resolve_vintage_year(date '2028-02-29', 2, 29) = 2029, 'leap cfg: 29 Feb 2028 must be Vintage 2029';
end $$;

-- ---------------------------------------------------------------------------
-- 7. Backfill existing live records (ids, dates, season ids, segments and
--    Work Task links are untouched — ONLY vintage_year is written)
-- ---------------------------------------------------------------------------
update public.pruning_entries e
set vintage_year = public.resolve_vineyard_vintage_year(e.vineyard_id, e.entry_date)
where e.vintage_year is null;

update public.work_tasks t
set vintage_year = public.resolve_vineyard_vintage_year(
      t.vineyard_id,
      (t.date at time zone coalesce(nullif(v.timezone, ''), 'UTC'))::date
    )
from public.vineyards v
where v.id = t.vineyard_id
  and t.vintage_year is null;

-- Make PostgREST pick up the new function signature immediately.
notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 8. Verification (run manually; read-only)
-- ---------------------------------------------------------------------------
-- Backfill result by vintage (expect Stockmans Ridge July-2026 pruning → 2027):
-- select vintage_year, count(*) as entries,
--        min(entry_date) as first_entry, max(entry_date) as last_entry
-- from public.pruning_entries
-- where vineyard_id = 'fe952afe-437f-4be7-8cbf-fdd8e630411c' and deleted_at is null
-- group by vintage_year order by vintage_year;
--
-- Linked Work Tasks (pruning tasks must report under Vintage 2027):
-- select t.vintage_year, count(*) as tasks,
--        coalesce(sum(l.worker_count * l.hours_per_worker * l.hourly_rate), 0) as labour_cost
-- from public.work_tasks t
-- left join public.work_task_labour_lines l on l.work_task_id = t.id and l.deleted_at is null
-- where t.vineyard_id = 'fe952afe-437f-4be7-8cbf-fdd8e630411c' and t.deleted_at is null
--   and exists (select 1 from public.pruning_entries e where e.work_task_id = t.id)
-- group by t.vintage_year order by t.vintage_year;
--
-- Entry/season consistency spot-check (technical season vs costing vintage):
-- select e.entry_date, s.season_year as technical_season, e.vintage_year
-- from public.pruning_entries e
-- join public.pruning_seasons s on s.id = e.pruning_season_id
-- where e.vineyard_id = 'fe952afe-437f-4be7-8cbf-fdd8e630411c' and e.deleted_at is null
-- order by e.entry_date desc limit 20;

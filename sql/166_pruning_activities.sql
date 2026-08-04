-- =============================================================================
-- 166: Pruning ACTIVITIES — one parent record, many per-block allocations.
--
-- WHY
-- A pruning day is one piece of work: one crew, one start and finish time, one
-- set of labour hours, one rate, one note, one linked Work Task. Until now the
-- only unit of storage was `pruning_entries`, which is per BLOCK, so a crew
-- that finished Cabernet Franc and moved into Sauvignon Blanc had to record the
-- day TWICE and split (or duplicate) the labour. Labour was therefore either
-- double-counted or arbitrarily apportioned, and reports could not show "one
-- activity across two blocks".
--
-- THE MODEL (Option 2 — a real parent activity)
--   public.pruning_activities   -- ACTIVITY level, exactly once per activity:
--        vineyard, entry_date, worker_or_crew, pruning_method, start_time,
--        finish_time, labour_hours, hourly_rate, notes, work_task_id,
--        vintage_year, created_by, reversal state, sync identity.
--   public.pruning_entries      -- ALLOCATION level, one row per block:
--        paddock_id, pruning_season_id, rows/quarters (via
--        pruning_row_segments), row_equivalents_completed,
--        estimated_vines_completed.
--
-- `pruning_entries` IS the allocation table. That is the whole point of this
-- design: every existing single-block entry becomes, byte for byte, an activity
-- containing exactly ONE allocation. Nothing is copied, re-keyed or recomputed —
-- no date, season, vintage, block, row, quarter, vine count, worker, labour
-- value, rate, cost, Work Task link, creator or reversal state changes. Every
-- existing read path (SQL 115 summary, the Activity Report, both mobile pulls,
-- the portal) keeps working unchanged, and every segment still belongs to an
-- allocation that carries its own paddock_id.
--
-- LABOUR IS STORED ONCE
-- Canonical labour/timing/rate/task live ONLY on the parent activity. For
-- backwards compatibility the legacy columns on `pruning_entries` are kept as a
-- MIRROR that is populated on the PRIMARY allocation (allocation_index = 0)
-- and NULL on every other allocation. So:
--   * any legacy `sum(labour_hours)` over pruning_entries still counts the
--     activity's hours exactly ONCE, and
--   * the unique index `pruning_entries_work_task_unique` (SQL 114) still
--     holds, because only the primary allocation carries work_task_id.
-- `sync_pruning_activity_rollup` maintains that invariant, including promoting
-- the mirror to the next allocation if the primary one is removed.
--
-- SEASON ENFORCEMENT (SQL 161, applied per allocation)
--   allocation season year = extract(year from ACTIVITY entry_date)
-- resolved independently for every allocation through
-- `resolve_pruning_season`, so a two-block August-2026 activity produces two
-- 2026 season rows (one per block) while the vintage stays 2027. A
-- client-supplied season is never trusted.
--
-- OLDER CLIENTS KEEP WORKING
-- `record_pruning_entry` / `update_pruning_entry` / `delete_pruning_entry` are
-- NOT changed by this migration. Instead a pair of triggers on
-- `pruning_entries` creates and maintains the parent activity for ANY write
-- path, so a one-block submission from an old build (or the portal, or a future
-- RPC) automatically becomes an activity with one allocation. The triggers are
-- re-entrancy guarded and are suppressed while the activity RPCs run, which
-- maintain the parent themselves.
--
-- RPCS ADDED
--   record_pruning_activity   -- create (idempotent on the client activity id)
--   update_pruning_activity   -- full desired state: add/remove/change blocks
--   get_pruning_activity      -- canonical activity + allocations + totals
--   list_pruning_activities   -- vineyard feed with a block summary
--   reverse_pruning_activity  -- reverse the whole activity as ONE operation
-- All are single-transaction: a failed allocation rolls back the entire
-- activity. All return the CANONICAL server state so both apps can replace
-- their local activity and allocations wholesale after sync.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. pruning_activities — the parent record
-- ---------------------------------------------------------------------------
create table if not exists public.pruning_activities (
  -- Client-generated and stable: the idempotency key for offline replays.
  id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  entry_date date not null,
  worker_or_crew text not null default '',
  pruning_method text not null default 'spur',
  start_time timestamptz,
  finish_time timestamptz,
  -- ACTIVITY-LEVEL labour. Never apportioned across blocks.
  labour_hours numeric,
  hourly_rate numeric,
  notes text not null default '',
  work_task_id uuid,
  -- Canonical pruning season year of the activity = year(entry_date) (SQL 161).
  season_year integer,
  -- Costing vintage, resolved independently (SQL 119).
  vintage_year integer,
  -- Roll-ups maintained by sync_pruning_activity_rollup.
  allocation_count integer not null default 0,
  total_quarters integer not null default 0,
  total_row_equivalents numeric not null default 0,
  total_estimated_vines integer not null default 0,
  block_summary text not null default '',
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Reversal state of the WHOLE activity.
  deleted_at timestamptz,
  client_updated_at timestamptz,
  sync_version integer not null default 1
);

create index if not exists pruning_activities_vineyard_idx
  on public.pruning_activities (vineyard_id, entry_date desc);
create index if not exists pruning_activities_updated_idx
  on public.pruning_activities (updated_at);
create index if not exists pruning_activities_work_task_idx
  on public.pruning_activities (work_task_id);

comment on table public.pruning_activities is
  'Parent pruning activity (SQL 166). Labour, timing, rate, notes and the Work Task link exist here exactly ONCE; per-block rows/quarters live in pruning_entries as allocations.';
comment on column public.pruning_activities.labour_hours is
  'Activity-level labour hours. NEVER apportioned or duplicated across allocations; mirrored onto the primary allocation only for legacy readers.';

drop trigger if exists pruning_activities_set_updated_at on public.pruning_activities;
create trigger pruning_activities_set_updated_at
  before update on public.pruning_activities
  for each row execute function public.set_updated_at();

alter table public.pruning_activities enable row level security;

drop policy if exists "pruning_activities_select_members" on public.pruning_activities;
create policy "pruning_activities_select_members" on public.pruning_activities
  for select to authenticated
  using (public.is_vineyard_member(vineyard_id));

-- Writes go through the RPCs only (same contract as pruning_entries, SQL 109).
drop policy if exists "pruning_activities_no_client_insert" on public.pruning_activities;
create policy "pruning_activities_no_client_insert" on public.pruning_activities
  for insert to authenticated with check (false);
drop policy if exists "pruning_activities_no_client_update" on public.pruning_activities;
create policy "pruning_activities_no_client_update" on public.pruning_activities
  for update to authenticated using (false);
drop policy if exists "pruning_activities_no_client_delete" on public.pruning_activities;
create policy "pruning_activities_no_client_delete" on public.pruning_activities
  for delete to authenticated using (false);

-- ---------------------------------------------------------------------------
-- 2. pruning_entries becomes the ALLOCATION table
-- ---------------------------------------------------------------------------
alter table public.pruning_entries
  add column if not exists pruning_activity_id uuid;

alter table public.pruning_entries
  add column if not exists allocation_index integer not null default 0;

comment on column public.pruning_entries.pruning_activity_id is
  'Parent activity (SQL 166). Every entry is an allocation of exactly one activity; legacy single-block entries own an activity with id = the entry id.';
comment on column public.pruning_entries.allocation_index is
  'Position of this allocation within its activity. Index 0 is the PRIMARY allocation and is the only one that mirrors the activity labour_hours / start_time / finish_time / work_task_id.';

create index if not exists pruning_entries_activity_idx
  on public.pruning_entries (pruning_activity_id, allocation_index);

-- One allocation per (activity, block): a replay can never add the same block
-- to the same activity twice.
create unique index if not exists pruning_entries_activity_block_unique
  on public.pruning_entries (pruning_activity_id, paddock_id)
  where pruning_activity_id is not null and deleted_at is null;

-- ---------------------------------------------------------------------------
-- 3. Deterministic allocation id — the same MD5 v3 technique as the season id
--    (SQL 161 §1), so an offline retry recreates the SAME allocation row
--    without the client having to remember it.
--    Name: 'vinetrack-pruning-allocation|{activity}|{paddock}' (lowercase).
-- ---------------------------------------------------------------------------
create or replace function public.derive_pruning_allocation_id(
  p_activity_id uuid,
  p_paddock_id uuid
) returns uuid
language plpgsql immutable
as $$
declare
  v_bytes bytea;
begin
  v_bytes := decode(md5('vinetrack-pruning-allocation|' || lower(p_activity_id::text)
    || '|' || lower(p_paddock_id::text)), 'hex');
  v_bytes := set_byte(v_bytes, 6, ((get_byte(v_bytes, 6) & 15) | 48));   -- version 3
  v_bytes := set_byte(v_bytes, 8, ((get_byte(v_bytes, 8) & 63) | 128));  -- IETF variant
  return encode(v_bytes, 'hex')::uuid;
end;
$$;

revoke all on function public.derive_pruning_allocation_id(uuid, uuid) from public, anon;
grant execute on function public.derive_pruning_allocation_id(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. sync_pruning_activity_rollup — THE invariant keeper.
--
--    * recomputes the parent totals from the LIVE allocations,
--    * keeps the labour / timing / task mirror on exactly ONE live allocation
--      (the lowest allocation_index), promoting it if the primary is removed,
--      so legacy sums over pruning_entries can never double-count labour,
--    * reverses the parent when no live allocation remains, and un-reverses it
--      when one comes back,
--    * keeps season_year = year(entry_date).
--
--    Idempotent, re-entrancy safe, and never touches segments.
-- ---------------------------------------------------------------------------
create or replace function public.sync_pruning_activity_rollup(p_activity_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_prev_lock text;
  v_act public.pruning_activities%rowtype;
  v_primary uuid;
  v_live integer := 0;
  v_any integer := 0;
  v_quarters integer := 0;
  v_row_eq numeric := 0;
  v_vines integer := 0;
  v_summary text := '';
  v_last_reversal timestamptz;
begin
  if p_activity_id is null then
    return;
  end if;

  select * into v_act from public.pruning_activities where id = p_activity_id;
  if not found then
    return;
  end if;

  -- Hold the trigger lock for the duration; restore whatever the caller had so
  -- a nested call cannot unlock an outer one.
  v_prev_lock := coalesce(current_setting('vinetrack.pruning_activity_lock', true), '');
  perform set_config('vinetrack.pruning_activity_lock', '1', true);

  select count(*) into v_any
  from public.pruning_entries where pruning_activity_id = p_activity_id;

  select count(*)::integer,
         coalesce(sum(e.estimated_vines_completed), 0)::integer,
         coalesce(sum(e.row_equivalents_completed), 0)::numeric
    into v_live, v_vines, v_row_eq
  from public.pruning_entries e
  where e.pruning_activity_id = p_activity_id and e.deleted_at is null;

  select max(e.deleted_at) into v_last_reversal
  from public.pruning_entries e
  where e.pruning_activity_id = p_activity_id;

  select count(*)::integer into v_quarters
  from public.pruning_row_segments s
  join public.pruning_entries e on e.id = s.pruning_entry_id
  where e.pruning_activity_id = p_activity_id and e.deleted_at is null;

  -- "Cab Franc + Sauvignon Blanc" — allocation order, duplicates collapsed.
  select coalesce(string_agg(t.name, ' + ' order by t.ord, t.name), '') into v_summary
  from (
    select coalesce(nullif(p.name, ''), 'Block') as name,
           min(e.allocation_index) as ord
    from public.pruning_entries e
    join public.paddocks p on p.id = e.paddock_id
    where e.pruning_activity_id = p_activity_id and e.deleted_at is null
    group by 1
  ) t;

  -- The primary allocation: lowest index among the live ones (stable tie-break).
  select id into v_primary
  from public.pruning_entries
  where pruning_activity_id = p_activity_id and deleted_at is null
  order by allocation_index, id
  limit 1;

  -- Mirror the activity's labour / timing / task onto the primary allocation
  -- ONLY. Every other allocation carries NULL, so labour exists once and the
  -- work-task unique index (SQL 114) can never be violated.
  if v_primary is not null then
    update public.pruning_entries
    set labour_hours = v_act.labour_hours,
        start_time = v_act.start_time,
        finish_time = v_act.finish_time,
        work_task_id = v_act.work_task_id,
        updated_at = now()
    where id = v_primary
      and (labour_hours is distinct from v_act.labour_hours
        or start_time is distinct from v_act.start_time
        or finish_time is distinct from v_act.finish_time
        or work_task_id is distinct from v_act.work_task_id);
  end if;

  update public.pruning_entries
  set labour_hours = null,
      start_time = null,
      finish_time = null,
      work_task_id = null,
      updated_at = now()
  where pruning_activity_id = p_activity_id
    and (v_primary is null or id <> v_primary)
    and deleted_at is null
    and (labour_hours is not null or start_time is not null
      or finish_time is not null or work_task_id is not null);

  update public.pruning_activities
  set allocation_count = v_live,
      total_quarters = v_quarters,
      total_row_equivalents = coalesce(v_row_eq, 0),
      total_estimated_vines = coalesce(v_vines, 0),
      block_summary = v_summary,
      season_year = extract(year from entry_date)::integer,
      -- No live allocation left => the activity itself is reversed. One coming
      -- back un-reverses it (an edit that re-adds a block).
      deleted_at = case
        when v_any > 0 and v_live = 0 then coalesce(deleted_at, v_last_reversal, now())
        when v_live > 0 then null
        else deleted_at
      end,
      updated_at = now()
  where id = p_activity_id;

  perform set_config('vinetrack.pruning_activity_lock', v_prev_lock, true);
end;
$$;

revoke all on function public.sync_pruning_activity_rollup(uuid) from public, anon;

-- ---------------------------------------------------------------------------
-- 5. Triggers — ANY write path to pruning_entries gets a parent activity.
--    This is what keeps `record_pruning_entry` / `update_pruning_entry` /
--    `delete_pruning_entry` (and the portal, and any future RPC) working
--    unchanged: a one-block write becomes an activity with one allocation.
-- ---------------------------------------------------------------------------
create or replace function public.pruning_entry_activity_default()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- A legacy single-block entry owns an activity keyed by its OWN id: stable,
  -- collision-free, and it makes the back-fill a pure projection.
  if new.pruning_activity_id is null then
    new.pruning_activity_id := new.id;
    new.allocation_index := 0;
  end if;
  return new;
end;
$$;

create or replace function public.pruning_entry_activity_sync()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.pruning_entries;
begin
  -- Suppressed while the activity RPCs (and the rollup) run: they maintain the
  -- parent themselves, and mirroring an allocation back onto the parent there
  -- would fight the caller's intent.
  if coalesce(current_setting('vinetrack.pruning_activity_lock', true), '') = '1' then
    return null;
  end if;

  v_row := coalesce(new, old);
  if v_row.pruning_activity_id is null then
    return null;
  end if;

  perform set_config('vinetrack.pruning_activity_lock', '1', true);

  -- Create the parent on first sight, projecting the entry's own values.
  insert into public.pruning_activities (
    id, vineyard_id, entry_date, worker_or_crew, pruning_method,
    start_time, finish_time, labour_hours, notes, work_task_id,
    season_year, vintage_year, created_by, created_at, updated_at,
    deleted_at, client_updated_at
  ) values (
    v_row.pruning_activity_id, v_row.vineyard_id, v_row.entry_date,
    v_row.worker_or_crew, v_row.pruning_method,
    v_row.start_time, v_row.finish_time, v_row.labour_hours, v_row.notes,
    v_row.work_task_id,
    extract(year from v_row.entry_date)::integer, v_row.vintage_year,
    v_row.created_by, v_row.created_at, v_row.updated_at,
    v_row.deleted_at, v_row.client_updated_at
  )
  on conflict (id) do nothing;

  -- Legacy edits/reversals arrive on the ALLOCATION. Mirror the activity-level
  -- fields up to the parent, but only from the PRIMARY allocation — a
  -- secondary block never rewrites the shared labour or timing.
  -- A reversal never mirrors up: a soft-deleted secondary allocation carries
  -- NULL labour, which would otherwise wipe the activity's shared hours.
  if tg_op <> 'DELETE' and new.allocation_index = 0 and new.deleted_at is null then
    update public.pruning_activities a
    set entry_date = new.entry_date,
        worker_or_crew = new.worker_or_crew,
        pruning_method = new.pruning_method,
        start_time = new.start_time,
        finish_time = new.finish_time,
        labour_hours = new.labour_hours,
        notes = new.notes,
        work_task_id = new.work_task_id,
        vintage_year = coalesce(new.vintage_year, a.vintage_year),
        updated_by = new.updated_by,
        client_updated_at = coalesce(new.client_updated_at, a.client_updated_at),
        updated_at = now()
    where a.id = new.pruning_activity_id
      -- Only when this really is a single-allocation activity, or the values
      -- genuinely came from the shared record. Multi-block activities are
      -- driven by update_pruning_activity, which holds the lock above.
      and (select count(*) from public.pruning_entries e
           where e.pruning_activity_id = a.id and e.deleted_at is null) <= 1;
  end if;

  perform public.sync_pruning_activity_rollup(v_row.pruning_activity_id);
  perform set_config('vinetrack.pruning_activity_lock', '', true);
  return null;
end;
$$;

drop trigger if exists pruning_entries_activity_default on public.pruning_entries;
create trigger pruning_entries_activity_default
  before insert on public.pruning_entries
  for each row execute function public.pruning_entry_activity_default();

drop trigger if exists pruning_entries_activity_sync on public.pruning_entries;
create trigger pruning_entries_activity_sync
  after insert or update on public.pruning_entries
  for each row execute function public.pruning_entry_activity_sync();

-- ---------------------------------------------------------------------------
-- 6. Back-fill — every EXISTING entry becomes a one-allocation activity.
--    Pure projection: created_at / updated_at / deleted_at / vintage / season /
--    labour / rate / task / creator are copied, never recomputed.
-- ---------------------------------------------------------------------------
do $$
declare
  v_prev text;
  v_activities integer;
  v_entries integer;
begin
  v_prev := coalesce(current_setting('vinetrack.pruning_activity_lock', true), '');
  perform set_config('vinetrack.pruning_activity_lock', '1', true);

  update public.pruning_entries
  set pruning_activity_id = id, allocation_index = 0
  where pruning_activity_id is null;

  insert into public.pruning_activities (
    id, vineyard_id, entry_date, worker_or_crew, pruning_method,
    start_time, finish_time, labour_hours, notes, work_task_id,
    season_year, vintage_year, allocation_count, total_quarters,
    total_row_equivalents, total_estimated_vines, block_summary,
    created_by, updated_by, created_at, updated_at, deleted_at,
    client_updated_at, sync_version
  )
  select e.id, e.vineyard_id, e.entry_date, e.worker_or_crew, e.pruning_method,
         e.start_time, e.finish_time, e.labour_hours, e.notes, e.work_task_id,
         extract(year from e.entry_date)::integer, e.vintage_year,
         case when e.deleted_at is null then 1 else 0 end,
         coalesce((select count(*) from public.pruning_row_segments s
                   where s.pruning_entry_id = e.id), 0),
         coalesce(e.row_equivalents_completed, 0),
         coalesce(e.estimated_vines_completed, 0),
         coalesce((select nullif(p.name, '') from public.paddocks p where p.id = e.paddock_id), 'Block'),
         e.created_by, e.updated_by, e.created_at, e.updated_at, e.deleted_at,
         e.client_updated_at, coalesce(e.sync_version, 1)
  from public.pruning_entries e
  where e.pruning_activity_id = e.id
  on conflict (id) do nothing;

  perform set_config('vinetrack.pruning_activity_lock', v_prev, true);

  select count(*) into v_activities from public.pruning_activities;
  select count(*) into v_entries from public.pruning_entries where pruning_activity_id is null;
  if v_entries > 0 then
    raise exception 'SQL 166 back-fill: % entries still have no parent activity', v_entries;
  end if;
  raise notice 'SQL 166 back-fill: % activities now exist, every entry has a parent', v_activities;
end$$;

-- ---------------------------------------------------------------------------
-- 7. Canonical response shape — the ONE definition both apps adopt after sync.
-- ---------------------------------------------------------------------------
create or replace function public.pruning_activity_json(
  p_activity_id uuid,
  p_include_segments boolean default true
) returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_act public.pruning_activities%rowtype;
  v_allocations jsonb;
  v_duration numeric;
begin
  select * into v_act from public.pruning_activities where id = p_activity_id;
  if not found then
    return null;
  end if;

  if v_act.start_time is not null and v_act.finish_time is not null
     and v_act.finish_time > v_act.start_time then
    v_duration := round(extract(epoch from (v_act.finish_time - v_act.start_time))::numeric / 3600.0, 4);
  end if;

  select coalesce(jsonb_agg(a order by a_index), '[]'::jsonb) into v_allocations
  from (
    select e.allocation_index as a_index,
           jsonb_build_object(
             'id', e.id,
             'allocation_index', e.allocation_index,
             'paddock_id', e.paddock_id,
             'block_name', coalesce((select nullif(p.name, '') from public.paddocks p where p.id = e.paddock_id), 'Block'),
             'pruning_season_id', e.pruning_season_id,
             'season_year', (select s.season_year from public.pruning_seasons s where s.id = e.pruning_season_id),
             'vintage_year', e.vintage_year,
             'rows', coalesce((
               select jsonb_agg(distinct g.row_number)
               from public.pruning_row_segments g
               where g.pruning_entry_id = e.id
             ), '[]'::jsonb),
             'quarters', coalesce((
               select count(*) from public.pruning_row_segments g where g.pruning_entry_id = e.id
             ), 0),
             'row_equivalents', coalesce(e.row_equivalents_completed, 0),
             'estimated_vines', coalesce(e.estimated_vines_completed, 0),
             'is_reversed', e.deleted_at is not null,
             'reversed_at', e.deleted_at,
             'segments', case when p_include_segments then coalesce((
               select jsonb_agg(jsonb_build_object(
                        'row', g.row_number,
                        'segment', g.segment_number,
                        'row_id', g.paddock_row_id,
                        'label', g.row_label
                      ) order by g.row_number, g.segment_number)
               from public.pruning_row_segments g
               where g.pruning_entry_id = e.id
             ), '[]'::jsonb) else null end
           ) as a
    from public.pruning_entries e
    where e.pruning_activity_id = p_activity_id
      and e.deleted_at is null
  ) t;

  return jsonb_build_object(
    'activity', jsonb_build_object(
      'id', v_act.id,
      'vineyard_id', v_act.vineyard_id,
      'entry_date', v_act.entry_date,
      'worker_or_crew', v_act.worker_or_crew,
      'method', v_act.pruning_method,
      'start_time', v_act.start_time,
      'finish_time', v_act.finish_time,
      'duration_hours', v_duration,
      'labour_hours', v_act.labour_hours,
      'hourly_rate', v_act.hourly_rate,
      'labour_cost', case
        when v_act.labour_hours is not null and v_act.hourly_rate is not null
        then round(v_act.labour_hours * v_act.hourly_rate, 2) end,
      'notes', v_act.notes,
      'work_task_id', v_act.work_task_id,
      'season_year', v_act.season_year,
      'vintage_year', v_act.vintage_year,
      'is_reversed', v_act.deleted_at is not null,
      'reversed_at', v_act.deleted_at,
      'created_by', v_act.created_by,
      'created_at', v_act.created_at,
      'updated_at', v_act.updated_at,
      'client_updated_at', v_act.client_updated_at,
      'sync_version', v_act.sync_version
    ),
    'allocations', v_allocations,
    'totals', jsonb_build_object(
      'allocation_count', v_act.allocation_count,
      'block_summary', v_act.block_summary,
      'quarters', v_act.total_quarters,
      'row_equivalents', v_act.total_row_equivalents,
      'estimated_vines', v_act.total_estimated_vines,
      -- Shared labour, counted ONCE for the whole activity.
      'labour_hours', v_act.labour_hours,
      'hourly_rate', v_act.hourly_rate,
      'labour_cost', case
        when v_act.labour_hours is not null and v_act.hourly_rate is not null
        then round(v_act.labour_hours * v_act.hourly_rate, 2) end
    )
  );
end;
$$;

revoke all on function public.pruning_activity_json(uuid, boolean) from public, anon;

-- ---------------------------------------------------------------------------
-- 8. apply_pruning_activity_allocation — ONE allocation, inside the caller's
--    transaction. Season resolution, segment claim/release, attribution and
--    totals for a single block. Raises on an invalid block so the whole
--    activity rolls back.
-- ---------------------------------------------------------------------------
create or replace function public.apply_pruning_activity_allocation(
  p_activity_id uuid,
  p_vineyard_id uuid,
  p_entry_date date,
  p_worker text,
  p_method text,
  p_notes text,
  p_vintage_year integer,
  p_client_updated_at timestamptz,
  p_allocation jsonb,
  p_allocation_index integer
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_paddock uuid;
  v_alloc uuid;
  v_season uuid;
  v_prev_season uuid;
  v_segs jsonb := '[]'::jsonb;
  v_raw integer := 0;
  v_requested integer := 0;
  v_attributed integer := 0;
  v_removed integer := 0;
  v_conflicts jsonb := '[]'::jsonb;
  v_keys text[] := '{}';
  v_seg jsonb;
  v_row_id uuid;
  v_row_num integer;
  v_seg_num integer;
  v_label text;
  v_owner uuid;
  v_vines integer;
begin
  begin
    v_paddock := nullif(p_allocation->>'paddock_id', '')::uuid;
  exception when others then
    v_paddock := null;
  end;
  if v_paddock is null then
    raise exception 'pruning allocation is missing paddock_id';
  end if;

  -- An invalid or foreign block aborts the whole activity (atomicity rule).
  if not exists (
    select 1 from public.paddocks
    where id = v_paddock and vineyard_id = p_vineyard_id and deleted_at is null
  ) then
    raise exception 'pruning allocation block % does not belong to this vineyard', v_paddock;
  end if;

  begin
    v_alloc := coalesce(
      nullif(p_allocation->>'id', '')::uuid,
      nullif(p_allocation->>'allocation_id', '')::uuid
    );
  exception when others then
    v_alloc := null;
  end;
  v_alloc := coalesce(v_alloc, public.derive_pruning_allocation_id(p_activity_id, v_paddock));

  -- CANONICAL season per allocation, from the ACTIVITY date (SQL 161).
  v_season := public.resolve_pruning_season(
    p_vineyard_id, v_paddock, p_entry_date, null, p_client_updated_at
  );

  -- ---- canonicalise the requested quarter set -----------------------------
  select count(*) into v_raw
  from jsonb_array_elements(
    case when jsonb_typeof(p_allocation->'segments') = 'array'
      then p_allocation->'segments' else '[]'::jsonb end
  );

  with raw as (
    select coalesce(nullif(e->>'row', '')::integer, 0) as row_num,
           coalesce(nullif(e->>'segment', '')::integer, 0) as seg_num,
           lower(nullif(e->>'row_id', '')) as row_id,
           nullif(e->>'label', '') as label
    from jsonb_array_elements(
      case when jsonb_typeof(p_allocation->'segments') = 'array'
        then p_allocation->'segments' else '[]'::jsonb end
    ) e
  ),
  keyed as (
    select *, coalesce(row_id, 'n' || row_num::text) as k
    from raw where seg_num between 1 and 4
  ),
  uniq as (
    select distinct on (k, seg_num) * from keyed order by k, seg_num, label nulls last
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'row', row_num, 'segment', seg_num, 'row_id', row_id, 'label', label
         ) order by row_num, seg_num), '[]'::jsonb)
  into v_segs from uniq;

  -- Convenience form: whole rows (all four quarters each).
  if v_segs = '[]'::jsonb and jsonb_typeof(p_allocation->'rows') = 'array' then
    select coalesce(jsonb_agg(jsonb_build_object('row', r, 'segment', q)
             order by r, q), '[]'::jsonb)
    into v_segs
    from (select distinct nullif(e, '')::integer as r
          from jsonb_array_elements_text(p_allocation->'rows') e) rr,
         generate_series(1, 4) q
    where rr.r is not null;
    v_raw := jsonb_array_length(v_segs);
  end if;

  v_requested := coalesce(jsonb_array_length(v_segs), 0);
  v_vines := coalesce(nullif(p_allocation->>'estimated_vines', '')::integer, 0);

  -- ---- the allocation row -------------------------------------------------
  select pruning_season_id into v_prev_season
  from public.pruning_entries where id = v_alloc;

  insert into public.pruning_entries (
    id, vineyard_id, pruning_season_id, paddock_id, entry_date, worker_or_crew,
    pruning_method, notes, vintage_year, created_by, client_updated_at,
    pruning_activity_id, allocation_index
  ) values (
    v_alloc, p_vineyard_id, v_season, v_paddock, p_entry_date, coalesce(p_worker, ''),
    coalesce(p_method, 'spur'), coalesce(p_notes, ''), p_vintage_year, auth.uid(),
    p_client_updated_at, p_activity_id, p_allocation_index
  )
  on conflict (id) do update
  set pruning_season_id = excluded.pruning_season_id,
      paddock_id = excluded.paddock_id,
      entry_date = excluded.entry_date,
      worker_or_crew = excluded.worker_or_crew,
      pruning_method = excluded.pruning_method,
      notes = excluded.notes,
      vintage_year = excluded.vintage_year,
      client_updated_at = excluded.client_updated_at,
      pruning_activity_id = excluded.pruning_activity_id,
      allocation_index = excluded.allocation_index,
      -- Re-adding a previously removed block revives its allocation in place.
      deleted_at = null,
      updated_by = auth.uid(),
      updated_at = now();

  -- A date edit that crossed a pruning year moves this allocation's quarters
  -- with it; a quarter the target season already holds is released, never
  -- stolen (identical rule to SQL 161 §4).
  if v_prev_season is not null and v_prev_season is distinct from v_season then
    update public.pruning_row_segments s
    set completed = false, completed_at = null, completed_by = null,
        pruning_entry_id = null, updated_at = now()
    where s.pruning_entry_id = v_alloc
      and exists (
        select 1 from public.pruning_row_segments x
        where x.pruning_season_id = v_season
          and x.segment_number = s.segment_number
          and (
            (s.paddock_row_id is not null and x.paddock_row_id = s.paddock_row_id)
            or (s.paddock_row_id is null and x.paddock_row_id is null and x.row_number = s.row_number)
          )
      );

    update public.pruning_row_segments s
    set pruning_season_id = v_season, updated_at = now()
    where s.pruning_entry_id = v_alloc;
  end if;

  -- ---- pass 1: claim every quarter in the new set -------------------------
  for v_seg in select * from jsonb_array_elements(v_segs)
  loop
    v_row_num := coalesce(nullif(v_seg->>'row', '')::integer, 0);
    v_seg_num := coalesce(nullif(v_seg->>'segment', '')::integer, 0);
    v_label := coalesce(nullif(v_seg->>'label', ''), v_row_num::text);
    begin
      v_row_id := nullif(v_seg->>'row_id', '')::uuid;
    exception when others then
      v_row_id := null;
    end;

    if v_row_id is null then
      select (elem->>'id')::uuid into v_row_id
      from public.paddocks p
      cross join lateral jsonb_array_elements(coalesce(p.rows, '[]'::jsonb)) elem
      where p.id = v_paddock
        and jsonb_typeof(elem->'number') = 'number'
        and (elem->>'number')::integer = v_row_num
        and (elem->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      limit 1;
    end if;

    if v_row_id is not null then
      v_keys := array_append(v_keys, 'id:' || lower(v_row_id::text) || ':' || v_seg_num);

      update public.pruning_row_segments s
      set paddock_row_id = v_row_id,
          row_label = coalesce(s.row_label, v_label),
          updated_at = now()
      where s.pruning_season_id = v_season
        and s.paddock_row_id is null
        and s.row_number = v_row_num
        and not exists (
          select 1 from public.pruning_row_segments x
          where x.pruning_season_id = v_season
            and x.paddock_row_id = v_row_id
            and x.segment_number = s.segment_number
        );

      insert into public.pruning_row_segments (
        vineyard_id, pruning_season_id, paddock_id, paddock_row_id,
        row_number, row_label, segment_number,
        completed, completed_at, completed_by, pruning_entry_id
      ) values (
        p_vineyard_id, v_season, v_paddock, v_row_id,
        v_row_num, v_label, v_seg_num,
        true, now(), coalesce(p_worker, ''), v_alloc
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

      select pruning_entry_id into v_owner
      from public.pruning_row_segments
      where pruning_season_id = v_season
        and paddock_row_id = v_row_id
        and segment_number = v_seg_num
      limit 1;
    else
      v_keys := array_append(v_keys, 'num:' || v_row_num || ':' || v_seg_num);

      insert into public.pruning_row_segments (
        vineyard_id, pruning_season_id, paddock_id,
        row_number, row_label, segment_number,
        completed, completed_at, completed_by, pruning_entry_id
      ) values (
        p_vineyard_id, v_season, v_paddock,
        v_row_num, v_label, v_seg_num,
        true, now(), coalesce(p_worker, ''), v_alloc
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

      select pruning_entry_id into v_owner
      from public.pruning_row_segments
      where pruning_season_id = v_season
        and paddock_row_id is null
        and row_number = v_row_num
        and segment_number = v_seg_num
      limit 1;
    end if;

    if v_owner is distinct from v_alloc then
      v_conflicts := v_conflicts || jsonb_build_object(
        'paddock_id', v_paddock, 'row', v_row_num, 'segment', v_seg_num,
        'reason', 'already_completed_by_another_entry'
      );
    end if;
  end loop;

  -- ---- pass 2: release quarters removed from this allocation ---------------
  update public.pruning_row_segments s
  set completed = false, completed_at = null, completed_by = null,
      pruning_entry_id = null, updated_at = now()
  where s.pruning_entry_id = v_alloc
    and not (
      (case
        when s.paddock_row_id is not null then 'id:' || lower(s.paddock_row_id::text) || ':' || s.segment_number
        else 'num:' || s.row_number || ':' || s.segment_number
      end) = any (v_keys)
    );
  get diagnostics v_removed = row_count;

  select count(*)::integer into v_attributed
  from public.pruning_row_segments where pruning_entry_id = v_alloc;

  update public.pruning_entries
  set row_equivalents_completed = v_attributed / 4.0,
      estimated_vines_completed = case
        when v_requested > 0
        then round(v_vines::numeric * least(v_attributed, v_requested) / v_requested)::integer
        else 0
      end,
      updated_at = now()
  where id = v_alloc;

  return jsonb_build_object(
    'allocation_id', v_alloc,
    'paddock_id', v_paddock,
    'allocation_index', p_allocation_index,
    'pruning_season_id', v_season,
    'season_year', (select season_year from public.pruning_seasons where id = v_season),
    'vintage_year', p_vintage_year,
    'season_changed', v_prev_season is not null and v_prev_season is distinct from v_season,
    'requested', v_requested,
    'attributed', v_attributed,
    'removed', v_removed,
    'duplicates_removed', greatest(v_raw - v_requested, 0),
    'quarters_declared', nullif(p_allocation->>'quarters', '')::integer,
    'conflicts', v_conflicts
  );
end;
$$;

revoke all on function public.apply_pruning_activity_allocation(
  uuid, uuid, date, text, text, text, integer, timestamptz, jsonb, integer) from public, anon;

-- ---------------------------------------------------------------------------
-- 9. RPC: record_pruning_activity
--    Idempotent on the client-generated p_activity_id — replaying the same
--    activity never creates a second parent or duplicate allocations.
-- ---------------------------------------------------------------------------
create or replace function public.record_pruning_activity(
  p_activity_id uuid,
  p_vineyard_id uuid,
  p_activity jsonb,
  p_allocations jsonb,
  p_client_updated_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_prev_lock text;
  v_date date;
  v_vintage integer;
  v_task uuid;
  v_alloc jsonb;
  v_index integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_conflicts jsonb := '[]'::jsonb;
  v_one jsonb;
  v_existing public.pruning_activities%rowtype;
  v_pre_exists boolean := false;
  v_created boolean := false;
begin
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;
  if p_activity_id is null then
    raise exception 'pruning activity id is required';
  end if;

  v_date := nullif(p_activity->>'entry_date', '')::date;
  if v_date is null then
    raise exception 'pruning activity entry_date is required';
  end if;
  if jsonb_typeof(p_allocations) <> 'array' or jsonb_array_length(p_allocations) = 0 then
    raise exception 'a pruning activity needs at least one block allocation';
  end if;

  -- Never resurrect a reversed activity from a queued replay.
  select * into v_existing from public.pruning_activities where id = p_activity_id;
  v_pre_exists := v_existing.id is not null;
  if v_pre_exists and v_existing.deleted_at is not null then
    return jsonb_build_object(
      'activity_id', p_activity_id, 'reversed', true, 'created', false,
      'canonical', public.pruning_activity_json(p_activity_id)
    );
  end if;

  -- Vintage: resolved ONCE for the whole activity (SQL 119).
  v_vintage := public.resolve_vineyard_vintage_year(p_vineyard_id, v_date);

  -- One Work Task per activity; a task already owned elsewhere is dropped
  -- rather than failing the offline queue (same rule as SQL 114).
  begin
    v_task := nullif(p_activity->>'work_task_id', '')::uuid;
  exception when others then
    v_task := null;
  end;
  if v_task is not null and (
    exists (select 1 from public.pruning_activities
            where work_task_id = v_task and id <> p_activity_id and deleted_at is null)
    or exists (select 1 from public.pruning_entries
               where work_task_id = v_task and pruning_activity_id <> p_activity_id and deleted_at is null)
  ) then
    v_task := null;
  end if;

  v_prev_lock := coalesce(current_setting('vinetrack.pruning_activity_lock', true), '');
  perform set_config('vinetrack.pruning_activity_lock', '1', true);

  insert into public.pruning_activities (
    id, vineyard_id, entry_date, worker_or_crew, pruning_method,
    start_time, finish_time, labour_hours, hourly_rate, notes, work_task_id,
    season_year, vintage_year, created_by, client_updated_at
  ) values (
    p_activity_id, p_vineyard_id, v_date,
    coalesce(p_activity->>'worker_or_crew', ''),
    coalesce(nullif(p_activity->>'method', ''), 'spur'),
    nullif(p_activity->>'start_time', '')::timestamptz,
    nullif(p_activity->>'finish_time', '')::timestamptz,
    nullif(p_activity->>'labour_hours', '')::numeric,
    nullif(p_activity->>'hourly_rate', '')::numeric,
    coalesce(p_activity->>'notes', ''),
    v_task,
    extract(year from v_date)::integer, v_vintage,
    auth.uid(), p_client_updated_at
  )
  on conflict (id) do nothing;
  v_created := not v_pre_exists;

  for v_alloc in select * from jsonb_array_elements(p_allocations)
  loop
    v_one := public.apply_pruning_activity_allocation(
      p_activity_id, p_vineyard_id, v_date,
      coalesce(p_activity->>'worker_or_crew', ''),
      coalesce(nullif(p_activity->>'method', ''), 'spur'),
      coalesce(p_activity->>'notes', ''),
      v_vintage, p_client_updated_at, v_alloc, v_index
    );
    v_results := v_results || v_one;
    v_conflicts := v_conflicts || coalesce(v_one->'conflicts', '[]'::jsonb);
    v_index := v_index + 1;
  end loop;

  perform public.sync_pruning_activity_rollup(p_activity_id);
  perform set_config('vinetrack.pruning_activity_lock', v_prev_lock, true);

  insert into public.pruning_entry_audit (
    vineyard_id, pruning_entry_id, event_type, new_quarters, new_labour_hours, detail, created_by
  )
  select p_vineyard_id, p_activity_id, 'pruning_entry_created',
         a.total_quarters, a.labour_hours,
         jsonb_build_object(
           'activity_id', p_activity_id,
           'allocations', v_results,
           'block_summary', a.block_summary
         ),
         auth.uid()
  from public.pruning_activities a
  where a.id = p_activity_id and v_created;

  return jsonb_build_object(
    'activity_id', p_activity_id,
    'created', v_created,
    'reversed', false,
    'allocation_results', v_results,
    'conflicts', v_conflicts,
    'canonical', public.pruning_activity_json(p_activity_id)
  );
end;
$$;

revoke all on function public.record_pruning_activity(uuid, uuid, jsonb, jsonb, timestamptz) from public, anon;
grant execute on function public.record_pruning_activity(uuid, uuid, jsonb, jsonb, timestamptz) to authenticated;

-- Nested-payload convenience form for the portal:
--   select record_pruning_activity('{"activity":{...},"allocations":[...]}'::jsonb);
create or replace function public.record_pruning_activity(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  return public.record_pruning_activity(
    coalesce(nullif(p_payload#>>'{activity,id}', '')::uuid, gen_random_uuid()),
    nullif(p_payload#>>'{activity,vineyard_id}', '')::uuid,
    coalesce(p_payload->'activity', '{}'::jsonb),
    coalesce(p_payload->'allocations', '[]'::jsonb),
    nullif(p_payload#>>'{activity,client_updated_at}', '')::timestamptz
  );
end;
$$;

revoke all on function public.record_pruning_activity(jsonb) from public, anon;
grant execute on function public.record_pruning_activity(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. RPC: update_pruning_activity — FULL desired state, one transaction.
--     Adds a block, removes a block, changes rows/quarters, changes labour
--     without touching allocations, changes the date and re-resolves EVERY
--     allocation's season. Removing one allocation never deletes the parent
--     while other allocations remain.
-- ---------------------------------------------------------------------------
create or replace function public.update_pruning_activity(
  p_activity_id uuid,
  p_activity jsonb,
  p_allocations jsonb,
  p_client_updated_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_prev_lock text;
  v_act public.pruning_activities%rowtype;
  v_date date;
  v_vintage integer;
  v_task uuid;
  v_clear_task boolean;
  v_alloc jsonb;
  v_index integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_conflicts jsonb := '[]'::jsonb;
  v_one jsonb;
  v_kept uuid[] := '{}';
  v_removed jsonb := '[]'::jsonb;
  v_prev_quarters integer;
  v_task_conflict boolean := false;
begin
  select * into v_act from public.pruning_activities where id = p_activity_id;
  if not found then
    return jsonb_build_object('activity_id', p_activity_id, 'error', 'activity_not_found');
  end if;
  if v_act.deleted_at is not null then
    return jsonb_build_object('activity_id', p_activity_id, 'error', 'activity_reversed');
  end if;
  if not public.has_vineyard_role(v_act.vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;

  -- Last-write-wins: an edit older than the stored client stamp is ignored.
  if v_act.client_updated_at is not null and p_client_updated_at is not null
     and p_client_updated_at < v_act.client_updated_at then
    return jsonb_build_object(
      'activity_id', p_activity_id, 'stale', true,
      'canonical', public.pruning_activity_json(p_activity_id)
    );
  end if;

  v_date := coalesce(nullif(p_activity->>'entry_date', '')::date, v_act.entry_date);
  if jsonb_typeof(p_allocations) <> 'array' or jsonb_array_length(p_allocations) = 0 then
    raise exception 'a pruning activity needs at least one block allocation';
  end if;

  v_vintage := public.resolve_vineyard_vintage_year(v_act.vineyard_id, v_date);
  v_prev_quarters := v_act.total_quarters;

  -- Work Task: explicit clear wins; a task owned elsewhere is refused, kept.
  v_clear_task := coalesce((p_activity->>'clear_work_task')::boolean, false);
  begin
    v_task := nullif(p_activity->>'work_task_id', '')::uuid;
  exception when others then
    v_task := null;
  end;
  if v_clear_task then
    v_task := null;
  elsif v_task is null then
    v_task := v_act.work_task_id;
  elsif v_task is distinct from v_act.work_task_id then
    if exists (select 1 from public.work_tasks
               where id = v_task and vineyard_id <> v_act.vineyard_id) then
      raise exception 'work task belongs to a different vineyard';
    end if;
    if exists (select 1 from public.pruning_activities
               where work_task_id = v_task and id <> p_activity_id and deleted_at is null)
       or exists (select 1 from public.pruning_entries
                  where work_task_id = v_task and pruning_activity_id <> p_activity_id and deleted_at is null) then
      v_task_conflict := true;
      v_task := v_act.work_task_id;
    end if;
  end if;

  v_prev_lock := coalesce(current_setting('vinetrack.pruning_activity_lock', true), '');
  perform set_config('vinetrack.pruning_activity_lock', '1', true);

  -- Activity-level fields FIRST: the rollup mirrors them onto the primary
  -- allocation afterwards, so labour can change without touching allocations.
  update public.pruning_activities
  set entry_date = v_date,
      worker_or_crew = coalesce(p_activity->>'worker_or_crew', worker_or_crew),
      pruning_method = coalesce(nullif(p_activity->>'method', ''), pruning_method),
      start_time = case when p_activity ? 'start_time'
        then nullif(p_activity->>'start_time', '')::timestamptz else start_time end,
      finish_time = case when p_activity ? 'finish_time'
        then nullif(p_activity->>'finish_time', '')::timestamptz else finish_time end,
      labour_hours = case when p_activity ? 'labour_hours'
        then nullif(p_activity->>'labour_hours', '')::numeric else labour_hours end,
      hourly_rate = case when p_activity ? 'hourly_rate'
        then nullif(p_activity->>'hourly_rate', '')::numeric else hourly_rate end,
      notes = coalesce(p_activity->>'notes', notes),
      work_task_id = v_task,
      vintage_year = v_vintage,
      season_year = extract(year from v_date)::integer,
      updated_by = auth.uid(),
      updated_at = now(),
      client_updated_at = coalesce(p_client_updated_at, now())
  where id = p_activity_id;

  -- Upsert every allocation in the desired set.
  for v_alloc in select * from jsonb_array_elements(p_allocations)
  loop
    v_one := public.apply_pruning_activity_allocation(
      p_activity_id, v_act.vineyard_id, v_date,
      coalesce(p_activity->>'worker_or_crew', v_act.worker_or_crew),
      coalesce(nullif(p_activity->>'method', ''), v_act.pruning_method),
      coalesce(p_activity->>'notes', v_act.notes),
      v_vintage, p_client_updated_at, v_alloc, v_index
    );
    v_results := v_results || v_one;
    v_conflicts := v_conflicts || coalesce(v_one->'conflicts', '[]'::jsonb);
    v_kept := array_append(v_kept, (v_one->>'allocation_id')::uuid);
    v_index := v_index + 1;
  end loop;

  -- Remove the allocations that are no longer part of the activity: release
  -- their quarters and soft-delete the allocation. The PARENT survives.
  select coalesce(jsonb_agg(jsonb_build_object(
           'allocation_id', e.id, 'paddock_id', e.paddock_id)), '[]'::jsonb)
  into v_removed
  from public.pruning_entries e
  where e.pruning_activity_id = p_activity_id
    and e.deleted_at is null
    and not (e.id = any (v_kept));

  update public.pruning_row_segments s
  set completed = false, completed_at = null, completed_by = null,
      pruning_entry_id = null, updated_at = now()
  where s.pruning_entry_id in (
    select e.id from public.pruning_entries e
    where e.pruning_activity_id = p_activity_id
      and e.deleted_at is null
      and not (e.id = any (v_kept))
  );

  update public.pruning_entries e
  set deleted_at = now(), updated_by = auth.uid(), updated_at = now(),
      row_equivalents_completed = 0, estimated_vines_completed = 0,
      labour_hours = null, start_time = null, finish_time = null, work_task_id = null
  where e.pruning_activity_id = p_activity_id
    and e.deleted_at is null
    and not (e.id = any (v_kept));

  perform public.sync_pruning_activity_rollup(p_activity_id);
  perform set_config('vinetrack.pruning_activity_lock', v_prev_lock, true);

  insert into public.pruning_entry_audit (
    vineyard_id, pruning_entry_id, event_type,
    previous_quarters, new_quarters,
    previous_labour_hours, new_labour_hours, work_task_changed, detail, created_by
  )
  select v_act.vineyard_id, p_activity_id, 'pruning_entry_edited',
         v_prev_quarters, a.total_quarters,
         v_act.labour_hours, a.labour_hours,
         v_task is distinct from v_act.work_task_id,
         jsonb_build_object(
           'activity_id', p_activity_id,
           'previous_entry_date', v_act.entry_date,
           'entry_date', v_date,
           'previous_vintage_year', v_act.vintage_year,
           'vintage_year', v_vintage,
           'allocations', v_results,
           'removed_allocations', v_removed,
           'conflicts', v_conflicts
         ),
         auth.uid()
  from public.pruning_activities a where a.id = p_activity_id;

  return jsonb_build_object(
    'activity_id', p_activity_id,
    'stale', false,
    'allocation_results', v_results,
    'removed_allocations', v_removed,
    'conflicts', v_conflicts,
    'work_task_conflict', v_task_conflict,
    'canonical', public.pruning_activity_json(p_activity_id)
  );
end;
$$;

revoke all on function public.update_pruning_activity(uuid, jsonb, jsonb, timestamptz) from public, anon;
grant execute on function public.update_pruning_activity(uuid, jsonb, jsonb, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. RPC: reverse_pruning_activity — the whole activity, ONE operation.
--     Every allocation inherits the activity's reversal state; individual
--     allocations are never reversed independently.
-- ---------------------------------------------------------------------------
create or replace function public.reverse_pruning_activity(
  p_activity_id uuid,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_prev_lock text;
  v_act public.pruning_activities%rowtype;
  v_released integer := 0;
  v_allocations integer := 0;
begin
  select * into v_act from public.pruning_activities where id = p_activity_id;
  if not found then
    return jsonb_build_object('activity_id', p_activity_id, 'error', 'activity_not_found');
  end if;
  if not public.has_vineyard_role(v_act.vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;
  if v_act.deleted_at is not null then
    return jsonb_build_object(
      'activity_id', p_activity_id, 'already_reversed', true,
      'canonical', public.pruning_activity_json(p_activity_id)
    );
  end if;

  v_prev_lock := coalesce(current_setting('vinetrack.pruning_activity_lock', true), '');
  perform set_config('vinetrack.pruning_activity_lock', '1', true);

  update public.pruning_row_segments s
  set completed = false, completed_at = null, completed_by = null,
      pruning_entry_id = null, updated_at = now()
  where s.pruning_entry_id in (
    select e.id from public.pruning_entries e
    where e.pruning_activity_id = p_activity_id and e.deleted_at is null
  );
  get diagnostics v_released = row_count;

  update public.pruning_entries
  set deleted_at = now(), updated_by = auth.uid(), updated_at = now()
  where pruning_activity_id = p_activity_id and deleted_at is null;
  get diagnostics v_allocations = row_count;

  update public.pruning_activities
  set deleted_at = now(), updated_by = auth.uid(), updated_at = now()
  where id = p_activity_id;

  perform public.sync_pruning_activity_rollup(p_activity_id);
  perform set_config('vinetrack.pruning_activity_lock', v_prev_lock, true);

  insert into public.pruning_entry_audit (
    vineyard_id, pruning_entry_id, event_type,
    previous_quarters, new_quarters, previous_labour_hours, detail, created_by
  ) values (
    v_act.vineyard_id, p_activity_id, 'pruning_entry_reversed',
    v_act.total_quarters, 0, v_act.labour_hours,
    jsonb_build_object(
      'activity_id', p_activity_id,
      'allocations_reversed', v_allocations,
      'quarters_released', v_released,
      'reason', p_reason
    ),
    auth.uid()
  );

  return jsonb_build_object(
    'activity_id', p_activity_id,
    'already_reversed', false,
    'allocations_reversed', v_allocations,
    'quarters_released', v_released,
    'canonical', public.pruning_activity_json(p_activity_id)
  );
end;
$$;

revoke all on function public.reverse_pruning_activity(uuid, text) from public, anon;
grant execute on function public.reverse_pruning_activity(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 12. RPC: get_pruning_activity / list_pruning_activities
-- ---------------------------------------------------------------------------
create or replace function public.get_pruning_activity(p_activity_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_vineyard uuid;
begin
  select vineyard_id into v_vineyard from public.pruning_activities where id = p_activity_id;
  if v_vineyard is null then
    return jsonb_build_object('activity_id', p_activity_id, 'error', 'activity_not_found');
  end if;
  if not public.is_vineyard_member(v_vineyard) then
    raise exception 'not allowed';
  end if;
  return public.pruning_activity_json(p_activity_id, true);
end;
$$;

revoke all on function public.get_pruning_activity(uuid) from public, anon;
grant execute on function public.get_pruning_activity(uuid) to authenticated;

create or replace function public.list_pruning_activities(
  p_vineyard_id uuid,
  p_from date default null,
  p_to date default null,
  p_include_reversed boolean default true,
  p_limit integer default 500,
  p_offset integer default 0
) returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_out jsonb;
begin
  if not public.is_vineyard_member(p_vineyard_id) then
    raise exception 'not allowed';
  end if;

  select coalesce(jsonb_agg(public.pruning_activity_json(t.id, false)
           order by t.entry_date desc, t.created_at desc), '[]'::jsonb)
  into v_out
  from (
    select a.id, a.entry_date, a.created_at
    from public.pruning_activities a
    where a.vineyard_id = p_vineyard_id
      and (p_from is null or a.entry_date >= p_from)
      and (p_to is null or a.entry_date <= p_to)
      and (p_include_reversed or a.deleted_at is null)
    order by a.entry_date desc, a.created_at desc
    limit greatest(coalesce(p_limit, 500), 1)
    offset greatest(coalesce(p_offset, 0), 0)
  ) t;

  return v_out;
end;
$$;

revoke all on function public.list_pruning_activities(uuid, date, date, boolean, integer, integer) from public, anon;
grant execute on function public.list_pruning_activities(uuid, date, date, boolean, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 13. Allocation-breakdown export view — shared labour appears ONCE.
--     `activity_labour_hours` / `activity_hourly_rate` / `activity_labour_cost`
--     are populated on the PRIMARY allocation row only, so summing the export
--     can never count the activity's labour twice. `allocation_share_*` is the
--     clearly-labelled proportional split for anyone who needs it.
-- ---------------------------------------------------------------------------
create or replace view public.pruning_activity_allocation_export as
select
  a.id                                as activity_id,
  a.vineyard_id,
  a.entry_date                        as activity_date,
  a.worker_or_crew,
  a.pruning_method                    as method,
  a.block_summary,
  e.id                                as allocation_id,
  e.allocation_index,
  e.paddock_id,
  p.name                              as block,
  e.pruning_season_id,
  s.season_year,
  e.vintage_year,
  (select coalesce(jsonb_agg(distinct g.row_number), '[]'::jsonb)
   from public.pruning_row_segments g where g.pruning_entry_id = e.id) as rows,
  (select count(*) from public.pruning_row_segments g
   where g.pruning_entry_id = e.id)   as quarters,
  e.row_equivalents_completed         as row_equivalents,
  e.estimated_vines_completed         as vines,
  case when e.allocation_index = (
    select min(x.allocation_index) from public.pruning_entries x
    where x.pruning_activity_id = a.id and x.deleted_at is null
  ) then a.labour_hours end           as activity_labour_hours,
  case when e.allocation_index = (
    select min(x.allocation_index) from public.pruning_entries x
    where x.pruning_activity_id = a.id and x.deleted_at is null
  ) then a.hourly_rate end            as activity_hourly_rate,
  case when e.allocation_index = (
    select min(x.allocation_index) from public.pruning_entries x
    where x.pruning_activity_id = a.id and x.deleted_at is null
  ) and a.labour_hours is not null and a.hourly_rate is not null
    then round(a.labour_hours * a.hourly_rate, 2) end as activity_labour_cost,
  case when a.total_row_equivalents > 0
    then round(e.row_equivalents_completed / a.total_row_equivalents, 6) end
                                      as allocation_share_of_row_equivalents,
  case when a.total_row_equivalents > 0 and a.labour_hours is not null
    then round(a.labour_hours * e.row_equivalents_completed / a.total_row_equivalents, 4) end
                                      as allocation_share_labour_hours_informational,
  a.work_task_id,
  case when a.deleted_at is not null or e.deleted_at is not null
    then 'reversed' else 'active' end as status,
  a.created_by,
  a.created_at,
  a.updated_at
from public.pruning_activities a
join public.pruning_entries e on e.pruning_activity_id = a.id
left join public.paddocks p on p.id = e.paddock_id
left join public.pruning_seasons s on s.id = e.pruning_season_id;

comment on view public.pruning_activity_allocation_export is
  'Allocation breakdown for reports/exports (SQL 166). activity_labour_hours / activity_hourly_rate / activity_labour_cost appear on the PRIMARY allocation row only so totals never double-count shared labour; allocation_share_labour_hours_informational is a labelled proportional split, never a stored value.';

alter view public.pruning_activity_allocation_export set (security_invoker = true);
grant select on public.pruning_activity_allocation_export to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 14. Validation — the migration ABORTS if any of these fail
-- ---------------------------------------------------------------------------
do $$
declare
  n integer;
begin
  if to_regclass('public.pruning_activities') is null then
    raise exception 'SQL 166: pruning_activities missing';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'pruning_entries'
      and column_name = 'pruning_activity_id'
  ) then
    raise exception 'SQL 166: pruning_entries.pruning_activity_id missing';
  end if;

  if to_regprocedure('public.record_pruning_activity(uuid, uuid, jsonb, jsonb, timestamptz)') is null then
    raise exception 'SQL 166: record_pruning_activity missing';
  end if;
  if to_regprocedure('public.update_pruning_activity(uuid, jsonb, jsonb, timestamptz)') is null then
    raise exception 'SQL 166: update_pruning_activity missing';
  end if;
  if to_regprocedure('public.get_pruning_activity(uuid)') is null then
    raise exception 'SQL 166: get_pruning_activity missing';
  end if;
  if to_regprocedure('public.list_pruning_activities(uuid, date, date, boolean, integer, integer)') is null then
    raise exception 'SQL 166: list_pruning_activities missing';
  end if;
  if to_regprocedure('public.reverse_pruning_activity(uuid, text)') is null then
    raise exception 'SQL 166: reverse_pruning_activity missing';
  end if;
  if to_regprocedure('public.derive_pruning_allocation_id(uuid, uuid)') is null then
    raise exception 'SQL 166: derive_pruning_allocation_id missing';
  end if;
  if to_regprocedure('public.sync_pruning_activity_rollup(uuid)') is null then
    raise exception 'SQL 166: sync_pruning_activity_rollup missing';
  end if;

  -- Legacy contract untouched.
  if to_regprocedure('public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb, uuid, integer)') is null then
    raise exception 'SQL 166: record_pruning_entry signature changed';
  end if;
  if to_regprocedure('public.update_pruning_entry(uuid, date, text, numeric, timestamptz, timestamptz, text, text, integer, jsonb, uuid, boolean, integer, timestamptz)') is null then
    raise exception 'SQL 166: update_pruning_entry signature changed';
  end if;

  -- Every entry has a parent, and no activity carries labour twice.
  select count(*) into n from public.pruning_entries where pruning_activity_id is null;
  if n > 0 then
    raise exception 'SQL 166: % entries without a parent activity', n;
  end if;

  select count(*) into n
  from (
    select pruning_activity_id
    from public.pruning_entries
    where deleted_at is null and labour_hours is not null
    group by pruning_activity_id
    having count(*) > 1
  ) t;
  if n > 0 then
    raise exception 'SQL 166: % activities mirror labour on more than one allocation', n;
  end if;

  raise notice 'SQL 166 pruning activities + per-block allocations: APPLIED';
end$$;

-- ---------------------------------------------------------------------------
-- 15. Verification (run manually; read-only)
-- ---------------------------------------------------------------------------
-- Multi-block activities:
-- select id, entry_date, worker_or_crew, block_summary, allocation_count,
--        labour_hours, total_quarters, total_row_equivalents
-- from public.pruning_activities
-- where allocation_count > 1 order by entry_date desc;
--
-- Labour is stored once (this must return zero rows):
-- select pruning_activity_id, count(*)
-- from public.pruning_entries where deleted_at is null and labour_hours is not null
-- group by 1 having count(*) > 1;
--
-- Allocation export for one activity:
-- select * from public.pruning_activity_allocation_export
-- where activity_id = '<activity-uuid>' order by allocation_index;

-- ===========================================================================
-- SQL 168 — Skipped pruning sections
--
-- Rows (or parts of rows) that are TEMPORARILY OR PERMANENTLY OUT OF PRUNING
-- ROTATION: vines removed, rows pulled out, replanted sections, dead or
-- inactive sections, anything that should not count as requiring pruning.
--
-- THE CONTRACT (identical on iOS, Android and the portal):
--   * a skipped section COUNTS AS COMPLETE for block progress, vineyard
--     progress, rows remaining and sections remaining,
--   * a skipped section is NEVER pruning work: no vines pruned, no rows
--     pruned, no labour hours, no labour cost, no vines/hour, no rows/hour,
--     no best-pruner or worker-performance contribution, nothing in Work
--     Task Reports,
--   * a skipped record carries no worker, no labour, no cost and no Work
--     Task — structurally, not by convention (see the RPCs below),
--   * skipped area counts toward COMPLETION area but never toward WORKED
--     area, so cost per worked hectare stays truthful.
--
-- Design note — why this is a flag and not a new completion system:
-- a skipped record is an ordinary `pruning_entries` row with ordinary
-- `pruning_row_segments` children. It reuses the same season resolution, the
-- same segment claim/release, the same activity parent, the same reversal
-- path (`delete_pruning_entry`) and the same offline queue. The ONLY new
-- state is one boolean.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. The flag
-- ---------------------------------------------------------------------------
alter table public.pruning_entries
  add column if not exists is_skipped boolean not null default false;

comment on column public.pruning_entries.is_skipped is
  'SQL 168. True when this record marks its sections OUT OF PRUNING ROTATION rather than pruned. Skipped sections count as COMPLETE for progress and as NOTHING for pruning work (no vines, labour, cost, rate or Work Task). Every pre-existing entry defaults to false = completed by pruning.';

-- The parent activity mirrors the flag so the activity feed, the Activity
-- Report and the exports can label a record without re-reading its
-- allocations. An activity is skipped when EVERY live allocation is skipped.
alter table public.pruning_activities
  add column if not exists is_skipped boolean not null default false;

comment on column public.pruning_activities.is_skipped is
  'SQL 168. True when every live allocation of this activity is a skipped (out-of-rotation) record. Maintained by sync_pruning_activity_rollup — never written directly by a client.';

-- Skipped sections are read on every progress query, so keep them cheap to find.
create index if not exists pruning_entries_skipped_idx
  on public.pruning_entries (pruning_season_id)
  where is_skipped and deleted_at is null;

-- A skipped record must never carry labour, a worker, a rate or a Work Task.
-- This is the guard rail behind "creates no labour hours / no worker record /
-- no cost / no Work Task": no code path, present or future, can violate it.
alter table public.pruning_entries
  drop constraint if exists pruning_entries_skipped_has_no_labour;
alter table public.pruning_entries
  add constraint pruning_entries_skipped_has_no_labour check (
    not is_skipped
    or (
      labour_hours is null
      and start_time is null
      and finish_time is null
      and work_task_id is null
      and coalesce(worker_or_crew, '') = ''
    )
  ) not valid;

-- `not valid` skips the full-table scan; existing rows are all is_skipped =
-- false so they satisfy it trivially, and validating separately keeps the
-- migration lock short.
alter table public.pruning_entries
  validate constraint pruning_entries_skipped_has_no_labour;

-- ---------------------------------------------------------------------------
-- 2. record_skipped_pruning_entry
--
-- A PURPOSE-BUILT create path rather than a new flag on
-- `record_pruning_entry`. It accepts no worker, no hours, no times, no
-- method, no rate and no work-task argument, so a skipped record cannot
-- carry labour even by accident — the guarantee is in the signature.
--
-- It delegates the hard parts (season resolution, segment attribution,
-- overlap rejection, vintage assignment, activity parenting) to the existing,
-- battle-tested `record_pruning_entry`, then stamps the flag. Both statements
-- run inside this function's transaction, so a skipped record is never
-- briefly visible as pruning work.
--
-- Idempotent for offline replay for exactly the same reason
-- `record_pruning_entry` is: the client supplies `p_id`.
-- ---------------------------------------------------------------------------
create or replace function public.record_skipped_pruning_entry(
  p_id uuid,
  p_vineyard_id uuid,
  p_season_id uuid,
  p_paddock_id uuid,
  p_season_year integer,
  p_entry_date date,
  p_segments jsonb default '[]'::jsonb,
  p_notes text default null,
  p_client_updated_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_result jsonb;
begin
  -- Delegate: identical permission check, season resolution, segment
  -- attribution and overlap handling as a normal pruning record.
  v_result := public.record_pruning_entry(
    p_id                := p_id,
    p_vineyard_id       := p_vineyard_id,
    p_season_id         := p_season_id,
    p_paddock_id        := p_paddock_id,
    p_season_year       := p_season_year,
    p_entry_date        := p_entry_date,
    p_worker            := '',
    p_labour_hours      := null,
    p_start_time        := null,
    p_finish_time       := null,
    p_method            := null,
    p_notes             := coalesce(p_notes, ''),
    -- Vines are attributed for reporting, but they are SKIPPED vines: every
    -- read path below excludes them from "vines pruned".
    p_estimated_vines   := null,
    p_client_updated_at := p_client_updated_at,
    p_segments          := p_segments,
    p_work_task_id      := null,
    p_vintage_year      := null
  );

  update public.pruning_entries
  set is_skipped = true,
      -- Belt and braces: the delegate already wrote nulls, but a skipped row
      -- must be provably clean of labour before the constraint sees it.
      labour_hours = null,
      start_time = null,
      finish_time = null,
      work_task_id = null,
      worker_or_crew = '',
      updated_at = now()
  where id = p_id;

  perform public.sync_pruning_activity_rollup(
    (select pruning_activity_id from public.pruning_entries where id = p_id)
  );

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object('is_skipped', true);
end;
$$;

revoke all on function public.record_skipped_pruning_entry(uuid, uuid, uuid, uuid, integer, date, jsonb, text, timestamptz) from public, anon;
grant execute on function public.record_skipped_pruning_entry(uuid, uuid, uuid, uuid, integer, date, jsonb, text, timestamptz) to authenticated;

comment on function public.record_skipped_pruning_entry(uuid, uuid, uuid, uuid, integer, date, jsonb, text, timestamptz) is
  'SQL 168. Marks rows or row sections as OUT OF PRUNING ROTATION. Accepts no worker, hours, times, method, rate or work task by design. Sections count as complete for progress and as nothing for pruning work. Idempotent on p_id for offline replay.';

-- ---------------------------------------------------------------------------
-- 3. update_skipped_pruning_entry — edit the date or the selection.
--     Same reasoning: the signature admits nothing that could become labour.
-- ---------------------------------------------------------------------------
create or replace function public.update_skipped_pruning_entry(
  p_entry_id uuid,
  p_entry_date date,
  p_segments jsonb default '[]'::jsonb,
  p_notes text default null,
  p_client_updated_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_result jsonb;
  v_is_skipped boolean;
begin
  select is_skipped into v_is_skipped
  from public.pruning_entries where id = p_entry_id;

  if v_is_skipped is null then
    raise exception 'pruning entry % not found', p_entry_id;
  end if;

  if not v_is_skipped then
    -- Refuse to convert a real pruning record into a skipped one through the
    -- back door: that would silently delete recorded labour and vines.
    raise exception 'pruning entry % is a pruning record, not a skipped record', p_entry_id;
  end if;

  v_result := public.update_pruning_entry(
    p_entry_id          := p_entry_id,
    p_entry_date        := p_entry_date,
    p_worker            := '',
    p_labour_hours      := null,
    p_start_time        := null,
    p_finish_time       := null,
    p_method            := null,
    p_notes             := coalesce(p_notes, ''),
    p_estimated_vines   := null,
    p_segments          := p_segments,
    p_work_task_id      := null,
    p_clear_work_task   := true,
    p_vintage_year      := null,
    p_client_updated_at := p_client_updated_at
  );

  update public.pruning_entries
  set is_skipped = true,
      labour_hours = null,
      start_time = null,
      finish_time = null,
      work_task_id = null,
      worker_or_crew = '',
      updated_at = now()
  where id = p_entry_id;

  perform public.sync_pruning_activity_rollup(
    (select pruning_activity_id from public.pruning_entries where id = p_entry_id)
  );

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object('is_skipped', true);
end;
$$;

revoke all on function public.update_skipped_pruning_entry(uuid, date, jsonb, text, timestamptz) from public, anon;
grant execute on function public.update_skipped_pruning_entry(uuid, date, jsonb, text, timestamptz) to authenticated;

comment on function public.update_skipped_pruning_entry(uuid, date, jsonb, text, timestamptz) is
  'SQL 168. Edits the date or section selection of an existing skipped record. Refuses to operate on a normal pruning record. Reversal uses the existing delete_pruning_entry path unchanged.';

-- ---------------------------------------------------------------------------
-- 4. Roll the flag up to the parent activity.
--     Only change from SQL 166: the is_skipped computation and its write.
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
  v_skipped_live integer := 0;
begin
  if p_activity_id is null then
    return;
  end if;

  select * into v_act from public.pruning_activities where id = p_activity_id;
  if not found then
    return;
  end if;

  v_prev_lock := coalesce(current_setting('vinetrack.pruning_activity_lock', true), '');
  perform set_config('vinetrack.pruning_activity_lock', '1', true);

  select count(*) into v_any
  from public.pruning_entries where pruning_activity_id = p_activity_id;

  select count(*)::integer,
         coalesce(sum(e.estimated_vines_completed), 0)::integer,
         coalesce(sum(e.row_equivalents_completed), 0)::numeric,
         count(*) filter (where e.is_skipped)::integer
    into v_live, v_vines, v_row_eq, v_skipped_live
  from public.pruning_entries e
  where e.pruning_activity_id = p_activity_id and e.deleted_at is null;

  select max(e.deleted_at) into v_last_reversal
  from public.pruning_entries e
  where e.pruning_activity_id = p_activity_id;

  select count(*)::integer into v_quarters
  from public.pruning_row_segments s
  join public.pruning_entries e on e.id = s.pruning_entry_id
  where e.pruning_activity_id = p_activity_id and e.deleted_at is null;

  select coalesce(string_agg(t.name, ' + ' order by t.ord, t.name), '') into v_summary
  from (
    select coalesce(nullif(p.name, ''), 'Block') as name,
           min(e.allocation_index) as ord
    from public.pruning_entries e
    join public.paddocks p on p.id = e.paddock_id
    where e.pruning_activity_id = p_activity_id and e.deleted_at is null
    group by 1
  ) t;

  select id into v_primary
  from public.pruning_entries
  where pruning_activity_id = p_activity_id and deleted_at is null
  order by allocation_index, id
  limit 1;

  -- Mirror labour onto the primary allocation ONLY — and never onto a skipped
  -- one, which must stay free of labour for the SQL 168 constraint.
  if v_primary is not null then
    update public.pruning_entries
    set labour_hours = v_act.labour_hours,
        start_time = v_act.start_time,
        finish_time = v_act.finish_time,
        work_task_id = v_act.work_task_id,
        updated_at = now()
    where id = v_primary
      and not is_skipped
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
    and (v_primary is null or id <> v_primary or is_skipped)
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
      -- Skipped only when there IS something live and all of it is skipped.
      -- A mixed activity is a pruning activity.
      is_skipped = (v_live > 0 and v_skipped_live = v_live),
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
-- 5. Expose the flag on the activity JSON (feed, report, editor, exports).
--     Only change from SQL 166: two `is_skipped` keys.
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
             'is_skipped', e.is_skipped,
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
      'is_skipped', v_act.is_skipped,
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
-- 6. Export view — a skipped allocation is labelled, and its labour columns
--     are structurally null. `status` gains a third value so a CSV reader can
--     separate the three states without inferring anything.
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
  -- Completion counts skipped sections; pruning work never does.
  e.row_equivalents_completed         as completion_row_equivalents,
  case when e.is_skipped then 0 else e.row_equivalents_completed end
                                      as pruned_row_equivalents,
  case when e.is_skipped then e.row_equivalents_completed else 0 end
                                      as skipped_row_equivalents,
  e.estimated_vines_completed         as vines,
  case when e.is_skipped then 0 else e.estimated_vines_completed end
                                      as vines_pruned,
  case when e.is_skipped then e.estimated_vines_completed else 0 end
                                      as vines_skipped,
  e.is_skipped,
  case when e.is_skipped then null when e.allocation_index = (
    select min(x.allocation_index) from public.pruning_entries x
    where x.pruning_activity_id = a.id and x.deleted_at is null
  ) then a.labour_hours end           as activity_labour_hours,
  case when e.is_skipped then null when e.allocation_index = (
    select min(x.allocation_index) from public.pruning_entries x
    where x.pruning_activity_id = a.id and x.deleted_at is null
  ) then a.hourly_rate end            as activity_hourly_rate,
  case when e.is_skipped then null when e.allocation_index = (
    select min(x.allocation_index) from public.pruning_entries x
    where x.pruning_activity_id = a.id and x.deleted_at is null
  ) and a.labour_hours is not null and a.hourly_rate is not null
    then round(a.labour_hours * a.hourly_rate, 2) end as activity_labour_cost,
  case when a.total_row_equivalents > 0
    then round(e.row_equivalents_completed / a.total_row_equivalents, 6) end
                                      as allocation_share_of_row_equivalents,
  case when e.is_skipped then null when a.total_row_equivalents > 0 and a.labour_hours is not null
    then round(a.labour_hours * e.row_equivalents_completed / a.total_row_equivalents, 4) end
                                      as allocation_share_labour_hours_informational,
  case when e.is_skipped then null else a.work_task_id end as work_task_id,
  case
    when a.deleted_at is not null or e.deleted_at is not null then 'reversed'
    when e.is_skipped then 'skipped'
    else 'active'
  end                                 as status,
  a.created_by,
  a.created_at,
  a.updated_at
from public.pruning_activities a
join public.pruning_entries e on e.pruning_activity_id = a.id
left join public.paddocks p on p.id = e.paddock_id
left join public.pruning_seasons s on s.id = e.pruning_season_id;

comment on view public.pruning_activity_allocation_export is
  'Allocation breakdown for reports/exports (SQL 166, extended by SQL 168). activity_labour_* appear on the PRIMARY allocation row only, and never on a skipped allocation, so totals never double-count shared labour and never attribute labour to an out-of-rotation section. status is active | skipped | reversed.';

alter view public.pruning_activity_allocation_export set (security_invoker = true);
grant select on public.pruning_activity_allocation_export to authenticated;

-- ---------------------------------------------------------------------------
-- 7. get_pruning_skipped_summary — the skipped side of the split, per block
--     and vineyard-wide.
--
--     Deliberately a SEPARATE, small function rather than more branches
--     inside the 350-line SQL 115 aggregation: SQL 115 keeps returning
--     COMPLETION (which correctly includes skipped sections), and SQL 115's
--     WORK figures are corrected in section 8 below by excluding skipped
--     entries. This function supplies the "Skipped: 10%" line.
-- ---------------------------------------------------------------------------
create or replace function public.get_pruning_skipped_summary(
  p_vineyard_id uuid,
  p_season_year integer default null
) returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_year integer;
  v_blocks jsonb := '[]'::jsonb;
  v_quarters bigint := 0;
begin
  if not public.is_vineyard_member(p_vineyard_id) then
    raise exception 'not allowed';
  end if;

  v_year := coalesce(p_season_year, extract(year from current_date)::integer);

  select coalesce(jsonb_agg(jsonb_build_object(
           'paddock_id', t.paddock_id,
           'skipped_quarters', t.quarters,
           'skipped_row_equivalents', round(t.quarters / 4.0, 4)
         ) order by t.paddock_id), '[]'::jsonb),
         coalesce(sum(t.quarters), 0)
    into v_blocks, v_quarters
  from (
    select e.paddock_id, count(seg.*)::bigint as quarters
    from public.pruning_entries e
    join public.pruning_seasons ps on ps.id = e.pruning_season_id
    join public.pruning_row_segments seg on seg.pruning_entry_id = e.id
    where e.vineyard_id = p_vineyard_id
      and ps.season_year = v_year
      and ps.deleted_at is null
      and e.deleted_at is null
      and e.is_skipped
      and seg.completed = true
    group by e.paddock_id
  ) t;

  return jsonb_build_object(
    'vineyard_id', p_vineyard_id,
    'season_year', v_year,
    'skipped_quarters', v_quarters,
    'skipped_row_equivalents', round(v_quarters / 4.0, 4),
    'blocks', v_blocks
  );
end;
$$;

revoke all on function public.get_pruning_skipped_summary(uuid, integer) from public, anon;
grant execute on function public.get_pruning_skipped_summary(uuid, integer) to authenticated;

comment on function public.get_pruning_skipped_summary(uuid, integer) is
  'SQL 168. Out-of-rotation quarters per block and vineyard-wide. Pairs with get_pruning_vineyard_summary: that returns COMPLETION (which includes skipped) and PRUNED WORK (which excludes it); this returns the skipped share so a caller can render Pruned / Skipped / Complete.';

-- ---------------------------------------------------------------------------
-- 8. get_pruning_vineyard_summary — keep the apps and the portal in parity.
--
--     COMPLETION is unchanged: `completed_row_equivalents`,
--     `completion_fraction` and `display_percent` still include skipped
--     sections, because a skipped section IS complete.
--
--     WORK now excludes them. Four changes from SQL 115, all of them the same
--     idea — a skipped record is not work:
--       a) `vines_pruned*` counts pruned quarters only,
--       b) the rolling rate ignores skipped entries,
--       c) the per-entry vines/day + labour loop ignores skipped entries,
--       d) new `skipped_*` and `pruned_*` keys expose the split, and
--          `vines_remaining` drops skipped vines from the workload.
-- ---------------------------------------------------------------------------
create or replace function public.get_pruning_vineyard_summary(
  p_vineyard_id uuid,
  p_season_year integer default null,
  p_today date default null
) returns jsonb
language plpgsql
as $$
declare
  v_tz text;
  v_today date;
  v_year integer;

  v_total_eq double precision := 0;
  v_completed_eq double precision := 0;
  v_skipped_eq double precision := 0;
  v_vines_total bigint := 0;
  v_vines_pruned_exact double precision := 0;
  v_vines_skipped_exact double precision := 0;
  v_blocks_complete integer := 0;
  v_blocks_at_risk integer := 0;
  v_projected date := null;
  v_hours double precision := 0;
  v_vines_for_hours double precision := 0;

  p record;
  e record;
  v_centroid_lat double precision;
  v_sum_len double precision;
  v_avg_len double precision;
  v_eff_len double precision;
  v_spacing double precision;
  v_block_vines double precision;
  v_season_id uuid;
  v_working integer[];
  v_manual_count integer;
  v_due date;
  v_row_count integer;
  v_b_completed_quarters integer;
  v_b_skipped_quarters integer;
  v_b_vines_pruned double precision;
  v_b_vines_skipped double precision;
  v_b_completed_eq double precision;
  v_b_skipped_eq double precision;
  v_b_total_eq double precision;
  v_rate double precision;
  v_remaining double precision;
  v_b_projected date;
  v_status text;
  v_days_late integer;
  v_days_needed integer;
  v_walk date;
  v_iter integer;

  v_vines_per_day double precision;
  v_fraction double precision;
  v_blocks jsonb := '[]'::jsonb;
begin
  if not public.is_vineyard_member(p_vineyard_id) then
    raise exception 'not allowed';
  end if;

  select timezone into v_tz from public.vineyards where id = p_vineyard_id;
  v_today := coalesce(p_today, (now() at time zone coalesce(nullif(v_tz, ''), 'UTC'))::date);
  v_year := coalesce(p_season_year, extract(year from v_today)::integer);

  drop table if exists _prs_rows;
  create temp table _prs_rows (
    paddock_id uuid,
    ord integer,
    row_id uuid,
    row_number integer,
    vines double precision
  );

  drop table if exists _prs_days;
  create temp table _prs_days (day date, vines double precision);

  for p in
    select pd.id, pd.name, pd.vine_spacing, pd.vine_count_override,
           pd.row_length_override, pd.polygon_points, pd.rows
    from public.paddocks pd
    where pd.vineyard_id = p_vineyard_id
      and pd.deleted_at is null
    order by pd.name
  loop
    select ps.id, ps.working_days, ps.manual_row_count, ps.due_date
    into v_season_id, v_working, v_manual_count, v_due
    from public.pruning_seasons ps
    where ps.vineyard_id = p_vineyard_id
      and ps.paddock_id = p.id
      and ps.season_year = v_year
      and ps.deleted_at is null
    limit 1;
    if not found then
      v_season_id := null;
      v_working := array[1,2,3,4,5];
      v_manual_count := null;
      v_due := null;
    end if;

    select avg((pt->>'latitude')::double precision)
    into v_centroid_lat
    from jsonb_array_elements(coalesce(p.polygon_points, '[]'::jsonb)) pt
    where jsonb_typeof(pt->'latitude') = 'number';

    delete from _prs_rows where paddock_id = p.id;

    with raw as (
      select
        row_number() over () as ord,
        case
          when (elem->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            then (elem->>'id')::uuid
          else public.derive_paddock_row_id(
            coalesce(nullif(elem->>'number', '')::integer, 0),
            (elem->'startPoint'->>'latitude')::double precision,
            (elem->'startPoint'->>'longitude')::double precision,
            (elem->'endPoint'->>'latitude')::double precision,
            (elem->'endPoint'->>'longitude')::double precision
          )
        end as row_id,
        coalesce(nullif(elem->>'number', '')::integer, 0) as row_number,
        (elem->'startPoint'->>'latitude')::double precision as slat,
        (elem->'startPoint'->>'longitude')::double precision as slon,
        (elem->'endPoint'->>'latitude')::double precision as elat,
        (elem->'endPoint'->>'longitude')::double precision as elon
      from jsonb_array_elements(coalesce(p.rows, '[]'::jsonb)) elem
    ),
    measured as (
      select ord, row_id, row_number,
        case
          when slat is null or slon is null or elat is null or elon is null then 0
          else sqrt(
            pow((elat - slat) * 111320.0, 2)
            + pow((elon - slon) * 111320.0 * cos(radians(coalesce(v_centroid_lat, slat))), 2)
          )
        end as len
      from raw
    )
    insert into _prs_rows (paddock_id, ord, row_id, row_number, vines)
    select p.id, m.ord, m.row_id, m.row_number, m.len
    from measured m;

    select coalesce(sum(vines), 0) into v_sum_len from _prs_rows where paddock_id = p.id;
    select avg(vines) into v_avg_len from _prs_rows where paddock_id = p.id and vines > 0;

    v_spacing := coalesce(p.vine_spacing, 1.0);
    v_eff_len := coalesce(p.row_length_override, v_sum_len);
    v_block_vines := coalesce(
      p.vine_count_override::double precision,
      case when v_spacing > 0 then trunc(v_eff_len / v_spacing) else 0 end
    );

    select count(*) into v_row_count from _prs_rows where paddock_id = p.id;

    if v_row_count > 0 then
      update _prs_rows r
      set vines = case
        when w.total_weight > 0 then v_block_vines * w.weight / w.total_weight
        else 0
      end
      from (
        select ord,
          case when vines > 0 then vines else coalesce(nullif(v_avg_len, 0), 1) end as weight,
          sum(case when vines > 0 then vines else coalesce(nullif(v_avg_len, 0), 1) end) over () as total_weight
        from _prs_rows where paddock_id = p.id
      ) w
      where r.paddock_id = p.id and r.ord = w.ord;
    elsif coalesce(v_manual_count, 0) > 0 then
      v_row_count := v_manual_count;
      insert into _prs_rows (paddock_id, ord, row_id, row_number, vines)
      select p.id, gs, null, gs, v_block_vines / v_manual_count
      from generate_series(1, v_manual_count) gs;
    else
      v_row_count := 0;
    end if;

    -- Completed quarters, matched exactly like the apps. `completed` is every
    -- finished quarter (pruned AND skipped); the pruned/skipped split comes
    -- from the owning entry's SQL 168 flag. The join is a LEFT join so the
    -- completed COUNT is byte-identical to SQL 115 — a segment whose entry row
    -- cannot be resolved is treated as pruned, exactly as before.
    v_b_completed_quarters := 0;
    v_b_skipped_quarters := 0;
    v_b_vines_pruned := 0;
    v_b_vines_skipped := 0;
    if v_season_id is not null and v_row_count > 0 then
      select count(rv.vines),
             count(rv.vines) filter (where coalesce(en.is_skipped, false)),
             coalesce(sum(rv.vines) filter (where not coalesce(en.is_skipped, false)), 0) / 4.0,
             coalesce(sum(rv.vines) filter (where coalesce(en.is_skipped, false)), 0) / 4.0
      into v_b_completed_quarters, v_b_skipped_quarters, v_b_vines_pruned, v_b_vines_skipped
      from public.pruning_row_segments seg
      left join public.pruning_entries en on en.id = seg.pruning_entry_id
      cross join lateral (
        select r.vines
        from _prs_rows r
        where r.paddock_id = p.id
          and (
            (seg.paddock_row_id is not null and r.row_id = seg.paddock_row_id)
            or (seg.paddock_row_id is null and r.row_number = seg.row_number)
          )
        order by r.ord
        limit 1
      ) rv
      where seg.pruning_season_id = v_season_id
        and seg.completed = true;
    end if;

    v_b_completed_eq := v_b_completed_quarters / 4.0;
    v_b_skipped_eq := v_b_skipped_quarters / 4.0;
    v_b_total_eq := v_row_count;

    -- Rolling rate: skipped records are not productive days and never enter it.
    v_rate := null;
    if v_season_id is not null then
      select avg(day_eq) into v_rate
      from (
        select en.entry_date, sum(en.row_equivalents_completed)::double precision as day_eq
        from public.pruning_entries en
        where en.pruning_season_id = v_season_id
          and en.deleted_at is null
          and not en.is_skipped
        group by en.entry_date
        order by en.entry_date desc
        limit 3
      ) t;

      -- Per-entry EXACT vines feed the vineyard day map + labour totals.
      -- Skipped entries are excluded from BOTH sides of every ratio.
      for e in
        select en.id, en.entry_date, en.labour_hours,
          coalesce((
            select sum(rv.vines) / 4.0
            from public.pruning_row_segments seg
            cross join lateral (
              select r.vines
              from _prs_rows r
              where r.paddock_id = p.id
                and (
                  (seg.paddock_row_id is not null and r.row_id = seg.paddock_row_id)
                  or (seg.paddock_row_id is null and r.row_number = seg.row_number)
                )
              order by r.ord
              limit 1
            ) rv
            where seg.pruning_entry_id = en.id and seg.completed = true
          ), 0) as exact_vines
        from public.pruning_entries en
        where en.pruning_season_id = v_season_id
          and en.deleted_at is null
          and not en.is_skipped
      loop
        insert into _prs_days (day, vines) values (e.entry_date, e.exact_vines);
        if e.labour_hours is not null and e.labour_hours > 0 then
          v_hours := v_hours + e.labour_hours;
          v_vines_for_hours := v_vines_for_hours + e.exact_vines;
        end if;
      end loop;
    end if;

    -- Projection: remaining work excludes skipped sections, because they are
    -- complete and will never be pruned.
    v_remaining := greatest(v_b_total_eq - v_b_completed_eq, 0);
    v_b_projected := null;
    if v_rate is not null and v_rate > 0 and v_remaining > 0 then
      v_days_needed := ceil(v_remaining / v_rate)::integer;
      v_walk := v_today;
      v_iter := 0;
      while v_iter < 3660 loop
        if (extract(isodow from v_walk)::integer) = any (coalesce(nullif(v_working, '{}'), array[1,2,3,4,5])) then
          v_days_needed := v_days_needed - 1;
          if v_days_needed <= 0 then
            v_b_projected := v_walk;
            exit;
          end if;
        end if;
        v_walk := v_walk + 1;
        v_iter := v_iter + 1;
      end loop;
    end if;

    -- Status uses COMPLETION, so a block finished by a mix of pruning and
    -- skipping is correctly complete.
    if v_b_total_eq > 0 and v_b_completed_eq >= v_b_total_eq - 0.0001 then
      v_status := 'complete';
    elsif v_b_completed_eq <= 0 then
      v_status := 'notStarted';
    elsif v_b_projected is null or v_due is null then
      v_status := 'onTrack';
    else
      v_days_late := v_b_projected - v_due;
      v_status := case
        when v_days_late < -3 then 'ahead'
        when v_days_late <= 0 then 'onTrack'
        when v_days_late <= 3 then 'atRisk'
        else 'behind'
      end;
    end if;

    v_completed_eq := v_completed_eq + v_b_completed_eq;
    v_skipped_eq := v_skipped_eq + v_b_skipped_eq;
    v_total_eq := v_total_eq + v_b_total_eq;
    v_vines_pruned_exact := v_vines_pruned_exact + v_b_vines_pruned;
    v_vines_skipped_exact := v_vines_skipped_exact + v_b_vines_skipped;
    v_vines_total := v_vines_total + v_block_vines::bigint;
    if v_status = 'complete' then v_blocks_complete := v_blocks_complete + 1; end if;
    if v_status in ('behind', 'atRisk') then v_blocks_at_risk := v_blocks_at_risk + 1; end if;
    if v_b_projected is not null and (v_projected is null or v_b_projected > v_projected) then
      v_projected := v_b_projected;
    end if;

    v_blocks := v_blocks || jsonb_build_object(
      'paddock_id', p.id,
      'name', p.name,
      'season_id', v_season_id,
      'row_count', v_row_count,
      'total_row_equivalents', v_b_total_eq,
      'completed_row_equivalents', v_b_completed_eq,
      'pruned_row_equivalents', v_b_completed_eq - v_b_skipped_eq,
      'skipped_row_equivalents', v_b_skipped_eq,
      'total_vines', v_block_vines::bigint,
      'vines_pruned_exact', v_b_vines_pruned,
      'vines_pruned', round(v_b_vines_pruned)::bigint,
      'vines_skipped_exact', v_b_vines_skipped,
      'vines_skipped', round(v_b_vines_skipped)::bigint,
      'rate_row_eq_per_day', v_rate,
      'projected_completion_date', v_b_projected,
      'due_date', v_due,
      'status', v_status
    );
  end loop;

  select sum(day_total) / count(*)
  into v_vines_per_day
  from (
    select day, sum(vines) as day_total
    from _prs_days
    group by day
  ) d;

  v_fraction := case when v_total_eq > 0 then least(v_completed_eq / v_total_eq, 1.0) else 0 end;

  return jsonb_build_object(
    'vineyard_id', p_vineyard_id,
    'season_year', v_year,
    'as_of_date', v_today,
    'total_row_equivalents', v_total_eq,
    -- COMPLETION — includes skipped sections.
    'completed_row_equivalents', v_completed_eq,
    'completion_fraction', v_fraction,
    'display_percent', round(v_fraction * 100)::integer,
    -- The Pruned / Skipped split of that same completion.
    'pruned_row_equivalents', v_completed_eq - v_skipped_eq,
    'skipped_row_equivalents', v_skipped_eq,
    'pruned_fraction', case when v_total_eq > 0
      then least((v_completed_eq - v_skipped_eq) / v_total_eq, 1.0) else 0 end,
    'skipped_fraction', case when v_total_eq > 0
      then least(v_skipped_eq / v_total_eq, 1.0) else 0 end,
    'pruned_percent', case when v_total_eq > 0
      then round(least((v_completed_eq - v_skipped_eq) / v_total_eq, 1.0) * 100)::integer else 0 end,
    'skipped_percent', case when v_total_eq > 0
      then round(least(v_skipped_eq / v_total_eq, 1.0) * 100)::integer else 0 end,
    'total_vines', v_vines_total,
    -- WORK — excludes skipped sections.
    'vines_pruned_exact', v_vines_pruned_exact,
    'vines_pruned', round(v_vines_pruned_exact)::bigint,
    'vines_skipped_exact', v_vines_skipped_exact,
    'vines_skipped', round(v_vines_skipped_exact)::bigint,
    'vines_remaining', greatest(
      v_vines_total - round(v_vines_pruned_exact)::bigint - round(v_vines_skipped_exact)::bigint, 0),
    'vines_per_day_exact', v_vines_per_day,
    'vines_per_day', case when v_vines_per_day is null then null else round(v_vines_per_day)::bigint end,
    'vines_per_labour_hour_exact', case when v_hours > 0 then v_vines_for_hours / v_hours else null end,
    'vines_per_labour_hour', case when v_hours > 0 then round(v_vines_for_hours / v_hours)::bigint else null end,
    'labour_hours', v_hours,
    'projected_completion_date', v_projected,
    'blocks_complete', v_blocks_complete,
    'blocks_at_risk', v_blocks_at_risk,
    'blocks', v_blocks
  );
end;
$$;

revoke all on function public.get_pruning_vineyard_summary(uuid, integer, date) from public;
grant execute on function public.get_pruning_vineyard_summary(uuid, integer, date) to authenticated;

comment on function public.get_pruning_vineyard_summary(uuid, integer, date) is
  'THE shared pruning aggregation (SQL 115, extended by SQL 168). completed_* / completion_fraction / display_percent count skipped sections as complete; vines_pruned*, vines_per_day*, vines_per_labour_hour* and labour_hours count only real pruning work. pruned_* and skipped_* expose the split.';

commit;

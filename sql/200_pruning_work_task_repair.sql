-- =============================================================================
-- 200: PRUNING COST MODEL REPAIR — Work Tasks are the ONE completed-work cost
--      ledger; a Pruning Activity may link 0..N of them.
--
-- ***** STATUS: PROPOSED MIGRATION — NOT YET APPLIED. *****
-- Review the data notes below, then apply BEFORE shipping the mobile builds
-- that write `work_tasks.pruning_activity_id`. Everything here is ADDITIVE.
--
-- Rork/VineTrack mobile is the SOURCE OF TRUTH for this contract. Lovable (the
-- web portal) CONSUMES it and MUST NOT independently create or modify these
-- tables, functions or rules.
--
-- ---------------------------------------------------------------------------
-- WHY (what the repair audit found)
-- ---------------------------------------------------------------------------
-- SQL 190 added a SECOND labour model directly to pruning activities
-- (`pruning_activity_labour_lines`) even though Work Tasks have been the
-- completed-work cost ledger since SQL 014/050. That inverted the intended
-- authority: activity-owned lines OUTRANKED the linked task's labour, and a
-- Work Task "read through" to activity rows it did not own.
--
-- The canonical model this migration restores:
--
--   Pruning Activity  — OPERATIONAL record only (date, blocks, rows/quarters,
--                       vines, method, worker/crew as descriptive metadata,
--                       notes). It owns NO labour cost.
--   Work Task         — the completed-work COST record (labour lines, piece
--                       rate, machine work, totals). 0..1 originating
--                       pruning activity.
--
--   pruning activity 0..N work tasks; activity totals are DERIVED:
--     activity labour hours = SUM(linked tasks' canonical labour hours)
--     activity total cost   = SUM(linked tasks' canonical totals)
--
-- ---------------------------------------------------------------------------
-- CARDINALITY BEFORE / AFTER
-- ---------------------------------------------------------------------------
-- Before: pruning_activities.work_task_id  (0..1, SQL 166)  +
--         pruning_entries.work_task_id     (0..1 per entry, SQL 113/114).
-- After:  work_tasks.pruning_activity_id   (task-side origin, 0..N tasks per
--         activity). The old activity-side column REMAINS as the legacy
--         "primary task" mirror so pre-repair clients and the portal keep
--         resolving exactly one linked task; new clients treat it as
--         read-compatible metadata only.
--
-- ---------------------------------------------------------------------------
-- DEPRECATIONS (tolerate on read, never write from new UI)
-- ---------------------------------------------------------------------------
--   * pruning_activity_labour_lines + save_pruning_activity_labour_lines
--     (SQL 190): DEPRECATED for new writes. Existing rows remain readable and
--     keep resolving for legacy activities. Mobile no longer offers the
--     editor; the portal must not offer one either.
--   * pruning_activities.labour_hours / hourly_rate (SQL 166 scalars):
--     legacy read-only history, resolved only when an activity has neither
--     linked tasks nor 190-lines.
--   * pruning_activities.worker_or_crew: RETAINED as descriptive operational
--     metadata (who pruned; feeds pruning_row_segments.completed_by). It is
--     never a costing input.
--
-- LEGACY DATA IS NOT REWRITTEN HERE. Activities whose only cost lives in
-- 190-lines or scalars keep resolving through the legacy rungs below. The
-- one-Work-Task-per-affected-activity conversion is a SEPARATE, review-gated
-- script (see docs/pruning-work-task-costing.md) and must not run unreviewed.
-- =============================================================================

begin;

do $$
begin
  if to_regclass('public.pruning_activities') is null then
    raise exception 'SQL 166 must be applied before SQL 200.';
  end if;
  if to_regprocedure('public.work_task_effective_labour_cost(uuid)') is null then
    raise exception 'SQL 189/190 must be applied before SQL 200.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Task-side origin link — the 0..N relationship
-- ---------------------------------------------------------------------------
-- LOGICAL reference (no hard FK), following the pruning link convention
-- (SQL 113/166): both records are client-generated and replay through
-- independent offline queues in either order.
alter table public.work_tasks
  add column if not exists pruning_activity_id uuid null;

comment on column public.work_tasks.pruning_activity_id is
  'Originating pruning activity (public.pruning_activities.id), SQL 200. A pruning activity may link 0..N work tasks; each task has 0..1 originating activity. Logical reference (no FK) so offline queues can replay in either order. NULL = not created from / linked to a pruning activity.';

create index if not exists work_tasks_pruning_activity_idx
  on public.work_tasks (pruning_activity_id)
  where pruning_activity_id is not null;

-- Backfill BOTH existing link shapes onto the task side. Idempotent, and only
-- ever fills a NULL — a task explicitly linked elsewhere is never re-parented.
update public.work_tasks t
set pruning_activity_id = a.id
from public.pruning_activities a
where a.work_task_id = t.id
  and t.pruning_activity_id is null;

update public.work_tasks t
set pruning_activity_id = e.pruning_activity_id
from public.pruning_entries e
where e.work_task_id = t.id
  and e.pruning_activity_id is not null
  and e.deleted_at is null
  and t.pruning_activity_id is null;

-- ---------------------------------------------------------------------------
-- 2. Explicit link / unlink (portal + retry path; mobile may also PATCH the
--    column directly under existing work_tasks RLS)
-- ---------------------------------------------------------------------------
create or replace function public.set_work_task_pruning_activity(
  p_work_task_id uuid,
  p_activity_id uuid
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_task_vineyard uuid;
  v_activity_vineyard uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select vineyard_id into v_task_vineyard from public.work_tasks where id = p_work_task_id;
  if v_task_vineyard is null then raise exception 'Work task not found'; end if;
  if not public.has_vineyard_role(v_task_vineyard,
       array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;

  if p_activity_id is not null then
    select vineyard_id into v_activity_vineyard
      from public.pruning_activities where id = p_activity_id;
    -- The activity may still be in the client's offline queue (see SQL 114
    -- header for the identical rule on the entry link) — an unknown id is
    -- accepted. An id that EXISTS in another vineyard is rejected.
    if v_activity_vineyard is not null and v_activity_vineyard <> v_task_vineyard then
      raise exception 'pruning activity belongs to a different vineyard';
    end if;
  end if;

  update public.work_tasks
     set pruning_activity_id = p_activity_id,
         updated_by = auth.uid(),
         updated_at = now()
   where id = p_work_task_id and deleted_at is null;
end;
$$;

comment on function public.set_work_task_pruning_activity(uuid, uuid) is
  'Links (or unlinks, with NULL) a work task to its originating pruning activity (SQL 200). Unlinking leaves BOTH records intact: the task remains a valid standalone cost record and the activity simply stops deriving that task''s hours/cost.';

revoke all on function public.set_work_task_pruning_activity(uuid, uuid) from public, anon;
grant execute on function public.set_work_task_pruning_activity(uuid, uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. The linked-task SET of one activity
-- ---------------------------------------------------------------------------
-- Union of the task-side origin link and the legacy activity-side mirror,
-- de-duplicated, live tasks only.
create or replace function public.pruning_activity_work_task_ids(p_activity_id uuid)
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select t.id
  from public.work_tasks t
  where t.deleted_at is null
    and (t.pruning_activity_id = p_activity_id
         or t.id = (select a.work_task_id from public.pruning_activities a
                     where a.id = p_activity_id))
  group by t.id;
$$;

comment on function public.pruning_activity_work_task_ids(uuid) is
  'Every LIVE work task linked to a pruning activity (SQL 200): the task-side pruning_activity_id links plus the legacy activity-side mirror, de-duplicated.';

-- ---------------------------------------------------------------------------
-- 4. Derived activity totals — SUM of the linked tasks' CANONICAL figures
-- ---------------------------------------------------------------------------
-- Per task the canonical figure is the task's OWN record only:
--   piece_rate -> piece_rate_total_cost (snapshot; hours are history)
--   hourly     -> its own rated labour lines
-- The SQL 190 "read-through" (a lineless mirror task borrowing the activity's
-- lines) is deliberately EXCLUDED from this aggregate: with N tasks it would
-- count the same legacy rows once per task and it is circular at activity
-- level. Legacy activities without task-owned cost fall through to the legacy
-- rungs in §5 instead.
create or replace function public.pruning_activity_work_tasks_labour_cost(p_activity_id uuid)
returns numeric
language sql stable security definer set search_path = public
as $$
  select sum(c.task_cost)
  from (
    select case
             when t.costing_method = 'piece_rate' then t.piece_rate_total_cost
             else public.work_task_labour_line_cost(t.id)
           end as task_cost
    from public.work_tasks t
    where t.id in (select public.pruning_activity_work_task_ids(p_activity_id))
  ) c
  where c.task_cost is not null;
$$;

comment on function public.pruning_activity_work_tasks_labour_cost(uuid) is
  'SUM of the linked work tasks'' canonical labour costs (SQL 200). Each task contributes its OWN record only (piece-rate snapshot or its own rated lines) — never the SQL 190 read-through, so nothing is counted twice. NULL when no linked task carries a cost.';

create or replace function public.pruning_activity_work_tasks_labour_hours(p_activity_id uuid)
returns numeric
language sql stable security definer set search_path = public
as $$
  select sum(h.task_hours)
  from (
    select (select sum(l.total_hours::numeric)
              from public.work_task_labour_lines l
             where l.work_task_id = t.id and l.deleted_at is null) as task_hours
    from public.work_tasks t
    where t.id in (select public.pruning_activity_work_task_ids(p_activity_id))
  ) h
  where h.task_hours is not null;
$$;

comment on function public.pruning_activity_work_tasks_labour_hours(uuid) is
  'SUM of the linked work tasks'' own labour-line hours (SQL 200). Includes unrated lines (hours are productivity data) and piece-rate tasks'' recorded hours (operational history). NULL when no linked task owns a line.';

create or replace function public.pruning_activity_work_task_count(p_activity_id uuid)
returns integer
language sql stable security definer set search_path = public
as $$
  select count(*)::integer
  from public.pruning_activity_work_task_ids(p_activity_id);
$$;

comment on function public.pruning_activity_work_task_count(uuid) is
  'Number of LIVE work tasks linked to a pruning activity (SQL 200).';

-- ---------------------------------------------------------------------------
-- 5. Effective activity labour — WORK TASKS FIRST, legacy beneath
-- ---------------------------------------------------------------------------
-- Replaced in place so every consumer (feed, report, export, portal) picks the
-- repaired authority up unchanged. STRICT precedence, never addition:
--
--   1. the linked work tasks' canonical totals (SQL 200)  <- the repair
--   2. the activity's own 190-lines            (DEPRECATED legacy, read-only)
--   3. the legacy mirror task's rated lines    (SQL 189, single-task history)
--   4. the legacy scalar pair                  (SQL 166)
--
-- Rung 1 only resolves when at least one linked task carries its OWN cost, so
-- every pre-repair record keeps its exact current value.
create or replace function public.pruning_activity_effective_labour_cost(
  p_activity_id uuid
) returns numeric
language sql stable security definer set search_path = public
as $$
  select case
           when a.id is null then null
           else coalesce(
             -- 1. THE repaired authority: SUM of linked tasks' canonical totals.
             public.pruning_activity_work_tasks_labour_cost(a.id),
             -- 2. DEPRECATED activity-owned lines (SQL 190), read-only legacy.
             public.pruning_activity_labour_line_cost(a.id),
             -- 3. Legacy mirror-task read (SQL 189) — kept for activities whose
             --    mirror task predates task-owned lines. Covered by rung 1 when
             --    the task owns lines, so this only fills historical NULLs.
             case when a.work_task_id is not null
                  then public.work_task_labour_line_cost(a.work_task_id) end,
             -- 4. Legacy scalars (SQL 166), unchanged.
             case
               when a.labour_hours is not null and a.hourly_rate is not null
               then round((a.labour_hours * a.hourly_rate)::numeric, 2)
             end
           )
         end
  from public.pruning_activities a
  where a.id = p_activity_id;
$$;

comment on function public.pruning_activity_effective_labour_cost(uuid) is
  'Effective labour cost of a pruning activity (SQL 189/190, REPAIRED by SQL 200). Precedence, never addition: SUM of the linked work tasks'' canonical totals; else the deprecated activity-owned 190-lines; else the legacy mirror task''s lines; else the legacy scalar pair. Work Tasks are the single cost ledger — the activity figure is DERIVED, so summing activities and tasks never counts the same money twice. NULL means "not specified", never $0.00.';

create or replace function public.pruning_activity_effective_labour_hours(p_activity_id uuid)
returns numeric
language sql stable security definer set search_path = public
as $$
  select coalesce(
           public.pruning_activity_work_tasks_labour_hours(p_activity_id),
           public.pruning_activity_labour_line_hours(p_activity_id),
           (select a.labour_hours from public.pruning_activities a
             where a.id = p_activity_id)
         );
$$;

comment on function public.pruning_activity_effective_labour_hours(uuid) is
  'Total labour hours of a pruning activity (SQL 190, REPAIRED by SQL 200): the linked work tasks'' own line hours when any exist, else the deprecated 190-lines, else the legacy scalar. Precedence, never addition.';

create or replace function public.pruning_activity_labour_cost_source(
  p_activity_id uuid
) returns text
language sql stable security definer set search_path = public
as $$
  select case
           when a.id is null then null
           when public.pruning_activity_work_tasks_labour_cost(a.id) is not null then
             'work_tasks'
           when public.pruning_activity_labour_line_cost(a.id) is not null then
             'pruning_labour_lines'
           when a.work_task_id is not null
                and public.work_task_labour_line_cost(a.work_task_id) is not null then
             'labour_lines'
           else
             case when a.labour_hours is not null and a.hourly_rate is not null
                  then 'activity_hours' end
         end
  from public.pruning_activities a
  where a.id = p_activity_id;
$$;

comment on function public.pruning_activity_labour_cost_source(uuid) is
  'Labels the branch pruning_activity_effective_labour_cost took (SQL 200): work_tasks | pruning_labour_lines (deprecated legacy) | labour_lines (legacy mirror task) | activity_hours (legacy scalars) | NULL.';

create or replace function public.pruning_activity_labour_hours_source(p_activity_id uuid)
returns text
language sql stable security definer set search_path = public
as $$
  select case
           when public.pruning_activity_work_tasks_labour_hours(p_activity_id) is not null
             then 'work_tasks'
           when public.pruning_activity_labour_line_hours(p_activity_id) is not null
             then 'labour_lines'
           when (select a.labour_hours from public.pruning_activities a
                  where a.id = p_activity_id) is not null
             then 'activity_hours'
         end;
$$;

revoke all on function public.pruning_activity_work_task_ids(uuid) from public, anon;
revoke all on function public.pruning_activity_work_tasks_labour_cost(uuid) from public, anon;
revoke all on function public.pruning_activity_work_tasks_labour_hours(uuid) from public, anon;
revoke all on function public.pruning_activity_work_task_count(uuid) from public, anon;

grant execute on function public.pruning_activity_work_task_ids(uuid) to authenticated, service_role;
grant execute on function public.pruning_activity_work_tasks_labour_cost(uuid) to authenticated, service_role;
grant execute on function public.pruning_activity_work_tasks_labour_hours(uuid) to authenticated, service_role;
grant execute on function public.pruning_activity_work_task_count(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. pruning_activity_json — expose the linked-task set and derived totals
-- ---------------------------------------------------------------------------
-- Rebuilt from the SQL 190 definition. Changes, and ONLY these changes:
--   * `work_task_ids`, `work_tasks` (per-task summaries) and
--     `work_task_count` are ADDED to the activity object,
--   * `totals.labour_hours` / `totals.labour_cost` now resolve through the
--     repaired chain (same keys, repaired authority),
--   * every legacy key (labour_lines, labour_hours, hourly_rate, work_task_id,
--     piece-rate mirror fields) is RETAINED byte-for-byte for old readers.
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
  v_task public.work_tasks%rowtype;
  v_cost numeric;
  v_source text;
  v_lines jsonb;
  v_line_count integer;
  v_hours numeric;
  v_hours_source text;
  v_tasks jsonb;
  v_task_ids jsonb;
  v_task_count integer;
begin
  select * into v_act from public.pruning_activities where id = p_activity_id;
  if not found then
    return null;
  end if;

  if v_act.start_time is not null and v_act.finish_time is not null
     and v_act.finish_time > v_act.start_time then
    v_duration := round(extract(epoch from (v_act.finish_time - v_act.start_time))::numeric / 3600.0, 4);
  end if;

  v_cost := public.pruning_activity_effective_labour_cost(p_activity_id);
  v_source := public.pruning_activity_labour_cost_source(p_activity_id);
  v_lines := public.pruning_activity_labour_lines_json(p_activity_id);
  v_line_count := public.pruning_activity_labour_line_count(p_activity_id);
  v_hours := public.pruning_activity_effective_labour_hours(p_activity_id);
  v_hours_source := public.pruning_activity_labour_hours_source(p_activity_id);
  if v_act.work_task_id is not null then
    select * into v_task from public.work_tasks where id = v_act.work_task_id;
  end if;

  -- SQL 200: the linked-task set with each task's CANONICAL summary, so the
  -- portal renders per-task cards without re-deriving costing rules.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id,
           'task_type', t.task_type,
           'date', t.date,
           'status', t.status,
           'is_finalized', t.is_finalized,
           'is_archived', t.is_archived,
           'costing_method', t.costing_method,
           'piece_rate_per_vine', t.piece_rate_per_vine,
           'piece_vine_count', t.piece_vine_count,
           'labour_hours', (select sum(l.total_hours::numeric)
                              from public.work_task_labour_lines l
                             where l.work_task_id = t.id and l.deleted_at is null),
           'labour_cost', case
             when t.costing_method = 'piece_rate' then t.piece_rate_total_cost
             else public.work_task_labour_line_cost(t.id)
           end
         ) order by t.date, t.created_at), '[]'::jsonb),
         coalesce(jsonb_agg(to_jsonb(t.id) order by t.date, t.created_at), '[]'::jsonb),
         count(*)::integer
    into v_tasks, v_task_ids, v_task_count
  from public.work_tasks t
  where t.id in (select public.pruning_activity_work_task_ids(p_activity_id));

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
      -- Descriptive operational metadata only — never a costing input.
      'worker_or_crew', v_act.worker_or_crew,
      'method', v_act.pruning_method,
      'start_time', v_act.start_time,
      'finish_time', v_act.finish_time,
      'duration_hours', v_duration,
      -- AS RECORDED (legacy), so a pre-repair activity round-trips exactly.
      'labour_hours', v_act.labour_hours,
      'hourly_rate', v_act.hourly_rate,
      -- DEPRECATED legacy lines (SQL 190): read-only history.
      'labour_lines', v_lines,
      'labour_line_count', v_line_count,
      'total_labour_hours', v_hours,
      'labour_hours_source', v_hours_source,
      'labour_cost', v_cost,
      'labour_cost_source', v_source,
      'costing_method', v_task.costing_method,
      'piece_rate_per_vine', v_task.piece_rate_per_vine,
      'piece_vine_count', v_task.piece_vine_count,
      'piece_rate_total_cost', v_task.piece_rate_total_cost,
      'notes', v_act.notes,
      -- Legacy 0..1 mirror (primary task). New readers use work_task_ids.
      'work_task_id', v_act.work_task_id,
      -- SQL 200: the 0..N linked-task set and per-task canonical summaries.
      'work_task_ids', v_task_ids,
      'work_tasks', v_tasks,
      'work_task_count', v_task_count,
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
      -- DERIVED from the linked Work Tasks when any carry labour; legacy
      -- fallbacks otherwise. Same keys as SQL 190.
      'labour_hours', v_hours,
      'total_labour_hours', v_hours,
      'labour_hours_source', v_hours_source,
      'labour_line_count', v_line_count,
      'hourly_rate', v_act.hourly_rate,
      'labour_cost', v_cost,
      'labour_cost_source', v_source,
      'work_task_count', v_task_count,
      'costing_method', v_task.costing_method,
      'piece_rate_per_vine', v_task.piece_rate_per_vine,
      'piece_vine_count', v_task.piece_vine_count,
      'piece_rate_total_cost', v_task.piece_rate_total_cost,
      'cost_per_vine', case
        when v_cost is null then null
        when v_task.costing_method = 'piece_rate' and coalesce(v_task.piece_vine_count, 0) > 0
          then round(v_cost / v_task.piece_vine_count, 4)
        when coalesce(v_act.total_estimated_vines, 0) > 0
          then round(v_cost / v_act.total_estimated_vines, 4)
      end,
      'vines_per_labour_hour', case
        when v_hours is not null and v_hours > 0
        then round(coalesce(v_act.total_estimated_vines, 0)::numeric / v_hours, 4)
      end
    )
  );
end;
$$;

revoke all on function public.pruning_activity_json(uuid, boolean) from public, anon;

comment on function public.pruning_activity_json(uuid, boolean) is
  'Activity payload (SQL 166/168/189/190, REPAIRED by SQL 200). Adds work_task_ids / work_tasks / work_task_count and derives totals.labour_hours + totals.labour_cost from the linked Work Tasks first (legacy 190-lines, mirror task and scalars only as read-only fallbacks). Every pre-200 key is retained unchanged. Work Tasks are the single cost ledger: the activity figure is derived, never a second cost.';

-- ---------------------------------------------------------------------------
-- 7. Deprecation markers on the SQL 190 write surface
-- ---------------------------------------------------------------------------
comment on table public.pruning_activity_labour_lines is
  'DEPRECATED for new writes (SQL 200): labour belongs to WORK TASKS (work_task_labour_lines). These rows remain readable legacy history and resolve only when an activity has no task-owned cost. New UI must not create or edit them; a review-gated migration converts them into one Work Task per affected activity (docs/pruning-work-task-costing.md).';

comment on function public.save_pruning_activity_labour_lines(uuid, jsonb, timestamptz) is
  'DEPRECATED for new writes (SQL 200) — kept only so queued offline writes from pre-repair clients still replay. New clients and the portal record labour on a linked WORK TASK instead (work_task_labour_lines).';

comment on column public.pruning_activities.work_task_id is
  'LEGACY 0..1 mirror of the PRIMARY linked work task (SQL 166). Since SQL 200 the authoritative relationship is work_tasks.pruning_activity_id (0..N). Kept read-compatible for pre-repair clients and the portal; new clients keep it pointing at the first linked task.';

commit;

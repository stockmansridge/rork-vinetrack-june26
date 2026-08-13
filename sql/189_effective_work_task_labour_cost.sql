-- =============================================================================
-- 189: ONE shared SQL definition of EFFECTIVE work task labour cost.
--
-- Rork/VineTrack mobile is the SOURCE OF TRUTH for this contract. Lovable (the
-- web portal) CONSUMES it and MUST NOT independently create or modify any of
-- these functions, views or rules.
--
-- WHY
-- SQL 188 added Piece Rate as an alternate costing method on `work_tasks`, and
-- both mobile clients now resolve labour cost through one helper. The database
-- did not: three shared consumers still derived labour cost from the OLD
-- hourly-only assumption, so a perfectly valid piece-rate job — 250 vines at
-- $0.55, no labour lines, no hours — surfaced as NULL or $0.00 to the portal
-- and the Integration Read API:
--
--   1. public.pruning_activity_json (SQL 166, superseded by SQL 168)
--        activity.labour_cost and totals.labour_cost = activity labour_hours
--        x hourly_rate. Never consulted the linked work task.
--   2. public.pruning_activity_allocation_export (SQL 166, rebuilt by SQL 168)
--        activity_labour_cost = the same legacy formula.
--   3. supabase/functions/vinetrack-api (Edge Function)
--        omitted the SQL 188 columns entirely. Handled separately, in the same
--        change, reading the same rule.
--
-- This migration is STRICTLY ADDITIVE:
--   * no column, table, constraint, index or RLS policy is added, dropped,
--     altered or renamed,
--   * SQL 188 is NOT edited,
--   * no synthetic labour line, labour type or worker record is created,
--   * no existing key is removed from pruning_activity_json,
--   * no existing column is removed from or reordered within the export view,
--   * every hourly and legacy record keeps its exact current value.
--
-- ---------------------------------------------------------------------------
-- THE RULE — one definition, three consumers
-- ---------------------------------------------------------------------------
-- Effective WORK TASK labour cost:
--
--   costing_method = 'piece_rate'  -> work_tasks.piece_rate_total_cost
--   anything else (incl. NULL)     -> SUM(active work_task_labour_lines.total_cost)
--
-- Effective PRUNING ACTIVITY labour cost:
--
--   linked work task, piece rate   -> the task's piece_rate_total_cost
--   linked work task, otherwise    -> the task's labour-line total, and if the
--                                     task carries NO costed line at all, the
--                                     activity's own labour_hours x hourly_rate
--                                     (this is exactly today's value, so no
--                                     existing record changes)
--   no linked work task            -> labour_hours x hourly_rate (unchanged)
--
-- Three invariants, identical to the mobile helper:
--   1. NEVER sum the two. A task has exactly ONE labour cost.
--   2. NEVER infer piece rate from the presence of a rate. `costing_method`
--      is the only switch, and any unrecognised value reads as hourly.
--   3. NEVER force a missing value to 0.00. Unknown is NULL — "not specified".
--
-- ---------------------------------------------------------------------------
-- WHY UNRATED LABOUR LINES ARE SKIPPED, NOT COUNTED AS ZERO
-- ---------------------------------------------------------------------------
-- `work_task_labour_lines.total_cost` (SQL 050) is generated as
--     worker_count * hours_per_worker * coalesce(hourly_rate, 0)
-- so a line recorded WITHOUT a rate contributes a hard 0. Summing those blindly
-- turns "nobody entered a rate" into "$0.00", which is the exact failure this
-- migration exists to remove. Only lines with a non-null `hourly_rate` are
-- costed; a task whose lines all lack rates resolves to NULL, not 0. This
-- matches WorkTaskLabourCosting on iOS and Android line for line.
--
-- ---------------------------------------------------------------------------
-- HISTORICAL PROTECTION
-- ---------------------------------------------------------------------------
-- Piece-rate cost is read from `work_tasks.piece_rate_total_cost`, which SQL
-- 188 generates from the SNAPSHOT columns (`piece_vine_count` x
-- `piece_rate_per_vine`). Nothing here reads `paddocks.rows`, so no vineyard
-- edit can ever re-cost a historical job.
-- =============================================================================

begin;

-- Guard: 189 has nothing to attach to without 188.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'work_tasks'
      and column_name = 'piece_rate_total_cost'
  ) then
    raise exception 'SQL 188 must be applied before SQL 189.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. work_task_labour_line_cost — the hourly/legacy side, on its own
-- ---------------------------------------------------------------------------
-- Kept separate so a caller can show BOTH numbers side by side (an audit
-- screen may want to say "hourly lines would have been $480") without any
-- caller ever being tempted to add them together.
create or replace function public.work_task_labour_line_cost(p_work_task_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select sum(l.total_cost::numeric)
  from public.work_task_labour_lines l
  where l.work_task_id = p_work_task_id
    and l.deleted_at is null
    -- Unrated lines are operational history, not a $0.00 cost.
    and l.hourly_rate is not null;
$$;

comment on function public.work_task_labour_line_cost(uuid) is
  'SUM of ACTIVE, RATED work_task_labour_lines.total_cost for a task. NULL (never 0.00) when the task has no costed line. This is the HOURLY side only — never add it to piece_rate_total_cost; use work_task_effective_labour_cost to pick the one that applies (SQL 189).';

-- ---------------------------------------------------------------------------
-- 2. work_task_effective_labour_cost — THE shared definition
-- ---------------------------------------------------------------------------
-- Every database object that exposes a work task's labour cost must call this
-- and nothing else. One rule, one place to change it.
create or replace function public.work_task_effective_labour_cost(p_work_task_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case
           when t.id is null then null
           when t.costing_method = 'piece_rate' then t.piece_rate_total_cost
           else public.work_task_labour_line_cost(t.id)
         end
  from public.work_tasks t
  where t.id = p_work_task_id;
$$;

comment on function public.work_task_effective_labour_cost(uuid) is
  'THE effective labour cost of a work task (SQL 189). piece_rate -> work_tasks.piece_rate_total_cost; anything else, including a NULL/unknown costing_method -> SUM of active rated labour lines. The two are NEVER summed. NULL means "not specified", never $0.00. Mirrors PieceRateCosting.effectiveLabourCost on iOS/Android exactly.';

-- ---------------------------------------------------------------------------
-- 3. work_task_labour_cost_source — which branch produced the number
-- ---------------------------------------------------------------------------
-- Reports need to LABEL the figure ("Piece rate" vs "Hourly"), and without
-- this every consumer would re-derive the branch and eventually disagree with
-- the cost it is labelling.
create or replace function public.work_task_labour_cost_source(p_work_task_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
           when t.id is null then null
           when t.costing_method = 'piece_rate' then 'piece_rate'
           when public.work_task_labour_line_cost(t.id) is not null then 'labour_lines'
           else null
         end
  from public.work_tasks t
  where t.id = p_work_task_id;
$$;

comment on function public.work_task_labour_cost_source(uuid) is
  'Labels the branch work_task_effective_labour_cost took: piece_rate | labour_lines | NULL (no cost specified). Never re-derive this in a consumer (SQL 189).';

-- ---------------------------------------------------------------------------
-- 4. v_work_task_effective_labour_cost — set-based form for joins
-- ---------------------------------------------------------------------------
-- The scalar function is right for a single row (an RPC). A view that joins a
-- pre-aggregated labour-line total is right for the export view, which reads
-- thousands of allocations at once.
--
-- security_invoker keeps the caller's RLS on work_tasks, exactly like the
-- existing export view.
create or replace view public.v_work_task_effective_labour_cost as
select
  t.id                                as work_task_id,
  t.vineyard_id,
  t.costing_method,
  t.piece_rate_per_vine,
  t.piece_vine_count,
  t.piece_rate_total_cost,
  l.labour_line_cost,
  case
    when t.costing_method = 'piece_rate' then t.piece_rate_total_cost
    else l.labour_line_cost
  end                                 as effective_labour_cost,
  case
    when t.costing_method = 'piece_rate' then 'piece_rate'
    when l.labour_line_cost is not null then 'labour_lines'
    else null
  end                                 as labour_cost_source,
  -- Cost per vine on the SNAPSHOT quantity, never today's geometry.
  case
    when t.costing_method = 'piece_rate' then t.piece_rate_per_vine
  end                                 as cost_per_vine
from public.work_tasks t
left join lateral (
  select sum(x.total_cost::numeric) as labour_line_cost
  from public.work_task_labour_lines x
  where x.work_task_id = t.id
    and x.deleted_at is null
    and x.hourly_rate is not null
) l on true;

alter view public.v_work_task_effective_labour_cost set (security_invoker = true);
grant select on public.v_work_task_effective_labour_cost to authenticated;

comment on view public.v_work_task_effective_labour_cost is
  'Set-based form of work_task_effective_labour_cost for joins (SQL 189). effective_labour_cost is piece_rate_total_cost for a piece-rate task and the active rated labour-line total otherwise; the two are never summed. labour_line_cost is exposed alongside for audit only. NULL means "not specified".';

-- ---------------------------------------------------------------------------
-- 5. pruning_activity_effective_labour_cost — the activity-level rule
-- ---------------------------------------------------------------------------
-- Precedence, never addition:
--   linked piece-rate task  -> the task's snapshot total (no fallback: an
--                              unpriced piece-rate job is "not specified", and
--                              falling back to hours x rate would report an
--                              HOURLY figure for a piece-rate job)
--   linked hourly/legacy    -> the task's labour lines, else the activity's own
--                              hours x rate (preserves today's value exactly)
--   unlinked                -> hours x rate (untouched legacy behaviour)
create or replace function public.pruning_activity_effective_labour_cost(
  p_activity_id uuid
) returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case
           when a.id is null then null
           when a.work_task_id is null then
             case
               when a.labour_hours is not null and a.hourly_rate is not null
               then round((a.labour_hours * a.hourly_rate)::numeric, 2)
             end
           when (select t.costing_method from public.work_tasks t
                  where t.id = a.work_task_id) = 'piece_rate' then
             (select t.piece_rate_total_cost from public.work_tasks t
               where t.id = a.work_task_id)
           else
             coalesce(
               public.work_task_labour_line_cost(a.work_task_id),
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
  'Effective labour cost of a pruning activity (SQL 189). Linked piece-rate task -> its snapshot total. Linked hourly/legacy task -> its rated labour lines, falling back to the activity''s own labour_hours x hourly_rate so no pre-189 value changes. No linked task -> the legacy hours x rate. Precedence, never addition; NULL means "not specified".';

create or replace function public.pruning_activity_labour_cost_source(
  p_activity_id uuid
) returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
           when a.id is null then null
           when a.work_task_id is null then
             case when a.labour_hours is not null and a.hourly_rate is not null
                  then 'activity_hours' end
           when (select t.costing_method from public.work_tasks t
                  where t.id = a.work_task_id) = 'piece_rate' then
             case when (select t.piece_rate_total_cost from public.work_tasks t
                         where t.id = a.work_task_id) is not null
                  then 'piece_rate' end
           when public.work_task_labour_line_cost(a.work_task_id) is not null then
             'labour_lines'
           else
             case when a.labour_hours is not null and a.hourly_rate is not null
                  then 'activity_hours' end
         end
  from public.pruning_activities a
  where a.id = p_activity_id;
$$;

comment on function public.pruning_activity_labour_cost_source(uuid) is
  'Labels the branch pruning_activity_effective_labour_cost took: piece_rate | labour_lines | activity_hours | NULL (SQL 189).';

revoke all on function public.work_task_labour_line_cost(uuid) from public, anon;
revoke all on function public.work_task_effective_labour_cost(uuid) from public, anon;
revoke all on function public.work_task_labour_cost_source(uuid) from public, anon;
revoke all on function public.pruning_activity_effective_labour_cost(uuid) from public, anon;
revoke all on function public.pruning_activity_labour_cost_source(uuid) from public, anon;

grant execute on function public.work_task_labour_line_cost(uuid) to authenticated, service_role;
grant execute on function public.work_task_effective_labour_cost(uuid) to authenticated, service_role;
grant execute on function public.work_task_labour_cost_source(uuid) to authenticated, service_role;
grant execute on function public.pruning_activity_effective_labour_cost(uuid) to authenticated, service_role;
grant execute on function public.pruning_activity_labour_cost_source(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. pruning_activity_json — labour cost now comes from the shared rule
-- ---------------------------------------------------------------------------
-- Rebuilt from the SQL 168 definition. Changes, and ONLY these changes:
--   * activity.labour_cost and totals.labour_cost call
--     pruning_activity_effective_labour_cost instead of inlining
--     labour_hours x hourly_rate,
--   * four SQL 188 piece-rate keys and a labour_cost_source label are ADDED to
--     both objects.
-- Every other key, its name, its type and its value are byte-for-byte the SQL
-- 168 definition. labour_hours and hourly_rate are deliberately still reported
-- as recorded — on a piece-rate job they are operational history, and hiding
-- them would lose the vines-per-hour productivity read.
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
begin
  select * into v_act from public.pruning_activities where id = p_activity_id;
  if not found then
    return null;
  end if;

  if v_act.start_time is not null and v_act.finish_time is not null
     and v_act.finish_time > v_act.start_time then
    v_duration := round(extract(epoch from (v_act.finish_time - v_act.start_time))::numeric / 3600.0, 4);
  end if;

  -- ONE shared rule for the labour figure, and the linked task's piece-rate
  -- contract carried through so a consumer never has to fetch it separately.
  v_cost := public.pruning_activity_effective_labour_cost(p_activity_id);
  v_source := public.pruning_activity_labour_cost_source(p_activity_id);
  if v_act.work_task_id is not null then
    select * into v_task from public.work_tasks where id = v_act.work_task_id;
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
      -- Hours and the hourly rate are reported AS RECORDED. On a piece-rate
      -- job they are operational history and never a cost basis.
      'labour_hours', v_act.labour_hours,
      'hourly_rate', v_act.hourly_rate,
      -- SQL 189: the shared effective cost, not hours x rate.
      'labour_cost', v_cost,
      'labour_cost_source', v_source,
      -- SQL 188 contract, carried through additively.
      'costing_method', v_task.costing_method,
      'piece_rate_per_vine', v_task.piece_rate_per_vine,
      'piece_vine_count', v_task.piece_vine_count,
      'piece_rate_total_cost', v_task.piece_rate_total_cost,
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
      -- Shared labour, counted ONCE for the whole activity.
      'labour_hours', v_act.labour_hours,
      'hourly_rate', v_act.hourly_rate,
      'labour_cost', v_cost,
      'labour_cost_source', v_source,
      'costing_method', v_task.costing_method,
      'piece_rate_per_vine', v_task.piece_rate_per_vine,
      'piece_vine_count', v_task.piece_vine_count,
      'piece_rate_total_cost', v_task.piece_rate_total_cost,
      -- Cost per vine on the SNAPSHOT quantity for a piece-rate job, and on
      -- the activity's own estimated vines otherwise.
      'cost_per_vine', case
        when v_cost is null then null
        when v_task.costing_method = 'piece_rate' and coalesce(v_task.piece_vine_count, 0) > 0
          then round(v_cost / v_task.piece_vine_count, 4)
        when coalesce(v_act.total_estimated_vines, 0) > 0
          then round(v_cost / v_act.total_estimated_vines, 4)
      end
    )
  );
end;
$$;

revoke all on function public.pruning_activity_json(uuid, boolean) from public, anon;

comment on function public.pruning_activity_json(uuid, boolean) is
  'Activity payload for the feed, report, editor and exports (SQL 166, extended by SQL 168 and SQL 189). labour_cost now comes from pruning_activity_effective_labour_cost: a linked piece-rate task reports its snapshot total even with zero labour lines and zero hours; hourly and unlinked activities keep their exact pre-189 value. labour_hours / hourly_rate are still reported as recorded (operational history on a piece-rate job).';

-- ---------------------------------------------------------------------------
-- 7. pruning_activity_allocation_export — allocate the EFFECTIVE cost
-- ---------------------------------------------------------------------------
-- `create or replace view` matches columns BY POSITION, so new columns cannot
-- be inserted mid-list. The new costing columns belong beside the figure they
-- explain, so the view is dropped and rebuilt exactly as SQL 168 did. It is a
-- leaf read by exports only; the drop is deliberately NOT cascaded, so if a
-- dependant is ever added this fails loudly here instead of silently deleting
-- someone's report.
--
-- ALL SQL 168 columns are preserved, with their SQL 168 names and semantics.
-- Added: activity_labour_cost_source, activity_costing_method,
-- activity_piece_rate_per_vine, activity_piece_vine_count and
-- allocation_share_labour_cost.
--
-- RECONCILIATION
-- activity_labour_cost stays on the PRIMARY allocation row only, so summing a
-- CSV never double-counts shared labour. allocation_share_labour_cost splits
-- that same figure across the live, non-skipped allocations by their share of
-- row equivalents, rounded to cents, with the rounding residual assigned to
-- the primary row. SUM(allocation_share_labour_cost) therefore equals
-- activity_labour_cost EXACTLY — no drifting half-cents.
drop view if exists public.pruning_activity_allocation_export;

create view public.pruning_activity_allocation_export as
with alloc as (
  select
    a.id                              as activity_id,
    a.vineyard_id,
    a.entry_date                      as activity_date,
    a.worker_or_crew,
    a.pruning_method                  as method,
    a.block_summary,
    a.labour_hours                    as a_labour_hours,
    a.hourly_rate                     as a_hourly_rate,
    a.total_row_equivalents           as a_total_row_equivalents,
    a.work_task_id                    as a_work_task_id,
    a.deleted_at                      as a_deleted_at,
    a.created_by,
    a.created_at,
    a.updated_at,
    e.id                              as allocation_id,
    e.allocation_index,
    e.paddock_id,
    e.pruning_season_id,
    e.vintage_year,
    e.row_equivalents_completed,
    e.estimated_vines_completed,
    e.is_skipped,
    e.deleted_at                      as e_deleted_at,
    p.name                            as block,
    s.season_year,
    -- SQL 189: the shared rule, resolved once per activity.
    case
      when a.work_task_id is null then
        case when a.labour_hours is not null and a.hourly_rate is not null
             then round((a.labour_hours * a.hourly_rate)::numeric, 2) end
      when w.costing_method = 'piece_rate' then w.piece_rate_total_cost
      else coalesce(
        w.labour_line_cost,
        case when a.labour_hours is not null and a.hourly_rate is not null
             then round((a.labour_hours * a.hourly_rate)::numeric, 2) end
      )
    end                               as effective_labour_cost,
    case
      when a.work_task_id is null then
        case when a.labour_hours is not null and a.hourly_rate is not null
             then 'activity_hours' end
      when w.costing_method = 'piece_rate' then
        case when w.piece_rate_total_cost is not null then 'piece_rate' end
      when w.labour_line_cost is not null then 'labour_lines'
      else
        case when a.labour_hours is not null and a.hourly_rate is not null
             then 'activity_hours' end
    end                               as labour_cost_source,
    w.costing_method                  as costing_method,
    w.piece_rate_per_vine             as piece_rate_per_vine,
    w.piece_vine_count                as piece_vine_count,
    (e.allocation_index = (
      select min(x.allocation_index) from public.pruning_entries x
      where x.pruning_activity_id = a.id and x.deleted_at is null
    ))                                as is_primary
  from public.pruning_activities a
  join public.pruning_entries e on e.pruning_activity_id = a.id
  left join public.paddocks p on p.id = e.paddock_id
  left join public.pruning_seasons s on s.id = e.pruning_season_id
  left join public.v_work_task_effective_labour_cost w on w.work_task_id = a.work_task_id
),
shared as (
  select
    alloc.*,
    -- Proportional split of the ONE effective cost. Skipped and reversed
    -- allocations are never allocated labour (SQL 168 contract).
    case
      when is_skipped or e_deleted_at is not null then null
      when effective_labour_cost is null then null
      when a_total_row_equivalents > 0
        then round(effective_labour_cost
                   * (row_equivalents_completed / a_total_row_equivalents)::numeric, 2)
      when is_primary then effective_labour_cost
    end                               as raw_share
  from alloc
)
select
  shared.activity_id,
  shared.vineyard_id,
  shared.activity_date,
  shared.worker_or_crew,
  shared.method,
  shared.block_summary,
  shared.allocation_id,
  shared.allocation_index,
  shared.paddock_id,
  shared.block,
  shared.pruning_season_id,
  shared.season_year,
  shared.vintage_year,
  (select coalesce(jsonb_agg(distinct g.row_number), '[]'::jsonb)
   from public.pruning_row_segments g
   where g.pruning_entry_id = shared.allocation_id) as rows,
  (select count(*) from public.pruning_row_segments g
   where g.pruning_entry_id = shared.allocation_id)  as quarters,
  shared.row_equivalents_completed    as row_equivalents,
  -- Completion counts skipped sections; pruning work never does.
  shared.row_equivalents_completed    as completion_row_equivalents,
  case when shared.is_skipped then 0 else shared.row_equivalents_completed end
                                      as pruned_row_equivalents,
  case when shared.is_skipped then shared.row_equivalents_completed else 0 end
                                      as skipped_row_equivalents,
  shared.estimated_vines_completed    as vines,
  case when shared.is_skipped then 0 else shared.estimated_vines_completed end
                                      as vines_pruned,
  case when shared.is_skipped then shared.estimated_vines_completed else 0 end
                                      as vines_skipped,
  shared.is_skipped,
  case when shared.is_skipped then null when shared.is_primary
    then shared.a_labour_hours end    as activity_labour_hours,
  case when shared.is_skipped then null when shared.is_primary
    then shared.a_hourly_rate end     as activity_hourly_rate,
  -- SQL 189: the EFFECTIVE cost, primary allocation row only.
  case when shared.is_skipped then null when shared.is_primary
    then shared.effective_labour_cost end as activity_labour_cost,
  case when shared.is_skipped then null when shared.is_primary
    then shared.labour_cost_source end as activity_labour_cost_source,
  case when shared.is_skipped then null when shared.is_primary
    then shared.costing_method end    as activity_costing_method,
  case when shared.is_skipped then null when shared.is_primary
    then shared.piece_rate_per_vine end as activity_piece_rate_per_vine,
  case when shared.is_skipped then null when shared.is_primary
    then shared.piece_vine_count end  as activity_piece_vine_count,
  case when shared.a_total_row_equivalents > 0
    then round(shared.row_equivalents_completed / shared.a_total_row_equivalents, 6) end
                                      as allocation_share_of_row_equivalents,
  case when shared.is_skipped then null when shared.a_total_row_equivalents > 0
        and shared.a_labour_hours is not null
    then round(shared.a_labour_hours * shared.row_equivalents_completed
               / shared.a_total_row_equivalents, 4) end
                                      as allocation_share_labour_hours_informational,
  -- The per-block money split. Rounding residual lands on the primary row so
  -- the allocations reconcile EXACTLY to activity_labour_cost.
  case
    when shared.raw_share is null then null
    when shared.is_primary then
      shared.raw_share
        + (shared.effective_labour_cost
           - coalesce(sum(shared.raw_share) over (partition by shared.activity_id), 0))
    else shared.raw_share
  end                                 as allocation_share_labour_cost,
  case when shared.is_skipped then null else shared.a_work_task_id end as work_task_id,
  case
    when shared.a_deleted_at is not null or shared.e_deleted_at is not null then 'reversed'
    when shared.is_skipped then 'skipped'
    else 'active'
  end                                 as status,
  shared.created_by,
  shared.created_at,
  shared.updated_at
from shared;

comment on view public.pruning_activity_allocation_export is
  'Allocation breakdown for reports/exports (SQL 166, extended by SQL 168 and SQL 189). activity_labour_* appear on the PRIMARY allocation row only, and never on a skipped allocation, so totals never double-count shared labour. activity_labour_cost is now the EFFECTIVE cost (piece-rate snapshot total, else the rated labour-line total, else the legacy activity hours x rate) and activity_labour_cost_source labels which. allocation_share_labour_cost splits that ONE figure across live, non-skipped allocations by row-equivalent share with the rounding residual on the primary row, so it reconciles exactly. status is active | skipped | reversed.';

alter view public.pruning_activity_allocation_export set (security_invoker = true);
grant select on public.pruning_activity_allocation_export to authenticated;

commit;

-- =============================================================================
-- END 189
--
-- Manual actions after applying:
--   * run sql/tests/189_effective_work_task_labour_cost_tests.sql
--   * redeploy supabase/functions/vinetrack-api (it reads the SQL 188 columns
--     and reports effective_labour_cost using this same rule)
--   * Lovable/portal: CONSUME this contract only. Read labour_cost /
--     activity_labour_cost as authoritative and STOP deriving hours x rate.
-- =============================================================================

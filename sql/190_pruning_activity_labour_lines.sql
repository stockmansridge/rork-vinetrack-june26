-- =============================================================================
-- 190: MULTIPLE labour lines per PRUNING ACTIVITY.
--
-- Rork/VineTrack mobile is the SOURCE OF TRUTH for this contract. Lovable (the
-- web portal) CONSUMES it and MUST NOT independently create or modify any of
-- these tables, functions, views or rules.
--
-- ---------------------------------------------------------------------------
-- WHY (what the audit found)
-- ---------------------------------------------------------------------------
-- Work Tasks have supported N labour lines since SQL 050
-- (public.work_task_labour_lines: per day, per worker TYPE, with worker_count,
-- hours_per_worker and generated total_hours / total_cost).
--
-- Pruning has nothing of the sort. Pruning labour is DENORMALISED onto the
-- parent activity (SQL 166) as exactly three scalar columns:
--     pruning_activities.worker_or_crew   text
--     pruning_activities.labour_hours     numeric
--     pruning_activities.hourly_rate      numeric
-- One crew, one figure for hours, one rate. A pruning day worked by two
-- contractors at different rates, or by a crew that changed size midweek,
-- cannot be recorded at all.
--
-- There is NO hidden pruning labour-line table that the clients simply are not
-- exposing: the only child of an activity is `pruning_entries`, which is the
-- per-BLOCK allocation table (rows, quarters, vines), and SQL 166 mirrors the
-- legacy labour scalars onto the PRIMARY allocation only, precisely so that a
-- legacy `sum(labour_hours)` still counts the activity once.
--
-- `work_task_labour_lines` cannot be reused directly: its `work_task_id` is
-- NOT NULL with an FK to `work_tasks`, while `pruning_activities.work_task_id`
-- is nullable and most pruning activities have no linked task at all. Reusing
-- it would mean fabricating a Work Task for every pruning day just to hold
-- labour — inventing rows in a module the user never touched, and inflating
-- Work Task counts and reports.
--
-- So: a migration IS required. This one MIRRORS the SQL 050 contract instead of
-- inventing a second, differently-shaped labour system. Same column names, same
-- semantics, same generated-column arithmetic, same soft-delete rule — so one
-- labour-line editor, one sync shape and one cost helper serve both modules on
-- iOS, Android and the portal.
--
-- ---------------------------------------------------------------------------
-- OWNERSHIP MODEL — labour is PRUNING-OWNED; the linked task REFERENCES it
-- ---------------------------------------------------------------------------
-- The requirement is a single authoritative labour cost that is never counted
-- twice. There are exactly two candidate models:
--
--   (a) SHARE rows with the linked Work Task's labour lines.
--       Rejected. It needs a Work Task to exist for every pruning activity,
--       which is false today and would force synthetic tasks offline. It also
--       makes the pruning editor write into another module's table, so
--       reversing a pruning activity would silently mutate a Work Task.
--
--   (b) PRUNING-OWNED lines; the linked Work Task RESOLVES to the same figure.
--       Chosen. Labour belongs to the pruning activity — which is exactly where
--       SQL 166 already put it, and exactly what "labour is counted once no
--       matter how many blocks" requires. The Work Task does not get a second
--       copy: when a pruning-linked task carries no labour of its own, its
--       effective cost RESOLVES THROUGH to the activity's lines. One stored
--       set, two readers, identical number.
--
-- Nothing is ever added together. Both resolvers are strict precedence chains:
--
--   PRUNING ACTIVITY effective labour cost
--     1. linked PIECE-RATE task -> the task's piece_rate_total_cost
--        (a piece rate IS the cost; pruning hours stay operational history)
--     2. the activity's OWN rated labour lines            <- NEW in 190
--     3. the linked hourly task's rated labour lines      (SQL 189, unchanged)
--     4. the activity's own labour_hours x hourly_rate    (legacy, unchanged)
--
--   WORK TASK effective labour cost
--     1. piece_rate            -> piece_rate_total_cost   (SQL 188/189)
--     2. its own rated labour lines                       (SQL 189)
--     3. the rated labour lines of the pruning activity
--        that links to it                                 <- NEW in 190
--
-- Rung 3 on the task side can only ever turn a NULL into a value: before this
-- migration no pruning activity could own a labour line, so no existing task
-- cost changes. Rung 2 on the pruning side likewise cannot alter any existing
-- activity, because no activity owns lines yet. The migration is therefore
-- additive in DATA and in BEHAVIOUR: every pre-190 record keeps its exact
-- current value.
--
-- ---------------------------------------------------------------------------
-- LEGACY ACTIVITIES ARE NOT BACKFILLED
-- ---------------------------------------------------------------------------
-- `worker_or_crew`, `labour_hours` and `hourly_rate` are NOT dropped, altered,
-- copied or cleared. An activity with no labour lines keeps resolving through
-- the legacy rung and displays exactly as it does today. Converting a legacy
-- activity to lines is a USER action in the editor, never an automatic rewrite,
-- so no historical cost is ever silently restated. A backfill would also be
-- lossy in one direction: `worker_or_crew` is free text ("Dave + 2 casuals"),
-- not a worker TYPE and not a crew size, so the database cannot honestly split
-- it into worker_type + worker_count.
--
-- ---------------------------------------------------------------------------
-- HOURS vs COST — deliberately different rules
-- ---------------------------------------------------------------------------
-- total_hours sums EVERY active line (an unrated line still represents work
-- that was done — it is real productivity data for vines-per-hour).
-- total_cost sums only lines with a non-null hourly_rate, because
-- `total_cost` is generated with coalesce(hourly_rate, 0) and blindly summing
-- would turn "nobody entered a rate" into "$0.00". Identical to SQL 189 and to
-- WorkTaskLabourCosting on both mobile clients.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES NOT DO
-- ---------------------------------------------------------------------------
--   * does not edit SQL 188 or SQL 189,
--   * does not add, drop, alter or rename any existing column, constraint,
--     index or policy on pruning_activities, pruning_entries, work_tasks or
--     work_task_labour_lines,
--   * does not remove or rename any key of pruning_activity_json,
--   * does not remove or reorder any column of the export view,
--   * does not create a synthetic Work Task, labour line or worker record,
--   * does not apportion labour across blocks.
-- =============================================================================

begin;

-- Guard: 190 extends the SQL 189 resolvers; without them the precedence chain
-- below would be built on functions that do not exist.
do $$
begin
  if to_regprocedure('public.work_task_effective_labour_cost(uuid)') is null
     or to_regprocedure('public.pruning_activity_effective_labour_cost(uuid)') is null then
    raise exception 'SQL 189 must be applied before SQL 190.';
  end if;
  if to_regclass('public.pruning_activities') is null then
    raise exception 'SQL 166 must be applied before SQL 190.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. pruning_activity_labour_lines — the child table, mirroring SQL 050
-- ---------------------------------------------------------------------------
-- Column-for-column identical to work_task_labour_lines apart from the parent
-- key, so the SAME model, editor and sync shape serve both modules.
--
-- `id` is CLIENT-GENERATED (like pruning_activities itself, unlike SQL 050's
-- server default) because pruning is an offline-first module: the client id IS
-- the idempotency key, so replaying a queued create can never duplicate a line.
create table if not exists public.pruning_activity_labour_lines (
  id uuid primary key,
  pruning_activity_id uuid not null
    references public.pruning_activities(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  work_date date not null,
  worker_type_id uuid null,
  worker_type text not null default '',
  worker_count integer not null default 1,
  hours_per_worker double precision not null default 0,
  hourly_rate double precision null,
  total_hours double precision generated always as
    (coalesce(worker_count, 0)::double precision * coalesce(hours_per_worker, 0)) stored,
  total_cost double precision generated always as
    (coalesce(worker_count, 0)::double precision
      * coalesce(hours_per_worker, 0)
      * coalesce(hourly_rate, 0)) stored,
  notes text not null default '',
  -- Stable display order, so a crew list does not reshuffle between devices.
  line_index integer not null default 0,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

comment on table public.pruning_activity_labour_lines is
  'Per-day, per-worker-TYPE labour lines belonging to a pruning ACTIVITY (SQL 190). Mirrors public.work_task_labour_lines (SQL 050) column for column so one contract serves both modules. Labour belongs to the activity and is counted ONCE regardless of how many blocks the activity covers — these lines are never apportioned to pruning_entries. A linked Work Task does NOT get a second copy; it resolves through to these lines.';
comment on column public.pruning_activity_labour_lines.id is
  'CLIENT-generated idempotency key: replaying a queued offline create can never duplicate a line.';
comment on column public.pruning_activity_labour_lines.worker_type is
  'Worker CATEGORY (e.g. "Contractor"), never a person''s identity — same rule as SQL 050.';
comment on column public.pruning_activity_labour_lines.total_cost is
  'Generated with coalesce(hourly_rate, 0), so an UNRATED line reads as 0.00 here. Never sum this column directly — use pruning_activity_labour_line_cost, which skips unrated lines so "no rate entered" stays NULL instead of becoming $0.00.';
comment on column public.pruning_activity_labour_lines.line_index is
  'Stable display order within the activity. Not an identity and never used for costing.';

create index if not exists pruning_activity_labour_lines_activity_idx
  on public.pruning_activity_labour_lines (pruning_activity_id);
create index if not exists pruning_activity_labour_lines_vineyard_idx
  on public.pruning_activity_labour_lines (vineyard_id);
create index if not exists pruning_activity_labour_lines_vineyard_date_idx
  on public.pruning_activity_labour_lines (vineyard_id, work_date);
create index if not exists pruning_activity_labour_lines_updated_idx
  on public.pruning_activity_labour_lines (updated_at);
create index if not exists pruning_activity_labour_lines_deleted_idx
  on public.pruning_activity_labour_lines (deleted_at);
-- Partial index for the hot path: costing/hours roll-ups only ever read the
-- live lines of one activity.
create index if not exists pruning_activity_labour_lines_active_idx
  on public.pruning_activity_labour_lines (pruning_activity_id)
  where deleted_at is null;

drop trigger if exists pruning_activity_labour_lines_set_updated_at
  on public.pruning_activity_labour_lines;
create trigger pruning_activity_labour_lines_set_updated_at
  before update on public.pruning_activity_labour_lines
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. RLS — identical to SQL 050's labour lines
-- ---------------------------------------------------------------------------
-- Deliberately NOT the RPC-only rule used by pruning_entries. That rule exists
-- because allocations CLAIM row quarters and must be serialised. Labour lines
-- claim nothing, so they follow the labour contract they mirror: members read,
-- working roles write, nobody hard-deletes. This also lets the portal use the
-- same plain REST path it already uses for work task labour lines.
alter table public.pruning_activity_labour_lines enable row level security;

drop policy if exists "pruning_activity_labour_lines_select_members"
  on public.pruning_activity_labour_lines;
create policy "pruning_activity_labour_lines_select_members"
on public.pruning_activity_labour_lines for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "pruning_activity_labour_lines_insert_members"
  on public.pruning_activity_labour_lines;
create policy "pruning_activity_labour_lines_insert_members"
on public.pruning_activity_labour_lines for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "pruning_activity_labour_lines_update_members"
  on public.pruning_activity_labour_lines;
create policy "pruning_activity_labour_lines_update_members"
on public.pruning_activity_labour_lines for update
to authenticated
using (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

-- History is reversed, never erased — same as every other VineTrack record.
drop policy if exists "pruning_activity_labour_lines_no_client_hard_delete"
  on public.pruning_activity_labour_lines;
create policy "pruning_activity_labour_lines_no_client_hard_delete"
on public.pruning_activity_labour_lines for delete
to authenticated
using (false);

grant select, insert, update on public.pruning_activity_labour_lines to authenticated;

-- ---------------------------------------------------------------------------
-- 3. soft_delete_pruning_activity_labour_line — mirrors SQL 050
-- ---------------------------------------------------------------------------
create or replace function public.soft_delete_pruning_activity_labour_line(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id
    from public.pruning_activity_labour_lines where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Pruning labour line not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id,
       array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete pruning labour line';
  end if;
  update public.pruning_activity_labour_lines
     set deleted_at = now(), updated_by = auth.uid()
   where id = p_id and deleted_at is null;
end;
$$;

comment on function public.soft_delete_pruning_activity_labour_line(uuid) is
  'Soft-deletes ONE pruning labour line (SQL 190). Mirrors soft_delete_work_task_labour_line: owner/manager/supervisor only, while operators may still add and edit lines through RLS. Idempotent — deleting an already-deleted line is a no-op, so an offline replay cannot fail.';

revoke all on function public.soft_delete_pruning_activity_labour_line(uuid) from public, anon;
grant execute on function public.soft_delete_pruning_activity_labour_line(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Roll-up helpers — hours and cost of an activity's OWN lines
-- ---------------------------------------------------------------------------
create or replace function public.pruning_activity_labour_line_hours(p_activity_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select sum(l.total_hours::numeric)
  from public.pruning_activity_labour_lines l
  where l.pruning_activity_id = p_activity_id
    and l.deleted_at is null;
$$;

comment on function public.pruning_activity_labour_line_hours(uuid) is
  'SUM of ACTIVE pruning labour line hours (SQL 190). Counts UNRATED lines too — an unpriced line is still work that was done, and hours drive vines-per-hour. NULL (never 0) when the activity owns no line.';

create or replace function public.pruning_activity_labour_line_cost(p_activity_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select sum(l.total_cost::numeric)
  from public.pruning_activity_labour_lines l
  where l.pruning_activity_id = p_activity_id
    and l.deleted_at is null
    -- Unrated lines are operational history, not a $0.00 cost (SQL 189 rule).
    and l.hourly_rate is not null;
$$;

comment on function public.pruning_activity_labour_line_cost(uuid) is
  'SUM of ACTIVE, RATED pruning labour line costs (SQL 190). NULL (never 0.00) when the activity owns no costed line. Never add this to a piece-rate total or to a linked task''s lines — use pruning_activity_effective_labour_cost to pick the ONE that applies.';

create or replace function public.pruning_activity_labour_line_count(p_activity_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.pruning_activity_labour_lines l
  where l.pruning_activity_id = p_activity_id
    and l.deleted_at is null;
$$;

comment on function public.pruning_activity_labour_line_count(uuid) is
  'Number of ACTIVE labour lines on a pruning activity (SQL 190). 0 means the activity is legacy/single-crew and resolves through the SQL 189 chain.';

-- ---------------------------------------------------------------------------
-- 5. Effective HOURS for an activity
-- ---------------------------------------------------------------------------
-- Lines when the activity owns any, the legacy scalar otherwise. An activity
-- with no lines therefore returns byte-for-byte what it returns today.
create or replace function public.pruning_activity_effective_labour_hours(p_activity_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
           public.pruning_activity_labour_line_hours(p_activity_id),
           (select a.labour_hours from public.pruning_activities a
             where a.id = p_activity_id)
         );
$$;

comment on function public.pruning_activity_effective_labour_hours(uuid) is
  'Total labour hours of a pruning activity (SQL 190): the sum of its own labour lines when it has any, otherwise the legacy pruning_activities.labour_hours. Precedence, never addition — the legacy scalar and the lines are two representations of the SAME hours.';

create or replace function public.pruning_activity_labour_hours_source(p_activity_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
           when public.pruning_activity_labour_line_hours(p_activity_id) is not null
             then 'labour_lines'
           when (select a.labour_hours from public.pruning_activities a
                  where a.id = p_activity_id) is not null
             then 'activity_hours'
         end;
$$;

comment on function public.pruning_activity_labour_hours_source(uuid) is
  'Labels the branch pruning_activity_effective_labour_hours took: labour_lines | activity_hours | NULL (SQL 190).';

-- ---------------------------------------------------------------------------
-- 6. pruning_activity_effective_labour_cost — SQL 189 chain + the new rung
-- ---------------------------------------------------------------------------
-- Replaced in place so every existing consumer picks the new rung up without
-- being touched. The only change is rung 2; rungs 1, 3 and 4 are the SQL 189
-- expressions verbatim, so an activity with no lines of its own is unaffected.
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
           -- 1. A linked piece-rate task IS the cost. No fallback: an unpriced
           --    piece-rate job is "not specified", and falling back to hours
           --    would report an HOURLY figure for a piece-rate job.
           when (select t.costing_method from public.work_tasks t
                  where t.id = a.work_task_id) = 'piece_rate' then
             (select t.piece_rate_total_cost from public.work_tasks t
               where t.id = a.work_task_id)
           else
             coalesce(
               -- 2. NEW: the activity's own rated labour lines.
               public.pruning_activity_labour_line_cost(a.id),
               -- 3. The linked hourly task's rated lines (SQL 189).
               case when a.work_task_id is not null
                    then public.work_task_labour_line_cost(a.work_task_id) end,
               -- 4. The legacy scalar pair (SQL 166), unchanged.
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
  'Effective labour cost of a pruning activity (SQL 189, extended by SQL 190). Precedence, never addition: linked piece-rate task -> its snapshot total; else the activity''s OWN rated labour lines; else the linked hourly task''s rated lines; else the legacy labour_hours x hourly_rate. Counted ONCE for the whole activity no matter how many blocks it covers. NULL means "not specified", never $0.00.';

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
           when (select t.costing_method from public.work_tasks t
                  where t.id = a.work_task_id) = 'piece_rate' then
             case when (select t.piece_rate_total_cost from public.work_tasks t
                         where t.id = a.work_task_id) is not null
                  then 'piece_rate' end
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
  'Labels the branch pruning_activity_effective_labour_cost took: piece_rate | pruning_labour_lines | labour_lines | activity_hours | NULL (SQL 190). pruning_labour_lines means the activity''s OWN lines; labour_lines means a linked work task''s. Never re-derive this in a consumer.';

-- ---------------------------------------------------------------------------
-- 7. Work task side — resolve THROUGH to the pruning activity's lines
-- ---------------------------------------------------------------------------
-- This is what stops the same money existing twice. A Work Task created from a
-- pruning activity does not receive a copy of the labour: when it holds no
-- rated line of its own it reports the activity's figure, so the Work Task
-- report and the Pruning report show the SAME number, sourced from the SAME
-- rows. Summing both modules therefore counts the job once.
--
-- Strictly a NULL-filling rung: pre-190 such a task returned NULL.
create or replace function public.work_task_pruning_labour_line_cost(p_work_task_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select sum(l.total_cost::numeric)
  from public.pruning_activities a
  join public.pruning_activity_labour_lines l
    on l.pruning_activity_id = a.id
  where a.work_task_id = p_work_task_id
    and a.deleted_at is null
    and l.deleted_at is null
    and l.hourly_rate is not null;
$$;

comment on function public.work_task_pruning_labour_line_cost(uuid) is
  'Rated labour-line total of the PRUNING ACTIVITY linked to this work task (SQL 190). Used only as a fallback so a pruning-linked task reports the activity''s labour instead of NULL. The rows live in exactly one place; this is a read-through, never a copy.';

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
           else coalesce(
             public.work_task_labour_line_cost(t.id),
             public.work_task_pruning_labour_line_cost(t.id)
           )
         end
  from public.work_tasks t
  where t.id = p_work_task_id;
$$;

comment on function public.work_task_effective_labour_cost(uuid) is
  'THE effective labour cost of a work task (SQL 189, extended by SQL 190). piece_rate -> piece_rate_total_cost; else its OWN rated labour lines; else, when the task is linked from a pruning activity, that activity''s rated labour lines (read-through, never a second copy). Never summed. NULL means "not specified", never $0.00.';

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
           when public.work_task_pruning_labour_line_cost(t.id) is not null
             then 'pruning_labour_lines'
           else null
         end
  from public.work_tasks t
  where t.id = p_work_task_id;
$$;

comment on function public.work_task_labour_cost_source(uuid) is
  'Labels the branch work_task_effective_labour_cost took: piece_rate | labour_lines | pruning_labour_lines | NULL (SQL 189, extended by SQL 190).';

revoke all on function public.pruning_activity_labour_line_hours(uuid) from public, anon;
revoke all on function public.pruning_activity_labour_line_cost(uuid) from public, anon;
revoke all on function public.pruning_activity_labour_line_count(uuid) from public, anon;
revoke all on function public.pruning_activity_effective_labour_hours(uuid) from public, anon;
revoke all on function public.pruning_activity_labour_hours_source(uuid) from public, anon;
revoke all on function public.work_task_pruning_labour_line_cost(uuid) from public, anon;

grant execute on function public.pruning_activity_labour_line_hours(uuid) to authenticated, service_role;
grant execute on function public.pruning_activity_labour_line_cost(uuid) to authenticated, service_role;
grant execute on function public.pruning_activity_labour_line_count(uuid) to authenticated, service_role;
grant execute on function public.pruning_activity_effective_labour_hours(uuid) to authenticated, service_role;
grant execute on function public.pruning_activity_labour_hours_source(uuid) to authenticated, service_role;
grant execute on function public.work_task_pruning_labour_line_cost(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. save_pruning_activity_labour_lines — desired-state, single transaction
-- ---------------------------------------------------------------------------
-- The same contract shape as update_pruning_activity (SQL 166): the client
-- sends the COMPLETE desired set for the activity, and the function upserts
-- what is present and soft-deletes what is absent. That is what makes an
-- offline replay deterministic — replaying the same payload twice produces the
-- same rows, and a queued edit made on a plane cannot resurrect a line that was
-- deleted on another device afterwards.
--
-- Returns the CANONICAL server state so the client can replace its local set
-- wholesale, exactly like the other pruning RPCs.
create or replace function public.save_pruning_activity_labour_lines(
  p_activity_id uuid,
  p_lines jsonb,
  p_client_updated_at timestamptz default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_act public.pruning_activities%rowtype;
  v_line jsonb;
  v_id uuid;
  v_kept uuid[] := array[]::uuid[];
  v_index integer := 0;
  v_now timestamptz := coalesce(p_client_updated_at, now());
  v_removed integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select * into v_act from public.pruning_activities where id = p_activity_id;
  if not found then
    raise exception 'Pruning activity not found';
  end if;
  if not public.has_vineyard_role(v_act.vineyard_id,
       array['owner','manager','supervisor','operator']) then
    raise exception 'Insufficient permissions to record pruning labour';
  end if;

  for v_line in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    -- A client id is the idempotency key; generate one only when the caller
    -- (the portal, typically) omits it.
    v_id := coalesce(nullif(v_line->>'id', '')::uuid, gen_random_uuid());

    insert into public.pruning_activity_labour_lines (
      id, pruning_activity_id, vineyard_id, work_date,
      worker_type_id, worker_type, worker_count, hours_per_worker,
      hourly_rate, notes, line_index,
      created_by, updated_by, client_updated_at
    ) values (
      v_id, p_activity_id, v_act.vineyard_id,
      coalesce(nullif(v_line->>'work_date', '')::date, v_act.entry_date),
      nullif(v_line->>'worker_type_id', '')::uuid,
      coalesce(v_line->>'worker_type', ''),
      coalesce(nullif(v_line->>'worker_count', '')::integer, 1),
      coalesce(nullif(v_line->>'hours_per_worker', '')::double precision, 0),
      nullif(v_line->>'hourly_rate', '')::double precision,
      coalesce(v_line->>'notes', ''),
      coalesce(nullif(v_line->>'line_index', '')::integer, v_index),
      auth.uid(), auth.uid(), v_now
    )
    on conflict (id) do update
      set work_date        = excluded.work_date,
          worker_type_id   = excluded.worker_type_id,
          worker_type      = excluded.worker_type,
          worker_count     = excluded.worker_count,
          hours_per_worker = excluded.hours_per_worker,
          hourly_rate      = excluded.hourly_rate,
          notes            = excluded.notes,
          line_index       = excluded.line_index,
          -- Re-sending a line that was soft-deleted restores it: the desired
          -- set is authoritative.
          deleted_at       = null,
          updated_by       = auth.uid(),
          updated_at       = now(),
          client_updated_at = excluded.client_updated_at,
          sync_version     = pruning_activity_labour_lines.sync_version + 1
      -- A client id already owned by ANOTHER activity is never re-parented.
      where pruning_activity_labour_lines.pruning_activity_id = p_activity_id;

    v_kept := array_append(v_kept, v_id);
    v_index := v_index + 1;
  end loop;

  -- Everything not in the desired set is reversed, never erased.
  update public.pruning_activity_labour_lines
     set deleted_at = now(), updated_by = auth.uid(), client_updated_at = v_now
   where pruning_activity_id = p_activity_id
     and deleted_at is null
     and not (id = any (v_kept));
  get diagnostics v_removed = row_count;

  return jsonb_build_object(
    'activity_id', p_activity_id,
    'saved', coalesce(jsonb_array_length(p_lines), 0),
    'removed', v_removed,
    'labour_lines', public.pruning_activity_labour_lines_json(p_activity_id),
    'total_labour_hours', public.pruning_activity_effective_labour_hours(p_activity_id),
    'labour_cost', public.pruning_activity_effective_labour_cost(p_activity_id),
    'labour_cost_source', public.pruning_activity_labour_cost_source(p_activity_id)
  );
end;
$$;

comment on function public.save_pruning_activity_labour_lines(uuid, jsonb, timestamptz) is
  'DESIRED-STATE save of ALL labour lines for one pruning activity (SQL 190), in a single transaction. Lines present are upserted on their CLIENT id, lines absent are soft-deleted, a re-sent soft-deleted line is restored. Replaying the same payload is therefore idempotent, which is what makes offline replay deterministic. Returns the canonical set plus the activity''s effective hours and cost.';

revoke all on function public.save_pruning_activity_labour_lines(uuid, jsonb, timestamptz) from public, anon;
grant execute on function public.save_pruning_activity_labour_lines(uuid, jsonb, timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. pruning_activity_labour_lines_json — the shared read shape
-- ---------------------------------------------------------------------------
-- One definition of the payload so the feed, the editor, the report and the
-- API cannot drift apart.
create or replace function public.pruning_activity_labour_lines_json(p_activity_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', l.id,
             'pruning_activity_id', l.pruning_activity_id,
             'vineyard_id', l.vineyard_id,
             'work_date', l.work_date,
             'worker_type_id', l.worker_type_id,
             'worker_type', l.worker_type,
             'worker_count', l.worker_count,
             'hours_per_worker', l.hours_per_worker,
             'hourly_rate', l.hourly_rate,
             'total_hours', l.total_hours,
             -- Reported as NULL, not 0.00, when the line carries no rate.
             'total_cost', case when l.hourly_rate is not null then l.total_cost end,
             'notes', l.notes,
             'line_index', l.line_index,
             'created_at', l.created_at,
             'updated_at', l.updated_at,
             'client_updated_at', l.client_updated_at,
             'sync_version', l.sync_version
           ) order by l.line_index, l.work_date, l.created_at
         ), '[]'::jsonb)
  from public.pruning_activity_labour_lines l
  where l.pruning_activity_id = p_activity_id
    and l.deleted_at is null;
$$;

comment on function public.pruning_activity_labour_lines_json(uuid) is
  'Canonical labour-line payload for a pruning activity (SQL 190). ACTIVE lines only, ordered by line_index. total_cost is NULL (not 0.00) on an unrated line, matching the costing rule.';

revoke all on function public.pruning_activity_labour_lines_json(uuid) from public, anon;
grant execute on function public.pruning_activity_labour_lines_json(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. pruning_activity_json — expose the lines and the effective hours
-- ---------------------------------------------------------------------------
-- Rebuilt from the SQL 189 definition. Changes, and ONLY these changes:
--   * `labour_lines` and `labour_line_count` are ADDED to the activity object,
--   * `total_labour_hours` + `labour_hours_source` are ADDED to both objects,
--   * `totals.labour_hours` now reports the EFFECTIVE hours (the lines when
--     the activity owns any, otherwise the same legacy scalar as before),
--   * `activity.labour_hours` / `activity.hourly_rate` remain AS RECORDED, so
--     an editor can still round-trip a legacy single-crew activity untouched.
-- Every other key, its name, its type and its value are unchanged.
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
      -- Legacy single-crew label. Still authoritative for an activity that
      -- owns no labour line, and never overwritten by one.
      'worker_or_crew', v_act.worker_or_crew,
      'method', v_act.pruning_method,
      'start_time', v_act.start_time,
      'finish_time', v_act.finish_time,
      'duration_hours', v_duration,
      -- AS RECORDED (unchanged), so a legacy activity round-trips exactly.
      'labour_hours', v_act.labour_hours,
      'hourly_rate', v_act.hourly_rate,
      -- SQL 190: the resolved figures and the lines behind them.
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
      -- Shared labour, counted ONCE for the whole activity. Now the SUM of the
      -- activity's labour lines when it owns any; identical to the pre-190
      -- value otherwise.
      'labour_hours', v_hours,
      'total_labour_hours', v_hours,
      'labour_hours_source', v_hours_source,
      'labour_line_count', v_line_count,
      'hourly_rate', v_act.hourly_rate,
      'labour_cost', v_cost,
      'labour_cost_source', v_source,
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
      -- Productivity on the resolved hours, so a multi-line activity reports a
      -- real vines-per-hour instead of dividing by one crew's hours.
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
  'Activity payload for the feed, report, editor and exports (SQL 166, extended by 168, 189 and 190). SQL 190 adds labour_lines / labour_line_count / total_labour_hours / labour_hours_source and makes totals.labour_hours the SUM of the activity''s labour lines when it owns any. activity.labour_hours and activity.hourly_rate remain AS RECORDED so a legacy single-crew activity round-trips unchanged. Labour is counted once per activity, never per block.';

-- ---------------------------------------------------------------------------
-- 11. Export view — effective hours and the same cost chain
-- ---------------------------------------------------------------------------
-- Rebuilt exactly as SQL 189 did (a positional `create or replace view` cannot
-- take new columns mid-list). ALL SQL 189 columns keep their names, positions
-- and semantics; `activity_labour_hours` now carries the EFFECTIVE hours, and
-- three columns are appended.
drop view if exists public.pruning_activity_allocation_export;

create view public.pruning_activity_allocation_export as
with lines as (
  select
    l.pruning_activity_id,
    sum(l.total_hours::numeric)                                     as line_hours,
    sum(l.total_cost::numeric) filter (where l.hourly_rate is not null) as line_cost,
    count(*)::integer                                               as line_count
  from public.pruning_activity_labour_lines l
  where l.deleted_at is null
  group by l.pruning_activity_id
),
alloc as (
  select
    a.id                              as activity_id,
    a.vineyard_id,
    a.entry_date                      as activity_date,
    a.worker_or_crew,
    a.pruning_method                  as method,
    a.block_summary,
    coalesce(ln.line_hours, a.labour_hours) as a_labour_hours,
    a.hourly_rate                     as a_hourly_rate,
    a.total_row_equivalents           as a_total_row_equivalents,
    a.work_task_id                    as a_work_task_id,
    a.deleted_at                      as a_deleted_at,
    a.created_by,
    a.created_at,
    a.updated_at,
    coalesce(ln.line_count, 0)        as a_labour_line_count,
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
    -- The SQL 190 chain, resolved once per activity.
    case
      when w.costing_method = 'piece_rate' then w.piece_rate_total_cost
      else coalesce(
        ln.line_cost,
        w.labour_line_cost,
        case when a.labour_hours is not null and a.hourly_rate is not null
             then round((a.labour_hours * a.hourly_rate)::numeric, 2) end
      )
    end                               as effective_labour_cost,
    case
      when w.costing_method = 'piece_rate' then
        case when w.piece_rate_total_cost is not null then 'piece_rate' end
      when ln.line_cost is not null then 'pruning_labour_lines'
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
  left join lines ln on ln.pruning_activity_id = a.id
),
shared as (
  select
    alloc.*,
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
  -- SQL 190: the EFFECTIVE hours (labour lines when the activity owns any),
  -- still on the PRIMARY allocation row only so a CSV sum counts them once.
  case when shared.is_skipped then null when shared.is_primary
    then shared.a_labour_hours end    as activity_labour_hours,
  case when shared.is_skipped then null when shared.is_primary
    then shared.a_hourly_rate end     as activity_hourly_rate,
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
  shared.updated_at,
  -- Appended by SQL 190.
  case when shared.is_skipped then null when shared.is_primary
    then shared.a_labour_line_count end as activity_labour_line_count,
  shared.a_labour_line_count          as labour_line_count,
  case when shared.is_primary then true else false end as is_primary_allocation
from shared;

comment on view public.pruning_activity_allocation_export is
  'Allocation breakdown for reports/exports (SQL 166, extended by 168, 189 and 190). activity_labour_* appear on the PRIMARY allocation row only, and never on a skipped allocation, so totals never double-count shared labour. SQL 190: activity_labour_hours is the SUM of the activity''s labour lines when it owns any (the legacy scalar otherwise), activity_labour_cost follows the same precedence chain, and activity_labour_cost_source adds pruning_labour_lines. allocation_share_labour_cost still splits the ONE figure by row-equivalent share with the residual on the primary row, so it reconciles exactly.';

alter view public.pruning_activity_allocation_export set (security_invoker = true);
grant select on public.pruning_activity_allocation_export to authenticated;

-- ---------------------------------------------------------------------------
-- 12. v_work_task_effective_labour_cost — the read-through, set-based
-- ---------------------------------------------------------------------------
-- Mirrors section 7 so the join form and the scalar form can never disagree.
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
    else coalesce(l.labour_line_cost, pl.pruning_line_cost)
  end                                 as effective_labour_cost,
  case
    when t.costing_method = 'piece_rate' then 'piece_rate'
    when l.labour_line_cost is not null then 'labour_lines'
    when pl.pruning_line_cost is not null then 'pruning_labour_lines'
    else null
  end                                 as labour_cost_source,
  case
    when t.costing_method = 'piece_rate' then t.piece_rate_per_vine
  end                                 as cost_per_vine,
  pl.pruning_line_cost
from public.work_tasks t
left join lateral (
  select sum(x.total_cost::numeric) as labour_line_cost
  from public.work_task_labour_lines x
  where x.work_task_id = t.id
    and x.deleted_at is null
    and x.hourly_rate is not null
) l on true
left join lateral (
  select sum(y.total_cost::numeric) as pruning_line_cost
  from public.pruning_activities a
  join public.pruning_activity_labour_lines y on y.pruning_activity_id = a.id
  where a.work_task_id = t.id
    and a.deleted_at is null
    and y.deleted_at is null
    and y.hourly_rate is not null
) pl on true;

alter view public.v_work_task_effective_labour_cost set (security_invoker = true);
grant select on public.v_work_task_effective_labour_cost to authenticated;

comment on view public.v_work_task_effective_labour_cost is
  'Set-based form of work_task_effective_labour_cost (SQL 189, extended by SQL 190). effective_labour_cost is the piece-rate snapshot total, else the task''s own rated labour lines, else the rated labour lines of the pruning activity linked to it — a READ-THROUGH so the same money is never stored or counted twice. labour_line_cost and pruning_line_cost are exposed alongside for audit only and must never be added together.';

commit;

-- =============================================================================
-- END 190
--
-- Manual actions after applying:
--   * run sql/tests/190_pruning_activity_labour_lines_tests.sql
--   * redeploy supabase/functions/vinetrack-api so the Integration Read API
--     exposes pruning labour_lines / total_labour_hours
--   * Lovable/portal: CONSUME this contract only. Read labour_lines,
--     total_labour_hours, labour_cost and labour_cost_source from
--     pruning_activity_json; write through save_pruning_activity_labour_lines.
--     Do NOT create a parallel pruning labour table, do NOT copy pruning labour
--     into work_task_labour_lines, and do NOT add a task's labour to an
--     activity's.
-- =============================================================================

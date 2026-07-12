-- =====================================================================
-- Work Task data-flow inspection (read-only, safe to run in SQL editor)
-- =====================================================================
-- HOW TO USE:
--   1. Replace :task_id below with the id of the portal-created task
--      (find it in step 0 if you don't know it).
--   2. Run each numbered block and compare against the expectations
--      in the comments.
--
-- Tables involved (canonical schema, post sql/106 rename):
--   work_tasks                 parent row (header only — no cost columns)
--   work_task_labour_lines     labour allocations (worker_type_id,
--                              worker_type, worker_count, hours_per_worker,
--                              hourly_rate; total_hours + total_cost are
--                              DB-GENERATED columns)
--   work_task_machine_lines    equipment allocations (equipment_source,
--                              equipment_ref_id, equipment_name_snapshot,
--                              duration_hours, hourly_machine_rate,
--                              fuel_cost, total_machine_cost)
--   work_task_paddocks         block joins
--   worker_types               rate catalog (name, cost_per_hour)
-- =====================================================================

-- 0. Most recent tasks — find the affected one.
select id, vineyard_id, task_type, date, duration_hours, status,
       start_date, end_date, resources, created_by, created_at
from public.work_tasks
order by created_at desc
limit 10;

-- 1. Parent row for the affected task.
--    EXPECT: header fields set. NOTE: work_tasks has NO planned-cost or
--    planned-hours-total column — totals only come from the line tables.
--    `resources` is a legacy iOS-only JSONB (camelCase keys:
--    id/operatorCategoryId/workerTypeName/hourlyRate/count). The portal
--    should normally leave it NULL.
select *
from public.work_tasks
where id = ':task_id';

-- 2. Labour allocations for the task (INCLUDING soft-deleted).
--    EXPECT: one row per planned labour resource with worker_type_id set,
--    numeric worker_count / hours_per_worker / hourly_rate, and
--    DB-generated total_hours / total_cost.
--    If ZERO rows: the portal never persisted the labour allocations —
--    the data is missing FROM THE DATABASE, not from the apps.
select id, work_task_id, vineyard_id, work_date,
       worker_type_id, worker_type, worker_count, hours_per_worker,
       hourly_rate, total_hours, total_cost, notes,
       created_by, created_at, deleted_at
from public.work_task_labour_lines
where work_task_id = ':task_id';

-- 3. Equipment allocations for the task (INCLUDING soft-deleted).
select id, work_task_id, vineyard_id, work_date,
       equipment_source, equipment_ref_id, equipment_name_snapshot,
       operator_user_id, worker_type_id, duration_hours,
       hourly_machine_rate, fuel_litres, fuel_cost, total_machine_cost,
       entry_source, created_by, created_at, deleted_at
from public.work_task_machine_lines
where work_task_id = ':task_id';

-- 4. Block joins for the task.
select * from public.work_task_paddocks
where work_task_id = ':task_id';

-- 5. FK validity: do the labour lines' worker_type_id values resolve?
select l.id as labour_line_id, l.worker_type_id,
       wt.id is not null as worker_type_exists,
       wt.name as worker_type_name, wt.cost_per_hour as current_rate,
       l.hourly_rate as snapshot_rate_on_line
from public.work_task_labour_lines l
left join public.worker_types wt on wt.id = l.worker_type_id
where l.work_task_id = ':task_id';

-- 6. CRITICAL: does the portal write to tables the apps don't read?
--    Lists EVERY column in the database named like a work-task FK.
--    EXPECT only: work_task_labour_lines, work_task_machine_lines,
--    work_task_paddocks, trips (work_task_id). Any OTHER table here
--    (e.g. a Lovable-created "work_task_resources") is the smoking gun —
--    the portal is saving allocations somewhere the mobile apps never
--    query.
select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and column_name in ('work_task_id', 'task_id')
order by table_name;

-- 7. Vineyard ownership + membership sanity for the task's vineyard.
--    EXPECT: the mobile user appears with a role in
--    ('owner','manager','supervisor','operator','viewer').
select vm.user_id, vm.role, vm.worker_type_id
from public.vineyard_members vm
where vm.vineyard_id = (select vineyard_id from public.work_tasks where id = ':task_id');

-- 8. RLS policies actually active on the involved tables.
--    EXPECT SELECT policies USING is_vineyard_member(vineyard_id) on all
--    three line/parent tables (they exist in the repo migrations; this
--    confirms they are live).
select tablename, policyname, cmd, qual
from pg_policies
where schemaname = 'public'
  and tablename in ('work_tasks', 'work_task_labour_lines',
                    'work_task_machine_lines', 'work_task_paddocks',
                    'worker_types')
order by tablename, cmd;

-- 9. Legacy-column check: since sql/106 the line tables have
--    worker_type_id and NO operator_category_id. If the portal still
--    inserts operator_category_id, PostgREST returns
--    400 "column ... does not exist" and the allocation insert fails.
--    EXPECT: only worker_type_id listed below.
select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and table_name in ('work_task_labour_lines', 'work_task_machine_lines')
  and column_name in ('worker_type_id', 'operator_category_id')
order by table_name, column_name;

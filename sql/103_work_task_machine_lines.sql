-- Phase: Work Tasks / Trips / Manual Machine Work — Step 1C (additive).
--
-- Adds public.work_task_machine_lines: a sibling of work_task_labour_lines
-- that records machine/tractor/equipment work entered manually when:
--   * no GPS trip exists,
--   * trip tracking was missed,
--   * trip tracking failed,
--   * or the user needs a correction / manual machine entry.
--
-- Design goals:
--   * Strictly additive — no existing column, table or RLS behaviour changes.
--   * Mirrors work_task_labour_lines (sql/050): vineyard-membership RLS,
--     soft-delete via SECURITY DEFINER RPC, sync_version + client_updated_at.
--   * Equipment identity reuses the migration-safe maintenance_logs pattern
--     (sql/100): generic equipment_source + equipment_ref_id +
--     equipment_name_snapshot. No separate machine_id / tractor_id columns.
--   * No backfill. No changes to trip_cost_allocations, work_task_labour_lines,
--     work_task_paddocks, trips, or any costing/reporting logic.

-- =====================================================================
-- work_task_machine_lines
-- =====================================================================
create table if not exists public.work_task_machine_lines (
  id uuid primary key default gen_random_uuid(),
  work_task_id uuid not null references public.work_tasks(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  work_date date not null,

  -- Equipment identity (migration-safe pattern, matches maintenance_logs).
  equipment_source text null,
  equipment_ref_id uuid null,
  equipment_name_snapshot text not null default '',

  -- Operator.
  operator_user_id uuid null references auth.users(id),
  operator_category_id uuid null,

  -- Time / engine hours.
  duration_hours double precision null,
  start_time timestamptz null,
  end_time timestamptz null,
  start_engine_hours double precision null,
  end_engine_hours double precision null,
  engine_hours_used double precision null,

  -- Fuel / cost.
  fuel_litres double precision null,
  fuel_cost double precision null,
  hourly_machine_rate double precision null,
  total_machine_cost double precision null,

  -- Entry provenance.
  entry_source text not null default 'manual',

  notes text not null default '',

  -- Audit / sync (mirrors work_task_labour_lines).
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

comment on column public.work_task_machine_lines.equipment_source is
  'Which catalog table equipment_ref_id points at: vineyard_machine | tractor | spray_equipment | equipment_item | free_text. NULL when unset.';
comment on column public.work_task_machine_lines.equipment_ref_id is
  'Optional id of the linked equipment row in the table named by equipment_source. NULL for free_text or unlinked rows.';
comment on column public.work_task_machine_lines.equipment_name_snapshot is
  'Display snapshot of the equipment name at entry time; authoritative when no stable link resolves.';
comment on column public.work_task_machine_lines.entry_source is
  'Why this manual machine line exists: manual | missed_trip | trip_failed | correction.';

-- Allowed equipment_source values (NULL permitted).
alter table public.work_task_machine_lines
  drop constraint if exists work_task_machine_lines_equipment_source_check;
alter table public.work_task_machine_lines
  add constraint work_task_machine_lines_equipment_source_check
  check (
    equipment_source is null
    or equipment_source in (
      'vineyard_machine', 'tractor', 'spray_equipment', 'equipment_item', 'free_text'
    )
  );

-- Allowed entry_source values.
alter table public.work_task_machine_lines
  drop constraint if exists work_task_machine_lines_entry_source_check;
alter table public.work_task_machine_lines
  add constraint work_task_machine_lines_entry_source_check
  check (entry_source in ('manual', 'missed_trip', 'trip_failed', 'correction'));

create index if not exists idx_work_task_machine_lines_work_task_id
  on public.work_task_machine_lines (work_task_id);
create index if not exists idx_work_task_machine_lines_vineyard_work_date
  on public.work_task_machine_lines (vineyard_id, work_date);
create index if not exists idx_work_task_machine_lines_vineyard_id
  on public.work_task_machine_lines (vineyard_id);
create index if not exists idx_work_task_machine_lines_updated_at
  on public.work_task_machine_lines (updated_at);
create index if not exists idx_work_task_machine_lines_deleted_at
  on public.work_task_machine_lines (deleted_at);
create index if not exists idx_work_task_machine_lines_equipment_ref
  on public.work_task_machine_lines (equipment_source, equipment_ref_id);

create or replace trigger work_task_machine_lines_set_updated_at
before update on public.work_task_machine_lines
for each row execute function public.set_updated_at();

alter table public.work_task_machine_lines enable row level security;

drop policy if exists "work_task_machine_lines_select_members"
  on public.work_task_machine_lines;
create policy "work_task_machine_lines_select_members"
on public.work_task_machine_lines for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "work_task_machine_lines_insert_members"
  on public.work_task_machine_lines;
create policy "work_task_machine_lines_insert_members"
on public.work_task_machine_lines for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "work_task_machine_lines_update_members"
  on public.work_task_machine_lines;
create policy "work_task_machine_lines_update_members"
on public.work_task_machine_lines for update
to authenticated
using (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "work_task_machine_lines_no_client_hard_delete"
  on public.work_task_machine_lines;
create policy "work_task_machine_lines_no_client_hard_delete"
on public.work_task_machine_lines for delete
to authenticated
using (false);

-- =====================================================================
-- soft_delete_work_task_machine_line
-- =====================================================================
-- Mirrors soft_delete_work_task_labour_line: only owner/manager/supervisor
-- may soft-delete a machine line. Operators may insert/update via RLS.
create or replace function public.soft_delete_work_task_machine_line(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id
    from public.work_task_machine_lines where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Work task machine line not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id,
       array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete work task machine line';
  end if;
  update public.work_task_machine_lines
     set deleted_at = now(), updated_by = auth.uid()
   where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_work_task_machine_line(uuid) from public;
grant execute on function public.soft_delete_work_task_machine_line(uuid)
  to authenticated;

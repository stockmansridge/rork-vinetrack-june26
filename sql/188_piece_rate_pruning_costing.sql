-- =============================================================================
-- 188: Piece Rate pruning costing + per-row manual vine-count override.
--
-- Rork/VineTrack mobile is the SOURCE OF TRUTH for this contract. Lovable (the
-- web portal) CONSUMES it and MUST NOT independently create or modify any of
-- these fields, tables or rules.
--
-- WHY
-- Pruning is commonly contracted at an agreed price PER VINE, not per hour.
-- Today the only labour costing VineTrack can express is
-- `work_task_labour_lines` (SQL 050): worker_count x hours_per_worker x
-- hourly_rate. A grower who agrees "$1.27 a vine" has to reverse-engineer an
-- hourly rate, which is neither what was agreed nor what gets invoiced.
--
-- This migration adds Piece Rate as an ALTERNATE costing method on the EXISTING
-- work task. It is strictly additive:
--   * no column or table is dropped or renamed,
--   * no existing RLS policy is changed,
--   * no existing generated column or constraint is altered,
--   * every existing record keeps behaving exactly as an hourly job,
--   * older mobile builds that know nothing about these columns keep working.
--
-- ---------------------------------------------------------------------------
-- CONFLICT FOUND DURING THE AUDIT, AND HOW IT IS RESOLVED
-- ---------------------------------------------------------------------------
-- `work_task_labour_lines.total_cost` (SQL 050) is a STORED GENERATED column:
--
--     total_cost = worker_count * hours_per_worker * hourly_rate
--
-- It is therefore structurally incapable of expressing a piece-rate cost, and
-- it cannot be redefined without dropping it — which would break the
-- Integration Read API (`vinetrack-api`), the External Write API (SQL 186), the
-- portal and both mobile clients, all of which read it today.
--
-- We do NOT hack around it. The smallest safe additive change is used instead:
--
--   * `work_task_labour_lines` is left COMPLETELY UNTOUCHED. For a piece-rate
--     job its lines still record hours (operational history — see PART 4 of the
--     product spec) and its generated `total_cost` still reports the hourly
--     arithmetic. That value is simply NOT the job's labour cost when the task
--     is costed by piece rate.
--   * The piece-rate agreement and its own generated total live on the PARENT
--     `work_tasks` row, where "one job, one commercial agreement" belongs.
--   * `work_tasks.costing_method` is the SINGLE switch that says which of the
--     two totals is the task's labour cost. There is exactly ONE labour cost
--     for a task at any time; the other number is never added to it.
--
-- Reading rule for EVERY consumer (mobile, portal, API, reports):
--
--     costing_method = 'hourly'      -> labour cost = SUM(work_task_labour_lines.total_cost)
--     costing_method = 'piece_rate'  -> labour cost = work_tasks.piece_rate_total_cost
--
-- Never sum the two. Never infer piece rate from the mere presence of a rate.
--
-- ---------------------------------------------------------------------------
-- HISTORICAL PROTECTION
-- ---------------------------------------------------------------------------
-- A piece-rate job must keep the commercial calculation it was created with. If
-- someone edits a row's vine count six months later, a completed job must NOT
-- silently re-cost. So the vine QUANTITY is snapshotted onto the task at
-- creation/update time (`piece_vine_count`), and the per-row detail behind that
-- quantity is snapshotted into `work_task_piece_rate_rows`.
--
-- `piece_rate_total_cost` is generated from the SNAPSHOT columns only. It never
-- reads `paddocks.rows`, so no vineyard-setup edit can ever change a historical
-- job's value.
--
-- ---------------------------------------------------------------------------
-- PER-ROW MANUAL VINE COUNT (`paddocks.rows[].vineCountOverride`)
-- ---------------------------------------------------------------------------
-- `paddocks.rows` is a JSONB array, so this needs NO schema change — the new
-- OPTIONAL property is documented here and in
-- `docs/paddock-rows-json-contract.md` so the portal implements the identical
-- shape. Canonical element:
--
--     {
--       "id": "uuid",                  -- stable row identity
--       "number": 12,                  -- real-world row number
--       "startPoint": { "latitude": .., "longitude": .. },
--       "endPoint":   { "latitude": .., "longitude": .. },
--       "vineCountOverride": 182       -- OPTIONAL. Absent = use calculated.
--     }
--
-- Rules (identical on iOS, Android and the portal):
--   * OPTIONAL. Existing rows without the key stay valid and unchanged.
--   * Whole positive integer, or absent. Never 0, never negative, never
--     fractional, never null-as-a-value (omit the key instead).
--   * effectiveVineCount(row) = vineCountOverride ?? round(rowLength / vineSpacing)
--   * It is NEVER stored as a computed/derived value; only the manual number is
--     persisted. The effective value is always derived at read time.
--
-- INTERACTION WITH THE EXISTING BLOCK-LEVEL `paddocks.vine_count_override`:
--   The two are INDEPENDENT and both are preserved.
--   * `paddocks.vine_count_override` (existing, unchanged) is the BLOCK total
--     used by water, spray, fertiliser and yield estimates. It is not derived
--     from rows and does not write to them.
--   * `rows[].vineCountOverride` (new) is per-ROW truth used by row-driven
--     work — specifically the pruning piece-rate quantity.
--   * Neither overwrites the other. Where a block total is needed from rows,
--     use SUM(effectiveVineCount(row)).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. work_tasks: costing method + piece-rate agreement snapshot
-- ---------------------------------------------------------------------------
alter table public.work_tasks
  add column if not exists costing_method text not null default 'hourly',
  -- Agreed price per vine. NUMERIC (never float) so money never drifts.
  add column if not exists piece_rate_per_vine numeric(12, 4) null,
  -- HISTORICAL SNAPSHOT of the vine quantity the job was costed on.
  add column if not exists piece_vine_count integer null;

-- Existing rows already default to 'hourly' via the column default; this is a
-- belt-and-braces no-op for any row inserted between statements.
update public.work_tasks
   set costing_method = 'hourly'
 where costing_method is null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'work_tasks_costing_method_check'
  ) then
    alter table public.work_tasks
      add constraint work_tasks_costing_method_check
      check (costing_method in ('hourly', 'piece_rate'));
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'work_tasks_piece_rate_per_vine_check'
  ) then
    alter table public.work_tasks
      add constraint work_tasks_piece_rate_per_vine_check
      check (piece_rate_per_vine is null or piece_rate_per_vine >= 0);
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'work_tasks_piece_vine_count_check'
  ) then
    alter table public.work_tasks
      add constraint work_tasks_piece_vine_count_check
      check (piece_vine_count is null or piece_vine_count >= 0);
  end if;
end $$;

-- THE piece-rate labour cost. Generated from the SNAPSHOT columns only, so it
-- can never be re-derived from today's vineyard setup. NUMERIC end to end.
alter table public.work_tasks
  add column if not exists piece_rate_total_cost numeric(14, 2)
    generated always as (
      case
        when costing_method = 'piece_rate'
             and piece_vine_count is not null
             and piece_rate_per_vine is not null
        then round(piece_vine_count::numeric * piece_rate_per_vine, 2)
        else null
      end
    ) stored;

create index if not exists idx_work_tasks_costing_method
  on public.work_tasks (costing_method);

comment on column public.work_tasks.costing_method is
  'How this task''s labour cost is calculated: ''hourly'' (SUM of work_task_labour_lines.total_cost, the pre-existing behaviour and the default for every legacy row) or ''piece_rate'' (work_tasks.piece_rate_total_cost). Exactly one applies; the two are NEVER summed. Never infer piece rate from the presence of a rate — this column is the only switch (SQL 188).';
comment on column public.work_tasks.piece_rate_per_vine is
  'Agreed piece rate in dollars per vine, e.g. 1.2700. NUMERIC so money never rounds through binary floating point. Historical: never rewritten by later vineyard edits (SQL 188).';
comment on column public.work_tasks.piece_vine_count is
  'HISTORICAL SNAPSHOT of the vine quantity this job was costed on, taken from the selected rows'' effectiveVineCount when the job was created/updated. Editing paddocks.rows later MUST NOT change it (SQL 188).';
comment on column public.work_tasks.piece_rate_total_cost is
  'Generated: round(piece_vine_count * piece_rate_per_vine, 2) when costing_method = ''piece_rate'', else NULL. Derived from the snapshot columns ONLY — never from live paddocks.rows (SQL 188).';

-- ---------------------------------------------------------------------------
-- 2. work_task_piece_rate_rows — the per-row historical quantity snapshot
-- ---------------------------------------------------------------------------
-- This is NOT a second row-selection system. Row SELECTION for pruning stays
-- exactly where it is (`pruning_row_segments`, SQL 112, quarter-level and
-- season-scoped). That structure records WHICH quarters were worked; it is
-- mutable progress data and carries no commercial quantity, so it cannot be
-- used as a price-protecting snapshot.
--
-- This table is a WRITE-ONCE COMMERCIAL RECORD: the rows, and the vine counts
-- for those rows, that the agreed job value was calculated from. Clients derive
-- it FROM the existing selection; they never ask the user to select rows again.
--
-- Mirrors work_task_paddocks (SQL 051) exactly for RLS, soft delete and sync.
create table if not exists public.work_task_piece_rate_rows (
  id uuid primary key default gen_random_uuid(),
  work_task_id uuid not null references public.work_tasks(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  paddock_id uuid not null references public.paddocks(id) on delete cascade,
  -- Logical reference into the paddocks.rows JSONB array (no FK target exists),
  -- matching the pruning_row_segments.paddock_row_id pattern from SQL 112.
  paddock_row_id uuid null,
  -- Display snapshot of the row number AT THE TIME OF COSTING.
  row_number integer null,
  -- THE snapshotted quantity for this row. This is the number that was paid on.
  vine_count integer not null default 0,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1,
  constraint work_task_piece_rate_rows_vine_count_check
    check (vine_count >= 0)
);

-- One active snapshot per (task, block, row). Soft-deleted rows are excluded so
-- a row can be removed and re-added while the job is still being edited.
create unique index if not exists uq_work_task_piece_rate_rows_active
  on public.work_task_piece_rate_rows (work_task_id, paddock_id, paddock_row_id)
  where deleted_at is null and paddock_row_id is not null;

-- Manual/fallback rows carry no stable row id; key those on the row number.
create unique index if not exists uq_work_task_piece_rate_rows_active_number
  on public.work_task_piece_rate_rows (work_task_id, paddock_id, row_number)
  where deleted_at is null and paddock_row_id is null;

create index if not exists idx_work_task_piece_rate_rows_work_task_id
  on public.work_task_piece_rate_rows (work_task_id);
create index if not exists idx_work_task_piece_rate_rows_vineyard_id
  on public.work_task_piece_rate_rows (vineyard_id);
create index if not exists idx_work_task_piece_rate_rows_paddock_id
  on public.work_task_piece_rate_rows (paddock_id);
create index if not exists idx_work_task_piece_rate_rows_updated_at
  on public.work_task_piece_rate_rows (updated_at);
create index if not exists idx_work_task_piece_rate_rows_deleted_at
  on public.work_task_piece_rate_rows (deleted_at);

create or replace trigger work_task_piece_rate_rows_set_updated_at
before update on public.work_task_piece_rate_rows
for each row execute function public.set_updated_at();

alter table public.work_task_piece_rate_rows enable row level security;

drop policy if exists "work_task_piece_rate_rows_select_members"
  on public.work_task_piece_rate_rows;
create policy "work_task_piece_rate_rows_select_members"
on public.work_task_piece_rate_rows for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "work_task_piece_rate_rows_insert_members"
  on public.work_task_piece_rate_rows;
create policy "work_task_piece_rate_rows_insert_members"
on public.work_task_piece_rate_rows for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "work_task_piece_rate_rows_update_members"
  on public.work_task_piece_rate_rows;
create policy "work_task_piece_rate_rows_update_members"
on public.work_task_piece_rate_rows for update
to authenticated
using (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id,
  array['owner','manager','supervisor','operator']));

drop policy if exists "work_task_piece_rate_rows_no_client_hard_delete"
  on public.work_task_piece_rate_rows;
create policy "work_task_piece_rate_rows_no_client_hard_delete"
on public.work_task_piece_rate_rows for delete
to authenticated
using (false);

comment on table public.work_task_piece_rate_rows is
  'HISTORICAL per-row vine-count snapshot behind a piece-rate work task (SQL 188). Not a row-selection system: selection stays in pruning_row_segments (SQL 112). These rows record the quantity the agreed job value was calculated from and MUST NOT be recalculated from paddocks.rows afterwards.';
comment on column public.work_task_piece_rate_rows.paddock_row_id is
  'Logical reference to the paddocks.rows[].id JSONB element. NULL for manual/fallback rows that have no mapped geometry (same pattern as pruning_row_segments.paddock_row_id).';
comment on column public.work_task_piece_rate_rows.vine_count is
  'Snapshotted effectiveVineCount for this row at costing time (rows[].vineCountOverride when set, otherwise the calculated estimate). Frozen history.';

-- ---------------------------------------------------------------------------
-- 3. soft_delete_work_task_piece_rate_row
-- ---------------------------------------------------------------------------
-- Mirrors soft_delete_work_task_paddock (SQL 051) exactly.
create or replace function public.soft_delete_work_task_piece_rate_row(p_id uuid)
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
    from public.work_task_piece_rate_rows where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Work task piece rate row not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id,
       array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete work task piece rate row';
  end if;
  update public.work_task_piece_rate_rows
     set deleted_at = now(), updated_by = auth.uid()
   where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_work_task_piece_rate_row(uuid) from public;
grant execute on function public.soft_delete_work_task_piece_rate_row(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Documentation-only comment for the paddocks.rows contract
-- ---------------------------------------------------------------------------
comment on column public.paddocks.rows is
  'JSONB array of vineyard rows. Canonical element: { id (uuid, stable identity), number (int, real-world row number), startPoint { latitude, longitude }, endPoint { latitude, longitude }, vineCountOverride (OPTIONAL positive integer, SQL 188) }. vineCountOverride is a MANUAL per-row vine count that supersedes the calculated rowLength / vineSpacing estimate; absent means use the calculated value. It is independent of the block-level paddocks.vine_count_override, which remains the block total for water/spray/fertiliser/yield estimates. Row identity MUST be preserved across geometry regeneration so overrides and pruning progress survive block edits.';

-- =============================================================================
-- END 188
--
-- Manual actions after applying:
--   * run sql/tests/188_piece_rate_pruning_costing_tests.sql
--   * Lovable/portal: CONSUME this contract only. Do not create or alter these
--     columns, tables, constraints or RPCs from the portal side.
-- =============================================================================

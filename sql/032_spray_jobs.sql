-- 032_spray_jobs.sql
-- Phase 1: Planned spray jobs + reusable spray templates.
--
-- Architecture:
--   * spray_records  = ACTUAL completed field/compliance records, written by
--                      the iOS app. Untouched by this migration.
--                      NOTE: spray_records.is_template is DEPRECATED for the
--                      new planned/template model. New code MUST use
--                      spray_jobs.is_template instead. The existing column
--                      is left in place to avoid breaking iOS sync.
--   * spray_jobs     = PLANNED spray work AND reusable templates (this file).
--                      is_template = true  -> reusable template
--                      is_template = false -> planned/in-progress/completed job
--
-- A nullable spray_records.spray_job_id link is added in 033 so that an
-- actual spray record can later reference the planned job it fulfilled.
--
-- Source priority and rainfall logic are unrelated and unchanged.

-- =====================================================================
-- spray_jobs
-- =====================================================================
create table if not exists public.spray_jobs (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,

  name text not null default '',
  is_template boolean not null default false,

  planned_date date null,
  status text not null default 'draft',

  -- Phase 1: chemical lines stored as JSONB. Suggested per-line shape:
  --   {
  --     "chemical_id": "optional uuid (saved_chemicals.id)",
  --     "name": "Product name",
  --     "active_ingredient": "optional",
  --     "rate": 1.2,
  --     "unit": "L/ha",
  --     "water_rate": 500,
  --     "notes": ""
  --   }
  chemical_lines jsonb null,

  water_volume numeric null,
  spray_rate_per_ha numeric null,

  operation_type text null,
  target text null,

  equipment_id uuid null references public.spray_equipment(id) on delete set null,
  tractor_id uuid null references public.tractors(id) on delete set null,
  operator_user_id uuid null references auth.users(id) on delete set null,

  notes text null,

  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,

  constraint spray_jobs_status_check check (status in (
    'draft','planned','in_progress','completed','cancelled','archived'
  )),
  constraint spray_jobs_chemical_lines_is_array check (
    chemical_lines is null or jsonb_typeof(chemical_lines) = 'array'
  )
);

create index if not exists idx_spray_jobs_vineyard_id on public.spray_jobs (vineyard_id);
create index if not exists idx_spray_jobs_is_template on public.spray_jobs (is_template);
create index if not exists idx_spray_jobs_status on public.spray_jobs (status);
create index if not exists idx_spray_jobs_planned_date on public.spray_jobs (planned_date);
create index if not exists idx_spray_jobs_updated_at on public.spray_jobs (updated_at);
create index if not exists idx_spray_jobs_deleted_at on public.spray_jobs (deleted_at);
create index if not exists idx_spray_jobs_equipment_id on public.spray_jobs (equipment_id);
create index if not exists idx_spray_jobs_tractor_id on public.spray_jobs (tractor_id);
create index if not exists idx_spray_jobs_operator_user_id on public.spray_jobs (operator_user_id);

create or replace trigger spray_jobs_set_updated_at
before update on public.spray_jobs
for each row execute function public.set_updated_at();

comment on table public.spray_jobs is
  'Planned spray work and reusable spray templates. is_template=true => '
  'template, is_template=false => planned/in-progress/completed job. '
  'Actual completed field/compliance records still live in spray_records.';
comment on column public.spray_jobs.is_template is
  'true = reusable template; false = planned spray job.';
comment on column public.spray_jobs.status is
  'draft | planned | in_progress | completed | cancelled | archived';
comment on column public.spray_jobs.chemical_lines is
  'Phase 1 JSONB array. Each line may include optional chemical_id '
  '(saved_chemicals.id), name, active_ingredient, rate, unit, water_rate, notes.';

-- =====================================================================
-- spray_job_paddocks (join table)
-- =====================================================================
create table if not exists public.spray_job_paddocks (
  spray_job_id uuid not null references public.spray_jobs(id) on delete cascade,
  paddock_id uuid not null references public.paddocks(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (spray_job_id, paddock_id)
);

create index if not exists idx_spray_job_paddocks_paddock_id on public.spray_job_paddocks (paddock_id);

comment on table public.spray_job_paddocks is
  'Join table linking spray_jobs to paddocks. Both rows must belong to '
  'the same vineyard (enforced by trigger).';

-- =====================================================================
-- Cross-vineyard integrity trigger for spray_jobs
-- Ensures equipment_id, tractor_id, operator_user_id all belong to the
-- same vineyard as the parent spray_job.
-- =====================================================================
create or replace function public.spray_jobs_validate_refs()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_other_vineyard uuid;
begin
  if new.equipment_id is not null then
    select vineyard_id into v_other_vineyard
    from public.spray_equipment
    where id = new.equipment_id;
    if v_other_vineyard is null then
      raise exception 'spray_jobs.equipment_id % not found', new.equipment_id;
    end if;
    if v_other_vineyard <> new.vineyard_id then
      raise exception 'spray_jobs.equipment_id % belongs to a different vineyard', new.equipment_id;
    end if;
  end if;

  if new.tractor_id is not null then
    select vineyard_id into v_other_vineyard
    from public.tractors
    where id = new.tractor_id;
    if v_other_vineyard is null then
      raise exception 'spray_jobs.tractor_id % not found', new.tractor_id;
    end if;
    if v_other_vineyard <> new.vineyard_id then
      raise exception 'spray_jobs.tractor_id % belongs to a different vineyard', new.tractor_id;
    end if;
  end if;

  if new.operator_user_id is not null then
    if not exists (
      select 1
      from public.vineyard_members
      where vineyard_id = new.vineyard_id
        and user_id = new.operator_user_id
    ) then
      raise exception 'spray_jobs.operator_user_id % is not a member of vineyard %',
        new.operator_user_id, new.vineyard_id;
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists spray_jobs_validate_refs_trg on public.spray_jobs;
create trigger spray_jobs_validate_refs_trg
before insert or update on public.spray_jobs
for each row execute function public.spray_jobs_validate_refs();

-- =====================================================================
-- Cross-vineyard integrity trigger for spray_job_paddocks
-- Ensures the paddock belongs to the same vineyard as its parent spray_job.
-- =====================================================================
create or replace function public.spray_job_paddocks_validate_vineyard()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_job_vineyard uuid;
  v_paddock_vineyard uuid;
begin
  select vineyard_id into v_job_vineyard
  from public.spray_jobs where id = new.spray_job_id;
  if v_job_vineyard is null then
    raise exception 'spray_job_paddocks.spray_job_id % not found', new.spray_job_id;
  end if;

  select vineyard_id into v_paddock_vineyard
  from public.paddocks where id = new.paddock_id;
  if v_paddock_vineyard is null then
    raise exception 'spray_job_paddocks.paddock_id % not found', new.paddock_id;
  end if;

  if v_job_vineyard <> v_paddock_vineyard then
    raise exception
      'spray_job_paddocks: paddock % belongs to a different vineyard than spray_job %',
      new.paddock_id, new.spray_job_id;
  end if;

  return new;
end;
$function$;

drop trigger if exists spray_job_paddocks_validate_vineyard_trg on public.spray_job_paddocks;
create trigger spray_job_paddocks_validate_vineyard_trg
before insert or update on public.spray_job_paddocks
for each row execute function public.spray_job_paddocks_validate_vineyard();

-- =====================================================================
-- RLS: spray_jobs
-- Phase 1 access:
--   * SELECT: any vineyard member
--   * INSERT/UPDATE: owner/manager only
--   * DELETE: blocked (use archive_spray_job RPC for soft delete)
-- =====================================================================
alter table public.spray_jobs enable row level security;

drop policy if exists "spray_jobs_select_members" on public.spray_jobs;
create policy "spray_jobs_select_members"
on public.spray_jobs for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "spray_jobs_insert_managers" on public.spray_jobs;
create policy "spray_jobs_insert_managers"
on public.spray_jobs for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "spray_jobs_update_managers" on public.spray_jobs;
create policy "spray_jobs_update_managers"
on public.spray_jobs for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "spray_jobs_no_client_hard_delete" on public.spray_jobs;
create policy "spray_jobs_no_client_hard_delete"
on public.spray_jobs for delete
to authenticated
using (false);

-- =====================================================================
-- RLS: spray_job_paddocks
-- SELECT for members, INSERT/DELETE for owner/manager of the parent job's
-- vineyard. UPDATE is uncommon (composite PK) but allowed for managers.
-- =====================================================================
alter table public.spray_job_paddocks enable row level security;

drop policy if exists "spray_job_paddocks_select_members" on public.spray_job_paddocks;
create policy "spray_job_paddocks_select_members"
on public.spray_job_paddocks for select
to authenticated
using (
  exists (
    select 1 from public.spray_jobs sj
    where sj.id = spray_job_paddocks.spray_job_id
      and public.is_vineyard_member(sj.vineyard_id)
  )
);

drop policy if exists "spray_job_paddocks_insert_managers" on public.spray_job_paddocks;
create policy "spray_job_paddocks_insert_managers"
on public.spray_job_paddocks for insert
to authenticated
with check (
  exists (
    select 1 from public.spray_jobs sj
    where sj.id = spray_job_paddocks.spray_job_id
      and public.has_vineyard_role(sj.vineyard_id, array['owner', 'manager'])
  )
);

drop policy if exists "spray_job_paddocks_update_managers" on public.spray_job_paddocks;
create policy "spray_job_paddocks_update_managers"
on public.spray_job_paddocks for update
to authenticated
using (
  exists (
    select 1 from public.spray_jobs sj
    where sj.id = spray_job_paddocks.spray_job_id
      and public.has_vineyard_role(sj.vineyard_id, array['owner', 'manager'])
  )
)
with check (
  exists (
    select 1 from public.spray_jobs sj
    where sj.id = spray_job_paddocks.spray_job_id
      and public.has_vineyard_role(sj.vineyard_id, array['owner', 'manager'])
  )
);

drop policy if exists "spray_job_paddocks_delete_managers" on public.spray_job_paddocks;
create policy "spray_job_paddocks_delete_managers"
on public.spray_job_paddocks for delete
to authenticated
using (
  exists (
    select 1 from public.spray_jobs sj
    where sj.id = spray_job_paddocks.spray_job_id
      and public.has_vineyard_role(sj.vineyard_id, array['owner', 'manager'])
  )
);

-- =====================================================================
-- RPC: archive_spray_job
-- Soft-delete: sets status='archived' and deleted_at=now().
-- Owner/manager only.
-- =====================================================================
create or replace function public.archive_spray_job(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select vineyard_id into v_vineyard_id
  from public.spray_jobs
  where id = p_id;

  if v_vineyard_id is null then
    raise exception 'Spray job not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to archive spray job';
  end if;

  update public.spray_jobs
  set status = 'archived',
      deleted_at = coalesce(deleted_at, now()),
      updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.archive_spray_job(uuid) from public;
grant execute on function public.archive_spray_job(uuid) to authenticated;

-- =====================================================================
-- RPC: restore_spray_job
-- Reverses archive: clears deleted_at and resets status to 'draft' if it
-- was 'archived'. Owner/manager only.
-- =====================================================================
create or replace function public.restore_spray_job(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select vineyard_id, status into v_vineyard_id, v_status
  from public.spray_jobs
  where id = p_id;

  if v_vineyard_id is null then
    raise exception 'Spray job not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to restore spray job';
  end if;

  update public.spray_jobs
  set deleted_at = null,
      status = case when v_status = 'archived' then 'draft' else v_status end,
      updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.restore_spray_job(uuid) from public;
grant execute on function public.restore_spray_job(uuid) to authenticated;

-- =====================================================================
-- RPC: duplicate_spray_job
-- Creates a copy of a spray_job within the same vineyard. Optionally
-- promotes the copy to a template (p_as_template). Owner/manager only.
-- Also copies spray_job_paddocks links.
-- Returns the new spray_jobs.id.
-- =====================================================================
create or replace function public.duplicate_spray_job(
  p_id uuid,
  p_as_template boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_src public.spray_jobs%rowtype;
  v_new_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select * into v_src from public.spray_jobs where id = p_id;
  if v_src.id is null then
    raise exception 'Spray job not found';
  end if;

  if not public.has_vineyard_role(v_src.vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to duplicate spray job';
  end if;

  insert into public.spray_jobs (
    vineyard_id,
    name,
    is_template,
    planned_date,
    status,
    chemical_lines,
    water_volume,
    spray_rate_per_ha,
    operation_type,
    target,
    equipment_id,
    tractor_id,
    operator_user_id,
    notes,
    created_by,
    updated_by
  ) values (
    v_src.vineyard_id,
    case
      when p_as_template then coalesce(nullif(v_src.name, ''), 'Untitled') || ' (template)'
      else coalesce(nullif(v_src.name, ''), 'Untitled') || ' (copy)'
    end,
    p_as_template,
    case when p_as_template then null else v_src.planned_date end,
    'draft',
    v_src.chemical_lines,
    v_src.water_volume,
    v_src.spray_rate_per_ha,
    v_src.operation_type,
    v_src.target,
    v_src.equipment_id,
    v_src.tractor_id,
    v_src.operator_user_id,
    v_src.notes,
    auth.uid(),
    auth.uid()
  )
  returning id into v_new_id;

  insert into public.spray_job_paddocks (spray_job_id, paddock_id)
  select v_new_id, paddock_id
  from public.spray_job_paddocks
  where spray_job_id = p_id;

  return v_new_id;
end;
$function$;

revoke all on function public.duplicate_spray_job(uuid, boolean) from public;
grant execute on function public.duplicate_spray_job(uuid, boolean) to authenticated;

-- Phase: safer paddock deletion.
--
-- Adds:
--   * paddock_reference_counts(p_paddock_id) -> table of counts per
--     linked table, plus a `total_references` aggregate. Counts only
--     active (non-deleted) rows so historical-but-already-archived
--     records don't block a permanent delete.
--   * hard_delete_paddock(p_paddock_id) -> permanently removes a
--     paddock ONLY when every reference count is zero. Owners/managers
--     only.
--   * restore_paddock(p_paddock_id) -> clears deleted_at on a
--     previously soft-deleted paddock. Owners/managers only.
--
-- Notes on production schema (verified against sql/004..072):
--   * paddocks already carries deleted_at (sql/005) and a working
--     soft_delete_paddock RPC. Client-side hard delete is blocked by
--     the paddocks_no_client_hard_delete RLS policy.
--   * Linked tables with a paddock_id reference (all in public.*):
--       - pins                       (nullable, no FK, has deleted_at)
--       - trips                      (set null FK, has deleted_at)
--       - work_tasks                 (nullable, has deleted_at)
--       - damage_records             (not null, has deleted_at)
--       - growth_stage_records       (set null FK, has deleted_at)
--       - trip_cost_allocations      (set null FK, has deleted_at)
--       - work_task_paddocks         (cascade FK, has deleted_at)
--       - spray_job_paddocks         (cascade FK, no deleted_at; follows
--                                     parent spray_jobs.deleted_at)
--       - paddock_soil_profiles      (cascade FK, no deleted_at)
--   * trips.paddock_ids (jsonb array) is also counted via a containment
--     check, so multi-paddock trips block permanent delete too.
--
-- Idempotent: drops and recreates the functions.

set search_path = public;

----------------------------------------------------------------------
-- paddock_reference_counts
----------------------------------------------------------------------
drop function if exists public.paddock_reference_counts(uuid);

create or replace function public.paddock_reference_counts(p_paddock_id uuid)
returns table (
  pins                  bigint,
  trips                 bigint,
  trip_cost_allocations bigint,
  work_tasks            bigint,
  work_task_paddocks    bigint,
  damage_records        bigint,
  growth_stage_records  bigint,
  spray_job_paddocks    bigint,
  paddock_soil_profiles bigint,
  total_references      bigint
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
  v_pins                  bigint := 0;
  v_trips                 bigint := 0;
  v_tca                   bigint := 0;
  v_work_tasks            bigint := 0;
  v_wtp                   bigint := 0;
  v_damage                bigint := 0;
  v_gsr                   bigint := 0;
  v_sjp                   bigint := 0;
  v_soil                  bigint := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_paddock_id is null then
    raise exception 'paddock_id_required' using errcode = '22023';
  end if;

  select pad.vineyard_id into v_vineyard_id
    from public.paddocks pad
   where pad.id = p_paddock_id;

  if v_vineyard_id is null then
    raise exception 'Paddock not found';
  end if;

  if not public.is_vineyard_member(v_vineyard_id) then
    raise exception 'Insufficient permissions to inspect paddock';
  end if;

  select count(*) into v_pins
    from public.pins t
   where t.paddock_id = p_paddock_id
     and t.deleted_at is null;

  select count(*) into v_trips
    from public.trips t
   where t.deleted_at is null
     and (
       t.paddock_id = p_paddock_id
       or (t.paddock_ids is not null
           and t.paddock_ids @> to_jsonb(p_paddock_id::text))
     );

  select count(*) into v_tca
    from public.trip_cost_allocations t
   where t.paddock_id = p_paddock_id
     and t.deleted_at is null;

  select count(*) into v_work_tasks
    from public.work_tasks t
   where t.paddock_id = p_paddock_id
     and t.deleted_at is null;

  select count(*) into v_wtp
    from public.work_task_paddocks t
   where t.paddock_id = p_paddock_id
     and t.deleted_at is null;

  select count(*) into v_damage
    from public.damage_records t
   where t.paddock_id = p_paddock_id
     and t.deleted_at is null;

  select count(*) into v_gsr
    from public.growth_stage_records t
   where t.paddock_id = p_paddock_id
     and t.deleted_at is null;

  -- spray_job_paddocks has no deleted_at; gate via parent spray_jobs.
  select count(*) into v_sjp
    from public.spray_job_paddocks sjp
    join public.spray_jobs sj on sj.id = sjp.spray_job_id
   where sjp.paddock_id = p_paddock_id
     and sj.deleted_at is null;

  select count(*) into v_soil
    from public.paddock_soil_profiles t
   where t.paddock_id = p_paddock_id;

  pins                  := v_pins;
  trips                 := v_trips;
  trip_cost_allocations := v_tca;
  work_tasks            := v_work_tasks;
  work_task_paddocks    := v_wtp;
  damage_records        := v_damage;
  growth_stage_records  := v_gsr;
  spray_job_paddocks    := v_sjp;
  paddock_soil_profiles := v_soil;
  total_references      := v_pins + v_trips + v_tca + v_work_tasks
                          + v_wtp + v_damage + v_gsr + v_sjp + v_soil;
  return next;
end;
$function$;

revoke all on function public.paddock_reference_counts(uuid) from public;
grant execute on function public.paddock_reference_counts(uuid) to authenticated;

----------------------------------------------------------------------
-- hard_delete_paddock
----------------------------------------------------------------------
drop function if exists public.hard_delete_paddock(uuid);

create or replace function public.hard_delete_paddock(p_paddock_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
  v_total       bigint;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_paddock_id is null then
    raise exception 'paddock_id_required' using errcode = '22023';
  end if;

  select pad.vineyard_id into v_vineyard_id
    from public.paddocks pad
   where pad.id = p_paddock_id;

  if v_vineyard_id is null then
    raise exception 'Paddock not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to permanently delete paddock';
  end if;

  select total_references
    into v_total
    from public.paddock_reference_counts(p_paddock_id);

  if v_total is null then v_total := 0; end if;

  if v_total > 0 then
    raise exception 'Cannot permanently delete paddock with % linked record(s). Archive it instead.', v_total
      using errcode = '23503';
  end if;

  -- At this point every active reference is zero; safe to hard delete.
  -- spray_job_paddocks / work_task_paddocks / paddock_soil_profiles use
  -- cascade FKs, so any historical rows from soft-deleted parents will
  -- be cleaned up by the cascade. Set-null FKs (trips,
  -- trip_cost_allocations, growth_stage_records) will null their
  -- paddock_id, which we want for archived/historical context.
  delete from public.paddocks where id = p_paddock_id;
end;
$function$;

revoke all on function public.hard_delete_paddock(uuid) from public;
grant execute on function public.hard_delete_paddock(uuid) to authenticated;

----------------------------------------------------------------------
-- restore_paddock
----------------------------------------------------------------------
drop function if exists public.restore_paddock(uuid);

create or replace function public.restore_paddock(p_paddock_id uuid)
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

  if p_paddock_id is null then
    raise exception 'paddock_id_required' using errcode = '22023';
  end if;

  select pad.vineyard_id into v_vineyard_id
    from public.paddocks pad
   where pad.id = p_paddock_id;

  if v_vineyard_id is null then
    raise exception 'Paddock not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to restore paddock';
  end if;

  update public.paddocks
     set deleted_at = null,
         updated_by = auth.uid(),
         updated_at = now()
   where id = p_paddock_id;
end;
$function$;

revoke all on function public.restore_paddock(uuid) from public;
grant execute on function public.restore_paddock(uuid) to authenticated;

-- Refresh PostgREST schema cache so clients see the new RPCs.
notify pgrst, 'reload schema';

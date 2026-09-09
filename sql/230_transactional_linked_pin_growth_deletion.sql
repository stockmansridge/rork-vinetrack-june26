-- 230 · Transactional linked pin / growth-stage deletion
--
-- Keeps the two existing mobile RPC contracts while making deletion of a
-- mirrored growth observation atomic, idempotent and monotonic. Jonathan runs
-- this migration manually; mobile clients remain backward compatible.

create or replace function public.delete_linked_pin_growth_v1(
  p_pin_id uuid default null,
  p_growth_stage_record_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_pin public.pins%rowtype;
  v_growth public.growth_stage_records%rowtype;
  v_vineyard_id uuid;
  v_deleted_at timestamptz := clock_timestamp();
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if p_pin_id is null and p_growth_stage_record_id is null then
    raise exception 'A pin or growth stage record id is required';
  end if;

  -- Resolve a growth entry before locking, then always lock the pin first.
  if p_growth_stage_record_id is not null then
    select * into v_growth
      from public.growth_stage_records
     where id = p_growth_stage_record_id;
    if not found then
      raise exception 'Growth stage record not found';
    end if;
    if p_pin_id is not null and v_growth.pin_id is not null and v_growth.pin_id <> p_pin_id then
      raise exception 'Pin and growth stage record are not linked';
    end if;
    p_pin_id := coalesce(p_pin_id, v_growth.pin_id);
  end if;

  if p_pin_id is not null then
    select * into v_pin
      from public.pins
     where id = p_pin_id
     for update;
    if not found then
      raise exception 'Pin not found';
    end if;
    v_vineyard_id := v_pin.vineyard_id;
  end if;

  -- Lock growth rows second, in deterministic id order. Re-read the explicit
  -- row after the pin lock so a concurrent relink cannot cross the boundary.
  if p_growth_stage_record_id is not null then
    select * into v_growth
      from public.growth_stage_records
     where id = p_growth_stage_record_id
     for update;
    if v_growth.pin_id is distinct from p_pin_id and v_growth.pin_id is not null then
      raise exception 'Growth stage record link changed during deletion';
    end if;
    v_vineyard_id := coalesce(v_vineyard_id, v_growth.vineyard_id);
  end if;

  if p_pin_id is not null then
    perform id
      from public.growth_stage_records
     where pin_id = p_pin_id
     order by id
     for update;
  end if;

  if p_pin_id is not null and exists (
    select 1 from public.growth_stage_records
     where pin_id = p_pin_id and vineyard_id <> v_vineyard_id
  ) then
    raise exception 'Linked pin and growth stage record belong to different vineyards';
  end if;
  if p_growth_stage_record_id is not null and v_growth.vineyard_id <> v_vineyard_id then
    raise exception 'Linked pin and growth stage record belong to different vineyards';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete operational record';
  end if;

  if p_pin_id is not null then
    update public.pins
       set deleted_at = v_deleted_at,
           updated_by = auth.uid(),
           sync_version = sync_version + 1
     where id = p_pin_id
       and deleted_at is null;

    update public.growth_stage_records
       set deleted_at = v_deleted_at,
           updated_by = auth.uid(),
           sync_version = sync_version + 1
     where pin_id = p_pin_id
       and deleted_at is null;
  end if;

  if p_growth_stage_record_id is not null then
    update public.growth_stage_records
       set deleted_at = v_deleted_at,
           updated_by = auth.uid(),
           sync_version = sync_version + 1
     where id = p_growth_stage_record_id
       and deleted_at is null;
  end if;
end;
$function$;

create or replace function public.soft_delete_pin(p_pin_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
begin
  perform public.delete_linked_pin_growth_v1(
    p_pin_id => p_pin_id,
    p_growth_stage_record_id => null
  );
end;
$function$;

create or replace function public.soft_delete_growth_stage_record(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
begin
  perform public.delete_linked_pin_growth_v1(
    p_pin_id => null,
    p_growth_stage_record_id => p_id
  );
end;
$function$;

revoke all on function public.delete_linked_pin_growth_v1(uuid, uuid) from public, anon;
grant execute on function public.delete_linked_pin_growth_v1(uuid, uuid) to authenticated;
revoke all on function public.soft_delete_pin(uuid) from public, anon;
grant execute on function public.soft_delete_pin(uuid) to authenticated;
revoke all on function public.soft_delete_growth_stage_record(uuid) from public, anon;
grant execute on function public.soft_delete_growth_stage_record(uuid) to authenticated;

-- Client upserts may update old tombstones, but they may never clear them.
-- Direct active→deleted writes are also held to the RPC's role policy.
create or replace function public.protect_pin_growth_tombstone_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_linked_pin public.pins%rowtype;
begin
  if tg_op = 'UPDATE' then
    if old.deleted_at is not null then
      new.deleted_at := old.deleted_at;
    elsif new.deleted_at is not null
      and not public.has_vineyard_role(old.vineyard_id, array['owner','manager','supervisor']) then
      raise exception 'Insufficient permissions to delete operational record';
    end if;
  end if;

  if tg_table_name = 'growth_stage_records' and new.pin_id is not null then
    select * into v_linked_pin from public.pins where id = new.pin_id;
    if not found then
      raise exception 'Linked pin not found';
    end if;
    if v_linked_pin.vineyard_id <> new.vineyard_id then
      raise exception 'Linked pin and growth stage record belong to different vineyards';
    end if;
    if v_linked_pin.deleted_at is not null then
      new.deleted_at := coalesce(new.deleted_at, v_linked_pin.deleted_at);
    end if;
  end if;
  return new;
end;
$function$;

revoke all on function public.protect_pin_growth_tombstone_v1() from public, anon, authenticated;

drop trigger if exists pins_protect_tombstone_v1 on public.pins;
create trigger pins_protect_tombstone_v1
before update on public.pins
for each row execute function public.protect_pin_growth_tombstone_v1();

drop trigger if exists growth_stage_records_protect_tombstone_v1 on public.growth_stage_records;
create trigger growth_stage_records_protect_tombstone_v1
before insert or update on public.growth_stage_records
for each row execute function public.protect_pin_growth_tombstone_v1();

-- A tombstoned mirrored row still owns the compatibility identity. Excluding
-- only active mirrors allowed a surviving pin to reappear after deletion.
create or replace view public.v_growth_stage_observations as
  select
    gsr.id as id, gsr.vineyard_id as vineyard_id, gsr.paddock_id as paddock_id,
    gsr.pin_id as pin_id, gsr.stage_code as stage_code, gsr.stage_label as stage_label,
    gsr.variety as variety, gsr.variety_id as variety_id, gsr.observed_at as observed_at,
    gsr.latitude as latitude, gsr.longitude as longitude, gsr.row_number as row_number,
    gsr.side as side, gsr.notes as notes, gsr.photo_paths as photo_paths,
    gsr.recorded_by_name as recorded_by_name, gsr.created_by as created_by,
    gsr.updated_by as updated_by, gsr.created_at as created_at, gsr.updated_at as updated_at,
    'growth_stage_records'::text as source
  from public.growth_stage_records gsr
  where gsr.deleted_at is null
  union all
  select
    p.id as id, p.vineyard_id as vineyard_id, p.paddock_id as paddock_id,
    p.id as pin_id, p.growth_stage_code as stage_code, null::text as stage_label,
    null::text as variety, null::uuid as variety_id, coalesce(p.created_at, now()) as observed_at,
    p.latitude as latitude, p.longitude as longitude, p.row_number as row_number,
    p.side as side, p.notes as notes,
    case when p.photo_path is not null then array[p.photo_path] else '{}'::text[] end as photo_paths,
    p.completed_by as recorded_by_name, p.created_by as created_by,
    p.updated_by as updated_by, p.created_at as created_at, p.updated_at as updated_at,
    'pins'::text as source
  from public.pins p
  where p.deleted_at is null
    and p.growth_stage_code is not null
    and not exists (
      select 1 from public.growth_stage_records gsr2 where gsr2.pin_id = p.id
    );

grant select on public.v_growth_stage_observations to authenticated;
notify pgrst, 'reload schema';

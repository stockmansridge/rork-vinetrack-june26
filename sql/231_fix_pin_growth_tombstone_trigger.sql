-- Fix table-specific NEW field access in the shared pin/growth tombstone trigger.
-- Migration 230 is already deployed, so this follow-up replaces only the trigger
-- function and leaves the existing RPCs, triggers, grants, and data untouched.

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

  -- NEW is a generic record. Keep growth-only columns inside a table-specific
  -- branch so PostgreSQL never resolves NEW.pin_id for a pins trigger row.
  if tg_table_name = 'growth_stage_records' then
    if new.pin_id is not null then
      select * into v_linked_pin
        from public.pins
       where id = new.pin_id;
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
  end if;

  return new;
end;
$function$;

revoke all on function public.protect_pin_growth_tombstone_v1() from public, anon, authenticated;
notify pgrst, 'reload schema';

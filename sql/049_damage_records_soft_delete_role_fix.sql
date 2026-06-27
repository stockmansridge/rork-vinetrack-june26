-- =====================================================================
-- 049 · damage_records — align soft-delete RPC roles with RLS
-- =====================================================================
-- The RLS policies for `public.damage_records` (sql/014) allow members
-- with role owner / manager / supervisor / operator to INSERT and UPDATE.
-- The `soft_delete_damage_record` RPC, however, only allowed
-- owner / manager / supervisor — operators could create and edit damage
-- records but their deletes would silently fail server-side, leaving the
-- iOS local store and the server out of sync (the row keeps showing up
-- on other devices and in yield-forecast stats).
--
-- This migration loosens the RPC role check to match the RLS update
-- policy so any member who can edit a damage record can also delete it.
-- Hard DELETE remains denied; deletes still go through the soft-delete
-- RPC which sets `deleted_at`.
-- =====================================================================

create or replace function public.soft_delete_damage_record(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id from public.damage_records where id = p_id;
  if v_vineyard_id is null then raise exception 'Damage record not found'; end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'Insufficient permissions to delete damage record';
  end if;
  update public.damage_records
     set deleted_at = now(),
         updated_by = auth.uid()
   where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_damage_record(uuid) from public;
grant execute on function public.soft_delete_damage_record(uuid) to authenticated;

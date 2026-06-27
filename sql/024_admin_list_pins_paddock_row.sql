-- Phase: Admin/Portal Pins listing — expose paddock + row + side + mode.
--
-- The Lovable backend portal Pins view shows "—" for Paddock and Row because
-- the admin_list_pins() RPC defined in 017_admin_engagement.sql only returns
-- a slim projection (id, vineyard_id, vineyard_name, title, category, status,
-- created_at, is_completed). The iOS app correctly saves paddock_id and
-- row_number into public.pins (see sql/004_pins_sync.sql + BackendPinUpsert),
-- but the portal cannot display them because they are not in the RPC result.
--
-- This migration replaces admin_list_pins() with an extended projection that
-- left-joins public.paddocks so the portal can show paddock name + row + side
-- + mode + updated_at without needing direct table access.
--
-- The function signature changes (new return columns), so we must drop the
-- old version first. Permissions are re-granted at the bottom.

drop function if exists public.admin_list_pins(int);

create or replace function public.admin_list_pins(p_limit int default 500)
returns table (
  id uuid,
  vineyard_id uuid,
  vineyard_name text,
  paddock_id uuid,
  paddock_name text,
  row_number integer,
  side text,
  mode text,
  title text,
  category text,
  status text,
  is_completed boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  return query
  select
    pn.id,
    pn.vineyard_id,
    v.name as vineyard_name,
    pn.paddock_id,
    pd.name as paddock_name,
    pn.row_number,
    pn.side,
    pn.mode,
    coalesce(nullif(pn.title, ''), nullif(pn.button_name, ''), pn.category, 'Pin') as title,
    pn.category,
    pn.status,
    pn.is_completed,
    pn.created_at,
    pn.updated_at
  from public.pins pn
  left join public.vineyards v on v.id = pn.vineyard_id
  left join public.paddocks pd on pd.id = pn.paddock_id
  where pn.deleted_at is null
  order by pn.created_at desc nulls last
  limit greatest(coalesce(p_limit, 500), 1);
end;
$$;

revoke all on function public.admin_list_pins(int) from public;
grant execute on function public.admin_list_pins(int) to authenticated;

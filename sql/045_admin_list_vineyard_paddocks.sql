-- 045_admin_list_vineyard_paddocks.sql
-- Admin RPC: return all paddocks (with polygon geometry) for a vineyard so the
-- Admin Dashboard can render the vineyard map. Bypasses RLS via SECURITY DEFINER
-- and gates access through public.is_admin().

create or replace function public.admin_list_vineyard_paddocks(p_vineyard_id uuid)
returns table (
  id uuid,
  vineyard_id uuid,
  name text,
  polygon_points jsonb,
  row_count integer,
  row_direction double precision,
  row_width double precision,
  created_at timestamptz,
  updated_at timestamptz,
  deleted_at timestamptz
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
    p.id,
    p.vineyard_id,
    p.name,
    coalesce(p.polygon_points, '[]'::jsonb) as polygon_points,
    coalesce(jsonb_array_length(coalesce(p.rows, '[]'::jsonb)), 0) as row_count,
    p.row_direction,
    p.row_width,
    p.created_at,
    p.updated_at,
    p.deleted_at
  from public.paddocks p
  where p.vineyard_id = p_vineyard_id
  order by p.name asc nulls last;
end;
$$;

revoke all on function public.admin_list_vineyard_paddocks(uuid) from public;
grant execute on function public.admin_list_vineyard_paddocks(uuid) to authenticated;

-- 046_admin_list_vineyard_paddocks_with_rows.sql
-- Extends admin_list_vineyard_paddocks to also return the paddock row geometry
-- (paddocks.rows jsonb) so the Admin Dashboard can render individual rows on
-- a per-paddock detail map for troubleshooting.

-- Drop the existing function first because the OUT parameter row type is
-- changing (Postgres cannot CREATE OR REPLACE across return-type changes).
drop function if exists public.admin_list_vineyard_paddocks(uuid);

create function public.admin_list_vineyard_paddocks(p_vineyard_id uuid)
returns table (
  id uuid,
  vineyard_id uuid,
  name text,
  polygon_points jsonb,
  rows jsonb,
  row_count integer,
  row_direction double precision,
  row_width double precision,
  vine_spacing double precision,
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
    coalesce(p.rows, '[]'::jsonb)           as rows,
    coalesce(jsonb_array_length(coalesce(p.rows, '[]'::jsonb)), 0) as row_count,
    p.row_direction,
    p.row_width,
    p.vine_spacing,
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

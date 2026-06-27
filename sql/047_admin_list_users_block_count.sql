-- 047_admin_list_users_block_count.sql
-- Extend admin_list_users() to include the number of blocks (paddocks)
-- the user can access across all of their vineyards. This lets the Admin
-- Dashboard show a quick "blocks setup" indicator per user.

drop function if exists public.admin_list_users();

create function public.admin_list_users()
returns table (
  id uuid,
  email text,
  full_name text,
  created_at timestamptz,
  updated_at timestamptz,
  last_sign_in_at timestamptz,
  vineyard_count bigint,
  owned_count bigint,
  block_count bigint
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
    p.email,
    p.full_name,
    p.created_at,
    p.updated_at,
    u.last_sign_in_at,
    coalesce((
      select count(distinct v.id)::bigint
      from public.vineyards v
      left join public.vineyard_members vm
        on vm.vineyard_id = v.id and vm.user_id = p.id
      where v.deleted_at is null
        and (v.owner_id = p.id or vm.user_id = p.id)
    ), 0) as vineyard_count,
    coalesce((
      select count(*)::bigint
      from public.vineyards v2
      where v2.owner_id = p.id and v2.deleted_at is null
    ), 0) as owned_count,
    coalesce((
      select count(distinct pd.id)::bigint
      from public.paddocks pd
      join public.vineyards v3 on v3.id = pd.vineyard_id
      left join public.vineyard_members vm2
        on vm2.vineyard_id = v3.id and vm2.user_id = p.id
      where pd.deleted_at is null
        and v3.deleted_at is null
        and (v3.owner_id = p.id or vm2.user_id = p.id)
    ), 0) as block_count
  from public.profiles p
  left join auth.users u on u.id = p.id
  order by p.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_users() from public;
grant execute on function public.admin_list_users() to authenticated;

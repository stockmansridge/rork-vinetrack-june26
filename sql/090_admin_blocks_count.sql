-- 090_admin_blocks_count.sql
-- Lightweight admin RPC returning the platform-wide count of active blocks
-- (paddocks where deleted_at is null). Used by the iOS admin dashboard so the
-- Blocks tile doesn't depend on a per-vineyard fan-out (which times out or
-- throws when any single vineyard call fails, leaving the tile stuck on "—").

create or replace function public.admin_blocks_count()
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_count bigint;
begin
  if not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  select count(*)::bigint
  into v_count
  from public.paddocks
  where deleted_at is null;

  return coalesce(v_count, 0);
end;
$$;

revoke all on function public.admin_blocks_count() from public;
grant execute on function public.admin_blocks_count() to authenticated;

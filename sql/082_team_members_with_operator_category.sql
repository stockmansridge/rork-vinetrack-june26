-- 082_team_members_with_operator_category.sql
--
-- Extends public.get_vineyard_team_members (sql/022) to also return:
--   - operator_category_id   uuid    (vineyard_members.operator_category_id)
--   - operator_category_name text    (operator_categories.name, when active)
--
-- This lets iOS (and Lovable) render member rows with name + email + role +
-- assigned operator category in a single round-trip, without weakening the
-- profiles_select_own RLS policy.
--
-- All other behaviour is unchanged: SECURITY DEFINER, vineyard membership
-- check, ordered by joined_at asc, id asc.
--
-- Postgres cannot change the OUT/return type of an existing function via
-- CREATE OR REPLACE, so we DROP the prior signature first. The function is
-- only called from authenticated clients via RPC, so dropping and recreating
-- in the same migration is safe.

drop function if exists public.get_vineyard_team_members(uuid);

create function public.get_vineyard_team_members(p_vineyard_id uuid)
returns table (
  membership_id uuid,
  vineyard_id uuid,
  user_id uuid,
  role text,
  joined_at timestamptz,
  display_name text,
  full_name text,
  email text,
  avatar_url text,
  operator_category_id uuid,
  operator_category_name text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_vineyard_id is null then
    raise exception 'p_vineyard_id is required';
  end if;

  if not public.is_vineyard_member(p_vineyard_id) then
    raise exception 'not a member of this vineyard'
      using errcode = '42501';
  end if;

  return query
  select
    vm.id            as membership_id,
    vm.vineyard_id   as vineyard_id,
    vm.user_id       as user_id,
    vm.role          as role,
    vm.joined_at     as joined_at,
    coalesce(
      nullif(btrim(vm.display_name), ''),
      nullif(btrim(p.full_name), ''),
      nullif(btrim(p.email), ''),
      nullif(btrim(au.email), ''),
      'User ' || substr(vm.user_id::text, 1, 8)
    )                as display_name,
    p.full_name      as full_name,
    coalesce(nullif(btrim(p.email), ''), au.email) as email,
    p.avatar_url     as avatar_url,
    vm.operator_category_id as operator_category_id,
    oc.name          as operator_category_name
  from public.vineyard_members vm
  left join public.profiles p on p.id = vm.user_id
  left join auth.users au on au.id = vm.user_id
  left join public.operator_categories oc
    on oc.id = vm.operator_category_id
   and oc.deleted_at is null
  where vm.vineyard_id = p_vineyard_id
  order by vm.joined_at asc, vm.id asc;
end;
$$;

revoke all on function public.get_vineyard_team_members(uuid) from public;
grant execute on function public.get_vineyard_team_members(uuid) to authenticated;

comment on function public.get_vineyard_team_members(uuid) is
  $c$Returns display-safe team member info (membership_id, vineyard_id, user_id, role, joined_at, display_name, full_name, email, avatar_url, operator_category_id, operator_category_name) for a vineyard the caller is a member of. SECURITY DEFINER; reads public.profiles and auth.users for email fallback. operator_category_name is NULL when no category is assigned or the category has been soft-deleted.$c$;

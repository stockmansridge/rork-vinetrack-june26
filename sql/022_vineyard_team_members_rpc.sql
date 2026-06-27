-- 022_vineyard_team_members_rpc.sql
--
-- Read-only RPC for resolving vineyard team member display info from the
-- web portal (Lovable) and the iOS app, without weakening the
-- profiles_select_own RLS policy on public.profiles.
--
-- Background:
--   public.profiles has RLS that only allows a user to read their own row.
--   This means the web portal cannot resolve full_name / email for OTHER
--   members of a vineyard the caller belongs to. We avoid loosening RLS by
--   exposing a SECURITY DEFINER RPC that:
--     1. confirms the caller is a member of the requested vineyard
--     2. returns only non-sensitive display fields for that vineyard's members
--
-- Sources joined:
--   - public.vineyard_members      (membership row, role, display_name override)
--   - public.profiles              (full_name, avatar_url, email mirror)
--   - auth.users                   (email fallback only; no metadata exposed)
--
-- Display priority handled client-side, but a resolved `display_name` is
-- also returned for convenience using the documented priority:
--   1. vineyard_members.display_name
--   2. profiles.full_name
--   3. profiles.email
--   4. auth.users.email
--   5. shortened user_id

create or replace function public.get_vineyard_team_members(p_vineyard_id uuid)
returns table (
  membership_id uuid,
  vineyard_id uuid,
  user_id uuid,
  role text,
  joined_at timestamptz,
  display_name text,
  full_name text,
  email text,
  avatar_url text
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
    p.avatar_url     as avatar_url
  from public.vineyard_members vm
  left join public.profiles p on p.id = vm.user_id
  left join auth.users au on au.id = vm.user_id
  where vm.vineyard_id = p_vineyard_id
  order by vm.joined_at asc, vm.id asc;
end;
$$;

revoke all on function public.get_vineyard_team_members(uuid) from public;
grant execute on function public.get_vineyard_team_members(uuid) to authenticated;

comment on function public.get_vineyard_team_members(uuid) is
  'Returns display-safe team member info (membership_id, vineyard_id, user_id, role, joined_at, display_name, full_name, email, avatar_url) for a vineyard the caller is a member of. SECURITY DEFINER; reads public.profiles and auth.users for email fallback only. Does not expose phone, identities, app_metadata, user_metadata, tokens, or any other auth.users columns.';

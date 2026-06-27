-- 094_admin_user_login_activity.sql
-- System-admin-only user login / activity list, shared by iOS and the Portal.
--
-- Goal:
--   Let VineTrack platform administrators view one row per user with login
--   recency, vineyard memberships/roles, and the most recently reported
--   device/app metadata (sourced from support_requests).
--
-- Security model:
--   * Gated on public.is_system_admin() (rows in public.system_admins), NOT
--     the is_admin() email allowlist and NOT vineyard owner/manager roles.
--   * SECURITY DEFINER so it can read auth.users.last_sign_in_at without
--     exposing auth.users to client roles.
--   * Non-admins get a permission-denied error (no rows leak).
--   * Read-only. No heartbeat / last-seen writes.
--
-- Reuses:
--   * public.is_system_admin()   (sql/062_system_admin_and_feature_flags.sql)
--   * public.profiles, public.vineyards, public.vineyard_members
--   * public.support_requests    (sql/091_support_requests.sql) for last-known
--     app_platform / app_version / app_build / device_model / os_version.
--
-- Additive only: creates a single new function. Nothing is dropped or altered.

begin;

create or replace function public.admin_list_user_login_activity()
returns table (
  user_id            uuid,
  email              text,
  display_name       text,
  account_created_at timestamptz,
  last_sign_in_at    timestamptz,
  vineyard_ids       uuid[],
  vineyard_names     text[],
  roles              text[],
  app_platform       text,
  app_version        text,
  app_build          text,
  device_model       text,
  os_version         text,
  status             text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;

  return query
  with memberships as (
    -- Combine explicit vineyard_members rows with implicit ownership so an
    -- owner who has no membership row is still represented.
    select
      p.id as user_id,
      v.id as vineyard_id,
      v.name as vineyard_name,
      coalesce(vm.role, case when v.owner_id = p.id then 'owner' end) as role
    from public.profiles p
    join public.vineyards v
      on v.deleted_at is null
     and (v.owner_id = p.id or exists (
            select 1 from public.vineyard_members vm0
            where vm0.vineyard_id = v.id and vm0.user_id = p.id
          ))
    left join public.vineyard_members vm
      on vm.vineyard_id = v.id and vm.user_id = p.id
  ),
  membership_agg as (
    select
      m.user_id,
      array_agg(distinct m.vineyard_id) as vineyard_ids,
      array_agg(distinct m.vineyard_name order by m.vineyard_name) as vineyard_names,
      array_agg(distinct m.role) filter (where m.role is not null) as roles
    from memberships m
    group by m.user_id
  ),
  latest_device as (
    -- Most recent support request per user carries the last-known device/app
    -- metadata. Left-joined, so users who never filed a request are still listed.
    select distinct on (sr.user_id)
      sr.user_id,
      sr.app_platform,
      sr.app_version,
      sr.app_build,
      sr.device_model,
      sr.os_version
    from public.support_requests sr
    where sr.user_id is not null
    order by sr.user_id, sr.created_at desc
  )
  select
    p.id as user_id,
    coalesce(p.email, u.email) as email,
    p.full_name as display_name,
    p.created_at as account_created_at,
    u.last_sign_in_at,
    coalesce(ma.vineyard_ids, '{}'::uuid[]) as vineyard_ids,
    coalesce(ma.vineyard_names, '{}'::text[]) as vineyard_names,
    coalesce(ma.roles, '{}'::text[]) as roles,
    ld.app_platform,
    ld.app_version,
    ld.app_build,
    ld.device_model,
    ld.os_version,
    case
      when u.last_sign_in_at is null then 'never'
      when u.last_sign_in_at >= now() - interval '7 days'  then 'active_recent'
      when u.last_sign_in_at >= now() - interval '30 days' then 'active_30d'
      when u.last_sign_in_at >= now() - interval '90 days' then 'inactive_30d'
      else 'inactive_90d'
    end as status
  from public.profiles p
  left join auth.users u on u.id = p.id
  left join membership_agg ma on ma.user_id = p.id
  left join latest_device ld on ld.user_id = p.id
  order by u.last_sign_in_at desc nulls last, p.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_user_login_activity() from public;
grant execute on function public.admin_list_user_login_activity() to authenticated;

commit;

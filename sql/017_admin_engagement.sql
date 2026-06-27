-- 017_admin_engagement.sql
-- Admin RPCs that bypass RLS for authorized admin accounts.
-- Returns accurate engagement counts and lists across all users/vineyards.

-- ---------------------------------------------------------------------------
-- is_admin(): true when the caller's auth email is on the admin allowlist.
-- ---------------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from auth.users u
    where u.id = auth.uid()
      and lower(coalesce(u.email, '')) in (
        'jonathan@stockmansridge.com.au'
      )
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- ---------------------------------------------------------------------------
-- admin_engagement_summary(): single row of platform-wide counts.
-- ---------------------------------------------------------------------------
create or replace function public.admin_engagement_summary()
returns table (
  total_users bigint,
  total_vineyards bigint,
  total_pins bigint,
  total_spray_records bigint,
  total_work_tasks bigint,
  signed_in_last_7_days bigint,
  signed_in_last_30_days bigint,
  new_users_last_30_days bigint,
  pending_invitations bigint
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
    (select count(*)::bigint from public.profiles),
    (select count(*)::bigint from public.vineyards where deleted_at is null),
    (select count(*)::bigint from public.pins where deleted_at is null),
    (select count(*)::bigint from public.spray_records where deleted_at is null),
    (select count(*)::bigint from public.work_tasks where deleted_at is null),
    (select count(*)::bigint from auth.users where last_sign_in_at >= now() - interval '7 days'),
    (select count(*)::bigint from auth.users where last_sign_in_at >= now() - interval '30 days'),
    (select count(*)::bigint from public.profiles where created_at >= now() - interval '30 days'),
    (select count(*)::bigint from public.invitations where status = 'pending');
end;
$$;

revoke all on function public.admin_engagement_summary() from public;
grant execute on function public.admin_engagement_summary() to authenticated;

-- ---------------------------------------------------------------------------
-- admin_list_users(): every profile + accurate vineyard counts (membership
-- and ownership combined, deduped by vineyard).
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_users()
returns table (
  id uuid,
  email text,
  full_name text,
  created_at timestamptz,
  updated_at timestamptz,
  last_sign_in_at timestamptz,
  vineyard_count bigint,
  owned_count bigint
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
    ), 0) as owned_count
  from public.profiles p
  left join auth.users u on u.id = p.id
  order by p.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_users() from public;
grant execute on function public.admin_list_users() to authenticated;

-- ---------------------------------------------------------------------------
-- admin_list_vineyards(): every vineyard with owner + member counts.
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_vineyards()
returns table (
  id uuid,
  name text,
  owner_id uuid,
  owner_email text,
  owner_full_name text,
  country text,
  created_at timestamptz,
  deleted_at timestamptz,
  member_count bigint,
  pending_invites bigint
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
    v.id,
    v.name,
    v.owner_id,
    p.email,
    p.full_name,
    v.country,
    v.created_at,
    v.deleted_at,
    (select count(*)::bigint from public.vineyard_members vm where vm.vineyard_id = v.id),
    (select count(*)::bigint from public.invitations i where i.vineyard_id = v.id and i.status = 'pending')
  from public.vineyards v
  left join public.profiles p on p.id = v.owner_id
  order by v.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_vineyards() from public;
grant execute on function public.admin_list_vineyards() to authenticated;

-- ---------------------------------------------------------------------------
-- admin_list_user_vineyards(p_user_id): vineyards a specific user belongs to
-- (either as owner or member).
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_user_vineyards(p_user_id uuid)
returns table (
  id uuid,
  name text,
  role text,
  is_owner boolean,
  country text,
  created_at timestamptz,
  deleted_at timestamptz,
  member_count bigint
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
    v.id,
    v.name,
    coalesce(vm.role, case when v.owner_id = p_user_id then 'owner' else null end) as role,
    (v.owner_id = p_user_id) as is_owner,
    v.country,
    v.created_at,
    v.deleted_at,
    (select count(*)::bigint from public.vineyard_members vm2 where vm2.vineyard_id = v.id) as member_count
  from public.vineyards v
  left join public.vineyard_members vm
    on vm.vineyard_id = v.id and vm.user_id = p_user_id
  where v.owner_id = p_user_id or vm.user_id = p_user_id
  order by v.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_user_vineyards(uuid) from public;
grant execute on function public.admin_list_user_vineyards(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- admin_list_invitations(): all invitations with vineyard + inviter info.
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_invitations()
returns table (
  id uuid,
  email text,
  role text,
  status text,
  vineyard_id uuid,
  vineyard_name text,
  invited_by uuid,
  invited_by_email text,
  created_at timestamptz,
  expires_at timestamptz
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
    i.id, i.email, i.role, i.status,
    i.vineyard_id, v.name,
    i.invited_by, p.email,
    i.created_at, i.expires_at
  from public.invitations i
  left join public.vineyards v on v.id = i.vineyard_id
  left join public.profiles p on p.id = i.invited_by
  order by i.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_invitations() from public;
grant execute on function public.admin_list_invitations() to authenticated;

-- ---------------------------------------------------------------------------
-- admin_list_pins(): recent pins across all vineyards.
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_pins(p_limit int default 500)
returns table (
  id uuid,
  vineyard_id uuid,
  vineyard_name text,
  title text,
  category text,
  status text,
  created_at timestamptz,
  is_completed boolean
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
    pn.id, pn.vineyard_id, v.name,
    coalesce(nullif(pn.title, ''), nullif(pn.button_name, ''), pn.category, 'Pin') as title,
    pn.category, pn.status, pn.created_at, pn.is_completed
  from public.pins pn
  left join public.vineyards v on v.id = pn.vineyard_id
  where pn.deleted_at is null
  order by pn.created_at desc nulls last
  limit greatest(coalesce(p_limit, 500), 1);
end;
$$;

revoke all on function public.admin_list_pins(int) from public;
grant execute on function public.admin_list_pins(int) to authenticated;

-- ---------------------------------------------------------------------------
-- admin_list_spray_records(): recent spray records across all vineyards.
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_spray_records(p_limit int default 500)
returns table (
  id uuid,
  vineyard_id uuid,
  vineyard_name text,
  spray_reference text,
  operation_type text,
  date timestamptz,
  created_at timestamptz
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
    sr.id, sr.vineyard_id, v.name,
    sr.spray_reference, sr.operation_type, sr.date, sr.created_at
  from public.spray_records sr
  left join public.vineyards v on v.id = sr.vineyard_id
  where sr.deleted_at is null
  order by sr.created_at desc nulls last
  limit greatest(coalesce(p_limit, 500), 1);
end;
$$;

revoke all on function public.admin_list_spray_records(int) from public;
grant execute on function public.admin_list_spray_records(int) to authenticated;

-- ---------------------------------------------------------------------------
-- admin_list_work_tasks(): recent work tasks across all vineyards.
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_work_tasks(p_limit int default 500)
returns table (
  id uuid,
  vineyard_id uuid,
  vineyard_name text,
  task_type text,
  paddock_name text,
  date timestamptz,
  duration_hours double precision,
  created_at timestamptz
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
    wt.id, wt.vineyard_id, v.name,
    wt.task_type, wt.paddock_name, wt.date, wt.duration_hours, wt.created_at
  from public.work_tasks wt
  left join public.vineyards v on v.id = wt.vineyard_id
  where wt.deleted_at is null
  order by wt.created_at desc nulls last
  limit greatest(coalesce(p_limit, 500), 1);
end;
$$;

revoke all on function public.admin_list_work_tasks(int) from public;
grant execute on function public.admin_list_work_tasks(int) to authenticated;

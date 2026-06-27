-- 063_system_admin_management_rpcs.sql
--
-- Secure RPCs for managing VineTrack platform system admins.
--
-- Builds on 062_system_admin_and_feature_flags.sql:
--   - public.system_admins is RLS-locked with no client policies.
--   - All access is funneled through SECURITY DEFINER functions guarded by
--     public.is_system_admin().
--
-- Provided RPCs:
--   list_system_admins()                              -> table of admins
--   add_system_admin(p_email text)                    -> inserts/reactivates by email
--   set_system_admin_active(p_user_id, p_is_active)   -> activate / deactivate
--   remove_system_admin(p_user_id)                    -> soft-deactivate (alias)
--
-- Guardrails:
--   - Only callers where public.is_system_admin() = true may execute these RPCs.
--   - The last remaining active system admin cannot be deactivated.
--   - A user can deactivate themselves only if at least one other active admin
--     would remain afterwards.
--   - Anon users have no access (execute granted to authenticated only, and the
--     is_system_admin() gate rejects non-admins).

-- =========================================================================
-- list_system_admins()
-- =========================================================================

create or replace function public.list_system_admins()
returns table (
    user_id    uuid,
    email      text,
    is_active  boolean,
    created_at timestamptz,
    created_by uuid
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
        select sa.user_id,
               coalesce(sa.email, u.email)::text as email,
               sa.is_active,
               sa.created_at,
               sa.created_by
          from public.system_admins sa
          left join auth.users u on u.id = sa.user_id
         order by sa.is_active desc, sa.created_at desc;
end$$;

grant execute on function public.list_system_admins() to authenticated;

-- =========================================================================
-- add_system_admin(p_email)
-- =========================================================================

create or replace function public.add_system_admin(p_email text)
returns table (
    user_id    uuid,
    email      text,
    is_active  boolean,
    created_at timestamptz,
    created_by uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user_id uuid;
    v_email   text;
begin
    if not public.is_system_admin() then
        raise exception 'System admin required' using errcode = '42501';
    end if;

    if p_email is null or length(trim(p_email)) = 0 then
        raise exception 'email_required' using errcode = '22023';
    end if;

    v_email := lower(trim(p_email));

    select u.id, u.email
      into v_user_id, v_email
      from auth.users u
     where lower(u.email) = v_email
     limit 1;

    if v_user_id is null then
        raise exception 'user_not_found' using errcode = 'P0002';
    end if;

    insert into public.system_admins as sa (user_id, email, is_active, created_by)
    values (v_user_id, v_email, true, auth.uid())
    on conflict (user_id) do update
        set is_active  = true,
            email      = coalesce(excluded.email, sa.email),
            created_by = coalesce(sa.created_by, auth.uid());

    return query
        select sa.user_id,
               coalesce(sa.email, u.email)::text as email,
               sa.is_active,
               sa.created_at,
               sa.created_by
          from public.system_admins sa
          left join auth.users u on u.id = sa.user_id
         where sa.user_id = v_user_id;
end$$;

grant execute on function public.add_system_admin(text) to authenticated;

-- =========================================================================
-- set_system_admin_active(p_user_id, p_is_active)
-- =========================================================================

create or replace function public.set_system_admin_active(
    p_user_id   uuid,
    p_is_active boolean
)
returns table (
    user_id    uuid,
    email      text,
    is_active  boolean,
    created_at timestamptz,
    created_by uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_active_count integer;
    v_exists       boolean;
begin
    if not public.is_system_admin() then
        raise exception 'System admin required' using errcode = '42501';
    end if;

    if p_user_id is null then
        raise exception 'user_id_required' using errcode = '22023';
    end if;

    select exists(select 1 from public.system_admins where user_id = p_user_id)
      into v_exists;

    if not v_exists then
        raise exception 'admin_not_found' using errcode = 'P0002';
    end if;

    -- Guardrail: prevent removing the last active system admin.
    if p_is_active = false then
        select count(*)
          into v_active_count
          from public.system_admins
         where is_active = true
           and user_id <> p_user_id;

        if v_active_count = 0 then
            raise exception 'cannot_deactivate_last_admin' using errcode = 'P0001';
        end if;
    end if;

    update public.system_admins
       set is_active = p_is_active
     where user_id = p_user_id;

    return query
        select sa.user_id,
               coalesce(sa.email, u.email)::text as email,
               sa.is_active,
               sa.created_at,
               sa.created_by
          from public.system_admins sa
          left join auth.users u on u.id = sa.user_id
         where sa.user_id = p_user_id;
end$$;

grant execute on function public.set_system_admin_active(uuid, boolean) to authenticated;

-- =========================================================================
-- remove_system_admin(p_user_id)
--
-- Soft-deactivate convenience wrapper. Prefer set_system_admin_active(..., false).
-- =========================================================================

create or replace function public.remove_system_admin(p_user_id uuid)
returns table (
    user_id    uuid,
    email      text,
    is_active  boolean,
    created_at timestamptz,
    created_by uuid
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.is_system_admin() then
        raise exception 'System admin required' using errcode = '42501';
    end if;

    return query select * from public.set_system_admin_active(p_user_id, false);
end$$;

grant execute on function public.remove_system_admin(uuid) to authenticated;

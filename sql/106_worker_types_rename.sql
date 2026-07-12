-- 106_worker_types_rename.sql
--
-- Unify "Operator Categories" and "Worker Types" into a single Worker Types
-- concept (name + hourly cost).
--
-- This migration:
--   1. Renames public.operator_categories -> public.worker_types.
--   2. Renames every linking column operator_category_id -> worker_type_id
--      (trips, vineyard_members, invitations, work_task_labour_lines,
--      work_task_machine_lines).
--   3. Recreates every function whose body referenced the old names:
--        - worker_type_normalised_name        (new canonical helper)
--        - soft_delete_worker_type            (new canonical)
--        - upsert_worker_type                 (new canonical)
--        - merge_worker_types                 (new canonical; now also remaps
--                                              work_task_machine_lines)
--        - update_member_worker_type          (new canonical)
--        - accept_invitation                  (same name, fixed body)
--        - create_invitation                  (same signature, fixed body)
--        - get_vineyard_team_members          (returns BOTH old and new
--                                              column names)
--   4. Adds a COMPATIBILITY LAYER for the web portal:
--        - view public.operator_categories (security_invoker, auto-updatable)
--        - soft_delete_operator_category / upsert_operator_category /
--          merge_operator_categories / update_member_operator_category
--          aliases that forward to the new canonical functions.
--
-- All existing data is preserved. Re-runnable: every step is guarded.

begin;

-- ---------------------------------------------------------------------------
-- 1. Rename table (guarded so re-runs are safe)
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.worker_types') is null
     and to_regclass('public.operator_categories') is not null then
    alter table public.operator_categories rename to worker_types;
  end if;
end $$;

comment on table public.worker_types is
  'Per-vineyard worker types (role name + hourly cost). Formerly operator_categories; a compatibility view under the old name exists for the web portal.';

-- Tidy index names (RLS policies and trigger follow the table automatically).
alter index if exists idx_operator_categories_vineyard_id rename to idx_worker_types_vineyard_id;
alter index if exists idx_operator_categories_updated_at rename to idx_worker_types_updated_at;
alter index if exists idx_operator_categories_deleted_at rename to idx_worker_types_deleted_at;

-- ---------------------------------------------------------------------------
-- 2. Rename linking columns
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'trips',
    'vineyard_members',
    'invitations',
    'work_task_labour_lines',
    'work_task_machine_lines'
  ] loop
    if exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = t
        and column_name = 'operator_category_id'
    ) then
      execute format(
        'alter table public.%I rename column operator_category_id to worker_type_id', t
      );
    end if;
  end loop;
end $$;

alter index if exists idx_vineyard_members_operator_category_id rename to idx_vineyard_members_worker_type_id;
alter index if exists idx_invitations_operator_category_id rename to idx_invitations_worker_type_id;

-- ---------------------------------------------------------------------------
-- 3. Canonical helper + rebuilt unique index
-- ---------------------------------------------------------------------------
create or replace function public.worker_type_normalised_name(p_name text)
returns text
language sql
immutable
as $$
  select lower(regexp_replace(coalesce(trim(p_name), ''), '\s+', ' ', 'g'));
$$;

-- Keep the old helper working too (identical body) — it may still be
-- referenced by external SQL.
create or replace function public.operator_category_normalised_name(p_name text)
returns text
language sql
immutable
as $$
  select public.worker_type_normalised_name(p_name);
$$;

drop index if exists uniq_operator_categories_active_name_cost;
create unique index if not exists uniq_worker_types_active_name_cost
  on public.worker_types (
    vineyard_id,
    public.worker_type_normalised_name(name),
    round(cost_per_hour::numeric, 4)
  )
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- 4. soft_delete_worker_type (canonical) + alias
-- ---------------------------------------------------------------------------
create or replace function public.soft_delete_worker_type(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  select vineyard_id into v_vineyard_id from public.worker_types where id = p_id;
  if v_vineyard_id is null then
    raise exception 'Worker type not found';
  end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to delete worker type';
  end if;
  update public.worker_types
  set deleted_at = now(), updated_by = auth.uid()
  where id = p_id;
end;
$function$;

revoke all on function public.soft_delete_worker_type(uuid) from public;
grant execute on function public.soft_delete_worker_type(uuid) to authenticated;

drop function if exists public.soft_delete_operator_category(uuid);
create function public.soft_delete_operator_category(p_id uuid)
returns void
language sql
as $$
  select public.soft_delete_worker_type(p_id);
$$;

revoke all on function public.soft_delete_operator_category(uuid) from public;
grant execute on function public.soft_delete_operator_category(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. upsert_worker_type (canonical) + alias
-- ---------------------------------------------------------------------------
create or replace function public.upsert_worker_type(
  p_vineyard_id uuid,
  p_name text,
  p_cost_per_hour double precision
)
returns setof public.worker_types
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_normalised text := public.worker_type_normalised_name(p_name);
  v_cost double precision := coalesce(p_cost_per_hour, 0);
  v_existing public.worker_types%rowtype;
  v_row public.worker_types%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if not public.has_vineyard_role(p_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to manage worker types';
  end if;

  if v_normalised = '' then
    raise exception 'Worker type name is required';
  end if;

  select * into v_existing
  from public.worker_types
  where vineyard_id = p_vineyard_id
    and deleted_at is null
    and public.worker_type_normalised_name(name) = v_normalised
    and round(cost_per_hour::numeric, 4) = round(v_cost::numeric, 4)
  order by updated_at desc
  limit 1;

  if found then
    update public.worker_types
      set name = trim(p_name),
          updated_by = v_user_id,
          updated_at = now()
      where id = v_existing.id
      returning * into v_row;
    return next v_row;
    return;
  end if;

  insert into public.worker_types (vineyard_id, name, cost_per_hour, created_by, updated_by)
  values (p_vineyard_id, trim(p_name), v_cost, v_user_id, v_user_id)
  returning * into v_row;

  return next v_row;
end;
$function$;

revoke all on function public.upsert_worker_type(uuid, text, double precision) from public;
grant execute on function public.upsert_worker_type(uuid, text, double precision) to authenticated;

drop function if exists public.upsert_operator_category(uuid, text, double precision);
create function public.upsert_operator_category(
  p_vineyard_id uuid,
  p_name text,
  p_cost_per_hour double precision
)
returns setof public.worker_types
language sql
as $$
  select * from public.upsert_worker_type(p_vineyard_id, p_name, p_cost_per_hour);
$$;

revoke all on function public.upsert_operator_category(uuid, text, double precision) from public;
grant execute on function public.upsert_operator_category(uuid, text, double precision) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. merge_worker_types (canonical; now also remaps machine lines) + alias
-- ---------------------------------------------------------------------------
create or replace function public.merge_worker_types(
  p_source_id uuid,
  p_target_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_source public.worker_types%rowtype;
  v_target public.worker_types%rowtype;
  v_trips_remapped int;
  v_members_remapped int;
  v_labour_remapped int;
  v_machine_remapped int;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_source_id = p_target_id then
    raise exception 'Source and target worker types must differ';
  end if;

  select * into v_source from public.worker_types where id = p_source_id;
  if not found then
    raise exception 'Source worker type not found';
  end if;

  select * into v_target from public.worker_types where id = p_target_id;
  if not found then
    raise exception 'Target worker type not found';
  end if;

  if v_source.vineyard_id <> v_target.vineyard_id then
    raise exception 'Worker types must belong to the same vineyard';
  end if;

  if v_target.deleted_at is not null then
    raise exception 'Target worker type is archived';
  end if;

  if not public.has_vineyard_role(v_source.vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to merge worker types';
  end if;

  with updated as (
    update public.trips
      set worker_type_id = p_target_id
      where worker_type_id = p_source_id
      returning 1
  ) select count(*) into v_trips_remapped from updated;

  with updated as (
    update public.vineyard_members
      set worker_type_id = p_target_id
      where worker_type_id = p_source_id
      returning 1
  ) select count(*) into v_members_remapped from updated;

  with updated as (
    update public.work_task_labour_lines
      set worker_type_id = p_target_id
      where worker_type_id = p_source_id
      returning 1
  ) select count(*) into v_labour_remapped from updated;

  with updated as (
    update public.work_task_machine_lines
      set worker_type_id = p_target_id
      where worker_type_id = p_source_id
      returning 1
  ) select count(*) into v_machine_remapped from updated;

  update public.worker_types
    set deleted_at = coalesce(deleted_at, now()),
        updated_by = v_user_id
    where id = p_source_id;

  insert into public.audit_events(vineyard_id, user_id, action, entity_type, entity_id, details)
  values (
    v_source.vineyard_id,
    v_user_id,
    'merge_worker_types',
    'worker_type',
    p_source_id,
    'Merged into ' || p_target_id::text ||
      ' (trips=' || v_trips_remapped ||
      ', members=' || v_members_remapped ||
      ', labour_lines=' || v_labour_remapped ||
      ', machine_lines=' || v_machine_remapped || ')'
  );

  return json_build_object(
    'success', true,
    'source_id', p_source_id,
    'target_id', p_target_id,
    'trips_remapped', v_trips_remapped,
    'members_remapped', v_members_remapped,
    'labour_lines_remapped', v_labour_remapped,
    'machine_lines_remapped', v_machine_remapped
  );
end;
$function$;

revoke all on function public.merge_worker_types(uuid, uuid) from public;
grant execute on function public.merge_worker_types(uuid, uuid) to authenticated;

drop function if exists public.merge_operator_categories(uuid, uuid);
create function public.merge_operator_categories(
  p_source_id uuid,
  p_target_id uuid
)
returns json
language sql
as $$
  select public.merge_worker_types(p_source_id, p_target_id);
$$;

revoke all on function public.merge_operator_categories(uuid, uuid) from public;
grant execute on function public.merge_operator_categories(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. update_member_worker_type (canonical) + alias
-- ---------------------------------------------------------------------------
create or replace function public.update_member_worker_type(
  p_vineyard_id uuid,
  p_user_id uuid,
  p_worker_type_id uuid
)
returns setof public.vineyard_members
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_caller uuid := auth.uid();
  v_row public.vineyard_members%rowtype;
begin
  if v_caller is null then
    raise exception 'Authentication required';
  end if;

  if not public.has_vineyard_role(p_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to update member worker type';
  end if;

  if p_worker_type_id is not null then
    if not exists (
      select 1
      from public.worker_types
      where id = p_worker_type_id
        and vineyard_id = p_vineyard_id
        and deleted_at is null
    ) then
      raise exception 'Worker type not found for this vineyard';
    end if;
  end if;

  update public.vineyard_members
    set worker_type_id = p_worker_type_id
    where vineyard_id = p_vineyard_id
      and user_id = p_user_id
    returning * into v_row;

  if not found then
    raise exception 'Member not found in this vineyard';
  end if;

  return next v_row;
end;
$function$;

revoke all on function public.update_member_worker_type(uuid, uuid, uuid) from public;
grant execute on function public.update_member_worker_type(uuid, uuid, uuid) to authenticated;

drop function if exists public.update_member_operator_category(uuid, uuid, uuid);
create function public.update_member_operator_category(
  p_vineyard_id uuid,
  p_user_id uuid,
  p_operator_category_id uuid
)
returns setof public.vineyard_members
language sql
as $$
  select * from public.update_member_worker_type(p_vineyard_id, p_user_id, p_operator_category_id);
$$;

revoke all on function public.update_member_operator_category(uuid, uuid, uuid) from public;
grant execute on function public.update_member_operator_category(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. accept_invitation — same behaviour (081), renamed references
-- ---------------------------------------------------------------------------
create or replace function public.accept_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_invitation public.invitations%rowtype;
  v_user_id uuid;
  v_user_email text;
  v_type_valid boolean;
  v_resolved_type uuid;
  v_already_member boolean;
begin
  v_user_id := auth.uid();
  v_user_email := lower(coalesce(auth.jwt() ->> 'email', ''));

  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select *
  into v_invitation
  from public.invitations
  where id = p_invitation_id
  for update;

  if not found then
    raise exception 'Invitation not found';
  end if;

  if v_invitation.status <> 'pending' then
    raise exception 'Invitation is not pending';
  end if;

  if v_invitation.expires_at is not null and v_invitation.expires_at < now() then
    update public.invitations
    set status = 'expired'
    where id = p_invitation_id;
    raise exception 'Invitation has expired';
  end if;

  if v_user_email = '' or v_user_email <> lower(v_invitation.email) then
    raise exception 'Invitation email does not match authenticated user';
  end if;

  -- Idempotent no-op when the caller is already a member (081 guard).
  select exists(
    select 1
    from public.vineyard_members
    where vineyard_id = v_invitation.vineyard_id
      and user_id = v_user_id
  ) into v_already_member;

  if v_already_member then
    update public.invitations
    set status = 'accepted'
    where id = p_invitation_id;
    return;
  end if;

  insert into public.profiles (id, email)
  values (v_user_id, v_user_email)
  on conflict (id) do update
  set email = coalesce(nullif(excluded.email, ''), public.profiles.email);

  v_resolved_type := null;
  if v_invitation.worker_type_id is not null then
    select true
    into v_type_valid
    from public.worker_types
    where id = v_invitation.worker_type_id
      and vineyard_id = v_invitation.vineyard_id
      and deleted_at is null;
    if coalesce(v_type_valid, false) then
      v_resolved_type := v_invitation.worker_type_id;
    end if;
  end if;

  insert into public.vineyard_members (vineyard_id, user_id, role, worker_type_id)
  values (v_invitation.vineyard_id, v_user_id, v_invitation.role, v_resolved_type)
  on conflict (vineyard_id, user_id)
  do update set
    role = excluded.role,
    worker_type_id = coalesce(excluded.worker_type_id, public.vineyard_members.worker_type_id);

  update public.invitations
  set status = 'accepted'
  where id = p_invitation_id;
end;
$function$;

revoke all on function public.accept_invitation(uuid) from public;
grant execute on function public.accept_invitation(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. create_invitation — SAME signature (portal + apps keep calling it with
--    p_operator_category_id), renamed internal references
-- ---------------------------------------------------------------------------
create or replace function public.create_invitation(
  p_vineyard_id uuid,
  p_email text,
  p_role text,
  p_operator_category_id uuid default null,
  p_expires_at timestamptz default null
)
returns setof public.invitations
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_normalised_email text;
  v_invitation public.invitations%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if not public.has_vineyard_role(p_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to invite members';
  end if;

  v_normalised_email := lower(trim(coalesce(p_email, '')));
  if v_normalised_email = '' then
    raise exception 'Invitation email is required';
  end if;

  if p_role is null or p_role not in ('manager', 'supervisor', 'operator') then
    raise exception 'Invalid role for invitation. Use transfer_vineyard_ownership to assign ownership.';
  end if;

  if p_operator_category_id is not null then
    if not exists (
      select 1
      from public.worker_types
      where id = p_operator_category_id
        and vineyard_id = p_vineyard_id
        and deleted_at is null
    ) then
      raise exception 'Worker type not found for this vineyard';
    end if;
  end if;

  update public.invitations
    set status = 'cancelled'
    where vineyard_id = p_vineyard_id
      and lower(email) = v_normalised_email
      and status = 'pending';

  insert into public.invitations (vineyard_id, email, role, worker_type_id, expires_at, invited_by)
  values (p_vineyard_id, v_normalised_email, p_role, p_operator_category_id, p_expires_at, v_user_id)
  returning * into v_invitation;

  return next v_invitation;
end;
$function$;

revoke all on function public.create_invitation(uuid, text, text, uuid, timestamptz) from public;
grant execute on function public.create_invitation(uuid, text, text, uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. get_vineyard_team_members — returns BOTH old and new column names so
--     the apps (worker_type_*) and the portal (operator_category_*) both work.
-- ---------------------------------------------------------------------------
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
  operator_category_name text,
  worker_type_id uuid,
  worker_type_name text
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
    vm.worker_type_id as operator_category_id,
    wt.name          as operator_category_name,
    vm.worker_type_id as worker_type_id,
    wt.name          as worker_type_name
  from public.vineyard_members vm
  left join public.profiles p on p.id = vm.user_id
  left join auth.users au on au.id = vm.user_id
  left join public.worker_types wt
    on wt.id = vm.worker_type_id
   and wt.deleted_at is null
  where vm.vineyard_id = p_vineyard_id
  order by vm.joined_at asc, vm.id asc;
end;
$$;

revoke all on function public.get_vineyard_team_members(uuid) from public;
grant execute on function public.get_vineyard_team_members(uuid) to authenticated;

comment on function public.get_vineyard_team_members(uuid) is
  $c$Returns display-safe team member info for a vineyard the caller is a member of. Includes both worker_type_id/worker_type_name (canonical) and operator_category_id/operator_category_name (legacy aliases for the portal).$c$;

-- ---------------------------------------------------------------------------
-- 11. Compatibility view under the old table name (portal keeps working).
--     security_invoker so the base table RLS applies to the querying user.
--     Single-table SELECT * view => auto-updatable (insert/update pass through).
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.operator_categories') is null then
    execute 'create view public.operator_categories with (security_invoker = on) as select * from public.worker_types';
  end if;
end $$;

grant select, insert, update on public.operator_categories to authenticated;
grant all on public.operator_categories to service_role;

comment on view public.operator_categories is
  'Legacy compatibility view over public.worker_types. Remove once the web portal has migrated to worker_types.';

commit;

-- ---------------------------------------------------------------------------
-- Verification queries (run manually after the migration)
-- ---------------------------------------------------------------------------
-- select count(*) from public.worker_types;
-- select count(*) from public.operator_categories;             -- same count via the view
-- select worker_type_id from public.trips limit 1;
-- select worker_type_id, worker_type_name from public.get_vineyard_team_members('<vineyard_id>') limit 5;

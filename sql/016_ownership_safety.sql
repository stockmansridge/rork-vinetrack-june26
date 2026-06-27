-- 016_ownership_safety.sql
-- Ownership transfer, last-owner protection, account deletion preflight,
-- account deletion request, and vineyard archive.

-- ---------------------------------------------------------------------------
-- A. Last owner protection trigger
-- ---------------------------------------------------------------------------
-- Prevents removing or downgrading the last 'owner' membership of any
-- vineyard. Runs before update/delete on vineyard_members so RLS policies
-- and direct RPC calls cannot accidentally orphan a vineyard.
create or replace function public.prevent_last_owner_loss()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vineyard_id uuid;
  v_remaining_owners int;
begin
  if TG_OP = 'DELETE' then
    if OLD.role = 'owner' then
      v_vineyard_id := OLD.vineyard_id;
      select count(*) into v_remaining_owners
      from public.vineyard_members
      where vineyard_id = v_vineyard_id
        and role = 'owner'
        and id <> OLD.id;
      if v_remaining_owners = 0 then
        raise exception 'Cannot remove the last owner of the vineyard. Transfer ownership first.'
          using errcode = 'P0001';
      end if;
    end if;
    return OLD;
  elsif TG_OP = 'UPDATE' then
    if OLD.role = 'owner' and NEW.role <> 'owner' then
      v_vineyard_id := OLD.vineyard_id;
      select count(*) into v_remaining_owners
      from public.vineyard_members
      where vineyard_id = v_vineyard_id
        and role = 'owner'
        and id <> OLD.id;
      if v_remaining_owners = 0 then
        raise exception 'Cannot downgrade the last owner of the vineyard. Transfer ownership first.'
          using errcode = 'P0001';
      end if;
    end if;
    return NEW;
  end if;
  return null;
end;
$$;

drop trigger if exists vineyard_members_last_owner_guard on public.vineyard_members;
create trigger vineyard_members_last_owner_guard
before update or delete on public.vineyard_members
for each row execute function public.prevent_last_owner_loss();

-- ---------------------------------------------------------------------------
-- B. Ownership transfer RPC
-- ---------------------------------------------------------------------------
create or replace function public.transfer_vineyard_ownership(
  p_vineyard_id uuid,
  p_new_owner_id uuid,
  p_remove_old_owner boolean default false
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_caller_role text;
  v_new_owner_role text;
begin
  if v_caller is null then
    raise exception 'Authentication required';
  end if;

  if p_new_owner_id = v_caller then
    raise exception 'Cannot transfer ownership to yourself';
  end if;

  select role into v_caller_role
  from public.vineyard_members
  where vineyard_id = p_vineyard_id and user_id = v_caller;

  if v_caller_role is null or v_caller_role <> 'owner' then
    raise exception 'Only the current owner can transfer ownership';
  end if;

  select role into v_new_owner_role
  from public.vineyard_members
  where vineyard_id = p_vineyard_id and user_id = p_new_owner_id;

  if v_new_owner_role is null then
    raise exception 'New owner must be an active member of the vineyard. Pending invitations cannot become owner until accepted.';
  end if;

  -- Promote new owner first to ensure the vineyard always has an owner.
  update public.vineyard_members
  set role = 'owner'
  where vineyard_id = p_vineyard_id and user_id = p_new_owner_id;

  if p_remove_old_owner then
    delete from public.vineyard_members
    where vineyard_id = p_vineyard_id and user_id = v_caller;
  else
    update public.vineyard_members
    set role = 'manager'
    where vineyard_id = p_vineyard_id and user_id = v_caller;
  end if;

  update public.vineyards
  set owner_id = p_new_owner_id
  where id = p_vineyard_id;

  insert into public.audit_events(vineyard_id, user_id, action, entity_type, entity_id, details)
  values (
    p_vineyard_id,
    v_caller,
    'transfer_ownership',
    'vineyard',
    p_vineyard_id,
    'New owner: ' || p_new_owner_id::text ||
      case when p_remove_old_owner then ' (old owner removed)' else ' (old owner demoted to manager)' end
  );

  return json_build_object(
    'success', true,
    'vineyard_id', p_vineyard_id,
    'new_owner_id', p_new_owner_id,
    'old_owner_removed', p_remove_old_owner
  );
end;
$$;

revoke all on function public.transfer_vineyard_ownership(uuid, uuid, boolean) from public;
grant execute on function public.transfer_vineyard_ownership(uuid, uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- C. Account deletion preflight RPC
-- ---------------------------------------------------------------------------
create or replace function public.account_deletion_preflight()
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_user_id uuid := auth.uid();
  v_owned json;
  v_blockers int;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(json_agg(row_to_json(t) order by t.vineyard_name), '[]'::json)
  into v_owned
  from (
    select
      v.id as vineyard_id,
      v.name as vineyard_name,
      (
        select count(*)::int
        from public.vineyard_members vm2
        where vm2.vineyard_id = v.id and vm2.user_id <> v_user_id
      ) as other_active_members,
      (
        (
          select count(*)
          from public.vineyard_members vm2
          where vm2.vineyard_id = v.id and vm2.user_id <> v_user_id
        ) > 0
      ) as transfer_required
    from public.vineyards v
    join public.vineyard_members vm on vm.vineyard_id = v.id
    where vm.user_id = v_user_id
      and vm.role = 'owner'
      and v.deleted_at is null
  ) t;

  select count(*)::int into v_blockers
  from public.vineyards v
  join public.vineyard_members vm on vm.vineyard_id = v.id
  where vm.user_id = v_user_id
    and vm.role = 'owner'
    and v.deleted_at is null
    and exists (
      select 1 from public.vineyard_members other
      where other.vineyard_id = v.id and other.user_id <> v_user_id
    );

  return json_build_object(
    'owned_vineyards', v_owned,
    'blocker_count', v_blockers,
    'safe_to_delete', v_blockers = 0
  );
end;
$$;

revoke all on function public.account_deletion_preflight() from public;
grant execute on function public.account_deletion_preflight() to authenticated;

-- ---------------------------------------------------------------------------
-- D. Account deletion request (manual review)
-- ---------------------------------------------------------------------------
create table if not exists public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  email text,
  reason text,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'completed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_account_deletion_requests_user_id
  on public.account_deletion_requests (user_id);
create index if not exists idx_account_deletion_requests_status
  on public.account_deletion_requests (status);

create or replace trigger account_deletion_requests_set_updated_at
before update on public.account_deletion_requests
for each row execute function public.set_updated_at();

alter table public.account_deletion_requests enable row level security;

drop policy if exists "deletion_requests_select_own" on public.account_deletion_requests;
create policy "deletion_requests_select_own"
on public.account_deletion_requests for select
to authenticated
using (user_id = auth.uid());

drop policy if exists "deletion_requests_insert_blocked" on public.account_deletion_requests;
create policy "deletion_requests_insert_blocked"
on public.account_deletion_requests for insert
to authenticated
with check (false);

drop policy if exists "deletion_requests_no_client_update" on public.account_deletion_requests;
create policy "deletion_requests_no_client_update"
on public.account_deletion_requests for update
to authenticated
using (false) with check (false);

drop policy if exists "deletion_requests_no_client_delete" on public.account_deletion_requests;
create policy "deletion_requests_no_client_delete"
on public.account_deletion_requests for delete
to authenticated
using (false);

create or replace function public.submit_account_deletion_request(p_reason text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_blockers int;
  v_request_id uuid;
  v_existing uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select count(*)::int into v_blockers
  from public.vineyards v
  join public.vineyard_members vm on vm.vineyard_id = v.id
  where vm.user_id = v_user_id
    and vm.role = 'owner'
    and v.deleted_at is null
    and exists (
      select 1 from public.vineyard_members other
      where other.vineyard_id = v.id and other.user_id <> v_user_id
    );

  if v_blockers > 0 then
    return json_build_object(
      'submitted', false,
      'blocker_count', v_blockers,
      'message', 'You own vineyards that other people use. Transfer ownership before requesting account deletion.'
    );
  end if;

  -- Reuse an existing pending request to avoid spam.
  select id into v_existing
  from public.account_deletion_requests
  where user_id = v_user_id and status = 'pending'
  limit 1;

  if v_existing is not null then
    update public.account_deletion_requests
    set reason = coalesce(p_reason, reason)
    where id = v_existing;
    return json_build_object('submitted', true, 'request_id', v_existing, 'reused', true);
  end if;

  insert into public.account_deletion_requests (user_id, email, reason)
  values (v_user_id, v_email, p_reason)
  returning id into v_request_id;

  return json_build_object('submitted', true, 'request_id', v_request_id, 'reused', false);
end;
$$;

revoke all on function public.submit_account_deletion_request(text) from public;
grant execute on function public.submit_account_deletion_request(text) to authenticated;

-- ---------------------------------------------------------------------------
-- E. Archive vineyard RPC (owner-only soft delete)
-- ---------------------------------------------------------------------------
create or replace function public.archive_vineyard(p_vineyard_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_role text;
begin
  if v_caller is null then
    raise exception 'Authentication required';
  end if;

  select role into v_role
  from public.vineyard_members
  where vineyard_id = p_vineyard_id and user_id = v_caller;

  if v_role is null or v_role <> 'owner' then
    raise exception 'Only the owner can archive a vineyard';
  end if;

  update public.vineyards
  set deleted_at = coalesce(deleted_at, now())
  where id = p_vineyard_id;

  insert into public.audit_events(vineyard_id, user_id, action, entity_type, entity_id)
  values (p_vineyard_id, v_caller, 'archive', 'vineyard', p_vineyard_id);

  return json_build_object('success', true, 'vineyard_id', p_vineyard_id);
end;
$$;

revoke all on function public.archive_vineyard(uuid) from public;
grant execute on function public.archive_vineyard(uuid) to authenticated;

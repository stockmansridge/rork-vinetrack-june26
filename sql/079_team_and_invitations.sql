-- 079_team_and_invitations.sql
-- Shared backend for Team & Invitations (iOS + Lovable portal).
--
-- This migration:
--   1. Adds normalised-name helpers + partial unique index on operator_categories
--      so future duplicates cannot be created.
--   2. Performs a one-time dedupe of existing duplicate active operator
--      categories, remapping references in trips, vineyard_members and
--      work_task_labour_lines before soft-deleting the duplicates.
--   3. Adds invitations.operator_category_id and copies it into
--      vineyard_members.operator_category_id on accept_invitation.
--   4. Adds SECURITY DEFINER RPCs that wrap the existing iOS-source-of-truth
--      behaviour so the Lovable portal can call the same primitives:
--        - upsert_operator_category
--        - merge_operator_categories
--        - create_invitation
--        - cancel_invitation
--        - resend_invitation
--        - list_vineyard_invitations
--        - update_member_role
--        - update_member_operator_category
--        - remove_member
--
-- Notes / decisions reflected here:
--   * iOS direct INSERT into public.invitations keeps working (RLS unchanged).
--   * No email delivery side effects (resend just re-pendings + extends expiry).
--   * Member removal stays hard-delete (last-owner guard from 016 still enforced).
--   * Roles: 'owner', 'manager', 'supervisor', 'operator'. Inviting 'owner' is
--     blocked through create_invitation (CHECK on table still permits it, but
--     ownership must go through transfer_vineyard_ownership).
--   * update_member_role: owner can change any non-owner row; manager can
--     change non-owner rows. Matches current iOS RLS in 001.
--   * cost_per_hour is double precision NOT NULL default 0 — no NULL handling
--     required, but rounded to 4dp in the normalised expression to avoid
--     float-equality drift.

-- ---------------------------------------------------------------------------
-- A. Helpers
-- ---------------------------------------------------------------------------

-- Normalise operator category names for dedupe: trim, collapse whitespace,
-- lowercase. Returns '' for null/blank input so the partial unique index
-- below treats blank-named categories as equal (they should not be created
-- in normal flows anyway).
create or replace function public.operator_category_normalised_name(p_name text)
returns text
language sql
immutable
as $$
  select lower(regexp_replace(coalesce(trim(p_name), ''), '\s+', ' ', 'g'));
$$;

-- ---------------------------------------------------------------------------
-- B. One-time dedupe of existing duplicate operator_categories
-- ---------------------------------------------------------------------------
-- For each (vineyard_id, normalised_name, rounded cost_per_hour) group of
-- active (deleted_at is null) categories with >1 row, keep the most recently
-- updated row, remap all known foreign references to it, then soft-delete the
-- duplicates.
do $$
declare
  v_group record;
  v_keep_id uuid;
  v_duplicate_ids uuid[];
begin
  for v_group in
    select
      vineyard_id,
      public.operator_category_normalised_name(name) as norm_name,
      round(cost_per_hour::numeric, 4) as norm_cost,
      array_agg(id order by updated_at desc, created_at desc, id) as ids
    from public.operator_categories
    where deleted_at is null
    group by 1, 2, 3
    having count(*) > 1
  loop
    v_keep_id := v_group.ids[1];
    v_duplicate_ids := v_group.ids[2:array_length(v_group.ids, 1)];

    update public.trips
      set operator_category_id = v_keep_id
      where operator_category_id = any(v_duplicate_ids);

    update public.vineyard_members
      set operator_category_id = v_keep_id
      where operator_category_id = any(v_duplicate_ids);

    update public.work_task_labour_lines
      set operator_category_id = v_keep_id
      where operator_category_id = any(v_duplicate_ids);

    update public.operator_categories
      set deleted_at = now()
      where id = any(v_duplicate_ids)
        and deleted_at is null;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- C. Partial unique index — prevents future active duplicates
-- ---------------------------------------------------------------------------
create unique index if not exists uniq_operator_categories_active_name_cost
  on public.operator_categories (
    vineyard_id,
    public.operator_category_normalised_name(name),
    round(cost_per_hour::numeric, 4)
  )
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- D. upsert_operator_category
-- ---------------------------------------------------------------------------
-- Returns the operator_categories row. If an active row already exists with
-- the same vineyard_id + normalised name + cost_per_hour, it is updated (name
-- spelling refreshed, updated_by/updated_at bumped) and returned. Otherwise a
-- new row is inserted.
create or replace function public.upsert_operator_category(
  p_vineyard_id uuid,
  p_name text,
  p_cost_per_hour double precision
)
returns setof public.operator_categories
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_normalised text := public.operator_category_normalised_name(p_name);
  v_cost double precision := coalesce(p_cost_per_hour, 0);
  v_existing public.operator_categories%rowtype;
  v_row public.operator_categories%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if not public.has_vineyard_role(p_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to manage operator categories';
  end if;

  if v_normalised = '' then
    raise exception 'Operator category name is required';
  end if;

  select * into v_existing
  from public.operator_categories
  where vineyard_id = p_vineyard_id
    and deleted_at is null
    and public.operator_category_normalised_name(name) = v_normalised
    and round(cost_per_hour::numeric, 4) = round(v_cost::numeric, 4)
  order by updated_at desc
  limit 1;

  if found then
    update public.operator_categories
      set name = trim(p_name),
          updated_by = v_user_id,
          updated_at = now()
      where id = v_existing.id
      returning * into v_row;
    return next v_row;
    return;
  end if;

  insert into public.operator_categories (vineyard_id, name, cost_per_hour, created_by, updated_by)
  values (p_vineyard_id, trim(p_name), v_cost, v_user_id, v_user_id)
  returning * into v_row;

  return next v_row;
end;
$function$;

revoke all on function public.upsert_operator_category(uuid, text, double precision) from public;
grant execute on function public.upsert_operator_category(uuid, text, double precision) to authenticated;

-- ---------------------------------------------------------------------------
-- E. merge_operator_categories
-- ---------------------------------------------------------------------------
-- Remap trips / vineyard_members / work_task_labour_lines references from
-- p_source_id into p_target_id, then soft-delete the source row. Both rows
-- must belong to the same vineyard.
create or replace function public.merge_operator_categories(
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
  v_source public.operator_categories%rowtype;
  v_target public.operator_categories%rowtype;
  v_trips_remapped int;
  v_members_remapped int;
  v_labour_remapped int;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_source_id = p_target_id then
    raise exception 'Source and target operator categories must differ';
  end if;

  select * into v_source from public.operator_categories where id = p_source_id;
  if not found then
    raise exception 'Source operator category not found';
  end if;

  select * into v_target from public.operator_categories where id = p_target_id;
  if not found then
    raise exception 'Target operator category not found';
  end if;

  if v_source.vineyard_id <> v_target.vineyard_id then
    raise exception 'Operator categories must belong to the same vineyard';
  end if;

  if v_target.deleted_at is not null then
    raise exception 'Target operator category is archived';
  end if;

  if not public.has_vineyard_role(v_source.vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to merge operator categories';
  end if;

  with updated as (
    update public.trips
      set operator_category_id = p_target_id
      where operator_category_id = p_source_id
      returning 1
  ) select count(*) into v_trips_remapped from updated;

  with updated as (
    update public.vineyard_members
      set operator_category_id = p_target_id
      where operator_category_id = p_source_id
      returning 1
  ) select count(*) into v_members_remapped from updated;

  with updated as (
    update public.work_task_labour_lines
      set operator_category_id = p_target_id
      where operator_category_id = p_source_id
      returning 1
  ) select count(*) into v_labour_remapped from updated;

  update public.operator_categories
    set deleted_at = coalesce(deleted_at, now()),
        updated_by = v_user_id
    where id = p_source_id;

  insert into public.audit_events(vineyard_id, user_id, action, entity_type, entity_id, details)
  values (
    v_source.vineyard_id,
    v_user_id,
    'merge_operator_categories',
    'operator_category',
    p_source_id,
    'Merged into ' || p_target_id::text ||
      ' (trips=' || v_trips_remapped ||
      ', members=' || v_members_remapped ||
      ', labour_lines=' || v_labour_remapped || ')'
  );

  return json_build_object(
    'success', true,
    'source_id', p_source_id,
    'target_id', p_target_id,
    'trips_remapped', v_trips_remapped,
    'members_remapped', v_members_remapped,
    'labour_lines_remapped', v_labour_remapped
  );
end;
$function$;

revoke all on function public.merge_operator_categories(uuid, uuid) from public;
grant execute on function public.merge_operator_categories(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- F. invitations.operator_category_id
-- ---------------------------------------------------------------------------
alter table public.invitations
  add column if not exists operator_category_id uuid null
    references public.operator_categories(id) on delete set null;

create index if not exists idx_invitations_operator_category_id
  on public.invitations (operator_category_id);

-- ---------------------------------------------------------------------------
-- G. accept_invitation — copy operator_category_id into membership
-- ---------------------------------------------------------------------------
-- Re-creates the function to copy the invitation's operator_category_id into
-- vineyard_members.operator_category_id when present and still valid for the
-- target vineyard. Unknown / soft-deleted categories are simply ignored
-- (membership is still created without one).
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
  v_category_valid boolean;
  v_resolved_category uuid;
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

  insert into public.profiles (id, email)
  values (v_user_id, v_user_email)
  on conflict (id) do update
  set email = coalesce(nullif(excluded.email, ''), public.profiles.email);

  v_resolved_category := null;
  if v_invitation.operator_category_id is not null then
    select true
    into v_category_valid
    from public.operator_categories
    where id = v_invitation.operator_category_id
      and vineyard_id = v_invitation.vineyard_id
      and deleted_at is null;
    if coalesce(v_category_valid, false) then
      v_resolved_category := v_invitation.operator_category_id;
    end if;
  end if;

  insert into public.vineyard_members (vineyard_id, user_id, role, operator_category_id)
  values (v_invitation.vineyard_id, v_user_id, v_invitation.role, v_resolved_category)
  on conflict (vineyard_id, user_id)
  do update set
    role = excluded.role,
    operator_category_id = coalesce(excluded.operator_category_id, public.vineyard_members.operator_category_id);

  update public.invitations
  set status = 'accepted'
  where id = p_invitation_id;
end;
$function$;

revoke all on function public.accept_invitation(uuid) from public;
grant execute on function public.accept_invitation(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- H. create_invitation
-- ---------------------------------------------------------------------------
-- Mirrors current iOS behaviour: cancels any prior pending row for the same
-- vineyard + lower(email), then inserts a new pending row. Optional
-- operator_category_id is validated to belong to the same vineyard and not
-- be soft-deleted. Inviting 'owner' is disallowed.
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
      from public.operator_categories
      where id = p_operator_category_id
        and vineyard_id = p_vineyard_id
        and deleted_at is null
    ) then
      raise exception 'Operator category not found for this vineyard';
    end if;
  end if;

  update public.invitations
    set status = 'cancelled'
    where vineyard_id = p_vineyard_id
      and lower(email) = v_normalised_email
      and status = 'pending';

  insert into public.invitations (vineyard_id, email, role, operator_category_id, expires_at, invited_by)
  values (p_vineyard_id, v_normalised_email, p_role, p_operator_category_id, p_expires_at, v_user_id)
  returning * into v_invitation;

  return next v_invitation;
end;
$function$;

revoke all on function public.create_invitation(uuid, text, text, uuid, timestamptz) from public;
grant execute on function public.create_invitation(uuid, text, text, uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- I. cancel_invitation
-- ---------------------------------------------------------------------------
create or replace function public.cancel_invitation(p_invitation_id uuid)
returns setof public.invitations
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_invitation public.invitations%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_invitation
  from public.invitations
  where id = p_invitation_id
  for update;

  if not found then
    raise exception 'Invitation not found';
  end if;

  if not public.has_vineyard_role(v_invitation.vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to cancel invitations';
  end if;

  if v_invitation.status <> 'pending' then
    return next v_invitation;
    return;
  end if;

  update public.invitations
    set status = 'cancelled'
    where id = p_invitation_id
    returning * into v_invitation;

  return next v_invitation;
end;
$function$;

revoke all on function public.cancel_invitation(uuid) from public;
grant execute on function public.cancel_invitation(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- J. resend_invitation
-- ---------------------------------------------------------------------------
-- No email side-effect today. Marks an existing invitation as pending again
-- and extends expires_at (defaults to 14 days from now if not provided).
create or replace function public.resend_invitation(
  p_invitation_id uuid,
  p_expires_at timestamptz default null
)
returns setof public.invitations
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_invitation public.invitations%rowtype;
  v_new_expiry timestamptz;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_invitation
  from public.invitations
  where id = p_invitation_id
  for update;

  if not found then
    raise exception 'Invitation not found';
  end if;

  if not public.has_vineyard_role(v_invitation.vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to resend invitations';
  end if;

  if v_invitation.status = 'accepted' then
    raise exception 'Invitation has already been accepted';
  end if;

  -- Cancel any other pending row for the same email + vineyard so the partial
  -- unique index uniq_invitations_pending_per_email is satisfied.
  update public.invitations
    set status = 'cancelled'
    where vineyard_id = v_invitation.vineyard_id
      and lower(email) = lower(v_invitation.email)
      and status = 'pending'
      and id <> p_invitation_id;

  v_new_expiry := coalesce(p_expires_at, now() + interval '14 days');

  update public.invitations
    set status = 'pending',
        expires_at = v_new_expiry
    where id = p_invitation_id
    returning * into v_invitation;

  return next v_invitation;
end;
$function$;

revoke all on function public.resend_invitation(uuid, timestamptz) from public;
grant execute on function public.resend_invitation(uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- K. list_vineyard_invitations
-- ---------------------------------------------------------------------------
-- Returns all invitations for a vineyard (any status) for owners/managers.
-- iOS can keep its existing select; this RPC is here for portal symmetry.
create or replace function public.list_vineyard_invitations(p_vineyard_id uuid)
returns setof public.invitations
language plpgsql
security definer
set search_path = public
stable
as $function$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not public.has_vineyard_role(p_vineyard_id, array['owner', 'manager']) then
    raise exception 'Insufficient permissions to list invitations';
  end if;

  return query
    select *
    from public.invitations
    where vineyard_id = p_vineyard_id
    order by created_at desc;
end;
$function$;

revoke all on function public.list_vineyard_invitations(uuid) from public;
grant execute on function public.list_vineyard_invitations(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- L. update_member_role
-- ---------------------------------------------------------------------------
-- Owner can change any non-owner member's role to any non-owner role.
-- Manager can change any non-owner member's role to any non-owner role.
-- Owner role assignment must go through transfer_vineyard_ownership.
-- Matches current iOS RLS in 001_backend_foundation.sql.
create or replace function public.update_member_role(
  p_vineyard_id uuid,
  p_user_id uuid,
  p_role text
)
returns setof public.vineyard_members
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_caller uuid := auth.uid();
  v_caller_role text;
  v_member public.vineyard_members%rowtype;
  v_row public.vineyard_members%rowtype;
begin
  if v_caller is null then
    raise exception 'Authentication required';
  end if;

  v_caller_role := public.vineyard_role(p_vineyard_id);
  if v_caller_role is null or v_caller_role not in ('owner', 'manager') then
    raise exception 'Insufficient permissions to update member role';
  end if;

  if p_role not in ('manager', 'supervisor', 'operator') then
    raise exception 'Invalid role. Use transfer_vineyard_ownership to assign ownership.';
  end if;

  select * into v_member
  from public.vineyard_members
  where vineyard_id = p_vineyard_id and user_id = p_user_id;

  if not found then
    raise exception 'Member not found in this vineyard';
  end if;

  if v_member.role = 'owner' then
    raise exception 'Cannot change the owner role. Use transfer_vineyard_ownership.';
  end if;

  update public.vineyard_members
    set role = p_role
    where vineyard_id = p_vineyard_id
      and user_id = p_user_id
    returning * into v_row;

  return next v_row;
end;
$function$;

revoke all on function public.update_member_role(uuid, uuid, text) from public;
grant execute on function public.update_member_role(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- M. update_member_operator_category
-- ---------------------------------------------------------------------------
create or replace function public.update_member_operator_category(
  p_vineyard_id uuid,
  p_user_id uuid,
  p_operator_category_id uuid
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
    raise exception 'Insufficient permissions to update member operator category';
  end if;

  if p_operator_category_id is not null then
    if not exists (
      select 1
      from public.operator_categories
      where id = p_operator_category_id
        and vineyard_id = p_vineyard_id
        and deleted_at is null
    ) then
      raise exception 'Operator category not found for this vineyard';
    end if;
  end if;

  update public.vineyard_members
    set operator_category_id = p_operator_category_id
    where vineyard_id = p_vineyard_id
      and user_id = p_user_id
    returning * into v_row;

  if not found then
    raise exception 'Member not found in this vineyard';
  end if;

  return next v_row;
end;
$function$;

revoke all on function public.update_member_operator_category(uuid, uuid, uuid) from public;
grant execute on function public.update_member_operator_category(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- N. remove_member
-- ---------------------------------------------------------------------------
-- Hard-deletes a vineyard_members row. The existing prevent_last_owner_loss
-- trigger (016_ownership_safety.sql) still applies. Owners and managers can
-- remove non-owner members.
create or replace function public.remove_member(
  p_vineyard_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_caller uuid := auth.uid();
  v_caller_role text;
  v_member public.vineyard_members%rowtype;
begin
  if v_caller is null then
    raise exception 'Authentication required';
  end if;

  v_caller_role := public.vineyard_role(p_vineyard_id);
  if v_caller_role is null or v_caller_role not in ('owner', 'manager') then
    raise exception 'Insufficient permissions to remove member';
  end if;

  select * into v_member
  from public.vineyard_members
  where vineyard_id = p_vineyard_id and user_id = p_user_id;

  if not found then
    raise exception 'Member not found in this vineyard';
  end if;

  if v_member.role = 'owner' then
    raise exception 'Cannot remove the owner. Transfer ownership first.';
  end if;

  delete from public.vineyard_members
    where vineyard_id = p_vineyard_id
      and user_id = p_user_id;

  insert into public.audit_events(vineyard_id, user_id, action, entity_type, entity_id, details)
  values (
    p_vineyard_id,
    v_caller,
    'remove_member',
    'vineyard_member',
    p_user_id,
    'Removed user ' || p_user_id::text || ' (role=' || v_member.role || ')'
  );

  return json_build_object(
    'success', true,
    'vineyard_id', p_vineyard_id,
    'user_id', p_user_id,
    'removed_role', v_member.role
  );
end;
$function$;

revoke all on function public.remove_member(uuid, uuid) from public;
grant execute on function public.remove_member(uuid, uuid) to authenticated;

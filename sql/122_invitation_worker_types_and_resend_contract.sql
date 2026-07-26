-- 122_invitation_worker_types_and_resend_contract.sql
-- Align invitation creation and resending across iOS, Android, and the portal.
-- The canonical worker-type argument retains its legacy RPC name for client
-- compatibility, while rows use the current worker_types schema.

begin;

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

  -- Worker types are an operator-only setting. Ignore stale values when a
  -- role changes to manager/supervisor, and verify the selected ID belongs to
  -- this vineyard before an operator invitation can be created.
  if p_role = 'operator' then
    if p_operator_category_id is null then
      raise exception 'A worker type is required when inviting an operator';
    end if;
    if not exists (
      select 1
      from public.worker_types
      where id = p_operator_category_id
        and vineyard_id = p_vineyard_id
        and deleted_at is null
    ) then
      raise exception 'Worker type not found for this vineyard';
    end if;
  else
    p_operator_category_id := null;
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

-- Canonical cross-platform resend contract. This deliberately leaves the
-- historical (uuid, timestamptz) overload in place for already-released apps.
create or replace function public.resend_invitation(
  p_invitation_id uuid,
  p_extend_days integer default 14
)
returns public.invitations
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
  if p_extend_days is null or p_extend_days < 1 or p_extend_days > 365 then
    raise exception 'p_extend_days must be between 1 and 365';
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

  update public.invitations
  set status = 'cancelled'
  where vineyard_id = v_invitation.vineyard_id
    and lower(email) = lower(v_invitation.email)
    and status = 'pending'
    and id <> p_invitation_id;

  update public.invitations
  set status = 'pending',
      expires_at = now() + make_interval(days => p_extend_days)
  where id = p_invitation_id
  returning * into v_invitation;

  return v_invitation;
end;
$function$;

revoke all on function public.resend_invitation(uuid, integer) from public;
grant execute on function public.resend_invitation(uuid, integer) to authenticated;

commit;

-- Live signature verification:
-- select p.proname, pg_get_function_identity_arguments(p.oid) as arguments,
--        pg_get_function_result(p.oid) as return_type
-- from pg_proc p join pg_namespace n on n.oid = p.pronamespace
-- where n.nspname = 'public' and p.proname in ('create_invitation', 'resend_invitation');

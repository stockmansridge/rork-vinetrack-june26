-- 220_invitation_default_worker_type_all_roles.sql
--
-- Invitation Default Worker Type parity (Portal + iOS + Android).
--
-- p_operator_category_id keeps its historical name for deployed-client
-- compatibility, but it now represents the OPTIONAL Default Worker Type for
-- ANY invited role (manager, supervisor, operator). Previously (sql/122):
--   * operator invitations REQUIRED a worker type;
--   * manager/supervisor invitations had the value silently forced to null.
--
-- New contract:
--   * The worker type is optional for every invitable role.
--   * When provided, it must be an active worker type of the invited
--     vineyard; invalid / deleted / cross-vineyard values are REJECTED with
--     an error (never silently nulled), for every role.
--   * No other behaviour changes: permissions, role restrictions (inviting
--     'owner' still goes through transfer_vineyard_ownership), pending-row
--     cancellation, email normalisation and the return shape are identical
--     to sql/122.
--
-- accept_invitation (sql/106) already copies invitations.worker_type_id into
-- vineyard_members.worker_type_id for any role — it needs no change and no
-- client performs a second membership write.
--
-- Signature is UNCHANGED: create_invitation(uuid, text, text, uuid, timestamptz).

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

  -- Default Worker Type is OPTIONAL for every invitable role. When provided
  -- it must be an active worker type of this vineyard; invalid values are
  -- rejected for any role — never silently replaced with null.
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

comment on function public.create_invitation(uuid, text, text, uuid, timestamptz) is
  $c$Creates a vineyard invitation. p_operator_category_id keeps its legacy name but is the OPTIONAL Default Worker Type for ANY invited role; when provided it must be an active worker type of the vineyard (sql/220).$c$;

commit;

-- Live signature verification (should be unchanged):
-- select p.proname, pg_get_function_identity_arguments(p.oid)
-- from pg_proc p join pg_namespace n on n.oid = p.pronamespace
-- where n.nspname = 'public' and p.proname = 'create_invitation';

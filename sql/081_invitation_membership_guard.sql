-- 081_invitation_membership_guard.sql
-- Defensive guard so an invitation cannot create a duplicate / conflicting
-- membership row when the signed-in auth.uid() is already a member of the
-- invited vineyard. Two layers:
--
--   1. Tighten the SELECT policy on public.invitations so already-member
--      rows are not returned to the client. This is what surfaces invites
--      in iOS (PendingInvitationsSheet, BackendVineyardListView) and any
--      future Lovable UI.
--
--   2. Make public.accept_invitation idempotent: if the calling user is
--      already a member of the invited vineyard, mark the invite accepted
--      and return without touching vineyard_members. This protects against
--      a stale client view racing against the SELECT policy.
--
-- This is a "Step 1" defensive fix only. A proper verified email alias
-- model (user_email_aliases + request/confirm verification RPCs) will be
-- added in a follow-up migration. Until that lands, the email-match check
-- in accept_invitation is unchanged.

begin;

-- ---------------------------------------------------------------------------
-- 1. Tighten RLS: hide invites for vineyards the caller already belongs to.
-- ---------------------------------------------------------------------------
drop policy if exists "invitations_select_invited_user" on public.invitations;
create policy "invitations_select_invited_user"
on public.invitations for select
to authenticated
using (
  status = 'pending'
  and lower(coalesce(auth.jwt() ->> 'email', '')) = lower(email)
  and not exists (
    select 1
    from public.vineyard_members vm
    where vm.vineyard_id = invitations.vineyard_id
      and vm.user_id = auth.uid()
  )
);

-- ---------------------------------------------------------------------------
-- 2. accept_invitation: idempotent no-op when caller is already a member.
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
  v_category_valid boolean;
  v_resolved_category uuid;
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

  -- If the caller is already a member of this vineyard (e.g. owner who
  -- received an invite addressed to an alias email), do not touch the
  -- existing membership. Mark the invite accepted so it stops appearing
  -- in pending lists and return.
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

commit;

-- ---------------------------------------------------------------------------
-- Test queries
-- ---------------------------------------------------------------------------
-- A) Confirm an existing-owner alias invite is now hidden by RLS:
--   set role authenticated;
--   select set_config('request.jwt.claims', json_build_object(
--     'sub', '<jonathan_user_id>',
--     'email', 'stockmansridge@gmail.com'
--   )::text, true);
--   select id, vineyard_id, email, status
--   from public.invitations
--   where email = 'stockmansridge@gmail.com';
--   -- Should return 0 rows for vineyards Jonathan already belongs to.
--
-- B) Confirm accept_invitation is a safe no-op for an existing member:
--   select public.accept_invitation('<invite_id>'); -- succeeds, no row inserted
--   select * from public.vineyard_members
--   where vineyard_id = '<vineyard_id>' and user_id = '<jonathan_user_id>';
--   -- Existing owner row unchanged.
--   select status from public.invitations where id = '<invite_id>';
--   -- 'accepted'

-- Mark any pending invitation as accepted when the invited user is already a member.
update public.invitations inv
set status = 'accepted'
where inv.status = 'pending'
  and exists (
    select 1
    from public.vineyard_members vm
    join public.profiles p on p.id = vm.user_id
    where vm.vineyard_id = inv.vineyard_id
      and lower(coalesce(p.email, '')) = lower(inv.email)
  );

-- Prevent duplicate pending invitations for the same email + vineyard.
create unique index if not exists uniq_invitations_pending_per_email
  on public.invitations (vineyard_id, lower(email))
  where status = 'pending';

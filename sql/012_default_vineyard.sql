-- Phase 16: Per-user default vineyard.
-- Stores the user's preferred vineyard to auto-select on app launch.

alter table public.profiles
  add column if not exists default_vineyard_id uuid
    references public.vineyards(id) on delete set null;

create index if not exists idx_profiles_default_vineyard_id
  on public.profiles (default_vineyard_id);

-- RLS: profiles_update_own already lets a user update their own row, which
-- includes default_vineyard_id. No additional policy required.

-- RPC: validate that the caller is a member of the vineyard (or null) and
-- atomically write the default. Defends against stale memberships clients
-- may not have noticed yet.
create or replace function public.set_default_vineyard(p_vineyard_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_vineyard_id is not null then
    if not exists (
      select 1 from public.vineyard_members
      where vineyard_id = p_vineyard_id
        and user_id = v_user_id
    ) then
      raise exception 'You are not a member of this vineyard';
    end if;
  end if;

  insert into public.profiles (id, email, default_vineyard_id)
  values (
    v_user_id,
    coalesce(auth.jwt() ->> 'email', ''),
    p_vineyard_id
  )
  on conflict (id) do update
    set default_vineyard_id = excluded.default_vineyard_id;
end;
$function$;

revoke all on function public.set_default_vineyard(uuid) from public;
grant execute on function public.set_default_vineyard(uuid) to authenticated;

-- Clear default automatically when membership is removed.
create or replace function public.clear_default_vineyard_on_member_removal()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  update public.profiles
  set default_vineyard_id = null
  where id = old.user_id
    and default_vineyard_id = old.vineyard_id;
  return old;
end;
$function$;

drop trigger if exists vineyard_members_clear_default on public.vineyard_members;
create trigger vineyard_members_clear_default
after delete on public.vineyard_members
for each row execute function public.clear_default_vineyard_on_member_removal();

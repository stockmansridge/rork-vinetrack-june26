create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.vineyards (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid references public.profiles(id) on delete set null,
  country text,
  logo_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.vineyard_members (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check (role in ('owner', 'manager', 'supervisor', 'operator')),
  display_name text,
  joined_at timestamptz not null default now(),
  unique (vineyard_id, user_id)
);

create table if not exists public.invitations (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  email text not null,
  role text not null check (role in ('owner', 'manager', 'supervisor', 'operator')),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'expired', 'cancelled')),
  invited_by uuid references public.profiles(id) on delete set null default auth.uid(),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.disclaimer_acceptances (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  version text not null,
  display_name text,
  email text,
  accepted_at timestamptz not null default now(),
  unique (user_id, version)
);

create table if not exists public.audit_events (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid references public.vineyards(id) on delete set null,
  user_id uuid references public.profiles(id) on delete set null default auth.uid(),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details text,
  created_at timestamptz not null default now()
);

create index if not exists idx_profiles_email_lower on public.profiles (lower(email));
create index if not exists idx_vineyards_owner_id on public.vineyards (owner_id);
create index if not exists idx_vineyards_deleted_at on public.vineyards (deleted_at);
create index if not exists idx_vineyard_members_vineyard_id on public.vineyard_members (vineyard_id);
create index if not exists idx_vineyard_members_user_id on public.vineyard_members (user_id);
create index if not exists idx_vineyard_members_role on public.vineyard_members (role);
create index if not exists idx_invitations_vineyard_id on public.invitations (vineyard_id);
create index if not exists idx_invitations_email_lower on public.invitations (lower(email));
create index if not exists idx_invitations_status on public.invitations (status);
create index if not exists idx_disclaimer_acceptances_user_id on public.disclaimer_acceptances (user_id);
create index if not exists idx_audit_events_vineyard_id_created_at on public.audit_events (vineyard_id, created_at desc);
create index if not exists idx_audit_events_user_id on public.audit_events (user_id);

create or replace trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create or replace trigger vineyards_set_updated_at
before update on public.vineyards
for each row execute function public.set_updated_at();

create or replace trigger invitations_set_updated_at
before update on public.invitations
for each row execute function public.set_updated_at();

alter table public.profiles enable row level security;
alter table public.vineyards enable row level security;
alter table public.vineyard_members enable row level security;
alter table public.invitations enable row level security;
alter table public.disclaimer_acceptances enable row level security;
alter table public.audit_events enable row level security;

create or replace function public.is_vineyard_member(p_vineyard_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.vineyard_members vm
    where vm.vineyard_id = p_vineyard_id
      and vm.user_id = auth.uid()
  );
$$;

create or replace function public.vineyard_role(p_vineyard_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select vm.role
  from public.vineyard_members vm
  where vm.vineyard_id = p_vineyard_id
    and vm.user_id = auth.uid()
  limit 1;
$$;

create or replace function public.has_vineyard_role(p_vineyard_id uuid, allowed_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.vineyard_role(p_vineyard_id) = any(allowed_roles), false);
$$;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
on public.profiles for select
to authenticated
using (id = auth.uid());

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own"
on public.profiles for insert
to authenticated
with check (id = auth.uid());

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
on public.profiles for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists "vineyards_select_members" on public.vineyards;
create policy "vineyards_select_members"
on public.vineyards for select
to authenticated
using (public.is_vineyard_member(id));

drop policy if exists "vineyards_update_owners_managers" on public.vineyards;
create policy "vineyards_update_owners_managers"
on public.vineyards for update
to authenticated
using (public.has_vineyard_role(id, array['owner', 'manager']))
with check (public.has_vineyard_role(id, array['owner', 'manager']) and deleted_at is null);

drop policy if exists "vineyards_soft_delete_owners" on public.vineyards;
create policy "vineyards_soft_delete_owners"
on public.vineyards for update
to authenticated
using (public.has_vineyard_role(id, array['owner']))
with check (public.has_vineyard_role(id, array['owner']));

drop policy if exists "vineyards_insert_authenticated" on public.vineyards;
create policy "vineyards_insert_authenticated"
on public.vineyards for insert
to authenticated
with check (owner_id = auth.uid());

drop policy if exists "vineyards_no_client_hard_delete" on public.vineyards;
create policy "vineyards_no_client_hard_delete"
on public.vineyards for delete
to authenticated
using (false);

drop policy if exists "vineyard_members_select_fellow_members" on public.vineyard_members;
create policy "vineyard_members_select_fellow_members"
on public.vineyard_members for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "vineyard_members_insert_owners_managers" on public.vineyard_members;
create policy "vineyard_members_insert_owners_managers"
on public.vineyard_members for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "vineyard_members_update_roles" on public.vineyard_members;
create policy "vineyard_members_update_roles"
on public.vineyard_members for update
to authenticated
using (
  public.has_vineyard_role(vineyard_id, array['owner'])
  or (public.has_vineyard_role(vineyard_id, array['manager']) and role <> 'owner')
)
with check (
  public.has_vineyard_role(vineyard_id, array['owner'])
  or (public.has_vineyard_role(vineyard_id, array['manager']) and role <> 'owner')
);

drop policy if exists "vineyard_members_delete_owners_managers" on public.vineyard_members;
create policy "vineyard_members_delete_owners_managers"
on public.vineyard_members for delete
to authenticated
using (
  public.has_vineyard_role(vineyard_id, array['owner'])
  or (public.has_vineyard_role(vineyard_id, array['manager']) and role <> 'owner')
);

drop policy if exists "invitations_insert_owners_managers" on public.invitations;
create policy "invitations_insert_owners_managers"
on public.invitations for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "invitations_select_vineyard_managers" on public.invitations;
create policy "invitations_select_vineyard_managers"
on public.invitations for select
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "invitations_select_invited_user" on public.invitations;
create policy "invitations_select_invited_user"
on public.invitations for select
to authenticated
using (
  status = 'pending'
  and lower(coalesce(auth.jwt() ->> 'email', '')) = lower(email)
);

drop policy if exists "invitations_update_vineyard_managers" on public.invitations;
create policy "invitations_update_vineyard_managers"
on public.invitations for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner', 'manager']))
with check (public.has_vineyard_role(vineyard_id, array['owner', 'manager']));

drop policy if exists "disclaimer_acceptances_select_own" on public.disclaimer_acceptances;
create policy "disclaimer_acceptances_select_own"
on public.disclaimer_acceptances for select
to authenticated
using (user_id = auth.uid());

drop policy if exists "disclaimer_acceptances_insert_own" on public.disclaimer_acceptances;
create policy "disclaimer_acceptances_insert_own"
on public.disclaimer_acceptances for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists "audit_events_select_vineyard_members" on public.audit_events;
create policy "audit_events_select_vineyard_members"
on public.audit_events for select
to authenticated
using (vineyard_id is not null and public.is_vineyard_member(vineyard_id));

drop policy if exists "audit_events_insert_vineyard_members" on public.audit_events;
create policy "audit_events_insert_vineyard_members"
on public.audit_events for insert
to authenticated
with check (
  user_id = auth.uid()
  and (
    vineyard_id is null
    or public.is_vineyard_member(vineyard_id)
  )
);

drop policy if exists "audit_events_no_client_update" on public.audit_events;
create policy "audit_events_no_client_update"
on public.audit_events for update
to authenticated
using (false)
with check (false);

drop policy if exists "audit_events_no_client_delete" on public.audit_events;
create policy "audit_events_no_client_delete"
on public.audit_events for delete
to authenticated
using (false);

create or replace function public.create_vineyard_with_owner(p_name text, p_country text default null)
returns setof public.vineyards
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard public.vineyards%rowtype;
  v_user_id uuid;
  v_email text;
begin
  v_user_id := auth.uid();
  v_email := coalesce(auth.jwt() ->> 'email', '');

  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if nullif(trim(p_name), '') is null then
    raise exception 'Vineyard name is required';
  end if;

  insert into public.profiles (id, email)
  values (v_user_id, v_email)
  on conflict (id) do update
  set email = coalesce(nullif(excluded.email, ''), public.profiles.email);

  insert into public.vineyards (name, owner_id, country)
  values (trim(p_name), v_user_id, nullif(trim(p_country), ''))
  returning * into v_vineyard;

  insert into public.vineyard_members (vineyard_id, user_id, role)
  values (v_vineyard.id, v_user_id, 'owner')
  on conflict (vineyard_id, user_id)
  do update set role = 'owner';

  return next v_vineyard;
end;
$function$;

revoke all on function public.create_vineyard_with_owner(text, text) from public;
grant execute on function public.create_vineyard_with_owner(text, text) to authenticated;

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

  insert into public.vineyard_members (vineyard_id, user_id, role)
  values (v_invitation.vineyard_id, v_user_id, v_invitation.role)
  on conflict (vineyard_id, user_id)
  do update set role = excluded.role;

  update public.invitations
  set status = 'accepted'
  where id = p_invitation_id;
end;
$function$;

revoke all on function public.accept_invitation(uuid) from public;
grant execute on function public.accept_invitation(uuid) to authenticated;

create or replace function public.decline_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_invitation public.invitations%rowtype;
  v_user_id uuid;
  v_user_email text;
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

  if v_user_email = '' or v_user_email <> lower(v_invitation.email) then
    raise exception 'Invitation email does not match authenticated user';
  end if;

  update public.invitations
  set status = 'declined'
  where id = p_invitation_id;
end;
$function$;

revoke all on function public.decline_invitation(uuid) from public;
grant execute on function public.decline_invitation(uuid) to authenticated;

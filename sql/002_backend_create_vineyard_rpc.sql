create or replace function public.create_vineyard_with_owner(p_name text, p_country text default null)
returns setof public.vineyards
language plpgsql
security definer
set search_path = public
as $$
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
$$;

revoke all on function public.create_vineyard_with_owner(text, text) from public;
grant execute on function public.create_vineyard_with_owner(text, text) to authenticated;

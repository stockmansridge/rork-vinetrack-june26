-- 061_forecast_provider_preference.sql
-- Vineyard-level forecast provider preference shared between iOS and Lovable.
--
-- Values:
--   auto         — use WillyWeather when a location is configured, else Open-Meteo
--   open_meteo   — always Open-Meteo
--   willyweather — always WillyWeather (requires a configured location)
--
-- The WillyWeather API key itself is NOT stored here. It lives globally
-- in the willyweather-proxy edge function as the WILLYWEATHER_API_KEY
-- secret and is never exposed to clients.

alter table public.vineyards
  add column if not exists forecast_provider text not null default 'auto';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'vineyards_forecast_provider_check'
  ) then
    alter table public.vineyards
      add constraint vineyards_forecast_provider_check
      check (forecast_provider in ('auto','open_meteo','willyweather'));
  end if;
end$$;

-- RLS already in place on public.vineyards: members can SELECT,
-- owner/manager can UPDATE. No new policies required.

-- SECURITY DEFINER RPC so the willyweather-proxy edge function can write
-- the preference using the caller's identity (membership/role enforced
-- inside the function rather than by table RLS via service-role).
create or replace function public.set_vineyard_forecast_provider(
  p_vineyard_id uuid,
  p_provider text
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  if p_provider not in ('auto','open_meteo','willyweather') then
    raise exception 'Invalid forecast_provider: %', p_provider;
  end if;

  select role::text into v_role
    from public.vineyard_members
   where vineyard_id = p_vineyard_id
     and user_id = auth.uid()
   limit 1;

  if v_role is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;
  if v_role not in ('owner','manager') then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  update public.vineyards
     set forecast_provider = p_provider,
         updated_at = now()
   where id = p_vineyard_id;

  return p_provider;
end$$;

grant execute on function public.set_vineyard_forecast_provider(uuid, text) to authenticated;

create or replace function public.get_vineyard_forecast_provider(
  p_vineyard_id uuid
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member boolean;
  v_provider text;
begin
  select exists(
    select 1 from public.vineyard_members
     where vineyard_id = p_vineyard_id
       and user_id = auth.uid()
  ) into v_member;
  if not v_member then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;

  select forecast_provider into v_provider
    from public.vineyards
   where id = p_vineyard_id;

  return coalesce(v_provider, 'auto');
end$$;

grant execute on function public.get_vineyard_forecast_provider(uuid) to authenticated;

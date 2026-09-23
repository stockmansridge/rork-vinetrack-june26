-- Run after sql/249 in a disposable database; all fixtures roll back.
begin;
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values ('24900000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
'authenticated', 'authenticated', 'sql249@test.local', 'x', now(), now(), now());
insert into public.profiles (id, email) values ('24900000-0000-4000-8000-000000000001', 'sql249@test.local') on conflict (id) do nothing;
insert into public.vineyards (id, name) values ('24900000-0000-4000-8000-000000000101', 'SQL249 weather');
insert into public.vineyard_members (vineyard_id, user_id, role) values
('24900000-0000-4000-8000-000000000101', '24900000-0000-4000-8000-000000000001', 'owner');
insert into public.vineyard_weather_integrations (vineyard_id, provider, station_id, station_name, api_key, api_secret, is_active)
values ('24900000-0000-4000-8000-000000000101', 'davis_weatherlink', 'davis-1', 'Davis', 'key', 'secret', true),
       ('24900000-0000-4000-8000-000000000101', 'wunderground', 'wu-1', 'PWS', null, null, true);
insert into public.vineyard_weather_observations (vineyard_id, source, station_id, observed_at, temperature_c, wind_gust_kmh)
values ('24900000-0000-4000-8000-000000000101', 'davis_weatherlink', 'davis-1', now() - interval '2 minutes', 21, 12),
       ('24900000-0000-4000-8000-000000000101', 'wunderground_pws', 'wu-1', now() - interval '21 minutes', 17, 27);
select set_config('request.jwt.claim.sub', '24900000-0000-4000-8000-000000000001', true);
do $$
declare v uuid := '24900000-0000-4000-8000-000000000101'; r record;
begin
  -- Unselected legacy vineyard remains Davis even when WU exists.
  select * into r from public.get_vineyard_current_weather(v);
  if r.source <> 'davis_weatherlink' or r.temperature_c <> 21 or r.is_stale then
    raise exception 'Legacy Davis selection regression'; end if;
  perform public.set_vineyard_current_observation_provider(v, 'wunderground_pws');
  select * into r from public.get_vineyard_current_weather(v);
  if r.source <> 'wunderground_pws' or r.temperature_c <> 17 or r.wind_gust_kmh <> 27 or not r.is_stale then
    raise exception 'WU provider, wind gust or server stale rule regression'; end if;
  -- Never read another provider's cached observation when WU is missing.
  delete from public.vineyard_weather_observations where vineyard_id = v and source = 'wunderground_pws';
  select * into r from public.get_vineyard_current_weather(v);
  if r.source <> 'wunderground_pws' or r.status <> 'no_data' then raise exception 'WU fell back to Davis'; end if;
  perform public.set_vineyard_current_observation_provider(v, 'none');
  select * into r from public.get_vineyard_current_weather(v);
  if r.status <> 'not_configured' or r.source <> 'none' then raise exception 'None not configured regression'; end if;
end $$;
rollback;

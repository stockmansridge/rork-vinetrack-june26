-- One release authority for both mobile clients. Only trusted database admins may edit rows.
create table if not exists public.app_release_policy (
  platform text primary key check (platform in ('ios', 'android')),
  latest_version text not null check (length(trim(latest_version)) > 0),
  latest_build bigint not null check (latest_build >= 0),
  minimum_supported_version text not null check (length(trim(minimum_supported_version)) > 0),
  minimum_supported_build bigint not null check (minimum_supported_build >= 0 and minimum_supported_build <= latest_build),
  update_title text not null,
  update_message text not null,
  store_url text not null,
  active boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.app_release_policy enable row level security;
revoke all on public.app_release_policy from anon, authenticated;

-- No table privileges are granted to clients; the only public surface is this read-only RPC.
create or replace function public.get_app_release_policy(p_platform text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(p)
  from public.app_release_policy p
  where p.platform = p_platform and p.active = true
    and p_platform in ('ios', 'android');
$$;
revoke all on function public.get_app_release_policy(text) from public;
grant execute on function public.get_app_release_policy(text) to anon, authenticated;

-- Seed with installed baseline builds: neither platform is forced to update by this migration.
insert into public.app_release_policy
  (platform, latest_version, latest_build, minimum_supported_version, minimum_supported_build, update_title, update_message, store_url, active)
values
  ('ios', '3.1.3', 1, '3.1.3', 1, 'Update available', 'A newer version of VineTrack is available.', 'https://apps.apple.com/app/id6761143377', true),
  ('android', '3.1.3', 9, '3.1.3', 9, 'Update available', 'A newer version of VineTrack is available.', 'https://play.google.com/store/apps/details?id=com.rork.vinetrack', true)
on conflict (platform) do nothing;

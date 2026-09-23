-- Non-mutating contract checks for the live read-only release RPC.
do $$
declare ios_policy jsonb; android_policy jsonb;
begin
  if not has_function_privilege('anon', 'public.get_app_release_policy(text)', 'EXECUTE') or
     not has_function_privilege('authenticated', 'public.get_app_release_policy(text)', 'EXECUTE') then
    raise exception 'release RPC must work before and after login';
  end if;
  if has_table_privilege('anon', 'public.app_release_policy', 'SELECT') or
     has_table_privilege('authenticated', 'public.app_release_policy', 'UPDATE') then
    raise exception 'mobile clients must not read or write release rows directly';
  end if;
  ios_policy := public.get_app_release_policy('ios');
  android_policy := public.get_app_release_policy('android');
  if ios_policy is null or android_policy is null then
    raise exception 'release policies are missing';
  end if;
  if ios_policy->>'platform' <> 'ios' or android_policy->>'platform' <> 'android' or
     (ios_policy->>'latest_build')::bigint < (ios_policy->>'minimum_supported_build')::bigint or
     (android_policy->>'latest_build')::bigint < (android_policy->>'minimum_supported_build')::bigint then
    raise exception 'release policies are missing or invalid';
  end if;
  if public.get_app_release_policy('web') is not null or public.get_app_release_policy(null) is not null then
    raise exception 'RPC leaked an unknown platform';
  end if;
end $$;

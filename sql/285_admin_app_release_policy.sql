-- System Admin management of the in-app update prompt (app_release_policy).
--
-- The apps read app_release_policy only through get_app_release_policy and
-- compare the installed BUILD number:
--   installed >= latest_build            -> no prompt
--   minimum <= installed < latest_build  -> optional "Update available" (Later = 24 h)
--   installed < minimum_supported_build  -> blocking "Update required"
-- These functions let a system admin read and change those values from the
-- portal. Clients still have no table privileges.

create or replace function public.admin_list_app_release_policies()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if not public.is_system_admin() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(p) order by p.platform)
      from public.app_release_policy p
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_set_app_release_policy(
  p_platform text,
  p_latest_version text,
  p_latest_build bigint,
  p_minimum_supported_version text,
  p_minimum_supported_build bigint,
  p_update_title text,
  p_update_message text,
  p_active boolean,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_old public.app_release_policy%rowtype;
  v_new public.app_release_policy%rowtype;
  v_title text := btrim(coalesce(p_update_title, ''));
  v_message text := btrim(coalesce(p_update_message, ''));
begin
  if not public.is_system_admin() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  if p_platform not in ('ios', 'android') then
    raise exception 'Platform must be ios or android' using errcode = '22023';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'A reason is required' using errcode = '22023';
  end if;
  if p_latest_version is null or length(btrim(p_latest_version)) = 0
     or p_minimum_supported_version is null or length(btrim(p_minimum_supported_version)) = 0 then
    raise exception 'Version names are required' using errcode = '22023';
  end if;
  if p_latest_build is null or p_latest_build < 0
     or p_minimum_supported_build is null or p_minimum_supported_build < 0 then
    raise exception 'Build numbers must be zero or more' using errcode = '22023';
  end if;
  if p_minimum_supported_build > p_latest_build then
    raise exception 'Minimum supported build cannot be above the latest build' using errcode = '22023';
  end if;
  -- The apps fall back to standard copy for empty, over-long or control text;
  -- refuse it here so the portal never saves copy the apps will ignore.
  if length(v_title) > 100 or length(v_message) > 800
     or v_title ~ '[[:cntrl:]]' or regexp_replace(v_message, E'\n', '', 'g') ~ '[[:cntrl:]]' then
    raise exception 'Title must be up to 100 characters and message up to 800, without control characters' using errcode = '22023';
  end if;

  select * into v_old from public.app_release_policy where platform = p_platform for update;
  if not found then
    raise exception 'No release policy row for %', p_platform using errcode = 'P0002';
  end if;

  update public.app_release_policy
     set latest_version = btrim(p_latest_version),
         latest_build = p_latest_build,
         minimum_supported_version = btrim(p_minimum_supported_version),
         minimum_supported_build = p_minimum_supported_build,
         update_title = case when v_title = '' then 'Update available' else v_title end,
         update_message = case when v_message = '' then 'A newer version of VineTrack is available.' else v_message end,
         active = coalesce(p_active, v_old.active),
         updated_at = now()
   where platform = p_platform
   returning * into v_new;

  insert into public.audit_events (vineyard_id, user_id, action, entity_type, entity_id, details)
  values (null, auth.uid(), 'admin_set_app_release_policy', 'app_release_policy', null,
    jsonb_build_object('platform', p_platform, 'reason', btrim(p_reason),
      'previous', to_jsonb(v_old), 'resulting', to_jsonb(v_new)));

  return to_jsonb(v_new);
end;
$$;

revoke all on function public.admin_list_app_release_policies() from public;
revoke all on function public.admin_set_app_release_policy(text, text, bigint, text, bigint, text, text, boolean, text) from public;
grant execute on function public.admin_list_app_release_policies() to authenticated;
grant execute on function public.admin_set_app_release_policy(text, text, bigint, text, bigint, text, text, boolean, text) to authenticated;
-- Supabase grants new public functions to anon by default; admin-only.
revoke execute on function public.admin_list_app_release_policies() from anon;
revoke execute on function public.admin_set_app_release_policy(text, text, bigint, text, bigint, text, text, boolean, text) from anon;

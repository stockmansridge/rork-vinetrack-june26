-- Run inside a transaction on a database with 251 and 285 applied and a
-- system_admins row for 11111111-1111-1111-1111-111111111111. Rolls back.
begin;
do $$
declare r jsonb; ok boolean;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  begin perform public.admin_list_app_release_policies(); raise exception 'T1 FAIL';
  exception when insufficient_privilege then null; end;
  begin perform public.admin_set_app_release_policy('ios','3.2.0',238,'1.0.0',1,'','',true,'x'); raise exception 'T2 FAIL';
  exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  if jsonb_array_length(public.admin_list_app_release_policies()) <> 2 then raise exception 'T3 FAIL'; end if;
  begin perform public.admin_set_app_release_policy('ios','3.2.0',100,'3.2.0',200,'','',true,'x'); raise exception 'T4 FAIL';
  exception when invalid_parameter_value then null; end;
  begin perform public.admin_set_app_release_policy('ios','3.2.0',238,'1.0.0',1,'','',true,'  '); raise exception 'T5 FAIL';
  exception when invalid_parameter_value then null; end;
  begin perform public.admin_set_app_release_policy('web','3.2.0',238,'1.0.0',1,'','',true,'x'); raise exception 'T6 FAIL';
  exception when invalid_parameter_value then null; end;
  begin perform public.admin_set_app_release_policy('ios','3.2.0',238,'1.0.0',1,repeat('a',101),'',true,'x'); raise exception 'T7 FAIL';
  exception when invalid_parameter_value then null; end;
  begin perform public.admin_set_app_release_policy('ios','3.2.0',238,'1.0.0',1,'Hi','bad'||chr(7),true,'x'); raise exception 'T8 FAIL';
  exception when invalid_parameter_value then null; end;

  r := public.admin_set_app_release_policy('ios',' 3.2.0 ',238,'1.0.0',1,'',E'Line one\nLine two',true,'3.2.0 live');
  if r->>'latest_version' <> '3.2.0' or (r->>'latest_build')::bigint <> 238 or r->>'update_title' <> 'Update available'
     or r->>'update_message' <> E'Line one\nLine two' then raise exception 'T9 FAIL %', r; end if;
  if (public.get_app_release_policy('ios')->>'latest_build')::bigint <> 238 then raise exception 'T10 FAIL'; end if;
  select exists(select 1 from public.audit_events where action = 'admin_set_app_release_policy'
     and details::jsonb->>'reason' = '3.2.0 live') into ok;
  if not ok then raise exception 'T11 FAIL'; end if;
  raise notice '285 admin app release policy tests: PASS';
end $$;
rollback;

-- =====================================================================
-- 135_store_entitlement_tests.sql — Phase 2B resolver + ingestion tests
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/133, sql/134, sql/135.
-- Everything runs inside ONE transaction that is ROLLED BACK — no
-- production data is touched. Expected output:
--   NOTICE: SQL 135 store entitlement tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 135 is applied.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'vinetrack_subscriptions'
      and column_name = 'grace_period_end'
  ) or to_regclass('public.billing_provider_events') is null then
    raise exception 'SQL 133/134/135 are not applied yet — run the migrations first, then re-run these tests.';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_my_vinetrack_access'
      and pg_get_function_result(p.oid) ilike '%purchase_platform%'
  ) then
    raise exception 'SQL 135 resolver not applied yet — run sql/135_verified_store_entitlement_resolver.sql first.';
  end if;
end$$;

do $$
declare
  u_apple   uuid;
  u_google  uuid;
  u_other   uuid;
  plan_solo   uuid;
  plan_legacy uuid;
  plan_internal uuid;
  s_id uuid;
  r record;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't135-apple@test.local',  'x', now(), now(), now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't135-google@test.local', 'x', now(), now(), now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't135-other@test.local',  'x', now(), now(), now());
  select id into u_apple  from auth.users where email = 't135-apple@test.local';
  select id into u_google from auth.users where email = 't135-google@test.local';
  select id into u_other  from auth.users where email = 't135-other@test.local';

  select id into plan_solo     from public.vinetrack_plans where code = 'solo';
  select id into plan_legacy   from public.vinetrack_plans where code = 'legacy_yearly';
  select id into plan_internal from public.vinetrack_plans where code = 'internal_unlimited';
  if plan_solo is null or plan_legacy is null then
    raise exception 'plan catalogue missing solo/legacy_yearly';
  end if;

  -- Helper macro: impersonate u and call the resolver.
  -- (Impersonation is transaction-local; the whole transaction rolls back.)

  -- ---- T1. Active verified Apple subscription grants access --------------
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     current_period_start, current_period_end, started_at, seats_included,
     external_subscription_id, cancel_at_period_end, last_verified_at)
  values
    (u_apple, plan_solo, 'apple', 'ios', 'production', 'active',
     now() - interval '1 day', now() + interval '30 days', now() - interval '1 day', 1,
     't135-apple-orig-txn-1', false, now())
  returning id into s_id;
  insert into public.vinetrack_user_licences (subscription_id, user_id, status)
  values (s_id, u_apple, 'active');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_apple::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();

  assert r.has_supabase_access = true,  'T1: apple sub must grant access';
  assert r.reason_code = 'app_store_subscription', 'T1: reason must be app_store_subscription, got ' || r.reason_code;
  assert r.can_use_ios_app = true,      'T1: ios access';
  assert r.can_use_android_app = true,  'T1: APPLE purchase must grant ANDROID access';
  assert r.can_use_portal = true,       'T1: apple purchase must grant portal access (solo => basic)';
  assert r.purchase_platform = 'ios',   'T1: purchase_platform must be ios';
  assert r.billing_provider = 'apple',  'T1: provider';
  raise notice 'T1 passed: Apple purchase grants iOS + Android + portal';

  -- ---- T2. Active verified Google subscription grants access -------------
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     current_period_start, current_period_end, started_at, seats_included,
     external_subscription_id, last_verified_at)
  values
    (u_google, plan_solo, 'google', 'android', 'production', 'active',
     now() - interval '1 day', now() + interval '30 days', now() - interval '1 day', 1,
     't135-google-token-1', now())
  returning id into s_id;
  insert into public.vinetrack_user_licences (subscription_id, user_id, status)
  values (s_id, u_google, 'active');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_google::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();

  assert r.has_supabase_access = true, 'T2: google sub must grant access';
  assert r.reason_code = 'app_store_subscription', 'T2: reason_code';
  assert r.can_use_ios_app = true,     'T2: GOOGLE purchase must grant IOS access';
  assert r.can_use_android_app = true, 'T2: android access';
  assert r.purchase_platform = 'android', 'T2: purchase_platform';
  raise notice 'T2 passed: Google purchase grants Android + iOS + portal';

  -- ---- T3. Cancelled-but-not-expired still grants ------------------------
  update public.vinetrack_subscriptions
  set cancel_at_period_end = true, canceled_at = now()
  where owner_user_id = u_apple and billing_provider = 'apple';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_apple::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();

  assert r.has_supabase_access = true, 'T3: cancelled-not-expired must still grant';
  assert r.cancel_at_period_end = true, 'T3: cancel_at_period_end must surface';
  raise notice 'T3 passed: cancellation keeps access until period end';

  -- ---- T4. Expired subscription does not grant ---------------------------
  update public.vinetrack_subscriptions
  set status = 'expired', current_period_end = now() - interval '1 day',
      expired_at = now() - interval '1 day'
  where owner_user_id = u_apple and billing_provider = 'apple';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_apple::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();

  assert r.has_supabase_access = false, 'T4: expired must not grant';
  assert r.reason_code = 'expired',     'T4: reason expired, got ' || r.reason_code;
  raise notice 'T4 passed: expiration removes access';

  -- ---- T5. Billing-issue grace grants only until grace end ---------------
  update public.vinetrack_subscriptions
  set status = 'past_due', current_period_end = now() - interval '1 day',
      expired_at = null, grace_period_end = now() + interval '5 days'
  where owner_user_id = u_apple and billing_provider = 'apple';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_apple::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true, 'T5a: within grace must grant';
  assert r.grace_period_end is not null, 'T5a: grace_period_end must surface';

  update public.vinetrack_subscriptions
  set grace_period_end = now() - interval '1 hour'
  where owner_user_id = u_apple and billing_provider = 'apple';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_apple::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false, 'T5b: elapsed grace must not grant';
  raise notice 'T5 passed: grace period grants only until grace expiry';

  -- ---- T6. Sandbox subscription never grants production access -----------
  update public.vinetrack_subscriptions
  set status = 'active', environment = 'sandbox',
      current_period_end = now() + interval '30 days', grace_period_end = null
  where owner_user_id = u_apple and billing_provider = 'apple';

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_apple::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false, 'T6: sandbox row must not grant';
  raise notice 'T6 passed: sandbox never grants production access';

  -- ---- T7. Internal Unlimited overrides a store subscription -------------
  update public.vinetrack_subscriptions
  set environment = 'production'
  where owner_user_id = u_apple and billing_provider = 'apple';
  if plan_internal is not null then
    insert into public.vinetrack_subscriptions
      (owner_user_id, plan_id, billing_provider, status, seats_included,
       unlimited_licences, manual_grant_reason)
    values (u_apple, plan_internal, 'manual', 'manual', 0, true, 'test grant')
    returning id into s_id;
    insert into public.vinetrack_user_licences (subscription_id, user_id, status)
    values (s_id, u_apple, 'active');

    perform set_config('request.jwt.claims',
      json_build_object('sub', u_apple::text, 'role', 'authenticated')::text, true);
    select * into r from public.get_my_vinetrack_access();
    assert r.reason_code = 'internal_unlimited',
      'T7: internal grant must outrank store sub, got ' || r.reason_code;
    raise notice 'T7 passed: Internal Unlimited overrides store subscription';
  end if;

  -- ---- T8. A user cannot see another user''s store subscription ----------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_other::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false, 'T8: unrelated user must have no access';
  assert r.reason_code = 'no_entitlement', 'T8: reason_code no_entitlement';
  raise notice 'T8 passed: entitlements are caller-scoped';

  -- ---- T9. Duplicate provider events are structurally impossible ---------
  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, app_user_id, processing_status)
  values ('revenuecat', 't135-evt-1', 'INITIAL_PURCHASE', 'PRODUCTION', u_apple::text, 'processed');
  begin
    insert into public.billing_provider_events
      (provider, provider_event_id, event_type, environment, app_user_id, processing_status)
    values ('revenuecat', 't135-evt-1', 'INITIAL_PURCHASE', 'PRODUCTION', u_apple::text, 'processed');
    raise exception 'T9 FAILED: duplicate provider event was accepted';
  exception when unique_violation then
    raise notice 'T9 passed: duplicate provider event rejected (idempotency guard)';
  end;

  -- ---- T10. Duplicate external subscription rows are impossible ----------
  begin
    insert into public.vinetrack_subscriptions
      (owner_user_id, plan_id, billing_provider, platform, environment, status,
       seats_included, external_subscription_id)
    values (u_other, plan_solo, 'google', 'android', 'production', 'active', 1, 't135-google-token-1');
    raise exception 'T10 FAILED: duplicate external subscription was accepted';
  exception when unique_violation then
    raise notice 'T10 passed: one live row per provider subscription enforced';
  end;

  -- ---- T11. Email change does not break the user-id-linked entitlement ---
  update auth.users set email = 't135-google-renamed@test.local' where id = u_google;
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_google::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true, 'T11: email change must not affect entitlement';
  raise notice 'T11 passed: entitlement keyed to auth.users.id, not email';

  -- ---- T12. Unknown catalogue product creates no access path -------------
  -- (Webhook-level rule; assert the catalogue exposes no active mapping for
  --  an unknown product so the webhook cannot map it.)
  assert not exists (
    select 1 from public.billing_product_catalog
    where external_product_id = 't135-unknown-product' and is_active = true
  ), 'T12: unknown product must have no active mapping';
  -- And the seeded placeholders must all be inactive until the live audit.
  assert not exists (
    select 1 from public.billing_product_catalog
    where is_active = true and metadata ? 'note'
      and metadata->>'note' like 'PLACEHOLDER%'
  ), 'T12: placeholder catalogue rows must stay inactive';
  raise notice 'T12 passed: unknown/placeholder products cannot grant access';

  raise notice 'SQL 135 store entitlement tests: ALL PASSED';
end$$;

rollback;

-- =====================================================================
-- 150_first_customer_diagnostics_tests.sql — Phase 2D diagnostic tests
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/150. Everything runs
-- inside ONE transaction that is ROLLED BACK — no production data is
-- touched. Expected final output:
--   NOTICE: SQL 150 first-customer diagnostic tests: ALL PASSED
--
-- Covers (Phase 2D Parts H, J, L subset):
--   T1  Non-admin cannot run the diagnostic (42501).
--   T2  Healthy Apple customer: active sub + processed event + active
--       catalogue mapping -> overall healthy, resolver grants, all three
--       platform booleans true, purchase platform 'ios'.
--   T3  Healthy Google customer -> provider 'google', platform 'android',
--       cross-platform booleans all true.
--   T4  Open alert + needs_review event -> overall 'attention' with
--       correct open counts and issue codes.
--   T5  State drift: 'active' store row whose period lapsed with no
--       expiry event -> overall 'failed'
--       (subscription_period_lapsed_without_expiry_event) and resolver
--       correctly denies (offline cache could never extend past expiry).
--   T6  No store subscription (trial-expired user) -> has_store_
--       subscription=false, attention, issue no_store_subscription.
--   T7  Unknown/inactive product on newest event -> catalogue_match=false,
--       issue product_not_in_active_catalogue.
--   T8  Sandbox subscription row -> issue sandbox_subscription; never
--       reported as a healthy production entitlement.
--   T9  Support grant (support_access, mandatory expiry+reason)
--       temporarily restores access on the failed user; diagnostic shows
--       resolver_has_access=true via internal grant, store issue remains.
--   T10 Revoking the support grant returns the user to the store-derived
--       (denied) state — grants never linger.
--   T11 Diagnostic returns no sensitive material: no raw payload keys,
--       external id redacted (first4…last4).
--   T12 Higher-priority source: healthy Apple customer ALSO holding an
--       Internal Unlimited grant stays overall healthy (resolver reason
--       internal_unlimited is not an error).
--   T13 Expired store subscription (normal churn) -> attention with
--       store_subscription_expired, resolver denies, booleans false.
--   T14 Diagnostic is read-only: no row counts change across calls.
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 150 is applied.
do $$
begin
  if to_regprocedure('public.admin_validate_user_store_entitlement(uuid)') is null then
    raise exception 'SQL 150 not applied — run sql/150_first_customer_store_diagnostics.sql first.';
  end if;
end$$;

do $$
declare
  u_admin    uuid;
  u_nonadmin uuid;
  u_apple    uuid;  -- healthy Apple customer
  u_google   uuid;  -- healthy Google customer
  u_drift    uuid;  -- active row, period lapsed, no expiry event -> failed
  u_none     uuid;  -- no store subscription, trial expired
  u_unknown  uuid;  -- newest event carries an unmapped product
  u_sandbox  uuid;  -- sandbox subscription row
  u_churn    uuid;  -- expired store subscription
  plan_solo  uuid;
  s_apple    uuid;
  s_drift    uuid;
  d          jsonb;
  g_id       uuid;
  n_subs     bigint;
  n_events   bigint;
  n_alerts   bigint;
  n_lic      bigint;
begin
  -- ---- fixtures ------------------------------------------------------------
  -- All users created > 3 months ago so the SQL 143 account trial is expired
  -- and can never mask store-entitlement behaviour.
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't150-admin@test.local',    'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't150-nonadmin@test.local', 'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't150-apple@test.local',    'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't150-google@test.local',   'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't150-drift@test.local',    'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't150-none@test.local',     'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't150-unknown@test.local',  'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't150-sandbox@test.local',  'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't150-churn@test.local',    'x', now(), now() - interval '1 year', now());
  select id into u_admin    from auth.users where email = 't150-admin@test.local';
  select id into u_nonadmin from auth.users where email = 't150-nonadmin@test.local';
  select id into u_apple    from auth.users where email = 't150-apple@test.local';
  select id into u_google   from auth.users where email = 't150-google@test.local';
  select id into u_drift    from auth.users where email = 't150-drift@test.local';
  select id into u_none     from auth.users where email = 't150-none@test.local';
  select id into u_unknown  from auth.users where email = 't150-unknown@test.local';
  select id into u_sandbox  from auth.users where email = 't150-sandbox@test.local';
  select id into u_churn    from auth.users where email = 't150-churn@test.local';

  insert into public.system_admins (user_id, is_active) values (u_admin, true)
  on conflict do nothing;

  select id into plan_solo from public.vinetrack_plans where code = 'solo';
  if plan_solo is null then raise exception 'plan catalogue missing solo'; end if;

  -- Active production catalogue mappings (mirrors SQL 138: yearly_9999 /
  -- vinetrack_solo_yearly). Test-scoped ids avoid touching real rows.
  insert into public.billing_product_catalog
    (provider, platform, environment, external_product_id, plan_code, entitlement_id, is_active)
  values ('revenuecat', 'ios',     'production', 'test150_yearly_ios',     'solo', 'pro', true),
         ('revenuecat', 'android', 'production', 'test150_yearly_android', 'solo', 'pro', true),
         ('revenuecat', 'ios',     'production', 'test150_inactive',       'solo', 'pro', false);

  -- Healthy Apple customer -----------------------------------------------------
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     external_subscription_id, current_period_start, current_period_end,
     started_at, seats_included, last_provider_event, last_provider_event_at, last_verified_at)
  values (u_apple, plan_solo, 'apple', 'ios', 'production', 'active',
          '200001234567890', now() - interval '10 days', now() + interval '355 days',
          now() - interval '10 days', 1, 'INITIAL_PURCHASE', now() - interval '10 days', now())
  returning id into s_apple;
  insert into public.vinetrack_user_licences (subscription_id, user_id, status)
  values (s_apple, u_apple, 'active');
  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, app_user_id, resolved_user_id,
     platform, store, product_id, entitlement_ids, external_subscription_id,
     provider_created_at, received_at, processed_at, processing_status)
  values ('revenuecat', 'evt150-apple-ok', 'INITIAL_PURCHASE', 'PRODUCTION', u_apple::text, u_apple,
          'ios', 'APP_STORE', 'test150_yearly_ios', array['pro'], '200001234567890',
          now() - interval '10 days', now() - interval '10 days', now() - interval '10 days', 'processed');

  -- Healthy Google customer ----------------------------------------------------
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     external_subscription_id, current_period_start, current_period_end,
     started_at, seats_included, last_provider_event, last_provider_event_at, last_verified_at)
  values (u_google, plan_solo, 'google', 'android', 'production', 'active',
          'GPA.3333-4444-5555-66666', now() - interval '5 days', now() + interval '360 days',
          now() - interval '5 days', 1, 'INITIAL_PURCHASE', now() - interval '5 days', now());
  insert into public.vinetrack_user_licences (subscription_id, user_id, status)
  select id, u_google, 'active' from public.vinetrack_subscriptions
  where owner_user_id = u_google and billing_provider = 'google';
  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, app_user_id, resolved_user_id,
     platform, store, product_id, entitlement_ids, external_subscription_id,
     provider_created_at, received_at, processed_at, processing_status)
  values ('revenuecat', 'evt150-google-ok', 'INITIAL_PURCHASE', 'PRODUCTION', u_google::text, u_google,
          'android', 'PLAY_STORE', 'test150_yearly_android', array['pro'], 'GPA.3333-4444-5555-66666',
          now() - interval '5 days', now() - interval '5 days', now() - interval '5 days', 'processed');

  -- Drift: 'active' but period + grace lapsed, no EXPIRATION arrived ----------
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     external_subscription_id, current_period_start, current_period_end,
     started_at, seats_included, last_provider_event, last_provider_event_at)
  values (u_drift, plan_solo, 'apple', 'ios', 'production', 'active',
          '200009876543210', now() - interval '400 days', now() - interval '35 days',
          now() - interval '400 days', 1, 'RENEWAL', now() - interval '400 days')
  returning id into s_drift;
  insert into public.vinetrack_user_licences (subscription_id, user_id, status)
  values (s_drift, u_drift, 'active');

  -- Unknown product: newest event carries an unmapped id -----------------------
  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, app_user_id, resolved_user_id,
     platform, store, product_id, entitlement_ids,
     provider_created_at, received_at, processed_at, processing_status,
     processing_error_code)
  values ('revenuecat', 'evt150-unknown-prod', 'INITIAL_PURCHASE', 'PRODUCTION', u_unknown::text, u_unknown,
          'ios', 'APP_STORE', 'not_in_catalogue_150', array['pro'],
          now() - interval '1 hour', now() - interval '1 hour', now() - interval '1 hour', 'needs_review',
          'unknown_product');

  -- Sandbox subscription row ----------------------------------------------------
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     external_subscription_id, current_period_start, current_period_end, started_at, seats_included)
  values (u_sandbox, plan_solo, 'apple', 'ios', 'sandbox', 'active',
          'SBX150-0001', now() - interval '1 day', now() + interval '30 days',
          now() - interval '1 day', 1);

  -- Churn: cleanly expired store subscription -----------------------------------
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     external_subscription_id, current_period_start, current_period_end,
     started_at, expired_at, seats_included, last_provider_event, last_provider_event_at)
  values (u_churn, plan_solo, 'google', 'android', 'production', 'expired',
          'GPA.7777-8888-9999-00000', now() - interval '400 days', now() - interval '35 days',
          now() - interval '400 days', now() - interval '35 days', 1, 'EXPIRATION', now() - interval '35 days');

  -- ---- T1. Non-admin rejected -----------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_nonadmin::text, 'role', 'authenticated')::text, true);
  begin
    perform public.admin_validate_user_store_entitlement(u_apple);
    raise exception 'T1: non-admin diagnostic call must be rejected';
  exception when insufficient_privilege then null;
  end;
  raise notice 'T1 passed: non-admin diagnostic rejected (42501)';

  -- Act as the System Admin for the rest.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);

  select count(*) into n_subs   from public.vinetrack_subscriptions;
  select count(*) into n_events from public.billing_provider_events;
  select count(*) into n_alerts from public.billing_admin_alerts;
  select count(*) into n_lic    from public.vinetrack_user_licences;

  -- ---- T2. Healthy Apple customer ---------------------------------------------
  d := public.admin_validate_user_store_entitlement(u_apple);
  if d->>'overall_status' <> 'healthy' then
    raise exception 'T2: expected healthy, got % (issues=%)', d->>'overall_status', d->'issues';
  end if;
  if (d->>'has_store_subscription')::boolean is distinct from true
     or d->>'provider' <> 'apple'
     or d->>'purchase_platform' <> 'ios'
     or d->>'subscription_status' <> 'active'
     or (d->>'catalogue_match')::boolean is distinct from true
     or (d->>'provider_event_found')::boolean is distinct from true
     or d->>'last_event_status' <> 'processed'
     or (d->>'resolver_has_access')::boolean is distinct from true
     or d->>'resolver_reason_code' <> 'app_store_subscription' then
    raise exception 'T2: healthy Apple payload wrong: %', d;
  end if;
  if (d->>'portal_access')::boolean is distinct from true
     or (d->>'can_use_ios_app')::boolean is distinct from true
     or (d->>'can_use_android_app')::boolean is distinct from true then
    raise exception 'T2: Apple purchase must unlock portal + iOS + Android: %', d;
  end if;
  raise notice 'T2 passed: healthy Apple customer, cross-platform booleans true';

  -- ---- T3. Healthy Google customer ---------------------------------------------
  d := public.admin_validate_user_store_entitlement(u_google);
  if d->>'overall_status' <> 'healthy'
     or d->>'provider' <> 'google'
     or d->>'purchase_platform' <> 'android'
     or (d->>'resolver_has_access')::boolean is distinct from true
     or (d->>'portal_access')::boolean is distinct from true
     or (d->>'can_use_ios_app')::boolean is distinct from true
     or (d->>'can_use_android_app')::boolean is distinct from true then
    raise exception 'T3: healthy Google payload wrong: %', d;
  end if;
  raise notice 'T3 passed: healthy Google customer, cross-platform booleans true';

  -- ---- T4. Open alert + review item -> attention -------------------------------
  -- Inserting a needs_review event fires the SQL 139 trigger, which creates
  -- the matching open alert automatically (one alert + one review item).
  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, resolved_user_id,
     platform, store, product_id, entitlement_ids, received_at, processed_at, processing_status,
     processing_error_code)
  values ('revenuecat', 'evt150-apple-review', 'RENEWAL', 'PRODUCTION', u_apple,
          'ios', 'APP_STORE', 'test150_yearly_ios', array['pro'], now(), now(), 'needs_review',
          'entitlement_mismatch');
  d := public.admin_validate_user_store_entitlement(u_apple);
  if d->>'overall_status' <> 'attention'
     or (d->>'open_alert_count')::bigint <> 1
     or (d->>'open_review_count')::bigint <> 1
     or not (d->'issues') ? 'open_billing_alerts'
     or not (d->'issues') ? 'open_review_items'
     or not (d->'issues') ? 'latest_event_needs_review' then
    raise exception 'T4: attention payload wrong: %', d;
  end if;
  -- Clean up so the Apple user is healthy again for T11/T12: acknowledge the
  -- trigger-created alert (retained historically) and remove the test event.
  update public.billing_admin_alerts set acknowledged_at = now(), acknowledged_by = u_admin
  where provider_event_id = 'evt150-apple-review' and acknowledged_at is null;
  delete from public.billing_provider_events where provider_event_id = 'evt150-apple-review';
  raise notice 'T4 passed: open alert + review item -> attention with correct counts';

  -- ---- T5. State drift -> failed ------------------------------------------------
  d := public.admin_validate_user_store_entitlement(u_drift);
  if d->>'overall_status' <> 'failed'
     or not (d->'issues') ? 'subscription_period_lapsed_without_expiry_event' then
    raise exception 'T5: expected failed drift, got %', d;
  end if;
  if (d->>'resolver_has_access')::boolean is distinct from false then
    raise exception 'T5: lapsed period must not grant access (server expiry caps everything): %', d;
  end if;
  raise notice 'T5 passed: lapsed active row -> failed; resolver denies';

  -- ---- T6. No store subscription -------------------------------------------------
  d := public.admin_validate_user_store_entitlement(u_none);
  if (d->>'has_store_subscription')::boolean is distinct from false
     or d->>'overall_status' <> 'attention'
     or not (d->'issues') ? 'no_store_subscription'
     or (d->>'resolver_has_access')::boolean is distinct from false then
    raise exception 'T6: no-store-subscription payload wrong (trial-expired user must be denied): %', d;
  end if;
  raise notice 'T6 passed: no store subscription -> attention, resolver denies';

  -- ---- T7. Unknown product ---------------------------------------------------------
  d := public.admin_validate_user_store_entitlement(u_unknown);
  if (d->>'catalogue_match')::boolean is distinct from false
     or not (d->'issues') ? 'product_not_in_active_catalogue'
     or d->>'overall_status' <> 'attention' then
    raise exception 'T7: unknown product payload wrong: %', d;
  end if;
  raise notice 'T7 passed: unmapped product -> catalogue_match=false, attention';

  -- ---- T8. Sandbox subscription ------------------------------------------------------
  d := public.admin_validate_user_store_entitlement(u_sandbox);
  if not (d->'issues') ? 'sandbox_subscription' then
    raise exception 'T8: sandbox subscription must be flagged: %', d;
  end if;
  if d->>'overall_status' = 'healthy' then
    raise exception 'T8: sandbox row must never be a healthy production entitlement: %', d;
  end if;
  raise notice 'T8 passed: sandbox subscription flagged, never healthy';

  -- ---- T9. Support grant temporarily restores access ----------------------------------
  g_id := public.admin_create_billing_grant(
    u_drift, 'support_access',
    'Payment confirmed in App Store Connect; webhook automation failed — temporary access while billing review item is resolved',
    null, now() + interval '72 hours', null);
  d := public.admin_validate_user_store_entitlement(u_drift);
  if (d->>'resolver_has_access')::boolean is distinct from true then
    raise exception 'T9: support grant must restore access: %', d;
  end if;
  if d->>'overall_status' <> 'failed' then
    raise exception 'T9: underlying store drift must STILL be reported while grant active: %', d;
  end if;
  raise notice 'T9 passed: support_access grant restores access; store issue still surfaced';

  -- ---- T10. Revoking the grant returns to the store-derived state ----------------------
  perform public.admin_revoke_billing_grant(g_id, 'Billing issue resolved — removing temporary support access');
  d := public.admin_validate_user_store_entitlement(u_drift);
  if (d->>'resolver_has_access')::boolean is distinct from false then
    raise exception 'T10: revoked support grant must not keep granting: %', d;
  end if;
  raise notice 'T10 passed: revoked support grant returns user to store-derived denial';

  -- ---- T11. Sanitisation ------------------------------------------------------------------
  d := public.admin_validate_user_store_entitlement(u_apple);
  if d ? 'raw_payload' or d ? 'receipt' or d ? 'purchase_token' or d ? 'token' then
    raise exception 'T11: diagnostic leaked sensitive keys: %', d;
  end if;
  if d->>'external_subscription_id_redacted' <> '2000…7890' then
    raise exception 'T11: external id not redacted first4…last4: %', d->>'external_subscription_id_redacted';
  end if;
  raise notice 'T11 passed: no sensitive keys; external id redacted';

  -- ---- T12. Higher-priority source stays healthy --------------------------------------------
  perform public.admin_create_billing_grant(
    u_apple, 'internal_unlimited', 'Internal team member who also purchased', null, null, null);
  d := public.admin_validate_user_store_entitlement(u_apple);
  if d->>'overall_status' <> 'healthy'
     or (d->>'resolver_has_access')::boolean is distinct from true
     or d->>'resolver_reason_code' <> 'internal_unlimited' then
    raise exception 'T12: internal grant over healthy store sub must stay healthy: %', d;
  end if;
  raise notice 'T12 passed: higher-priority internal source keeps diagnostic healthy';

  -- ---- T13. Expired store subscription (churn) -----------------------------------------------
  d := public.admin_validate_user_store_entitlement(u_churn);
  if d->>'overall_status' <> 'attention'
     or not (d->'issues') ? 'store_subscription_expired'
     or (d->>'resolver_has_access')::boolean is distinct from false
     or (d->>'portal_access')::boolean is distinct from false
     or (d->>'can_use_ios_app')::boolean is distinct from false
     or (d->>'can_use_android_app')::boolean is distinct from false then
    raise exception 'T13: churned customer payload wrong: %', d;
  end if;
  raise notice 'T13 passed: expired subscription -> attention, access + booleans false';

  -- ---- T14. Read-only --------------------------------------------------------------------------
  -- Expected deliberate deltas since the baseline counts:
  --   subscriptions +2 (T9 support grant, T12 internal grant)
  --   events        +0 (T4 event deleted in cleanup)
  --   alerts        +1 (T4 trigger alert retained, acknowledged)
  -- The diagnostic calls themselves must add nothing on top.
  perform public.admin_validate_user_store_entitlement(u_apple);
  perform public.admin_validate_user_store_entitlement(u_drift);
  perform public.admin_validate_user_store_entitlement(u_none);
  if (select count(*) from public.vinetrack_subscriptions)      <> n_subs + 2
     or (select count(*) from public.billing_provider_events)   <> n_events
     or (select count(*) from public.billing_admin_alerts)      <> n_alerts + 1 then
    raise exception 'T14: diagnostic calls must not create/remove rows';
  end if;
  raise notice 'T14 passed: diagnostic is read-only';

  raise notice 'SQL 150 first-customer diagnostic tests: ALL PASSED';
end$$;

rollback;

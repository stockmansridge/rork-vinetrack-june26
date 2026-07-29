-- =====================================================================
-- 148_billing_review_resolution_tests.sql — Billing Review Resolution tests
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/148. Everything runs
-- inside ONE transaction that is ROLLED BACK — no production data is
-- touched. Expected final output:
--   NOTICE: SQL 148 billing-review tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 148 is applied.
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_update_billing_review_item'
  ) then
    raise exception 'SQL 148 not applied — run sql/148_billing_review_resolution_actions.sql first.';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'billing_provider_events'
      and column_name = 'dismissal_reason'
  ) then
    raise exception 'SQL 148 review columns missing on billing_provider_events.';
  end if;
end$$;

do $$
declare
  u_admin    uuid;
  u_nonadmin uuid;
  u_target   uuid;
  u_other    uuid;
  plan_solo  uuid;
  ev_review   uuid;  -- needs_review: entitlement mismatch -> resolve
  ev_dismiss  uuid;  -- needs_review: unexpected entitlement -> dismiss
  ev_unres    uuid;  -- needs_review: unresolved user -> link_user + retry
  ev_retry    uuid;  -- failed: retryable INITIAL_PURCHASE -> retry (grants)
  ev_renewal  uuid;  -- failed: RENEWAL, same store transaction -> no duplicate
  ev_stuck    uuid;  -- received 1h ago -> stuck delivery retry
  ev_conflict uuid;  -- needs_review: ownership conflict -> resolve (audited)
  s_other     uuid;
  a_id        uuid;
  v_events_before bigint;
  v_alerts_before bigint;
  n           bigint;
  n2          bigint;
  m           jsonb;
  res         jsonb;
  v_payload   jsonb;
begin
  -- ---- fixtures ------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't148-admin@test.local',    'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't148-nonadmin@test.local', 'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't148-target@test.local',   'x', now(), now() - interval '1 year', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't148-other@test.local',    'x', now(), now() - interval '1 year', now());
  select id into u_admin    from auth.users where email = 't148-admin@test.local';
  select id into u_nonadmin from auth.users where email = 't148-nonadmin@test.local';
  select id into u_target   from auth.users where email = 't148-target@test.local';
  select id into u_other    from auth.users where email = 't148-other@test.local';

  insert into public.system_admins (user_id, is_active) values (u_admin, true)
  on conflict do nothing;

  select id into plan_solo from public.vinetrack_plans where code = 'solo';
  if plan_solo is null then
    raise exception 'plan catalogue missing solo';
  end if;

  -- Catalogue mapping for the retryable product.
  insert into public.billing_product_catalog
    (provider, platform, environment, external_product_id, plan_code, entitlement_id, is_active)
  values ('revenuecat', 'ios',     'production', 'test_prod_148', 'solo', 'pro', true),
         ('revenuecat', 'android', 'production', 'test_prod_148', 'solo', 'pro', true);

  -- Subscription owned by ANOTHER user for the ownership-conflict fixture.
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     external_subscription_id, current_period_start, current_period_end, started_at, seats_included)
  values (u_other, plan_solo, 'apple', 'ios', 'production', 'active',
          'sub148D', now() - interval '1 day', now() + interval '30 days', now() - interval '1 day', 1)
  returning id into s_other;

  -- Problem events (the SQL 139 trigger auto-creates matching alerts).
  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, app_user_id, resolved_user_id,
     platform, store, product_id, entitlement_ids, external_subscription_id,
     provider_created_at, received_at, processed_at, processing_status,
     processing_error_code, processing_error_message, raw_payload)
  values
    ('revenuecat', 'evt148-review', 'INITIAL_PURCHASE', 'PRODUCTION', u_target::text, u_target,
     'ios', 'APP_STORE', 'test_prod_148', array['premium'], 'sub148X',
     now() - interval '2 hours', now() - interval '2 hours', now() - interval '2 hours', 'needs_review',
     'entitlement_mismatch', 'premium without pro', jsonb_build_object('event', jsonb_build_object('period_type', 'NORMAL')))
  returning id into ev_review;

  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, resolved_user_id,
     platform, store, product_id, entitlement_ids,
     provider_created_at, received_at, processed_at, processing_status,
     processing_error_code, processing_error_message, raw_payload)
  values
    ('revenuecat', 'evt148-dismiss', 'INITIAL_PURCHASE', 'PRODUCTION', u_target,
     'ios', 'APP_STORE', 'test_prod_148', array['other'],
     now() - interval '2 hours', now() - interval '2 hours', now() - interval '2 hours', 'needs_review',
     'unexpected_entitlement', 'entitlements do not include pro', '{}'::jsonb)
  returning id into ev_dismiss;

  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, app_user_id, resolved_user_id,
     platform, store, product_id, entitlement_ids, external_subscription_id,
     provider_created_at, received_at, processed_at, processing_status,
     processing_error_code, processing_error_message, raw_payload)
  values
    ('revenuecat', 'evt148-unres', 'INITIAL_PURCHASE', 'PRODUCTION', 'anon-user-ref', null,
     'android', 'PLAY_STORE', 'test_prod_148', array['pro'], 'sub148A',
     now() - interval '2 hours', now() - interval '2 hours', now() - interval '2 hours', 'needs_review',
     'unresolved_app_user_id', 'No Supabase UUID in app_user_id', jsonb_build_object('event', jsonb_build_object(
       'period_type', 'NORMAL',
       'purchased_at_ms', (extract(epoch from now() - interval '2 hours') * 1000)::bigint,
       'expiration_at_ms', (extract(epoch from now() + interval '30 days') * 1000)::bigint)))
  returning id into ev_unres;

  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, app_user_id, resolved_user_id,
     platform, store, product_id, entitlement_ids, external_subscription_id,
     provider_created_at, received_at, processed_at, processing_status,
     processing_error_code, processing_error_message, raw_payload)
  values
    ('revenuecat', 'evt148-retry', 'INITIAL_PURCHASE', 'PRODUCTION', u_target::text, u_target,
     'ios', 'APP_STORE', 'test_prod_148', array['pro'], 'sub148B',
     now() - interval '2 hours', now() - interval '2 hours', now() - interval '2 hours', 'failed',
     'plan_lookup_failed', 'transient failure', jsonb_build_object('event', jsonb_build_object(
       'period_type', 'NORMAL',
       'purchased_at_ms', (extract(epoch from now() - interval '2 hours') * 1000)::bigint,
       'expiration_at_ms', (extract(epoch from now() + interval '30 days') * 1000)::bigint)))
  returning id into ev_retry;

  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, app_user_id, resolved_user_id,
     platform, store, product_id, entitlement_ids, external_subscription_id,
     provider_created_at, received_at, processed_at, processing_status,
     processing_error_code, processing_error_message, raw_payload)
  values
    ('revenuecat', 'evt148-renewal', 'RENEWAL', 'PRODUCTION', u_target::text, u_target,
     'ios', 'APP_STORE', 'test_prod_148', array['pro'], 'sub148B',
     now() - interval '1 hour', now() - interval '1 hour', now() - interval '1 hour', 'failed',
     'subscription_update_failed', 'transient failure', jsonb_build_object('event', jsonb_build_object(
       'period_type', 'NORMAL',
       'purchased_at_ms', (extract(epoch from now() - interval '1 hour') * 1000)::bigint,
       'expiration_at_ms', (extract(epoch from now() + interval '60 days') * 1000)::bigint)))
  returning id into ev_renewal;

  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, app_user_id, resolved_user_id,
     platform, store, product_id, entitlement_ids, external_subscription_id,
     provider_created_at, received_at, processing_status, raw_payload)
  values
    ('revenuecat', 'evt148-stuck', 'INITIAL_PURCHASE', 'PRODUCTION', u_target::text, u_target,
     'ios', 'APP_STORE', 'test_prod_148', array['pro'], 'sub148C',
     now() - interval '1 hour', now() - interval '1 hour', 'received', jsonb_build_object('event', jsonb_build_object(
       'period_type', 'NORMAL',
       'purchased_at_ms', (extract(epoch from now() - interval '1 hour') * 1000)::bigint,
       'expiration_at_ms', (extract(epoch from now() + interval '30 days') * 1000)::bigint)))
  returning id into ev_stuck;

  insert into public.billing_provider_events
    (provider, provider_event_id, event_type, environment, app_user_id, resolved_user_id,
     platform, store, product_id, entitlement_ids, external_subscription_id,
     provider_created_at, received_at, processed_at, processing_status,
     processing_error_code, processing_error_message, raw_payload)
  values
    ('revenuecat', 'evt148-conflict', 'INITIAL_PURCHASE', 'PRODUCTION', u_target::text, u_target,
     'ios', 'APP_STORE', 'test_prod_148', array['pro'], 'sub148D',
     now() - interval '2 hours', now() - interval '2 hours', now() - interval '2 hours', 'needs_review',
     'ownership_conflict', 'subscription belongs to another user', '{}'::jsonb)
  returning id into ev_conflict;

  select count(*) into v_events_before from public.billing_provider_events;
  select count(*) into v_alerts_before from public.billing_admin_alerts;

  -- ---- T1. Non-admin mutations and listing rejected -------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_nonadmin::text, 'role', 'authenticated')::text, true);
  begin
    perform public.admin_update_billing_review_item('event', ev_review, 'resolve', 'x');
    raise exception 'T1: non-admin resolve must be rejected';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.admin_dismiss_billing_review_item('event', ev_review, 'x');
    raise exception 'T1: non-admin dismiss must be rejected';
  exception when insufficient_privilege then null;
  end;
  begin
    perform * from public.admin_billing_review_items('event');
    raise exception 'T1: non-admin listing must be rejected';
  exception when insufficient_privilege then null;
  end;
  raise notice 'T1 passed: non-admin calls rejected (42501)';

  -- Act as the System Admin for the rest of the tests.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);

  -- ---- T2. Acknowledged alert disappears from open count --------------------
  select id into a_id from public.billing_admin_alerts
  where provider_event_id = 'evt148-review' and acknowledged_at is null
  limit 1;
  if a_id is null then
    raise exception 'T2: SQL 139 trigger did not create an alert for evt148-review';
  end if;
  select (public.admin_store_billing_monitor()->>'open_alerts')::bigint into n;
  res := public.admin_update_billing_review_item('alert', a_id, 'acknowledge', 'Reviewed and handled');
  select (public.admin_store_billing_monitor()->>'open_alerts')::bigint into n2;
  if n2 <> n - 1 then
    raise exception 'T2: open alert count % should drop to %, got %', n, n - 1, n2;
  end if;
  if not exists (select 1 from public.billing_admin_alerts where id = a_id and acknowledged_at is not null) then
    raise exception 'T2: acknowledged alert must remain in history';
  end if;
  raise notice 'T2 passed: acknowledged alert leaves open count, stays in history';

  -- ---- T3. Resolved review item disappears from active count ----------------
  select (public.admin_store_billing_monitor()->'events_needing_review'->>'count')::bigint into n;
  res := public.admin_resolve_billing_review_item('event', ev_review, 'Entitlement configuration corrected in RevenueCat');
  select (public.admin_store_billing_monitor()->'events_needing_review'->>'count')::bigint into n2;
  if n2 <> n - 1 then
    raise exception 'T3: needs_review count % should drop to %, got %', n, n - 1, n2;
  end if;
  if exists (select 1 from public.admin_billing_review_items('event', 'open', 500, 0) i where i.item_id = ev_review) then
    raise exception 'T3: resolved item must not appear in the open list';
  end if;
  raise notice 'T3 passed: resolve removes item from active count and open list';

  -- ---- T4. Dismiss requires a reason; dismissed item leaves active count ----
  begin
    perform public.admin_update_billing_review_item('event', ev_dismiss, 'dismiss', '   ');
    raise exception 'T4: dismiss without a reason must be rejected';
  exception when sqlstate '22023' then null;
  end;
  res := public.admin_dismiss_billing_review_item('event', ev_dismiss, 'Synthetic test event — not actionable');
  if exists (select 1 from public.admin_billing_review_items('event', 'open', 500, 0) i where i.item_id = ev_dismiss) then
    raise exception 'T4: dismissed item must not appear in the open list';
  end if;
  raise notice 'T4 passed: dismissal reason mandatory; dismissed item leaves active list';

  -- ---- T5. Historical records remain available ------------------------------
  if not exists (select 1 from public.admin_billing_review_items('event', 'resolved', 500, 0) i where i.item_id = ev_review) then
    raise exception 'T5: resolved item missing from historical (resolved) list';
  end if;
  if not exists (select 1 from public.admin_billing_review_items('event', 'dismissed', 500, 0) i where i.item_id = ev_dismiss) then
    raise exception 'T5: dismissed item missing from historical (dismissed) list';
  end if;
  raise notice 'T5 passed: resolved and dismissed items remain queryable';

  -- ---- T6. Retry grants access, is idempotent, never duplicates -------------
  res := public.admin_retry_billing_delivery(ev_retry, 'Transient failure — reprocess');
  if (res->'result'->>'outcome') <> 'processed' then
    raise exception 'T6: retry outcome expected processed, got %', res->'result'->>'outcome';
  end if;
  select count(*) into n from public.vinetrack_subscriptions
  where billing_provider = 'apple' and external_subscription_id = 'sub148B' and deleted_at is null;
  if n <> 1 then
    raise exception 'T6: expected exactly 1 subscription for sub148B, got %', n;
  end if;
  if not exists (
    select 1 from public.vinetrack_user_licences l
    join public.vinetrack_subscriptions s on s.id = l.subscription_id
    where s.external_subscription_id = 'sub148B' and l.user_id = u_target and l.status = 'active'
  ) then
    raise exception 'T6: active licence missing for the retried purchase';
  end if;
  -- Second retry of the SAME event must be rejected (already resolved/processed).
  begin
    perform public.admin_retry_billing_delivery(ev_retry, 'Second attempt');
    raise exception 'T6: second retry of a processed event must be rejected';
  exception when sqlstate '22023' then null;
  end;
  -- Retrying the RENEWAL for the SAME store transaction must UPDATE, not duplicate.
  res := public.admin_retry_billing_delivery(ev_renewal, 'Transient failure — reprocess renewal');
  if (res->'result'->>'outcome') <> 'processed' then
    raise exception 'T6: renewal retry expected processed, got %', res->'result'->>'outcome';
  end if;
  select count(*) into n from public.vinetrack_subscriptions
  where billing_provider = 'apple' and external_subscription_id = 'sub148B' and deleted_at is null;
  if n <> 1 then
    raise exception 'T6: renewal retry duplicated the subscription (count %)', n;
  end if;
  raise notice 'T6 passed: retry idempotent, no duplicate subscriptions or licences';

  -- ---- T7. Unresolved user: link_user then retry -----------------------------
  -- Invalid target rejected first.
  begin
    perform public.admin_update_billing_review_item('unresolved_user', ev_unres, 'link_user', 'Confirmed account', gen_random_uuid());
    raise exception 'T7: linking a non-existent user must be rejected';
  exception when sqlstate 'P0002' then null;
  end;
  -- Missing target rejected (never resolve by email alone).
  begin
    perform public.admin_update_billing_review_item('unresolved_user', ev_unres, 'link_user', 'Confirmed account', null);
    raise exception 'T7: link_user without a target user must be rejected';
  exception when sqlstate '22023' then null;
  end;
  res := public.admin_update_billing_review_item('unresolved_user', ev_unres, 'link_user', 'Customer confirmed account by support ticket', u_target);
  if not exists (select 1 from public.billing_provider_events where id = ev_unres and resolved_user_id = u_target) then
    raise exception 'T7: link_user did not set resolved_user_id';
  end if;
  res := public.admin_update_billing_review_item('unresolved_user', ev_unres, 'retry', 'Linked — reprocess');
  if (res->'result'->>'outcome') <> 'processed' then
    raise exception 'T7: linked retry expected processed, got %', res->'result'->>'outcome';
  end if;
  select count(*) into n from public.vinetrack_subscriptions
  where billing_provider = 'google' and external_subscription_id = 'sub148A' and deleted_at is null;
  if n <> 1 then
    raise exception 'T7: expected 1 Google subscription for sub148A, got %', n;
  end if;
  raise notice 'T7 passed: unresolved user linked safely; invalid/missing targets rejected';

  -- ---- T8. Stuck delivery retry ----------------------------------------------
  res := public.admin_update_billing_review_item('stuck_delivery', ev_stuck, 'retry', 'Webhook crashed mid-flight — reprocess');
  if (res->'result'->>'outcome') <> 'processed' then
    raise exception 'T8: stuck-delivery retry expected processed, got %', res->'result'->>'outcome';
  end if;
  m := public.admin_store_billing_monitor();
  if exists (
    select 1 from jsonb_array_elements(m->'stuck_deliveries') d
    where (d->>'id')::uuid = ev_stuck
  ) then
    raise exception 'T8: retried stuck delivery must leave the stuck list';
  end if;
  raise notice 'T8 passed: stuck delivery reprocessed and cleared from monitor';

  -- ---- T9. Ownership conflict resolution is audited ---------------------------
  res := public.admin_resolve_billing_review_item('ownership_conflict', ev_conflict, 'Duplicate sandbox account confirmed with customer');
  select payload into v_payload
  from public.vinetrack_billing_events
  where event_type = 'billing_review_resolved'
    and (payload->>'item_id')::uuid = ev_conflict
  order by created_at desc
  limit 1;
  if v_payload is null then
    raise exception 'T9: ownership-conflict resolution must write a billing_review_resolved audit event';
  end if;
  if (v_payload->>'actor')::uuid <> u_admin then
    raise exception 'T9: audit event must record the acting admin';
  end if;
  -- Retry, resolve and dismiss must all have audit rows with reasons.
  select count(*) into n from public.vinetrack_billing_events
  where event_type like 'billing\_review\_%' escape '\'
    and coalesce(btrim(payload->>'reason'), '') = '';
  if n <> 0 then
    raise exception 'T9: % review audit rows are missing a reason', n;
  end if;
  raise notice 'T9 passed: review actions audited with actor, reason and timestamp';

  -- ---- T10. Raw billing evidence is never deleted -----------------------------
  select count(*) into n from public.billing_provider_events;
  if n <> v_events_before then
    raise exception 'T10: billing_provider_events count changed (% -> %)', v_events_before, n;
  end if;
  select count(*) into n from public.billing_admin_alerts;
  if n < v_alerts_before then
    raise exception 'T10: billing_admin_alerts rows were deleted (% -> %)', v_alerts_before, n;
  end if;
  if not exists (select 1 from public.billing_provider_events where id = ev_review and raw_payload is not null) then
    raise exception 'T10: resolved event lost its raw payload';
  end if;
  raise notice 'T10 passed: no review evidence deleted';

  -- ---- T11. Monitor counts refresh after every action -------------------------
  m := public.admin_store_billing_monitor();
  if exists (
    select 1 from jsonb_array_elements(m->'events_needing_review'->'recent') r
    where (r->>'id')::uuid in (ev_review, ev_dismiss)
  ) then
    raise exception 'T11: resolved/dismissed events must leave the needs-review list';
  end if;
  select count(*) into n
  from public.billing_provider_events
  where processing_error_code = 'ownership_conflict'
    and resolved_at is null and dismissed_at is null
    and id = ev_conflict;
  if (m->'ownership_conflicts'->>'count')::bigint <> (
    select count(*) from public.billing_provider_events
    where processing_error_code = 'ownership_conflict'
      and resolved_at is null and dismissed_at is null
  ) then
    raise exception 'T11: ownership-conflict count out of sync with review state';
  end if;
  if n <> 0 then
    raise exception 'T11: resolved conflict still counted as open';
  end if;
  if jsonb_array_length(m->'recent_review_actions') < 1 then
    raise exception 'T11: recent_review_actions must list the review activity';
  end if;
  raise notice 'T11 passed: monitor counts and recent actions refresh correctly';

  raise notice 'SQL 148 billing-review tests: ALL PASSED';
end$$;

rollback;

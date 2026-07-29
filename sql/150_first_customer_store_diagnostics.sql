-- =====================================================================
-- 150_first_customer_store_diagnostics.sql
-- =====================================================================
-- Phase 2D — First Paid Customer Readiness (Part H).
--
-- PURPOSE
--   One protected, READ-ONLY System Admin RPC that checks a single user's
--   store entitlement end to end:
--     store subscription row  →  product catalogue mapping  →  provider
--     webhook events          →  shared resolver result     →  platform
--     booleans                →  open alerts / review items
--   and returns a sanitised diagnostic with overall_status
--   healthy | attention | failed plus a machine-readable issues[] list.
--
-- EXISTING BEHAVIOUR BEING CORRECTED
--   Nothing is corrected — this is purely ADDITIVE. Today an admin must
--   manually cross-reference admin_user_access_detail(),
--   admin_store_subscription_diagnostics(), admin_billing_review_items()
--   and admin_billing_alerts() to validate one customer. This RPC folds
--   that first-customer check into a single call (launch checklist step).
--
-- OBJECTS ADDED
--   * function public.admin_validate_user_store_entitlement(uuid) → jsonb
--
-- OBJECTS CHANGED
--   * none. get_my_vinetrack_access(), _admin_effective_access(),
--     admin_access_users(), admin_user_access_detail(), the webhook and
--     the billing monitor are untouched.
--
-- SOURCE OF TRUTH
--   * Entitlement result: public._admin_effective_access(p_user_id)
--     (the read-only mirror of get_my_vinetrack_access(), SQL 144) —
--     the diagnostic never re-implements entitlement precedence.
--   * Platform booleans: the EXACT SQL 146 expressions
--     (portal_access = has_access AND portal level <> 'none';
--      can_use_ios_app / can_use_android_app = has_access).
--   * Store subscription: newest non-deleted apple/google row in
--     public.vinetrack_subscriptions owned by the user.
--   * Events / review: public.billing_provider_events incl. the SQL 148
--     review columns (resolved_at / dismissed_at).
--   * Alerts: public.billing_admin_alerts (open = acknowledged_at null).
--
-- SANITISATION
--   Never returns receipts, purchase tokens, raw provider payloads,
--   webhook signatures or service-role data. external_subscription_id is
--   redacted to first4…last4 (same convention as SQL 139).
--
-- OVERALL STATUS RULES (documented for the portal/support team)
--   failed    — a paying customer would be locked out or mis-linked:
--                 * user id does not exist in auth.users
--                 * a currently-valid store subscription row exists but
--                   the shared resolver denies access
--                 * an apple/google subscription row is 'active'/'trialing'
--                   yet its period (incl. grace) has already lapsed
--                   (state drift — webhook expiry never arrived)
--   attention — works or is explainable, but needs a human eye:
--                 * open billing alerts or open review items for the user
--                 * store subscription present but no provider event ever
--                   recorded (webhook gap)
--                 * newest event for the user is needs_review/failed
--                 * product on the newest event has no ACTIVE production
--                   catalogue mapping
--                 * subscription row is sandbox-environment
--                 * store subscription expired (normal churn, but worth a
--                   look during first-customer validation)
--                 * no store subscription at all (this RPC exists to
--                   validate paying customers)
--                 * account disabled/banned while store access exists
--   healthy   — active/trialing store subscription, catalogue-mapped
--               product, last event processed, resolver grants access via
--               the store source (or a deliberately higher-priority
--               source), no open alerts or review items.
--
-- BACKWARD COMPATIBILITY
--   Additive-only. No released client calls this function yet; the
--   Lovable portal may adopt it without any other contract change.
--
-- ROLLBACK
--   drop function if exists public.admin_validate_user_store_entitlement(uuid);
--
-- VERIFICATION (after apply, as a System Admin):
--   select public.admin_validate_user_store_entitlement(
--     (select id from auth.users where email = 'jonathan@stockmansridge.com.au'));
--   -- then run sql/tests/150_first_customer_diagnostics_tests.sql
--   -- (single transaction, always rolled back).
-- =====================================================================

begin;

-- Preconditions -------------------------------------------------------------
do $$
begin
  if to_regprocedure('public._admin_effective_access(uuid)') is null then
    raise exception 'SQL 150 precondition failed: apply sql/144 first';
  end if;
  if to_regclass('public.billing_provider_events') is null then
    raise exception 'SQL 150 precondition failed: apply sql/133 first';
  end if;
  if to_regclass('public.billing_admin_alerts') is null then
    raise exception 'SQL 150 precondition failed: apply sql/139 first';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'billing_provider_events'
      and column_name = 'resolved_at'
  ) then
    raise exception 'SQL 150 precondition failed: apply sql/148 first (review columns)';
  end if;
end$$;

create or replace function public.admin_validate_user_store_entitlement(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user record;
  v_sub  record;
  v_ev   record;
  v_ea   record;
  v_open_alerts   bigint := 0;
  v_open_reviews  bigint := 0;
  v_catalogue_match boolean := null;   -- null = not applicable (no product seen)
  v_issues        text[] := array[]::text[];
  v_overall       text := 'healthy';
  v_sub_currently_valid boolean := false;
  v_redacted_ext  text := null;
begin
  -- Security: System Admin only; read-only; fails closed.
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_user_id is null then
    raise exception 'p_user_id required' using errcode = '22023';
  end if;

  select u.id, u.email, u.created_at, u.banned_until
  into v_user
  from auth.users u
  where u.id = p_user_id;

  if v_user.id is null then
    return jsonb_build_object(
      'user_id',                p_user_id,
      'has_store_subscription', false,
      'resolver_has_access',    false,
      'open_alert_count',       0,
      'open_review_count',      0,
      'overall_status',         'failed',
      'issues',                 jsonb_build_array('user_not_found'),
      'checked_at',             now());
  end if;

  -- 1. Newest non-deleted store (apple/google) subscription owned by user.
  select s.id, s.billing_provider, s.platform, s.environment, s.status,
         s.cancel_at_period_end, s.current_period_start, s.current_period_end,
         s.grace_period_end, s.external_subscription_id,
         s.last_provider_event, s.last_provider_event_at, s.last_verified_at,
         p.code as plan_code
  into v_sub
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  where s.owner_user_id = p_user_id
    and s.billing_provider in ('apple', 'google')
    and s.deleted_at is null
  order by s.updated_at desc, s.created_at desc
  limit 1;

  if v_sub.id is not null and v_sub.external_subscription_id is not null then
    v_redacted_ext := case
      when length(v_sub.external_subscription_id) > 8 then
        left(v_sub.external_subscription_id, 4) || '…' || right(v_sub.external_subscription_id, 4)
      else v_sub.external_subscription_id
    end;
  end if;

  -- "Currently valid" mirrors the resolver's store-row validity window:
  -- active/trialing (or past_due inside grace) with a period end still ahead.
  v_sub_currently_valid :=
    v_sub.id is not null
    and coalesce(v_sub.environment, 'production') <> 'sandbox'
    and (
      (v_sub.status in ('active', 'trialing')
       and (v_sub.current_period_end is null or v_sub.current_period_end > now()
            or (v_sub.grace_period_end is not null and v_sub.grace_period_end > now())))
      or (v_sub.status = 'past_due'
          and v_sub.grace_period_end is not null and v_sub.grace_period_end > now())
    );

  -- 2. Newest provider event attributed to this user (resolved id, or the
  --    App User ID string when resolution never completed).
  select e.event_type, e.processing_status, e.processing_error_code,
         e.environment, e.product_id, e.platform, e.store,
         e.received_at, e.processed_at
  into v_ev
  from public.billing_provider_events e
  where e.resolved_user_id = p_user_id
     or e.app_user_id = p_user_id::text
  order by e.received_at desc
  limit 1;

  -- 3. Catalogue check for the product on the newest event: must have an
  --    ACTIVE production (or 'any') mapping to entitlement 'pro'.
  if v_ev.product_id is not null then
    v_catalogue_match := exists (
      select 1 from public.billing_product_catalog c
      where c.provider = 'revenuecat'
        and c.external_product_id = v_ev.product_id
        and c.is_active
        and c.environment in ('production', 'any')
        and c.entitlement_id = 'pro'
        and (v_ev.platform is null or v_ev.platform = 'unknown'
             or c.platform in (v_ev.platform, 'any'))
    );
  end if;

  -- 4. Shared resolver result — the single source of entitlement truth.
  select * into v_ea from public._admin_effective_access(p_user_id);

  -- 5. Open alerts / open review items for this user.
  select count(*) into v_open_alerts
  from public.billing_admin_alerts a
  where a.resolved_user_id = p_user_id
    and a.acknowledged_at is null;

  select count(*) into v_open_reviews
  from public.billing_provider_events e
  where e.resolved_user_id = p_user_id
    and e.processing_status in ('needs_review', 'failed')
    and e.resolved_at is null
    and e.dismissed_at is null;

  -- 6. Issue derivation (order: hard failures first, then attention).
  if v_sub_currently_valid and not coalesce(v_ea.has_access, false) then
    v_issues := array_append(v_issues, 'valid_store_subscription_but_access_denied');
    v_overall := 'failed';
  end if;

  if v_sub.id is not null
     and v_sub.status in ('active', 'trialing')
     and v_sub.current_period_end is not null
     and v_sub.current_period_end <= now()
     and (v_sub.grace_period_end is null or v_sub.grace_period_end <= now()) then
    v_issues := array_append(v_issues, 'subscription_period_lapsed_without_expiry_event');
    v_overall := 'failed';
  end if;

  if v_sub.id is null then
    v_issues := array_append(v_issues, 'no_store_subscription');
  end if;
  if v_sub.id is not null and coalesce(v_sub.environment, '') = 'sandbox' then
    v_issues := array_append(v_issues, 'sandbox_subscription');
  end if;
  if v_sub.id is not null and v_sub.status = 'expired' then
    v_issues := array_append(v_issues, 'store_subscription_expired');
  end if;
  if v_sub.id is not null and v_ev.event_type is null then
    v_issues := array_append(v_issues, 'no_provider_event_recorded');
  end if;
  if v_ev.processing_status in ('needs_review', 'failed') then
    v_issues := array_append(v_issues, 'latest_event_' || v_ev.processing_status);
  end if;
  if v_catalogue_match is false then
    v_issues := array_append(v_issues, 'product_not_in_active_catalogue');
  end if;
  if v_open_alerts > 0 then
    v_issues := array_append(v_issues, 'open_billing_alerts');
  end if;
  if v_open_reviews > 0 then
    v_issues := array_append(v_issues, 'open_review_items');
  end if;
  if v_user.banned_until is not null and v_user.banned_until > now() then
    v_issues := array_append(v_issues, 'account_disabled');
  end if;

  if v_overall <> 'failed' and array_length(v_issues, 1) is not null then
    v_overall := 'attention';
  end if;

  -- 7. Sanitised diagnostic payload (Part H contract).
  return jsonb_build_object(
    'user_id',                p_user_id,
    'has_store_subscription', (v_sub.id is not null),
    'provider',               v_sub.billing_provider,
    'purchase_platform',      v_sub.platform,
    'product_id',             v_ev.product_id,
    'catalogue_match',        v_catalogue_match,
    'subscription_status',    v_sub.status,
    'environment',            v_sub.environment,
    'cancel_at_period_end',   v_sub.cancel_at_period_end,
    'current_period_end',     v_sub.current_period_end,
    'external_subscription_id_redacted', v_redacted_ext,
    'last_provider_event',    v_sub.last_provider_event,
    'last_provider_event_at', v_sub.last_provider_event_at,
    'last_verified_at',       v_sub.last_verified_at,
    'provider_event_found',   (v_ev.event_type is not null),
    'last_event_type',        v_ev.event_type,
    'last_event_status',      v_ev.processing_status,
    'last_event_error_code',  v_ev.processing_error_code,
    'last_event_received_at', v_ev.received_at,
    'resolver_has_access',    coalesce(v_ea.has_access, false),
    'resolver_reason_code',   v_ea.reason_code,
    'resolver_plan_code',     v_ea.plan_code,
    'resolver_purchase_platform', v_ea.purchase_platform,
    'portal_access',          (coalesce(v_ea.has_access, false)
                               and coalesce(v_ea.portal_access, false)),
    'can_use_ios_app',        coalesce(v_ea.has_access, false),
    'can_use_android_app',    coalesce(v_ea.has_access, false),
    'expires_at',             coalesce(v_ea.current_period_end, v_ea.trial_end),
    'open_alert_count',       v_open_alerts,
    'open_review_count',      v_open_reviews,
    'overall_status',         v_overall,
    'issues',                 to_jsonb(v_issues),
    'checked_at',             now());
end;
$$;

revoke all on function public.admin_validate_user_store_entitlement(uuid) from public;
grant execute on function public.admin_validate_user_store_entitlement(uuid) to authenticated;

comment on function public.admin_validate_user_store_entitlement(uuid) is
  'SQL 150 (Phase 2D Part H): read-only System-Admin diagnostic validating one user''s store entitlement end to end — store subscription row, catalogue mapping, provider events (SQL 148 review state), shared resolver result (_admin_effective_access, identical to get_my_vinetrack_access), SQL 146 platform booleans, open alerts/review counts — returning overall_status healthy|attention|failed and issues[]. Never returns receipts, tokens, raw payloads or signatures; external ids redacted first4…last4. No writes.';

commit;

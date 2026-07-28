-- =====================================================================
-- 136_deactivate_unverified_ios_catalog_rows.sql
-- =====================================================================
-- Phase 2B (revised) — fail-close the three UNVERIFIED iOS catalogue rows.
--
-- Context: there are currently NO paying VineTrack customers, so there is
-- no subscriber-continuity reason to keep unverified legacy mappings
-- active. The three iOS product ids below were seeded as PLACEHOLDERS
-- (SQL 134) and later activated before being confirmed against the live
-- RevenueCat offering / App Store Connect. Until each exact product id is
-- confirmed to (a) exist in the store, (b) be attached to RevenueCat
-- entitlement 'pro', and (c) be intentionally supported for purchase or
-- renewal, it must stay inactive — the webhook then classifies events for
-- it as needs_review and grants no access (fail-closed).
--
-- The verified Android row (vinetrack_solo_yearly) is NOT touched.
--
-- Idempotent: re-running is a no-op once the rows are inactive.
-- =====================================================================

begin;

update public.billing_product_catalog
set is_active = false,
    metadata  = metadata || jsonb_build_object(
      'note', 'Deactivated (Phase 2B revised): unverified placeholder — confirm exact product id in RevenueCat offering + App Store Connect, attached to entitlement pro, before reactivating',
      'deactivated_at', now()::text
    )
where provider = 'revenuecat'
  and platform = 'ios'
  and external_product_id in (
    'com.vinetrack.solo.yearly',
    'com.vinetrack.legacy.monthly',
    'com.vinetrack.legacy.yearly'
  );

commit;

-- Verification: expect exactly ONE active row (android / vinetrack_solo_yearly).
-- select platform, external_product_id, environment, plan_code, entitlement_id, is_active
-- from public.billing_product_catalog
-- where provider = 'revenuecat'
-- order by is_active desc, platform, external_product_id;

-- =====================================================================
-- ROLLBACK (only after each product id is confirmed live + attached to
-- entitlement 'pro' in the RevenueCat dashboard — activate per product,
-- never blanket-reactivate):
--
-- update public.billing_product_catalog
-- set is_active = true
-- where provider = 'revenuecat'
--   and platform = 'ios'
--   and external_product_id = '<CONFIRMED_PRODUCT_ID>';
-- =====================================================================

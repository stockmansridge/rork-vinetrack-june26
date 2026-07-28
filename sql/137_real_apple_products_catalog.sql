-- =====================================================================
-- 137_real_apple_products_catalog.sql
-- =====================================================================
-- Phase 2B — register the REAL Apple subscription products confirmed in
-- App Store Connect (app 6761143377, subscription group "VineTrack Pro",
-- both state APPROVED):
--
--     monthly_999   ONE_MONTH   "Monthly Premium"
--     yearly_9999   ONE_YEAR    "Yearly Premium"
--
-- These differ from ALL three placeholder iOS rows seeded by SQL 134
-- (com.vinetrack.solo.yearly / com.vinetrack.legacy.monthly /
-- com.vinetrack.legacy.yearly), which SQL 136 deactivates and which stay
-- inactive for reference.
--
-- PART 1 (safe to run now): ADDITIVE inserts, is_active = false.
--   Unknown products remain fail-closed: a webhook event for an inactive
--   row is stored as needs_review and grants nothing.
--
-- PART 2 (activation — run ONLY after BOTH confirmations):
--   a) RevenueCat dashboard shows the product attached to entitlement
--      exactly 'pro' and present in the current offering, AND
--   b) the controlled TestFlight purchase webhook event carries the same
--      product id.
--   Activate per product — never blanket-activate.
--
-- Plan mapping (verify against vinetrack_plans before activating):
--   yearly_9999  → 'solo'            (yearly Solo — mirrors the verified
--                                     Android row vinetrack_solo_yearly)
--   monthly_999  → 'legacy_monthly'  (the only monthly plan code; if a
--                                     dedicated monthly Solo plan is
--                                     intended, create it first and remap)
-- One product maps to exactly ONE plan; the UNIQUE index on
-- (provider, platform, environment, external_product_id) rejects
-- duplicate mappings structurally.
-- =====================================================================

-- ---------------------------------------------------------------------
-- PART 1 — additive, inactive registration (idempotent).
-- ---------------------------------------------------------------------
begin;

insert into public.billing_product_catalog
  (provider, platform, environment, external_product_id, plan_code, entitlement_id, is_active, licence_quantity, metadata)
values
  ('revenuecat', 'ios', 'production', 'yearly_9999', 'solo', 'pro', false, 1,
   '{"note":"REAL App Store product (ASC group VineTrack Pro, APPROVED, ONE_YEAR, name Yearly Premium). Activate only after RevenueCat dashboard shows it attached to entitlement pro AND the controlled TestFlight purchase webhook confirms this exact id.","source":"asc_audit_2026-07-28"}'::jsonb),
  ('revenuecat', 'ios', 'production', 'monthly_999', 'legacy_monthly', 'pro', false, 1,
   '{"note":"REAL App Store product (ASC group VineTrack Pro, APPROVED, ONE_MONTH, name Monthly Premium). Verify intended plan mapping (legacy_monthly is the only monthly plan code) and RevenueCat pro attachment before activating.","source":"asc_audit_2026-07-28"}'::jsonb)
on conflict (provider, platform, environment, external_product_id) do nothing;

commit;

-- Verification after PART 1: the two new rows exist, inactive; only the
-- Android row is active.
-- select provider, platform, environment, external_product_id, plan_code,
--        entitlement_id, is_active, licence_quantity
-- from public.billing_product_catalog
-- order by platform, external_product_id;

-- ---------------------------------------------------------------------
-- PART 2 — ACTIVATION (do NOT run until dashboard + purchase confirm).
-- Run per product, only for the product actually being sold:
-- ---------------------------------------------------------------------
-- update public.billing_product_catalog
-- set is_active = true
-- where provider = 'revenuecat' and platform = 'ios'
--   and environment = 'production'
--   and external_product_id = 'yearly_9999';
--
-- update public.billing_product_catalog
-- set is_active = true
-- where provider = 'revenuecat' and platform = 'ios'
--   and environment = 'production'
--   and external_product_id = 'monthly_999';

-- ---------------------------------------------------------------------
-- ROLLBACK (per product — returns to fail-closed):
-- ---------------------------------------------------------------------
-- update public.billing_product_catalog
-- set is_active = false
-- where provider = 'revenuecat' and platform = 'ios'
--   and environment = 'production'
--   and external_product_id in ('yearly_9999', 'monthly_999');

-- ---------------------------------------------------------------------
-- AMBIGUITY CHECK (must return ZERO rows — one product, one plan):
-- ---------------------------------------------------------------------
-- select provider, platform, environment, external_product_id,
--        count(distinct plan_code) as plan_count
-- from public.billing_product_catalog
-- where is_active
-- group by 1, 2, 3, 4
-- having count(distinct plan_code) > 1;

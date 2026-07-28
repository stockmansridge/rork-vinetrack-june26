-- =====================================================================
-- 138_activate_verified_production_products.sql
-- =====================================================================
-- Phase 2B CLOSEOUT — activate ONLY the two verified production products
-- and fail-close everything else in billing_product_catalog.
--
-- Verified products (both attached to RevenueCat entitlement 'pro',
-- controlled purchase flows treated as provisionally successful):
--
--   ios     / production / yearly_9999            -> plan 'solo', qty 1
--   android / production / vinetrack_solo_yearly  -> plan 'solo', qty 1
--
-- Stays / becomes INACTIVE (fail-closed; webhook -> needs_review, no access):
--
--   monthly_999                  (real ASC product; NOT launching monthly yet)
--   REAL_ID_FROM_RC              (accidental row — a literal example
--                                 placeholder was pasted into an UPDATE that
--                                 renamed com.vinetrack.solo.yearly; it may
--                                 also still be ACTIVE from the earlier
--                                 blanket "activate all ios" update that ran
--                                 BEFORE SQL 136. SQL 136 only matched the
--                                 three original names, so this migration
--                                 catches it explicitly.)
--   com.vinetrack.solo.yearly    (placeholder, may no longer exist post-rename)
--   com.vinetrack.legacy.monthly (placeholder)
--   com.vinetrack.legacy.yearly  (placeholder)
--   any sandbox / 'any'-environment leftovers
--
-- Safety properties:
--   * ADDITIVE — no rows deleted; inactive rows stay for reference.
--   * Idempotent — safe to re-run.
--   * Self-asserting — the transaction ABORTS (nothing is committed) unless
--     the final state is exactly: 2 active rows, both entitlement 'pro',
--     environment 'production', plan 'solo', licence_quantity 1, and no
--     ambiguous product→plan mapping.
--   * Does not touch subscriptions, licences, entitlements or the
--     use_shared_supabase_entitlement rollout flag (stays 'internal').
-- =====================================================================

begin;

-- Preconditions --------------------------------------------------------
do $$
begin
  if to_regclass('public.billing_product_catalog') is null then
    raise exception 'SQL 138 precondition failed: apply sql/134 first';
  end if;
  if not exists (select 1 from public.vinetrack_plans where code = 'solo') then
    raise exception 'SQL 138 precondition failed: plan ''solo'' missing';
  end if;
end$$;

-- A. Ensure the verified iOS row exists (additive; covers the case where
--    SQL 137 PART 1 was not run). No-op if already present.
insert into public.billing_product_catalog
  (provider, platform, environment, external_product_id, plan_code, entitlement_id, is_active, licence_quantity, metadata)
values
  ('revenuecat', 'ios', 'production', 'yearly_9999', 'solo', 'pro', false, 1,
   '{"note":"REAL App Store product (ASC group VineTrack Pro, APPROVED, ONE_YEAR, name Yearly Premium)","source":"asc_audit_2026-07-28"}'::jsonb)
on conflict (provider, platform, environment, external_product_id) do nothing;

-- B. Normalise the verified products back to environment = 'production'
--    (an earlier manual UPDATE set active rows to 'any'). Guarded against
--    the UNIQUE index: only rename when no production twin already exists.
update public.billing_product_catalog c
set environment = 'production'
where c.provider = 'revenuecat'
  and c.environment = 'any'
  and (   (c.platform = 'ios'     and c.external_product_id = 'yearly_9999')
       or (c.platform = 'android' and c.external_product_id = 'vinetrack_solo_yearly'))
  and not exists (
    select 1 from public.billing_product_catalog d
    where d.provider = c.provider
      and d.platform = c.platform
      and d.environment = 'production'
      and d.external_product_id = c.external_product_id
  );

-- C. FAIL-CLOSE everything that is not a verified production mapping.
--    This explicitly catches the accidental REAL_ID_FROM_RC row (still
--    active from the pre-136 blanket iOS activation), monthly_999 if it was
--    ever activated, all placeholders, and any sandbox/'any' leftovers.
update public.billing_product_catalog
set is_active = false,
    metadata  = metadata || jsonb_build_object(
      'note', 'Deactivated by SQL 138 (Phase 2B closeout): not a verified production product — fail-closed. Webhook events for this product become needs_review and grant no access.',
      'deactivated_at', now()::text
    )
where provider = 'revenuecat'
  and is_active
  and not (
    environment = 'production'
    and (   (platform = 'ios'     and external_product_id = 'yearly_9999')
         or (platform = 'android' and external_product_id = 'vinetrack_solo_yearly'))
  );

-- C2. Annotate the accidental row for future readers (idempotent; the row
--     only exists if the earlier mis-run rename happened).
update public.billing_product_catalog
set metadata = metadata || jsonb_build_object(
  'note', 'ACCIDENTAL ROW: created when the literal example placeholder REAL_ID_FROM_RC was pasted into a rename of com.vinetrack.solo.yearly. Not a real store product. Keep inactive; retained for audit reference only.'
)
where provider = 'revenuecat'
  and external_product_id = 'REAL_ID_FROM_RC';

-- D. Activate the VERIFIED iOS yearly product.
update public.billing_product_catalog
set is_active        = true,
    plan_code        = 'solo',
    entitlement_id   = 'pro',
    licence_quantity = 1,
    metadata         = (metadata - 'note' - 'deactivated_at') || jsonb_build_object(
      'note', 'VERIFIED production product: ASC app 6761143377, subscription group "VineTrack Pro", yearly_9999 (ONE_YEAR, "Yearly Premium", APPROVED), attached to RevenueCat entitlement pro. Controlled TestFlight purchase flow provisionally successful (Phase 2B closeout).',
      'verified_at', now()::text,
      'verified_by', 'phase2b_closeout_sql_138'
    )
where provider = 'revenuecat'
  and platform = 'ios'
  and environment = 'production'
  and external_product_id = 'yearly_9999';

-- E. Confirm the VERIFIED Android yearly product (replaces the old
--    "PLACEHOLDER" metadata note — it is confirmed real).
update public.billing_product_catalog
set is_active        = true,
    plan_code        = 'solo',
    entitlement_id   = 'pro',
    licence_quantity = 1,
    metadata         = (metadata - 'note' - 'deactivated_at') || jsonb_build_object(
      'note', 'VERIFIED production product: Google Play subscription vinetrack_solo_yearly, attached to RevenueCat entitlement pro. Controlled licence-test purchase flow provisionally successful (Phase 2B closeout).',
      'verified_at', now()::text,
      'verified_by', 'phase2b_closeout_sql_138'
    )
where provider = 'revenuecat'
  and platform = 'android'
  and environment = 'production'
  and external_product_id = 'vinetrack_solo_yearly';

-- F. ASSERTIONS — abort the whole transaction unless the state is exact.
do $$
declare
  v_active integer;
  v_bad    integer;
begin
  select count(*) into v_active
  from public.billing_product_catalog
  where is_active;

  if v_active <> 2 then
    raise exception 'SQL 138 assertion failed: expected exactly 2 active catalogue rows, found % — transaction rolled back', v_active;
  end if;

  select count(*) into v_bad
  from public.billing_product_catalog
  where is_active
    and not (
      provider = 'revenuecat'
      and entitlement_id = 'pro'
      and environment = 'production'
      and plan_code = 'solo'
      and licence_quantity = 1
      and (   (platform = 'ios'     and external_product_id = 'yearly_9999')
           or (platform = 'android' and external_product_id = 'vinetrack_solo_yearly'))
    );
  if v_bad > 0 then
    raise exception 'SQL 138 assertion failed: % active row(s) outside the verified set — transaction rolled back', v_bad;
  end if;

  -- Ambiguity: one active product must map to exactly one plan.
  select count(*) into v_bad
  from (
    select provider, platform, environment, external_product_id
    from public.billing_product_catalog
    where is_active
    group by 1, 2, 3, 4
    having count(distinct plan_code) > 1
  ) q;
  if v_bad > 0 then
    raise exception 'SQL 138 assertion failed: ambiguous active product→plan mapping — transaction rolled back';
  end if;
end$$;

commit;

-- =====================================================================
-- VERIFICATION (run after commit; paste results back for the report):
-- =====================================================================
-- select provider, platform, environment, external_product_id, plan_code,
--        entitlement_id, is_active, licence_quantity,
--        metadata->>'verified_at' as verified_at
-- from public.billing_product_catalog
-- order by is_active desc, platform, external_product_id;
--
-- Ambiguity check (must return ZERO rows):
-- select provider, platform, environment, external_product_id,
--        count(distinct plan_code) as plan_count
-- from public.billing_product_catalog
-- where is_active
-- group by 1, 2, 3, 4
-- having count(distinct plan_code) > 1;

-- =====================================================================
-- ROLLBACK (returns the catalogue to fully fail-closed — no product can
-- create NEW access; existing verified subscription rows are untouched
-- and keep granting until their own lifecycle ends):
--
-- update public.billing_product_catalog
-- set is_active = false,
--     metadata  = metadata || jsonb_build_object(
--       'note', 'Rolled back by SQL 138 rollback', 'deactivated_at', now()::text)
-- where provider = 'revenuecat'
--   and (   (platform = 'ios'     and external_product_id = 'yearly_9999')
--        or (platform = 'android' and external_product_id = 'vinetrack_solo_yearly'));
-- =====================================================================

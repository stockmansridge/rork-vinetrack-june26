-- =====================================================================
-- tests/132_live_jonathan_and_grant_checks.sql
-- =====================================================================
-- Phase 2A §2 — LIVE verification of the Jonathan Auth + Billing Grant
-- linkage. READ-ONLY: every statement is a SELECT; nothing is modified.
--
-- HOW TO RUN: paste into the Supabase SQL editor (service role) and run
-- block by block. The Rork sandbox has no service-role credentials, so
-- this must be executed there.
--
-- Do NOT hard-code this email into any application logic — it is used
-- here only as a lookup key for the one-off diagnostic.
-- =====================================================================

-- (a) Does the auth account exist, is it confirmed, when did it sign in?
--     → If no row: the account must be created/invited first (do NOT
--       silently create one). If email_confirmed_at is null: that is the
--       portal login failure (authentication, not entitlement).
select id as user_id,
       lower(email) as email,
       created_at,
       email_confirmed_at,
       last_sign_in_at,
       banned_until
from auth.users
where lower(email) = 'jonathan@stockmansridge.com.au';

-- (b) Every manual/unlimited grant row, with owner + validity breakdown.
--     → Confirm the grant's owner_user_id equals (a)'s user_id, that
--       is_live = true, plan_code = 'internal_unlimited', not revoked,
--       not expired.
select s.id as subscription_id,
       s.owner_user_id,
       lower(u.email) as owner_email,
       p.code as plan_code,
       s.status,
       s.unlimited_licences,
       s.manual_grant_reason,
       s.manual_grant_expires_at,
       s.manual_grant_revoked_at,
       s.started_at,
       s.deleted_at,
       (s.deleted_at is null
        and coalesce(s.unlimited_licences, false)
        and s.status in ('trialing','active','manual','past_due')
        and s.manual_grant_revoked_at is null
        and (s.manual_grant_expires_at is null or s.manual_grant_expires_at > now())
        and (s.started_at is null or s.started_at <= now())) as is_live
from public.vinetrack_subscriptions s
join public.vinetrack_plans p on p.id = s.plan_id
left join auth.users u on u.id = s.owner_user_id
where coalesce(s.unlimited_licences, false) = true
   or s.manual_grant_reason is not null
   or p.code = 'internal_unlimited'
order by s.updated_at desc;

-- (c) Stockmans Ridge vineyard membership + role for that user.
select vm.vineyard_id, v.name as vineyard_name, vm.role, vm.created_at
from public.vineyard_members vm
join public.vineyards v on v.id = vm.vineyard_id
where vm.user_id = (
  select id from auth.users
  where lower(email) = 'jonathan@stockmansridge.com.au'
);

-- (d) What the SQL 132 resolver returns FOR THAT USER (impersonated).
--     Run this whole block in ONE statement batch so the impersonation
--     setting applies. Expected after SQL 132 with a live grant:
--       has_supabase_access = true, reason_code = 'internal_unlimited',
--       is_unlimited = true, enforcement_enabled = true.
begin;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select id from auth.users
            where lower(email) = 'jonathan@stockmansridge.com.au'),
    'role', 'authenticated'
  )::text,
  true
);
select * from public.get_my_vinetrack_access();
rollback;  -- discards the impersonation AND the resolver's audit write

-- (e) Rollout flag state (who is currently enforced on iOS).
select key, is_enabled, value, updated_at
from public.system_feature_flags
where key = 'use_shared_supabase_entitlement';

-- (f) If (b) shows the grant pointing at a DIFFERENT user id than (a):
--     corrective SQL — prepared but COMMENTED OUT. Review before running.
--     Re-issues the grant against the correct auth user via the audited
--     admin RPC (as a System Admin session), then revokes the misdirected
--     row via admin_revoke_unlimited_access(<old subscription_id>).
--
-- select public.admin_grant_unlimited_access(
--   p_owner_user_id := '<correct user id from (a)>'::uuid,
--   p_vineyard_id   := '<stockmans ridge vineyard id from (c)>'::uuid,
--   p_reason        := 'Re-linked Internal Unlimited grant to correct auth user',
--   p_expires_at    := null
-- );
-- select public.admin_revoke_unlimited_access('<old subscription_id>'::uuid, true);

-- =====================================================================
-- RevenueCat live checks (dashboard — no API secret is available here):
--   1. Entitlements → confirm the production entitlement id is exactly
--      "pro" and list every Apple + Google product attached to it.
--      Any purchasable product NOT attached to "pro" will charge the
--      customer without unlocking the app — report it.
--   2. Offerings → confirm which offering is "current", its packages,
--      and that the Basic ($5/$30) products are NOT in the default
--      offering (per SubscriptionService.swift's contract comment).
--   3. Customers → search by the Supabase user id from (a) (NOT email).
--      Check: aliases/anonymous ids, whether "pro" is active/absent,
--      last seen platform + app version, linked store transactions.
--   4. Targeting / Experiments / customer attributes → confirm no
--      override or experiment affects this customer's offering.
--   5. Webhook config → the draft supabase/functions/revenuecat-webhook
--      maps entitlement "premium" while the apps use "pro". Phase 2B
--      fixes this; do not enable the webhook in Phase 2A.
-- =====================================================================

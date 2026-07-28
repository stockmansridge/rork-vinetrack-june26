-- =====================================================================
-- 135_verified_store_entitlement_resolver.sql
-- =====================================================================
-- Phase 2B (3 of 3) — extend get_my_vinetrack_access() so VERIFIED
-- app-store subscriptions (written by the RevenueCat webhook, SQL 133/134)
-- are a trusted Supabase source, recognised on iOS, Android AND the portal.
--
-- What this migration does (all ADDITIVE / backward compatible):
--   A. DROPs and recreates public.get_my_vinetrack_access() with:
--        * the SAME first 30 output columns, same names/order/types as
--          SQL 132 — every released Android build and the Portal keep
--          parsing unchanged;
--        * THREE new appended columns:
--            purchase_platform    text        ('ios'|'android'|'web'|null —
--                                              where the purchase happened,
--                                              NOT where VineTrack works)
--            cancel_at_period_end boolean
--            grace_period_end     timestamptz
--        * new validity rules (server time only):
--            - sandbox rows NEVER grant access
--              (environment is null or <> 'sandbox');
--            - billing-issue grace: status 'past_due' grants access while
--              grace_period_end > now() (in addition to the existing
--              unlimited-grant past_due exemption);
--            - an 'active' row past current_period_end still grants access
--              while grace_period_end > now() (provider-supplied grace);
--        * cross-platform access preserved: can_use_ios_app,
--          can_use_android_app and portal flags all derive from the SAME
--          has-access decision — an Apple purchase unlocks Android + portal
--          and a Google purchase unlocks iOS + portal.
--        * precedence UNCHANGED from Phase 2A:
--            internal_unlimited > enterprise > team > legacy > solo
--          (verified store subscriptions are 'solo'/'legacy' tier rows, so
--          Internal Unlimited and Team/Enterprise still override them; the
--          store subscription still beats the client-side account trial,
--          which is not a Supabase source at all.)
--   B. Adds public.admin_store_subscription_diagnostics(p_limit) — a
--      System-Admin-only RPC exposing store-sync state with REDACTED
--      external ids. No receipts, tokens or raw payloads.
--
-- Reason codes: unchanged set. Verified store rows return
--   access_source = plan tier ('solo'/'legacy'), reason_code =
--   'app_store_subscription' (billing_provider in ('apple','google')).
--
-- ROLLBACK:
--   1. Behavioural rollback: disable the 'use_shared_supabase_entitlement'
--      flag (iOS reverts to the legacy gate; Android already tolerates
--      any response shape).
--   2. Full function rollback: re-run section E of sql/132 (drop +
--      recreate). The three appended columns disappear; clients ignore
--      their absence. drop function if exists
--      public.admin_store_subscription_diagnostics(integer);
-- =====================================================================

begin;

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'vinetrack_subscriptions'
      and column_name = 'grace_period_end'
  ) then
    raise exception 'SQL 135 precondition failed: apply sql/134 first';
  end if;
  if to_regclass('public.billing_provider_events') is null then
    raise exception 'SQL 135 precondition failed: apply sql/133 first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. get_my_vinetrack_access() — recognise verified store subscriptions.
-- ---------------------------------------------------------------------------
drop function if exists public.get_my_vinetrack_access();

create or replace function public.get_my_vinetrack_access()
returns table (
  user_id                 uuid,
  has_supabase_access     boolean,
  access_source           text,
  is_owner                boolean,
  subscription_id         uuid,
  plan_code               text,
  plan_tier               text,
  plan_name               text,
  billing_provider        text,     -- 'apple' | 'google' | 'stripe' | 'manual'
  status                  text,
  trial_end               timestamptz,
  current_period_end      timestamptz,
  portal_access           boolean,
  portal_access_level     text,
  can_use_ios_app         boolean,
  can_use_portal          boolean,
  seats_included          integer,
  seats_purchased         integer,
  active_licences         integer,
  vineyard_id             uuid,
  licence_id              uuid,
  unlimited_licences      boolean,
  manual_grant_reason     text,
  manual_grant_expires_at timestamptz,
  solo_check_required     boolean,
  reason_code             text,
  is_unlimited            boolean,
  can_use_android_app     boolean,
  last_verified_at        timestamptz,
  enforcement_enabled     boolean,
  -- ---- NEW (SQL 135, appended — additive only) ----
  purchase_platform       text,
  cancel_at_period_end    boolean,
  grace_period_end        timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();

  v_sub_id          uuid;
  v_is_owner        boolean;
  v_status          text;
  v_provider        text;
  v_trial_end       timestamptz;
  v_period_end      timestamptz;
  v_seats_included  integer;
  v_seats_purchased integer;
  v_unlimited       boolean;
  v_grant_reason    text;
  v_grant_expires   timestamptz;
  v_plan_code       text;
  v_plan_tier       text;
  v_plan_name       text;
  v_portal_level    text;
  v_active_licences integer;
  v_licence_id      uuid;
  v_vineyard_id     uuid;
  v_platform        text;
  v_cancel_at_end   boolean;
  v_grace_end       timestamptz;

  v_has     boolean := false;
  v_source  text := 'none';
  v_reason  text := 'no_entitlement';
  v_enforce boolean := false;

  v_prev_has    boolean;
  v_prev_source text;
  v_prev_reason text;
  v_event       text;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- ---- 1. Best VALID entitlement (server time only; deterministic order).
  select
    b.id, b.b_is_owner, b.b_status, b.b_provider, b.b_trial_end, b.b_period_end,
    b.b_seats_included, b.b_seats_purchased, b.b_unlimited, b.b_grant_reason,
    b.b_grant_expires, b.b_plan_code, b.b_plan_tier, b.b_plan_name,
    b.b_portal_level, b.b_active_licences, b.b_licence_id, b.b_vineyard_id,
    b.b_platform, b.b_cancel_at_end, b.b_grace_end
  into
    v_sub_id, v_is_owner, v_status, v_provider, v_trial_end, v_period_end,
    v_seats_included, v_seats_purchased, v_unlimited, v_grant_reason,
    v_grant_expires, v_plan_code, v_plan_tier, v_plan_name,
    v_portal_level, v_active_licences, v_licence_id, v_vineyard_id,
    v_platform, v_cancel_at_end, v_grace_end
  from (select 1) one
  left join (
    select
      s.id,
      (s.owner_user_id = v_uid)             as b_is_owner,
      s.status                               as b_status,
      s.billing_provider                     as b_provider,
      s.trial_end                            as b_trial_end,
      s.current_period_end                   as b_period_end,
      s.seats_included                       as b_seats_included,
      s.seats_purchased                      as b_seats_purchased,
      coalesce(s.unlimited_licences, false)  as b_unlimited,
      s.manual_grant_reason                  as b_grant_reason,
      s.manual_grant_expires_at              as b_grant_expires,
      p.code                                 as b_plan_code,
      p.tier                                 as b_plan_tier,
      p.name                                 as b_plan_name,
      p.portal_access_level                  as b_portal_level,
      s.platform                             as b_platform,
      coalesce(s.cancel_at_period_end, false) as b_cancel_at_end,
      s.grace_period_end                     as b_grace_end,
      (
        select count(*)::integer
        from public.vinetrack_user_licences cl
        where cl.subscription_id = s.id
          and cl.status = 'active'
      ) as b_active_licences,
      (
        select ul.id
        from public.vinetrack_user_licences ul
        where ul.subscription_id = s.id
          and ul.user_id = v_uid
          and ul.status = 'active'
        order by ul.id
        limit 1
      ) as b_licence_id,
      coalesce(
        (
          select ul2.vineyard_id
          from public.vinetrack_user_licences ul2
          where ul2.subscription_id = s.id
            and ul2.user_id = v_uid
            and ul2.status = 'active'
          order by ul2.id
          limit 1
        ),
        s.primary_vineyard_id
      ) as b_vineyard_id,
      case
        when p.code = 'internal_unlimited' then 6
        when p.tier = 'enterprise'         then 5
        when p.tier = 'team'               then 4
        when p.tier = 'legacy'             then 3
        when p.tier = 'solo'               then 2
        else 1
      end as tier_rank
    from public.vinetrack_subscriptions s
    join public.vinetrack_plans p on p.id = s.plan_id
    where s.deleted_at is null
      -- Sandbox purchases NEVER grant production access (SQL 135).
      and (s.environment is null or s.environment <> 'sandbox')
      -- Ownership: the entitlement must belong to the caller.
      and (
        s.owner_user_id = v_uid
        or exists (
          select 1 from public.vinetrack_user_licences l
          where l.subscription_id = s.id
            and l.user_id = v_uid
            and l.status = 'active'
        )
      )
      -- Status gate: past_due survives under an unlimited grant (SQL 132)
      -- OR while a provider-supplied billing-issue grace holds (SQL 135).
      and (
        s.status in ('trialing', 'active', 'manual')
        or (coalesce(s.unlimited_licences, false) = true and s.status = 'past_due')
        or (s.status = 'past_due' and s.grace_period_end is not null and s.grace_period_end > now())
      )
      -- Future-starting entitlements do not grant access yet.
      and (s.started_at is null or s.started_at <= now())
      -- Trial expiry enforced at read time.
      and (s.status <> 'trialing' or s.trial_end is null or s.trial_end > now())
      -- Paid period expiry enforced at read time. Unlimited grants exempt;
      -- provider grace (grace_period_end) extends an elapsed period (SQL 135).
      and (
        coalesce(s.unlimited_licences, false) = true
        or s.status not in ('active', 'past_due')
        or s.current_period_end is null
        or s.current_period_end > now()
        or (s.grace_period_end is not null and s.grace_period_end > now())
      )
      -- Revoked / expired manual grants never grant access.
      and (coalesce(s.unlimited_licences, false) = false or s.manual_grant_revoked_at is null)
      and (
        coalesce(s.unlimited_licences, false) = false
        or s.manual_grant_expires_at is null
        or s.manual_grant_expires_at > now()
      )
    order by
      tier_rank desc,
      (s.status = 'trialing') asc,
      (s.owner_user_id = v_uid) desc,
      s.current_period_end desc nulls last,
      s.created_at desc,
      s.id
    limit 1
  ) b on true;

  -- ---- 2. Reason code.
  if v_sub_id is not null then
    v_has := true;
    v_source := coalesce(v_plan_tier, 'none');
    v_reason := case
      when v_plan_code = 'internal_unlimited'            then 'internal_unlimited'
      when v_plan_tier = 'enterprise'                    then 'enterprise_subscription'
      when v_status = 'trialing'
           and v_provider not in ('apple', 'google')     then 'active_trial'
      when v_licence_id is not null
           and coalesce(v_is_owner, false) = false
           and v_provider not in ('apple', 'google')     then 'assigned_licence'
      when v_provider in ('apple', 'google')             then 'app_store_subscription'
      else 'portal_subscription'
    end;
  else
    select case
      when s2.manual_grant_revoked_at is not null
        or s2.status = 'canceled'
        or s2.deleted_at is not null                                  then 'revoked'
      when s2.status = 'expired'                                      then 'expired'
      when s2.status = 'trialing'
        and s2.trial_end is not null and s2.trial_end <= now()        then 'expired'
      when s2.status in ('active', 'past_due')
        and s2.current_period_end is not null
        and s2.current_period_end <= now()                            then 'expired'
      when coalesce(s2.unlimited_licences, false) = true
        and s2.manual_grant_expires_at is not null
        and s2.manual_grant_expires_at <= now()                       then 'expired'
      else 'no_entitlement'
    end
    into v_reason
    from public.vinetrack_subscriptions s2
    where s2.owner_user_id = v_uid
       or exists (
         select 1 from public.vinetrack_user_licences l2
         where l2.subscription_id = s2.id and l2.user_id = v_uid
       )
    order by s2.updated_at desc, s2.id
    limit 1;

    v_reason := coalesce(v_reason, 'no_entitlement');
  end if;

  -- ---- 3. Per-caller rollout flag.
  v_enforce := public._entitlement_enforcement_enabled(
    v_uid,
    v_has and v_reason = 'internal_unlimited'
  );

  -- ---- 4. Change-detected audit (guarded: never blocks resolution).
  begin
    select es.has_access, es.access_source, es.reason_code
      into v_prev_has, v_prev_source, v_prev_reason
    from public.vinetrack_entitlement_state es
    where es.user_id = v_uid;

    if not found then
      insert into public.vinetrack_entitlement_state
        (user_id, has_access, access_source, reason_code, plan_code, updated_at)
      values (v_uid, v_has, v_source, v_reason, v_plan_code, now());

      insert into public.vinetrack_entitlement_audit
        (user_id, event_type, previous_state, new_state, platform)
      values (
        v_uid,
        case when v_has then 'entitlement_granted' else 'entitlement_denied' end,
        null,
        jsonb_build_object(
          'has_access', v_has, 'access_source', v_source,
          'reason_code', v_reason, 'plan_code', v_plan_code
        ),
        'server'
      );
    elsif v_prev_has is distinct from v_has
       or v_prev_source is distinct from v_source
       or v_prev_reason is distinct from v_reason then

      v_event := case
        when v_has and not coalesce(v_prev_has, false) then 'entitlement_granted'
        when not v_has and coalesce(v_prev_has, false) then
          case v_reason
            when 'expired' then 'entitlement_expired'
            when 'revoked' then 'entitlement_revoked'
            else 'entitlement_denied'
          end
        else 'entitlement_source_changed'
      end;

      update public.vinetrack_entitlement_state es
      set has_access    = v_has,
          access_source = v_source,
          reason_code   = v_reason,
          plan_code     = v_plan_code,
          updated_at    = now()
      where es.user_id = v_uid;

      insert into public.vinetrack_entitlement_audit
        (user_id, event_type, previous_state, new_state, platform)
      values (
        v_uid,
        v_event,
        jsonb_build_object(
          'has_access', v_prev_has, 'access_source', v_prev_source,
          'reason_code', v_prev_reason
        ),
        jsonb_build_object(
          'has_access', v_has, 'access_source', v_source,
          'reason_code', v_reason, 'plan_code', v_plan_code
        ),
        'server'
      );
    end if;
  exception when others then
    null;
  end;

  -- ---- 5. Response (existing 30 columns unchanged; 3 appended).
  return query select
    v_uid,
    v_has,
    v_source,
    coalesce(v_is_owner, false),
    v_sub_id,
    v_plan_code,
    v_plan_tier,
    v_plan_name,
    v_provider,
    v_status,
    v_trial_end,
    v_period_end,
    (v_has and coalesce(v_portal_level, 'none') <> 'none'),
    coalesce(v_portal_level, 'none'),
    v_has,                                   -- can_use_ios_app (any purchase platform)
    (v_has and coalesce(v_portal_level, 'none') <> 'none'),
    v_seats_included,
    v_seats_purchased,
    coalesce(v_active_licences, 0),
    v_vineyard_id,
    v_licence_id,
    coalesce(v_unlimited, false),
    v_grant_reason,
    v_grant_expires,
    (not v_has),                             -- solo_check_required
    v_reason,
    coalesce(v_unlimited, false),
    v_has,                                   -- can_use_android_app (any purchase platform)
    now(),
    v_enforce,
    v_platform,                              -- purchase_platform (NEW)
    coalesce(v_cancel_at_end, false),        -- cancel_at_period_end (NEW)
    v_grace_end;                             -- grace_period_end (NEW)
end;
$$;

revoke all on function public.get_my_vinetrack_access() from public;
grant execute on function public.get_my_vinetrack_access() to authenticated;

comment on function public.get_my_vinetrack_access() is
  'SQL 135 shared entitlement resolver. Backward compatible with sql/132: first 30 output columns unchanged. Appended: purchase_platform, cancel_at_period_end, grace_period_end. New rules: sandbox rows never grant access; billing-issue grace (grace_period_end) keeps past_due/elapsed-period rows valid until grace end. Verified store subscriptions (billing_provider apple/google, written by the RevenueCat webhook) return reason_code app_store_subscription and unlock iOS, Android and the portal alike.';

-- ---------------------------------------------------------------------------
-- B. Admin diagnostics — store-sync overview with redacted identifiers.
-- ---------------------------------------------------------------------------
create or replace function public.admin_store_subscription_diagnostics(
  p_limit integer default 100
)
returns table (
  user_id                  uuid,
  plan_code                text,
  billing_provider         text,
  platform                 text,
  environment              text,
  status                   text,
  external_subscription_ref text,      -- redacted: first4…last4
  current_period_end       timestamptz,
  grace_period_end         timestamptz,
  cancel_at_period_end     boolean,
  expired_at               timestamptz,
  last_provider_event      text,
  last_provider_event_at   timestamptz,
  last_verified_at         timestamptz,
  needs_review_events      integer,
  failed_events            integer,
  last_event_received_at   timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    s.owner_user_id,
    p.code,
    s.billing_provider,
    s.platform,
    s.environment,
    s.status,
    case
      when s.external_subscription_id is null then null
      when length(s.external_subscription_id) <= 8 then '…'
      else left(s.external_subscription_id, 4) || '…' || right(s.external_subscription_id, 4)
    end,
    s.current_period_end,
    s.grace_period_end,
    s.cancel_at_period_end,
    s.expired_at,
    s.last_provider_event,
    s.last_provider_event_at,
    s.last_verified_at,
    (select count(*)::integer from public.billing_provider_events e
      where e.resolved_user_id = s.owner_user_id and e.processing_status = 'needs_review'),
    (select count(*)::integer from public.billing_provider_events e
      where e.resolved_user_id = s.owner_user_id and e.processing_status = 'failed'),
    (select max(e.received_at) from public.billing_provider_events e
      where e.resolved_user_id = s.owner_user_id)
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  where public.is_system_admin()
    and s.deleted_at is null
    and s.billing_provider in ('apple', 'google')
  order by s.updated_at desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

revoke all on function public.admin_store_subscription_diagnostics(integer) from public;
grant execute on function public.admin_store_subscription_diagnostics(integer) to authenticated;

comment on function public.admin_store_subscription_diagnostics(integer) is
  'SQL 135: System-Admin-only store-sync diagnostics. External subscription ids are redacted (first4…last4); returns zero rows for non-admin callers. No receipts, tokens or raw payloads.';

commit;

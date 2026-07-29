-- =====================================================================
-- 144_trial_resolver_and_admin_surface.sql
-- =====================================================================
-- Phase 2C.1 (2 of 3) — recognise the SERVER-AUTHORITATIVE account trial
-- (sql/143) in the shared entitlement resolver AND the admin read
-- surface, so iOS, Android, the portal and the Access & Entitlements
-- centre all agree on trial access.
--
-- EXISTING BEHAVIOUR BEING CORRECTED:
--   * get_my_vinetrack_access() (SQL 135) knows nothing about the account
--     trial — trial users resolve to has_access=false /
--     reason_code='no_entitlement', so the admin centre shows most users
--     as "No Access" while both mobile apps grant a LOCAL device-time
--     trial. Root cause confirmed by code audit (see sql/143 header).
--
-- WHAT THIS MIGRATION CHANGES:
--   A. DROPs and recreates public.get_my_vinetrack_access():
--        * the SAME first 33 output columns, same names/order/types as
--          SQL 135 — released Android builds and the portal keep parsing
--          unchanged;
--        * ONE new appended column:
--            expires_at timestamptz — the earliest KNOWN future expiry of
--            the granted source (trial end / period+grace end / manual
--            grant expiry), or the ORIGINAL trial end on a trial-expired
--            denial. Null for open-ended grants.
--        * NEW precedence step (STRICTLY below every subscription
--          source): when no valid subscription/licence/grant exists, an
--          ACTIVE account trial grants access:
--            reason_code='active_trial', access_source='trial',
--            plan_code='trial', plan_tier='trial', status='trialling',
--            seats_included=1, portal/iOS/Android access all true,
--            purchase_platform NULL, billing_provider 'trial'.
--          Full precedence (unchanged above the trial):
--            internal_unlimited > enterprise > team > legacy > solo
--            (incl. verified store subs) > ACCOUNT TRIAL > no access.
--        * NEW denial classification: an EXPIRED/REVOKED trial (with no
--          other entitlement AND no more-specific subscription denial)
--          returns reason_code='expired'/'revoked', access_source='trial',
--          plan_code='trial', status='expired'/'revoked', expires_at =
--          original trial end — so the portal can distinguish "Trial
--          expired" from "no entitlement has ever existed".
--        * purchase_platform semantics: NULL (never the text 'none') for
--          trial / manual grants / no-entitlement; 'ios'|'android'|'web'
--          only for real store/portal purchases (unchanged data path —
--          s.platform is already null on non-store rows).
--        * calls _ensure_account_trial() inside the guarded diagnostics
--          block (lazy row persistence + one-time expiry event; never
--          blocks resolution, skipped in read-only transactions).
--   B. CREATE OR REPLACEs public._admin_effective_access() (same
--      signature) with the identical trial recognition, so the admin
--      surface can NEVER drift from the resolver.
--   C. CREATE OR REPLACEs admin_access_users() — trial users now surface
--      as has_access=true / reason_code='active_trial' /
--      billing_provider='trial'; filters p_billing_source='trial' and
--      p_status_filter='trial' match the account trial.
--   D. CREATE OR REPLACEs admin_user_access_detail() — adds an
--      'account_trial' section (source_type, trial_started_at,
--      trial_ends_at, status, is_currently_valid, created_from).
--   E. CREATE OR REPLACEs admin_user_access_history() — adds the
--      'account_created' timeline entry; trial lifecycle events
--      (trial_migrated/started/expired/revoked) already flow through the
--      vinetrack_billing_events branch (provider 'system').
--
-- BACKWARD COMPATIBILITY:
--   * Resolver: first 33 columns unchanged; 1 appended (clients that
--     ignore unknown keys — both apps and the portal — are unaffected).
--   * status 'trialling' (account trial) is deliberately distinct from
--     the billing-row status 'trialing' (portal subscription trial) so
--     the two sources remain distinguishable; no released client branches
--     on either value for the access decision.
--   * admin_* functions keep their exact signatures (CREATE OR REPLACE).
--
-- ROLLBACK PROCEDURE (non-destructive):
--   1. Behavioural: disable the 'use_shared_supabase_entitlement' flag —
--      iOS reverts to its legacy gate; Android grant-only behaviour keeps
--      working either way.
--   2. Full: re-run sql/135 section A (resolver) and sql/140 sections
--      A–D (admin surface). The appended expires_at column disappears;
--      clients ignore its absence. Then sql/143 may be rolled back.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.vinetrack_account_trials') is null
     or to_regprocedure('public._account_trial_for(uuid)') is null then
    raise exception 'SQL 144 precondition failed: apply sql/143 first';
  end if;
  if to_regprocedure('public._admin_effective_access(uuid)') is null then
    raise exception 'SQL 144 precondition failed: apply sql/140 first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. get_my_vinetrack_access() — account trial + expires_at.
--    Output signature grows by one appended column -> DROP + recreate.
-- ---------------------------------------------------------------------------
drop function if exists public.get_my_vinetrack_access();

create or replace function public.get_my_vinetrack_access()
returns table (
  user_id                 uuid,
  has_supabase_access     boolean,
  access_source           text,     -- tier | 'trial' | 'none'
  is_owner                boolean,
  subscription_id         uuid,
  plan_code               text,
  plan_tier               text,
  plan_name               text,
  billing_provider        text,     -- 'apple'|'google'|'stripe'|'manual'|'trial'
  status                  text,     -- billing status | 'trialling' | 'expired'
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
  purchase_platform       text,
  cancel_at_period_end    boolean,
  grace_period_end        timestamptz,
  -- ---- NEW (SQL 144, appended — additive only) ----
  expires_at              timestamptz
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
  v_expires_at      timestamptz;

  -- Account trial (sql/143).
  tr record;

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

  -- ---- 1. Best VALID subscription entitlement (unchanged from SQL 135).
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
      and (s.environment is null or s.environment <> 'sandbox')
      and (
        s.owner_user_id = v_uid
        or exists (
          select 1 from public.vinetrack_user_licences l
          where l.subscription_id = s.id
            and l.user_id = v_uid
            and l.status = 'active'
        )
      )
      and (
        s.status in ('trialing', 'active', 'manual')
        or (coalesce(s.unlimited_licences, false) = true and s.status = 'past_due')
        or (s.status = 'past_due' and s.grace_period_end is not null and s.grace_period_end > now())
      )
      and (s.started_at is null or s.started_at <= now())
      and (s.status <> 'trialing' or s.trial_end is null or s.trial_end > now())
      and (
        coalesce(s.unlimited_licences, false) = true
        or s.status not in ('active', 'past_due')
        or s.current_period_end is null
        or s.current_period_end > now()
        or (s.grace_period_end is not null and s.grace_period_end > now())
      )
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

  -- ---- 2. Account trial (sql/143) — read regardless; used for grant OR
  --         denial classification. Pure read, server time only.
  select * into tr from public._account_trial_for(v_uid);

  -- ---- 3. Reason code + trial precedence.
  if v_sub_id is not null then
    -- Subscription sources always outrank the account trial.
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
    -- Earliest KNOWN future expiry (grace EXTENDS an elapsed period).
    select min(cand) into v_expires_at
    from unnest(array[
      v_grant_expires,
      v_trial_end,
      case
        when v_period_end is not null and v_grace_end is not null
          then greatest(v_period_end, v_grace_end)
        else coalesce(v_period_end, v_grace_end)
      end
    ]) cand
    where cand is not null and cand > now();

  elsif coalesce(tr.is_active, false) then
    -- ACTIVE account trial: lowest-priority granting source.
    v_has          := true;
    v_source       := 'trial';
    v_reason       := 'active_trial';
    v_plan_code    := 'trial';
    v_plan_tier    := 'trial';
    v_plan_name    := 'Account Trial';
    v_provider     := 'trial';
    v_status       := 'trialling';
    v_trial_end    := tr.trial_ends_at;
    v_portal_level := 'basic';
    v_seats_included := 1;
    v_expires_at   := tr.trial_ends_at;
    -- subscription_id / licence / vineyard / purchase_platform stay NULL;
    -- unlimited / cancel_at_period_end stay false.

  else
    -- ---- Denial classification. A more specific subscription denial
    --      (expired/revoked billing row) takes precedence; otherwise the
    --      trial state distinguishes "Trial expired" from "never entitled".
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
      else null
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

    if v_reason is null and tr.status is not null then
      -- Expired or revoked ACCOUNT TRIAL with no other billing history.
      v_reason     := case when tr.status = 'revoked' then 'revoked' else 'expired' end;
      v_source     := 'trial';
      v_plan_code  := 'trial';
      v_plan_tier  := 'trial';
      v_plan_name  := 'Account Trial';
      v_provider   := 'trial';
      v_status     := case when tr.status = 'revoked' then 'revoked' else 'expired' end;
      v_trial_end  := tr.trial_ends_at;
      v_expires_at := tr.trial_ends_at;   -- ORIGINAL trial end (informational)
    end if;

    v_reason := coalesce(v_reason, 'no_entitlement');
  end if;

  -- ---- 4. Per-caller rollout flag.
  v_enforce := public._entitlement_enforcement_enabled(
    v_uid,
    v_has and v_reason = 'internal_unlimited'
  );

  -- ---- 5. Guarded maintenance + change-detected audit (never blocks
  --         resolution; skipped wholesale in read-only transactions).
  begin
    -- Lazy trial-row persistence / one-time expiry flip (sql/143).
    perform public._ensure_account_trial(v_uid);

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

  -- ---- 6. Response (existing 33 columns unchanged; 1 appended).
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
    v_has,                                   -- can_use_ios_app
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
    v_has,                                   -- can_use_android_app
    now(),
    v_enforce,
    v_platform,                              -- purchase_platform (null unless store)
    coalesce(v_cancel_at_end, false),
    v_grace_end,
    v_expires_at;                            -- expires_at (NEW)
end;
$$;

revoke all on function public.get_my_vinetrack_access() from public;
grant execute on function public.get_my_vinetrack_access() to authenticated;

comment on function public.get_my_vinetrack_access() is
  'SQL 144 shared entitlement resolver. Backward compatible with sql/135: first 33 output columns unchanged; appended expires_at. Recognises the server-authoritative account trial (sql/143) BELOW every subscription source: active trial -> reason_code active_trial, access_source/plan_code trial, status trialling, portal+iOS+Android access. Expired trial denial -> reason_code expired, access_source trial, expires_at = original trial end. purchase_platform is NULL for non-purchase sources (never the text none). Server time only; clients cannot write trial state.';

-- ---------------------------------------------------------------------------
-- B. _admin_effective_access — identical trial recognition (same signature).
--    The admin surface consumes THIS helper, so it cannot drift from the
--    resolver: both call _account_trial_for with the same precedence.
-- ---------------------------------------------------------------------------
create or replace function public._admin_effective_access(p_user_id uuid)
returns table (
  has_access              boolean,
  reason_code             text,
  subscription_id         uuid,
  plan_code               text,
  plan_tier               text,
  plan_name               text,
  billing_provider        text,
  status                  text,
  purchase_platform       text,
  environment             text,
  trial_end               timestamptz,
  current_period_end      timestamptz,
  cancel_at_period_end    boolean,
  grace_period_end        timestamptz,
  unlimited_licences      boolean,
  manual_grant_reason     text,
  manual_grant_expires_at timestamptz,
  is_owner                boolean,
  licence_id              uuid,
  vineyard_id             uuid,
  portal_access           boolean,
  portal_access_level     text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r record;
  tr record;
  v_reason text;
begin
  select
    s.id            as sub_id,
    p.code          as plan_code,
    p.tier          as plan_tier,
    p.name          as plan_name,
    p.portal_access_level,
    s.billing_provider,
    s.status,
    s.platform,
    s.environment,
    s.trial_end,
    s.current_period_end,
    coalesce(s.cancel_at_period_end, false) as cancel_at_period_end,
    s.grace_period_end,
    coalesce(s.unlimited_licences, false)   as unlimited,
    s.manual_grant_reason,
    s.manual_grant_expires_at,
    (s.owner_user_id = p_user_id)           as is_owner,
    (
      select ul.id from public.vinetrack_user_licences ul
      where ul.subscription_id = s.id
        and ul.user_id = p_user_id
        and ul.status = 'active'
      order by ul.id limit 1
    ) as licence_id,
    coalesce(
      (
        select ul2.vineyard_id from public.vinetrack_user_licences ul2
        where ul2.subscription_id = s.id
          and ul2.user_id = p_user_id
          and ul2.status = 'active'
        order by ul2.id limit 1
      ),
      s.primary_vineyard_id
    ) as vineyard_id
  into r
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  where s.deleted_at is null
    and (s.environment is null or s.environment <> 'sandbox')
    and (
      s.owner_user_id = p_user_id
      or exists (
        select 1 from public.vinetrack_user_licences l
        where l.subscription_id = s.id
          and l.user_id = p_user_id
          and l.status = 'active'
      )
    )
    and (
      s.status in ('trialing', 'active', 'manual')
      or (coalesce(s.unlimited_licences, false) = true and s.status = 'past_due')
      or (s.status = 'past_due' and s.grace_period_end is not null and s.grace_period_end > now())
    )
    and (s.started_at is null or s.started_at <= now())
    and (s.status <> 'trialing' or s.trial_end is null or s.trial_end > now())
    and (
      coalesce(s.unlimited_licences, false) = true
      or s.status not in ('active', 'past_due')
      or s.current_period_end is null
      or s.current_period_end > now()
      or (s.grace_period_end is not null and s.grace_period_end > now())
    )
    and (coalesce(s.unlimited_licences, false) = false or s.manual_grant_revoked_at is null)
    and (
      coalesce(s.unlimited_licences, false) = false
      or s.manual_grant_expires_at is null
      or s.manual_grant_expires_at > now()
    )
  order by
    case
      when p.code = 'internal_unlimited' then 6
      when p.tier = 'enterprise'         then 5
      when p.tier = 'team'               then 4
      when p.tier = 'legacy'             then 3
      when p.tier = 'solo'               then 2
      else 1
    end desc,
    (s.status = 'trialing') asc,
    (s.owner_user_id = p_user_id) desc,
    s.current_period_end desc nulls last,
    s.created_at desc,
    s.id
  limit 1;

  if r.sub_id is not null then
    v_reason := case
      when r.plan_code = 'internal_unlimited'                 then 'internal_unlimited'
      when r.plan_tier = 'enterprise'                         then 'enterprise_subscription'
      when r.status = 'trialing'
           and r.billing_provider not in ('apple', 'google')  then 'active_trial'
      when r.licence_id is not null
           and coalesce(r.is_owner, false) = false
           and r.billing_provider not in ('apple', 'google')  then 'assigned_licence'
      when r.billing_provider in ('apple', 'google')          then 'app_store_subscription'
      else 'portal_subscription'
    end;

    return query select
      true, v_reason, r.sub_id, r.plan_code, r.plan_tier, r.plan_name,
      r.billing_provider, r.status, r.platform, r.environment,
      r.trial_end, r.current_period_end, r.cancel_at_period_end,
      r.grace_period_end, r.unlimited, r.manual_grant_reason,
      r.manual_grant_expires_at, coalesce(r.is_owner, false),
      r.licence_id, r.vineyard_id,
      (coalesce(r.portal_access_level, 'none') <> 'none'),
      coalesce(r.portal_access_level, 'none');
    return;
  end if;

  -- Account trial (sql/143): SAME precedence as the resolver.
  select * into tr from public._account_trial_for(p_user_id);

  if coalesce(tr.is_active, false) then
    return query select
      true, 'active_trial'::text, null::uuid,
      'trial'::text, 'trial'::text, 'Account Trial'::text,
      'trial'::text, 'trialling'::text,
      null::text,                          -- purchase_platform: NULL, never 'none'
      null::text,
      tr.trial_ends_at, null::timestamptz, false,
      null::timestamptz, false, null::text,
      null::timestamptz, false,
      null::uuid, null::uuid,
      true, 'basic'::text;
    return;
  end if;

  -- Denial classification: subscription denial first, then trial state.
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
    else null
  end
  into v_reason
  from public.vinetrack_subscriptions s2
  where s2.owner_user_id = p_user_id
     or exists (
       select 1 from public.vinetrack_user_licences l2
       where l2.subscription_id = s2.id and l2.user_id = p_user_id
     )
  order by s2.updated_at desc, s2.id
  limit 1;

  if v_reason is null and tr.status is not null then
    -- Expired/revoked account trial: "Trial expired" != "never entitled".
    return query select
      false,
      case when tr.status = 'revoked' then 'revoked' else 'expired' end,
      null::uuid,
      'trial'::text, 'trial'::text, 'Account Trial'::text,
      'trial'::text,
      case when tr.status = 'revoked' then 'revoked' else 'expired' end,
      null::text, null::text,
      tr.trial_ends_at,                    -- original trial end
      null::timestamptz, false,
      null::timestamptz, false, null::text,
      null::timestamptz, false,
      null::uuid, null::uuid,
      false, 'none'::text;
    return;
  end if;

  return query select
    false, coalesce(v_reason, 'no_entitlement'),
    null::uuid, null::text, null::text, null::text,
    null::text, null::text, null::text, null::text,
    null::timestamptz, null::timestamptz, false,
    null::timestamptz, false, null::text,
    null::timestamptz, false,
    null::uuid, null::uuid,
    false, 'none'::text;
end;
$$;

revoke all on function public._admin_effective_access(uuid) from public;

comment on function public._admin_effective_access(uuid) is
  'SQL 144 internal: read-only mirror of the SQL 144 resolver (subscriptions + server-authoritative account trial, identical precedence and validity rules). Never writes state/audit. No client execute grant.';

-- ---------------------------------------------------------------------------
-- C. admin_access_users — trial-aware filters (same signature).
--    Only the two trial filter branches change; everything else identical
--    to SQL 140. Trial users now surface via _admin_effective_access.
-- ---------------------------------------------------------------------------
create or replace function public.admin_access_users(
  p_search         text    default null,
  p_has_access     boolean default null,
  p_plan_code      text    default null,
  p_vineyard_id    uuid    default null,
  p_role           text    default null,
  p_billing_source text    default null,   -- apple|google|stripe|manual|internal|trial|none
  p_status_filter  text    default null,   -- trial|expired|cancelled|needs_review|failed|mismatch|manual_override
  p_limit          integer default 50,
  p_offset         integer default 0
)
returns table (
  user_id              uuid,
  email                text,
  full_name            text,
  email_confirmed      boolean,
  is_disabled          boolean,
  is_system_admin      boolean,
  account_created_at   timestamptz,
  last_sign_in_at      timestamptz,
  vineyards            jsonb,
  has_access           boolean,
  reason_code          text,
  access_source        text,
  plan_code            text,
  plan_name            text,
  billing_provider     text,
  purchase_platform    text,
  product_id           text,
  subscription_status  text,
  current_period_end   timestamptz,
  cancel_at_period_end boolean,
  manual_override      boolean,
  unlimited_licences   boolean,
  licence_count        integer,
  review_status        text,
  last_verified_at     timestamptz,
  total_count          bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;

  return query
  with users as (
    select
      u.id,
      coalesce(pr.email, u.email)::text as email,
      pr.full_name,
      (u.email_confirmed_at is not null) as email_confirmed,
      (u.banned_until is not null and u.banned_until > now()) as is_disabled,
      exists (
        select 1 from public.system_admins sa
        where sa.user_id = u.id and sa.is_active = true
      ) as is_sys_admin,
      u.created_at,
      u.last_sign_in_at
    from auth.users u
    left join public.profiles pr on pr.id = u.id
    where u.deleted_at is null
      and (
        p_search is null
        or coalesce(pr.email, u.email) ilike '%' || p_search || '%'
        or coalesce(pr.full_name, '') ilike '%' || p_search || '%'
      )
      and (
        p_vineyard_id is null
        or exists (
          select 1 from public.vineyard_members vm
          where vm.user_id = u.id and vm.vineyard_id = p_vineyard_id
        )
      )
      and (
        p_role is null
        or exists (
          select 1 from public.vineyard_members vm2
          join public.vineyards vy2 on vy2.id = vm2.vineyard_id
          where vm2.user_id = u.id
            and vm2.role = p_role
            and vy2.deleted_at is null
        )
      )
  ),
  enriched as (
    select
      us.*,
      ea.has_access           as e_has_access,
      ea.reason_code          as e_reason_code,
      coalesce(ea.plan_tier, 'none') as e_access_source,
      ea.plan_code            as e_plan_code,
      ea.plan_name            as e_plan_name,
      ea.billing_provider     as e_billing_provider,
      ea.purchase_platform    as e_purchase_platform,
      ea.status               as e_status,
      case when ea.plan_tier = 'trial' then ea.trial_end
           else ea.current_period_end end as e_period_end,
      ea.cancel_at_period_end as e_cancel_at_end,
      ea.unlimited_licences   as e_unlimited,
      (
        coalesce(ea.unlimited_licences, false)
        or ea.billing_provider = 'manual'
      ) as e_manual_override,
      coalesce((
        select prod.product_id
        from public.billing_provider_events prod
        where prod.resolved_user_id = us.id
          and prod.product_id is not null
        order by prod.received_at desc
        limit 1
      ), null) as e_product_id,
      coalesce((
        select count(*)::integer
        from public.vinetrack_user_licences lic
        where lic.user_id = us.id and lic.status = 'active'
      ), 0) as e_licence_count,
      case
        when exists (
          select 1 from public.vinetrack_entitlement_audit a
          where a.user_id = us.id
            and a.event_type = 'store_subscription_sync_mismatch'
            and a.created_at > now() - interval '30 days'
        ) then 'mismatch'
        when exists (
          select 1 from public.billing_provider_events e
          where e.resolved_user_id = us.id and e.processing_status = 'failed'
        ) then 'failed'
        when exists (
          select 1 from public.billing_provider_events e
          where e.resolved_user_id = us.id and e.processing_status = 'needs_review'
        ) then 'needs_review'
        else 'ok'
      end as e_review_status,
      (
        select es.updated_at from public.vinetrack_entitlement_state es
        where es.user_id = us.id
      ) as e_last_verified_at,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'vineyard_id', vy.id,
          'name', vy.name,
          'role', vm.role
        ) order by vy.name)
        from public.vineyard_members vm
        join public.vineyards vy on vy.id = vm.vineyard_id
        where vm.user_id = us.id and vy.deleted_at is null
      ), '[]'::jsonb) as e_vineyards
    from users us
    cross join lateral public._admin_effective_access(us.id) ea
  ),
  filtered as (
    select * from enriched en
    where (p_has_access is null or en.e_has_access = p_has_access)
      and (p_plan_code is null or en.e_plan_code = p_plan_code)
      and (
        p_billing_source is null
        or (p_billing_source = 'internal'
            and (en.e_plan_code = 'internal_unlimited' or coalesce(en.e_unlimited, false)))
        -- SQL 144: 'trial' matches the ACCOUNT trial and billing-row trials.
        or (p_billing_source = 'trial'
            and (en.e_billing_provider = 'trial' or en.e_status in ('trialing', 'trialling')))
        or (p_billing_source = 'none' and en.e_has_access = false)
        or (p_billing_source in ('apple', 'google', 'stripe', 'manual')
            and en.e_billing_provider = p_billing_source)
      )
      and (
        p_status_filter is null
        or (p_status_filter = 'trial' and en.e_status in ('trialing', 'trialling'))
        or (p_status_filter = 'expired'
            and en.e_has_access = false and en.e_reason_code = 'expired')
        or (p_status_filter = 'cancelled'
            and ((en.e_has_access and coalesce(en.e_cancel_at_end, false))
                 or (en.e_has_access = false and en.e_reason_code = 'revoked')))
        or (p_status_filter = 'needs_review' and en.e_review_status = 'needs_review')
        or (p_status_filter = 'failed' and en.e_review_status = 'failed')
        or (p_status_filter = 'mismatch' and en.e_review_status = 'mismatch')
        or (p_status_filter = 'manual_override' and en.e_manual_override)
      )
  )
  select
    f.id,
    f.email,
    f.full_name,
    f.email_confirmed,
    f.is_disabled,
    f.is_sys_admin,
    f.created_at,
    f.last_sign_in_at,
    f.e_vineyards,
    f.e_has_access,
    f.e_reason_code,
    f.e_access_source,
    f.e_plan_code,
    f.e_plan_name,
    f.e_billing_provider,
    f.e_purchase_platform,
    f.e_product_id,
    f.e_status,
    f.e_period_end,
    coalesce(f.e_cancel_at_end, false),
    f.e_manual_override,
    coalesce(f.e_unlimited, false),
    f.e_licence_count,
    f.e_review_status,
    f.e_last_verified_at,
    count(*) over () as total_count
  from filtered f
  order by f.email asc
  limit greatest(1, least(coalesce(p_limit, 50), 200))
  offset greatest(0, coalesce(p_offset, 0));
end;
$$;

revoke all on function public.admin_access_users(text, boolean, text, uuid, text, text, text, integer, integer) from public;
grant execute on function public.admin_access_users(text, boolean, text, uuid, text, text, text, integer, integer) to authenticated;

comment on function public.admin_access_users(text, boolean, text, uuid, text, text, text, integer, integer) is
  'SQL 144: System-Admin-only paginated user directory (trial-aware). Account-trial users: has_access=true, reason_code=active_trial, access_source/plan_code=trial, billing_provider=trial, subscription_status=trialling, purchase_platform NULL, current_period_end = trial end. Expired-trial users: has_access=false, reason_code=expired, access_source=trial. Filters: p_billing_source=trial / p_status_filter=trial match the account trial.';

-- ---------------------------------------------------------------------------
-- D. admin_user_access_detail — adds the 'account_trial' section.
--    Everything else identical to SQL 140 (same signature, jsonb).
-- ---------------------------------------------------------------------------
create or replace function public.admin_user_access_detail(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_user_id is null then
    raise exception 'user_required' using errcode = '22023';
  end if;
  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'generated_at', now(),

    'identity', (
      select jsonb_build_object(
        'user_id', u.id,
        'email', coalesce(pr.email, u.email),
        'full_name', pr.full_name,
        'email_confirmed', (u.email_confirmed_at is not null),
        'email_confirmed_at', u.email_confirmed_at,
        'account_created_at', u.created_at,
        'last_sign_in_at', u.last_sign_in_at,
        'is_disabled', (u.banned_until is not null and u.banned_until > now()),
        'is_system_admin', exists (
          select 1 from public.system_admins sa
          where sa.user_id = u.id and sa.is_active = true
        )
      )
      from auth.users u
      left join public.profiles pr on pr.id = u.id
      where u.id = p_user_id
    ),

    'memberships', jsonb_build_object(
      'active', coalesce((
        select jsonb_agg(jsonb_build_object(
          'vineyard_id', vy.id,
          'vineyard_name', vy.name,
          'role', vm.role,
          'display_name', vm.display_name,
          'joined_at', vm.joined_at,
          'licence', (
            select jsonb_build_object(
              'licence_id', l.id, 'status', l.status, 'assigned_at', l.assigned_at
            )
            from public.vinetrack_user_licences l
            where l.user_id = p_user_id
              and l.vineyard_id = vy.id
              and l.status = 'active'
            order by l.assigned_at desc
            limit 1
          )
        ) order by vy.name)
        from public.vineyard_members vm
        join public.vineyards vy on vy.id = vm.vineyard_id
        where vm.user_id = p_user_id and vy.deleted_at is null
      ), '[]'::jsonb),
      'historical', coalesce((
        select jsonb_agg(jsonb_build_object(
          'vineyard_id', vy.id,
          'vineyard_name', vy.name,
          'role', vm.role,
          'joined_at', vm.joined_at,
          'vineyard_deleted_at', vy.deleted_at
        ) order by vy.deleted_at desc)
        from public.vineyard_members vm
        join public.vineyards vy on vy.id = vm.vineyard_id
        where vm.user_id = p_user_id and vy.deleted_at is not null
      ), '[]'::jsonb),
      'pending_invitations', coalesce((
        select jsonb_agg(jsonb_build_object(
          'invitation_id', i.id,
          'vineyard_id', i.vineyard_id,
          'vineyard_name', vy.name,
          'role', i.role,
          'status', i.status,
          'expires_at', i.expires_at,
          'created_at', i.created_at
        ) order by i.created_at desc)
        from public.invitations i
        join public.vineyards vy on vy.id = i.vineyard_id
        left join public.profiles pr2 on pr2.id = p_user_id
        where lower(i.email) = lower(coalesce(pr2.email,
                (select u2.email from auth.users u2 where u2.id = p_user_id)))
          and i.status = 'pending'
      ), '[]'::jsonb)
    ),

    'effective_access', (
      select jsonb_build_object(
        'has_access', ea.has_access,
        'reason_code', ea.reason_code,
        'access_source', coalesce(ea.plan_tier, 'none'),
        'plan_code', ea.plan_code,
        'plan_name', ea.plan_name,
        'billing_provider', ea.billing_provider,
        'subscription_status', ea.status,
        'purchase_platform', ea.purchase_platform,
        'unlimited_licences', ea.unlimited_licences,
        'trial_end', ea.trial_end,
        'current_period_end', ea.current_period_end,
        'cancel_at_period_end', ea.cancel_at_period_end,
        'grace_period_end', ea.grace_period_end,
        'manual_grant_reason', ea.manual_grant_reason,
        'manual_grant_expires_at', ea.manual_grant_expires_at,
        'subscription_id', ea.subscription_id,
        'licence_id', ea.licence_id,
        'vineyard_id', ea.vineyard_id,
        'portal_access', (ea.has_access and ea.portal_access),
        'portal_access_level', ea.portal_access_level,
        'can_use_ios_app', ea.has_access,
        'can_use_android_app', ea.has_access,
        'expires_at', case when ea.plan_tier = 'trial' then ea.trial_end
                           else coalesce(ea.manual_grant_expires_at,
                                         ea.trial_end,
                                         greatest(ea.current_period_end, ea.grace_period_end),
                                         ea.current_period_end,
                                         ea.grace_period_end) end,
        'last_verified_at', (
          select es.updated_at from public.vinetrack_entitlement_state es
          where es.user_id = p_user_id
        ),
        'cached_state', (
          select jsonb_build_object(
            'has_access', es.has_access, 'access_source', es.access_source,
            'reason_code', es.reason_code, 'plan_code', es.plan_code,
            'updated_at', es.updated_at
          )
          from public.vinetrack_entitlement_state es
          where es.user_id = p_user_id
        )
      )
      from public._admin_effective_access(p_user_id) ea
    ),

    -- SQL 144: server-authoritative account trial (sql/143). Appears as an
    -- ACCESS SOURCE — never as an Apple/Google/portal purchase.
    'account_trial', (
      select jsonb_build_object(
        'source_type', 'account_trial',
        'trial_started_at', t.trial_started_at,
        'trial_ends_at', t.trial_ends_at,
        'status', t.status,
        'is_currently_valid', t.is_active,
        'created_from', t.created_from,
        'is_persisted', t.is_persisted
      )
      from public._account_trial_for(p_user_id) t
    ),

    'billing_sources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'subscription_id', s.id,
        'plan_code', p.code,
        'plan_name', p.name,
        'plan_tier', p.tier,
        'billing_provider', s.billing_provider,
        'status', s.status,
        'environment', s.environment,
        'purchase_platform', s.platform,
        'is_owner', (s.owner_user_id = p_user_id),
        'started_at', s.started_at,
        'trial_end', s.trial_end,
        'current_period_start', s.current_period_start,
        'current_period_end', s.current_period_end,
        'cancel_at_period_end', s.cancel_at_period_end,
        'grace_period_end', s.grace_period_end,
        'canceled_at', s.canceled_at,
        'expired_at', s.expired_at,
        'deleted_at', s.deleted_at,
        'unlimited_licences', coalesce(s.unlimited_licences, false),
        'manual_grant_reason', s.manual_grant_reason,
        'manual_grant_expires_at', s.manual_grant_expires_at,
        'manual_grant_revoked_at', s.manual_grant_revoked_at,
        'external_subscription_ref', case
          when s.external_subscription_id is null then null
          when length(s.external_subscription_id) <= 8 then '…'
          else left(s.external_subscription_id, 4) || '…' || right(s.external_subscription_id, 4)
        end,
        'product_id', (
          select e.product_id from public.billing_provider_events e
          where e.resolved_user_id = s.owner_user_id
            and e.product_id is not null
            and (s.external_subscription_id is null
                 or e.external_subscription_id = s.external_subscription_id)
          order by e.received_at desc limit 1
        ),
        'last_provider_event', s.last_provider_event,
        'last_provider_event_at', s.last_provider_event_at,
        'last_verified_at', s.last_verified_at,
        'seats_included', s.seats_included,
        'seats_purchased', s.seats_purchased,
        'active_licences', (
          select count(*)::integer from public.vinetrack_user_licences cl
          where cl.subscription_id = s.id and cl.status = 'active'
        ),
        'is_effective', (s.id = (
          select ea2.subscription_id from public._admin_effective_access(p_user_id) ea2
        )),
        'is_currently_valid', (
          s.deleted_at is null
          and (s.environment is null or s.environment <> 'sandbox')
          and (
            s.status in ('trialing', 'active', 'manual')
            or (coalesce(s.unlimited_licences, false) and s.status = 'past_due')
            or (s.status = 'past_due' and s.grace_period_end is not null and s.grace_period_end > now())
          )
          and (s.started_at is null or s.started_at <= now())
          and (s.status <> 'trialing' or s.trial_end is null or s.trial_end > now())
          and (
            coalesce(s.unlimited_licences, false)
            or s.status not in ('active', 'past_due')
            or s.current_period_end is null
            or s.current_period_end > now()
            or (s.grace_period_end is not null and s.grace_period_end > now())
          )
          and (coalesce(s.unlimited_licences, false) = false or s.manual_grant_revoked_at is null)
          and (
            coalesce(s.unlimited_licences, false) = false
            or s.manual_grant_expires_at is null
            or s.manual_grant_expires_at > now()
          )
        )
      ) order by (s.deleted_at is null) desc, s.updated_at desc)
      from public.vinetrack_subscriptions s
      join public.vinetrack_plans p on p.id = s.plan_id
      where s.owner_user_id = p_user_id
         or exists (
           select 1 from public.vinetrack_user_licences l
           where l.subscription_id = s.id and l.user_id = p_user_id
         )
    ), '[]'::jsonb),

    'licences_held', coalesce((
      select jsonb_agg(jsonb_build_object(
        'licence_id', l.id,
        'subscription_id', l.subscription_id,
        'plan_code', p.code,
        'plan_name', p.name,
        'status', l.status,
        'vineyard_id', l.vineyard_id,
        'vineyard_name', vy.name,
        'assigned_at', l.assigned_at,
        'revoked_at', l.revoked_at
      ) order by l.assigned_at desc)
      from public.vinetrack_user_licences l
      join public.vinetrack_subscriptions s2 on s2.id = l.subscription_id
      join public.vinetrack_plans p on p.id = s2.plan_id
      left join public.vineyards vy on vy.id = l.vineyard_id
      where l.user_id = p_user_id
    ), '[]'::jsonb),

    'open_alerts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'alert_id', a.id,
        'alert_type', a.alert_type,
        'severity', a.severity,
        'product_id', a.product_id,
        'event_type', a.event_type,
        'detail', a.detail,
        'created_at', a.created_at
      ) order by a.created_at desc)
      from public.billing_admin_alerts a
      where a.resolved_user_id = p_user_id
        and a.acknowledged_at is null
    ), '[]'::jsonb)
  ) into v;

  return v;
end;
$$;

revoke all on function public.admin_user_access_detail(uuid) from public;
grant execute on function public.admin_user_access_detail(uuid) to authenticated;

comment on function public.admin_user_access_detail(uuid) is
  'SQL 144: System-Admin-only one-call JSON detail for the Access & Entitlements drawer. Adds account_trial section (source_type, trial_started_at, trial_ends_at, status, is_currently_valid, created_from). The trial appears as an access source, never as a purchase. External ids remain redacted; no tokens/passwords.';

-- ---------------------------------------------------------------------------
-- E. admin_user_access_history — adds 'account_created'; trial lifecycle
--    events (provider 'system') already flow via the billing branch.
-- ---------------------------------------------------------------------------
create or replace function public.admin_user_access_history(
  p_user_id uuid,
  p_limit   integer default 100
)
returns table (
  occurred_at timestamptz,
  source      text,
  event_type  text,
  platform    text,
  detail      jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_user_id is null then
    raise exception 'user_required' using errcode = '22023';
  end if;

  return query
  (
    -- SQL 144: the account anchor of the trial timeline.
    select
      u.created_at,
      'account'::text,
      'account_created'::text,
      null::text,
      jsonb_strip_nulls(jsonb_build_object(
        'trial_started_at', t.trial_started_at,
        'trial_ends_at', t.trial_ends_at
      ))
    from auth.users u
    left join lateral public._account_trial_for(p_user_id) t on true
    where u.id = p_user_id

    union all

    select
      a.created_at,
      'entitlement_audit'::text,
      a.event_type,
      a.platform,
      jsonb_strip_nulls(jsonb_build_object(
        'previous_state', a.previous_state,
        'new_state', a.new_state,
        'app_version', a.app_version
      ))
    from public.vinetrack_entitlement_audit a
    where a.user_id = p_user_id

    union all

    select
      be.created_at,
      'billing_event'::text,
      be.event_type,
      null::text,
      jsonb_strip_nulls(jsonb_build_object(
        'provider', be.provider,
        'subscription_id', be.subscription_id,
        'payload',
          coalesce(be.payload, '{}'::jsonb)
            - 'receipt' - 'receipts' - 'token' - 'tokens'
            - 'access_token' - 'refresh_token'
            - 'transaction_id' - 'purchase_token'
      ))
    from public.vinetrack_billing_events be
    where be.owner_user_id = p_user_id

    union all

    select
      al.created_at,
      'alert'::text,
      ('alert_created:' || al.alert_type),
      null::text,
      jsonb_strip_nulls(jsonb_build_object(
        'alert_id', al.id,
        'severity', al.severity,
        'product_id', al.product_id,
        'detail', al.detail
      ))
    from public.billing_admin_alerts al
    where al.resolved_user_id = p_user_id

    union all

    select
      al2.acknowledged_at,
      'alert'::text,
      ('alert_acknowledged:' || al2.alert_type),
      null::text,
      jsonb_strip_nulls(jsonb_build_object(
        'alert_id', al2.id,
        'acknowledged_by', al2.acknowledged_by
      ))
    from public.billing_admin_alerts al2
    where al2.resolved_user_id = p_user_id
      and al2.acknowledged_at is not null
  )
  order by 1 desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

revoke all on function public.admin_user_access_history(uuid, integer) from public;
grant execute on function public.admin_user_access_history(uuid, integer) to authenticated;

comment on function public.admin_user_access_history(uuid, integer) is
  'SQL 144: System-Admin-only unified timeline. Adds account_created (with the trial window); trial lifecycle events (trial_migrated/trial_started/trial_expired/trial_revoked, provider system) flow via the billing branch. Receipt/token keys stripped; capped at 500 rows.';

commit;

-- =====================================================================
-- VERIFICATION (run after commit):
--   -- As any user inside their first 3 months:
--   select has_supabase_access, reason_code, access_source, plan_code,
--          status, trial_end, expires_at, purchase_platform,
--          portal_access, can_use_ios_app, can_use_android_app
--   from public.get_my_vinetrack_access();
--   -- expect: true | active_trial | trial | trial | trialling |
--   --         <trial end> | <trial end> | NULL | true | true | true
--
--   -- As a System Admin:
--   select user_id, has_access, reason_code, access_source, plan_code,
--          billing_provider, subscription_status, purchase_platform
--   from public.admin_access_users(p_billing_source => 'trial', p_limit => 20);
--
--   select public.admin_user_access_detail('<user-uuid>') -> 'account_trial';
--   select * from public.admin_user_access_history('<user-uuid>', 20);
--
--   -- Paid sources still outrank the trial: grant Internal Unlimited to a
--   -- young account and re-run the resolver — reason_code must be
--   -- internal_unlimited, never active_trial.
-- =====================================================================

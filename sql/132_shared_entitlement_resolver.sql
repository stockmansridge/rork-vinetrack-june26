-- =====================================================================
-- 132_shared_entitlement_resolver.sql
-- =====================================================================
-- Phase 2A — harden get_my_vinetrack_access() so it can become the shared
-- access source for iOS, Android and the Portal.
--
-- What this migration does (all ADDITIVE / backward compatible):
--   A. Seeds the rollout feature flag `use_shared_supabase_entitlement`
--      (system_feature_flags, sql/062). Enabled for the INTERNAL cohort
--      only: active System Admins, holders of an active Internal Unlimited
--      grant, and any user id listed in the flag's value->'user_ids'.
--   B. Adds a per-caller enforcement helper
--      public._entitlement_enforcement_enabled(uid, has_internal_grant).
--   C. Adds server-side entitlement audit objects:
--        * public.vinetrack_entitlement_state — one row per user, last
--          effective state (change detection; keeps audit volume low).
--        * public.vinetrack_entitlement_audit — append-only state-change
--          events. NO raw receipts / tokens / provider payloads.
--   D. Adds public.report_entitlement_mismatch(platform, app_version,
--      detail) — clients report "RevenueCat grants but Supabase does not"
--      diagnostics (throttled to 1/user/platform/24h).
--   E. DROPs and recreates public.get_my_vinetrack_access() with:
--        * the SAME first 25 output columns, in the SAME order, so every
--          released Android build and the Portal keep parsing unchanged;
--        * five NEW appended columns:
--            reason_code          text        (stable machine code)
--            is_unlimited         boolean     (alias of unlimited_licences)
--            can_use_android_app  boolean     (mirror of can_use_ios_app)
--            last_verified_at     timestamptz (server now())
--            enforcement_enabled  boolean     (per-caller rollout flag)
--        * hardened validity — all against DATABASE now(), never client
--          time:
--            - status must be in ('trialing','active','manual')
--              (+ 'past_due' only while an unlimited grant holds);
--            - started_at (when set) must be <= now()   [future-start deny]
--            - trialing rows require trial_end null or > now()
--            - active/past_due rows require current_period_end null or
--              > now() (unlimited grants exempt — their own expiry rules
--              apply instead)
--            - unlimited grants require manual_grant_revoked_at null and
--              manual_grant_expires_at null or > now()
--            - deleted_at must be null (existing rule kept)
--            - entitlement must belong to auth.uid() as owner or active
--              licence holder (existing rule kept)
--        * deterministic duplicate resolution — stable ORDER BY ending in
--          the subscription id;
--        * precedence: internal_unlimited > enterprise > team > legacy >
--          solo, non-trial preferred over trial at equal tier;
--        * change-detected audit write (guarded — an audit failure can
--          never block access resolution).
--
-- Reason codes returned in `reason_code`:
--   internal_unlimited | enterprise_subscription | portal_subscription |
--   assigned_licence | app_store_subscription | active_trial |
--   expired | revoked | no_entitlement
--   (account_disabled / no_membership / server_error are client-side
--    states; the RPC raises 42501 for unauthenticated callers.)
--
-- What does NOT change:
--   * No table is renamed or dropped. No historical subscription row is
--     modified. No RLS policy on existing tables changes.
--   * Function permissions: unchanged (authenticated execute only).
--   * `solo_check_required` semantics: unchanged (no valid row → clients
--     defer to RevenueCat).
--
-- ROLLBACK PROCEDURE (documented, non-destructive):
--   1. Immediate behavioural rollback — no SQL redeploy needed:
--        select public.set_system_feature_flag(
--          'use_shared_supabase_entitlement', false);
--      iOS then reverts to the legacy RevenueCat-only gate at its next
--      refresh; Android behaviour is unaffected either way.
--   2. Full function rollback: re-run section D of
--      sql/096_internal_unlimited_licensing.sql (drop + recreate). The
--      five appended columns disappear; clients ignore their absence.
--   3. The audit tables are additive and may simply be left in place.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Preconditions — refuse to run against a database missing the billing
--    layer this migration hardens.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.vinetrack_subscriptions') is null
     or to_regclass('public.vinetrack_plans') is null
     or to_regclass('public.vinetrack_user_licences') is null then
    raise exception 'SQL 132 precondition failed: vinetrack billing tables missing (apply migrations-draft-billing/01 first)';
  end if;
  if to_regclass('public.system_feature_flags') is null then
    raise exception 'SQL 132 precondition failed: system_feature_flags missing (apply sql/062 first)';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'vinetrack_subscriptions'
      and column_name = 'unlimited_licences'
  ) then
    raise exception 'SQL 132 precondition failed: sql/096 (unlimited grants) not applied';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. Rollout feature flag (idempotent seed — never overwrites an existing
--    admin-managed value).
--    Rollout stages (edit via set_system_feature_flag / the flags admin UI):
--      {"cohort":"internal","user_ids":[]}  → System Admins + Internal
--                                             Unlimited holders + listed ids
--      {"cohort":"beta","user_ids":[...]}   → same as internal + listed ids
--                                             (label distinguishes the stage)
--      {"cohort":"all"}                     → every authenticated user
--      is_enabled = false                   → nobody (legacy iOS gate)
-- ---------------------------------------------------------------------------
insert into public.system_feature_flags
  (key, value, value_type, category, label, description, is_enabled)
values
  ('use_shared_supabase_entitlement',
   '{"cohort":"internal","user_ids":[]}'::jsonb,
   'json', 'entitlement', 'Shared Supabase Entitlement',
   'When enabled, iOS enforces the shared Supabase entitlement resolver (get_my_vinetrack_access) before RevenueCat. Cohorts: internal (System Admins + Internal Unlimited grants + user_ids list), beta (same + user_ids list), all.',
   true)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- B. Per-caller enforcement helper (internal; called by the resolver).
-- ---------------------------------------------------------------------------
create or replace function public._entitlement_enforcement_enabled(
  p_user_id            uuid,
  p_has_internal_grant boolean default false
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_enabled boolean;
  v_value   jsonb;
  v_cohort  text;
begin
  if p_user_id is null then
    return false;
  end if;

  select f.is_enabled, f.value
    into v_enabled, v_value
  from public.system_feature_flags f
  where f.key = 'use_shared_supabase_entitlement';

  if not found or not coalesce(v_enabled, false) then
    return false;
  end if;

  v_cohort := lower(coalesce(v_value->>'cohort', 'internal'));
  if v_cohort = 'all' then
    return true;
  end if;

  -- Explicit user-id allowlist applies to every staged cohort.
  if v_value ? 'user_ids' and jsonb_typeof(v_value->'user_ids') = 'array' then
    if exists (
      select 1
      from jsonb_array_elements_text(v_value->'user_ids') t(uid)
      where t.uid = p_user_id::text
    ) then
      return true;
    end if;
  end if;

  -- 'internal' and 'beta' both include Internal Unlimited grant holders
  -- and active System Admins (controlled test cohort — no emails anywhere).
  if coalesce(p_has_internal_grant, false) then
    return true;
  end if;

  return exists (
    select 1
    from public.system_admins sa
    where sa.user_id = p_user_id
      and sa.is_active = true
  );
end$$;

revoke all on function public._entitlement_enforcement_enabled(uuid, boolean) from public;
-- No client grant — only SECURITY DEFINER functions owned by the same role
-- call this helper.

-- ---------------------------------------------------------------------------
-- C. Entitlement state + audit (additive; no client write path).
-- ---------------------------------------------------------------------------
create table if not exists public.vinetrack_entitlement_state (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  has_access    boolean not null,
  access_source text not null,
  reason_code   text not null,
  plan_code     text null,
  updated_at    timestamptz not null default now()
);

alter table public.vinetrack_entitlement_state enable row level security;
-- No client policies: written only by the SECURITY DEFINER resolver.

create table if not exists public.vinetrack_entitlement_audit (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  event_type     text not null check (event_type in (
                   'entitlement_granted',
                   'entitlement_denied',
                   'entitlement_source_changed',
                   'entitlement_expired',
                   'entitlement_revoked',
                   'entitlement_mismatch_detected'
                 )),
  previous_state jsonb null,
  new_state      jsonb null,
  platform       text null check (platform is null or platform in ('ios','android','portal','server')),
  app_version    text null,
  created_at     timestamptz not null default now()
);

create index if not exists idx_vinetrack_entitlement_audit_user
  on public.vinetrack_entitlement_audit (user_id, created_at desc);

alter table public.vinetrack_entitlement_audit enable row level security;

-- System admins may read the audit trail (diagnostics); nobody writes
-- directly — all inserts go through SECURITY DEFINER functions.
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'vinetrack_entitlement_audit'
      and policyname = 'vinetrack_entitlement_audit_admin_select'
  ) then
    create policy vinetrack_entitlement_audit_admin_select
      on public.vinetrack_entitlement_audit
      for select
      to authenticated
      using (public.is_system_admin());
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- D. Client mismatch diagnostic ("RevenueCat grants; Supabase does not").
--    Throttled: at most one row per user per platform per 24 hours, so
--    repeated resolver calls never flood the audit table.
-- ---------------------------------------------------------------------------
create or replace function public.report_entitlement_mismatch(
  p_platform    text,
  p_app_version text default null,
  p_detail      jsonb default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_detail jsonb;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_platform is null or lower(p_platform) not in ('ios','android','portal') then
    raise exception 'invalid_platform' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.vinetrack_entitlement_audit a
    where a.user_id = v_uid
      and a.event_type = 'entitlement_mismatch_detected'
      and a.platform = lower(p_platform)
      and a.created_at > now() - interval '24 hours'
  ) then
    return;
  end if;

  -- Never store large or sensitive payloads: cap the detail blob and strip
  -- any receipt/token-looking keys defensively.
  v_detail := coalesce(p_detail, '{}'::jsonb)
              - 'receipt' - 'receipts' - 'token' - 'tokens'
              - 'access_token' - 'refresh_token' - 'transaction_id';
  if pg_column_size(v_detail) > 2048 then
    v_detail := jsonb_build_object('truncated', true);
  end if;

  insert into public.vinetrack_entitlement_audit
    (user_id, event_type, previous_state, new_state, platform, app_version)
  values
    (v_uid, 'entitlement_mismatch_detected', null, v_detail,
     lower(p_platform), left(coalesce(p_app_version, ''), 40));
end$$;

revoke all on function public.report_entitlement_mismatch(text, text, jsonb) from public;
grant execute on function public.report_entitlement_mismatch(text, text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- E. get_my_vinetrack_access() — hardened, additive response contract.
--    The output signature grows, so DROP + recreate (CREATE OR REPLACE
--    cannot change OUT columns). Existing 25 columns keep name/order/type.
-- ---------------------------------------------------------------------------
drop function if exists public.get_my_vinetrack_access();

create or replace function public.get_my_vinetrack_access()
returns table (
  user_id                 uuid,
  has_supabase_access     boolean,
  access_source           text,     -- 'enterprise' | 'internal' | 'team' | 'legacy' | 'solo' | 'none'
  is_owner                boolean,
  subscription_id         uuid,
  plan_code               text,
  plan_tier               text,
  plan_name               text,
  billing_provider        text,     -- 'apple' | 'stripe' | 'manual'
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
  -- ---- NEW (SQL 132, appended — additive only) ----
  reason_code             text,
  is_unlimited            boolean,
  can_use_android_app     boolean,
  last_verified_at        timestamptz,
  enforcement_enabled     boolean
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();

  -- Best valid entitlement (all null when none).
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

  v_has     boolean := false;
  v_source  text := 'none';
  v_reason  text := 'no_entitlement';
  v_enforce boolean := false;

  -- Audit change detection.
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
    b.b_portal_level, b.b_active_licences, b.b_licence_id, b.b_vineyard_id
  into
    v_sub_id, v_is_owner, v_status, v_provider, v_trial_end, v_period_end,
    v_seats_included, v_seats_purchased, v_unlimited, v_grant_reason,
    v_grant_expires, v_plan_code, v_plan_tier, v_plan_name,
    v_portal_level, v_active_licences, v_licence_id, v_vineyard_id
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
      -- Precedence: internal grant > enterprise > team > legacy > solo.
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
      -- Status gate (past_due only survives under an unlimited grant).
      and (
        s.status in ('trialing', 'active', 'manual')
        or (coalesce(s.unlimited_licences, false) = true and s.status = 'past_due')
      )
      -- Future-starting entitlements do not grant access yet.
      and (s.started_at is null or s.started_at <= now())
      -- Trial expiry enforced at read time (was event-driven only).
      and (s.status <> 'trialing' or s.trial_end is null or s.trial_end > now())
      -- Paid period expiry enforced at read time. Unlimited grants are
      -- exempt (their own expiry/revocation rules below apply instead).
      and (
        coalesce(s.unlimited_licences, false) = true
        or s.status not in ('active', 'past_due')
        or s.current_period_end is null
        or s.current_period_end > now()
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
      (s.status = 'trialing') asc,           -- prefer paid over trial at equal tier
      (s.owner_user_id = v_uid) desc,
      s.current_period_end desc nulls last,
      s.created_at desc,
      s.id                                    -- deterministic final tiebreaker
    limit 1
  ) b on true;

  -- ---- 2. Reason code.
  if v_sub_id is not null then
    v_has := true;
    v_source := coalesce(v_plan_tier, 'none');
    v_reason := case
      when v_plan_code = 'internal_unlimited'            then 'internal_unlimited'
      when v_plan_tier = 'enterprise'                    then 'enterprise_subscription'
      when v_status = 'trialing'                         then 'active_trial'
      when v_licence_id is not null
           and coalesce(v_is_owner, false) = false       then 'assigned_licence'
      when v_provider = 'apple'                          then 'app_store_subscription'
      else 'portal_subscription'
    end;
  else
    -- Classify the denial from the caller's most recent row (any validity).
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

  -- ---- 4. Change-detected audit (guarded: never blocks resolution, e.g.
  --         when the call happens inside a read-only transaction).
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
    null;  -- diagnostics must never break access resolution
  end;

  -- ---- 5. Response (existing 25 columns unchanged; 5 appended).
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
    v_reason,                                -- reason_code (NEW)
    coalesce(v_unlimited, false),            -- is_unlimited (NEW)
    v_has,                                   -- can_use_android_app (NEW)
    now(),                                   -- last_verified_at (NEW)
    v_enforce;                               -- enforcement_enabled (NEW)
end;
$$;

revoke all on function public.get_my_vinetrack_access() from public;
grant execute on function public.get_my_vinetrack_access() to authenticated;

comment on function public.get_my_vinetrack_access() is
  'SQL 132 shared entitlement resolver. Backward compatible with sql/096: first 25 output columns unchanged. Appended: reason_code, is_unlimited, can_use_android_app, last_verified_at, enforcement_enabled. Hardened: server-time expiry on trial_end/current_period_end/manual_grant_expires_at, future-start denial, revocation checks, deterministic duplicate resolution. Volatile only for the guarded change-detection audit write.';

commit;

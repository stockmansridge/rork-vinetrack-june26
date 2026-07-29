-- =====================================================================
-- 143_server_authoritative_account_trials.sql
-- =====================================================================
-- Phase 2C.1 (1 of 3) — make the VineTrack three-month account trial
-- SERVER-AUTHORITATIVE.
--
-- EXISTING BEHAVIOUR BEING CORRECTED:
--   Both mobile apps compute the trial LOCALLY:
--     * iOS   — SubscriptionService.isInInitialFreeAccessPeriod:
--               auth user created_at + 3 calendar months, DEVICE time.
--     * Android — AppViewModel.isInInitialFreeAccessPeriod():
--               same rule, Calendar.MONTH + 3, DEVICE time.
--   The server resolver (get_my_vinetrack_access, SQL 135) and the admin
--   read surface (SQL 140) only see persisted vinetrack_subscriptions
--   rows — ordinary trial users have none, so the Access & Entitlements
--   centre shows them as "No Access" even while the apps grant the local
--   trial. This migration adds the missing server-side trial record.
--
-- WHAT THIS MIGRATION ADDS (all ADDITIVE):
--   A. public.vinetrack_account_trials — one row per auth user:
--        user_id (PK -> auth.users.id), trial_started_at, trial_ends_at,
--        status ('active'|'expired'|'revoked'), source ('account_trial'),
--        created_at, updated_at, migrated_at.
--      RLS: user may SELECT their own row; System Admins may SELECT all.
--      NO client INSERT/UPDATE/DELETE policies — iOS, Android and the
--      portal can never write or extend a trial.
--   B. public._account_trial_for(p_user_id) — STABLE pure-read helper.
--      Returns the trial window for ANY user. When no row exists yet it
--      DERIVES the window from auth.users.created_at + interval
--      '3 months' (calendar months — matches both shipped apps), so the
--      trial is correct even before the row is lazily persisted and even
--      inside read-only transactions. Validity uses DATABASE now() only.
--   C. public._ensure_account_trial(p_user_id) — VOLATILE maintainer.
--      Best-effort: persists the derived row for users created after this
--      migration (trial_started_at is ALWAYS auth.users.created_at, never
--      now(), so installing/reinstalling/re-running can NEVER restart a
--      trial) and lazily flips status active -> expired once
--      trial_ends_at passes (writing ONE 'trial_expired' audit event).
--      Called from the resolver inside its guarded diagnostics block.
--   D. public.admin_revoke_account_trial(user, reason) — System-Admin-only
--      revocation (writes 'trial_revoked'). Additive; not used by apps.
--   E. Existing-account migration — idempotent backfill:
--        * one row per existing auth user (on conflict do nothing);
--        * trial_started_at = auth.users.created_at;
--        * trial_ends_at    = created_at + interval '3 months';
--        * status derived from DATABASE now() (active/expired);
--        * migrated_at = now();
--        * ONE 'trial_migrated' event per user in
--          vinetrack_billing_events (provider 'system' — no tokens,
--          no auth metadata);
--        * re-running is safe: existing rows are never shortened,
--          restarted or duplicated.
--   F. Diagnostics — raise notice report before/after the backfill
--      (counts only; no emails or identifiers in the log).
--
-- TRIAL LIFECYCLE EVENTS (vinetrack_billing_events, provider 'system'):
--   trial_migrated | trial_started | trial_expired | trial_revoked |
--   trial_converted (reserved — conversion is recorded by the existing
--   entitlement_source_changed audit; the event name is documented for
--   the portal timeline).
--   At most one migration/start event per user; resolver calls never
--   append events repeatedly (change-detection only).
--
-- BACKWARD COMPATIBILITY:
--   * No existing table/column/function is changed here (the resolver is
--     updated in sql/144). Released clients are unaffected by this file.
--   * No account creation dates are modified. No billing data deleted.
--
-- ROLLBACK PROCEDURE (non-destructive):
--   drop function if exists public.admin_revoke_account_trial(uuid, text);
--   drop function if exists public._ensure_account_trial(uuid);
--   drop function if exists public._account_trial_for(uuid);
--   -- The table may simply remain (additive, no client writes):
--   -- drop table if exists public.vinetrack_account_trials;
--   -- (sql/144 must be rolled back FIRST — its resolver references these.)
-- =====================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Preconditions.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.vinetrack_subscriptions') is null
     or to_regclass('public.vinetrack_billing_events') is null then
    raise exception 'SQL 143 precondition failed: billing tables missing (apply migrations-draft-billing/01 first)';
  end if;
  if to_regproc('public.is_system_admin') is null then
    raise exception 'SQL 143 precondition failed: is_system_admin() missing';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. Account trial table — one row per user, keyed on auth.users.id.
--    NEVER keyed on email or device. NEVER client-writable.
-- ---------------------------------------------------------------------------
create table if not exists public.vinetrack_account_trials (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  trial_started_at timestamptz not null,
  trial_ends_at    timestamptz not null,
  status           text not null default 'active'
                     check (status in ('active', 'expired', 'revoked')),
  source           text not null default 'account_trial'
                     check (source in ('account_trial')),
  revoked_reason   text null,
  revoked_by       uuid null references auth.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  migrated_at      timestamptz null,
  constraint vinetrack_account_trials_window_check
    check (trial_ends_at > trial_started_at)
);

create index if not exists idx_vinetrack_account_trials_ends
  on public.vinetrack_account_trials (trial_ends_at);

alter table public.vinetrack_account_trials enable row level security;

-- SELECT: own row, or System Admin. NO write policies of any kind — with
-- RLS enabled and no INSERT/UPDATE/DELETE policy, authenticated clients
-- structurally cannot create, extend, shorten or delete a trial. All writes
-- flow through the SECURITY DEFINER functions below.
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'vinetrack_account_trials'
      and policyname = 'vinetrack_account_trials_select_own_or_admin'
  ) then
    create policy vinetrack_account_trials_select_own_or_admin
      on public.vinetrack_account_trials
      for select
      to authenticated
      using (user_id = auth.uid() or public.is_system_admin());
  end if;
end$$;

comment on table public.vinetrack_account_trials is
  'SQL 143: server-authoritative three-calendar-month account trial. Keyed permanently on auth.users.id (never email/device). trial_started_at is always auth.users.created_at — reinstalling, changing email or signing in on another platform can never restart it. No client write path (RLS, no write policies).';

-- ---------------------------------------------------------------------------
-- B. _account_trial_for — STABLE pure-read trial window for ANY user.
--    Falls back to deriving the window from auth.users.created_at when no
--    row has been persisted yet, so resolution is correct in read-only
--    transactions and before the lazy insert runs. DATABASE time only.
-- ---------------------------------------------------------------------------
create or replace function public._account_trial_for(p_user_id uuid)
returns table (
  trial_started_at timestamptz,
  trial_ends_at    timestamptz,
  status           text,
  is_active        boolean,
  is_persisted     boolean,
  created_from     text     -- 'migrated' | 'signup' | 'derived'
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t record;
  v_created timestamptz;
begin
  if p_user_id is null then
    return;
  end if;

  select at.trial_started_at, at.trial_ends_at, at.status, at.migrated_at
    into t
  from public.vinetrack_account_trials at
  where at.user_id = p_user_id;

  if found then
    return query select
      t.trial_started_at,
      t.trial_ends_at,
      -- Report derived status: an 'active' row past its end reads as expired
      -- (the volatile maintainer persists the flip; reads never depend on it).
      case
        when t.status = 'revoked' then 'revoked'
        when t.trial_ends_at <= now() then 'expired'
        else t.status
      end,
      (t.status = 'active' and t.trial_ends_at > now()),
      true,
      case when t.migrated_at is not null then 'migrated' else 'signup' end;
    return;
  end if;

  -- No persisted row yet: derive from the immutable account creation date.
  -- Calendar months (matches both shipped mobile apps), server time only.
  select u.created_at into v_created
  from auth.users u
  where u.id = p_user_id and u.deleted_at is null;

  if v_created is null then
    return;  -- unknown or deleted user: no trial
  end if;

  return query select
    v_created,
    v_created + interval '3 months',
    case when v_created + interval '3 months' > now() then 'active' else 'expired' end,
    (v_created + interval '3 months' > now()),
    false,
    'derived'::text;
end;
$$;

revoke all on function public._account_trial_for(uuid) from public;
-- No client grant — called only by SECURITY DEFINER resolver/admin functions.

comment on function public._account_trial_for(uuid) is
  'SQL 143 internal: pure-read account-trial window for any user. Derives from auth.users.created_at + 3 calendar months when no row is persisted. Database time only. No client execute grant.';

-- ---------------------------------------------------------------------------
-- C. _ensure_account_trial — VOLATILE best-effort maintainer.
--    * Persists the derived row (started_at = auth.users.created_at, NEVER
--      now()) with ONE 'trial_started' event.
--    * Flips active -> expired once ends_at passes, with ONE
--      'trial_expired' event.
--    Idempotent; safe under concurrency (on conflict do nothing / guarded
--    update). Never raises to the caller.
-- ---------------------------------------------------------------------------
create or replace function public._ensure_account_trial(p_user_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_created  timestamptz;
  v_inserted boolean := false;
  v_flipped  boolean := false;
  v_ends     timestamptz;
begin
  if p_user_id is null then
    return;
  end if;

  if not exists (
    select 1 from public.vinetrack_account_trials at where at.user_id = p_user_id
  ) then
    select u.created_at into v_created
    from auth.users u
    where u.id = p_user_id and u.deleted_at is null;

    if v_created is null then
      return;
    end if;

    v_ends := v_created + interval '3 months';

    insert into public.vinetrack_account_trials
      (user_id, trial_started_at, trial_ends_at, status, source)
    values
      (p_user_id, v_created, v_ends,
       case when v_ends > now() then 'active' else 'expired' end,
       'account_trial')
    on conflict (user_id) do nothing;

    v_inserted = found;
    if v_inserted then
      insert into public.vinetrack_billing_events
        (subscription_id, owner_user_id, provider, event_type, payload)
      values
        (null, p_user_id, 'system', 'trial_started',
         jsonb_build_object(
           'trial_started_at', v_created,
           'trial_ends_at', v_ends,
           'source', 'account_trial',
           'server_time', now()
         ));
    end if;
    return;
  end if;

  -- Lazy expiry flip (once): active row past its end becomes 'expired'.
  update public.vinetrack_account_trials at
  set status = 'expired', updated_at = now()
  where at.user_id = p_user_id
    and at.status = 'active'
    and at.trial_ends_at <= now();

  v_flipped = found;
  if v_flipped then
    insert into public.vinetrack_billing_events
      (subscription_id, owner_user_id, provider, event_type, payload)
    values
      (null, p_user_id, 'system', 'trial_expired',
       jsonb_build_object(
         'trial_ends_at', (select at2.trial_ends_at
                           from public.vinetrack_account_trials at2
                           where at2.user_id = p_user_id),
         'server_time', now()
       ));
  end if;
exception when others then
  null;  -- maintenance must never break access resolution
end;
$$;

revoke all on function public._ensure_account_trial(uuid) from public;
-- No client grant — called by the SECURITY DEFINER resolver (sql/144).

-- ---------------------------------------------------------------------------
-- D. admin_revoke_account_trial — System-Admin-only revocation (audited).
-- ---------------------------------------------------------------------------
create or replace function public.admin_revoke_account_trial(
  p_user_id uuid,
  p_reason  text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'reason_required' using errcode = '22023';
  end if;

  perform public._ensure_account_trial(p_user_id);

  update public.vinetrack_account_trials
  set status         = 'revoked',
      revoked_reason = btrim(p_reason),
      revoked_by     = v_admin,
      updated_at     = now()
  where user_id = p_user_id
    and status <> 'revoked';

  if not found then
    raise exception 'trial_not_found_or_already_revoked' using errcode = 'P0002';
  end if;

  insert into public.vinetrack_billing_events
    (subscription_id, owner_user_id, provider, event_type, payload)
  values
    (null, p_user_id, 'system', 'trial_revoked',
     jsonb_build_object('revoked_by', v_admin, 'reason', btrim(p_reason),
                        'server_time', now()));

  -- Effective access updates immediately in the admin centre.
  if to_regprocedure('public._admin_refresh_entitlement_state(uuid)') is not null then
    perform public._admin_refresh_entitlement_state(p_user_id);
  end if;

  return jsonb_build_object('user_id', p_user_id, 'status', 'revoked',
                            'revoked_at', now());
end;
$$;

revoke all on function public.admin_revoke_account_trial(uuid, text) from public;
grant execute on function public.admin_revoke_account_trial(uuid, text) to authenticated;

comment on function public.admin_revoke_account_trial(uuid, text) is
  'SQL 143: System-Admin-only account-trial revocation. Reason required; audited to vinetrack_billing_events (trial_revoked); entitlement state refreshed.';

-- ---------------------------------------------------------------------------
-- E+F. Existing-account migration with diagnostics.
--    Idempotent: on conflict do nothing; migrated_at marks backfilled rows;
--    exactly one 'trial_migrated' event per backfilled user; re-running
--    never restarts, shortens or duplicates a trial.
-- ---------------------------------------------------------------------------
do $$
declare
  n_users            bigint;
  n_young            bigint;
  n_old              bigint;
  n_null_created     bigint;
  n_disabled         bigint;
  n_internal         bigint;
  n_portal_subs      bigint;
  n_store_subs       bigint;
  n_licensed         bigint;
  n_existing_trials  bigint;
  n_inserted         bigint;
  n_active_after     bigint;
  n_expired_after    bigint;
begin
  -- ---- Pre-migration diagnostics (counts only; no identifiers logged).
  select count(*) into n_users
  from auth.users u where u.deleted_at is null;

  select count(*) into n_young
  from auth.users u
  where u.deleted_at is null
    and u.created_at + interval '3 months' > now();

  select count(*) into n_old
  from auth.users u
  where u.deleted_at is null
    and u.created_at + interval '3 months' <= now();

  select count(*) into n_null_created
  from auth.users u
  where u.deleted_at is null and u.created_at is null;

  select count(*) into n_disabled
  from auth.users u
  where u.deleted_at is null
    and u.banned_until is not null and u.banned_until > now();

  select count(distinct s.owner_user_id) into n_internal
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  where p.code = 'internal_unlimited'
    and s.deleted_at is null
    and s.manual_grant_revoked_at is null;

  select count(distinct s.owner_user_id) into n_portal_subs
  from public.vinetrack_subscriptions s
  where s.billing_provider = 'stripe'
    and s.deleted_at is null
    and s.status in ('trialing', 'active', 'past_due');

  select count(distinct s.owner_user_id) into n_store_subs
  from public.vinetrack_subscriptions s
  where s.billing_provider in ('apple', 'google')
    and s.deleted_at is null
    and (s.environment is null or s.environment <> 'sandbox')
    and s.status in ('trialing', 'active', 'past_due');

  select count(distinct l.user_id) into n_licensed
  from public.vinetrack_user_licences l
  where l.status = 'active' and l.user_id is not null;

  select count(*) into n_existing_trials
  from public.vinetrack_account_trials;

  raise notice 'SQL 143 pre-migration: total_users=%, within_3_months=%, older_than_3_months=%, null_created_at=%, disabled=%, internal_unlimited_holders=%, active_portal_subs=%, verified_store_subs=%, assigned_licence_holders=%, existing_trial_rows=%',
    n_users, n_young, n_old, n_null_created, n_disabled,
    n_internal, n_portal_subs, n_store_subs, n_licensed, n_existing_trials;

  if n_null_created > 0 then
    raise warning 'SQL 143: % user(s) have a NULL created_at and receive NO trial row — review these accounts manually (not corrected silently).', n_null_created;
  end if;

  -- ---- Backfill (idempotent; never restarts or shortens existing rows).
  with ins as (
    insert into public.vinetrack_account_trials
      (user_id, trial_started_at, trial_ends_at, status, source, migrated_at)
    select
      u.id,
      u.created_at,
      u.created_at + interval '3 months',
      case when u.created_at + interval '3 months' > now()
           then 'active' else 'expired' end,
      'account_trial',
      now()
    from auth.users u
    where u.deleted_at is null
      and u.created_at is not null
    on conflict (user_id) do nothing
    returning user_id, trial_started_at, trial_ends_at, status
  )
  insert into public.vinetrack_billing_events
    (subscription_id, owner_user_id, provider, event_type, payload)
  select
    null, ins.user_id, 'system', 'trial_migrated',
    jsonb_build_object(
      'trial_started_at', ins.trial_started_at,
      'trial_ends_at', ins.trial_ends_at,
      'status_at_migration', ins.status,
      'server_time', now()
    )
  from ins;

  get diagnostics n_inserted = row_count;

  -- ---- Post-migration diagnostics.
  select count(*) filter (where t.status = 'active' and t.trial_ends_at > now()),
         count(*) filter (where t.status <> 'active' or t.trial_ends_at <= now())
    into n_active_after, n_expired_after
  from public.vinetrack_account_trials t;

  raise notice 'SQL 143 post-migration: trial_rows_created=%, active_trials=%, expired_or_revoked_trials=%',
    n_inserted, n_active_after, n_expired_after;
end$$;

commit;

-- =====================================================================
-- VERIFICATION (run after commit):
--   -- Distribution:
--   select status, count(*),
--          min(trial_started_at) as earliest, max(trial_ends_at) as latest
--   from public.vinetrack_account_trials group by status;
--
--   -- Every trial start equals the account creation date (must be 0):
--   select count(*) from public.vinetrack_account_trials t
--   join auth.users u on u.id = t.user_id
--   where t.trial_started_at is distinct from u.created_at;
--
--   -- Exactly one migration event per backfilled user (must be 0):
--   select owner_user_id, count(*)
--   from public.vinetrack_billing_events
--   where provider = 'system' and event_type = 'trial_migrated'
--   group by owner_user_id having count(*) > 1;
--
--   -- Client write rejection (as an authenticated non-admin):
--   --   update public.vinetrack_account_trials set trial_ends_at = now() + interval '10 years';
--   --   -> 0 rows updated (RLS: no write policy).
--
-- Re-running this migration is safe: the backfill is ON CONFLICT DO
-- NOTHING and events are only written for newly inserted rows.
-- =====================================================================

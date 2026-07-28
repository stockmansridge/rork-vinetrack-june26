-- =====================================================================
-- 133_revenuecat_event_ingestion.sql
-- =====================================================================
-- Phase 2B (1 of 3) — idempotent provider-event storage for the
-- RevenueCat webhook, plus store-lifecycle audit event types.
--
-- What this migration does (all ADDITIVE / backward compatible):
--   A. Creates public.billing_provider_events — the idempotent inbox for
--      RevenueCat (and future provider) webhook deliveries.
--        * UNIQUE (provider, provider_event_id): a duplicate delivery can
--          never create a second row or a second subscription.
--        * processing_status: received | processed | ignored | failed |
--          needs_review — failed events can be retried safely because the
--          webhook UPDATES the status instead of deleting the row.
--        * raw_payload is service-role/System-Admin only (RLS below) and
--          is stored with receipt/token-looking keys stripped by the
--          webhook before insert.
--   B. Extends the vinetrack_entitlement_audit event_type CHECK (sql/132)
--      with the store-subscription lifecycle events, reusing the existing
--      audit table instead of creating a second one:
--        store_subscription_created | store_subscription_renewed |
--        store_subscription_product_changed | store_subscription_cancelled |
--        store_subscription_uncancelled | store_subscription_billing_issue |
--        store_subscription_expired | store_subscription_transferred |
--        store_subscription_alias_linked | store_subscription_sync_mismatch |
--        store_subscription_backfilled
--
-- What does NOT change:
--   * No existing table is renamed/dropped; no rows are modified.
--   * No existing RLS policy changes; new table is admin-read-only.
--   * No function permissions change.
--
-- ROLLBACK:
--   drop table if exists public.billing_provider_events;
--   -- and re-add the original sql/132 event_type check:
--   -- alter table public.vinetrack_entitlement_audit
--   --   drop constraint vinetrack_entitlement_audit_event_type_check;
--   -- alter table public.vinetrack_entitlement_audit
--   --   add constraint vinetrack_entitlement_audit_event_type_check
--   --   check (event_type in ('entitlement_granted','entitlement_denied',
--   --     'entitlement_source_changed','entitlement_expired',
--   --     'entitlement_revoked','entitlement_mismatch_detected'));
-- =====================================================================

begin;

-- Preconditions: SQL 132 must be applied.
do $$
begin
  if to_regclass('public.vinetrack_entitlement_audit') is null then
    raise exception 'SQL 133 precondition failed: apply sql/132 first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. billing_provider_events — idempotent webhook inbox
-- ---------------------------------------------------------------------------
create table if not exists public.billing_provider_events (
  id                       uuid primary key default gen_random_uuid(),
  provider                 text not null check (provider in ('revenuecat', 'apple', 'google', 'stripe', 'manual')),
  provider_event_id        text not null,
  event_type               text not null,
  environment              text null,                -- 'PRODUCTION' | 'SANDBOX' | null
  app_user_id              text null,                -- RevenueCat App User ID as sent
  original_app_user_id     text null,
  aliases                  text[] null,
  resolved_user_id         uuid null references auth.users(id) on delete set null,
  platform                 text null check (platform is null or platform in ('ios', 'android', 'web', 'unknown')),
  store                    text null,                -- APP_STORE | PLAY_STORE | PROMOTIONAL | ...
  product_id               text null,
  entitlement_ids          text[] null,
  external_subscription_id text null,                -- original transaction id / purchase-token ref
  external_transaction_id  text null,
  provider_created_at      timestamptz null,         -- provider event timestamp
  received_at              timestamptz not null default now(),
  processed_at             timestamptz null,
  processing_status        text not null default 'received'
    check (processing_status in ('received', 'processed', 'ignored', 'failed', 'needs_review')),
  processing_error_code    text null,
  processing_error_message text null,
  payload_hash             text null,
  -- Raw payload for support/audit only. The webhook strips receipt/token
  -- keys before insert; RLS below keeps it away from normal clients.
  raw_payload              jsonb null
);

create unique index if not exists uniq_billing_provider_events_event
  on public.billing_provider_events (provider, provider_event_id);
create index if not exists idx_billing_provider_events_user
  on public.billing_provider_events (resolved_user_id, received_at desc);
create index if not exists idx_billing_provider_events_status
  on public.billing_provider_events (processing_status)
  where processing_status in ('failed', 'needs_review');
create index if not exists idx_billing_provider_events_type
  on public.billing_provider_events (event_type, received_at desc);

alter table public.billing_provider_events enable row level security;

-- System Admins may read (diagnostics / unresolved-event review). No client
-- can insert/update/delete: only the service-role webhook writes here.
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'billing_provider_events'
      and policyname = 'billing_provider_events_admin_select'
  ) then
    create policy billing_provider_events_admin_select
      on public.billing_provider_events
      for select
      to authenticated
      using (public.is_system_admin());
  end if;
end$$;

comment on table public.billing_provider_events is
  'SQL 133: idempotent inbox for provider (RevenueCat) webhook events. Unique (provider, provider_event_id) is the duplicate-delivery guard. processing_status drives safe retries; raw_payload is admin/service-role only and stored with receipt/token keys stripped.';

-- ---------------------------------------------------------------------------
-- B. Extend the entitlement audit event types with store lifecycle events.
--    (Reuses vinetrack_entitlement_audit per Phase 2B §17 instead of adding
--    a second audit table.)
-- ---------------------------------------------------------------------------
do $$
declare
  v_conname text;
begin
  select c.conname into v_conname
  from pg_constraint c
  where c.conrelid = 'public.vinetrack_entitlement_audit'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%event_type%';

  if v_conname is not null then
    execute format('alter table public.vinetrack_entitlement_audit drop constraint %I', v_conname);
  end if;

  alter table public.vinetrack_entitlement_audit
    add constraint vinetrack_entitlement_audit_event_type_check
    check (event_type in (
      'entitlement_granted',
      'entitlement_denied',
      'entitlement_source_changed',
      'entitlement_expired',
      'entitlement_revoked',
      'entitlement_mismatch_detected',
      'store_subscription_created',
      'store_subscription_renewed',
      'store_subscription_product_changed',
      'store_subscription_cancelled',
      'store_subscription_uncancelled',
      'store_subscription_billing_issue',
      'store_subscription_expired',
      'store_subscription_transferred',
      'store_subscription_alias_linked',
      'store_subscription_sync_mismatch',
      'store_subscription_backfilled'
    ));
end$$;

commit;

-- =====================================================================
-- 139_store_billing_monitoring_and_alerts.sql
-- =====================================================================
-- Phase 2B CLOSEOUT — operational visibility for the store-billing system.
-- All ADDITIVE; nothing existing is dropped except the SQL 135 diagnostics
-- function, which is recreated with a richer signature.
--
--   A. admin_store_subscription_diagnostics(p_limit) v2 — now includes:
--        product ID (from the latest provider event for that subscription),
--        purchase platform, provider, plan, status, period end, grace end,
--        cancel-at-period-end, last provider event, last webhook received,
--        last verified, review/mismatch status.
--      External subscription/transaction identifiers stay REDACTED
--      (first4…last4). No receipts, tokens or raw payloads.
--
--   B. billing_admin_alerts — System-Admin alert inbox. Written by a
--      trigger on billing_provider_events; NO client writes; alerts fire
--      only on problem states (needs_review / failed / unknown product /
--      ownership conflict) — never on successful renewals.
--
--   C. Trigger billing_provider_events_alert_tg — turns problem events
--      into alerts, deduplicated per (alert_type, provider_event_id).
--
--   D. admin_store_billing_monitor() — one-call JSON health report:
--      events needing review, failed events, unknown products, unresolved
--      users, ownership conflicts, RevenueCat-active-but-Supabase-missing
--      mismatches, stuck deliveries, subscriptions approaching expiry,
--      recent subscription status changes.
--
--   E. admin_billing_alerts(...) — lists alerts and lazily materialises
--      'sync_window_exceeded' alerts (grant event processed >15 min ago
--      with no active Supabase subscription; deliveries stuck 'received').
--      admin_acknowledge_billing_alert(id) — mark handled.
--
-- ROLLBACK:
--   drop trigger  if exists billing_provider_events_alert_tg on public.billing_provider_events;
--   drop function if exists public.billing_provider_events_alert_fn();
--   drop function if exists public.admin_store_billing_monitor();
--   drop function if exists public.admin_billing_alerts(boolean, integer);
--   drop function if exists public.admin_acknowledge_billing_alert(uuid);
--   drop table    if exists public.billing_admin_alerts;
--   drop function if exists public.admin_store_subscription_diagnostics(integer);
--   -- then re-run section B of sql/135 to restore the previous diagnostics.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.billing_provider_events') is null
     or to_regclass('public.vinetrack_subscriptions') is null then
    raise exception 'SQL 139 precondition failed: apply sql/133 and sql/134 first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. Diagnostics v2 (return type changes -> drop first).
-- ---------------------------------------------------------------------------
drop function if exists public.admin_store_subscription_diagnostics(integer);

create or replace function public.admin_store_subscription_diagnostics(
  p_limit integer default 100
)
returns table (
  user_id                   uuid,
  plan_code                 text,
  provider                  text,        -- billing_provider: apple | google
  purchase_platform         text,        -- ios | android
  environment               text,
  product_id                text,        -- store product id (catalogue data, not sensitive)
  status                    text,
  external_subscription_ref text,        -- REDACTED first4…last4
  current_period_end        timestamptz,
  grace_period_end          timestamptz,
  cancel_at_period_end      boolean,
  expired_at                timestamptz,
  last_provider_event       text,
  last_provider_event_at    timestamptz,
  last_webhook_received_at  timestamptz,
  last_verified_at          timestamptz,
  needs_review_events       integer,
  failed_events             integer,
  review_status             text         -- ok | needs_review | failed | mismatch
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
    ev.product_id,
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
    ev_last.last_received_at,
    s.last_verified_at,
    coalesce(cnt.needs_review, 0),
    coalesce(cnt.failed, 0),
    case
      when exists (
        select 1 from public.vinetrack_entitlement_audit a
        where a.user_id = s.owner_user_id
          and a.event_type = 'store_subscription_sync_mismatch'
          and a.created_at > now() - interval '30 days'
      ) then 'mismatch'
      when coalesce(cnt.failed, 0) > 0 then 'failed'
      when coalesce(cnt.needs_review, 0) > 0 then 'needs_review'
      else 'ok'
    end
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  left join lateral (
    select e.product_id
    from public.billing_provider_events e
    where e.provider = 'revenuecat'
      and e.resolved_user_id = s.owner_user_id
      and e.product_id is not null
      and (s.external_subscription_id is null
           or e.external_subscription_id = s.external_subscription_id)
    order by e.received_at desc
    limit 1
  ) ev on true
  left join lateral (
    select max(e.received_at) as last_received_at
    from public.billing_provider_events e
    where e.resolved_user_id = s.owner_user_id
  ) ev_last on true
  left join lateral (
    select
      count(*) filter (where e.processing_status = 'needs_review')::integer as needs_review,
      count(*) filter (where e.processing_status = 'failed')::integer       as failed
    from public.billing_provider_events e
    where e.resolved_user_id = s.owner_user_id
  ) cnt on true
  where public.is_system_admin()
    and s.deleted_at is null
    and s.billing_provider in ('apple', 'google')
  order by s.updated_at desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

revoke all on function public.admin_store_subscription_diagnostics(integer) from public;
grant execute on function public.admin_store_subscription_diagnostics(integer) to authenticated;

comment on function public.admin_store_subscription_diagnostics(integer) is
  'SQL 139 v2: System-Admin-only store-sync diagnostics with product id, purchase platform, lifecycle timestamps and review/mismatch status. External ids redacted (first4…last4); zero rows for non-admins. No receipts, tokens or raw payloads.';

-- ---------------------------------------------------------------------------
-- B. billing_admin_alerts — admin alert inbox.
-- ---------------------------------------------------------------------------
create table if not exists public.billing_admin_alerts (
  id                uuid primary key default gen_random_uuid(),
  alert_type        text not null check (alert_type in (
                      'event_needs_review',
                      'event_failed',
                      'unknown_product',
                      'ownership_conflict',
                      'sync_window_exceeded'
                    )),
  severity          text not null default 'warning'
                      check (severity in ('info', 'warning', 'critical')),
  provider          text null,
  provider_event_id text null,
  event_type        text null,
  product_id        text null,
  resolved_user_id  uuid null references auth.users(id) on delete set null,
  detail            text null,          -- error code + short message; never receipts/tokens
  created_at        timestamptz not null default now(),
  acknowledged_at   timestamptz null,
  acknowledged_by   uuid null references auth.users(id) on delete set null
);

-- One alert per problem event per type (duplicate webhook deliveries and
-- re-runs of the lazy sync check can never spam the inbox).
create unique index if not exists uniq_billing_admin_alerts_event
  on public.billing_admin_alerts (alert_type, provider_event_id)
  where provider_event_id is not null;
create index if not exists idx_billing_admin_alerts_open
  on public.billing_admin_alerts (created_at desc)
  where acknowledged_at is null;

alter table public.billing_admin_alerts enable row level security;

-- Admin read-only; all writes go through the trigger / SECURITY DEFINER RPCs.
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'billing_admin_alerts'
      and policyname = 'billing_admin_alerts_admin_select'
  ) then
    create policy billing_admin_alerts_admin_select
      on public.billing_admin_alerts
      for select
      to authenticated
      using (public.is_system_admin());
  end if;
end$$;

comment on table public.billing_admin_alerts is
  'SQL 139: System-Admin alert inbox for store-billing problems. Trigger-written on needs_review/failed/unknown-product/ownership-conflict events plus lazy sync-window checks. Never fires on successful renewals. No receipts, tokens or secrets.';

-- ---------------------------------------------------------------------------
-- C. Trigger: problem events -> alerts (never on success/renewals).
-- ---------------------------------------------------------------------------
create or replace function public.billing_provider_events_alert_fn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.processing_status in ('needs_review', 'failed')
     and (tg_op = 'INSERT' or old.processing_status is distinct from new.processing_status) then
    insert into public.billing_admin_alerts
      (alert_type, severity, provider, provider_event_id, event_type, product_id, resolved_user_id, detail)
    values (
      case
        when new.processing_error_code in ('unknown_product', 'inactive_product') then 'unknown_product'
        when new.processing_error_code = 'ownership_conflict'                     then 'ownership_conflict'
        when new.processing_status = 'failed'                                     then 'event_failed'
        else 'event_needs_review'
      end,
      case
        when new.processing_status = 'failed'
          or new.processing_error_code = 'ownership_conflict' then 'critical'
        else 'warning'
      end,
      new.provider,
      new.provider_event_id,
      new.event_type,
      new.product_id,
      new.resolved_user_id,
      coalesce(new.processing_error_code, new.processing_status)
        || coalesce(': ' || left(new.processing_error_message, 300), '')
    )
    on conflict (alert_type, provider_event_id) where provider_event_id is not null
    do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists billing_provider_events_alert_tg on public.billing_provider_events;
create trigger billing_provider_events_alert_tg
after insert or update of processing_status on public.billing_provider_events
for each row execute function public.billing_provider_events_alert_fn();

-- ---------------------------------------------------------------------------
-- D. One-call health report (JSON; System Admin only).
-- ---------------------------------------------------------------------------
create or replace function public.admin_store_billing_monitor()
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

  select jsonb_build_object(
    'generated_at', now(),

    'events_needing_review', jsonb_build_object(
      'count', (select count(*) from public.billing_provider_events
                where processing_status = 'needs_review'),
      'recent', coalesce((
        select jsonb_agg(jsonb_build_object(
          'event_type', r.event_type, 'code', r.processing_error_code,
          'product_id', r.product_id, 'platform', r.platform,
          'environment', r.environment, 'received_at', r.received_at,
          'resolved_user_id', r.resolved_user_id,
          'app_user_ref', case when r.app_user_id is null then null
                               else left(r.app_user_id, 8) || '…' end
        ) order by r.received_at desc)
        from (select * from public.billing_provider_events
              where processing_status = 'needs_review'
              order by received_at desc limit 20) r), '[]'::jsonb)
    ),

    'failed_events', jsonb_build_object(
      'count', (select count(*) from public.billing_provider_events
                where processing_status = 'failed'),
      'recent', coalesce((
        select jsonb_agg(jsonb_build_object(
          'event_type', r.event_type, 'code', r.processing_error_code,
          'message', left(coalesce(r.processing_error_message, ''), 200),
          'received_at', r.received_at, 'resolved_user_id', r.resolved_user_id
        ) order by r.received_at desc)
        from (select * from public.billing_provider_events
              where processing_status = 'failed'
              order by received_at desc limit 20) r), '[]'::jsonb)
    ),

    'unknown_products', coalesce((
      select jsonb_agg(distinct e.product_id)
      from public.billing_provider_events e
      where e.processing_error_code in ('unknown_product', 'inactive_product')
        and e.product_id is not null), '[]'::jsonb),

    'unresolved_users', jsonb_build_object(
      'count', (select count(*) from public.billing_provider_events
                where processing_error_code in ('unresolved_app_user_id', 'user_not_found')),
      'recent', coalesce((
        select jsonb_agg(jsonb_build_object(
          'event_type', r.event_type, 'code', r.processing_error_code,
          'app_user_ref', case when r.app_user_id is null then null
                               else left(r.app_user_id, 8) || '…' end,
          'received_at', r.received_at
        ) order by r.received_at desc)
        from (select * from public.billing_provider_events
              where processing_error_code in ('unresolved_app_user_id', 'user_not_found')
              order by received_at desc limit 10) r), '[]'::jsonb)
    ),

    'ownership_conflicts', jsonb_build_object(
      'count', (select count(*) from public.billing_provider_events
                where processing_error_code = 'ownership_conflict'),
      'recent', coalesce((
        select jsonb_agg(jsonb_build_object(
          'event_type', r.event_type, 'resolved_user_id', r.resolved_user_id,
          'product_id', r.product_id, 'received_at', r.received_at
        ) order by r.received_at desc)
        from (select * from public.billing_provider_events
              where processing_error_code = 'ownership_conflict'
              order by received_at desc limit 10) r), '[]'::jsonb)
    ),

    -- RevenueCat granted access (processed grant event) but the user has no
    -- live Supabase subscription 15+ minutes later.
    'rc_active_supabase_missing', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', m.event_type, 'resolved_user_id', m.resolved_user_id,
        'product_id', m.product_id, 'processed_at', m.processed_at
      ) order by m.processed_at desc)
      from (
        select e.event_type, e.resolved_user_id, e.product_id, e.processed_at
        from public.billing_provider_events e
        where e.provider = 'revenuecat'
          and e.processing_status = 'processed'
          and e.event_type in ('INITIAL_PURCHASE','RENEWAL','UNCANCELLATION',
                               'PRODUCT_CHANGE','SUBSCRIPTION_EXTENDED')
          and upper(coalesce(e.environment, '')) = 'PRODUCTION'
          and e.received_at > now() - interval '7 days'
          and e.processed_at < now() - interval '15 minutes'
          and e.resolved_user_id is not null
          and not exists (
            select 1 from public.vinetrack_subscriptions s
            where s.owner_user_id = e.resolved_user_id
              and s.billing_provider in ('apple', 'google')
              and s.deleted_at is null
              and s.status in ('trialing', 'active', 'past_due')
          )
        order by e.processed_at desc limit 20
      ) m), '[]'::jsonb),

    -- Deliveries stuck before finalisation (webhook crashed mid-flight).
    'stuck_deliveries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', r.event_type, 'received_at', r.received_at
      ) order by r.received_at desc)
      from (select * from public.billing_provider_events
            where processing_status = 'received'
              and received_at < now() - interval '15 minutes'
            order by received_at desc limit 20) r), '[]'::jsonb),

    'expiring_within_7_days', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', s.owner_user_id, 'plan_code', p.code,
        'provider', s.billing_provider, 'status', s.status,
        'current_period_end', s.current_period_end,
        'cancel_at_period_end', s.cancel_at_period_end
      ) order by s.current_period_end)
      from public.vinetrack_subscriptions s
      join public.vinetrack_plans p on p.id = s.plan_id
      where s.deleted_at is null
        and s.billing_provider in ('apple', 'google')
        and s.status in ('active', 'past_due', 'trialing')
        and s.current_period_end between now() and now() + interval '7 days'),
      '[]'::jsonb),

    'recent_status_changes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', r.user_id, 'event_type', r.event_type,
        'new_status', r.new_state->>'status', 'plan_code', r.new_state->>'plan_code',
        'created_at', r.created_at
      ) order by r.created_at desc)
      from (select * from public.vinetrack_entitlement_audit
            where event_type like 'store\_%' escape '\'
            order by created_at desc limit 20) r), '[]'::jsonb),

    'open_alerts', (select count(*) from public.billing_admin_alerts
                    where acknowledged_at is null)
  ) into v;

  return v;
end;
$$;

revoke all on function public.admin_store_billing_monitor() from public;
grant execute on function public.admin_store_billing_monitor() to authenticated;

comment on function public.admin_store_billing_monitor() is
  'SQL 139: System-Admin-only one-call store-billing health report (JSON). Sections: needs-review, failed, unknown products, unresolved users, ownership conflicts, RC-active-but-Supabase-missing, stuck deliveries, expiring subscriptions, recent status changes, open alerts. App user ids truncated; no receipts, tokens or payloads.';

-- ---------------------------------------------------------------------------
-- E. Alert listing (lazily materialises sync-window alerts) + acknowledge.
-- ---------------------------------------------------------------------------
create or replace function public.admin_billing_alerts(
  p_include_acknowledged boolean default false,
  p_limit integer default 100
)
returns setof public.billing_admin_alerts
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;

  -- Lazy check 1: RevenueCat granted, Supabase not synchronised in window.
  insert into public.billing_admin_alerts
    (alert_type, severity, provider, provider_event_id, event_type, product_id, resolved_user_id, detail)
  select 'sync_window_exceeded', 'critical', e.provider, e.provider_event_id,
         e.event_type, e.product_id, e.resolved_user_id,
         'Provider granted access but no active Supabase subscription 15+ minutes after processing'
  from public.billing_provider_events e
  where e.provider = 'revenuecat'
    and e.processing_status = 'processed'
    and e.event_type in ('INITIAL_PURCHASE','RENEWAL','UNCANCELLATION',
                         'PRODUCT_CHANGE','SUBSCRIPTION_EXTENDED')
    and upper(coalesce(e.environment, '')) = 'PRODUCTION'
    and e.received_at > now() - interval '7 days'
    and e.processed_at < now() - interval '15 minutes'
    and e.resolved_user_id is not null
    and not exists (
      select 1 from public.vinetrack_subscriptions s
      where s.owner_user_id = e.resolved_user_id
        and s.billing_provider in ('apple', 'google')
        and s.deleted_at is null
        and s.status in ('trialing', 'active', 'past_due')
    )
  on conflict (alert_type, provider_event_id) where provider_event_id is not null
  do nothing;

  -- Lazy check 2: deliveries stuck before finalisation.
  insert into public.billing_admin_alerts
    (alert_type, severity, provider, provider_event_id, event_type, product_id, resolved_user_id, detail)
  select 'sync_window_exceeded', 'warning', e.provider, e.provider_event_id,
         e.event_type, e.product_id, e.resolved_user_id,
         'Delivery stuck in status received for 15+ minutes (webhook did not finalise)'
  from public.billing_provider_events e
  where e.processing_status = 'received'
    and e.received_at < now() - interval '15 minutes'
  on conflict (alert_type, provider_event_id) where provider_event_id is not null
  do nothing;

  return query
  select *
  from public.billing_admin_alerts a
  where p_include_acknowledged or a.acknowledged_at is null
  order by a.created_at desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

revoke all on function public.admin_billing_alerts(boolean, integer) from public;
grant execute on function public.admin_billing_alerts(boolean, integer) to authenticated;

create or replace function public.admin_acknowledge_billing_alert(p_alert_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  update public.billing_admin_alerts
  set acknowledged_at = now(),
      acknowledged_by = auth.uid()
  where id = p_alert_id
    and acknowledged_at is null;
  return found;
end;
$$;

revoke all on function public.admin_acknowledge_billing_alert(uuid) from public;
grant execute on function public.admin_acknowledge_billing_alert(uuid) to authenticated;

commit;

-- =====================================================================
-- VERIFICATION (run after commit):
--   select * from public.admin_store_subscription_diagnostics(20);
--   select public.admin_store_billing_monitor();
--   select * from public.admin_billing_alerts();
-- Non-admin callers: diagnostics returns zero rows; monitor/alerts raise.
-- =====================================================================

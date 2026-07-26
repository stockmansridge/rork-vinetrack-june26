-- 124_resend_webhook_delivery_tracking.sql
-- Verified Resend webhook delivery tracking.
--
-- Adds provider lifecycle fields to public.email_delivery_events and creates
-- the idempotency/audit table public.email_webhook_events used by the
-- `resend-webhook` Edge Function.
--
-- Already present from sql/121_email_delivery_events.sql (NOT duplicated here):
--   * email_delivery_events.sent_at
--   * index email_delivery_events_provider_message_idx
--       on email_delivery_events(provider_message_id)
--   * status check constraint already allowing:
--       submitted / sent / delivered / failed / bounced / complained / suppressed
--
-- `email.delivery_delayed` is deliberately NOT a status value. A delay is a
-- temporary condition, so the row keeps its current lifecycle status and only
-- `delayed_at` is stamped (option 2 of the approved status model — no
-- downstream status filters change).
--
-- Writers: service role only (the resend-webhook function). No client
-- insert/update policies exist on either table.
-- Readers: System Administrators via public.is_system_admin().

begin;

-- ---------------------------------------------------------------------------
-- 1. Provider lifecycle fields on the existing delivery log
-- ---------------------------------------------------------------------------
alter table public.email_delivery_events
  add column if not exists provider_event_id   text,
  add column if not exists provider_event_type text,
  add column if not exists provider_event_at   timestamptz,
  add column if not exists delivered_at        timestamptz,
  add column if not exists delayed_at          timestamptz,
  add column if not exists bounced_at          timestamptz,
  add column if not exists complained_at       timestamptz,
  add column if not exists failed_at           timestamptz,
  add column if not exists suppressed_at       timestamptz,
  add column if not exists failure_reason      text,
  add column if not exists bounce_type         text,
  add column if not exists bounce_subtype      text;

comment on column public.email_delivery_events.provider_event_id is
  'svix-id of the most recent provider webhook event applied to this row';
comment on column public.email_delivery_events.provider_event_type is
  'Resend event type of the most recent provider webhook event (e.g. email.delivered)';
comment on column public.email_delivery_events.provider_event_at is
  'Provider-reported time of the most recent webhook event';
comment on column public.email_delivery_events.delayed_at is
  'First email.delivery_delayed event time. A delay never changes status.';

-- ---------------------------------------------------------------------------
-- 2. Webhook receipt table (idempotency + audit)
-- ---------------------------------------------------------------------------
-- One row per unique provider webhook event (svix-id). The unique constraint
-- is the idempotency guard: replays and Svix retries insert-conflict and are
-- acknowledged without reprocessing.
--
-- safe_payload holds ONLY filtered diagnostic fields (email_id, event type,
-- to_count, bounce classification, safe failure reason). Never the full
-- payload, HTML, recipient list, or signature material.
create table if not exists public.email_webhook_events (
  id                  uuid primary key default gen_random_uuid(),
  provider            text not null default 'resend',
  provider_event_id   text not null,
  provider_message_id text,
  event_type          text not null,
  event_created_at    timestamptz,
  delivery_event_id   uuid references public.email_delivery_events(id) on delete set null,
  -- received:  verified + stored, processing not yet finished
  -- processed: matched a delivery event and applied
  -- unmatched: verified but no delivery row has this provider_message_id yet
  --            (kept for delayed reconciliation)
  -- error:     verified but processing failed (safe error in processing_error)
  processing_status   text not null default 'received'
    check (processing_status in ('received', 'processed', 'unmatched', 'error')),
  safe_payload        jsonb not null default '{}'::jsonb,
  processing_error    text,
  received_at         timestamptz not null default now(),
  processed_at        timestamptz,
  constraint email_webhook_events_provider_event_unique
    unique (provider, provider_event_id)
);

create index if not exists email_webhook_events_message_idx
  on public.email_webhook_events (provider_message_id);
create index if not exists email_webhook_events_received_idx
  on public.email_webhook_events (received_at desc);

alter table public.email_webhook_events enable row level security;

-- System admins may read; nobody else. No insert/update/delete policies —
-- only the service role (RLS-bypassing resend-webhook function) writes rows.
drop policy if exists "email_webhook_events_select_system_admin" on public.email_webhook_events;
create policy "email_webhook_events_select_system_admin"
on public.email_webhook_events for select
to authenticated
using (public.is_system_admin());

commit;

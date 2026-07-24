-- 121_email_delivery_events.sql
-- Shared email delivery-event log for ALL application email sent through the
-- Resend API by Supabase Edge Functions (invitations, support, notifications,
-- diagnostics). Supabase Auth email (recovery / signup / email-change) is NOT
-- logged here — Auth owns those flows.
--
-- Writers: edge functions using the SERVICE ROLE key only (service role
--          bypasses RLS; no client insert/update policies are created).
-- Readers: System Administrators (public.is_system_admin(),
--          sql/062_system_admin_and_feature_flags.sql). Ordinary users cannot
--          browse delivery history.
--
-- Never stored here: API keys, password-reset tokens, Auth confirmation
-- links, or full rendered email HTML. `metadata` holds only small structured
-- context (e.g. invitation_id, support_request_id, template name).

begin;

create table if not exists public.email_delivery_events (
  id                  uuid primary key default gen_random_uuid(),
  email_type          text not null,
  recipient_email     text not null,
  source_platform     text not null default 'unknown',
  actor_user_id       uuid references auth.users(id) on delete set null,
  provider            text not null default 'resend',
  provider_message_id text,
  -- submitted: accepted by our function, handed to provider not yet confirmed
  -- sent:      provider API accepted the message
  -- delivered/bounced/complained/failed: from provider webhooks
  -- suppressed: provider refused (e.g. suppression list)
  status              text not null default 'submitted'
    check (status in ('submitted','sent','delivered','failed','bounced','complained','suppressed')),
  error_code          text,
  created_at          timestamptz not null default now(),
  sent_at             timestamptz,
  metadata            jsonb not null default '{}'::jsonb
);

create index if not exists email_delivery_events_recipient_created_idx
  on public.email_delivery_events (recipient_email, created_at desc);
create index if not exists email_delivery_events_type_created_idx
  on public.email_delivery_events (email_type, created_at desc);
create index if not exists email_delivery_events_provider_message_idx
  on public.email_delivery_events (provider_message_id);

alter table public.email_delivery_events enable row level security;

-- System admins may read; nobody else. No insert/update/delete policies —
-- only the service role (RLS-bypassing) writes rows.
drop policy if exists "email_delivery_events_select_system_admin" on public.email_delivery_events;
create policy "email_delivery_events_select_system_admin"
on public.email_delivery_events for select
to authenticated
using (public.is_system_admin());

commit;

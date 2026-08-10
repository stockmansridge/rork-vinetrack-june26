-- ===========================================================================
-- 178_integration_webhook_platform.sql — Stage 5A: outbound webhook platform
-- ===========================================================================
-- Builds the complete server-side webhook system on the SQL 172 foundation:
--
--   A. Event catalogue extension (is_system flag + webhook.test)
--   B. webhook_endpoints lifecycle/health columns (additive)
--   C. integration_events — canonical immutable domain events (outbox)
--   D. webhook_deliveries — delivery queue (one logical delivery per
--      event × endpoint; replays/tests create additional rows)
--   E. webhook_delivery_attempts — one row per HTTP attempt
--   F. integration_audit_log action catalogue extension (webhook actions)
--   G. RLS + privilege lockdown for the new tables
--   H. Internal helpers (event→scope map, SSRF-safe URL validation,
--      endpoint authority resolution, Vault-backed secret storage,
--      the canonical event emitter with fan-out)
--   I. Event-generation triggers per resource family
--   J. Management RPCs (authenticated; Stage 2 authority model)
--   K. Dispatcher RPCs (service_role only: claim / secret / record)
--
-- Design guarantees (documented in docs/vinetrack-webhooks.md):
--   * Events are recorded in the SAME transaction as the operational write
--     (outbox pattern): a rolled-back write emits nothing; a committed
--     write either has its event or a WARNING in the Postgres log.
--   * Delivery is AT-LEAST-ONCE. Consumers dedupe on event id/delivery id.
--   * No global ordering promise. occurred_at + ids allow reconciliation.
--   * Access chain re-checked at dispatch time: integration active +
--     active vineyard grant + active scope. Revocation stops queued
--     deliveries (cancelled at claim time, never sent).
--   * Signing secrets live in Supabase Vault; tables keep hash + prefix
--     only; the plaintext is returned exactly once on create/rotate.
--   * Retention: none implemented yet — events/deliveries/attempts are
--     kept indefinitely (documented; no destructive cleanup).
--
-- Strictly additive. Never edits SQL 172–177 objects destructively
-- (the two check-constraint swaps below only WIDEN allowed value sets).
-- ===========================================================================

begin;

-- ===========================================================================
-- A. Event catalogue extension
-- ===========================================================================
alter table public.integration_webhook_event_catalog
  add column if not exists is_system boolean not null default false;

comment on column public.integration_webhook_event_catalog.is_system is
  'System/test-only event names (e.g. webhook.test). Never subscribable; only emitted by explicit management actions.';

insert into public.integration_webhook_event_catalog (event, module, description, is_system) values
  ('webhook.test', 'system', 'Test event sent via the Send Test Webhook management action. Signed exactly like a real webhook; never emitted by operational data.', true)
on conflict (event) do update set is_system = true;

-- ===========================================================================
-- B. webhook_endpoints — lifecycle, health and secret-reference columns
-- ===========================================================================
alter table public.webhook_endpoints
  add column if not exists name                 text check (name is null or length(name) <= 120),
  add column if not exists secret_ref           uuid,
  add column if not exists last_success_at      timestamptz,
  add column if not exists last_failure_at      timestamptz,
  add column if not exists consecutive_failures integer not null default 0,
  add column if not exists paused_at            timestamptz,
  add column if not exists disabled_at          timestamptz,
  add column if not exists disabled_reason      text check (disabled_reason is null or length(disabled_reason) <= 200),
  add column if not exists deleted_at           timestamptz;

comment on column public.webhook_endpoints.secret_ref is
  'Supabase Vault secret id holding the usable signing secret. Tables store hash + prefix only; the plaintext is shown once at create/rotate and is otherwise readable only by the service-role dispatcher RPC.';
comment on column public.webhook_endpoints.consecutive_failures is
  'Consecutive failed deliveries across all deliveries to this endpoint. Reset to 0 on any success. At 10 the endpoint is auto-disabled (status=disabled) and audited.';

-- widen the status set: active | paused | disabled
alter table public.webhook_endpoints
  drop constraint if exists webhook_endpoints_status_check;
alter table public.webhook_endpoints
  add constraint webhook_endpoints_status_check
  check (status in ('active', 'paused', 'disabled'));

-- ===========================================================================
-- C. integration_events — canonical immutable domain events
-- ===========================================================================
create table if not exists public.integration_events (
  id            uuid primary key default gen_random_uuid(),
  -- stable external identity (webhook envelope "id")
  public_id     text not null unique
                default ('evt_' || encode(gen_random_bytes(16), 'hex'))
                check (public_id ~ '^evt_[0-9a-f]{32}$'),
  event_type    text not null references public.integration_webhook_event_catalog(event),
  api_version   text not null default 'v1',
  -- nullable ONLY for the system test event
  vineyard_id   uuid references public.vineyards(id) on delete cascade,
  resource_type text not null check (length(resource_type) <= 60),
  resource_id   uuid not null,
  occurred_at   timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  -- compact, safe "data" object of the webhook envelope. NEVER a raw row.
  payload       jsonb not null default '{}'::jsonb,
  -- origin marker, e.g. 'trigger:trips' or 'rpc:integration_send_test_webhook'
  source        text check (source is null or length(source) <= 80),
  -- logical-operation dedup (resource id + lifecycle transition, with a
  -- transaction discriminator for repeatable transitions)
  dedup_key     text check (dedup_key is null or length(dedup_key) <= 200),
  constraint integration_events_vineyard_required
    check (vineyard_id is not null or event_type = 'webhook.test')
);

comment on table public.integration_events is
  'Canonical integration domain events (Stage 5A outbox). Immutable after creation (guard trigger). Written in the SAME transaction as the operational change. Payload is a compact safe object — consumers fetch authoritative state from the read API. Retention: indefinite (no cleanup implemented; documented).';

create unique index if not exists uq_integration_events_dedup
  on public.integration_events (dedup_key) where dedup_key is not null;
create index if not exists idx_integration_events_vineyard
  on public.integration_events (vineyard_id, created_at desc);
create index if not exists idx_integration_events_type
  on public.integration_events (event_type, created_at desc);

create or replace function public._integration_events_guard()
returns trigger
language plpgsql
as $$
begin
  raise exception 'integration_events is immutable';
end$$;

drop trigger if exists trg_integration_events_guard on public.integration_events;
create trigger trg_integration_events_guard
before update or delete on public.integration_events
for each row execute function public._integration_events_guard();

-- ===========================================================================
-- D. webhook_deliveries — the delivery queue
-- ===========================================================================
create table if not exists public.webhook_deliveries (
  id                    uuid primary key default gen_random_uuid(),
  -- delivery identity presented in X-VineTrack-Delivery. NEVER reused:
  -- replays create a brand-new row with a brand-new public id.
  public_id             text not null unique
                        default ('dlv_' || encode(gen_random_bytes(16), 'hex'))
                        check (public_id ~ '^dlv_[0-9a-f]{32}$'),
  event_id              uuid not null references public.integration_events(id) on delete cascade,
  endpoint_id           uuid not null references public.webhook_endpoints(id) on delete cascade,
  integration_client_id uuid not null references public.integration_clients(id) on delete cascade,
  vineyard_id           uuid references public.vineyards(id) on delete cascade,
  subscription_id       uuid references public.webhook_subscriptions(id) on delete set null,
  status                text not null default 'pending'
                        check (status in ('pending', 'delivering', 'delivered', 'failed', 'cancelled')),
  is_test               boolean not null default false,
  replay_of             uuid references public.webhook_deliveries(id) on delete set null,
  attempt_count         integer not null default 0 check (attempt_count >= 0),
  next_attempt_at       timestamptz not null default now(),
  claim_token           uuid,
  claimed_at            timestamptz,
  created_at            timestamptz not null default now(),
  delivered_at          timestamptz,
  failed_at             timestamptz,
  cancelled_at          timestamptz,
  cancel_reason         text check (cancel_reason is null or length(cancel_reason) <= 80),
  last_status_code      integer check (last_status_code is null or last_status_code between 100 and 599),
  last_error_code       text check (last_error_code is null or length(last_error_code) <= 80)
);

comment on table public.webhook_deliveries is
  'Webhook delivery queue + history. At-least-once semantics. One ORIGINAL delivery per (event, endpoint); replays add rows (replay_of set, fresh public_id). Claimed with FOR UPDATE SKIP LOCKED + lease (claim_token/claimed_at) so parallel dispatchers never double-send. Stores no secret-bearing headers by design. Retention: indefinite (documented).';

-- one original (non-replay, non-test) delivery per event × endpoint
create unique index if not exists uq_webhook_deliveries_original
  on public.webhook_deliveries (event_id, endpoint_id)
  where replay_of is null and is_test = false;
-- due-queue scan
create index if not exists idx_webhook_deliveries_due
  on public.webhook_deliveries (next_attempt_at)
  where status in ('pending', 'delivering');
-- management keyset (newest first)
create index if not exists idx_webhook_deliveries_client_keyset
  on public.webhook_deliveries (integration_client_id, created_at desc, id desc);
create index if not exists idx_webhook_deliveries_endpoint
  on public.webhook_deliveries (endpoint_id, created_at desc);
create index if not exists idx_webhook_deliveries_event
  on public.webhook_deliveries (event_id);

-- ===========================================================================
-- E. webhook_delivery_attempts — one row per HTTP attempt
-- ===========================================================================
create table if not exists public.webhook_delivery_attempts (
  id             uuid primary key default gen_random_uuid(),
  delivery_id    uuid not null references public.webhook_deliveries(id) on delete cascade,
  attempt_number integer not null check (attempt_number >= 1),
  attempted_at   timestamptz not null default now(),
  finished_at    timestamptz,
  http_status    integer check (http_status is null or http_status between 100 and 599),
  duration_ms    integer check (duration_ms is null or duration_ms >= 0),
  -- safe error taxonomy; NEVER raw response bodies or headers
  error_category text check (error_category is null or error_category in
                   ('timeout', 'network', 'tls', 'http_3xx', 'http_4xx', 'http_5xx',
                    'ssrf_blocked', 'secret_unavailable', 'dispatch_error', 'other')),
  error_detail   text check (error_detail is null or length(error_detail) <= 500),
  constraint uq_webhook_delivery_attempt unique (delivery_id, attempt_number)
);

comment on table public.webhook_delivery_attempts is
  'One row per outbound HTTP attempt. First version deliberately stores NO response bodies — only status, duration and a sanitised error category/detail (≤500 chars, set by the dispatcher, never raw payloads).';

-- ===========================================================================
-- F. integration_audit_log — widen the action catalogue (additive values)
-- ===========================================================================
alter table public.integration_audit_log
  drop constraint if exists integration_audit_log_action_check;
alter table public.integration_audit_log
  add constraint integration_audit_log_action_check
  check (action in (
    -- SQL 172 originals
    'integration.created', 'integration.updated',
    'integration.paused', 'integration.reactivated',
    'integration.revoked',
    'api_key.created', 'api_key.revoked', 'api_key.rotated',
    'vineyard_access.granted', 'vineyard_access.revoked',
    'scope.granted', 'scope.revoked',
    -- Stage 5A webhook actions
    'webhook_endpoint.created', 'webhook_endpoint.updated',
    'webhook_endpoint.paused', 'webhook_endpoint.reactivated',
    'webhook_endpoint.disabled', 'webhook_endpoint.deleted',
    'webhook_secret.rotated',
    'webhook_subscription.created', 'webhook_subscription.deleted',
    'webhook.test_sent', 'webhook.replayed'
  ));

-- ===========================================================================
-- G. RLS + privilege lockdown (new tables are RPC/service-role only)
-- ===========================================================================
alter table public.integration_events       enable row level security;
alter table public.webhook_deliveries       enable row level security;
alter table public.webhook_delivery_attempts enable row level security;

revoke all on public.integration_events,
              public.webhook_deliveries,
              public.webhook_delivery_attempts
from anon, authenticated;

-- ===========================================================================
-- H. Internal helpers (no client execute)
-- ===========================================================================

-- Required read scope for an event, derived from the catalogue module.
-- NULL means "no scope gate" (system test events only).
create or replace function public._integration_event_scope(p_event text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case c.module
    when 'trips'      then 'trips:read'
    when 'sprays'     then 'sprays:read'
    when 'fuel'       then 'fuel:read'
    when 'growth'     then 'growth_stages:read'
    when 'yield'      then 'yield:read'
    when 'work'       then 'work_tasks:read'
    when 'pruning'    then 'pruning:read'
    when 'irrigation' then 'irrigation:read'
    when 'pins'       then 'pins:read'
    when 'structure'  then 'blocks:read'
    else null
  end
  from public.integration_webhook_event_catalog c
  where c.event = p_event;
$$;

-- ---------------------------------------------------------------------------
-- SSRF-safe webhook URL validation.
--   invalid_webhook_url      — malformed / not HTTPS / bad hostname
--   webhook_url_not_allowed  — well-formed but targets a blocked destination
--
-- Policy (documented in docs/vinetrack-webhooks.md):
--   * HTTPS only; optional explicit port limited to 443 / 8443
--   * hostname required (IP literals — v4, v6, decimal, hex — all refused)
--   * at least one dot + alphabetic TLD (single-label intranet names refused)
--   * localhost / *.localhost / *.local / *.internal / *.home.arpa refused
--   * no userinfo (user@host) trickery
-- DNS resolution cannot happen in SQL; the dispatcher re-resolves the host
-- at send time and refuses private/reserved addresses (defence in depth).
-- ---------------------------------------------------------------------------
create or replace function public._integration_validate_webhook_url(p_url text)
returns void
language plpgsql
immutable
security definer
set search_path = public
as $$
declare
  v_rest      text;
  v_authority text;
  v_host      text;
  v_port      text;
begin
  if p_url is null or length(p_url) > 500 or p_url ~ '\s' then
    raise exception 'invalid_webhook_url';
  end if;
  if p_url !~* '^https://' then
    raise exception 'invalid_webhook_url';
  end if;

  v_rest := substring(p_url from 9);                    -- strip https://
  v_authority := substring(v_rest from '^[^/?#]*');     -- up to path/query/frag

  if v_authority is null or v_authority = '' then
    raise exception 'invalid_webhook_url';
  end if;
  -- no userinfo, no IPv6 literals
  if position('@' in v_authority) > 0 or position('[' in v_authority) > 0 then
    raise exception 'webhook_url_not_allowed';
  end if;

  v_host := lower(split_part(v_authority, ':', 1));
  v_port := nullif(split_part(v_authority, ':', 2), '');

  if v_port is not null and v_port not in ('443', '8443') then
    raise exception 'webhook_url_not_allowed';
  end if;
  if v_host = '' then
    raise exception 'invalid_webhook_url';
  end if;
  -- syntactically valid hostname
  if v_host !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' then
    raise exception 'invalid_webhook_url';
  end if;
  -- IP-literal shapes (dotted quad, bare decimal, hex) — hostname required
  if v_host ~ '^[0-9.]+$' or v_host ~ '^0x' then
    raise exception 'webhook_url_not_allowed';
  end if;
  -- must have a dot and an alphabetic TLD (blocks single-label intranet names)
  if v_host !~ '\.[a-z][a-z0-9-]*$' then
    raise exception 'webhook_url_not_allowed';
  end if;
  -- loopback / link-local / internal suffixes
  if v_host = 'localhost'
     or v_host like '%.localhost'
     or v_host like '%.local'
     or v_host like '%.internal'
     or v_host like '%.home.arpa'
     or v_host = 'metadata.google.internal' then
    raise exception 'webhook_url_not_allowed';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- Resolve an endpoint the current user may MANAGE. Non-disclosing: missing,
-- deleted and not-yours all raise 'webhook_endpoint_not_found'.
-- ---------------------------------------------------------------------------
create or replace function public._integration_webhook_require_endpoint(p_endpoint_id uuid)
returns public.webhook_endpoints
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.webhook_endpoints;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select * into r from public.webhook_endpoints e
  where e.id = p_endpoint_id and e.deleted_at is null;
  if not found then
    raise exception 'webhook_endpoint_not_found';
  end if;
  begin
    perform public._integration_require_manage(r.integration_client_id);
  exception when raise_exception then
    raise exception 'webhook_endpoint_not_found';
  end;
  return r;
end$$;

-- View-authority variant (Stage 2 rule: account owner, platform admin, or
-- Owner/Manager of a vineyard with an ACTIVE grant to the integration).
create or replace function public._integration_webhook_view_endpoint(p_endpoint_id uuid)
returns public.webhook_endpoints
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.webhook_endpoints;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select * into r from public.webhook_endpoints e
  where e.id = p_endpoint_id and e.deleted_at is null;
  if not found or not public._integration_can_view(auth.uid(), r.integration_client_id) then
    raise exception 'webhook_endpoint_not_found';
  end if;
  return r;
end$$;

-- ---------------------------------------------------------------------------
-- Store/rotate the usable signing secret in Supabase Vault. Returns the
-- vault secret id. Plaintext NEVER lands in a public table or audit row.
-- ---------------------------------------------------------------------------
create or replace function public._integration_webhook_store_secret(
  p_endpoint_id uuid,
  p_secret text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, vault
as $$
declare
  v_ref uuid;
begin
  select secret_ref into v_ref
  from public.webhook_endpoints where id = p_endpoint_id;

  if v_ref is null then
    v_ref := vault.create_secret(
      p_secret,
      'webhook_endpoint:' || p_endpoint_id::text,
      'VineTrack webhook signing secret (Stage 5A)');
  else
    perform vault.update_secret(v_ref, p_secret);
  end if;
  return v_ref;
end$$;

-- ---------------------------------------------------------------------------
-- Canonical event emitter + fan-out (the outbox writer).
--   * Fast exit: nothing is stored unless at least one ACTIVE integration
--     holds an ACTIVE grant on the vineyard (keeps hot tables cheap).
--   * Dedup: ON CONFLICT on dedup_key — created/completed transitions are
--     once-ever per resource; updated transitions are once per transaction.
--   * Fan-out enforces, PER ENDPOINT: subscription active + event/vineyard
--     match + endpoint active + integration active + ACTIVE vineyard grant
--     + ACTIVE required scope. The dispatcher re-checks all of it later.
-- Returns the event id, or NULL when suppressed/deduplicated.
-- ---------------------------------------------------------------------------
create or replace function public._integration_emit_event(
  p_event_type text,
  p_vineyard_id uuid,
  p_resource_type text,
  p_resource_id uuid,
  p_data jsonb,
  p_dedup_key text,
  p_source text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_scope    text;
begin
  if p_vineyard_id is not null then
    if not exists (
      select 1
      from public.integration_client_vineyards g
      join public.integration_clients c on c.id = g.integration_client_id
      where g.vineyard_id = p_vineyard_id
        and g.revoked_at is null
        and c.status = 'active'
    ) then
      return null;
    end if;
  end if;

  insert into public.integration_events
    (event_type, vineyard_id, resource_type, resource_id, payload, dedup_key, source)
  values
    (p_event_type, p_vineyard_id, p_resource_type, p_resource_id,
     coalesce(p_data, '{}'::jsonb), p_dedup_key, p_source)
  on conflict (dedup_key) where dedup_key is not null do nothing
  returning id into v_event_id;

  if v_event_id is null then
    return null;  -- deduplicated
  end if;

  v_scope := public._integration_event_scope(p_event_type);

  insert into public.webhook_deliveries
    (event_id, endpoint_id, integration_client_id, vineyard_id, subscription_id)
  select distinct on (e.id)
         v_event_id, e.id, e.integration_client_id, p_vineyard_id, s.id
  from public.webhook_subscriptions s
  join public.webhook_endpoints e on e.id = s.webhook_endpoint_id
  join public.integration_clients c on c.id = e.integration_client_id
  where s.is_active
    and s.event_type = p_event_type
    and (s.vineyard_id is null or s.vineyard_id = p_vineyard_id)
    and e.status = 'active'
    and e.deleted_at is null
    and c.status = 'active'
    and exists (
      select 1 from public.integration_client_vineyards g
      where g.integration_client_id = c.id
        and g.vineyard_id = p_vineyard_id
        and g.revoked_at is null)
    and (v_scope is null or exists (
      select 1 from public.integration_client_scopes sc
      where sc.integration_client_id = c.id
        and sc.scope = v_scope
        and sc.revoked_at is null))
  order by e.id, (s.vineyard_id is not null) desc  -- prefer vineyard-specific subscription
  on conflict (event_id, endpoint_id) where replay_of is null and is_test = false
  do nothing;

  return v_event_id;
end$$;

revoke all on function public._integration_event_scope(text)                          from public, anon, authenticated;
revoke all on function public._integration_validate_webhook_url(text)                 from public, anon, authenticated;
revoke all on function public._integration_webhook_require_endpoint(uuid)             from public, anon, authenticated;
revoke all on function public._integration_webhook_view_endpoint(uuid)                from public, anon, authenticated;
revoke all on function public._integration_webhook_store_secret(uuid, text)           from public, anon, authenticated;
revoke all on function public._integration_emit_event(text, uuid, text, uuid, jsonb, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Never-break-the-app wrapper: a webhook bug must not fail iOS/Android sync
-- writes. Failures raise a WARNING (visible in Postgres logs) instead of
-- aborting the operational transaction. Trade-off documented in the report.
-- ---------------------------------------------------------------------------
create or replace function public._integration_emit_safe(
  p_event_type text,
  p_vineyard_id uuid,
  p_resource_type text,
  p_resource_id uuid,
  p_data jsonb,
  p_dedup_key text,
  p_source text
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  perform public._integration_emit_event(
    p_event_type, p_vineyard_id, p_resource_type, p_resource_id,
    p_data, p_dedup_key, p_source);
exception when others then
  raise warning 'integration webhook event emission failed (% on %): %',
    p_event_type, p_resource_id, sqlerrm;
end$$;

revoke all on function public._integration_emit_safe(text, uuid, text, uuid, jsonb, text, text)
  from public, anon, authenticated;

-- ===========================================================================
-- I. Event-generation triggers — one router per resource family.
--    Mutation paths are fragmented (iOS sync, Android sync, portal RPCs all
--    write the canonical tables directly), so triggers on the CANONICAL
--    PRIMARY tables are the single reliable choke point. Child/allocation
--    tables deliberately carry no triggers (documented limitation).
--    Soft deletions / reversals emit NO events in v1 (no *.deleted names
--    in the catalogue — deliberate; documented).
-- ===========================================================================

-- trips → trip.created / trip.updated / trip.completed
--   * rows inserted already-finished (offline sync) emit ONLY trip.completed
--   * live-tracking updates (is_active) are suppressed — they arrive many
--     times per minute and are not a meaningful external lifecycle change
create or replace function public._integration_evt_trips()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is not null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.end_time is not null then
      perform public._integration_emit_safe('trip.completed', new.vineyard_id, 'trip', new.id,
        jsonb_build_object('id', new.id, 'end_time', new.end_time),
        'trip.completed:' || new.id, 'trigger:trips');
    else
      perform public._integration_emit_safe('trip.created', new.vineyard_id, 'trip', new.id,
        jsonb_build_object('id', new.id),
        'trip.created:' || new.id, 'trigger:trips');
    end if;
  else
    if old.end_time is null and new.end_time is not null then
      perform public._integration_emit_safe('trip.completed', new.vineyard_id, 'trip', new.id,
        jsonb_build_object('id', new.id, 'end_time', new.end_time),
        'trip.completed:' || new.id, 'trigger:trips');
    elsif coalesce(new.is_active, false) then
      return new;  -- live tracking noise: no event
    else
      perform public._integration_emit_safe('trip.updated', new.vineyard_id, 'trip', new.id,
        jsonb_build_object('id', new.id),
        'trip.updated:' || new.id || ':' || txid_current(), 'trigger:trips');
    end if;
  end if;
  return new;
end$$;

drop trigger if exists trg_integration_evt_trips on public.trips;
create trigger trg_integration_evt_trips
after insert or update on public.trips
for each row execute function public._integration_evt_trips();

-- spray_records → spray_job.completed / spray_job.updated
--   A spray_record IS a completed application, so INSERT emits
--   spray_job.completed (one logical event — never created+completed).
--   spray_job.created stays in the catalogue reserved for a future
--   planning-header exposure; it is NOT emitted in v1 (documented).
create or replace function public._integration_evt_spray_records()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is not null or coalesce(new.is_template, false) then
    return new;
  end if;
  if tg_op = 'INSERT' then
    perform public._integration_emit_safe('spray_job.completed', new.vineyard_id, 'spray_job', new.id,
      jsonb_build_object('id', new.id),
      'spray_job.completed:' || new.id, 'trigger:spray_records');
  else
    perform public._integration_emit_safe('spray_job.updated', new.vineyard_id, 'spray_job', new.id,
      jsonb_build_object('id', new.id),
      'spray_job.updated:' || new.id || ':' || txid_current(), 'trigger:spray_records');
  end if;
  return new;
end$$;

drop trigger if exists trg_integration_evt_spray_records on public.spray_records;
create trigger trg_integration_evt_spray_records
after insert or update on public.spray_records
for each row execute function public._integration_evt_spray_records();

-- fuel_purchases → fuel_purchase.created (catalogue has no updated name)
create or replace function public._integration_evt_fuel_purchases()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is null and tg_op = 'INSERT' then
    perform public._integration_emit_safe('fuel_purchase.created', new.vineyard_id, 'fuel_purchase', new.id,
      jsonb_build_object('id', new.id),
      'fuel_purchase.created:' || new.id, 'trigger:fuel_purchases');
  end if;
  return new;
end$$;

drop trigger if exists trg_integration_evt_fuel_purchases on public.fuel_purchases;
create trigger trg_integration_evt_fuel_purchases
after insert on public.fuel_purchases
for each row execute function public._integration_evt_fuel_purchases();

-- tractor_fuel_logs → fuel_log.created / fuel_log.updated
create or replace function public._integration_evt_tractor_fuel_logs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is not null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    perform public._integration_emit_safe('fuel_log.created', new.vineyard_id, 'fuel_log', new.id,
      jsonb_build_object('id', new.id),
      'fuel_log.created:' || new.id, 'trigger:tractor_fuel_logs');
  else
    perform public._integration_emit_safe('fuel_log.updated', new.vineyard_id, 'fuel_log', new.id,
      jsonb_build_object('id', new.id),
      'fuel_log.updated:' || new.id || ':' || txid_current(), 'trigger:tractor_fuel_logs');
  end if;
  return new;
end$$;

drop trigger if exists trg_integration_evt_tractor_fuel_logs on public.tractor_fuel_logs;
create trigger trg_integration_evt_tractor_fuel_logs
after insert or update on public.tractor_fuel_logs
for each row execute function public._integration_evt_tractor_fuel_logs();

-- work_tasks → work_task.created / work_task.updated / work_task.completed
--   "completed" maps to FINALISATION (is_finalized false→true), the only
--   canonical completion concept work_tasks has. Rows inserted already
--   finalised emit ONLY work_task.completed.
create or replace function public._integration_evt_work_tasks()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is not null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if coalesce(new.is_finalized, false) then
      perform public._integration_emit_safe('work_task.completed', new.vineyard_id, 'work_task', new.id,
        jsonb_build_object('id', new.id, 'finalized_at', new.finalized_at),
        'work_task.completed:' || new.id, 'trigger:work_tasks');
    else
      perform public._integration_emit_safe('work_task.created', new.vineyard_id, 'work_task', new.id,
        jsonb_build_object('id', new.id),
        'work_task.created:' || new.id, 'trigger:work_tasks');
    end if;
  else
    if not coalesce(old.is_finalized, false) and coalesce(new.is_finalized, false) then
      perform public._integration_emit_safe('work_task.completed', new.vineyard_id, 'work_task', new.id,
        jsonb_build_object('id', new.id, 'finalized_at', new.finalized_at),
        'work_task.completed:' || new.id, 'trigger:work_tasks');
    else
      perform public._integration_emit_safe('work_task.updated', new.vineyard_id, 'work_task', new.id,
        jsonb_build_object('id', new.id),
        'work_task.updated:' || new.id || ':' || txid_current(), 'trigger:work_tasks');
    end if;
  end if;
  return new;
end$$;

drop trigger if exists trg_integration_evt_work_tasks on public.work_tasks;
create trigger trg_integration_evt_work_tasks
after insert or update on public.work_tasks
for each row execute function public._integration_evt_work_tasks();

-- pruning_activities → pruning_activity.created / pruning_activity.updated
--   Reversal (deleted_at set) emits nothing — the read API omits reversed
--   activities, and the catalogue has no pruning_activity.deleted.
--   Client-generated ids + offline replays: the once-ever created dedup key
--   makes sync replays safe.
create or replace function public._integration_evt_pruning_activities()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is not null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    perform public._integration_emit_safe('pruning_activity.created', new.vineyard_id, 'pruning_activity', new.id,
      jsonb_build_object('id', new.id),
      'pruning_activity.created:' || new.id, 'trigger:pruning_activities');
  else
    perform public._integration_emit_safe('pruning_activity.updated', new.vineyard_id, 'pruning_activity', new.id,
      jsonb_build_object('id', new.id),
      'pruning_activity.updated:' || new.id || ':' || txid_current(), 'trigger:pruning_activities');
  end if;
  return new;
end$$;

drop trigger if exists trg_integration_evt_pruning_activities on public.pruning_activities;
create trigger trg_integration_evt_pruning_activities
after insert or update on public.pruning_activities
for each row execute function public._integration_evt_pruning_activities();

-- irrigation_sessions → irrigation_record.created / .updated / .completed
--   * INSERT emits irrigation_record.created (manual entries are recorded
--     post-hoc with status='completed' — still ONE created event).
--   * planned/running → completed transition emits irrigation_record.completed.
--   * status='reversed' (correction reversal) emits nothing — the read API
--     omits reversed sessions (documented).
create or replace function public._integration_evt_irrigation_sessions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is not null or new.status = 'reversed' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    perform public._integration_emit_safe('irrigation_record.created', new.vineyard_id, 'irrigation_record', new.id,
      jsonb_build_object('id', new.id, 'status', new.status),
      'irrigation_record.created:' || new.id, 'trigger:irrigation_sessions');
  else
    if old.status in ('planned', 'running') and new.status = 'completed' then
      perform public._integration_emit_safe('irrigation_record.completed', new.vineyard_id, 'irrigation_record', new.id,
        jsonb_build_object('id', new.id, 'status', new.status),
        'irrigation_record.completed:' || new.id, 'trigger:irrigation_sessions');
    else
      perform public._integration_emit_safe('irrigation_record.updated', new.vineyard_id, 'irrigation_record', new.id,
        jsonb_build_object('id', new.id, 'status', new.status),
        'irrigation_record.updated:' || new.id || ':' || txid_current(), 'trigger:irrigation_sessions');
    end if;
  end if;
  return new;
end$$;

drop trigger if exists trg_integration_evt_irrigation_sessions on public.irrigation_sessions;
create trigger trg_integration_evt_irrigation_sessions
after insert or update on public.irrigation_sessions
for each row execute function public._integration_evt_irrigation_sessions();

-- growth_stage_records → growth_stage.recorded (insert-only by design)
create or replace function public._integration_evt_growth_stage_records()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is null and tg_op = 'INSERT' then
    perform public._integration_emit_safe('growth_stage.recorded', new.vineyard_id, 'growth_stage', new.id,
      jsonb_build_object('id', new.id, 'stage_code', new.stage_code),
      'growth_stage.recorded:' || new.id, 'trigger:growth_stage_records');
  end if;
  return new;
end$$;

drop trigger if exists trg_integration_evt_growth_stage_records on public.growth_stage_records;
create trigger trg_integration_evt_growth_stage_records
after insert on public.growth_stage_records
for each row execute function public._integration_evt_growth_stage_records();

-- historical_yield_records → yield_record.created / yield_record.updated
create or replace function public._integration_evt_historical_yield_records()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is not null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    perform public._integration_emit_safe('yield_record.created', new.vineyard_id, 'yield_record', new.id,
      jsonb_build_object('id', new.id),
      'yield_record.created:' || new.id, 'trigger:historical_yield_records');
  else
    perform public._integration_emit_safe('yield_record.updated', new.vineyard_id, 'yield_record', new.id,
      jsonb_build_object('id', new.id),
      'yield_record.updated:' || new.id || ':' || txid_current(), 'trigger:historical_yield_records');
  end if;
  return new;
end$$;

drop trigger if exists trg_integration_evt_historical_yield_records on public.historical_yield_records;
create trigger trg_integration_evt_historical_yield_records
after insert or update on public.historical_yield_records
for each row execute function public._integration_evt_historical_yield_records();

-- pins → pin.created / pin.updated / pin.resolved
--   "resolved" = is_completed false→true transition. Pins can be re-opened
--   and re-resolved, so the resolved dedup key carries the transaction id.
create or replace function public._integration_evt_pins()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is not null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    perform public._integration_emit_safe('pin.created', new.vineyard_id, 'pin', new.id,
      jsonb_build_object('id', new.id),
      'pin.created:' || new.id, 'trigger:pins');
  else
    if not coalesce(old.is_completed, false) and coalesce(new.is_completed, false) then
      perform public._integration_emit_safe('pin.resolved', new.vineyard_id, 'pin', new.id,
        jsonb_build_object('id', new.id, 'completed_at', new.completed_at),
        'pin.resolved:' || new.id || ':' || txid_current(), 'trigger:pins');
    else
      perform public._integration_emit_safe('pin.updated', new.vineyard_id, 'pin', new.id,
        jsonb_build_object('id', new.id),
        'pin.updated:' || new.id || ':' || txid_current(), 'trigger:pins');
    end if;
  end if;
  return new;
end$$;

drop trigger if exists trg_integration_evt_pins on public.pins;
create trigger trg_integration_evt_pins
after insert or update on public.pins
for each row execute function public._integration_evt_pins();

-- paddocks (external name: block) → block.created / block.updated
create or replace function public._integration_evt_paddocks()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is not null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    perform public._integration_emit_safe('block.created', new.vineyard_id, 'block', new.id,
      jsonb_build_object('id', new.id),
      'block.created:' || new.id, 'trigger:paddocks');
  else
    perform public._integration_emit_safe('block.updated', new.vineyard_id, 'block', new.id,
      jsonb_build_object('id', new.id),
      'block.updated:' || new.id || ':' || txid_current(), 'trigger:paddocks');
  end if;
  return new;
end$$;

drop trigger if exists trg_integration_evt_paddocks on public.paddocks;
create trigger trg_integration_evt_paddocks
after insert or update on public.paddocks
for each row execute function public._integration_evt_paddocks();

-- ===========================================================================
-- J. Management RPCs (authenticated; Stage 2 authority model:
--    mutations = account owner / platform admin via _integration_require_manage,
--    reads     = additionally Owner/Manager of a granted vineyard).
-- ===========================================================================

-- Shared safe JSON shape for an endpoint. NEVER includes signing_secret_hash
-- or secret_ref — only the display prefix.
create or replace function public._integration_webhook_endpoint_json(r public.webhook_endpoints)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', r.id,
    'integration_client_id', r.integration_client_id,
    'name', r.name,
    'url', r.url,
    'status', r.status,
    'signing_secret_prefix', r.signing_secret_prefix,
    'consecutive_failures', r.consecutive_failures,
    'last_success_at', r.last_success_at,
    'last_failure_at', r.last_failure_at,
    'paused_at', r.paused_at,
    'disabled_at', r.disabled_at,
    'disabled_reason', r.disabled_reason,
    'created_at', r.created_at,
    'updated_at', r.updated_at,
    'subscription_count', (
      select count(*) from public.webhook_subscriptions s
      where s.webhook_endpoint_id = r.id and s.is_active)
  );
$$;

revoke all on function public._integration_webhook_endpoint_json(public.webhook_endpoints)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- integration_list_webhook_endpoints(client) — view authority
-- ---------------------------------------------------------------------------
create or replace function public.integration_list_webhook_endpoints(p_client_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not public._integration_can_view(auth.uid(), p_client_id) then
    raise exception 'integration_not_found';
  end if;
  return coalesce((
    select jsonb_agg(public._integration_webhook_endpoint_json(e) order by e.created_at desc)
    from public.webhook_endpoints e
    where e.integration_client_id = p_client_id
      and e.deleted_at is null), '[]'::jsonb);
end$$;

-- ---------------------------------------------------------------------------
-- integration_get_webhook_endpoint(endpoint) — view authority; includes
-- subscriptions + queue counters.
-- ---------------------------------------------------------------------------
create or replace function public.integration_get_webhook_endpoint(p_endpoint_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.webhook_endpoints;
begin
  r := public._integration_webhook_view_endpoint(p_endpoint_id);
  return public._integration_webhook_endpoint_json(r)
    || jsonb_build_object(
      'subscriptions', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', s.id,
                 'event_type', s.event_type,
                 'vineyard_id', s.vineyard_id,
                 'is_active', s.is_active,
                 'created_at', s.created_at)
               order by s.created_at)
        from public.webhook_subscriptions s
        where s.webhook_endpoint_id = r.id), '[]'::jsonb),
      'pending_deliveries', (
        select count(*) from public.webhook_deliveries d
        where d.endpoint_id = r.id and d.status in ('pending', 'delivering')));
end$$;

-- ---------------------------------------------------------------------------
-- integration_create_webhook_endpoint(client, url, name) — manage authority.
-- Returns the endpoint JSON plus 'signing_secret' EXACTLY ONCE.
-- ---------------------------------------------------------------------------
create or replace function public.integration_create_webhook_endpoint(
  p_client_id uuid,
  p_url text,
  p_name text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  c public.integration_clients;
  v_id     uuid := gen_random_uuid();
  v_secret text := 'whsec_' || encode(gen_random_bytes(24), 'hex');
  v_ref    uuid;
  r public.webhook_endpoints;
begin
  c := public._integration_require_manage(p_client_id);
  if c.status <> 'active' then
    raise exception 'integration_not_active';
  end if;
  if p_name is not null and length(trim(p_name)) > 120 then
    raise exception 'invalid_request';
  end if;
  perform public._integration_validate_webhook_url(p_url);
  if (select count(*) from public.webhook_endpoints e
      where e.integration_client_id = p_client_id and e.deleted_at is null) >= 10 then
    raise exception 'endpoint_limit_reached';
  end if;

  insert into public.webhook_endpoints
    (id, integration_client_id, url, status, signing_secret_hash, signing_secret_prefix, name, created_by)
  values
    (v_id, p_client_id, p_url, 'active',
     public._integration_hash_secret(v_secret),
     left(v_secret, 14),
     nullif(trim(coalesce(p_name, '')), ''),
     auth.uid());

  v_ref := public._integration_webhook_store_secret(v_id, v_secret);
  update public.webhook_endpoints set secret_ref = v_ref where id = v_id;

  perform public._integration_audit(p_client_id, 'webhook_endpoint.created', null,
    jsonb_build_object('endpoint_id', v_id, 'url', p_url));

  select * into r from public.webhook_endpoints where id = v_id;
  return public._integration_webhook_endpoint_json(r)
    || jsonb_build_object('signing_secret', v_secret);
end$$;

-- ---------------------------------------------------------------------------
-- integration_update_webhook_endpoint(endpoint, url, name) — manage authority.
-- ---------------------------------------------------------------------------
create or replace function public.integration_update_webhook_endpoint(
  p_endpoint_id uuid,
  p_url text default null,
  p_name text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.webhook_endpoints;
  v_changes jsonb := '{}'::jsonb;
begin
  r := public._integration_webhook_require_endpoint(p_endpoint_id);

  if p_url is not null and p_url <> r.url then
    perform public._integration_validate_webhook_url(p_url);
    update public.webhook_endpoints
    set url = p_url,
        consecutive_failures = 0   -- fresh start for a fixed destination
    where id = r.id;
    v_changes := v_changes || jsonb_build_object('url', p_url);
  end if;

  if p_name is not null then
    if length(trim(p_name)) > 120 then
      raise exception 'invalid_request';
    end if;
    update public.webhook_endpoints
    set name = nullif(trim(p_name), '')
    where id = r.id;
    v_changes := v_changes || jsonb_build_object('name', nullif(trim(p_name), ''));
  end if;

  if v_changes <> '{}'::jsonb then
    perform public._integration_audit(r.integration_client_id, 'webhook_endpoint.updated', null,
      jsonb_build_object('endpoint_id', r.id, 'changes', v_changes));
  end if;

  select * into r from public.webhook_endpoints where id = r.id;
  return public._integration_webhook_endpoint_json(r);
end$$;

-- ---------------------------------------------------------------------------
-- integration_set_webhook_endpoint_status(endpoint, 'paused'|'active')
--   pause      — dispatching defers queued deliveries (nothing is lost)
--   reactivate — clears pause/disable state, resets the failure counter;
--                deferred deliveries resume automatically
-- ---------------------------------------------------------------------------
create or replace function public.integration_set_webhook_endpoint_status(
  p_endpoint_id uuid,
  p_status text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.webhook_endpoints;
begin
  r := public._integration_webhook_require_endpoint(p_endpoint_id);
  if p_status not in ('active', 'paused') then
    raise exception 'invalid_status';
  end if;
  if p_status = r.status then
    return public._integration_webhook_endpoint_json(r);
  end if;

  if p_status = 'paused' then
    update public.webhook_endpoints
    set status = 'paused', paused_at = now()
    where id = r.id;
    perform public._integration_audit(r.integration_client_id, 'webhook_endpoint.paused', null,
      jsonb_build_object('endpoint_id', r.id));
  else
    update public.webhook_endpoints
    set status = 'active',
        paused_at = null,
        disabled_at = null,
        disabled_reason = null,
        consecutive_failures = 0
    where id = r.id;
    perform public._integration_audit(r.integration_client_id, 'webhook_endpoint.reactivated', null,
      jsonb_build_object('endpoint_id', r.id, 'previous_status', r.status));
  end if;

  select * into r from public.webhook_endpoints where id = r.id;
  return public._integration_webhook_endpoint_json(r);
end$$;

-- ---------------------------------------------------------------------------
-- integration_delete_webhook_endpoint(endpoint) — manage authority.
-- Soft delete: history retained; queued deliveries cancelled; Vault secret
-- removed so the signing secret is unrecoverable afterwards.
-- ---------------------------------------------------------------------------
create or replace function public.integration_delete_webhook_endpoint(p_endpoint_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, vault
as $$
declare
  r public.webhook_endpoints;
  v_cancelled integer;
begin
  r := public._integration_webhook_require_endpoint(p_endpoint_id);

  update public.webhook_deliveries
  set status = 'cancelled',
      cancelled_at = now(),
      cancel_reason = 'endpoint_deleted',
      claim_token = null
  where endpoint_id = r.id and status in ('pending', 'delivering');
  get diagnostics v_cancelled = row_count;

  update public.webhook_endpoints
  set deleted_at = now(), secret_ref = null
  where id = r.id;

  if r.secret_ref is not null then
    delete from vault.secrets where id = r.secret_ref;
  end if;

  perform public._integration_audit(r.integration_client_id, 'webhook_endpoint.deleted', null,
    jsonb_build_object('endpoint_id', r.id, 'cancelled_deliveries', v_cancelled));
end$$;

-- ---------------------------------------------------------------------------
-- integration_rotate_webhook_secret(endpoint) — manage authority.
-- Immediate cutover: the old secret stops verifying the moment this returns.
-- Returns the NEW secret exactly once.
-- ---------------------------------------------------------------------------
create or replace function public.integration_rotate_webhook_secret(p_endpoint_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.webhook_endpoints;
  v_secret text := 'whsec_' || encode(gen_random_bytes(24), 'hex');
  v_ref uuid;
begin
  r := public._integration_webhook_require_endpoint(p_endpoint_id);

  v_ref := public._integration_webhook_store_secret(r.id, v_secret);
  update public.webhook_endpoints
  set signing_secret_hash = public._integration_hash_secret(v_secret),
      signing_secret_prefix = left(v_secret, 14),
      secret_ref = v_ref
  where id = r.id;

  perform public._integration_audit(r.integration_client_id, 'webhook_secret.rotated', null,
    jsonb_build_object('endpoint_id', r.id));

  select * into r from public.webhook_endpoints where id = r.id;
  return public._integration_webhook_endpoint_json(r)
    || jsonb_build_object('signing_secret', v_secret);
end$$;

-- ---------------------------------------------------------------------------
-- integration_list_webhook_subscriptions(endpoint) — view authority
-- ---------------------------------------------------------------------------
create or replace function public.integration_list_webhook_subscriptions(p_endpoint_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.webhook_endpoints;
begin
  r := public._integration_webhook_view_endpoint(p_endpoint_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id,
             'event_type', s.event_type,
             'vineyard_id', s.vineyard_id,
             'is_active', s.is_active,
             'created_at', s.created_at)
           order by s.created_at)
    from public.webhook_subscriptions s
    where s.webhook_endpoint_id = r.id), '[]'::jsonb);
end$$;

-- ---------------------------------------------------------------------------
-- integration_create_webhook_subscription(endpoint, event, vineyard?)
-- Manage authority. Enforces — INDEPENDENTLY — that:
--   * the event exists and is not system-only,
--   * the integration holds the ACTIVE required scope for the event family,
--   * a vineyard restriction (if given) targets an ACTIVELY granted vineyard.
-- ---------------------------------------------------------------------------
create or replace function public.integration_create_webhook_subscription(
  p_endpoint_id uuid,
  p_event_type text,
  p_vineyard_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.webhook_endpoints;
  v_cat record;
  v_scope text;
  v_sub_id uuid;
begin
  r := public._integration_webhook_require_endpoint(p_endpoint_id);

  select * into v_cat from public.integration_webhook_event_catalog c
  where c.event = p_event_type;
  if not found then
    raise exception 'event_not_found';
  end if;
  if v_cat.is_system then
    raise exception 'event_not_subscribable';
  end if;

  v_scope := public._integration_event_scope(p_event_type);
  if v_scope is not null and not exists (
    select 1 from public.integration_client_scopes sc
    where sc.integration_client_id = r.integration_client_id
      and sc.scope = v_scope
      and sc.revoked_at is null) then
    raise exception 'scope_not_granted';
  end if;

  if p_vineyard_id is not null and not exists (
    select 1 from public.integration_client_vineyards g
    where g.integration_client_id = r.integration_client_id
      and g.vineyard_id = p_vineyard_id
      and g.revoked_at is null) then
    raise exception 'vineyard_not_granted';
  end if;

  begin
    insert into public.webhook_subscriptions (webhook_endpoint_id, event_type, vineyard_id)
    values (r.id, p_event_type, p_vineyard_id)
    returning id into v_sub_id;
  exception when unique_violation then
    raise exception 'subscription_exists';
  end;

  perform public._integration_audit(r.integration_client_id, 'webhook_subscription.created', p_vineyard_id,
    jsonb_build_object('endpoint_id', r.id, 'subscription_id', v_sub_id, 'event_type', p_event_type));

  return jsonb_build_object(
    'id', v_sub_id,
    'webhook_endpoint_id', r.id,
    'event_type', p_event_type,
    'vineyard_id', p_vineyard_id,
    'is_active', true);
end$$;

-- ---------------------------------------------------------------------------
-- integration_delete_webhook_subscription(subscription) — manage authority.
-- Hard delete (subscriptions are configuration, not history); audited.
-- ---------------------------------------------------------------------------
create or replace function public.integration_delete_webhook_subscription(p_subscription_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_sub record;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select s.id, s.event_type, s.vineyard_id, e.integration_client_id, e.id as endpoint_id
  into v_sub
  from public.webhook_subscriptions s
  join public.webhook_endpoints e on e.id = s.webhook_endpoint_id
  where s.id = p_subscription_id;
  if not found then
    raise exception 'subscription_not_found';
  end if;
  begin
    perform public._integration_require_manage(v_sub.integration_client_id);
  exception when raise_exception then
    raise exception 'subscription_not_found';
  end;

  delete from public.webhook_subscriptions where id = v_sub.id;

  perform public._integration_audit(v_sub.integration_client_id, 'webhook_subscription.deleted', v_sub.vineyard_id,
    jsonb_build_object('endpoint_id', v_sub.endpoint_id, 'subscription_id', v_sub.id, 'event_type', v_sub.event_type));
end$$;

-- ---------------------------------------------------------------------------
-- integration_send_test_webhook(endpoint) — manage authority.
-- Emits a webhook.test event + one is_test delivery. Signed and delivered
-- exactly like a real webhook; bypasses subscriptions/scopes by design
-- (documented — it proves transport + signature, not entitlements).
-- ---------------------------------------------------------------------------
create or replace function public.integration_send_test_webhook(p_endpoint_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.webhook_endpoints;
  c public.integration_clients;
  v_event_id uuid;
  v_delivery record;
begin
  r := public._integration_webhook_require_endpoint(p_endpoint_id);
  select * into c from public.integration_clients where id = r.integration_client_id;
  if c.status <> 'active' then
    raise exception 'integration_not_active';
  end if;
  if r.status <> 'active' then
    raise exception 'endpoint_not_active';
  end if;

  insert into public.integration_events
    (event_type, vineyard_id, resource_type, resource_id, payload, source)
  values
    ('webhook.test', null, 'webhook_endpoint', r.id,
     jsonb_build_object('endpoint_id', r.id,
                        'message', 'VineTrack test webhook. Verify the X-VineTrack-Signature header, then respond 2xx.'),
     'rpc:integration_send_test_webhook')
  returning id into v_event_id;

  insert into public.webhook_deliveries
    (event_id, endpoint_id, integration_client_id, vineyard_id, is_test)
  values
    (v_event_id, r.id, r.integration_client_id, null, true)
  returning id, public_id into v_delivery;

  perform public._integration_audit(r.integration_client_id, 'webhook.test_sent', null,
    jsonb_build_object('endpoint_id', r.id, 'delivery_id', v_delivery.id));

  return jsonb_build_object(
    'delivery_id', v_delivery.id,
    'delivery_public_id', v_delivery.public_id,
    'status', 'pending');
end$$;

-- ---------------------------------------------------------------------------
-- integration_replay_webhook_delivery(delivery) — manage authority.
-- Creates a BRAND-NEW delivery row (fresh public id, fresh attempts) for the
-- SAME immutable event. Denied when the endpoint is not active or when the
-- integration/grant/scope chain is no longer intact.
-- ---------------------------------------------------------------------------
create or replace function public.integration_replay_webhook_delivery(p_delivery_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  d public.webhook_deliveries;
  r public.webhook_endpoints;
  c public.integration_clients;
  ev public.integration_events;
  v_scope text;
  v_new record;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select * into d from public.webhook_deliveries where id = p_delivery_id;
  if not found then
    raise exception 'delivery_not_found';
  end if;
  begin
    perform public._integration_require_manage(d.integration_client_id);
  exception when raise_exception then
    raise exception 'delivery_not_found';
  end;

  select * into r from public.webhook_endpoints
  where id = d.endpoint_id and deleted_at is null;
  if not found or r.status <> 'active' then
    raise exception 'endpoint_not_active';
  end if;
  select * into c from public.integration_clients where id = d.integration_client_id;
  if c.status <> 'active' then
    raise exception 'integration_not_active';
  end if;

  select * into ev from public.integration_events where id = d.event_id;

  if ev.vineyard_id is not null then
    if not exists (
      select 1 from public.integration_client_vineyards g
      where g.integration_client_id = d.integration_client_id
        and g.vineyard_id = ev.vineyard_id
        and g.revoked_at is null) then
      raise exception 'replay_not_allowed';
    end if;
    v_scope := public._integration_event_scope(ev.event_type);
    if v_scope is not null and not exists (
      select 1 from public.integration_client_scopes sc
      where sc.integration_client_id = d.integration_client_id
        and sc.scope = v_scope
        and sc.revoked_at is null) then
      raise exception 'replay_not_allowed';
    end if;
  end if;

  insert into public.webhook_deliveries
    (event_id, endpoint_id, integration_client_id, vineyard_id,
     subscription_id, is_test, replay_of)
  values
    (d.event_id, d.endpoint_id, d.integration_client_id, d.vineyard_id,
     d.subscription_id, d.is_test, d.id)
  returning id, public_id into v_new;

  perform public._integration_audit(d.integration_client_id, 'webhook.replayed', ev.vineyard_id,
    jsonb_build_object('endpoint_id', d.endpoint_id,
                       'original_delivery_id', d.id,
                       'new_delivery_id', v_new.id,
                       'event_type', ev.event_type));

  return jsonb_build_object(
    'delivery_id', v_new.id,
    'delivery_public_id', v_new.public_id,
    'replay_of', d.id,
    'status', 'pending');
end$$;

-- ---------------------------------------------------------------------------
-- integration_list_webhook_deliveries — view authority; keyset pagination
-- (newest first), same cursor convention as SQL 177 request logs.
-- ---------------------------------------------------------------------------
create or replace function public.integration_list_webhook_deliveries(
  p_client_id uuid,
  p_endpoint_id uuid default null,
  p_event_type text default null,
  p_status text default null,
  p_vineyard_id uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 100,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit integer;
  v_rows jsonb;
  v_count integer;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not public._integration_can_view(auth.uid(), p_client_id) then
    raise exception 'integration_not_found';
  end if;
  if p_status is not null
     and p_status not in ('pending', 'delivering', 'delivered', 'failed', 'cancelled') then
    raise exception 'invalid_status';
  end if;
  if p_from is not null and p_to is not null and p_from > p_to then
    raise exception 'invalid_range';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'invalid_cursor';
  end if;
  v_limit := least(greatest(coalesce(p_limit, 100), 1), 1000);

  select coalesce(jsonb_agg(row_json), '[]'::jsonb), count(*)
  into v_rows, v_count
  from (
    select jsonb_build_object(
             'id', d.id,
             'delivery_id', d.public_id,
             'event_id', ev.public_id,
             'event_type', ev.event_type,
             'endpoint_id', d.endpoint_id,
             'vineyard_id', d.vineyard_id,
             'status', d.status,
             'is_test', d.is_test,
             'replay_of', d.replay_of,
             'attempt_count', d.attempt_count,
             'next_attempt_at', case when d.status = 'pending' then d.next_attempt_at end,
             'last_status_code', d.last_status_code,
             'last_error_code', d.last_error_code,
             'cancel_reason', d.cancel_reason,
             'created_at', d.created_at,
             'delivered_at', d.delivered_at,
             'failed_at', d.failed_at,
             'cancelled_at', d.cancelled_at) as row_json,
           d.created_at, d.id
    from public.webhook_deliveries d
    join public.integration_events ev on ev.id = d.event_id
    where d.integration_client_id = p_client_id
      and (p_endpoint_id is null or d.endpoint_id = p_endpoint_id)
      and (p_event_type is null or ev.event_type = p_event_type)
      and (p_status is null or d.status = p_status)
      and (p_vineyard_id is null or d.vineyard_id = p_vineyard_id)
      and (p_from is null or d.created_at >= p_from)
      and (p_to is null or d.created_at <= p_to)
      and (p_before_created_at is null
           or (d.created_at, d.id) < (p_before_created_at, p_before_id))
    order by d.created_at desc, d.id desc
    limit v_limit
  ) t;

  return jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object(
      'limit', v_limit,
      'returned', v_count,
      'has_more', v_count = v_limit,
      'next_before_created_at', case when v_count = v_limit then (v_rows -> (v_count - 1)) ->> 'created_at' end,
      'next_before_id', case when v_count = v_limit then (v_rows -> (v_count - 1)) ->> 'id' end));
end$$;

-- ---------------------------------------------------------------------------
-- integration_get_webhook_delivery(delivery) — view authority; includes the
-- full attempt history (sanitised categories only — never response bodies).
-- ---------------------------------------------------------------------------
create or replace function public.integration_get_webhook_delivery(p_delivery_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d public.webhook_deliveries;
  ev public.integration_events;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select * into d from public.webhook_deliveries where id = p_delivery_id;
  if not found or not public._integration_can_view(auth.uid(), d.integration_client_id) then
    raise exception 'delivery_not_found';
  end if;
  select * into ev from public.integration_events where id = d.event_id;

  return jsonb_build_object(
    'id', d.id,
    'delivery_id', d.public_id,
    'event', jsonb_build_object(
      'id', ev.public_id,
      'type', ev.event_type,
      'api_version', ev.api_version,
      'occurred_at', ev.occurred_at,
      'vineyard_id', ev.vineyard_id,
      'resource_type', ev.resource_type,
      'resource_id', ev.resource_id,
      'data', ev.payload),
    'endpoint_id', d.endpoint_id,
    'status', d.status,
    'is_test', d.is_test,
    'replay_of', d.replay_of,
    'attempt_count', d.attempt_count,
    'next_attempt_at', case when d.status = 'pending' then d.next_attempt_at end,
    'last_status_code', d.last_status_code,
    'last_error_code', d.last_error_code,
    'cancel_reason', d.cancel_reason,
    'created_at', d.created_at,
    'delivered_at', d.delivered_at,
    'failed_at', d.failed_at,
    'cancelled_at', d.cancelled_at,
    'attempts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'attempt_number', a.attempt_number,
               'attempted_at', a.attempted_at,
               'finished_at', a.finished_at,
               'http_status', a.http_status,
               'duration_ms', a.duration_ms,
               'error_category', a.error_category,
               'error_detail', a.error_detail)
             order by a.attempt_number)
      from public.webhook_delivery_attempts a
      where a.delivery_id = d.id), '[]'::jsonb));
end$$;

-- ===========================================================================
-- K. Dispatcher RPCs — service_role ONLY (called by the
--    vinetrack-webhook-dispatch Edge Function). No client access.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- integration_webhook_claim_deliveries(batch, lease_seconds)
-- Atomically claims due deliveries with FOR UPDATE SKIP LOCKED so parallel
-- dispatcher runs never double-send. Also the LAZY REVOCATION point: every
-- claim re-checks endpoint / integration / vineyard-grant / scope state and
--   * cancels permanently broken deliveries (revoked / deleted / disabled),
--   * defers paused ones (endpoint or integration paused → +5 minutes),
--   * claims the rest (status='delivering', fresh claim_token lease).
-- Expired leases ('delivering' older than the lease) are reclaimable, which
-- is what makes delivery AT-LEAST-ONCE rather than at-most-once.
-- ---------------------------------------------------------------------------
create or replace function public.integration_webhook_claim_deliveries(
  p_batch integer default 20,
  p_lease_seconds integer default 60
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_batch integer := least(greatest(coalesce(p_batch, 20), 1), 100);
  v_lease integer := least(greatest(coalesce(p_lease_seconds, 60), 10), 600);
  v_out jsonb := '[]'::jsonb;
  v_token uuid;
  v_scope text;
  rec record;
begin
  for rec in
    select d.id
    from public.webhook_deliveries d
    where (d.status = 'pending' and d.next_attempt_at <= now())
       or (d.status = 'delivering'
           and d.claimed_at is not null
           and d.claimed_at < now() - make_interval(secs => v_lease))
    order by d.next_attempt_at asc
    limit v_batch
    for update skip locked
  loop
    declare
      d  public.webhook_deliveries;
      ep public.webhook_endpoints;
      cl public.integration_clients;
      ev public.integration_events;
    begin
      select * into d  from public.webhook_deliveries where id = rec.id;
      select * into ep from public.webhook_endpoints  where id = d.endpoint_id;
      select * into cl from public.integration_clients where id = d.integration_client_id;
      select * into ev from public.integration_events  where id = d.event_id;

      -- permanent terminations (never sent; recorded via cancel_reason)
      if ep.deleted_at is not null then
        update public.webhook_deliveries set status = 'cancelled', cancelled_at = now(),
          cancel_reason = 'endpoint_deleted', claim_token = null where id = d.id;
        continue;
      elsif ep.status = 'disabled' then
        update public.webhook_deliveries set status = 'cancelled', cancelled_at = now(),
          cancel_reason = 'endpoint_disabled', claim_token = null where id = d.id;
        continue;
      elsif cl.status = 'revoked' then
        update public.webhook_deliveries set status = 'cancelled', cancelled_at = now(),
          cancel_reason = 'integration_revoked', claim_token = null where id = d.id;
        continue;
      end if;

      -- paused → defer (nothing lost; resumes on reactivation)
      if ep.status = 'paused' or cl.status = 'paused' then
        update public.webhook_deliveries set status = 'pending',
          next_attempt_at = now() + interval '5 minutes',
          claim_token = null, claimed_at = null where id = d.id;
        continue;
      end if;

      -- entitlement re-check for real (non-test) events
      if not d.is_test and ev.vineyard_id is not null then
        if not exists (
          select 1 from public.integration_client_vineyards g
          where g.integration_client_id = d.integration_client_id
            and g.vineyard_id = ev.vineyard_id
            and g.revoked_at is null) then
          update public.webhook_deliveries set status = 'cancelled', cancelled_at = now(),
            cancel_reason = 'vineyard_grant_revoked', claim_token = null where id = d.id;
          continue;
        end if;
        v_scope := public._integration_event_scope(ev.event_type);
        if v_scope is not null and not exists (
          select 1 from public.integration_client_scopes sc
          where sc.integration_client_id = d.integration_client_id
            and sc.scope = v_scope
            and sc.revoked_at is null) then
          update public.webhook_deliveries set status = 'cancelled', cancelled_at = now(),
            cancel_reason = 'scope_revoked', claim_token = null where id = d.id;
          continue;
        end if;
      end if;

      -- claim
      v_token := gen_random_uuid();
      update public.webhook_deliveries
      set status = 'delivering', claim_token = v_token, claimed_at = now()
      where id = d.id;

      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'delivery_id', d.id,
        'claim_token', v_token,
        'delivery_public_id', d.public_id,
        'attempt_number', d.attempt_count + 1,
        'endpoint_id', ep.id,
        'url', ep.url,
        'event', jsonb_build_object(
          'id', ev.public_id,
          'type', ev.event_type,
          'api_version', ev.api_version,
          'occurred_at', to_char(ev.occurred_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
          'vineyard_id', ev.vineyard_id,
          'data', ev.payload)));
    end;
  end loop;

  return v_out;
end$$;

-- ---------------------------------------------------------------------------
-- integration_webhook_get_endpoint_secret(endpoint) — the ONLY reader of the
-- usable signing secret. service_role only.
-- ---------------------------------------------------------------------------
create or replace function public.integration_webhook_get_endpoint_secret(p_endpoint_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, vault
as $$
declare
  v_ref uuid;
  v_secret text;
begin
  select secret_ref into v_ref
  from public.webhook_endpoints
  where id = p_endpoint_id and deleted_at is null;
  if v_ref is null then
    raise exception 'secret_unavailable';
  end if;
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where id = v_ref;
  if v_secret is null then
    raise exception 'secret_unavailable';
  end if;
  return v_secret;
end$$;

-- ---------------------------------------------------------------------------
-- integration_webhook_record_attempt — outcome bookkeeping for one attempt.
--   p_outcome: 'success' | 'retryable' | 'permanent'
-- Backoff schedule after failed attempt N: 1m, 5m, 30m, 2h, 12h, 24h;
-- max 7 attempts total. Retry-After (seconds, clamped ≤ 1h) can only WIDEN
-- the scheduled gap, never shrink it. 10 consecutive endpoint failures
-- auto-disable the endpoint (audited, actor = system/null).
-- ---------------------------------------------------------------------------
create or replace function public.integration_webhook_record_attempt(
  p_delivery_id uuid,
  p_claim_token uuid,
  p_outcome text,
  p_http_status integer default null,
  p_duration_ms integer default null,
  p_error_category text default null,
  p_error_detail text default null,
  p_retry_after_seconds integer default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  d public.webhook_deliveries;
  v_attempt integer;
  v_failures integer;
  v_endpoint_status text;
  v_delay interval;
  v_result jsonb;
begin
  if p_outcome not in ('success', 'retryable', 'permanent') then
    raise exception 'invalid_request';
  end if;

  select * into d from public.webhook_deliveries
  where id = p_delivery_id
  for update;
  if not found or d.status <> 'delivering'
     or d.claim_token is null or d.claim_token <> p_claim_token then
    raise exception 'claim_invalid';
  end if;

  v_attempt := d.attempt_count + 1;

  insert into public.webhook_delivery_attempts
    (delivery_id, attempt_number, attempted_at, finished_at,
     http_status, duration_ms, error_category, error_detail)
  values
    (d.id, v_attempt, coalesce(d.claimed_at, now()), now(),
     p_http_status, p_duration_ms,
     case when p_outcome = 'success' then null else p_error_category end,
     case when p_outcome = 'success' then null else left(p_error_detail, 500) end);

  if p_outcome = 'success' then
    update public.webhook_deliveries
    set status = 'delivered', delivered_at = now(),
        attempt_count = v_attempt,
        last_status_code = p_http_status, last_error_code = null,
        claim_token = null
    where id = d.id;

    update public.webhook_endpoints
    set last_success_at = now(), consecutive_failures = 0
    where id = d.endpoint_id;

    return jsonb_build_object('status', 'delivered', 'attempt_number', v_attempt);
  end if;

  -- failure paths -----------------------------------------------------------
  update public.webhook_endpoints
  set last_failure_at = now(),
      consecutive_failures = consecutive_failures + 1
  where id = d.endpoint_id
  returning consecutive_failures, status into v_failures, v_endpoint_status;

  if v_failures >= 10 and v_endpoint_status = 'active' then
    update public.webhook_endpoints
    set status = 'disabled', disabled_at = now(),
        disabled_reason = 'auto_disabled_after_consecutive_failures'
    where id = d.endpoint_id;
    perform public._integration_audit(d.integration_client_id, 'webhook_endpoint.disabled', null,
      jsonb_build_object('endpoint_id', d.endpoint_id,
                         'consecutive_failures', v_failures,
                         'auto', true));
  end if;

  if p_outcome = 'permanent' or v_attempt >= 7 then
    update public.webhook_deliveries
    set status = 'failed', failed_at = now(),
        attempt_count = v_attempt,
        last_status_code = p_http_status,
        last_error_code = coalesce(p_error_category, 'other'),
        claim_token = null
    where id = d.id;
    v_result := jsonb_build_object('status', 'failed', 'attempt_number', v_attempt);
  else
    v_delay := case v_attempt
      when 1 then interval '1 minute'
      when 2 then interval '5 minutes'
      when 3 then interval '30 minutes'
      when 4 then interval '2 hours'
      when 5 then interval '12 hours'
      else interval '24 hours'
    end;
    if p_retry_after_seconds is not null and p_retry_after_seconds > 0 then
      v_delay := greatest(v_delay,
        make_interval(secs => least(p_retry_after_seconds, 3600)));
    end if;
    update public.webhook_deliveries
    set status = 'pending',
        next_attempt_at = now() + v_delay,
        attempt_count = v_attempt,
        last_status_code = p_http_status,
        last_error_code = coalesce(p_error_category, 'other'),
        claim_token = null, claimed_at = null
    where id = d.id;
    v_result := jsonb_build_object('status', 'pending', 'attempt_number', v_attempt,
                                   'next_attempt_at', now() + v_delay);
  end if;

  return v_result;
end$$;

-- ===========================================================================
-- L. Grants
-- ===========================================================================

-- Management RPCs: authenticated portal users (authority enforced inside).
grant execute on function public.integration_list_webhook_endpoints(uuid)                       to authenticated;
grant execute on function public.integration_get_webhook_endpoint(uuid)                         to authenticated;
grant execute on function public.integration_create_webhook_endpoint(uuid, text, text)          to authenticated;
grant execute on function public.integration_update_webhook_endpoint(uuid, text, text)          to authenticated;
grant execute on function public.integration_set_webhook_endpoint_status(uuid, text)            to authenticated;
grant execute on function public.integration_delete_webhook_endpoint(uuid)                      to authenticated;
grant execute on function public.integration_rotate_webhook_secret(uuid)                        to authenticated;
grant execute on function public.integration_list_webhook_subscriptions(uuid)                   to authenticated;
grant execute on function public.integration_create_webhook_subscription(uuid, text, uuid)      to authenticated;
grant execute on function public.integration_delete_webhook_subscription(uuid)                  to authenticated;
grant execute on function public.integration_send_test_webhook(uuid)                            to authenticated;
grant execute on function public.integration_replay_webhook_delivery(uuid)                      to authenticated;
grant execute on function public.integration_list_webhook_deliveries(uuid, uuid, text, text, uuid, timestamptz, timestamptz, integer, timestamptz, uuid) to authenticated;
grant execute on function public.integration_get_webhook_delivery(uuid)                         to authenticated;

-- Keep anon/public away from everything.
revoke all on function public.integration_list_webhook_endpoints(uuid)                       from public, anon;
revoke all on function public.integration_get_webhook_endpoint(uuid)                         from public, anon;
revoke all on function public.integration_create_webhook_endpoint(uuid, text, text)          from public, anon;
revoke all on function public.integration_update_webhook_endpoint(uuid, text, text)          from public, anon;
revoke all on function public.integration_set_webhook_endpoint_status(uuid, text)            from public, anon;
revoke all on function public.integration_delete_webhook_endpoint(uuid)                      from public, anon;
revoke all on function public.integration_rotate_webhook_secret(uuid)                        from public, anon;
revoke all on function public.integration_list_webhook_subscriptions(uuid)                   from public, anon;
revoke all on function public.integration_create_webhook_subscription(uuid, text, uuid)      from public, anon;
revoke all on function public.integration_delete_webhook_subscription(uuid)                  from public, anon;
revoke all on function public.integration_send_test_webhook(uuid)                            from public, anon;
revoke all on function public.integration_replay_webhook_delivery(uuid)                      from public, anon;
revoke all on function public.integration_list_webhook_deliveries(uuid, uuid, text, text, uuid, timestamptz, timestamptz, integer, timestamptz, uuid) from public, anon;
revoke all on function public.integration_get_webhook_delivery(uuid)                         from public, anon;

-- Dispatcher RPCs: service_role ONLY.
revoke all on function public.integration_webhook_claim_deliveries(integer, integer) from public, anon, authenticated;
revoke all on function public.integration_webhook_get_endpoint_secret(uuid)          from public, anon, authenticated;
revoke all on function public.integration_webhook_record_attempt(uuid, uuid, text, integer, integer, text, text, integer) from public, anon, authenticated;
grant execute on function public.integration_webhook_claim_deliveries(integer, integer) to service_role;
grant execute on function public.integration_webhook_get_endpoint_secret(uuid)          to service_role;
grant execute on function public.integration_webhook_record_attempt(uuid, uuid, text, integer, integer, text, text, integer) to service_role;

commit;

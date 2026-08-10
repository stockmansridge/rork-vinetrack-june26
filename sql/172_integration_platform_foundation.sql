-- =====================================================================
-- 172_integration_platform_foundation.sql
-- =====================================================================
-- VineTrack Integration Platform — Stage 2: database foundation ONLY.
--
-- Creates the canonical data model, permission model, audit foundation
-- and management RPC contract for the FUTURE external API / webhook
-- platform. This stage deliberately does NOT:
--   * expose any public /v1 resource endpoint,
--   * deliver any webhook HTTP request,
--   * add any operational-table restructuring,
--   * add portal/iOS/Android UI.
--
-- ACCESS CHAIN (future API request):
--   API key -> integration client -> explicit vineyard grant
--           -> explicit scope grant -> VineTrack API layer -> data.
-- Access is NEVER inferred from the creating user's current vineyard
-- membership at request time. Every vineyard is granted explicitly.
--
-- OWNERSHIP MAPPING:
--   VineTrack has no separate organisations table. The canonical
--   "account" anchor is a profile/user id (same convention as
--   vinetrack_subscriptions.owner_user_id and vineyards.owner_id).
--   integration_clients.owner_user_id is that anchor.
--
-- HUMAN AUTHORITY MAPPING (existing role system, no new role system):
--   * Owner   = vineyard_members.role = 'owner' OR vineyards.owner_id.
--               May create integrations, grant/revoke vineyards+scopes,
--               create/revoke keys, pause/revoke, read audit.
--   * Manager = vineyard_members.role = 'manager' of a vineyard with an
--               ACTIVE grant to the integration. View-only: may list the
--               integration, its grants/scopes and audit history. May
--               NOT create integrations, issue credentials, or grant
--               vineyards/scopes.
--   * Supervisor / Operator = no integration-management access.
--   * Platform admin = public.is_system_admin() (sql/062). Full manage,
--               but can NEVER retrieve a plaintext API secret (only the
--               SHA-256 hash is stored).
--
-- API KEY STORAGE:
--   Secrets look like  vt_live_<48 hex>  /  vt_test_<48 hex>.
--   The database stores ONLY:
--     key_prefix (safe display, e.g. 'vt_live_ab12cd34') and
--     key_hash   (SHA-256 hex of the full secret, unique).
--   The plaintext secret is returned exactly once by
--   integration_create_api_key() and is never written to any table,
--   audit row or log.
--
-- WEBHOOK SIGNING SECRETS:
--   webhook_endpoints stores signing_secret_hash + prefix only.
--   The dispatching stage will keep the usable signing secret in a
--   secure server-side store (e.g. Supabase Vault) — never in this
--   table. No HTTP is sent in Stage 2.
--
-- RLS MODEL:
--   * Catalogue tables (scope + webhook event): readable by any
--     authenticated user (reference data, not sensitive).
--   * ALL other integration tables: RLS enabled with NO policies and
--     ALL table privileges revoked from anon/authenticated. The ONLY
--     access path is the SECURITY DEFINER management RPCs below, which
--     perform explicit authority checks. Nothing can be forged
--     client-side.
--   * integration_audit_log is append-only (trigger blocks UPDATE and
--     DELETE).
--
-- FUTURE-API VALIDATION INVARIANT (sec. 15 of the stage brief), proven
-- by integration_validate_api_request() (service_role only):
--   credential valid AND integration active AND credential not
--   revoked/expired AND scope actively granted AND vineyard explicitly
--   granted. Each check is independent; none substitutes for another.
--
-- ROLLBACK (non-destructive; drops Stage-2 objects only):
--   drop function if exists public.integration_validate_api_request(text, text, uuid);
--   drop function if exists public.integration_audit_history(uuid, integer);
--   drop function if exists public.integration_revoke_api_key(uuid, uuid);
--   drop function if exists public.integration_create_api_key(uuid, text, text, timestamptz);
--   drop function if exists public.integration_list_api_keys(uuid);
--   drop function if exists public.integration_revoke_scope(uuid, text);
--   drop function if exists public.integration_grant_scope(uuid, text);
--   drop function if exists public.integration_list_scopes(uuid);
--   drop function if exists public.integration_revoke_vineyard(uuid, uuid);
--   drop function if exists public.integration_grant_vineyard(uuid, uuid);
--   drop function if exists public.integration_list_vineyard_grants(uuid);
--   drop function if exists public.integration_set_status(uuid, text);
--   drop function if exists public.integration_update_client(uuid, text, text);
--   drop function if exists public.integration_create_client(text, text, text);
--   drop function if exists public.integration_list_clients();
--   drop function if exists public._integration_audit(uuid, text, uuid, jsonb);
--   drop function if exists public._integration_can_view(uuid, uuid);
--   drop function if exists public._integration_require_manage(uuid);
--   drop function if exists public._integration_is_vineyard_owner(uuid, uuid);
--   drop function if exists public._integration_generate_secret(text);
--   drop function if exists public._integration_hash_secret(text);
--   drop table if exists public.integration_idempotency_keys;
--   drop table if exists public.webhook_subscriptions;
--   drop table if exists public.webhook_endpoints;
--   drop table if exists public.integration_api_requests;
--   drop table if exists public.integration_audit_log;
--   drop function if exists public._integration_audit_log_guard();
--   drop table if exists public.integration_client_scopes;
--   drop table if exists public.integration_client_vineyards;
--   drop table if exists public.integration_api_keys;
--   drop table if exists public.integration_clients;
--   drop table if exists public.integration_webhook_event_catalog;
--   drop table if exists public.integration_scope_catalog;
-- =====================================================================

begin;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Preconditions: the canonical VineTrack objects this contract builds on.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.vineyards') is null
     or to_regclass('public.vineyard_members') is null
     or to_regclass('public.profiles') is null then
    raise exception 'SQL 172 precondition failed: core VineTrack tables missing (apply sql/001 first)';
  end if;
  if to_regprocedure('public.is_system_admin()') is null then
    raise exception 'SQL 172 precondition failed: is_system_admin() missing (apply sql/062 first)';
  end if;
  if to_regprocedure('public.set_updated_at()') is null then
    raise exception 'SQL 172 precondition failed: set_updated_at() missing (apply sql/001 first)';
  end if;
end$$;

-- ===========================================================================
-- A. Scope catalogue — canonical permission identifiers. Extensible by
--    inserting new rows; scope grants FK onto this catalogue so arbitrary
--    free-text scopes are impossible.
--    NOTE: write scopes are DEFINED now but no external write behaviour
--    exists in Stage 2. The first public API release is read-only.
-- ===========================================================================
create table if not exists public.integration_scope_catalog (
  scope        text primary key
               check (scope ~ '^[a-z][a-z_]*:(read|write)$'),
  module       text not null,
  access       text not null check (access in ('read', 'write')),
  is_sensitive boolean not null default false,
  description  text not null,
  created_at   timestamptz not null default now()
);

comment on table public.integration_scope_catalog is
  'Canonical catalogue of grantable integration permission scopes. Scope grants FK here; free-text scopes are rejected.';

insert into public.integration_scope_catalog (scope, module, access, is_sensitive, description) values
  -- Vineyard structure
  ('vineyards:read',      'vineyard_structure', 'read',  false, 'Read vineyard metadata for granted vineyards'),
  ('blocks:read',         'vineyard_structure', 'read',  false, 'Read block/paddock structure and row layout'),
  -- Trips
  ('trips:read',          'trips',              'read',  false, 'Read operational trip records (excludes labour cost, worker personal details, internal costing and billing fields)'),
  ('trips:write',         'trips',              'write', false, 'Future: create/update trips (no external write behaviour exists in Stage 2)'),
  -- Spray records
  ('sprays:read',         'sprays',             'read',  false, 'Read spray job records (excludes cost and labour fields; those require costs:read / labour:read)'),
  ('sprays:write',        'sprays',             'write', false, 'Future: create/update spray records'),
  -- Fuel
  ('fuel:read',           'fuel',               'read',  false, 'Read fuel purchases and fuel logs'),
  ('fuel:write',          'fuel',               'write', false, 'Future: create/update fuel records'),
  -- Growth
  ('growth_stages:read',  'growth',             'read',  false, 'Read growth stage observations'),
  ('growth_stages:write', 'growth',             'write', false, 'Future: record growth stages'),
  -- Yield
  ('yield:read',          'yield',              'read',  false, 'Read yield records'),
  ('yield:write',         'yield',              'write', false, 'Future: create/update yield records'),
  -- Work
  ('work_tasks:read',     'work',               'read',  false, 'Read work tasks'),
  ('work_tasks:write',    'work',               'write', false, 'Future: create/update work tasks'),
  -- Pruning
  ('pruning:read',        'pruning',            'read',  false, 'Read pruning activities and season progress'),
  ('pruning:write',       'pruning',            'write', false, 'Future: create/update pruning activity'),
  -- Irrigation
  ('irrigation:read',     'irrigation',         'read',  false, 'Read irrigation records'),
  ('irrigation:write',    'irrigation',         'write', false, 'Future: create/update irrigation records'),
  -- Equipment
  ('equipment:read',      'equipment',          'read',  false, 'Read equipment records'),
  ('equipment:write',     'equipment',          'write', false, 'Future: create/update equipment records'),
  -- Vineyard observations / pins
  ('pins:read',           'pins',               'read',  false, 'Read vineyard observation pins (canonical placement contract, sql/171)'),
  ('pins:write',          'pins',               'write', false, 'Future: create/update pins'),
  -- Environmental
  ('weather:read',        'environment',        'read',  false, 'Read weather data for granted vineyards'),
  ('rainfall:read',       'environment',        'read',  false, 'Read rainfall data for granted vineyards'),
  ('disease_risk:read',   'environment',        'read',  false, 'Read disease risk assessments'),
  -- Sensitive operational data (never implied by resource scopes)
  ('labour:read',         'sensitive',          'read',  true,  'Read labour details (worker names, hours, labour cost). NEVER implied by trips:read / sprays:read etc.'),
  ('costs:read',          'sensitive',          'read',  true,  'Read internal costing and financial fields. NEVER implied by resource scopes.'),
  ('team:read',           'sensitive',          'read',  true,  'Read team membership details. NEVER implied by resource scopes.')
on conflict (scope) do nothing;

-- ===========================================================================
-- B. Webhook event catalogue — constrained future event names. No triggers
--    or dispatching are connected in Stage 2.
-- ===========================================================================
create table if not exists public.integration_webhook_event_catalog (
  event       text primary key
              check (event ~ '^[a-z][a-z_]*\.[a-z_]+$'),
  module      text not null,
  description text not null,
  created_at  timestamptz not null default now()
);

comment on table public.integration_webhook_event_catalog is
  'Canonical catalogue of future webhook event names. webhook_subscriptions FK here. No dispatching exists in Stage 2.';

insert into public.integration_webhook_event_catalog (event, module, description) values
  ('trip.created',                'trips',      'A trip was created'),
  ('trip.updated',                'trips',      'A trip was updated'),
  ('trip.completed',              'trips',      'A trip was completed'),
  ('spray_job.created',           'sprays',     'A spray job was created'),
  ('spray_job.updated',           'sprays',     'A spray job was updated'),
  ('spray_job.completed',         'sprays',     'A spray job was completed'),
  ('fuel_purchase.created',       'fuel',       'A fuel purchase was recorded'),
  ('fuel_log.created',            'fuel',       'A fuel log entry was created'),
  ('fuel_log.updated',            'fuel',       'A fuel log entry was updated'),
  ('growth_stage.recorded',       'growth',     'A growth stage observation was recorded'),
  ('yield_record.created',        'yield',      'A yield record was created'),
  ('yield_record.updated',        'yield',      'A yield record was updated'),
  ('work_task.created',           'work',       'A work task was created'),
  ('work_task.updated',           'work',       'A work task was updated'),
  ('work_task.completed',         'work',       'A work task was completed'),
  ('pruning_activity.created',    'pruning',    'A pruning activity was created'),
  ('pruning_activity.updated',    'pruning',    'A pruning activity was updated'),
  ('irrigation_record.created',   'irrigation', 'An irrigation record was created'),
  ('irrigation_record.updated',   'irrigation', 'An irrigation record was updated'),
  ('irrigation_record.completed', 'irrigation', 'An irrigation record was completed'),
  ('pin.created',                 'pins',       'An observation pin was created'),
  ('pin.updated',                 'pins',       'An observation pin was updated'),
  ('pin.resolved',                'pins',       'An observation pin was resolved/completed'),
  ('block.created',               'structure',  'A block was created'),
  ('block.updated',               'structure',  'A block was updated')
on conflict (event) do nothing;

-- ===========================================================================
-- C. integration_clients — one row per external integration.
-- ===========================================================================
create table if not exists public.integration_clients (
  id               uuid primary key default gen_random_uuid(),
  owner_user_id    uuid not null references public.profiles(id) on delete restrict,
  name             text not null check (length(trim(name)) between 1 and 120),
  description      text check (description is null or length(description) <= 2000),
  integration_type text not null
                   check (integration_type in ('custom_api', 'custom_webhook', 'managed_integration')),
  status           text not null default 'active'
                   check (status in ('active', 'paused', 'revoked')),
  created_by       uuid not null references public.profiles(id) on delete restrict,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  paused_at        timestamptz,
  revoked_at       timestamptz,
  -- lifecycle consistency: timestamps agree with status
  constraint integration_clients_status_timestamps check (
    (status = 'revoked') = (revoked_at is not null)
    and (status <> 'paused' or paused_at is not null)
  )
);

comment on table public.integration_clients is
  'External integration clients. Owned by an account (owner_user_id = canonical VineTrack account anchor). Revoke is the normal end-of-life; history is never hard-deleted.';

create index if not exists idx_integration_clients_owner
  on public.integration_clients (owner_user_id, status);

drop trigger if exists trg_integration_clients_updated_at on public.integration_clients;
create trigger trg_integration_clients_updated_at
before update on public.integration_clients
for each row execute function public.set_updated_at();

-- ===========================================================================
-- D. integration_api_keys — credential metadata. NEVER a recoverable secret.
-- ===========================================================================
create table if not exists public.integration_api_keys (
  id                    uuid primary key default gen_random_uuid(),
  integration_client_id uuid not null references public.integration_clients(id) on delete cascade,
  environment           text not null default 'live' check (environment in ('live', 'test')),
  key_prefix            text not null check (key_prefix ~ '^vt_(live|test)_[0-9a-f]{8}$'),
  key_hash              text not null unique check (key_hash ~ '^[0-9a-f]{64}$'),
  name                  text check (name is null or length(name) <= 120),
  created_by            uuid not null references public.profiles(id) on delete restrict,
  created_at            timestamptz not null default now(),
  expires_at            timestamptz,
  last_used_at          timestamptz,
  revoked_at            timestamptz
);

comment on table public.integration_api_keys is
  'API credential metadata. Stores ONLY SHA-256 hash + display prefix of secrets shaped vt_live_/vt_test_<48 hex>. Plaintext is shown exactly once at creation and is unrecoverable — including by platform admins.';
comment on column public.integration_api_keys.key_hash is
  'SHA-256 hex of the full presented secret. Never exposed by any RPC.';

create index if not exists idx_integration_api_keys_client
  on public.integration_api_keys (integration_client_id, created_at desc);

-- ===========================================================================
-- E. integration_client_vineyards — explicit vineyard grants.
-- ===========================================================================
create table if not exists public.integration_client_vineyards (
  id                    uuid primary key default gen_random_uuid(),
  integration_client_id uuid not null references public.integration_clients(id) on delete cascade,
  vineyard_id           uuid not null references public.vineyards(id) on delete cascade,
  granted_by            uuid not null references public.profiles(id) on delete restrict,
  granted_at            timestamptz not null default now(),
  revoked_at            timestamptz
);

comment on table public.integration_client_vineyards is
  'Explicit vineyard grants. An integration can touch a vineyard ONLY via an active row here — never via the creating user''s own membership at request time.';

-- one ACTIVE grant per integration/vineyard (revoked history rows retained)
create unique index if not exists uq_integration_vineyard_active
  on public.integration_client_vineyards (integration_client_id, vineyard_id)
  where revoked_at is null;

create index if not exists idx_integration_vineyards_vineyard
  on public.integration_client_vineyards (vineyard_id) where revoked_at is null;

-- ===========================================================================
-- F. integration_client_scopes — explicit scope grants (FK to catalogue).
-- ===========================================================================
create table if not exists public.integration_client_scopes (
  id                    uuid primary key default gen_random_uuid(),
  integration_client_id uuid not null references public.integration_clients(id) on delete cascade,
  scope                 text not null references public.integration_scope_catalog(scope),
  granted_by            uuid not null references public.profiles(id) on delete restrict,
  granted_at            timestamptz not null default now(),
  revoked_at            timestamptz
);

comment on table public.integration_client_scopes is
  'Explicit scope grants (FK to integration_scope_catalog). Scope and vineyard checks are INDEPENDENT — both must pass on a future API request.';

create unique index if not exists uq_integration_scope_active
  on public.integration_client_scopes (integration_client_id, scope)
  where revoked_at is null;

-- ===========================================================================
-- G. integration_audit_log — append-only management audit.
-- ===========================================================================
create table if not exists public.integration_audit_log (
  id                    uuid primary key default gen_random_uuid(),
  created_at            timestamptz not null default now(),
  actor_user_id         uuid references public.profiles(id) on delete set null,
  integration_client_id uuid not null references public.integration_clients(id) on delete cascade,
  action                text not null check (action in (
                          'integration.created', 'integration.updated',
                          'integration.paused', 'integration.reactivated',
                          'integration.revoked',
                          'api_key.created', 'api_key.revoked', 'api_key.rotated',
                          'vineyard_access.granted', 'vineyard_access.revoked',
                          'scope.granted', 'scope.revoked')),
  vineyard_id           uuid references public.vineyards(id) on delete set null,
  metadata              jsonb not null default '{}'::jsonb
);

comment on table public.integration_audit_log is
  'Append-only audit of integration management events. Never contains secrets. UPDATE/DELETE blocked by trigger.';

create index if not exists idx_integration_audit_client
  on public.integration_audit_log (integration_client_id, created_at desc);

create or replace function public._integration_audit_log_guard()
returns trigger
language plpgsql
as $$
begin
  raise exception 'integration_audit_log is append-only';
end$$;

drop trigger if exists trg_integration_audit_log_guard on public.integration_audit_log;
create trigger trg_integration_audit_log_guard
before update or delete on public.integration_audit_log
for each row execute function public._integration_audit_log_guard();

-- ===========================================================================
-- H. integration_api_requests — future API traffic log foundation.
--    Diagnostics only: no request/response bodies, no vineyard data copy.
-- ===========================================================================
create table if not exists public.integration_api_requests (
  id                    uuid primary key default gen_random_uuid(),
  integration_client_id uuid not null references public.integration_clients(id) on delete cascade,
  api_key_id            uuid references public.integration_api_keys(id) on delete set null,
  vineyard_id           uuid references public.vineyards(id) on delete set null,
  method                text not null check (method in ('GET', 'POST', 'PUT', 'PATCH', 'DELETE')),
  path                  text not null check (length(path) <= 300),
  status_code           integer not null check (status_code between 100 and 599),
  duration_ms           integer check (duration_ms is null or duration_ms >= 0),
  error_code            text check (error_code is null or length(error_code) <= 80),
  created_at            timestamptz not null default now()
);

comment on table public.integration_api_requests is
  'Future API traffic diagnostics (canonical path + status + duration). By design stores NO request/response bodies. Written by the future API layer via service_role; no client access.';

create index if not exists idx_integration_api_requests_client
  on public.integration_api_requests (integration_client_id, created_at desc);
create index if not exists idx_integration_api_requests_key
  on public.integration_api_requests (api_key_id, created_at desc);

-- ===========================================================================
-- I. Webhook foundation — schema only. NO dispatching in Stage 2.
-- ===========================================================================
create table if not exists public.webhook_endpoints (
  id                    uuid primary key default gen_random_uuid(),
  integration_client_id uuid not null references public.integration_clients(id) on delete cascade,
  url                   text not null check (url ~* '^https://' and length(url) <= 500),
  status                text not null default 'active' check (status in ('active', 'paused')),
  signing_secret_hash   text not null check (signing_secret_hash ~ '^[0-9a-f]{64}$'),
  signing_secret_prefix text not null check (length(signing_secret_prefix) <= 24),
  created_by            uuid not null references public.profiles(id) on delete restrict,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

comment on table public.webhook_endpoints is
  'Future webhook delivery targets (HTTPS only). Stores signing-secret hash + prefix only; the usable signing secret will live in secure server-side storage (e.g. Vault) when dispatching is built. No HTTP is sent in Stage 2.';

create index if not exists idx_webhook_endpoints_client
  on public.webhook_endpoints (integration_client_id);

drop trigger if exists trg_webhook_endpoints_updated_at on public.webhook_endpoints;
create trigger trg_webhook_endpoints_updated_at
before update on public.webhook_endpoints
for each row execute function public.set_updated_at();

create table if not exists public.webhook_subscriptions (
  id                  uuid primary key default gen_random_uuid(),
  webhook_endpoint_id uuid not null references public.webhook_endpoints(id) on delete cascade,
  event_type          text not null references public.integration_webhook_event_catalog(event),
  vineyard_id         uuid references public.vineyards(id) on delete cascade,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now()
);

comment on table public.webhook_subscriptions is
  'Future webhook event subscriptions (event names constrained by catalogue). Optional vineyard restriction; the dispatcher must STILL verify the integration''s active vineyard grant at send time.';

create unique index if not exists uq_webhook_subscription_all_vineyards
  on public.webhook_subscriptions (webhook_endpoint_id, event_type)
  where vineyard_id is null;
create unique index if not exists uq_webhook_subscription_vineyard
  on public.webhook_subscriptions (webhook_endpoint_id, event_type, vineyard_id)
  where vineyard_id is not null;

-- ===========================================================================
-- J. Idempotency foundation — model only; no write API exists in Stage 2.
-- ===========================================================================
create table if not exists public.integration_idempotency_keys (
  id                    uuid primary key default gen_random_uuid(),
  integration_client_id uuid not null references public.integration_clients(id) on delete cascade,
  idempotency_key       text not null check (length(idempotency_key) between 1 and 200),
  method                text not null check (method in ('POST', 'PUT', 'PATCH', 'DELETE')),
  path                  text not null check (length(path) <= 300),
  request_hash          text check (request_hash is null or request_hash ~ '^[0-9a-f]{64}$'),
  response_status       integer check (response_status is null or response_status between 100 and 599),
  resource_type         text,
  resource_id           uuid,
  created_at            timestamptz not null default now(),
  expires_at            timestamptz not null default now() + interval '24 hours',
  constraint uq_integration_idempotency unique (integration_client_id, idempotency_key)
);

comment on table public.integration_idempotency_keys is
  'Future Idempotency-Key support for write APIs. Uniqueness boundary = (integration client, idempotency key). Stores reconciliation metadata (status + created resource reference), not payload bodies. Unused in Stage 2.';

create index if not exists idx_integration_idempotency_expiry
  on public.integration_idempotency_keys (expires_at);

-- ===========================================================================
-- K. RLS + privilege lockdown.
--    Catalogues: readable reference data. Everything else: RPC-only.
-- ===========================================================================
alter table public.integration_scope_catalog         enable row level security;
alter table public.integration_webhook_event_catalog enable row level security;
alter table public.integration_clients               enable row level security;
alter table public.integration_api_keys              enable row level security;
alter table public.integration_client_vineyards      enable row level security;
alter table public.integration_client_scopes         enable row level security;
alter table public.integration_audit_log             enable row level security;
alter table public.integration_api_requests          enable row level security;
alter table public.webhook_endpoints                 enable row level security;
alter table public.webhook_subscriptions             enable row level security;
alter table public.integration_idempotency_keys      enable row level security;

-- Catalogue read policies (non-sensitive reference data).
drop policy if exists integration_scope_catalog_read on public.integration_scope_catalog;
create policy integration_scope_catalog_read
  on public.integration_scope_catalog for select
  to authenticated using (true);

drop policy if exists integration_webhook_event_catalog_read on public.integration_webhook_event_catalog;
create policy integration_webhook_event_catalog_read
  on public.integration_webhook_event_catalog for select
  to authenticated using (true);

-- Strip every direct table privilege from client roles. Catalogues get
-- SELECT back; all other tables are reachable ONLY through the SECURITY
-- DEFINER RPCs (which run as the migration owner and bypass RLS).
revoke all on public.integration_scope_catalog,
              public.integration_webhook_event_catalog,
              public.integration_clients,
              public.integration_api_keys,
              public.integration_client_vineyards,
              public.integration_client_scopes,
              public.integration_audit_log,
              public.integration_api_requests,
              public.webhook_endpoints,
              public.webhook_subscriptions,
              public.integration_idempotency_keys
from anon, authenticated;

grant select on public.integration_scope_catalog,
                public.integration_webhook_event_catalog
to authenticated;

-- ===========================================================================
-- L. Internal helpers (no client execute).
-- ===========================================================================

-- SHA-256 hex of a presented secret. pgcrypto may live in `extensions`
-- (Supabase default) or `public`; search_path covers both.
create or replace function public._integration_hash_secret(p_secret text)
returns text
language sql
immutable
security definer
set search_path = public, extensions
as $$
  select encode(digest(convert_to(p_secret, 'UTF8'), 'sha256'), 'hex');
$$;

-- Cryptographically secure secret: vt_<env>_<48 hex> (24 random bytes).
create or replace function public._integration_generate_secret(p_environment text)
returns text
language sql
volatile
security definer
set search_path = public, extensions
as $$
  select 'vt_' || p_environment || '_' || encode(gen_random_bytes(24), 'hex');
$$;

-- Vineyard-level OWNER authority: membership role 'owner' OR legacy
-- vineyards.owner_id — the same dual convention used by sql/156.
create or replace function public._integration_is_vineyard_owner(p_user_id uuid, p_vineyard_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.vineyards v
    where v.id = p_vineyard_id and v.deleted_at is null and v.owner_id = p_user_id
  ) or exists (
    select 1
    from public.vineyard_members vm
    join public.vineyards v on v.id = vm.vineyard_id and v.deleted_at is null
    where vm.vineyard_id = p_vineyard_id
      and vm.user_id = p_user_id
      and vm.role = 'owner'
  );
$$;

-- Resolve a client the CURRENT user may MANAGE (account owner or platform
-- admin). Raises the SAME error for "does not exist" and "not yours" so
-- cross-account integration ids cannot be probed.
create or replace function public._integration_require_manage(p_client_id uuid)
returns public.integration_clients
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  r public.integration_clients;
begin
  if v_actor is null then
    raise exception 'not_authenticated';
  end if;
  select * into r from public.integration_clients c where c.id = p_client_id;
  if not found or not (r.owner_user_id = v_actor or public.is_system_admin()) then
    raise exception 'integration_not_found';
  end if;
  return r;
end$$;

-- View authority: manage authority OR Manager/Owner membership of a
-- vineyard with an ACTIVE grant to this integration.
create or replace function public._integration_can_view(p_user_id uuid, p_client_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.integration_clients c
    where c.id = p_client_id
      and (c.owner_user_id = p_user_id or public.is_system_admin())
  ) or exists (
    select 1
    from public.integration_client_vineyards g
    join public.vineyard_members vm
      on vm.vineyard_id = g.vineyard_id
    where g.integration_client_id = p_client_id
      and g.revoked_at is null
      and vm.user_id = p_user_id
      and vm.role in ('owner', 'manager')
  );
$$;

-- Append an audit row. Metadata must NEVER contain secret material.
create or replace function public._integration_audit(
  p_client_id uuid,
  p_action text,
  p_vineyard_id uuid,
  p_metadata jsonb
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  insert into public.integration_audit_log
    (actor_user_id, integration_client_id, action, vineyard_id, metadata)
  values
    (auth.uid(), p_client_id, p_action, p_vineyard_id, coalesce(p_metadata, '{}'::jsonb));
end$$;

revoke all on function public._integration_hash_secret(text)                 from public, anon, authenticated;
revoke all on function public._integration_generate_secret(text)             from public, anon, authenticated;
revoke all on function public._integration_is_vineyard_owner(uuid, uuid)     from public, anon, authenticated;
revoke all on function public._integration_require_manage(uuid)              from public, anon, authenticated;
revoke all on function public._integration_can_view(uuid, uuid)              from public, anon, authenticated;
revoke all on function public._integration_audit(uuid, text, uuid, jsonb)    from public, anon, authenticated;

-- ===========================================================================
-- M. Management RPCs (authenticated portal users; authority checked inside).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- integration_list_clients() -> jsonb array
-- Visible: own integrations (account owner), integrations granted a
-- vineyard the caller Owns/Manages, and everything for platform admins.
-- ---------------------------------------------------------------------------
create or replace function public.integration_list_clients()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_out jsonb;
begin
  if v_actor is null then
    raise exception 'not_authenticated';
  end if;

  select coalesce(jsonb_agg(row_json order by created_at desc), '[]'::jsonb)
  into v_out
  from (
    select
      c.created_at,
      jsonb_build_object(
        'id', c.id,
        'name', c.name,
        'description', c.description,
        'integration_type', c.integration_type,
        'status', c.status,
        'created_at', c.created_at,
        'updated_at', c.updated_at,
        'paused_at', c.paused_at,
        'revoked_at', c.revoked_at,
        'is_account_owner', (c.owner_user_id = v_actor),
        'can_manage', (c.owner_user_id = v_actor or public.is_system_admin()),
        'active_vineyard_grants', (
          select count(*) from public.integration_client_vineyards g
          where g.integration_client_id = c.id and g.revoked_at is null),
        'active_scopes', (
          select count(*) from public.integration_client_scopes s
          where s.integration_client_id = c.id and s.revoked_at is null),
        'active_api_keys', (
          select count(*) from public.integration_api_keys k
          where k.integration_client_id = c.id and k.revoked_at is null)
      ) as row_json
    from public.integration_clients c
    where c.owner_user_id = v_actor
       or public.is_system_admin()
       or exists (
            select 1
            from public.integration_client_vineyards g
            join public.vineyard_members vm on vm.vineyard_id = g.vineyard_id
            where g.integration_client_id = c.id
              and g.revoked_at is null
              and vm.user_id = v_actor
              and vm.role in ('owner', 'manager'))
  ) t;

  return v_out;
end$$;

-- ---------------------------------------------------------------------------
-- integration_create_client(name, type, description) -> jsonb
-- Only users with vineyard-OWNER authority somewhere (or platform admins)
-- may create integrations. Managers/Supervisors/Operators are refused.
-- ---------------------------------------------------------------------------
create or replace function public.integration_create_client(
  p_name text,
  p_integration_type text,
  p_description text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
begin
  if v_actor is null then
    raise exception 'not_authenticated';
  end if;
  if p_name is null or length(trim(p_name)) < 1 or length(trim(p_name)) > 120 then
    raise exception 'invalid_name';
  end if;
  if p_integration_type is null
     or p_integration_type not in ('custom_api', 'custom_webhook', 'managed_integration') then
    raise exception 'invalid_integration_type';
  end if;
  if not public.is_system_admin() and not (
    exists (select 1 from public.vineyards v
            where v.owner_id = v_actor and v.deleted_at is null)
    or exists (select 1
               from public.vineyard_members vm
               join public.vineyards v on v.id = vm.vineyard_id and v.deleted_at is null
               where vm.user_id = v_actor and vm.role = 'owner')
  ) then
    raise exception 'not_authorised';
  end if;

  insert into public.integration_clients
    (owner_user_id, name, description, integration_type, created_by)
  values
    (v_actor, trim(p_name), nullif(trim(coalesce(p_description, '')), ''), p_integration_type, v_actor)
  returning id into v_id;

  perform public._integration_audit(v_id, 'integration.created', null,
    jsonb_build_object('name', trim(p_name), 'integration_type', p_integration_type));

  return jsonb_build_object('id', v_id, 'status', 'active');
end$$;

-- ---------------------------------------------------------------------------
-- integration_update_client(client, name?, description?) -> jsonb
-- ---------------------------------------------------------------------------
create or replace function public.integration_update_client(
  p_client_id uuid,
  p_name text default null,
  p_description text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.integration_clients;
  v_changes jsonb := '{}'::jsonb;
begin
  r := public._integration_require_manage(p_client_id);
  if r.status = 'revoked' then
    raise exception 'integration_revoked';
  end if;

  if p_name is not null then
    if length(trim(p_name)) < 1 or length(trim(p_name)) > 120 then
      raise exception 'invalid_name';
    end if;
    v_changes := v_changes || jsonb_build_object('name', trim(p_name));
  end if;
  if p_description is not null then
    v_changes := v_changes || jsonb_build_object('description', left(p_description, 2000));
  end if;
  if v_changes = '{}'::jsonb then
    raise exception 'nothing_to_update';
  end if;

  update public.integration_clients c
  set name        = coalesce(nullif(trim(coalesce(p_name, '')), ''), c.name),
      description = case when p_description is not null
                         then nullif(trim(p_description), '')
                         else c.description end
  where c.id = p_client_id;

  perform public._integration_audit(p_client_id, 'integration.updated', null,
    jsonb_build_object('changed', v_changes));

  return jsonb_build_object('id', p_client_id, 'ok', true);
end$$;

-- ---------------------------------------------------------------------------
-- integration_set_status(client, action) -> jsonb
-- action: 'pause' | 'reactivate' | 'revoke'.
-- Revoked is terminal: a revoked integration can NOT be reactivated.
-- ---------------------------------------------------------------------------
create or replace function public.integration_set_status(
  p_client_id uuid,
  p_action text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.integration_clients;
  v_new_status text;
  v_audit text;
begin
  r := public._integration_require_manage(p_client_id);

  if p_action not in ('pause', 'reactivate', 'revoke') then
    raise exception 'invalid_action';
  end if;
  if r.status = 'revoked' then
    raise exception 'integration_revoked';
  end if;

  if p_action = 'pause' then
    if r.status <> 'active' then raise exception 'invalid_status_transition'; end if;
    v_new_status := 'paused';  v_audit := 'integration.paused';
    update public.integration_clients set status = 'paused', paused_at = now()
    where id = p_client_id;
  elsif p_action = 'reactivate' then
    if r.status <> 'paused' then raise exception 'invalid_status_transition'; end if;
    v_new_status := 'active';  v_audit := 'integration.reactivated';
    update public.integration_clients set status = 'active', paused_at = null
    where id = p_client_id;
  else -- revoke (from active or paused)
    v_new_status := 'revoked'; v_audit := 'integration.revoked';
    update public.integration_clients set status = 'revoked', revoked_at = now()
    where id = p_client_id;
  end if;

  perform public._integration_audit(p_client_id, v_audit, null,
    jsonb_build_object('previous_status', r.status, 'new_status', v_new_status));

  return jsonb_build_object('id', p_client_id, 'status', v_new_status);
end$$;

-- ---------------------------------------------------------------------------
-- integration_list_vineyard_grants(client) -> jsonb array (view authority)
-- ---------------------------------------------------------------------------
create or replace function public.integration_list_vineyard_grants(p_client_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then raise exception 'not_authenticated'; end if;
  if not public._integration_can_view(v_actor, p_client_id) then
    raise exception 'integration_not_found';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', g.id,
      'vineyard_id', g.vineyard_id,
      'vineyard_name', v.name,
      'granted_by', g.granted_by,
      'granted_at', g.granted_at,
      'revoked_at', g.revoked_at,
      'is_active', (g.revoked_at is null)
    ) order by g.granted_at desc)
    from public.integration_client_vineyards g
    join public.vineyards v on v.id = g.vineyard_id
    where g.integration_client_id = p_client_id
  ), '[]'::jsonb);
end$$;

-- ---------------------------------------------------------------------------
-- integration_grant_vineyard(client, vineyard) -> jsonb
-- Manage authority AND vineyard-OWNER authority over the specific vineyard.
-- ---------------------------------------------------------------------------
create or replace function public.integration_grant_vineyard(
  p_client_id uuid,
  p_vineyard_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.integration_clients;
  v_actor uuid := auth.uid();
  v_id uuid;
begin
  r := public._integration_require_manage(p_client_id);
  if r.status = 'revoked' then
    raise exception 'integration_revoked';
  end if;
  if not exists (select 1 from public.vineyards v
                 where v.id = p_vineyard_id and v.deleted_at is null) then
    raise exception 'vineyard_not_found';
  end if;
  if not public.is_system_admin()
     and not public._integration_is_vineyard_owner(v_actor, p_vineyard_id) then
    raise exception 'not_authorised_for_vineyard';
  end if;
  if exists (select 1 from public.integration_client_vineyards g
             where g.integration_client_id = p_client_id
               and g.vineyard_id = p_vineyard_id
               and g.revoked_at is null) then
    raise exception 'vineyard_already_granted';
  end if;

  insert into public.integration_client_vineyards
    (integration_client_id, vineyard_id, granted_by)
  values (p_client_id, p_vineyard_id, v_actor)
  returning id into v_id;

  perform public._integration_audit(p_client_id, 'vineyard_access.granted', p_vineyard_id,
    jsonb_build_object('grant_id', v_id));

  return jsonb_build_object('id', v_id, 'ok', true);
end$$;

-- ---------------------------------------------------------------------------
-- integration_revoke_vineyard(client, vineyard) -> jsonb
-- ---------------------------------------------------------------------------
create or replace function public.integration_revoke_vineyard(
  p_client_id uuid,
  p_vineyard_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.integration_clients;
  v_id uuid;
begin
  r := public._integration_require_manage(p_client_id);

  update public.integration_client_vineyards g
  set revoked_at = now()
  where g.integration_client_id = p_client_id
    and g.vineyard_id = p_vineyard_id
    and g.revoked_at is null
  returning g.id into v_id;

  if v_id is null then
    raise exception 'grant_not_found';
  end if;

  perform public._integration_audit(p_client_id, 'vineyard_access.revoked', p_vineyard_id,
    jsonb_build_object('grant_id', v_id));

  return jsonb_build_object('id', v_id, 'ok', true);
end$$;

-- ---------------------------------------------------------------------------
-- integration_list_scopes(client) -> jsonb array (view authority)
-- ---------------------------------------------------------------------------
create or replace function public.integration_list_scopes(p_client_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then raise exception 'not_authenticated'; end if;
  if not public._integration_can_view(v_actor, p_client_id) then
    raise exception 'integration_not_found';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id,
      'scope', s.scope,
      'module', cat.module,
      'access', cat.access,
      'is_sensitive', cat.is_sensitive,
      'granted_by', s.granted_by,
      'granted_at', s.granted_at,
      'revoked_at', s.revoked_at,
      'is_active', (s.revoked_at is null)
    ) order by s.granted_at desc)
    from public.integration_client_scopes s
    join public.integration_scope_catalog cat on cat.scope = s.scope
    where s.integration_client_id = p_client_id
  ), '[]'::jsonb);
end$$;

-- ---------------------------------------------------------------------------
-- integration_grant_scope(client, scope) -> jsonb
-- Scope must exist in the catalogue; unknown scopes are rejected.
-- ---------------------------------------------------------------------------
create or replace function public.integration_grant_scope(
  p_client_id uuid,
  p_scope text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.integration_clients;
  v_actor uuid := auth.uid();
  v_id uuid;
begin
  r := public._integration_require_manage(p_client_id);
  if r.status = 'revoked' then
    raise exception 'integration_revoked';
  end if;
  if not exists (select 1 from public.integration_scope_catalog c where c.scope = p_scope) then
    raise exception 'unknown_scope';
  end if;
  if exists (select 1 from public.integration_client_scopes s
             where s.integration_client_id = p_client_id
               and s.scope = p_scope and s.revoked_at is null) then
    raise exception 'scope_already_granted';
  end if;

  insert into public.integration_client_scopes (integration_client_id, scope, granted_by)
  values (p_client_id, p_scope, v_actor)
  returning id into v_id;

  perform public._integration_audit(p_client_id, 'scope.granted', null,
    jsonb_build_object('scope', p_scope));

  return jsonb_build_object('id', v_id, 'ok', true);
end$$;

-- ---------------------------------------------------------------------------
-- integration_revoke_scope(client, scope) -> jsonb
-- ---------------------------------------------------------------------------
create or replace function public.integration_revoke_scope(
  p_client_id uuid,
  p_scope text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.integration_clients;
  v_id uuid;
begin
  r := public._integration_require_manage(p_client_id);

  update public.integration_client_scopes s
  set revoked_at = now()
  where s.integration_client_id = p_client_id
    and s.scope = p_scope
    and s.revoked_at is null
  returning s.id into v_id;

  if v_id is null then
    raise exception 'scope_grant_not_found';
  end if;

  perform public._integration_audit(p_client_id, 'scope.revoked', null,
    jsonb_build_object('scope', p_scope));

  return jsonb_build_object('id', v_id, 'ok', true);
end$$;

-- ---------------------------------------------------------------------------
-- integration_list_api_keys(client) -> jsonb array
-- MANAGE authority only (Managers see integration status, never credential
-- metadata). NEVER returns key_hash or any secret material.
-- ---------------------------------------------------------------------------
create or replace function public.integration_list_api_keys(p_client_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.integration_clients;
begin
  r := public._integration_require_manage(p_client_id);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', k.id,
      'environment', k.environment,
      'key_prefix', k.key_prefix,
      'name', k.name,
      'created_by', k.created_by,
      'created_at', k.created_at,
      'expires_at', k.expires_at,
      'last_used_at', k.last_used_at,
      'revoked_at', k.revoked_at,
      'is_active', (k.revoked_at is null and (k.expires_at is null or k.expires_at > now()))
    ) order by k.created_at desc)
    from public.integration_api_keys k
    where k.integration_client_id = p_client_id
  ), '[]'::jsonb);
end$$;

-- ---------------------------------------------------------------------------
-- integration_create_api_key(client, environment, name?, expires_at?) -> jsonb
-- ONE-TIME creation flow: the response is the only place the plaintext
-- secret ever exists. It is not stored, not audited, not logged.
-- ---------------------------------------------------------------------------
create or replace function public.integration_create_api_key(
  p_client_id uuid,
  p_environment text default 'live',
  p_name text default null,
  p_expires_at timestamptz default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.integration_clients;
  v_actor uuid := auth.uid();
  v_secret text;
  v_prefix text;
  v_hash text;
  v_id uuid;
begin
  r := public._integration_require_manage(p_client_id);
  if r.status <> 'active' then
    raise exception 'integration_not_active';
  end if;
  if p_environment not in ('live', 'test') then
    raise exception 'invalid_environment';
  end if;
  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'invalid_expiry';
  end if;

  v_secret := public._integration_generate_secret(p_environment);
  v_prefix := left(v_secret, length('vt_' || p_environment || '_') + 8);
  v_hash   := public._integration_hash_secret(v_secret);

  insert into public.integration_api_keys
    (integration_client_id, environment, key_prefix, key_hash, name, created_by, expires_at)
  values
    (p_client_id, p_environment, v_prefix, v_hash,
     nullif(trim(coalesce(p_name, '')), ''), v_actor, p_expires_at)
  returning id into v_id;

  -- Audit metadata: identifiers and safe prefix ONLY. Never the secret.
  perform public._integration_audit(p_client_id, 'api_key.created', null,
    jsonb_build_object('api_key_id', v_id, 'key_prefix', v_prefix, 'environment', p_environment));

  return jsonb_build_object(
    'api_key_id', v_id,
    'environment', p_environment,
    'key_prefix', v_prefix,
    'expires_at', p_expires_at,
    'secret', v_secret,
    'warning', 'Store this secret now. It cannot be retrieved again by anyone, including VineTrack administrators.'
  );
end$$;

-- ---------------------------------------------------------------------------
-- integration_revoke_api_key(client, key) -> jsonb
-- Revocation retains the row (history) with revoked_at set.
-- ---------------------------------------------------------------------------
create or replace function public.integration_revoke_api_key(
  p_client_id uuid,
  p_key_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r public.integration_clients;
  v_prefix text;
begin
  r := public._integration_require_manage(p_client_id);

  update public.integration_api_keys k
  set revoked_at = now()
  where k.id = p_key_id
    and k.integration_client_id = p_client_id
    and k.revoked_at is null
  returning k.key_prefix into v_prefix;

  if v_prefix is null then
    raise exception 'api_key_not_found';
  end if;

  perform public._integration_audit(p_client_id, 'api_key.revoked', null,
    jsonb_build_object('api_key_id', p_key_id, 'key_prefix', v_prefix));

  return jsonb_build_object('id', p_key_id, 'ok', true);
end$$;

-- ---------------------------------------------------------------------------
-- integration_audit_history(client, limit) -> jsonb array (view authority)
-- ---------------------------------------------------------------------------
create or replace function public.integration_audit_history(
  p_client_id uuid,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 500));
begin
  if v_actor is null then raise exception 'not_authenticated'; end if;
  if not public._integration_can_view(v_actor, p_client_id) then
    raise exception 'integration_not_found';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id,
      'created_at', a.created_at,
      'actor_user_id', a.actor_user_id,
      'action', a.action,
      'vineyard_id', a.vineyard_id,
      'metadata', a.metadata
    ) order by a.created_at desc)
    from (
      select * from public.integration_audit_log l
      where l.integration_client_id = p_client_id
      order by l.created_at desc
      limit v_limit
    ) a
  ), '[]'::jsonb);
end$$;

revoke all on function public.integration_list_clients()                                   from public, anon;
revoke all on function public.integration_create_client(text, text, text)                  from public, anon;
revoke all on function public.integration_update_client(uuid, text, text)                  from public, anon;
revoke all on function public.integration_set_status(uuid, text)                           from public, anon;
revoke all on function public.integration_list_vineyard_grants(uuid)                       from public, anon;
revoke all on function public.integration_grant_vineyard(uuid, uuid)                       from public, anon;
revoke all on function public.integration_revoke_vineyard(uuid, uuid)                      from public, anon;
revoke all on function public.integration_list_scopes(uuid)                                from public, anon;
revoke all on function public.integration_grant_scope(uuid, text)                          from public, anon;
revoke all on function public.integration_revoke_scope(uuid, text)                         from public, anon;
revoke all on function public.integration_list_api_keys(uuid)                              from public, anon;
revoke all on function public.integration_create_api_key(uuid, text, text, timestamptz)    from public, anon;
revoke all on function public.integration_revoke_api_key(uuid, uuid)                       from public, anon;
revoke all on function public.integration_audit_history(uuid, integer)                     from public, anon;

grant execute on function public.integration_list_clients()                                to authenticated;
grant execute on function public.integration_create_client(text, text, text)               to authenticated;
grant execute on function public.integration_update_client(uuid, text, text)               to authenticated;
grant execute on function public.integration_set_status(uuid, text)                        to authenticated;
grant execute on function public.integration_list_vineyard_grants(uuid)                    to authenticated;
grant execute on function public.integration_grant_vineyard(uuid, uuid)                    to authenticated;
grant execute on function public.integration_revoke_vineyard(uuid, uuid)                   to authenticated;
grant execute on function public.integration_list_scopes(uuid)                             to authenticated;
grant execute on function public.integration_grant_scope(uuid, text)                       to authenticated;
grant execute on function public.integration_revoke_scope(uuid, text)                      to authenticated;
grant execute on function public.integration_list_api_keys(uuid)                           to authenticated;
grant execute on function public.integration_create_api_key(uuid, text, text, timestamptz) to authenticated;
grant execute on function public.integration_revoke_api_key(uuid, uuid)                    to authenticated;
grant execute on function public.integration_audit_history(uuid, integer)                  to authenticated;

-- ===========================================================================
-- N. integration_validate_api_request — the future API layer's auth check.
--    SERVICE ROLE ONLY (the Stage-3 API gateway runs with service_role).
--    Proves the Stage-2 invariant: five INDEPENDENT checks, none of which
--    substitutes for another. Returns a safe failure code, never the hash.
-- ===========================================================================
create or replace function public.integration_validate_api_request(
  p_presented_key text,
  p_required_scope text,
  p_vineyard_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_hash text;
  k record;
begin
  if p_presented_key is null or p_required_scope is null or p_vineyard_id is null then
    return jsonb_build_object('valid', false, 'failure_code', 'invalid_request');
  end if;

  v_hash := public._integration_hash_secret(p_presented_key);

  select key.id, key.integration_client_id, key.environment,
         key.expires_at, key.revoked_at, c.status as client_status
  into k
  from public.integration_api_keys key
  join public.integration_clients c on c.id = key.integration_client_id
  where key.key_hash = v_hash;

  -- 1. credential exists
  if not found then
    return jsonb_build_object('valid', false, 'failure_code', 'invalid_key');
  end if;
  -- 2. credential not revoked
  if k.revoked_at is not null then
    return jsonb_build_object('valid', false, 'failure_code', 'key_revoked');
  end if;
  -- 3. credential not expired
  if k.expires_at is not null and k.expires_at <= now() then
    return jsonb_build_object('valid', false, 'failure_code', 'key_expired');
  end if;
  -- 4. integration active (paused/revoked both refuse)
  if k.client_status <> 'active' then
    return jsonb_build_object('valid', false, 'failure_code', 'integration_not_active');
  end if;
  -- 5a. required scope actively granted
  if not exists (select 1 from public.integration_client_scopes s
                 where s.integration_client_id = k.integration_client_id
                   and s.scope = p_required_scope
                   and s.revoked_at is null) then
    return jsonb_build_object('valid', false, 'failure_code', 'scope_not_granted');
  end if;
  -- 5b. requested vineyard EXPLICITLY granted (independent of scope check;
  --     NEVER derived from any human user's vineyard membership)
  if not exists (select 1 from public.integration_client_vineyards g
                 where g.integration_client_id = k.integration_client_id
                   and g.vineyard_id = p_vineyard_id
                   and g.revoked_at is null) then
    return jsonb_build_object('valid', false, 'failure_code', 'vineyard_not_granted');
  end if;

  update public.integration_api_keys set last_used_at = now() where id = k.id;

  return jsonb_build_object(
    'valid', true,
    'integration_client_id', k.integration_client_id,
    'api_key_id', k.id,
    'environment', k.environment
  );
end$$;

revoke all on function public.integration_validate_api_request(text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.integration_validate_api_request(text, text, uuid)
  to service_role;

commit;

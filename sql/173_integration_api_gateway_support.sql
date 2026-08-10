-- =====================================================================
-- 173_integration_api_gateway_support.sql
-- =====================================================================
-- VineTrack Integration Platform — Stage 3A: gateway support objects.
--
-- The public read-only API gateway (Supabase Edge Function `vinetrack-api`)
-- needs three small additions on top of the SQL 172 foundation. This
-- migration is ADDITIVE ONLY — SQL 172 is not restructured:
--
--   1. integration_api_requests gains a `request_id` column (returned to
--      callers as X-VineTrack-Request-ID) and its integration_client_id
--      becomes nullable so failed-authentication attempts can be logged
--      safely (no client/key is known for an invalid credential).
--
--   2. integration_authenticate_api_key(p_presented_key) — service_role
--      only. Authenticates a presented key WITHOUT a vineyard/scope
--      context (checks 1–4 of the Stage-2 chain: credential exists, not
--      revoked, not expired, integration active) and returns the safe
--      integration profile: active scopes + active vineyard grants.
--      Used by GET /v1/me and GET /v1/vineyards (collection endpoints
--      that have no single-vineyard context). Per-vineyard endpoints
--      keep using SQL 172's integration_validate_api_request(), which
--      remains the canonical five-check validator.
--      last_used_at is throttled here to at most one write per 60 s per
--      key to avoid a write hot-spot on high-volume traffic.
--
--   3. Rate limiting: integration_rate_limit_counters (fixed 60-second
--      windows per API key) + integration_check_rate_limit(). Postgres
--      is the single shared store, so the limit holds across all Edge
--      Function instances (an in-memory counter would not).
--
--   4. integration_log_api_request() — service_role only writer for the
--      request log, so the log contract lives in one place. Never logs
--      credentials or bodies (the table has no columns for them).
--
-- ROLLBACK (non-destructive; Stage-3A objects only):
--   drop function if exists public.integration_log_api_request(text, uuid, uuid, uuid, text, text, integer, integer, text);
--   drop function if exists public.integration_check_rate_limit(uuid, integer);
--   drop function if exists public.integration_authenticate_api_key(text);
--   drop table if exists public.integration_rate_limit_counters;
--   alter table public.integration_api_requests drop column if exists request_id;
--   -- (restoring NOT NULL on integration_client_id would first require
--   --  deleting failed-auth rows; intentionally not part of rollback)
-- =====================================================================

begin;

-- ---------------------------------------------------------------------------
-- Preconditions: SQL 172 must be applied.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.integration_api_keys') is null
     or to_regclass('public.integration_api_requests') is null
     or to_regprocedure('public.integration_validate_api_request(text, text, uuid)') is null
     or to_regprocedure('public._integration_hash_secret(text)') is null then
    raise exception 'SQL 173 precondition failed: apply sql/172_integration_platform_foundation.sql first';
  end if;
end$$;

-- ===========================================================================
-- A. integration_api_requests: request_id + nullable client id.
-- ===========================================================================
alter table public.integration_api_requests
  add column if not exists request_id text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'integration_api_requests_request_id_format'
  ) then
    alter table public.integration_api_requests
      add constraint integration_api_requests_request_id_format
      check (request_id is null or request_id ~ '^req_[0-9a-f]{32}$');
  end if;
end$$;

comment on column public.integration_api_requests.request_id is
  'Gateway-generated request id (req_<32 hex>), returned to the caller as X-VineTrack-Request-ID. Correlates support enquiries with log rows.';

create index if not exists idx_integration_api_requests_request_id
  on public.integration_api_requests (request_id);

-- Failed authentication attempts have no known integration/key. Allow a
-- NULL client id so those attempts can still be logged (method + path +
-- status + error code only — the presented credential is NEVER stored).
alter table public.integration_api_requests
  alter column integration_client_id drop not null;

comment on table public.integration_api_requests is
  'External API traffic diagnostics (canonical path + status + duration + request id). integration_client_id is NULL for failed-authentication attempts. By design stores NO bodies, NO headers and NO credential material. Written only by the service-role gateway.';

-- ===========================================================================
-- B. integration_authenticate_api_key — checks 1–4, no vineyard context.
--    SERVICE ROLE ONLY. Returns safe integration profile for /v1/me and
--    collection endpoints. Scope/vineyard enforcement for per-vineyard
--    resources stays in integration_validate_api_request() (SQL 172).
-- ===========================================================================
create or replace function public.integration_authenticate_api_key(
  p_presented_key text
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
  -- Shape check first: avoids hashing garbage and gives one uniform
  -- failure for anything that is not a VineTrack credential.
  if p_presented_key is null
     or p_presented_key !~ '^vt_(live|test)_[0-9a-f]{48}$' then
    return jsonb_build_object('valid', false, 'failure_code', 'invalid_key');
  end if;

  v_hash := public._integration_hash_secret(p_presented_key);

  select key.id, key.integration_client_id, key.environment,
         key.expires_at, key.revoked_at, key.last_used_at,
         c.status as client_status, c.name as client_name
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

  -- Throttled freshness marker: at most one write per key per 60 s.
  if k.last_used_at is null or k.last_used_at < now() - interval '60 seconds' then
    update public.integration_api_keys set last_used_at = now() where id = k.id;
  end if;

  return jsonb_build_object(
    'valid', true,
    'integration_client_id', k.integration_client_id,
    'api_key_id', k.id,
    'environment', k.environment,
    'integration_name', k.client_name,
    'status', k.client_status,
    'scopes', (
      select coalesce(jsonb_agg(s.scope order by s.scope), '[]'::jsonb)
      from public.integration_client_scopes s
      where s.integration_client_id = k.integration_client_id
        and s.revoked_at is null
    ),
    'vineyards', (
      select coalesce(jsonb_agg(
               jsonb_build_object('id', g.vineyard_id, 'name', v.name)
               order by v.created_at, v.id), '[]'::jsonb)
      from public.integration_client_vineyards g
      join public.vineyards v
        on v.id = g.vineyard_id and v.deleted_at is null
      where g.integration_client_id = k.integration_client_id
        and g.revoked_at is null
    )
  );
end$$;

comment on function public.integration_authenticate_api_key(text) is
  'Stage 3A gateway: authenticate a presented API key (checks 1–4; NO scope/vineyard context) and return the safe integration profile (active scopes + active vineyard grants). service_role only. Per-vineyard requests must additionally pass integration_validate_api_request().';

revoke all on function public.integration_authenticate_api_key(text)
  from public, anon, authenticated;
grant execute on function public.integration_authenticate_api_key(text)
  to service_role;

-- ===========================================================================
-- C. Rate limiting — fixed 60-second windows per API key, stored in
--    Postgres so every Edge Function instance shares one counter.
-- ===========================================================================
create table if not exists public.integration_rate_limit_counters (
  api_key_id    uuid not null references public.integration_api_keys(id) on delete cascade,
  window_start  timestamptz not null,
  request_count integer not null default 0 check (request_count >= 0),
  primary key (api_key_id, window_start)
);

comment on table public.integration_rate_limit_counters is
  'Fixed-window (60 s) API rate-limit counters per API key. Shared across all gateway instances. Rows older than 10 minutes are pruned opportunistically. No client access.';

alter table public.integration_rate_limit_counters enable row level security;
revoke all on public.integration_rate_limit_counters from anon, authenticated;

create or replace function public.integration_check_rate_limit(
  p_api_key_id uuid,
  p_limit integer default 300
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_window timestamptz := date_trunc('minute', now());
  v_limit integer := greatest(1, least(coalesce(p_limit, 300), 100000));
  v_count integer;
begin
  if p_api_key_id is null then
    return jsonb_build_object('allowed', false, 'failure_code', 'invalid_request');
  end if;

  insert into public.integration_rate_limit_counters as rl
    (api_key_id, window_start, request_count)
  values (p_api_key_id, v_window, 1)
  on conflict (api_key_id, window_start)
  do update set request_count = rl.request_count + 1
  returning rl.request_count into v_count;

  -- Opportunistic pruning of this key's stale windows (PK-indexed, cheap).
  delete from public.integration_rate_limit_counters
  where api_key_id = p_api_key_id
    and window_start < now() - interval '10 minutes';

  if v_count > v_limit then
    return jsonb_build_object(
      'allowed', false,
      'limit', v_limit,
      'remaining', 0,
      'retry_after_seconds',
        greatest(1, ceil(extract(epoch from (v_window + interval '1 minute') - now())))::integer
    );
  end if;

  return jsonb_build_object(
    'allowed', true,
    'limit', v_limit,
    'remaining', greatest(0, v_limit - v_count)
  );
end$$;

comment on function public.integration_check_rate_limit(uuid, integer) is
  'Stage 3A gateway: increment-and-check the fixed 60 s rate-limit window for an API key. Postgres-backed so the limit holds across all Edge Function instances. service_role only.';

revoke all on function public.integration_check_rate_limit(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.integration_check_rate_limit(uuid, integer)
  to service_role;

-- ===========================================================================
-- D. integration_log_api_request — single writer for the request log.
-- ===========================================================================
create or replace function public.integration_log_api_request(
  p_request_id text,
  p_integration_client_id uuid,
  p_api_key_id uuid,
  p_vineyard_id uuid,
  p_method text,
  p_path text,
  p_status_code integer,
  p_duration_ms integer,
  p_error_code text
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if p_method is null or p_method not in ('GET', 'POST', 'PUT', 'PATCH', 'DELETE') then
    raise exception 'invalid_method';
  end if;
  if p_path is null or length(p_path) < 1 then
    raise exception 'invalid_path';
  end if;
  if p_status_code is null or p_status_code not between 100 and 599 then
    raise exception 'invalid_status';
  end if;

  insert into public.integration_api_requests
    (request_id, integration_client_id, api_key_id, vineyard_id,
     method, path, status_code, duration_ms, error_code)
  values
    (p_request_id, p_integration_client_id, p_api_key_id, p_vineyard_id,
     p_method, left(p_path, 300), p_status_code,
     greatest(0, coalesce(p_duration_ms, 0)), nullif(left(coalesce(p_error_code, ''), 80), ''));
end$$;

comment on function public.integration_log_api_request(text, uuid, uuid, uuid, text, text, integer, integer, text) is
  'Stage 3A gateway: append one safe row to integration_api_requests (canonical path template + status + duration + error code). NEVER receives credentials, headers or bodies. service_role only.';

revoke all on function public.integration_log_api_request(text, uuid, uuid, uuid, text, text, integer, integer, text)
  from public, anon, authenticated;
grant execute on function public.integration_log_api_request(text, uuid, uuid, uuid, text, text, integer, integer, text)
  to service_role;

commit;

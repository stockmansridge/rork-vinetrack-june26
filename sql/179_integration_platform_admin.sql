-- ===========================================================================
-- SQL 179 — Integration Platform Administration, Observability & Governance
--            (Stage 7A)
--
-- Platform-admin (VineTrack staff) visibility and narrowly-scoped controls
-- over the external integration platform, across ALL customers.
--
-- Reuses the established admin authority: public.is_system_admin() — the
-- same check used by the Access & Entitlements admin centre (SQL 140/146).
-- No second admin permission system is introduced.
--
-- Reuses the established integration audit helper public._integration_audit
-- and the existing integration_clients status machine
-- ('active' | 'paused' | 'revoked') for suspension semantics:
--   * paused  => API auth fails with integration_not_active (SQL 173),
--                dispatcher defers queued deliveries +5 min (SQL 178),
--                configuration intact, reactivatable.
--   * revoked => terminal; queued deliveries cancelled (integration_revoked).
--
-- SAFETY CONTRACT (applies to every function in this file):
--   * never returns key_hash, plaintext API keys, signing_secret_hash,
--     signing_secret_prefix, secret_ref (Vault id), auth headers or
--     request/response bodies (the request log never stored them anyway);
--   * webhook URLs are returned with the query string redacted;
--   * all RPCs raise 'System Admin only' (errcode 42501) for non-admins.
--
-- Requires: sql/172, sql/173, sql/177, sql/178.
--
-- ROLLBACK:
--   drop function if exists public.admin_list_integrations(text, text, uuid, text, uuid, text, text, boolean, boolean, timestamptz, timestamptz, timestamptz, timestamptz, integer, timestamptz, uuid);
--   drop function if exists public.admin_get_integration(uuid);
--   drop function if exists public.admin_get_integration_diagnostics(uuid);
--   drop function if exists public.admin_integration_api_metrics(text, uuid, text);
--   drop function if exists public.admin_list_integration_api_requests(uuid, uuid, uuid, text, text, integer, text, boolean, boolean, boolean, timestamptz, timestamptz, integer, timestamptz, uuid);
--   drop function if exists public.admin_webhook_metrics(text, uuid);
--   drop function if exists public.admin_list_webhook_endpoints(uuid, text, boolean, boolean, integer, timestamptz, uuid);
--   drop function if exists public.admin_list_webhook_deliveries(uuid, uuid, text, text, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid);
--   drop function if exists public.admin_suspend_integration(uuid, text);
--   drop function if exists public.admin_reactivate_integration(uuid);
--   drop function if exists public.admin_revoke_integration_api_key(uuid, text);
--   drop function if exists public.admin_set_webhook_endpoint_status(uuid, text, text);
--   drop function if exists public.admin_list_integration_audit(uuid, text, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid);
--   drop function if exists public._admin_integration_health(uuid);
--   drop function if exists public._admin_mask_url(text);
--   drop index if exists public.idx_integration_api_requests_created_keyset;
--   drop index if exists public.idx_webhook_deliveries_created_keyset;
--   drop index if exists public.idx_integration_audit_created_keyset;
-- ===========================================================================

begin;

-- ===========================================================================
-- A. Preconditions
-- ===========================================================================
do $$
begin
  if to_regclass('public.integration_clients') is null
     or to_regclass('public.integration_api_requests') is null
     or to_regclass('public.webhook_deliveries') is null
     or to_regclass('public.webhook_delivery_attempts') is null
     or to_regclass('public.integration_audit_log') is null
     or to_regprocedure('public.is_system_admin()') is null
     or to_regprocedure('public._integration_audit(uuid, text, uuid, jsonb)') is null then
    raise exception 'SQL 179 precondition failed: apply sql/062, sql/172, sql/173, sql/177, sql/178 first';
  end if;
end$$;

-- ===========================================================================
-- B. Indexes for platform-wide (cross-client) admin queries.
--    Existing indexes are all client-scoped; global keyset listing and
--    windowed metrics need time-ordered access without a client filter.
-- ===========================================================================
create index if not exists idx_integration_api_requests_created_keyset
  on public.integration_api_requests (created_at desc, id desc);

create index if not exists idx_webhook_deliveries_created_keyset
  on public.webhook_deliveries (created_at desc, id desc);

create index if not exists idx_integration_audit_created_keyset
  on public.integration_audit_log (created_at desc, id desc);

-- ===========================================================================
-- C. Internal helpers (no client execute)
-- ===========================================================================

-- Redact webhook URL query strings: receiver URLs may embed credentials
-- (?token=...); admins see host + path only.
create or replace function public._admin_mask_url(p_url text)
returns text
language sql
immutable
as $$
  select case
    when p_url is null then null
    when position('?' in p_url) > 0 then split_part(p_url, '?', 1) || '?[redacted]'
    else p_url
  end;
$$;

-- ---------------------------------------------------------------------------
-- _admin_integration_health(client) -> jsonb
--
-- Backend-derived health classification. The frontend must NOT re-derive
-- these rules. Thresholds (documented in docs/integration-platform-admin.md):
--
--   inactive : status = 'revoked' (terminal, expected-quiet)
--              OR created > 30 days ago with no API request and no webhook
--              delivery in the last 30 days.
--   critical : status = 'paused' (suspended)
--              OR any non-deleted webhook endpoint disabled (incl. the
--              SQL 178 auto-disable at 10 consecutive failures)
--              OR the integration has keys but zero usable keys
--              (all revoked/expired).
--   warning  : >=20 requests in 24h with >10% 4xx/5xx error rate
--              OR >=10 rate-limited (429) requests in 24h
--              OR any endpoint with >=3 consecutive delivery failures
--              OR any usable key expiring within 7 days.
--   healthy  : none of the above.
-- ---------------------------------------------------------------------------
create or replace function public._admin_integration_health(p_client_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c public.integration_clients;
  v_keys_total integer;
  v_keys_active integer;
  v_keys_expiring integer;
  v_ep_total integer;
  v_ep_active integer;
  v_ep_disabled integer;
  v_ep_auto_disabled integer;
  v_max_consec integer;
  v_last_api timestamptz;
  v_last_delivery timestamptz;
  v_req_24h integer;
  v_err_24h integer;
  v_rl_24h integer;
  v_wh_fail_24h integer;
  v_class text;
  v_reasons text[] := '{}';
begin
  select * into c from public.integration_clients where id = p_client_id;
  if not found then
    raise exception 'integration_not_found' using errcode = 'P0002';
  end if;

  select count(*),
         count(*) filter (where revoked_at is null
                            and (expires_at is null or expires_at > now())),
         count(*) filter (where revoked_at is null
                            and expires_at is not null
                            and expires_at > now()
                            and expires_at <= now() + interval '7 days')
    into v_keys_total, v_keys_active, v_keys_expiring
  from public.integration_api_keys
  where integration_client_id = p_client_id;

  select count(*),
         count(*) filter (where status = 'active'),
         count(*) filter (where status = 'disabled'),
         count(*) filter (where status = 'disabled'
                            and disabled_reason = 'auto_disabled_after_consecutive_failures'),
         coalesce(max(consecutive_failures), 0)
    into v_ep_total, v_ep_active, v_ep_disabled, v_ep_auto_disabled, v_max_consec
  from public.webhook_endpoints
  where integration_client_id = p_client_id
    and deleted_at is null;

  select max(created_at) into v_last_api
  from public.integration_api_requests
  where integration_client_id = p_client_id;

  select max(created_at) into v_last_delivery
  from public.webhook_deliveries
  where integration_client_id = p_client_id;

  select count(*),
         count(*) filter (where status_code >= 400),
         count(*) filter (where status_code = 429)
    into v_req_24h, v_err_24h, v_rl_24h
  from public.integration_api_requests
  where integration_client_id = p_client_id
    and created_at >= now() - interval '24 hours';

  select count(*) into v_wh_fail_24h
  from public.webhook_delivery_attempts a
  join public.webhook_deliveries d on d.id = a.delivery_id
  where d.integration_client_id = p_client_id
    and a.attempted_at >= now() - interval '24 hours'
    and a.error_category is not null;

  if c.status = 'revoked' then
    v_class := 'inactive';
    v_reasons := array['integration_revoked'];
  elsif c.status = 'paused' then
    v_class := 'critical';
    v_reasons := array['integration_suspended'];
  elsif v_ep_auto_disabled > 0 then
    v_class := 'critical';
    v_reasons := array['webhook_endpoint_auto_disabled'];
  elsif v_ep_disabled > 0 then
    v_class := 'critical';
    v_reasons := array['webhook_endpoint_disabled'];
  elsif v_keys_total > 0 and v_keys_active = 0 then
    v_class := 'critical';
    v_reasons := array['no_usable_api_keys'];
  else
    if v_req_24h >= 20 and v_err_24h::numeric / v_req_24h > 0.10 then
      v_reasons := array_append(v_reasons, 'elevated_api_error_rate_24h');
    end if;
    if v_rl_24h >= 10 then
      v_reasons := array_append(v_reasons, 'rate_limited_24h');
    end if;
    if v_max_consec >= 3 then
      v_reasons := array_append(v_reasons, 'webhook_consecutive_failures');
    end if;
    if v_keys_expiring > 0 then
      v_reasons := array_append(v_reasons, 'api_key_expiring_within_7_days');
    end if;

    if coalesce(array_length(v_reasons, 1), 0) > 0 then
      v_class := 'warning';
    elsif c.created_at < now() - interval '30 days'
      and (v_last_api is null or v_last_api < now() - interval '30 days')
      and (v_last_delivery is null or v_last_delivery < now() - interval '30 days') then
      v_class := 'inactive';
      v_reasons := array['no_activity_30_days'];
    else
      v_class := 'healthy';
    end if;
  end if;

  return jsonb_build_object(
    'classification', v_class,
    'reasons', to_jsonb(v_reasons),
    'signals', jsonb_build_object(
      'api_keys_total', v_keys_total,
      'api_keys_active', v_keys_active,
      'api_keys_expiring_7d', v_keys_expiring,
      'webhook_endpoints_total', v_ep_total,
      'webhook_endpoints_active', v_ep_active,
      'webhook_endpoints_disabled', v_ep_disabled,
      'webhook_endpoints_auto_disabled', v_ep_auto_disabled,
      'max_consecutive_failures', v_max_consec,
      'last_api_request_at', v_last_api,
      'last_webhook_delivery_at', v_last_delivery,
      'api_requests_24h', v_req_24h,
      'api_errors_24h', v_err_24h,
      'api_rate_limited_24h', v_rl_24h,
      'webhook_failed_attempts_24h', v_wh_fail_24h
    )
  );
end$$;

-- ===========================================================================
-- D. admin_list_integrations — global integration directory
-- ===========================================================================
create or replace function public.admin_list_integrations(
  p_status text default null,             -- 'active' | 'paused' | 'revoked'
  p_environment text default null,        -- 'live' | 'test' (has non-revoked key in env)
  p_owner_user_id uuid default null,
  p_owner_query text default null,        -- ilike on integration name / owner email / owner name
  p_vineyard_id uuid default null,        -- has an active grant for this vineyard
  p_activity text default null,           -- 'active_24h' | 'active_7d' | 'no_activity_30d'
  p_health text default null,             -- 'healthy' | 'warning' | 'critical' | 'inactive'
  p_errors_only boolean default false,    -- API errors or webhook failures in last 24h
  p_rate_limited_only boolean default false,
  p_created_from timestamptz default null,
  p_created_to timestamptz default null,
  p_last_used_from timestamptz default null,  -- on last API request time
  p_last_used_to timestamptz default null,
  p_limit integer default 50,
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
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
  v_rows jsonb;
  v_count integer;
  v_next_created timestamptz;
  v_next_id uuid;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;

  if p_status is not null and p_status not in ('active', 'paused', 'revoked') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  if p_environment is not null and p_environment not in ('live', 'test') then
    raise exception 'invalid_environment' using errcode = '22023';
  end if;
  if p_activity is not null and p_activity not in ('active_24h', 'active_7d', 'no_activity_30d') then
    raise exception 'invalid_activity' using errcode = '22023';
  end if;
  if p_health is not null and p_health not in ('healthy', 'warning', 'critical', 'inactive') then
    raise exception 'invalid_health' using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'invalid_cursor' using errcode = '22023';
  end if;

  with page as (
    select
      jsonb_build_object(
        'id', c.id,
        'name', c.name,
        'integration_type', c.integration_type,
        'status', c.status,
        'created_at', c.created_at,
        'updated_at', c.updated_at,
        'paused_at', c.paused_at,
        'revoked_at', c.revoked_at,
        'owner', jsonb_build_object(
          'user_id', pr.id,
          'email', pr.email,
          'full_name', pr.full_name
        ),
        'counts', jsonb_build_object(
          'vineyard_grants', g.n,
          'scopes', s.n,
          'api_keys', (h.health #>> '{signals,api_keys_total}')::integer,
          'active_api_keys', (h.health #>> '{signals,api_keys_active}')::integer,
          'webhook_endpoints', (h.health #>> '{signals,webhook_endpoints_total}')::integer,
          'active_webhook_endpoints', (h.health #>> '{signals,webhook_endpoints_active}')::integer
        ),
        'last_api_request_at', h.health #> '{signals,last_api_request_at}',
        'last_webhook_delivery_at', h.health #> '{signals,last_webhook_delivery_at}',
        'activity_24h', jsonb_build_object(
          'api_requests', h.health #> '{signals,api_requests_24h}',
          'api_errors', h.health #> '{signals,api_errors_24h}',
          'rate_limited', h.health #> '{signals,api_rate_limited_24h}',
          'webhook_failed_attempts', h.health #> '{signals,webhook_failed_attempts_24h}'
        ),
        'health', jsonb_build_object(
          'classification', h.health -> 'classification',
          'reasons', h.health -> 'reasons'
        )
      ) as row_json,
      c.created_at as c_created_at,
      c.id as c_id,
      row_number() over (order by c.created_at desc, c.id desc) as rn
    from public.integration_clients c
    join public.profiles pr on pr.id = c.owner_user_id
    cross join lateral (select public._admin_integration_health(c.id) as health) h
    cross join lateral (
      select count(*) as n from public.integration_client_vineyards gv
      where gv.integration_client_id = c.id and gv.revoked_at is null
    ) g
    cross join lateral (
      select count(*) as n from public.integration_client_scopes cs
      where cs.integration_client_id = c.id and cs.revoked_at is null
    ) s
    where (p_status is null or c.status = p_status)
      and (p_owner_user_id is null or c.owner_user_id = p_owner_user_id)
      and (p_owner_query is null
           or c.name ilike '%' || p_owner_query || '%'
           or coalesce(pr.email, '') ilike '%' || p_owner_query || '%'
           or coalesce(pr.full_name, '') ilike '%' || p_owner_query || '%')
      and (p_environment is null or exists (
             select 1 from public.integration_api_keys k
             where k.integration_client_id = c.id
               and k.environment = p_environment
               and k.revoked_at is null))
      and (p_vineyard_id is null or exists (
             select 1 from public.integration_client_vineyards gv2
             where gv2.integration_client_id = c.id
               and gv2.vineyard_id = p_vineyard_id
               and gv2.revoked_at is null))
      and (p_created_from is null or c.created_at >= p_created_from)
      and (p_created_to is null or c.created_at <= p_created_to)
      and (p_last_used_from is null
           or (h.health #>> '{signals,last_api_request_at}')::timestamptz >= p_last_used_from)
      and (p_last_used_to is null
           or (h.health #>> '{signals,last_api_request_at}')::timestamptz <= p_last_used_to)
      and (p_health is null or h.health ->> 'classification' = p_health)
      and (not coalesce(p_errors_only, false)
           or (h.health #>> '{signals,api_errors_24h}')::integer > 0
           or (h.health #>> '{signals,webhook_failed_attempts_24h}')::integer > 0)
      and (not coalesce(p_rate_limited_only, false)
           or (h.health #>> '{signals,api_rate_limited_24h}')::integer > 0)
      and (p_activity is null
           or (p_activity = 'active_24h' and (
                 coalesce((h.health #>> '{signals,last_api_request_at}')::timestamptz, timestamptz 'epoch') >= now() - interval '24 hours'
              or coalesce((h.health #>> '{signals,last_webhook_delivery_at}')::timestamptz, timestamptz 'epoch') >= now() - interval '24 hours'))
           or (p_activity = 'active_7d' and (
                 coalesce((h.health #>> '{signals,last_api_request_at}')::timestamptz, timestamptz 'epoch') >= now() - interval '7 days'
              or coalesce((h.health #>> '{signals,last_webhook_delivery_at}')::timestamptz, timestamptz 'epoch') >= now() - interval '7 days'))
           or (p_activity = 'no_activity_30d'
               and coalesce((h.health #>> '{signals,last_api_request_at}')::timestamptz, timestamptz 'epoch') < now() - interval '30 days'
               and coalesce((h.health #>> '{signals,last_webhook_delivery_at}')::timestamptz, timestamptz 'epoch') < now() - interval '30 days'))
      and (p_before_created_at is null
           or (c.created_at, c.id) < (p_before_created_at, p_before_id))
    order by c.created_at desc, c.id desc
    limit v_limit + 1
  )
  select coalesce(jsonb_agg(row_json order by rn) filter (where rn <= v_limit), '[]'::jsonb),
         count(*)::integer,
         max(c_created_at) filter (where rn = v_limit),
         max(c_id::text) filter (where rn = v_limit)
    into v_rows, v_count, v_next_created, v_next_id
  from page;

  return jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object(
      'has_more', v_count > v_limit,
      'next_before_created_at', case when v_count > v_limit then v_next_created end,
      'next_before_id', case when v_count > v_limit then v_next_id end
    )
  );
end$$;

-- ===========================================================================
-- E. admin_get_integration — configuration inspection (safe metadata only)
-- ===========================================================================
create or replace function public.admin_get_integration(p_client_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c public.integration_clients;
  v_owner jsonb;
  v_grants jsonb;
  v_scopes jsonb;
  v_keys jsonb;
  v_endpoints jsonb;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_client_id is null then
    raise exception 'client_required' using errcode = '22023';
  end if;

  select * into c from public.integration_clients where id = p_client_id;
  if not found then
    raise exception 'integration_not_found' using errcode = 'P0002';
  end if;

  select jsonb_build_object('user_id', pr.id, 'email', pr.email, 'full_name', pr.full_name)
    into v_owner
  from public.profiles pr where pr.id = c.owner_user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', g.id,
           'vineyard_id', g.vineyard_id,
           'vineyard_name', v.name,
           'granted_by', g.granted_by,
           'granted_at', g.granted_at,
           'revoked_at', g.revoked_at,
           'is_active', g.revoked_at is null
         ) order by g.granted_at desc), '[]'::jsonb)
    into v_grants
  from public.integration_client_vineyards g
  join public.vineyards v on v.id = g.vineyard_id
  where g.integration_client_id = p_client_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'scope', s.scope,
           'module', sc.module,
           'is_sensitive', sc.is_sensitive,
           'granted_at', s.granted_at,
           'revoked_at', s.revoked_at,
           'is_active', s.revoked_at is null
         ) order by s.granted_at desc), '[]'::jsonb)
    into v_scopes
  from public.integration_client_scopes s
  join public.integration_scope_catalog sc on sc.scope = s.scope
  where s.integration_client_id = p_client_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', k.id,
           'name', k.name,
           'key_prefix', k.key_prefix,
           'environment', k.environment,
           'status', case
             when k.revoked_at is not null then 'revoked'
             when k.expires_at is not null and k.expires_at <= now() then 'expired'
             else 'active'
           end,
           'created_at', k.created_at,
           'expires_at', k.expires_at,
           'last_used_at', k.last_used_at,
           'revoked_at', k.revoked_at
         ) order by k.created_at desc), '[]'::jsonb)
    into v_keys
  from public.integration_api_keys k
  where k.integration_client_id = p_client_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id,
           'name', e.name,
           'url', public._admin_mask_url(e.url),
           'status', e.status,
           'consecutive_failures', e.consecutive_failures,
           'last_success_at', e.last_success_at,
           'last_failure_at', e.last_failure_at,
           'paused_at', e.paused_at,
           'disabled_at', e.disabled_at,
           'disabled_reason', e.disabled_reason,
           'created_at', e.created_at,
           'updated_at', e.updated_at,
           'subscriptions_active', (
             select count(*) from public.webhook_subscriptions ws
             where ws.webhook_endpoint_id = e.id and ws.is_active
           )
         ) order by e.created_at desc), '[]'::jsonb)
    into v_endpoints
  from public.webhook_endpoints e
  where e.integration_client_id = p_client_id
    and e.deleted_at is null;

  return jsonb_build_object(
    'integration', jsonb_build_object(
      'id', c.id,
      'name', c.name,
      'description', c.description,
      'integration_type', c.integration_type,
      'status', c.status,
      'created_by', c.created_by,
      'created_at', c.created_at,
      'updated_at', c.updated_at,
      'paused_at', c.paused_at,
      'revoked_at', c.revoked_at
    ),
    'owner', v_owner,
    'health', public._admin_integration_health(p_client_id),
    'vineyard_grants', v_grants,
    'scopes', v_scopes,
    'api_keys', v_keys,
    'webhook_endpoints', v_endpoints
  );
end$$;

-- ===========================================================================
-- F. admin_get_integration_diagnostics — one-call support snapshot
-- ===========================================================================
create or replace function public.admin_get_integration_diagnostics(p_client_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_base jsonb;
  v_last_request jsonb;
  v_24h jsonb;
  v_7d jsonb;
  v_webhooks jsonb;
  v_audit jsonb;
begin
  -- Authority + existence enforced by admin_get_integration.
  v_base := public.admin_get_integration(p_client_id);

  select jsonb_build_object(
           'request_id', r.request_id,
           'created_at', r.created_at,
           'method', r.method,
           'path', r.path,
           'status_code', r.status_code,
           'duration_ms', r.duration_ms,
           'error_code', r.error_code
         )
    into v_last_request
  from public.integration_api_requests r
  where r.integration_client_id = p_client_id
  order by r.created_at desc, r.id desc
  limit 1;

  select jsonb_build_object(
           'requests', count(*),
           'errors', count(*) filter (where status_code >= 400),
           'rate_limited', count(*) filter (where status_code = 429))
    into v_24h
  from public.integration_api_requests
  where integration_client_id = p_client_id
    and created_at >= now() - interval '24 hours';

  select jsonb_build_object(
           'requests', count(*),
           'errors', count(*) filter (where status_code >= 400),
           'rate_limited', count(*) filter (where status_code = 429))
    into v_7d
  from public.integration_api_requests
  where integration_client_id = p_client_id
    and created_at >= now() - interval '7 days';

  select jsonb_build_object(
           'pending_deliveries', count(*) filter (where status in ('pending', 'delivering')),
           'retrying_deliveries', count(*) filter (where status = 'pending' and attempt_count >= 1),
           'next_retry_at', min(next_attempt_at) filter (where status = 'pending'),
           'failed_deliveries_7d', count(*) filter (where status = 'failed'
                                                      and failed_at >= now() - interval '7 days'),
           'failed_attempts_24h', (
             select count(*)
             from public.webhook_delivery_attempts a
             join public.webhook_deliveries d2 on d2.id = a.delivery_id
             where d2.integration_client_id = p_client_id
               and a.attempted_at >= now() - interval '24 hours'
               and a.error_category is not null
           ))
    into v_webhooks
  from public.webhook_deliveries
  where integration_client_id = p_client_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'created_at', l.created_at,
           'actor_user_id', l.actor_user_id,
           'action', l.action,
           'vineyard_id', l.vineyard_id,
           'metadata', l.metadata
         ) order by l.created_at desc), '[]'::jsonb)
    into v_audit
  from (
    select * from public.integration_audit_log
    where integration_client_id = p_client_id
    order by created_at desc, id desc
    limit 20
  ) l;

  return v_base || jsonb_build_object(
    'api_activity', jsonb_build_object(
      'last_request', v_last_request,
      'window_24h', v_24h,
      'window_7d', v_7d
    ),
    'webhook_activity', v_webhooks,
    'recent_audit', v_audit
  );
end$$;

-- ===========================================================================
-- G. admin_integration_api_metrics — global API usage aggregation
-- ===========================================================================
create or replace function public.admin_integration_api_metrics(
  p_window text default '24h',      -- '24h' | '7d' | '30d'
  p_client_id uuid default null,
  p_group_by text default 'none'    -- 'none'|'integration'|'path'|'status_class'|'vineyard'|'api_key'|'day'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_totals jsonb;
  v_breakdown jsonb := null;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;

  v_from := now() - case p_window
    when '24h' then interval '24 hours'
    when '7d' then interval '7 days'
    when '30d' then interval '30 days'
  end;
  if v_from is null then
    raise exception 'invalid_window' using errcode = '22023';
  end if;
  if p_group_by not in ('none', 'integration', 'path', 'status_class', 'vineyard', 'api_key', 'day') then
    raise exception 'invalid_group_by' using errcode = '22023';
  end if;

  -- Note: 429 rows are also counted inside client_error_4xx (documented).
  select jsonb_build_object(
           'requests', count(*),
           'success_2xx', count(*) filter (where status_code between 200 and 299),
           'client_error_4xx', count(*) filter (where status_code between 400 and 499),
           'server_error_5xx', count(*) filter (where status_code between 500 and 599),
           'rate_limited', count(*) filter (where status_code = 429),
           'unauthenticated', count(*) filter (where integration_client_id is null),
           'avg_duration_ms', round(avg(duration_ms)::numeric, 1),
           'p95_duration_ms', round((percentile_cont(0.95) within group (order by duration_ms))::numeric, 1),
           'unique_integrations', count(distinct integration_client_id),
           'unique_api_keys', count(distinct api_key_id))
    into v_totals
  from public.integration_api_requests
  where created_at >= v_from
    and (p_client_id is null or integration_client_id = p_client_id);

  if p_group_by <> 'none' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'key', g.group_key,
             'label', case p_group_by
               when 'integration' then coalesce(
                 (select ic.name from public.integration_clients ic where ic.id::text = g.group_key),
                 case when g.group_key = 'unauthenticated' then 'unauthenticated' else g.group_key end)
               when 'api_key' then coalesce(
                 (select k.key_prefix || coalesce(' (' || k.name || ')', '')
                  from public.integration_api_keys k where k.id::text = g.group_key),
                 g.group_key)
               when 'vineyard' then coalesce(
                 (select vy.name from public.vineyards vy where vy.id::text = g.group_key),
                 g.group_key)
               else g.group_key
             end,
             'requests', g.requests,
             'success_2xx', g.success_2xx,
             'client_error_4xx', g.client_error_4xx,
             'server_error_5xx', g.server_error_5xx,
             'rate_limited', g.rate_limited,
             'avg_duration_ms', g.avg_duration_ms,
             'p95_duration_ms', g.p95_duration_ms
           ) order by g.rn), '[]'::jsonb)
      into v_breakdown
    from (
      select grouped.*,
             row_number() over (
               order by case when p_group_by = 'day' then grouped.group_key end asc nulls last,
                        case when p_group_by <> 'day' then grouped.requests end desc nulls last,
                        grouped.group_key
             ) as rn
      from (
        select
          case p_group_by
            when 'integration' then coalesce(r.integration_client_id::text, 'unauthenticated')
            when 'path' then r.path
            when 'status_class' then (r.status_code / 100)::text || 'xx'
            when 'vineyard' then coalesce(r.vineyard_id::text, 'none')
            when 'api_key' then coalesce(r.api_key_id::text, 'none')
            when 'day' then to_char(date_trunc('day', r.created_at), 'YYYY-MM-DD')
          end as group_key,
          count(*) as requests,
          count(*) filter (where r.status_code between 200 and 299) as success_2xx,
          count(*) filter (where r.status_code between 400 and 499) as client_error_4xx,
          count(*) filter (where r.status_code between 500 and 599) as server_error_5xx,
          count(*) filter (where r.status_code = 429) as rate_limited,
          round(avg(r.duration_ms)::numeric, 1) as avg_duration_ms,
          round((percentile_cont(0.95) within group (order by r.duration_ms))::numeric, 1) as p95_duration_ms
        from public.integration_api_requests r
        where r.created_at >= v_from
          and (p_client_id is null or r.integration_client_id = p_client_id)
        group by 1
      ) grouped
      order by rn
      limit 100
    ) g;
  end if;

  return jsonb_build_object(
    'window', p_window,
    'from', v_from,
    'to', now(),
    'group_by', p_group_by,
    'totals', v_totals,
    'breakdown', v_breakdown
  );
end$$;

-- ===========================================================================
-- H. admin_list_integration_api_requests — cross-client request diagnostics.
--    Unlike SQL 177 (single-client, customer-facing), this covers ALL
--    integrations AND unauthenticated failures (integration_client_id null).
--    The log never stores headers, tokens or bodies (SQL 172 §H design).
-- ===========================================================================
create or replace function public.admin_list_integration_api_requests(
  p_client_id uuid default null,
  p_api_key_id uuid default null,
  p_vineyard_id uuid default null,
  p_method text default null,
  p_path text default null,
  p_status_code integer default null,
  p_status_class text default null,        -- '2xx' | '3xx' | '4xx' | '5xx'
  p_errors_only boolean default false,
  p_rate_limited_only boolean default false,
  p_unauthenticated_only boolean default false,
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
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 1000));
  v_rows jsonb;
  v_count integer;
  v_next_created timestamptz;
  v_next_id uuid;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_status_class is not null and p_status_class not in ('2xx', '3xx', '4xx', '5xx') then
    raise exception 'invalid_status_class' using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'invalid_cursor' using errcode = '22023';
  end if;

  with page as (
    select
      jsonb_build_object(
        'id', r.id,
        'request_id', r.request_id,
        'created_at', r.created_at,
        'integration_client_id', r.integration_client_id,
        'integration_name', c.name,
        'api_key_id', r.api_key_id,
        'api_key_prefix', k.key_prefix,
        'api_key_name', k.name,
        'vineyard_id', r.vineyard_id,
        'vineyard_name', v.name,
        'method', r.method,
        'path', r.path,
        'status_code', r.status_code,
        'duration_ms', r.duration_ms,
        'error_code', r.error_code
      ) as row_json,
      r.created_at as r_created_at,
      r.id as r_id,
      row_number() over (order by r.created_at desc, r.id desc) as rn
    from public.integration_api_requests r
    left join public.integration_clients c on c.id = r.integration_client_id
    left join public.integration_api_keys k on k.id = r.api_key_id
    left join public.vineyards v on v.id = r.vineyard_id
    where (p_client_id is null or r.integration_client_id = p_client_id)
      and (p_api_key_id is null or r.api_key_id = p_api_key_id)
      and (p_vineyard_id is null or r.vineyard_id = p_vineyard_id)
      and (p_method is null or r.method = upper(p_method))
      and (p_path is null or r.path = p_path)
      and (p_status_code is null or r.status_code = p_status_code)
      and (p_status_class is null
           or r.status_code between (left(p_status_class, 1)::integer * 100)
                                and (left(p_status_class, 1)::integer * 100 + 99))
      and (not coalesce(p_errors_only, false) or r.status_code >= 400)
      and (not coalesce(p_rate_limited_only, false) or r.status_code = 429)
      and (not coalesce(p_unauthenticated_only, false) or r.integration_client_id is null)
      and (p_from is null or r.created_at >= p_from)
      and (p_to is null or r.created_at <= p_to)
      and (p_before_created_at is null
           or (r.created_at, r.id) < (p_before_created_at, p_before_id))
    order by r.created_at desc, r.id desc
    limit v_limit + 1
  )
  select coalesce(jsonb_agg(row_json order by rn) filter (where rn <= v_limit), '[]'::jsonb),
         count(*)::integer,
         max(r_created_at) filter (where rn = v_limit),
         max(r_id::text) filter (where rn = v_limit)
    into v_rows, v_count, v_next_created, v_next_id
  from page;

  return jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object(
      'has_more', v_count > v_limit,
      'next_before_created_at', case when v_count > v_limit then v_next_created end,
      'next_before_id', case when v_count > v_limit then v_next_id end
    )
  );
end$$;

-- ===========================================================================
-- I. admin_webhook_metrics — global webhook platform health
-- ===========================================================================
create or replace function public.admin_webhook_metrics(
  p_window text default '24h',
  p_client_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_deliveries jsonb;
  v_attempts jsonb;
  v_endpoints jsonb;
  v_oldest jsonb;
  v_problems jsonb;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;

  v_from := now() - case p_window
    when '24h' then interval '24 hours'
    when '7d' then interval '7 days'
    when '30d' then interval '30 days'
  end;
  if v_from is null then
    raise exception 'invalid_window' using errcode = '22023';
  end if;

  select jsonb_build_object(
           'total', count(*),
           'pending', count(*) filter (where status = 'pending'),
           'delivering', count(*) filter (where status = 'delivering'),
           'delivered', count(*) filter (where status = 'delivered'),
           'failed', count(*) filter (where status = 'failed'),
           'cancelled', count(*) filter (where status = 'cancelled'),
           'retry_scheduled', count(*) filter (where status = 'pending' and attempt_count >= 1),
           'test_deliveries', count(*) filter (where is_test),
           'delivered_rate', case
             when count(*) filter (where status in ('delivered', 'failed')) > 0
             then round(count(*) filter (where status = 'delivered')::numeric
                      / count(*) filter (where status in ('delivered', 'failed')), 4)
           end,
           'failed_rate', case
             when count(*) filter (where status in ('delivered', 'failed')) > 0
             then round(count(*) filter (where status = 'failed')::numeric
                      / count(*) filter (where status in ('delivered', 'failed')), 4)
           end,
           'avg_attempts_terminal', round(avg(attempt_count) filter (where status in ('delivered', 'failed')), 2))
    into v_deliveries
  from public.webhook_deliveries
  where created_at >= v_from
    and (p_client_id is null or integration_client_id = p_client_id);

  select jsonb_build_object(
           'total', count(*),
           'failed', count(*) filter (where a.error_category is not null),
           'avg_duration_ms', round(avg(a.duration_ms)::numeric, 1))
    into v_attempts
  from public.webhook_delivery_attempts a
  join public.webhook_deliveries d on d.id = a.delivery_id
  where a.attempted_at >= v_from
    and (p_client_id is null or d.integration_client_id = p_client_id);

  select jsonb_build_object(
           'total', count(*),
           'active', count(*) filter (where status = 'active'),
           'paused', count(*) filter (where status = 'paused'),
           'disabled', count(*) filter (where status = 'disabled'),
           'auto_disabled', count(*) filter (where status = 'disabled'
                              and disabled_reason = 'auto_disabled_after_consecutive_failures'),
           'with_consecutive_failures', count(*) filter (where consecutive_failures >= 3
                              and status <> 'disabled'))
    into v_endpoints
  from public.webhook_endpoints
  where deleted_at is null
    and (p_client_id is null or integration_client_id = p_client_id);

  select jsonb_build_object(
           'public_id', d.public_id,
           'integration_client_id', d.integration_client_id,
           'endpoint_id', d.endpoint_id,
           'status', d.status,
           'attempt_count', d.attempt_count,
           'created_at', d.created_at,
           'age_seconds', extract(epoch from now() - d.created_at)::bigint)
    into v_oldest
  from public.webhook_deliveries d
  where d.status in ('pending', 'delivering')
    and (p_client_id is null or d.integration_client_id = p_client_id)
  order by d.created_at asc
  limit 1;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_problems
  from (
    select jsonb_build_object(
             'integration_client_id', c.id,
             'name', c.name,
             'status', c.status,
             'disabled_endpoints', (
               select count(*) from public.webhook_endpoints e
               where e.integration_client_id = c.id and e.deleted_at is null
                 and e.status = 'disabled'),
             'failing_endpoints', (
               select count(*) from public.webhook_endpoints e
               where e.integration_client_id = c.id and e.deleted_at is null
                 and e.status <> 'disabled' and e.consecutive_failures >= 3),
             'failed_deliveries_window', (
               select count(*) from public.webhook_deliveries d
               where d.integration_client_id = c.id
                 and d.status = 'failed' and d.failed_at >= v_from)
           ) as x
    from public.integration_clients c
    where (p_client_id is null or c.id = p_client_id)
      and (exists (select 1 from public.webhook_endpoints e
                   where e.integration_client_id = c.id and e.deleted_at is null
                     and (e.status = 'disabled' or e.consecutive_failures >= 3))
        or exists (select 1 from public.webhook_deliveries d
                   where d.integration_client_id = c.id
                     and d.status = 'failed' and d.failed_at >= v_from))
    order by c.created_at desc
    limit 50
  ) q;

  return jsonb_build_object(
    'window', p_window,
    'from', v_from,
    'to', now(),
    'deliveries', v_deliveries,
    'attempts', v_attempts,
    'endpoints', v_endpoints,
    'oldest_pending_delivery', v_oldest,
    'integrations_with_problems', v_problems
  );
end$$;

-- ===========================================================================
-- J. admin_list_webhook_endpoints — global endpoint diagnostics
-- ===========================================================================
create or replace function public.admin_list_webhook_endpoints(
  p_client_id uuid default null,
  p_status text default null,              -- 'active' | 'paused' | 'disabled'
  p_failing_only boolean default false,    -- consecutive_failures > 0 or disabled
  p_include_deleted boolean default false,
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
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 500));
  v_rows jsonb;
  v_count integer;
  v_next_created timestamptz;
  v_next_id uuid;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_status is not null and p_status not in ('active', 'paused', 'disabled') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'invalid_cursor' using errcode = '22023';
  end if;

  with page as (
    select
      jsonb_build_object(
        'id', e.id,
        'integration_client_id', e.integration_client_id,
        'integration_name', c.name,
        'owner_email', pr.email,
        'name', e.name,
        'url', public._admin_mask_url(e.url),
        'status', e.status,
        'consecutive_failures', e.consecutive_failures,
        'last_success_at', e.last_success_at,
        'last_failure_at', e.last_failure_at,
        'paused_at', e.paused_at,
        'disabled_at', e.disabled_at,
        'disabled_reason', e.disabled_reason,
        'deleted_at', e.deleted_at,
        'created_at', e.created_at,
        'updated_at', e.updated_at,
        'subscriptions_total', (
          select count(*) from public.webhook_subscriptions ws
          where ws.webhook_endpoint_id = e.id),
        'subscriptions_active', (
          select count(*) from public.webhook_subscriptions ws
          where ws.webhook_endpoint_id = e.id and ws.is_active)
      ) as row_json,
      e.created_at as e_created_at,
      e.id as e_id,
      row_number() over (order by e.created_at desc, e.id desc) as rn
    from public.webhook_endpoints e
    join public.integration_clients c on c.id = e.integration_client_id
    left join public.profiles pr on pr.id = c.owner_user_id
    where (p_client_id is null or e.integration_client_id = p_client_id)
      and (p_status is null or e.status = p_status)
      and (coalesce(p_include_deleted, false) or e.deleted_at is null)
      and (not coalesce(p_failing_only, false)
           or e.consecutive_failures > 0 or e.status = 'disabled')
      and (p_before_created_at is null
           or (e.created_at, e.id) < (p_before_created_at, p_before_id))
    order by e.created_at desc, e.id desc
    limit v_limit + 1
  )
  select coalesce(jsonb_agg(row_json order by rn) filter (where rn <= v_limit), '[]'::jsonb),
         count(*)::integer,
         max(e_created_at) filter (where rn = v_limit),
         max(e_id::text) filter (where rn = v_limit)
    into v_rows, v_count, v_next_created, v_next_id
  from page;

  return jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object(
      'has_more', v_count > v_limit,
      'next_before_created_at', case when v_count > v_limit then v_next_created end,
      'next_before_id', case when v_count > v_limit then v_next_id end
    )
  );
end$$;

-- ===========================================================================
-- K. admin_list_webhook_deliveries — cross-client delivery diagnostics.
--    Per-delivery detail (attempt history + safe event envelope) is served
--    by the existing integration_get_webhook_delivery — platform admins pass
--    its view authority via is_system_admin() inside _integration_can_view.
-- ===========================================================================
create or replace function public.admin_list_webhook_deliveries(
  p_client_id uuid default null,
  p_endpoint_id uuid default null,
  p_event_type text default null,
  p_status text default null,   -- 'pending'|'delivering'|'delivered'|'failed'|'cancelled'
  p_vineyard_id uuid default null,
  p_is_test boolean default null,
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
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 1000));
  v_rows jsonb;
  v_count integer;
  v_next_created timestamptz;
  v_next_id uuid;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_status is not null
     and p_status not in ('pending', 'delivering', 'delivered', 'failed', 'cancelled') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'invalid_cursor' using errcode = '22023';
  end if;

  with page as (
    select
      jsonb_build_object(
        'id', d.id,
        'public_id', d.public_id,
        'created_at', d.created_at,
        'event_type', ev.event_type,
        'event_public_id', ev.public_id,
        'occurred_at', ev.occurred_at,
        'integration_client_id', d.integration_client_id,
        'integration_name', c.name,
        'endpoint_id', d.endpoint_id,
        'endpoint_name', e.name,
        'vineyard_id', d.vineyard_id,
        'status', d.status,
        'is_test', d.is_test,
        'replay_of', d.replay_of,
        'attempt_count', d.attempt_count,
        'next_attempt_at', d.next_attempt_at,
        'last_status_code', d.last_status_code,
        'last_error_code', d.last_error_code,
        'delivered_at', d.delivered_at,
        'failed_at', d.failed_at,
        'cancelled_at', d.cancelled_at,
        'cancel_reason', d.cancel_reason
      ) as row_json,
      d.created_at as d_created_at,
      d.id as d_id,
      row_number() over (order by d.created_at desc, d.id desc) as rn
    from public.webhook_deliveries d
    join public.integration_events ev on ev.id = d.event_id
    join public.integration_clients c on c.id = d.integration_client_id
    join public.webhook_endpoints e on e.id = d.endpoint_id
    where (p_client_id is null or d.integration_client_id = p_client_id)
      and (p_endpoint_id is null or d.endpoint_id = p_endpoint_id)
      and (p_event_type is null or ev.event_type = p_event_type)
      and (p_status is null or d.status = p_status)
      and (p_vineyard_id is null or d.vineyard_id = p_vineyard_id)
      and (p_is_test is null or d.is_test = p_is_test)
      and (p_from is null or d.created_at >= p_from)
      and (p_to is null or d.created_at <= p_to)
      and (p_before_created_at is null
           or (d.created_at, d.id) < (p_before_created_at, p_before_id))
    order by d.created_at desc, d.id desc
    limit v_limit + 1
  )
  select coalesce(jsonb_agg(row_json order by rn) filter (where rn <= v_limit), '[]'::jsonb),
         count(*)::integer,
         max(d_created_at) filter (where rn = v_limit),
         max(d_id::text) filter (where rn = v_limit)
    into v_rows, v_count, v_next_created, v_next_id
  from page;

  return jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object(
      'has_more', v_count > v_limit,
      'next_before_created_at', case when v_count > v_limit then v_next_created end,
      'next_before_id', case when v_count > v_limit then v_next_id end
    )
  );
end$$;

-- ===========================================================================
-- L. Platform-admin control actions (narrow, reversible, audited)
-- ===========================================================================

-- Suspend = the existing 'paused' status (SQL 172 state machine):
--   * API auth fails with integration_not_active (SQL 173 checks client status)
--   * dispatcher defers queued deliveries +5 min while paused (SQL 178)
--   * configuration remains intact; reversible via reactivate.
create or replace function public.admin_suspend_integration(
  p_client_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  c public.integration_clients;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_client_id is null then
    raise exception 'client_required' using errcode = '22023';
  end if;

  select * into c from public.integration_clients where id = p_client_id;
  if not found then
    raise exception 'integration_not_found' using errcode = 'P0002';
  end if;
  if c.status = 'revoked' then
    raise exception 'integration_revoked';
  end if;
  if c.status = 'paused' then
    raise exception 'already_suspended';
  end if;

  update public.integration_clients
     set status = 'paused', paused_at = now()
   where id = p_client_id;

  perform public._integration_audit(p_client_id, 'integration.paused', null,
    jsonb_build_object(
      'platform_admin', true,
      'previous_status', c.status,
      'reason', nullif(left(trim(coalesce(p_reason, '')), 200), '')));

  return jsonb_build_object('id', p_client_id, 'status', 'paused', 'suspended', true);
end$$;

create or replace function public.admin_reactivate_integration(p_client_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  c public.integration_clients;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_client_id is null then
    raise exception 'client_required' using errcode = '22023';
  end if;

  select * into c from public.integration_clients where id = p_client_id;
  if not found then
    raise exception 'integration_not_found' using errcode = 'P0002';
  end if;
  if c.status = 'revoked' then
    raise exception 'integration_revoked';
  end if;
  if c.status <> 'paused' then
    raise exception 'not_suspended';
  end if;

  update public.integration_clients
     set status = 'active', paused_at = null
   where id = p_client_id;

  perform public._integration_audit(p_client_id, 'integration.reactivated', null,
    jsonb_build_object('platform_admin', true, 'previous_status', 'paused'));

  return jsonb_build_object('id', p_client_id, 'status', 'active');
end$$;

create or replace function public.admin_revoke_integration_api_key(
  p_api_key_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  k public.integration_api_keys;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_api_key_id is null then
    raise exception 'api_key_required' using errcode = '22023';
  end if;

  select * into k from public.integration_api_keys where id = p_api_key_id;
  if not found then
    raise exception 'api_key_not_found' using errcode = 'P0002';
  end if;
  if k.revoked_at is not null then
    raise exception 'api_key_already_revoked';
  end if;

  update public.integration_api_keys
     set revoked_at = now()
   where id = p_api_key_id;

  perform public._integration_audit(k.integration_client_id, 'api_key.revoked', null,
    jsonb_build_object(
      'platform_admin', true,
      'api_key_id', k.id,
      'key_prefix', k.key_prefix,
      'environment', k.environment,
      'reason', nullif(left(trim(coalesce(p_reason, '')), 200), '')));

  return jsonb_build_object(
    'id', k.id,
    'key_prefix', k.key_prefix,
    'status', 'revoked'
  );
end$$;

create or replace function public.admin_set_webhook_endpoint_status(
  p_endpoint_id uuid,
  p_status text,                  -- 'active' | 'paused'
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  e public.webhook_endpoints;
  v_action text;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_endpoint_id is null then
    raise exception 'endpoint_required' using errcode = '22023';
  end if;
  if p_status not in ('active', 'paused') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;

  select * into e from public.webhook_endpoints
  where id = p_endpoint_id and deleted_at is null;
  if not found then
    raise exception 'webhook_endpoint_not_found' using errcode = 'P0002';
  end if;
  if e.status = p_status then
    raise exception 'status_unchanged';
  end if;

  if p_status = 'paused' then
    update public.webhook_endpoints
       set status = 'paused', paused_at = now(), updated_at = now()
     where id = p_endpoint_id;
    v_action := 'webhook_endpoint.paused';
  else
    -- Reactivation (from paused or disabled) clears the disable state and
    -- resets the failure streak — same semantics as the customer-facing
    -- integration_set_webhook_endpoint_status (SQL 178).
    update public.webhook_endpoints
       set status = 'active',
           paused_at = null,
           disabled_at = null,
           disabled_reason = null,
           consecutive_failures = 0,
           updated_at = now()
     where id = p_endpoint_id;
    v_action := 'webhook_endpoint.reactivated';
  end if;

  perform public._integration_audit(e.integration_client_id, v_action, null,
    jsonb_build_object(
      'platform_admin', true,
      'endpoint_id', e.id,
      'previous_status', e.status,
      'reason', nullif(left(trim(coalesce(p_reason, '')), 200), '')));

  return jsonb_build_object(
    'id', e.id,
    'status', p_status,
    'previous_status', e.status
  );
end$$;

-- ===========================================================================
-- M. admin_list_integration_audit — global + per-integration audit history
-- ===========================================================================
create or replace function public.admin_list_integration_audit(
  p_client_id uuid default null,
  p_action text default null,
  p_actor_user_id uuid default null,
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
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 1000));
  v_rows jsonb;
  v_count integer;
  v_next_created timestamptz;
  v_next_id uuid;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'invalid_cursor' using errcode = '22023';
  end if;

  with page as (
    select
      jsonb_build_object(
        'id', l.id,
        'created_at', l.created_at,
        'actor_user_id', l.actor_user_id,
        'actor_email', pr.email,
        'actor_type', case
          when l.actor_user_id is null then 'system'
          when exists (select 1 from public.system_admins sa
                       where sa.user_id = l.actor_user_id and sa.is_active) then 'platform_admin'
          else 'user'
        end,
        'integration_client_id', l.integration_client_id,
        'integration_name', c.name,
        'action', l.action,
        'vineyard_id', l.vineyard_id,
        'vineyard_name', v.name,
        'metadata', l.metadata
      ) as row_json,
      l.created_at as l_created_at,
      l.id as l_id,
      row_number() over (order by l.created_at desc, l.id desc) as rn
    from public.integration_audit_log l
    join public.integration_clients c on c.id = l.integration_client_id
    left join public.profiles pr on pr.id = l.actor_user_id
    left join public.vineyards v on v.id = l.vineyard_id
    where (p_client_id is null or l.integration_client_id = p_client_id)
      and (p_action is null or l.action = p_action)
      and (p_actor_user_id is null or l.actor_user_id = p_actor_user_id)
      and (p_vineyard_id is null or l.vineyard_id = p_vineyard_id)
      and (p_from is null or l.created_at >= p_from)
      and (p_to is null or l.created_at <= p_to)
      and (p_before_created_at is null
           or (l.created_at, l.id) < (p_before_created_at, p_before_id))
    order by l.created_at desc, l.id desc
    limit v_limit + 1
  )
  select coalesce(jsonb_agg(row_json order by rn) filter (where rn <= v_limit), '[]'::jsonb),
         count(*)::integer,
         max(l_created_at) filter (where rn = v_limit),
         max(l_id::text) filter (where rn = v_limit)
    into v_rows, v_count, v_next_created, v_next_id
  from page;

  return jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object(
      'has_more', v_count > v_limit,
      'next_before_created_at', case when v_count > v_limit then v_next_created end,
      'next_before_id', case when v_count > v_limit then v_next_id end
    )
  );
end$$;

-- ===========================================================================
-- N. Grants — authorization is enforced INSIDE each function via
--    is_system_admin(); execute is granted to authenticated only.
--    anon and service_role have no execute (service_role must use the
--    customer/dispatcher RPC surface, not the admin surface).
-- ===========================================================================

-- Internal helpers: no client execute at all.
revoke all on function public._admin_integration_health(uuid) from public, anon, authenticated;
revoke all on function public._admin_mask_url(text) from public, anon, authenticated;

revoke all on function public.admin_list_integrations(text, text, uuid, text, uuid, text, text, boolean, boolean, timestamptz, timestamptz, timestamptz, timestamptz, integer, timestamptz, uuid) from public, anon;
grant execute on function public.admin_list_integrations(text, text, uuid, text, uuid, text, text, boolean, boolean, timestamptz, timestamptz, timestamptz, timestamptz, integer, timestamptz, uuid) to authenticated;

revoke all on function public.admin_get_integration(uuid) from public, anon;
grant execute on function public.admin_get_integration(uuid) to authenticated;

revoke all on function public.admin_get_integration_diagnostics(uuid) from public, anon;
grant execute on function public.admin_get_integration_diagnostics(uuid) to authenticated;

revoke all on function public.admin_integration_api_metrics(text, uuid, text) from public, anon;
grant execute on function public.admin_integration_api_metrics(text, uuid, text) to authenticated;

revoke all on function public.admin_list_integration_api_requests(uuid, uuid, uuid, text, text, integer, text, boolean, boolean, boolean, timestamptz, timestamptz, integer, timestamptz, uuid) from public, anon;
grant execute on function public.admin_list_integration_api_requests(uuid, uuid, uuid, text, text, integer, text, boolean, boolean, boolean, timestamptz, timestamptz, integer, timestamptz, uuid) to authenticated;

revoke all on function public.admin_webhook_metrics(text, uuid) from public, anon;
grant execute on function public.admin_webhook_metrics(text, uuid) to authenticated;

revoke all on function public.admin_list_webhook_endpoints(uuid, text, boolean, boolean, integer, timestamptz, uuid) from public, anon;
grant execute on function public.admin_list_webhook_endpoints(uuid, text, boolean, boolean, integer, timestamptz, uuid) to authenticated;

revoke all on function public.admin_list_webhook_deliveries(uuid, uuid, text, text, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid) from public, anon;
grant execute on function public.admin_list_webhook_deliveries(uuid, uuid, text, text, uuid, boolean, timestamptz, timestamptz, integer, timestamptz, uuid) to authenticated;

revoke all on function public.admin_suspend_integration(uuid, text) from public, anon;
grant execute on function public.admin_suspend_integration(uuid, text) to authenticated;

revoke all on function public.admin_reactivate_integration(uuid) from public, anon;
grant execute on function public.admin_reactivate_integration(uuid) to authenticated;

revoke all on function public.admin_revoke_integration_api_key(uuid, text) from public, anon;
grant execute on function public.admin_revoke_integration_api_key(uuid, text) to authenticated;

revoke all on function public.admin_set_webhook_endpoint_status(uuid, text, text) from public, anon;
grant execute on function public.admin_set_webhook_endpoint_status(uuid, text, text) to authenticated;

revoke all on function public.admin_list_integration_audit(uuid, text, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid) from public, anon;
grant execute on function public.admin_list_integration_audit(uuid, text, uuid, uuid, timestamptz, timestamptz, integer, timestamptz, uuid) to authenticated;

commit;

-- ===========================================================================
-- VERIFICATION
--
--   -- as a system admin (request.jwt.claims sub in system_admins):
--   select public.admin_list_integrations();
--   select public.admin_integration_api_metrics('24h', null, 'integration');
--   select public.admin_webhook_metrics('7d');
--   select public.admin_get_integration_diagnostics('<client uuid>');
--
--   -- authority: any non-admin caller must receive
--   --   ERROR: System Admin only (SQLSTATE 42501)
--
--   -- tests: sql/tests/179_integration_platform_admin_tests.sql
--   --        (rollback-only; expected output
--   --         'SQL 179 integration platform admin tests: ALL PASSED')
-- ===========================================================================

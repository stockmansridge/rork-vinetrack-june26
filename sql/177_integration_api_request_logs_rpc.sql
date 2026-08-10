-- =====================================================================
-- 177_integration_api_request_logs_rpc.sql
-- =====================================================================
-- Stage 4A backend patch: safe management read access to the API request
-- log (public.integration_api_requests) so the Lovable portal can show
-- an "API Logs" tab.
--
-- STRICTLY ADDITIVE:
--   * Does NOT alter anything created by SQL 172-176.
--   * Does NOT change the log WRITE path (integration_log_api_request),
--     gateway authentication, key validation, vineyard isolation or
--     rate limiting.
--   * Does NOT grant any direct table privilege — the table stays
--     RPC-only exactly as locked down in SQL 172.
--
-- Adds:
--   1. One composite keyset index for newest-first pagination.
--   2. public.integration_list_api_requests(...) — SECURITY DEFINER
--      management RPC using the EXISTING Stage 2 authority model:
--        * Authority = public._integration_can_view(actor, client):
--          account owner of the integration, OR platform admin
--          (is_system_admin()), OR Owner/Manager membership of a
--          vineyard with an ACTIVE grant to the integration.
--          Supervisors/Operators have no access. This is the same
--          authority already used by integration_audit_history — no
--          new role model is invented.
--        * Non-disclosing: an inaccessible or nonexistent client id
--          raises the SAME 'integration_not_found' error used by every
--          existing management RPC, so cross-account integration ids
--          cannot be probed.
--   Returned fields are safe metadata only (canonical path template,
--   status, duration, error code, key prefix/name, vineyard name).
--   The table stores no bodies/headers/hashes, and this RPC selects
--   nothing from integration_api_keys except prefix / name /
--   revoked_at — the key hash is never touched.
--
-- Pagination: keyset over (created_at DESC, id DESC) — the same
-- philosophy as the external API. Cursor = the (created_at, id) pair of
-- the last row of the previous page, passed back via
-- p_before_created_at + p_before_id (both or neither). Default limit
-- 100, maximum 1000; the RPC reads limit+1 rows to compute has_more.
--
-- Idempotent and production-safe. Apply via the Supabase SQL editor,
-- then run sql/tests/177_integration_api_request_logs_tests.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Keyset pagination index (additive; the existing
--    (integration_client_id, created_at desc) index remains).
-- ---------------------------------------------------------------------
create index if not exists idx_integration_api_requests_client_keyset
  on public.integration_api_requests (integration_client_id, created_at desc, id desc);

-- ---------------------------------------------------------------------
-- 2. Management RPC
-- ---------------------------------------------------------------------
create or replace function public.integration_list_api_requests(
  p_client_id uuid,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_status_code integer default null,
  p_vineyard_id uuid default null,
  p_api_key_id uuid default null,
  p_error_only boolean default false,
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
  v_actor uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 1000));
  v_rows jsonb;
  v_count integer;
  v_last_created timestamptz;
  v_last_id uuid;
begin
  if v_actor is null then
    raise exception 'not_authenticated';
  end if;

  -- Existing Stage 2 view authority; non-disclosing on refusal.
  if not public._integration_can_view(v_actor, p_client_id) then
    raise exception 'integration_not_found';
  end if;

  -- Input validation (no unrestricted arbitrary filtering).
  if p_status_code is not null and (p_status_code < 100 or p_status_code > 599) then
    raise exception 'invalid_status';
  end if;
  if p_from is not null and p_to is not null and p_from > p_to then
    raise exception 'invalid_range';
  end if;
  -- Keyset cursor halves must travel together.
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'invalid_cursor';
  end if;

  -- Page of limit+1 rows, newest first, deterministic keyset.
  with page as (
    select
      r.id,
      r.request_id,
      r.created_at,
      r.integration_client_id,
      r.api_key_id,
      r.vineyard_id,
      r.method,
      r.path,
      r.status_code,
      r.duration_ms,
      r.error_code
    from public.integration_api_requests r
    where r.integration_client_id = p_client_id
      and (p_from is null or r.created_at >= p_from)
      and (p_to is null or r.created_at <= p_to)
      and (p_status_code is null or r.status_code = p_status_code)
      and (p_vineyard_id is null or r.vineyard_id = p_vineyard_id)
      and (p_api_key_id is null or r.api_key_id = p_api_key_id)
      and (coalesce(p_error_only, false) = false or r.error_code is not null)
      and (
        p_before_created_at is null
        or (r.created_at, r.id) < (p_before_created_at, p_before_id)
      )
    order by r.created_at desc, r.id desc
    limit v_limit + 1
  ),
  trimmed as (
    select * from page
    order by created_at desc, id desc
    limit v_limit
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id,
      'request_id', t.request_id,
      'created_at', t.created_at,
      'integration_client_id', t.integration_client_id,
      'api_key_id', t.api_key_id,
      -- Safe key display metadata (prefix + label only; never the hash).
      -- Revoked keys stay resolvable for historical rows.
      'api_key_prefix', k.key_prefix,
      'api_key_name', k.name,
      'api_key_revoked_at', k.revoked_at,
      'vineyard_id', t.vineyard_id,
      'vineyard_name', v.name,
      'method', t.method,
      'path', t.path,          -- canonical template logged by SQL 173+
      'status_code', t.status_code,
      'duration_ms', t.duration_ms,
      'error_code', t.error_code
    ) order by t.created_at desc, t.id desc), '[]'::jsonb),
    count(*)
  into v_rows, v_count
  from trimmed t
  left join public.integration_api_keys k on k.id = t.api_key_id
  left join public.vineyards v on v.id = t.vineyard_id;

  -- Cursor for the next page = keyset of the last returned row.
  select t.created_at, t.id
  into v_last_created, v_last_id
  from (
    select r.created_at, r.id
    from public.integration_api_requests r
    where r.integration_client_id = p_client_id
      and (p_from is null or r.created_at >= p_from)
      and (p_to is null or r.created_at <= p_to)
      and (p_status_code is null or r.status_code = p_status_code)
      and (p_vineyard_id is null or r.vineyard_id = p_vineyard_id)
      and (p_api_key_id is null or r.api_key_id = p_api_key_id)
      and (coalesce(p_error_only, false) = false or r.error_code is not null)
      and (
        p_before_created_at is null
        or (r.created_at, r.id) < (p_before_created_at, p_before_id)
      )
    order by r.created_at desc, r.id desc
    limit v_limit
  ) t
  order by t.created_at asc, t.id asc
  limit 1;

  return jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object(
      'has_more', exists (
        select 1
        from public.integration_api_requests r
        where r.integration_client_id = p_client_id
          and (p_from is null or r.created_at >= p_from)
          and (p_to is null or r.created_at <= p_to)
          and (p_status_code is null or r.status_code = p_status_code)
          and (p_vineyard_id is null or r.vineyard_id = p_vineyard_id)
          and (p_api_key_id is null or r.api_key_id = p_api_key_id)
          and (coalesce(p_error_only, false) = false or r.error_code is not null)
          and v_last_created is not null
          and (r.created_at, r.id) < (v_last_created, v_last_id)
      ),
      'next_before_created_at', case when v_count >= v_limit then v_last_created end,
      'next_before_id', case when v_count >= v_limit then v_last_id end
    )
  );
end$$;

comment on function public.integration_list_api_requests(
  uuid, timestamptz, timestamptz, integer, uuid, uuid, boolean, integer, timestamptz, uuid
) is
  'Stage 4A portal RPC: safe, paginated read of integration_api_requests '
  'for callers with existing Stage 2 view authority '
  '(_integration_can_view: account owner, platform admin, or '
  'Owner/Manager of an actively granted vineyard). Non-disclosing '
  '(integration_not_found) for inaccessible ids. Returns only safe '
  'metadata: canonical path template, status, duration, error code, key '
  'prefix/name, vineyard name. Never the key hash, headers or bodies '
  '(none are stored). Keyset pagination created_at DESC, id DESC; '
  'default limit 100, max 1000.';

revoke all on function public.integration_list_api_requests(
  uuid, timestamptz, timestamptz, integer, uuid, uuid, boolean, integer, timestamptz, uuid
) from public, anon;
grant execute on function public.integration_list_api_requests(
  uuid, timestamptz, timestamptz, integer, uuid, uuid, boolean, integer, timestamptz, uuid
) to authenticated;

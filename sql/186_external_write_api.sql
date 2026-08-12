-- =============================================================================
-- 186: Stage 8 — Controlled External Write API
--
-- First production write surface for the VineTrack integration platform.
-- Contract doc: docs/vinetrack-developer-platform.md (§ Write API) and
-- docs/openapi/vinetrack-v1.yaml.
--
-- WRITE-ENABLED RESOURCES (canonical mobile tables, NO parallel API tables):
--   work_tasks               POST + PATCH   scope work_tasks:write
--   tractor_fuel_logs        POST + PATCH   scope fuel:write        (operational entry only — no cost fields)
--   irrigation_sessions      POST only      scope irrigation:write  (VineTrack calculation core reused; corrections stay in-app)
--   growth_stage_records     POST only      scope growth_stages:write (insert-only by design, sql/055 + 178)
--   historical_yield_records POST + PATCH   scope yield:write       (canonical camelCase block_results JSONB preserved)
--
-- EXPLICITLY NOT WRITE-ENABLED:
--   pins (placement is resolved on-device — sql/171 provides read-time
--   derivation only; no server resolver exists, so per the Stage 8 rule pins
--   stay read-only), fuel_purchases (purchasing/cost), work task labour
--   lines (payroll) & machine lines (cost + equipment identity), spray
--   records/programs, chemicals, pruning, vineyards/blocks/geometry,
--   team/users/billing/API keys/webhook config. NO DELETE routes.
--
-- PROVENANCE (additive, uniform across the five tables):
--   origin                             'vinetrack' | 'integration' (creator)
--   integration_client_id              creating integration (machine identity;
--                                      created_by stays NULL — never impersonate
--                                      the human integration owner)
--   integration_api_key_id             creating key
--   updated_by_integration_client_id   last external modifier
--   external_id                        integration-scoped reconciliation id,
--                                      unique per (integration, table) among
--                                      live rows; owned by the CREATING
--                                      integration — PATCH may set it only on
--                                      rows that integration created (no
--                                      cross-integration mapping hijack)
--
-- IDEMPOTENCY (durable, database-backed — survives function restarts):
--   Every public POST requires an Idempotency-Key header. Reservation row is
--   inserted in the SAME transaction as the canonical record; a concurrent
--   duplicate blocks on the unique index until the first commits, then
--   replays the stored response. Same key + different payload hash → 409
--   idempotency_conflict. Only a hash of the payload is stored alongside the
--   SAFE public response representation (never raw sensitive bodies).
--
-- CONCURRENCY: every PATCH requires expected_updated_at (the updated_at from
--   a prior GET). Mismatch → 409 conflict. External writes can never silently
--   overwrite a newer VineTrack/mobile edit.
--
-- EVENTS/WEBHOOKS: external writes hit the canonical tables, so the sql/178
--   outbox triggers fire exactly as for native writes (no parallel webhook
--   path). Trigger payloads gain additive origin/external_id fields for
--   receiver-side loop prevention. Signature formula, headers, retry policy
--   and api_version are UNCHANGED.
--
-- All write RPCs are SECURITY DEFINER, search_path=public, service_role only,
-- and re-run the FULL five-check validation (sql/172
-- integration_validate_api_request) internally — the gateway cannot bypass
-- scope/grant checks. RLS is not weakened anywhere.
-- =============================================================================

begin;

-- ===========================================================================
-- A. Activate the five write scopes (identifiers already reserved in sql/172;
--    no new identifiers are invented).
-- ===========================================================================
update public.integration_scope_catalog set description =
  'Create and update work tasks via POST /v1/work-tasks and PATCH /v1/work-tasks/{id} (operational fields only; labour and machine cost lines are not writable externally)'
  where scope = 'work_tasks:write';
update public.integration_scope_catalog set description =
  'Create and update operational fuel log entries via POST /v1/fuel-records and PATCH /v1/fuel-records/{id} (no cost or purchasing fields)'
  where scope = 'fuel:write';
update public.integration_scope_catalog set description =
  'Record irrigation sessions via POST /v1/irrigation-records (volumes, allocations and vintage are derived by VineTrack''s canonical calculation core; corrections remain in-app)'
  where scope = 'irrigation:write';
update public.integration_scope_catalog set description =
  'Record growth stage observations via POST /v1/growth-stages (create-only; supported E-L codes from the VineTrack catalogue)'
  where scope = 'growth_stages:write';
update public.integration_scope_catalog set description =
  'Create and update historical yield records via POST /v1/yield-records and PATCH /v1/yield-records/{id} (canonical per-block result shape)'
  where scope = 'yield:write';

-- ===========================================================================
-- B. Audit-log action catalogue — two new machine-write actions.
-- ===========================================================================
do $$
declare v_con text;
begin
  select conname into v_con
  from pg_constraint
  where conrelid = 'public.integration_audit_log'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%action%';
  if v_con is not null then
    execute format('alter table public.integration_audit_log drop constraint %I', v_con);
  end if;
end$$;

alter table public.integration_audit_log add constraint integration_audit_log_action_check
  check (action in (
    -- SQL 172 originals
    'integration.created', 'integration.updated',
    'integration.paused', 'integration.reactivated',
    'integration.revoked',
    'api_key.created', 'api_key.revoked', 'api_key.rotated',
    'vineyard_access.granted', 'vineyard_access.revoked',
    'scope.granted', 'scope.revoked',
    -- Stage 5A webhook actions (SQL 178/179 — must be preserved: live rows exist)
    'webhook_endpoint.created', 'webhook_endpoint.updated',
    'webhook_endpoint.paused', 'webhook_endpoint.reactivated',
    'webhook_endpoint.disabled', 'webhook_endpoint.deleted',
    'webhook_secret.rotated',
    'webhook_subscription.created', 'webhook_subscription.deleted',
    'webhook.test_sent', 'webhook.replayed',
    -- Stage 8: successful external API mutations (metadata carries
    -- resource_type / resource_id / changed_fields — never bodies/secrets)
    'api.write.created', 'api.write.updated'));

-- ===========================================================================
-- C. Uniform provenance columns on the five write-enabled tables.
-- ===========================================================================
do $$
declare t text;
begin
  foreach t in array array[
    'work_tasks', 'tractor_fuel_logs', 'irrigation_sessions',
    'growth_stage_records', 'historical_yield_records'
  ] loop
    execute format('alter table public.%I add column if not exists origin text not null default ''vinetrack''', t);
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_origin_check');
    execute format('alter table public.%I add constraint %I check (origin in (''vinetrack'', ''integration''))', t, t || '_origin_check');
    execute format('alter table public.%I add column if not exists integration_client_id uuid null references public.integration_clients(id) on delete set null', t);
    execute format('alter table public.%I add column if not exists integration_api_key_id uuid null references public.integration_api_keys(id) on delete set null', t);
    execute format('alter table public.%I add column if not exists updated_by_integration_client_id uuid null references public.integration_clients(id) on delete set null', t);
    execute format('alter table public.%I add column if not exists external_id text null', t);
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_external_id_len_check');
    execute format('alter table public.%I add constraint %I check (external_id is null or char_length(external_id) between 1 and 255)', t, t || '_external_id_len_check');
    -- Reconciliation index + per-integration uniqueness among live rows.
    execute format(
      'create unique index if not exists %I on public.%I (integration_client_id, external_id) where integration_client_id is not null and external_id is not null and deleted_at is null',
      'uq_' || t || '_integration_external_id', t);
    execute format('comment on column public.%I.origin is %L', t,
      'Creator origin: vinetrack (human app/portal) or integration (external write API). Machine-created rows keep created_by NULL — provenance lives in integration_client_id.');
    execute format('comment on column public.%I.external_id is %L', t,
      'Integration-supplied reconciliation id, scoped to the CREATING integration (unique per integration among live rows). Never replaces the VineTrack UUID.');
  end loop;
end$$;

-- Irrigation already has a provenance enum — external API writes use the
-- dedicated source value (existing convention, sql/125/142).
do $$
declare v_con text;
begin
  select conname into v_con
  from pg_constraint
  where conrelid = 'public.irrigation_sessions'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%source_type%';
  if v_con is not null then
    execute format('alter table public.irrigation_sessions drop constraint %I', v_con);
  end if;
end$$;

alter table public.irrigation_sessions add constraint irrigation_sessions_source_type_check
  check (source_type in ('manual_ios', 'manual_android', 'manual_portal',
                         'csv_import', 'controller_api', 'system_generated',
                         -- sql/142 controller import value — live rows exist
                         'galcon_gsi_import',
                         -- Stage 8 external write API
                         'external_api'));

-- Machine writes have no auth.uid(); the irrigation audit trail keeps full
-- old/new values while integration identity is recorded in
-- integration_audit_log. (Additive relaxation only.)
alter table public.irrigation_audit alter column user_id drop not null;

-- ===========================================================================
-- D. Durable idempotency store.
-- ===========================================================================
-- sql/172 shipped a placeholder version of this table (method/path columns,
-- explicitly documented "Unused in Stage 2" — no RPC or client ever had a
-- write path to it). Replace the placeholder with the Stage 8 shape. Guarded
-- on the missing `operation` column so re-runs never touch the real table,
-- and hard-stop if the placeholder unexpectedly holds data.
do $$
declare v_rows bigint;
begin
  if to_regclass('public.integration_idempotency_keys') is not null
     and not exists (
       select 1 from information_schema.columns
       where table_schema = 'public'
         and table_name = 'integration_idempotency_keys'
         and column_name = 'operation') then
    execute 'select count(*) from public.integration_idempotency_keys' into v_rows;
    if v_rows > 0 then
      raise exception 'integration_idempotency_keys placeholder unexpectedly has % rows — investigate before migrating', v_rows;
    end if;
    drop table public.integration_idempotency_keys;
  end if;
end$$;

create table if not exists public.integration_idempotency_keys (
  id                    uuid primary key default gen_random_uuid(),
  integration_client_id uuid not null references public.integration_clients(id) on delete cascade,
  operation             text not null,   -- canonical route, e.g. 'POST /v1/work-tasks'
  idempotency_key       text not null check (char_length(idempotency_key) between 1 and 255),
  request_hash          text not null,   -- one-way hash of the canonical payload (never the raw body)
  resource_type         text null,
  resource_id           uuid null,
  status_code           integer null,
  response_body         jsonb null,      -- the SAFE public representation returned to the caller
  created_at            timestamptz not null default now(),
  completed_at          timestamptz null
);

comment on table public.integration_idempotency_keys is
  'Durable POST idempotency. Reservation + canonical record commit in ONE transaction; concurrent duplicates serialise on the unique index. Same key + same payload hash replays the stored response; different hash is a 409 idempotency_conflict.';

create unique index if not exists uq_integration_idempotency
  on public.integration_idempotency_keys (integration_client_id, operation, idempotency_key);

alter table public.integration_idempotency_keys enable row level security;
revoke all on public.integration_idempotency_keys from public, anon, authenticated;
-- No policies: definer-RPC / service_role access only.

-- ===========================================================================
-- E. Small parse/validation helpers (pure; safe casts that never raise).
-- ===========================================================================
create or replace function public._integration_api_ts(p text)
returns timestamptz language plpgsql immutable as $$
begin
  return p::timestamptz;
exception when others then
  return null;
end$$;

create or replace function public._integration_api_date(p text)
returns date language plpgsql immutable as $$
begin
  return p::date;
exception when others then
  return null;
end$$;

create or replace function public._integration_api_uuid(p text)
returns uuid language plpgsql immutable as $$
begin
  return p::uuid;
exception when others then
  return null;
end$$;

-- Payload fingerprint: reuses the platform's canonical one-way hash
-- convention (sql/172). Raw bodies are never persisted.
create or replace function public._integration_api_hash(p jsonb)
returns text language sql immutable
as $$ select public._integration_hash_secret(coalesce(p, '{}'::jsonb)::text) $$;

-- Unknown-key rejection (allowlist model — matches the read API's strict
-- query-parameter policy).
create or replace function public._integration_api_unknown_keys(p_payload jsonb, p_allowed text[])
returns jsonb language sql immutable
as $$
  select coalesce(jsonb_agg(jsonb_build_object('field', k, 'issue', 'unknown field')), '[]'::jsonb)
  from jsonb_object_keys(coalesce(p_payload, '{}'::jsonb)) k
  where k <> all (p_allowed);
$$;

-- The supported E-L growth-stage catalogue — byte-identical to the mobile
-- catalogue (ios GrowthStage.swift / Android equivalent). Returns the label
-- for a supported code, NULL for anything else.
create or replace function public._integration_api_el_stage_label(p_code text)
returns text language sql immutable
as $$
  select case upper(btrim(coalesce(p_code, '')))
    when 'EL1'  then 'Winter bud'
    when 'EL2'  then 'Bud scales opening'
    when 'EL3'  then 'Wooly Bud ± green showing'
    when 'EL4'  then 'Budburst; leaf tips visible'
    when 'EL7'  then 'First leaf separated from shoot tip'
    when 'EL9'  then '2 to 3 leaves separated; shoots 2-4 cm long'
    when 'EL11' then '4 leaves separated'
    when 'EL12' then '5 leaves separated; shoots about 10 cm long; inflorescence clear'
    when 'EL13' then '6 leaves separated'
    when 'EL14' then '7 leaves separated'
    when 'EL15' then '8 leaves separated, shoot elongating rapidly; single flowers in compact groups'
    when 'EL16' then '10 leaves separated'
    when 'EL17' then '12 leaves separated; inflorescence well developed, single flowers separated'
    when 'EL18' then '14 leaves separate and flower caps still in place, but cap colour fading from green'
    when 'EL19' then 'About 16 leaves separated; beginning of flowering (first flower caps loosening)'
    when 'EL20' then '10% caps off'
    when 'EL21' then '30% caps off'
    when 'EL23' then '17-20 leaves separated; 50% caps off (= flowering)'
    when 'EL25' then '80% caps off'
    when 'EL26' then 'Cap-fall complete'
    when 'EL27' then 'Setting; young berries enlarging (>2 mm diam.), bunch at right angles to stem'
    when 'EL29' then 'Berries pepper-corn size (4 mm diam.); bunches tending downwards'
    when 'EL31' then 'Berries pea-size (7 mm diam.) (if bunches are tight)'
    when 'EL32' then 'Beginning of bunch closure, berries touching (if bunches are tight)'
    when 'EL33' then 'Berries still hard and green'
    when 'EL34' then 'Berries begins to soft; Sugar starts increasing'
    when 'EL35' then 'Berries begin to colour and enlarge'
    when 'EL36' then 'Berries with intermediate sugar values'
    when 'EL37' then 'Berries not quite ripe'
    when 'EL38' then 'Berries harvest-ripe'
    when 'EL39' then 'Berries over-ripe'
    when 'EL41' then 'After harvest; cane maturation complete'
    when 'EL43' then 'Begin of leaf fall'
    when 'EL47' then 'End of leaf fall'
    else null
  end;
$$;

-- ===========================================================================
-- F. Idempotency engine.
-- ===========================================================================
-- Reserve the (integration, operation, key) slot. Returns:
--   {'mode':'proceed','id':<reservation uuid>}      first time
--   {'mode':'replay','status':n,'response':{...}}   duplicate, same payload
--   {'mode':'conflict'}                             duplicate, different payload
-- Called INSIDE the write transaction: a concurrent duplicate blocks on the
-- unique index until this transaction commits/aborts, then resolves safely.
create or replace function public._integration_api_idem_begin(
  p_client_id uuid,
  p_operation text,
  p_key text,
  p_request_hash text
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_row public.integration_idempotency_keys;
begin
  insert into public.integration_idempotency_keys
    (integration_client_id, operation, idempotency_key, request_hash)
  values (p_client_id, p_operation, p_key, p_request_hash)
  on conflict (integration_client_id, operation, idempotency_key) do nothing
  returning id into v_id;

  if v_id is not null then
    return jsonb_build_object('mode', 'proceed', 'id', v_id);
  end if;

  select * into v_row
  from public.integration_idempotency_keys
  where integration_client_id = p_client_id
    and operation = p_operation
    and idempotency_key = p_key;

  if v_row.request_hash = p_request_hash and v_row.response_body is not null then
    return jsonb_build_object('mode', 'replay',
      'status', coalesce(v_row.status_code, 200),
      'response', v_row.response_body);
  end if;
  -- Different material payload with the same key — or (defensively) a
  -- reservation that never completed: both are conflicts, never duplicates.
  return jsonb_build_object('mode', 'conflict');
end$$;

create or replace function public._integration_api_idem_store(
  p_reservation_id uuid,
  p_resource_type text,
  p_resource_id uuid,
  p_status integer,
  p_response jsonb
) returns void
language sql
volatile
security definer
set search_path = public
as $$
  update public.integration_idempotency_keys
     set resource_type = p_resource_type,
         resource_id   = p_resource_id,
         status_code   = p_status,
         response_body = p_response,
         completed_at  = now()
   where id = p_reservation_id;
$$;

-- ===========================================================================
-- G. Public representation builders — byte-compatible with the gateway's GET
--    mappers so a create/update response equals a follow-up GET (base
--    representation; sensitive-scope fields are additive on GET only).
-- ===========================================================================
create or replace function public._integration_api_work_task_json(p_id uuid)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'id', w.id,
    'vineyard_id', w.vineyard_id,
    'task_type', nullif(btrim(w.task_type), ''),
    'status', w.status,
    'date', w.date,
    'start_date', w.start_date,
    'end_date', w.end_date,
    'duration_hours', w.duration_hours,
    'area_ha', w.area_ha,
    'blocks', coalesce((
      select jsonb_agg(jsonb_build_object('block_id', p.id, 'name', p.name) order by p.name)
      from public.work_task_paddocks tp
      join public.paddocks p on p.id = tp.paddock_id and p.vineyard_id = w.vineyard_id
      where tp.work_task_id = w.id and tp.deleted_at is null
    ), '[]'::jsonb),
    'description', w.description,
    'notes', nullif(btrim(w.notes), ''),
    'is_archived', w.is_archived,
    'is_finalized', w.is_finalized,
    'origin', w.origin,
    'external_id', w.external_id,
    'created_at', w.created_at,
    'updated_at', w.updated_at)
  from public.work_tasks w
  where w.id = p_id;
$$;

create or replace function public._integration_api_fuel_record_json(p_id uuid)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'id', f.id,
    'vineyard_id', f.vineyard_id,
    'date', f.fill_datetime,
    'equipment_id', m.id,
    'equipment_name', nullif(btrim(coalesce(m.name, '')), ''),
    'volume_l', f.litres_added,
    'engine_hours', f.engine_hours,
    'filled_to_full', f.filled_to_full,
    'notes', f.notes,
    'origin', f.origin,
    'external_id', f.external_id,
    'created_at', f.created_at,
    'updated_at', f.updated_at)
  from public.tractor_fuel_logs f
  left join public.vineyard_machines m on m.id = f.machine_id
  where f.id = p_id;
$$;

create or replace function public._integration_api_irrigation_json(p_id uuid)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'id', s.id,
    'vineyard_id', s.vineyard_id,
    'date', s.session_date,
    'vintage_year', s.vintage_year,
    'status', s.status,
    'started_at', s.started_at,
    'ended_at', s.finished_at,
    'duration_minutes', s.duration_minutes,
    'calculation_method', s.calculation_method,
    'source_type', s.source_type,
    'flow_l_per_hour', s.flow_litres_per_hour,
    'volume_l', s.total_volume_litres,
    'effective_volume_l', s.effective_volume_litres,
    'efficiency_percent', s.irrigation_efficiency_percent,
    'irrigation_system_id', s.irrigation_system_id,
    'valve_id', s.valve_id,
    'blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'block_id', b.block_id,
        'block_name', p.name,
        'allocation_percent', b.allocation_percentage,
        'volume_l', b.allocated_volume_litres,
        'effective_volume_l', b.effective_volume_litres,
        'area_ha', case when b.serviced_area_m2 is not null then round((b.serviced_area_m2 / 10000.0)::numeric, 4) end,
        'vine_count', b.serviced_vine_count,
        'water_l_per_vine', b.water_litres_per_vine,
        'water_l_per_ha', b.water_litres_per_hectare,
        'depth_mm', b.irrigation_depth_mm,
        'effective_depth_mm', b.effective_irrigation_depth_mm))
      from public.irrigation_session_blocks b
      left join public.paddocks p on p.id = b.block_id
      where b.session_id = s.id
    ), '[]'::jsonb),
    'notes', nullif(btrim(coalesce(s.notes, '')), ''),
    'origin', s.origin,
    'external_id', s.external_id,
    'created_at', s.created_at,
    'updated_at', s.updated_at)
  from public.irrigation_sessions s
  where s.id = p_id;
$$;

create or replace function public._integration_api_growth_stage_json(p_id uuid)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'id', g.id,
    'vineyard_id', g.vineyard_id,
    'block_id', g.paddock_id,
    'block_name', p.name,
    'observed_at', g.observed_at,
    'stage_code', g.stage_code,
    'stage_label', g.stage_label,
    'variety', g.variety,
    'variety_id', g.variety_id,
    'row_number', g.row_number,
    'side', case when g.side is not null then lower(g.side) end,
    'latitude', g.latitude,
    'longitude', g.longitude,
    'notes', nullif(btrim(coalesce(g.notes, '')), ''),
    'origin', g.origin,
    'external_id', g.external_id,
    'created_at', g.created_at,
    'updated_at', g.updated_at)
  from public.growth_stage_records g
  left join public.paddocks p on p.id = g.paddock_id
  where g.id = p_id;
$$;

create or replace function public._integration_api_yield_record_json(p_id uuid)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'id', y.id,
    'vineyard_id', y.vineyard_id,
    'season', nullif(btrim(y.season), ''),
    'vintage_year', case when y.year > 0 then y.year end,
    'archived_at', y.archived_at,
    'total_yield_tonnes', y.total_yield_tonnes,
    'total_area_ha', y.total_area_hectares,
    'yield_tonnes_per_ha', case when y.total_area_hectares > 0
      then round((y.total_yield_tonnes / y.total_area_hectares)::numeric, 3) end,
    'blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'block_id', lower(b->>'paddockId'),
        'block_name', b->>'paddockName',
        'area_ha', (b->>'areaHectares')::numeric,
        'estimated_yield_tonnes', (b->>'yieldTonnes')::numeric,
        'yield_tonnes_per_ha', (b->>'yieldPerHectare')::numeric,
        'average_bunches_per_vine', (b->>'averageBunchesPerVine')::numeric,
        'average_bunch_weight_g', (b->>'averageBunchWeightGrams')::numeric,
        'vine_count', (b->>'totalVines')::numeric,
        'samples_recorded', (b->>'samplesRecorded')::numeric,
        'damage_factor', (b->>'damageFactor')::numeric,
        'actual_yield_tonnes', (b->>'actualYieldTonnes')::numeric,
        'actual_recorded_at', b->>'actualRecordedAt'))
      from jsonb_array_elements(coalesce(y.block_results, '[]'::jsonb)) b
    ), '[]'::jsonb),
    'notes', nullif(btrim(y.notes), ''),
    'origin', y.origin,
    'external_id', y.external_id,
    'created_at', y.created_at,
    'updated_at', y.updated_at)
  from public.historical_yield_records y
  where y.id = p_id;
$$;

-- ===========================================================================
-- H. WORK TASKS — POST /v1/work-tasks, PATCH /v1/work-tasks/{id}
-- ===========================================================================
create or replace function public.integration_api_create_work_task(
  p_presented_key text,
  p_vineyard_id uuid,
  p_idempotency_key text,
  p_payload jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_auth jsonb;
  v_client uuid; v_key uuid;
  v_errors jsonb := '[]'::jsonb;
  v_idem jsonb; v_idem_id uuid;
  v_id uuid := gen_random_uuid();
  v_task_type text; v_date timestamptz; v_desc text; v_status text;
  v_notes text; v_start timestamptz; v_end timestamptz;
  v_duration double precision := 0;
  v_block_ids uuid[] := '{}'; v_first_block uuid; v_first_name text;
  v_external_id text;
  v_bid text; v_u uuid;
  v_data jsonb;
begin
  v_auth := public.integration_validate_api_request(p_presented_key, 'work_tasks:write', p_vineyard_id);
  if not coalesce((v_auth->>'valid')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', v_auth->>'failure_code');
  end if;
  v_client := (v_auth->>'integration_client_id')::uuid;
  v_key := (v_auth->>'api_key_id')::uuid;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_required');
  end if;
  if char_length(p_idempotency_key) > 255 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
      'details', jsonb_build_array(jsonb_build_object('field', 'Idempotency-Key', 'issue', 'must be 1-255 characters')));
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  v_errors := public._integration_api_unknown_keys(p_payload, array[
    'task_type', 'date', 'description', 'status', 'notes',
    'start_date', 'end_date', 'duration_hours', 'block_ids', 'external_id']);

  -- task_type: required, 1-100 chars
  if jsonb_typeof(p_payload->'task_type') is distinct from 'string'
     or btrim(p_payload->>'task_type') = '' or char_length(p_payload->>'task_type') > 100 then
    v_errors := v_errors || jsonb_build_object('field', 'task_type', 'issue', 'required string, 1-100 characters');
  else
    v_task_type := btrim(p_payload->>'task_type');
  end if;

  -- date: required ISO timestamp
  if jsonb_typeof(p_payload->'date') is distinct from 'string'
     or public._integration_api_ts(p_payload->>'date') is null then
    v_errors := v_errors || jsonb_build_object('field', 'date', 'issue', 'required ISO 8601 timestamp');
  else
    v_date := public._integration_api_ts(p_payload->>'date');
  end if;

  if p_payload ? 'description' and jsonb_typeof(p_payload->'description') <> 'null' then
    if jsonb_typeof(p_payload->'description') <> 'string' or char_length(p_payload->>'description') > 2000 then
      v_errors := v_errors || jsonb_build_object('field', 'description', 'issue', 'string up to 2000 characters');
    else v_desc := p_payload->>'description'; end if;
  end if;

  if p_payload ? 'status' and jsonb_typeof(p_payload->'status') <> 'null' then
    if jsonb_typeof(p_payload->'status') <> 'string' or char_length(p_payload->>'status') > 50 then
      v_errors := v_errors || jsonb_build_object('field', 'status', 'issue', 'string up to 50 characters');
    else v_status := p_payload->>'status'; end if;
  end if;

  if p_payload ? 'notes' and jsonb_typeof(p_payload->'notes') <> 'null' then
    if jsonb_typeof(p_payload->'notes') <> 'string' or char_length(p_payload->>'notes') > 4000 then
      v_errors := v_errors || jsonb_build_object('field', 'notes', 'issue', 'string up to 4000 characters');
    else v_notes := p_payload->>'notes'; end if;
  end if;

  if p_payload ? 'start_date' and jsonb_typeof(p_payload->'start_date') <> 'null' then
    if jsonb_typeof(p_payload->'start_date') <> 'string' or public._integration_api_ts(p_payload->>'start_date') is null then
      v_errors := v_errors || jsonb_build_object('field', 'start_date', 'issue', 'ISO 8601 timestamp');
    else v_start := public._integration_api_ts(p_payload->>'start_date'); end if;
  end if;

  if p_payload ? 'end_date' and jsonb_typeof(p_payload->'end_date') <> 'null' then
    if jsonb_typeof(p_payload->'end_date') <> 'string' or public._integration_api_ts(p_payload->>'end_date') is null then
      v_errors := v_errors || jsonb_build_object('field', 'end_date', 'issue', 'ISO 8601 timestamp');
    else v_end := public._integration_api_ts(p_payload->>'end_date'); end if;
  end if;
  if v_start is not null and v_end is not null and v_end < v_start then
    v_errors := v_errors || jsonb_build_object('field', 'end_date', 'issue', 'must not be before start_date');
  end if;

  if p_payload ? 'duration_hours' and jsonb_typeof(p_payload->'duration_hours') <> 'null' then
    if jsonb_typeof(p_payload->'duration_hours') <> 'number' or (p_payload->>'duration_hours')::numeric < 0 then
      v_errors := v_errors || jsonb_build_object('field', 'duration_hours', 'issue', 'non-negative number');
    else v_duration := (p_payload->>'duration_hours')::double precision; end if;
  end if;

  if p_payload ? 'block_ids' and jsonb_typeof(p_payload->'block_ids') <> 'null' then
    if jsonb_typeof(p_payload->'block_ids') <> 'array' then
      v_errors := v_errors || jsonb_build_object('field', 'block_ids', 'issue', 'array of block UUIDs');
    else
      for v_bid in select value #>> '{}' from jsonb_array_elements(p_payload->'block_ids') loop
        v_u := public._integration_api_uuid(v_bid);
        if v_u is null then
          v_errors := v_errors || jsonb_build_object('field', 'block_ids', 'issue', 'contains an invalid UUID');
        elsif not exists (select 1 from public.paddocks p
                          where p.id = v_u and p.vineyard_id = p_vineyard_id and p.deleted_at is null) then
          -- Cross-vineyard substitution fails without revealing anything.
          v_errors := v_errors || jsonb_build_object('field', 'block_ids', 'issue', 'block ' || v_bid || ' does not exist in this vineyard');
        elsif not (v_u = any (v_block_ids)) then
          v_block_ids := v_block_ids || v_u;
        end if;
      end loop;
    end if;
  end if;

  if p_payload ? 'external_id' and jsonb_typeof(p_payload->'external_id') <> 'null' then
    if jsonb_typeof(p_payload->'external_id') <> 'string'
       or char_length(p_payload->>'external_id') not between 1 and 255 then
      v_errors := v_errors || jsonb_build_object('field', 'external_id', 'issue', 'string, 1-255 characters');
    else v_external_id := p_payload->>'external_id'; end if;
  end if;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed', 'details', v_errors);
  end if;

  v_idem := public._integration_api_idem_begin(v_client, 'POST /v1/work-tasks', p_idempotency_key,
              public._integration_api_hash(p_payload || jsonb_build_object('vineyard_id', p_vineyard_id)));
  if v_idem->>'mode' = 'replay' then
    return jsonb_build_object('ok', true, 'status', (v_idem->>'status')::int, 'replayed', true, 'data', v_idem->'response');
  elsif v_idem->>'mode' = 'conflict' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_conflict');
  end if;
  v_idem_id := (v_idem->>'id')::uuid;

  if array_length(v_block_ids, 1) > 0 then
    v_first_block := v_block_ids[1];
    select name into v_first_name from public.paddocks where id = v_first_block;
  end if;

  begin
    insert into public.work_tasks (
      id, vineyard_id, paddock_id, paddock_name, date, task_type,
      duration_hours, notes, description, status, start_date, end_date,
      origin, integration_client_id, integration_api_key_id, external_id,
      client_updated_at
    ) values (
      v_id, p_vineyard_id, v_first_block, coalesce(v_first_name, ''), v_date, v_task_type,
      v_duration, coalesce(v_notes, ''), v_desc, v_status, v_start, v_end,
      'integration', v_client, v_key, v_external_id,
      now()
    );
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another work task')));
  end;

  insert into public.work_task_paddocks (work_task_id, vineyard_id, paddock_id, client_updated_at)
  select v_id, p_vineyard_id, b, now() from unnest(v_block_ids) b;

  perform public._integration_audit(v_client, 'api.write.created', p_vineyard_id,
    jsonb_build_object('resource_type', 'work_task', 'resource_id', v_id,
      'external_id', v_external_id, 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_work_task_json(v_id);
  perform public._integration_api_idem_store(v_idem_id, 'work_task', v_id, 201, v_data);
  return jsonb_build_object('ok', true, 'status', 201, 'replayed', false, 'data', v_data);
end$$;

create or replace function public.integration_api_update_work_task(
  p_presented_key text,
  p_work_task_id uuid,
  p_payload jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_row public.work_tasks;
  v_auth jsonb; v_client uuid; v_key uuid;
  v_errors jsonb := '[]'::jsonb;
  v_expected timestamptz;
  v_changed text[] := '{}';
  v_block_ids uuid[]; v_first_block uuid; v_first_name text;
  v_bid text; v_u uuid;
  k text;
  v_data jsonb;
begin
  if p_work_task_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  select * into v_row from public.work_tasks where id = p_work_task_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'resource_not_found');
  end if;

  v_auth := public.integration_validate_api_request(p_presented_key, 'work_tasks:write', v_row.vineyard_id);
  if not coalesce((v_auth->>'valid')::boolean, false) then
    -- Anti-enumeration: an ungranted vineyard is indistinguishable from a
    -- missing resource.
    if v_auth->>'failure_code' = 'vineyard_not_granted' then
      return jsonb_build_object('ok', false, 'error', 'resource_not_found');
    end if;
    return jsonb_build_object('ok', false, 'error', v_auth->>'failure_code');
  end if;
  v_client := (v_auth->>'integration_client_id')::uuid;
  v_key := (v_auth->>'api_key_id')::uuid;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  v_errors := public._integration_api_unknown_keys(p_payload, array[
    'expected_updated_at', 'task_type', 'date', 'description', 'status', 'notes',
    'start_date', 'end_date', 'duration_hours', 'block_ids', 'external_id']);

  -- Optimistic concurrency is REQUIRED on every PATCH.
  if jsonb_typeof(p_payload->'expected_updated_at') is distinct from 'string'
     or public._integration_api_ts(p_payload->>'expected_updated_at') is null then
    v_errors := v_errors || jsonb_build_object('field', 'expected_updated_at', 'issue', 'required ISO 8601 timestamp (the updated_at from your latest GET)');
  else
    v_expected := public._integration_api_ts(p_payload->>'expected_updated_at');
  end if;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed', 'details', v_errors);
  end if;

  if v_expected is distinct from v_row.updated_at then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'expected_updated_at', 'issue', 'the record has been modified since it was last read')));
  end if;

  if v_row.is_finalized or v_row.is_archived then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'id', 'issue', 'finalised or archived work tasks cannot be modified')));
  end if;

  -- Field-by-field partial update. Omitted = unchanged; null clears only
  -- explicitly nullable fields.
  for k in select jsonb_object_keys(p_payload) loop
    if k = 'expected_updated_at' then continue; end if;
    v_changed := v_changed || k;
    case k
      when 'task_type' then
        if jsonb_typeof(p_payload->'task_type') = 'null' then
          v_row.task_type := '';
        elsif jsonb_typeof(p_payload->'task_type') <> 'string' or btrim(p_payload->>'task_type') = '' or char_length(p_payload->>'task_type') > 100 then
          v_errors := v_errors || jsonb_build_object('field', 'task_type', 'issue', 'string, 1-100 characters');
        else v_row.task_type := btrim(p_payload->>'task_type'); end if;
      when 'date' then
        if jsonb_typeof(p_payload->'date') <> 'string' or public._integration_api_ts(p_payload->>'date') is null then
          v_errors := v_errors || jsonb_build_object('field', 'date', 'issue', 'ISO 8601 timestamp (not nullable)');
        else v_row.date := public._integration_api_ts(p_payload->>'date'); end if;
      when 'description' then
        if jsonb_typeof(p_payload->'description') = 'null' then v_row.description := null;
        elsif jsonb_typeof(p_payload->'description') <> 'string' or char_length(p_payload->>'description') > 2000 then
          v_errors := v_errors || jsonb_build_object('field', 'description', 'issue', 'string up to 2000 characters, or null to clear');
        else v_row.description := p_payload->>'description'; end if;
      when 'status' then
        if jsonb_typeof(p_payload->'status') = 'null' then v_row.status := null;
        elsif jsonb_typeof(p_payload->'status') <> 'string' or char_length(p_payload->>'status') > 50 then
          v_errors := v_errors || jsonb_build_object('field', 'status', 'issue', 'string up to 50 characters, or null to clear');
        else v_row.status := p_payload->>'status'; end if;
      when 'notes' then
        if jsonb_typeof(p_payload->'notes') = 'null' then v_row.notes := '';
        elsif jsonb_typeof(p_payload->'notes') <> 'string' or char_length(p_payload->>'notes') > 4000 then
          v_errors := v_errors || jsonb_build_object('field', 'notes', 'issue', 'string up to 4000 characters, or null to clear');
        else v_row.notes := p_payload->>'notes'; end if;
      when 'start_date' then
        if jsonb_typeof(p_payload->'start_date') = 'null' then v_row.start_date := null;
        elsif jsonb_typeof(p_payload->'start_date') <> 'string' or public._integration_api_ts(p_payload->>'start_date') is null then
          v_errors := v_errors || jsonb_build_object('field', 'start_date', 'issue', 'ISO 8601 timestamp, or null to clear');
        else v_row.start_date := public._integration_api_ts(p_payload->>'start_date'); end if;
      when 'end_date' then
        if jsonb_typeof(p_payload->'end_date') = 'null' then v_row.end_date := null;
        elsif jsonb_typeof(p_payload->'end_date') <> 'string' or public._integration_api_ts(p_payload->>'end_date') is null then
          v_errors := v_errors || jsonb_build_object('field', 'end_date', 'issue', 'ISO 8601 timestamp, or null to clear');
        else v_row.end_date := public._integration_api_ts(p_payload->>'end_date'); end if;
      when 'duration_hours' then
        if jsonb_typeof(p_payload->'duration_hours') = 'null' then v_row.duration_hours := 0;
        elsif jsonb_typeof(p_payload->'duration_hours') <> 'number' or (p_payload->>'duration_hours')::numeric < 0 then
          v_errors := v_errors || jsonb_build_object('field', 'duration_hours', 'issue', 'non-negative number');
        else v_row.duration_hours := (p_payload->>'duration_hours')::double precision; end if;
      when 'block_ids' then
        if jsonb_typeof(p_payload->'block_ids') = 'null' then
          v_block_ids := '{}';
        elsif jsonb_typeof(p_payload->'block_ids') <> 'array' then
          v_errors := v_errors || jsonb_build_object('field', 'block_ids', 'issue', 'array of block UUIDs, or null to clear');
        else
          v_block_ids := '{}';
          for v_bid in select value #>> '{}' from jsonb_array_elements(p_payload->'block_ids') loop
            v_u := public._integration_api_uuid(v_bid);
            if v_u is null then
              v_errors := v_errors || jsonb_build_object('field', 'block_ids', 'issue', 'contains an invalid UUID');
            elsif not exists (select 1 from public.paddocks p
                              where p.id = v_u and p.vineyard_id = v_row.vineyard_id and p.deleted_at is null) then
              v_errors := v_errors || jsonb_build_object('field', 'block_ids', 'issue', 'block ' || v_bid || ' does not exist in this vineyard');
            elsif not (v_u = any (v_block_ids)) then
              v_block_ids := v_block_ids || v_u;
            end if;
          end loop;
        end if;
      when 'external_id' then
        if v_row.integration_client_id is distinct from v_client then
          v_errors := v_errors || jsonb_build_object('field', 'external_id', 'issue', 'can only be set by the integration that created this record');
        elsif jsonb_typeof(p_payload->'external_id') = 'null' then v_row.external_id := null;
        elsif jsonb_typeof(p_payload->'external_id') <> 'string' or char_length(p_payload->>'external_id') not between 1 and 255 then
          v_errors := v_errors || jsonb_build_object('field', 'external_id', 'issue', 'string, 1-255 characters, or null to clear');
        else v_row.external_id := p_payload->>'external_id'; end if;
      else
        null; -- unknown keys already rejected
    end case;
  end loop;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed', 'details', v_errors);
  end if;
  if v_row.start_date is not null and v_row.end_date is not null and v_row.end_date < v_row.start_date then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
      'details', jsonb_build_array(jsonb_build_object('field', 'end_date', 'issue', 'must not be before start_date')));
  end if;

  if v_block_ids is not null then
    -- Full replacement of the active block set.
    update public.work_task_paddocks
       set deleted_at = now(), sync_version = sync_version + 1
     where work_task_id = v_row.id and deleted_at is null
       and not (paddock_id = any (v_block_ids));
    insert into public.work_task_paddocks (work_task_id, vineyard_id, paddock_id, client_updated_at)
    select v_row.id, v_row.vineyard_id, b, now() from unnest(v_block_ids) b
    where not exists (select 1 from public.work_task_paddocks tp
                      where tp.work_task_id = v_row.id and tp.paddock_id = b and tp.deleted_at is null);
    if array_length(v_block_ids, 1) > 0 then
      v_first_block := v_block_ids[1];
      select name into v_first_name from public.paddocks where id = v_first_block;
    end if;
    v_row.paddock_id := v_first_block;
    v_row.paddock_name := coalesce(v_first_name, '');
  end if;

  begin
    update public.work_tasks set
      task_type = v_row.task_type, date = v_row.date, description = v_row.description,
      status = v_row.status, notes = v_row.notes, start_date = v_row.start_date,
      end_date = v_row.end_date, duration_hours = v_row.duration_hours,
      paddock_id = v_row.paddock_id, paddock_name = v_row.paddock_name,
      external_id = v_row.external_id,
      updated_by = null,
      updated_by_integration_client_id = v_client,
      client_updated_at = now(),
      sync_version = sync_version + 1
    where id = v_row.id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another work task')));
  end;

  perform public._integration_audit(v_client, 'api.write.updated', v_row.vineyard_id,
    jsonb_build_object('resource_type', 'work_task', 'resource_id', v_row.id,
      'changed_fields', to_jsonb(v_changed), 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_work_task_json(v_row.id);
  return jsonb_build_object('ok', true, 'status', 200, 'data', v_data);
end$$;

-- ===========================================================================
-- I. FUEL RECORDS — POST /v1/fuel-records, PATCH /v1/fuel-records/{id}
--    Operational entry only: no cost, purchasing or operator identity fields.
-- ===========================================================================
create or replace function public.integration_api_create_fuel_record(
  p_presented_key text,
  p_vineyard_id uuid,
  p_idempotency_key text,
  p_payload jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_auth jsonb; v_client uuid; v_key uuid;
  v_errors jsonb := '[]'::jsonb;
  v_idem jsonb; v_idem_id uuid;
  v_id uuid := gen_random_uuid();
  v_date timestamptz; v_volume double precision; v_machine uuid;
  v_engine double precision; v_full boolean; v_notes text; v_external_id text;
  v_data jsonb;
begin
  v_auth := public.integration_validate_api_request(p_presented_key, 'fuel:write', p_vineyard_id);
  if not coalesce((v_auth->>'valid')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', v_auth->>'failure_code');
  end if;
  v_client := (v_auth->>'integration_client_id')::uuid;
  v_key := (v_auth->>'api_key_id')::uuid;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_required');
  end if;
  if char_length(p_idempotency_key) > 255 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
      'details', jsonb_build_array(jsonb_build_object('field', 'Idempotency-Key', 'issue', 'must be 1-255 characters')));
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  v_errors := public._integration_api_unknown_keys(p_payload, array[
    'date', 'volume_l', 'equipment_id', 'engine_hours', 'filled_to_full', 'notes', 'external_id']);

  if jsonb_typeof(p_payload->'date') is distinct from 'string'
     or public._integration_api_ts(p_payload->>'date') is null then
    v_errors := v_errors || jsonb_build_object('field', 'date', 'issue', 'required ISO 8601 timestamp');
  else
    v_date := public._integration_api_ts(p_payload->>'date');
    if v_date > now() + interval '24 hours' then
      v_errors := v_errors || jsonb_build_object('field', 'date', 'issue', 'must not be in the future');
    end if;
  end if;

  if jsonb_typeof(p_payload->'volume_l') is distinct from 'number'
     or (p_payload->>'volume_l')::numeric <= 0 then
    v_errors := v_errors || jsonb_build_object('field', 'volume_l', 'issue', 'required number greater than 0');
  else
    v_volume := (p_payload->>'volume_l')::double precision;
  end if;

  if p_payload ? 'equipment_id' and jsonb_typeof(p_payload->'equipment_id') <> 'null' then
    if jsonb_typeof(p_payload->'equipment_id') <> 'string'
       or public._integration_api_uuid(p_payload->>'equipment_id') is null then
      v_errors := v_errors || jsonb_build_object('field', 'equipment_id', 'issue', 'equipment UUID');
    else
      v_machine := public._integration_api_uuid(p_payload->>'equipment_id');
      if not exists (select 1 from public.vineyard_machines m
                     where m.id = v_machine and m.vineyard_id = p_vineyard_id and m.deleted_at is null) then
        v_errors := v_errors || jsonb_build_object('field', 'equipment_id', 'issue', 'equipment does not exist in this vineyard');
        v_machine := null;
      end if;
    end if;
  end if;

  if p_payload ? 'engine_hours' and jsonb_typeof(p_payload->'engine_hours') <> 'null' then
    if jsonb_typeof(p_payload->'engine_hours') <> 'number' or (p_payload->>'engine_hours')::numeric < 0 then
      v_errors := v_errors || jsonb_build_object('field', 'engine_hours', 'issue', 'non-negative number');
    else v_engine := (p_payload->>'engine_hours')::double precision; end if;
  end if;

  if p_payload ? 'filled_to_full' and jsonb_typeof(p_payload->'filled_to_full') <> 'null' then
    if jsonb_typeof(p_payload->'filled_to_full') <> 'boolean' then
      v_errors := v_errors || jsonb_build_object('field', 'filled_to_full', 'issue', 'boolean');
    else v_full := (p_payload->>'filled_to_full')::boolean; end if;
  end if;

  if p_payload ? 'notes' and jsonb_typeof(p_payload->'notes') <> 'null' then
    if jsonb_typeof(p_payload->'notes') <> 'string' or char_length(p_payload->>'notes') > 4000 then
      v_errors := v_errors || jsonb_build_object('field', 'notes', 'issue', 'string up to 4000 characters');
    else v_notes := p_payload->>'notes'; end if;
  end if;

  if p_payload ? 'external_id' and jsonb_typeof(p_payload->'external_id') <> 'null' then
    if jsonb_typeof(p_payload->'external_id') <> 'string'
       or char_length(p_payload->>'external_id') not between 1 and 255 then
      v_errors := v_errors || jsonb_build_object('field', 'external_id', 'issue', 'string, 1-255 characters');
    else v_external_id := p_payload->>'external_id'; end if;
  end if;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed', 'details', v_errors);
  end if;

  v_idem := public._integration_api_idem_begin(v_client, 'POST /v1/fuel-records', p_idempotency_key,
              public._integration_api_hash(p_payload || jsonb_build_object('vineyard_id', p_vineyard_id)));
  if v_idem->>'mode' = 'replay' then
    return jsonb_build_object('ok', true, 'status', (v_idem->>'status')::int, 'replayed', true, 'data', v_idem->'response');
  elsif v_idem->>'mode' = 'conflict' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_conflict');
  end if;
  v_idem_id := (v_idem->>'id')::uuid;

  begin
    insert into public.tractor_fuel_logs (
      id, vineyard_id, machine_id, fill_datetime, litres_added, engine_hours,
      filled_to_full, notes,
      origin, integration_client_id, integration_api_key_id, external_id,
      client_updated_at
    ) values (
      v_id, p_vineyard_id, v_machine, v_date, v_volume, v_engine,
      v_full, v_notes,
      'integration', v_client, v_key, v_external_id,
      now()
    );
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another fuel record')));
  end;

  perform public._integration_audit(v_client, 'api.write.created', p_vineyard_id,
    jsonb_build_object('resource_type', 'fuel_record', 'resource_id', v_id,
      'external_id', v_external_id, 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_fuel_record_json(v_id);
  perform public._integration_api_idem_store(v_idem_id, 'fuel_record', v_id, 201, v_data);
  return jsonb_build_object('ok', true, 'status', 201, 'replayed', false, 'data', v_data);
end$$;

create or replace function public.integration_api_update_fuel_record(
  p_presented_key text,
  p_fuel_record_id uuid,
  p_payload jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_row public.tractor_fuel_logs;
  v_auth jsonb; v_client uuid; v_key uuid;
  v_errors jsonb := '[]'::jsonb;
  v_expected timestamptz;
  v_changed text[] := '{}';
  k text; v_u uuid;
  v_data jsonb;
begin
  if p_fuel_record_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  select * into v_row from public.tractor_fuel_logs where id = p_fuel_record_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'resource_not_found');
  end if;

  v_auth := public.integration_validate_api_request(p_presented_key, 'fuel:write', v_row.vineyard_id);
  if not coalesce((v_auth->>'valid')::boolean, false) then
    if v_auth->>'failure_code' = 'vineyard_not_granted' then
      return jsonb_build_object('ok', false, 'error', 'resource_not_found');
    end if;
    return jsonb_build_object('ok', false, 'error', v_auth->>'failure_code');
  end if;
  v_client := (v_auth->>'integration_client_id')::uuid;
  v_key := (v_auth->>'api_key_id')::uuid;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  v_errors := public._integration_api_unknown_keys(p_payload, array[
    'expected_updated_at', 'date', 'volume_l', 'equipment_id', 'engine_hours',
    'filled_to_full', 'notes', 'external_id']);

  if jsonb_typeof(p_payload->'expected_updated_at') is distinct from 'string'
     or public._integration_api_ts(p_payload->>'expected_updated_at') is null then
    v_errors := v_errors || jsonb_build_object('field', 'expected_updated_at', 'issue', 'required ISO 8601 timestamp (the updated_at from your latest GET)');
  else
    v_expected := public._integration_api_ts(p_payload->>'expected_updated_at');
  end if;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed', 'details', v_errors);
  end if;

  if v_expected is distinct from v_row.updated_at then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'expected_updated_at', 'issue', 'the record has been modified since it was last read')));
  end if;

  for k in select jsonb_object_keys(p_payload) loop
    if k = 'expected_updated_at' then continue; end if;
    v_changed := v_changed || k;
    case k
      when 'date' then
        if jsonb_typeof(p_payload->'date') <> 'string' or public._integration_api_ts(p_payload->>'date') is null then
          v_errors := v_errors || jsonb_build_object('field', 'date', 'issue', 'ISO 8601 timestamp (not nullable)');
        elsif public._integration_api_ts(p_payload->>'date') > now() + interval '24 hours' then
          v_errors := v_errors || jsonb_build_object('field', 'date', 'issue', 'must not be in the future');
        else v_row.fill_datetime := public._integration_api_ts(p_payload->>'date'); end if;
      when 'volume_l' then
        if jsonb_typeof(p_payload->'volume_l') <> 'number' or (p_payload->>'volume_l')::numeric <= 0 then
          v_errors := v_errors || jsonb_build_object('field', 'volume_l', 'issue', 'number greater than 0 (not nullable)');
        else v_row.litres_added := (p_payload->>'volume_l')::double precision; end if;
      when 'equipment_id' then
        if jsonb_typeof(p_payload->'equipment_id') = 'null' then v_row.machine_id := null;
        elsif jsonb_typeof(p_payload->'equipment_id') <> 'string'
           or public._integration_api_uuid(p_payload->>'equipment_id') is null then
          v_errors := v_errors || jsonb_build_object('field', 'equipment_id', 'issue', 'equipment UUID, or null to clear');
        else
          v_u := public._integration_api_uuid(p_payload->>'equipment_id');
          if not exists (select 1 from public.vineyard_machines m
                         where m.id = v_u and m.vineyard_id = v_row.vineyard_id and m.deleted_at is null) then
            v_errors := v_errors || jsonb_build_object('field', 'equipment_id', 'issue', 'equipment does not exist in this vineyard');
          else v_row.machine_id := v_u; end if;
        end if;
      when 'engine_hours' then
        if jsonb_typeof(p_payload->'engine_hours') = 'null' then v_row.engine_hours := null;
        elsif jsonb_typeof(p_payload->'engine_hours') <> 'number' or (p_payload->>'engine_hours')::numeric < 0 then
          v_errors := v_errors || jsonb_build_object('field', 'engine_hours', 'issue', 'non-negative number, or null to clear');
        else v_row.engine_hours := (p_payload->>'engine_hours')::double precision; end if;
      when 'filled_to_full' then
        if jsonb_typeof(p_payload->'filled_to_full') = 'null' then v_row.filled_to_full := null;
        elsif jsonb_typeof(p_payload->'filled_to_full') <> 'boolean' then
          v_errors := v_errors || jsonb_build_object('field', 'filled_to_full', 'issue', 'boolean, or null to clear');
        else v_row.filled_to_full := (p_payload->>'filled_to_full')::boolean; end if;
      when 'notes' then
        if jsonb_typeof(p_payload->'notes') = 'null' then v_row.notes := null;
        elsif jsonb_typeof(p_payload->'notes') <> 'string' or char_length(p_payload->>'notes') > 4000 then
          v_errors := v_errors || jsonb_build_object('field', 'notes', 'issue', 'string up to 4000 characters, or null to clear');
        else v_row.notes := p_payload->>'notes'; end if;
      when 'external_id' then
        if v_row.integration_client_id is distinct from v_client then
          v_errors := v_errors || jsonb_build_object('field', 'external_id', 'issue', 'can only be set by the integration that created this record');
        elsif jsonb_typeof(p_payload->'external_id') = 'null' then v_row.external_id := null;
        elsif jsonb_typeof(p_payload->'external_id') <> 'string' or char_length(p_payload->>'external_id') not between 1 and 255 then
          v_errors := v_errors || jsonb_build_object('field', 'external_id', 'issue', 'string, 1-255 characters, or null to clear');
        else v_row.external_id := p_payload->>'external_id'; end if;
      else
        null;
    end case;
  end loop;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed', 'details', v_errors);
  end if;

  begin
    update public.tractor_fuel_logs set
      fill_datetime = v_row.fill_datetime, litres_added = v_row.litres_added,
      machine_id = v_row.machine_id, engine_hours = v_row.engine_hours,
      filled_to_full = v_row.filled_to_full, notes = v_row.notes,
      external_id = v_row.external_id,
      updated_by = null,
      updated_by_integration_client_id = v_client,
      client_updated_at = now(),
      sync_version = sync_version + 1
    where id = v_row.id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another fuel record')));
  end;

  perform public._integration_audit(v_client, 'api.write.updated', v_row.vineyard_id,
    jsonb_build_object('resource_type', 'fuel_record', 'resource_id', v_row.id,
      'changed_fields', to_jsonb(v_changed), 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_fuel_record_json(v_row.id);
  return jsonb_build_object('ok', true, 'status', 200, 'data', v_data);
end$$;

-- ===========================================================================
-- J. IRRIGATION RECORDS — POST /v1/irrigation-records (create-only).
--    Reuses the canonical calculation core (_irrigation_compute,
--    _irrigation_validate_session_times, resolve_vineyard_vintage_year) so
--    volumes, allocations, efficiency and vintage are ALWAYS VineTrack-derived
--    — externally supplied calculated fields are not accepted. Corrections
--    (reverse / update) remain in-app; external corrections re-POST.
-- ===========================================================================
create or replace function public.integration_api_create_irrigation_record(
  p_presented_key text,
  p_vineyard_id uuid,
  p_idempotency_key text,
  p_payload jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_auth jsonb; v_client uuid; v_key uuid;
  v_errors jsonb := '[]'::jsonb;
  v_idem jsonb; v_idem_id uuid;
  v_id uuid := gen_random_uuid();
  v_system uuid; v_valve uuid; v_date date;
  v_duration integer; v_method text;
  v_flow numeric; v_meter_start numeric; v_meter_finish numeric; v_volume numeric;
  v_started timestamptz; v_finished timestamptz;
  v_notes text; v_external_id text;
  v_calc jsonb; v_vintage integer; v_block jsonb;
  v_reason text;
  v_data jsonb;
begin
  v_auth := public.integration_validate_api_request(p_presented_key, 'irrigation:write', p_vineyard_id);
  if not coalesce((v_auth->>'valid')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', v_auth->>'failure_code');
  end if;
  v_client := (v_auth->>'integration_client_id')::uuid;
  v_key := (v_auth->>'api_key_id')::uuid;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_required');
  end if;
  if char_length(p_idempotency_key) > 255 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
      'details', jsonb_build_array(jsonb_build_object('field', 'Idempotency-Key', 'issue', 'must be 1-255 characters')));
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  v_errors := public._integration_api_unknown_keys(p_payload, array[
    'system_id', 'valve_id', 'date', 'duration_minutes', 'calculation_method',
    'flow_l_per_hour', 'meter_start_l', 'meter_end_l', 'volume_l',
    'started_at', 'ended_at', 'notes', 'external_id']);

  if jsonb_typeof(p_payload->'system_id') is distinct from 'string'
     or public._integration_api_uuid(p_payload->>'system_id') is null then
    v_errors := v_errors || jsonb_build_object('field', 'system_id', 'issue', 'required irrigation system UUID');
  else v_system := public._integration_api_uuid(p_payload->>'system_id'); end if;

  if jsonb_typeof(p_payload->'valve_id') is distinct from 'string'
     or public._integration_api_uuid(p_payload->>'valve_id') is null then
    v_errors := v_errors || jsonb_build_object('field', 'valve_id', 'issue', 'required valve UUID');
  else v_valve := public._integration_api_uuid(p_payload->>'valve_id'); end if;

  if jsonb_typeof(p_payload->'date') is distinct from 'string'
     or public._integration_api_date(p_payload->>'date') is null then
    v_errors := v_errors || jsonb_build_object('field', 'date', 'issue', 'required ISO 8601 date (YYYY-MM-DD)');
  else v_date := public._integration_api_date(p_payload->>'date'); end if;

  if jsonb_typeof(p_payload->'duration_minutes') is distinct from 'number'
     or (p_payload->>'duration_minutes')::numeric <> trunc((p_payload->>'duration_minutes')::numeric)
     or (p_payload->>'duration_minutes')::numeric <= 0 then
    v_errors := v_errors || jsonb_build_object('field', 'duration_minutes', 'issue', 'required positive integer');
  else v_duration := (p_payload->>'duration_minutes')::integer; end if;

  if jsonb_typeof(p_payload->'calculation_method') is distinct from 'string'
     or p_payload->>'calculation_method' not in ('configured_flow', 'session_flow', 'total_volume', 'meter_readings') then
    v_errors := v_errors || jsonb_build_object('field', 'calculation_method', 'issue', 'one of configured_flow, session_flow, total_volume, meter_readings');
  else v_method := p_payload->>'calculation_method'; end if;

  if p_payload ? 'flow_l_per_hour' and jsonb_typeof(p_payload->'flow_l_per_hour') <> 'null' then
    if jsonb_typeof(p_payload->'flow_l_per_hour') <> 'number' or (p_payload->>'flow_l_per_hour')::numeric <= 0 then
      v_errors := v_errors || jsonb_build_object('field', 'flow_l_per_hour', 'issue', 'number greater than 0');
    else v_flow := (p_payload->>'flow_l_per_hour')::numeric; end if;
  end if;
  if p_payload ? 'meter_start_l' and jsonb_typeof(p_payload->'meter_start_l') <> 'null' then
    if jsonb_typeof(p_payload->'meter_start_l') <> 'number' or (p_payload->>'meter_start_l')::numeric < 0 then
      v_errors := v_errors || jsonb_build_object('field', 'meter_start_l', 'issue', 'non-negative number');
    else v_meter_start := (p_payload->>'meter_start_l')::numeric; end if;
  end if;
  if p_payload ? 'meter_end_l' and jsonb_typeof(p_payload->'meter_end_l') <> 'null' then
    if jsonb_typeof(p_payload->'meter_end_l') <> 'number' or (p_payload->>'meter_end_l')::numeric < 0 then
      v_errors := v_errors || jsonb_build_object('field', 'meter_end_l', 'issue', 'non-negative number');
    else v_meter_finish := (p_payload->>'meter_end_l')::numeric; end if;
  end if;
  if p_payload ? 'volume_l' and jsonb_typeof(p_payload->'volume_l') <> 'null' then
    if jsonb_typeof(p_payload->'volume_l') <> 'number' or (p_payload->>'volume_l')::numeric <= 0 then
      v_errors := v_errors || jsonb_build_object('field', 'volume_l', 'issue', 'number greater than 0');
    else v_volume := (p_payload->>'volume_l')::numeric; end if;
  end if;

  if p_payload ? 'started_at' and jsonb_typeof(p_payload->'started_at') <> 'null' then
    if jsonb_typeof(p_payload->'started_at') <> 'string' or public._integration_api_ts(p_payload->>'started_at') is null then
      v_errors := v_errors || jsonb_build_object('field', 'started_at', 'issue', 'ISO 8601 timestamp');
    else v_started := public._integration_api_ts(p_payload->>'started_at'); end if;
  end if;
  if p_payload ? 'ended_at' and jsonb_typeof(p_payload->'ended_at') <> 'null' then
    if jsonb_typeof(p_payload->'ended_at') <> 'string' or public._integration_api_ts(p_payload->>'ended_at') is null then
      v_errors := v_errors || jsonb_build_object('field', 'ended_at', 'issue', 'ISO 8601 timestamp');
    else v_finished := public._integration_api_ts(p_payload->>'ended_at'); end if;
  end if;

  if p_payload ? 'notes' and jsonb_typeof(p_payload->'notes') <> 'null' then
    if jsonb_typeof(p_payload->'notes') <> 'string' or char_length(p_payload->>'notes') > 4000 then
      v_errors := v_errors || jsonb_build_object('field', 'notes', 'issue', 'string up to 4000 characters');
    else v_notes := p_payload->>'notes'; end if;
  end if;

  if p_payload ? 'external_id' and jsonb_typeof(p_payload->'external_id') <> 'null' then
    if jsonb_typeof(p_payload->'external_id') <> 'string'
       or char_length(p_payload->>'external_id') not between 1 and 255 then
      v_errors := v_errors || jsonb_build_object('field', 'external_id', 'issue', 'string, 1-255 characters');
    else v_external_id := p_payload->>'external_id'; end if;
  end if;

  -- Valve must belong to the declared system AND the granted vineyard
  -- (cross-vineyard substitution fails without leaking anything).
  if v_valve is not null and v_system is not null then
    if not exists (select 1 from public.irrigation_valves v
                   where v.id = v_valve and v.irrigation_system_id = v_system
                     and v.vineyard_id = p_vineyard_id) then
      v_errors := v_errors || jsonb_build_object('field', 'valve_id', 'issue', 'valve does not exist in this vineyard under the given system');
    end if;
  end if;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed', 'details', v_errors);
  end if;

  v_idem := public._integration_api_idem_begin(v_client, 'POST /v1/irrigation-records', p_idempotency_key,
              public._integration_api_hash(p_payload || jsonb_build_object('vineyard_id', p_vineyard_id)));
  if v_idem->>'mode' = 'replay' then
    return jsonb_build_object('ok', true, 'status', (v_idem->>'status')::int, 'replayed', true, 'data', v_idem->'response');
  elsif v_idem->>'mode' = 'conflict' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_conflict');
  end if;
  v_idem_id := (v_idem->>'id')::uuid;

  -- Canonical calculation core. Its curated business-rule exceptions
  -- ('reason_code: human message') surface as field-level validation errors;
  -- anything else is an internal error (never leaked).
  begin
    perform public._irrigation_validate_session_times(v_started, v_finished, v_duration);
    v_calc := public._irrigation_compute(
      p_vineyard_id, v_valve, v_duration, v_method,
      v_flow, v_meter_start, v_meter_finish, v_volume);
  exception when others then
    v_reason := split_part(sqlerrm, ':', 1);
    if v_reason ~ '^[a-z][a-z_]*$' then
      return jsonb_build_object('ok', false, 'error', 'validation_failed',
        'details', jsonb_build_array(jsonb_build_object('field', 'calculation_method', 'issue', sqlerrm)));
    end if;
    raise;
  end;

  v_vintage := public.resolve_vineyard_vintage_year(p_vineyard_id, v_date);

  begin
    insert into public.irrigation_sessions (
      id, vineyard_id, irrigation_system_id, valve_id, session_date, vintage_year,
      started_at, finished_at, duration_minutes, calculation_method,
      flow_litres_per_hour, meter_start_litres, meter_finish_litres,
      total_volume_litres, effective_volume_litres, irrigation_efficiency_percent,
      status, source_type, notes, configuration_snapshot,
      created_by, updated_by,
      origin, integration_client_id, integration_api_key_id, external_id
    ) values (
      v_id, p_vineyard_id, v_system, v_valve, v_date, v_vintage,
      v_started, v_finished, v_duration, v_method,
      (v_calc->>'flow_litres_per_hour_used')::numeric, v_meter_start, v_meter_finish,
      (v_calc->>'total_volume_litres')::numeric,
      nullif(v_calc->>'effective_volume_litres', '')::numeric,
      nullif(v_calc->>'irrigation_efficiency_percent', '')::numeric,
      'completed', 'external_api', v_notes, v_calc->'configuration_snapshot',
      null, null,
      'integration', v_client, v_key, v_external_id
    );
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another irrigation record')));
  end;

  for v_block in select * from jsonb_array_elements(v_calc->'blocks') loop
    insert into public.irrigation_session_blocks (
      session_id, vineyard_id, valve_id, block_id, variety_id, variety_name,
      allocation_method, allocation_percentage, allocated_volume_litres,
      effective_volume_litres, serviced_area_m2, serviced_vine_count,
      water_litres_per_vine, water_litres_per_hectare,
      irrigation_depth_mm, effective_irrigation_depth_mm
    ) values (
      v_id, p_vineyard_id, v_valve,
      (v_block->>'block_id')::uuid,
      nullif(v_block->>'variety_id', '')::uuid,
      nullif(v_block->>'variety_name', ''),
      v_block->>'allocation_method',
      (v_block->>'allocation_percentage')::numeric,
      (v_block->>'allocated_volume_litres')::numeric,
      nullif(v_block->>'effective_volume_litres', '')::numeric,
      nullif(v_block->>'serviced_area_m2', '')::numeric,
      nullif(v_block->>'serviced_vine_count', '')::integer,
      nullif(v_block->>'water_litres_per_vine', '')::numeric,
      nullif(v_block->>'water_litres_per_hectare', '')::numeric,
      nullif(v_block->>'irrigation_depth_mm', '')::numeric,
      nullif(v_block->>'effective_irrigation_depth_mm', '')::numeric
    );
  end loop;

  -- Same domain audit trail as native writes (user_id NULL = machine write;
  -- integration identity below).
  perform public._irrigation_audit(p_vineyard_id, 'create', 'irrigation_session', v_id,
    null, public._irrigation_session_json(v_id));

  perform public._integration_audit(v_client, 'api.write.created', p_vineyard_id,
    jsonb_build_object('resource_type', 'irrigation_record', 'resource_id', v_id,
      'external_id', v_external_id, 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_irrigation_json(v_id);
  perform public._integration_api_idem_store(v_idem_id, 'irrigation_record', v_id, 201, v_data);
  return jsonb_build_object('ok', true, 'status', 201, 'replayed', false, 'data', v_data);
end$$;

-- ===========================================================================
-- K. GROWTH STAGES — POST /v1/growth-stages (create-only, sql/055 + 178).
--    Placement metadata (row/side/coordinates) follows the pin principle:
--    device-resolved only, never accepted from external callers.
-- ===========================================================================
create or replace function public.integration_api_create_growth_stage(
  p_presented_key text,
  p_vineyard_id uuid,
  p_idempotency_key text,
  p_payload jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_auth jsonb; v_client uuid; v_key uuid;
  v_errors jsonb := '[]'::jsonb;
  v_idem jsonb; v_idem_id uuid;
  v_id uuid := gen_random_uuid();
  v_code text; v_label text; v_observed timestamptz := now();
  v_block uuid; v_variety text; v_notes text; v_external_id text;
  v_integration_name text;
  v_data jsonb;
begin
  v_auth := public.integration_validate_api_request(p_presented_key, 'growth_stages:write', p_vineyard_id);
  if not coalesce((v_auth->>'valid')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', v_auth->>'failure_code');
  end if;
  v_client := (v_auth->>'integration_client_id')::uuid;
  v_key := (v_auth->>'api_key_id')::uuid;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_required');
  end if;
  if char_length(p_idempotency_key) > 255 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
      'details', jsonb_build_array(jsonb_build_object('field', 'Idempotency-Key', 'issue', 'must be 1-255 characters')));
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  v_errors := public._integration_api_unknown_keys(p_payload, array[
    'stage_code', 'observed_at', 'block_id', 'variety', 'notes', 'external_id']);

  if jsonb_typeof(p_payload->'stage_code') is distinct from 'string' then
    v_errors := v_errors || jsonb_build_object('field', 'stage_code', 'issue', 'required E-L stage code (e.g. EL4)');
  else
    v_code := upper(btrim(p_payload->>'stage_code'));
    v_label := public._integration_api_el_stage_label(v_code);
    if v_label is null then
      v_errors := v_errors || jsonb_build_object('field', 'stage_code', 'issue', 'unsupported E-L stage code — only codes from the VineTrack catalogue are accepted');
    end if;
  end if;

  if p_payload ? 'observed_at' and jsonb_typeof(p_payload->'observed_at') <> 'null' then
    if jsonb_typeof(p_payload->'observed_at') <> 'string' or public._integration_api_ts(p_payload->>'observed_at') is null then
      v_errors := v_errors || jsonb_build_object('field', 'observed_at', 'issue', 'ISO 8601 timestamp');
    elsif public._integration_api_ts(p_payload->>'observed_at') > now() + interval '24 hours' then
      v_errors := v_errors || jsonb_build_object('field', 'observed_at', 'issue', 'must not be in the future');
    else v_observed := public._integration_api_ts(p_payload->>'observed_at'); end if;
  end if;

  if p_payload ? 'block_id' and jsonb_typeof(p_payload->'block_id') <> 'null' then
    if jsonb_typeof(p_payload->'block_id') <> 'string'
       or public._integration_api_uuid(p_payload->>'block_id') is null then
      v_errors := v_errors || jsonb_build_object('field', 'block_id', 'issue', 'block UUID');
    else
      v_block := public._integration_api_uuid(p_payload->>'block_id');
      if not exists (select 1 from public.paddocks p
                     where p.id = v_block and p.vineyard_id = p_vineyard_id and p.deleted_at is null) then
        v_errors := v_errors || jsonb_build_object('field', 'block_id', 'issue', 'block does not exist in this vineyard');
        v_block := null;
      end if;
    end if;
  end if;

  if p_payload ? 'variety' and jsonb_typeof(p_payload->'variety') <> 'null' then
    if jsonb_typeof(p_payload->'variety') <> 'string' or char_length(p_payload->>'variety') > 100 then
      v_errors := v_errors || jsonb_build_object('field', 'variety', 'issue', 'string up to 100 characters');
    else v_variety := p_payload->>'variety'; end if;
  end if;

  if p_payload ? 'notes' and jsonb_typeof(p_payload->'notes') <> 'null' then
    if jsonb_typeof(p_payload->'notes') <> 'string' or char_length(p_payload->>'notes') > 4000 then
      v_errors := v_errors || jsonb_build_object('field', 'notes', 'issue', 'string up to 4000 characters');
    else v_notes := p_payload->>'notes'; end if;
  end if;

  if p_payload ? 'external_id' and jsonb_typeof(p_payload->'external_id') <> 'null' then
    if jsonb_typeof(p_payload->'external_id') <> 'string'
       or char_length(p_payload->>'external_id') not between 1 and 255 then
      v_errors := v_errors || jsonb_build_object('field', 'external_id', 'issue', 'string, 1-255 characters');
    else v_external_id := p_payload->>'external_id'; end if;
  end if;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed', 'details', v_errors);
  end if;

  v_idem := public._integration_api_idem_begin(v_client, 'POST /v1/growth-stages', p_idempotency_key,
              public._integration_api_hash(p_payload || jsonb_build_object('vineyard_id', p_vineyard_id)));
  if v_idem->>'mode' = 'replay' then
    return jsonb_build_object('ok', true, 'status', (v_idem->>'status')::int, 'replayed', true, 'data', v_idem->'response');
  elsif v_idem->>'mode' = 'conflict' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_conflict');
  end if;
  v_idem_id := (v_idem->>'id')::uuid;

  select name into v_integration_name from public.integration_clients where id = v_client;

  begin
    insert into public.growth_stage_records (
      id, vineyard_id, paddock_id, stage_code, stage_label, variety,
      observed_at, notes, recorded_by_name,
      origin, integration_client_id, integration_api_key_id, external_id,
      client_updated_at
    ) values (
      v_id, p_vineyard_id, v_block, v_code, v_label, v_variety,
      v_observed, v_notes, v_integration_name,
      'integration', v_client, v_key, v_external_id,
      now()
    );
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another growth stage record')));
  end;

  perform public._integration_audit(v_client, 'api.write.created', p_vineyard_id,
    jsonb_build_object('resource_type', 'growth_stage', 'resource_id', v_id,
      'external_id', v_external_id, 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_growth_stage_json(v_id);
  perform public._integration_api_idem_store(v_idem_id, 'growth_stage', v_id, 201, v_data);
  return jsonb_build_object('ok', true, 'status', 201, 'replayed', false, 'data', v_data);
end$$;

-- ===========================================================================
-- L. YIELD RECORDS — POST /v1/yield-records, PATCH /v1/yield-records/{id}.
--    The canonical camelCase block_results JSONB shape (iOS
--    HistoricalBlockResult Codable keys) is preserved exactly — the RPC maps
--    the public snake_case block input into it; yieldPerHectare is always
--    server-derived.
-- ===========================================================================
create or replace function public._integration_api_yield_blocks(
  p_vineyard_id uuid,
  p_blocks jsonb,
  inout io_errors jsonb,
  out o_block_results jsonb,
  out o_total_yield double precision,
  out o_total_area double precision
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b jsonb;
  v_u uuid; v_name text;
  v_area numeric; v_yield numeric; v_per_ha numeric;
  v_seen uuid[] := '{}';
  v_unknown jsonb;
begin
  o_block_results := '[]'::jsonb;
  o_total_yield := 0;
  o_total_area := 0;

  if jsonb_typeof(p_blocks) <> 'array' then
    io_errors := io_errors || jsonb_build_object('field', 'blocks', 'issue', 'array of block results');
    return;
  end if;

  for b in select * from jsonb_array_elements(p_blocks) loop
    if jsonb_typeof(b) <> 'object' then
      io_errors := io_errors || jsonb_build_object('field', 'blocks', 'issue', 'each entry must be an object');
      continue;
    end if;
    v_unknown := public._integration_api_unknown_keys(b, array[
      'block_id', 'area_ha', 'yield_tonnes', 'vine_count', 'average_bunches_per_vine',
      'average_bunch_weight_g', 'samples_recorded', 'damage_factor',
      'actual_yield_tonnes', 'actual_recorded_at']);
    if jsonb_array_length(v_unknown) > 0 then
      io_errors := io_errors || v_unknown;
      continue;
    end if;

    if jsonb_typeof(b->'block_id') is distinct from 'string'
       or public._integration_api_uuid(b->>'block_id') is null then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.block_id', 'issue', 'required block UUID');
      continue;
    end if;
    v_u := public._integration_api_uuid(b->>'block_id');
    select name into v_name from public.paddocks p
    where p.id = v_u and p.vineyard_id = p_vineyard_id and p.deleted_at is null;
    if v_name is null then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.block_id', 'issue', 'block ' || (b->>'block_id') || ' does not exist in this vineyard');
      continue;
    end if;
    if v_u = any (v_seen) then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.block_id', 'issue', 'duplicate block ' || (b->>'block_id'));
      continue;
    end if;
    v_seen := v_seen || v_u;

    if (b ? 'area_ha' and jsonb_typeof(b->'area_ha') not in ('number', 'null'))
       or (jsonb_typeof(b->'area_ha') = 'number' and (b->>'area_ha')::numeric < 0) then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.area_ha', 'issue', 'non-negative number');
      continue;
    end if;
    if (b ? 'yield_tonnes' and jsonb_typeof(b->'yield_tonnes') not in ('number', 'null'))
       or (jsonb_typeof(b->'yield_tonnes') = 'number' and (b->>'yield_tonnes')::numeric < 0) then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.yield_tonnes', 'issue', 'non-negative number');
      continue;
    end if;
    if (b ? 'vine_count' and jsonb_typeof(b->'vine_count') not in ('number', 'null'))
       or (jsonb_typeof(b->'vine_count') = 'number'
           and ((b->>'vine_count')::numeric < 0 or (b->>'vine_count')::numeric <> trunc((b->>'vine_count')::numeric))) then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.vine_count', 'issue', 'non-negative integer');
      continue;
    end if;
    if (b ? 'average_bunches_per_vine' and jsonb_typeof(b->'average_bunches_per_vine') not in ('number', 'null'))
       or (jsonb_typeof(b->'average_bunches_per_vine') = 'number' and (b->>'average_bunches_per_vine')::numeric < 0) then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.average_bunches_per_vine', 'issue', 'non-negative number');
      continue;
    end if;
    if (b ? 'average_bunch_weight_g' and jsonb_typeof(b->'average_bunch_weight_g') not in ('number', 'null'))
       or (jsonb_typeof(b->'average_bunch_weight_g') = 'number' and (b->>'average_bunch_weight_g')::numeric < 0) then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.average_bunch_weight_g', 'issue', 'non-negative number');
      continue;
    end if;
    if (b ? 'samples_recorded' and jsonb_typeof(b->'samples_recorded') not in ('number', 'null'))
       or (jsonb_typeof(b->'samples_recorded') = 'number'
           and ((b->>'samples_recorded')::numeric < 0 or (b->>'samples_recorded')::numeric <> trunc((b->>'samples_recorded')::numeric))) then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.samples_recorded', 'issue', 'non-negative integer');
      continue;
    end if;
    if (b ? 'damage_factor' and jsonb_typeof(b->'damage_factor') not in ('number', 'null'))
       or (jsonb_typeof(b->'damage_factor') = 'number'
           and ((b->>'damage_factor')::numeric < 0 or (b->>'damage_factor')::numeric > 1)) then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.damage_factor', 'issue', 'number between 0 and 1');
      continue;
    end if;
    if (b ? 'actual_yield_tonnes' and jsonb_typeof(b->'actual_yield_tonnes') not in ('number', 'null'))
       or (jsonb_typeof(b->'actual_yield_tonnes') = 'number' and (b->>'actual_yield_tonnes')::numeric < 0) then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.actual_yield_tonnes', 'issue', 'non-negative number');
      continue;
    end if;
    if b ? 'actual_recorded_at' and jsonb_typeof(b->'actual_recorded_at') not in ('string', 'null') then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.actual_recorded_at', 'issue', 'ISO 8601 timestamp');
      continue;
    end if;
    if jsonb_typeof(b->'actual_recorded_at') = 'string'
       and public._integration_api_ts(b->>'actual_recorded_at') is null then
      io_errors := io_errors || jsonb_build_object('field', 'blocks.actual_recorded_at', 'issue', 'ISO 8601 timestamp');
      continue;
    end if;

    v_area := coalesce(nullif(b->>'area_ha', '')::numeric, 0);
    v_yield := coalesce(nullif(b->>'yield_tonnes', '')::numeric, 0);
    -- yieldPerHectare is ALWAYS derived (VineTrack calculation convention).
    v_per_ha := case when v_area > 0 then round(v_yield / v_area, 4) else 0 end;

    o_total_yield := o_total_yield + v_yield;
    o_total_area := o_total_area + v_area;

    -- Canonical camelCase HistoricalBlockResult element.
    o_block_results := o_block_results || jsonb_strip_nulls(jsonb_build_object(
      'id', gen_random_uuid(),
      'paddockId', v_u,
      'paddockName', v_name,
      'areaHectares', v_area,
      'yieldTonnes', v_yield,
      'yieldPerHectare', v_per_ha,
      'averageBunchesPerVine', coalesce(nullif(b->>'average_bunches_per_vine', '')::numeric, 0),
      'averageBunchWeightGrams', coalesce(nullif(b->>'average_bunch_weight_g', '')::numeric, 0),
      'totalVines', coalesce(nullif(b->>'vine_count', '')::integer, 0),
      'samplesRecorded', coalesce(nullif(b->>'samples_recorded', '')::integer, 0),
      'damageFactor', coalesce(nullif(b->>'damage_factor', '')::numeric, 0),
      'actualYieldTonnes', nullif(b->>'actual_yield_tonnes', '')::numeric,
      'actualRecordedAt', nullif(b->>'actual_recorded_at', '')));
  end loop;
end$$;

create or replace function public.integration_api_create_yield_record(
  p_presented_key text,
  p_vineyard_id uuid,
  p_idempotency_key text,
  p_payload jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_auth jsonb; v_client uuid; v_key uuid;
  v_errors jsonb := '[]'::jsonb;
  v_idem jsonb; v_idem_id uuid;
  v_id uuid := gen_random_uuid();
  v_year integer; v_season text := ''; v_notes text := '';
  v_total_yield double precision; v_total_area double precision;
  v_blocks jsonb; v_block_yield double precision; v_block_area double precision;
  v_external_id text;
  v_data jsonb;
begin
  v_auth := public.integration_validate_api_request(p_presented_key, 'yield:write', p_vineyard_id);
  if not coalesce((v_auth->>'valid')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', v_auth->>'failure_code');
  end if;
  v_client := (v_auth->>'integration_client_id')::uuid;
  v_key := (v_auth->>'api_key_id')::uuid;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_required');
  end if;
  if char_length(p_idempotency_key) > 255 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed',
      'details', jsonb_build_array(jsonb_build_object('field', 'Idempotency-Key', 'issue', 'must be 1-255 characters')));
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  v_errors := public._integration_api_unknown_keys(p_payload, array[
    'vintage_year', 'season', 'total_yield_tonnes', 'total_area_ha', 'notes', 'blocks', 'external_id']);

  if jsonb_typeof(p_payload->'vintage_year') is distinct from 'number'
     or (p_payload->>'vintage_year')::numeric <> trunc((p_payload->>'vintage_year')::numeric)
     or (p_payload->>'vintage_year')::numeric not between 1900 and 2100 then
    v_errors := v_errors || jsonb_build_object('field', 'vintage_year', 'issue', 'required integer between 1900 and 2100');
  else
    v_year := (p_payload->>'vintage_year')::integer;
  end if;

  if p_payload ? 'season' and jsonb_typeof(p_payload->'season') <> 'null' then
    if jsonb_typeof(p_payload->'season') <> 'string' or char_length(p_payload->>'season') > 50 then
      v_errors := v_errors || jsonb_build_object('field', 'season', 'issue', 'string up to 50 characters');
    else v_season := p_payload->>'season'; end if;
  end if;

  if p_payload ? 'total_yield_tonnes' and jsonb_typeof(p_payload->'total_yield_tonnes') <> 'null' then
    if jsonb_typeof(p_payload->'total_yield_tonnes') <> 'number' or (p_payload->>'total_yield_tonnes')::numeric < 0 then
      v_errors := v_errors || jsonb_build_object('field', 'total_yield_tonnes', 'issue', 'non-negative number');
    else v_total_yield := (p_payload->>'total_yield_tonnes')::double precision; end if;
  end if;

  if p_payload ? 'total_area_ha' and jsonb_typeof(p_payload->'total_area_ha') <> 'null' then
    if jsonb_typeof(p_payload->'total_area_ha') <> 'number' or (p_payload->>'total_area_ha')::numeric < 0 then
      v_errors := v_errors || jsonb_build_object('field', 'total_area_ha', 'issue', 'non-negative number');
    else v_total_area := (p_payload->>'total_area_ha')::double precision; end if;
  end if;

  if p_payload ? 'notes' and jsonb_typeof(p_payload->'notes') <> 'null' then
    if jsonb_typeof(p_payload->'notes') <> 'string' or char_length(p_payload->>'notes') > 4000 then
      v_errors := v_errors || jsonb_build_object('field', 'notes', 'issue', 'string up to 4000 characters');
    else v_notes := p_payload->>'notes'; end if;
  end if;

  if p_payload ? 'external_id' and jsonb_typeof(p_payload->'external_id') <> 'null' then
    if jsonb_typeof(p_payload->'external_id') <> 'string'
       or char_length(p_payload->>'external_id') not between 1 and 255 then
      v_errors := v_errors || jsonb_build_object('field', 'external_id', 'issue', 'string, 1-255 characters');
    else v_external_id := p_payload->>'external_id'; end if;
  end if;

  if p_payload ? 'blocks' and jsonb_typeof(p_payload->'blocks') <> 'null' then
    select o_block_results, o_total_yield, o_total_area, io_errors
    into v_blocks, v_block_yield, v_block_area, v_errors
    from public._integration_api_yield_blocks(p_vineyard_id, p_payload->'blocks', v_errors);
  end if;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed', 'details', v_errors);
  end if;

  -- Totals: caller-supplied when present, otherwise derived from blocks.
  v_total_yield := coalesce(v_total_yield, v_block_yield, 0);
  v_total_area := coalesce(v_total_area, v_block_area, 0);

  v_idem := public._integration_api_idem_begin(v_client, 'POST /v1/yield-records', p_idempotency_key,
              public._integration_api_hash(p_payload || jsonb_build_object('vineyard_id', p_vineyard_id)));
  if v_idem->>'mode' = 'replay' then
    return jsonb_build_object('ok', true, 'status', (v_idem->>'status')::int, 'replayed', true, 'data', v_idem->'response');
  elsif v_idem->>'mode' = 'conflict' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_conflict');
  end if;
  v_idem_id := (v_idem->>'id')::uuid;

  begin
    insert into public.historical_yield_records (
      id, vineyard_id, season, year, archived_at, total_yield_tonnes,
      total_area_hectares, notes, block_results,
      origin, integration_client_id, integration_api_key_id, external_id,
      client_updated_at
    ) values (
      v_id, p_vineyard_id, v_season, v_year, now(), v_total_yield,
      v_total_area, v_notes, v_blocks,
      'integration', v_client, v_key, v_external_id,
      now()
    );
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another yield record')));
  end;

  perform public._integration_audit(v_client, 'api.write.created', p_vineyard_id,
    jsonb_build_object('resource_type', 'yield_record', 'resource_id', v_id,
      'external_id', v_external_id, 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_yield_record_json(v_id);
  perform public._integration_api_idem_store(v_idem_id, 'yield_record', v_id, 201, v_data);
  return jsonb_build_object('ok', true, 'status', 201, 'replayed', false, 'data', v_data);
end$$;

create or replace function public.integration_api_update_yield_record(
  p_presented_key text,
  p_yield_record_id uuid,
  p_payload jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_row public.historical_yield_records;
  v_auth jsonb; v_client uuid; v_key uuid;
  v_errors jsonb := '[]'::jsonb;
  v_expected timestamptz;
  v_changed text[] := '{}';
  v_blocks jsonb; v_block_yield double precision; v_block_area double precision;
  v_blocks_set boolean := false;
  k text;
  v_data jsonb;
begin
  if p_yield_record_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  select * into v_row from public.historical_yield_records where id = p_yield_record_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'resource_not_found');
  end if;

  v_auth := public.integration_validate_api_request(p_presented_key, 'yield:write', v_row.vineyard_id);
  if not coalesce((v_auth->>'valid')::boolean, false) then
    if v_auth->>'failure_code' = 'vineyard_not_granted' then
      return jsonb_build_object('ok', false, 'error', 'resource_not_found');
    end if;
    return jsonb_build_object('ok', false, 'error', v_auth->>'failure_code');
  end if;
  v_client := (v_auth->>'integration_client_id')::uuid;
  v_key := (v_auth->>'api_key_id')::uuid;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;

  v_errors := public._integration_api_unknown_keys(p_payload, array[
    'expected_updated_at', 'vintage_year', 'season', 'total_yield_tonnes',
    'total_area_ha', 'notes', 'blocks', 'external_id']);

  if jsonb_typeof(p_payload->'expected_updated_at') is distinct from 'string'
     or public._integration_api_ts(p_payload->>'expected_updated_at') is null then
    v_errors := v_errors || jsonb_build_object('field', 'expected_updated_at', 'issue', 'required ISO 8601 timestamp (the updated_at from your latest GET)');
  else
    v_expected := public._integration_api_ts(p_payload->>'expected_updated_at');
  end if;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed', 'details', v_errors);
  end if;

  if v_expected is distinct from v_row.updated_at then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'expected_updated_at', 'issue', 'the record has been modified since it was last read')));
  end if;

  for k in select jsonb_object_keys(p_payload) loop
    if k = 'expected_updated_at' then continue; end if;
    v_changed := v_changed || k;
    case k
      when 'vintage_year' then
        if jsonb_typeof(p_payload->'vintage_year') <> 'number'
           or (p_payload->>'vintage_year')::numeric <> trunc((p_payload->>'vintage_year')::numeric)
           or (p_payload->>'vintage_year')::numeric not between 1900 and 2100 then
          v_errors := v_errors || jsonb_build_object('field', 'vintage_year', 'issue', 'integer between 1900 and 2100 (not nullable)');
        else v_row.year := (p_payload->>'vintage_year')::integer; end if;
      when 'season' then
        if jsonb_typeof(p_payload->'season') = 'null' then v_row.season := '';
        elsif jsonb_typeof(p_payload->'season') <> 'string' or char_length(p_payload->>'season') > 50 then
          v_errors := v_errors || jsonb_build_object('field', 'season', 'issue', 'string up to 50 characters, or null to clear');
        else v_row.season := p_payload->>'season'; end if;
      when 'total_yield_tonnes' then
        if jsonb_typeof(p_payload->'total_yield_tonnes') = 'null' then v_row.total_yield_tonnes := 0;
        elsif jsonb_typeof(p_payload->'total_yield_tonnes') <> 'number' or (p_payload->>'total_yield_tonnes')::numeric < 0 then
          v_errors := v_errors || jsonb_build_object('field', 'total_yield_tonnes', 'issue', 'non-negative number');
        else v_row.total_yield_tonnes := (p_payload->>'total_yield_tonnes')::double precision; end if;
      when 'total_area_ha' then
        if jsonb_typeof(p_payload->'total_area_ha') = 'null' then v_row.total_area_hectares := 0;
        elsif jsonb_typeof(p_payload->'total_area_ha') <> 'number' or (p_payload->>'total_area_ha')::numeric < 0 then
          v_errors := v_errors || jsonb_build_object('field', 'total_area_ha', 'issue', 'non-negative number');
        else v_row.total_area_hectares := (p_payload->>'total_area_ha')::double precision; end if;
      when 'notes' then
        if jsonb_typeof(p_payload->'notes') = 'null' then v_row.notes := '';
        elsif jsonb_typeof(p_payload->'notes') <> 'string' or char_length(p_payload->>'notes') > 4000 then
          v_errors := v_errors || jsonb_build_object('field', 'notes', 'issue', 'string up to 4000 characters, or null to clear');
        else v_row.notes := p_payload->>'notes'; end if;
      when 'blocks' then
        if jsonb_typeof(p_payload->'blocks') = 'null' then
          v_row.block_results := null;
          v_blocks_set := true;
        else
          select o_block_results, o_total_yield, o_total_area, io_errors
          into v_blocks, v_block_yield, v_block_area, v_errors
          from public._integration_api_yield_blocks(v_row.vineyard_id, p_payload->'blocks', v_errors);
          v_row.block_results := v_blocks;
          v_blocks_set := true;
        end if;
      when 'external_id' then
        if v_row.integration_client_id is distinct from v_client then
          v_errors := v_errors || jsonb_build_object('field', 'external_id', 'issue', 'can only be set by the integration that created this record');
        elsif jsonb_typeof(p_payload->'external_id') = 'null' then v_row.external_id := null;
        elsif jsonb_typeof(p_payload->'external_id') <> 'string' or char_length(p_payload->>'external_id') not between 1 and 255 then
          v_errors := v_errors || jsonb_build_object('field', 'external_id', 'issue', 'string, 1-255 characters, or null to clear');
        else v_row.external_id := p_payload->>'external_id'; end if;
      else
        null;
    end case;
  end loop;

  if jsonb_array_length(v_errors) > 0 then
    return jsonb_build_object('ok', false, 'error', 'validation_failed', 'details', v_errors);
  end if;

  -- Replacing blocks without explicit totals re-derives totals from the new
  -- block set (same derivation as create).
  if v_blocks_set and v_row.block_results is not null
     and not (p_payload ? 'total_yield_tonnes') then
    v_row.total_yield_tonnes := coalesce(v_block_yield, 0);
  end if;
  if v_blocks_set and v_row.block_results is not null
     and not (p_payload ? 'total_area_ha') then
    v_row.total_area_hectares := coalesce(v_block_area, 0);
  end if;

  begin
    update public.historical_yield_records set
      season = v_row.season, year = v_row.year,
      total_yield_tonnes = v_row.total_yield_tonnes,
      total_area_hectares = v_row.total_area_hectares,
      notes = v_row.notes, block_results = v_row.block_results,
      external_id = v_row.external_id,
      updated_by = null,
      updated_by_integration_client_id = v_client,
      client_updated_at = now(),
      sync_version = sync_version + 1
    where id = v_row.id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another yield record')));
  end;

  perform public._integration_audit(v_client, 'api.write.updated', v_row.vineyard_id,
    jsonb_build_object('resource_type', 'yield_record', 'resource_id', v_row.id,
      'changed_fields', to_jsonb(v_changed), 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_yield_record_json(v_row.id);
  return jsonb_build_object('ok', true, 'status', 200, 'data', v_data);
end$$;

-- ===========================================================================
-- M. Event payloads gain additive origin/external_id (webhook v1 signature,
--    headers, retry policy and api_version are all UNCHANGED — receivers can
--    now ignore their own writes for loop prevention).
-- ===========================================================================
create or replace function public._integration_evt_provenance(
  p_origin text, p_external_id text
) returns jsonb language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'origin', coalesce(p_origin, 'vinetrack'),
    'external_id', p_external_id));
$$;

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
      jsonb_build_object('id', new.id) || public._integration_evt_provenance(new.origin, new.external_id),
      'fuel_log.created:' || new.id, 'trigger:tractor_fuel_logs');
  else
    perform public._integration_emit_safe('fuel_log.updated', new.vineyard_id, 'fuel_log', new.id,
      jsonb_build_object('id', new.id) || public._integration_evt_provenance(new.origin, new.external_id),
      'fuel_log.updated:' || new.id || ':' || txid_current(), 'trigger:tractor_fuel_logs');
  end if;
  return new;
end$$;

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
        jsonb_build_object('id', new.id, 'finalized_at', new.finalized_at) || public._integration_evt_provenance(new.origin, new.external_id),
        'work_task.completed:' || new.id, 'trigger:work_tasks');
    else
      perform public._integration_emit_safe('work_task.created', new.vineyard_id, 'work_task', new.id,
        jsonb_build_object('id', new.id) || public._integration_evt_provenance(new.origin, new.external_id),
        'work_task.created:' || new.id, 'trigger:work_tasks');
    end if;
  else
    if not coalesce(old.is_finalized, false) and coalesce(new.is_finalized, false) then
      perform public._integration_emit_safe('work_task.completed', new.vineyard_id, 'work_task', new.id,
        jsonb_build_object('id', new.id, 'finalized_at', new.finalized_at) || public._integration_evt_provenance(new.origin, new.external_id),
        'work_task.completed:' || new.id, 'trigger:work_tasks');
    else
      perform public._integration_emit_safe('work_task.updated', new.vineyard_id, 'work_task', new.id,
        jsonb_build_object('id', new.id) || public._integration_evt_provenance(new.origin, new.external_id),
        'work_task.updated:' || new.id || ':' || txid_current(), 'trigger:work_tasks');
    end if;
  end if;
  return new;
end$$;

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
      jsonb_build_object('id', new.id, 'status', new.status) || public._integration_evt_provenance(new.origin, new.external_id),
      'irrigation_record.created:' || new.id, 'trigger:irrigation_sessions');
  else
    if old.status in ('planned', 'running') and new.status = 'completed' then
      perform public._integration_emit_safe('irrigation_record.completed', new.vineyard_id, 'irrigation_record', new.id,
        jsonb_build_object('id', new.id, 'status', new.status) || public._integration_evt_provenance(new.origin, new.external_id),
        'irrigation_record.completed:' || new.id, 'trigger:irrigation_sessions');
    else
      perform public._integration_emit_safe('irrigation_record.updated', new.vineyard_id, 'irrigation_record', new.id,
        jsonb_build_object('id', new.id, 'status', new.status) || public._integration_evt_provenance(new.origin, new.external_id),
        'irrigation_record.updated:' || new.id || ':' || txid_current(), 'trigger:irrigation_sessions');
    end if;
  end if;
  return new;
end$$;

create or replace function public._integration_evt_growth_stage_records()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is null and tg_op = 'INSERT' then
    perform public._integration_emit_safe('growth_stage.recorded', new.vineyard_id, 'growth_stage', new.id,
      jsonb_build_object('id', new.id, 'stage_code', new.stage_code) || public._integration_evt_provenance(new.origin, new.external_id),
      'growth_stage.recorded:' || new.id, 'trigger:growth_stage_records');
  end if;
  return new;
end$$;

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
      jsonb_build_object('id', new.id) || public._integration_evt_provenance(new.origin, new.external_id),
      'yield_record.created:' || new.id, 'trigger:historical_yield_records');
  else
    perform public._integration_emit_safe('yield_record.updated', new.vineyard_id, 'yield_record', new.id,
      jsonb_build_object('id', new.id) || public._integration_evt_provenance(new.origin, new.external_id),
      'yield_record.updated:' || new.id || ':' || txid_current(), 'trigger:historical_yield_records');
  end if;
  return new;
end$$;

-- ===========================================================================
-- N. Grants — write RPCs are SERVICE ROLE ONLY. Internal helpers are callable
--    from definer SQL only.
-- ===========================================================================
revoke all on function public._integration_api_ts(text)                                       from public, anon, authenticated;
revoke all on function public._integration_api_date(text)                                     from public, anon, authenticated;
revoke all on function public._integration_api_uuid(text)                                     from public, anon, authenticated;
revoke all on function public._integration_api_hash(jsonb)                                    from public, anon, authenticated;
revoke all on function public._integration_api_unknown_keys(jsonb, text[])                    from public, anon, authenticated;
revoke all on function public._integration_api_el_stage_label(text)                           from public, anon, authenticated;
revoke all on function public._integration_api_idem_begin(uuid, text, text, text)             from public, anon, authenticated;
revoke all on function public._integration_api_idem_store(uuid, text, uuid, integer, jsonb)   from public, anon, authenticated;
revoke all on function public._integration_api_work_task_json(uuid)                           from public, anon, authenticated;
revoke all on function public._integration_api_fuel_record_json(uuid)                         from public, anon, authenticated;
revoke all on function public._integration_api_irrigation_json(uuid)                          from public, anon, authenticated;
revoke all on function public._integration_api_growth_stage_json(uuid)                        from public, anon, authenticated;
revoke all on function public._integration_api_yield_record_json(uuid)                        from public, anon, authenticated;
revoke all on function public._integration_api_yield_blocks(uuid, jsonb, jsonb)               from public, anon, authenticated;
revoke all on function public._integration_evt_provenance(text, text)                         from public, anon, authenticated;

revoke all on function public.integration_api_create_work_task(text, uuid, text, jsonb)       from public, anon, authenticated;
revoke all on function public.integration_api_update_work_task(text, uuid, jsonb)             from public, anon, authenticated;
revoke all on function public.integration_api_create_fuel_record(text, uuid, text, jsonb)     from public, anon, authenticated;
revoke all on function public.integration_api_update_fuel_record(text, uuid, jsonb)           from public, anon, authenticated;
revoke all on function public.integration_api_create_irrigation_record(text, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.integration_api_create_growth_stage(text, uuid, text, jsonb)    from public, anon, authenticated;
revoke all on function public.integration_api_create_yield_record(text, uuid, text, jsonb)    from public, anon, authenticated;
revoke all on function public.integration_api_update_yield_record(text, uuid, jsonb)          from public, anon, authenticated;

grant execute on function public.integration_api_create_work_task(text, uuid, text, jsonb)       to service_role;
grant execute on function public.integration_api_update_work_task(text, uuid, jsonb)             to service_role;
grant execute on function public.integration_api_create_fuel_record(text, uuid, text, jsonb)     to service_role;
grant execute on function public.integration_api_update_fuel_record(text, uuid, jsonb)           to service_role;
grant execute on function public.integration_api_create_irrigation_record(text, uuid, text, jsonb) to service_role;
grant execute on function public.integration_api_create_growth_stage(text, uuid, text, jsonb)    to service_role;
grant execute on function public.integration_api_create_yield_record(text, uuid, text, jsonb)    to service_role;
grant execute on function public.integration_api_update_yield_record(text, uuid, jsonb)          to service_role;

commit;

notify pgrst, 'reload schema';

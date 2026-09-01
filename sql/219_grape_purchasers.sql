-- =====================================================================
-- 219_grape_purchasers.sql — Purchaser foundation for Grape Allocations
-- =====================================================================
-- Small reusable vineyard purchaser book (NOT a CRM) + optional
-- purchaser link on grape allocations.
--
-- Design decisions (mirroring existing house contracts):
--
--   * grape_purchasers stores winery/contact details ONLY — no financial
--     data ever lands in this table. Deliberately small: no tags, no
--     history, no reminders, no documents.
--   * grape_allocations gains a NULLABLE purchaser_id. The existing
--     purchaser_name / contact_* columns on each allocation are kept as
--     HISTORICAL SNAPSHOTS: selecting a saved purchaser copies its
--     CURRENT details onto the allocation, and later edits to the
--     purchaser must never rewrite old allocation snapshots.
--   * purchaser_id is only valid for allocation_type = 'external'
--     (CHECK constraint) and must reference a purchaser of the SAME
--     vineyard (BEFORE trigger — authoritative regardless of client).
--   * Existing allocations without purchaser_id remain fully valid; the
--     API keeps accepting explicit snapshot purchaser fields.
--   * Purchasers are soft-delete only (RLS delete policy = false +
--     soft_delete_grape_purchaser RPC). An allocation that references a
--     since-deleted purchaser keeps working: the vineyard-match trigger
--     intentionally ignores deleted_at, while NEW links through the API
--     RPCs require a live purchaser.
--   * External API: grape_purchasers:read / grape_purchasers:write
--     scopes + integration_api_create/update_grape_purchaser RPCs follow
--     sql/186 (five-check auth, Idempotency-Key, expected_updated_at,
--     field validation, provenance, audit, representation builder).
--   * The two grape-allocation write RPCs are re-created (byte-identical
--     to sql/218 apart from purchaser_id support): when purchaser_id is
--     supplied for an external allocation the RPC resolves it inside the
--     same vineyard and snapshots its current contact details onto the
--     allocation. purchaser_id is mutually exclusive with explicit
--     purchaser/contact snapshot fields in the same payload.
--   * SQL 217/218 financial architecture is UNCHANGED: routing trigger,
--     costs:read read gate, costs:write write gate, owner/manager-only
--     companion table.
--
-- Verification: sql/tests/219_grape_purchasers_tests.sql
-- =====================================================================

-- ===========================================================================
-- A. Purchaser table
-- ===========================================================================
create table if not exists public.grape_purchasers (
  id                 uuid primary key default gen_random_uuid(),
  vineyard_id        uuid not null references public.vineyards(id) on delete cascade,
  winery_name        text not null check (btrim(winery_name) <> ''),
  contact_name       text null,
  contact_email      text null,
  contact_phone      text null,
  contact_address    text null,

  -- Integration provenance (sql/186 convention).
  origin             text not null default 'app',
  integration_client_id uuid null,
  integration_api_key_id uuid null,
  updated_by_integration_client_id uuid null,
  external_id        text null,

  created_by         uuid references auth.users(id),
  updated_by         uuid references auth.users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz null,
  client_updated_at  timestamptz null,
  sync_version       integer not null default 1
);

create index if not exists idx_grape_purchasers_vineyard
  on public.grape_purchasers (vineyard_id);
create index if not exists idx_grape_purchasers_updated_at
  on public.grape_purchasers (updated_at);
create index if not exists idx_grape_purchasers_created_at_id
  on public.grape_purchasers (created_at, id);
create unique index if not exists idx_grape_purchasers_external_id
  on public.grape_purchasers (integration_client_id, external_id)
  where external_id is not null and deleted_at is null;

create or replace trigger grape_purchasers_set_updated_at
before update on public.grape_purchasers
for each row execute function public.set_updated_at();

-- ===========================================================================
-- B. RLS — canonical 4-policy member set (sql/196 shape). Purchaser and
--    contact details are ordinary operational data readable by any member;
--    NO financial data belongs in this table.
-- ===========================================================================
alter table public.grape_purchasers enable row level security;

drop policy if exists "grape_purchasers_select_members" on public.grape_purchasers;
create policy "grape_purchasers_select_members"
on public.grape_purchasers for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "grape_purchasers_insert_members" on public.grape_purchasers;
create policy "grape_purchasers_insert_members"
on public.grape_purchasers for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "grape_purchasers_update_members" on public.grape_purchasers;
create policy "grape_purchasers_update_members"
on public.grape_purchasers for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "grape_purchasers_no_client_hard_delete" on public.grape_purchasers;
create policy "grape_purchasers_no_client_hard_delete"
on public.grape_purchasers for delete
to authenticated
using (false);

grant select, insert, update on public.grape_purchasers to authenticated;

-- ===========================================================================
-- C. purchaser_id on grape_allocations
-- ===========================================================================
alter table public.grape_allocations
  add column if not exists purchaser_id uuid null references public.grape_purchasers(id) on delete set null;

create index if not exists idx_grape_allocations_purchaser
  on public.grape_allocations (purchaser_id) where purchaser_id is not null;

-- Own Use must have no purchaser link (mirrors the sql/217 snapshot-field
-- constraint grape_allocations_own_use_no_purchaser).
do $$
begin
  alter table public.grape_allocations
    add constraint grape_allocations_own_use_no_purchaser_link
    check (allocation_type = 'external' or purchaser_id is null);
exception when duplicate_object then null;
end $$;

-- Same-vineyard enforcement, authoritative regardless of client. deleted_at
-- is intentionally NOT checked here so allocations referencing a
-- since-soft-deleted purchaser keep saving; NEW links through the API RPCs
-- require a live purchaser.
create or replace function public.grape_allocations_validate_purchaser()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.purchaser_id is not null then
    if not exists (
      select 1 from public.grape_purchasers gp
      where gp.id = new.purchaser_id and gp.vineyard_id = new.vineyard_id
    ) then
      raise exception 'purchaser does not belong to this vineyard'
        using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists grape_allocations_validate_purchaser on public.grape_allocations;
create trigger grape_allocations_validate_purchaser
before insert or update on public.grape_allocations
for each row execute function public.grape_allocations_validate_purchaser();

-- ===========================================================================
-- D. App RPC — soft delete (mirrors soft_delete_grape_allocation)
-- ===========================================================================
create or replace function public.soft_delete_grape_purchaser(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vineyard uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select vineyard_id into v_vineyard
    from public.grape_purchasers
   where id = p_id and deleted_at is null;
  if v_vineyard is null then
    return;
  end if;

  if not public.has_vineyard_role(v_vineyard, array['owner','manager','supervisor','operator']) then
    raise exception 'Vineyard membership required' using errcode = '42501';
  end if;

  update public.grape_purchasers
     set deleted_at = now(),
         updated_by = auth.uid(),
         sync_version = sync_version + 1
   where id = p_id;
end;
$$;

revoke all on function public.soft_delete_grape_purchaser(uuid) from public;
grant execute on function public.soft_delete_grape_purchaser(uuid) to authenticated;

-- ===========================================================================
-- E. Integration scopes
-- ===========================================================================
insert into public.integration_scope_catalog (scope, module, access, is_sensitive, description) values
  ('grape_purchasers:read',  'grape_purchasers', 'read',  false, 'Read saved grape purchasers (vineyard winery contact book; contains no financial data)'),
  ('grape_purchasers:write', 'grape_purchasers', 'write', false, 'Create/update saved grape purchasers')
on conflict (scope) do nothing;

-- ===========================================================================
-- F. Public representation builder — byte-compatible with the gateway's
--    GET mapper.
-- ===========================================================================
create or replace function public._integration_api_grape_purchaser_json(p_id uuid)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'id', gp.id,
    'vineyard_id', gp.vineyard_id,
    'winery_name', gp.winery_name,
    'contact_name', gp.contact_name,
    'contact_email', gp.contact_email,
    'contact_phone', gp.contact_phone,
    'contact_address', gp.contact_address,
    'origin', gp.origin,
    'external_id', gp.external_id,
    'created_at', gp.created_at,
    'updated_at', gp.updated_at)
  from public.grape_purchasers gp
  where gp.id = p_id;
$$;

-- ===========================================================================
-- G. POST /v1/grape-purchasers
-- ===========================================================================
create or replace function public.integration_api_create_grape_purchaser(
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
  v_name text; v_c_name text; v_c_email text; v_c_phone text; v_c_address text;
  v_external_id text;
  v_data jsonb;
begin
  v_auth := public.integration_validate_api_request(p_presented_key, 'grape_purchasers:write', p_vineyard_id);
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
    'winery_name', 'contact_name', 'contact_email', 'contact_phone', 'contact_address', 'external_id']);

  -- winery_name: required, 1-200 chars
  if jsonb_typeof(p_payload->'winery_name') is distinct from 'string'
     or btrim(p_payload->>'winery_name') = '' or char_length(p_payload->>'winery_name') > 200 then
    v_errors := v_errors || jsonb_build_object('field', 'winery_name', 'issue', 'required string, 1-200 characters');
  else
    v_name := btrim(p_payload->>'winery_name');
  end if;

  if p_payload ? 'contact_name' and jsonb_typeof(p_payload->'contact_name') <> 'null' then
    if jsonb_typeof(p_payload->'contact_name') <> 'string' or char_length(p_payload->>'contact_name') > 200 then
      v_errors := v_errors || jsonb_build_object('field', 'contact_name', 'issue', 'string up to 200 characters');
    else v_c_name := p_payload->>'contact_name'; end if;
  end if;
  if p_payload ? 'contact_email' and jsonb_typeof(p_payload->'contact_email') <> 'null' then
    if jsonb_typeof(p_payload->'contact_email') <> 'string' or char_length(p_payload->>'contact_email') > 320 then
      v_errors := v_errors || jsonb_build_object('field', 'contact_email', 'issue', 'string up to 320 characters');
    else v_c_email := p_payload->>'contact_email'; end if;
  end if;
  if p_payload ? 'contact_phone' and jsonb_typeof(p_payload->'contact_phone') <> 'null' then
    if jsonb_typeof(p_payload->'contact_phone') <> 'string' or char_length(p_payload->>'contact_phone') > 50 then
      v_errors := v_errors || jsonb_build_object('field', 'contact_phone', 'issue', 'string up to 50 characters');
    else v_c_phone := p_payload->>'contact_phone'; end if;
  end if;
  if p_payload ? 'contact_address' and jsonb_typeof(p_payload->'contact_address') <> 'null' then
    if jsonb_typeof(p_payload->'contact_address') <> 'string' or char_length(p_payload->>'contact_address') > 500 then
      v_errors := v_errors || jsonb_build_object('field', 'contact_address', 'issue', 'string up to 500 characters');
    else v_c_address := p_payload->>'contact_address'; end if;
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

  v_idem := public._integration_api_idem_begin(v_client, 'POST /v1/grape-purchasers', p_idempotency_key,
              public._integration_api_hash(p_payload || jsonb_build_object('vineyard_id', p_vineyard_id)));
  if v_idem->>'mode' = 'replay' then
    return jsonb_build_object('ok', true, 'status', (v_idem->>'status')::int, 'replayed', true, 'data', v_idem->'response');
  elsif v_idem->>'mode' = 'conflict' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_conflict');
  end if;
  v_idem_id := (v_idem->>'id')::uuid;

  begin
    insert into public.grape_purchasers (
      id, vineyard_id, winery_name,
      contact_name, contact_email, contact_phone, contact_address,
      origin, integration_client_id, integration_api_key_id, external_id,
      client_updated_at
    ) values (
      v_id, p_vineyard_id, v_name,
      v_c_name, v_c_email, v_c_phone, v_c_address,
      'integration', v_client, v_key, v_external_id,
      now()
    );
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another grape purchaser')));
  end;

  perform public._integration_audit(v_client, 'api.write.created', p_vineyard_id,
    jsonb_build_object('resource_type', 'grape_purchaser', 'resource_id', v_id,
      'external_id', v_external_id, 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_grape_purchaser_json(v_id);
  perform public._integration_api_idem_store(v_idem_id, 'grape_purchaser', v_id, 201, v_data);
  return jsonb_build_object('ok', true, 'status', 201, 'replayed', false, 'data', v_data);
end$$;

-- ===========================================================================
-- H. PATCH /v1/grape-purchasers/{id}
-- ===========================================================================
create or replace function public.integration_api_update_grape_purchaser(
  p_presented_key text,
  p_grape_purchaser_id uuid,
  p_payload jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_row public.grape_purchasers;
  v_auth jsonb; v_client uuid; v_key uuid;
  v_errors jsonb := '[]'::jsonb;
  v_expected timestamptz;
  v_changed text[] := '{}';
  k text;
  v_data jsonb;
begin
  if p_grape_purchaser_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  select * into v_row from public.grape_purchasers where id = p_grape_purchaser_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'resource_not_found');
  end if;

  v_auth := public.integration_validate_api_request(p_presented_key, 'grape_purchasers:write', v_row.vineyard_id);
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
    'expected_updated_at', 'winery_name', 'contact_name', 'contact_email',
    'contact_phone', 'contact_address', 'external_id']);

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

  for k in select jsonb_object_keys(p_payload) loop
    if k = 'expected_updated_at' then continue; end if;
    v_changed := v_changed || k;
    case k
      when 'winery_name' then
        if jsonb_typeof(p_payload->'winery_name') <> 'string'
           or btrim(p_payload->>'winery_name') = '' or char_length(p_payload->>'winery_name') > 200 then
          v_errors := v_errors || jsonb_build_object('field', 'winery_name', 'issue', 'string, 1-200 characters (not nullable)');
        else v_row.winery_name := btrim(p_payload->>'winery_name'); end if;
      when 'contact_name' then
        if jsonb_typeof(p_payload->'contact_name') = 'null' then v_row.contact_name := null;
        elsif jsonb_typeof(p_payload->'contact_name') <> 'string' or char_length(p_payload->>'contact_name') > 200 then
          v_errors := v_errors || jsonb_build_object('field', 'contact_name', 'issue', 'string up to 200 characters, or null to clear');
        else v_row.contact_name := p_payload->>'contact_name'; end if;
      when 'contact_email' then
        if jsonb_typeof(p_payload->'contact_email') = 'null' then v_row.contact_email := null;
        elsif jsonb_typeof(p_payload->'contact_email') <> 'string' or char_length(p_payload->>'contact_email') > 320 then
          v_errors := v_errors || jsonb_build_object('field', 'contact_email', 'issue', 'string up to 320 characters, or null to clear');
        else v_row.contact_email := p_payload->>'contact_email'; end if;
      when 'contact_phone' then
        if jsonb_typeof(p_payload->'contact_phone') = 'null' then v_row.contact_phone := null;
        elsif jsonb_typeof(p_payload->'contact_phone') <> 'string' or char_length(p_payload->>'contact_phone') > 50 then
          v_errors := v_errors || jsonb_build_object('field', 'contact_phone', 'issue', 'string up to 50 characters, or null to clear');
        else v_row.contact_phone := p_payload->>'contact_phone'; end if;
      when 'contact_address' then
        if jsonb_typeof(p_payload->'contact_address') = 'null' then v_row.contact_address := null;
        elsif jsonb_typeof(p_payload->'contact_address') <> 'string' or char_length(p_payload->>'contact_address') > 500 then
          v_errors := v_errors || jsonb_build_object('field', 'contact_address', 'issue', 'string up to 500 characters, or null to clear');
        else v_row.contact_address := p_payload->>'contact_address'; end if;
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

  begin
    update public.grape_purchasers set
      winery_name = v_row.winery_name,
      contact_name = v_row.contact_name, contact_email = v_row.contact_email,
      contact_phone = v_row.contact_phone, contact_address = v_row.contact_address,
      external_id = v_row.external_id,
      updated_by = null,
      updated_by_integration_client_id = v_client,
      client_updated_at = now(),
      sync_version = sync_version + 1
    where id = v_row.id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another grape purchaser')));
  end;

  perform public._integration_audit(v_client, 'api.write.updated', v_row.vineyard_id,
    jsonb_build_object('resource_type', 'grape_purchaser', 'resource_id', v_row.id,
      'changed_fields', to_jsonb(v_changed), 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_grape_purchaser_json(v_row.id);
  return jsonb_build_object('ok', true, 'status', 200, 'data', v_data);
end$$;

-- ===========================================================================
-- I. Grape allocation representation — additive purchaser_id.
-- ===========================================================================
create or replace function public._integration_api_grape_allocation_json(p_id uuid)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'id', ga.id,
    'vineyard_id', ga.vineyard_id,
    'vintage', ga.vintage,
    'allocation_type', ga.allocation_type,
    'variety_name', ga.variety_name,
    'variety_key', ga.variety_key,
    'destination_name', ga.destination_name,
    'quantity_tonnes', ga.quantity_tonnes,
    'notes', ga.notes,
    'purchaser_id', ga.purchaser_id,
    'purchaser_name', ga.purchaser_name,
    'contact_name', ga.contact_name,
    'contact_email', ga.contact_email,
    'contact_phone', ga.contact_phone,
    'contact_address', ga.contact_address,
    'blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_id', b.paddock_id,
               'name', b.paddock_name,
               'quantity_tonnes', b.quantity_tonnes)
             order by b.paddock_name, b.paddock_id)
      from public.grape_allocation_blocks b
      where b.allocation_id = ga.id
    ), '[]'::jsonb),
    'origin', ga.origin,
    'external_id', ga.external_id,
    'created_at', ga.created_at,
    'updated_at', ga.updated_at)
  from public.grape_allocations ga
  where ga.id = p_id;
$$;

-- ===========================================================================
-- J. POST /v1/grape-allocations — re-created from sql/218 with additive
--    purchaser_id support. Financial gates (costs:write) and the
--    vinetrack.integration_financial_write routing flag are UNCHANGED.
-- ===========================================================================
create or replace function public.integration_api_create_grape_allocation(
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
  v_vintage integer; v_type text; v_variety text; v_variety_key text;
  v_destination text; v_tonnes double precision; v_notes text;
  v_purchaser text; v_c_name text; v_c_email text; v_c_phone text; v_c_address text;
  v_purchaser_id uuid;
  v_p public.grape_purchasers;
  v_price double precision;
  v_external_id text;
  v_blocks jsonb := '[]'::jsonb;
  v_block jsonb; v_u uuid; v_bq double precision;
  v_seen uuid[] := '{}';
  v_data jsonb;
begin
  v_auth := public.integration_validate_api_request(p_presented_key, 'grape_allocations:write', p_vineyard_id);
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
    'vintage', 'allocation_type', 'variety_name', 'variety_key',
    'destination_name', 'quantity_tonnes', 'notes',
    'purchaser_id',
    'purchaser_name', 'contact_name', 'contact_email', 'contact_phone', 'contact_address',
    'price_per_tonne', 'blocks', 'external_id']);

  -- vintage: required integer 2000-2100
  if jsonb_typeof(p_payload->'vintage') is distinct from 'number'
     or (p_payload->>'vintage')::numeric <> floor((p_payload->>'vintage')::numeric)
     or (p_payload->>'vintage')::numeric not between 2000 and 2100 then
    v_errors := v_errors || jsonb_build_object('field', 'vintage', 'issue', 'required integer between 2000 and 2100');
  else
    v_vintage := (p_payload->>'vintage')::integer;
  end if;

  -- allocation_type: required enum
  if jsonb_typeof(p_payload->'allocation_type') is distinct from 'string'
     or p_payload->>'allocation_type' not in ('own_use', 'external') then
    v_errors := v_errors || jsonb_build_object('field', 'allocation_type', 'issue', 'required, one of own_use | external');
  else
    v_type := p_payload->>'allocation_type';
  end if;

  -- variety_name: required, 1-100 chars
  if jsonb_typeof(p_payload->'variety_name') is distinct from 'string'
     or btrim(p_payload->>'variety_name') = '' or char_length(p_payload->>'variety_name') > 100 then
    v_errors := v_errors || jsonb_build_object('field', 'variety_name', 'issue', 'required string, 1-100 characters');
  else
    v_variety := btrim(p_payload->>'variety_name');
  end if;

  if p_payload ? 'variety_key' and jsonb_typeof(p_payload->'variety_key') <> 'null' then
    if jsonb_typeof(p_payload->'variety_key') <> 'string' or char_length(p_payload->>'variety_key') > 200 then
      v_errors := v_errors || jsonb_build_object('field', 'variety_key', 'issue', 'string up to 200 characters');
    else v_variety_key := p_payload->>'variety_key'; end if;
  end if;

  if p_payload ? 'destination_name' and jsonb_typeof(p_payload->'destination_name') <> 'null' then
    if jsonb_typeof(p_payload->'destination_name') <> 'string' or char_length(p_payload->>'destination_name') > 200 then
      v_errors := v_errors || jsonb_build_object('field', 'destination_name', 'issue', 'string up to 200 characters');
    else v_destination := p_payload->>'destination_name'; end if;
  end if;

  -- quantity_tonnes: required, > 0
  if jsonb_typeof(p_payload->'quantity_tonnes') is distinct from 'number'
     or (p_payload->>'quantity_tonnes')::numeric <= 0 then
    v_errors := v_errors || jsonb_build_object('field', 'quantity_tonnes', 'issue', 'required number greater than 0');
  else
    v_tonnes := (p_payload->>'quantity_tonnes')::double precision;
  end if;

  if p_payload ? 'notes' and jsonb_typeof(p_payload->'notes') <> 'null' then
    if jsonb_typeof(p_payload->'notes') <> 'string' or char_length(p_payload->>'notes') > 4000 then
      v_errors := v_errors || jsonb_build_object('field', 'notes', 'issue', 'string up to 4000 characters');
    else v_notes := p_payload->>'notes'; end if;
  end if;

  -- External-only fields
  if p_payload ? 'purchaser_name' and jsonb_typeof(p_payload->'purchaser_name') <> 'null' then
    if jsonb_typeof(p_payload->'purchaser_name') <> 'string' or char_length(p_payload->>'purchaser_name') > 200 then
      v_errors := v_errors || jsonb_build_object('field', 'purchaser_name', 'issue', 'string up to 200 characters');
    else v_purchaser := p_payload->>'purchaser_name'; end if;
  end if;
  if p_payload ? 'contact_name' and jsonb_typeof(p_payload->'contact_name') <> 'null' then
    if jsonb_typeof(p_payload->'contact_name') <> 'string' or char_length(p_payload->>'contact_name') > 200 then
      v_errors := v_errors || jsonb_build_object('field', 'contact_name', 'issue', 'string up to 200 characters');
    else v_c_name := p_payload->>'contact_name'; end if;
  end if;
  if p_payload ? 'contact_email' and jsonb_typeof(p_payload->'contact_email') <> 'null' then
    if jsonb_typeof(p_payload->'contact_email') <> 'string' or char_length(p_payload->>'contact_email') > 320 then
      v_errors := v_errors || jsonb_build_object('field', 'contact_email', 'issue', 'string up to 320 characters');
    else v_c_email := p_payload->>'contact_email'; end if;
  end if;
  if p_payload ? 'contact_phone' and jsonb_typeof(p_payload->'contact_phone') <> 'null' then
    if jsonb_typeof(p_payload->'contact_phone') <> 'string' or char_length(p_payload->>'contact_phone') > 50 then
      v_errors := v_errors || jsonb_build_object('field', 'contact_phone', 'issue', 'string up to 50 characters');
    else v_c_phone := p_payload->>'contact_phone'; end if;
  end if;
  if p_payload ? 'contact_address' and jsonb_typeof(p_payload->'contact_address') <> 'null' then
    if jsonb_typeof(p_payload->'contact_address') <> 'string' or char_length(p_payload->>'contact_address') > 500 then
      v_errors := v_errors || jsonb_build_object('field', 'contact_address', 'issue', 'string up to 500 characters');
    else v_c_address := p_payload->>'contact_address'; end if;
  end if;

  if v_type = 'own_use'
     and (v_purchaser is not null or v_c_name is not null or v_c_email is not null
          or v_c_phone is not null or v_c_address is not null) then
    v_errors := v_errors || jsonb_build_object('field', 'allocation_type', 'issue', 'purchaser/contact fields are only valid for external allocations');
  end if;

  -- purchaser_id (sql/219): external only; resolves a saved vineyard
  -- purchaser and snapshots its CURRENT details onto the allocation.
  -- Mutually exclusive with explicit purchaser/contact snapshot fields —
  -- one deterministic source per write.
  if p_payload ? 'purchaser_id' and jsonb_typeof(p_payload->'purchaser_id') <> 'null' then
    if (p_payload ? 'purchaser_name' and jsonb_typeof(p_payload->'purchaser_name') <> 'null')
       or (p_payload ? 'contact_name' and jsonb_typeof(p_payload->'contact_name') <> 'null')
       or (p_payload ? 'contact_email' and jsonb_typeof(p_payload->'contact_email') <> 'null')
       or (p_payload ? 'contact_phone' and jsonb_typeof(p_payload->'contact_phone') <> 'null')
       or (p_payload ? 'contact_address' and jsonb_typeof(p_payload->'contact_address') <> 'null') then
      v_errors := v_errors || jsonb_build_object('field', 'purchaser_id', 'issue', 'provide either purchaser_id or explicit purchaser/contact fields, not both');
    elsif v_type = 'own_use' then
      v_errors := v_errors || jsonb_build_object('field', 'purchaser_id', 'issue', 'only valid for external allocations');
    else
      v_purchaser_id := public._integration_api_uuid(p_payload->>'purchaser_id');
      if v_purchaser_id is null then
        v_errors := v_errors || jsonb_build_object('field', 'purchaser_id', 'issue', 'must be a UUID');
      else
        select * into v_p from public.grape_purchasers gp
         where gp.id = v_purchaser_id and gp.vineyard_id = p_vineyard_id and gp.deleted_at is null;
        if not found then
          v_errors := v_errors || jsonb_build_object('field', 'purchaser_id', 'issue', 'purchaser does not exist in this vineyard');
          v_purchaser_id := null;
        else
          v_purchaser := v_p.winery_name;
          v_c_name := v_p.contact_name;
          v_c_email := v_p.contact_email;
          v_c_phone := v_p.contact_phone;
          v_c_address := v_p.contact_address;
        end if;
      end if;
    end if;
  end if;

  -- price_per_tonne: external only, requires the costs:write grant (sql/218).
  if p_payload ? 'price_per_tonne' and jsonb_typeof(p_payload->'price_per_tonne') <> 'null' then
    if not public._integration_client_has_scope(v_client, 'costs:write') then
      v_errors := v_errors || jsonb_build_object('field', 'price_per_tonne', 'issue', 'requires the costs:write scope');
    elsif v_type = 'own_use' then
      v_errors := v_errors || jsonb_build_object('field', 'price_per_tonne', 'issue', 'only valid for external allocations');
    elsif jsonb_typeof(p_payload->'price_per_tonne') <> 'number' or (p_payload->>'price_per_tonne')::numeric < 0 then
      v_errors := v_errors || jsonb_build_object('field', 'price_per_tonne', 'issue', 'non-negative number');
    else v_price := (p_payload->>'price_per_tonne')::double precision; end if;
  end if;

  -- blocks: optional array of { block_id, quantity_tonnes? }
  if p_payload ? 'blocks' and jsonb_typeof(p_payload->'blocks') <> 'null' then
    if jsonb_typeof(p_payload->'blocks') <> 'array' then
      v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'array of { block_id, quantity_tonnes? }');
    else
      for v_block in select value from jsonb_array_elements(p_payload->'blocks') loop
        if jsonb_typeof(v_block) <> 'object' then
          v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'each entry must be an object with block_id');
          continue;
        end if;
        v_u := public._integration_api_uuid(v_block->>'block_id');
        if v_u is null then
          v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'contains an invalid block_id');
        elsif not exists (select 1 from public.paddocks p
                          where p.id = v_u and p.vineyard_id = p_vineyard_id and p.deleted_at is null) then
          v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'block ' || (v_block->>'block_id') || ' does not exist in this vineyard');
        elsif v_u = any (v_seen) then
          v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'duplicate block ' || (v_block->>'block_id'));
        else
          v_bq := null;
          if v_block ? 'quantity_tonnes' and jsonb_typeof(v_block->'quantity_tonnes') <> 'null' then
            if jsonb_typeof(v_block->'quantity_tonnes') <> 'number' or (v_block->>'quantity_tonnes')::numeric <= 0 then
              v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'quantity_tonnes must be a number greater than 0');
              continue;
            end if;
            v_bq := (v_block->>'quantity_tonnes')::double precision;
          end if;
          v_seen := v_seen || v_u;
          v_blocks := v_blocks || jsonb_build_object('block_id', v_u, 'quantity_tonnes', v_bq);
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

  v_idem := public._integration_api_idem_begin(v_client, 'POST /v1/grape-allocations', p_idempotency_key,
              public._integration_api_hash(p_payload || jsonb_build_object('vineyard_id', p_vineyard_id)));
  if v_idem->>'mode' = 'replay' then
    return jsonb_build_object('ok', true, 'status', (v_idem->>'status')::int, 'replayed', true, 'data', v_idem->'response');
  elsif v_idem->>'mode' = 'conflict' then
    return jsonb_build_object('ok', false, 'error', 'idempotency_conflict');
  end if;
  v_idem_id := (v_idem->>'id')::uuid;

  -- Mark this validated API write for the routing trigger (sql/218 header).
  perform set_config('vinetrack.integration_financial_write', 'on', true);
  begin
    insert into public.grape_allocations (
      id, vineyard_id, vintage, allocation_type,
      variety_key, variety_name, destination_name, quantity_tonnes, notes,
      purchaser_id,
      purchaser_name, contact_name, contact_email, contact_phone, contact_address,
      price_per_tonne,
      origin, integration_client_id, integration_api_key_id, external_id,
      client_updated_at
    ) values (
      v_id, p_vineyard_id, v_vintage, v_type,
      v_variety_key, v_variety, v_destination, v_tonnes, v_notes,
      v_purchaser_id,
      v_purchaser, v_c_name, v_c_email, v_c_phone, v_c_address,
      v_price,
      'integration', v_client, v_key, v_external_id,
      now()
    );
  exception when unique_violation then
    perform set_config('vinetrack.integration_financial_write', '', true);
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another grape allocation')));
  end;
  perform set_config('vinetrack.integration_financial_write', '', true);

  insert into public.grape_allocation_blocks (allocation_id, vineyard_id, paddock_id, paddock_name, quantity_tonnes)
  select v_id, p_vineyard_id, (b->>'block_id')::uuid,
         coalesce((select p.name from public.paddocks p where p.id = (b->>'block_id')::uuid), ''),
         (b->>'quantity_tonnes')::double precision
  from jsonb_array_elements(v_blocks) b;

  perform public._integration_audit(v_client, 'api.write.created', p_vineyard_id,
    jsonb_build_object('resource_type', 'grape_allocation', 'resource_id', v_id,
      'external_id', v_external_id, 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_grape_allocation_json(v_id);
  perform public._integration_api_idem_store(v_idem_id, 'grape_allocation', v_id, 201, v_data);
  return jsonb_build_object('ok', true, 'status', 201, 'replayed', false, 'data', v_data);
end$$;

-- ===========================================================================
-- K. PATCH /v1/grape-allocations/{id} — re-created from sql/218 with
--    additive purchaser_id support. Financial gates unchanged.
-- ===========================================================================
create or replace function public.integration_api_update_grape_allocation(
  p_presented_key text,
  p_grape_allocation_id uuid,
  p_payload jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_row public.grape_allocations;
  v_auth jsonb; v_client uuid; v_key uuid;
  v_errors jsonb := '[]'::jsonb;
  v_expected timestamptz;
  v_changed text[] := '{}';
  v_price double precision;
  v_price_touched boolean := false;
  v_blocks jsonb;
  v_block jsonb; v_u uuid; v_bq double precision;
  v_pu uuid;
  v_p public.grape_purchasers;
  v_seen uuid[] := '{}';
  k text;
  v_data jsonb;
begin
  if p_grape_allocation_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_request');
  end if;
  select * into v_row from public.grape_allocations where id = p_grape_allocation_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'resource_not_found');
  end if;

  v_auth := public.integration_validate_api_request(p_presented_key, 'grape_allocations:write', v_row.vineyard_id);
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
    'expected_updated_at', 'vintage', 'allocation_type', 'variety_name', 'variety_key',
    'destination_name', 'quantity_tonnes', 'notes',
    'purchaser_id',
    'purchaser_name', 'contact_name', 'contact_email', 'contact_phone', 'contact_address',
    'price_per_tonne', 'blocks', 'external_id']);

  -- Optimistic concurrency is REQUIRED on every PATCH.
  if jsonb_typeof(p_payload->'expected_updated_at') is distinct from 'string'
     or public._integration_api_ts(p_payload->>'expected_updated_at') is null then
    v_errors := v_errors || jsonb_build_object('field', 'expected_updated_at', 'issue', 'required ISO 8601 timestamp (the updated_at from your latest GET)');
  else
    v_expected := public._integration_api_ts(p_payload->>'expected_updated_at');
  end if;

  -- purchaser_id (sql/219) is mutually exclusive with explicit snapshot
  -- fields in the same payload — one deterministic source per write.
  if p_payload ? 'purchaser_id' and jsonb_typeof(p_payload->'purchaser_id') <> 'null'
     and (p_payload ? 'purchaser_name' or p_payload ? 'contact_name' or p_payload ? 'contact_email'
          or p_payload ? 'contact_phone' or p_payload ? 'contact_address') then
    v_errors := v_errors || jsonb_build_object('field', 'purchaser_id', 'issue', 'provide either purchaser_id or explicit purchaser/contact fields, not both');
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
      when 'vintage' then
        if jsonb_typeof(p_payload->'vintage') <> 'number'
           or (p_payload->>'vintage')::numeric <> floor((p_payload->>'vintage')::numeric)
           or (p_payload->>'vintage')::numeric not between 2000 and 2100 then
          v_errors := v_errors || jsonb_build_object('field', 'vintage', 'issue', 'integer between 2000 and 2100 (not nullable)');
        else v_row.vintage := (p_payload->>'vintage')::integer; end if;
      when 'allocation_type' then
        if jsonb_typeof(p_payload->'allocation_type') <> 'string'
           or p_payload->>'allocation_type' not in ('own_use', 'external') then
          v_errors := v_errors || jsonb_build_object('field', 'allocation_type', 'issue', 'one of own_use | external (not nullable)');
        else v_row.allocation_type := p_payload->>'allocation_type'; end if;
      when 'variety_name' then
        if jsonb_typeof(p_payload->'variety_name') <> 'string'
           or btrim(p_payload->>'variety_name') = '' or char_length(p_payload->>'variety_name') > 100 then
          v_errors := v_errors || jsonb_build_object('field', 'variety_name', 'issue', 'string, 1-100 characters (not nullable)');
        else v_row.variety_name := btrim(p_payload->>'variety_name'); end if;
      when 'variety_key' then
        if jsonb_typeof(p_payload->'variety_key') = 'null' then v_row.variety_key := null;
        elsif jsonb_typeof(p_payload->'variety_key') <> 'string' or char_length(p_payload->>'variety_key') > 200 then
          v_errors := v_errors || jsonb_build_object('field', 'variety_key', 'issue', 'string up to 200 characters, or null to clear');
        else v_row.variety_key := p_payload->>'variety_key'; end if;
      when 'destination_name' then
        if jsonb_typeof(p_payload->'destination_name') = 'null' then v_row.destination_name := null;
        elsif jsonb_typeof(p_payload->'destination_name') <> 'string' or char_length(p_payload->>'destination_name') > 200 then
          v_errors := v_errors || jsonb_build_object('field', 'destination_name', 'issue', 'string up to 200 characters, or null to clear');
        else v_row.destination_name := p_payload->>'destination_name'; end if;
      when 'quantity_tonnes' then
        if jsonb_typeof(p_payload->'quantity_tonnes') <> 'number' or (p_payload->>'quantity_tonnes')::numeric <= 0 then
          v_errors := v_errors || jsonb_build_object('field', 'quantity_tonnes', 'issue', 'number greater than 0 (not nullable)');
        else v_row.quantity_tonnes := (p_payload->>'quantity_tonnes')::double precision; end if;
      when 'notes' then
        if jsonb_typeof(p_payload->'notes') = 'null' then v_row.notes := null;
        elsif jsonb_typeof(p_payload->'notes') <> 'string' or char_length(p_payload->>'notes') > 4000 then
          v_errors := v_errors || jsonb_build_object('field', 'notes', 'issue', 'string up to 4000 characters, or null to clear');
        else v_row.notes := p_payload->>'notes'; end if;
      when 'purchaser_id' then
        if jsonb_typeof(p_payload->'purchaser_id') = 'null' then
          -- Unlink ONLY: the historical snapshot fields stay untouched.
          v_row.purchaser_id := null;
        else
          v_pu := public._integration_api_uuid(p_payload->>'purchaser_id');
          if v_pu is null then
            v_errors := v_errors || jsonb_build_object('field', 'purchaser_id', 'issue', 'must be a UUID, or null to unlink');
          else
            select * into v_p from public.grape_purchasers gp
             where gp.id = v_pu and gp.vineyard_id = v_row.vineyard_id and gp.deleted_at is null;
            if not found then
              v_errors := v_errors || jsonb_build_object('field', 'purchaser_id', 'issue', 'purchaser does not exist in this vineyard');
            else
              -- Snapshot the purchaser's CURRENT details onto the allocation.
              v_row.purchaser_id := v_pu;
              v_row.purchaser_name := v_p.winery_name;
              v_row.contact_name := v_p.contact_name;
              v_row.contact_email := v_p.contact_email;
              v_row.contact_phone := v_p.contact_phone;
              v_row.contact_address := v_p.contact_address;
            end if;
          end if;
        end if;
      when 'purchaser_name' then
        if jsonb_typeof(p_payload->'purchaser_name') = 'null' then v_row.purchaser_name := null;
        elsif jsonb_typeof(p_payload->'purchaser_name') <> 'string' or char_length(p_payload->>'purchaser_name') > 200 then
          v_errors := v_errors || jsonb_build_object('field', 'purchaser_name', 'issue', 'string up to 200 characters, or null to clear');
        else v_row.purchaser_name := p_payload->>'purchaser_name'; end if;
      when 'contact_name' then
        if jsonb_typeof(p_payload->'contact_name') = 'null' then v_row.contact_name := null;
        elsif jsonb_typeof(p_payload->'contact_name') <> 'string' or char_length(p_payload->>'contact_name') > 200 then
          v_errors := v_errors || jsonb_build_object('field', 'contact_name', 'issue', 'string up to 200 characters, or null to clear');
        else v_row.contact_name := p_payload->>'contact_name'; end if;
      when 'contact_email' then
        if jsonb_typeof(p_payload->'contact_email') = 'null' then v_row.contact_email := null;
        elsif jsonb_typeof(p_payload->'contact_email') <> 'string' or char_length(p_payload->>'contact_email') > 320 then
          v_errors := v_errors || jsonb_build_object('field', 'contact_email', 'issue', 'string up to 320 characters, or null to clear');
        else v_row.contact_email := p_payload->>'contact_email'; end if;
      when 'contact_phone' then
        if jsonb_typeof(p_payload->'contact_phone') = 'null' then v_row.contact_phone := null;
        elsif jsonb_typeof(p_payload->'contact_phone') <> 'string' or char_length(p_payload->>'contact_phone') > 50 then
          v_errors := v_errors || jsonb_build_object('field', 'contact_phone', 'issue', 'string up to 50 characters, or null to clear');
        else v_row.contact_phone := p_payload->>'contact_phone'; end if;
      when 'contact_address' then
        if jsonb_typeof(p_payload->'contact_address') = 'null' then v_row.contact_address := null;
        elsif jsonb_typeof(p_payload->'contact_address') <> 'string' or char_length(p_payload->>'contact_address') > 500 then
          v_errors := v_errors || jsonb_build_object('field', 'contact_address', 'issue', 'string up to 500 characters, or null to clear');
        else v_row.contact_address := p_payload->>'contact_address'; end if;
      when 'price_per_tonne' then
        if not public._integration_client_has_scope(v_client, 'costs:write') then
          v_errors := v_errors || jsonb_build_object('field', 'price_per_tonne', 'issue', 'requires the costs:write scope');
        elsif jsonb_typeof(p_payload->'price_per_tonne') = 'null' then
          v_price := null; v_price_touched := true;
        elsif jsonb_typeof(p_payload->'price_per_tonne') <> 'number' or (p_payload->>'price_per_tonne')::numeric < 0 then
          v_errors := v_errors || jsonb_build_object('field', 'price_per_tonne', 'issue', 'non-negative number, or null to clear');
        else
          v_price := (p_payload->>'price_per_tonne')::double precision; v_price_touched := true;
        end if;
      when 'blocks' then
        if jsonb_typeof(p_payload->'blocks') = 'null' then
          v_blocks := '[]'::jsonb;
        elsif jsonb_typeof(p_payload->'blocks') <> 'array' then
          v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'array of { block_id, quantity_tonnes? }, or null to clear');
        else
          v_blocks := '[]'::jsonb;
          for v_block in select value from jsonb_array_elements(p_payload->'blocks') loop
            if jsonb_typeof(v_block) <> 'object' then
              v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'each entry must be an object with block_id');
              continue;
            end if;
            v_u := public._integration_api_uuid(v_block->>'block_id');
            if v_u is null then
              v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'contains an invalid block_id');
            elsif not exists (select 1 from public.paddocks p
                              where p.id = v_u and p.vineyard_id = v_row.vineyard_id and p.deleted_at is null) then
              v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'block ' || (v_block->>'block_id') || ' does not exist in this vineyard');
            elsif v_u = any (v_seen) then
              v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'duplicate block ' || (v_block->>'block_id'));
            else
              v_bq := null;
              if v_block ? 'quantity_tonnes' and jsonb_typeof(v_block->'quantity_tonnes') <> 'null' then
                if jsonb_typeof(v_block->'quantity_tonnes') <> 'number' or (v_block->>'quantity_tonnes')::numeric <= 0 then
                  v_errors := v_errors || jsonb_build_object('field', 'blocks', 'issue', 'quantity_tonnes must be a number greater than 0');
                  continue;
                end if;
                v_bq := (v_block->>'quantity_tonnes')::double precision;
              end if;
              v_seen := v_seen || v_u;
              v_blocks := v_blocks || jsonb_build_object('block_id', v_u, 'quantity_tonnes', v_bq);
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

  if v_row.allocation_type = 'own_use' then
    -- Switching to own_use clears the commercial fields, including the
    -- purchaser link (sql/219). Snapshot fields on OTHER allocations are
    -- never touched.
    v_row.purchaser_id := null;
    v_row.purchaser_name := null; v_row.contact_name := null; v_row.contact_email := null;
    v_row.contact_phone := null; v_row.contact_address := null;
    v_price := null; v_price_touched := true;
  end if;

  -- Preserve the companion price when the payload didn't touch it: the
  -- routing trigger treats this security-definer update as a financial
  -- editor, so we must feed the current value back through it.
  if not v_price_touched then
    select f.price_per_tonne into v_price
      from public.grape_allocation_financials f
     where f.allocation_id = v_row.id;
  end if;

  if v_blocks is not null then
    delete from public.grape_allocation_blocks where allocation_id = v_row.id;
    insert into public.grape_allocation_blocks (allocation_id, vineyard_id, paddock_id, paddock_name, quantity_tonnes)
    select v_row.id, v_row.vineyard_id, (b->>'block_id')::uuid,
           coalesce((select p.name from public.paddocks p where p.id = (b->>'block_id')::uuid), ''),
           (b->>'quantity_tonnes')::double precision
    from jsonb_array_elements(v_blocks) b;
  end if;

  -- Mark this validated API write for the routing trigger (sql/218 header).
  perform set_config('vinetrack.integration_financial_write', 'on', true);
  begin
    update public.grape_allocations set
      vintage = v_row.vintage, allocation_type = v_row.allocation_type,
      variety_key = v_row.variety_key, variety_name = v_row.variety_name,
      destination_name = v_row.destination_name, quantity_tonnes = v_row.quantity_tonnes,
      notes = v_row.notes,
      purchaser_id = v_row.purchaser_id,
      purchaser_name = v_row.purchaser_name, contact_name = v_row.contact_name,
      contact_email = v_row.contact_email, contact_phone = v_row.contact_phone,
      contact_address = v_row.contact_address,
      price_per_tonne = v_price,
      external_id = v_row.external_id,
      updated_by = null,
      updated_by_integration_client_id = v_client,
      client_updated_at = now(),
      sync_version = sync_version + 1
    where id = v_row.id;
  exception when unique_violation then
    perform set_config('vinetrack.integration_financial_write', '', true);
    return jsonb_build_object('ok', false, 'error', 'conflict',
      'details', jsonb_build_array(jsonb_build_object('field', 'external_id', 'issue', 'already used by this integration for another grape allocation')));
  end;
  perform set_config('vinetrack.integration_financial_write', '', true);

  perform public._integration_audit(v_client, 'api.write.updated', v_row.vineyard_id,
    jsonb_build_object('resource_type', 'grape_allocation', 'resource_id', v_row.id,
      'changed_fields', to_jsonb(v_changed), 'api_key_id', v_key, 'source', 'external_api'));

  v_data := public._integration_api_grape_allocation_json(v_row.id);
  return jsonb_build_object('ok', true, 'status', 200, 'data', v_data);
end$$;

notify pgrst, 'reload schema';

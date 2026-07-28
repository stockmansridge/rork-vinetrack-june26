-- =============================================================================
-- 142: Irrigation Records Phase 2A — multi-provider controller import framework
--      with Galcon GSI as the first provider adapter.
--
-- Design principles (shared master contract for iOS / Android / Lovable Portal):
--   * PROVIDER-ADAPTER framework, not a Galcon-only schema. The Galcon-specific
--     knowledge lives in the `galcon_gsi` adapter descriptor + the Edge Function
--     `parse-galcon-irrigation-import` (file parsing) + `_galcon_classify_comment`
--     (status rules). Adding a provider = new descriptor + new parser; no table
--     or workflow rebuild.
--   * File parsing happens in the Edge Function; ALL rules (threshold, Test
--     programs, classification, duplicates, mapping, reconciliation, commit,
--     reversal) are enforced server-side in these RPCs. Clients can NEVER
--     insert imported sessions directly.
--   * Imported sessions are CANONICAL irrigation_sessions rows: they flow
--     through the existing block allocation (`_irrigation_valve_allocations` +
--     `_irrigation_allocate`), the existing snapshot freeze, and the existing
--     reporting RPCs untouched.
--   * FEATURE GATE: every import RPC requires a VineTrack System Administrator
--     who is a member of the vineyard (`_irrigation_import_require_admin`).
--     This is deliberately INDEPENDENT of `has_irrigation_records_access` so a
--     future role release of Irrigation Records does not open imports.
--   * Duplicate protection is layered: file hash (batch level), deterministic
--     event fingerprint (row level, format/file-name independent), and unique
--     partial indexes (database level) so the same controller event can never
--     create two sessions — even under concurrent commits or retries.
--
-- Canonical values introduced:
--   irrigation_sessions.source_type          += 'galcon_gsi_import'
--   irrigation_sessions.calculation_method   += 'controller_reported_volume'
--   irrigation_sessions.status: imported sessions use existing 'imported'.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Admin gate (import-specific, independent of the Phase 1 feature gate)
-- ---------------------------------------------------------------------------
create or replace function public._irrigation_import_require_admin(p_vineyard_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_vineyard_id is null then
    raise exception 'invalid_vineyard: vineyard is required';
  end if;
  if not (public.is_system_admin() and public.is_vineyard_member(p_vineyard_id)) then
    raise exception 'import_access_denied: Controller imports are restricted to VineTrack System Administrators';
  end if;
end;
$$;

revoke all on function public._irrigation_import_require_admin(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Canonical session values for controller imports
-- ---------------------------------------------------------------------------
alter table public.irrigation_sessions
  drop constraint if exists irrigation_sessions_source_check;
alter table public.irrigation_sessions
  add constraint irrigation_sessions_source_check
  check (source_type in ('manual_ios','manual_android','manual_portal',
                         'csv_import','controller_api','system_generated',
                         'galcon_gsi_import'));

alter table public.irrigation_sessions
  drop constraint if exists irrigation_sessions_method_check;
alter table public.irrigation_sessions
  add constraint irrigation_sessions_method_check
  check (calculation_method in ('configured_flow','session_flow','total_volume','meter_readings',
                                'controller_reported_volume'));

-- Session-side structural duplicate guard: one LIVE imported session per
-- controller event fingerprint per vineyard. Reversal (deleted_at set) frees
-- the fingerprint so a wrongly-mapped batch can be reversed and re-imported.
create unique index if not exists irrigation_sessions_import_event_uq
  on public.irrigation_sessions (vineyard_id, external_source_id)
  where external_source_id is not null
    and source_type = 'galcon_gsi_import'
    and deleted_at is null;

-- ---------------------------------------------------------------------------
-- 2. Import tables
-- ---------------------------------------------------------------------------

create table if not exists public.irrigation_import_provider_settings (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  provider text not null,
  external_controller_key text not null default '',   -- normalised unit name ('' = provider default)
  external_controller_name text null,
  timezone text null,                                  -- IANA tz used to build timestamps
  minimum_volume_litres numeric not null default 1000,
  volume_comparison text not null default 'greater_than',
  exclude_test_programs boolean not null default true,
  is_active boolean not null default true,
  last_imported_at timestamptz null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),

  constraint irrigation_import_settings_provider_check check (provider in ('galcon_gsi')),
  constraint irrigation_import_settings_comparison_check
    check (volume_comparison in ('greater_than','greater_than_or_equal')),
  constraint irrigation_import_settings_volume_check check (minimum_volume_litres >= 0)
);

create unique index if not exists irrigation_import_provider_settings_uq
  on public.irrigation_import_provider_settings (vineyard_id, provider, lower(external_controller_key));

create table if not exists public.irrigation_controller_valve_mappings (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  provider text not null,
  external_controller_key text not null default '',
  external_controller_name text null,
  external_valve_number integer null,
  external_station_code text null,       -- normalised upper-case, e.g. 'S12'
  external_valve_name text not null,     -- full name as seen in the export
  irrigation_system_id uuid null references public.irrigation_systems(id),
  irrigation_valve_id uuid null references public.irrigation_valves(id),
  is_ignored boolean not null default false,
  is_active boolean not null default true,
  mapping_source text not null default 'manual',   -- manual | auto_station | auto_valve_number
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  last_successfully_imported_at timestamptz null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),

  constraint irrigation_valve_mappings_provider_check check (provider in ('galcon_gsi')),
  constraint irrigation_valve_mappings_target_check
    check (is_ignored or irrigation_valve_id is not null),
  constraint irrigation_valve_mappings_identity_check
    check (external_station_code is not null or external_valve_number is not null)
);

-- One ACTIVE mapping per external valve identity per vineyard/provider/controller.
create unique index if not exists irrigation_valve_mappings_station_uq
  on public.irrigation_controller_valve_mappings
     (vineyard_id, provider, lower(external_controller_key), upper(external_station_code))
  where is_active and external_station_code is not null;

create unique index if not exists irrigation_valve_mappings_number_uq
  on public.irrigation_controller_valve_mappings
     (vineyard_id, provider, lower(external_controller_key), external_valve_number)
  where is_active and external_valve_number is not null;

create index if not exists irrigation_valve_mappings_vineyard_idx
  on public.irrigation_controller_valve_mappings (vineyard_id, provider);

create table if not exists public.irrigation_import_batches (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  provider text not null,
  external_controller_key text not null default '',
  file_name text not null,
  file_hash text not null,               -- sha256 of raw file bytes
  file_size integer null,
  worksheet_name text null,
  source_unit_name text null,
  timezone text null,
  status text not null default 'parsed',
  total_rows integer not null default 0,
  valid_rows integer not null default 0,
  review_rows integer not null default 0,
  ignored_rows integer not null default 0,
  error_rows integer not null default 0,
  duplicate_rows integer not null default 0,
  imported_sessions integer not null default 0,
  threshold_litres numeric not null default 1000,
  volume_comparison text not null default 'greater_than',
  exclude_test_programs boolean not null default true,
  reprocess_of_batch_id uuid null references public.irrigation_import_batches(id),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  completed_at timestamptz null,
  reversed_at timestamptz null,
  reversed_by uuid null references auth.users(id),

  constraint irrigation_import_batches_provider_check check (provider in ('galcon_gsi')),
  constraint irrigation_import_batches_status_check
    check (status in ('parsed','validated','partially_committed','committed','reversed','abandoned')),
  constraint irrigation_import_batches_comparison_check
    check (volume_comparison in ('greater_than','greater_than_or_equal'))
);

-- File-level structural duplicate guard: the same file content cannot be an
-- open/committed batch twice (validation-only reprocess batches are exempt).
create unique index if not exists irrigation_import_batches_file_uq
  on public.irrigation_import_batches (vineyard_id, provider, file_hash)
  where status not in ('reversed','abandoned') and reprocess_of_batch_id is null;

create index if not exists irrigation_import_batches_vineyard_idx
  on public.irrigation_import_batches (vineyard_id, created_at desc);

create table if not exists public.irrigation_import_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.irrigation_import_batches(id) on delete cascade,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  provider text not null,
  source_row_number integer not null,
  raw_payload jsonb not null,
  raw_row_hash text not null,
  event_fingerprint text null,
  parsed_date date null,
  parsed_start_time time null,
  parsed_end_time time null,
  parsed_duration_seconds integer null,
  parsed_water_litres numeric null,
  parsed_flow_litres_per_hour numeric null,
  original_water_value numeric null,
  original_water_unit text null,
  original_flow_value numeric null,
  original_flow_unit text null,
  external_valve_number integer null,
  external_station_code text null,
  external_valve_name text null,
  external_valve_label text null,
  matched_valve_id uuid null references public.irrigation_valves(id),
  matched_mapping_id uuid null references public.irrigation_controller_valve_mappings(id),
  program_name text null,
  source_comment text null,
  classification text null,
  primary_exclusion_reason text null,
  additional_reason_codes jsonb not null default '[]'::jsonb,
  validation_status text not null default 'pending',
  validation_errors jsonb not null default '[]'::jsonb,
  validation_warnings jsonb not null default '[]'::jsonb,
  water_flow_reconciliation text null,
  expected_water_litres numeric null,
  duplicate_status text not null default 'new',
  duplicate_reference uuid null,
  override_threshold boolean not null default false,
  override_test boolean not null default false,
  override_reason text null,
  override_by uuid null references auth.users(id),
  override_at timestamptz null,
  created_session_id uuid null references public.irrigation_sessions(id),
  is_reversed boolean not null default false,
  created_at timestamptz not null default now(),

  constraint irrigation_import_rows_status_check
    check (validation_status in ('pending','eligible','excluded','needs_review','error')),
  constraint irrigation_import_rows_duplicate_check
    check (duplicate_status in ('new','duplicate_imported','duplicate_ignored',
                                'duplicate_reviewed','possible_duplicate_changed_values')),
  constraint irrigation_import_rows_reconciliation_check
    check (water_flow_reconciliation is null or water_flow_reconciliation in
           ('reconciled','minor_rounding_difference','material_mismatch','cannot_compare'))
);

create unique index if not exists irrigation_import_rows_batch_row_uq
  on public.irrigation_import_rows (batch_id, source_row_number);

-- THE row-level structural guard: one LIVE session per event fingerprint per
-- vineyard/provider across ALL batches. Reversal marks rows is_reversed and
-- frees the fingerprint for a corrected re-import.
create unique index if not exists irrigation_import_rows_event_session_uq
  on public.irrigation_import_rows (vineyard_id, provider, event_fingerprint)
  where created_session_id is not null and not is_reversed;

-- One import row can only ever own one session.
create unique index if not exists irrigation_import_rows_session_uq
  on public.irrigation_import_rows (created_session_id)
  where created_session_id is not null;

create index if not exists irrigation_import_rows_batch_idx
  on public.irrigation_import_rows (batch_id, source_row_number);
create index if not exists irrigation_import_rows_fingerprint_idx
  on public.irrigation_import_rows (vineyard_id, provider, event_fingerprint);

-- updated_at triggers
create or replace trigger irrigation_import_provider_settings_set_updated_at
before update on public.irrigation_import_provider_settings
for each row execute function public.set_updated_at();

create or replace trigger irrigation_controller_valve_mappings_set_updated_at
before update on public.irrigation_controller_valve_mappings
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. RLS — SELECT for System Administrators of the vineyard; RPC-only writes.
-- ---------------------------------------------------------------------------
alter table public.irrigation_import_provider_settings enable row level security;
alter table public.irrigation_controller_valve_mappings enable row level security;
alter table public.irrigation_import_batches enable row level security;
alter table public.irrigation_import_rows enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['irrigation_import_provider_settings',
                           'irrigation_controller_valve_mappings',
                           'irrigation_import_batches',
                           'irrigation_import_rows']
  loop
    execute format('drop policy if exists "%s_select_admin" on public.%I', t, t);
    execute format(
      'create policy "%s_select_admin" on public.%I for select to authenticated
       using (public.is_system_admin() and public.is_vineyard_member(vineyard_id))', t, t);
    -- No insert/update/delete policies: writes only via security-definer RPCs.
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Pure helpers (adapter-shared)
-- ---------------------------------------------------------------------------

-- Whitespace/case normalisation used for fingerprints and comment matching.
create or replace function public._irrigation_import_normalise_text(p_text text)
returns text
language sql
immutable
as $$
  select lower(regexp_replace(trim(coalesce(p_text, '')), '\s+', ' ', 'g'));
$$;

-- Galcon GSI comment/status classification. Tolerates punctuation variants
-- ("Cancel (Valve canceled manually)" vs "Cancel — Valve cancelled manually"),
-- US/UK spelling and stray whitespace.
create or replace function public._galcon_classify_comment(p_comment text)
returns text
language plpgsql
immutable
as $$
declare
  v text;
begin
  v := lower(regexp_replace(trim(coalesce(p_comment, '')), '[^a-z0-9]+', ' ', 'gi'));
  v := trim(regexp_replace(v, '\s+', ' ', 'g'));
  if v = '' then return 'unknown_comment'; end if;
  if v = 'ok' then return 'completed'; end if;
  if v like '%ended manually%' then return 'ended_manually'; end if;
  if v like '%not enabled%' then return 'cancelled_not_enabled'; end if;
  if v like '%cancel%' and v like '%manual%' then return 'cancelled_manual'; end if;
  if v like '%cancel%' and v like '%error%' then return 'cancelled_error'; end if;
  if v like '%no water flow%' then return 'no_flow_error'; end if;
  if v like '%low flow%' then return 'low_flow_error'; end if;
  if v like '%high flow%' then return 'high_flow_error'; end if;
  if v like '%paused%' then return 'paused'; end if;
  if v like '%continue%' then return 'continued'; end if;
  return 'unknown_comment';
end;
$$;

grant execute on function public._galcon_classify_comment(text) to authenticated;

-- Canonical numeric rendering for fingerprints (stable across xlsx/csv/json).
create or replace function public._irrigation_import_num_text(p_value numeric)
returns text
language sql
immutable
as $$
  select case when p_value is null then ''
              else to_char(round(p_value, 3), 'FM999999999999990.000') end;
$$;

-- Deterministic event fingerprint — independent of file name, worksheet name,
-- row order, source row number and xlsx-vs-csv format.
create or replace function public._irrigation_import_fingerprint(
  p_provider text,
  p_vineyard_id uuid,
  p_controller_key text,
  p_station_code text,
  p_valve_number integer,
  p_date date,
  p_start_time time,
  p_end_time time,
  p_runtime_seconds integer,
  p_water_litres numeric,
  p_flow_litres_per_hour numeric,
  p_comment text,
  p_program text
) returns text
language sql
immutable
set search_path = public, extensions
as $$
  select encode(digest(concat_ws('|',
    lower(trim(coalesce(p_provider, ''))),
    p_vineyard_id::text,
    public._irrigation_import_normalise_text(p_controller_key),
    upper(trim(coalesce(p_station_code, ''))),
    coalesce(p_valve_number::text, ''),
    coalesce(to_char(p_date, 'YYYY-MM-DD'), ''),
    coalesce(to_char(p_start_time, 'HH24:MI:SS'), ''),
    coalesce(to_char(p_end_time, 'HH24:MI:SS'), ''),
    coalesce(p_runtime_seconds::text, ''),
    public._irrigation_import_num_text(p_water_litres),
    public._irrigation_import_num_text(p_flow_litres_per_hour),
    public._irrigation_import_normalise_text(p_comment),
    public._irrigation_import_normalise_text(p_program)
  ), 'sha256'), 'hex');
$$;

grant execute on function public._irrigation_import_fingerprint(text, uuid, text, text, integer, date, time, time, integer, numeric, numeric, text, text) to authenticated;

-- Threshold comparison (configured per vineyard/provider, snapshotted per batch).
create or replace function public._irrigation_import_passes_threshold(
  p_water_litres numeric,
  p_threshold_litres numeric,
  p_comparison text
) returns boolean
language sql
immutable
as $$
  select case
    when p_water_litres is null then false
    when p_comparison = 'greater_than_or_equal' then p_water_litres >= p_threshold_litres
    else p_water_litres > p_threshold_litres
  end;
$$;

grant execute on function public._irrigation_import_passes_threshold(numeric, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Provider adapter registry
-- ---------------------------------------------------------------------------
create or replace function public.list_irrigation_import_providers()
returns jsonb
language sql
stable
as $$
  select jsonb_build_array(
    jsonb_build_object(
      'provider_id', 'galcon_gsi',
      'display_name', 'Galcon GSI',
      'supported_file_types', jsonb_build_array('xlsx', 'csv'),
      'max_file_size_bytes', 10485760,
      'max_source_rows', 50000,
      'required_headers', jsonb_build_array(
        'Unit Name','Date','Start Time','End Time','Program','Valve Name',
        'Run Time','Water Quantity','Average Flow','Comment'),
      'optional_headers', jsonb_build_array(
        'Irrigation Head','Fert Program Name','Fertilizer Quantity'),
      'date_format', 'DD/MM/YYYY',
      'time_format', 'HH:mm:ss',
      'volume_units', 'm3',
      'flow_units', 'm3_per_hour',
      'canonical_volume_units', 'litres',
      'canonical_flow_units', 'litres_per_hour',
      'default_import_thresholds', jsonb_build_object(
        'minimum_import_volume_litres', 1000,
        'comparison', 'greater_than',
        'exclude_test_programs', true),
      'parser_edge_function', 'parse-galcon-irrigation-import'
    )
  );
$$;

grant execute on function public.list_irrigation_import_providers() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Provider settings
-- ---------------------------------------------------------------------------
create or replace function public.get_irrigation_import_provider_settings(
  p_vineyard_id uuid,
  p_provider text,
  p_external_controller_key text default ''
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_row public.irrigation_import_provider_settings;
begin
  perform public._irrigation_import_require_admin(p_vineyard_id);
  select * into v_row
  from public.irrigation_import_provider_settings
  where vineyard_id = p_vineyard_id and provider = p_provider
    and lower(external_controller_key) = lower(coalesce(p_external_controller_key, ''));
  if not found then
    -- Provider defaults (not persisted until explicitly saved or first batch).
    return jsonb_build_object(
      'vineyard_id', p_vineyard_id,
      'provider', p_provider,
      'external_controller_key', coalesce(p_external_controller_key, ''),
      'minimum_volume_litres', 1000,
      'volume_comparison', 'greater_than',
      'exclude_test_programs', true,
      'timezone', null,
      'is_default', true);
  end if;
  return to_jsonb(v_row) || jsonb_build_object('is_default', false);
end;
$$;

create or replace function public.set_irrigation_import_provider_settings(
  p_vineyard_id uuid,
  p_provider text,
  p_external_controller_key text default '',
  p_external_controller_name text default null,
  p_minimum_volume_litres numeric default null,
  p_volume_comparison text default null,
  p_exclude_test_programs boolean default null,
  p_timezone text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.irrigation_import_provider_settings;
  v_row public.irrigation_import_provider_settings;
begin
  perform public._irrigation_import_require_admin(p_vineyard_id);
  if p_minimum_volume_litres is not null and p_minimum_volume_litres < 0 then
    raise exception 'invalid_threshold: the minimum volume cannot be negative';
  end if;
  if p_volume_comparison is not null
     and p_volume_comparison not in ('greater_than','greater_than_or_equal') then
    raise exception 'invalid_comparison: unsupported volume comparison';
  end if;

  select * into v_old
  from public.irrigation_import_provider_settings
  where vineyard_id = p_vineyard_id and provider = p_provider
    and lower(external_controller_key) = lower(coalesce(p_external_controller_key, ''));

  if found then
    update public.irrigation_import_provider_settings
    set external_controller_name = coalesce(p_external_controller_name, external_controller_name),
        minimum_volume_litres = coalesce(p_minimum_volume_litres, minimum_volume_litres),
        volume_comparison = coalesce(p_volume_comparison, volume_comparison),
        exclude_test_programs = coalesce(p_exclude_test_programs, exclude_test_programs),
        timezone = coalesce(p_timezone, timezone),
        updated_by = auth.uid()
    where id = v_old.id
    returning * into v_row;
  else
    insert into public.irrigation_import_provider_settings
      (vineyard_id, provider, external_controller_key, external_controller_name,
       minimum_volume_litres, volume_comparison, exclude_test_programs, timezone,
       created_by, updated_by)
    values
      (p_vineyard_id, p_provider, coalesce(p_external_controller_key, ''),
       p_external_controller_name,
       coalesce(p_minimum_volume_litres, 1000),
       coalesce(p_volume_comparison, 'greater_than'),
       coalesce(p_exclude_test_programs, true),
       p_timezone, auth.uid(), auth.uid())
    returning * into v_row;
  end if;

  perform public._irrigation_audit(p_vineyard_id,
    case when v_old.id is null then 'create' else 'update' end,
    'irrigation_import_provider_settings', v_row.id,
    case when v_old.id is null then null else to_jsonb(v_old) end, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Batch creation (file-level duplicate protection)
-- ---------------------------------------------------------------------------
create or replace function public.create_irrigation_import_batch(
  p_id uuid,
  p_vineyard_id uuid,
  p_provider text,
  p_file_name text,
  p_file_hash text,
  p_file_size integer default null,
  p_worksheet_name text default null,
  p_source_unit_name text default null,
  p_total_rows integer default 0,
  p_timezone text default null,
  p_allow_revalidation boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.irrigation_import_batches;
  v_settings jsonb;
  v_controller_key text;
  v_row public.irrigation_import_batches;
begin
  perform public._irrigation_import_require_admin(p_vineyard_id);
  if p_provider not in ('galcon_gsi') then
    raise exception 'invalid_provider: unsupported import provider %', p_provider;
  end if;
  if nullif(trim(coalesce(p_file_hash, '')), '') is null then
    raise exception 'invalid_file_hash: a file content hash is required';
  end if;
  if p_total_rows > 50000 then
    raise exception 'file_too_large: the file exceeds the maximum of 50,000 source rows';
  end if;

  v_controller_key := public._irrigation_import_normalise_text(p_source_unit_name);

  -- Idempotent retry on the same client-generated id.
  select * into v_row from public.irrigation_import_batches where id = p_id;
  if found then
    return jsonb_build_object('batch', to_jsonb(v_row), 'duplicate_file', false, 'retried', true);
  end if;

  -- File-level duplicate: same content already processed for vineyard/provider.
  select * into v_existing
  from public.irrigation_import_batches
  where vineyard_id = p_vineyard_id and provider = p_provider and file_hash = p_file_hash
    and status not in ('reversed','abandoned') and reprocess_of_batch_id is null
  order by created_at desc
  limit 1;

  if found and not p_allow_revalidation then
    return jsonb_build_object(
      'batch', to_jsonb(v_existing),
      'duplicate_file', true,
      'message', 'This file content has already been processed for this vineyard. Open the earlier batch, or reprocess for validation only.');
  end if;

  v_settings := public.get_irrigation_import_provider_settings(p_vineyard_id, p_provider, v_controller_key);

  insert into public.irrigation_import_batches
    (id, vineyard_id, provider, external_controller_key, file_name, file_hash,
     file_size, worksheet_name, source_unit_name, timezone, total_rows,
     threshold_litres, volume_comparison, exclude_test_programs,
     reprocess_of_batch_id, created_by)
  values
    (coalesce(p_id, gen_random_uuid()), p_vineyard_id, p_provider, v_controller_key,
     p_file_name, p_file_hash, p_file_size, p_worksheet_name, p_source_unit_name,
     coalesce(p_timezone, v_settings->>'timezone'),
     greatest(coalesce(p_total_rows, 0), 0),
     (v_settings->>'minimum_volume_litres')::numeric,
     v_settings->>'volume_comparison',
     (v_settings->>'exclude_test_programs')::boolean,
     case when p_allow_revalidation then v_existing.id else null end,
     auth.uid())
  returning * into v_row;

  -- Persist default settings on first use so later imports reuse them.
  if (v_settings->>'is_default')::boolean then
    perform public.set_irrigation_import_provider_settings(
      p_vineyard_id, p_provider, v_controller_key, p_source_unit_name);
  end if;

  perform public._irrigation_audit(p_vineyard_id, 'create', 'irrigation_import_batch',
    v_row.id, null, to_jsonb(v_row));
  return jsonb_build_object('batch', to_jsonb(v_row), 'duplicate_file', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Row staging (called by the parser Edge Function in chunks)
-- ---------------------------------------------------------------------------
create or replace function public.stage_irrigation_import_rows(
  p_batch_id uuid,
  p_rows jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch public.irrigation_import_batches;
  v_el jsonb;
  v_staged integer := 0;
  v_skipped integer := 0;
  v_fp text;
begin
  select * into v_batch from public.irrigation_import_batches where id = p_batch_id;
  if not found then
    raise exception 'not_found: import batch not found';
  end if;
  perform public._irrigation_import_require_admin(v_batch.vineyard_id);
  if v_batch.status not in ('parsed','validated') then
    raise exception 'batch_locked: rows can only be staged before commit';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'invalid_rows: an array of parsed rows is required';
  end if;

  for v_el in select * from jsonb_array_elements(p_rows) loop
    v_fp := public._irrigation_import_fingerprint(
      v_batch.provider, v_batch.vineyard_id, v_batch.external_controller_key,
      nullif(v_el->>'external_station_code', ''),
      nullif(v_el->>'external_valve_number', '')::integer,
      nullif(v_el->>'parsed_date', '')::date,
      nullif(v_el->>'parsed_start_time', '')::time,
      nullif(v_el->>'parsed_end_time', '')::time,
      nullif(v_el->>'parsed_duration_seconds', '')::integer,
      nullif(v_el->>'parsed_water_litres', '')::numeric,
      nullif(v_el->>'parsed_flow_litres_per_hour', '')::numeric,
      v_el->>'source_comment',
      v_el->>'program_name');

    insert into public.irrigation_import_rows
      (batch_id, vineyard_id, provider, source_row_number, raw_payload, raw_row_hash,
       event_fingerprint, parsed_date, parsed_start_time, parsed_end_time,
       parsed_duration_seconds, parsed_water_litres, parsed_flow_litres_per_hour,
       original_water_value, original_water_unit, original_flow_value, original_flow_unit,
       external_valve_number, external_station_code, external_valve_name,
       external_valve_label, program_name, source_comment,
       validation_status, validation_errors, validation_warnings)
    values
      (p_batch_id, v_batch.vineyard_id, v_batch.provider,
       (v_el->>'source_row_number')::integer,
       coalesce(v_el->'raw_payload', '{}'::jsonb),
       encode(digest(coalesce(v_el->'raw_payload', '{}'::jsonb)::text, 'sha256'), 'hex'),
       v_fp,
       nullif(v_el->>'parsed_date', '')::date,
       nullif(v_el->>'parsed_start_time', '')::time,
       nullif(v_el->>'parsed_end_time', '')::time,
       nullif(v_el->>'parsed_duration_seconds', '')::integer,
       nullif(v_el->>'parsed_water_litres', '')::numeric,
       nullif(v_el->>'parsed_flow_litres_per_hour', '')::numeric,
       nullif(v_el->>'original_water_value', '')::numeric,
       nullif(v_el->>'original_water_unit', ''),
       nullif(v_el->>'original_flow_value', '')::numeric,
       nullif(v_el->>'original_flow_unit', ''),
       nullif(v_el->>'external_valve_number', '')::integer,
       nullif(upper(trim(coalesce(v_el->>'external_station_code', ''))), ''),
       nullif(v_el->>'external_valve_name', ''),
       nullif(v_el->>'external_valve_label', ''),
       nullif(v_el->>'program_name', ''),
       v_el->>'source_comment',
       case when jsonb_array_length(coalesce(v_el->'parse_errors', '[]'::jsonb)) > 0
            then 'error' else 'pending' end,
       coalesce(v_el->'parse_errors', '[]'::jsonb),
       coalesce(v_el->'parse_warnings', '[]'::jsonb))
    on conflict (batch_id, source_row_number) do nothing;

    if found then v_staged := v_staged + 1; else v_skipped := v_skipped + 1; end if;
  end loop;

  update public.irrigation_import_batches
  set total_rows = (select count(*) from public.irrigation_import_rows where batch_id = p_batch_id)
  where id = p_batch_id;

  return jsonb_build_object('staged', v_staged, 'skipped_existing', v_skipped);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Valve mapping
-- ---------------------------------------------------------------------------

-- One row per DISTINCT controller valve in the batch, with resolution status.
create or replace function public.list_irrigation_import_valves(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_batch public.irrigation_import_batches;
begin
  select * into v_batch from public.irrigation_import_batches where id = p_batch_id;
  if not found then
    raise exception 'not_found: import batch not found';
  end if;
  perform public._irrigation_import_require_admin(v_batch.vineyard_id);

  return coalesce((
    with distinct_valves as (
      select external_station_code, external_valve_number,
             max(external_valve_name) as external_valve_name,
             max(external_valve_label) as external_valve_label,
             count(*) as row_count
      from public.irrigation_import_rows
      where batch_id = p_batch_id
      group by external_station_code, external_valve_number
    ),
    resolved as (
      select dv.*,
             m.id as mapping_id,
             m.irrigation_valve_id,
             m.is_ignored,
             m.mapping_source,
             m.external_valve_name as mapped_external_name,
             v.name as vinetrack_valve_name,
             v.is_active as valve_is_active,
             sug.id as suggested_valve_id,
             sug.name as suggested_valve_name
      from distinct_valves dv
      left join public.irrigation_controller_valve_mappings m
        on m.vineyard_id = v_batch.vineyard_id
       and m.provider = v_batch.provider
       and lower(m.external_controller_key) = lower(v_batch.external_controller_key)
       and m.is_active
       and ((dv.external_station_code is not null
             and upper(m.external_station_code) = upper(dv.external_station_code))
            or (dv.external_station_code is null
                and m.external_valve_number = dv.external_valve_number))
      left join public.irrigation_valves v on v.id = m.irrigation_valve_id
      left join lateral (
        select iv.id, iv.name
        from public.irrigation_valves iv
        where iv.vineyard_id = v_batch.vineyard_id and iv.is_active
          and m.id is null
          and (
            public._irrigation_import_normalise_text(iv.name)
              = public._irrigation_import_normalise_text(
                  regexp_replace(coalesce(dv.external_valve_label, ''), '\s+\d+\s*-\s*\d+\s*$', ''))
            or (length(coalesce(dv.external_valve_label, '')) > 0
                and position(public._irrigation_import_normalise_text(iv.name)
                             in public._irrigation_import_normalise_text(dv.external_valve_label)) > 0)
          )
        order by length(iv.name) desc
        limit 1
      ) sug on true
    )
    select jsonb_agg(jsonb_build_object(
      'external_station_code', r.external_station_code,
      'external_valve_number', r.external_valve_number,
      'external_valve_name', r.external_valve_name,
      'external_valve_label', r.external_valve_label,
      'row_count', r.row_count,
      'mapping_id', r.mapping_id,
      'irrigation_valve_id', r.irrigation_valve_id,
      'vinetrack_valve_name', r.vinetrack_valve_name,
      'valve_is_active', r.valve_is_active,
      'mapping_source', r.mapping_source,
      'is_ignored', r.is_ignored,
      'name_changed', r.mapping_id is not null
        and public._irrigation_import_normalise_text(r.mapped_external_name)
            is distinct from public._irrigation_import_normalise_text(r.external_valve_name),
      'previous_external_name', r.mapped_external_name,
      'suggested_valve_id', r.suggested_valve_id,
      'suggested_valve_name', r.suggested_valve_name,
      'status', case
        when r.mapping_id is not null and r.is_ignored then 'ignored'
        when r.mapping_id is not null
             and public._irrigation_import_normalise_text(r.mapped_external_name)
                 is distinct from public._irrigation_import_normalise_text(r.external_valve_name)
          then 'conflict'
        when r.mapping_id is not null then 'saved'
        when r.suggested_valve_id is not null then 'suggested'
        else 'unmapped'
      end
    ) order by r.external_valve_number nulls last, r.external_station_code)
    from resolved r
  ), '[]'::jsonb);
end;
$$;

create or replace function public.set_irrigation_controller_valve_mapping(
  p_vineyard_id uuid,
  p_provider text,
  p_external_controller_key text,
  p_external_valve_name text,
  p_external_station_code text default null,
  p_external_valve_number integer default null,
  p_external_controller_name text default null,
  p_irrigation_valve_id uuid default null,
  p_ignore boolean default false,
  p_confirm_change boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.irrigation_controller_valve_mappings;
  v_row public.irrigation_controller_valve_mappings;
  v_valve public.irrigation_valves;
  v_change_summary text;
begin
  perform public._irrigation_import_require_admin(p_vineyard_id);
  if p_external_station_code is null and p_external_valve_number is null then
    raise exception 'invalid_identity: a station code or valve number is required';
  end if;
  if not p_ignore then
    if p_irrigation_valve_id is null then
      raise exception 'invalid_target: choose a VineTrack valve or ignore this controller valve';
    end if;
    select * into v_valve from public.irrigation_valves
    where id = p_irrigation_valve_id and vineyard_id = p_vineyard_id;
    if not found then
      raise exception 'invalid_valve: the valve does not belong to this vineyard';
    end if;
  end if;

  select * into v_old
  from public.irrigation_controller_valve_mappings
  where vineyard_id = p_vineyard_id and provider = p_provider and is_active
    and lower(external_controller_key) = lower(coalesce(p_external_controller_key, ''))
    and ((p_external_station_code is not null
          and upper(external_station_code) = upper(p_external_station_code))
         or (p_external_station_code is null
             and external_valve_number = p_external_valve_number));

  if found then
    -- Mapping-change protection: a materially different target or external
    -- name requires explicit confirmation and is audited.
    if (v_old.irrigation_valve_id is distinct from p_irrigation_valve_id
        or v_old.is_ignored is distinct from p_ignore
        or public._irrigation_import_normalise_text(v_old.external_valve_name)
           is distinct from public._irrigation_import_normalise_text(p_external_valve_name))
       and not p_confirm_change then
      v_change_summary := format(
        'mapping_conflict: %s station %s was previously mapped as "%s". Review the mapping change before continuing.',
        p_provider, coalesce(p_external_station_code, p_external_valve_number::text),
        v_old.external_valve_name);
      raise exception '%', v_change_summary;
    end if;

    update public.irrigation_controller_valve_mappings
    set external_valve_name = p_external_valve_name,
        external_valve_number = coalesce(p_external_valve_number, external_valve_number),
        external_station_code = coalesce(upper(p_external_station_code), external_station_code),
        external_controller_name = coalesce(p_external_controller_name, external_controller_name),
        irrigation_valve_id = case when p_ignore then null else p_irrigation_valve_id end,
        irrigation_system_id = case when p_ignore then null else v_valve.irrigation_system_id end,
        is_ignored = p_ignore,
        mapping_source = 'manual',
        last_seen_at = now(),
        updated_by = auth.uid()
    where id = v_old.id
    returning * into v_row;
  else
    insert into public.irrigation_controller_valve_mappings
      (vineyard_id, provider, external_controller_key, external_controller_name,
       external_valve_number, external_station_code, external_valve_name,
       irrigation_system_id, irrigation_valve_id, is_ignored, mapping_source,
       created_by, updated_by)
    values
      (p_vineyard_id, p_provider, coalesce(p_external_controller_key, ''),
       p_external_controller_name, p_external_valve_number,
       upper(p_external_station_code), p_external_valve_name,
       case when p_ignore then null else v_valve.irrigation_system_id end,
       case when p_ignore then null else p_irrigation_valve_id end,
       p_ignore, 'manual', auth.uid(), auth.uid())
    returning * into v_row;
  end if;

  perform public._irrigation_audit(p_vineyard_id,
    case when v_old.id is null then 'create' else 'update' end,
    'irrigation_controller_valve_mapping', v_row.id,
    case when v_old.id is null then null else to_jsonb(v_old) end, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Validation (classification, threshold, duplicates, mapping, reconciliation)
-- ---------------------------------------------------------------------------
create or replace function public.validate_irrigation_import(
  p_batch_id uuid,
  p_threshold_litres numeric default null,
  p_volume_comparison text default null,
  p_exclude_test_programs boolean default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.irrigation_import_batches;
  r record;
  v_class text;
  v_comment_class text;
  v_status text;
  v_primary text;
  v_reasons jsonb;
  v_warnings jsonb;
  v_errors jsonb;
  v_dup_status text;
  v_dup_ref uuid;
  v_recon text;
  v_expected numeric;
  v_mapping public.irrigation_controller_valve_mappings;
  v_valve_id uuid;
  v_mapping_id uuid;
  v_derived_seconds integer;
  v_is_test boolean;
  v_passes boolean;
  v_at_threshold boolean;
  v_importable_comment boolean;
  v_valve_ok jsonb := '{}'::jsonb;   -- per-valve connection validity cache
  v_alloc jsonb;
  v_el jsonb;
  v_sum numeric;
  v_ok boolean;
  v_tol numeric;
  v_prev record;
begin
  select * into v_batch from public.irrigation_import_batches where id = p_batch_id for update;
  if not found then
    raise exception 'not_found: import batch not found';
  end if;
  perform public._irrigation_import_require_admin(v_batch.vineyard_id);
  if v_batch.status in ('reversed','abandoned') then
    raise exception 'batch_closed: this batch can no longer be validated';
  end if;

  -- Optional settings change for THIS batch preview (never alters committed sessions).
  if p_threshold_litres is not null or p_volume_comparison is not null
     or p_exclude_test_programs is not null then
    if p_threshold_litres is not null and p_threshold_litres < 0 then
      raise exception 'invalid_threshold: the minimum volume cannot be negative';
    end if;
    if p_volume_comparison is not null
       and p_volume_comparison not in ('greater_than','greater_than_or_equal') then
      raise exception 'invalid_comparison: unsupported volume comparison';
    end if;
    update public.irrigation_import_batches
    set threshold_litres = coalesce(p_threshold_litres, threshold_litres),
        volume_comparison = coalesce(p_volume_comparison, volume_comparison),
        exclude_test_programs = coalesce(p_exclude_test_programs, exclude_test_programs)
    where id = p_batch_id
    returning * into v_batch;
    perform public._irrigation_audit(v_batch.vineyard_id, 'update_settings',
      'irrigation_import_batch', p_batch_id, null,
      jsonb_build_object('threshold_litres', v_batch.threshold_litres,
                         'volume_comparison', v_batch.volume_comparison,
                         'exclude_test_programs', v_batch.exclude_test_programs));
  end if;

  -- Auto-map: existing VineTrack external identifiers may resolve valves
  -- without a saved mapping (priority 3 and 4 of the shared contract).
  insert into public.irrigation_controller_valve_mappings
    (vineyard_id, provider, external_controller_key, external_controller_name,
     external_valve_number, external_station_code, external_valve_name,
     irrigation_system_id, irrigation_valve_id, mapping_source, created_by, updated_by)
  select distinct on (coalesce(upper(rw.external_station_code), 'n:' || rw.external_valve_number::text))
         v_batch.vineyard_id, v_batch.provider, v_batch.external_controller_key,
         v_batch.source_unit_name, rw.external_valve_number,
         upper(rw.external_station_code), rw.external_valve_name,
         iv.irrigation_system_id, iv.id,
         case when rw.external_station_code is not null
                   and upper(trim(coalesce(iv.external_station_id, '')))
                       = upper(rw.external_station_code)
              then 'auto_station' else 'auto_valve_number' end,
         auth.uid(), auth.uid()
  from (select distinct external_station_code, external_valve_number, external_valve_name
        from public.irrigation_import_rows where batch_id = p_batch_id
          and (external_station_code is not null or external_valve_number is not null)) rw
  join public.irrigation_valves iv
    on iv.vineyard_id = v_batch.vineyard_id and iv.is_active
   and ((rw.external_station_code is not null
         and upper(trim(coalesce(iv.external_station_id, ''))) = upper(rw.external_station_code))
        or (rw.external_valve_number is not null
            and trim(coalesce(iv.valve_number, '')) = rw.external_valve_number::text))
  where not exists (
    select 1 from public.irrigation_controller_valve_mappings m
    where m.vineyard_id = v_batch.vineyard_id and m.provider = v_batch.provider
      and lower(m.external_controller_key) = lower(v_batch.external_controller_key)
      and m.is_active
      and ((rw.external_station_code is not null
            and upper(m.external_station_code) = upper(rw.external_station_code))
           or (rw.external_station_code is null
               and m.external_valve_number = rw.external_valve_number)))
  on conflict do nothing;

  -- Row-by-row classification.
  for r in
    select * from public.irrigation_import_rows
    where batch_id = p_batch_id
    order by source_row_number
  loop
    v_reasons := '[]'::jsonb;
    v_warnings := coalesce(r.validation_warnings, '[]'::jsonb);
    v_errors := coalesce(r.validation_errors, '[]'::jsonb);
    v_dup_status := 'new';
    v_dup_ref := null;
    v_recon := null;
    v_expected := null;
    v_valve_id := null;
    v_mapping_id := null;

    -- Parse errors from the adapter are terminal for the row.
    if jsonb_array_length(v_errors) > 0 then
      update public.irrigation_import_rows
      set classification = 'needs_review',
          validation_status = 'error',
          primary_exclusion_reason = 'parse_error',
          additional_reason_codes = '[]'::jsonb,
          matched_valve_id = null, matched_mapping_id = null,
          duplicate_status = 'new', duplicate_reference = null
      where id = r.id;
      continue;
    end if;

    v_comment_class := public._galcon_classify_comment(r.source_comment);
    v_is_test := public._irrigation_import_normalise_text(r.program_name) = 'test';
    v_importable_comment := v_comment_class in ('completed','ended_manually');
    v_passes := public._irrigation_import_passes_threshold(
      r.parsed_water_litres, v_batch.threshold_litres, v_batch.volume_comparison);
    v_at_threshold := r.parsed_water_litres is not null
      and r.parsed_water_litres = v_batch.threshold_litres
      and v_batch.volume_comparison = 'greater_than';

    -- Valve resolution (saved mapping via station, then valve number).
    select * into v_mapping
    from public.irrigation_controller_valve_mappings m
    where m.vineyard_id = v_batch.vineyard_id and m.provider = v_batch.provider
      and lower(m.external_controller_key) = lower(v_batch.external_controller_key)
      and m.is_active
      and ((r.external_station_code is not null
            and upper(m.external_station_code) = upper(r.external_station_code))
           or (r.external_station_code is null
               and m.external_valve_number = r.external_valve_number))
    limit 1;

    if v_mapping.id is not null then
      v_mapping_id := v_mapping.id;
      if v_mapping.is_ignored then
        v_reasons := v_reasons || to_jsonb('valve_ignored'::text);
      else
        v_valve_id := v_mapping.irrigation_valve_id;
        -- Mapping-change protection: materially different external name.
        if public._irrigation_import_normalise_text(v_mapping.external_valve_name)
           is distinct from public._irrigation_import_normalise_text(r.external_valve_name) then
          v_reasons := v_reasons || to_jsonb('mapping_name_changed'::text);
        end if;
      end if;
      update public.irrigation_controller_valve_mappings
      set last_seen_at = now() where id = v_mapping.id and last_seen_at < now() - interval '1 minute';
    else
      v_reasons := v_reasons || to_jsonb('unmapped_valve'::text);
    end if;

    -- Valve connection validity (cached per valve within this call).
    if v_valve_id is not null then
      if v_valve_ok ? v_valve_id::text then
        v_ok := (v_valve_ok->>v_valve_id::text)::boolean;
      else
        v_ok := true;
        v_alloc := public._irrigation_valve_allocations(v_valve_id);
        if jsonb_array_length(v_alloc) = 0 then
          v_ok := false;
        else
          v_sum := 0;
          for v_el in select * from jsonb_array_elements(v_alloc) loop
            if nullif(v_el->>'allocation_percentage', '') is null then
              v_ok := false;
            else
              v_sum := v_sum + (v_el->>'allocation_percentage')::numeric;
            end if;
          end loop;
          if v_ok and abs(v_sum - 100) > 0.05 then v_ok := false; end if;
        end if;
        v_valve_ok := v_valve_ok || jsonb_build_object(v_valve_id::text, v_ok);
      end if;
      if not v_ok then
        v_reasons := v_reasons || to_jsonb('invalid_valve_connection'::text);
      end if;
    end if;

    -- Duration: timestamps vs reported runtime (overnight rolls to next day).
    v_derived_seconds := null;
    if r.parsed_start_time is not null and r.parsed_end_time is not null then
      v_derived_seconds := (extract(epoch from (r.parsed_end_time - r.parsed_start_time)))::integer;
      if v_derived_seconds < 0 then
        v_derived_seconds := v_derived_seconds + 86400;   -- overnight event
      end if;
      if r.parsed_duration_seconds is not null
         and abs(v_derived_seconds - r.parsed_duration_seconds) > 120 then
        v_reasons := v_reasons || to_jsonb('duration_mismatch'::text);
      end if;
    end if;

    -- Water/flow reconciliation: expected = flow (L/h) × runtime (h).
    if r.parsed_flow_litres_per_hour is null or r.parsed_flow_litres_per_hour <= 0
       or coalesce(r.parsed_duration_seconds, 0) <= 0 then
      v_recon := 'cannot_compare';
    elsif r.parsed_water_litres is null then
      v_recon := 'cannot_compare';
      v_expected := round(r.parsed_flow_litres_per_hour * r.parsed_duration_seconds / 3600.0, 3);
    else
      v_expected := round(r.parsed_flow_litres_per_hour * r.parsed_duration_seconds / 3600.0, 3);
      v_tol := greatest(100, 0.10 * r.parsed_water_litres);
      if abs(v_expected - r.parsed_water_litres) <= greatest(10, 0.01 * r.parsed_water_litres) then
        v_recon := 'reconciled';
      elsif abs(v_expected - r.parsed_water_litres) <= v_tol then
        v_recon := 'minor_rounding_difference';
      else
        v_recon := 'material_mismatch';
        v_reasons := v_reasons || to_jsonb('water_flow_material_mismatch'::text);
      end if;
    end if;

    -- Duplicate detection (event fingerprints, format and file independent).
    select rw.id, rw.batch_id, rw.created_session_id, rw.is_reversed,
           rw.validation_status, rw.override_threshold, rw.override_test
    into v_prev
    from public.irrigation_import_rows rw
    where rw.vineyard_id = v_batch.vineyard_id and rw.provider = v_batch.provider
      and rw.event_fingerprint = r.event_fingerprint
      and rw.id <> r.id
      and (rw.batch_id <> r.batch_id or rw.source_row_number < r.source_row_number)
    order by (rw.created_session_id is not null and not rw.is_reversed) desc, rw.created_at
    limit 1;

    if v_prev.id is not null then
      v_dup_ref := v_prev.id;
      if v_prev.created_session_id is not null and not v_prev.is_reversed then
        v_dup_status := 'duplicate_imported';
      elsif exists (select 1 from public.irrigation_import_batches b
                    where b.id = v_prev.batch_id
                      and b.status in ('committed','partially_committed')) then
        if v_prev.override_threshold or v_prev.override_test
           or v_prev.validation_status = 'needs_review' then
          v_dup_status := 'duplicate_reviewed';
        else
          v_dup_status := 'duplicate_ignored';
        end if;
      elsif v_prev.batch_id = r.batch_id then
        v_dup_status := 'duplicate_ignored';   -- in-file duplicate: first row wins
      end if;
    end if;

    -- Similar event with changed values: same valve identity + same start,
    -- but a different fingerprint, already imported → review, never overwrite.
    if v_dup_status = 'new' then
      select rw.id into v_dup_ref
      from public.irrigation_import_rows rw
      where rw.vineyard_id = v_batch.vineyard_id and rw.provider = v_batch.provider
        and rw.created_session_id is not null and not rw.is_reversed
        and rw.event_fingerprint <> r.event_fingerprint
        and rw.parsed_date = r.parsed_date
        and rw.parsed_start_time = r.parsed_start_time
        and coalesce(upper(rw.external_station_code), '') = coalesce(upper(r.external_station_code), '')
        and coalesce(rw.external_valve_number, -1) = coalesce(r.external_valve_number, -1)
      limit 1;
      if v_dup_ref is not null then
        v_dup_status := 'possible_duplicate_changed_values';
        v_reasons := v_reasons || to_jsonb('changed_duplicate_values'::text);
      end if;
    end if;

    -- Base validity reasons.
    if r.parsed_date is null then
      v_reasons := v_reasons || to_jsonb('invalid_date'::text);
    end if;
    if coalesce(r.parsed_duration_seconds, 0) < 60
       and coalesce(v_derived_seconds, 0) < 60 then
      v_reasons := v_reasons || to_jsonb('invalid_runtime'::text);
    end if;
    if r.parsed_water_litres is null and v_importable_comment then
      v_reasons := v_reasons || to_jsonb('missing_water_quantity'::text);
    end if;

    -- ---- Primary classification + status resolution --------------------
    if v_dup_status in ('duplicate_imported','duplicate_ignored','duplicate_reviewed') then
      v_class := v_comment_class;
      v_status := 'excluded';
      v_primary := 'duplicate';
    elsif v_is_test and not r.override_test then
      v_class := 'test';
      v_status := 'excluded';
      v_primary := 'test_program';
      if not v_passes then
        v_reasons := v_reasons || to_jsonb('below_minimum_volume'::text);
      end if;
    elsif coalesce(r.parsed_duration_seconds, 0) = 0
          and coalesce(r.parsed_water_litres, 0) = 0 then
      v_class := 'zero_activity';
      v_status := 'excluded';
      v_primary := 'zero_activity';
    elsif v_importable_comment then
      if not v_passes and not r.override_threshold then
        v_class := case when v_at_threshold then 'at_volume_threshold'
                        else 'below_volume_threshold' end;
        v_status := 'excluded';
        v_primary := case when v_at_threshold then 'at_volume_threshold'
                          else 'below_volume_threshold' end;
      elsif jsonb_array_length(v_reasons) > 0 then
        v_class := v_comment_class;
        v_status := 'needs_review';
        v_primary := v_reasons->>0;
      else
        v_class := v_comment_class;
        v_status := 'eligible';
        v_primary := null;
        if r.override_threshold then
          v_reasons := v_reasons || to_jsonb('threshold_override_applied'::text);
        end if;
        if r.override_test and v_is_test then
          v_reasons := v_reasons || to_jsonb('test_override_applied'::text);
        end if;
      end if;
    else
      -- Cancelled / error / paused / continued / unknown comments.
      v_class := v_comment_class;
      if v_comment_class in ('paused','continued','unknown_comment') then
        v_status := 'needs_review';
        v_primary := case v_comment_class
                       when 'paused' then 'paused_event'
                       when 'continued' then 'continued_event'
                       else 'unknown_comment' end;
      elsif coalesce(r.parsed_water_litres, 0) > 0 and v_passes then
        -- Material water recorded against a cancellation/error → review.
        v_status := 'needs_review';
        v_primary := 'positive_water_with_' ||
          case when v_comment_class like '%error%' then 'error' else 'cancellation' end;
      else
        v_status := 'excluded';
        v_primary := v_comment_class;
        if not v_passes and coalesce(r.parsed_water_litres, 0) > 0 then
          v_reasons := v_reasons || to_jsonb('below_minimum_volume'::text);
        end if;
      end if;
    end if;

    -- Overrides can only lift threshold/test exclusions — every other
    -- validation failure still blocks eligibility.
    if v_status = 'excluded'
       and ((v_primary in ('below_volume_threshold','at_volume_threshold') and r.override_threshold)
            or (v_primary = 'test_program' and r.override_test)) then
      if v_importable_comment and jsonb_array_length(v_reasons) = 0 then
        v_status := 'eligible';
        v_primary := null;
      elsif v_importable_comment then
        v_status := 'needs_review';
        v_primary := v_reasons->>0;
      end if;
    end if;

    update public.irrigation_import_rows
    set classification = v_class,
        validation_status = v_status,
        primary_exclusion_reason = v_primary,
        additional_reason_codes = v_reasons,
        validation_warnings = v_warnings,
        water_flow_reconciliation = v_recon,
        expected_water_litres = v_expected,
        duplicate_status = v_dup_status,
        duplicate_reference = v_dup_ref,
        matched_valve_id = v_valve_id,
        matched_mapping_id = v_mapping_id
    where id = r.id;
  end loop;

  -- Batch counters.
  update public.irrigation_import_batches b
  set status = case when b.status = 'parsed' then 'validated' else b.status end,
      valid_rows = c.valid, review_rows = c.review, ignored_rows = c.ignored,
      error_rows = c.errors, duplicate_rows = c.dups
  from (
    select count(*) filter (where validation_status = 'eligible') as valid,
           count(*) filter (where validation_status = 'needs_review') as review,
           count(*) filter (where validation_status = 'excluded'
                              and duplicate_status = 'new') as ignored,
           count(*) filter (where validation_status = 'error') as errors,
           count(*) filter (where duplicate_status <> 'new') as dups
    from public.irrigation_import_rows where batch_id = p_batch_id
  ) c
  where b.id = p_batch_id;

  return public.preview_irrigation_import(p_batch_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. Row overrides (threshold / Test) — audited, never changes defaults
-- ---------------------------------------------------------------------------
create or replace function public.set_irrigation_import_row_override(
  p_row_id uuid,
  p_override_threshold boolean default null,
  p_override_test boolean default null,
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.irrigation_import_rows;
  v_batch public.irrigation_import_batches;
begin
  select * into v_row from public.irrigation_import_rows where id = p_row_id;
  if not found then
    raise exception 'not_found: import row not found';
  end if;
  select * into v_batch from public.irrigation_import_batches where id = v_row.batch_id;
  perform public._irrigation_import_require_admin(v_batch.vineyard_id);
  if v_row.created_session_id is not null then
    raise exception 'already_imported: this event has already been imported';
  end if;

  update public.irrigation_import_rows
  set override_threshold = coalesce(p_override_threshold, override_threshold),
      override_test = coalesce(p_override_test, override_test),
      override_reason = coalesce(p_reason, override_reason),
      override_by = auth.uid(),
      override_at = now()
  where id = p_row_id;

  perform public._irrigation_audit(v_batch.vineyard_id, 'override',
    'irrigation_import_row', p_row_id,
    jsonb_build_object('override_threshold', v_row.override_threshold,
                       'override_test', v_row.override_test),
    jsonb_build_object('override_threshold', coalesce(p_override_threshold, v_row.override_threshold),
                       'override_test', coalesce(p_override_test, v_row.override_test),
                       'reason', p_reason,
                       'reported_water_litres', v_row.parsed_water_litres,
                       'threshold_litres', v_batch.threshold_litres,
                       'program', v_row.program_name));

  -- Re-classify the batch so the preview reflects the override.
  return public.validate_irrigation_import(v_row.batch_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. Preview totals (§36 contract — one primary class per row, no double count)
-- ---------------------------------------------------------------------------
create or replace function public.preview_irrigation_import(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_batch public.irrigation_import_batches;
  v_totals jsonb;
begin
  select * into v_batch from public.irrigation_import_batches where id = p_batch_id;
  if not found then
    raise exception 'not_found: import batch not found';
  end if;
  perform public._irrigation_import_require_admin(v_batch.vineyard_id);

  select jsonb_build_object(
    'total_source_rows', count(*),
    'eligible_completed', count(*) filter (where validation_status = 'eligible'),
    'below_threshold', count(*) filter (where classification = 'below_volume_threshold'),
    'at_threshold', count(*) filter (where classification = 'at_volume_threshold'),
    'test_program', count(*) filter (where classification = 'test'),
    'cancelled', count(*) filter (where classification in
        ('cancelled_manual','cancelled_error','cancelled_not_enabled')
        and duplicate_status = 'new'),
    'controller_errors', count(*) filter (where classification in
        ('low_flow_error','high_flow_error','no_flow_error') and duplicate_status = 'new'),
    'zero_activity', count(*) filter (where classification = 'zero_activity'),
    'needs_review', count(*) filter (where validation_status = 'needs_review'),
    'parse_errors', count(*) filter (where validation_status = 'error'),
    'unmapped_valves', count(*) filter (where additional_reason_codes ? 'unmapped_valve'),
    'exact_duplicates', count(*) filter (where duplicate_status in
        ('duplicate_imported','duplicate_ignored','duplicate_reviewed')),
    'possible_changed_duplicates', count(*) filter
        (where duplicate_status = 'possible_duplicate_changed_values'),
    'selected_for_import', count(*) filter (where validation_status = 'eligible'
        and created_session_id is null),
    'already_imported', count(*) filter (where created_session_id is not null and not is_reversed),
    'threshold_litres', v_batch.threshold_litres,
    'volume_comparison', v_batch.volume_comparison,
    'exclude_test_programs', v_batch.exclude_test_programs,
    'distinct_valves', (select count(distinct coalesce(upper(external_station_code),
                                     'n:' || external_valve_number::text))
                        from public.irrigation_import_rows where batch_id = p_batch_id),
    'threshold_explanation', format(
      'Events are selected when the reported water quantity is %s %s L (%s m³). '
      || 'This helps exclude controller tests, valve switching and very short runs.',
      case when v_batch.volume_comparison = 'greater_than' then 'more than' else 'at least' end,
      trim(to_char(v_batch.threshold_litres, 'FM999999990.###')),
      trim(to_char(v_batch.threshold_litres / 1000.0, 'FM999999990.###')))
  ) into v_totals
  from public.irrigation_import_rows
  where batch_id = p_batch_id;

  return jsonb_build_object('batch', to_jsonb(v_batch)) || v_totals;
end;
$$;

-- ---------------------------------------------------------------------------
-- 13. Commit (transactional, idempotent, DB-guarded)
-- ---------------------------------------------------------------------------
create or replace function public.commit_irrigation_import(
  p_batch_id uuid,
  p_row_ids uuid[] default null,
  p_acknowledge_current_configuration boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.irrigation_import_batches;
  r public.irrigation_import_rows;
  v_results jsonb := '[]'::jsonb;
  v_imported integer := 0;
  v_already integer := 0;
  v_skipped integer := 0;
  v_review integer := 0;
  v_tz text;
  v_started timestamptz;
  v_finished timestamptz;
  v_end_date date;
  v_duration integer;
  v_valve public.irrigation_valves;
  v_system public.irrigation_systems;
  v_alloc jsonb;
  v_result jsonb;
  v_session_id uuid;
  v_vintage integer;
  v_block jsonb;
  v_snapshot jsonb;
  v_import_meta jsonb;
  v_status text;
begin
  select * into v_batch from public.irrigation_import_batches where id = p_batch_id for update;
  if not found then
    raise exception 'not_found: import batch not found';
  end if;
  perform public._irrigation_import_require_admin(v_batch.vineyard_id);
  if v_batch.status in ('reversed','abandoned') then
    raise exception 'batch_closed: this batch can no longer be committed';
  end if;
  if v_batch.reprocess_of_batch_id is not null then
    raise exception 'validation_only: a revalidation batch cannot be committed — reverse the original batch first';
  end if;
  if not p_acknowledge_current_configuration then
    raise exception 'configuration_acknowledgement_required: Imported water will be allocated using each valve''s CURRENT VineTrack connection. Confirm that the connections reflect the imported period before committing.';
  end if;

  v_tz := coalesce(v_batch.timezone, 'Australia/Sydney');

  for r in
    select * from public.irrigation_import_rows
    where batch_id = p_batch_id
      and (p_row_ids is null or id = any(p_row_ids))
    order by source_row_number
    for update
  loop
    -- Idempotent retry: already linked to a live session.
    if r.created_session_id is not null and not r.is_reversed then
      v_already := v_already + 1;
      v_results := v_results || jsonb_build_object('row_id', r.id, 'status', 'already_imported',
        'session_id', r.created_session_id);
      continue;
    end if;
    if r.validation_status = 'needs_review' then
      v_review := v_review + 1;
      v_results := v_results || jsonb_build_object('row_id', r.id, 'status', 'needs_review',
        'reason', r.primary_exclusion_reason);
      continue;
    end if;
    if r.validation_status <> 'eligible' then
      if p_row_ids is not null then
        v_skipped := v_skipped + 1;
        v_results := v_results || jsonb_build_object('row_id', r.id, 'status', 'skipped',
          'reason', coalesce(r.primary_exclusion_reason, r.validation_status));
      end if;
      continue;
    end if;
    if r.duplicate_status in ('duplicate_imported','possible_duplicate_changed_values') then
      v_skipped := v_skipped + 1;
      v_results := v_results || jsonb_build_object('row_id', r.id, 'status', 'skipped_duplicate');
      continue;
    end if;

    -- Timestamps in the vineyard/controller timezone; overnight rolls +1 day.
    v_started := null; v_finished := null;
    if r.parsed_start_time is not null then
      v_started := (r.parsed_date::text || ' ' || r.parsed_start_time::text)::timestamp
                   at time zone v_tz;
      if r.parsed_end_time is not null then
        v_end_date := r.parsed_date
          + case when r.parsed_end_time <= r.parsed_start_time then 1 else 0 end;
        v_finished := (v_end_date::text || ' ' || r.parsed_end_time::text)::timestamp
                      at time zone v_tz;
      end if;
    end if;

    -- SQL 130 rule: the time pair is authoritative when present.
    if v_started is not null and v_finished is not null then
      v_duration := round(extract(epoch from (v_finished - v_started)) / 60.0)::integer;
    else
      v_duration := round(coalesce(r.parsed_duration_seconds, 0) / 60.0)::integer;
    end if;
    if v_duration < 1 or v_duration > 10080 then
      v_review := v_review + 1;
      update public.irrigation_import_rows
      set validation_status = 'needs_review', primary_exclusion_reason = 'invalid_runtime'
      where id = r.id;
      v_results := v_results || jsonb_build_object('row_id', r.id, 'status', 'needs_review',
        'reason', 'invalid_runtime');
      continue;
    end if;

    select * into v_valve from public.irrigation_valves where id = r.matched_valve_id;
    if v_valve.id is null or v_valve.vineyard_id <> v_batch.vineyard_id then
      v_review := v_review + 1;
      update public.irrigation_import_rows
      set validation_status = 'needs_review', primary_exclusion_reason = 'unmapped_valve'
      where id = r.id;
      v_results := v_results || jsonb_build_object('row_id', r.id, 'status', 'needs_review',
        'reason', 'unmapped_valve');
      continue;
    end if;
    select * into v_system from public.irrigation_systems where id = v_valve.irrigation_system_id;

    begin
      v_alloc := public._irrigation_valve_allocations(v_valve.id);
      v_result := public._irrigation_allocate(round(r.parsed_water_litres, 3), v_alloc);
    exception when others then
      v_review := v_review + 1;
      update public.irrigation_import_rows
      set validation_status = 'needs_review',
          primary_exclusion_reason = 'invalid_valve_connection',
          validation_warnings = validation_warnings || to_jsonb(sqlerrm)
      where id = r.id;
      v_results := v_results || jsonb_build_object('row_id', r.id, 'status', 'needs_review',
        'reason', 'invalid_valve_connection');
      continue;
    end;

    v_vintage := public.resolve_vineyard_vintage_year(v_batch.vineyard_id, r.parsed_date);
    v_session_id := gen_random_uuid();

    -- §31 frozen import snapshot — the session stays traceable to its source row.
    v_import_meta := jsonb_build_object(
      'provider', v_batch.provider,
      'batch_id', v_batch.id,
      'row_id', r.id,
      'source_row_number', r.source_row_number,
      'file_name', v_batch.file_name,
      'unit_name', v_batch.source_unit_name,
      'program', r.program_name,
      'external_valve_name', r.external_valve_name,
      'external_valve_number', r.external_valve_number,
      'external_station_code', r.external_station_code,
      'reported_runtime_seconds', r.parsed_duration_seconds,
      'reported_water_litres', r.parsed_water_litres,
      'reported_flow_litres_per_hour', r.parsed_flow_litres_per_hour,
      'original_water_value', r.original_water_value,
      'original_water_unit', r.original_water_unit,
      'original_flow_value', r.original_flow_value,
      'original_flow_unit', r.original_flow_unit,
      'source_comment', r.source_comment,
      'classification', r.classification,
      'event_fingerprint', r.event_fingerprint,
      'valve_mapping_id', r.matched_mapping_id,
      'water_flow_reconciliation', r.water_flow_reconciliation,
      'expected_water_litres', r.expected_water_litres,
      'validation_warnings', r.validation_warnings,
      'threshold_litres', v_batch.threshold_litres,
      'volume_comparison', v_batch.volume_comparison,
      'override_threshold', r.override_threshold,
      'override_test', r.override_test,
      'override_reason', r.override_reason,
      'override_by', r.override_by,
      'override_at', r.override_at,
      'configuration_basis', 'current_saved_valve_configuration',
      'current_configuration_acknowledged', true);

    v_snapshot := jsonb_build_object(
      'calculation_version', 1,
      'irrigation_system_id', v_system.id,
      'irrigation_system_name', v_system.name,
      'valve_id', v_valve.id,
      'valve_name', v_valve.name,
      'valve_configured_flow_lph', v_valve.configured_flow_litres_per_hour,
      'flow_lph_used', null,
      'calculation_method', 'controller_reported_volume',
      'unit_context', jsonb_build_object(
        'volume', 'litres', 'flow', 'litres_per_hour',
        'area', 'square_metres', 'depth', 'millimetres', 'duration', 'minutes'),
      'blocks', v_alloc,
      'import', v_import_meta);

    begin
      insert into public.irrigation_sessions (
        id, vineyard_id, irrigation_system_id, valve_id, session_date, vintage_year,
        started_at, finished_at, duration_minutes, calculation_method,
        flow_litres_per_hour, total_volume_litres, effective_volume_litres,
        original_value, original_unit, irrigation_efficiency_percent,
        status, source_type, external_source_id, import_batch_id, notes,
        configuration_snapshot, created_by, updated_by
      ) values (
        v_session_id, v_batch.vineyard_id, v_system.id, v_valve.id, r.parsed_date, v_vintage,
        v_started, v_finished, v_duration, 'controller_reported_volume',
        r.parsed_flow_litres_per_hour,
        (v_result->>'total_volume_litres')::numeric,
        nullif(v_result->>'effective_volume_litres', '')::numeric,
        r.original_water_value, coalesce(r.original_water_unit, 'm³'),
        nullif(v_result->>'irrigation_efficiency_percent', '')::numeric,
        'imported', 'galcon_gsi_import', r.event_fingerprint, v_batch.id, null,
        v_snapshot, auth.uid(), auth.uid());

      update public.irrigation_import_rows
      set created_session_id = v_session_id, is_reversed = false
      where id = r.id;
    exception when unique_violation then
      -- DB-level guard fired (concurrent commit or cross-batch duplicate).
      v_skipped := v_skipped + 1;
      update public.irrigation_import_rows
      set duplicate_status = 'duplicate_imported'
      where id = r.id and created_session_id is null;
      v_results := v_results || jsonb_build_object('row_id', r.id, 'status', 'skipped_duplicate');
      continue;
    end;

    for v_block in select * from jsonb_array_elements(v_result->'blocks') loop
      insert into public.irrigation_session_blocks (
        session_id, vineyard_id, valve_id, block_id, variety_id, variety_name,
        allocation_method, allocation_percentage, allocated_volume_litres,
        effective_volume_litres, serviced_area_m2, serviced_vine_count,
        water_litres_per_vine, water_litres_per_hectare,
        irrigation_depth_mm, effective_irrigation_depth_mm
      ) values (
        v_session_id, v_batch.vineyard_id, v_valve.id,
        (v_block->>'block_id')::uuid,
        nullif(v_block->>'variety_id', '')::uuid,
        nullif(v_block->>'variety_name', ''),
        coalesce(v_block->>'allocation_method', 'manual_percentage'),
        (v_block->>'allocation_percentage')::numeric,
        (v_block->>'allocated_volume_litres')::numeric,
        nullif(v_block->>'effective_volume_litres', '')::numeric,
        nullif(v_block->>'serviced_area_m2', '')::numeric,
        nullif(v_block->>'serviced_vine_count', '')::integer,
        nullif(v_block->>'water_litres_per_vine', '')::numeric,
        nullif(v_block->>'water_litres_per_hectare', '')::numeric,
        nullif(v_block->>'irrigation_depth_mm', '')::numeric,
        nullif(v_block->>'effective_irrigation_depth_mm', '')::numeric);
    end loop;

    if r.matched_mapping_id is not null then
      update public.irrigation_controller_valve_mappings
      set last_successfully_imported_at = now() where id = r.matched_mapping_id;
    end if;

    perform public._irrigation_audit(v_batch.vineyard_id, 'import_commit',
      'irrigation_session', v_session_id,
      null, jsonb_build_object('batch_id', v_batch.id, 'row_id', r.id,
                               'fingerprint', r.event_fingerprint,
                               'total_volume_litres', (v_result->>'total_volume_litres')::numeric));

    v_imported := v_imported + 1;
    v_results := v_results || jsonb_build_object('row_id', r.id, 'status', 'imported',
      'session_id', v_session_id);
  end loop;

  update public.irrigation_import_batches b
  set imported_sessions = (select count(*) from public.irrigation_import_rows rw
                           where rw.batch_id = p_batch_id
                             and rw.created_session_id is not null and not rw.is_reversed),
      status = case
        when not exists (select 1 from public.irrigation_import_rows rw
                         where rw.batch_id = p_batch_id
                           and rw.validation_status = 'eligible'
                           and rw.created_session_id is null)
          then 'committed'
        else 'partially_committed' end,
      completed_at = now()
  where b.id = p_batch_id;

  update public.irrigation_import_provider_settings
  set last_imported_at = now()
  where vineyard_id = v_batch.vineyard_id and provider = v_batch.provider
    and lower(external_controller_key) = lower(v_batch.external_controller_key);

  return jsonb_build_object(
    'batch_id', p_batch_id,
    'imported', v_imported,
    'already_imported', v_already,
    'skipped_duplicate', v_skipped,
    'needs_review', v_review,
    'results', v_results);
end;
$$;

-- ---------------------------------------------------------------------------
-- 14. Batch reads
-- ---------------------------------------------------------------------------
create or replace function public.get_irrigation_import_batch(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_batch public.irrigation_import_batches;
begin
  select * into v_batch from public.irrigation_import_batches where id = p_batch_id;
  if not found then
    raise exception 'not_found: import batch not found';
  end if;
  perform public._irrigation_import_require_admin(v_batch.vineyard_id);
  return public.preview_irrigation_import(p_batch_id);
end;
$$;

create or replace function public.list_irrigation_import_batches(
  p_vineyard_id uuid,
  p_provider text default null,
  p_limit integer default 25,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._irrigation_import_require_admin(p_vineyard_id);
  return coalesce((
    select jsonb_agg(to_jsonb(b) order by b.created_at desc)
    from (
      select * from public.irrigation_import_batches
      where vineyard_id = p_vineyard_id
        and (p_provider is null or provider = p_provider)
      order by created_at desc
      limit greatest(coalesce(p_limit, 25), 1)
      offset greatest(coalesce(p_offset, 0), 0)
    ) b
  ), '[]'::jsonb);
end;
$$;

-- Paginated rows. Raw payloads stay out of normal screens (p_include_raw).
create or replace function public.list_irrigation_import_rows(
  p_batch_id uuid,
  p_validation_status text default null,
  p_classification text default null,
  p_limit integer default 100,
  p_offset integer default 0,
  p_include_raw boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_batch public.irrigation_import_batches;
  v_total integer;
  v_rows jsonb;
begin
  select * into v_batch from public.irrigation_import_batches where id = p_batch_id;
  if not found then
    raise exception 'not_found: import batch not found';
  end if;
  perform public._irrigation_import_require_admin(v_batch.vineyard_id);

  select count(*) into v_total
  from public.irrigation_import_rows
  where batch_id = p_batch_id
    and (p_validation_status is null or validation_status = p_validation_status)
    and (p_classification is null or classification = p_classification);

  select coalesce(jsonb_agg(
    (to_jsonb(rw) - 'raw_payload')
    || case when p_include_raw then jsonb_build_object('raw_payload', rw.raw_payload)
            else '{}'::jsonb end
    || jsonb_build_object('vinetrack_valve_name', v.name)
    order by rw.source_row_number), '[]'::jsonb)
  into v_rows
  from (
    select * from public.irrigation_import_rows
    where batch_id = p_batch_id
      and (p_validation_status is null or validation_status = p_validation_status)
      and (p_classification is null or classification = p_classification)
    order by source_row_number
    limit greatest(coalesce(p_limit, 100), 1)
    offset greatest(coalesce(p_offset, 0), 0)
  ) rw
  left join public.irrigation_valves v on v.id = rw.matched_valve_id;

  return jsonb_build_object('rows', v_rows, 'total_count', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 15. Batch reversal (dry-run preview + audited execute)
-- ---------------------------------------------------------------------------
create or replace function public.reverse_irrigation_import_batch(
  p_batch_id uuid,
  p_dry_run boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch public.irrigation_import_batches;
  v_impact jsonb;
  v_count integer;
begin
  select * into v_batch from public.irrigation_import_batches where id = p_batch_id for update;
  if not found then
    raise exception 'not_found: import batch not found';
  end if;
  perform public._irrigation_import_require_admin(v_batch.vineyard_id);

  select jsonb_build_object(
    'batch_id', p_batch_id,
    'sessions_affected', count(*),
    'total_water_litres_removed', coalesce(sum(s.total_volume_litres), 0),
    'date_range_from', min(s.session_date),
    'date_range_to', max(s.session_date),
    'valves_affected', coalesce(jsonb_agg(distinct v.name), '[]'::jsonb))
  into v_impact
  from public.irrigation_sessions s
  join public.irrigation_valves v on v.id = s.valve_id
  where s.import_batch_id = p_batch_id
    and s.source_type = 'galcon_gsi_import'
    and s.status <> 'reversed' and s.deleted_at is null;

  if p_dry_run then
    return v_impact || jsonb_build_object('dry_run', true);
  end if;

  if v_batch.status = 'reversed' then
    return v_impact || jsonb_build_object('dry_run', false, 'already_reversed', true);
  end if;

  -- Reverse ONLY the sessions this batch created. Manual sessions untouched;
  -- batch and source rows are preserved for audit.
  update public.irrigation_sessions
  set status = 'reversed', deleted_at = now(), updated_by = auth.uid()
  where import_batch_id = p_batch_id
    and source_type = 'galcon_gsi_import'
    and status <> 'reversed' and deleted_at is null;
  get diagnostics v_count = row_count;

  update public.irrigation_import_rows
  set is_reversed = true
  where batch_id = p_batch_id and created_session_id is not null;

  update public.irrigation_import_batches
  set status = 'reversed', reversed_at = now(), reversed_by = auth.uid()
  where id = p_batch_id;

  perform public._irrigation_audit(v_batch.vineyard_id, 'reverse',
    'irrigation_import_batch', p_batch_id, to_jsonb(v_batch),
    v_impact || jsonb_build_object('sessions_reversed', v_count));

  return v_impact || jsonb_build_object('dry_run', false, 'sessions_reversed', v_count);
end;
$$;

-- ---------------------------------------------------------------------------
-- 16. Session surface updates (source filter + import info for mobile/portal)
-- ---------------------------------------------------------------------------

-- Session json now exposes the frozen import metadata (never raw payloads).
create or replace function public._irrigation_session_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select to_jsonb(s)
         || jsonb_build_object(
              'system_name', sys.name,
              'valve_name', v.name,
              'import_info', s.configuration_snapshot->'import',
              'blocks', coalesce((
                select jsonb_agg(to_jsonb(sb) || jsonb_build_object('block_name', p.name)
                                 order by p.name)
                from public.irrigation_session_blocks sb
                join public.paddocks p on p.id = sb.block_id
                where sb.session_id = s.id
              ), '[]'::jsonb))
  from public.irrigation_sessions s
  join public.irrigation_systems sys on sys.id = s.irrigation_system_id
  join public.irrigation_valves v on v.id = s.valve_id
  where s.id = p_id;
$$;

-- list_irrigation_sessions: p_source_type now also accepts the pseudo values
-- 'manual' (any manual_%) and 'imported' (any controller/import source), so
-- mobile history can filter Manual vs Imported with one parameter.
create or replace function public.list_irrigation_sessions(
  p_vineyard_id uuid,
  p_vintage_year integer default null,
  p_from_date date default null,
  p_to_date date default null,
  p_irrigation_system_id uuid default null,
  p_valve_id uuid default null,
  p_block_id uuid default null,
  p_status text default null,
  p_source_type text default null,
  p_include_reversed boolean default false,
  p_limit integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sessions jsonb;
  v_total integer;
begin
  perform public._irrigation_require_access(p_vineyard_id);

  select count(*) into v_total
  from public.irrigation_sessions s
  where s.vineyard_id = p_vineyard_id
    and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
    and (p_vintage_year is null or s.vintage_year = p_vintage_year)
    and (p_from_date is null or s.session_date >= p_from_date)
    and (p_to_date is null or s.session_date <= p_to_date)
    and (p_irrigation_system_id is null or s.irrigation_system_id = p_irrigation_system_id)
    and (p_valve_id is null or s.valve_id = p_valve_id)
    and (p_status is null or s.status = p_status)
    and (p_source_type is null
         or (p_source_type = 'manual' and s.source_type like 'manual\_%')
         or (p_source_type = 'imported' and s.source_type in
             ('galcon_gsi_import','csv_import','controller_api'))
         or s.source_type = p_source_type)
    and (p_block_id is null or exists (
      select 1 from public.irrigation_session_blocks sb
      where sb.session_id = s.id and sb.block_id = p_block_id));

  select coalesce(jsonb_agg(row_json), '[]'::jsonb) into v_sessions
  from (
    select public._irrigation_session_json(s.id) as row_json
    from public.irrigation_sessions s
    where s.vineyard_id = p_vineyard_id
      and (p_include_reversed or (s.status <> 'reversed' and s.deleted_at is null))
      and (p_vintage_year is null or s.vintage_year = p_vintage_year)
      and (p_from_date is null or s.session_date >= p_from_date)
      and (p_to_date is null or s.session_date <= p_to_date)
      and (p_irrigation_system_id is null or s.irrigation_system_id = p_irrigation_system_id)
      and (p_valve_id is null or s.valve_id = p_valve_id)
      and (p_status is null or s.status = p_status)
      and (p_source_type is null
           or (p_source_type = 'manual' and s.source_type like 'manual\_%')
           or (p_source_type = 'imported' and s.source_type in
               ('galcon_gsi_import','csv_import','controller_api'))
           or s.source_type = p_source_type)
      and (p_block_id is null or exists (
        select 1 from public.irrigation_session_blocks sb
        where sb.session_id = s.id and sb.block_id = p_block_id))
    order by s.session_date desc, s.created_at desc
    limit greatest(coalesce(p_limit, 50), 1)
    offset greatest(coalesce(p_offset, 0), 0)
  ) rows;

  return jsonb_build_object('sessions', v_sessions, 'total_count', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 17. Grants
-- ---------------------------------------------------------------------------
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'get_irrigation_import_provider_settings(uuid, text, text)',
    'set_irrigation_import_provider_settings(uuid, text, text, text, numeric, text, boolean, text)',
    'create_irrigation_import_batch(uuid, uuid, text, text, text, integer, text, text, integer, text, boolean)',
    'stage_irrigation_import_rows(uuid, jsonb)',
    'list_irrigation_import_valves(uuid)',
    'set_irrigation_controller_valve_mapping(uuid, text, text, text, text, integer, text, uuid, boolean, boolean)',
    'validate_irrigation_import(uuid, numeric, text, boolean)',
    'set_irrigation_import_row_override(uuid, boolean, boolean, text)',
    'preview_irrigation_import(uuid)',
    'commit_irrigation_import(uuid, uuid[], boolean)',
    'get_irrigation_import_batch(uuid)',
    'list_irrigation_import_batches(uuid, text, integer, integer)',
    'list_irrigation_import_rows(uuid, text, text, integer, integer, boolean)',
    'reverse_irrigation_import_batch(uuid, boolean)'
  ]
  loop
    execute format('revoke all on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 18. Regression tests (mirrors the supplied-workbook fixtures)
-- ---------------------------------------------------------------------------
do $$
declare
  v_fp1 text;
  v_fp2 text;
  v_fp3 text;
begin
  -- Comment classification — exact strings observed in HistoryIrrigation.xlsx.
  assert public._galcon_classify_comment('OK') = 'completed';
  assert public._galcon_classify_comment('  ok  ') = 'completed';
  assert public._galcon_classify_comment('Irrigation ended manually') = 'ended_manually';
  assert public._galcon_classify_comment('Cancel (Valve canceled manually)') = 'cancelled_manual';
  assert public._galcon_classify_comment('Cancel (Valve canceled due to error)') = 'cancelled_error';
  assert public._galcon_classify_comment('Cancel (Valves not enabled)') = 'cancelled_not_enabled';
  assert public._galcon_classify_comment('Error (Low Flow)') = 'low_flow_error';
  assert public._galcon_classify_comment('Error (High Flow)') = 'high_flow_error';
  assert public._galcon_classify_comment('Error (No Water Flow)') = 'no_flow_error';
  assert public._galcon_classify_comment('Irrigation paused due to waiting condition') = 'paused';
  assert public._galcon_classify_comment('Irrigation paused due to waiting condition ') = 'paused';
  assert public._galcon_classify_comment('Continue unfinished irrigation') = 'continued';
  -- Punctuation/spelling variants (em-dash and UK spelling).
  assert public._galcon_classify_comment('Cancel — Valve cancelled manually') = 'cancelled_manual';
  assert public._galcon_classify_comment('Cancel — Valve cancelled due to error') = 'cancelled_error';
  assert public._galcon_classify_comment('Something new entirely') = 'unknown_comment';
  assert public._galcon_classify_comment(null) = 'unknown_comment';

  -- Threshold: default is STRICTLY more than 1,000 L.
  assert not public._irrigation_import_passes_threshold(0, 1000, 'greater_than');
  assert not public._irrigation_import_passes_threshold(999.999, 1000, 'greater_than');
  assert not public._irrigation_import_passes_threshold(1000, 1000, 'greater_than');
  assert public._irrigation_import_passes_threshold(1000.001, 1000, 'greater_than');
  assert public._irrigation_import_passes_threshold(1000, 1000, 'greater_than_or_equal');
  assert not public._irrigation_import_passes_threshold(null, 1000, 'greater_than');

  -- Fingerprints: identical events fingerprint identically regardless of
  -- comment whitespace/case; changed values change the fingerprint.
  v_fp1 := public._irrigation_import_fingerprint('galcon_gsi',
    '00000000-0000-0000-0000-000000000001', 'Stockman''s Ridge Wines', 'S7', 7,
    '2026-05-06', '13:28:48', '13:29:51', 63, 200, 12000, 'OK', 'Test');
  v_fp2 := public._irrigation_import_fingerprint('galcon_gsi',
    '00000000-0000-0000-0000-000000000001', ' stockman''s  ridge wines ', 's7', 7,
    '2026-05-06', '13:28:48', '13:29:51', 63, 200.000, 12000.0, ' ok ', 'test');
  v_fp3 := public._irrigation_import_fingerprint('galcon_gsi',
    '00000000-0000-0000-0000-000000000001', 'Stockman''s Ridge Wines', 'S7', 7,
    '2026-05-06', '13:28:48', '13:29:51', 63, 300, 12000, 'OK', 'Test');
  assert v_fp1 = v_fp2, 'fingerprint must be format/whitespace independent';
  assert v_fp1 <> v_fp3, 'changed water quantity must change the fingerprint';

  -- Canonical numeric rendering is stable across integer/decimal inputs.
  assert public._irrigation_import_num_text(1000) = public._irrigation_import_num_text(1000.000);
  assert public._irrigation_import_num_text(null) = '';

  raise notice 'SQL 142 irrigation import framework tests passed';
end $$;

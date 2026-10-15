-- REFERENCE ONLY: ALREADY APPLIED to VineTrackv2. Do not re-execute.
-- Migration: 20261015102804_legacy_spray_pair_receipts_v1
-- Exact SQL from supabase_migrations.schema_migrations follows this header.

-- SQL 279: atomic, immutable receipt contract for legacy no-route Save for Later.
-- Separate from occurrence authority and new spray planning. Additive, no backfill.
create schema if not exists vinetrack_private;
revoke all on schema vinetrack_private from public, anon, authenticated;

create table if not exists vinetrack_private.legacy_spray_pair_receipts_v1 (
  operation_id uuid primary key,
  actor_user_id uuid not null references auth.users(id),
  vineyard_id uuid not null references public.vineyards(id),
  trip_id uuid not null,
  spray_record_id uuid not null,
  request_sha256 text not null check (request_sha256 ~ '^[0-9a-f]{64}$'),
  request_trip jsonb not null,
  request_record jsonb not null,
  outcome text not null check (outcome in ('accepted','rejected')),
  failure_code text,
  receipt jsonb not null,
  committed_at timestamptz not null default now(),
  constraint legacy_pair_request_objects check (
    jsonb_typeof(request_trip) = 'object' and jsonb_typeof(request_record) = 'object'
  ),
  constraint legacy_pair_outcome_code check (
    (outcome = 'accepted' and failure_code is null) or
    (outcome = 'rejected' and failure_code is not null)
  )
);
create unique index if not exists legacy_pair_accepted_trip_v1_uidx
  on vinetrack_private.legacy_spray_pair_receipts_v1 (trip_id) where outcome = 'accepted';
create unique index if not exists legacy_pair_accepted_record_v1_uidx
  on vinetrack_private.legacy_spray_pair_receipts_v1 (spray_record_id) where outcome = 'accepted';
create index if not exists legacy_pair_vineyard_actor_v1_idx
  on vinetrack_private.legacy_spray_pair_receipts_v1 (vineyard_id,actor_user_id,committed_at);
alter table vinetrack_private.legacy_spray_pair_receipts_v1 enable row level security;
revoke all on table vinetrack_private.legacy_spray_pair_receipts_v1
  from public, anon, authenticated;

-- Security definer is intentional: private ledger has NO client grants.
-- Every RPC validates the authenticated actor and current vineyard membership.
-- No dynamic SQL, no client-chosen schema/table/column names.
create or replace function public.save_legacy_spray_pair_v1(
  p_operation_id uuid,
  p_trip jsonb,
  p_record jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $rpc$
declare
  v_actor uuid := auth.uid();
  v_vineyard uuid;
  v_trip_id uuid;
  v_record_id uuid;
  v_trip_ref uuid;
  v_hash text;
  v_existing vinetrack_private.legacy_spray_pair_receipts_v1%rowtype;
  v_lock bigint;
  v_now timestamptz := transaction_timestamp();
  v_outcome text := 'accepted';
  v_failure text;
  v_receipt jsonb;
  v_trip_payload jsonb;
  v_record_payload jsonb;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  if p_operation_id is null or jsonb_typeof(p_trip) is distinct from 'object'
       or jsonb_typeof(p_record) is distinct from 'object'
       or pg_column_size(p_trip) + pg_column_size(p_record) > 4194304 then
    raise exception 'Invalid legacy spray pair request' using errcode='22023';
  end if;
  -- Reject fields not used by the original no-route, inactive Trip and spray
  -- insert contracts. Triggers still validate references and block attribution.
  if exists (
    select 1 from jsonb_object_keys(p_trip) as k(key)
    where k.key <> all (array[
      'id','vineyard_id','paddock_id','paddock_ids','paddock_name',
      'tracking_pattern','start_time','is_active','is_paused',
      'person_name','trip_function','trip_title','machine_id','tractor_id',
      'work_task_id','operator_user_id','worker_type_id','total_distance',
      'path_points','start_engine_hours','seeding_details','row_sequence',
      'sequence_index','current_row_number','next_row_number','total_tanks',
      'created_by','client_updated_at'
    ])
  ) or exists (
    select 1 from jsonb_object_keys(p_record) as k(key)
    where k.key <> all (array[
      'id','vineyard_id','date','start_time','temperature','wind_speed',
      'wind_direction','humidity','spray_reference','notes',
      'number_of_fans_jets','average_speed','equipment_type','tractor',
      'tractor_gear','machine_id','tractor_id','spray_equipment_id',
      'operation_type','trip_id','spray_job_id','is_template','tanks',
      'gross_area_ha','treated_area_ha','application_mode',
      'treated_area_method','band_width_total_metres',
      'band_width_left_metres','band_width_right_metres',
      'canonical_row_length_metres','row_spacing_metres','geometry_source',
      'geometry_quality','carrier_volume_basis','total_carrier_litres',
      'carrier_litres_per_hectare','dilute_litres_per_100m',
      'applied_litres_per_100m','concentration_factor','targets',
      'spray_head_target','ground_application_target','carrier_area_basis',
      'application_blocks','entry_source','created_by','client_updated_at'
    ])
  ) then
    raise exception 'Unexpected legacy spray pair fields' using errcode='22023';
  end if;
  begin
    v_vineyard := (p_trip->>'vineyard_id')::uuid;
    v_trip_id := (p_trip->>'id')::uuid;
    v_record_id := (p_record->>'id')::uuid;
    v_trip_ref := (p_record->>'trip_id')::uuid;
  exception when invalid_text_representation then
    raise exception 'Invalid pair identity' using errcode='22023';
  end;
  if v_vineyard is null or v_trip_id is null or v_record_id is null
       or v_trip_ref is distinct from v_trip_id
       or (p_record->>'vineyard_id') is distinct from v_vineyard::text
       or not public.has_vineyard_role(v_vineyard,
           array['owner','manager','supervisor','operator']) then
    raise exception 'Pair identity or vineyard access denied' using errcode='42501';
  end if;
  if (p_trip->>'created_by' is not null and p_trip->>'created_by' <> v_actor::text)
       or (p_record->>'created_by' is not null and p_record->>'created_by' <> v_actor::text)
       or (p_trip->>'is_active') is distinct from 'false'
       or coalesce(p_trip->>'is_paused','false') <> 'false'
       or (p_trip->>'work_task_id') is not null
       or coalesce(p_trip->'row_sequence','[]'::jsonb) <> '[]'::jsonb
       or coalesce(p_trip->'path_points','[]'::jsonb) <> '[]'::jsonb
       or coalesce((p_trip->>'total_distance')::numeric,0) <> 0
       or p_trip->>'start_time' is null
       or p_trip->>'client_updated_at' is null
       or coalesce(p_record->>'is_template','false') <> 'false'
       or p_record->>'entry_source' not in ('tracked')
       or p_record->>'date' is null or p_record->>'start_time' is null
       or p_record->>'client_updated_at' is null
       or jsonb_typeof(p_record->'tanks') is distinct from 'array'
       or (p_trip ? 'paddock_ids' and jsonb_typeof(p_trip->'paddock_ids') <> 'array') then
    raise exception 'Legacy Save for Later must be an inactive no-route pair' using errcode='22023';
  end if;
  -- Scope optional block ids before privileged insertion.
  if (p_trip->>'paddock_id') is not null and not exists (
    select 1 from public.paddocks p
    where p.id=(p_trip->>'paddock_id')::uuid and p.vineyard_id=v_vineyard
  ) then
    raise exception 'Trip block is outside vineyard' using errcode='42501';
  end if;
  if exists (
    select 1 from jsonb_array_elements_text(coalesce(p_trip->'paddock_ids','[]'::jsonb)) as b(value)
    where not exists (select 1 from public.paddocks p
      where p.id=b.value::uuid and p.vineyard_id=v_vineyard)
  ) then
    raise exception 'Trip blocks are outside vineyard' using errcode='42501';
  end if;

  v_hash := encode(extensions.digest(convert_to(
    jsonb_build_object('v',1,'actor',v_actor,'operation',p_operation_id,
      'vineyard',v_vineyard,'trip',p_trip,'record',p_record)::text, 'UTF8'
  ),'sha256'),'hex');

  -- Lock by operation AND by both original record IDs, in sorted order.
  perform pg_advisory_xact_lock(hashtextextended('legacy-pair-operation:'||p_operation_id::text,0));
  for v_lock in select distinct h from (
    values
      (hashtextextended('legacy-pair-trip:'||v_trip_id::text,0)),
      (hashtextextended('legacy-pair-record:'||v_record_id::text,0))
  ) as locks(h) order by h loop
    perform pg_advisory_xact_lock(v_lock);
  end loop;
  select * into v_existing from vinetrack_private.legacy_spray_pair_receipts_v1
  where operation_id=p_operation_id;
  if found then
    if v_existing.actor_user_id=v_actor
       and v_existing.vineyard_id=v_vineyard
       and v_existing.trip_id=v_trip_id
       and v_existing.spray_record_id=v_record_id
       and v_existing.request_sha256=v_hash
       and v_existing.request_trip=p_trip
       and v_existing.request_record=p_record then
      return v_existing.receipt;
    end if;
    return jsonb_build_object('version',1,'status','conflict','code','operation_payload_mismatch');
  end if;
  -- Existing unreceipted REST rows must NEVER be adopted as evidence.
  if exists(select 1 from public.trips where id=v_trip_id)
     or exists(select 1 from public.spray_records where id=v_record_id)
     or exists(select 1 from vinetrack_private.legacy_spray_pair_receipts_v1
       where outcome='accepted'
         and (trip_id=v_trip_id or spray_record_id=v_record_id)) then
    v_outcome := 'rejected';
    v_failure := 'identity_conflict';
  else
    v_trip_payload := p_trip || jsonb_build_object(
      'created_by',v_actor,'updated_by',v_actor,
      'created_at',v_now,'updated_at',v_now,'sync_version',1,
      'is_active',false,'is_paused',false,'deleted_at',null
    );
    v_record_payload := p_record || jsonb_build_object(
      'created_by',v_actor,'updated_by',v_actor,
      'created_at',v_now,'updated_at',v_now,'sync_version',1,
      'is_template',false,'deleted_at',null
    );
    begin
      insert into public.trips
        select (jsonb_populate_record(null::public.trips,v_trip_payload)).*;
      insert into public.spray_records
        select (jsonb_populate_record(null::public.spray_records,v_record_payload)).*;
    exception
      when unique_violation or foreign_key_violation or check_violation
        or not_null_violation or invalid_text_representation
        or invalid_datetime_format or numeric_value_out_of_range then
        v_outcome := 'rejected';
        v_failure := 'validation_or_reference_conflict';
    end;
  end if;
  v_receipt := jsonb_build_object(
    'version',1,'status',v_outcome,'operation_id',p_operation_id,
    'vineyard_id',v_vineyard,'trip_id',v_trip_id,
    'spray_record_id',v_record_id,'request_sha256',v_hash,
    'committed_at',v_now
  );
  if v_failure is not null then
    v_receipt := v_receipt || jsonb_build_object('code',v_failure);
  end if;
  insert into vinetrack_private.legacy_spray_pair_receipts_v1
    (operation_id,actor_user_id,vineyard_id,trip_id,spray_record_id,
     request_sha256,request_trip,request_record,outcome,failure_code,receipt,committed_at)
  values
    (p_operation_id,v_actor,v_vineyard,v_trip_id,v_record_id,
     v_hash,p_trip,p_record,v_outcome,v_failure,v_receipt,v_now);
  return v_receipt;
end;
$rpc$;

create or replace function public.recover_legacy_spray_pair_v1(
  p_operation_id uuid,
  p_trip jsonb,
  p_record jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $rpc$
declare
  v_actor uuid := auth.uid();
  v_vineyard uuid;
  v_trip_id uuid;
  v_record_id uuid;
  v_hash text;
  v_existing vinetrack_private.legacy_spray_pair_receipts_v1%rowtype;
begin
  if v_actor is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  if p_operation_id is null or jsonb_typeof(p_trip) is distinct from 'object'
       or jsonb_typeof(p_record) is distinct from 'object'
       or pg_column_size(p_trip)+pg_column_size(p_record)>4194304 then
    raise exception 'Invalid receipt recovery request' using errcode='22023';
  end if;
  begin
    v_vineyard:=(p_trip->>'vineyard_id')::uuid;
    v_trip_id:=(p_trip->>'id')::uuid;
    v_record_id:=(p_record->>'id')::uuid;
  exception when invalid_text_representation then
    raise exception 'Invalid receipt identity' using errcode='22023';
  end;
  if v_vineyard is null or v_trip_id is null or v_record_id is null
       or (p_record->>'trip_id') is distinct from v_trip_id::text
       or (p_record->>'vineyard_id') is distinct from v_vineyard::text
       or not public.has_vineyard_role(v_vineyard,
           array['owner','manager','supervisor','operator']) then
    raise exception 'Receipt identity or vineyard access denied' using errcode='42501';
  end if;
  v_hash := encode(extensions.digest(convert_to(
    jsonb_build_object('v',1,'actor',v_actor,'operation',p_operation_id,
      'vineyard',v_vineyard,'trip',p_trip,'record',p_record)::text,'UTF8'
  ),'sha256'),'hex');
  select * into v_existing
    from vinetrack_private.legacy_spray_pair_receipts_v1
    where operation_id=p_operation_id;
  if not found then
    -- Unknown is NOT proof of non-delivery of any prior unreceipted REST writes.
    return jsonb_build_object('version',1,'status','unknown','operation_id',p_operation_id);
  end if;
  if v_existing.actor_user_id is distinct from v_actor
      or v_existing.vineyard_id is distinct from v_vineyard
      or v_existing.trip_id is distinct from v_trip_id
      or v_existing.spray_record_id is distinct from v_record_id
      or v_existing.request_sha256 is distinct from v_hash
      or v_existing.request_trip is distinct from p_trip
      or v_existing.request_record is distinct from p_record then
    return jsonb_build_object('version',1,'status','conflict','code','operation_payload_mismatch');
  end if;
  return v_existing.receipt;
end;
$rpc$;

revoke all on function public.save_legacy_spray_pair_v1(uuid,jsonb,jsonb)
  from public, anon, authenticated;
revoke all on function public.recover_legacy_spray_pair_v1(uuid,jsonb,jsonb)
  from public, anon, authenticated;
grant execute on function public.save_legacy_spray_pair_v1(uuid,jsonb,jsonb)
  to authenticated;
grant execute on function public.recover_legacy_spray_pair_v1(uuid,jsonb,jsonb)
  to authenticated;
comment on function public.save_legacy_spray_pair_v1(uuid,jsonb,jsonb) is
  'Atomic no-route Save for Later; immutable actor/payload-bound receipt; never adopt old REST rows.';
comment on function public.recover_legacy_spray_pair_v1(uuid,jsonb,jsonb) is
  'Read-only immutable legacy pair receipt recovery; unknown never authorizes blind retry.';

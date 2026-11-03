-- VineTrack iOS guided repair: explicitly reviewed legacy Trip tombstone.
-- Additive only. No existing Trip/cancellation RPC is changed and this script
-- does NOT modify any production record. A signed-in Owner or Manager must
-- explicitly invoke it after reviewing a saved original Trip deletion.
--
-- This is NOT generic queue cleanup. The original server Trip must already
-- be soft-deleted. Dependent Spray, Actual and Cost rows are archived first,
-- then soft-deleted transactionally. Original Trip id / deleted_at untouched.
-- Stable operation id + unique receipt permit lost-response replay.
create or replace function public.reconcile_deleted_trip_activity_v1(
    p_operation_id uuid,
    p_trip_id uuid,
    p_vineyard_id uuid,
    p_application text,
    p_attestation text,
    p_client_evidence jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
    v_uid uuid := auth.uid();
    v_role text;
    v_trip public.trips;
    v_existing public.trip_activity_cancellation_receipts;
    v_receipt public.trip_activity_cancellation_receipts;
    v_sprays uuid[];
    v_archive uuid;
    n_actuals integer := 0;
    n_spray integer := 0;
    n_cost integer := 0;
    v_facts jsonb;
begin
    if v_uid is null then
        raise exception 'TRIP_REVIEW_AUTH_REQUIRED' using errcode='42501';
    end if;
    if p_operation_id is null or p_trip_id is null or p_vineyard_id is null then
        raise exception 'TRIP_REVIEW_INVALID_IDENTITY' using errcode='22023';
    end if;
    if p_application is null or p_application not in ('not_applied','applied') then
        raise exception 'TRIP_REVIEW_APPLICATION_REQUIRED' using errcode='22023';
    end if;
    if p_attestation is null or length(btrim(p_attestation)) < 12
       or length(btrim(p_attestation)) > 500 then
        raise exception 'TRIP_REVIEW_EVIDENCE_NOTE_REQUIRED' using errcode='22023';
    end if;
    if p_client_evidence is null or jsonb_typeof(p_client_evidence) <> 'object'
       or octet_length(p_client_evidence::text) > 1048576 then
        raise exception 'TRIP_REVIEW_INVALID_CLIENT_EVIDENCE' using errcode='22023';
    end if;
    v_role := public.vineyard_role(p_vineyard_id);
    if v_role is null or v_role not in ('owner','manager') then
        raise exception 'TRIP_REVIEW_FORBIDDEN' using errcode='42501';
    end if;

    -- Serialize review with any other cancellation of the exact Trip.
    select * into v_trip from public.trips
      where id=p_trip_id and vineyard_id=p_vineyard_id for update;
    if not found then
        raise exception 'TRIP_REVIEW_ORIGINAL_NOT_FOUND' using errcode='P0002';
    end if;
    if v_trip.deleted_at is null then
        raise exception 'TRIP_REVIEW_NOT_DELETED' using errcode='55000';
    end if;

    select * into v_existing from public.trip_activity_cancellation_receipts
      where trip_id=p_trip_id for update;
    if found then
        if v_existing.operation_id <> p_operation_id
           or v_existing.vineyard_id <> p_vineyard_id
           or v_existing.application_classification <> p_application then
            raise exception 'TRIP_REVIEW_RECEIPT_OPERATION_CONFLICT' using errcode='23505';
        end if;
        return public.trip_cancellation_receipt_json_v1(v_existing)
            || jsonb_build_object('replayed',true,'reviewed_legacy_tombstone',true);
    end if;
    if exists (
        select 1 from public.trip_activity_cancellation_receipts
        where operation_id=p_operation_id and trip_id<>p_trip_id
    ) then
        raise exception 'TRIP_REVIEW_OPERATION_ID_CONFLICT' using errcode='23505';
    end if;

    if p_application='not_applied' and (
       exists (select 1 from public.spray_tank_actuals
               where trip_id=p_trip_id and deleted_at is null)
       or jsonb_array_length(
            case when jsonb_typeof(p_client_evidence->'tanks')='array'
                 then p_client_evidence->'tanks' else '[]'::jsonb end
          ) > 0
    ) then
        raise exception 'TRIP_REVIEW_RECORDED_ACTUALS_NEED_APPLIED_REVIEW' using errcode='55000';
    end if;

    select coalesce(array_agg(id order by id),'{}') into v_sprays
      from public.spray_records where trip_id=p_trip_id and vineyard_id=p_vineyard_id
        and deleted_at is null;

    -- Compliance: retain every server-side original even if the handset never
    -- uploaded its final Actual Use. The reviewed device evidence is included
    -- verbatim, with provenance, without guessing missing fields.
    v_facts := jsonb_build_object(
        'contract','vinetrack.guided-deleted-trip-reconciliation-v1',
        'original_trip',to_jsonb(v_trip),
        'original_sprays',coalesce(
          (select jsonb_agg(to_jsonb(s)) from public.spray_records s
           where s.trip_id=p_trip_id and s.vineyard_id=p_vineyard_id), '[]'::jsonb),
        'original_tank_actuals',coalesce(
          (select jsonb_agg(to_jsonb(a)) from public.spray_tank_actuals a
           where a.trip_id=p_trip_id), '[]'::jsonb),
        'original_cost_allocations',coalesce(
          (select jsonb_agg(to_jsonb(c)) from public.trip_cost_allocations c
           where c.trip_id=p_trip_id), '[]'::jsonb),
        'operator_attestation',btrim(p_attestation),
        'application_classification',p_application,
        'client_original_evidence',p_client_evidence,
        'actor_user_id',v_uid,
        'actor_role',v_role,
        'legacy_server_deleted_at',v_trip.deleted_at,
        'reviewed_at',clock_timestamp()
    );
    insert into public.trip_compliance_archive (
        operation_id, trip_id, vineyard_id, source, facts, retain_until, created_by
    ) values (
        p_operation_id,p_trip_id,p_vineyard_id,'applied_trip_cancellation',
        v_facts,(current_date + interval '3 years')::date,v_uid
    ) returning id into v_archive;

    update public.spray_tank_actuals set deleted_at=clock_timestamp(),
        updated_by=v_uid where trip_id=p_trip_id and deleted_at is null;
    get diagnostics n_actuals=row_count;

    update public.trip_cost_allocations set deleted_at=clock_timestamp(),
        updated_by=v_uid where trip_id=p_trip_id and deleted_at is null;
    get diagnostics n_cost=row_count;

    update public.spray_records set deleted_at=clock_timestamp(),
        updated_by=v_uid where id=any(v_sprays) and deleted_at is null;
    get diagnostics n_spray=row_count;

    insert into public.trip_activity_cancellation_receipts (
        operation_id,trip_id,vineyard_id,actor_user_id,actor_role,
        application_classification,compliance_archive_id,spray_record_ids,
        removed_counts,client_baseline
    ) values (
        p_operation_id,p_trip_id,p_vineyard_id,v_uid,v_role,p_application,
        v_archive,v_sprays,
        jsonb_build_object('trip',0,'spray_records',n_spray,
                           'spray_tank_actuals',n_actuals,
                           'trip_cost_allocations',n_cost),
        jsonb_build_object('legacy_tombstone_reviewed',true,
                           'original_deleted_at',v_trip.deleted_at,
                           'client_evidence_present',p_client_evidence<>'{}'::jsonb)
    ) returning * into v_receipt;

    return public.trip_cancellation_receipt_json_v1(v_receipt)
        || jsonb_build_object('replayed',false,'reviewed_legacy_tombstone',true);
end
$function$;

revoke all on function public.reconcile_deleted_trip_activity_v1(
    uuid,uuid,uuid,text,text,jsonb
) from public, anon;
grant execute on function public.reconcile_deleted_trip_activity_v1(
    uuid,uuid,uuid,text,text,jsonb
) to authenticated;

-- 259: Server-authoritative completion of operational Spray records.
-- Narrow, online/server-confirmed completion of an existing operational Spray.
-- Prerequisites: 007 (sync), 232 (manual provenance/guard). No schema/backfill.
-- Tests: sql/tests/259_complete_spray_record_tests.sql (isolated DB only).
-- Does not replace any Trip function, trigger, policy or manual-spray contract.
begin;

create function public.complete_spray_record(
  p_spray_record_id uuid,
  p_allow_unlinked boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_actor uuid := auth.uid();
  v_spray public.spray_records%rowtype;
  v_trip public.trips%rowtype;
  v_end_time timestamptz;
  v_source text;
begin
  if v_actor is null then
    raise exception 'AUTH_REQUIRED' using errcode = '42501',
      detail = 'Authentication required.';
  end if;

  -- Lock order is always Spray, then its current linked Trip (if present).
  -- Do not filter away deleted rows: distinguish unavailable canonical states.
  select r.* into v_spray
  from public.spray_records r where r.id = p_spray_record_id for update;
  if not found then
    raise exception 'SPRAY_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- Role check precedes state disclosure, including an idempotent result.
  if not public.has_vineyard_role(
    v_spray.vineyard_id, array['owner', 'manager', 'supervisor', 'operator']
  ) then
    raise exception 'SPRAY_EDIT_FORBIDDEN' using errcode = '42501';
  end if;
  if v_spray.deleted_at is not null then
    raise exception 'SPRAY_DELETED' using errcode = '55000';
  end if;
  if v_spray.is_template is distinct from false then
    raise exception 'SPRAY_TEMPLATE' using errcode = '55000',
      detail = 'Program Steps cannot be completed as operational sprays.';
  end if;
  if v_spray.entry_source = 'manual' or v_spray.manual_entry_id is not null then
    raise exception 'MANUAL_SPRAY_WORKFLOW_REQUIRED' using errcode = '42501',
      detail = 'Manual spray records must be managed through the manual spray workflow.';
  end if;

  if v_spray.trip_id is not null then
    select t.* into v_trip
    from public.trips t where t.id = v_spray.trip_id for update;
  end if;

  -- Explicit completion wins. No UPDATE, audit bump or trigger on a retry.
  -- An already-completed valid Spray remains idempotent even if its historical
  -- Trip is later unavailable/active; no new completion is being authorised.
  if v_spray.end_time is not null then
    v_source := 'existing';
  else
    if v_spray.trip_id is not null then
      if v_trip.id is null or v_trip.deleted_at is not null then
        raise exception 'LINKED_TRIP_UNAVAILABLE' using errcode = '55000';
      end if;
      if v_trip.vineyard_id is distinct from v_spray.vineyard_id then
        raise exception 'LINKED_TRIP_VINEYARD_MISMATCH' using errcode = '55000';
      end if;
      if v_trip.is_active is true then
        raise exception 'ACTIVE_TRIP' using errcode = '55000',
          detail = 'This spray still has an active Trip. End the Trip to complete the spray.';
      end if;
      if v_trip.is_active is distinct from false or v_trip.end_time is null then
        raise exception 'LINKED_TRIP_NOT_ENDED' using errcode = '55000';
      end if;
      -- Reject contradictory ended states, without repairing historical data.
      -- A missing historical start is not itself grounds to invent a start.
      if v_trip.entry_source = 'manual' or v_trip.manual_entry_id is not null
         or not isfinite(v_trip.end_time)
         or (v_trip.start_time is not null and v_trip.end_time < v_trip.start_time) then
        raise exception 'LINKED_TRIP_INCONSISTENT' using errcode = '55000';
      end if;
      v_end_time := v_trip.end_time;
      v_source := 'trip_end';
    else
      -- NULL is not affirmative confirmation. A broken trip_id never reaches here.
      if p_allow_unlinked is distinct from true then
        raise exception 'UNLINKED_CONFIRMATION_REQUIRED' using errcode = '55000',
          detail = 'No linked Trip is available. Confirm marking this spray complete now.';
      end if;
      v_end_time := now();
      v_source := 'server_now';
    end if;

    -- Same explicit audit/version convention as the existing Spray RPCs (232).
    -- updated_at is owned by spray_records_set_updated_at (007 / set_updated_at).
    -- Keep all provenance, planning/application fields and Trips untouched.
    update public.spray_records r
    set end_time = v_end_time,
        updated_by = v_actor,
        client_updated_at = now(),
        sync_version = r.sync_version + 1
    where r.id = v_spray.id
    returning r.* into v_spray;
    if not found or v_spray.end_time is distinct from v_end_time then
      raise exception 'SPRAY_COMPLETION_NOT_APPLIED' using errcode = '55000';
    end if;
  end if;

  return jsonb_build_object(
    'sprayRecordId', v_spray.id,
    'endTime', v_spray.end_time,
    'completionSource', v_source,
    'serverConfirmed', true,
    'updatedAt', v_spray.updated_at,
    'updatedBy', v_spray.updated_by,
    'clientUpdatedAt', v_spray.client_updated_at,
    'syncVersion', v_spray.sync_version
  );
end;
$function$;

-- Clear explicit defaults too (254 documents inherited per-function grants).
-- No service-role grant or anonymous/public execution; the owner retains control.
revoke all on function public.complete_spray_record(uuid, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.complete_spray_record(uuid, boolean) to authenticated;

comment on function public.complete_spray_record(uuid, boolean) is
  'Server-confirmed End Spray only. Locks Spray then linked Trip; excludes templates/manual/deleted records; preserves existing completion; never modifies Trips. Unlinked completion requires explicit confirmation.';

commit;

-- READ-ONLY: server state of the 8 Trips still queued on the iPhone (7 uploads + held delete 2be68a70, plus 6f6754a0 handoff).
-- Paste into the Supabase SQL editor (production), run once, copy the result cell back. Never raises, never writes.
-- Per Trip look at: trip.found, trip.deleted_at, trip.is_active/end_time, tank_actual_count, spray_completed_count.
-- BEGIN READBACK FUNCTION
create or replace function pg_temp.vinetrack_trip_readback(p_trip uuid)
returns jsonb
language plpgsql
as $readback$
declare
  trip_part jsonb;
  operations_part jsonb;
  actuals_part jsonb;
  spray_part jsonb;
begin
  -- Every section is guarded on its own: a missing table or column is reported, never raised.
  begin
    execute $q$
      select jsonb_build_object(
        'found', true,
        'vineyard_id', t.vineyard_id,
        'is_active', t.is_active,
        'end_time', t.end_time,
        'deleted_at', t.deleted_at,
        'sync_version', t.sync_version,
        'updated_at', t.updated_at,
        'tank_session_ids', coalesce((
            select jsonb_agg(s ->> 'id' order by s ->> 'id')
            from jsonb_array_elements(case when jsonb_typeof(t.tank_sessions) = 'array'
                                           then t.tank_sessions else '[]'::jsonb end) s), '[]'::jsonb),
        'occurrence_revision', t.occurrence_coverage ->> 'revision',
        'occurrence_status_counts', coalesce((
            select jsonb_object_agg(x.k, x.c) from (
              select coalesce(e.v ->> 'status', 'unknown') as k, count(*) as c
              from jsonb_each(case when jsonb_typeof(t.occurrence_coverage -> 'states') = 'object'
                                   then t.occurrence_coverage -> 'states' else '{}'::jsonb end) as e(id, v)
              group by 1) x), '{}'::jsonb),
        'occurrence_linked_tank_session_ids', coalesce((
            select jsonb_agg(l.link order by l.link)
            from jsonb_each(case when jsonb_typeof(t.occurrence_coverage -> 'states') = 'object'
                                 then t.occurrence_coverage -> 'states' else '{}'::jsonb end) as e(id, v),
                 jsonb_array_elements_text(case when jsonb_typeof(e.v -> 'tankSessionIds') = 'array'
                                                then e.v -> 'tankSessionIds' else '[]'::jsonb end) as l(link)), '[]'::jsonb))
      from public.trips t
      where t.id = $1
    $q$ into trip_part using p_trip;
    trip_part := coalesce(trip_part, jsonb_build_object('found', false));
  exception when others then
    trip_part := jsonb_build_object('readback_error', sqlerrm, 'sqlstate', sqlstate);
  end;

  begin
    execute $q$
      select jsonb_build_object(
        'count', count(*),
        'accepted', coalesce(jsonb_agg(jsonb_build_object(
            'operation_id', o.operation_id,
            'kind', coalesce(o.request ->> 'kind', o.request #>> '{action,kind}'),
            'occurrence_id', o.occurrence_id,
            'accepted_at', o.accepted_at,
            'to_status', o.request #>> '{action,toStatus}',
            'resulting_status', o.resulting_state ->> 'status',
            'linked_tank_session_ids', o.resulting_state -> 'tankSessionIds',
            'requested_end_time', o.request #>> '{end,endTime}',
            'result_end_time', o.result ->> 'endTime',
            'result_is_active', o.result ->> 'isActive') order by o.accepted_at, o.operation_id), '[]'::jsonb))
      from public.trip_occurrence_operations o
      where o.trip_id = $1
    $q$ into operations_part using p_trip;
  exception when others then
    operations_part := jsonb_build_object('readback_error', sqlerrm, 'sqlstate', sqlstate);
  end;

  begin
    execute $q$
      select jsonb_build_object(
        'count', count(*),
        'rows', coalesce(jsonb_agg(jsonb_build_object(
            'id', a.id,
            'spray_record_id', a.spray_record_id,
            'tank_session_id', a.tank_session_id,
            'tank_number', a.tank_number,
            'water_volume_l', a.water_volume_l,
            'confirmed_at', a.confirmed_at,
            'sync_version', a.sync_version) order by a.tank_number, a.id), '[]'::jsonb))
      from public.spray_tank_actuals a
      where a.trip_id = $1 and a.deleted_at is null
    $q$ into actuals_part using p_trip;
  exception when others then
    actuals_part := jsonb_build_object('readback_error', sqlerrm, 'sqlstate', sqlstate);
  end;

  begin
    execute $q$
      select jsonb_build_object(
        'count', count(*),
        'completed_count', count(*) filter (where r.end_time is not null and r.deleted_at is null),
        'rows', coalesce(jsonb_agg(jsonb_build_object(
            'id', r.id,
            'completed', r.end_time is not null,
            'end_time', r.end_time,
            'deleted_at', r.deleted_at,
            'sync_version', r.sync_version) order by r.created_at, r.id), '[]'::jsonb))
      from public.spray_records r
      where r.trip_id = $1 and not r.is_template
    $q$ into spray_part using p_trip;
  exception when others then
    spray_part := jsonb_build_object('readback_error', sqlerrm, 'sqlstate', sqlstate);
  end;

  return jsonb_build_object(
    'trip_id', p_trip,
    'trip', trip_part,
    'occurrence_operations', operations_part,
    'tank_actuals', actuals_part,
    'spray_records', spray_part,
    'summary', jsonb_build_object(
      'trip_ended_on_server', coalesce(
        (trip_part ->> 'is_active') = 'false' and (trip_part ->> 'end_time') is not null and (trip_part ->> 'deleted_at') is null, false),
      'tank_session_count', coalesce(jsonb_array_length(trip_part -> 'tank_session_ids'), 0),
      'tank_actual_count', coalesce((actuals_part ->> 'count')::int, -1),
      'spray_completed_count', coalesce((spray_part ->> 'completed_count')::int, -1)));
exception when others then
  return jsonb_build_object('trip_id', p_trip, 'readback_error', sqlerrm, 'sqlstate', sqlstate);
end;
$readback$;
-- END READBACK FUNCTION

select jsonb_pretty(jsonb_agg(jsonb_build_object('trip', x.id, 'readback', pg_temp.vinetrack_trip_readback(x.id)) order by x.id)) as legacy_queue_readback
from (values ('0a5466df-f0c1-4289-b2e2-a832ddb29ae5'::uuid),('2be68a70-9582-4981-8a87-e727f113cdf6'),('6f6754a0-bad1-4e3c-900f-c51580096dec'),('78bfc262-2620-4833-9d86-a3c5c6f5fb47'),('a3c31b89-4302-44fc-b860-b4d31289c8a4'),('bb19e4c0-e3de-43e0-81a3-d48b63b3e868'),('dead3350-4cf6-4080-8c56-2d3101cfc424'),('f2cbf5b2-9ed3-4ac8-bc9d-73b885cbcc52')) as x(id);

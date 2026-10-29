-- Run via an administrator psql connection, NOT an anonymous public client.
-- psql -v actor_uuid=<existing-owner-uuid> -v vineyard_uuid=<owned-vineyard-uuid> -f scripts/verify-sync-compatibility.sql
-- All synthetic field records and receipt writes are ROLLED BACK.
-- Never substitute a customer Trip ID or reuse a customer operation ID.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('vt.test_actor', :'actor_uuid', true),
       set_config('vt.test_vineyard', :'vineyard_uuid', true),
       set_config('request.jwt.claims', '{}', true);
DO $negative$
DECLARE r record; msg text; phase integer; expected text;
BEGIN
 FOR phase IN 0..1 LOOP
  PERFORM set_config('request.jwt.claim.sub',CASE WHEN phase=0 THEN '' ELSE current_setting('vt.test_actor') END,true);
  expected:=CASE WHEN phase=0 THEN 'OCCURRENCE_AUTH_REQUIRED' ELSE 'OCCURRENCE_INVALID_REQUEST' END;
  FOR r IN SELECT p.proname, 'SELECT public.'||quote_ident(p.proname)||'('||
    (SELECT string_agg('NULL::'||format_type(typ,null),',' ORDER BY ord)
     FROM unnest(p.proargtypes::oid[]) WITH ORDINALITY a(typ,ord))||')' AS statement
   FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
   WHERE ns.nspname='public' AND p.proname=ANY(ARRAY[
    'create_trip_with_occurrences_v1','activate_trip_occurrences_v1',
    'apply_trip_occurrence_action_v1','finalize_trip_occurrences_v1',
    'get_trip_occurrence_recovery_v1'])
  LOOP
   BEGIN EXECUTE r.statement; RAISE EXCEPTION 'Unexpected success';
   EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;
    IF msg<>expected THEN RAISE EXCEPTION 'Phase % RPC %: % (expected %)',phase,r.proname,msg,expected; END IF;
   END;
  END LOOP;
 END LOOP;
END $negative$;
DO $legacy$
DECLARE vid uuid:=current_setting('vt.test_vineyard')::uuid; tid uuid:=gen_random_uuid(); n integer; msg text;
BEGIN
 IF NOT public.has_vineyard_role(vid,ARRAY['owner','manager']) THEN RAISE EXCEPTION 'Test actor must manage selected vineyard'; END IF;
 INSERT INTO public.trips(id,vineyard_id,start_time,is_active,is_paused,trip_title,trip_function,person_name,created_by,row_sequence,path_points,completed_paths,skipped_paths,paddock_ids,pin_ids,tank_sessions,pause_timestamps,resume_timestamps)
 VALUES(tid,vid,now(),false,false,'ROLLBACK legacy contract probe','General','Sync validation',auth.uid(),'[]','[]','[]','[]','[]','[]','[]','[]','[]');
 UPDATE public.trips SET trip_title='ROLLBACK legacy metadata update' WHERE id=tid;
 SELECT count(*) INTO n FROM public.trips WHERE id=tid AND trip_title='ROLLBACK legacy metadata update' AND occurrence_coverage IS NULL;
 IF n<>1 THEN RAISE EXCEPTION 'Legacy insert/update/read failed'; END IF;
 BEGIN
  UPDATE public.trips SET occurrence_coverage='{"schemaVersion":1}'::jsonb WHERE id=tid;
  RAISE EXCEPTION 'Unexpected direct occurrence write accepted';
 EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;
  IF msg NOT LIKE 'OCCURRENCE_%' THEN RAISE EXCEPTION 'Unexpected occurrence guard: %',msg; END IF;
 END;
END $legacy$;
DO $occurrence$
DECLARE v uuid:=current_setting('vt.test_vineyard')::uuid; b record;
 tid uuid:=gen_random_uuid(); occurrence_id uuid:=gen_random_uuid(); op uuid:=gen_random_uuid(); activation uuid:=gen_random_uuid();
 d jsonb; setup jsonb; ack jsonb; replay jsonb; recovered jsonb; started timestamptz:=clock_timestamp(); msg text;
BEGIN
 SELECT id,name INTO STRICT b FROM public.paddocks WHERE vineyard_id=v AND deleted_at IS NULL ORDER BY id LIMIT 1;
 d:=jsonb_build_object('contract','vinetrack.planned-occurrence','schemaVersion',1,
 'planId',gen_random_uuid(),'revision',0,'planRevision',1,'selectedOccurrenceId',NULL,'plannedCursorId',occurrence_id,
 'items',jsonb_build_array(jsonb_build_object('occurrenceId',occurrence_id,'blockId',b.id,
 'blockNameSnapshot',b.name,'pathNumber',1,'passOrdinal',1,
 'physicalPathRef',jsonb_build_object('pathId',gen_random_uuid(),'rowIds','[]'::jsonb,'rowSnapshots','[]'::jsonb,'geometryRevision','unresolved'))),
 'activeOrder',jsonb_build_array(occurrence_id),'retired','[]'::jsonb,
 'states',jsonb_build_object(occurrence_id::text,jsonb_build_object('status','incomplete','source',NULL,'lastOperationId',NULL,'tankSessionIds','[]'::jsonb)));
 setup:=jsonb_build_object('id',tid,'vineyard_id',v,'paddock_id',b.id,'paddock_ids',jsonb_build_array(b.id),
 'paddock_name',b.name,'trip_title','ROLLBACK occurrence contract probe','trip_function','General',
 'tracking_pattern','One After Another','start_time',started,'is_active',false,'is_paused',false,'person_name','Sync validation');
 ack:=public.create_trip_with_occurrences_v1(op,setup,d);
 IF ack->>'tripId'<>tid::text THEN RAISE EXCEPTION 'Create returned wrong Trip identity'; END IF;
 replay:=public.create_trip_with_occurrences_v1(op,setup,d);
 IF replay IS DISTINCT FROM ack THEN RAISE EXCEPTION 'Exact replay was not idempotent'; END IF;
 recovered:=public.get_trip_occurrence_recovery_v1(tid,ARRAY[op]);
 IF jsonb_array_length(recovered->'receipts')<>1 THEN RAISE EXCEPTION 'Create receipt missing'; END IF;
 ack:=public.activate_trip_occurrences_v1(activation,tid,0,1,jsonb_build_object('startTime',started));
 IF ack->'isActive'<>'true'::jsonb OR ack#>>'{coverage,revision}'<>'1' THEN RAISE EXCEPTION 'Activation not acknowledged'; END IF;
 recovered:=public.get_trip_occurrence_recovery_v1(tid,ARRAY[op,activation]);
 IF jsonb_array_length(recovered->'receipts')<>2 THEN RAISE EXCEPTION 'Activation receipt missing'; END IF;
 BEGIN
  PERFORM public.get_trip_occurrence_recovery_v1(gen_random_uuid()); RAISE EXCEPTION 'Unexpected missing-trip access';
 EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS msg=MESSAGE_TEXT;
  IF msg<>'OCCURRENCE_TRIP_FORBIDDEN' THEN RAISE EXCEPTION 'Missing-trip guard: %',msg; END IF;
 END;
END $occurrence$;
ROLLBACK;
SELECT 'PASS: rollback-only database compatibility probes' AS result;
-- Does NOT certify installed 3.1.8/3.1.9 binaries, offline migration, chemical
-- approvals, Ktor retry integration, or physical-device Trip activation.

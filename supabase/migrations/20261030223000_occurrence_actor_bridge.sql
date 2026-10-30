-- Applied as occurrence_actor_identity_compatibility_v1; verified against live RPCs.
-- No data rows or public RPC signatures change. auth schema remains protected.
-- Identity semantics exactly match auth.uid() (already-verified PostgREST claims).
-- Helper is SECURITY INVOKER: no added privileged lookup and no auth-table access.
CREATE OR REPLACE FUNCTION public.trip_occurrence_actor_uid_v1()
RETURNS uuid LANGUAGE sql STABLE SECURITY INVOKER SET search_path=''
AS $actor$
 SELECT coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
   nullif(current_setting('request.jwt.claims',true),'')::jsonb ->> 'sub')::uuid;
$actor$;
REVOKE ALL ON FUNCTION public.trip_occurrence_actor_uid_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.trip_occurrence_actor_uid_v1() TO vinetrack_occurrence_writer;
DO $repair$
DECLARE n integer; r record; before_sql text; after_sql text; predicate text;
 original_membership jsonb; original_create boolean; original_set boolean;
BEGIN
 IF current_user<>'postgres' OR session_user<>'postgres' THEN RAISE EXCEPTION 'Run as project postgres administrator'; END IF;
 SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
 WHERE ns.nspname='public' AND p.proname=ANY(ARRAY['create_trip_with_occurrences_v1','activate_trip_occurrences_v1','apply_trip_occurrence_action_v1','finalize_trip_occurrences_v1','get_trip_occurrence_recovery_v1'])
 AND p.prosecdef AND pg_get_userbyid(p.proowner)='vinetrack_occurrence_writer';
 IF n<>5 THEN RAISE EXCEPTION 'Expected exactly five restricted RPCs'; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='vinetrack_occurrence_writer' AND (rolcanlogin OR rolsuper OR rolbypassrls)) THEN RAISE EXCEPTION 'Unexpected writer privileges'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.grantor),'[]') INTO original_membership FROM pg_auth_members m WHERE m.roleid='vinetrack_occurrence_writer'::regrole AND m.member='postgres'::regrole;
 original_create:=has_schema_privilege('vinetrack_occurrence_writer','public','CREATE');
 original_set:=pg_has_role('postgres','vinetrack_occurrence_writer','SET');
 -- Membership already has ADMIN, but not SET/INHERIT. Restore it exactly below.
 IF NOT original_set THEN EXECUTE 'GRANT vinetrack_occurrence_writer TO postgres WITH SET TRUE, INHERIT FALSE GRANTED BY postgres'; END IF;
 IF NOT original_create THEN EXECUTE 'GRANT CREATE ON SCHEMA public TO vinetrack_occurrence_writer'; END IF;
 FOR r IN SELECT p.oid FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
 WHERE ns.nspname='public' AND p.proname=ANY(ARRAY['create_trip_with_occurrences_v1','activate_trip_occurrences_v1','apply_trip_occurrence_action_v1','finalize_trip_occurrences_v1','get_trip_occurrence_recovery_v1']) ORDER BY p.proname LOOP
  before_sql:=pg_get_functiondef(r.oid);
  after_sql:=replace(before_sql,'auth.uid()','public.trip_occurrence_actor_uid_v1()');
  IF before_sql=after_sql AND position('trip_occurrence_actor_uid_v1()' in before_sql)=0 THEN RAISE EXCEPTION 'Unexpected RPC identity implementation'; END IF;
  IF before_sql<>after_sql THEN
   PERFORM set_config('role','vinetrack_occurrence_writer',true);
   EXECUTE after_sql;
   PERFORM set_config('role','postgres',true);
  END IF;
 END LOOP;
 SELECT pg_get_expr(polwithcheck,polrelid) INTO predicate FROM pg_policy
 WHERE polrelid='public.trip_occurrence_operations'::regclass AND polname='trip_occurrence_operations_rpc_insert';
 IF predicate IS NULL OR (position('auth.uid()' in predicate)=0 AND position('trip_occurrence_actor_uid_v1()' in predicate)=0) THEN RAISE EXCEPTION 'Unexpected receipt actor check'; END IF;
 EXECUTE format('ALTER POLICY trip_occurrence_operations_rpc_insert ON public.trip_occurrence_operations WITH CHECK (%s)',replace(predicate,'auth.uid()','public.trip_occurrence_actor_uid_v1()'));
 IF NOT original_create THEN EXECUTE 'REVOKE CREATE ON SCHEMA public FROM vinetrack_occurrence_writer'; END IF;
 IF NOT original_set THEN EXECUTE 'REVOKE vinetrack_occurrence_writer FROM postgres GRANTED BY postgres'; END IF;
 IF original_create<>has_schema_privilege('vinetrack_occurrence_writer','public','CREATE') OR original_set<>pg_has_role('postgres','vinetrack_occurrence_writer','SET') THEN RAISE EXCEPTION 'Temporary deployment privileges not restored'; END IF;
 IF original_membership IS DISTINCT FROM (SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.grantor),'[]') FROM pg_auth_members m WHERE m.roleid='vinetrack_occurrence_writer'::regrole AND m.member='postgres'::regrole) THEN RAISE EXCEPTION 'Role membership changed unexpectedly'; END IF;
 IF has_function_privilege('authenticated','public.trip_occurrence_actor_uid_v1()','EXECUTE') OR has_function_privilege('anon','public.trip_occurrence_actor_uid_v1()','EXECUTE') THEN RAISE EXCEPTION 'Internal identity function exposed'; END IF;
 IF EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
 WHERE ns.nspname='public' AND p.proname=ANY(ARRAY['create_trip_with_occurrences_v1','activate_trip_occurrences_v1','apply_trip_occurrence_action_v1','finalize_trip_occurrences_v1','get_trip_occurrence_recovery_v1'])
 AND (NOT p.prosecdef OR pg_get_userbyid(p.proowner)<>'vinetrack_occurrence_writer' OR position('auth.uid()' in pg_get_functiondef(p.oid))>0)) THEN RAISE EXCEPTION 'RPC security postcondition failed'; END IF;
END $repair$;
NOTIFY pgrst,'reload schema';

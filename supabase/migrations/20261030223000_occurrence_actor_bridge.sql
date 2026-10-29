-- Compatibility repair for both existing and new occurrence-enabled clients.
-- A project administrator cannot grant USAGE on Supabase's managed auth schema.
-- Keep the restricted occurrence writer; bridge only auth.uid(), not auth tables.
-- Apply transactionally. No customer rows, RPC signatures, or JSON fields change.

DO $preflight$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
  WHERE ns.nspname='public' AND p.proname=ANY(ARRAY[
    'create_trip_with_occurrences_v1','activate_trip_occurrences_v1',
    'apply_trip_occurrence_action_v1','finalize_trip_occurrences_v1',
    'get_trip_occurrence_recovery_v1'])
    AND p.prosecdef AND pg_get_userbyid(p.proowner)='vinetrack_occurrence_writer';
  IF n<>5 THEN RAISE EXCEPTION 'Expected exactly five restricted occurrence RPCs; found %',n; END IF;
  IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='vinetrack_occurrence_writer' AND (rolcanlogin OR rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION 'Unexpected occurrence writer privilege configuration';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public'
    AND tablename='trip_occurrence_operations' AND policyname='trip_occurrence_operations_rpc_insert'
    AND cmd='INSERT' AND roles=ARRAY['vinetrack_occurrence_writer']::name[]) THEN
    RAISE EXCEPTION 'Expected restricted receipt-insert policy not found';
  END IF;
END $preflight$;

CREATE OR REPLACE FUNCTION public.trip_occurrence_actor_uid_v1()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=''
AS $actor$ SELECT auth.uid(); $actor$;
ALTER FUNCTION public.trip_occurrence_actor_uid_v1() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.trip_occurrence_actor_uid_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.trip_occurrence_actor_uid_v1() TO vinetrack_occurrence_writer;
COMMENT ON FUNCTION public.trip_occurrence_actor_uid_v1() IS
 'Internal identity-only bridge for restricted occurrence RPCs. Returns auth.uid() unchanged; does not accept an actor argument or read auth tables.';

DO $repair$
DECLARE r record; before_sql text; after_sql text; predicate text;
BEGIN
  FOR r IN SELECT p.oid FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
    WHERE ns.nspname='public' AND p.proname=ANY(ARRAY[
      'create_trip_with_occurrences_v1','activate_trip_occurrences_v1',
      'apply_trip_occurrence_action_v1','finalize_trip_occurrences_v1',
      'get_trip_occurrence_recovery_v1']) ORDER BY p.proname
  LOOP
    before_sql:=pg_get_functiondef(r.oid);
    after_sql:=replace(before_sql,'auth.uid()','public.trip_occurrence_actor_uid_v1()');
    IF after_sql=before_sql AND position('trip_occurrence_actor_uid_v1()' in before_sql)=0 THEN
      RAISE EXCEPTION 'Occurrence RPC has no recognised identity check';
    END IF;
    IF after_sql<>before_sql THEN EXECUTE after_sql; END IF;
  END LOOP;
  SELECT pg_get_expr(polwithcheck,polrelid) INTO predicate FROM pg_policy
    WHERE polrelid='public.trip_occurrence_operations'::regclass
    AND polname='trip_occurrence_operations_rpc_insert';
  IF predicate IS NULL OR (position('auth.uid()' in predicate)=0 AND position('trip_occurrence_actor_uid_v1()' in predicate)=0) THEN
    RAISE EXCEPTION 'Receipt policy does not contain expected actor check';
  END IF;
  EXECUTE format('ALTER POLICY trip_occurrence_operations_rpc_insert ON public.trip_occurrence_operations WITH CHECK (%s)',
    replace(predicate,'auth.uid()','public.trip_occurrence_actor_uid_v1()'));
END $repair$;

DO $verify$
BEGIN
  IF NOT has_function_privilege('vinetrack_occurrence_writer','public.trip_occurrence_actor_uid_v1()','EXECUTE')
    OR has_function_privilege('anon','public.trip_occurrence_actor_uid_v1()','EXECUTE')
    OR has_function_privilege('authenticated','public.trip_occurrence_actor_uid_v1()','EXECUTE') THEN
    RAISE EXCEPTION 'Identity bridge execute privileges failed verification';
  END IF;
  IF EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
    WHERE ns.nspname='public' AND p.proname=ANY(ARRAY[
      'create_trip_with_occurrences_v1','activate_trip_occurrences_v1',
      'apply_trip_occurrence_action_v1','finalize_trip_occurrences_v1',
      'get_trip_occurrence_recovery_v1'])
    AND (NOT p.prosecdef OR pg_get_userbyid(p.proowner)<>'vinetrack_occurrence_writer'
      OR position('auth.uid()' in pg_get_functiondef(p.oid))>0)) THEN
    RAISE EXCEPTION 'Occurrence RPC identity or ownership postcondition failed';
  END IF;
END $verify$;
NOTIFY pgrst,'reload schema';

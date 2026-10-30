-- An empty RLS-filtered client SELECT is not authoritative absence.
-- This helper confirms physical absence without creating/deleting any record.
-- Existing soft_delete_trip and every 3.1.8 route remain unchanged.
CREATE SCHEMA IF NOT EXISTS vinetrack_sync_internal AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA vinetrack_sync_internal FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA vinetrack_sync_internal TO authenticated;

CREATE OR REPLACE FUNCTION vinetrack_sync_internal.confirm_trip_absence_v1(p_trip_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_vineyard uuid;
  v_present boolean;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'TRIP_DELETE_AUTH_REQUIRED';
  END IF;
  IF p_trip_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'TRIP_DELETE_ID_REQUIRED';
  END IF;
  SELECT t.vineyard_id INTO v_vineyard FROM public.trips t WHERE t.id = p_trip_id;
  v_present := FOUND;
  -- Soft-deleted rows still count as present. A hidden row is never absence.
  IF v_present AND NOT coalesce(public.is_vineyard_member(v_vineyard), false) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'TRIP_DELETE_SCOPE_UNRESOLVED';
  END IF;
  RETURN jsonb_build_object('schema_version',1,'trip_id',p_trip_id,
    'actor_id',v_actor,'absent',NOT v_present);
END;
$function$;
ALTER FUNCTION vinetrack_sync_internal.confirm_trip_absence_v1(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION vinetrack_sync_internal.confirm_trip_absence_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION vinetrack_sync_internal.confirm_trip_absence_v1(uuid) TO authenticated;

-- Only this invoker wrapper is exposed by PostgREST; privileged logic is private.
CREATE OR REPLACE FUNCTION public.confirm_trip_absence_v1(p_trip_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $function$
  SELECT vinetrack_sync_internal.confirm_trip_absence_v1(p_trip_id);
$function$;
ALTER FUNCTION public.confirm_trip_absence_v1(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.confirm_trip_absence_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_trip_absence_v1(uuid) TO authenticated;
COMMENT ON FUNCTION public.confirm_trip_absence_v1(uuid) IS
'Read-only, actor-bound confirmation of physical absence for a queued Trip delete. Never equates RLS invisibility with absence. Does not delete, recreate or approve anything.';
NOTIFY pgrst, 'reload schema';

-- Fix: hard-deleting a Yield Estimate trip (e.g. a Panel Count recorded
-- observation) failed with "permission denied for table season_yield_estimates".
--
-- hard_delete_yield_estimation_session is SECURITY INVOKER (deletion must
-- satisfy RLS) but it also UPDATEs season_yield_estimates, on which
-- `authenticated` has SELECT only. Postgres checks that privilege even when no
-- row matches, so every hard delete failed.
--
-- The detach step moves into a narrow SECURITY DEFINER helper. It only acts on
-- a session that is already gone and has a deletion receipt, so calling it
-- directly can never detach an estimate from a live trip.

CREATE OR REPLACE FUNCTION public.detach_season_estimate_from_deleted_session(
    p_session_id uuid, p_vineyard_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
    IF auth.uid() IS NULL
       OR NOT public.has_vineyard_role(p_vineyard_id, ARRAY['owner','manager','supervisor','operator']) THEN
        RAISE EXCEPTION 'Signed-in vineyard membership is required' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM public.yield_estimation_sessions s
               WHERE s.id = p_session_id)
       OR NOT EXISTS (SELECT 1 FROM public.yield_estimation_session_deletion_receipts r
                      WHERE r.session_id = p_session_id AND r.vineyard_id = p_vineyard_id) THEN
        RAISE EXCEPTION 'Only a hard-deleted yield observation can be detached' USING ERRCODE = '42501';
    END IF;

    -- A currently selected canonical projection must not silently continue
    -- referencing the permanently deleted source.
    UPDATE public.season_yield_estimates
       SET source_session_id = NULL,
           base_estimate_tonnes = NULL,
           is_estimate_available = false,
           setup_warnings = coalesce(setup_warnings,'[]'::jsonb) ||
               '["Source Yield Estimate Trip was hard-deleted; select or recalculate a current source"]'::jsonb,
           updated_at = now(),
           calculated_at = now()
     WHERE vineyard_id = p_vineyard_id AND source_session_id = p_session_id
       AND estimate_source = 'bunch_count';
END $function$;

REVOKE ALL ON FUNCTION public.detach_season_estimate_from_deleted_session(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.detach_season_estimate_from_deleted_session(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.hard_delete_yield_estimation_session(
    p_id uuid, p_vineyard_id uuid, p_expected_completed boolean
) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
    v_row public.yield_estimation_sessions%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL
       OR NOT public.has_vineyard_role(p_vineyard_id, ARRAY['owner','manager','supervisor','operator']) THEN
        RAISE EXCEPTION 'Signed-in vineyard membership is required to delete a yield observation'
            USING ERRCODE = '42501';
    END IF;
    SELECT * INTO v_row
    FROM public.yield_estimation_sessions
    WHERE id = p_id AND vineyard_id = p_vineyard_id
    FOR UPDATE;
    IF NOT FOUND THEN
        -- Repeated deletes of the same already removed observation are
        -- idempotent but cannot claim success for an unknown record.
        RETURN EXISTS (
            SELECT 1 FROM public.yield_estimation_session_deletion_receipts
            WHERE session_id = p_id AND vineyard_id = p_vineyard_id
        );
    END IF;
    IF v_row.is_completed IS DISTINCT FROM p_expected_completed
       OR coalesce((v_row.payload->>'isCompleted')::boolean,false)
             IS DISTINCT FROM p_expected_completed THEN
        RAISE EXCEPTION 'The observation completion status has changed; reload before deleting'
            USING ERRCODE = '23514';
    END IF;
    IF v_row.is_completed
       AND NOT public.has_vineyard_role(p_vineyard_id, ARRAY['owner','manager','supervisor']) THEN
        RAISE EXCEPTION 'Only Supervisors, Managers and Owners can hard-delete confirmed yield observations'
            USING ERRCODE = '42501';
    END IF;

    DELETE FROM public.yield_estimation_sessions
      WHERE id = p_id AND vineyard_id = p_vineyard_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Yield observation was not deleted' USING ERRCODE = '42501'; END IF;

    -- Same transaction: if detaching fails, the delete rolls back too.
    PERFORM public.detach_season_estimate_from_deleted_session(p_id, p_vineyard_id);
    RETURN true;
END $function$;

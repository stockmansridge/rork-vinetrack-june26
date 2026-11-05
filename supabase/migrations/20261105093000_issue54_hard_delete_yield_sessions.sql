-- Issue #54. Hard-delete yield count sessions, never Trip/Spray/Tank records.
-- Draft: every operator/supervisor/manager/owner in that vineyard.
-- Confirmed: only supervisor/manager/owner.
-- Receipts are intentionally metadata-only, to prevent older devices from
-- re-uploading a deleted observation and to let other devices remove it.

CREATE TABLE public.yield_estimation_session_deletion_receipts (
    session_id uuid PRIMARY KEY,
    vineyard_id uuid NOT NULL REFERENCES public.vineyards(id) ON DELETE CASCADE,
    was_completed boolean NOT NULL,
    deleted_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.yield_estimation_session_deletion_receipts ENABLE ROW LEVEL SECURITY;
CREATE POLICY yield_session_delete_receipts_members
    ON public.yield_estimation_session_deletion_receipts FOR SELECT TO authenticated
    USING (public.is_vineyard_member(vineyard_id));
REVOKE ALL ON public.yield_estimation_session_deletion_receipts FROM anon, authenticated;
GRANT SELECT ON public.yield_estimation_session_deletion_receipts TO authenticated;

CREATE SCHEMA IF NOT EXISTS vinetrack_internal;
CREATE FUNCTION vinetrack_internal.yield_session_hard_delete_audit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
BEGIN
    INSERT INTO public.yield_estimation_session_deletion_receipts
       (session_id,vineyard_id,was_completed,deleted_by)
    VALUES
       (OLD.id,OLD.vineyard_id,OLD.is_completed,auth.uid());
    RETURN OLD;
END $$;
CREATE FUNCTION vinetrack_internal.yield_session_prevent_resurrection()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.yield_estimation_session_deletion_receipts
               WHERE session_id = NEW.id) THEN
        RAISE EXCEPTION 'This yield observation was permanently deleted and cannot be restored by an old sync operation'
            USING ERRCODE = '23505';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION vinetrack_internal.yield_session_hard_delete_audit() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION vinetrack_internal.yield_session_prevent_resurrection() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER yield_session_hard_delete_audit
    AFTER DELETE ON public.yield_estimation_sessions
    FOR EACH ROW EXECUTE FUNCTION vinetrack_internal.yield_session_hard_delete_audit();
CREATE TRIGGER yield_session_hard_delete_prevent_replay
    BEFORE INSERT ON public.yield_estimation_sessions
    FOR EACH ROW EXECUTE FUNCTION vinetrack_internal.yield_session_prevent_resurrection();

DROP POLICY IF EXISTS yield_estimation_sessions_no_client_hard_delete
    ON public.yield_estimation_sessions;
CREATE POLICY yield_estimation_sessions_delete_completion_roles
    ON public.yield_estimation_sessions FOR DELETE TO authenticated
    USING (
        public.has_vineyard_role(vineyard_id, ARRAY['owner','manager','supervisor','operator'])
        AND (
            (NOT is_completed AND coalesce((payload->>'isCompleted')::boolean,false) = false)
            OR public.has_vineyard_role(vineyard_id, ARRAY['owner','manager','supervisor'])
        )
    );
GRANT DELETE ON public.yield_estimation_sessions TO authenticated;

-- SECURITY INVOKER: deletion must satisfy RLS. Exact vineyard and completion
-- state are supplied so a stale device cannot delete a newly confirmed record.
CREATE FUNCTION public.hard_delete_yield_estimation_session(
    p_id uuid, p_vineyard_id uuid, p_expected_completed boolean
) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER
SET search_path = public AS $$
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
     WHERE vineyard_id = p_vineyard_id AND source_session_id = p_id
       AND estimate_source = 'bunch_count';

    DELETE FROM public.yield_estimation_sessions
      WHERE id = p_id AND vineyard_id = p_vineyard_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Yield observation was not deleted' USING ERRCODE = '42501'; END IF;
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.hard_delete_yield_estimation_session(uuid,uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.hard_delete_yield_estimation_session(uuid,uuid,boolean) TO authenticated;

COMMENT ON TABLE public.yield_estimation_session_deletion_receipts IS
    'Issue54 metadata-only physical deletion receipts for cross-device sync and stale-save replay suppression.';
COMMENT ON FUNCTION public.hard_delete_yield_estimation_session(uuid,uuid,boolean) IS
    'Issue54 physical yield-session deletion; any vineyard operator before completion, leaders afterward, with RLS and revision receipt.';

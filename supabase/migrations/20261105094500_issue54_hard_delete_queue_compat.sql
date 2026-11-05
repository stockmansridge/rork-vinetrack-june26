-- Issue 54: compatibility path for Android's existing retained DELETE queue.
-- The queue payload predates the role-aware RPC and carries only the session ID.
-- This wrapper re-resolves the authenticated row/status at replay time.
CREATE FUNCTION public.hard_delete_yield_estimation_session_by_id(p_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER
SET search_path = public AS $$
DECLARE
    v_id uuid;
    v_completed boolean;
BEGIN
    SELECT vineyard_id, is_completed INTO v_id, v_completed
    FROM public.yield_estimation_sessions WHERE id=p_id FOR UPDATE;
    IF FOUND THEN
        RETURN public.hard_delete_yield_estimation_session(p_id,v_id,v_completed);
    END IF;
    -- Idempotency for an acknowledged physical deletion. A user without
    -- vineyard access cannot learn or claim the receipt.
    RETURN EXISTS (
        SELECT 1 FROM public.yield_estimation_session_deletion_receipts
        WHERE session_id=p_id
          AND public.has_vineyard_role(vineyard_id,ARRAY['owner','manager','supervisor','operator'])
    );
END $$;
REVOKE ALL ON FUNCTION public.hard_delete_yield_estimation_session_by_id(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.hard_delete_yield_estimation_session_by_id(uuid) TO authenticated;

-- Issue54 follow-up. Source-only until an explicitly approved deployment.
-- Serialize configuration writes per vineyard/block, including direct-table
-- confirmation and deletion. READ COMMITTED is required so checks after waiting
-- see the preceding transaction's receipts rather than a stale snapshot.
CREATE FUNCTION vinetrack_internal.yield_site_scope_lock()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v uuid; b uuid;
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Sampling location writes require READ COMMITTED; retry' USING ERRCODE='40001';
    END IF;
    IF TG_OP='DELETE' THEN v:=OLD.vineyard_id; b:=OLD.paddock_id;
    ELSE v:=NEW.vineyard_id; b:=NEW.paddock_id; END IF;
    -- Direct table writes already hold tuple locks. Never wait here behind
    -- an RPC holding the scope lock and waiting for that tuple: abort/retry
    -- instead of creating an inverted-lock deadlock.
    IF NOT pg_try_advisory_xact_lock(hashtextextended('yield-sites:'||v::text||':'||b::text,0)) THEN
        RAISE EXCEPTION 'Sampling locations changed concurrently; reload and retry' USING ERRCODE='40001';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION vinetrack_internal.yield_site_scope_lock() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER a_issue54_site_scope_lock BEFORE INSERT OR UPDATE OR DELETE
    ON public.yield_sample_sites FOR EACH ROW EXECUTE FUNCTION vinetrack_internal.yield_site_scope_lock();
CREATE TRIGGER a_issue54_set_scope_lock BEFORE INSERT OR UPDATE OR DELETE
    ON public.yield_sample_site_sets FOR EACH ROW EXECUTE FUNCTION vinetrack_internal.yield_site_scope_lock();
CREATE INDEX yield_site_receipt_logical_scope ON public.yield_sample_site_deletion_receipts(vineyard_id,paddock_id,site_id,was_confirmed);
CREATE INDEX yield_site_receipt_draft_scope ON public.yield_sample_site_deletion_receipts(site_set_id,site_id);

CREATE OR REPLACE FUNCTION vinetrack_internal.yield_sample_site_prevent_resurrection()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.yield_sample_site_deletion_receipts r
        WHERE r.deleted_row_id=NEW.id OR
          (r.vineyard_id=NEW.vineyard_id AND r.paddock_id=NEW.paddock_id AND r.site_id=NEW.site_id
           AND (r.was_confirmed OR r.site_set_id=NEW.site_set_id))) THEN
        RAISE EXCEPTION 'This sampling location was permanently deleted; reload locations' USING ERRCODE='23505';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER yield_sample_site_prevent_replay ON public.yield_sample_sites;
CREATE TRIGGER yield_sample_site_prevent_replay BEFORE INSERT OR UPDATE
    ON public.yield_sample_sites FOR EACH ROW EXECUTE FUNCTION vinetrack_internal.yield_sample_site_prevent_resurrection();

-- Covers already copied drafts and direct UPDATE status='confirmed', not just RPC.
CREATE FUNCTION vinetrack_internal.yield_set_deleted_site_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
    IF NEW.status='confirmed' AND EXISTS (
        SELECT 1 FROM public.yield_sample_sites s JOIN public.yield_sample_site_deletion_receipts r
          ON r.vineyard_id=s.vineyard_id AND r.paddock_id=s.paddock_id AND r.site_id=s.site_id
        WHERE s.site_set_id=NEW.id AND (r.was_confirmed OR r.site_set_id=s.site_set_id)
    ) THEN
        RAISE EXCEPTION 'A deleted sampling location cannot be confirmed again; reload draft' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION vinetrack_internal.yield_set_deleted_site_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER b_issue54_set_deleted_site_guard BEFORE UPDATE ON public.yield_sample_site_sets
    FOR EACH ROW EXECUTE FUNCTION vinetrack_internal.yield_set_deleted_site_guard();

CREATE OR REPLACE FUNCTION vinetrack_internal.yield_sample_site_hard_delete_receipt()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE is_confirmed boolean;
BEGIN
    SELECT s.status='confirmed' INTO is_confirmed FROM public.yield_sample_site_sets s WHERE s.id=OLD.site_set_id;
    INSERT INTO public.yield_sample_site_deletion_receipts(
        deleted_row_id,site_set_id,site_id,vineyard_id,paddock_id,was_confirmed,deleted_by)
    VALUES(OLD.id,OLD.site_set_id,OLD.site_id,OLD.vineyard_id,OLD.paddock_id,coalesce(is_confirmed,false),auth.uid());
    -- A leadership deletion also physically removes unconfirmed copies of this
    -- logical location. Independent session payloads and archived revisions stay intact.
    IF is_confirmed THEN
        DELETE FROM public.yield_sample_sites s USING public.yield_sample_site_sets p
        WHERE p.id=s.site_set_id AND p.status='draft' AND s.vineyard_id=OLD.vineyard_id
          AND s.paddock_id=OLD.paddock_id AND s.site_id=OLD.site_id;
    END IF;
    RETURN OLD;
END $$;

-- Native clients provide the exact expected parent state; an old draft screen
-- cannot silently delete a site that has since been confirmed by another device.
CREATE FUNCTION public.hard_delete_yield_sample_site(p_id uuid,p_set_id uuid,p_vineyard_id uuid,p_expected_status text)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE parent public.yield_sample_site_sets%ROWTYPE;
BEGIN
    SELECT * INTO parent FROM public.yield_sample_site_sets WHERE id=p_set_id AND vineyard_id=p_vineyard_id;
    IF NOT FOUND OR NOT public.has_vineyard_role(p_vineyard_id,ARRAY['owner','manager','supervisor','operator']) THEN
        RAISE EXCEPTION 'Vineyard membership required' USING ERRCODE='42501';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('yield-sites:'||p_vineyard_id::text||':'||parent.paddock_id::text,0));
    SELECT * INTO parent FROM public.yield_sample_site_sets WHERE id=p_set_id AND vineyard_id=p_vineyard_id FOR UPDATE;
    IF parent.status IS DISTINCT FROM p_expected_status OR p_expected_status NOT IN ('draft','confirmed') THEN
        RAISE EXCEPTION 'Sampling revision status changed; reload before deleting' USING ERRCODE='23514';
    END IF;
    IF parent.status='confirmed' AND NOT public.has_vineyard_role(p_vineyard_id,ARRAY['owner','manager','supervisor']) THEN
        RAISE EXCEPTION 'Only vineyard leadership may delete confirmed locations' USING ERRCODE='42501';
    END IF;
    DELETE FROM public.yield_sample_sites WHERE id=p_id AND site_set_id=p_set_id AND vineyard_id=p_vineyard_id;
    RETURN EXISTS(SELECT 1 FROM public.yield_sample_site_deletion_receipts
        WHERE deleted_row_id=p_id AND site_set_id=p_set_id AND vineyard_id=p_vineyard_id);
END $$;
REVOKE ALL ON FUNCTION public.hard_delete_yield_sample_site(uuid,uuid,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.hard_delete_yield_sample_site(uuid,uuid,uuid,text) TO authenticated;

-- Session identity locking covers an INSERT already in flight when a local-only
-- draft is deleted, and a delete request arriving before the first upload.
CREATE FUNCTION vinetrack_internal.yield_session_identity_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE target uuid;
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Yield writes require READ COMMITTED; retry' USING ERRCODE='40001';
    END IF;
    IF TG_OP='DELETE' THEN target:=OLD.id; ELSE target:=NEW.id; END IF;
    IF NOT pg_try_advisory_xact_lock(hashtextextended('yield-session:'||target::text,0)) THEN
        RAISE EXCEPTION 'Yield observation changed concurrently; retry' USING ERRCODE='40001';
    END IF;
    IF TG_OP='UPDATE' THEN
        IF NEW.id<>OLD.id OR NEW.vineyard_id<>OLD.vineyard_id THEN
            RAISE EXCEPTION 'Yield session identity and vineyard cannot change' USING ERRCODE='23514';
        END IF;
        IF (OLD.is_completed OR coalesce((OLD.payload->>'isCompleted')::boolean,false))
           AND (NOT NEW.is_completed OR NOT coalesce((NEW.payload->>'isCompleted')::boolean,false)
                OR NEW.completed_at IS DISTINCT FROM OLD.completed_at) THEN
            RAISE EXCEPTION 'A confirmed yield observation cannot be downgraded to a draft' USING ERRCODE='23514';
        END IF;
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    IF EXISTS(SELECT 1 FROM public.yield_estimation_session_deletion_receipts WHERE session_id=NEW.id) THEN
        RAISE EXCEPTION 'This yield observation was permanently deleted' USING ERRCODE='23505';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION vinetrack_internal.yield_session_identity_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER a_issue54_session_identity_guard BEFORE INSERT OR UPDATE OR DELETE ON public.yield_estimation_sessions
    FOR EACH ROW EXECUTE FUNCTION vinetrack_internal.yield_session_identity_guard();

-- The audit trigger, not only the RPC, invalidates a selected projection. It is
-- atomic with the physical deletion and cannot be bypassed by direct DELETE.
CREATE OR REPLACE FUNCTION vinetrack_internal.yield_session_hard_delete_audit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
    INSERT INTO public.yield_estimation_session_deletion_receipts(session_id,vineyard_id,was_completed,deleted_by)
    VALUES(OLD.id,OLD.vineyard_id,OLD.is_completed OR coalesce((OLD.payload->>'isCompleted')::boolean,false),auth.uid());
    UPDATE public.season_yield_estimates SET source_session_id=NULL,base_estimate_tonnes=NULL,
        is_estimate_available=false,
        setup_warnings=coalesce(setup_warnings,'[]'::jsonb)||
            '["Source Yield Estimate Trip was hard-deleted; select or recalculate a current source"]'::jsonb,
        updated_at=now(),calculated_at=now()
    WHERE vineyard_id=OLD.vineyard_id AND source_session_id=OLD.id AND estimate_source='bunch_count';
    RETURN OLD;
END $$;

-- This narrow definer performs explicit membership/state checks before any
-- write. Global identity lookup prevents reserving an unseen foreign-vineyard ID.
-- Ordinary table RLS remains unchanged, including direct DELETE permissions.
CREATE OR REPLACE FUNCTION public.hard_delete_yield_estimation_session(
    p_id uuid,p_vineyard_id uuid,p_expected_completed boolean
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_row public.yield_estimation_sessions%ROWTYPE; prior public.yield_estimation_session_deletion_receipts%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL OR NOT public.has_vineyard_role(p_vineyard_id,ARRAY['owner','manager','supervisor','operator']) THEN
        RAISE EXCEPTION 'Signed-in vineyard membership required' USING ERRCODE='42501';
    END IF;
    IF p_id IS NULL OR p_vineyard_id IS NULL OR p_expected_completed IS NULL THEN
        RAISE EXCEPTION 'Exact yield identity and completion state required' USING ERRCODE='22023';
    END IF;
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Yield deletion requires READ COMMITTED; retry' USING ERRCODE='40001';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('yield-session:'||p_id::text,0));
    SELECT * INTO prior FROM public.yield_estimation_session_deletion_receipts WHERE session_id=p_id;
    IF FOUND THEN
        IF prior.vineyard_id<>p_vineyard_id OR (prior.was_completed AND
            NOT public.has_vineyard_role(p_vineyard_id,ARRAY['owner','manager','supervisor'])) THEN
            RAISE EXCEPTION 'Yield deletion not authorised' USING ERRCODE='42501';
        END IF;
        RETURN true;
    END IF;
    SELECT * INTO v_row FROM public.yield_estimation_sessions WHERE id=p_id FOR UPDATE;
    IF NOT FOUND THEN
        IF p_expected_completed THEN RETURN false; END IF;
        -- Durable server receipt even for a never-uploaded draft. No geometry,
        -- observations, or invented customer session rows are inserted.
        INSERT INTO public.yield_estimation_session_deletion_receipts(session_id,vineyard_id,was_completed,deleted_by)
        VALUES(p_id,p_vineyard_id,false,auth.uid());
        RETURN true;
    END IF;
    IF v_row.vineyard_id<>p_vineyard_id THEN
        RAISE EXCEPTION 'Yield deletion not authorised' USING ERRCODE='42501';
    END IF;
    IF v_row.is_completed IS DISTINCT FROM p_expected_completed OR
        coalesce((v_row.payload->>'isCompleted')::boolean,false) IS DISTINCT FROM p_expected_completed THEN
        RAISE EXCEPTION 'Observation completion changed; reload before deleting' USING ERRCODE='23514';
    END IF;
    IF p_expected_completed AND NOT public.has_vineyard_role(p_vineyard_id,ARRAY['owner','manager','supervisor']) THEN
        RAISE EXCEPTION 'Only vineyard leadership may delete confirmed observations' USING ERRCODE='42501';
    END IF;
    DELETE FROM public.yield_estimation_sessions WHERE id=p_id AND vineyard_id=p_vineyard_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Yield deletion not confirmed' USING ERRCODE='42501'; END IF;
    RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.hard_delete_yield_estimation_session(uuid,uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.hard_delete_yield_estimation_session(uuid,uuid,boolean) TO authenticated;

-- Retained older clients can still call the ID-only wrapper. It must use the
-- same advisory-before-tuple ordering as the exact-state RPC, never the old
-- SELECT FOR UPDATE followed by a waiting identity lock.
CREATE OR REPLACE FUNCTION public.hard_delete_yield_estimation_session_by_id(p_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog AS $$
DECLARE v_id uuid; v_completed boolean;
BEGIN
    IF p_id IS NULL OR current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Exact identity and READ COMMITTED required; retry' USING ERRCODE='40001';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('yield-session:'||p_id::text,0));
    SELECT vineyard_id,is_completed INTO v_id,v_completed
    FROM public.yield_estimation_sessions WHERE id=p_id;
    IF FOUND THEN
        RETURN public.hard_delete_yield_estimation_session(p_id,v_id,v_completed);
    END IF;
    SELECT vineyard_id,was_completed INTO v_id,v_completed
    FROM public.yield_estimation_session_deletion_receipts WHERE session_id=p_id;
    IF FOUND THEN
        RETURN public.hard_delete_yield_estimation_session(p_id,v_id,v_completed);
    END IF;
    RETURN false;
END $$;
REVOKE ALL ON FUNCTION public.hard_delete_yield_estimation_session_by_id(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.hard_delete_yield_estimation_session_by_id(uuid) TO authenticated;

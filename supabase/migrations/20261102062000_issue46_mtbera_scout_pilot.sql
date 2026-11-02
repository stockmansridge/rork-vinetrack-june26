-- Issue #46: Mt Bera only, customer Scout Trip write pilot. 2026-11-02
-- Does not touch mobile outboxes, recovery Issue #43, Vintage Report permissions,
-- existing can_use_vineyard_insights, or previously stored Scout rows.
-- Existing System Admin permissions are preserved through existing RLS policies.
-- Rollback: drop the issue46_* policies; drop can_write_scout_customer_pilot(uuid);
-- then disable key scout_customer_pilot_vineyards. Never purge Scout data.

DO $seed$
DECLARE
  target_id uuid;
  matches integer;
BEGIN
  SELECT count(*) INTO matches
  FROM public.vineyards WHERE name = 'Mt Bera Vineyards' AND deleted_at IS NULL;
  IF matches <> 1 THEN
    RAISE EXCEPTION 'ISSUE46_EXPECTED_ONE_ACTIVE_MT_BERA_VINEYARD';
  END IF;
  SELECT id INTO target_id
  FROM public.vineyards WHERE name = 'Mt Bera Vineyards' AND deleted_at IS NULL;
  INSERT INTO public.system_feature_flags
    (key,value,value_type,is_enabled,category,label,description)
  VALUES
    ('scout_customer_pilot_vineyards',jsonb_build_array(target_id::text),
     'json',true,'features','Scout customer pilot allowlist',
     'Scoped, reversible owner/manager Scout write permission for ticket #46')
  ON CONFLICT (key) DO NOTHING;
  IF NOT EXISTS (
    SELECT 1 FROM public.system_feature_flags ff
    WHERE ff.key='scout_customer_pilot_vineyards'
      AND ff.is_enabled AND ff.value_type='json'
      AND jsonb_typeof(ff.value)='array'
      AND ff.value @> jsonb_build_array(target_id::text)
  ) THEN
    RAISE EXCEPTION 'ISSUE46_PILOT_FLAG_NOT_ENABLED_FOR_EXPECTED_VINEYARD';
  END IF;
END
$seed$;

CREATE OR REPLACE FUNCTION public.can_write_scout_customer_pilot(p_vineyard_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $fn$
  SELECT auth.uid() IS NOT NULL
     AND p_vineyard_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.vineyards v
       WHERE v.id = p_vineyard_id AND v.deleted_at IS NULL
         AND (v.owner_id = auth.uid()
           OR public.has_vineyard_role(p_vineyard_id, ARRAY['owner','manager']::text[]))
     )
     AND EXISTS (
       SELECT 1 FROM public.system_feature_flags ff
       WHERE ff.key = 'scout_customer_pilot_vineyards'
         AND ff.is_enabled
         AND ff.value_type = 'json'
         AND jsonb_typeof(ff.value) = 'array'
         AND ff.value @> jsonb_build_array(p_vineyard_id::text)
     );
$fn$;
REVOKE ALL ON FUNCTION public.can_write_scout_customer_pilot(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_write_scout_customer_pilot(uuid) TO authenticated;

-- ADDITIVE permissive policies (do not replace established Admin policies).
-- Do NOT add direct DELETE policies to Scout tables; canonical hard deletion
-- remains RPC-only and deliberately gated independently of this pilot.
CREATE POLICY issue46_pilot_visits_insert ON public.scout_visits
  FOR INSERT TO authenticated WITH CHECK (public.can_write_scout_customer_pilot(vineyard_id));
CREATE POLICY issue46_pilot_visits_update ON public.scout_visits
  FOR UPDATE TO authenticated
  USING (public.can_write_scout_customer_pilot(vineyard_id))
  WITH CHECK (public.can_write_scout_customer_pilot(vineyard_id));

CREATE POLICY issue46_pilot_assessments_insert ON public.scout_block_assessments
  FOR INSERT TO authenticated WITH CHECK (public.can_write_scout_customer_pilot(vineyard_id));
CREATE POLICY issue46_pilot_assessments_update ON public.scout_block_assessments
  FOR UPDATE TO authenticated
  USING (public.can_write_scout_customer_pilot(vineyard_id))
  WITH CHECK (public.can_write_scout_customer_pilot(vineyard_id));

CREATE POLICY issue46_pilot_observations_insert ON public.scout_observations
  FOR INSERT TO authenticated WITH CHECK (public.can_write_scout_customer_pilot(vineyard_id));
CREATE POLICY issue46_pilot_observations_update ON public.scout_observations
  FOR UPDATE TO authenticated
  USING (public.can_write_scout_customer_pilot(vineyard_id))
  WITH CHECK (public.can_write_scout_customer_pilot(vineyard_id));

CREATE POLICY issue46_pilot_photo_rows_insert ON public.scout_observation_photos
  FOR INSERT TO authenticated WITH CHECK (public.can_write_scout_customer_pilot(vineyard_id));
CREATE POLICY issue46_pilot_photo_rows_update ON public.scout_observation_photos
  FOR UPDATE TO authenticated
  USING (public.can_write_scout_customer_pilot(vineyard_id))
  WITH CHECK (public.can_write_scout_customer_pilot(vineyard_id));

-- The app's deletion ledger pull must be able to see the scoped vineyard's
-- canonical tombstones. Does not permit direct delete of any Scout row.
CREATE POLICY issue46_pilot_deletion_ledger_read ON public.vineyard_insights_deletions
  FOR SELECT TO authenticated USING (public.can_write_scout_customer_pilot(vineyard_id));

-- Storage uses vineyard UUID as the FIRST path segment; no cross-vineyard
-- read/write and no public bucket access.
CREATE POLICY issue46_pilot_photo_storage_select ON storage.objects
  FOR SELECT TO authenticated USING (
    bucket_id='scout-photos'
    AND public.can_write_scout_customer_pilot(public.storage_first_folder_uuid(name))
  );
CREATE POLICY issue46_pilot_photo_storage_insert ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (
    bucket_id='scout-photos'
    AND public.can_write_scout_customer_pilot(public.storage_first_folder_uuid(name))
  );
CREATE POLICY issue46_pilot_photo_storage_update ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id='scout-photos'
    AND public.can_write_scout_customer_pilot(public.storage_first_folder_uuid(name)))
  WITH CHECK (bucket_id='scout-photos'
    AND public.can_write_scout_customer_pilot(public.storage_first_folder_uuid(name)));
CREATE POLICY issue46_pilot_photo_storage_delete ON storage.objects
  FOR DELETE TO authenticated USING (
    bucket_id='scout-photos'
    AND public.can_write_scout_customer_pilot(public.storage_first_folder_uuid(name))
  );

-- Existing authenticated Scout cleanup RPCs are called BEFORE visit/photo push;
-- without these guards updated, a 403 would still be shown after successful
-- pilot writes. Preserve original lease, ownership and receipt checks.
CREATE OR REPLACE FUNCTION public.claim_scout_photo_cleanup(
  p_vineyard_id uuid, p_limit integer DEFAULT 20)
RETURNS SETOF public.scout_photo_cleanup_queue
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog','public'
AS $fn$
BEGIN
  IF auth.uid() IS NULL OR NOT (
     public.can_use_vineyard_insights(p_vineyard_id)
     OR public.can_write_scout_customer_pilot(p_vineyard_id)
  ) THEN
    RAISE EXCEPTION USING errcode='42501',message='NOT_AUTHORISED';
  END IF;
  RETURN QUERY WITH due AS (
    SELECT q.id FROM public.scout_photo_cleanup_queue q
    WHERE q.vineyard_id = p_vineyard_id
      AND q.status IN ('pending','failed','delivering')
      AND q.next_attempt_at <= now()
      AND (q.lease_expires_at IS NULL OR q.lease_expires_at < now())
    ORDER BY q.next_attempt_at,q.id
    FOR UPDATE SKIP LOCKED LIMIT least(greatest(p_limit,1),50)
  ) UPDATE public.scout_photo_cleanup_queue q SET
      status='delivering',lease_token=gen_random_uuid(),leased_at=now(),
      lease_expires_at=now()+interval '90 seconds',attempt_count=q.attempt_count+1
    FROM due WHERE q.id=due.id RETURNING q.*;
END $fn$;

CREATE OR REPLACE FUNCTION public.complete_scout_photo_cleanup(p_id uuid,p_lease_token uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog','public'
AS $fn$
DECLARE v_vineyard uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION USING errcode='42501',message='NOT_AUTHORISED'; END IF;
  SELECT vineyard_id INTO v_vineyard FROM public.scout_photo_cleanup_queue
    WHERE id=p_id AND lease_token=p_lease_token AND lease_expires_at>now() FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  IF NOT (public.can_use_vineyard_insights(v_vineyard)
       OR public.can_write_scout_customer_pilot(v_vineyard)) THEN
    RAISE EXCEPTION USING errcode='42501',message='NOT_AUTHORISED';
  END IF;
  UPDATE public.scout_photo_cleanup_queue SET status='completed',completed_at=now(),
    lease_token=null,leased_at=null,lease_expires_at=null,last_error=null WHERE id=p_id;
  RETURN true;
END $fn$;

CREATE OR REPLACE FUNCTION public.fail_scout_photo_cleanup(p_id uuid,p_lease_token uuid,p_error text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog','public'
AS $fn$
DECLARE v_vineyard uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION USING errcode='42501',message='NOT_AUTHORISED'; END IF;
  SELECT vineyard_id INTO v_vineyard FROM public.scout_photo_cleanup_queue
    WHERE id=p_id AND lease_token=p_lease_token AND lease_expires_at>now() FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  IF NOT (public.can_use_vineyard_insights(v_vineyard)
       OR public.can_write_scout_customer_pilot(v_vineyard)) THEN
    RAISE EXCEPTION USING errcode='42501',message='NOT_AUTHORISED';
  END IF;
  UPDATE public.scout_photo_cleanup_queue SET status='failed',
    next_attempt_at=now()+make_interval(secs=>least(3600,30*power(2,least(attempt_count,7))::integer)),
    lease_token=null,leased_at=null,lease_expires_at=null,last_error=left(p_error,500)
  WHERE id=p_id;
  RETURN true;
END $fn$;

-- Explicit guard against accidental broad feature release.
DO $assert$
BEGIN
  IF (SELECT count(*) FROM public.system_feature_flags
      WHERE key='scout_customer_pilot_vineyards' AND is_enabled
       AND jsonb_array_length(value)=1) <> 1 THEN
    RAISE EXCEPTION 'ISSUE46_PILOT_ALLOWLIST_NOT_SINGLE_VINEYARD';
  END IF;
END $assert$;

-- Issue #54 follow-up: confirmed-site archival requires vineyard leadership and immutable archived snapshots.
CREATE OR REPLACE FUNCTION public.yield_sample_site_set_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Yield site sets must be archived, not deleted' USING ERRCODE = '23514';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.paddocks p
                 WHERE p.id = NEW.paddock_id AND p.vineyard_id = NEW.vineyard_id
                   AND p.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Sampling site set must reference a live block in its vineyard' USING ERRCODE = '23514';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' OR NEW.confirmed_by IS NOT NULL OR NEW.confirmed_at IS NOT NULL THEN
      RAISE EXCEPTION 'Sampling site sets begin as drafts' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT 1 FROM public.yield_sample_site_sets s WHERE s.set_key = NEW.set_key
               AND (s.vineyard_id <> NEW.vineyard_id OR s.paddock_id <> NEW.paddock_id)) THEN
      RAISE EXCEPTION 'A site set identity cannot move between blocks' USING ERRCODE = '23514';
    END IF;
    IF NEW.version > 1 AND NOT EXISTS (
      SELECT 1 FROM public.yield_sample_site_sets s
      WHERE s.set_key = NEW.set_key AND s.version = NEW.version - 1
        AND s.vineyard_id = NEW.vineyard_id AND s.paddock_id = NEW.paddock_id
        AND s.status <> 'draft'
    ) THEN
      RAISE EXCEPTION 'Previous site set version must be confirmed or archived' USING ERRCODE = '23514';
    END IF;
  ELSE
    IF NEW.id <> OLD.id OR NEW.vineyard_id <> OLD.vineyard_id
       OR NEW.paddock_id <> OLD.paddock_id OR NEW.set_key <> OLD.set_key
       OR NEW.version <> OLD.version OR NEW.created_by IS DISTINCT FROM OLD.created_by
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'Site set identity and provenance are immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.status = 'archived' THEN
      RAISE EXCEPTION 'Archived sampling revisions are immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.status = 'confirmed' THEN
      IF NEW.status <> 'archived'
         OR NEW.name IS DISTINCT FROM OLD.name
         OR NEW.confirmed_by IS DISTINCT FROM OLD.confirmed_by
         OR NEW.confirmed_at IS DISTINCT FROM OLD.confirmed_at THEN
        RAISE EXCEPTION 'Confirmed sampling revisions may only be archived unchanged' USING ERRCODE = '23514';
      END IF;
      IF NOT public.has_vineyard_role(OLD.vineyard_id, ARRAY['owner', 'manager', 'supervisor']) THEN
        RAISE EXCEPTION 'Only vineyard leadership may archive confirmed sites' USING ERRCODE = '42501';
      END IF;
    ELSIF NEW.status = 'confirmed' THEN
      IF NOT public.has_vineyard_role(NEW.vineyard_id, ARRAY['owner', 'manager', 'supervisor']) THEN
        RAISE EXCEPTION 'A vineyard manager must confirm sampling sites' USING ERRCODE = '42501';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.yield_sample_sites z WHERE z.site_set_id = NEW.id) THEN
        RAISE EXCEPTION 'At least one sampling site is required to confirm a set' USING ERRCODE = '23514';
      END IF;
      NEW.confirmed_by := (SELECT auth.uid());
      NEW.confirmed_at := now();
    ELSIF NEW.status = 'archived' THEN
      IF NOT public.has_vineyard_role(NEW.vineyard_id, ARRAY['owner', 'manager', 'supervisor']) THEN
        RAISE EXCEPTION 'Only vineyard leadership may archive sampling revisions' USING ERRCODE = '42501';
      END IF;
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
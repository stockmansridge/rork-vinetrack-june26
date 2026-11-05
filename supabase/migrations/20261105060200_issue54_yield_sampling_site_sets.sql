-- Issue #54: durable, versioned fixed yield-sampling sites. Additive; no existing yield or trip data changes.
CREATE TABLE public.yield_sample_site_sets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vineyard_id uuid NOT NULL REFERENCES public.vineyards(id) ON DELETE CASCADE,
  paddock_id uuid NOT NULL REFERENCES public.paddocks(id) ON DELETE CASCADE,
  set_key uuid NOT NULL DEFAULT gen_random_uuid(),
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  name text NOT NULL DEFAULT 'Permanent Yield Sampling Locations' CHECK (length(name) BETWEEN 1 AND 120),
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'confirmed', 'archived')),
  created_by uuid DEFAULT auth.uid(),
  confirmed_by uuid,
  confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT yield_site_sets_identity_version UNIQUE(set_key, version),
  CONSTRAINT yield_site_sets_parent_key UNIQUE(id, vineyard_id, paddock_id)
);
CREATE UNIQUE INDEX yield_site_sets_one_confirmed_block
  ON public.yield_sample_site_sets(vineyard_id, paddock_id) WHERE status = 'confirmed';
CREATE INDEX yield_site_sets_scope ON public.yield_sample_site_sets(vineyard_id, paddock_id, set_key, version DESC);

CREATE TABLE public.yield_sample_sites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_set_id uuid NOT NULL,
  vineyard_id uuid NOT NULL,
  paddock_id uuid NOT NULL,
  site_id uuid NOT NULL DEFAULT gen_random_uuid(),
  site_number integer NOT NULL CHECK (site_number > 0),
  name text NOT NULL DEFAULT '' CHECK (length(name) <= 120),
  row_number text CHECK (length(row_number) <= 40),
  panel_number text CHECK (length(panel_number) <= 40),
  latitude double precision NOT NULL CHECK (isfinite(latitude) AND latitude BETWEEN -90 AND 90),
  longitude double precision NOT NULL CHECK (isfinite(longitude) AND longitude BETWEEN -180 AND 180),
  notes text CHECK (length(notes) <= 4000),
  created_by uuid DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT yield_sites_parent FOREIGN KEY(site_set_id, vineyard_id, paddock_id)
    REFERENCES public.yield_sample_site_sets(id, vineyard_id, paddock_id) ON DELETE RESTRICT,
  CONSTRAINT yield_sites_stable_identity UNIQUE(site_set_id, site_id),
  CONSTRAINT yield_sites_number_in_version UNIQUE(site_set_id, site_number)
);
CREATE INDEX yield_sample_sites_scope ON public.yield_sample_sites(vineyard_id, paddock_id, site_set_id);

-- A confirmed site-set version is immutable. Corrections create a new draft
-- version with the same set_key and physical site_id values, then confirm it.
CREATE FUNCTION public.yield_sample_site_set_guard()
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
       OR NEW.version <> OLD.version THEN
      RAISE EXCEPTION 'Site set identity/version are immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.status = 'archived' OR (OLD.status = 'confirmed' AND NEW.status <> 'archived') THEN
      RAISE EXCEPTION 'Confirmed/archived sampling revisions are immutable' USING ERRCODE = '23514';
    END IF;
    IF NEW.status = 'confirmed' THEN
      IF NOT public.has_vineyard_role(NEW.vineyard_id, ARRAY['owner', 'manager', 'supervisor']) THEN
        RAISE EXCEPTION 'A vineyard manager must confirm sampling sites' USING ERRCODE = '42501';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.yield_sample_sites z WHERE z.site_set_id = NEW.id) THEN
        RAISE EXCEPTION 'At least one sampling site is required to confirm a set' USING ERRCODE = '23514';
      END IF;
      NEW.confirmed_by := (SELECT auth.uid());
      NEW.confirmed_at := now();
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE FUNCTION public.yield_sample_site_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE parent_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    SELECT status INTO parent_status FROM public.yield_sample_site_sets
      WHERE id = OLD.site_set_id AND vineyard_id = OLD.vineyard_id AND paddock_id = OLD.paddock_id;
    IF parent_status = 'draft' THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'Confirmed sampling sites cannot be deleted; create a new set version' USING ERRCODE = '23514';
  END IF;
  SELECT status INTO parent_status FROM public.yield_sample_site_sets
   WHERE id = NEW.site_set_id AND vineyard_id = NEW.vineyard_id AND paddock_id = NEW.paddock_id;
  IF parent_status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'Only draft sampling site revisions can be edited' USING ERRCODE = '23514';
  END IF;
  IF TG_OP = 'UPDATE' AND (
    NEW.id <> OLD.id OR NEW.site_set_id <> OLD.site_set_id
    OR NEW.site_id <> OLD.site_id OR NEW.vineyard_id <> OLD.vineyard_id
    OR NEW.paddock_id <> OLD.paddock_id
  ) THEN
    RAISE EXCEPTION 'Sampling site and parent identities are immutable' USING ERRCODE = '23514';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE TRIGGER yield_sample_site_sets_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.yield_sample_site_sets
  FOR EACH ROW EXECUTE FUNCTION public.yield_sample_site_set_guard();
CREATE TRIGGER yield_sample_sites_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.yield_sample_sites
  FOR EACH ROW EXECUTE FUNCTION public.yield_sample_site_guard();

-- One transaction archives the old confirmed revision and confirms the new one.
-- This does not change historical yield sessions or the protected Trip journals.
CREATE FUNCTION public.confirm_yield_sample_site_set(p_set_id uuid, p_expected_version integer)
RETURNS public.yield_sample_site_sets
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE target_set public.yield_sample_site_sets;
BEGIN
  SELECT * INTO target_set FROM public.yield_sample_site_sets
  WHERE id = p_set_id AND version = p_expected_version FOR UPDATE;
  IF NOT FOUND OR target_set.status <> 'draft' THEN
    RAISE EXCEPTION 'Sampling site revision is missing or not a draft' USING ERRCODE = '23514';
  END IF;
  IF NOT public.has_vineyard_role(target_set.vineyard_id, ARRAY['owner','manager','supervisor']) THEN
    RAISE EXCEPTION 'Vineyard manager permission required' USING ERRCODE = '42501';
  END IF;
  -- The unique confirmed index also prevents concurrent double-confirmation.
  UPDATE public.yield_sample_site_sets
     SET status = 'archived'
   WHERE vineyard_id = target_set.vineyard_id AND paddock_id = target_set.paddock_id
     AND status = 'confirmed' AND id <> target_set.id;
  UPDATE public.yield_sample_site_sets
     SET status = 'confirmed'
   WHERE id = target_set.id RETURNING * INTO target_set;
  RETURN target_set;
END $$;

ALTER TABLE public.yield_sample_site_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.yield_sample_sites ENABLE ROW LEVEL SECURITY;
CREATE POLICY yield_site_sets_read ON public.yield_sample_site_sets
 FOR SELECT TO authenticated USING (public.is_vineyard_member(vineyard_id));
CREATE POLICY yield_site_sets_add ON public.yield_sample_site_sets
 FOR INSERT TO authenticated WITH CHECK
 (public.has_vineyard_role(vineyard_id, ARRAY['owner','manager','supervisor','operator']));
CREATE POLICY yield_site_sets_edit ON public.yield_sample_site_sets
 FOR UPDATE TO authenticated
 USING (public.has_vineyard_role(vineyard_id, ARRAY['owner','manager','supervisor','operator']))
 WITH CHECK (public.has_vineyard_role(vineyard_id, ARRAY['owner','manager','supervisor','operator']));
CREATE POLICY yield_sites_read ON public.yield_sample_sites
 FOR SELECT TO authenticated USING (public.is_vineyard_member(vineyard_id));
CREATE POLICY yield_sites_add ON public.yield_sample_sites
 FOR INSERT TO authenticated WITH CHECK
 (public.has_vineyard_role(vineyard_id, ARRAY['owner','manager','supervisor','operator']));
CREATE POLICY yield_sites_edit ON public.yield_sample_sites
 FOR UPDATE TO authenticated
 USING (public.has_vineyard_role(vineyard_id, ARRAY['owner','manager','supervisor','operator']))
 WITH CHECK (public.has_vineyard_role(vineyard_id, ARRAY['owner','manager','supervisor','operator']));
CREATE POLICY yield_sites_remove_draft ON public.yield_sample_sites
 FOR DELETE TO authenticated USING
 (public.has_vineyard_role(vineyard_id, ARRAY['owner','manager','supervisor','operator'])
  AND EXISTS (SELECT 1 FROM public.yield_sample_site_sets ss
              WHERE ss.id = site_set_id AND ss.status = 'draft'));


REVOKE ALL ON public.yield_sample_site_sets, public.yield_sample_sites FROM anon;
GRANT SELECT, INSERT, UPDATE ON public.yield_sample_site_sets, public.yield_sample_sites TO authenticated;
GRANT DELETE ON public.yield_sample_sites TO authenticated;
REVOKE ALL ON FUNCTION public.confirm_yield_sample_site_set(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_yield_sample_site_set(uuid, integer) TO authenticated;

COMMENT ON TABLE public.yield_sample_site_sets IS 'Issue54 immutable confirmed versions of per-block yield sampling locations; distinct from Permanent Items and Pins.';
COMMENT ON TABLE public.yield_sample_sites IS 'Issue54 physical site UUID survives set versions; GPS and row/panel are versioned snapshots.';

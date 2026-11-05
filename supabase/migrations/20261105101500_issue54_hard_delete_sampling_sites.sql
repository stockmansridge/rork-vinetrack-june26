-- Issue 54: explicit physical removal of an individual fixed sampling
-- site (draft: any vineyard operator; confirmed: leadership only).
-- Historical sessions retain their own independent GPS/row/panel snapshots.
CREATE TABLE public.yield_sample_site_deletion_receipts (
    deleted_row_id uuid PRIMARY KEY,
    site_set_id uuid NOT NULL,
    site_id uuid NOT NULL,
    vineyard_id uuid NOT NULL REFERENCES public.vineyards(id) ON DELETE CASCADE,
    paddock_id uuid NOT NULL,
    was_confirmed boolean NOT NULL,
    deleted_by uuid NOT NULL REFERENCES auth.users(id),
    deleted_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.yield_sample_site_deletion_receipts ENABLE ROW LEVEL SECURITY;
CREATE POLICY yield_site_deletion_receipts_read_members
    ON public.yield_sample_site_deletion_receipts FOR SELECT TO authenticated
    USING (public.is_vineyard_member(vineyard_id));
REVOKE ALL ON public.yield_sample_site_deletion_receipts FROM anon,authenticated;
GRANT SELECT ON public.yield_sample_site_deletion_receipts TO authenticated;

CREATE OR REPLACE FUNCTION public.yield_sample_site_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE parent_status text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        SELECT status INTO parent_status
          FROM public.yield_sample_site_sets
          WHERE id=OLD.site_set_id AND vineyard_id=OLD.vineyard_id
            AND paddock_id=OLD.paddock_id;
        IF parent_status = 'draft'
           AND public.has_vineyard_role(OLD.vineyard_id,
               ARRAY['owner','manager','supervisor','operator']) THEN
            RETURN OLD;
        END IF;
        IF parent_status = 'confirmed'
           AND public.has_vineyard_role(OLD.vineyard_id,
               ARRAY['owner','manager','supervisor']) THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'Hard deleting confirmed locations requires Supervisor, Manager or Owner permissions'
            USING ERRCODE = '42501';
    END IF;
    SELECT status INTO parent_status
      FROM public.yield_sample_site_sets
      WHERE id=NEW.site_set_id AND vineyard_id=NEW.vineyard_id
        AND paddock_id=NEW.paddock_id;
    IF parent_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'Only draft site revisions can be edited' USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'UPDATE' AND
       (NEW.id<>OLD.id OR NEW.site_set_id<>OLD.site_set_id
        OR NEW.site_id<>OLD.site_id OR NEW.vineyard_id<>OLD.vineyard_id
        OR NEW.paddock_id<>OLD.paddock_id) THEN
        RAISE EXCEPTION 'Sampling site and parent identities are immutable' USING ERRCODE = '23514';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE POLICY yield_site_delete_confirmed_by_leadership
    ON public.yield_sample_sites FOR DELETE TO authenticated
    USING (
        public.has_vineyard_role(vineyard_id,ARRAY['owner','manager','supervisor'])
        AND EXISTS (
            SELECT 1 FROM public.yield_sample_site_sets s
            WHERE s.id=site_set_id AND s.vineyard_id=yield_sample_sites.vineyard_id
              AND s.status='confirmed'
        )
    );

CREATE FUNCTION vinetrack_internal.yield_sample_site_hard_delete_receipt()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE is_confirmed boolean;
BEGIN
    SELECT s.status='confirmed' INTO is_confirmed
    FROM public.yield_sample_site_sets s WHERE s.id=OLD.site_set_id;
    INSERT INTO public.yield_sample_site_deletion_receipts(
        deleted_row_id,site_set_id,site_id,vineyard_id,paddock_id,
        was_confirmed,deleted_by
    ) VALUES(
        OLD.id,OLD.site_set_id,OLD.site_id,OLD.vineyard_id,OLD.paddock_id,
        coalesce(is_confirmed,false),auth.uid()
    );
    RETURN OLD;
END $$;
CREATE FUNCTION vinetrack_internal.yield_sample_site_prevent_resurrection()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.yield_sample_site_deletion_receipts
               WHERE deleted_row_id=NEW.id) THEN
        RAISE EXCEPTION 'This sampling location was permanently deleted'
            USING ERRCODE='23505';
    END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION vinetrack_internal.yield_sample_site_hard_delete_receipt() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION vinetrack_internal.yield_sample_site_prevent_resurrection() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER yield_sample_site_hard_delete_receipt
    AFTER DELETE ON public.yield_sample_sites FOR EACH ROW
    EXECUTE FUNCTION vinetrack_internal.yield_sample_site_hard_delete_receipt();
CREATE TRIGGER yield_sample_site_prevent_replay
    BEFORE INSERT ON public.yield_sample_sites FOR EACH ROW
    EXECUTE FUNCTION vinetrack_internal.yield_sample_site_prevent_resurrection();
COMMENT ON TABLE public.yield_sample_site_deletion_receipts IS
    'Issue54 metadata-only receipts. Physical sites are deleted, historical observation snapshots retained.';

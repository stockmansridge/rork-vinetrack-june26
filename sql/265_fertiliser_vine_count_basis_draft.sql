-- DRAFT ONLY — NOT APPLIED. Deploy separately before releasing basis-aware sync.
-- Live schema inspected 2026-10-05: fertiliser_records has no count-basis field.
-- Record-level provenance is sufficient: all allocations use the same basis.
-- No default, backfill, record rewrite, or allocation schema change.
BEGIN;
ALTER TABLE public.fertiliser_records
    ADD COLUMN IF NOT EXISTS vine_count_basis text;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.fertiliser_records'::regclass
          AND conname = 'fertiliser_records_vine_count_basis_check'
    ) THEN
        ALTER TABLE public.fertiliser_records
            ADD CONSTRAINT fertiliser_records_vine_count_basis_check
            CHECK (vine_count_basis IS NULL OR vine_count_basis IN ('actual', 'assumed_full', 'manual'));
    END IF;
END $$;
COMMENT ON COLUMN public.fertiliser_records.vine_count_basis IS
    'Saved calculation basis: actual, assumed_full, manual; NULL means legacy/unspecified. Counts and quantities remain snapshots.';
COMMIT;

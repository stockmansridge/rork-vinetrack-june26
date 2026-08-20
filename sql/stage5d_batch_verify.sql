-- stage5d_batch_verify.sql — AWRI seed FULL-BATCH (Stage 5D) verification.
-- READ-ONLY: every statement is a SELECT. Run in the Supabase SQL editor on
-- tbafuqwruefgkbyxrxyb AFTER the Stage 5D execute run completes.
--
-- Verified post-pilot baseline (operator, Stage 5C sign-off):
--   master_chemicals 7 | master_chemical_versions 7
--   saved_chemicals 35 | spray_records 10
--
-- Batch rows are identified by their AWRI provenance: exactly the rows whose
-- verification_sources contain the AWRI Dog Book viticulture_reference entry.
-- The 2 pre-seed rows (incl. AU:apvma:91636) have no such entry, so:
--   master_rows − awri_rows = 2   (invariant, before and after Stage 5D)

-- ===========================================================================
-- A. TABLE COUNTS + unchanged PASS/FAIL
--    Expect: saved_chemicals_check = PASS, spray_records_check = PASS,
--            master_rows = 7 + <Stage 5D created>,
--            master_version_rows = master_rows (one insert-audit row each).
-- ===========================================================================
select
  (select count(*) from public.master_chemicals)         as master_rows,
  (select count(*) from public.master_chemical_versions) as master_version_rows,
  (select count(*) from public.saved_chemicals)          as saved_chemicals_rows,
  (select count(*) from public.spray_records)            as spray_records_rows,
  case when (select count(*) from public.saved_chemicals) = 35
       then 'PASS' else 'FAIL' end                       as saved_chemicals_check,
  case when (select count(*) from public.spray_records) = 10
       then 'PASS' else 'FAIL' end                       as spray_records_check;

-- ===========================================================================
-- B. BATCH PROVENANCE ROLLUP — one row of PASS/FAIL over ALL seed-created rows
--    (pilot 5 + Stage 5D). Every check must read PASS.
-- ===========================================================================
with batch as (
  select *
    from public.master_chemicals m
   where exists (
           select 1
             from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) s
            where s->>'kind' = 'viticulture_reference'
              and s->>'reference' = 'https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf'
         )
)
select
  (select count(*) from batch)                                   as awri_rows, -- = 5 + Stage 5D created
  case when not exists (select 1 from batch where review_status <> 'candidate')
       then 'PASS' else 'FAIL' end                               as all_candidate,
  case when not exists (select 1 from batch
                         where reviewed_by is not null or reviewed_at is not null)
       then 'PASS' else 'FAIL' end                               as no_auto_approval,
  case when not exists (select 1 from batch where source_kind <> 'official_register')
       then 'PASS' else 'FAIL' end                               as all_official_register,
  case when not exists (select 1 from batch
                         where registration_identity_key !~ '^AU:apvma:[0-9]+$')
       then 'PASS' else 'FAIL' end                               as all_au_apvma_identities,
  case when not exists (
         select 1 from batch b
          where (select count(*)
                   from jsonb_array_elements(coalesce(b.verification_sources, '[]'::jsonb)) s
                  where s->>'kind' = 'viticulture_reference') <> 1)
       then 'PASS' else 'FAIL' end                               as awri_provenance, -- exactly 1 AWRI entry each
  case when not exists (
         select 1 from batch b
          where not exists (
                select 1
                  from jsonb_array_elements(coalesce(b.verification_sources, '[]'::jsonb)) s
                 where s->>'kind' = 'official_register'))
       then 'PASS' else 'FAIL' end                               as apvma_evidence_each_row,
  case when (select count(*) from public.master_chemicals)
          - (select count(*) from batch) = 2
       then 'PASS' else 'FAIL' end                               as preseed_rows_invariant;

-- ===========================================================================
-- C. NO DUPLICATES — identity is UNIQUE-constrained; prove it held.
--    Expect 0 rows (= PASS).
-- ===========================================================================
select registration_identity_key, count(*)
  from public.master_chemicals
 group by registration_identity_key
having count(*) > 1;

-- ===========================================================================
-- D. PRE-SEED ROWS UNTOUCHED — AU:apvma:91636 must match the Stage 5C
--    snapshot exactly (same review_status, catalogue_version, updated_at).
-- ===========================================================================
select registration_identity_key, review_status, catalogue_version, updated_at
  from public.master_chemicals
 where registration_identity_key = 'AU:apvma:91636';

-- ===========================================================================
-- E. CROSS-CHECK AGAINST THE RUNNER SUMMARY
--    awri_rows (section B) must equal 5 + <created> printed by the runner.
--    unresolved / conflict / failed items write NOTHING — they exist only in
--    the runner state file, so master_rows must not grow for them.
-- ===========================================================================
select count(*) as awri_rows_now
  from public.master_chemicals m
 where exists (
         select 1
           from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) s
          where s->>'kind' = 'viticulture_reference'
            and s->>'reference' = 'https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf');

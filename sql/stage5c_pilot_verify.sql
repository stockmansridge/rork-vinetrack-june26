-- stage5c_pilot_verify.sql — AWRI seed PRODUCTION PILOT verification.
-- READ-ONLY: every statement is a SELECT. Run in the Supabase SQL editor on
-- tbafuqwruefgkbyxrxyb. Section A runs BEFORE the pilot; B–F run AFTER.
--
-- The 5 pilot identities (first 5 of the 196 sendable, numeric order — the
-- exact set `run_awri_apply.ts --limit 5` sends from a fresh state):
--   AU:apvma:30462  Rovral Liquid
--   AU:apvma:30467  Polyram DF
--   AU:apvma:30476  Topas 100 EC
--   AU:apvma:30582  Manzate 750 WG
--   AU:apvma:31393  Roundup

-- ===========================================================================
-- A. BASELINE — run BEFORE the pilot; keep the outputs for comparison
-- ===========================================================================
select
  (select count(*) from public.master_chemicals)          as master_rows,
  (select count(*) from public.master_chemical_versions)  as master_version_rows,
  (select count(*) from public.saved_chemicals)           as saved_chemicals_rows,
  (select count(*) from public.spray_records)             as spray_records_rows;

-- Snapshot of the pre-existing Stage 4 candidate — must be byte-identical after.
select registration_identity_key, review_status, catalogue_version, updated_at
  from public.master_chemicals
 where registration_identity_key = 'AU:apvma:91636';

-- ===========================================================================
-- B. PILOT ROWS — one row per pilot chemical with everything the report needs
-- ===========================================================================
select registration_identity_key,
       id                            as master_chemical_id,
       registered_product_name,
       registrant,
       review_status,                -- must be 'candidate'
       source_kind,                  -- must be 'official_register'
       verification_status,
       active_ingredients,           -- actives + concentrations (register-sourced)
       jsonb_array_length(coalesce(registered_uses, '[]'::jsonb)) as label_use_lines,
       (select count(*)
          from jsonb_array_elements(coalesce(registered_uses, '[]'::jsonb)) u
         where u ? 'withholding_period_days')                     as uses_with_whp,
       (select count(*)
          from jsonb_array_elements(coalesce(verification_sources, '[]'::jsonb)) s
         where s->>'kind' = 'viticulture_reference'
           and s->>'reference' = 'https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf')
                                                                  as awri_evidence_entries, -- must be 1
       (select count(*)
          from jsonb_array_elements(coalesce(verification_sources, '[]'::jsonb)) s
         where s->>'kind' = 'official_register')                  as register_evidence_entries, -- >= 1
       label_reference,
       retrieved_at,
       created_at
  from public.master_chemicals
 where registration_identity_key in
       ('AU:apvma:30462','AU:apvma:30467','AU:apvma:30476','AU:apvma:30582','AU:apvma:31393')
 order by registration_identity_key;

-- ===========================================================================
-- C. CANDIDATE GATE — no auto-approval anywhere in the pilot set. Expect 0 rows.
-- ===========================================================================
select registration_identity_key, review_status
  from public.master_chemicals
 where registration_identity_key in
       ('AU:apvma:30462','AU:apvma:30467','AU:apvma:30476','AU:apvma:30582','AU:apvma:31393')
   and (review_status <> 'candidate' or reviewed_by is not null or reviewed_at is not null);

-- ===========================================================================
-- D. NO DUPLICATES — identity is UNIQUE-constrained; prove it held. Expect 0 rows.
-- ===========================================================================
select registration_identity_key, count(*)
  from public.master_chemicals
 group by registration_identity_key
having count(*) > 1;

-- ===========================================================================
-- E. 91636 UNTOUCHED — compare with the Section A snapshot (same
--    review_status, catalogue_version AND updated_at).
-- ===========================================================================
select registration_identity_key, review_status, catalogue_version, updated_at
  from public.master_chemicals
 where registration_identity_key = 'AU:apvma:91636';

-- ===========================================================================
-- F. NO UNEXPECTED WRITES — rerun the Section A counts and compare:
--      master_rows           = baseline + <created count>   (expected +5)
--      master_version_rows   = baseline + <created count>   (insert-audit
--                              trigger from sql/199 — the designed write path)
--      saved_chemicals_rows  = baseline (unchanged)
--      spray_records_rows    = baseline (unchanged)
-- ===========================================================================
select
  (select count(*) from public.master_chemicals)          as master_rows,
  (select count(*) from public.master_chemical_versions)  as master_version_rows,
  (select count(*) from public.saved_chemicals)           as saved_chemicals_rows,
  (select count(*) from public.spray_records)             as spray_records_rows;

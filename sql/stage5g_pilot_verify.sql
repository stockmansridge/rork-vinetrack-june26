-- stage5g_pilot_verify.sql — Stage 5G 10-product PILOT verification.
-- READ-ONLY: every statement is a SELECT. Run in the Supabase SQL editor on
-- tbafuqwruefgkbyxrxyb (production).
--
-- Operator baseline before the pilot (Stage 5D/5F sign-off):
--   master_chemicals 198 | master_chemical_versions 198
--   saved_chemicals   35 | spray_records 10
--   AWRI-provenance rows 196 (master_rows − awri_rows = 2 pre-seed rows)
--
-- The pilot cohort (Stage 5F strongest-10, operator-approved):
--   AU:apvma:53987  Penncozeb 750DF          → PENNCOZEB 750 DF FUNGICIDE
--   AU:apvma:54522  Spraytop 250SL           → SPRAYTOP 250 SL HERBICIDE
--   AU:apvma:58831  Clash Storm Guard 720 SC → CONQUEST CLASH STORM GUARD 720 SC FUNGICIDE
--   AU:apvma:60560  Glister 680 SG           → GLISTER 680SG HERBICIDE
--   AU:apvma:63228  Hammer 400 EC            → HAMMER 400EC HERBICIDE
--   AU:apvma:67494  Fortuna Globe 750WG      → FORTUNA GLOBE 750 WG FUNGICIDE
--   AU:apvma:68458  Conan Sticks 720SC       → CONAN STICKS 720 SC FUNGICIDE
--   AU:apvma:81077  Cavalier 500SC           → CAVALIER 500 SC HERBICIDE
--   AU:apvma:83459  Fascinate 280SL          → Fascinate 280 SL Herbicide
--   AU:apvma:92506  Kobus 480SC              → Kobus 480 SC Insecticide
--
-- Every section uses this literal key list; nothing is parameterised.

-- ===========================================================================
-- A. RUN BEFORE THE PILOT — baseline snapshot.
--    Expect: 198 | 198 | 35 | 10, pilot_keys_present = 0.
--    RECORD baseline_max_updated_at — section E needs it verbatim.
-- ===========================================================================
select
  (select count(*) from public.master_chemicals)         as master_rows,          -- 198
  (select count(*) from public.master_chemical_versions) as master_version_rows,  -- 198
  (select count(*) from public.saved_chemicals)          as saved_chemicals_rows, -- 35
  (select count(*) from public.spray_records)            as spray_records_rows,   -- 10
  (select count(*) from public.master_chemicals
    where registration_identity_key in
      ('AU:apvma:53987','AU:apvma:54522','AU:apvma:58831','AU:apvma:60560',
       'AU:apvma:63228','AU:apvma:67494','AU:apvma:68458','AU:apvma:81077',
       'AU:apvma:83459','AU:apvma:92506'))                as pilot_keys_present,  -- 0
  (select max(updated_at) from public.master_chemicals)   as baseline_max_updated_at; -- RECORD THIS

-- ===========================================================================
-- B. RUN AFTER THE PILOT — table counts + unchanged PASS/FAIL.
--    Expect: master 208, versions 208, saved PASS, spray PASS.
-- ===========================================================================
select
  (select count(*) from public.master_chemicals)         as master_rows,          -- 208
  (select count(*) from public.master_chemical_versions) as master_version_rows,  -- 208
  case when (select count(*) from public.saved_chemicals) = 35
       then 'PASS' else 'FAIL' end                       as saved_chemicals_check,
  case when (select count(*) from public.spray_records) = 10
       then 'PASS' else 'FAIL' end                       as spray_records_check;

-- ===========================================================================
-- C. PILOT ROWS — one PASS/FAIL rollup over exactly the 10 cohort identities.
--    Every check must read PASS; pilot_rows must be 10.
-- ===========================================================================
with pilot as (
  select *
    from public.master_chemicals
   where registration_identity_key in
     ('AU:apvma:53987','AU:apvma:54522','AU:apvma:58831','AU:apvma:60560',
      'AU:apvma:63228','AU:apvma:67494','AU:apvma:68458','AU:apvma:81077',
      'AU:apvma:83459','AU:apvma:92506')
)
select
  (select count(*) from pilot)                                    as pilot_rows, -- 10
  case when not exists (select 1 from pilot where review_status <> 'candidate')
       then 'PASS' else 'FAIL' end                                as all_candidate,
  case when not exists (select 1 from pilot
                         where reviewed_by is not null or reviewed_at is not null)
       then 'PASS' else 'FAIL' end                                as no_auto_approval,
  case when not exists (select 1 from pilot where source_kind <> 'official_register')
       then 'PASS' else 'FAIL' end                                as all_official_register,
  case when not exists (select 1 from pilot where catalogue_version <> 1)
       then 'PASS' else 'FAIL' end                                as all_first_revision,
  case when not exists (
         select 1 from pilot p
          where (select count(*)
                   from jsonb_array_elements(coalesce(p.verification_sources, '[]'::jsonb)) s
                  where s->>'kind' = 'viticulture_reference') <> 1)
       then 'PASS' else 'FAIL' end                                as awri_provenance_each_row,
  case when not exists (
         select 1 from pilot p
          where not exists (
                select 1
                  from jsonb_array_elements(coalesce(p.verification_sources, '[]'::jsonb)) s
                 where s->>'kind' = 'official_register'))
       then 'PASS' else 'FAIL' end                                as apvma_evidence_each_row,
  case when not exists (
         select 1 from pilot p
          where (select count(*) from public.master_chemical_versions v
                  where v.master_chemical_id = p.id) <> 1)
       then 'PASS' else 'FAIL' end                                as one_version_row_each;

-- Pilot row detail — eyeball registered names/registrants against the list above.
select registration_identity_key, registered_product_name, registrant,
       review_status, source_kind, catalogue_version, created_at
  from public.master_chemicals
 where registration_identity_key in
   ('AU:apvma:53987','AU:apvma:54522','AU:apvma:58831','AU:apvma:60560',
    'AU:apvma:63228','AU:apvma:67494','AU:apvma:68458','AU:apvma:81077',
    'AU:apvma:83459','AU:apvma:92506')
 order by registration_identity_key;

-- ===========================================================================
-- D. NO DUPLICATE IDENTITIES — expect 0 rows.
-- ===========================================================================
select registration_identity_key, count(*)
  from public.master_chemicals
 group by registration_identity_key
having count(*) > 1;

-- ===========================================================================
-- E. EVERYTHING ELSE UNTOUCHED.
--    e1: non-pilot rows still 198. e2: substitute the RECORDED
--    baseline_max_updated_at from section A — expect 0 touched rows.
--    e3: AWRI-provenance invariant — master_rows − awri_rows = 2, and
--        awri_rows = 206 (196 batch + 10 pilot).
-- ===========================================================================
select count(*) as non_pilot_rows -- 198
  from public.master_chemicals
 where registration_identity_key not in
   ('AU:apvma:53987','AU:apvma:54522','AU:apvma:58831','AU:apvma:60560',
    'AU:apvma:63228','AU:apvma:67494','AU:apvma:68458','AU:apvma:81077',
    'AU:apvma:83459','AU:apvma:92506');

select count(*) as non_pilot_rows_touched -- 0
  from public.master_chemicals
 where registration_identity_key not in
   ('AU:apvma:53987','AU:apvma:54522','AU:apvma:58831','AU:apvma:60560',
    'AU:apvma:63228','AU:apvma:67494','AU:apvma:68458','AU:apvma:81077',
    'AU:apvma:83459','AU:apvma:92506')
   and updated_at > '<PASTE baseline_max_updated_at FROM SECTION A>';

select
  (select count(*) from public.master_chemicals) as master_rows, -- 208
  (select count(*)
     from public.master_chemicals m
    where exists (
            select 1
              from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) s
             where s->>'kind' = 'viticulture_reference'
               and s->>'reference' = 'https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf'
          ))                                      as awri_rows,   -- 206
  case when (select count(*) from public.master_chemicals)
          - (select count(*)
               from public.master_chemicals m
              where exists (
                      select 1
                        from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) s
                       where s->>'kind' = 'viticulture_reference'
                         and s->>'reference' = 'https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf'
                    )) = 2
       then 'PASS' else 'FAIL' end                as preseed_rows_invariant;

-- ===========================================================================
-- F. RUN AFTER THE IDEMPOTENCE RERUN (throwaway state, all 10 re-sent).
--    Expect IDENTICAL numbers to sections B/C: 208 | 208 | 35 | 10,
--    pilot rows still catalogue_version 1 with exactly one version row —
--    the rerun must have answered already_exists 10 times with zero writes.
-- ===========================================================================
select
  (select count(*) from public.master_chemicals)         as master_rows,          -- 208 (unchanged)
  (select count(*) from public.master_chemical_versions) as master_version_rows,  -- 208 (unchanged)
  (select count(*) from public.saved_chemicals)          as saved_chemicals_rows, -- 35
  (select count(*) from public.spray_records)            as spray_records_rows,   -- 10
  case when not exists (
         select 1 from public.master_chemicals p
          where p.registration_identity_key in
            ('AU:apvma:53987','AU:apvma:54522','AU:apvma:58831','AU:apvma:60560',
             'AU:apvma:63228','AU:apvma:67494','AU:apvma:68458','AU:apvma:81077',
             'AU:apvma:83459','AU:apvma:92506')
            and (p.catalogue_version <> 1
                 or (select count(*) from public.master_chemical_versions v
                      where v.master_chemical_id = p.id) <> 1))
       then 'PASS' else 'FAIL' end                       as rerun_wrote_nothing;

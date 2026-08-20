-- stage5g_pilot_verify.sql — Stage 5G 10-product PILOT verification (v2).
-- READ-ONLY: every statement is a SELECT. Nothing to edit, nothing to paste.
--
-- HOW TO RUN
--   Paste this ENTIRE file into the Supabase SQL editor on tbafuqwruefgkbyxrxyb
--   (production) and run it. The editor shows the LAST statement's result:
--   one verdict table with a row per check (expected | actual | status).
--
--   Run the same file three times, unchanged:
--     Run 1 — BEFORE the pilot.  stage = PRE-PILOT; counts PASS at
--             198 | 198 | 35 | 10, awri_provenance_rows 196, non_pilot_rows 198,
--             duplicate_identities PASS; pilot-dependent rows read PENDING.
--     Run 2 — AFTER the pilot.   stage = POST-PILOT; EVERY row must read PASS:
--             208 | 208 | 35 | 10, pilot_rows_present 10, awri_provenance_rows 206.
--     Run 3 — AFTER the idempotence rerun (throwaway state, all 10 re-sent).
--             Output must be IDENTICAL to Run 2 — the rerun answered
--             already_exists x 10 and wrote nothing.
--
--   The OPTIONAL DETAIL queries below can be run by selecting just that
--   query's text and running the selection.
--
-- The pilot cohort (Stage 5F strongest-10, operator-approved):
--   AU:apvma:53987  Penncozeb 750DF          -> PENNCOZEB 750 DF FUNGICIDE
--   AU:apvma:54522  Spraytop 250SL           -> SPRAYTOP 250 SL HERBICIDE
--   AU:apvma:58831  Clash Storm Guard 720 SC -> CONQUEST CLASH STORM GUARD 720 SC FUNGICIDE
--   AU:apvma:60560  Glister 680 SG           -> GLISTER 680SG HERBICIDE
--   AU:apvma:63228  Hammer 400 EC            -> HAMMER 400EC HERBICIDE
--   AU:apvma:67494  Fortuna Globe 750WG      -> FORTUNA GLOBE 750 WG FUNGICIDE
--   AU:apvma:68458  Conan Sticks 720SC       -> CONAN STICKS 720 SC FUNGICIDE
--   AU:apvma:81077  Cavalier 500SC           -> CAVALIER 500 SC HERBICIDE
--   AU:apvma:83459  Fascinate 280SL          -> Fascinate 280 SL Herbicide
--   AU:apvma:92506  Kobus 480SC              -> Kobus 480 SC Insecticide
--
-- Every query uses this literal key list; nothing is parameterised.
--
-- NOTE on non_pilot_rows_touched: instead of a hand-recorded baseline
-- timestamp, non-pilot rows are compared against the pilot's own earliest
-- insert time (min created_at of the 10 pilot rows). The seed surface is
-- insert-only, so any non-pilot Master row updated at/after that instant
-- means some OTHER writer touched the catalogue mid-pilot — investigate
-- before proceeding. Before the pilot runs this check reports PENDING.

-- ===========================================================================
-- OPTIONAL DETAIL 1 — pilot rows, one line each (0 rows before the pilot).
-- Eyeball registered names/registrants against the cohort list above, and
-- the per-row provenance/version counts (expect 1 | >=1 | 1 on every row).
-- ===========================================================================
select
  m.registration_identity_key,
  m.registered_product_name,
  m.registrant,
  m.review_status,
  m.source_kind,
  m.catalogue_version,
  m.created_at,
  (select count(*)
     from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) src
    where src->>'kind' = 'viticulture_reference')                as awri_sources,     -- 1
  (select count(*)
     from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) src
    where src->>'kind' = 'official_register')                    as register_sources, -- >= 1
  (select count(*) from public.master_chemical_versions v
    where v.master_chemical_id = m.id)                           as version_rows      -- 1
  from public.master_chemicals m
 where m.registration_identity_key in
   ('AU:apvma:53987','AU:apvma:54522','AU:apvma:58831','AU:apvma:60560',
    'AU:apvma:63228','AU:apvma:67494','AU:apvma:68458','AU:apvma:81077',
    'AU:apvma:83459','AU:apvma:92506')
 order by m.registration_identity_key;

-- ===========================================================================
-- OPTIONAL DETAIL 2 — duplicate identity listing (expect 0 rows, always).
-- ===========================================================================
select registration_identity_key, count(*) as row_count
  from public.master_chemicals
 group by registration_identity_key
having count(*) > 1
 order by registration_identity_key;

-- ===========================================================================
-- VERDICT — the last statement, so this is what the editor displays.
-- Every row must read PASS after the pilot; PENDING rows are expected
-- only on the pre-pilot baseline run.
-- ===========================================================================
with pilot as (
  select
    m.*,
    (select count(*)
       from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) src
      where src->>'kind' = 'viticulture_reference') as awri_source_count,
    (select count(*)
       from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) src
      where src->>'kind' = 'official_register')     as register_source_count,
    (select count(*) from public.master_chemical_versions v
      where v.master_chemical_id = m.id)            as version_row_count
    from public.master_chemicals m
   where m.registration_identity_key in
     ('AU:apvma:53987','AU:apvma:54522','AU:apvma:58831','AU:apvma:60560',
      'AU:apvma:63228','AU:apvma:67494','AU:apvma:68458','AU:apvma:81077',
      'AU:apvma:83459','AU:apvma:92506')
),
snapshot as (
  select
    (select count(*) from public.master_chemicals)         as master_rows,
    (select count(*) from public.master_chemical_versions) as version_rows,
    (select count(*) from public.saved_chemicals)          as saved_rows,
    (select count(*) from public.spray_records)            as spray_rows,
    (select count(*) from pilot)                           as pilot_rows,
    (select min(created_at) from pilot)                    as pilot_started_at,
    (select count(*) from pilot
      where review_status <> 'candidate')                  as not_candidate,
    (select count(*) from pilot
      where reviewed_by is not null
         or reviewed_at is not null)                       as auto_approved,
    (select count(*) from pilot
      where source_kind <> 'official_register')            as wrong_source_kind,
    (select count(*) from pilot
      where catalogue_version <> 1)                        as not_first_revision,
    (select count(*) from pilot
      where awri_source_count <> 1)                        as bad_awri_provenance,
    (select count(*) from pilot
      where register_source_count = 0)                     as missing_register_evidence,
    (select count(*) from pilot
      where version_row_count <> 1)                        as bad_version_count,
    (select count(*) from (
        select registration_identity_key
          from public.master_chemicals
         group by registration_identity_key
        having count(*) > 1) dup)                          as duplicate_identities,
    (select count(*) from public.master_chemicals
      where registration_identity_key not in
        ('AU:apvma:53987','AU:apvma:54522','AU:apvma:58831','AU:apvma:60560',
         'AU:apvma:63228','AU:apvma:67494','AU:apvma:68458','AU:apvma:81077',
         'AU:apvma:83459','AU:apvma:92506'))               as non_pilot_rows,
    (select count(*) from public.master_chemicals m
      where m.registration_identity_key not in
        ('AU:apvma:53987','AU:apvma:54522','AU:apvma:58831','AU:apvma:60560',
         'AU:apvma:63228','AU:apvma:67494','AU:apvma:68458','AU:apvma:81077',
         'AU:apvma:83459','AU:apvma:92506')
        and m.updated_at >= (select min(created_at) from pilot)) as non_pilot_rows_touched,
    (select count(*) from public.master_chemicals m
      where exists (
              select 1
                from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) src
               where src->>'kind' = 'viticulture_reference'
                 and src->>'reference' = 'https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf'
            ))                                             as awri_rows
)
select ord, section, check_name, expected, actual, status
  from (
    select 1 as ord, 'A' as section, 'stage' as check_name,
           'PRE-PILOT (0/10) or POST-PILOT (10/10)' as expected,
           case when s.pilot_rows = 0  then 'PRE-PILOT — pilot not applied yet'
                when s.pilot_rows = 10 then 'POST-PILOT — all 10 present'
                else 'PARTIAL — ' || s.pilot_rows::text || ' of 10 present' end as actual,
           case when s.pilot_rows in (0, 10) then 'PASS' else 'FAIL' end as status
      from snapshot s
    union all
    select 2, 'B', 'master_rows',
           (198 + s.pilot_rows)::text, s.master_rows::text,
           case when s.master_rows = 198 + s.pilot_rows then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 3, 'B', 'master_version_rows',
           (198 + s.pilot_rows)::text, s.version_rows::text,
           case when s.version_rows = 198 + s.pilot_rows then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 4, 'B', 'saved_chemicals_rows',
           '35', s.saved_rows::text,
           case when s.saved_rows = 35 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 5, 'B', 'spray_records_rows',
           '10', s.spray_rows::text,
           case when s.spray_rows = 10 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 6, 'C', 'pilot_rows_present',
           '0 before, 10 after', s.pilot_rows::text,
           case when s.pilot_rows in (0, 10) then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 7, 'C', 'pilot_first_insert_at',
           'informational',
           coalesce(s.pilot_started_at::text, '— (pilot not applied)'),
           'INFO'
      from snapshot s
    union all
    select 8, 'C', 'all_candidate',
           '0 deviations', s.not_candidate::text,
           case when s.pilot_rows = 0 then 'PENDING'
                when s.not_candidate = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 9, 'C', 'no_auto_approval',
           '0 reviewed rows', s.auto_approved::text,
           case when s.pilot_rows = 0 then 'PENDING'
                when s.auto_approved = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 10, 'C', 'all_official_register',
           '0 deviations', s.wrong_source_kind::text,
           case when s.pilot_rows = 0 then 'PENDING'
                when s.wrong_source_kind = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 11, 'C', 'all_first_revision',
           '0 deviations', s.not_first_revision::text,
           case when s.pilot_rows = 0 then 'PENDING'
                when s.not_first_revision = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 12, 'C', 'awri_provenance_each_row',
           '0 deviations (exactly 1 each)', s.bad_awri_provenance::text,
           case when s.pilot_rows = 0 then 'PENDING'
                when s.bad_awri_provenance = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 13, 'C', 'apvma_evidence_each_row',
           '0 rows missing evidence', s.missing_register_evidence::text,
           case when s.pilot_rows = 0 then 'PENDING'
                when s.missing_register_evidence = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 14, 'C', 'one_version_row_each',
           '0 deviations', s.bad_version_count::text,
           case when s.pilot_rows = 0 then 'PENDING'
                when s.bad_version_count = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 15, 'D', 'duplicate_identities',
           '0', s.duplicate_identities::text,
           case when s.duplicate_identities = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 16, 'E', 'non_pilot_rows',
           '198', s.non_pilot_rows::text,
           case when s.non_pilot_rows = 198 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 17, 'E', 'non_pilot_rows_touched',
           '0 (vs pilot_first_insert_at)', s.non_pilot_rows_touched::text,
           case when s.pilot_rows = 0 then 'PENDING'
                when s.non_pilot_rows_touched = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 18, 'E', 'awri_provenance_rows',
           (196 + s.pilot_rows)::text, s.awri_rows::text,
           case when s.awri_rows = 196 + s.pilot_rows then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 19, 'E', 'preseed_rows_invariant',
           '2 (master_rows - awri_rows)', (s.master_rows - s.awri_rows)::text,
           case when s.master_rows - s.awri_rows = 2 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 20, 'F', 'rerun_wrote_nothing',
           'Run 3 identical to Run 2',
           s.master_rows::text || '|' || s.version_rows::text
             || ' · rev-1 deviations ' || s.not_first_revision::text
             || ' · extra version rows ' || s.bad_version_count::text,
           case when s.pilot_rows = 0 then 'PENDING'
                when s.master_rows = 208 and s.version_rows = 208
                 and s.not_first_revision = 0 and s.bad_version_count = 0
                then 'PASS' else 'FAIL' end
      from snapshot s
  ) verdict
 order by ord;

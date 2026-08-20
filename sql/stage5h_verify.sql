-- stage5h_verify.sql — Stage 5H remaining-169 batch verification.
-- READ-ONLY: every statement is a SELECT. Nothing to edit, nothing to paste.
--
-- HOW TO RUN
--   Paste this ENTIRE file into the Supabase SQL editor on tbafuqwruefgkbyxrxyb
--   (production) and run it. The editor shows the LAST statement's result:
--   one verdict table with a row per check (expected | actual | status).
--
--   Run the same file three times, unchanged:
--     Run 1 — BEFORE the batch.  stage = PRE-STAGE5H; counts PASS at
--             208 | 208 | 35 | 10, awri_provenance_rows 206,
--             non_stage5h_rows 208, stage5g_pilot_rows_present 10,
--             duplicate_identities PASS; batch-dependent rows read PENDING.
--     Run 2 — AFTER the batch.   stage = POST-STAGE5H; EVERY row must read
--             PASS: 377 | 377 | 35 | 10, stage5h_rows_present 169,
--             awri_provenance_rows 375.
--     Run 3 — AFTER the idempotence rerun (throwaway state, all 169 re-sent).
--             Output must be IDENTICAL to Run 2 — the rerun answered
--             already_exists x 169 and wrote nothing.
--
--   The OPTIONAL DETAIL queries below can be run by selecting just that
--   query's text and running the selection.
--
-- THE COHORT: the 169 identity keys embedded below are DERIVED from the
-- operator-approved Stage 5F audit artifact (seeds/awri_dogbook_2026_27
-- .audit.json): all 179 approve_for_seed identities MINUS the 10 already
-- applied and production-verified in Stage 5G. The 2 rejected duplicate
-- aliases, 162 probable, 87 ambiguous and 38 no-match names are absent.
--
-- NOTE on non_stage5h_rows_touched: non-batch rows are compared against the
-- batch's own earliest insert time (min created_at of the stage5h rows). The
-- seed surface is insert-only, so any non-batch Master row updated at/after
-- that instant means some OTHER writer touched the catalogue mid-batch
-- (including operator review actions) — investigate before proceeding.
-- Run verification BEFORE reviewing any of the new candidates.

-- ===========================================================================
-- OPTIONAL DETAIL 1 — stage 5H rows, one line each (0 rows before the batch).
-- Eyeball registered names/registrants, and the per-row provenance/version
-- counts (expect 1 | >=1 | 1 on every row).
-- ===========================================================================
with stage5h_keys(identity_key) as (
  values
    ('AU:apvma:42105'), ('AU:apvma:49333'), ('AU:apvma:50312'), ('AU:apvma:50883'),
    ('AU:apvma:52141'), ('AU:apvma:52518'), ('AU:apvma:52680'), ('AU:apvma:52710'),
    ('AU:apvma:53131'), ('AU:apvma:53576'), ('AU:apvma:53613'), ('AU:apvma:53935'),
    ('AU:apvma:54080'), ('AU:apvma:56421'), ('AU:apvma:56720'), ('AU:apvma:56798'),
    ('AU:apvma:56826'), ('AU:apvma:56857'), ('AU:apvma:56975'), ('AU:apvma:57039'),
    ('AU:apvma:57817'), ('AU:apvma:58470'), ('AU:apvma:58732'), ('AU:apvma:58733'),
    ('AU:apvma:58835'), ('AU:apvma:58989'), ('AU:apvma:59897'), ('AU:apvma:60603'),
    ('AU:apvma:60687'), ('AU:apvma:61016'), ('AU:apvma:61278'), ('AU:apvma:61792'),
    ('AU:apvma:61820'), ('AU:apvma:61860'), ('AU:apvma:62349'), ('AU:apvma:62489'),
    ('AU:apvma:62723'), ('AU:apvma:62787'), ('AU:apvma:63727'), ('AU:apvma:63821'),
    ('AU:apvma:64216'), ('AU:apvma:64295'), ('AU:apvma:64296'), ('AU:apvma:64303'),
    ('AU:apvma:64323'), ('AU:apvma:64325'), ('AU:apvma:64334'), ('AU:apvma:64362'),
    ('AU:apvma:64444'), ('AU:apvma:64558'), ('AU:apvma:64710'), ('AU:apvma:64932'),
    ('AU:apvma:65082'), ('AU:apvma:65245'), ('AU:apvma:65494'), ('AU:apvma:65676'),
    ('AU:apvma:65743'), ('AU:apvma:65774'), ('AU:apvma:65807'), ('AU:apvma:65842'),
    ('AU:apvma:65924'), ('AU:apvma:66599'), ('AU:apvma:66687'), ('AU:apvma:66703'),
    ('AU:apvma:67384'), ('AU:apvma:67467'), ('AU:apvma:67554'), ('AU:apvma:68003'),
    ('AU:apvma:68210'), ('AU:apvma:68604'), ('AU:apvma:68607'), ('AU:apvma:68776'),
    ('AU:apvma:68856'), ('AU:apvma:68941'), ('AU:apvma:68987'), ('AU:apvma:69283'),
    ('AU:apvma:69322'), ('AU:apvma:69351'), ('AU:apvma:69359'), ('AU:apvma:69450'),
    ('AU:apvma:69621'), ('AU:apvma:69686'), ('AU:apvma:69705'), ('AU:apvma:69725'),
    ('AU:apvma:69727'), ('AU:apvma:69745'), ('AU:apvma:69885'), ('AU:apvma:69946'),
    ('AU:apvma:70081'), ('AU:apvma:70118'), ('AU:apvma:70132'), ('AU:apvma:70143'),
    ('AU:apvma:70284'), ('AU:apvma:70372'), ('AU:apvma:70433'), ('AU:apvma:80006'),
    ('AU:apvma:81615'), ('AU:apvma:82003'), ('AU:apvma:82495'), ('AU:apvma:82626'),
    ('AU:apvma:83625'), ('AU:apvma:83859'), ('AU:apvma:84047'), ('AU:apvma:84786'),
    ('AU:apvma:85062'), ('AU:apvma:85084'), ('AU:apvma:85582'), ('AU:apvma:86250'),
    ('AU:apvma:86761'), ('AU:apvma:87040'), ('AU:apvma:87191'), ('AU:apvma:87259'),
    ('AU:apvma:87475'), ('AU:apvma:87790'), ('AU:apvma:87896'), ('AU:apvma:88309'),
    ('AU:apvma:88400'), ('AU:apvma:88549'), ('AU:apvma:88617'), ('AU:apvma:88780'),
    ('AU:apvma:88958'), ('AU:apvma:89257'), ('AU:apvma:89484'), ('AU:apvma:89666'),
    ('AU:apvma:89688'), ('AU:apvma:89862'), ('AU:apvma:89988'), ('AU:apvma:90143'),
    ('AU:apvma:90155'), ('AU:apvma:90172'), ('AU:apvma:90184'), ('AU:apvma:90186'),
    ('AU:apvma:90198'), ('AU:apvma:90260'), ('AU:apvma:90279'), ('AU:apvma:90283'),
    ('AU:apvma:90294'), ('AU:apvma:90305'), ('AU:apvma:90309'), ('AU:apvma:90335'),
    ('AU:apvma:90436'), ('AU:apvma:90442'), ('AU:apvma:90455'), ('AU:apvma:90525'),
    ('AU:apvma:90733'), ('AU:apvma:90750'), ('AU:apvma:90794'), ('AU:apvma:90822'),
    ('AU:apvma:91516'), ('AU:apvma:91573'), ('AU:apvma:91705'), ('AU:apvma:91845'),
    ('AU:apvma:92058'), ('AU:apvma:92373'), ('AU:apvma:92411'), ('AU:apvma:93031'),
    ('AU:apvma:93240'), ('AU:apvma:93445'), ('AU:apvma:93616'), ('AU:apvma:93697'),
    ('AU:apvma:93953'), ('AU:apvma:93991'), ('AU:apvma:94311'), ('AU:apvma:94330'),
    ('AU:apvma:94994'), ('AU:apvma:95157'), ('AU:apvma:95207'), ('AU:apvma:95307'),
    ('AU:apvma:95491')
)
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
 where m.registration_identity_key in (select identity_key from stage5h_keys)
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
-- Every row must read PASS after the batch; PENDING rows are expected
-- only on the pre-batch baseline run.
-- ===========================================================================
with stage5h_keys(identity_key) as (
  values
    ('AU:apvma:42105'), ('AU:apvma:49333'), ('AU:apvma:50312'), ('AU:apvma:50883'),
    ('AU:apvma:52141'), ('AU:apvma:52518'), ('AU:apvma:52680'), ('AU:apvma:52710'),
    ('AU:apvma:53131'), ('AU:apvma:53576'), ('AU:apvma:53613'), ('AU:apvma:53935'),
    ('AU:apvma:54080'), ('AU:apvma:56421'), ('AU:apvma:56720'), ('AU:apvma:56798'),
    ('AU:apvma:56826'), ('AU:apvma:56857'), ('AU:apvma:56975'), ('AU:apvma:57039'),
    ('AU:apvma:57817'), ('AU:apvma:58470'), ('AU:apvma:58732'), ('AU:apvma:58733'),
    ('AU:apvma:58835'), ('AU:apvma:58989'), ('AU:apvma:59897'), ('AU:apvma:60603'),
    ('AU:apvma:60687'), ('AU:apvma:61016'), ('AU:apvma:61278'), ('AU:apvma:61792'),
    ('AU:apvma:61820'), ('AU:apvma:61860'), ('AU:apvma:62349'), ('AU:apvma:62489'),
    ('AU:apvma:62723'), ('AU:apvma:62787'), ('AU:apvma:63727'), ('AU:apvma:63821'),
    ('AU:apvma:64216'), ('AU:apvma:64295'), ('AU:apvma:64296'), ('AU:apvma:64303'),
    ('AU:apvma:64323'), ('AU:apvma:64325'), ('AU:apvma:64334'), ('AU:apvma:64362'),
    ('AU:apvma:64444'), ('AU:apvma:64558'), ('AU:apvma:64710'), ('AU:apvma:64932'),
    ('AU:apvma:65082'), ('AU:apvma:65245'), ('AU:apvma:65494'), ('AU:apvma:65676'),
    ('AU:apvma:65743'), ('AU:apvma:65774'), ('AU:apvma:65807'), ('AU:apvma:65842'),
    ('AU:apvma:65924'), ('AU:apvma:66599'), ('AU:apvma:66687'), ('AU:apvma:66703'),
    ('AU:apvma:67384'), ('AU:apvma:67467'), ('AU:apvma:67554'), ('AU:apvma:68003'),
    ('AU:apvma:68210'), ('AU:apvma:68604'), ('AU:apvma:68607'), ('AU:apvma:68776'),
    ('AU:apvma:68856'), ('AU:apvma:68941'), ('AU:apvma:68987'), ('AU:apvma:69283'),
    ('AU:apvma:69322'), ('AU:apvma:69351'), ('AU:apvma:69359'), ('AU:apvma:69450'),
    ('AU:apvma:69621'), ('AU:apvma:69686'), ('AU:apvma:69705'), ('AU:apvma:69725'),
    ('AU:apvma:69727'), ('AU:apvma:69745'), ('AU:apvma:69885'), ('AU:apvma:69946'),
    ('AU:apvma:70081'), ('AU:apvma:70118'), ('AU:apvma:70132'), ('AU:apvma:70143'),
    ('AU:apvma:70284'), ('AU:apvma:70372'), ('AU:apvma:70433'), ('AU:apvma:80006'),
    ('AU:apvma:81615'), ('AU:apvma:82003'), ('AU:apvma:82495'), ('AU:apvma:82626'),
    ('AU:apvma:83625'), ('AU:apvma:83859'), ('AU:apvma:84047'), ('AU:apvma:84786'),
    ('AU:apvma:85062'), ('AU:apvma:85084'), ('AU:apvma:85582'), ('AU:apvma:86250'),
    ('AU:apvma:86761'), ('AU:apvma:87040'), ('AU:apvma:87191'), ('AU:apvma:87259'),
    ('AU:apvma:87475'), ('AU:apvma:87790'), ('AU:apvma:87896'), ('AU:apvma:88309'),
    ('AU:apvma:88400'), ('AU:apvma:88549'), ('AU:apvma:88617'), ('AU:apvma:88780'),
    ('AU:apvma:88958'), ('AU:apvma:89257'), ('AU:apvma:89484'), ('AU:apvma:89666'),
    ('AU:apvma:89688'), ('AU:apvma:89862'), ('AU:apvma:89988'), ('AU:apvma:90143'),
    ('AU:apvma:90155'), ('AU:apvma:90172'), ('AU:apvma:90184'), ('AU:apvma:90186'),
    ('AU:apvma:90198'), ('AU:apvma:90260'), ('AU:apvma:90279'), ('AU:apvma:90283'),
    ('AU:apvma:90294'), ('AU:apvma:90305'), ('AU:apvma:90309'), ('AU:apvma:90335'),
    ('AU:apvma:90436'), ('AU:apvma:90442'), ('AU:apvma:90455'), ('AU:apvma:90525'),
    ('AU:apvma:90733'), ('AU:apvma:90750'), ('AU:apvma:90794'), ('AU:apvma:90822'),
    ('AU:apvma:91516'), ('AU:apvma:91573'), ('AU:apvma:91705'), ('AU:apvma:91845'),
    ('AU:apvma:92058'), ('AU:apvma:92373'), ('AU:apvma:92411'), ('AU:apvma:93031'),
    ('AU:apvma:93240'), ('AU:apvma:93445'), ('AU:apvma:93616'), ('AU:apvma:93697'),
    ('AU:apvma:93953'), ('AU:apvma:93991'), ('AU:apvma:94311'), ('AU:apvma:94330'),
    ('AU:apvma:94994'), ('AU:apvma:95157'), ('AU:apvma:95207'), ('AU:apvma:95307'),
    ('AU:apvma:95491')
),
stage5h as (
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
   where m.registration_identity_key in (select identity_key from stage5h_keys)
),
snapshot as (
  select
    (select count(*) from public.master_chemicals)         as master_rows,
    (select count(*) from public.master_chemical_versions) as version_rows,
    (select count(*) from public.saved_chemicals)          as saved_rows,
    (select count(*) from public.spray_records)            as spray_rows,
    (select count(*) from stage5h)                         as s5h_rows,
    (select min(created_at) from stage5h)                  as s5h_started_at,
    (select count(*) from stage5h
      where review_status <> 'candidate')                  as not_candidate,
    (select count(*) from stage5h
      where reviewed_by is not null
         or reviewed_at is not null)                       as auto_approved,
    (select count(*) from stage5h
      where source_kind <> 'official_register')            as wrong_source_kind,
    (select count(*) from stage5h
      where catalogue_version <> 1)                        as not_first_revision,
    (select count(*) from stage5h
      where awri_source_count <> 1)                        as bad_awri_provenance,
    (select count(*) from stage5h
      where register_source_count = 0)                     as missing_register_evidence,
    (select count(*) from stage5h
      where version_row_count <> 1)                        as bad_version_count,
    (select count(*) from (
        select registration_identity_key
          from public.master_chemicals
         group by registration_identity_key
        having count(*) > 1) dup)                          as duplicate_identities,
    (select count(*) from public.master_chemicals m
      where m.registration_identity_key not in
        (select identity_key from stage5h_keys))           as non_s5h_rows,
    (select count(*) from public.master_chemicals m
      where m.registration_identity_key not in
        (select identity_key from stage5h_keys)
        and m.updated_at >= (select min(created_at) from stage5h)) as non_s5h_rows_touched,
    (select count(*) from public.master_chemicals m
      where exists (
              select 1
                from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) src
               where src->>'kind' = 'viticulture_reference'
                 and src->>'reference' = 'https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf'
            ))                                             as awri_rows,
    (select count(*) from public.master_chemicals
      where registration_identity_key in
        ('AU:apvma:53987','AU:apvma:54522','AU:apvma:58831','AU:apvma:60560',
         'AU:apvma:63228','AU:apvma:67494','AU:apvma:68458','AU:apvma:81077',
         'AU:apvma:83459','AU:apvma:92506'))               as pilot_rows_present
)
select ord, section, check_name, expected, actual, status
  from (
    select 1 as ord, 'A' as section, 'stage' as check_name,
           'PRE-STAGE5H (0/169) or POST-STAGE5H (169/169)' as expected,
           case when s.s5h_rows = 0   then 'PRE-STAGE5H — batch not applied yet'
                when s.s5h_rows = 169 then 'POST-STAGE5H — all 169 present'
                else 'PARTIAL — ' || s.s5h_rows::text || ' of 169 present' end as actual,
           case when s.s5h_rows in (0, 169) then 'PASS' else 'FAIL' end as status
      from snapshot s
    union all
    select 2, 'B', 'master_rows',
           (208 + s.s5h_rows)::text, s.master_rows::text,
           case when s.master_rows = 208 + s.s5h_rows then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 3, 'B', 'master_version_rows',
           (208 + s.s5h_rows)::text, s.version_rows::text,
           case when s.version_rows = 208 + s.s5h_rows then 'PASS' else 'FAIL' end
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
    select 6, 'C', 'stage5h_rows_present',
           '0 before, 169 after', s.s5h_rows::text,
           case when s.s5h_rows in (0, 169) then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 7, 'C', 'stage5h_first_insert_at',
           'informational',
           coalesce(s.s5h_started_at::text, '— (batch not applied)'),
           'INFO'
      from snapshot s
    union all
    select 8, 'C', 'all_candidate',
           '0 deviations', s.not_candidate::text,
           case when s.s5h_rows = 0 then 'PENDING'
                when s.not_candidate = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 9, 'C', 'no_auto_approval',
           '0 reviewed rows', s.auto_approved::text,
           case when s.s5h_rows = 0 then 'PENDING'
                when s.auto_approved = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 10, 'C', 'all_official_register',
           '0 deviations', s.wrong_source_kind::text,
           case when s.s5h_rows = 0 then 'PENDING'
                when s.wrong_source_kind = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 11, 'C', 'all_first_revision',
           '0 deviations', s.not_first_revision::text,
           case when s.s5h_rows = 0 then 'PENDING'
                when s.not_first_revision = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 12, 'C', 'awri_provenance_each_row',
           '0 deviations (exactly 1 each)', s.bad_awri_provenance::text,
           case when s.s5h_rows = 0 then 'PENDING'
                when s.bad_awri_provenance = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 13, 'C', 'apvma_evidence_each_row',
           '0 rows missing evidence', s.missing_register_evidence::text,
           case when s.s5h_rows = 0 then 'PENDING'
                when s.missing_register_evidence = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 14, 'C', 'one_version_row_each',
           '0 deviations', s.bad_version_count::text,
           case when s.s5h_rows = 0 then 'PENDING'
                when s.bad_version_count = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 15, 'D', 'duplicate_identities',
           '0', s.duplicate_identities::text,
           case when s.duplicate_identities = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 16, 'E', 'non_stage5h_rows',
           '208', s.non_s5h_rows::text,
           case when s.non_s5h_rows = 208 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 17, 'E', 'non_stage5h_rows_touched',
           '0 (vs stage5h_first_insert_at)', s.non_s5h_rows_touched::text,
           case when s.s5h_rows = 0 then 'PENDING'
                when s.non_s5h_rows_touched = 0 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 18, 'E', 'awri_provenance_rows',
           (206 + s.s5h_rows)::text, s.awri_rows::text,
           case when s.awri_rows = 206 + s.s5h_rows then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 19, 'E', 'preseed_rows_invariant',
           '2 (master_rows - awri_rows)', (s.master_rows - s.awri_rows)::text,
           case when s.master_rows - s.awri_rows = 2 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 20, 'E', 'stage5g_pilot_rows_present',
           '10', s.pilot_rows_present::text,
           case when s.pilot_rows_present = 10 then 'PASS' else 'FAIL' end
      from snapshot s
    union all
    select 21, 'F', 'rerun_wrote_nothing',
           'Run 3 identical to Run 2',
           s.master_rows::text || '|' || s.version_rows::text
             || ' · rev-1 deviations ' || s.not_first_revision::text
             || ' · extra version rows ' || s.bad_version_count::text,
           case when s.s5h_rows = 0 then 'PENDING'
                when s.master_rows = 377 and s.version_rows = 377
                 and s.not_first_revision = 0 and s.bad_version_count = 0
                then 'PASS' else 'FAIL' end
      from snapshot s
  ) verdict
 order by ord;

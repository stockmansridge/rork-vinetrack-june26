-- 194: Chemical Intelligence foundation.
--
-- Establishes structured, country-aware, verification-aware chemical data so
-- that future resistance calculations never depend on parsing the uncontrolled
-- free-text `saved_chemicals.chemical_group` column ("3 + 11", "Strobilurin",
-- "Group 3/11", ...).
--
-- WHAT THIS REPLACES CONCEPTUALLY
--   Before: chemical_group text = '3 + 11'         (one opaque string)
--   After:  active_ingredients jsonb              (Tebuconazole 200 g/L -> FRAC 3,
--                                                  Azoxystrobin 120 g/L -> FRAC 11)
--           activity_groups   text[] = {'3','11'} (queryable, one entry PER GROUP)
--
--   A mixture counts as Group 3 AND Group 11 independently. `chemical_group`
--   is retained and becomes a DERIVED display projection of `activity_groups`.
--
-- SAFETY CONTRACT
--   * Purely ADDITIVE. No existing column is dropped, renamed, retyped or
--     backfilled with inferred data.
--   * Every new column is nullable or defaulted, so existing rows remain valid
--     and older app builds that never SELECT these columns keep working.
--   * Completed historical spray records are NOT touched. Their resistance
--     snapshot lives additively inside the existing `spray_records.tanks`
--     JSONB (see "SPRAY LINE SNAPSHOT" below) and needs no DDL.
--   * NO value is inferred for existing chemicals. A pre-existing chemical
--     gets `verification_status = 'needs_match'` and NOTHING else — its
--     actives and groups stay null until a human matches it. Deriving groups
--     from the legacy string here would launder a guess into the database.
--   * Idempotent; single transaction.
--
-- CHECK CONSTRAINTS
--   `verification_status` gets a CHECK: small, stable, closed vocabulary that
--   the whole trust model depends on.
--   `activity_groups` gets NO value CHECK: the FRAC/HRAC/IRAC code vocabulary
--   expands every year (new SDHI codes, new HRAC letters). The typed enum in
--   the app is the enforcement point, exactly as with sql/193 `targets`.
--
-- SPRAY LINE SNAPSHOT (no DDL required)
--   Each chemical line inside `spray_records.tanks` / `spray_jobs.tanks` gains
--   an optional `chemicalSnapshot` object:
--     { "active_ingredients": [...], "activity_groups": ["3","11"],
--       "verification_status": "verified", "registration_identity_key": "AU:apvma:62764",
--       "country_code": "AU", "schema_version": 1,
--       "activity_group_table_version": 1, "legacy_chemical_group": "3 + 11",
--       "captured_at": "2026-08-15T00:00:00Z" }
--   Historical resistance analysis reads THAT, never the current chemical, so
--   correcting a product in three years cannot restate what was applied today.

begin;

-- ---------------------------------------------------------------------------
-- 1. Structured chemical intelligence on saved_chemicals
-- ---------------------------------------------------------------------------

alter table public.saved_chemicals
  -- Array of { name, concentration, concentration_unit,
  --            activity_group: { scheme, code, common_name },
  --            group_source, identity_source }.
  -- A product may have MANY actives; each active owns exactly one group.
  add column if not exists active_ingredients jsonb,

  -- Derived, queryable projection of every active's group code: {'3','11'}.
  -- NEVER {'3 + 11'}. This is the column the future Resistance Engine and all
  -- audit reporting read. Kept in lock-step with `active_ingredients` by the
  -- app on write.
  add column if not exists activity_groups text[],

  -- Which classification scheme the codes belong to: 'frac' | 'hrac' | 'irac'
  -- | 'not_applicable'. A bare '3' is ambiguous — FRAC 3 (DMI fungicide) and
  -- IRAC 3 (pyrethroid) are unrelated chemistries.
  add column if not exists activity_group_scheme text,

  -- Country-scoped registered identity. An AU product and an NZ product with
  -- the same brand name are DIFFERENT identities with different labels and
  -- rates, so country is part of the key, not a display detail.
  add column if not exists registration_country text,
  add column if not exists registration_scheme text,
  add column if not exists registration_number text,
  add column if not exists registrant text,
  add column if not exists registered_product_name text,
  add column if not exists label_reference text,
  add column if not exists label_version text,

  -- Verification state. Deliberately separate from "the AI returned something":
  -- an AI hit is a lead, never a verification.
  add column if not exists verification_status text not null default 'unverified',
  add column if not exists verification_sources jsonb,
  -- Unresolved source disagreements. Non-empty MUST force status 'conflict';
  -- the app treats a conflicted product as undependable regardless of what
  -- status happens to be stored.
  add column if not exists verification_conflicts jsonb,
  -- Fields the lookup explicitly could not resolve, named so the UI shows what
  -- is missing rather than an unexplained blank.
  add column if not exists verification_unresolved_fields text[],
  add column if not exists verified_at timestamptz,

  -- Registered crop + target + label rate/use, structured.
  -- "Group 11 therefore powdery mildew" is an assumption, not a registered
  -- use; the future engine needs the target the label actually names.
  add column if not exists registered_uses jsonb,

  -- Distinct LABEL rate bases across the registered uses:
  -- 'per_100_litres' | 'per_hectare' | 'range_per_100_litres' |
  -- 'range_per_hectare' | 'other'.
  --
  -- Independent of the spray CARRIER volume basis (sql/192). An NZ vineyard
  -- measuring carrier in L/100 m still applies a product whose label says
  -- 1.5 L/ha. This column lets the Guided Spray workflow PROPOSE the right
  -- product rate bases instead of making the operator guess.
  add column if not exists label_rate_bases text[],

  -- Version of the app-side FRAC/HRAC/IRAC reference table that classified
  -- this row, so a future re-verification can tell which revision judged it.
  add column if not exists activity_group_table_version integer,
  -- Version of the chemical intelligence payload contract.
  add column if not exists intelligence_schema_version integer not null default 0;

-- Verification status: closed, stable vocabulary — safe to constrain.
do $$
begin
  alter table public.saved_chemicals
    add constraint saved_chemicals_verification_status_check
    check (verification_status in (
      'verified', 'partially_verified', 'unverified', 'needs_match', 'conflict'
    ));
exception
  when duplicate_object then null;
end $$;

-- Classification scheme: also a closed vocabulary.
do $$
begin
  alter table public.saved_chemicals
    add constraint saved_chemicals_activity_group_scheme_check
    check (activity_group_scheme is null or activity_group_scheme in (
      'frac', 'hrac', 'irac', 'not_applicable'
    ));
exception
  when duplicate_object then null;
end $$;

-- Registration scheme: closed vocabulary, extensible via 'other'.
do $$
begin
  alter table public.saved_chemicals
    add constraint saved_chemicals_registration_scheme_check
    check (registration_scheme is null or registration_scheme in (
      'apvma', 'acvm', 'nz_epa', 'other'
    ));
exception
  when duplicate_object then null;
end $$;

-- NOTE: deliberately NO check constraint on `activity_groups` values. The
-- resistance code vocabulary grows (new SDHI/HRAC codes are published
-- annually) and a database CHECK would reject valid future chemistry. The
-- typed enum in iOS/Android is the enforcement point.

-- ---------------------------------------------------------------------------
-- 2. Indexes for the Resistance Engine and the audit
-- ---------------------------------------------------------------------------

-- "Which of my chemicals are Group 11?" — the core resistance question.
create index if not exists idx_saved_chemicals_activity_groups
  on public.saved_chemicals using gin (activity_groups);

-- "Show me everything still needing verification."
create index if not exists idx_saved_chemicals_verification_status
  on public.saved_chemicals (verification_status);

-- Country-scoped identity lookups and duplicate detection.
create index if not exists idx_saved_chemicals_registration
  on public.saved_chemicals (registration_country, registration_scheme, registration_number)
  where registration_number is not null;

-- ---------------------------------------------------------------------------
-- 3. Mark pre-existing chemicals as needing a match
-- ---------------------------------------------------------------------------
-- This is the ONLY data touched by this migration, and it writes exactly one
-- value: a status meaning "nobody has confirmed which registered product this
-- is yet". It does NOT populate actives or groups from the legacy free text —
-- an unreviewed parse of a typed string is not evidence, and writing it here
-- would make guesses indistinguishable from verified data forever.
--
-- Existing chemicals keep loading and displaying from their untouched scalar
-- columns exactly as before.
update public.saved_chemicals
set verification_status = 'needs_match'
where verification_status = 'unverified'
  and active_ingredients is null
  and deleted_at is null;

-- ---------------------------------------------------------------------------
-- 4. Audit view
-- ---------------------------------------------------------------------------
-- Backend/admin reporting for the Phase 13 audit. Answers, per vineyard:
-- how many chemicals exist, how many are structured, how many are missing
-- groups, how many mixtures are unresolved, how many lack a registration, and
-- how many are in conflict. Enough to drive a future admin dashboard without
-- building one now.

create or replace view public.saved_chemical_intelligence_audit as
select
  c.id,
  c.vineyard_id,
  c.name,
  c.product_category,
  c.verification_status,
  c.registration_country,
  c.registration_scheme,
  c.registration_number,
  c.activity_group_scheme,
  c.activity_groups,
  c.label_rate_bases,
  c.verified_at,
  c.activity_group_table_version,
  c.intelligence_schema_version,
  -- Legacy values retained for comparison during migration review.
  c.active_ingredient as legacy_active_ingredient,
  c.chemical_group    as legacy_chemical_group,
  c.mode_of_action    as legacy_mode_of_action,
  coalesce(jsonb_array_length(c.active_ingredients), 0) as active_ingredient_count,
  coalesce(array_length(c.activity_groups, 1), 0)       as activity_group_count,
  coalesce(jsonb_array_length(c.registered_uses), 0)    as registered_use_count,
  coalesce(jsonb_array_length(c.verification_conflicts), 0) as conflict_count,
  -- Structured actives exist at all.
  (c.active_ingredients is not null
     and jsonb_array_length(c.active_ingredients) > 0)   as has_structured_actives,
  -- Has actives but no machine-readable group: cannot be used for resistance.
  (c.active_ingredients is not null
     and jsonb_array_length(c.active_ingredients) > 0
     and coalesce(array_length(c.activity_groups, 1), 0) = 0) as missing_activity_groups,
  -- A multi-active product whose group count is lower than its active count:
  -- at least one active in the mixture is still unclassified. These are the
  -- rows most likely to mislead a resistance rotation.
  (coalesce(jsonb_array_length(c.active_ingredients), 0) > 1
     and coalesce(array_length(c.activity_groups, 1), 0)
         < jsonb_array_length(c.active_ingredients))      as unresolved_mixture,
  (c.registration_number is null or c.registration_number = '') as missing_registration,
  (c.verification_conflicts is not null
     and jsonb_array_length(c.verification_conflicts) > 0) as has_conflict,
  -- The legacy string implies a mixture but no structured actives exist.
  (c.chemical_group like '%+%'
     and coalesce(jsonb_array_length(c.active_ingredients), 0) = 0) as legacy_mixture_needs_match
from public.saved_chemicals c
where c.deleted_at is null;

comment on view public.saved_chemical_intelligence_audit is
  'Chemical Intelligence audit (sql/194). Classifies saved chemicals as verified / '
  'partially verified / unverified / needs match / conflict and flags missing groups, '
  'unresolved mixtures and missing registrations. Read-only reporting; rewrites nothing.';

-- The view inherits row-level security from `saved_chemicals` via
-- security_invoker, so a caller only ever sees chemicals for vineyards they
-- are already a member of.
alter view public.saved_chemical_intelligence_audit set (security_invoker = on);

grant select on public.saved_chemical_intelligence_audit to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Per-vineyard audit summary
-- ---------------------------------------------------------------------------

create or replace view public.saved_chemical_intelligence_summary as
select
  vineyard_id,
  count(*)                                              as total_chemicals,
  count(*) filter (where verification_status = 'verified')           as verified_count,
  count(*) filter (where verification_status = 'partially_verified') as partially_verified_count,
  count(*) filter (where verification_status = 'unverified')         as unverified_count,
  count(*) filter (where verification_status = 'needs_match')        as needs_match_count,
  count(*) filter (where verification_status = 'conflict')           as conflict_count,
  count(*) filter (where has_structured_actives)                     as structured_actives_count,
  count(*) filter (where missing_activity_groups)                    as missing_groups_count,
  count(*) filter (where unresolved_mixture)                         as unresolved_mixture_count,
  count(*) filter (where missing_registration)                       as missing_registration_count,
  count(*) filter (where legacy_mixture_needs_match)                 as legacy_mixture_count
from public.saved_chemical_intelligence_audit
group by vineyard_id;

comment on view public.saved_chemical_intelligence_summary is
  'Per-vineyard Chemical Intelligence rollup (sql/194) for admin reporting.';

alter view public.saved_chemical_intelligence_summary set (security_invoker = on);

grant select on public.saved_chemical_intelligence_summary to authenticated;

commit;

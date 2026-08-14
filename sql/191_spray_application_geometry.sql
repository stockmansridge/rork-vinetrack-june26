-- =============================================================================
-- 191: Spray application geometry — canonical row length, banded treated area,
--      per-product rate basis, and the L/100 m carrier-volume contract.
--
-- Rork/VineTrack mobile is the SOURCE OF TRUTH for this contract. Lovable (the
-- web portal) CONSUMES it and MUST NOT independently create or modify any of
-- these columns, functions or rules.
--
-- ---------------------------------------------------------------------------
-- WHY (what the audit found)
-- ---------------------------------------------------------------------------
-- 1. BANDED SPRAY HAS NO TREATED AREA. Both clients calculate every banded and
--    spreader job as `rate × SUM(block gross hectares)` — the identical
--    expression used for a full-canopy foliar spray. A 0.8 m herbicide band in a
--    3.2 m row is therefore dosed as if the whole 10 ha block were sprayed: 4x
--    the product actually needed. There is no band-width field anywhere in the
--    schema, so the error is not even recoverable from stored data.
--
-- 2. NO CALCULATION INPUT IS STORED AS A COLUMN. `spray_records` has no area,
--    no carrier volume, no water rate and no concentration factor. Everything
--    lives inside the untyped `tanks` JSONB, and the Integration Read API
--    RE-DERIVES area as `waterVolume × concentrationFactor / sprayRatePerHa`,
--    publishing it as `treated_area_ha` — a GROSS area under a treated name.
--
-- 3. RATE BASIS HAS NO SERVER-SIDE REPRESENTATION. `per_hectare` /
--    `per_100_litres` exist only in Swift/Kotlin. Worse, a stored spray line
--    carries BOTH `ratePerHa` and `ratePer100L` with no discriminator, so the
--    grower's intent is unrecoverable server-side. `per_hectare` is also
--    overloaded: it means gross-block hectares for foliar AND (incorrectly)
--    gross-block hectares for banded, with no way to express "per treated ha".
--
-- 4. ROW LENGTH IS COMPUTED IN MULTIPLE PLACES. `paddocks` stores no length at
--    all (only `row_length_override`); each client re-derives it from the `rows`
--    JSONB, and iOS additionally has a second, subtly different implementation.
--    Nothing records WHICH geometry produced a given spray quantity.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES
-- ---------------------------------------------------------------------------
-- STRICTLY ADDITIVE. Every column is nullable with NO default, no existing
-- column/constraint/index is altered or dropped, and NOTHING is backfilled.
--
-- A historical record keeps NULL in every new column, which the clients read as
-- "this record predates the geometry contract" and fall back to the legacy
-- derivation for. A NULL band width can therefore never be mistaken for a
-- measured zero, and no completed spray silently acquires a treated area.
--
-- CRITICAL SEPARATION OF CONCERNS — these two are INDEPENDENT:
--   * CARRIER VOLUME BASIS (`carrier_volume_basis`): how the grower ENTERS
--     water volume — L/ha or L/100 m. A vineyard-level compliance preference.
--   * PRODUCT LABEL RATE BASIS (`rate_basis` per product line): what a product's
--     label rate is measured against. Legally authoritative and per product.
-- An SWNZ vineyard entering carrier volume exclusively in L/100 m may still dose
-- a product whose label is authoritative in L/ha. Never conflate them.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. spray_records — the completed/historical spray. All nullable, no defaults.
-- ---------------------------------------------------------------------------
alter table public.spray_records
  -- Application geometry. gross and treated are BOTH retained: treated area
  -- never replaces gross. Reporting, per-hectare costing and whole-block
  -- product rates all still need gross hectares.
  add column if not exists gross_area_ha               numeric null,
  add column if not exists treated_area_ha             numeric null,
  add column if not exists application_mode            text    null,
  add column if not exists treated_area_method         text    null,
  -- Band width per ROW. `band_width_total_metres` is the AUTHORITATIVE value
  -- used by the arithmetic; left/right are carried for future nozzle-level
  -- setups and are never multiplied directly.
  add column if not exists band_width_total_metres     numeric null,
  add column if not exists band_width_left_metres      numeric null,
  add column if not exists band_width_right_metres     numeric null,
  -- Canonical geometry that produced the numbers above, so any quantity can be
  -- traced back to the geometry it came from.
  add column if not exists canonical_row_length_metres numeric null,
  add column if not exists row_spacing_metres          numeric null,
  add column if not exists geometry_source             text    null,
  add column if not exists geometry_quality            text    null,
  -- Carrier (water) volume.
  add column if not exists carrier_volume_basis        text    null,
  add column if not exists total_carrier_litres        numeric null,
  add column if not exists carrier_litres_per_hectare  numeric null,
  add column if not exists dilute_litres_per_100m      numeric null,
  add column if not exists applied_litres_per_100m     numeric null,
  add column if not exists concentration_factor        numeric null;

-- ---------------------------------------------------------------------------
-- 2. spray_jobs — planned jobs AND templates (is_template = true).
--
-- Templates must be able to carry the new contract or a saved banded template
-- would lose its band width on reuse. `row_spacing_metres` and
-- `concentration_factor` already exist (sql/034) and are NOT redeclared;
-- `water_volume` already holds total litres and `spray_rate_per_ha` the L/ha
-- rate, so neither is duplicated here.
-- ---------------------------------------------------------------------------
alter table public.spray_jobs
  add column if not exists gross_area_ha               numeric null,
  add column if not exists treated_area_ha             numeric null,
  add column if not exists application_mode            text    null,
  add column if not exists treated_area_method         text    null,
  add column if not exists band_width_total_metres     numeric null,
  add column if not exists band_width_left_metres      numeric null,
  add column if not exists band_width_right_metres     numeric null,
  add column if not exists canonical_row_length_metres numeric null,
  add column if not exists geometry_source             text    null,
  add column if not exists geometry_quality            text    null,
  add column if not exists carrier_volume_basis        text    null,
  add column if not exists dilute_litres_per_100m      numeric null,
  add column if not exists applied_litres_per_100m     numeric null;

-- ---------------------------------------------------------------------------
-- 3. Value domains.
--
-- Every CHECK is NULL-tolerant (`x is null or x in (...)`) so existing rows
-- validate unchanged, and every numeric guard admits NULL for the same reason.
-- Constraints are added conditionally so re-running the migration is safe.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['spray_records', 'spray_jobs'] loop

    -- Whole-canopy vs banded/strip application.
    if not exists (
      select 1 from pg_constraint
       where conname = t || '_application_mode_check'
    ) then
      execute format(
        'alter table public.%I add constraint %I check (
           application_mode is null
           or application_mode in (''whole_block'', ''banded''))',
        t, t || '_application_mode_check'
      );
    end if;

    -- Which formula produced treated_area_ha.
    if not exists (
      select 1 from pg_constraint
       where conname = t || '_treated_area_method_check'
    ) then
      execute format(
        'alter table public.%I add constraint %I check (
           treated_area_method is null
           or treated_area_method in (
             ''canonical_row_length'', ''area_and_spacing_fallback'',
             ''whole_block'', ''unavailable''))',
        t, t || '_treated_area_method_check'
      );
    end if;

    -- Where the canonical row length came from.
    if not exists (
      select 1 from pg_constraint
       where conname = t || '_geometry_source_check'
    ) then
      execute format(
        'alter table public.%I add constraint %I check (
           geometry_source is null
           or geometry_source in (
             ''mapped_rows'', ''stored_row_length'',
             ''derived_from_area_and_spacing'', ''unavailable''))',
        t, t || '_geometry_source_check'
      );
    end if;

    -- How much that geometry can be trusted.
    if not exists (
      select 1 from pg_constraint
       where conname = t || '_geometry_quality_check'
    ) then
      execute format(
        'alter table public.%I add constraint %I check (
           geometry_quality is null
           or geometry_quality in (''authoritative'', ''derived'', ''incomplete''))',
        t, t || '_geometry_quality_check'
      );
    end if;

    -- How the grower ENTERED carrier volume (NOT a product rate basis).
    if not exists (
      select 1 from pg_constraint
       where conname = t || '_carrier_volume_basis_check'
    ) then
      execute format(
        'alter table public.%I add constraint %I check (
           carrier_volume_basis is null
           or carrier_volume_basis in (''l_per_ha'', ''l_per_100m''))',
        t, t || '_carrier_volume_basis_check'
      );
    end if;

    -- Physical sanity. A band width or row length of 0 is not a measurement;
    -- absence must be expressed as NULL so it can never dose a tank.
    if not exists (
      select 1 from pg_constraint
       where conname = t || '_band_width_positive_check'
    ) then
      execute format(
        'alter table public.%I add constraint %I check (
           (band_width_total_metres is null or band_width_total_metres > 0)
           and (band_width_left_metres  is null or band_width_left_metres  >= 0)
           and (band_width_right_metres is null or band_width_right_metres >= 0))',
        t, t || '_band_width_positive_check'
      );
    end if;

    if not exists (
      select 1 from pg_constraint
       where conname = t || '_geometry_positive_check'
    ) then
      execute format(
        'alter table public.%I add constraint %I check (
           (canonical_row_length_metres is null or canonical_row_length_metres > 0)
           and (gross_area_ha   is null or gross_area_ha   >= 0)
           and (treated_area_ha is null or treated_area_ha >= 0)
           and (dilute_litres_per_100m  is null or dilute_litres_per_100m  > 0)
           and (applied_litres_per_100m is null or applied_litres_per_100m > 0))',
        t, t || '_geometry_positive_check'
      );
    end if;

  end loop;
end$$;

-- spray_records-only numeric guards (spray_jobs keeps its sql/034 equivalents).
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'spray_records_carrier_positive_check'
  ) then
    alter table public.spray_records
      add constraint spray_records_carrier_positive_check check (
        (total_carrier_litres       is null or total_carrier_litres       >= 0)
        and (carrier_litres_per_hectare is null or carrier_litres_per_hectare >= 0)
        and (row_spacing_metres         is null or row_spacing_metres         > 0)
        and (concentration_factor       is null or concentration_factor       > 0)
      );
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- 4. Vineyard spray compliance profile.
--
-- Both columns nullable with NO default and NO backfill. An unset vineyard
-- keeps NULL and the clients resolve a country-appropriate default at read time
-- from the EXISTING `vineyards.country_code` (sql/099) — NZ ⇒ SWNZ/L-per-100 m,
-- everything else ⇒ AU/either. Nothing is written on the grower's behalf, so no
-- vineyard silently acquires a compliance profile it did not choose.
-- ---------------------------------------------------------------------------
alter table public.vineyards
  add column if not exists spray_compliance_profile   text null,
  add column if not exists spray_carrier_volume_basis text null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'vineyards_spray_compliance_profile_check'
  ) then
    alter table public.vineyards
      add constraint vineyards_spray_compliance_profile_check check (
        spray_compliance_profile is null
        or spray_compliance_profile in ('au', 'nz_swnz')
      );
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'vineyards_spray_carrier_volume_basis_check'
  ) then
    alter table public.vineyards
      add constraint vineyards_spray_carrier_volume_basis_check check (
        spray_carrier_volume_basis is null
        or spray_carrier_volume_basis in ('l_per_ha', 'l_per_100m', 'either')
      );
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- 5. get_vineyard_spray_profile(p_vineyard_id) — any member may read.
--
-- Deliberately SEPARATE from get_vineyard_region_settings (sql/099) rather than
-- extending it: changing that function's return signature would break every
-- deployed client and the portal mid-rollout.
--
-- `country_code` is returned alongside so a client can resolve the default
-- profile without a second round trip. NULLs are returned as-is.
-- ---------------------------------------------------------------------------
drop function if exists public.get_vineyard_spray_profile(uuid);

create or replace function public.get_vineyard_spray_profile(
  p_vineyard_id uuid
) returns table (
  vineyard_id                uuid,
  country_code               text,
  spray_compliance_profile   text,
  spray_carrier_volume_basis text
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_member boolean;
begin
  select exists(
    select 1
      from public.vineyard_members vm
     where vm.vineyard_id = p_vineyard_id
       and vm.user_id     = auth.uid()
  ) into v_member;

  if not v_member then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;

  return query
    select v.id,
           v.country_code,
           v.spray_compliance_profile,
           v.spray_carrier_volume_basis
      from public.vineyards v
     where v.id = p_vineyard_id;
end$$;

revoke all on function public.get_vineyard_spray_profile(uuid) from public;
grant execute on function public.get_vineyard_spray_profile(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. set_vineyard_spray_profile(...) — owner/manager only.
--
-- A spray compliance profile decides how the whole vineyard is allowed to enter
-- carrier volume, so it sits at the same permission level as region settings
-- (sql/099) rather than with field data entry.
--
-- Empty strings are coerced to NULL so "cleared" always means "fall back to the
-- country default" and never an invalid stored value.
-- ---------------------------------------------------------------------------
drop function if exists public.set_vineyard_spray_profile(uuid, text, text);

create or replace function public.set_vineyard_spray_profile(
  p_vineyard_id                uuid,
  p_spray_compliance_profile   text,
  p_spray_carrier_volume_basis text
) returns table (
  vineyard_id                uuid,
  country_code               text,
  spray_compliance_profile   text,
  spray_carrier_volume_basis text
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_role    text;
  v_profile text := nullif(btrim(coalesce(p_spray_compliance_profile,   '')), '');
  v_basis   text := nullif(btrim(coalesce(p_spray_carrier_volume_basis, '')), '');
begin
  select vm.role
    into v_role
    from public.vineyard_members vm
   where vm.vineyard_id = p_vineyard_id
     and vm.user_id     = auth.uid();

  if v_role is null then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;

  if v_role not in ('owner', 'manager') then
    raise exception 'Only an owner or manager may change the spray profile'
      using errcode = '42501';
  end if;

  if v_profile is not null and v_profile not in ('au', 'nz_swnz') then
    raise exception 'Unsupported spray compliance profile: %', v_profile
      using errcode = '22023';
  end if;

  if v_basis is not null and v_basis not in ('l_per_ha', 'l_per_100m', 'either') then
    raise exception 'Unsupported carrier volume basis: %', v_basis
      using errcode = '22023';
  end if;

  update public.vineyards v
     set spray_compliance_profile   = v_profile,
         spray_carrier_volume_basis = v_basis,
         updated_at                 = now()
   where v.id = p_vineyard_id;

  return query
    select v.id,
           v.country_code,
           v.spray_compliance_profile,
           v.spray_carrier_volume_basis
      from public.vineyards v
     where v.id = p_vineyard_id;
end$$;

revoke all on function public.set_vineyard_spray_profile(uuid, text, text) from public;
grant execute on function public.set_vineyard_spray_profile(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Column documentation, including the JSONB product-rate-basis contract.
-- ---------------------------------------------------------------------------
comment on column public.spray_records.gross_area_ha is
  'Gross (whole-block) hectares for the application. Retained ALONGSIDE treated_area_ha — treated area never replaces it. NULL on records written before sql/191.';

comment on column public.spray_records.treated_area_ha is
  'ACTUAL treated hectares. For a banded job: canonical_row_length_metres × band_width_total_metres / 10000, or the grossHa × band / rowSpacing fallback. Equals gross_area_ha for a whole-block application. NULL means unknown and MUST NOT be defaulted to gross — never derive a treated area for a record that has no band width.';

comment on column public.spray_records.band_width_total_metres is
  'TOTAL treated band width per row, metres. The authoritative figure for treated-area maths. band_width_left/right_metres are informational only (future nozzle-level setups) and are never multiplied directly.';

comment on column public.spray_records.canonical_row_length_metres is
  'Total applicable row/trellis metres from the canonical geometry engine. THE SAME value feeds banded treated area and L/100 m carrier volume, so the two can never disagree. geometry_source records where it came from.';

comment on column public.spray_records.carrier_volume_basis is
  'How the grower ENTERED carrier volume: l_per_ha or l_per_100m. This is the CARRIER VOLUME BASIS and is INDEPENDENT of any product''s label rate basis. Do not conflate the two.';

comment on column public.spray_records.concentration_factor is
  'dilute/runoff volume ÷ actual applied volume (>= 1.0). Per-100 L label rates are written against the DILUTE volume, so product = rate × actualLitres/100 × concentration_factor. 1.0 when spraying dilute.';

comment on column public.spray_records.tanks is
  'Canonical tank mix snapshot. Per-tank: tankNumber, waterVolume, sprayRatePerHa, concentrationFactor, rowApplications[], chemicals[]. Per chemical: name, volumePerTank, ratePerHa, ratePer100L, costPerUnit, unit, savedChemicalId, and (sql/191, OPTIONAL) rateBasis in (whole_block_area, treated_area, per_100_litres, per_100_metres). ABSENT rateBasis MUST be read with the legacy mapping: a per-hectare line means whole_block_area — which is exactly what every pre-191 record computed, including banded jobs. Never reinterpret an absent rateBasis as treated_area: that would silently restate historical quantities.';

comment on column public.spray_jobs.chemical_lines is
  'Planned/template product lines. Per line: saved_chemical_id, name, rate, unit, active_ingredient, and (sql/191, OPTIONAL) rate_basis in (whole_block_area, treated_area, per_100_litres, per_100_metres). ABSENT rate_basis falls back to the legacy per-hectare = whole_block_area mapping, so existing templates keep producing identical quantities.';

comment on column public.vineyards.spray_compliance_profile is
  'Vineyard spray calculation/compliance profile: au or nz_swnz. NULL = never set; clients resolve from country_code (NZ ⇒ nz_swnz, else au) WITHOUT writing. Governs carrier-volume entry only — product label rate basis stays authoritative per product.';

comment on column public.vineyards.spray_carrier_volume_basis is
  'Which carrier-volume bases the vineyard may ENTER: l_per_ha, l_per_100m or either. NULL = never set; resolved from spray_compliance_profile (nz_swnz ⇒ l_per_100m only, au ⇒ either). Under SWNZ, L/ha is still DERIVED and stored internally — it is simply not the entry basis.';

commit;

-- =============================================================================
-- ROLLBACK
--
-- Every change is additive, so rollback is a pure drop with no data recovery
-- step. Dropping the columns loses only the new geometry metadata; all legacy
-- fields (tanks, water_volume, spray_rate_per_ha, row_spacing_metres,
-- concentration_factor on spray_jobs) are untouched by this migration and keep
-- working exactly as before, because no client has been changed to depend on
-- the new columns for legacy records.
--
-- begin;
--   drop function if exists public.set_vineyard_spray_profile(uuid, text, text);
--   drop function if exists public.get_vineyard_spray_profile(uuid);
--   alter table public.vineyards
--     drop column if exists spray_carrier_volume_basis,
--     drop column if exists spray_compliance_profile;
--   -- CHECK constraints drop automatically with their columns.
--   alter table public.spray_jobs
--     drop column if exists gross_area_ha,
--     drop column if exists treated_area_ha,
--     drop column if exists application_mode,
--     drop column if exists treated_area_method,
--     drop column if exists band_width_total_metres,
--     drop column if exists band_width_left_metres,
--     drop column if exists band_width_right_metres,
--     drop column if exists canonical_row_length_metres,
--     drop column if exists geometry_source,
--     drop column if exists geometry_quality,
--     drop column if exists carrier_volume_basis,
--     drop column if exists dilute_litres_per_100m,
--     drop column if exists applied_litres_per_100m;
--   alter table public.spray_records
--     drop column if exists gross_area_ha,
--     drop column if exists treated_area_ha,
--     drop column if exists application_mode,
--     drop column if exists treated_area_method,
--     drop column if exists band_width_total_metres,
--     drop column if exists band_width_left_metres,
--     drop column if exists band_width_right_metres,
--     drop column if exists canonical_row_length_metres,
--     drop column if exists row_spacing_metres,
--     drop column if exists geometry_source,
--     drop column if exists geometry_quality,
--     drop column if exists carrier_volume_basis,
--     drop column if exists total_carrier_litres,
--     drop column if exists carrier_litres_per_hectare,
--     drop column if exists dilute_litres_per_100m,
--     drop column if exists applied_litres_per_100m,
--     drop column if exists concentration_factor;
-- commit;
--
-- END 191
--
-- Manual actions after applying:
--   * run sql/tests/191_spray_application_geometry_tests.sql
--   * NO backfill. Historical records intentionally keep NULL in every new
--     column and continue to be read with the legacy derivation.
--   * supabase/functions/vinetrack-api does NOT need redeploying for this
--     migration: it selects an explicit column list and is unaffected. A later
--     task should extend it to publish gross_area_ha vs treated_area_ha, since
--     it currently derives a GROSS area and labels it `treated_area_ha`.
--   * Lovable/portal: CONSUME this contract only. Read the new columns and the
--     OPTIONAL rateBasis/rate_basis JSONB keys; treat absent values with the
--     legacy per-hectare = whole_block_area mapping. Do NOT backfill band
--     widths, do NOT reinterpret historical per-hectare lines as treated-area,
--     and do NOT add a treated area to a record that has no band width.
-- =============================================================================

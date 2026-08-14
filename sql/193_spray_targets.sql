-- =============================================================================
-- 193: Spray targets — first-class target pest/disease/purpose and spray head
--      target on the completed spray record.
--
-- Rork/VineTrack mobile is the SOURCE OF TRUTH for this contract. Lovable (the
-- web portal) CONSUMES it and MUST NOT independently create or modify any of
-- these columns.
--
-- ---------------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------------
-- sql/191 gave `spray_records` seventeen geometry/carrier columns and
-- `spray_jobs` thirteen, but NEITHER table has any representation of what a
-- spray was actually aimed at. The guided calculator collects the target today
-- and can only hold it in screen state, so the moment a spray is saved the
-- agronomic intent is lost.
--
-- That intent is about to become load-bearing. The next stage builds:
--   * Chemical Intelligence (verified actives / activity groups)
--   * the Resistance Rules Engine
--   * the Resistance Planner
--   * the live Resistance Check
-- Every one of those matches on "what were you spraying FOR" — a DMI applied
-- three times in a row only matters against powdery mildew. Reporting, the
-- integration API, webhooks, SWNZ compatibility and historical analysis need
-- the same field.
--
-- It deliberately does NOT go in the `tanks` JSONB. sql/191's audit recorded
-- exactly how that ends: an untyped blob that cannot be indexed, cannot be
-- constrained, cannot be queried by the planner, and whose meaning is
-- unrecoverable server-side. Resistance-critical data must be first-class.
--
-- Targets are NEVER inferred from the products in the tank. A grower who tank
-- mixes a nutrient with a fungicide has one target, not two, and only the
-- operator knows which. Historical records therefore stay NULL forever rather
-- than being back-derived from chemistry — a guessed target would silently
-- become a compliance claim.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES
-- ---------------------------------------------------------------------------
-- STRICTLY ADDITIVE. Every column is nullable with NO default, no existing
-- column/constraint/index is altered or dropped, and NOTHING is backfilled.
--
-- A historical record keeps NULL in both new columns, which the clients read as
-- "this record predates the target contract" and present as unknown. NULL (never
-- recorded) stays distinguishable from '{}' (recorded as explicitly none).
--
-- ---------------------------------------------------------------------------
-- VALUE DOMAIN POLICY — read before adding a CHECK here
-- ---------------------------------------------------------------------------
-- `targets` gets NO value CHECK, on purpose. The target vocabulary is expected
-- to expand often and per-region (mealybug, phylloxera, trunk disease, frost
-- protection, SWNZ-specific purposes...). A CHECK would turn every one of those
-- into a production migration, and — far worse — an app shipped ahead of the
-- migration would have its writes REJECTED, losing the operator's record. The
-- typed enum in Swift/Kotlin is the enforcement point; unknown values degrade to
-- nil client-side via the existing tolerant `SprayTarget.from(_:)` decode.
--
-- Only structural hygiene is enforced: no NULL elements, no empty strings. That
-- cannot block future expansion because it says nothing about which identifiers
-- are legal.
--
-- `spray_head_target` DOES get a value CHECK. It is a small, physically bounded
-- vocabulary (where the nozzle points), it is not expected to churn, and the
-- guard protects a compliance field. sql/192 already established the pattern
-- for widening one of these safely if that ever changes — see below.
--
-- To widen the spray_head_target CHECK later, follow sql/192: drop and re-add
-- (Postgres has no "widen CHECK" verb), additive values only, never narrow.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. spray_records — the completed/historical spray. All nullable, no defaults.
--
-- `targets` is text[] rather than a join table or a single text column because:
--   * one pass genuinely addresses several targets (powdery + downy is routine),
--     so a scalar column would force the operator to lie;
--   * a join table would need its own RLS, its own sync/offline replay path and
--     its own conflict resolution for what is a small fixed-size value list
--     owned entirely by the parent record;
--   * text[] is indexable with GIN, which is exactly what the Resistance
--     Planner's "find sprays targeting X in the last N days" query needs.
-- ---------------------------------------------------------------------------
alter table public.spray_records
  add column if not exists targets           text[] null,
  add column if not exists spray_head_target text   null;

-- ---------------------------------------------------------------------------
-- 2. spray_jobs — the PLANNED spray, kept in step with spray_records exactly as
--    sql/191 did. The Resistance Planner will reason about planned work, not
--    just completed work, so the planned side needs the same field.
-- ---------------------------------------------------------------------------
alter table public.spray_jobs
  add column if not exists targets           text[] null,
  add column if not exists spray_head_target text   null;

-- ---------------------------------------------------------------------------
-- 3. Value domains.
--
-- Every CHECK is NULL-tolerant so existing rows validate unchanged, and each is
-- added conditionally so re-running the migration is safe.
--
-- NOTE: a CHECK constraint may not contain a subquery, so the "no empty string"
-- rule is expressed with array_remove/cardinality rather than `not exists`.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['spray_records', 'spray_jobs'] loop

    -- Structural hygiene ONLY — deliberately says nothing about which target
    -- identifiers are legal, so new targets never require a migration.
    --   * array_position(targets, null) is null  → no NULL elements
    --   * cardinality unchanged by array_remove(targets, '') → no empty strings
    if not exists (
      select 1 from pg_constraint
       where conname = t || '_targets_wellformed_check'
    ) then
      execute format(
        'alter table public.%I add constraint %I check (
           targets is null
           or (
             array_position(targets, null) is null
             and cardinality(targets) = cardinality(array_remove(targets, ''''))
           ))',
        t, t || '_targets_wellformed_check'
      );
    end if;

    -- Where the spray head is aimed. Foliar applications only; a banded or
    -- spreader pass legitimately leaves this NULL.
    if not exists (
      select 1 from pg_constraint
       where conname = t || '_spray_head_target_check'
    ) then
      execute format(
        'alter table public.%I add constraint %I check (
           spray_head_target is null
           or spray_head_target in (
             ''full_canopy'', ''bunch_line'', ''leaf_zone''))',
        t, t || '_spray_head_target_check'
      );
    end if;

  end loop;
end$$;

-- ---------------------------------------------------------------------------
-- 4. Index supporting the Resistance Planner's core lookup.
--
-- GIN over text[] answers `targets && array['powdery_mildew']` — "every spray
-- aimed at this target" — which is the read the rules engine will perform per
-- block per season. Partial (`where targets is not null`) so the index stays
-- small: historical rows are all NULL and can never match a containment query.
--
-- Plain CREATE INDEX (not CONCURRENTLY) because this migration runs in a
-- transaction. It takes a brief SHARE lock that blocks writes to spray_records
-- for the build; these tables are small enough for that to be milliseconds.
-- ---------------------------------------------------------------------------
create index if not exists spray_records_targets_gin
  on public.spray_records using gin (targets)
  where targets is not null;

create index if not exists spray_jobs_targets_gin
  on public.spray_jobs using gin (targets)
  where targets is not null;

-- ---------------------------------------------------------------------------
-- 5. Documentation.
-- ---------------------------------------------------------------------------
comment on column public.spray_records.targets is
  'Stable machine identifiers for what this spray targeted (powdery_mildew, '
  'downy_mildew, botrytis, weeds, nutrition_biostimulant, other, ...). '
  'Multi-valued. Display names live in the app, never here. NULL = never '
  'recorded (pre-sql/193); ''{}'' = recorded as explicitly none. NEVER inferred '
  'from the products in the tank.';

comment on column public.spray_records.spray_head_target is
  'Foliar applications only: where the spray head was aimed — full_canopy, '
  'bunch_line or leaf_zone. NULL for banded/spreader passes and for records '
  'written before sql/193.';

comment on column public.spray_jobs.targets is
  'Planned equivalent of spray_records.targets. Same identifiers, same rules.';

comment on column public.spray_jobs.spray_head_target is
  'Planned equivalent of spray_records.spray_head_target.';

commit;

-- =============================================================================
-- ROLLBACK (manual, only if this migration must be reverted before clients ship)
--
-- begin;
--   drop index if exists public.spray_records_targets_gin;
--   drop index if exists public.spray_jobs_targets_gin;
--   -- CHECK constraints drop automatically with their columns.
--   alter table public.spray_records
--     drop column if exists targets,
--     drop column if exists spray_head_target;
--   alter table public.spray_jobs
--     drop column if exists targets,
--     drop column if exists spray_head_target;
-- commit;
--
-- END 193
--
-- Manual actions after applying:
--   * NO backfill. Historical records intentionally keep NULL in both columns.
--     Do NOT derive targets from chemical names, product types or job titles.
--   * supabase/functions/vinetrack-api DOES need redeploying for this migration:
--     it selects an explicit column list, so `targets` and `spray_head_target`
--     are added to that list to publish them additively. No existing API field
--     changes shape.
--   * Lovable/portal: CONSUME only. Read the new columns; treat NULL as unknown
--     and do NOT infer a target from the tank mix.
-- =============================================================================

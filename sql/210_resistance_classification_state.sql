-- 210: Resistance classification STATE — proposal for review (task §10).
--
-- ###########################################################################
-- #                                                                         #
-- #   PROPOSAL ONLY — DO NOT RUN AGAINST PRODUCTION UNTIL APPROVED.         #
-- #                                                                         #
-- #   Reviewed and applied together with sql/tests/210_..._tests.sql,       #
-- #   which is rollback-only and safe to run first.                         #
-- #                                                                         #
-- ###########################################################################
--
-- THE PROBLEM
--
--   Resistance data exists to drive spray-selection warnings, the Resistance
--   Planner and seasonal rotation reporting. Those features must be able to
--   tell three genuinely different conditions apart:
--
--     classified      this active belongs to FRAC 3 / IRAC 4A / HRAC G
--     not_applicable  this product HAS no resistance group by design —
--                     an adjuvant, a wetter, a straight fertiliser
--     unresolved      nobody has established the group yet, or the lookup
--                     failed, or the record predates classification
--
--   Today only the FIRST is representable with confidence. The other two are
--   inferred from the SHAPE of the stored JSON:
--
--     active_ingredients[i].activity_group absent            -> "unknown"
--     active_ingredients[i].activity_group.scheme =
--                                     'not_applicable'       -> "no group"
--
--   Absence is doing two jobs at once. A product nobody has classified and a
--   product that legitimately has no classification are stored identically
--   when the writer simply omitted the key — and `activity_groups text[]`
--   (sql/194) is an empty array in BOTH cases, which is the column the
--   Resistance Planner actually queries.
--
--   The consequence is not cosmetic. A planner that reads an empty array as
--   "no resistance concern" will happily rotate two unclassified Group 11
--   products back to back and report the season as compliant.
--
-- WHAT THIS MIGRATION DOES
--
--   Adds ONE queryable column stating the condition explicitly, plus the
--   per-active `classification_state` key inside the existing JSONB (no DDL
--   needed for that half — JSONB is schemaless; the app and the edge function
--   are the writers, and the CHECK below governs the product-level rollup).
--
--   It deliberately does NOT:
--     * add a table, a type, or a foreign key;
--     * touch `activity_groups`, `activity_group_scheme` or any existing
--       CHECK — every current reader keeps working unchanged;
--     * infer a single classification from the legacy free-text
--       `chemical_group` column. sql/194 refused to launder that guess into
--       the database and this migration keeps that promise.
--
-- WHY A COLUMN AND NOT JUST THE JSONB KEY
--
--   The Resistance Planner asks set questions across a vineyard's whole store
--   ("show me everything unresolved", "which Group 11 products do I stock").
--   A jsonb path predicate over every active cannot use an index; a single
--   text column can, and it is the shape the existing
--   `idx_saved_chemicals_verification_status` already proves out.
--
-- Idempotent. Single transaction. Additive.

begin;

-- ---------------------------------------------------------------------------
-- 1. The column
-- ---------------------------------------------------------------------------

alter table public.saved_chemicals
  -- The product-level rollup of its actives' classification states.
  --
  -- NOT NULL with an explicit default is deliberate: a null here would
  -- reintroduce exactly the fourth ambiguous state this column exists to
  -- remove. 'unresolved' is the honest default for a row nobody has
  -- classified, and it is the SAFE default — it makes the Resistance Planner
  -- warn rather than stay silent.
  add column if not exists resistance_classification_state text
    not null default 'unresolved';

comment on column public.saved_chemicals.resistance_classification_state is
  'Resistance classification state (sql/210): classified | not_applicable | '
  'unresolved. Rollup of active_ingredients[].classification_state. '
  '''unresolved'' means nobody has established the groups yet; '
  '''not_applicable'' is a positive assertion that the product has no '
  'resistance classification by design (adjuvant, wetter, straight '
  'fertiliser). Absence of a group is NEVER not_applicable.';

-- Closed, stable, three-value vocabulary — safe to constrain, unlike the
-- FRAC/HRAC/IRAC code vocabulary which sql/194 deliberately left unconstrained
-- because new codes are published annually.
do $$
begin
  alter table public.saved_chemicals
    add constraint saved_chemicals_resistance_classification_state_check
    check (resistance_classification_state in (
      'classified', 'not_applicable', 'unresolved'
    ));
exception
  when duplicate_object then null;
end $$;

-- "Which of my chemicals still need a resistance group?" — the Planner's
-- own opening question, and the one the audit dashboard leads with.
create index if not exists idx_saved_chemicals_resistance_state
  on public.saved_chemicals (resistance_classification_state)
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- 2. The same column on the master catalogue (sql/199)
-- ---------------------------------------------------------------------------
-- A master row is copied into a vineyard's record on match. If the catalogue
-- could not state the classification state, every copy would arrive
-- 'unresolved' and the catalogue's own review work would be thrown away.

alter table public.master_chemicals
  add column if not exists resistance_classification_state text
    not null default 'unresolved';

do $$
begin
  alter table public.master_chemicals
    add constraint master_chemicals_resistance_classification_state_check
    check (resistance_classification_state in (
      'classified', 'not_applicable', 'unresolved'
    ));
exception
  when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Backfill — deliberately conservative
-- ---------------------------------------------------------------------------
--
-- THE RULE THAT MATTERS MOST
--
--   A missing activity group NEVER becomes 'not_applicable'.
--
--   It is tempting to read "no group stored" as "no group needed", because
--   most rows in that state really are adjuvants. But the ones that are NOT
--   adjuvants are precisely the dangerous rows: an unclassified fungicide
--   silently marked not_applicable would be excluded from every resistance
--   warning it should have triggered. 'unresolved' costs a prompt; a wrong
--   'not_applicable' costs a resistance failure in the block.
--
--   So 'not_applicable' is written ONLY where the stored data already
--   contains that positive assertion — somebody, or an authoritative
--   classification pass, explicitly said the product has no group.
--
-- THE MIXTURE RULE
--
--   A two-active product is only 'classified' when EVERY active that needs a
--   group has one. A mixture with Tebuconazole classified and the second
--   active unresolved is 'unresolved': reporting it as classified would tell
--   the Planner it knows the whole chemistry when it knows half of it.
--
--   An active explicitly marked not_applicable inside an otherwise classified
--   mixture (a classified fungicide plus a wetter) does not spoil the
--   product's 'classified' state — that active genuinely has nothing to
--   contribute.

-- 3a. Rows with NO structured actives at all -> unresolved.
--     This includes every pre-sql/194 record. It is already the column
--     default, so this statement exists to be explicit and to be re-runnable
--     if the column was added in an earlier partial apply.
update public.saved_chemicals
set resistance_classification_state = 'unresolved'
where deleted_at is null
  and (active_ingredients is null or jsonb_array_length(active_ingredients) = 0);

-- 3b. Every active carries a usable scheme+code -> classified.
--     "Usable" means a real scheme (frac/hrac/irac) AND a non-empty code.
--     A group object with a scheme but an empty code is NOT classification —
--     it is a half-written record, and it stays unresolved.
update public.saved_chemicals c
set resistance_classification_state = 'classified'
where c.deleted_at is null
  and c.active_ingredients is not null
  and jsonb_array_length(c.active_ingredients) > 0
  -- at least one active actually classified …
  and exists (
    select 1
      from jsonb_array_elements(c.active_ingredients) a
     where a->'activity_group'->>'scheme' in ('frac', 'hrac', 'irac')
       and coalesce(a->'activity_group'->>'code', '') <> ''
  )
  -- … and NO active left in an unknown condition.
  and not exists (
    select 1
      from jsonb_array_elements(c.active_ingredients) a
     where not (
       -- classified
       (a->'activity_group'->>'scheme' in ('frac', 'hrac', 'irac')
          and coalesce(a->'activity_group'->>'code', '') <> '')
       -- or an explicit "this active has no group"
       or a->'activity_group'->>'scheme' = 'not_applicable'
     )
  );

-- 3c. EVERY active explicitly asserts not_applicable -> not_applicable.
--     Note the `exists` guard: an empty actives array can never reach here,
--     and neither can a row whose actives merely LACK a group object.
update public.saved_chemicals c
set resistance_classification_state = 'not_applicable'
where c.deleted_at is null
  and c.active_ingredients is not null
  and jsonb_array_length(c.active_ingredients) > 0
  and exists (
    select 1
      from jsonb_array_elements(c.active_ingredients) a
     where a->'activity_group'->>'scheme' = 'not_applicable'
  )
  and not exists (
    select 1
      from jsonb_array_elements(c.active_ingredients) a
     where coalesce(a->'activity_group'->>'scheme', '') <> 'not_applicable'
  );

-- 3d. Same three rules for the master catalogue.
update public.master_chemicals m
set resistance_classification_state = 'unresolved'
where m.active_ingredients is null
   or jsonb_array_length(m.active_ingredients) = 0;

update public.master_chemicals m
set resistance_classification_state = 'classified'
where m.active_ingredients is not null
  and jsonb_array_length(m.active_ingredients) > 0
  and exists (
    select 1 from jsonb_array_elements(m.active_ingredients) a
     where a->'activity_group'->>'scheme' in ('frac', 'hrac', 'irac')
       and coalesce(a->'activity_group'->>'code', '') <> ''
  )
  and not exists (
    select 1 from jsonb_array_elements(m.active_ingredients) a
     where not (
       (a->'activity_group'->>'scheme' in ('frac', 'hrac', 'irac')
          and coalesce(a->'activity_group'->>'code', '') <> '')
       or a->'activity_group'->>'scheme' = 'not_applicable'
     )
  );

update public.master_chemicals m
set resistance_classification_state = 'not_applicable'
where m.active_ingredients is not null
  and jsonb_array_length(m.active_ingredients) > 0
  and exists (
    select 1 from jsonb_array_elements(m.active_ingredients) a
     where a->'activity_group'->>'scheme' = 'not_applicable'
  )
  and not exists (
    select 1 from jsonb_array_elements(m.active_ingredients) a
     where coalesce(a->'activity_group'->>'scheme', '') <> 'not_applicable'
  );

-- ---------------------------------------------------------------------------
-- 4. Audit view — additive column only
-- ---------------------------------------------------------------------------
-- `create or replace view` requires the existing column list to be preserved
-- in order, so the new column is APPENDED. Re-running sql/194 after this
-- would silently drop it again, exactly as re-running sql/206 drops C9 —
-- the same warning applies and the tests check for it.

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
  c.active_ingredient as legacy_active_ingredient,
  c.chemical_group    as legacy_chemical_group,
  c.mode_of_action    as legacy_mode_of_action,
  coalesce(jsonb_array_length(c.active_ingredients), 0) as active_ingredient_count,
  coalesce(array_length(c.activity_groups, 1), 0)       as activity_group_count,
  coalesce(jsonb_array_length(c.registered_uses), 0)    as registered_use_count,
  coalesce(jsonb_array_length(c.verification_conflicts), 0) as conflict_count,
  (c.active_ingredients is not null
     and jsonb_array_length(c.active_ingredients) > 0)   as has_structured_actives,
  (c.active_ingredients is not null
     and jsonb_array_length(c.active_ingredients) > 0
     and coalesce(array_length(c.activity_groups, 1), 0) = 0) as missing_activity_groups,
  (coalesce(jsonb_array_length(c.active_ingredients), 0) > 1
     and coalesce(array_length(c.activity_groups, 1), 0)
         < jsonb_array_length(c.active_ingredients))      as unresolved_mixture,
  (c.registration_number is null or c.registration_number = '') as missing_registration,
  (c.verification_conflicts is not null
     and jsonb_array_length(c.verification_conflicts) > 0) as has_conflict,
  (c.chemical_group like '%+%'
     and coalesce(jsonb_array_length(c.active_ingredients), 0) = 0) as legacy_mixture_needs_match,
  -- sql/210 additions.
  c.resistance_classification_state,
  -- The Planner's blind spot, named: a product with no established groups
  -- that has NOT been asserted group-free. These are the rows a resistance
  -- rotation would silently treat as harmless.
  (c.resistance_classification_state = 'unresolved') as resistance_unresolved
from public.saved_chemicals c
where c.deleted_at is null;

commit;

-- ---------------------------------------------------------------------------
-- ROLLBACK
-- ---------------------------------------------------------------------------
-- Fully reversible. The column is additive and nothing reads it until the
-- app and edge function are deployed, so dropping it restores sql/194
-- behaviour exactly. Re-run sql/194's view definition afterwards to restore
-- the pre-210 audit view.
--
-- begin;
--   drop index if exists public.idx_saved_chemicals_resistance_state;
--   alter table public.saved_chemicals
--     drop constraint if exists saved_chemicals_resistance_classification_state_check,
--     drop column if exists resistance_classification_state;
--   alter table public.master_chemicals
--     drop constraint if exists master_chemicals_resistance_classification_state_check,
--     drop column if exists resistance_classification_state;
--   -- then re-run the view block from sql/194.
-- commit;

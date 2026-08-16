-- =============================================================================
-- 195: Spray block attribution — WHICH blocks an application actually treated.
--
-- Rork/VineTrack mobile is the SOURCE OF TRUTH for this contract. Lovable (the
-- web portal) CONSUMES it and MUST NOT independently create or modify any of
-- these columns, functions or rules, nor invent a competing representation.
--
-- ---------------------------------------------------------------------------
-- WHY (what the audit found)
-- ---------------------------------------------------------------------------
-- 1. A COMPLETED SPRAY DOES NOT RECORD WHAT IT TREATED. `spray_records` has
--    `vineyard_id` and nothing else. The Guided Spray workflow has a Blocks
--    step, the operator's selection reaches the canonical geometry engine as a
--    per-block array, and every block's gross area / row length / spacing /
--    source / quality is resolved individually — then
--    `SprayApplicationSnapshot.init(plan:)` projects ONLY the aggregate totals
--    onto the sql/191 columns and every block id is discarded. The selection
--    exists in memory for the whole calculation and is thrown away at the
--    single moment it would have become durable.
--
-- 2. PLANNED JOBS ALREADY HAVE THIS AND COMPLETED SPRAYS DO NOT.
--    `spray_job_paddocks` (sql/032) is a proper FK junction giving every
--    `spray_jobs` row its intended blocks. The actual compliance record — the
--    one a resistance strategy, a re-entry interval and an audit are read from
--    — has no equivalent. This migration closes that asymmetry.
--
-- 3. ROW RANGES ARE NOT BLOCK IDENTITY. `tanks[].rowApplications[]` carries
--    `startRow`/`endRow` only. Row numbers are not unique across blocks and
--    carry no block reference on either platform, so they cannot be turned into
--    attribution without guessing. They are left alone.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES
-- ---------------------------------------------------------------------------
-- STRICTLY ADDITIVE. Two nullable columns on `spray_records`, no default, no
-- backfill, no existing column/constraint/index altered or dropped.
--
--   * `application_blocks` jsonb  — the ordered, structured per-block snapshot.
--   * `block_ids`         uuid[]  — a queryable projection of the same ids.
--
-- `application_blocks` EXTENDS the sql/191 application-geometry contract rather
-- than starting a second unrelated list: it is the per-block breakdown of the
-- geometry that sql/191 already stores in aggregate, so `gross_area_ha` is the
-- sum of the snapshot's per-block gross areas and `canonical_row_length_metres`
-- the sum of its per-block row lengths, BY CONSTRUCTION on the client.
--
-- `block_ids` exists because a resistance history query is "every application
-- that treated THIS block, in date order" and that must be an index seek, not a
-- JSONB scan. It is DERIVED from `application_blocks` by trigger, never written
-- independently, so the two can never disagree (see section 4).
--
-- ---------------------------------------------------------------------------
-- NULL MEANS "BLOCKS NOT RECORDED"
-- ---------------------------------------------------------------------------
-- This is the load-bearing rule of the whole migration.
--
-- A historical spray keeps NULL in both columns. NULL means, exactly and only,
-- "this record predates block attribution". It does NOT mean all blocks, no
-- blocks, the vineyard's current blocks, or whichever block happens to contain
-- matching row numbers. Nothing here backfills, and nothing may infer
-- attribution from row ranges, block-name similarity, current geometry,
-- vineyard size or chemical history.
--
-- `'[]'::jsonb` / `'{}'::uuid[]` are therefore REJECTED (section 3): an empty
-- array would be a third state meaning "recorded as treating nothing", which is
-- not a thing a spray can do. Absence is spelled NULL and only NULL.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. The columns.
-- ---------------------------------------------------------------------------
alter table public.spray_records
  add column if not exists application_blocks jsonb  null,
  add column if not exists block_ids          uuid[] null;

-- ---------------------------------------------------------------------------
-- 2. Structural validation of the JSONB snapshot.
--
-- Deliberately shallow: shape and identity are enforced, per-block MEASUREMENTS
-- are not constrained here. The client already refuses to persist a
-- non-positive row length or area (it maps them to absent), and re-encoding
-- those numeric rules in SQL would create a second, drifting definition of the
-- same contract. What SQL guards is what SQL is uniquely able to guard: that
-- every element is an object carrying a parseable uuid `blockId`.
-- ---------------------------------------------------------------------------
create or replace function public.spray_block_attribution_is_valid(p_blocks jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path = public
as $$
  select
    case
      when p_blocks is null then true
      when jsonb_typeof(p_blocks) <> 'array' then false
      when jsonb_array_length(p_blocks) = 0 then false
      else not exists (
        select 1
          from jsonb_array_elements(p_blocks) as e(value)
         where jsonb_typeof(e.value) <> 'object'
            or nullif(btrim(coalesce(e.value ->> 'blockId', '')), '') is null
            or btrim(e.value ->> 'blockId') !~*
               '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
    end
$$;

comment on function public.spray_block_attribution_is_valid(jsonb) is
  'True when a spray_records.application_blocks value is NULL, or a non-empty JSONB array whose every element is an object with a parseable uuid blockId. An EMPTY array is invalid: absence of attribution is spelled NULL, never [].';

-- ---------------------------------------------------------------------------
-- 3. Constraints. Every one is NULL-tolerant so existing rows validate
--    unchanged, and each is added conditionally so re-running is safe.
-- ---------------------------------------------------------------------------
do $$
begin
  -- Shape + uuid identity of the structured snapshot.
  if not exists (
    select 1 from pg_constraint where conname = 'spray_records_application_blocks_check'
  ) then
    alter table public.spray_records
      add constraint spray_records_application_blocks_check
      check (public.spray_block_attribution_is_valid(application_blocks));
  end if;

  -- The id projection: non-empty when present, no NULL elements, no duplicates.
  -- Duplicates are rejected rather than silently tolerated because a block that
  -- appears twice in one application would be counted twice by a per-block
  -- resistance history. The client normalises before writing; this is the
  -- backstop that makes the normalisation non-optional.
  if not exists (
    select 1 from pg_constraint where conname = 'spray_records_block_ids_check'
  ) then
    alter table public.spray_records
      add constraint spray_records_block_ids_check
      check (
        block_ids is null
        or (
          array_length(block_ids, 1) >= 1
          and array_position(block_ids, null) is null
          and array_length(block_ids, 1) = (
            select count(distinct b) from unnest(block_ids) as u(b)
          )
        )
      );
  end if;

  -- The two columns are recorded together or not at all. Prevents a row that
  -- has a queryable projection but no explainable snapshot behind it.
  if not exists (
    select 1 from pg_constraint where conname = 'spray_records_block_attribution_paired_check'
  ) then
    alter table public.spray_records
      add constraint spray_records_block_attribution_paired_check
      check ((application_blocks is null) = (block_ids is null));
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- 4. `block_ids` is DERIVED, never authored.
--
-- The invariant this protects is the one the audit called out explicitly: a
-- record whose geometry was calculated from blocks A+C must never claim it
-- treated A+B. Because `application_blocks` IS the per-block geometry snapshot,
-- deriving the projection from it — inside the write path, on every insert and
-- update — makes that divergence unrepresentable rather than merely tested for.
--
-- Order is preserved (first occurrence wins) so the stored projection reads in
-- the same order the operator selected, and duplicates are collapsed here so a
-- client that sends the same block twice is normalised rather than rejected.
-- ---------------------------------------------------------------------------
create or replace function public.spray_records_derive_block_ids()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.application_blocks is null then
    -- No structured snapshot ⇒ no projection. Guarantees "unknown" cannot be
    -- half-recorded, and makes the paired CHECK unfailable from this path.
    new.block_ids := null;
    return new;
  end if;

  select array_agg(block_id order by first_ordinality)
    into new.block_ids
    from (
      select (btrim(e.value ->> 'blockId'))::uuid as block_id,
             min(e.ordinality)                    as first_ordinality
        from jsonb_array_elements(new.application_blocks) with ordinality as e(value, ordinality)
       group by 1
    ) distinct_blocks;

  return new;
end$$;

comment on function public.spray_records_derive_block_ids() is
  'Derives spray_records.block_ids from application_blocks on every write, preserving first-occurrence order and collapsing duplicates. block_ids is a projection and is never authored independently, so the queryable ids can never disagree with the per-block geometry snapshot they came from.';

drop trigger if exists trg_spray_records_derive_block_ids on public.spray_records;

create trigger trg_spray_records_derive_block_ids
  before insert or update of application_blocks, block_ids
  on public.spray_records
  for each row
  execute function public.spray_records_derive_block_ids();

-- ---------------------------------------------------------------------------
-- 5. Vineyard isolation.
--
-- A spray must not claim to have treated a block in someone else's vineyard.
--
-- The check is deliberately ASYMMETRIC and that asymmetry is the point:
--   * A block that EXISTS and belongs to a DIFFERENT vineyard ⇒ rejected.
--   * A block id that matches NO paddock row ⇒ ALLOWED.
--
-- The second case is why this is a trigger and not a foreign key. A uuid[] can
-- carry no FK, but more importantly a completed spray is a compliance document:
-- when a block is later deleted or archived, the historical application must
-- keep saying which block it treated. An FK (or an existence check) would force
-- the system to either cascade the id away or refuse the write — both of which
-- destroy history to satisfy referential tidiness. Unknown ids are preserved
-- and the clients render them from the `blockName` snapshot.
-- ---------------------------------------------------------------------------
create or replace function public.spray_records_validate_block_vineyard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_foreign uuid;
begin
  if new.block_ids is null then
    return new;
  end if;

  select p.id
    into v_foreign
    from public.paddocks p
   where p.id = any(new.block_ids)
     and p.vineyard_id is distinct from new.vineyard_id
   limit 1;

  if v_foreign is not null then
    raise exception
      'spray_records.block_ids contains block % which belongs to a different vineyard than the spray record',
      v_foreign
      using errcode = '23514';
  end if;

  return new;
end$$;

comment on function public.spray_records_validate_block_vineyard() is
  'Rejects a spray record whose block_ids reference a paddock in a different vineyard. Block ids matching no paddock row are ALLOWED so a deleted or archived block never erases the historical attribution of a completed spray.';

drop trigger if exists trg_spray_records_validate_block_vineyard on public.spray_records;

create trigger trg_spray_records_validate_block_vineyard
  after insert or update of application_blocks, block_ids, vineyard_id
  on public.spray_records
  for each row
  execute function public.spray_records_validate_block_vineyard();

-- ---------------------------------------------------------------------------
-- 6. Index for per-block history queries.
--
-- The Resistance Engine's access pattern is "every application that treated
-- THIS block, chronologically, within this vineyard". GIN over the uuid[]
-- serves the containment predicate:
--
--   select * from spray_records
--    where vineyard_id = $1 and block_ids @> array[$2]::uuid[]
--    order by date;
--
-- Partial (`where block_ids is not null`) so the index carries only attributed
-- rows and historical NULLs cost nothing.
-- ---------------------------------------------------------------------------
create index if not exists idx_spray_records_block_ids
  on public.spray_records using gin (block_ids)
  where block_ids is not null;

-- ---------------------------------------------------------------------------
-- 7. Documentation.
-- ---------------------------------------------------------------------------
comment on column public.spray_records.application_blocks is
  'AUTHORITATIVE record of which blocks this application actually treated, as an ordered JSONB array. Per element: blockId (uuid, REQUIRED — stable identity, never a name), blockName (display snapshot for exports and for blocks later renamed/deleted), grossAreaHa, rowLengthMetres, rowSpacingMetres, rowCount, geometrySource, geometryQuality (the per-block breakdown of the sql/191 aggregate geometry — same ids, same numbers, summed). NULL means BLOCKS NOT RECORDED: a record written before sql/195. NULL never means all blocks, no blocks, the vineyard''s current blocks, or the block containing matching row numbers. NEVER backfill it, and never infer it from row ranges, name similarity, current geometry or chemical history.';

comment on column public.spray_records.block_ids is
  'Queryable projection of application_blocks[].blockId, GIN-indexed for per-block history lookups. DERIVED BY TRIGGER on every write — never authored independently — so it can never disagree with the per-block geometry snapshot. Order matches the operator''s selection; duplicates collapsed. NULL exactly when application_blocks is NULL, meaning blocks not recorded. An empty array is rejected: absence is NULL and only NULL.';

commit;

-- =============================================================================
-- ROLLBACK
--
-- Additive only, so rollback is a pure drop. No data recovery step is needed
-- and no legacy field is touched: every pre-195 record already reads as
-- "blocks not recorded" and continues to do so.
--
-- begin;
--   drop index if exists public.idx_spray_records_block_ids;
--   drop trigger if exists trg_spray_records_validate_block_vineyard on public.spray_records;
--   drop trigger if exists trg_spray_records_derive_block_ids on public.spray_records;
--   drop function if exists public.spray_records_validate_block_vineyard();
--   drop function if exists public.spray_records_derive_block_ids();
--   -- CHECK constraints drop automatically with their columns.
--   alter table public.spray_records
--     drop column if exists block_ids,
--     drop column if exists application_blocks;
--   drop function if exists public.spray_block_attribution_is_valid(jsonb);
-- commit;
--
-- END 195
--
-- Manual actions after applying:
--   * run sql/tests/195_spray_block_attribution_tests.sql
--   * NO backfill. Historical records intentionally keep NULL in both columns
--     and MUST continue to read as "blocks not recorded".
--   * `spray_jobs` is deliberately NOT changed. Planned jobs and templates
--     already carry their intended blocks in the `spray_job_paddocks` junction
--     (sql/032); adding a second representation there is exactly the
--     disconnected-list mistake this migration exists to avoid. Templates
--     stored as `spray_records` rows (is_template = true) use the columns above
--     and keep block IDENTITY as reusable intent while dropping the per-block
--     geometry OUTPUTS, mirroring the sql/191 template rule.
--   * supabase/functions/vinetrack-api DOES need redeploying to publish the new
--     fields (it selects an explicit column list):
--       supabase functions deploy vinetrack-api --project-ref <ref>
--   * Lovable/portal: CONSUME this contract only. Read `block_ids` for
--     filtering and `application_blocks` for display. Do NOT write `block_ids`
--     directly (the trigger overwrites it), do NOT backfill historical rows,
--     and do NOT render the vineyard's current blocks for a record whose
--     attribution is NULL — show "Blocks not recorded".
-- =============================================================================

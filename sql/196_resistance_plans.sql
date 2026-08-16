-- =============================================================================
-- 196: Resistance Plans — vineyard-scoped, synced, multi-device season plans.
--
-- Rork/VineTrack mobile is the SOURCE OF TRUTH for this contract. Lovable (the
-- web portal) CONSUMES it and MUST NOT independently create or modify any of
-- these columns, functions or policies, nor invent a competing representation.
-- The persistence contract is documented in docs/resistance-plan-persistence.md.
--
-- ---------------------------------------------------------------------------
-- WHY (what the audit found)
-- ---------------------------------------------------------------------------
-- Resistance Planner v1 shipped with plans in UserDefaults (iOS) and
-- SharedPreferences (Android). For a tool whose entire purpose is SEASON-LONG
-- planning that is a real defect, not a cosmetic one:
--
--   * a plan does not follow the grower from the ute iPad to the office phone;
--   * the manager who authored "2026/27 Powdery Plan" is the only person alive
--     who can see it — a spray operator cannot open the plan they are meant to
--     be executing;
--   * reinstalling the app destroys the plan silently.
--
-- There is NO existing table this can borrow. Every audited candidate is
-- either a fixed-column user-preference row (operational tool layout, button
-- templates, fertiliser defaults, GDD settings) or local-only. Hence a new
-- table.
--
-- ---------------------------------------------------------------------------
-- THE LOAD-BEARING DESIGN RULE: THIS TABLE STORES FACTS, NEVER VERDICTS
-- ---------------------------------------------------------------------------
-- There is deliberately NO column for "Good fit", "Would exceed strategy",
-- warning text, resistance counters, threshold results or rendered
-- explanations. A resistance verdict is a function of THREE inputs:
--
--     plan positions  +  actual spray history  +  ruleset
--
-- Two of those change after the plan is saved. The moment an operator records
-- an unplanned Group 3 spray, every stored "Good fit" in this table would
-- become a lie that looks authoritative. Storing the verdict would turn a
-- stale cache into compliance advice, so the verdict is recomputed on every
-- load from `spray_records` (sql/193 targets + sql/195 block attribution) and
-- the client's ruleset registry. What is persisted here is only what a human
-- actually decided: which chemistry, in which order, for which blocks.
--
-- ---------------------------------------------------------------------------
-- WHY positions IS JSONB AND NOT A JOIN TABLE
-- ---------------------------------------------------------------------------
-- Audited against the implemented model, and JSONB is correct here:
--
--   * PLAN ORDER IS THE DOMAIN FACT. The engine derives planned chronology
--     from array order, not from dates (a stale target date must never be able
--     to contradict the sequence the operator is looking at). An ordered array
--     represents that natively; a join table would need a sort_index column
--     that could drift out of step with itself after a reorder.
--   * A plan is edited AS ONE DOCUMENT. Add, reorder, remove and re-evaluate
--     all happen together in one screen and are saved as one write. That makes
--     the whole-document conflict story (section 7) honest and simple.
--   * v1 HAS NO QUERY that selects across individual positions. Nothing asks
--     "every position using Group 11 across all plans". The moment something
--     does, a GIN index on this column serves it without a migration.
--   * POSITION IDS ARE ALREADY STABLE inside the document, so the future
--     planned-position <-> actual-spray association has a durable target
--     without needing a row of its own.
--
-- A join table would add a second source of truth for ordering and a cascade
-- path into planning data, buying nothing v1 needs. Structure is enforced by
-- the validator in section 3 instead, so "JSONB" does not mean "unvalidated".
--
-- ---------------------------------------------------------------------------
-- WHY block_ids IS uuid[] WITH NO FOREIGN KEY
-- ---------------------------------------------------------------------------
-- Same historical-survival principle as sql/195. A resistance plan must NOT be
-- destroyed or silently altered because a block was later archived or deleted.
-- `references paddocks(id) on delete cascade` would erase a season's planning
-- because someone tidied up a block list; `on delete set null` would corrupt
-- the plan into covering nothing. Instead the ids are stored plainly, validated
-- against the vineyard AT WRITE TIME (section 5) so a foreign vineyard's block
-- can never be attached, and thereafter left alone. A plan referencing a
-- deleted block keeps the id and the client renders it as unavailable.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES
-- ---------------------------------------------------------------------------
-- STRICTLY ADDITIVE. One new table, its validators, indexes, RLS policies and
-- a soft-delete RPC. NOTHING existing is altered: no column added to
-- spray_records, no change to chemicals, paddocks, spray history, snapshots,
-- targets or block attribution. Deleting a plan CANNOT delete a spray record,
-- a chemical or any resistance history — there is no FK from this table into
-- operational data at all, by design (section 9).
--
-- Verification: sql/tests/196_resistance_plans_tests.sql (rollback-only).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Structural validator for the positions document.
--
-- JSONB is not an excuse for an unvalidated blob. This enforces exactly the
-- shape both clients serialise (ResistancePlan.swift / ResistancePlan.kt) and
-- nothing more, so the portal cannot later write a variant shape that the
-- mobile decoder silently drops.
--
-- Enforced:
--   * top level is a JSON ARRAY (an object or scalar is rejected);
--   * every element is an OBJECT;
--   * every element has a non-empty text `id`  -> stable position identity;
--   * position ids are UNIQUE within the plan  -> "Spray 4" resolves to one
--     position, and a future actual-spray association can never be ambiguous;
--   * `products`, when present, is an ARRAY of OBJECTS;
--   * every product's `group_codes`, when present, is an ARRAY of strings;
--   * every product has a non-empty text `id`;
--   * `source`, when present, is one of the two known sources.
--
-- Deliberately NOT enforced: that a position HAS chemistry. An empty position
-- is a legitimate work-in-progress slot the operator created but has not
-- filled, and rejecting it would make the server refuse to save a half-built
-- plan — losing the grower's work in the name of tidiness.
-- ---------------------------------------------------------------------------
create or replace function public.resistance_plan_positions_are_valid(p_positions jsonb)
returns boolean
language plpgsql
immutable
as $$
declare
  v_position jsonb;
  v_product  jsonb;
  v_code     jsonb;
  v_ids      text[] := '{}';
  v_id       text;
begin
  if p_positions is null then
    return true;
  end if;

  if jsonb_typeof(p_positions) <> 'array' then
    return false;
  end if;

  for v_position in select value from jsonb_array_elements(p_positions) loop
    if jsonb_typeof(v_position) <> 'object' then
      return false;
    end if;

    v_id := v_position->>'id';
    if v_id is null or length(trim(v_id)) = 0 then
      return false;
    end if;
    if v_id = any(v_ids) then
      -- Duplicate position id: two slots claiming one identity.
      return false;
    end if;
    v_ids := v_ids || v_id;

    if v_position ? 'products' and jsonb_typeof(v_position->'products') <> 'null' then
      if jsonb_typeof(v_position->'products') <> 'array' then
        return false;
      end if;

      for v_product in select value from jsonb_array_elements(v_position->'products') loop
        if jsonb_typeof(v_product) <> 'object' then
          return false;
        end if;

        if v_product->>'id' is null or length(trim(v_product->>'id')) = 0 then
          return false;
        end if;

        if v_product ? 'source'
           and jsonb_typeof(v_product->'source') <> 'null'
           and (v_product->>'source') not in ('group', 'saved_chemical') then
          return false;
        end if;

        if v_product ? 'group_codes' and jsonb_typeof(v_product->'group_codes') <> 'null' then
          if jsonb_typeof(v_product->'group_codes') <> 'array' then
            return false;
          end if;
          for v_code in select value from jsonb_array_elements(v_product->'group_codes') loop
            if jsonb_typeof(v_code) <> 'string' then
              return false;
            end if;
          end loop;
        end if;
      end loop;
    end if;
  end loop;

  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Validator for the block id array.
--
-- NULL is allowed (a plan whose blocks have not been chosen yet).
-- An EMPTY array is allowed and means "no blocks selected yet" — unlike
-- sql/195, where an empty attribution array would have been a nonsense third
-- state, an unfinished plan genuinely has no blocks.
-- A NULL ELEMENT is rejected: "one of these blocks is nothing" is not a
-- statement a plan can make.
-- DUPLICATES are rejected: a block evaluated twice would be counted twice in
-- multi-block aggregation.
-- ---------------------------------------------------------------------------
create or replace function public.resistance_plan_block_ids_are_valid(p_ids uuid[])
returns boolean
language sql
immutable
as $$
  select case
    when p_ids is null then true
    when array_position(p_ids, null) is not null then false
    when array_length(p_ids, 1) is null then true
    when (select count(distinct x) from unnest(p_ids) as t(x)) <> array_length(p_ids, 1) then false
    else true
  end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The table.
--
-- Column names match the clients' wire keys exactly (snake_case, `group_codes`
-- inside the document) so the row and the JSON document never disagree about
-- what a field is called.
-- ---------------------------------------------------------------------------
create table if not exists public.resistance_plans (
  id                 uuid primary key default gen_random_uuid(),
  vineyard_id        uuid not null references public.vineyards(id) on delete cascade,

  -- Season identity as the clients model it: "2026/27". Never a bare calendar
  -- year, because an Australian season spans two of them. `season_start_year`
  -- is the sortable/queryable projection of the same fact.
  season_id          text not null,
  season_start_year  integer null,

  -- Domain vocabulary. Stored as text with a LOOSE guard (section 4) rather
  -- than an enum: botrytis, black spot and eutypa are foreseeable additions,
  -- and a hard enum would require a migration on both platforms plus a
  -- deployment ordering dance before a new disease could even be saved.
  disease            text not null,
  jurisdiction       text not null default 'AU',
  crop               text not null default 'grape',

  -- Blocks covered. Deliberately NOT a foreign key — see header.
  block_ids          uuid[] null,

  -- The ordered planned chemistry. Order IS the planned chronology.
  positions          jsonb not null default '[]'::jsonb,

  notes              text null,

  -- The strategy this plan was authored under. See section 4 for why these are
  -- required once a plan has real content.
  ruleset_id         text null,
  ruleset_version    text null,

  -- Attribution, NOT a visibility scope. Plans are vineyard data; every
  -- authorised member reads them (section 8).
  created_by         uuid references auth.users(id),
  updated_by         uuid references auth.users(id),

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz null,

  -- Offline conflict resolution, matching the sql/185 contract used by every
  -- other client-upserted table.
  client_updated_at  timestamptz null,
  sync_version       integer not null default 1
);

-- ---------------------------------------------------------------------------
-- 4. Constraints.
--
-- Each one is added defensively so re-running the migration is safe.
-- ---------------------------------------------------------------------------

-- positions must be a well-formed ordered document.
do $$
begin
  alter table public.resistance_plans
    add constraint resistance_plans_positions_valid
    check (public.resistance_plan_positions_are_valid(positions));
exception when duplicate_object then null;
end $$;

-- block ids must be clean.
do $$
begin
  alter table public.resistance_plans
    add constraint resistance_plans_block_ids_valid
    check (public.resistance_plan_block_ids_are_valid(block_ids));
exception when duplicate_object then null;
end $$;

-- A season id is meaningless if blank.
do $$
begin
  alter table public.resistance_plans
    add constraint resistance_plans_season_id_present
    check (length(trim(season_id)) > 0);
exception when duplicate_object then null;
end $$;

-- Season start year: sanity bounds only, wide enough to be useless as a cage.
do $$
begin
  alter table public.resistance_plans
    add constraint resistance_plans_season_start_year_sane
    check (season_start_year is null or season_start_year between 1900 and 2200);
exception when duplicate_object then null;
end $$;

-- Disease/jurisdiction/crop: NON-EMPTY and lower-case-normalised, NOT an
-- allow-list of today's two diseases.
--
-- This is a deliberate restraint. A CHECK pinned to
-- ('powdery_mildew','downy_mildew') would mean that the day botrytis rules are
-- authored, every client that saves a botrytis plan gets a 400 from a database
-- constraint until a migration lands — a schema change gating a client feature
-- flag. The real guard against a nonsense disease is the client's enum plus the
-- ruleset registry: a disease with no ruleset simply cannot be evaluated, which
-- is a far better failure than a rejected write.
--
-- Jurisdiction IS constrained to the ISO-style codes the clients emit, because
-- that vocabulary is small, external and stable ('AU', 'NZ', 'unknown').
do $$
begin
  alter table public.resistance_plans
    add constraint resistance_plans_disease_present
    check (length(trim(disease)) > 0 and disease = lower(disease));
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.resistance_plans
    add constraint resistance_plans_jurisdiction_known
    check (jurisdiction in ('AU', 'NZ', 'unknown'));
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.resistance_plans
    add constraint resistance_plans_crop_present
    check (length(trim(crop)) > 0 and crop = lower(crop));
exception when duplicate_object then null;
end $$;

-- RULESET METADATA IS REQUIRED ONCE A PLAN HAS CONTENT.
--
-- A plan with planned chemistry but no recorded strategy version is a
-- compliance trap: when the 2027 CropLife strategy lands there is no way to
-- tell whether the plan predates it, so VineTrack would either silently
-- re-interpret it under the new rules or be unable to say anything at all.
--
-- An EMPTY plan (no positions) is exempt: a freshly created plan the grower is
-- still filling in has not been evaluated under any strategy yet, and refusing
-- to save it would lose their work at the very first keystroke.
do $$
begin
  alter table public.resistance_plans
    add constraint resistance_plans_ruleset_required_when_planned
    check (
      jsonb_array_length(positions) = 0
      or (
        ruleset_id is not null and length(trim(ruleset_id)) > 0
        and ruleset_version is not null and length(trim(ruleset_version)) > 0
      )
    );
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Cross-vineyard block guard.
--
-- Validated at WRITE TIME and never afterwards. This is the honest place for
-- the check: at the moment of writing, the client knows which vineyard it is
-- operating in, so attaching another vineyard's block is a bug worth
-- rejecting. Later, when that block may have been archived, re-validating
-- would only serve to make an existing plan unsavable.
--
-- An id matching NO paddock at all is ALLOWED — that is how a plan survives
-- the deletion of one of its blocks (header). Only ids belonging to a
-- DIFFERENT vineyard are rejected.
-- ---------------------------------------------------------------------------
create or replace function public.resistance_plans_validate_block_vineyard()
returns trigger
language plpgsql
as $$
declare
  v_foreign uuid;
begin
  if new.block_ids is null or array_length(new.block_ids, 1) is null then
    return new;
  end if;

  select p.id into v_foreign
  from public.paddocks p
  where p.id = any(new.block_ids)
    and p.vineyard_id <> new.vineyard_id
  limit 1;

  if v_foreign is not null then
    raise exception 'Block % belongs to a different vineyard', v_foreign
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists resistance_plans_validate_block_vineyard on public.resistance_plans;
create trigger resistance_plans_validate_block_vineyard
before insert or update of block_ids, vineyard_id on public.resistance_plans
for each row execute function public.resistance_plans_validate_block_vineyard();

-- ---------------------------------------------------------------------------
-- 6. Attribution guard — created_by is write-once.
--
-- Same defect sql/185 fixed for picking_records: both clients push edits
-- through the SAME upsert as creates, so without this the last editor
-- overwrites the original author and "who planned this season" is lost on the
-- first edit by a colleague.
-- ---------------------------------------------------------------------------
create or replace function public.resistance_plans_attribution_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    if new.created_by is null then
      new.created_by := auth.uid();
    end if;
    if new.updated_by is null then
      new.updated_by := auth.uid();
    end if;
  else
    -- Preserve the original author whatever the client sends.
    new.created_by := old.created_by;
    if auth.uid() is not null then
      new.updated_by := auth.uid();
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists resistance_plans_attribution_guard on public.resistance_plans;
create trigger resistance_plans_attribution_guard
before insert or update on public.resistance_plans
for each row execute function public.resistance_plans_attribution_guard();

-- ---------------------------------------------------------------------------
-- 7. Stale-write protection (the conflict strategy).
--
-- Reuses the EXISTING sql/185 guard rather than inventing a scheme: an UPDATE
-- whose client_updated_at is OLDER than the stored one is skipped silently.
--
-- Conflict order this protects:
--   1. Device A edits the plan offline           (client_updated_at = T1)
--   2. Device B reorders positions online        (T2 > T1) — applied
--   3. Device A reconnects and replays its edit  (T1)     — SKIPPED
--   4. B's version stays authoritative; A converges on it at its next pull.
--
-- WHOLE-DOCUMENT, NOT MERGED. Two independently reordered position arrays are
-- never merged field-by-field. There is no defensible automatic merge of
-- "A moved the Group 11 spray to position 2" against "B deleted position 2":
-- any row-wise merge could silently produce a sequence NEITHER operator
-- authored and then present it as a resistance-compliant plan. Losing the
-- older edit is recoverable and visible; inventing a third plan is not.
-- ---------------------------------------------------------------------------
drop trigger if exists resistance_plans_stale_write_guard on public.resistance_plans;
create trigger resistance_plans_stale_write_guard
before update on public.resistance_plans
for each row execute function public.reject_stale_client_write();

create or replace trigger resistance_plans_set_updated_at
before update on public.resistance_plans
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 8. Indexes.
-- ---------------------------------------------------------------------------
create index if not exists idx_resistance_plans_vineyard
  on public.resistance_plans (vineyard_id);

-- The plan-list query: this vineyard's live plans, newest first.
create index if not exists idx_resistance_plans_vineyard_live
  on public.resistance_plans (vineyard_id, updated_at desc)
  where deleted_at is null;

-- The Planner's own lookup: plans for a season + disease.
create index if not exists idx_resistance_plans_season_disease
  on public.resistance_plans (vineyard_id, season_id, disease)
  where deleted_at is null;

create index if not exists idx_resistance_plans_deleted_at
  on public.resistance_plans (deleted_at);

-- "Which plans cover this block" — serves future plan-vs-actual work without
-- needing a join table.
create index if not exists idx_resistance_plans_block_ids
  on public.resistance_plans using gin (block_ids);

-- ---------------------------------------------------------------------------
-- 9. RLS — vineyard data, shared with the team.
--
-- Follows the established sql/180 operational pattern exactly; no new
-- permission concept is invented.
--
--   READ    any vineyard member. A spray operator must be able to open the
--           plan they are expected to execute. Scoping reads to created_by
--           would make a "shared season plan" private by construction.
--   WRITE   the operational-write roles, same set that may log a spray.
--   DELETE  no client hard delete, ever (see below).
-- ---------------------------------------------------------------------------
alter table public.resistance_plans enable row level security;

drop policy if exists "resistance_plans_select_members" on public.resistance_plans;
create policy "resistance_plans_select_members"
on public.resistance_plans for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "resistance_plans_insert_members" on public.resistance_plans;
create policy "resistance_plans_insert_members"
on public.resistance_plans for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "resistance_plans_update_members" on public.resistance_plans;
create policy "resistance_plans_update_members"
on public.resistance_plans for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

-- HARD DELETE IS DENIED TO ALL CLIENTS.
--
-- Not merely a tidiness preference. A hard delete is invisible to other
-- devices: Device B, holding the plan in its local cache, has nothing to
-- observe and would happily push the plan back on its next sync, resurrecting
-- it. The tombstone is what makes a delete propagate.
drop policy if exists "resistance_plans_no_client_hard_delete" on public.resistance_plans;
create policy "resistance_plans_no_client_hard_delete"
on public.resistance_plans for delete
to authenticated
using (false);

-- ---------------------------------------------------------------------------
-- 10. Soft delete RPC.
--
-- Deleting a PLAN deletes ADVISORY PLANNING DATA AND NOTHING ELSE. There is no
-- cascade, trigger or FK from this table into spray_records, saved_chemicals,
-- spray_targets, application_blocks or any snapshot — so this statement cannot
-- reach operational history even in principle. A plan is what someone intended;
-- history is what actually happened, and one must never erase the other.
-- ---------------------------------------------------------------------------
create or replace function public.soft_delete_resistance_plan(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select vineyard_id into v_vineyard_id
  from public.resistance_plans
  where id = p_id;

  if v_vineyard_id is null then
    raise exception 'Resistance plan not found' using errcode = 'P0002';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'Insufficient permissions to delete resistance plan' using errcode = '42501';
  end if;

  update public.resistance_plans
     set deleted_at = now(),
         updated_by = auth.uid()
   where id = p_id
     and deleted_at is null;
end;
$$;

revoke all on function public.soft_delete_resistance_plan(uuid) from public;
grant execute on function public.soft_delete_resistance_plan(uuid) to authenticated;

-- Restore, for an accidental archive. Cheap to provide now that the tombstone
-- exists, and its absence would push users toward rebuilding a season by hand.
create or replace function public.restore_resistance_plan(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select vineyard_id into v_vineyard_id
  from public.resistance_plans
  where id = p_id;

  if v_vineyard_id is null then
    raise exception 'Resistance plan not found' using errcode = 'P0002';
  end if;

  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'Insufficient permissions to restore resistance plan' using errcode = '42501';
  end if;

  update public.resistance_plans
     set deleted_at = null,
         updated_by = auth.uid()
   where id = p_id;
end;
$$;

revoke all on function public.restore_resistance_plan(uuid) from public;
grant execute on function public.restore_resistance_plan(uuid) to authenticated;

commit;

-- =============================================================================
-- POST-MIGRATION NOTES
--
-- 1. NOT EXPOSED IN vinetrack-api. Resistance Plans are not added to the public
--    API surface by this migration. The API's current stage covers operational
--    records, not planning resources, and broadening it would commit to a
--    public contract for a v1 feature whose shape is still settling. Mobile
--    sync uses the direct shared backend contract. Documented as a future item.
--
-- 2. LOVABLE consumes this table read-only until the portal work is scheduled.
--    Rork/mobile owns the schema. See docs/resistance-plan-persistence.md.
--
-- 3. NO BACKFILL. Existing local-only plans are adopted by the CLIENTS on first
--    synced launch (one-time, id-preserving, idempotent), not by SQL — the
--    server has never seen them, so only the device can supply them.
-- =============================================================================

-- =============================================================================
-- 197: SECURITY REPAIR — make the sql/195 spray block attribution guard see
--      foreign paddocks that RLS hides from the caller.
--
-- Rork/VineTrack mobile remains the SOURCE OF TRUTH for the block attribution
-- contract. Lovable (the web portal) CONSUMES it. This migration changes NO
-- part of that contract: no column, no constraint, no trigger, no semantics.
-- It replaces the BODY-IDENTICAL guard function with one privilege change.
--
-- ---------------------------------------------------------------------------
-- THE DEFECT (confirmed, live in production)
-- ---------------------------------------------------------------------------
-- `public.spray_records_validate_block_vineyard()` (sql/195 section 5) rejects a
-- spray record whose `block_ids` reference a paddock owned by a DIFFERENT
-- vineyard. It answers that question by reading `public.paddocks`.
--
-- It was created WITHOUT `security definer`, so it executes with the privileges
-- of the calling user. `public.paddocks` has RLS enabled (sql/005) and its
-- SELECT policy is:
--
--     using (public.is_vineyard_member(vineyard_id))
--
-- So for a caller who is NOT a member of the foreign vineyard, the guard's own
-- lookup is filtered by that policy:
--
--     select p.id from public.paddocks p
--      where p.id = any(new.block_ids)
--        and p.vineyard_id is distinct from new.vineyard_id
--
-- returns ZERO ROWS — not because the block is legitimate, but because the
-- caller cannot see it. `v_foreign` stays NULL, no exception is raised, and the
-- cross-vineyard block id is PERSISTED.
--
-- The guard is therefore strongest against the harmless case (a user who can
-- see both vineyards) and blind in exactly the case it exists to stop (a user
-- referencing a vineyard that is not theirs). RLS silently converted a security
-- check into a no-op.
--
-- This is the same class of defect as sql/196 T9. It is fixed here the same way.
--
-- ---------------------------------------------------------------------------
-- WHY THE sql/195 TEST SUITE PASSED ANYWAY
-- ---------------------------------------------------------------------------
-- `sql/tests/195_spray_block_attribution_tests.sql` never switches role. It runs
-- as the migration/table owner, and a table owner BYPASSES RLS. Under owner
-- rights the guard's lookup does see the foreign paddock, so T11 ("a block from
-- another vineyard was accepted") passed — and would pass against this defect
-- forever. The bug is invisible to any owner-role test by construction. See
-- sql/tests/195_spray_block_attribution_tests.sql T18, added alongside this
-- migration, and sql/tests/197_fix_spray_block_vineyard_guard_tests.sql.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES / DOES NOT DO
-- ---------------------------------------------------------------------------
-- DOES:  add `security definer` to one existing function, keeping its explicit
--        `set search_path = public`, its logic, its error and its errcode.
--
-- DOES NOT: touch `spray_records` columns, the CHECK constraints, the
--        `block_ids` derivation trigger, the GIN index, the asymmetric
--        unknown-id rule, or the attribution semantics. sql/195 is NOT
--        redesigned and NOT edited — a migration that has already been applied
--        must never be rewritten in place, because editing it changes only the
--        repository, never the database.
--
-- The ONLY intended production behaviour change:
--   a block id belonging to another vineyard is now rejected EVEN WHEN RLS
--   would hide that paddock from the caller.
--
-- Unchanged, and re-asserted by the tests:
--   * block in the SAME vineyard              -> accepted
--   * block id matching NO paddock row        -> accepted, identity retained
--   * block later deleted or archived         -> historical row keeps its ids
-- The fix must not become a foreign-key requirement, which is why the lookup
-- still only rejects paddocks that EXIST and disagree about the vineyard.
-- =============================================================================

begin;

-- Refuse to run if sql/195 was never applied: replacing a function that does
-- not exist would silently CREATE a guard on a table with no attribution
-- columns, leaving a half-configured contract behind.
do $$
begin
  if to_regprocedure('public.spray_records_validate_block_vineyard()') is null then
    raise exception
      'SQL 195 not applied — run sql/195_spray_block_attribution.sql before this repair.';
  end if;

  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.spray_records'::regclass
       and tgname  = 'trg_spray_records_validate_block_vineyard'
       and not tgisinternal
  ) then
    raise exception
      'SQL 195 guard trigger trg_spray_records_validate_block_vineyard is missing — investigate before repairing.';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- 1. The repair.
--
-- CREATE OR REPLACE (not DROP + CREATE) is deliberate and is what keeps this
-- migration safe: replace preserves the function's OID, so the EXISTING sql/195
-- trigger keeps pointing at it with no window during which `spray_records` has
-- no vineyard-isolation guard at all. Dropping the function would require
-- dropping its trigger first (dependency), and any write landing in between
-- would be unguarded.
--
-- `security definer` makes the lookup run as the function OWNER. The owner owns
-- `paddocks`, and a table owner bypasses RLS, so the guard can finally see every
-- paddock it must compare against. This does NOT widen what the CALLER can do:
-- the caller's own INSERT/UPDATE is still filtered by the `spray_records` RLS
-- policies, and the elevated rights exist only for the duration of this
-- read-only existence check.
--
-- `set search_path = public` was already present in sql/195 and is retained
-- verbatim. It is mandatory for a definer function — without a pinned
-- search_path a caller could point `paddocks` at their own object and run code
-- as the owner. Retained here, so nothing regresses.
--
-- The body below is CHARACTER-FOR-CHARACTER the sql/195 body, including the
-- `is distinct from` comparison and the `limit 1`. No behavioural drift.
-- ---------------------------------------------------------------------------
create or replace function public.spray_records_validate_block_vineyard()
returns trigger
language plpgsql
security definer
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

-- ---------------------------------------------------------------------------
-- 2. Information leakage: nothing new is disclosed.
--
-- The elevated read is used ONLY to decide accept/reject. The message keeps the
-- sql/195 wording, which interpolates `v_foreign` — a block id the CALLER
-- ITSELF just submitted. Echoing back the caller's own input tells them nothing
-- they did not already know.
--
-- Deliberately NOT disclosed, despite now being readable inside the function:
--   * the owning vineyard's id
--   * the owning vineyard's or block's name
--   * any membership, owner or attribute of the foreign vineyard
--   * whether the id exists at all (an unknown id is ACCEPTED and an existing
--     foreign id is REJECTED, so a rejection reveals "not yours" — which the
--     caller established by sending it — and an acceptance reveals nothing)
--
-- The wording is preserved rather than genericised on purpose: no client or
-- edge function matches on this text today (verified), but the sql/195 suite's
-- T11 and the messages operators may already have in support tickets both refer
-- to it, and changing a string is a behavioural change this repair has no
-- mandate to make. It already satisfies the generic-error requirement.
--
-- Direct invocation is not a leak vector either: PostgreSQL refuses to call a
-- `returns trigger` function from SQL (`trigger functions can only be called as
-- triggers`), so no caller can use it as an oracle to probe for paddock
-- existence. EXECUTE grants are therefore left exactly as sql/195 left them —
-- revoking them here would risk the trigger's own permission checks for no
-- security gain.
-- ---------------------------------------------------------------------------
comment on function public.spray_records_validate_block_vineyard() is
  'Rejects a spray record whose block_ids reference a paddock in a different vineyard. Block ids matching no paddock row are ALLOWED so a deleted or archived block never erases the historical attribution of a completed spray. SECURITY DEFINER (sql/197): paddocks is RLS-protected, so under caller rights this lookup returned no row for a vineyard the caller is not a member of and the foreign block was silently ACCEPTED. The elevated read is used only to accept/reject — no foreign vineyard id, name or membership is disclosed, and the error echoes only the block id the caller supplied.';

-- ---------------------------------------------------------------------------
-- 3. Verify the repair landed, in the same transaction that made it.
--
-- A migration that cannot prove its own postcondition is a hope, not a repair.
-- ---------------------------------------------------------------------------
do $$
declare
  v_secdef  boolean;
  v_config  text[];
  v_trigfn  oid;
begin
  select p.prosecdef, p.proconfig
    into v_secdef, v_config
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'spray_records_validate_block_vineyard';

  if not coalesce(v_secdef, false) then
    raise exception 'SQL 197 FAILED: guard is still not SECURITY DEFINER';
  end if;

  if v_config is null or not (v_config @> array['search_path=public']) then
    raise exception
      'SQL 197 FAILED: guard lost its pinned search_path (proconfig = %)',
      coalesce(v_config::text, '<null>');
  end if;

  -- The pre-existing trigger must still resolve to the function just replaced.
  select t.tgfoid into v_trigfn
    from pg_trigger t
   where t.tgrelid = 'public.spray_records'::regclass
     and t.tgname  = 'trg_spray_records_validate_block_vineyard'
     and not t.tgisinternal;

  if v_trigfn is distinct from 'public.spray_records_validate_block_vineyard()'::regprocedure::oid then
    raise exception 'SQL 197 FAILED: sql/195 trigger no longer calls the repaired guard';
  end if;

  raise notice 'SQL 197: spray block vineyard guard is SECURITY DEFINER with pinned search_path; sql/195 trigger intact.';
end$$;

commit;

-- =============================================================================
-- ROLLBACK
--
-- Function replacement only — reverting is a second CREATE OR REPLACE.
--
-- WARNING: this restores the vulnerability. A caller who is not a member of the
-- foreign vineyard will again be able to persist that vineyard's block ids.
-- Prefer fixing forward.
--
-- begin;
--   create or replace function public.spray_records_validate_block_vineyard()
--   returns trigger
--   language plpgsql
--   set search_path = public
--   as $$
--   declare
--     v_foreign uuid;
--   begin
--     if new.block_ids is null then
--       return new;
--     end if;
--     select p.id into v_foreign
--       from public.paddocks p
--      where p.id = any(new.block_ids)
--        and p.vineyard_id is distinct from new.vineyard_id
--      limit 1;
--     if v_foreign is not null then
--       raise exception
--         'spray_records.block_ids contains block % which belongs to a different vineyard than the spray record',
--         v_foreign using errcode = '23514';
--     end if;
--     return new;
--   end$$;
-- commit;
--
-- END 197
--
-- Manual actions after applying:
--   * run sql/tests/197_fix_spray_block_vineyard_guard_tests.sql
--   * re-run sql/tests/195_spray_block_attribution_tests.sql — it now carries
--     T18, the authenticated-role regression test the original suite lacked.
--   * NO redeploy of supabase/functions/vinetrack-api is needed: no column,
--     view or API-visible field changed.
--   * NO client change is needed on iOS, Android or Lovable. A correct client
--     never sent a foreign block id, so nothing that used to work stops
--     working; only the previously-silent illegitimate write now errors.
--   * NO backfill and NO audit sweep is included here. Any cross-vineyard
--     block id already persisted by this defect is left untouched: deleting
--     attribution from a compliance document is a data-destroying decision that
--     needs an explicit owner. To find such rows (read-only, run as owner):
--       select sr.id, sr.vineyard_id, sr.date, p.id as foreign_block_id
--         from public.spray_records sr
--         join public.paddocks p on p.id = any(sr.block_ids)
--        where sr.block_ids is not null
--          and p.vineyard_id is distinct from sr.vineyard_id;
--     Expected: 0 rows. Investigate before deciding any remediation.
-- =============================================================================

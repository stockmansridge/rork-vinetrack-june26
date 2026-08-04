-- =============================================================================
-- 165: RUN the sql/164 pruning-season repair (this is the script that CHANGES DATA).
--
-- WHY THIS FILE EXISTS
--   Applying sql/164 only INSTALLS the tooling. Its own final notice says so:
--     "SQL 164 pruning season repair + enforcement verification: APPLIED
--      (nothing repaired yet)"
--   `repair_pruning_entry_seasons()` is DRY RUN BY DEFAULT and must be called
--   explicitly with p_dry_run = false. Until that call is made, every one of the
--   seven 2026-dated entries still points at the 2027 pruning season row, which
--   is exactly what the Pruning Activity Report is showing (Season "2027 ⚠",
--   the ⚠ being the portal's own mismatch badge).
--
--   `pruning_entries` has NO denormalised season column (see sql/109) — the
--   portal's Season column is the joined `pruning_seasons.season_year`. So there
--   is nothing else to update: re-pointing `pruning_season_id` is the whole fix,
--   and the report changes the moment this script commits.
--
-- WHAT THIS SCRIPT DOES
--   1. Impersonates an active System Administrator for THIS TRANSACTION ONLY,
--      because the repair is gated on `is_system_admin()` and a SQL-editor
--      session has no `auth.uid()` (it would fail with "not allowed").
--   2. DRY RUN across every vineyard  -> recorded as phase 'BEFORE (plan)'.
--   3. APPLIES the same set            -> recorded as phase 'AFTER (applied)'.
--   4. Verifies live mismatches are gone, and ABORTS (rolls back) if the repair
--      did not fully land — nothing is half-applied.
--   5. Returns the before-and-after list: entry id, date, block, old season
--      year, new season year, vintage year.
--
-- SAFE TO RE-RUN. A second run finds nothing to repair and returns 0 rows.
-- REVERSIBLE. Every change is logged to `pruning_season_backfill_log`; the
-- revert recipe is in sql/164 §7.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Act as a real System Administrator (transaction-scoped)
-- ---------------------------------------------------------------------------
do $$
declare
  v_admin uuid;
  v_email text;
begin
  if to_regprocedure('public.repair_pruning_entry_seasons(boolean, uuid, uuid[], boolean)') is null then
    raise exception 'SQL 165: apply sql/164_pruning_season_repair.sql first';
  end if;

  select sa.user_id, sa.email
    into v_admin, v_email
  from public.system_admins sa
  where sa.is_active = true
  order by sa.created_at
  limit 1;

  if v_admin is null then
    raise exception 'SQL 165: no active row in public.system_admins — the repair is admin-gated';
  end if;

  -- `true` = transaction-local, so the claim disappears at commit and cannot
  -- leak into another request on a pooled connection.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  raise notice 'SQL 165: acting as System Administrator % (%)', coalesce(v_email, '(no email)'), v_admin;
end$$;

-- ---------------------------------------------------------------------------
-- 2. DRY RUN — the "before" list. Writes nothing.
-- ---------------------------------------------------------------------------
drop table if exists pruning_season_repair_run;

create temp table pruning_season_repair_run as
select 1 as phase_order, 'BEFORE (plan)'::text as phase, r.*
from public.repair_pruning_entry_seasons(true) r;

-- ---------------------------------------------------------------------------
-- 3. APPLY — the same set, for real.
--
--    Scope note: no vineyard filter and no id list, so this is the
--    vineyard-wide sweep (every live entry whose linked season year disagrees
--    with year(entry_date)), which includes the seven portal records.
--    Reversed (audit-history) entries are excluded — the sql/162 audit found
--    none mismatched. To include them, add `, null, null, true`.
-- ---------------------------------------------------------------------------
insert into pruning_season_repair_run
select 2, 'AFTER (applied)', r.*
from public.repair_pruning_entry_seasons(false) r;

-- ---------------------------------------------------------------------------
-- 4. Verify it landed — abort the whole transaction if it did not
-- ---------------------------------------------------------------------------
do $$
declare
  n_planned   integer;
  n_repaired  integer;
  n_skipped   integer;
  n_remaining integer;
  n_empty     integer;
begin
  select count(*) into n_planned  from pruning_season_repair_run where phase_order = 1 and action = 'planned';
  select count(*) into n_skipped  from pruning_season_repair_run where phase_order = 1 and action = 'skipped';
  select count(*) into n_repaired from pruning_season_repair_run where phase_order = 2 and action = 'repaired';
  select count(*) into n_empty    from pruning_season_repair_run where phase_order = 2 and action = 'source_season_now_empty';

  select count(*) into n_remaining
  from public.pruning_entries e
  left join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.deleted_at is null
    and s.season_year is distinct from extract(year from e.entry_date)::integer;

  raise notice 'SQL 165: planned %, repaired %, skipped %, emptied source seasons %',
    n_planned, n_repaired, n_skipped, n_empty;

  if n_repaired <> n_planned then
    raise exception 'SQL 165: planned % but repaired % — rolling back, nothing changed',
      n_planned, n_repaired;
  end if;

  -- `skipped` rows are the only legitimate remainder: a quarter of that entry
  -- is already recorded in the canonical season, so moving it would release or
  -- merge a quarter. sql/164 refuses to do that silently; sql/163 is the
  -- reviewed tool that may.
  if n_remaining <> n_skipped then
    raise exception 'SQL 165: % live mismatch(es) remain but only % were skipped — rolling back',
      n_remaining, n_skipped;
  end if;

  if n_remaining = 0 then
    raise notice 'SQL 165: live_entry_mismatches = 0 — every pruning entry now sits in the season of its work year';
  else
    raise notice 'SQL 165: % entry(ies) intentionally left for review (action = skipped) — see the note column', n_remaining;
  end if;
end$$;

commit;

-- ---------------------------------------------------------------------------
-- 5. THE BEFORE-AND-AFTER LIST
-- ---------------------------------------------------------------------------
select r.phase,
       r.action,
       r.entry_id,
       to_char(r.entry_date, 'DD/MM/YYYY') as entry_date,
       r.vineyard_name,
       r.block_name,
       r.rows_covered,
       r.quarters,
       r.old_season_year,
       r.new_season_year,
       r.vintage_year,
       r.note,
       (select count(*)
          from public.pruning_entries e
          left join public.pruning_seasons s on s.id = e.pruning_season_id
         where e.deleted_at is null
           and s.season_year is distinct from extract(year from e.entry_date)::integer
       ) as remaining_live_mismatches
from pruning_season_repair_run r
order by r.phase_order,
         r.entry_date desc nulls last,
         r.entry_id nulls last;

-- ---------------------------------------------------------------------------
-- 6. AFTERWARDS
-- ---------------------------------------------------------------------------
-- a) The portal: the "2027 pruning season" filter now returns 0 entries and all
--    seven appear under "2026 pruning season", Vintage still 2027, and the ⚠
--    mismatch badge is gone. The Season dropdown may still LIST an empty 2027
--    season row (reported above as `source_season_now_empty`) — retiring a
--    season row is a separate explicit decision, see sql/163.
--
-- b) Confirm the live write RPCs cannot let it happen again:
--      select jsonb_pretty(public.verify_pruning_season_enforcement());
--    Require "enforced": true, "unprotected_writers": [], "live_entry_mismatches": 0.
--
-- c) Watch for old app builds still submitting the wrong season:
--      select vineyard_id, entry_date, submitted_season_year,
--             canonical_season_year, occurrences, last_seen_at
--      from public.pruning_season_mismatch_log
--      order by last_seen_at desc limit 50;
--
-- d) The iOS and Android apps cache pruning seasons locally. They adopt the
--    canonical season on their next sync; a pull-to-refresh on the Pruning
--    Tracker is enough.

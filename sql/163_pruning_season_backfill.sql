-- =============================================================================
-- 163: REVIEWED historical correction — re-point mis-assigned pruning entries
--      onto their canonical pruning season.
--
-- WHY (evidence: sql/162 audit run against the shared project, 2 Aug 2026)
--   live_entries               50
--   season_year_mismatches      8   <- all 2026 work stored under season 2027
--   vintage_year_mismatches     0   <- vintages are already correct
--   duplicate_season_groups     0
--   orphan_or_invalid_seasons   0
--   same_date_split_dates       4   <- caused entirely by the 8 rows above
--   canonical_season_exists  false for every mismatch — no live 2026 season row
--                                   exists for those blocks, so nothing collides.
--
--   The 8 rows sit under just THREE season rows, all stamped 2027 and all
--   holding 2026-dated work only:
--     5ed686d3-… Cab Franc  @ Stockmans Ridge (fe952afe-…)   5 entries
--     25fb7b25-… Sauv Blanc @ Stockmans Ridge (fe952afe-…)   2 entries
--     caa9a34c-… Cab Franc  @ JH Testing      (59973ced-…)   1 entry
--
-- CANONICAL RULE (unchanged, SQL 161)
--   season_year  = extract(year from pruning_entries.entry_date)
--   vintage_year = resolve_vineyard_vintage_year(vineyard, entry_date)
--
-- WHAT THIS MIGRATION DOES
--   1. Creates `public.pruning_season_backfill_log` — one row per corrected
--      entry recording the PREVIOUS season id/year and the new one, so the
--      correction is fully reversible (revert snippet at the bottom).
--   2. Adds the audit event type 'pruning_entry_season_corrected'.
--   3. Creates `public.backfill_pruning_season_assignment(p_dry_run, p_vineyard_id)`
--      — System-Administrator-only, security definer, fixed search_path.
--      * DEFAULT IS A DRY RUN. It changes nothing and returns the full plan.
--      * Applying it moves each affected entry, ITS QUARTERS, and any leftover
--        completed quarters / reversed entries of an emptied season onto the
--        canonical row for the year of the work (created under the
--        deterministic id both clients derive, copying the block's pruning
--        setup: due date, crew, working days, manual row count, hours, notes).
--      * A quarter the TARGET season already holds is released and reported,
--        never duplicated — identical to the year-crossing edit path in
--        SQL 161 §4. `row_equivalents_completed` / `estimated_vines_completed`
--        are recomputed for any entry that loses quarters that way.
--      * An emptied source season is soft-deleted, freeing the
--        `pruning_seasons_active_unique` slot.
--      * Re-running it is a no-op (`entries_corrected: 0`).
--
-- WHAT IT DOES NOT DO
--   * It does NOT run itself. Applying this file only installs the tooling.
--     Run the dry run, review the plan, then run it for real (see §5).
--   * It does not touch `vintage_year` — the audit found zero vintage
--     mismatches and vintage is resolved by SQL 119, not by the season row.
--   * It does not change any RPC, RLS policy, grant or client contract.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Reversal log
-- ---------------------------------------------------------------------------
create table if not exists public.pruning_season_backfill_log (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  paddock_id uuid not null,
  pruning_entry_id uuid not null,
  entry_date date not null,
  previous_season_id uuid not null,
  previous_season_year integer,
  new_season_id uuid not null,
  new_season_year integer not null,
  quarters_before integer not null default 0,
  quarters_after integer not null default 0,
  quarters_released integer not null default 0,
  entry_reversed boolean not null default false,
  ran_by uuid references auth.users(id),
  ran_at timestamptz not null default now()
);

create index if not exists pruning_season_backfill_log_entry_idx
  on public.pruning_season_backfill_log (pruning_entry_id);
create index if not exists pruning_season_backfill_log_vineyard_idx
  on public.pruning_season_backfill_log (vineyard_id, ran_at);

alter table public.pruning_season_backfill_log enable row level security;

-- Readable by System Administrators only; written solely by the RPC below.
drop policy if exists "pruning_season_backfill_log_select_admin" on public.pruning_season_backfill_log;
create policy "pruning_season_backfill_log_select_admin" on public.pruning_season_backfill_log
  for select to authenticated
  using (public.is_system_admin());

drop policy if exists "pruning_season_backfill_log_no_client_insert" on public.pruning_season_backfill_log;
create policy "pruning_season_backfill_log_no_client_insert" on public.pruning_season_backfill_log
  for insert to authenticated with check (false);
drop policy if exists "pruning_season_backfill_log_no_client_update" on public.pruning_season_backfill_log;
create policy "pruning_season_backfill_log_no_client_update" on public.pruning_season_backfill_log
  for update to authenticated using (false);
drop policy if exists "pruning_season_backfill_log_no_client_delete" on public.pruning_season_backfill_log;
create policy "pruning_season_backfill_log_no_client_delete" on public.pruning_season_backfill_log
  for delete to authenticated using (false);

-- ---------------------------------------------------------------------------
-- 2. Audit event type for the correction (SQL 120 constraint, extended)
-- ---------------------------------------------------------------------------
alter table public.pruning_entry_audit
  drop constraint if exists pruning_entry_audit_event_type_check;
alter table public.pruning_entry_audit
  add constraint pruning_entry_audit_event_type_check check (event_type in (
    'pruning_entry_created',
    'pruning_entry_edited',
    'pruning_entry_reversed',
    'pruning_work_task_linked',
    'pruning_work_task_updated',
    'pruning_entry_season_corrected'
  ));

-- ---------------------------------------------------------------------------
-- 3. The backfill — dry run by default
-- ---------------------------------------------------------------------------
create or replace function public.backfill_pruning_season_assignment(
  p_dry_run boolean default true,
  p_vineyard_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  r              record;
  v_target       uuid;
  v_target_year  integer;
  v_existed      boolean;
  v_before       integer;
  v_after        integer;
  v_released     integer;
  v_plan         jsonb := '[]'::jsonb;
  v_created      jsonb := '[]'::jsonb;   -- distinct target ids created
  v_sources      jsonb := '{}'::jsonb;   -- source id -> {target, year} | {mixed}
  v_retired      jsonb := '[]'::jsonb;
  v_retained     jsonb := '[]'::jsonb;
  v_extra        integer;
  v_moved        integer;
  v_reversed     integer := 0;
  v_source       record;
begin
  if not public.is_system_admin() then
    raise exception 'not allowed';
  end if;

  -- -------------------------------------------------------------------------
  -- Pass 1 — live entries whose season year disagrees with the year of work.
  -- -------------------------------------------------------------------------
  for r in
    select e.id            as entry_id,
           e.vineyard_id,
           e.paddock_id,
           e.entry_date,
           e.pruning_season_id as source_season_id,
           s.season_year       as source_year,
           extract(year from e.entry_date)::integer as work_year,
           e.estimated_vines_completed
    from public.pruning_entries e
    join public.pruning_seasons s on s.id = e.pruning_season_id
    where e.deleted_at is null
      and (p_vineyard_id is null or e.vineyard_id = p_vineyard_id)
      and s.season_year is distinct from extract(year from e.entry_date)::integer
    order by e.entry_date, e.id
  loop
    v_target_year := r.work_year;

    -- The live canonical row for the year of the work, if there is one.
    select id into v_target
    from public.pruning_seasons
    where vineyard_id = r.vineyard_id
      and paddock_id = r.paddock_id
      and season_year = v_target_year
      and deleted_at is null
    limit 1;
    v_existed := v_target is not null;

    if v_target is null then
      -- Same deterministic id iOS/Android/SQL 161 derive for this block+year.
      v_target := public.derive_pruning_season_id(r.vineyard_id, r.paddock_id, v_target_year);

      if not p_dry_run then
        insert into public.pruning_seasons (
          id, vineyard_id, paddock_id, season_year,
          start_date, due_date, pruning_method, assigned_crew, working_days,
          manual_row_count, estimated_labour_hours, notes, status, created_by
        )
        select v_target, r.vineyard_id, r.paddock_id, v_target_year,
               src.start_date, src.due_date, src.pruning_method, src.assigned_crew,
               src.working_days, src.manual_row_count, src.estimated_labour_hours,
               src.notes, src.status, auth.uid()
        from public.pruning_seasons src
        where src.id = r.source_season_id
        on conflict (id) do update
          set deleted_at = null, updated_at = now()
          where public.pruning_seasons.deleted_at is not null;
      end if;

      if not (v_created ? v_target::text) then
        v_created := v_created || to_jsonb(v_target::text);
      end if;
    end if;

    -- Quarters currently attributed to this entry, and how many of them the
    -- target season already holds (those cannot move — a quarter exists once
    -- per season — so they are released and reported).
    select count(*)::integer into v_before
    from public.pruning_row_segments where pruning_entry_id = r.entry_id;

    select count(*)::integer into v_released
    from public.pruning_row_segments s
    where s.pruning_entry_id = r.entry_id
      and exists (
        select 1 from public.pruning_row_segments x
        where x.pruning_season_id = v_target
          and x.segment_number = s.segment_number
          and (
            (s.paddock_row_id is not null and x.paddock_row_id = s.paddock_row_id)
            or (s.paddock_row_id is null and x.paddock_row_id is null and x.row_number = s.row_number)
          )
      );

    if not p_dry_run then
      update public.pruning_row_segments s
      set completed = false,
          completed_at = null,
          completed_by = null,
          pruning_entry_id = null,
          updated_at = now()
      where s.pruning_entry_id = r.entry_id
        and exists (
          select 1 from public.pruning_row_segments x
          where x.pruning_season_id = v_target
            and x.segment_number = s.segment_number
            and (
              (s.paddock_row_id is not null and x.paddock_row_id = s.paddock_row_id)
              or (s.paddock_row_id is null and x.paddock_row_id is null and x.row_number = s.row_number)
            )
        );

      update public.pruning_row_segments
      set pruning_season_id = v_target, updated_at = now()
      where pruning_entry_id = r.entry_id;

      select count(*)::integer into v_after
      from public.pruning_row_segments where pruning_entry_id = r.entry_id;

      update public.pruning_entries
      set pruning_season_id = v_target,
          row_equivalents_completed = v_after / 4.0,
          estimated_vines_completed = case
            when v_before > 0 and v_after <> v_before
            then round(coalesce(r.estimated_vines_completed, 0)::numeric * v_after / v_before)::integer
            else estimated_vines_completed
          end,
          updated_at = now()
      where id = r.entry_id;

      insert into public.pruning_season_backfill_log (
        vineyard_id, paddock_id, pruning_entry_id, entry_date,
        previous_season_id, previous_season_year, new_season_id, new_season_year,
        quarters_before, quarters_after, quarters_released, entry_reversed, ran_by
      ) values (
        r.vineyard_id, r.paddock_id, r.entry_id, r.entry_date,
        r.source_season_id, r.source_year, v_target, v_target_year,
        v_before, v_after, v_released, false, auth.uid()
      );

      insert into public.pruning_entry_audit (
        vineyard_id, pruning_entry_id, event_type,
        previous_quarters, new_quarters, detail, created_by
      ) values (
        r.vineyard_id, r.entry_id, 'pruning_entry_season_corrected',
        v_before, v_after,
        jsonb_build_object(
          'reason', 'sql_163_reviewed_backfill',
          'entry_date', r.entry_date,
          'previous_season_id', r.source_season_id,
          'previous_season_year', r.source_year,
          'season_id', v_target,
          'season_year', v_target_year,
          'quarters_released', v_released
        ),
        auth.uid()
      );
    else
      v_after := v_before - v_released;
    end if;

    v_plan := v_plan || jsonb_build_object(
      'entry_id', r.entry_id,
      'vineyard_id', r.vineyard_id,
      'paddock_id', r.paddock_id,
      'entry_date', r.entry_date,
      'from_season_id', r.source_season_id,
      'from_season_year', r.source_year,
      'to_season_id', v_target,
      'to_season_year', v_target_year,
      'target_existed', v_existed,
      'quarters', v_before,
      'quarters_released', v_released
    );

    -- Remember the source -> target mapping for the cleanup pass.
    if not (v_sources ? r.source_season_id::text) then
      v_sources := jsonb_set(
        v_sources, array[r.source_season_id::text],
        jsonb_build_object('target', v_target::text, 'year', v_target_year), true);
    elsif (v_sources #>> array[r.source_season_id::text, 'target']) is distinct from v_target::text then
      -- Two different target years out of one season row: leave it alone and
      -- report it rather than guessing which year the leftovers belong to.
      v_sources := jsonb_set(
        v_sources, array[r.source_season_id::text],
        jsonb_build_object('target', 'mixed'), true);
    end if;
  end loop;

  -- -------------------------------------------------------------------------
  -- Pass 2 — clean up each emptied source season: take its leftover completed
  -- quarters and its REVERSED entries with it (so audit history and any
  -- unattributed completion follow the work), then soft-delete it.
  -- -------------------------------------------------------------------------
  for v_source in
    select key::uuid as source_id,
           value ->> 'target' as target_text,
           (value ->> 'year')::integer as target_year
    from jsonb_each(v_sources)
  loop
    if v_source.target_text = 'mixed' then
      v_retained := v_retained || jsonb_build_object(
        'season_id', v_source.source_id, 'reason', 'multiple_target_years');
      continue;
    end if;
    v_target := v_source.target_text::uuid;
    v_target_year := v_source.target_year;

    -- Live entries that will still be under the source afterwards. During a
    -- dry run nothing has moved yet, so the planned entries are discounted.
    select count(*)::integer into v_extra
    from public.pruning_entries e
    where e.pruning_season_id = v_source.source_id
      and e.deleted_at is null
      and (
        not p_dry_run
        or not exists (
          select 1 from jsonb_array_elements(v_plan) pl
          where (pl->>'entry_id')::uuid = e.id
        )
      );
    if v_extra > 0 then
      v_retained := v_retained || jsonb_build_object(
        'season_id', v_source.source_id, 'reason', 'still_has_live_entries',
        'entries', v_extra);
      continue;
    end if;

    -- Reversed entries of the emptied season whose work year matches the
    -- target follow it, so the Activity Report files them under one season.
    select count(*)::integer into v_moved
    from public.pruning_entries
    where pruning_season_id = v_source.source_id
      and deleted_at is not null
      and extract(year from entry_date)::integer = coalesce(v_target_year, -1);
    v_reversed := v_reversed + v_moved;

    -- Leftover COMPLETED quarters with no live owner that the target does not
    -- already hold.
    select count(*)::integer into v_extra
    from public.pruning_row_segments s
    where s.pruning_season_id = v_source.source_id
      and s.completed
      and not exists (
        select 1 from public.pruning_row_segments x
        where x.pruning_season_id = v_target
          and x.segment_number = s.segment_number
          and (
            (s.paddock_row_id is not null and x.paddock_row_id = s.paddock_row_id)
            or (s.paddock_row_id is null and x.paddock_row_id is null and x.row_number = s.row_number)
          )
      );

    if not p_dry_run then
      update public.pruning_row_segments s
      set pruning_season_id = v_target, updated_at = now()
      where s.pruning_season_id = v_source.source_id
        and s.completed
        and not exists (
          select 1 from public.pruning_row_segments x
          where x.pruning_season_id = v_target
            and x.segment_number = s.segment_number
            and (
              (s.paddock_row_id is not null and x.paddock_row_id = s.paddock_row_id)
              or (s.paddock_row_id is null and x.paddock_row_id is null and x.row_number = s.row_number)
            )
        );

      insert into public.pruning_season_backfill_log (
        vineyard_id, paddock_id, pruning_entry_id, entry_date,
        previous_season_id, previous_season_year, new_season_id, new_season_year,
        quarters_before, quarters_after, quarters_released, entry_reversed, ran_by
      )
      select e.vineyard_id, e.paddock_id, e.id, e.entry_date,
             v_source.source_id, s.season_year, v_target, v_target_year,
             0, 0, 0, true, auth.uid()
      from public.pruning_entries e
      join public.pruning_seasons s on s.id = e.pruning_season_id
      where e.pruning_season_id = v_source.source_id
        and e.deleted_at is not null
        and extract(year from e.entry_date)::integer = coalesce(v_target_year, -1);

      update public.pruning_entries
      set pruning_season_id = v_target, updated_at = now()
      where pruning_season_id = v_source.source_id
        and deleted_at is not null
        and extract(year from entry_date)::integer = coalesce(v_target_year, -1);

      -- Nothing meaningful left? Free the unique slot.
      if not exists (
        select 1 from public.pruning_entries where pruning_season_id = v_source.source_id
      ) and not exists (
        select 1 from public.pruning_row_segments
        where pruning_season_id = v_source.source_id and completed
      ) then
        update public.pruning_seasons
        set deleted_at = now(), updated_at = now()
        where id = v_source.source_id and deleted_at is null;
        v_retired := v_retired || to_jsonb(v_source.source_id::text);
      else
        v_retained := v_retained || jsonb_build_object(
          'season_id', v_source.source_id, 'reason', 'residual_rows_kept');
      end if;
    else
      v_retired := v_retired || to_jsonb(v_source.source_id::text);
    end if;
  end loop;

  if not p_dry_run then
    -- Let the clients pick the corrected rows up on their next pull.
    notify pgrst, 'reload schema';
  end if;

  return jsonb_build_object(
    'dry_run', p_dry_run,
    'ran_at', now(),
    'vineyard_filter', p_vineyard_id,
    'canonical_rule', 'season_year = year(entry_date)',
    'entries_corrected', jsonb_array_length(v_plan),
    'seasons_created', jsonb_array_length(v_created),
    'seasons_retired', jsonb_array_length(v_retired),
    'reversed_entries_moved', v_reversed,
    'quarters_released', (
      select coalesce(sum((e->>'quarters_released')::integer), 0)
      from jsonb_array_elements(v_plan) e
    ),
    'created_season_ids', v_created,
    'retired_season_ids', v_retired,
    'retained_seasons', v_retained,
    'plan', v_plan,
    'remaining_mismatches', (
      select count(*)
      from public.pruning_entries e
      join public.pruning_seasons s on s.id = e.pruning_season_id
      where e.deleted_at is null
        and (p_vineyard_id is null or e.vineyard_id = p_vineyard_id)
        and s.season_year is distinct from extract(year from e.entry_date)::integer
    )
  );
end;
$$;

revoke all on function public.backfill_pruning_season_assignment(boolean, uuid) from public, anon, authenticated;
grant execute on function public.backfill_pruning_season_assignment(boolean, uuid) to authenticated;
revoke execute on function public.backfill_pruning_season_assignment(boolean, uuid) from anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 4. Validation — the migration ABORTS if any of these fail
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.pruning_season_backfill_log') is null then
    raise exception 'SQL 163: reversal log missing';
  end if;
  if to_regprocedure('public.backfill_pruning_season_assignment(boolean, uuid)') is null then
    raise exception 'SQL 163: backfill function missing';
  end if;
  if to_regprocedure('public.derive_pruning_season_id(uuid, uuid, integer)') is null then
    raise exception 'SQL 163: SQL 161 must be applied first';
  end if;
  if has_function_privilege('anon',
    'public.backfill_pruning_season_assignment(boolean, uuid)', 'execute') then
    raise exception 'SQL 163: anon must not execute the backfill';
  end if;
  raise notice 'SQL 163 pruning season backfill tooling: APPLIED (nothing corrected yet)';
end$$;

-- ---------------------------------------------------------------------------
-- 5. HOW TO RUN (System Administrator, in this order)
-- ---------------------------------------------------------------------------
-- a) Rollback-only test suite first:
--      sql/tests/163_pruning_season_backfill_tests.sql
--
-- b) DRY RUN — changes nothing, returns the exact plan (expect 8 entries,
--    3 seasons created, 3 retired, 0 quarters released):
--      select jsonb_pretty(public.backfill_pruning_season_assignment(true));
--
-- c) APPLY once the plan matches the sql/162 audit:
--      select jsonb_pretty(public.backfill_pruning_season_assignment(false));
--    Expect 'remaining_mismatches': 0.
--
-- d) Re-run the audit to confirm the split dates are gone:
--      sql/162_pruning_season_assignment_diagnostic.sql
--
-- One vineyard at a time is also supported, e.g. Stockmans Ridge:
--      select jsonb_pretty(public.backfill_pruning_season_assignment(
--        false, 'fe952afe-437f-4be7-8cbf-fdd8e630411c'));
--
-- ---------------------------------------------------------------------------
-- 6. REVERT (per run — uses the log; run as postgres)
-- ---------------------------------------------------------------------------
-- with run as (
--   select * from public.pruning_season_backfill_log
--   where ran_at >= '<the ran_at of the run you want to undo>'
-- )
-- update public.pruning_entries e
-- set pruning_season_id = r.previous_season_id, updated_at = now()
-- from run r where e.id = r.pruning_entry_id;
-- -- then move the quarters back and clear deleted_at on the retired seasons:
-- update public.pruning_row_segments g
-- set pruning_season_id = r.previous_season_id, updated_at = now()
-- from run r where g.pruning_entry_id = r.pruning_entry_id;
-- update public.pruning_seasons s set deleted_at = null, updated_at = now()
-- from run r where s.id = r.previous_season_id and s.deleted_at is not null;

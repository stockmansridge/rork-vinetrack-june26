-- =============================================================================
-- 164: Targeted pruning-season REPAIR + server-side enforcement verification.
--
-- WHY
--   The portal shows seven 2026-dated pruning entries linked to a 2027 pruning
--   season (an eighth sits in the JH Testing vineyard, invisible to that
--   portal view — see the sql/162 audit). Their VINTAGE is already correct:
--   winter pruning in 2026 belongs to vintage 2027. Only the SEASON LINK is
--   wrong.
--
--   Portal list (all Stockmans Ridge, vineyard fe952afe-…):
--     02/08/2026  Sauvignon Blanc  rows 66–67    7874c51f-…
--     02/08/2026  Cabernet Franc   rows 42–44    4cac6a17-…
--     29/07/2026  Cabernet Franc   rows 40–43    632321ae-…
--     29/07/2026  Cabernet Franc   rows 38–39    5696e4fc-…
--     28/07/2026  Cabernet Franc   rows 40–41    6bc0bfe6-…
--     23/07/2026  Cabernet Franc   rows 38–39    6f2b0f2c-…
--     01/07/2026  Sauvignon Blanc  rows 58–60    07a24186-…
--   Plus, from the same audit: 15/07/2026 Cab Franc @ JH Testing 7a336b3b-….
--
-- CANONICAL RULE (unchanged, SQL 161)
--   season_year  = extract(year from pruning_entries.entry_date)
--   vintage_year = resolve_vineyard_vintage_year(vineyard, entry_date)   [SQL 119]
--   August 2026  -> Season 2026 · Vintage 2027.
--
-- WHAT THIS MIGRATION ADDS
--   1. `resolve_pruning_season_for_date(...)` — the SQL 161 resolver body
--      lifted into ONE shared core, so the repair and the write RPCs cannot
--      drift. `resolve_pruning_season(...)` keeps its exact SQL 161 signature
--      and behaviour and becomes a thin authorised wrapper over that core.
--   2. `pruning_season_mismatch_log` — every time a client SUBMITS a season
--      that conflicts with the entry date, the server ignores it (as before)
--      and now records it, deduplicated with an occurrence counter. This is
--      the persistent form of the `season_mismatch` / `season_corrected`
--      flags the RPCs already return, so an old app version writing the wrong
--      season is visible without shipping a new client.
--   3. `repair_pruning_entry_seasons(dry_run, vineyard, entry_ids,
--      include_reversed)` — the REVIEWED, minimal correction. Dry run by
--      default; returns a before-and-after list.
--   4. `verify_pruning_season_enforcement()` — proves the LIVE database (not
--      this file) enforces the rule in every routine that writes
--      `pruning_entries`, including stale overloads an old client could still
--      resolve.
--
-- WHAT THE REPAIR TOUCHES — and nothing else
--   CHANGES : pruning_entries.pruning_season_id (+ the normal updated_at)
--             pruning_row_segments.pruning_season_id for the quarters ALREADY
--             attributed to that entry (a quarter row is keyed by its season;
--             the quarters themselves, their completion, their completer and
--             their row/segment numbers are untouched).
--   PRESERVES: entry_date, vintage_year, worker_or_crew, labour_hours,
--             start_time, finish_time, pruning_method, notes, work_task_id,
--             paddock_id, created_by, created_at, updated_by,
--             row_equivalents_completed, estimated_vines_completed,
--             client_updated_at, sync_version, deleted_at.
--   REFUSES : if the canonical season already holds one of the entry's
--             quarters, the entry is REPORTED as `skipped` and nothing about
--             it changes. The repair never releases, recounts or rescales a
--             quarter — unlike the broader sql/163 backfill, which is allowed
--             to and reports it.
--   LEAVES  : the emptied source season row in place (reported as
--             `source_season_now_empty`). Retiring it is a separate, explicit
--             decision — sql/163 does that.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Preconditions
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.derive_pruning_season_id(uuid, uuid, integer)') is null
     or to_regprocedure('public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz)') is null then
    raise exception 'SQL 164: apply sql/161_pruning_season_canonical_assignment.sql first';
  end if;
  if to_regprocedure('public.resolve_vineyard_vintage_year(uuid, date)') is null then
    raise exception 'SQL 164: apply sql/119_vintage_year_assignment.sql first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- 1. Client-submitted season mismatches (persistent form of the RPC flag)
-- ---------------------------------------------------------------------------
create table if not exists public.pruning_season_mismatch_log (
  id bigserial primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  paddock_id uuid not null,
  entry_date date not null,
  submitted_season_id uuid not null,
  submitted_season_year integer,
  canonical_season_id uuid not null,
  canonical_season_year integer not null,
  occurrences integer not null default 1,
  actor uuid references auth.users(id),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  constraint pruning_season_mismatch_log_unique unique
    (vineyard_id, paddock_id, entry_date, submitted_season_id, canonical_season_id)
);

create index if not exists pruning_season_mismatch_log_seen_idx
  on public.pruning_season_mismatch_log (last_seen_at desc);

alter table public.pruning_season_mismatch_log enable row level security;

-- Readable by System Administrators; written only by the resolver below.
drop policy if exists "pruning_season_mismatch_log_select_admin" on public.pruning_season_mismatch_log;
create policy "pruning_season_mismatch_log_select_admin" on public.pruning_season_mismatch_log
  for select to authenticated using (public.is_system_admin());

drop policy if exists "pruning_season_mismatch_log_no_client_insert" on public.pruning_season_mismatch_log;
create policy "pruning_season_mismatch_log_no_client_insert" on public.pruning_season_mismatch_log
  for insert to authenticated with check (false);
drop policy if exists "pruning_season_mismatch_log_no_client_update" on public.pruning_season_mismatch_log;
create policy "pruning_season_mismatch_log_no_client_update" on public.pruning_season_mismatch_log
  for update to authenticated using (false);
drop policy if exists "pruning_season_mismatch_log_no_client_delete" on public.pruning_season_mismatch_log;
create policy "pruning_season_mismatch_log_no_client_delete" on public.pruning_season_mismatch_log
  for delete to authenticated using (false);

-- Reversal log (identical to sql/163 — created here too so 164 stands alone).
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
alter table public.pruning_season_backfill_log enable row level security;
drop policy if exists "pruning_season_backfill_log_select_admin" on public.pruning_season_backfill_log;
create policy "pruning_season_backfill_log_select_admin" on public.pruning_season_backfill_log
  for select to authenticated using (public.is_system_admin());

-- Audit event type (idempotent; sql/163 adds the same value).
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
-- 2. THE resolver, now a single shared core.
--
--    `resolve_pruning_season_for_date` is the SQL 161 §2 body verbatim, plus
--    a `p_create_missing` switch so a DRY RUN can learn the canonical id
--    without writing a season row. It performs NO authorisation check and is
--    therefore executable only by the security-definer callers below —
--    revoked from public, anon and authenticated.
-- ---------------------------------------------------------------------------
create or replace function public.resolve_pruning_season_for_date(
  p_vineyard_id uuid,
  p_paddock_id uuid,
  p_entry_date date,
  p_season_id uuid default null,
  p_client_updated_at timestamptz default null,
  p_create_missing boolean default true
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_year integer;
  v_season_id uuid;
begin
  if p_entry_date is null then
    raise exception 'pruning entry date is required to resolve a season';
  end if;

  -- CANONICAL: the pruning season year is the calendar year of the work.
  v_year := extract(year from p_entry_date)::integer;

  -- (a) the live row for this block and this pruning year always wins.
  select id into v_season_id
  from public.pruning_seasons
  where vineyard_id = p_vineyard_id
    and paddock_id = p_paddock_id
    and season_year = v_year
    and deleted_at is null
  limit 1;
  if v_season_id is not null then
    return v_season_id;
  end if;

  -- (b) the caller's id — accepted ONLY when it is this block's row for this
  -- exact pruning year. An id belonging to another year (the 2027-vs-2026
  -- defect) or another block is ignored.
  if p_season_id is not null then
    select id into v_season_id
    from public.pruning_seasons
    where id = p_season_id
      and vineyard_id = p_vineyard_id
      and paddock_id = p_paddock_id
      and season_year = v_year
      and deleted_at is null;
    if v_season_id is not null then
      return v_season_id;
    end if;
  end if;

  -- (c) the canonical row under the deterministic id both clients compute,
  -- resurrected if soft-deleted. (a) proved no live row exists for this
  -- (vineyard, paddock, year), so the partial unique index cannot be violated.
  v_season_id := public.derive_pruning_season_id(p_vineyard_id, p_paddock_id, v_year);

  if p_create_missing then
    insert into public.pruning_seasons (
      id, vineyard_id, paddock_id, season_year, created_by, client_updated_at
    ) values (
      v_season_id, p_vineyard_id, p_paddock_id, v_year, auth.uid(), p_client_updated_at
    )
    on conflict (id) do update
      set deleted_at = null, updated_at = now()
      where public.pruning_seasons.deleted_at is not null;
  end if;

  return v_season_id;
end;
$$;

revoke all on function public.resolve_pruning_season_for_date(uuid, uuid, date, uuid, timestamptz, boolean)
  from public, anon, authenticated;

-- The authorised wrapper. SAME signature and SAME behaviour as SQL 161 §2, so
-- `record_pruning_entry` and `update_pruning_entry` need no change at all —
-- they keep calling this and keep getting the canonical season. It now also
-- records a conflicting client submission.
create or replace function public.resolve_pruning_season(
  p_vineyard_id uuid,
  p_paddock_id uuid,
  p_entry_date date,
  p_season_id uuid default null,
  p_client_updated_at timestamptz default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_year integer;
  v_season_id uuid;
  v_submitted_year integer;
begin
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;
  if p_entry_date is null then
    raise exception 'pruning entry date is required to resolve a season';
  end if;

  v_year := extract(year from p_entry_date)::integer;
  v_season_id := public.resolve_pruning_season_for_date(
    p_vineyard_id, p_paddock_id, p_entry_date, p_season_id, p_client_updated_at, true
  );

  -- The client suggested a season the entry date does not support. It was
  -- ignored above; record it so a stale app version is visible server-side.
  if p_season_id is not null and p_season_id is distinct from v_season_id then
    select s.season_year into v_submitted_year
    from public.pruning_seasons s where s.id = p_season_id;

    insert into public.pruning_season_mismatch_log (
      vineyard_id, paddock_id, entry_date,
      submitted_season_id, submitted_season_year,
      canonical_season_id, canonical_season_year, actor
    ) values (
      p_vineyard_id, p_paddock_id, p_entry_date,
      p_season_id, v_submitted_year,
      v_season_id, v_year, auth.uid()
    )
    on conflict (vineyard_id, paddock_id, entry_date, submitted_season_id, canonical_season_id)
    do update set
      occurrences = public.pruning_season_mismatch_log.occurrences + 1,
      submitted_season_year = excluded.submitted_season_year,
      actor = excluded.actor,
      last_seen_at = now();
  end if;

  return v_season_id;
end;
$$;

revoke all on function public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz) from public, anon;
grant execute on function public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. The reviewed repair — DRY RUN BY DEFAULT.
--
--    Returns one row per affected entry: the before-and-after list.
--      action = planned | repaired | skipped | source_season_now_empty
-- ---------------------------------------------------------------------------
create or replace function public.repair_pruning_entry_seasons(
  p_dry_run boolean default true,
  p_vineyard_id uuid default null,
  p_entry_ids uuid[] default null,
  p_include_reversed boolean default false
) returns table (
  action           text,
  entry_id         uuid,
  entry_date       date,
  vineyard_name    text,
  block_name       text,
  rows_covered     text,
  quarters         integer,
  old_season_id    uuid,
  old_season_year  integer,
  new_season_id    uuid,
  new_season_year  integer,
  vintage_year     integer,
  note             text
)
language plpgsql security definer set search_path = public
as $$
declare
  r          record;
  v_target   uuid;
  v_year     integer;
  v_conflict integer;
  v_quarters integer;
  v_rows     text;
  v_sources  uuid[] := '{}';
begin
  if not public.is_system_admin() then
    raise exception 'not allowed';
  end if;

  for r in
    select e.id                                      as e_id,
           e.vineyard_id                             as e_vineyard,
           e.paddock_id                              as e_paddock,
           e.entry_date                              as e_date,
           e.vintage_year                            as e_vintage,
           e.pruning_season_id                       as e_season,
           s.season_year                             as s_year,
           (e.deleted_at is not null)                as e_reversed,
           extract(year from e.entry_date)::integer  as work_year,
           vy.name                                   as vy_name,
           pd.name                                   as pd_name
    from public.pruning_entries e
    left join public.pruning_seasons s on s.id = e.pruning_season_id
    left join public.vineyards vy      on vy.id = e.vineyard_id
    left join public.paddocks pd       on pd.id = e.paddock_id
    where (p_vineyard_id is null or e.vineyard_id = p_vineyard_id)
      and (p_entry_ids is null or e.id = any (p_entry_ids))
      and (p_include_reversed or e.deleted_at is null)
      and s.season_year is distinct from extract(year from e.entry_date)::integer
    order by e.entry_date desc, e.id
  loop
    v_year := r.work_year;

    -- Quarters currently attributed to this entry (for the report and for the
    -- preservation guarantee — the count must not change).
    select count(*)::integer,
           case
             when count(*) = 0 then '—'
             when min(g.row_number) = max(g.row_number) then min(g.row_number)::text
             else min(g.row_number)::text || '–' || max(g.row_number)::text
           end
      into v_quarters, v_rows
    from public.pruning_row_segments g
    where g.pruning_entry_id = r.e_id;

    -- The canonical season for the year of the WORK, via the shared SQL 161
    -- core. A dry run never creates the row; it still reports the exact id
    -- that will be used (the deterministic id both clients derive).
    v_target := public.resolve_pruning_season_for_date(
      r.e_vineyard, r.e_paddock, r.e_date, r.e_season, null, not p_dry_run
    );

    -- Preservation guard: a quarter exists at most once per season. If the
    -- canonical season already holds one of this entry's quarters, moving the
    -- entry would mean releasing or merging a quarter — out of scope for this
    -- repair. Report it and change nothing.
    select count(*)::integer into v_conflict
    from public.pruning_row_segments g
    where g.pruning_entry_id = r.e_id
      and exists (
        select 1 from public.pruning_row_segments x
        where x.pruning_season_id = v_target
          and x.segment_number = g.segment_number
          and (
            (g.paddock_row_id is not null and x.paddock_row_id = g.paddock_row_id)
            or (g.paddock_row_id is null and x.paddock_row_id is null and x.row_number = g.row_number)
          )
      );

    action          := null;
    entry_id        := r.e_id;
    entry_date      := r.e_date;
    vineyard_name   := coalesce(r.vy_name, '(unknown vineyard)');
    block_name      := coalesce(r.pd_name, '(unknown block)');
    rows_covered    := v_rows;
    quarters        := v_quarters;
    old_season_id   := r.e_season;
    old_season_year := r.s_year;
    new_season_id   := v_target;
    new_season_year := v_year;
    vintage_year    := r.e_vintage;   -- never modified
    note            := null;

    if v_conflict > 0 then
      action := 'skipped';
      note := v_conflict || ' quarter(s) already recorded in the canonical season — '
        || 'left untouched for review (use sql/163 if a release is intended)';
      new_season_year := r.s_year;
      return next;
      continue;
    end if;

    if p_dry_run then
      action := 'planned';
      note := case
        when r.e_reversed then 'reversed entry — audit history'
        else 'season link only; vintage ' || coalesce(r.e_vintage::text, 'null') || ' preserved'
      end;
      return next;
    else
      -- The quarters keep every value they have; only the season they hang
      -- off changes, so they stay attributed to this entry.
      update public.pruning_row_segments g
      set pruning_season_id = v_target,
          updated_at = now()
      where g.pruning_entry_id = r.e_id;

      -- ONLY the season link. vintage_year, totals, worker, creator, labour,
      -- work-task link, times and notes are not in this statement; updated_at
      -- is the normal modification stamp (also set by the table trigger).
      update public.pruning_entries e
      set pruning_season_id = v_target,
          updated_at = now()
      where e.id = r.e_id;

      insert into public.pruning_season_backfill_log (
        vineyard_id, paddock_id, pruning_entry_id, entry_date,
        previous_season_id, previous_season_year, new_season_id, new_season_year,
        quarters_before, quarters_after, quarters_released, entry_reversed, ran_by
      ) values (
        r.e_vineyard, r.e_paddock, r.e_id, r.e_date,
        r.e_season, r.s_year, v_target, v_year,
        v_quarters, v_quarters, 0, r.e_reversed, auth.uid()
      );

      insert into public.pruning_entry_audit (
        vineyard_id, pruning_entry_id, event_type,
        previous_quarters, new_quarters, detail, created_by
      ) values (
        r.e_vineyard, r.e_id, 'pruning_entry_season_corrected',
        v_quarters, v_quarters,
        jsonb_build_object(
          'reason', 'sql_164_targeted_repair',
          'entry_date', r.e_date,
          'previous_season_id', r.e_season,
          'previous_season_year', r.s_year,
          'season_id', v_target,
          'season_year', v_year,
          'vintage_year_preserved', r.e_vintage,
          'quarters_released', 0
        ),
        auth.uid()
      );

      action := 'repaired';
      note := 'season link only; vintage ' || coalesce(r.e_vintage::text, 'null') || ' preserved';
      return next;
    end if;

    if not (r.e_season = any (v_sources)) then
      v_sources := array_append(v_sources, r.e_season);
    end if;
  end loop;

  -- Informational: source seasons left with no live entry. They are NOT
  -- deleted here — retiring a season row is a separate explicit decision.
  for r in
    select s.id                as s_id,
           s.season_year       as s_year,
           s.vineyard_id       as s_vineyard,
           vy.name             as vy_name,
           pd.name             as pd_name,
           (select count(*) from public.pruning_row_segments g
             where g.pruning_season_id = s.id and g.completed) as leftover
    from public.pruning_seasons s
    left join public.vineyards vy on vy.id = s.vineyard_id
    left join public.paddocks pd  on pd.id = s.paddock_id
    where s.id = any (v_sources)
      and s.deleted_at is null
      and not exists (
        select 1 from public.pruning_entries e
        where e.pruning_season_id = s.id and e.deleted_at is null
      )
    order by s.season_year
  loop
    action          := 'source_season_now_empty';
    entry_id        := null;
    entry_date      := null;
    vineyard_name   := coalesce(r.vy_name, '(unknown vineyard)');
    block_name      := coalesce(r.pd_name, '(unknown block)');
    rows_covered    := '—';
    quarters        := r.leftover::integer;
    old_season_id   := r.s_id;
    old_season_year := r.s_year;
    new_season_id   := null;
    new_season_year := null;
    vintage_year    := null;
    note            := 'no live entry left under this season row — retire it with sql/163 '
      || 'if the portal should stop listing it';
    return next;
  end loop;

  return;
end;
$$;

revoke all on function public.repair_pruning_entry_seasons(boolean, uuid, uuid[], boolean)
  from public, anon, authenticated;
grant execute on function public.repair_pruning_entry_seasons(boolean, uuid, uuid[], boolean) to authenticated;
revoke execute on function public.repair_pruning_entry_seasons(boolean, uuid, uuid[], boolean) from anon;

-- ---------------------------------------------------------------------------
-- 4. PRODUCTION VERIFICATION — does the LIVE database enforce the rule?
--
--    Scans every routine in `public` whose body writes `pruning_entries`
--    (not a fixed name list, so a stale overload an old client can still
--    resolve is caught) and reports whether it resolves the season
--    server-side from the entry date.
-- ---------------------------------------------------------------------------
create or replace function public.verify_pruning_season_enforcement()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  r            record;
  v_writers    jsonb := '[]'::jsonb;
  v_unprotect  jsonb := '[]'::jsonb;
  v_overloads  jsonb := '[]'::jsonb;
  v_client     jsonb := '[]'::jsonb;
  v_enforced   boolean;
  v_signature  text;
  v_resolves   boolean;
  v_sets       boolean;
  v_admin      boolean;
begin
  if not public.is_system_admin() then
    raise exception 'not allowed';
  end if;

  for r in
    select p.oid,
           p.proname,
           pg_get_function_identity_arguments(p.oid) as args,
           p.prosecdef,
           coalesce(p.prosrc, '') as src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and coalesce(p.prosrc, '') ~* '(insert into|update)\s+(public\.)?pruning_entries'
    order by p.proname, p.oid
  loop
    v_signature := r.proname || '(' || r.args || ')';
    v_resolves  := r.src ~* 'resolve_pruning_season';
    -- Does the routine actually SET the season link? A reversal (deleted_at)
    -- or a totals recount does not, and must not be judged as if it did.
    v_sets := r.src ~* 'insert into\s+(public\.)?pruning_entries\s*\([^)]*pruning_season_id'
           or r.src ~* 'set\s+pruning_season_id';
    -- Reviewed System-Administrator tooling (sql/163, sql/164) is allowed to
    -- re-point a season deliberately; it is not a client write path.
    v_admin := r.src ~* 'is_system_admin';

    v_writers := v_writers || jsonb_build_object(
      'routine', v_signature,
      'role', case when v_admin then 'admin_tool'
                   when v_sets then 'client_write_rpc'
                   else 'non_season_writer' end,
      'sets_season_link', v_sets,
      'resolves_season_server_side', v_resolves,
      'derives_year_from_entry_date', r.src ~* 'extract\(year from',
      'echoes_client_season_year_only', r.src ~* 'season_year_requested',
      'reports_season_mismatch', r.src ~* 'season_mismatch|season_changed',
      'security_definer', r.prosecdef,
      'callable_by_authenticated', has_function_privilege('authenticated', r.oid, 'execute'),
      'anon_can_execute', has_function_privilege('anon', r.oid, 'execute')
    );

    -- A client-reachable writer that sets the season link WITHOUT the resolver
    -- can still store a client-chosen season. That is the hole an old app
    -- version drives through.
    if v_sets and not v_resolves and not v_admin then
      v_unprotect := v_unprotect || jsonb_build_object(
        'routine', v_signature,
        'callable_by_authenticated', has_function_privilege('authenticated', r.oid, 'execute'),
        -- PostgREST resolves an RPC by the exact set of argument NAMES, so a
        -- superseded signature left behind is still reachable by an old build.
        'suggested_cleanup', format('drop function if exists public.%I(%s);', r.proname, r.args)
      );
    end if;
  end loop;

  -- Stale overloads of the two write RPCs (PostgREST resolves by argument
  -- names, so an old signature left behind is still reachable).
  for r in
    select p.proname, count(*)::integer as versions,
           jsonb_agg(pg_get_function_identity_arguments(p.oid) order by p.oid) as signatures
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('record_pruning_entry','update_pruning_entry','delete_pruning_entry')
    group by p.proname
    having count(*) > 1
  loop
    v_overloads := v_overloads || jsonb_build_object(
      'routine', r.proname, 'versions', r.versions, 'signatures', r.signatures);
  end loop;

  -- Client-writable surfaces (RLS write policies) on the pruning tables.
  for r in
    select pol.tablename, pol.policyname, pol.cmd
    from pg_policies pol
    where pol.schemaname = 'public'
      and pol.tablename in ('pruning_entries','pruning_row_segments','pruning_seasons')
      and pol.cmd in ('INSERT','UPDATE','DELETE','ALL')
    order by pol.tablename, pol.policyname
  loop
    v_client := v_client || jsonb_build_object(
      'table', r.tablename, 'policy', r.policyname, 'command', r.cmd);
  end loop;

  v_enforced := jsonb_array_length(v_unprotect) = 0;

  return jsonb_build_object(
    'checked_at', now(),
    'canonical_rule', 'season_year = year(entry_date); vintage_year = resolve_vineyard_vintage_year(vineyard, entry_date)',
    'verdict', case when v_enforced
                    then 'ENFORCED — every routine that writes pruning_entries resolves the season server-side'
                    else 'NOT ENFORCED — see unprotected_writers' end,
    'enforced', v_enforced,
    'entry_writers', v_writers,
    'unprotected_writers', v_unprotect,
    'stale_overloads', v_overloads,
    'client_write_policies', v_client,
    'shared_core_present', to_regprocedure(
      'public.resolve_pruning_season_for_date(uuid, uuid, date, uuid, timestamptz, boolean)') is not null,
    'mismatch_log_present', to_regclass('public.pruning_season_mismatch_log') is not null,
    'mismatch_log', (
      select jsonb_build_object(
        'rows', count(*),
        'submissions', coalesce(sum(occurrences), 0),
        'last_seen_at', max(last_seen_at)
      ) from public.pruning_season_mismatch_log
    ),
    'live_entry_mismatches', (
      select count(*)
      from public.pruning_entries e
      left join public.pruning_seasons s on s.id = e.pruning_season_id
      where e.deleted_at is null
        and s.season_year is distinct from extract(year from e.entry_date)::integer
    ),
    'reversed_entry_mismatches', (
      select count(*)
      from public.pruning_entries e
      left join public.pruning_seasons s on s.id = e.pruning_season_id
      where e.deleted_at is not null
        and s.season_year is distinct from extract(year from e.entry_date)::integer
    ),
    'season_rows_with_legacy_ids', (
      select count(*)
      from public.pruning_seasons s
      where s.deleted_at is null
        and s.id <> public.derive_pruning_season_id(s.vineyard_id, s.paddock_id, s.season_year)
    )
  );
end;
$$;

revoke all on function public.verify_pruning_season_enforcement() from public, anon, authenticated;
grant execute on function public.verify_pruning_season_enforcement() to authenticated;
revoke execute on function public.verify_pruning_season_enforcement() from anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 5. Validation — this migration ABORTS if any of these fail
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.pruning_season_mismatch_log') is null then
    raise exception 'SQL 164: mismatch log missing';
  end if;
  if to_regprocedure('public.resolve_pruning_season_for_date(uuid, uuid, date, uuid, timestamptz, boolean)') is null then
    raise exception 'SQL 164: shared resolver core missing';
  end if;
  if to_regprocedure('public.repair_pruning_entry_seasons(boolean, uuid, uuid[], boolean)') is null then
    raise exception 'SQL 164: repair function missing';
  end if;
  if to_regprocedure('public.verify_pruning_season_enforcement()') is null then
    raise exception 'SQL 164: verification function missing';
  end if;
  if to_regprocedure('public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz)') is null then
    raise exception 'SQL 164: the SQL 161 resolver signature must be preserved';
  end if;
  if has_function_privilege('anon',
    'public.resolve_pruning_season_for_date(uuid, uuid, date, uuid, timestamptz, boolean)', 'execute') then
    raise exception 'SQL 164: the unauthenticated core must not be callable by anon';
  end if;
  if has_function_privilege('authenticated',
    'public.resolve_pruning_season_for_date(uuid, uuid, date, uuid, timestamptz, boolean)', 'execute') then
    raise exception 'SQL 164: the core must only be reachable through the authorised wrapper';
  end if;
  if has_function_privilege('anon',
    'public.repair_pruning_entry_seasons(boolean, uuid, uuid[], boolean)', 'execute') then
    raise exception 'SQL 164: anon must not run the repair';
  end if;
  raise notice 'SQL 164 pruning season repair + enforcement verification: APPLIED (nothing repaired yet)';
end$$;

-- ---------------------------------------------------------------------------
-- 6. HOW TO RUN (System Administrator, in this order)
-- ---------------------------------------------------------------------------
-- a) Rollback-only test suite first:
--      sql/tests/164_pruning_season_repair_tests.sql
--
-- b) Confirm the LIVE RPCs enforce the rule BEFORE repairing data:
--      select jsonb_pretty(public.verify_pruning_season_enforcement());
--    Require: "enforced": true and "unprotected_writers": [].
--    If `unprotected_writers` lists anything, a SUPERSEDED signature of a write
--    RPC is still installed. PostgREST resolves a function by the exact set of
--    argument NAMES, so an older app build can still reach it and store its own
--    season. Each entry carries a ready `suggested_cleanup` DROP statement —
--    review it, confirm no live client depends on that argument set, then run
--    it. `stale_overloads` lists the same thing grouped by routine name.
--
-- c) DRY RUN for the seven portal records (plus the JH Testing eighth). This
--    changes nothing and returns the before-and-after list:
--      select * from public.repair_pruning_entry_seasons(
--        true,
--        null,
--        array[
--          '7874c51f-2a29-44f6-b6cd-99f649e6d913',  -- 02/08/2026 Sauv Blanc  66–67
--          '4cac6a17-af89-418e-8a8c-9515941e4e3e',  -- 02/08/2026 Cab Franc   42–44
--          '632321ae-0793-4d21-b766-47011c3b8138',  -- 29/07/2026 Cab Franc   40–43
--          '5696e4fc-be7c-439a-a0a2-632832b53440',  -- 29/07/2026 Cab Franc   38–39
--          '6bc0bfe6-841a-4086-a2bf-4d6c01848fc0',  -- 28/07/2026 Cab Franc   40–41
--          '6f2b0f2c-7466-4799-9bde-43c33bcca014',  -- 23/07/2026 Cab Franc   38–39
--          '07a24186-1d9e-4998-a11e-741cc43498d6',  -- 01/07/2026 Sauv Blanc  58–60
--          '7a336b3b-457d-49b6-b35a-0e6f1cb23a1f'   -- 15/07/2026 Cab Franc @ JH Testing
--        ]::uuid[]);
--    Expect 8 rows, all action = 'planned', old_season_year 2027,
--    new_season_year 2026, vintage_year 2027 on every row.
--
-- d) APPLY the same eight once the list matches:
--      select * from public.repair_pruning_entry_seasons(
--        false, null, array[ ...the same eight... ]::uuid[]);
--
-- e) VINEYARD-WIDE sweep (every remaining entry whose season year disagrees
--    with year(entry_date)) — dry run, review, then apply:
--      select * from public.repair_pruning_entry_seasons(true);
--      select * from public.repair_pruning_entry_seasons(false);
--    One vineyard at a time is also supported, e.g. Stockmans Ridge:
--      select * from public.repair_pruning_entry_seasons(
--        false, 'fe952afe-437f-4be7-8cbf-fdd8e630411c');
--    Reversed (audit-history) entries are EXCLUDED unless you opt in:
--      select * from public.repair_pruning_entry_seasons(true, null, null, true);
--
-- f) Re-audit and confirm the split dates are gone:
--      sql/162_pruning_season_assignment_diagnostic.sql
--      select jsonb_pretty(public.verify_pruning_season_enforcement());
--    Require "live_entry_mismatches": 0.
--
-- g) Watch for old app versions still submitting the wrong season:
--      select vineyard_id, entry_date, submitted_season_year,
--             canonical_season_year, occurrences, last_seen_at
--      from public.pruning_season_mismatch_log
--      order by last_seen_at desc limit 50;
--
-- ---------------------------------------------------------------------------
-- 7. REVERT a repair run (uses the log; run as postgres)
-- ---------------------------------------------------------------------------
-- with run as (
--   select * from public.pruning_season_backfill_log
--   where ran_at >= '<the ran_at of the run you want to undo>'
-- )
-- update public.pruning_row_segments g
-- set pruning_season_id = r.previous_season_id, updated_at = now()
-- from run r where g.pruning_entry_id = r.pruning_entry_id;
-- with run as (
--   select * from public.pruning_season_backfill_log
--   where ran_at >= '<same timestamp>'
-- )
-- update public.pruning_entries e
-- set pruning_season_id = r.previous_season_id, updated_at = now()
-- from run r where e.id = r.pruning_entry_id;

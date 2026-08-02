-- =============================================================================
-- 161: Canonical pruning-season assignment — one rule for iOS, Android, portal.
--
-- CONFIRMED DEFECT
-- Pruning entries recorded on the SAME DAY landed under DIFFERENT
-- `pruning_seasons.season_year` values (2 Aug 2026: Sauvignon Blanc → 2027,
-- Pinot Noir → 2026, Cabernet Franc → 2027), because the season a new entry
-- attaches to was decided ENTIRELY by the client:
--
--   * `record_pruning_entry` (109 → 119) resolved the season by
--     `p_season_id` FIRST and attached the entry to whatever row that id
--     pointed at — with NO check that the row's `season_year` matched the
--     entry date. A client holding a 2027 season row for a block therefore
--     wrote August-2026 work into season 2027 and the server accepted it.
--   * `p_season_year` was only consulted when `p_season_id` did not resolve,
--     and was never validated against `p_entry_date`.
--   * iOS sent `p_season_year` = the DEVICE's calendar year at sync time;
--     Android sent the year of the ENTRY DATE. Two definitions, one column.
--   * `update_pruning_entry` (120) deliberately kept the entry's season on a
--     date edit, so moving an entry across a year boundary left it under the
--     old season for ever.
--
-- CANONICAL RULE (this migration makes the SERVER enforce it)
--   pruning season year = calendar year in which the winter pruning happened
--                       = extract(year from pruning_entries.entry_date)
--   vintage year        = resolve_vineyard_vintage_year(vineyard, entry_date)
--                         (SQL 119 — unchanged, still the costing vintage)
-- So work done in August 2026 is ALWAYS season 2026 / vintage 2027.
-- season_year is NEVER derived from vintage_year.
--
-- WHAT CHANGES
--   1. `derive_pruning_season_id(vineyard, paddock, year)` — the deterministic
--      MD5 v3 season id both mobile clients already compute, now available
--      server-side (same technique as `derive_paddock_row_id`, SQL 115).
--   2. `resolve_pruning_season(vineyard, paddock, entry_date, season_id,
--      client_updated_at)` — THE single resolver:
--        a. the live row for (vineyard, paddock, year-of-entry-date),
--        b. else the caller's `p_season_id` row, but ONLY when it is live,
--           belongs to the same vineyard + paddock AND already carries that
--           season year,
--        c. else create the canonical row (deterministic id, resurrecting a
--           soft-deleted one). The partial unique index stays safe because
--           (a) proved no live row exists for that year.
--      A client id pointing at the WRONG year is ignored, never followed.
--   3. `record_pruning_entry` (same 17-parameter signature — no client change
--      required) uses the resolver, and treats a mismatching `p_season_year`
--      as advisory only: it is ignored, and the response reports the
--      correction so clients can adopt the canonical id.
--      The response gains: 'season_year', 'season_year_requested',
--      'season_corrected'.
--   4. `update_pruning_entry` (same signature) re-points an entry whose
--      EDITED date moves it into another pruning year: the entry's own
--      quarters migrate to the canonical season, and any quarter the target
--      season already holds is released rather than duplicated.
--      The response gains: 'season_year', 'season_changed'.
--
-- WHAT DOES NOT CHANGE
--   * No historical row is rewritten. Existing mis-assigned entries stay
--     exactly as they are until the audit in
--     sql/162_pruning_season_assignment_diagnostic.sql has been reviewed.
--     A replay of an ALREADY-STORED entry reports 'season_mismatch': true
--     instead of quietly moving it.
--   * RLS, roles, quarter idempotency, work-task linking, attribution,
--     vintage resolution and the audit table are byte-identical to 119/120.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Deterministic season id (matches iOS `PruningSeasonId.make` and Kotlin
--    `UUID.nameUUIDFromBytes` — MD5, version 3, IETF variant).
--    Name: 'vinetrack-pruning-season|{vineyard}|{paddock}|{year}' (lowercase).
-- ---------------------------------------------------------------------------
create or replace function public.derive_pruning_season_id(
  p_vineyard_id uuid,
  p_paddock_id uuid,
  p_season_year integer
) returns uuid
language plpgsql immutable
as $$
declare
  v_name text;
  v_bytes bytea;
begin
  v_name := 'vinetrack-pruning-season|' || lower(p_vineyard_id::text)
    || '|' || lower(p_paddock_id::text)
    || '|' || p_season_year::text;
  v_bytes := decode(md5(v_name), 'hex');
  v_bytes := set_byte(v_bytes, 6, ((get_byte(v_bytes, 6) & 15) | 48));   -- version 3
  v_bytes := set_byte(v_bytes, 8, ((get_byte(v_bytes, 8) & 63) | 128));  -- IETF variant
  return encode(v_bytes, 'hex')::uuid;
end;
$$;

revoke all on function public.derive_pruning_season_id(uuid, uuid, integer) from public, anon;
grant execute on function public.derive_pruning_season_id(uuid, uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. THE resolver — the only place a pruning season is chosen.
--    Security definer: it may create the canonical season row on behalf of an
--    authorised caller. The caller's vineyard role is verified by the RPCs
--    that call it; the direct grant is limited to authenticated users and the
--    function itself re-checks membership.
-- ---------------------------------------------------------------------------
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
begin
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;
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

  -- (c) create the canonical row under the deterministic id both clients
  -- compute, resurrecting it if it was soft-deleted. (a) proved that no live
  -- row exists for this (vineyard, paddock, year), so the partial unique
  -- index cannot be violated.
  v_season_id := public.derive_pruning_season_id(p_vineyard_id, p_paddock_id, v_year);

  insert into public.pruning_seasons (
    id, vineyard_id, paddock_id, season_year, created_by, client_updated_at
  ) values (
    v_season_id, p_vineyard_id, p_paddock_id, v_year, auth.uid(), p_client_updated_at
  )
  on conflict (id) do update
    set deleted_at = null, updated_at = now()
    where public.pruning_seasons.deleted_at is not null;

  return v_season_id;
end;
$$;

revoke all on function public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz) from public, anon;
grant execute on function public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. record_pruning_entry — season resolved server-side from the entry date.
--    Signature identical to SQL 119 (17 parameters, same order, same
--    defaults) so every deployed client keeps working unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.record_pruning_entry(
  p_id uuid,
  p_vineyard_id uuid,
  p_season_id uuid,
  p_paddock_id uuid,
  p_season_year integer,
  p_entry_date date,
  p_worker text,
  p_labour_hours numeric default null,
  p_start_time timestamptz default null,
  p_finish_time timestamptz default null,
  p_method text default null,
  p_notes text default null,
  p_estimated_vines integer default null,
  p_client_updated_at timestamptz default null,
  p_segments jsonb default '[]'::jsonb,
  p_work_task_id uuid default null,
  p_vintage_year integer default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_requested integer;
  v_attributed integer;
  v_seg jsonb;
  v_row_id uuid;
  v_row_num integer;
  v_label text;
  v_year integer;
  v_season_id uuid;
  v_vintage integer;
  v_stored_season uuid;
  v_mismatch boolean := false;
begin
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;
  if p_entry_date is null then
    raise exception 'pruning entry date is required';
  end if;

  -- CANONICAL season year: the calendar year of the pruning work. A client
  -- p_season_year that disagrees is advisory only and is ignored (never an
  -- error — an old build must not wedge its offline queue).
  v_year := extract(year from p_entry_date)::integer;

  -- Production/costing vintage (SQL 119) — server resolution is
  -- authoritative; a mismatching client p_vintage_year is ignored.
  v_vintage := public.resolve_vineyard_vintage_year(p_vineyard_id, p_entry_date);

  -- THE season (SQL 161 resolver): always the row for (block, v_year).
  v_season_id := public.resolve_pruning_season(
    p_vineyard_id, p_paddock_id, p_entry_date, p_season_id, p_client_updated_at
  );

  -- One task per entry: if another live entry already owns this task id
  -- (e.g. a raced replay), record the entry WITHOUT the link rather than
  -- failing the queue or stealing the link.
  if p_work_task_id is not null and exists (
    select 1 from public.pruning_entries
    where work_task_id = p_work_task_id and id <> p_id and deleted_at is null
  ) then
    p_work_task_id := null;
  end if;

  -- Replaying a delete-raced entry: never resurrect.
  if exists (select 1 from public.pruning_entries where id = p_id and deleted_at is not null) then
    return jsonb_build_object(
      'entry_id', p_id, 'requested', 0, 'attributed', 0, 'deleted', true,
      'vintage_year', v_vintage, 'season_year', v_year
    );
  end if;

  insert into public.pruning_entries (
    id, vineyard_id, pruning_season_id, paddock_id, entry_date, worker_or_crew,
    labour_hours, start_time, finish_time, pruning_method, notes,
    work_task_id, vintage_year, created_by, client_updated_at
  ) values (
    p_id, p_vineyard_id, v_season_id, p_paddock_id, p_entry_date, coalesce(p_worker, ''),
    p_labour_hours, p_start_time, p_finish_time, coalesce(p_method, 'spur'), coalesce(p_notes, ''),
    p_work_task_id, v_vintage, auth.uid(), p_client_updated_at
  )
  on conflict (id) do nothing;

  -- A REPLAY of an entry stored earlier under a non-canonical season is
  -- REPORTED, never silently moved: historical corrections are a reviewed
  -- data exercise (see sql/162 diagnostic), not a side effect of a retry.
  select pruning_season_id into v_stored_season
  from public.pruning_entries where id = p_id;
  if v_stored_season is distinct from v_season_id then
    v_mismatch := true;
    v_season_id := v_stored_season;   -- keep working against the stored season
  end if;

  -- Replay fills a MISSING vintage only — a stored vintage is never
  -- overwritten, so later Operational Preference changes can't rewrite
  -- historical costing.
  update public.pruning_entries
  set vintage_year = v_vintage, updated_at = now()
  where id = p_id and deleted_at is null and vintage_year is null;

  -- Idempotent link back-fill on replay: only fills an EMPTY link — a replay
  -- can never overwrite an existing (possibly different) linked task.
  -- NOTE: p_work_task_id may reference a work_tasks row that does not exist
  -- yet (offline queues replay in either order) — deliberate, see SQL 114.
  if p_work_task_id is not null then
    update public.pruning_entries
    set work_task_id = p_work_task_id, updated_at = now()
    where id = p_id and deleted_at is null and work_task_id is null;
  end if;

  v_requested := coalesce(jsonb_array_length(p_segments), 0);

  for v_seg in select * from jsonb_array_elements(coalesce(p_segments, '[]'::jsonb))
  loop
    v_row_num := coalesce(nullif(v_seg->>'row', '')::integer, 0);
    v_label := coalesce(nullif(v_seg->>'label', ''), v_row_num::text);
    begin
      v_row_id := nullif(v_seg->>'row_id', '')::uuid;
    exception when others then
      v_row_id := null;
    end;

    -- Legacy clients send only the number — resolve the configured row id
    -- from the paddock's stored rows so both identity schemes converge.
    if v_row_id is null then
      select (elem->>'id')::uuid into v_row_id
      from public.paddocks p
      cross join lateral jsonb_array_elements(coalesce(p.rows, '[]'::jsonb)) elem
      where p.id = p_paddock_id
        and jsonb_typeof(elem->'number') = 'number'
        and (elem->>'number')::integer = v_row_num
        and (elem->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      limit 1;
    end if;

    if v_row_id is not null then
      -- Adopt any legacy fallback quarter for the same number so it can't be
      -- double-counted under both identities.
      update public.pruning_row_segments s
      set paddock_row_id = v_row_id,
          row_label = coalesce(s.row_label, v_label),
          updated_at = now()
      where s.pruning_season_id = v_season_id
        and s.paddock_row_id is null
        and s.row_number = v_row_num
        and not exists (
          select 1 from public.pruning_row_segments x
          where x.pruning_season_id = v_season_id
            and x.paddock_row_id = v_row_id
            and x.segment_number = s.segment_number
        );

      insert into public.pruning_row_segments (
        vineyard_id, pruning_season_id, paddock_id, paddock_row_id,
        row_number, row_label, segment_number,
        completed, completed_at, completed_by, pruning_entry_id
      ) values (
        p_vineyard_id, v_season_id, p_paddock_id, v_row_id,
        v_row_num, v_label, (v_seg->>'segment')::integer,
        true, now(), coalesce(p_worker, ''), p_id
      )
      on conflict (pruning_season_id, paddock_row_id, segment_number) where paddock_row_id is not null
      do update
        set completed = true,
            completed_at = coalesce(public.pruning_row_segments.completed_at, excluded.completed_at),
            completed_by = excluded.completed_by,
            pruning_entry_id = excluded.pruning_entry_id,
            row_number = excluded.row_number,
            row_label = excluded.row_label,
            updated_at = now()
        where public.pruning_row_segments.completed = false;
    else
      insert into public.pruning_row_segments (
        vineyard_id, pruning_season_id, paddock_id,
        row_number, row_label, segment_number,
        completed, completed_at, completed_by, pruning_entry_id
      ) values (
        p_vineyard_id, v_season_id, p_paddock_id,
        v_row_num, v_label, (v_seg->>'segment')::integer,
        true, now(), coalesce(p_worker, ''), p_id
      )
      on conflict (pruning_season_id, row_number, segment_number) where paddock_row_id is null
      do update
        set completed = true,
            completed_at = coalesce(public.pruning_row_segments.completed_at, excluded.completed_at),
            completed_by = excluded.completed_by,
            pruning_entry_id = excluded.pruning_entry_id,
            row_label = excluded.row_label,
            updated_at = now()
        where public.pruning_row_segments.completed = false;
    end if;
  end loop;

  select count(*)::integer into v_attributed
  from public.pruning_row_segments
  where pruning_entry_id = p_id;

  update public.pruning_entries
  set row_equivalents_completed = v_attributed / 4.0,
      estimated_vines_completed = case
        when v_requested > 0 then round(coalesce(p_estimated_vines, 0)::numeric * v_attributed / v_requested)::integer
        else 0
      end,
      updated_at = now()
  where id = p_id;

  return jsonb_build_object(
    'entry_id', p_id,
    'season_id', v_season_id,
    'season_year', (select season_year from public.pruning_seasons where id = v_season_id),
    'season_year_requested', p_season_year,
    'season_corrected', p_season_id is distinct from v_season_id,
    'season_mismatch', v_mismatch,
    'vintage_year', v_vintage,
    'requested', v_requested,
    'attributed', v_attributed,
    'deleted', false
  );
end;
$$;

revoke all on function public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb, uuid, integer) from public, anon;
grant execute on function public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb, uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. update_pruning_entry — a date edit that crosses a pruning year now
--    re-points the entry to the canonical season and migrates its quarters.
--    Signature identical to SQL 120.
-- ---------------------------------------------------------------------------
create or replace function public.update_pruning_entry(
  p_entry_id uuid,
  p_entry_date date,
  p_worker text,
  p_labour_hours numeric default null,
  p_start_time timestamptz default null,
  p_finish_time timestamptz default null,
  p_method text default null,
  p_notes text default null,
  p_estimated_vines integer default null,
  p_segments jsonb default '[]'::jsonb,
  p_work_task_id uuid default null,
  p_clear_work_task boolean default false,
  p_vintage_year integer default null,
  p_client_updated_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_entry public.pruning_entries%rowtype;
  v_vintage integer;
  v_requested integer;
  v_attributed integer;
  v_prev_quarters integer;
  v_removed integer := 0;
  v_conflicts jsonb := '[]'::jsonb;
  v_new_keys text[] := '{}';
  v_seg jsonb;
  v_row_id uuid;
  v_row_num integer;
  v_seg_num integer;
  v_label text;
  v_new_task uuid;
  v_task_changed boolean := false;
  v_task_conflict boolean := false;
  v_owner uuid;
  v_is_replay boolean := false;
  v_season_id uuid;
  v_prev_season uuid;
  v_season_changed boolean := false;
begin
  select * into v_entry from public.pruning_entries where id = p_entry_id;
  if not found then
    return jsonb_build_object('entry_id', p_entry_id, 'error', 'entry_not_found');
  end if;
  if v_entry.deleted_at is not null then
    return jsonb_build_object('entry_id', p_entry_id, 'error', 'entry_reversed');
  end if;

  if not public.has_vineyard_role(v_entry.vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;

  -- Last-write-wins for descriptive fields: an edit OLDER than the stored
  -- client timestamp is skipped entirely (a replay can never restore
  -- quarters or values removed by a newer edit on another device).
  if v_entry.client_updated_at is not null
     and p_client_updated_at is not null
     and p_client_updated_at < v_entry.client_updated_at then
    select count(*)::integer into v_attributed
    from public.pruning_row_segments where pruning_entry_id = p_entry_id;
    return jsonb_build_object(
      'entry_id', p_entry_id,
      'season_id', v_entry.pruning_season_id,
      'season_year', (select season_year from public.pruning_seasons where id = v_entry.pruning_season_id),
      'vintage_year', v_entry.vintage_year,
      'attributed', v_attributed,
      'conflicts', '[]'::jsonb,
      'season_changed', false,
      'stale', true
    );
  end if;

  -- Exact-replay detection (same client timestamp already applied): the edit
  -- is re-applied idempotently but the audit insert is skipped below.
  v_is_replay := v_entry.client_updated_at is not null
    and p_client_updated_at is not null
    and p_client_updated_at = v_entry.client_updated_at;

  -- Production/costing vintage (SQL 119) — server resolution is
  -- authoritative; a mismatching client p_vintage_year is silently ignored.
  v_vintage := public.resolve_vineyard_vintage_year(v_entry.vineyard_id, p_entry_date);

  -- SQL 161: the technical season follows the EDITED date. Within the same
  -- pruning year nothing moves; a date edit that crosses into another year
  -- re-points the entry to that year's canonical season and takes this
  -- entry's own quarters with it.
  v_prev_season := v_entry.pruning_season_id;
  v_season_id := public.resolve_pruning_season(
    v_entry.vineyard_id, v_entry.paddock_id, p_entry_date,
    v_entry.pruning_season_id, p_client_updated_at
  );

  if v_season_id is distinct from v_prev_season then
    -- Release any of THIS entry's quarters the target season already holds —
    -- a quarter can exist only once per season, and another entry's claim is
    -- never stolen. Released quarters are reported as conflicts below.
    update public.pruning_row_segments s
    set completed = false,
        completed_at = null,
        completed_by = null,
        pruning_entry_id = null,
        updated_at = now()
    where s.pruning_entry_id = p_entry_id
      and exists (
        select 1 from public.pruning_row_segments x
        where x.pruning_season_id = v_season_id
          and x.segment_number = s.segment_number
          and (
            (s.paddock_row_id is not null and x.paddock_row_id = s.paddock_row_id)
            or (s.paddock_row_id is null and x.paddock_row_id is null and x.row_number = s.row_number)
          )
      );

    update public.pruning_row_segments s
    set pruning_season_id = v_season_id, updated_at = now()
    where s.pruning_entry_id = p_entry_id;

    update public.pruning_entries
    set pruning_season_id = v_season_id, updated_at = now()
    where id = p_entry_id;

    v_entry.pruning_season_id := v_season_id;
    v_season_changed := true;
  end if;

  -- Work Task link changes: explicit unlink beats everything; a provided
  -- different task id must be same-vineyard and not owned by another entry.
  v_new_task := v_entry.work_task_id;
  if p_clear_work_task then
    v_new_task := null;
  elsif p_work_task_id is not null and p_work_task_id is distinct from v_entry.work_task_id then
    if exists (
      select 1 from public.work_tasks
      where id = p_work_task_id and vineyard_id <> v_entry.vineyard_id
    ) then
      raise exception 'work task belongs to a different vineyard';
    end if;
    if exists (
      select 1 from public.pruning_entries
      where work_task_id = p_work_task_id and id <> p_entry_id and deleted_at is null
    ) then
      v_task_conflict := true; -- keep the current link, report the refusal
    else
      v_new_task := p_work_task_id;
    end if;
  end if;
  v_task_changed := v_new_task is distinct from v_entry.work_task_id;

  select count(*)::integer into v_prev_quarters
  from public.pruning_row_segments where pruning_entry_id = p_entry_id;

  v_requested := coalesce(jsonb_array_length(p_segments), 0);

  -- Pass 1 — claim/keep every quarter in the NEW set. Identity resolution
  -- and the adopt-legacy convergence mirror record_pruning_entry (SQL 117).
  for v_seg in select * from jsonb_array_elements(coalesce(p_segments, '[]'::jsonb))
  loop
    v_row_num := coalesce(nullif(v_seg->>'row', '')::integer, 0);
    v_seg_num := coalesce(nullif(v_seg->>'segment', '')::integer, 0);
    v_label := coalesce(nullif(v_seg->>'label', ''), v_row_num::text);
    begin
      v_row_id := nullif(v_seg->>'row_id', '')::uuid;
    exception when others then
      v_row_id := null;
    end;

    if v_row_id is null then
      select (elem->>'id')::uuid into v_row_id
      from public.paddocks p
      cross join lateral jsonb_array_elements(coalesce(p.rows, '[]'::jsonb)) elem
      where p.id = v_entry.paddock_id
        and jsonb_typeof(elem->'number') = 'number'
        and (elem->>'number')::integer = v_row_num
        and (elem->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      limit 1;
    end if;

    if v_row_id is not null then
      v_new_keys := array_append(v_new_keys, 'id:' || lower(v_row_id::text) || ':' || v_seg_num);

      -- Adopt any legacy fallback quarter for the same number so it can't be
      -- double-counted under both identities.
      update public.pruning_row_segments s
      set paddock_row_id = v_row_id,
          row_label = coalesce(s.row_label, v_label),
          updated_at = now()
      where s.pruning_season_id = v_entry.pruning_season_id
        and s.paddock_row_id is null
        and s.row_number = v_row_num
        and not exists (
          select 1 from public.pruning_row_segments x
          where x.pruning_season_id = v_entry.pruning_season_id
            and x.paddock_row_id = v_row_id
            and x.segment_number = s.segment_number
        );

      insert into public.pruning_row_segments (
        vineyard_id, pruning_season_id, paddock_id, paddock_row_id,
        row_number, row_label, segment_number,
        completed, completed_at, completed_by, pruning_entry_id
      ) values (
        v_entry.vineyard_id, v_entry.pruning_season_id, v_entry.paddock_id, v_row_id,
        v_row_num, v_label, v_seg_num,
        true, now(), coalesce(p_worker, ''), p_entry_id
      )
      on conflict (pruning_season_id, paddock_row_id, segment_number) where paddock_row_id is not null
      do update
        set completed = true,
            completed_at = coalesce(public.pruning_row_segments.completed_at, excluded.completed_at),
            completed_by = excluded.completed_by,
            pruning_entry_id = excluded.pruning_entry_id,
            row_number = excluded.row_number,
            row_label = excluded.row_label,
            updated_at = now()
        where public.pruning_row_segments.completed = false;

      select pruning_entry_id into v_owner
      from public.pruning_row_segments
      where pruning_season_id = v_entry.pruning_season_id
        and paddock_row_id = v_row_id
        and segment_number = v_seg_num
      limit 1;
    else
      v_new_keys := array_append(v_new_keys, 'num:' || v_row_num || ':' || v_seg_num);

      insert into public.pruning_row_segments (
        vineyard_id, pruning_season_id, paddock_id,
        row_number, row_label, segment_number,
        completed, completed_at, completed_by, pruning_entry_id
      ) values (
        v_entry.vineyard_id, v_entry.pruning_season_id, v_entry.paddock_id,
        v_row_num, v_label, v_seg_num,
        true, now(), coalesce(p_worker, ''), p_entry_id
      )
      on conflict (pruning_season_id, row_number, segment_number) where paddock_row_id is null
      do update
        set completed = true,
            completed_at = coalesce(public.pruning_row_segments.completed_at, excluded.completed_at),
            completed_by = excluded.completed_by,
            pruning_entry_id = excluded.pruning_entry_id,
            row_label = excluded.row_label,
            updated_at = now()
        where public.pruning_row_segments.completed = false;

      select pruning_entry_id into v_owner
      from public.pruning_row_segments
      where pruning_season_id = v_entry.pruning_season_id
        and paddock_row_id is null
        and row_number = v_row_num
        and segment_number = v_seg_num
      limit 1;
    end if;

    -- Never silently save a materially different selection: report every
    -- quarter the edit could not attribute.
    if v_owner is distinct from p_entry_id then
      v_conflicts := v_conflicts || jsonb_build_object(
        'row', v_row_num,
        'segment', v_seg_num,
        'reason', 'already_completed_by_another_entry'
      );
    end if;
  end loop;

  -- Pass 2 — release quarters REMOVED from this entry. Only rows currently
  -- attributed to THIS entry are cleared; other entries' quarters are never
  -- touched (their identity keys simply aren't attributed to this entry).
  update public.pruning_row_segments s
  set completed = false,
      completed_at = null,
      completed_by = null,
      pruning_entry_id = null,
      updated_at = now()
  where s.pruning_entry_id = p_entry_id
    and not (
      (case
        when s.paddock_row_id is not null then 'id:' || lower(s.paddock_row_id::text) || ':' || s.segment_number
        else 'num:' || s.row_number || ':' || s.segment_number
      end) = any (v_new_keys)
    );
  get diagnostics v_removed = row_count;

  select count(*)::integer into v_attributed
  from public.pruning_row_segments where pruning_entry_id = p_entry_id;

  -- Descriptive fields + recomputed totals — SQL 115 reflects this at once.
  update public.pruning_entries
  set entry_date = p_entry_date,
      worker_or_crew = coalesce(p_worker, ''),
      labour_hours = p_labour_hours,
      start_time = p_start_time,
      finish_time = p_finish_time,
      pruning_method = coalesce(p_method, pruning_method),
      notes = coalesce(p_notes, ''),
      work_task_id = v_new_task,
      vintage_year = v_vintage,
      row_equivalents_completed = v_attributed / 4.0,
      estimated_vines_completed = case
        when v_requested > 0 then round(coalesce(p_estimated_vines, 0)::numeric * least(v_attributed, v_requested) / v_requested)::integer
        else 0
      end,
      updated_by = auth.uid(),
      updated_at = now(),
      client_updated_at = coalesce(p_client_updated_at, now())
  where id = p_entry_id;

  -- Audit history — skipped for byte-identical replays of an already-applied
  -- edit so offline retries don't spam the log.
  if not (v_is_replay and v_removed = 0 and v_attributed = v_prev_quarters
          and not v_task_changed and not v_season_changed) then
    insert into public.pruning_entry_audit (
      vineyard_id, pruning_entry_id, event_type,
      previous_quarters, new_quarters,
      previous_labour_hours, new_labour_hours,
      work_task_changed, detail, created_by
    ) values (
      v_entry.vineyard_id, p_entry_id, 'pruning_entry_edited',
      v_prev_quarters, v_attributed,
      v_entry.labour_hours, p_labour_hours,
      v_task_changed,
      jsonb_build_object(
        'requested', v_requested,
        'removed', v_removed,
        'conflicts', v_conflicts,
        'previous_entry_date', v_entry.entry_date,
        'entry_date', p_entry_date,
        'previous_vintage_year', v_entry.vintage_year,
        'vintage_year', v_vintage,
        'previous_season_id', v_prev_season,
        'season_id', v_entry.pruning_season_id,
        'season_changed', v_season_changed,
        'previous_work_task_id', v_entry.work_task_id,
        'work_task_id', v_new_task
      ),
      auth.uid()
    );
  end if;

  return jsonb_build_object(
    'entry_id', p_entry_id,
    'season_id', v_entry.pruning_season_id,
    'season_year', (select season_year from public.pruning_seasons where id = v_entry.pruning_season_id),
    'season_changed', v_season_changed,
    'vintage_year', v_vintage,
    'requested', v_requested,
    'attributed', v_attributed,
    'removed', v_removed,
    'added', greatest(v_attributed - (v_prev_quarters - v_removed), 0),
    'conflicts', v_conflicts,
    'work_task_id', v_new_task,
    'work_task_conflict', v_task_conflict,
    'stale', false
  );
end;
$$;

revoke all on function public.update_pruning_entry(uuid, date, text, numeric, timestamptz, timestamptz, text, text, integer, jsonb, uuid, boolean, integer, timestamptz) from public, anon;
grant execute on function public.update_pruning_entry(uuid, date, text, numeric, timestamptz, timestamptz, text, text, integer, jsonb, uuid, boolean, integer, timestamptz) to authenticated;

-- Make PostgREST pick up the changed functions immediately.
notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 5. Validation — the migration ABORTS if any of these fail
-- ---------------------------------------------------------------------------
do $$
declare
  v_expected uuid;
begin
  if to_regprocedure('public.derive_pruning_season_id(uuid, uuid, integer)') is null then
    raise exception 'SQL 161: derive_pruning_season_id missing';
  end if;
  if to_regprocedure('public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz)') is null then
    raise exception 'SQL 161: resolve_pruning_season missing';
  end if;
  if to_regprocedure('public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb, uuid, integer)') is null then
    raise exception 'SQL 161: record_pruning_entry signature changed';
  end if;
  if to_regprocedure('public.update_pruning_entry(uuid, date, text, numeric, timestamptz, timestamptz, text, text, integer, jsonb, uuid, boolean, integer, timestamptz)') is null then
    raise exception 'SQL 161: update_pruning_entry signature changed';
  end if;

  -- Deterministic id parity with iOS `PruningSeasonId.make` / Kotlin
  -- `UUID.nameUUIDFromBytes` for the fixed vector used by the client tests:
  -- 'vinetrack-pruning-season|11111111-1111-4111-8111-111111111111|
  --  22222222-2222-4222-8222-222222222222|2026'
  v_expected := public.derive_pruning_season_id(
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222',
    2026
  );
  if v_expected is null then
    raise exception 'SQL 161: derive_pruning_season_id returned null';
  end if;
  -- MD5 v3 shape: version nibble 3, variant bits 10xx.
  if substr(v_expected::text, 15, 1) <> '3' then
    raise exception 'SQL 161: derived season id is not UUID version 3 (got %)', v_expected;
  end if;
  if position(substr(v_expected::text, 20, 1) in '89ab') = 0 then
    raise exception 'SQL 161: derived season id has the wrong variant (got %)', v_expected;
  end if;

  raise notice 'SQL 161 canonical pruning season assignment: APPLIED';
end$$;

-- ---------------------------------------------------------------------------
-- 6. Verification (run manually; read-only)
-- ---------------------------------------------------------------------------
-- Entries whose season year does not match the year of the work:
-- select e.entry_date, s.season_year, e.vintage_year, count(*)
-- from public.pruning_entries e
-- join public.pruning_seasons s on s.id = e.pruning_season_id
-- where e.deleted_at is null
--   and extract(year from e.entry_date)::integer <> s.season_year
-- group by 1, 2, 3 order by 1 desc;
--
-- Full audit incl. duplicate seasons and same-date splits:
--   sql/162_pruning_season_assignment_diagnostic.sql

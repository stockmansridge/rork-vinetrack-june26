-- =============================================================================
-- 120: Editable pruning entries — the shared, transaction-safe edit contract.
--
-- Adds ONE authoritative RPC, `update_pruning_entry`, that every client
-- (iOS, Android, Lovable portal) must use to edit a live pruning entry.
-- Clients still CANNOT write pruning_entries / pruning_row_segments directly
-- (RLS from SQL 109 is unchanged) — record, edit and reverse are the only
-- three write paths, all RPCs, all idempotent and replay-safe.
--
-- WHAT THE RPC DOES (single transaction):
--   * Loads the existing entry; rejects missing ('entry_not_found') and
--     reversed ('entry_reversed') entries with a structured JSON error —
--     never an exception, so an offline replay can inspect and retry.
--   * Verifies the caller holds an operational vineyard role.
--   * Last-write-wins for descriptive fields via p_client_updated_at: an
--     incoming edit OLDER than the stored client_updated_at is skipped and
--     returned with 'stale': true (a replay can never resurrect old values).
--   * Quarter diffing against the CURRENT server attribution:
--       - removed quarters (attributed to THIS entry, absent from the new
--         set) are released: completed=false, completed_at/by=null,
--         pruning_entry_id=null. Quarters owned by OTHER entries are never
--         touched.
--       - added quarters are claimed only while incomplete. A quarter already
--         completed by another entry is NOT stolen — it is reported in the
--         'conflicts' array (row, segment, reason) so the client can show
--         exactly what could not be attributed.
--       - unchanged quarters keep their original completed_at (the claim
--         upsert only fires WHERE completed = false).
--   * Row identity mirrors SQL 112/117: segments may carry 'row_id' (stable
--     paddock row id); legacy number-only segments resolve the configured
--     row id from paddocks.rows so both identity schemes converge.
--   * The entry KEEPS its canonical pruning_season_id (technical season
--     grouping is unchanged by an edit; date edits re-resolve only vintage).
--   * vintage_year is re-resolved server-side from the edited entry date via
--     resolve_vineyard_vintage_year (SQL 119) — a client p_vintage_year is
--     accepted only when it matches; the server value always wins silently.
--   * Work Task link: p_work_task_id (when provided AND different) links a
--     same-vineyard task not owned by another live entry;
--     p_clear_work_task=true explicitly unlinks. p_work_task_id=null with
--     p_clear_work_task=false means "no link change". Cross-vineyard links
--     raise; a task owned by another entry is refused (link kept, reported
--     via 'work_task_conflict': true).
--   * Totals are recomputed and persisted from the ACTUAL post-edit
--     attribution (row_equivalents_completed, estimated_vines_completed,
--     labour_hours, updated_by, updated_at, client_updated_at) — SQL 115
--     reflects the edit immediately.
--   * An audit row is written to the new pruning_entry_audit table
--     (previous/new quarter counts, previous/new labour hours, whether the
--     Work Task link changed). Exact replays (same client_updated_at, no
--     quarter movement) skip the audit insert so retries don't spam history.
--
-- WHAT STAYS CLIENT-SIDE (by design): the linked Work Task's own header,
-- labour lines and soft-deletes continue to flow through the EXISTING
-- work-task endpoints/offline queues with stable client-generated UUIDs
-- (idempotent by id — a replay can never duplicate a task or line). The
-- work_tasks vintage trigger from SQL 119 re-resolves the task's costing
-- vintage whenever its date changes. If the pruning edit lands but the task
-- update fails, the pruning edit is preserved and the client retries the
-- task update with the SAME ids.
--
-- PORTAL CONTRACT (Lovable): call
--   supabase.rpc('update_pruning_entry', { p_entry_id, p_entry_date,
--     p_worker, p_labour_hours, p_start_time, p_finish_time, p_method,
--     p_notes, p_estimated_vines, p_segments, p_work_task_id,
--     p_clear_work_task, p_client_updated_at })
-- with p_segments = [{ "row": 42, "segment": 3, "row_id": "<uuid|null>",
-- "label": "42" }, ...] (the FULL desired quarter set, not a delta).
-- Inspect the response: 'error' (entry_not_found | entry_reversed),
-- 'stale', and 'conflicts' [{row, segment, reason}]. Never update the
-- pruning tables directly.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Audit history for pruning entry edits
-- ---------------------------------------------------------------------------
create table if not exists public.pruning_entry_audit (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  pruning_entry_id uuid not null,
  event_type text not null check (event_type in (
    'pruning_entry_created',
    'pruning_entry_edited',
    'pruning_entry_reversed',
    'pruning_work_task_linked',
    'pruning_work_task_updated'
  )),
  previous_quarters integer,
  new_quarters integer,
  previous_labour_hours numeric,
  new_labour_hours numeric,
  work_task_changed boolean not null default false,
  detail jsonb,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists pruning_entry_audit_entry_idx
  on public.pruning_entry_audit (pruning_entry_id);
create index if not exists pruning_entry_audit_vineyard_idx
  on public.pruning_entry_audit (vineyard_id, created_at);

alter table public.pruning_entry_audit enable row level security;

drop policy if exists "pruning_entry_audit_select_members" on public.pruning_entry_audit;
create policy "pruning_entry_audit_select_members" on public.pruning_entry_audit
  for select to authenticated
  using (public.is_vineyard_member(vineyard_id));

-- Audit rows are written ONLY by the security-definer RPCs.
drop policy if exists "pruning_entry_audit_no_client_insert" on public.pruning_entry_audit;
create policy "pruning_entry_audit_no_client_insert" on public.pruning_entry_audit
  for insert to authenticated with check (false);
drop policy if exists "pruning_entry_audit_no_client_update" on public.pruning_entry_audit;
create policy "pruning_entry_audit_no_client_update" on public.pruning_entry_audit
  for update to authenticated using (false);
drop policy if exists "pruning_entry_audit_no_client_delete" on public.pruning_entry_audit;
create policy "pruning_entry_audit_no_client_delete" on public.pruning_entry_audit
  for delete to authenticated using (false);

-- ---------------------------------------------------------------------------
-- 2. RPC: update_pruning_entry
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
      'vintage_year', v_entry.vintage_year,
      'attributed', v_attributed,
      'conflicts', '[]'::jsonb,
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
  if not (v_is_replay and v_removed = 0 and v_attributed = v_prev_quarters and not v_task_changed) then
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
        'previous_work_task_id', v_entry.work_task_id,
        'work_task_id', v_new_task
      ),
      auth.uid()
    );
  end if;

  return jsonb_build_object(
    'entry_id', p_entry_id,
    'season_id', v_entry.pruning_season_id,
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

-- Make PostgREST pick up the new function immediately.
notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 3. Verification (run manually; read-only)
-- ---------------------------------------------------------------------------
-- Function signature:
-- select pg_get_function_arguments('public.update_pruning_entry'::regproc);
--
-- Recent edit audit trail for a vineyard:
-- select event_type, pruning_entry_id, previous_quarters, new_quarters,
--        previous_labour_hours, new_labour_hours, work_task_changed, created_at
-- from public.pruning_entry_audit
-- where vineyard_id = '<vineyard-uuid>'
-- order by created_at desc limit 20;

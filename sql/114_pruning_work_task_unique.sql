-- 114: Pruning Tracker — one Work Task per pruning entry (corrective to 113).
--
-- SQL 113 review outcomes:
--
--   1. UNIQUENESS. 113 created only a normal index on
--      pruning_entries.work_task_id, so nothing stopped two pruning entries
--      from linking the SAME Work Task. The intended rule is one linked task
--      per pruning recording submission — this migration enforces it with a
--      partial unique index (live rows only; soft-deleted entries release
--      their task so an explicit re-link stays possible). Any existing
--      duplicate links are resolved first: the earliest-created live entry
--      keeps the task, later ones are unlinked.
--
--   2. NON-EXISTENT TASK IDS. set_pruning_entry_work_task (and the
--      record_pruning_entry back-fill) deliberately accept a work_task_id
--      that does not exist in public.work_tasks YET. This is required for
--      offline replay: the Work Task is created client-side with a
--      client-generated UUID and pushed through its own offline queue, so
--      the pruning queue may replay BEFORE the work-task queue. Rejecting an
--      unknown id would strand the pruning queue behind the task queue.
--      Vineyard isolation still holds — an id that DOES exist and belongs to
--      another vineyard is rejected. This behaviour is intentional and now
--      documented on both functions.
--
-- Both RPCs are re-created (same signatures, so `create or replace`) with
-- guards that keep replay idempotent under the new unique index:
--   * record_pruning_entry: if another live entry already owns the task id,
--     the link is dropped (entry still records) instead of raising — a replay
--     can never fail or steal a link.
--   * set_pruning_entry_work_task: linking a task already owned by a
--     DIFFERENT live entry raises a clear error (explicit action, so the
--     user should see it rather than silently losing the link).
--
-- SQL 113 itself is untouched.

-- ---------------------------------------------------------------------------
-- 1. Resolve existing duplicates, then enforce uniqueness
-- ---------------------------------------------------------------------------
with ranked as (
  select id,
         row_number() over (
           partition by work_task_id
           order by created_at asc, id asc
         ) as rn
  from public.pruning_entries
  where work_task_id is not null and deleted_at is null
)
update public.pruning_entries e
set work_task_id = null, updated_at = now()
from ranked r
where e.id = r.id and r.rn > 1;

create unique index if not exists pruning_entries_work_task_unique
  on public.pruning_entries (work_task_id)
  where work_task_id is not null and deleted_at is null;

comment on index public.pruning_entries_work_task_unique is
  'One Work Task may be linked to at most ONE live pruning entry. Soft-deleted entries fall outside the index so their task can be explicitly re-linked.';

-- ---------------------------------------------------------------------------
-- 2. record_pruning_entry — same signature as 113, link guarded
-- ---------------------------------------------------------------------------
create or replace function public.record_pruning_entry(
  p_id uuid,
  p_vineyard_id uuid,
  p_season_id uuid,
  p_paddock_id uuid,
  p_season_year integer,
  p_entry_date date,
  p_worker text,
  p_labour_hours numeric,
  p_start_time timestamptz,
  p_finish_time timestamptz,
  p_method text,
  p_notes text,
  p_estimated_vines integer,
  p_client_updated_at timestamptz,
  p_segments jsonb,
  p_work_task_id uuid default null
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
begin
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;

  -- One task per entry: if another live entry already owns this task id
  -- (e.g. a raced replay), record the entry WITHOUT the link rather than
  -- failing the queue or stealing the link.
  if p_work_task_id is not null and exists (
    select 1 from public.pruning_entries
    where work_task_id = p_work_task_id and id <> p_id and deleted_at is null
  ) then
    p_work_task_id := null;
  end if;

  insert into public.pruning_seasons (id, vineyard_id, paddock_id, season_year, created_by, client_updated_at)
  values (p_season_id, p_vineyard_id, p_paddock_id, coalesce(p_season_year, extract(year from p_entry_date)::integer), auth.uid(), p_client_updated_at)
  on conflict (id) do nothing;

  -- Replaying a delete-raced entry: never resurrect.
  if exists (select 1 from public.pruning_entries where id = p_id and deleted_at is not null) then
    return jsonb_build_object('entry_id', p_id, 'requested', 0, 'attributed', 0, 'deleted', true);
  end if;

  insert into public.pruning_entries (
    id, vineyard_id, pruning_season_id, paddock_id, entry_date, worker_or_crew,
    labour_hours, start_time, finish_time, pruning_method, notes,
    work_task_id, created_by, client_updated_at
  ) values (
    p_id, p_vineyard_id, p_season_id, p_paddock_id, p_entry_date, coalesce(p_worker, ''),
    p_labour_hours, p_start_time, p_finish_time, coalesce(p_method, 'spur'), coalesce(p_notes, ''),
    p_work_task_id, auth.uid(), p_client_updated_at
  )
  on conflict (id) do nothing;

  -- Idempotent link back-fill on replay: only fills an EMPTY link — a replay
  -- can never overwrite an existing (possibly different) linked task.
  -- NOTE: p_work_task_id may reference a work_tasks row that does not exist
  -- yet (offline queues replay in either order) — deliberate, see header.
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
      where s.pruning_season_id = p_season_id
        and s.paddock_row_id is null
        and s.row_number = v_row_num
        and not exists (
          select 1 from public.pruning_row_segments x
          where x.pruning_season_id = p_season_id
            and x.paddock_row_id = v_row_id
            and x.segment_number = s.segment_number
        );

      insert into public.pruning_row_segments (
        vineyard_id, pruning_season_id, paddock_id, paddock_row_id,
        row_number, row_label, segment_number,
        completed, completed_at, completed_by, pruning_entry_id
      ) values (
        p_vineyard_id, p_season_id, p_paddock_id, v_row_id,
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
        p_vineyard_id, p_season_id, p_paddock_id,
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

  return jsonb_build_object('entry_id', p_id, 'requested', v_requested, 'attributed', v_attributed, 'deleted', false);
end;
$$;

revoke all on function public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb, uuid) from public;
grant execute on function public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. set_pruning_entry_work_task — uniqueness enforced, replay allowance kept
-- ---------------------------------------------------------------------------
create or replace function public.set_pruning_entry_work_task(p_entry_id uuid, p_work_task_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_vineyard uuid;
begin
  select vineyard_id into v_vineyard from public.pruning_entries where id = p_entry_id;
  if v_vineyard is null then
    return;
  end if;
  if not public.has_vineyard_role(v_vineyard, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;

  -- Vineyard isolation: a linked task must belong to the same vineyard.
  -- An id with NO work_tasks row is deliberately accepted — the task may
  -- still be sitting in the client's offline queue (see 114 header).
  if p_work_task_id is not null and exists (
    select 1 from public.work_tasks
    where id = p_work_task_id and vineyard_id <> v_vineyard
  ) then
    raise exception 'work task belongs to a different vineyard';
  end if;

  -- One task per entry: an explicit link to a task already owned by a
  -- different live entry is an error the user should see.
  if p_work_task_id is not null and exists (
    select 1 from public.pruning_entries
    where work_task_id = p_work_task_id and id <> p_entry_id and deleted_at is null
  ) then
    raise exception 'work task is already linked to another pruning entry';
  end if;

  update public.pruning_entries
  set work_task_id = p_work_task_id, updated_by = auth.uid(), updated_at = now()
  where id = p_entry_id and deleted_at is null;
end;
$$;

revoke all on function public.set_pruning_entry_work_task(uuid, uuid) from public;
grant execute on function public.set_pruning_entry_work_task(uuid, uuid) to authenticated;

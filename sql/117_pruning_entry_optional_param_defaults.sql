-- 117: record_pruning_entry — defaults for optional params (fix PGRST202 wedge).
--
-- PROBLEM
-- Both mobile clients omit JSON keys whose values are null (Swift's synthesized
-- Encodable uses encodeIfPresent; the Android shared client uses
-- explicitNulls = false). An entry recorded WITHOUT labour hours / start time /
-- finish time therefore calls the RPC with only 12 named arguments:
--
--   record_pruning_entry(p_client_updated_at, p_entry_date, p_estimated_vines,
--     p_id, p_method, p_notes, p_paddock_id, p_season_id, p_season_year,
--     p_segments, p_vineyard_id, p_worker)
--
-- PostgREST resolves functions by the exact set of provided argument names,
-- and missing arguments only resolve when they have SQL defaults. Since
-- p_labour_hours / p_start_time / p_finish_time had NO defaults, the call
-- fails with PGRST202 "Could not find the function ... in the schema cache"
-- and the entry wedges in the client's offline queue forever. Entries that
-- happened to have hours + times filled in synced fine — which is why only
-- some items wedge.
--
-- FIX
-- Same function, same body as SQL 116 (byte-identical), but the three
-- nullable parameters get `default null` so every partial call shape the
-- clients can produce resolves. This un-wedges builds already in the field
-- with no app update. Clients are also being updated to always send explicit
-- nulls, so this is belt-and-braces.
--
-- NOTE: CREATE OR REPLACE keeps the same argument types, so no drop is
-- needed and grants are re-stated below.

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
  v_year integer;
  v_season_id uuid;
begin
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;

  v_year := coalesce(p_season_year, extract(year from p_entry_date)::integer);

  -- Canonical season resolution (see SQL 116 header).
  select id into v_season_id
  from public.pruning_seasons
  where id = p_season_id and deleted_at is null;

  if v_season_id is null then
    select id into v_season_id
    from public.pruning_seasons
    where vineyard_id = p_vineyard_id
      and paddock_id = p_paddock_id
      and season_year = v_year
      and deleted_at is null
    limit 1;
  end if;

  if v_season_id is null then
    insert into public.pruning_seasons (id, vineyard_id, paddock_id, season_year, created_by, client_updated_at)
    values (p_season_id, p_vineyard_id, p_paddock_id, v_year, auth.uid(), p_client_updated_at)
    on conflict (id) do update
      set deleted_at = null, updated_at = now()
      where public.pruning_seasons.deleted_at is not null;
    v_season_id := p_season_id;
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

  -- Replaying a delete-raced entry: never resurrect.
  if exists (select 1 from public.pruning_entries where id = p_id and deleted_at is not null) then
    return jsonb_build_object('entry_id', p_id, 'requested', 0, 'attributed', 0, 'deleted', true);
  end if;

  insert into public.pruning_entries (
    id, vineyard_id, pruning_season_id, paddock_id, entry_date, worker_or_crew,
    labour_hours, start_time, finish_time, pruning_method, notes,
    work_task_id, created_by, client_updated_at
  ) values (
    p_id, p_vineyard_id, v_season_id, p_paddock_id, p_entry_date, coalesce(p_worker, ''),
    p_labour_hours, p_start_time, p_finish_time, coalesce(p_method, 'spur'), coalesce(p_notes, ''),
    p_work_task_id, auth.uid(), p_client_updated_at
  )
  on conflict (id) do nothing;

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
    'requested', v_requested,
    'attributed', v_attributed,
    'deleted', false
  );
end;
$$;

revoke all on function public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb, uuid) from public;
grant execute on function public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb, uuid) to authenticated;

-- Make PostgREST pick up the new signature immediately (Supabase normally
-- reloads on DDL, but a stale schema cache is exactly the failure mode here).
notify pgrst, 'reload schema';

-- Verification: confirm the three params now have defaults.
-- select pg_get_function_arguments('public.record_pruning_entry'::regproc);

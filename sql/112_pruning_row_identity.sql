-- 112: Pruning Tracker — tie row segments to the REAL paddock row records.
--
-- Problem: sql/109 keyed `pruning_row_segments` on a bare integer
-- `row_number`, and the apps generated rows 1…rowCount. Actual vineyard rows
-- live in `paddocks.rows` (jsonb array of { id, number, startPoint, endPoint })
-- and can be non-sequential (1,2,3,5,6), start above 1 (101,102…), or be
-- reordered. Progress must follow the stable row id, not the visible number.
--
-- This corrective migration (109 is already installed — do not edit it):
--   1. adds `paddock_row_id` (stable row identity) + `row_label` (display /
--      history snapshot) to `pruning_row_segments`,
--   2. backfills both from the paddock's configured rows by number,
--   3. replaces the old UNIQUE(season, row_number, segment) with two partial
--      unique indexes — row-id identity for configured rows, row-number
--      identity only for manual-fallback rows (paddock_row_id IS NULL),
--   4. replaces `record_pruning_entry` so segments carry `row_id` + `label`;
--      legacy clients that send only a number get the row id resolved
--      server-side, and legacy fallback segments are adopted onto the row id
--      so the same quarter can never exist twice under both identities.
--
-- NOTE: `paddocks.rows` is a jsonb column, not a table, so `paddock_row_id`
-- is a logical reference (no FK target exists). Uniqueness + RPC-only writes
-- keep it consistent.

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.pruning_row_segments
  add column if not exists paddock_row_id uuid;

alter table public.pruning_row_segments
  add column if not exists row_label text;

-- Row numbers are real-world identifiers now (may be 0 or start anywhere).
alter table public.pruning_row_segments
  drop constraint if exists pruning_row_segments_row_number_check;

-- ---------------------------------------------------------------------------
-- 2. Backfill from the paddock's configured rows (match by number)
-- ---------------------------------------------------------------------------
with paddock_rows as (
  select distinct on (p.id, (elem->>'number')::integer)
    p.id as paddock_id,
    (elem->>'id')::uuid as row_id,
    (elem->>'number')::integer as row_num
  from public.paddocks p
  cross join lateral jsonb_array_elements(coalesce(p.rows, '[]'::jsonb)) elem
  where jsonb_typeof(elem->'number') = 'number'
    and (elem->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  order by p.id, (elem->>'number')::integer
)
update public.pruning_row_segments s
set paddock_row_id = pr.row_id
from paddock_rows pr
where s.paddock_id = pr.paddock_id
  and s.row_number = pr.row_num
  and s.paddock_row_id is null;

update public.pruning_row_segments
set row_label = row_number::text
where row_label is null;

-- Safety: if bad data produced duplicate quarters under the same row id,
-- keep the completed one (or the lowest id) so the unique index can build.
delete from public.pruning_row_segments s
where s.paddock_row_id is not null
  and exists (
    select 1 from public.pruning_row_segments k
    where k.pruning_season_id = s.pruning_season_id
      and k.paddock_row_id = s.paddock_row_id
      and k.segment_number = s.segment_number
      and k.id <> s.id
      and (
        (k.completed and not s.completed)
        or (k.completed = s.completed and k.id < s.id)
      )
  );

-- ---------------------------------------------------------------------------
-- 3. Identity constraints
-- ---------------------------------------------------------------------------
alter table public.pruning_row_segments
  drop constraint if exists pruning_row_segments_unique_quarter;

-- Configured rows: identity is the stable paddock row id.
create unique index if not exists pruning_row_segments_row_identity_unique
  on public.pruning_row_segments (pruning_season_id, paddock_row_id, segment_number)
  where paddock_row_id is not null;

-- Manual-fallback rows (block has no configured row records): number identity.
create unique index if not exists pruning_row_segments_fallback_unique
  on public.pruning_row_segments (pruning_season_id, row_number, segment_number)
  where paddock_row_id is null;

create index if not exists pruning_row_segments_row_idx
  on public.pruning_row_segments (paddock_row_id);

-- ---------------------------------------------------------------------------
-- 4. RPC: record_pruning_entry (same signature — segments jsonb gains
--    optional "row_id" and "label" per element: {row, segment, row_id, label})
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
  p_segments jsonb
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
    created_by, client_updated_at
  ) values (
    p_id, p_vineyard_id, p_season_id, p_paddock_id, p_entry_date, coalesce(p_worker, ''),
    p_labour_hours, p_start_time, p_finish_time, coalesce(p_method, 'spur'), coalesce(p_notes, ''),
    auth.uid(), p_client_updated_at
  )
  on conflict (id) do nothing;

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

revoke all on function public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb) from public;
grant execute on function public.record_pruning_entry(uuid, uuid, uuid, uuid, integer, date, text, numeric, timestamptz, timestamptz, text, text, integer, timestamptz, jsonb) to authenticated;

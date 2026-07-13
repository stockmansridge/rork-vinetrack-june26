-- 109: Pruning Tracker shared sync tables (Phase 2).
--
-- Three entities:
--   * pruning_seasons       — one row per block + season year (setup: due date, crew, working days).
--   * pruning_row_segments  — four fixed quarters per row; the single source of truth for
--                             completed work. UNIQUE(season,row,segment) makes completion
--                             idempotent and double-count-proof across devices.
--   * pruning_entries       — one row per "Complete Today" press (crew, hours, method, notes).
--
-- Clients read all three tables directly (RLS: vineyard members) but WRITE segments and
-- entries ONLY through the security-definer RPC `record_pruning_entry`, which attributes
-- each quarter to the first entry that completes it. Reversals happen ONLY through
-- `delete_pruning_entry` (explicit authorised action) — normal sync can never revert a
-- completed quarter.

-- ---------------------------------------------------------------------------
-- pruning_seasons
-- ---------------------------------------------------------------------------
create table if not exists public.pruning_seasons (
  id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  paddock_id uuid not null,
  season_year integer not null,
  start_date date,
  due_date date,
  pruning_method text not null default 'spur',
  assigned_crew text not null default '',
  -- ISO weekdays that count as working days (1 = Monday … 7 = Sunday).
  working_days integer[] not null default '{1,2,3,4,5}',
  -- Manual row count for blocks without mapped rows.
  manual_row_count integer,
  estimated_labour_hours numeric,
  notes text not null default '',
  status text not null default 'active' check (status in ('active','complete','archived')),
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  client_updated_at timestamptz,
  sync_version integer not null default 1
);

-- One active season per vineyard + block + year (separate pruning passes are a
-- later requirement; a soft-deleted season frees the slot).
create unique index if not exists pruning_seasons_active_unique
  on public.pruning_seasons (vineyard_id, paddock_id, season_year)
  where deleted_at is null;

create index if not exists pruning_seasons_vineyard_idx on public.pruning_seasons (vineyard_id);
create index if not exists pruning_seasons_updated_idx on public.pruning_seasons (updated_at);

drop trigger if exists pruning_seasons_set_updated_at on public.pruning_seasons;
create trigger pruning_seasons_set_updated_at
  before update on public.pruning_seasons
  for each row execute function public.set_updated_at();

alter table public.pruning_seasons enable row level security;

drop policy if exists "pruning_seasons_select_members" on public.pruning_seasons;
create policy "pruning_seasons_select_members" on public.pruning_seasons
  for select to authenticated
  using (public.is_vineyard_member(vineyard_id));

drop policy if exists "pruning_seasons_insert_members" on public.pruning_seasons;
create policy "pruning_seasons_insert_members" on public.pruning_seasons
  for insert to authenticated
  with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "pruning_seasons_update_members" on public.pruning_seasons;
create policy "pruning_seasons_update_members" on public.pruning_seasons
  for update to authenticated
  using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
  with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "pruning_seasons_no_client_hard_delete" on public.pruning_seasons;
create policy "pruning_seasons_no_client_hard_delete" on public.pruning_seasons
  for delete to authenticated using (false);

-- ---------------------------------------------------------------------------
-- pruning_entries (read-only to clients; written via record_pruning_entry RPC)
-- ---------------------------------------------------------------------------
create table if not exists public.pruning_entries (
  id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  pruning_season_id uuid not null references public.pruning_seasons(id) on delete cascade,
  paddock_id uuid not null,
  entry_date date not null,
  worker_or_crew text not null default '',
  labour_hours numeric,
  start_time timestamptz,
  finish_time timestamptz,
  pruning_method text not null default 'spur',
  notes text not null default '',
  -- Server-attributed values (set by record_pruning_entry after segment attribution).
  row_equivalents_completed numeric not null default 0,
  estimated_vines_completed integer not null default 0,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  client_updated_at timestamptz,
  sync_version integer not null default 1
);

create index if not exists pruning_entries_vineyard_idx on public.pruning_entries (vineyard_id);
create index if not exists pruning_entries_season_idx on public.pruning_entries (pruning_season_id);
create index if not exists pruning_entries_updated_idx on public.pruning_entries (updated_at);

drop trigger if exists pruning_entries_set_updated_at on public.pruning_entries;
create trigger pruning_entries_set_updated_at
  before update on public.pruning_entries
  for each row execute function public.set_updated_at();

alter table public.pruning_entries enable row level security;

drop policy if exists "pruning_entries_select_members" on public.pruning_entries;
create policy "pruning_entries_select_members" on public.pruning_entries
  for select to authenticated
  using (public.is_vineyard_member(vineyard_id));

-- All writes go through the RPCs below — no direct client insert/update/delete.
drop policy if exists "pruning_entries_no_client_insert" on public.pruning_entries;
create policy "pruning_entries_no_client_insert" on public.pruning_entries
  for insert to authenticated with check (false);

drop policy if exists "pruning_entries_no_client_update" on public.pruning_entries;
create policy "pruning_entries_no_client_update" on public.pruning_entries
  for update to authenticated using (false);

drop policy if exists "pruning_entries_no_client_delete" on public.pruning_entries;
create policy "pruning_entries_no_client_delete" on public.pruning_entries
  for delete to authenticated using (false);

-- ---------------------------------------------------------------------------
-- pruning_row_segments (read-only to clients; written via RPCs)
-- ---------------------------------------------------------------------------
create table if not exists public.pruning_row_segments (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  pruning_season_id uuid not null references public.pruning_seasons(id) on delete cascade,
  paddock_id uuid not null,
  row_number integer not null check (row_number >= 1),
  segment_number integer not null check (segment_number between 1 and 4),
  completed boolean not null default false,
  completed_at timestamptz,
  completed_by text,
  pruning_entry_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- The same quarter can never exist twice for a season.
do $$ begin
  alter table public.pruning_row_segments
    add constraint pruning_row_segments_unique_quarter
    unique (pruning_season_id, row_number, segment_number);
exception when duplicate_table then null; when duplicate_object then null; end $$;

create index if not exists pruning_row_segments_vineyard_idx on public.pruning_row_segments (vineyard_id);
create index if not exists pruning_row_segments_season_idx on public.pruning_row_segments (pruning_season_id);
create index if not exists pruning_row_segments_entry_idx on public.pruning_row_segments (pruning_entry_id);
create index if not exists pruning_row_segments_updated_idx on public.pruning_row_segments (updated_at);

drop trigger if exists pruning_row_segments_set_updated_at on public.pruning_row_segments;
create trigger pruning_row_segments_set_updated_at
  before update on public.pruning_row_segments
  for each row execute function public.set_updated_at();

alter table public.pruning_row_segments enable row level security;

drop policy if exists "pruning_row_segments_select_members" on public.pruning_row_segments;
create policy "pruning_row_segments_select_members" on public.pruning_row_segments
  for select to authenticated
  using (public.is_vineyard_member(vineyard_id));

drop policy if exists "pruning_row_segments_no_client_insert" on public.pruning_row_segments;
create policy "pruning_row_segments_no_client_insert" on public.pruning_row_segments
  for insert to authenticated with check (false);

drop policy if exists "pruning_row_segments_no_client_update" on public.pruning_row_segments;
create policy "pruning_row_segments_no_client_update" on public.pruning_row_segments
  for update to authenticated using (false);

drop policy if exists "pruning_row_segments_no_client_delete" on public.pruning_row_segments;
create policy "pruning_row_segments_no_client_delete" on public.pruning_row_segments
  for delete to authenticated using (false);

-- ---------------------------------------------------------------------------
-- RPC: record_pruning_entry
--
-- Atomic + idempotent "Complete Today". Safe to replay from the offline queue:
--   * the entry insert is `on conflict (id) do nothing`,
--   * each quarter is only claimed when not already completed — a quarter
--     completed first by another device stays with that device's entry,
--   * the entry's row-equivalents / vine counts are recomputed from the
--     quarters actually attributed to it, so nothing is ever double-counted.
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
begin
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;

  -- Ensure the season exists (a device may record work before the season
  -- setup row has synced). Season ids are deterministic per
  -- vineyard/paddock/year, so both devices converge on the same row.
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
    insert into public.pruning_row_segments (
      vineyard_id, pruning_season_id, paddock_id, row_number, segment_number,
      completed, completed_at, completed_by, pruning_entry_id
    ) values (
      p_vineyard_id, p_season_id, p_paddock_id,
      (v_seg->>'row')::integer, (v_seg->>'segment')::integer,
      true, now(), coalesce(p_worker, ''), p_id
    )
    on conflict (pruning_season_id, row_number, segment_number) do update
      set completed = true,
          completed_at = coalesce(public.pruning_row_segments.completed_at, excluded.completed_at),
          completed_by = excluded.completed_by,
          pruning_entry_id = excluded.pruning_entry_id,
          updated_at = now()
      where public.pruning_row_segments.completed = false;
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

-- ---------------------------------------------------------------------------
-- RPC: delete_pruning_entry — the ONLY way completed quarters revert.
-- ---------------------------------------------------------------------------
create or replace function public.delete_pruning_entry(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_vineyard uuid;
begin
  select vineyard_id into v_vineyard from public.pruning_entries where id = p_id;
  if v_vineyard is null then
    return;
  end if;
  if not public.has_vineyard_role(v_vineyard, array['owner','manager','supervisor','operator']) then
    raise exception 'not allowed';
  end if;

  update public.pruning_entries
  set deleted_at = now(), updated_by = auth.uid(), updated_at = now()
  where id = p_id and deleted_at is null;

  update public.pruning_row_segments
  set completed = false, completed_at = null, completed_by = null,
      pruning_entry_id = null, updated_at = now()
  where pruning_entry_id = p_id;
end;
$$;

revoke all on function public.delete_pruning_entry(uuid) from public;
grant execute on function public.delete_pruning_entry(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- RPC: soft_delete_pruning_season
-- ---------------------------------------------------------------------------
create or replace function public.soft_delete_pruning_season(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_vineyard uuid;
begin
  select vineyard_id into v_vineyard from public.pruning_seasons where id = p_id;
  if v_vineyard is null then
    return;
  end if;
  if not public.has_vineyard_role(v_vineyard, array['owner','manager','supervisor']) then
    raise exception 'not allowed';
  end if;

  update public.pruning_seasons
  set deleted_at = now(), updated_by = auth.uid(), updated_at = now()
  where id = p_id and deleted_at is null;
end;
$$;

revoke all on function public.soft_delete_pruning_season(uuid) from public;
grant execute on function public.soft_delete_pruning_season(uuid) to authenticated;

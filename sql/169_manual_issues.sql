-- 169: Manual Issues.
--
-- A Manual Issue is a lightweight, manually created issue / action / planning
-- marker for a point, a row selection, or a whole block. It rides the shared
-- `pins` architecture (mode = 'ManualIssue') so every existing map surface,
-- delta sync path, photo bucket, and soft-delete rule applies unchanged —
-- deliberately NOT a parallel map-marker system.
--
-- A manual issue never creates a repair, growth observation, Work Task,
-- labour, cost, machinery or pruning record. `linked_work_task_id` exists for
-- a future explicit conversion only.
--
-- Location contract (matches the established pin contract from sql/041):
--   * point : latitude/longitude = original tapped coordinates;
--             snapped_latitude/snapped_longitude = canonical snapped point;
--             driving_row_number keeps the exact path row (e.g. 19.5),
--             pin_row_number the attached vine row, pin_side Left/Right,
--             along_row_distance_m the distance along the row.
--   * row   : structured selection in pin_row_segments (row + quarter 1..4,
--             the same canonical shape as pruning_row_segments);
--             latitude/longitude = representative marker (midpoint/centroid
--             of the selected segments). The segments stay authoritative.
--   * block : paddock_id required; latitude/longitude = block centroid.

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------

alter table public.pins add column if not exists location_scope text null;
alter table public.pins add column if not exists assigned_user_id uuid null references auth.users(id);
alter table public.pins add column if not exists due_date date null;
-- Future Work Task conversion target. Plain uuid (no FK) so an offline
-- replay can never be rejected by a not-yet-synced task row.
alter table public.pins add column if not exists linked_work_task_id uuid null;

create index if not exists idx_pins_manual_issue
  on public.pins (vineyard_id, status)
  where mode = 'ManualIssue' and deleted_at is null;

create index if not exists idx_pins_manual_issue_assignee
  on public.pins (assigned_user_id)
  where mode = 'ManualIssue' and assigned_user_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Constraints (scoped to mode = 'ManualIssue' so legacy pins are untouched)
-- ---------------------------------------------------------------------------

alter table public.pins drop constraint if exists pins_manual_issue_title;
alter table public.pins add constraint pins_manual_issue_title check (
  mode is distinct from 'ManualIssue'
  or (title is not null and btrim(title) <> '')
);

alter table public.pins drop constraint if exists pins_manual_issue_category;
alter table public.pins add constraint pins_manual_issue_category check (
  mode is distinct from 'ManualIssue'
  or category in ('general','action_required','inspection','planning','infrastructure','vine_or_row','safety','other')
);

alter table public.pins drop constraint if exists pins_manual_issue_priority;
alter table public.pins add constraint pins_manual_issue_priority check (
  mode is distinct from 'ManualIssue'
  or priority in ('low','normal','high','urgent')
);

alter table public.pins drop constraint if exists pins_manual_issue_status;
alter table public.pins add constraint pins_manual_issue_status check (
  mode is distinct from 'ManualIssue'
  or status in ('open','in_progress','completed','cancelled')
);

alter table public.pins drop constraint if exists pins_manual_issue_scope;
alter table public.pins add constraint pins_manual_issue_scope check (
  mode is distinct from 'ManualIssue'
  or location_scope in ('point','row','block')
);

-- Every scope needs a renderable marker coordinate; block scope needs a block.
alter table public.pins drop constraint if exists pins_manual_issue_marker;
alter table public.pins add constraint pins_manual_issue_marker check (
  mode is distinct from 'ManualIssue'
  or (latitude is not null and longitude is not null)
);

alter table public.pins drop constraint if exists pins_manual_issue_block;
alter table public.pins add constraint pins_manual_issue_block check (
  mode is distinct from 'ManualIssue'
  or location_scope is distinct from 'block'
  or paddock_id is not null
);

-- Completion metadata must agree with status: completed_at present exactly
-- when the status is completed.
alter table public.pins drop constraint if exists pins_manual_issue_completion;
alter table public.pins add constraint pins_manual_issue_completion check (
  mode is distinct from 'ManualIssue'
  or ((status = 'completed') = (completed_at is not null))
);

-- ---------------------------------------------------------------------------
-- 3. Row segments (canonical structured row selection)
-- ---------------------------------------------------------------------------

-- Same canonical shape as pruning_row_segments: block row number + quarter
-- (segment 1..4). A whole row is all four quarters. Written only through the
-- manual-issue RPCs; readable by vineyard members.
create table if not exists public.pin_row_segments (
  pin_id uuid not null references public.pins(id) on delete cascade,
  row_number integer not null check (row_number >= 1),
  segment_number integer not null check (segment_number between 1 and 4),
  primary key (pin_id, row_number, segment_number)
);

create index if not exists idx_pin_row_segments_pin on public.pin_row_segments (pin_id);

alter table public.pin_row_segments enable row level security;

drop policy if exists "pin_row_segments_select_members" on public.pin_row_segments;
create policy "pin_row_segments_select_members"
on public.pin_row_segments for select
to authenticated
using (
  exists (
    select 1 from public.pins p
    where p.id = pin_row_segments.pin_id
      and public.is_vineyard_member(p.vineyard_id)
  )
);
-- No insert/update/delete policies: clients write segments only through the
-- SECURITY DEFINER manual-issue RPCs, atomically with the parent pin.

-- ---------------------------------------------------------------------------
-- 4. Canonical JSON
-- ---------------------------------------------------------------------------

create or replace function public.manual_issue_json(p_pin public.pins)
returns jsonb
language sql
stable
set search_path = public
as $function$
  select jsonb_build_object(
    'id', p_pin.id,
    'vineyard_id', p_pin.vineyard_id,
    'paddock_id', p_pin.paddock_id,
    'title', p_pin.title,
    'description', p_pin.notes,
    'category', p_pin.category,
    'priority', p_pin.priority,
    'status', p_pin.status,
    'location_scope', p_pin.location_scope,
    'latitude', p_pin.latitude,
    'longitude', p_pin.longitude,
    'snapped_latitude', p_pin.snapped_latitude,
    'snapped_longitude', p_pin.snapped_longitude,
    'driving_row_number', p_pin.driving_row_number,
    'pin_row_number', p_pin.pin_row_number,
    'pin_side', p_pin.pin_side,
    'along_row_distance_m', p_pin.along_row_distance_m,
    'snapped_to_row', coalesce(p_pin.snapped_to_row, false),
    'assigned_user_id', p_pin.assigned_user_id,
    'due_date', p_pin.due_date,
    'linked_work_task_id', p_pin.linked_work_task_id,
    'photo_path', p_pin.photo_path,
    'created_by', p_pin.created_by,
    'created_at', p_pin.created_at,
    'updated_at', p_pin.updated_at,
    'client_updated_at', p_pin.client_updated_at,
    'deleted_at', p_pin.deleted_at,
    'completed_at', p_pin.completed_at,
    'completed_by_user_id', p_pin.completed_by_user_id,
    'completed_by', p_pin.completed_by,
    'segments', case
      when p_pin.location_scope = 'row' then coalesce(
        (
          select jsonb_agg(jsonb_build_object('row', s.row_number, 'segment', s.segment_number)
                           order by s.row_number, s.segment_number)
          from public.pin_row_segments s
          where s.pin_id = p_pin.id
        ),
        '[]'::jsonb
      )
      else null
    end
  );
$function$;

-- ---------------------------------------------------------------------------
-- 5. Internal validation helpers
-- ---------------------------------------------------------------------------

-- Parses, validates and de-duplicates a segments payload of
-- [{"row": int >= 1, "segment": int 1..4}]. Raises on malformed input.
create or replace function public._manual_issue_parse_segments(p_segments jsonb)
returns table (row_number integer, segment_number integer)
language plpgsql
immutable
set search_path = public
as $function$
declare
  v_item jsonb;
  v_row integer;
  v_segment integer;
begin
  if p_segments is null or jsonb_typeof(p_segments) <> 'array' then
    raise exception 'SEGMENTS_INVALID: segments must be a JSON array of {row, segment}';
  end if;
  for v_item in select jsonb_array_elements(p_segments) loop
    if jsonb_typeof(v_item->'row') <> 'number' or jsonb_typeof(v_item->'segment') <> 'number' then
      raise exception 'SEGMENTS_INVALID: each segment needs numeric row and segment';
    end if;
    v_row := (v_item->>'row')::integer;
    v_segment := (v_item->>'segment')::integer;
    if v_row < 1 then
      raise exception 'SEGMENTS_INVALID: row must be >= 1';
    end if;
    if v_segment < 1 or v_segment > 4 then
      raise exception 'SEGMENTS_INVALID: segment must be between 1 and 4';
    end if;
    row_number := v_row;
    segment_number := v_segment;
    return next;
  end loop;
  return;
end;
$function$;

-- Shared field validation for create/update. Raises stable, prefix-coded
-- errors the portal can map to user-safe messages.
create or replace function public._manual_issue_validate(
  p_vineyard_id uuid,
  p_title text,
  p_category text,
  p_priority text,
  p_location_scope text,
  p_paddock_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_assigned_user_id uuid,
  p_segments jsonb
)
returns void
language plpgsql
stable
set search_path = public
as $function$
begin
  if p_title is null or btrim(p_title) = '' then
    raise exception 'TITLE_REQUIRED: a manual issue needs a title';
  end if;
  if p_category not in ('general','action_required','inspection','planning','infrastructure','vine_or_row','safety','other') then
    raise exception 'INVALID_CATEGORY: %', p_category;
  end if;
  if p_priority not in ('low','normal','high','urgent') then
    raise exception 'INVALID_PRIORITY: %', p_priority;
  end if;
  if p_location_scope not in ('point','row','block') then
    raise exception 'INVALID_SCOPE: %', p_location_scope;
  end if;
  if p_latitude is null or p_longitude is null then
    raise exception 'LOCATION_REQUIRED: a marker coordinate is required for every scope';
  end if;
  if p_location_scope = 'block' and p_paddock_id is null then
    raise exception 'BLOCK_REQUIRED: a block issue needs a block';
  end if;
  if p_location_scope = 'row' then
    if p_paddock_id is null then
      raise exception 'BLOCK_REQUIRED: a row issue needs the block that owns the rows';
    end if;
    if (select count(*) from public._manual_issue_parse_segments(p_segments)) = 0 then
      raise exception 'SEGMENTS_REQUIRED: a row issue needs at least one row segment';
    end if;
  end if;
  if p_assigned_user_id is not null and not exists (
    select 1 from public.vineyard_members m
    where m.vineyard_id = p_vineyard_id and m.user_id = p_assigned_user_id
  ) then
    raise exception 'ASSIGNEE_NOT_MEMBER: the assigned user is not a member of this vineyard';
  end if;
end;
$function$;

-- True when the current user may edit / change status on the issue:
-- creator, assigned user, or owner/manager/supervisor.
create or replace function public._manual_issue_can_edit(p_pin public.pins)
returns boolean
language sql
stable
set search_path = public
as $function$
  select auth.uid() is not null and (
    p_pin.created_by = auth.uid()
    or p_pin.assigned_user_id = auth.uid()
    or public.has_vineyard_role(p_pin.vineyard_id, array['owner','manager','supervisor'])
  );
$function$;

-- Best display name for a user in a vineyard (member display name, then
-- auth profile name, then email) — used for completed_by attribution.
create or replace function public._manual_issue_user_name(p_vineyard_id uuid, p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $function$
  select coalesce(
    (select nullif(btrim(m.display_name), '') from public.vineyard_members m
     where m.vineyard_id = p_vineyard_id and m.user_id = p_user_id),
    (select nullif(btrim(u.raw_user_meta_data->>'full_name'), '') from auth.users u where u.id = p_user_id),
    (select u.email from auth.users u where u.id = p_user_id)
  );
$function$;

-- ---------------------------------------------------------------------------
-- 6. RPCs
-- ---------------------------------------------------------------------------

-- Idempotent create keyed by the client-generated id: replaying the same
-- create returns the existing canonical issue instead of duplicating.
create or replace function public.create_manual_issue(
  p_id uuid,
  p_vineyard_id uuid,
  p_title text,
  p_location_scope text,
  p_paddock_id uuid default null,
  p_description text default null,
  p_category text default 'general',
  p_priority text default 'normal',
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_snapped_latitude double precision default null,
  p_snapped_longitude double precision default null,
  p_driving_row_number numeric default null,
  p_pin_row_number numeric default null,
  p_pin_side text default null,
  p_along_row_distance_m numeric default null,
  p_snapped_to_row boolean default false,
  p_assigned_user_id uuid default null,
  p_due_date date default null,
  p_client_updated_at timestamptz default now(),
  p_segments jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_existing public.pins;
  v_pin public.pins;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: authentication required';
  end if;
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'PERMISSION_DENIED: you cannot create manual issues in this vineyard';
  end if;

  select * into v_existing from public.pins where id = p_id;
  if found then
    if v_existing.mode is distinct from 'ManualIssue' then
      raise exception 'NOT_A_MANUAL_ISSUE: id already used by another pin type';
    end if;
    -- Idempotent replay of an offline create — the row is already there.
    return public.manual_issue_json(v_existing);
  end if;

  perform public._manual_issue_validate(
    p_vineyard_id, p_title, p_category, p_priority, p_location_scope,
    p_paddock_id, p_latitude, p_longitude, p_assigned_user_id, p_segments
  );

  if p_pin_side is not null and p_pin_side not in ('Left','Right') then
    raise exception 'INVALID_SIDE: %', p_pin_side;
  end if;

  insert into public.pins (
    id, vineyard_id, paddock_id, mode, title, notes, category, priority, status,
    location_scope, latitude, longitude,
    snapped_latitude, snapped_longitude, driving_row_number, pin_row_number,
    pin_side, along_row_distance_m, snapped_to_row,
    assigned_user_id, due_date,
    -- Stored identity columns so every legacy map/list surface renders the
    -- amber manual-issue appearance without client changes.
    button_name, button_color,
    is_completed, created_by, updated_by, client_updated_at
  ) values (
    p_id, p_vineyard_id, p_paddock_id, 'ManualIssue', btrim(p_title),
    nullif(btrim(coalesce(p_description, '')), ''), p_category, p_priority, 'open',
    p_location_scope, p_latitude, p_longitude,
    case when p_location_scope = 'point' then p_snapped_latitude else null end,
    case when p_location_scope = 'point' then p_snapped_longitude else null end,
    case when p_location_scope = 'point' then p_driving_row_number else null end,
    case when p_location_scope = 'point' then p_pin_row_number else null end,
    case when p_location_scope = 'point' then p_pin_side else null end,
    case when p_location_scope = 'point' then p_along_row_distance_m else null end,
    case when p_location_scope = 'point' then coalesce(p_snapped_to_row, false) else false end,
    p_assigned_user_id, p_due_date,
    btrim(p_title), 'orange',
    false, auth.uid(), auth.uid(), coalesce(p_client_updated_at, now())
  )
  returning * into v_pin;

  if p_location_scope = 'row' then
    insert into public.pin_row_segments (pin_id, row_number, segment_number)
    select distinct p_id, s.row_number, s.segment_number
    from public._manual_issue_parse_segments(p_segments) s;
  end if;

  return public.manual_issue_json(v_pin);
end;
$function$;

-- Full-field update with last-write-wins conflict handling: a stale
-- client_updated_at is ignored and the newer canonical issue returned, so an
-- offline edit replay can never clobber a newer edit. Changing the location
-- scope atomically replaces the obsolete location data (segments are dropped
-- unless the new scope is row; point snapping is cleared unless point).
create or replace function public.update_manual_issue(
  p_id uuid,
  p_title text,
  p_location_scope text,
  p_paddock_id uuid default null,
  p_description text default null,
  p_category text default 'general',
  p_priority text default 'normal',
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_snapped_latitude double precision default null,
  p_snapped_longitude double precision default null,
  p_driving_row_number numeric default null,
  p_pin_row_number numeric default null,
  p_pin_side text default null,
  p_along_row_distance_m numeric default null,
  p_snapped_to_row boolean default false,
  p_assigned_user_id uuid default null,
  p_due_date date default null,
  p_client_updated_at timestamptz default now(),
  p_segments jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_pin public.pins;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: authentication required';
  end if;

  select * into v_pin from public.pins where id = p_id and deleted_at is null;
  if not found then
    raise exception 'ISSUE_NOT_FOUND: %', p_id;
  end if;
  if v_pin.mode is distinct from 'ManualIssue' then
    raise exception 'NOT_A_MANUAL_ISSUE: %', p_id;
  end if;
  if not public._manual_issue_can_edit(v_pin) then
    raise exception 'PERMISSION_DENIED: only the creator, assignee, or a manager can edit this issue';
  end if;

  -- Last-write-wins: ignore a write older than what the server already has.
  if v_pin.client_updated_at is not null
     and p_client_updated_at is not null
     and p_client_updated_at < v_pin.client_updated_at then
    return public.manual_issue_json(v_pin);
  end if;

  perform public._manual_issue_validate(
    v_pin.vineyard_id, p_title, p_category, p_priority, p_location_scope,
    p_paddock_id, p_latitude, p_longitude, p_assigned_user_id, p_segments
  );
  if p_pin_side is not null and p_pin_side not in ('Left','Right') then
    raise exception 'INVALID_SIDE: %', p_pin_side;
  end if;

  update public.pins set
    title = btrim(p_title),
    button_name = btrim(p_title),
    notes = nullif(btrim(coalesce(p_description, '')), ''),
    category = p_category,
    priority = p_priority,
    location_scope = p_location_scope,
    paddock_id = p_paddock_id,
    latitude = p_latitude,
    longitude = p_longitude,
    snapped_latitude = case when p_location_scope = 'point' then p_snapped_latitude else null end,
    snapped_longitude = case when p_location_scope = 'point' then p_snapped_longitude else null end,
    driving_row_number = case when p_location_scope = 'point' then p_driving_row_number else null end,
    pin_row_number = case when p_location_scope = 'point' then p_pin_row_number else null end,
    pin_side = case when p_location_scope = 'point' then p_pin_side else null end,
    along_row_distance_m = case when p_location_scope = 'point' then p_along_row_distance_m else null end,
    snapped_to_row = case when p_location_scope = 'point' then coalesce(p_snapped_to_row, false) else false end,
    assigned_user_id = p_assigned_user_id,
    due_date = p_due_date,
    updated_by = auth.uid(),
    client_updated_at = coalesce(p_client_updated_at, now())
  where id = p_id
  returning * into v_pin;

  -- Replace the structured selection atomically. Obsolete segments from a
  -- previous row scope are removed even when the new scope isn't row.
  delete from public.pin_row_segments where pin_id = p_id;
  if p_location_scope = 'row' then
    insert into public.pin_row_segments (pin_id, row_number, segment_number)
    select distinct p_id, s.row_number, s.segment_number
    from public._manual_issue_parse_segments(p_segments) s;
  end if;

  return public.manual_issue_json(v_pin);
end;
$function$;

create or replace function public.get_manual_issue(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_pin public.pins;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: authentication required';
  end if;
  select * into v_pin from public.pins where id = p_id and mode = 'ManualIssue';
  if not found then
    raise exception 'ISSUE_NOT_FOUND: %', p_id;
  end if;
  if not public.is_vineyard_member(v_pin.vineyard_id) then
    raise exception 'PERMISSION_DENIED: not a member of this vineyard';
  end if;
  return public.manual_issue_json(v_pin);
end;
$function$;

-- Active issues by default (open + in_progress). Pass p_statuses to include
-- completed/cancelled; p_include_deleted for audit views.
create or replace function public.list_manual_issues(
  p_vineyard_id uuid,
  p_statuses text[] default null,
  p_paddock_id uuid default null,
  p_include_deleted boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: authentication required';
  end if;
  if not public.is_vineyard_member(p_vineyard_id) then
    raise exception 'PERMISSION_DENIED: not a member of this vineyard';
  end if;
  return coalesce(
    (
      select jsonb_agg(public.manual_issue_json(p) order by p.created_at desc)
      from public.pins p
      where p.vineyard_id = p_vineyard_id
        and p.mode = 'ManualIssue'
        and (p_include_deleted or p.deleted_at is null)
        and (p_paddock_id is null or p.paddock_id = p_paddock_id)
        and (
          case
            when p_statuses is not null then p.status = any (p_statuses)
            else p.status in ('open','in_progress')
          end
        )
    ),
    '[]'::jsonb
  );
end;
$function$;

-- Server-authoritative status change. Completing stamps completed_at /
-- completed_by; reopening clears them. is_completed mirrors completed status
-- so legacy map muting keeps working.
create or replace function public.set_manual_issue_status(
  p_id uuid,
  p_status text,
  p_client_updated_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_pin public.pins;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: authentication required';
  end if;
  if p_status not in ('open','in_progress','completed','cancelled') then
    raise exception 'INVALID_STATUS: %', p_status;
  end if;

  select * into v_pin from public.pins where id = p_id and deleted_at is null;
  if not found then
    raise exception 'ISSUE_NOT_FOUND: %', p_id;
  end if;
  if v_pin.mode is distinct from 'ManualIssue' then
    raise exception 'NOT_A_MANUAL_ISSUE: %', p_id;
  end if;
  if not public._manual_issue_can_edit(v_pin) then
    raise exception 'PERMISSION_DENIED: only the creator, assignee, or a manager can change status';
  end if;

  update public.pins set
    status = p_status,
    is_completed = (p_status = 'completed'),
    completed_at = case when p_status = 'completed' then now() else null end,
    completed_by_user_id = case when p_status = 'completed' then auth.uid() else null end,
    completed_by = case
      when p_status = 'completed' then public._manual_issue_user_name(v_pin.vineyard_id, auth.uid())
      else null
    end,
    updated_by = auth.uid(),
    client_updated_at = coalesce(p_client_updated_at, now())
  where id = p_id
  returning * into v_pin;

  return public.manual_issue_json(v_pin);
end;
$function$;

-- 'cancel' keeps the issue in history with status = cancelled (creator,
-- assignee, or owner/manager/supervisor). 'delete' soft-deletes, matching
-- the existing soft_delete_pin permission (owner/manager/supervisor only).
create or replace function public.delete_or_cancel_manual_issue(
  p_id uuid,
  p_action text default 'cancel'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_pin public.pins;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: authentication required';
  end if;
  if p_action not in ('cancel','delete') then
    raise exception 'INVALID_ACTION: %', p_action;
  end if;

  select * into v_pin from public.pins where id = p_id and deleted_at is null;
  if not found then
    raise exception 'ISSUE_NOT_FOUND: %', p_id;
  end if;
  if v_pin.mode is distinct from 'ManualIssue' then
    raise exception 'NOT_A_MANUAL_ISSUE: %', p_id;
  end if;

  if p_action = 'cancel' then
    if not public._manual_issue_can_edit(v_pin) then
      raise exception 'PERMISSION_DENIED: only the creator, assignee, or a manager can cancel this issue';
    end if;
    return public.set_manual_issue_status(p_id, 'cancelled');
  end if;

  -- delete: aligned with soft_delete_pin — owner/manager/supervisor.
  if not public.has_vineyard_role(v_pin.vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'PERMISSION_DENIED: only a manager can delete this issue';
  end if;
  update public.pins set
    deleted_at = now(),
    updated_by = auth.uid()
  where id = p_id
  returning * into v_pin;
  return public.manual_issue_json(v_pin);
end;
$function$;

revoke all on function public.create_manual_issue(uuid, uuid, text, text, uuid, text, text, text, double precision, double precision, double precision, double precision, numeric, numeric, text, numeric, boolean, uuid, date, timestamptz, jsonb) from public;
grant execute on function public.create_manual_issue(uuid, uuid, text, text, uuid, text, text, text, double precision, double precision, double precision, double precision, numeric, numeric, text, numeric, boolean, uuid, date, timestamptz, jsonb) to authenticated;

revoke all on function public.update_manual_issue(uuid, text, text, uuid, text, text, text, double precision, double precision, double precision, double precision, numeric, numeric, text, numeric, boolean, uuid, date, timestamptz, jsonb) from public;
grant execute on function public.update_manual_issue(uuid, text, text, uuid, text, text, text, double precision, double precision, double precision, double precision, numeric, numeric, text, numeric, boolean, uuid, date, timestamptz, jsonb) to authenticated;

revoke all on function public.get_manual_issue(uuid) from public;
grant execute on function public.get_manual_issue(uuid) to authenticated;

revoke all on function public.list_manual_issues(uuid, text[], uuid, boolean) from public;
grant execute on function public.list_manual_issues(uuid, text[], uuid, boolean) to authenticated;

revoke all on function public.set_manual_issue_status(uuid, text, timestamptz) from public;
grant execute on function public.set_manual_issue_status(uuid, text, timestamptz) to authenticated;

revoke all on function public.delete_or_cancel_manual_issue(uuid, text) from public;
grant execute on function public.delete_or_cancel_manual_issue(uuid, text) to authenticated;

revoke all on function public._manual_issue_user_name(uuid, uuid) from public;

-- ---------------------------------------------------------------------------
-- 7. Export view (CSV / Excel / portal reporting)
-- ---------------------------------------------------------------------------

-- Machine-readable coordinate and id columns stay separate; the row summary
-- is a convenience label — the structured segments remain authoritative.
drop view if exists public.manual_issues_export;
create view public.manual_issues_export
with (security_invoker = true)
as
select
  p.id as issue_id,
  p.vineyard_id,
  v.name as vineyard_name,
  p.paddock_id,
  pk.name as block_name,
  p.title,
  p.notes as description,
  p.category,
  p.priority,
  p.status,
  case when p.deleted_at is not null then 'deleted' else p.status end as effective_status,
  p.location_scope,
  p.latitude,
  p.longitude,
  p.snapped_latitude,
  p.snapped_longitude,
  p.driving_row_number,
  p.pin_row_number,
  p.pin_side,
  p.along_row_distance_m,
  (
    select string_agg(distinct s.row_number::text, ', ' order by s.row_number::text)
    from public.pin_row_segments s
    where s.pin_id = p.id
  ) as row_summary,
  p.assigned_user_id,
  p.due_date,
  p.created_by,
  p.created_at,
  p.completed_at,
  p.completed_by,
  p.linked_work_task_id,
  p.deleted_at
from public.pins p
left join public.vineyards v on v.id = p.vineyard_id
left join public.paddocks pk on pk.id = p.paddock_id
where p.mode = 'ManualIssue';

grant select on public.manual_issues_export to authenticated;

-- 170: Unified pin composer — vineyard-shared custom pin types + simplified
-- custom create + generic row-segment persistence.
--
-- Revises the sql/169 Manual Issue feature into an extension of the existing
-- pin workflow. The unified "Add Pin / Action" composer on mobile/portal is a
-- location-first flow (point / row / block) with three tabs:
--   * Repair  -> the EXISTING direct pins insert (mode = 'Repairs') stays
--                authoritative — never routed through a Manual Issue RPC.
--   * Growth  -> the EXISTING direct pins insert (mode = 'Growth') stays
--                authoritative.
--   * Custom  -> the simplified `create_custom_pin` RPC below (the only
--                remaining creation use of mode = 'ManualIssue'). Category /
--                priority / status stay as safe backend defaults
--                (general / normal / open) and are never asked for in the UI.
--
-- Side selection (Left/Right) is not part of this workflow: `pin_side` is
-- stored null for composer-created pins. Existing sql/169 records are
-- untouched and keep decoding through the unchanged 169 RPCs.

-- ---------------------------------------------------------------------------
-- 1. Vineyard-shared custom pin type catalogue
-- ---------------------------------------------------------------------------

-- Shared across every authorised user of the vineyard (iOS / Android /
-- portal). Never device- or user-specific. Naming mirrors the existing
-- vineyard-scoped catalogues (vineyard_button_configs).
create table if not exists public.vineyard_custom_pin_types (
  id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  name text not null check (btrim(name) <> ''),
  color text null,
  icon text null,
  is_active boolean not null default true,
  created_by uuid null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Duplicate ACTIVE names are prevented per vineyard using trimmed,
-- case-insensitive comparison. Inactive items keep their name so historical
-- pins never lose meaning.
create unique index if not exists uq_vineyard_custom_pin_type_active_name
  on public.vineyard_custom_pin_types (vineyard_id, lower(btrim(name)))
  where is_active;

create index if not exists idx_vineyard_custom_pin_types_vineyard
  on public.vineyard_custom_pin_types (vineyard_id) where is_active;

alter table public.vineyard_custom_pin_types enable row level security;

drop policy if exists "custom_pin_types_select_members" on public.vineyard_custom_pin_types;
create policy "custom_pin_types_select_members"
on public.vineyard_custom_pin_types for select
to authenticated
using (public.is_vineyard_member(vineyard_id));
-- No insert/update/delete policies: writes go through the SECURITY DEFINER
-- RPCs below so the database enforces roles and duplicate rules.

-- Structural reference from a Custom pin to its vineyard-shared type. Plain
-- uuid (no FK) so an offline pin replay can never be rejected by a
-- not-yet-synced catalogue row; the type syncs before or atomically with the
-- pin in the normal flow.
alter table public.pins add column if not exists custom_type_id uuid null;

create index if not exists idx_pins_custom_type
  on public.pins (custom_type_id) where custom_type_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Catalogue JSON + RPCs
-- ---------------------------------------------------------------------------

create or replace function public.custom_pin_type_json(t public.vineyard_custom_pin_types)
returns jsonb
language sql
stable
set search_path = public
as $function$
  select jsonb_build_object(
    'id', t.id,
    'vineyard_id', t.vineyard_id,
    'name', t.name,
    'color', t.color,
    'icon', t.icon,
    'is_active', t.is_active,
    'created_by', t.created_by,
    'created_at', t.created_at,
    'updated_at', t.updated_at
  );
$function$;

-- Idempotent create keyed by the client-generated id (offline-safe replay).
-- A trimmed, case-insensitive duplicate of an ACTIVE name returns the
-- existing item instead of erroring, so two users adding "Broken Wire"
-- converge on one shared entry.
create or replace function public.create_vineyard_custom_pin_type(
  p_id uuid,
  p_vineyard_id uuid,
  p_name text,
  p_color text default null,
  p_icon text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_existing public.vineyard_custom_pin_types;
  v_row public.vineyard_custom_pin_types;
  v_name text := btrim(coalesce(p_name, ''));
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: authentication required';
  end if;
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'PERMISSION_DENIED: you cannot add custom pin types in this vineyard';
  end if;
  if v_name = '' then
    raise exception 'NAME_REQUIRED: a custom item needs a name';
  end if;

  -- Idempotent replay by client id.
  select * into v_existing from public.vineyard_custom_pin_types where id = p_id;
  if found then
    return public.custom_pin_type_json(v_existing);
  end if;

  -- Trimmed, case-insensitive duplicate of an active name -> converge.
  select * into v_existing
  from public.vineyard_custom_pin_types
  where vineyard_id = p_vineyard_id
    and is_active
    and lower(btrim(name)) = lower(v_name)
  limit 1;
  if found then
    return public.custom_pin_type_json(v_existing);
  end if;

  insert into public.vineyard_custom_pin_types (id, vineyard_id, name, color, icon, created_by)
  values (p_id, p_vineyard_id, v_name, nullif(btrim(coalesce(p_color, '')), ''), nullif(btrim(coalesce(p_icon, '')), ''), auth.uid())
  returning * into v_row;

  -- Safe exact-match compatibility for existing sql/169 records: link
  -- historical Manual Issue pins whose free-form title exactly matches the
  -- new type name (trimmed, case-insensitive). Uncertain matches are never
  -- rewritten; titles, locations and everything else stay untouched.
  update public.pins
  set custom_type_id = v_row.id
  where vineyard_id = p_vineyard_id
    and mode = 'ManualIssue'
    and custom_type_id is null
    and lower(btrim(coalesce(title, ''))) = lower(v_name);

  return public.custom_pin_type_json(v_row);
end;
$function$;

-- Active items by default (what the composer offers); pass
-- p_include_inactive for admin/audit views.
create or replace function public.list_vineyard_custom_pin_types(
  p_vineyard_id uuid,
  p_include_inactive boolean default false
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
      select jsonb_agg(public.custom_pin_type_json(t) order by lower(t.name))
      from public.vineyard_custom_pin_types t
      where t.vineyard_id = p_vineyard_id
        and (p_include_inactive or t.is_active)
    ),
    '[]'::jsonb
  );
end;
$function$;

-- Deactivating hides an item from new selection; historical pins keep their
-- custom_type_id and title so their meaning never changes.
create or replace function public.set_vineyard_custom_pin_type_active(
  p_id uuid,
  p_is_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_row public.vineyard_custom_pin_types;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: authentication required';
  end if;
  select * into v_row from public.vineyard_custom_pin_types where id = p_id;
  if not found then
    raise exception 'TYPE_NOT_FOUND: %', p_id;
  end if;
  if not public.has_vineyard_role(v_row.vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'PERMISSION_DENIED: only a manager can change custom pin types';
  end if;

  update public.vineyard_custom_pin_types
  set is_active = p_is_active, updated_at = now()
  where id = p_id
  returning * into v_row;
  return public.custom_pin_type_json(v_row);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Simplified custom pin create (the only creation path for ManualIssue)
-- ---------------------------------------------------------------------------

-- Custom tab save. Deliberately narrower than create_manual_issue: no
-- category / priority / assignee / due-date / side parameters — safe backend
-- defaults (general / normal / open, pin_side null) apply and the creation UI
-- never shows those fields. Idempotent by the client-generated id.
-- The 169 create_manual_issue RPC remains untouched for compatibility.
create or replace function public.create_custom_pin(
  p_id uuid,
  p_vineyard_id uuid,
  p_title text,
  p_location_scope text,
  p_custom_type_id uuid default null,
  p_paddock_id uuid default null,
  p_notes text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_snapped_latitude double precision default null,
  p_snapped_longitude double precision default null,
  p_driving_row_number numeric default null,
  p_pin_row_number numeric default null,
  p_along_row_distance_m numeric default null,
  p_snapped_to_row boolean default false,
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
  v_type public.vineyard_custom_pin_types;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED: authentication required';
  end if;
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'PERMISSION_DENIED: you cannot create pins in this vineyard';
  end if;

  select * into v_existing from public.pins where id = p_id;
  if found then
    if v_existing.mode is distinct from 'ManualIssue' then
      raise exception 'NOT_A_CUSTOM_PIN: id already used by another pin type';
    end if;
    -- Idempotent replay of an offline create.
    return public.manual_issue_json(v_existing);
  end if;

  -- When the referenced catalogue row already exists it must belong to this
  -- vineyard. A not-yet-synced offline type id is allowed (plain uuid) — the
  -- type create replays before or alongside the pin.
  if p_custom_type_id is not null then
    select * into v_type from public.vineyard_custom_pin_types where id = p_custom_type_id;
    if found and v_type.vineyard_id <> p_vineyard_id then
      raise exception 'TYPE_VINEYARD_MISMATCH: custom type belongs to another vineyard';
    end if;
  end if;

  perform public._manual_issue_validate(
    p_vineyard_id, p_title, 'general', 'normal', p_location_scope,
    p_paddock_id, p_latitude, p_longitude, null, p_segments
  );

  insert into public.pins (
    id, vineyard_id, paddock_id, mode, title, notes, category, priority, status,
    location_scope, custom_type_id, latitude, longitude,
    snapped_latitude, snapped_longitude, driving_row_number, pin_row_number,
    pin_side, along_row_distance_m, snapped_to_row,
    button_name, button_color,
    is_completed, created_by, updated_by, client_updated_at
  ) values (
    p_id, p_vineyard_id, p_paddock_id, 'ManualIssue', btrim(p_title),
    nullif(btrim(coalesce(p_notes, '')), ''), 'general', 'normal', 'open',
    p_location_scope, p_custom_type_id, p_latitude, p_longitude,
    case when p_location_scope = 'point' then p_snapped_latitude else null end,
    case when p_location_scope = 'point' then p_snapped_longitude else null end,
    case when p_location_scope = 'point' then p_driving_row_number else null end,
    case when p_location_scope = 'point' then p_pin_row_number else null end,
    null, -- pin_side: the unified composer has no Left/Right selection
    case when p_location_scope = 'point' then p_along_row_distance_m else null end,
    case when p_location_scope = 'point' then coalesce(p_snapped_to_row, false) else false end,
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

-- ---------------------------------------------------------------------------
-- 4. Generic row-segment persistence for Repair / Growth pins
-- ---------------------------------------------------------------------------

-- The Repair and Growth tabs keep their existing authoritative write path
-- (direct pins insert). When those saves carry a ROW location, the structured
-- selection is persisted here — the same canonical pin_row_segments shape the
-- Manual Issue RPCs use. Replaces atomically; idempotent on replay.
create or replace function public.set_pin_row_segments(
  p_pin_id uuid,
  p_segments jsonb
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
  select * into v_pin from public.pins where id = p_pin_id and deleted_at is null;
  if not found then
    -- The client may replay before the offline pin insert has landed;
    -- callers treat this error as retryable.
    raise exception 'PIN_NOT_FOUND: %', p_pin_id;
  end if;
  if not public.has_vineyard_role(v_pin.vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'PERMISSION_DENIED: you cannot edit pins in this vineyard';
  end if;
  if (select count(*) from public._manual_issue_parse_segments(p_segments)) = 0 then
    raise exception 'SEGMENTS_REQUIRED: at least one row segment is required';
  end if;

  update public.pins set location_scope = 'row' where id = p_pin_id
    and (location_scope is distinct from 'row');

  delete from public.pin_row_segments where pin_id = p_pin_id;
  insert into public.pin_row_segments (pin_id, row_number, segment_number)
  select distinct p_pin_id, s.row_number, s.segment_number
  from public._manual_issue_parse_segments(p_segments) s;

  return coalesce(
    (
      select jsonb_agg(jsonb_build_object('row', s.row_number, 'segment', s.segment_number)
                       order by s.row_number, s.segment_number)
      from public.pin_row_segments s
      where s.pin_id = p_pin_id
    ),
    '[]'::jsonb
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. manual_issue_json now carries custom_type_id
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
    'custom_type_id', p_pin.custom_type_id,
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
-- 6. Grants
-- ---------------------------------------------------------------------------

revoke all on function public.create_vineyard_custom_pin_type(uuid, uuid, text, text, text) from public;
grant execute on function public.create_vineyard_custom_pin_type(uuid, uuid, text, text, text) to authenticated;

revoke all on function public.list_vineyard_custom_pin_types(uuid, boolean) from public;
grant execute on function public.list_vineyard_custom_pin_types(uuid, boolean) to authenticated;

revoke all on function public.set_vineyard_custom_pin_type_active(uuid, boolean) from public;
grant execute on function public.set_vineyard_custom_pin_type_active(uuid, boolean) to authenticated;

revoke all on function public.create_custom_pin(uuid, uuid, text, text, uuid, uuid, text, double precision, double precision, double precision, double precision, numeric, numeric, numeric, boolean, timestamptz, jsonb) from public;
grant execute on function public.create_custom_pin(uuid, uuid, text, text, uuid, uuid, text, double precision, double precision, double precision, double precision, numeric, numeric, numeric, boolean, timestamptz, jsonb) to authenticated;

revoke all on function public.set_pin_row_segments(uuid, jsonb) from public;
grant execute on function public.set_pin_row_segments(uuid, jsonb) to authenticated;

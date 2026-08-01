-- =====================================================================
-- 159_operational_tool_preferences.sql
-- =====================================================================
-- Customisable Operational Tools — per-USER (never per-vineyard) layout
-- for the Home "Operational Tools" grid, shared across iOS, Android and
-- (later) the Lovable portal.
--
-- WHAT THIS MIGRATION ADDS (additive only):
--   A. public.operational_tool_catalogue          — the recognised stable
--      tool IDs. Seeded from the live iOS/Android 12-tile grid. Future
--      tools are added here by a later migration; nothing else changes.
--   B. public.user_operational_tool_preferences   — one row per user.
--      RLS: a user can only read/write their OWN row.
--   C. public._normalise_operational_tool_ids()   — dedupe + drop unknown
--      IDs + cap length.
--   D. get_my_operational_tool_preferences()      — read own layout.
--   E. set_my_operational_tool_preferences(..)    — write own layout.
--   F. reset_my_operational_tool_preferences()    — back to default.
--
-- RULES ENFORCED SERVER-SIDE:
--   * user_id always derived from auth.uid(); never client-supplied.
--   * Duplicates within a list are rejected.
--   * A tool present in BOTH lists is rejected.
--   * Unknown / retired tool IDs are IGNORED (dropped on save) so an old
--     client can never corrupt a newer layout, and a removed tool
--     silently disappears at the next save.
--   * At least one visible tool must remain whenever anything is hidden.
--   * Hiding is presentation ONLY. This table grants nothing: the apps
--     always filter the saved layout through the caller's currently
--     authorised tool catalogue before displaying it, and every feature
--     keeps its own independent permission checks.
--
-- WHAT THIS MIGRATION DOES NOT DO:
--   * No preference row is created for existing users — absence means
--     "VineTrack default order, all authorised tools", so nobody sees a
--     change until they customise.
--   * No permission/entitlement logic is touched.
--
-- ROLLBACK (non-destructive to unrelated objects):
--   drop function if exists public.reset_my_operational_tool_preferences();
--   drop function if exists public.set_my_operational_tool_preferences(text[], text[], integer);
--   drop function if exists public.get_my_operational_tool_preferences();
--   drop function if exists public._normalise_operational_tool_ids(text[]);
--   drop table if exists public.user_operational_tool_preferences;
--   drop table if exists public.operational_tool_catalogue;
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A. Recognised tool catalogue (stable IDs — never display names)
-- ---------------------------------------------------------------------
create table if not exists public.operational_tool_catalogue (
  tool_id       text primary key,
  display_order integer not null,
  is_active     boolean not null default true,
  added_in      text,
  created_at    timestamptz not null default now(),
  constraint operational_tool_catalogue_id_format
    check (tool_id ~ '^[a-z][a-z0-9_]{1,62}$')
);

-- Seeded from the live grid in NewMainTabView.operationsSection (iOS) and
-- HomeDashboard.baseOperationalTools (Android). display_order IS the
-- VineTrack default order used when a user has no saved preference.
insert into public.operational_tool_catalogue (tool_id, display_order, added_in) values
  ('work_tasks',            10, 'sql/159'),
  ('equipment_maintenance', 20, 'sql/159'),
  ('fuel_log',              30, 'sql/159'),
  ('irrigation_advisor',    40, 'sql/159'),
  ('disease_risk',          50, 'sql/159'),
  ('yield_records',         60, 'sql/159'),
  ('growth_stages',         70, 'sql/159'),
  ('optimal_ripeness',      80, 'sql/159'),
  ('cost_reports',          90, 'sql/159'),
  ('fertiliser_calculator',100, 'sql/159'),
  ('pruning_tracker',      110, 'sql/159'),
  ('irrigation_records',   120, 'sql/159')
on conflict (tool_id) do nothing;

alter table public.operational_tool_catalogue enable row level security;

drop policy if exists operational_tool_catalogue_read on public.operational_tool_catalogue;
create policy operational_tool_catalogue_read
  on public.operational_tool_catalogue
  for select
  to authenticated
  using (true);

revoke all on table public.operational_tool_catalogue from anon;
grant select on table public.operational_tool_catalogue to authenticated;

comment on table public.operational_tool_catalogue is
  'SQL 159: recognised Operational Tools stable IDs + VineTrack default order. Read-only for clients; extended by future migrations when a tool is added. Renaming a tool must keep its tool_id.';

-- ---------------------------------------------------------------------
-- B. Per-user preference (NOT per-vineyard)
-- ---------------------------------------------------------------------
create table if not exists public.user_operational_tool_preferences (
  user_id            uuid primary key references auth.users (id) on delete cascade,
  visible_tool_ids   text[] not null default '{}',
  hidden_tool_ids    text[] not null default '{}',
  preference_version integer not null default 1,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint user_operational_tool_preferences_version_check
    check (preference_version between 1 and 1),
  constraint user_operational_tool_preferences_size_check
    check (
      coalesce(array_length(visible_tool_ids, 1), 0)
      + coalesce(array_length(hidden_tool_ids, 1), 0) <= 64
    )
);

alter table public.user_operational_tool_preferences enable row level security;

drop policy if exists user_operational_tool_preferences_select on public.user_operational_tool_preferences;
create policy user_operational_tool_preferences_select
  on public.user_operational_tool_preferences
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists user_operational_tool_preferences_insert on public.user_operational_tool_preferences;
create policy user_operational_tool_preferences_insert
  on public.user_operational_tool_preferences
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists user_operational_tool_preferences_update on public.user_operational_tool_preferences;
create policy user_operational_tool_preferences_update
  on public.user_operational_tool_preferences
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists user_operational_tool_preferences_delete on public.user_operational_tool_preferences;
create policy user_operational_tool_preferences_delete
  on public.user_operational_tool_preferences
  for delete to authenticated
  using (user_id = auth.uid());

revoke all on table public.user_operational_tool_preferences from anon;
grant select, insert, update, delete
  on table public.user_operational_tool_preferences to authenticated;

comment on table public.user_operational_tool_preferences is
  'SQL 159: per-user Operational Tools layout (visible order + hidden list). User-scoped, NOT vineyard-scoped — the same layout follows the user across vineyards and devices. Presentation only: grants no access to any feature.';

-- ---------------------------------------------------------------------
-- C. Normaliser — order-preserving dedupe, drops unknown/retired IDs
-- ---------------------------------------------------------------------
create or replace function public._normalise_operational_tool_ids(
  p_ids text[]
)
returns text[]
language sql
stable
as $$
  select coalesce(
    array_agg(t.tool_id order by t.ord),
    '{}'::text[]
  )
  from (
    select distinct on (x.id) x.id as tool_id, x.ord
    from (
      select btrim(lower(v)) as id, i as ord
      from unnest(coalesce(p_ids, '{}'::text[])) with ordinality as u(v, i)
    ) x
    join public.operational_tool_catalogue c
      on c.tool_id = x.id and c.is_active
    order by x.id, x.ord
  ) t
$$;

revoke all on function public._normalise_operational_tool_ids(text[]) from public;
grant execute on function public._normalise_operational_tool_ids(text[]) to authenticated;

comment on function public._normalise_operational_tool_ids(text[]) is
  'SQL 159: lower/trim, keep first occurrence, drop IDs missing from the active catalogue, preserve caller order.';

-- ---------------------------------------------------------------------
-- D. Read own preference
-- ---------------------------------------------------------------------
create or replace function public.get_my_operational_tool_preferences()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_row  public.user_operational_tool_preferences%rowtype;
begin
  if v_user is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select * into v_row
  from public.user_operational_tool_preferences
  where user_id = v_user;

  if not found then
    -- No record yet: the client uses the VineTrack default order and shows
    -- every authorised tool. Deliberately does NOT create a row.
    return jsonb_build_object(
      'has_preference',     false,
      'version',            1,
      'visible_tool_ids',   '[]'::jsonb,
      'hidden_tool_ids',    '[]'::jsonb,
      'updated_at',         null,
      'catalogue_tool_ids', (
        select coalesce(jsonb_agg(c.tool_id order by c.display_order), '[]'::jsonb)
        from public.operational_tool_catalogue c where c.is_active
      )
    );
  end if;

  return jsonb_build_object(
    'has_preference',   true,
    'version',          v_row.preference_version,
    'visible_tool_ids', to_jsonb(public._normalise_operational_tool_ids(v_row.visible_tool_ids)),
    'hidden_tool_ids',  to_jsonb(public._normalise_operational_tool_ids(v_row.hidden_tool_ids)),
    'updated_at',       v_row.updated_at,
    'catalogue_tool_ids', (
      select coalesce(jsonb_agg(c.tool_id order by c.display_order), '[]'::jsonb)
      from public.operational_tool_catalogue c where c.is_active
    )
  );
end;
$$;

revoke all on function public.get_my_operational_tool_preferences() from public;
grant execute on function public.get_my_operational_tool_preferences() to authenticated;

comment on function public.get_my_operational_tool_preferences() is
  'SQL 159: own Operational Tools layout. Returns {has_preference, version, visible_tool_ids, hidden_tool_ids, updated_at, catalogue_tool_ids}. has_preference=false means "use the VineTrack default order and show every authorised tool" — no row is created.';

-- ---------------------------------------------------------------------
-- E. Write own preference
-- ---------------------------------------------------------------------
create or replace function public.set_my_operational_tool_preferences(
  p_visible_tool_ids   text[],
  p_hidden_tool_ids    text[] default '{}'::text[],
  p_preference_version integer default 1
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user    uuid := auth.uid();
  v_visible text[];
  v_hidden  text[];
  v_raw_vis text[] := coalesce(p_visible_tool_ids, '{}'::text[]);
  v_raw_hid text[] := coalesce(p_hidden_tool_ids,  '{}'::text[]);
  v_version integer := coalesce(p_preference_version, 1);
begin
  if v_user is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if v_version <> 1 then
    raise exception 'unsupported_preference_version' using errcode = '22023';
  end if;
  if coalesce(array_length(v_raw_vis, 1), 0)
     + coalesce(array_length(v_raw_hid, 1), 0) > 64 then
    raise exception 'too_many_tool_ids' using errcode = '22023';
  end if;

  -- Duplicates inside either list are a client bug — reject loudly.
  if (select count(*) from (select distinct btrim(lower(v)) d from unnest(v_raw_vis) v) s)
     <> coalesce(array_length(v_raw_vis, 1), 0)
     or (select count(*) from (select distinct btrim(lower(v)) d from unnest(v_raw_hid) v) s)
     <> coalesce(array_length(v_raw_hid, 1), 0) then
    raise exception 'duplicate_tool_ids' using errcode = '22023';
  end if;

  -- The same tool may not be both visible and hidden.
  if exists (
    select 1
    from unnest(v_raw_vis) v
    join unnest(v_raw_hid) h on btrim(lower(h)) = btrim(lower(v))
  ) then
    raise exception 'tool_in_both_lists' using errcode = '22023';
  end if;

  -- Unknown / retired IDs are dropped here (never rejected) so an older
  -- client and a newer catalogue can always agree on a safe result.
  v_visible := public._normalise_operational_tool_ids(v_raw_vis);
  v_hidden  := public._normalise_operational_tool_ids(v_raw_hid);

  -- Nothing recognised at all → treat as a reset to the default layout.
  if coalesce(array_length(v_visible, 1), 0) = 0
     and coalesce(array_length(v_hidden, 1), 0) = 0 then
    delete from public.user_operational_tool_preferences where user_id = v_user;
    return public.get_my_operational_tool_preferences();
  end if;

  if coalesce(array_length(v_visible, 1), 0) = 0 then
    raise exception 'at_least_one_visible_tool' using errcode = '22023';
  end if;

  insert into public.user_operational_tool_preferences as p (
    user_id, visible_tool_ids, hidden_tool_ids, preference_version,
    created_at, updated_at
  )
  values (v_user, v_visible, v_hidden, 1, now(), now())
  on conflict (user_id) do update set
    visible_tool_ids   = excluded.visible_tool_ids,
    hidden_tool_ids    = excluded.hidden_tool_ids,
    preference_version = excluded.preference_version,
    updated_at         = now();

  return public.get_my_operational_tool_preferences();
end;
$$;

revoke all on function public.set_my_operational_tool_preferences(text[], text[], integer) from public;
grant execute on function public.set_my_operational_tool_preferences(text[], text[], integer) to authenticated;

comment on function public.set_my_operational_tool_preferences(text[], text[], integer) is
  'SQL 159: replace the caller''s own Operational Tools layout. auth.uid() only. Rejects duplicates, a tool in both lists, an empty visible list and unsupported versions; silently drops unknown/retired IDs. Returns the stored layout in get_my_operational_tool_preferences() shape.';

-- ---------------------------------------------------------------------
-- F. Reset to the VineTrack default
-- ---------------------------------------------------------------------
create or replace function public.reset_my_operational_tool_preferences()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  delete from public.user_operational_tool_preferences where user_id = v_user;
  return public.get_my_operational_tool_preferences();
end;
$$;

revoke all on function public.reset_my_operational_tool_preferences() from public;
grant execute on function public.reset_my_operational_tool_preferences() to authenticated;

comment on function public.reset_my_operational_tool_preferences() is
  'SQL 159: delete the caller''s own layout row so the VineTrack default order and every authorised tool are shown again. Affects only the calling user.';

commit;

-- =====================================================================
-- VERIFICATION (run after commit, as any authenticated user):
--   select public.get_my_operational_tool_preferences();
--   select public.set_my_operational_tool_preferences(
--     array['irrigation_records','work_tasks'], array['cost_reports'], 1);
--   select public.reset_my_operational_tool_preferences();
-- =====================================================================

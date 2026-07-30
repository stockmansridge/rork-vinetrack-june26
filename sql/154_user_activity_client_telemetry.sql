-- =====================================================================
-- 154_user_activity_client_telemetry.sql
-- =====================================================================
-- User Activity Client Telemetry — server-authoritative device/client
-- reporting for the System Admin User Activity page.
--
-- ROOT CAUSE BEING FIXED:
--   admin_list_user_login_activity() (SQL 094) sources its device/app
--   metadata from public.support_requests — the ONLY writer of device
--   metadata in the whole backend. Users who never filed a support
--   request therefore show App/Platform/Device/OS as blank ("Unknown").
--   There is no heartbeat, no client/device table, and Supabase Auth
--   only exposes last_sign_in_at. RevenueCat purchase platform is
--   billing data and is deliberately NOT used for activity.
--
-- WHAT THIS MIGRATION ADDS (additive only):
--   A. public.vinetrack_user_clients        — one row per (user, client
--      installation). RLS-locked; no direct client access.
--   B. public._sanitise_client_text()       — trim/strip/length-limit.
--   C. public.record_my_client_activity(..) — authenticated heartbeat
--      upsert. auth.uid() only; validates app/platform enums; ignores
--      foreign vineyard IDs; preserves first_seen_at; bounds history to
--      the newest 10 clients per user.
--   D. admin_list_user_login_activity(..)   — DROP + recreate. The 14
--      existing output columns are UNCHANGED (names, types, order,
--      meanings) so current iOS/Android/portal callers keep working;
--      6 optional filter params (all default null — the existing
--      zero-argument call still resolves) and 10 APPENDED columns:
--        last_app_type, last_platform, last_device_family,
--        last_device_model, last_os_name, last_os_version,
--        last_app_version, last_app_build, last_client_seen_at,
--        client_count
--   E. public.admin_user_client_activity(p_user_id) — System-Admin-only
--      per-user client history with a redacted client reference.
--   F. public.prune_stale_user_clients(..)  — retention helper (System
--      Admin), deletes clients not seen for 24 months by default.
--
-- PRIVACY:
--   * client_instance_id is a RANDOM per-installation UUID supplied by
--     the app — never a hardware identifier.
--   * No IMEI/serial/MAC/advertising ID/location/IP is accepted or
--     stored. All free-text fields are sanitised and length-limited.
--   * The raw installation UUID is never returned by the admin RPCs —
--     only a redacted reference.
--
-- ROLLBACK (non-destructive to unrelated objects):
--   drop function if exists public.admin_list_user_login_activity(text, text, text, timestamptz, timestamptz, text);
--   -- then re-run sql/094 to restore the original list RPC.
--   drop function if exists public.admin_user_client_activity(uuid);
--   drop function if exists public.record_my_client_activity(uuid, text, text, text, text, text, text, text, text, text, text, uuid);
--   drop function if exists public.prune_stale_user_clients(interval);
--   drop function if exists public._sanitise_client_text(text, integer);
--   drop table if exists public.vinetrack_user_clients;
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A. Client activity table
-- ---------------------------------------------------------------------
create table if not exists public.vinetrack_user_clients (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users (id) on delete cascade,
  client_instance_id    uuid not null,
  app_type              text not null,
  platform              text not null,
  device_family         text,
  device_model          text,
  os_name               text,
  os_version            text,
  app_version           text,
  app_build             text,
  browser_name          text,
  browser_version       text,
  first_seen_at         timestamptz not null default now(),
  last_seen_at          timestamptz not null default now(),
  last_authenticated_at timestamptz,
  last_vineyard_id      uuid references public.vineyards (id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint vinetrack_user_clients_user_client_key
    unique (user_id, client_instance_id),
  constraint vinetrack_user_clients_app_type_check
    check (app_type in ('ios', 'android', 'portal-web')),
  constraint vinetrack_user_clients_platform_check
    check (platform in ('ios', 'android', 'web')),
  constraint vinetrack_user_clients_pair_check
    check (
      (app_type = 'ios'        and platform = 'ios')
      or (app_type = 'android' and platform = 'android')
      or (app_type = 'portal-web' and platform = 'web')
    )
);

create index if not exists vinetrack_user_clients_user_seen_idx
  on public.vinetrack_user_clients (user_id, last_seen_at desc);
create index if not exists vinetrack_user_clients_last_seen_idx
  on public.vinetrack_user_clients (last_seen_at desc);

-- Locked down: no customer-facing direct table access. All reads and
-- writes flow through the SECURITY DEFINER RPCs below.
alter table public.vinetrack_user_clients enable row level security;
revoke all on table public.vinetrack_user_clients from anon, authenticated;

comment on table public.vinetrack_user_clients is
  'SQL 154: per-installation client telemetry (one row per user + random client_instance_id). No hardware identifiers, no IP, no location. RLS locked — access only via record_my_client_activity / admin RPCs.';

-- ---------------------------------------------------------------------
-- B. Sanitiser — trim, strip control characters, length-limit, null blanks
-- ---------------------------------------------------------------------
create or replace function public._sanitise_client_text(
  p_value text,
  p_max   integer default 80
)
returns text
language sql
immutable
as $$
  select nullif(
    btrim(left(
      regexp_replace(coalesce(p_value, ''), '[[:cntrl:]]+', ' ', 'g'),
      greatest(1, coalesce(p_max, 80))
    )),
    ''
  )
$$;

revoke all on function public._sanitise_client_text(text, integer) from public;

-- ---------------------------------------------------------------------
-- C. Authenticated heartbeat RPC
-- ---------------------------------------------------------------------
create or replace function public.record_my_client_activity(
  p_client_instance_id uuid,
  p_app_type           text,
  p_platform           text,
  p_device_family      text,
  p_device_model       text,
  p_os_name            text,
  p_os_version         text,
  p_app_version        text,
  p_app_build          text,
  p_browser_name       text default null,
  p_browser_version    text default null,
  p_vineyard_id        uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_user     uuid := auth.uid();
  v_vineyard uuid := null;
  v_count    integer;
begin
  if v_user is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if p_client_instance_id is null then
    raise exception 'invalid_client_instance' using errcode = '22023';
  end if;
  -- Permitted app/platform pairs only.
  if not (
    (p_app_type = 'ios'        and p_platform = 'ios')
    or (p_app_type = 'android' and p_platform = 'android')
    or (p_app_type = 'portal-web' and p_platform = 'web')
  ) then
    raise exception 'invalid_app_platform' using errcode = '22023';
  end if;

  -- last_vineyard_id: only stored when the caller is genuinely a member
  -- (or owner) of that vineyard. A foreign vineyard ID is silently
  -- dropped — telemetry must never block normal app use.
  if p_vineyard_id is not null then
    if exists (
         select 1 from public.vineyard_members vm
         where vm.vineyard_id = p_vineyard_id and vm.user_id = v_user
       )
       or exists (
         select 1 from public.vineyards v
         where v.id = p_vineyard_id and v.owner_id = v_user and v.deleted_at is null
       )
    then
      v_vineyard := p_vineyard_id;
    end if;
  end if;

  insert into public.vinetrack_user_clients as c (
    user_id, client_instance_id, app_type, platform,
    device_family, device_model, os_name, os_version,
    app_version, app_build, browser_name, browser_version,
    first_seen_at, last_seen_at, last_authenticated_at,
    last_vineyard_id, created_at, updated_at
  )
  values (
    v_user, p_client_instance_id, p_app_type, p_platform,
    public._sanitise_client_text(p_device_family, 40),
    public._sanitise_client_text(p_device_model, 80),
    public._sanitise_client_text(p_os_name, 40),
    public._sanitise_client_text(p_os_version, 40),
    public._sanitise_client_text(p_app_version, 40),
    public._sanitise_client_text(p_app_build, 40),
    case when p_app_type = 'portal-web'
         then public._sanitise_client_text(p_browser_name, 60) end,
    case when p_app_type = 'portal-web'
         then public._sanitise_client_text(p_browser_version, 40) end,
    now(), now(), now(), v_vineyard, now(), now()
  )
  on conflict (user_id, client_instance_id) do update set
    app_type              = excluded.app_type,
    platform              = excluded.platform,
    device_family         = excluded.device_family,
    device_model          = excluded.device_model,
    os_name               = excluded.os_name,
    os_version            = excluded.os_version,
    app_version           = excluded.app_version,
    app_build             = excluded.app_build,
    browser_name          = excluded.browser_name,
    browser_version       = excluded.browser_version,
    last_seen_at          = now(),
    last_authenticated_at = now(),
    last_vineyard_id      = coalesce(excluded.last_vineyard_id, c.last_vineyard_id),
    updated_at            = now();
    -- first_seen_at deliberately NOT in the update list — preserved.

  -- Bounded history: keep only the newest 10 clients per user.
  delete from public.vinetrack_user_clients d
  where d.user_id = v_user
    and d.id not in (
      select k.id from public.vinetrack_user_clients k
      where k.user_id = v_user
      order by k.last_seen_at desc
      limit 10
    );

  select count(*)::integer into v_count
  from public.vinetrack_user_clients cc
  where cc.user_id = v_user;

  return jsonb_build_object('ok', true, 'client_count', v_count);
end;
$$;

revoke all on function public.record_my_client_activity(uuid, text, text, text, text, text, text, text, text, text, text, uuid) from public;
grant execute on function public.record_my_client_activity(uuid, text, text, text, text, text, text, text, text, text, text, uuid) to authenticated;

comment on function public.record_my_client_activity(uuid, text, text, text, text, text, text, text, text, text, text, uuid) is
  'SQL 154: authenticated client heartbeat. user_id from auth.uid() only. Validates app_type/platform pairs (ios/ios, android/android, portal-web/web), sanitises + length-limits all text, ignores foreign vineyard IDs, preserves first_seen_at, keeps the newest 10 clients per user. Returns {ok, client_count}.';

-- ---------------------------------------------------------------------
-- D. User Activity list RPC — same 14 columns + appended client fields
-- ---------------------------------------------------------------------
drop function if exists public.admin_list_user_login_activity();

create function public.admin_list_user_login_activity(
  p_app_type    text        default null,   -- ios | android | portal-web
  p_platform    text        default null,   -- ios | android | web
  p_os_name     text        default null,   -- exact, case-insensitive
  p_seen_since  timestamptz default null,   -- last_client_seen_at >=
  p_seen_before timestamptz default null,   -- last_client_seen_at <
  p_app_version text        default null    -- exact
)
returns table (
  user_id             uuid,
  email               text,
  display_name        text,
  account_created_at  timestamptz,
  last_sign_in_at     timestamptz,
  vineyard_ids        uuid[],
  vineyard_names      text[],
  roles               text[],
  app_platform        text,
  app_version         text,
  app_build           text,
  device_model        text,
  os_version          text,
  status              text,
  -- ---- appended (SQL 154) — most recently active client ----
  last_app_type       text,
  last_platform       text,
  last_device_family  text,
  last_device_model   text,
  last_os_name        text,
  last_os_version     text,
  last_app_version    text,
  last_app_build      text,
  last_client_seen_at timestamptz,
  client_count        integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;

  return query
  with memberships as (
    select
      p.id as user_id,
      v.id as vineyard_id,
      v.name as vineyard_name,
      coalesce(vm.role, case when v.owner_id = p.id then 'owner' end) as role
    from public.profiles p
    join public.vineyards v
      on v.deleted_at is null
     and (v.owner_id = p.id or exists (
            select 1 from public.vineyard_members vm0
            where vm0.vineyard_id = v.id and vm0.user_id = p.id
          ))
    left join public.vineyard_members vm
      on vm.vineyard_id = v.id and vm.user_id = p.id
  ),
  membership_agg as (
    select
      m.user_id,
      array_agg(distinct m.vineyard_id) as vineyard_ids,
      array_agg(distinct m.vineyard_name order by m.vineyard_name) as vineyard_names,
      array_agg(distinct m.role) filter (where m.role is not null) as roles
    from memberships m
    group by m.user_id
  ),
  latest_device as (
    -- Legacy source (support_requests), retained for backwards
    -- compatibility of the original columns.
    select distinct on (sr.user_id)
      sr.user_id,
      sr.app_platform,
      sr.app_version,
      sr.app_build,
      sr.device_model,
      sr.os_version
    from public.support_requests sr
    where sr.user_id is not null
    order by sr.user_id, sr.created_at desc
  ),
  latest_client as (
    -- SQL 154: most recently active telemetry client per user.
    select distinct on (c.user_id)
      c.user_id,
      c.app_type,
      c.platform,
      c.device_family,
      c.device_model,
      c.os_name,
      c.os_version,
      c.app_version,
      c.app_build,
      c.last_seen_at
    from public.vinetrack_user_clients c
    order by c.user_id, c.last_seen_at desc
  ),
  client_counts as (
    select cc.user_id, count(*)::integer as n
    from public.vinetrack_user_clients cc
    group by cc.user_id
  )
  select
    p.id as user_id,
    coalesce(p.email, u.email) as email,
    p.full_name as display_name,
    p.created_at as account_created_at,
    u.last_sign_in_at,
    coalesce(ma.vineyard_ids, '{}'::uuid[]) as vineyard_ids,
    coalesce(ma.vineyard_names, '{}'::text[]) as vineyard_names,
    coalesce(ma.roles, '{}'::text[]) as roles,
    ld.app_platform,
    ld.app_version,
    ld.app_build,
    ld.device_model,
    ld.os_version,
    case
      when u.last_sign_in_at is null then 'never'
      when u.last_sign_in_at >= now() - interval '7 days'  then 'active_recent'
      when u.last_sign_in_at >= now() - interval '30 days' then 'active_30d'
      when u.last_sign_in_at >= now() - interval '90 days' then 'inactive_30d'
      else 'inactive_90d'
    end as status,
    lc.app_type      as last_app_type,
    lc.platform      as last_platform,
    lc.device_family as last_device_family,
    lc.device_model  as last_device_model,
    lc.os_name       as last_os_name,
    lc.os_version    as last_os_version,
    lc.app_version   as last_app_version,
    lc.app_build     as last_app_build,
    lc.last_seen_at  as last_client_seen_at,
    coalesce(nc.n, 0) as client_count
  from public.profiles p
  left join auth.users u on u.id = p.id
  left join membership_agg ma on ma.user_id = p.id
  left join latest_device ld on ld.user_id = p.id
  left join latest_client lc on lc.user_id = p.id
  left join client_counts nc on nc.user_id = p.id
  where (p_app_type    is null or lc.app_type = p_app_type)
    and (p_platform    is null or lc.platform = p_platform)
    and (p_os_name     is null or lower(coalesce(lc.os_name, '')) = lower(p_os_name))
    and (p_seen_since  is null or lc.last_seen_at >= p_seen_since)
    and (p_seen_before is null or lc.last_seen_at <  p_seen_before)
    and (p_app_version is null or lc.app_version = p_app_version)
  order by u.last_sign_in_at desc nulls last, p.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_user_login_activity(text, text, text, timestamptz, timestamptz, text) from public;
grant execute on function public.admin_list_user_login_activity(text, text, text, timestamptz, timestamptz, text) to authenticated;

comment on function public.admin_list_user_login_activity(text, text, text, timestamptz, timestamptz, text) is
  'SQL 154: System-Admin-only user activity list. First 14 columns identical to SQL 094 (support_requests legacy metadata retained); appends the most recently active telemetry client (last_app_type/last_platform/last_device_family/last_device_model/last_os_name/last_os_version/last_app_version/last_app_build/last_client_seen_at/client_count). All filter params optional — the legacy zero-argument call is unchanged. Null client fields mean "Not recorded" (no heartbeat yet), never derived from purchase platform.';

-- ---------------------------------------------------------------------
-- E. Per-user client history (System Admin)
-- ---------------------------------------------------------------------
create or replace function public.admin_user_client_activity(
  p_user_id uuid
)
returns table (
  client_reference   text,
  app_type           text,
  platform           text,
  device_family      text,
  device_model       text,
  os_name            text,
  os_version         text,
  app_version        text,
  app_build          text,
  browser_name       text,
  browser_version    text,
  first_seen_at      timestamptz,
  last_seen_at       timestamptz,
  last_vineyard_name text,
  is_current         boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_user_id is null then
    raise exception 'user_required' using errcode = '22023';
  end if;

  return query
  select
    -- Redacted, stable reference — the raw installation UUID never
    -- leaves the database.
    'client-' || right(md5(c.client_instance_id::text || c.user_id::text), 8),
    c.app_type,
    c.platform,
    c.device_family,
    c.device_model,
    c.os_name,
    c.os_version,
    c.app_version,
    c.app_build,
    c.browser_name,
    c.browser_version,
    c.first_seen_at,
    c.last_seen_at,
    v.name,
    (row_number() over (order by c.last_seen_at desc) = 1)
  from public.vinetrack_user_clients c
  left join public.vineyards v on v.id = c.last_vineyard_id
  where c.user_id = p_user_id
  order by c.last_seen_at desc;
end;
$$;

revoke all on function public.admin_user_client_activity(uuid) from public;
grant execute on function public.admin_user_client_activity(uuid) to authenticated;

comment on function public.admin_user_client_activity(uuid) is
  'SQL 154: System-Admin-only client history for one user (newest 10 clients, redacted client reference, is_current on the most recent).';

-- ---------------------------------------------------------------------
-- F. Retention helper — delete clients not seen for 24 months
-- ---------------------------------------------------------------------
create or replace function public.prune_stale_user_clients(
  p_older_than interval default interval '24 months'
)
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_deleted integer;
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  delete from public.vinetrack_user_clients c
  where c.last_seen_at < now() - coalesce(p_older_than, interval '24 months');
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.prune_stale_user_clients(interval) from public;
grant execute on function public.prune_stale_user_clients(interval) to authenticated;

comment on function public.prune_stale_user_clients(interval) is
  'SQL 154: retention helper. System-Admin-only; deletes telemetry clients not seen for 24 months (default). Per-user history is already bounded to 10 clients by the heartbeat.';

commit;

-- =====================================================================
-- VERIFICATION (run after commit):
--   -- As any authenticated user (their own heartbeat):
--   select public.record_my_client_activity(
--     gen_random_uuid(), 'ios', 'ios', 'iPhone', 'iPhone16,2',
--     'iOS', '18.6', '2.8.7', '20');
--
--   -- As a System Admin:
--   select user_id, email, last_app_type, last_platform,
--          last_device_model, last_os_name, last_os_version,
--          last_client_seen_at, client_count
--   from public.admin_list_user_login_activity();
--   -- Users with no heartbeat show NULL client fields ("Not recorded").
--
--   select * from public.admin_user_client_activity('<user-uuid>');
-- =====================================================================

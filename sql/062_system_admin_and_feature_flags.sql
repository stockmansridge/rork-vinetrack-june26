-- 062_system_admin_and_feature_flags.sql
--
-- VineTrack platform-level System Admin controls and shared Feature Flags.
--
-- Roles:
--   System admin    = VineTrack platform administrator (rows in public.system_admins)
--   Vineyard owner/manager = customer-level admin for their own vineyard (NOT a system admin)
--   Supervisor/operator    = normal operational users
--
-- Storage:
--   public.system_admins        - registry of platform admins
--   public.system_feature_flags - shared flags read by iOS + Lovable
--
-- Access:
--   - Only active system admins can read or write flags via the RPCs below.
--   - Anon users have no access.
--   - is_system_admin() is callable by any authenticated user but only returns
--     true for active system admins.

-- =========================================================================
-- system_admins
-- =========================================================================

create table if not exists public.system_admins (
    user_id     uuid primary key references auth.users(id) on delete cascade,
    email       text,
    is_active   boolean not null default true,
    created_at  timestamptz not null default now(),
    created_by  uuid references auth.users(id) on delete set null
);

create index if not exists system_admins_active_idx
    on public.system_admins(user_id)
    where is_active = true;

alter table public.system_admins enable row level security;

-- No client SELECT / INSERT / UPDATE / DELETE policies. All access is funneled
-- through SECURITY DEFINER functions below.

-- =========================================================================
-- system_feature_flags
-- =========================================================================

create table if not exists public.system_feature_flags (
    id          uuid primary key default gen_random_uuid(),
    key         text not null unique,
    value       jsonb not null default 'false'::jsonb,
    value_type  text not null default 'boolean'
        check (value_type in ('boolean','string','number','json')),
    category    text,
    label       text,
    description text,
    is_enabled  boolean not null default false,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    updated_by  uuid references auth.users(id) on delete set null
);

create index if not exists system_feature_flags_key_idx
    on public.system_feature_flags(key);

alter table public.system_feature_flags enable row level security;

-- Allow ANY authenticated user to SELECT flags so the app can decide what to
-- show. The flags themselves are not sensitive; only system admins can WRITE.
do $$
begin
    if not exists (
        select 1 from pg_policies
        where schemaname = 'public'
          and tablename  = 'system_feature_flags'
          and policyname = 'system_feature_flags_select_authenticated'
    ) then
        create policy system_feature_flags_select_authenticated
            on public.system_feature_flags
            for select
            to authenticated
            using (true);
    end if;
end$$;

-- No direct INSERT/UPDATE/DELETE policies — all writes via RPC.

-- =========================================================================
-- is_system_admin()
-- =========================================================================

create or replace function public.is_system_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists(
        select 1
          from public.system_admins
         where user_id  = auth.uid()
           and is_active = true
    );
$$;

grant execute on function public.is_system_admin() to authenticated;

-- =========================================================================
-- get_system_feature_flags()
-- =========================================================================

create or replace function public.get_system_feature_flags()
returns table (
    key         text,
    value       jsonb,
    value_type  text,
    category    text,
    label       text,
    description text,
    is_enabled  boolean,
    updated_at  timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
    select f.key, f.value, f.value_type, f.category, f.label, f.description,
           f.is_enabled, f.updated_at
      from public.system_feature_flags f
     order by f.category nulls last, f.key;
$$;

grant execute on function public.get_system_feature_flags() to authenticated;

-- =========================================================================
-- set_system_feature_flag(key, is_enabled, value?)
-- =========================================================================

create or replace function public.set_system_feature_flag(
    p_key        text,
    p_is_enabled boolean,
    p_value      jsonb default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.is_system_admin() then
        raise exception 'System admin required' using errcode = '42501';
    end if;

    insert into public.system_feature_flags as f (key, value, is_enabled, updated_at, updated_by)
    values (
        p_key,
        coalesce(p_value, to_jsonb(p_is_enabled)),
        p_is_enabled,
        now(),
        auth.uid()
    )
    on conflict (key) do update
        set is_enabled = excluded.is_enabled,
            value      = coalesce(p_value, to_jsonb(excluded.is_enabled)),
            updated_at = now(),
            updated_by = auth.uid();
end$$;

grant execute on function public.set_system_feature_flag(text, boolean, jsonb) to authenticated;

-- =========================================================================
-- Seed default flags (idempotent)
-- =========================================================================

insert into public.system_feature_flags (key, value, value_type, category, label, description, is_enabled)
values
    ('show_sync_diagnostics',     'false'::jsonb, 'boolean', 'diagnostics', 'Sync Diagnostics',          'Show the Sync Diagnostics panel in Settings.',                          false),
    ('show_pin_diagnostics',      'false'::jsonb, 'boolean', 'diagnostics', 'Pin Diagnostics',           'Show pin audit / diagnostic tooling.',                                  false),
    ('show_weather_diagnostics',  'false'::jsonb, 'boolean', 'diagnostics', 'Weather Diagnostics',       'Show weather provider/data diagnostics.',                               false),
    ('show_willyweather_debug',   'false'::jsonb, 'boolean', 'diagnostics', 'WillyWeather Debug',        'Show raw WillyWeather request/response debug surfaces.',                false),
    ('show_map_pin_diagnostics',  'false'::jsonb, 'boolean', 'diagnostics', 'Map Pin Diagnostics',       'Show map pin diagnostics on the map screen.',                           false),
    ('show_raw_json_panels',      'false'::jsonb, 'boolean', 'diagnostics', 'Raw JSON Panels',           'Show raw JSON debug panels across the app.',                            false),
    ('show_costing_diagnostics',  'false'::jsonb, 'boolean', 'diagnostics', 'Costing Diagnostics',       'Show costing / trip allocation diagnostics.',                           false),
    ('enable_beta_features',      'false'::jsonb, 'boolean', 'beta',        'Beta Features',             'Enable opt-in beta features across the app.',                           false)
on conflict (key) do nothing;

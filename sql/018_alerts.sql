-- 018_alerts.sql
-- Vineyard Alerts Centre.
-- Stores vineyard-scoped operational alerts plus per-user read/dismiss state
-- and per-vineyard preferences for thresholds and toggles.

-- ---------------------------------------------------------------------------
-- vineyard_alerts: one row per active alert. Deduplicated via dedup_key.
-- ---------------------------------------------------------------------------
create table if not exists public.vineyard_alerts (
    id uuid primary key default gen_random_uuid(),
    vineyard_id uuid not null references public.vineyards(id) on delete cascade,
    alert_type text not null,
    severity text not null default 'info',
    title text not null,
    message text not null,
    related_table text,
    related_id uuid,
    paddock_id uuid,
    action text,
    payload jsonb not null default '{}'::jsonb,
    dedup_key text not null,
    generated_for_date date,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    expires_at timestamptz,
    created_by uuid
);

create unique index if not exists vineyard_alerts_dedup_key_idx
    on public.vineyard_alerts (vineyard_id, dedup_key);
create index if not exists vineyard_alerts_vineyard_idx
    on public.vineyard_alerts (vineyard_id, created_at desc);
create index if not exists vineyard_alerts_active_idx
    on public.vineyard_alerts (vineyard_id, expires_at);

-- ---------------------------------------------------------------------------
-- vineyard_alert_user_status: per-user read/dismissed status.
-- ---------------------------------------------------------------------------
create table if not exists public.vineyard_alert_user_status (
    alert_id uuid not null references public.vineyard_alerts(id) on delete cascade,
    user_id uuid not null,
    read_at timestamptz,
    dismissed_at timestamptz,
    updated_at timestamptz not null default now(),
    primary key (alert_id, user_id)
);

create index if not exists vineyard_alert_user_status_user_idx
    on public.vineyard_alert_user_status (user_id);

-- ---------------------------------------------------------------------------
-- vineyard_alert_preferences: per-vineyard configuration.
-- ---------------------------------------------------------------------------
create table if not exists public.vineyard_alert_preferences (
    vineyard_id uuid primary key references public.vineyards(id) on delete cascade,
    irrigation_alerts_enabled boolean not null default true,
    irrigation_forecast_days int not null default 5,
    irrigation_deficit_threshold_mm numeric not null default 8,
    aged_pin_alerts_enabled boolean not null default true,
    aged_pin_days int not null default 14,
    weather_alerts_enabled boolean not null default true,
    rain_alert_threshold_mm numeric not null default 5,
    wind_alert_threshold_kmh numeric not null default 25,
    frost_alert_threshold_c numeric not null default 1,
    heat_alert_threshold_c numeric not null default 35,
    spray_job_reminders_enabled boolean not null default true,
    quiet_hours_start time,
    quiet_hours_end time,
    push_enabled boolean not null default false,
    updated_at timestamptz not null default now(),
    updated_by uuid
);

-- ---------------------------------------------------------------------------
-- updated_at triggers.
-- ---------------------------------------------------------------------------
create or replace function public.tg_alerts_set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists trg_vineyard_alerts_updated_at on public.vineyard_alerts;
create trigger trg_vineyard_alerts_updated_at
    before update on public.vineyard_alerts
    for each row execute function public.tg_alerts_set_updated_at();

drop trigger if exists trg_vineyard_alert_user_status_updated_at on public.vineyard_alert_user_status;
create trigger trg_vineyard_alert_user_status_updated_at
    before update on public.vineyard_alert_user_status
    for each row execute function public.tg_alerts_set_updated_at();

drop trigger if exists trg_vineyard_alert_preferences_updated_at on public.vineyard_alert_preferences;
create trigger trg_vineyard_alert_preferences_updated_at
    before update on public.vineyard_alert_preferences
    for each row execute function public.tg_alerts_set_updated_at();

-- ---------------------------------------------------------------------------
-- Helper: is the caller a member of the vineyard?
-- ---------------------------------------------------------------------------
create or replace function public.is_vineyard_member(p_vineyard_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.vineyards v
        where v.id = p_vineyard_id and v.owner_id = auth.uid()
    ) or exists (
        select 1 from public.vineyard_members vm
        where vm.vineyard_id = p_vineyard_id and vm.user_id = auth.uid()
    );
$$;

create or replace function public.is_vineyard_owner_or_manager(p_vineyard_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.vineyards v
        where v.id = p_vineyard_id and v.owner_id = auth.uid()
    ) or exists (
        select 1 from public.vineyard_members vm
        where vm.vineyard_id = p_vineyard_id
          and vm.user_id = auth.uid()
          and lower(vm.role) in ('owner', 'manager')
    );
$$;

revoke all on function public.is_vineyard_member(uuid) from public;
grant execute on function public.is_vineyard_member(uuid) to authenticated;
revoke all on function public.is_vineyard_owner_or_manager(uuid) from public;
grant execute on function public.is_vineyard_owner_or_manager(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.vineyard_alerts enable row level security;
alter table public.vineyard_alert_user_status enable row level security;
alter table public.vineyard_alert_preferences enable row level security;

-- vineyard_alerts: any vineyard member can read; any member can insert/update
-- (alerts are generated by clients). Soft-delete via expires_at.
drop policy if exists vineyard_alerts_select on public.vineyard_alerts;
create policy vineyard_alerts_select on public.vineyard_alerts
    for select to authenticated
    using (public.is_vineyard_member(vineyard_id));

drop policy if exists vineyard_alerts_insert on public.vineyard_alerts;
create policy vineyard_alerts_insert on public.vineyard_alerts
    for insert to authenticated
    with check (public.is_vineyard_member(vineyard_id));

drop policy if exists vineyard_alerts_update on public.vineyard_alerts;
create policy vineyard_alerts_update on public.vineyard_alerts
    for update to authenticated
    using (public.is_vineyard_member(vineyard_id))
    with check (public.is_vineyard_member(vineyard_id));

drop policy if exists vineyard_alerts_delete on public.vineyard_alerts;
create policy vineyard_alerts_delete on public.vineyard_alerts
    for delete to authenticated
    using (public.is_vineyard_owner_or_manager(vineyard_id));

-- vineyard_alert_user_status: each user manages their own row only.
drop policy if exists vineyard_alert_user_status_select on public.vineyard_alert_user_status;
create policy vineyard_alert_user_status_select on public.vineyard_alert_user_status
    for select to authenticated
    using (user_id = auth.uid());

drop policy if exists vineyard_alert_user_status_modify on public.vineyard_alert_user_status;
create policy vineyard_alert_user_status_modify on public.vineyard_alert_user_status
    for all to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

-- vineyard_alert_preferences: members read; owners/managers write.
drop policy if exists vineyard_alert_preferences_select on public.vineyard_alert_preferences;
create policy vineyard_alert_preferences_select on public.vineyard_alert_preferences
    for select to authenticated
    using (public.is_vineyard_member(vineyard_id));

drop policy if exists vineyard_alert_preferences_upsert on public.vineyard_alert_preferences;
create policy vineyard_alert_preferences_upsert on public.vineyard_alert_preferences
    for insert to authenticated
    with check (public.is_vineyard_owner_or_manager(vineyard_id));

drop policy if exists vineyard_alert_preferences_update on public.vineyard_alert_preferences;
create policy vineyard_alert_preferences_update on public.vineyard_alert_preferences
    for update to authenticated
    using (public.is_vineyard_owner_or_manager(vineyard_id))
    with check (public.is_vineyard_owner_or_manager(vineyard_id));

-- ---------------------------------------------------------------------------
-- mark_vineyard_alert_status: set read/dismissed for the calling user.
-- ---------------------------------------------------------------------------
create or replace function public.mark_vineyard_alert_status(
    p_alert_id uuid,
    p_read boolean default null,
    p_dismissed boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_vineyard uuid;
begin
    select vineyard_id into v_vineyard from public.vineyard_alerts where id = p_alert_id;
    if v_vineyard is null then
        return;
    end if;
    if not public.is_vineyard_member(v_vineyard) then
        raise exception 'Not a vineyard member' using errcode = '42501';
    end if;

    insert into public.vineyard_alert_user_status (alert_id, user_id, read_at, dismissed_at)
    values (
        p_alert_id,
        auth.uid(),
        case when coalesce(p_read, false) then now() else null end,
        case when coalesce(p_dismissed, false) then now() else null end
    )
    on conflict (alert_id, user_id) do update set
        read_at = case
            when p_read is null then public.vineyard_alert_user_status.read_at
            when p_read then coalesce(public.vineyard_alert_user_status.read_at, now())
            else null
        end,
        dismissed_at = case
            when p_dismissed is null then public.vineyard_alert_user_status.dismissed_at
            when p_dismissed then coalesce(public.vineyard_alert_user_status.dismissed_at, now())
            else null
        end,
        updated_at = now();
end;
$$;

revoke all on function public.mark_vineyard_alert_status(uuid, boolean, boolean) from public;
grant execute on function public.mark_vineyard_alert_status(uuid, boolean, boolean) to authenticated;

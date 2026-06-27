-- 056_app_notices.sql
-- App-wide information notices managed inside the iOS app under
-- Settings -> Admin -> App Notices. Notices appear as dismissible banners
-- on the Home screen for every authenticated user.
--
-- Dismissal is local-only (stored in UserDefaults on the device) so we
-- only need a single table here. If an admin wants everyone to see an
-- updated message they create a new notice instead of editing an
-- existing one.

create table if not exists public.app_notices (
    id uuid primary key default gen_random_uuid(),
    title text not null,
    message text not null,
    notice_type text not null default 'info',
    priority int not null default 0,
    starts_at timestamptz,
    ends_at timestamptz,
    is_active boolean not null default true,
    created_by uuid,
    updated_by uuid,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    client_updated_at timestamptz not null default now(),
    sync_version bigint not null default 1
);

create index if not exists app_notices_active_idx
    on public.app_notices (is_active, deleted_at, priority desc, created_at desc);
create index if not exists app_notices_updated_idx
    on public.app_notices (updated_at desc);

-- updated_at trigger
create or replace function public.tg_app_notices_set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    new.sync_version = coalesce(old.sync_version, 0) + 1;
    return new;
end;
$$;

drop trigger if exists trg_app_notices_updated_at on public.app_notices;
create trigger trg_app_notices_updated_at
    before update on public.app_notices
    for each row execute function public.tg_app_notices_set_updated_at();

-- RLS: any authenticated user may read; writes are gated client-side
-- behind the admin allow-list (super-admin email check on iOS). RLS
-- still scopes writes to authenticated users so anon keys cannot
-- touch the table.
alter table public.app_notices enable row level security;

drop policy if exists app_notices_select on public.app_notices;
create policy app_notices_select on public.app_notices
    for select to authenticated
    using (true);

drop policy if exists app_notices_insert on public.app_notices;
create policy app_notices_insert on public.app_notices
    for insert to authenticated
    with check (auth.uid() is not null);

drop policy if exists app_notices_update on public.app_notices;
create policy app_notices_update on public.app_notices
    for update to authenticated
    using (auth.uid() is not null)
    with check (auth.uid() is not null);

drop policy if exists app_notices_delete on public.app_notices;
create policy app_notices_delete on public.app_notices
    for delete to authenticated
    using (auth.uid() is not null);

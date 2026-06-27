-- 091_support_requests.sql
-- In-app support / feedback / feature-request workflow (additive, non-destructive).
--
-- Restores the in-app support form pathway:
--   * public.support_requests          stores every submission for the admin
--                                       portal list view + email status.
--   * storage bucket "support-attachments"  holds optional uploaded files,
--     namespaced per user: {user_id}/{request_id}/attachment-N.<ext>
--   * admin_list_support_requests()     SECURITY DEFINER RPC for the portal.
--
-- Email delivery to jonathan@stockmansridge.com.au is handled out-of-band by
-- the `support-request` edge function, which updates email_status on this row.
-- The DB insert is the durable path: a support request is never lost even if
-- email delivery is unavailable.
--
-- Reuses existing helpers:
--   * public.is_admin()                  (sql/017_admin_engagement.sql)
--   * public.storage_first_folder_uuid() (sql/010_vineyard_logo_storage.sql)

begin;

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------
create table if not exists public.support_requests (
  id                uuid primary key default gen_random_uuid(),
  created_at        timestamptz not null default now(),
  -- Submitter. user_id is nullable + ON DELETE SET NULL so a deleted account
  -- does not erase the support history the admin may still need.
  user_id           uuid references auth.users(id) on delete set null,
  submitter_name    text,
  submitter_email   text,
  -- Optional vineyard / business context.
  vineyard_id       uuid,
  vineyard_name     text,
  -- Content.
  category          text not null default 'general',
  subject           text not null,
  message           text not null,
  -- Attachments live in the support-attachments bucket; we store their paths.
  attachment_paths  text[] not null default '{}',
  attachment_count  integer not null default 0,
  -- Diagnostics.
  app_platform      text,
  app_version       text,
  app_build         text,
  device_model      text,
  os_version        text,
  -- Lifecycle.
  status            text not null default 'open',
  -- Email delivery status: pending | sent | failed | unconfigured
  email_status      text not null default 'pending',
  email_provider_id text,
  email_error       text,
  email_sent_at     timestamptz
);

create index if not exists support_requests_created_at_idx
  on public.support_requests (created_at desc);
create index if not exists support_requests_user_id_idx
  on public.support_requests (user_id);

alter table public.support_requests enable row level security;

-- ---------------------------------------------------------------------------
-- RLS: a customer may insert their own request and read only their own.
--      Admins may read & update all. No client deletes.
-- ---------------------------------------------------------------------------
drop policy if exists "support_requests_insert_own" on public.support_requests;
create policy "support_requests_insert_own"
on public.support_requests for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists "support_requests_select_own" on public.support_requests;
create policy "support_requests_select_own"
on public.support_requests for select
to authenticated
using (user_id = auth.uid());

drop policy if exists "support_requests_select_admin" on public.support_requests;
create policy "support_requests_select_admin"
on public.support_requests for select
to authenticated
using (public.is_admin());

drop policy if exists "support_requests_update_admin" on public.support_requests;
create policy "support_requests_update_admin"
on public.support_requests for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

-- ---------------------------------------------------------------------------
-- Storage bucket for attachments (private).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('support-attachments', 'support-attachments', false)
on conflict (id) do nothing;

-- A user may upload into their own folder ({user_id}/...).
drop policy if exists "support_attachments_insert_own" on storage.objects;
create policy "support_attachments_insert_own"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'support-attachments'
  and public.storage_first_folder_uuid(name) = auth.uid()
);

-- A user may read their own attachments; admins may read all.
drop policy if exists "support_attachments_select_own_or_admin" on storage.objects;
create policy "support_attachments_select_own_or_admin"
on storage.objects for select
to authenticated
using (
  bucket_id = 'support-attachments'
  and (
    public.storage_first_folder_uuid(name) = auth.uid()
    or public.is_admin()
  )
);

-- ---------------------------------------------------------------------------
-- Admin RPC: full list for the portal. SECURITY DEFINER, gated on is_admin().
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_support_requests(p_limit integer default 200)
returns table (
  id                uuid,
  created_at        timestamptz,
  user_id           uuid,
  submitter_name    text,
  submitter_email   text,
  vineyard_id       uuid,
  vineyard_name     text,
  category          text,
  subject           text,
  message           text,
  attachment_paths  text[],
  attachment_count  integer,
  app_platform      text,
  app_version       text,
  app_build         text,
  device_model      text,
  os_version        text,
  status            text,
  email_status      text,
  email_provider_id text,
  email_error       text,
  email_sent_at     timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  return query
  select
    sr.id, sr.created_at, sr.user_id, sr.submitter_name, sr.submitter_email,
    sr.vineyard_id, sr.vineyard_name, sr.category, sr.subject, sr.message,
    sr.attachment_paths, sr.attachment_count, sr.app_platform, sr.app_version,
    sr.app_build, sr.device_model, sr.os_version, sr.status, sr.email_status,
    sr.email_provider_id, sr.email_error, sr.email_sent_at
  from public.support_requests sr
  order by sr.created_at desc
  limit greatest(1, least(coalesce(p_limit, 200), 1000));
end;
$$;

revoke all on function public.admin_list_support_requests(integer) from public;
grant execute on function public.admin_list_support_requests(integer) to authenticated;

commit;

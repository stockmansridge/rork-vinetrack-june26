-- PREPARED ONLY: Jonathan applies after review. No Master patch, catalogue approval, or spray data changes.
-- Shared contract: one immutable PDF version per (Master id, SHA-256), with a reviewed
-- physical cover page, full image and once-generated thumbnail. Vineyard rows retain
-- only their existing master_chemical_id; never copy documents per vineyard.
begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('master-chemical-media', 'master-chemical-media', false, 52428800,
        array['application/pdf','image/png','image/webp']::text[])
on conflict (id) do update set public = false, file_size_limit = 52428800,
  allowed_mime_types = array['application/pdf','image/png','image/webp']::text[];

create table if not exists public.master_chemical_media (
  id uuid primary key default gen_random_uuid(),
  master_chemical_id uuid not null references public.master_chemicals(id),
  registration_identity_key text not null,
  document_sha256 text not null check (document_sha256 ~ '^[0-9a-f]{64}$'),
  source_url text not null check (source_url ~ '^https://'),
  document_version text,
  physical_page integer not null check (physical_page > 0),
  pdf_path text not null unique,
  full_image_path text not null unique,
  thumbnail_path text not null unique,
  preview_id uuid not null,
  preview_patch_sha256 text not null check (preview_patch_sha256 ~ '^[0-9a-f]{64}$'),
  cover_confirmed_by uuid not null references auth.users(id),
  cover_confirmed_at timestamptz not null,
  staged_at timestamptz not null default now(),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  approval_reason text,
  unique (master_chemical_id, document_sha256),
  check ((approved_at is null and approved_by is null and approval_reason is null) or
         (approved_at is not null and approved_by is not null and approval_reason is not null
          and length(btrim(approval_reason)) >= 8)),
  check (pdf_path = master_chemical_id::text || '/' || document_sha256 || '/label.pdf'
    and full_image_path = master_chemical_id::text || '/' || document_sha256 || '/front-p' || physical_page || '.png'
    and thumbnail_path = master_chemical_id::text || '/' || document_sha256 || '/thumb-p' || physical_page || '.webp')
);
create index if not exists master_chemical_media_current_idx
  on public.master_chemical_media(master_chemical_id, approved_at desc) where approved_at is not null;
alter table public.master_chemical_media enable row level security;
revoke all on public.master_chemical_media from public, anon, authenticated;
grant select on public.master_chemical_media to authenticated;
drop policy if exists master_chemical_media_admin_read on public.master_chemical_media;
create policy master_chemical_media_admin_read on public.master_chemical_media
  for select to authenticated using (public.is_system_admin());

-- Evidence is retained in the actual stored resolver patch, not in a client claim.
create or replace function public.master_media_matches_current(d public.master_chemical_media)
returns boolean language sql stable security definer set search_path = public as $$
  select d.approved_at is not null and m.review_status = 'approved'
    and m.registration_identity_key = d.registration_identity_key
    and m.label_version is not distinct from d.document_version
    and d.document_sha256 = (
      select s->'reviewed_visual_declaration'->>'document_sha256'
      from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) s
      where s ? 'reviewed_visual_declaration'
      order by s->'reviewed_visual_declaration'->>'reviewed_at' desc limit 1
    )
    and exists (
      select 1 from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) s
      where s->'reviewed_visual_declaration'->>'document_sha256' = d.document_sha256
        and s->'reviewed_visual_declaration'->>'source_url' = d.source_url
        and (s->'reviewed_visual_declaration'->>'physical_page')::integer = d.physical_page
        and s->'reviewed_visual_declaration'->>'document_version' is not distinct from d.document_version
    )
  from public.master_chemicals m where m.id = d.master_chemical_id;
$$;
revoke all on function public.master_media_matches_current(public.master_chemical_media) from public, anon;
grant execute on function public.master_media_matches_current(public.master_chemical_media) to authenticated;

-- Security definer bypasses the admin-only row policy without exposing private provenance.
create or replace function public.master_media_can_read_object(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (
    select 1 from public.master_chemical_media d
    where p_path in (d.pdf_path, d.full_image_path, d.thumbnail_path)
      and public.master_media_matches_current(d)
  );
$$;
revoke all on function public.master_media_can_read_object(text) from public, anon;
grant execute on function public.master_media_can_read_object(text) to authenticated;

-- Object ACL protects pending PDFs and cover images, even if a path leaks.
drop policy if exists master_chemical_media_object_read on storage.objects;
create policy master_chemical_media_object_read on storage.objects for select to authenticated
using (bucket_id = 'master-chemical-media' and
  (public.is_system_admin() or public.master_media_can_read_object(name)));
drop policy if exists master_chemical_media_object_insert on storage.objects;
create policy master_chemical_media_object_insert on storage.objects for insert to authenticated
with check (bucket_id = 'master-chemical-media' and public.is_system_admin()
  and name ~ '^[0-9a-f-]{36}/[0-9a-f]{64}/(label\.pdf|front-p[1-9][0-9]*\.png|thumb-p[1-9][0-9]*\.webp)$');
-- No update/upsert or delete grants: object paths are immutable version keys.

create or replace function public.stage_master_chemical_media(
  p_master_id uuid, p_preview_id uuid, p_patch_sha256 text,
  p_document_sha256 text, p_source_url text, p_document_version text, p_physical_page integer
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_master public.master_chemicals%rowtype;
  v_preview public.master_review_previews%rowtype;
  v_declaration jsonb;
  v_existing public.master_chemical_media%rowtype;
  v_base text;
  v_id uuid;
begin
  if not public.is_system_admin() then raise exception 'not_authorised' using errcode = '42501'; end if;
  select * into strict v_master from public.master_chemicals where id = p_master_id for update;
  select * into strict v_preview from public.master_review_previews where id = p_preview_id and master_chemical_id = p_master_id;
  if v_preview.requested_by <> auth.uid() or v_preview.consumed_at is not null
     or v_preview.expires_at <= now() or v_preview.base_revision <> v_master.catalogue_version
     or p_patch_sha256 !~ '^[0-9a-f]{64}$' or p_document_sha256 !~ '^[0-9a-f]{64}$'
     or p_source_url !~ '^https://' or p_physical_page < 1 then
    raise exception 'pending_preview_or_identity_mismatch' using errcode = '55000';
  end if;
  select s->'reviewed_visual_declaration' into v_declaration
    from jsonb_array_elements(coalesce(v_preview.proposed_patch->'verification_sources', '[]'::jsonb)) s
    where s->'reviewed_visual_declaration'->>'document_sha256' = p_document_sha256 limit 1;
  if v_declaration is null or v_declaration->>'reviewed_by' <> auth.uid()::text
     or v_declaration->>'source_url' <> p_source_url
     or (v_declaration->>'physical_page')::integer <> p_physical_page
     or v_declaration->>'document_version' is distinct from p_document_version then
    raise exception 'reviewed_cover_not_in_stored_preview' using errcode = '22023';
  end if;
  v_base := p_master_id::text || '/' || p_document_sha256 || '/';
  if (select count(*) from storage.objects where bucket_id = 'master-chemical-media'
        and name in (v_base || 'label.pdf', v_base || 'front-p' || p_physical_page || '.png',
                     v_base || 'thumb-p' || p_physical_page || '.webp')) <> 3 then
    raise exception 'media_objects_missing' using errcode = '22023';
  end if;
  select * into v_existing from public.master_chemical_media
    where master_chemical_id = p_master_id and document_sha256 = p_document_sha256;
  if found then
    if v_existing.preview_id <> p_preview_id or v_existing.preview_patch_sha256 <> p_patch_sha256
       or v_existing.physical_page <> p_physical_page
       or v_existing.registration_identity_key <> v_master.registration_identity_key
       or v_existing.source_url <> p_source_url
       or v_existing.document_version is distinct from p_document_version then
      raise exception 'document_version_already_staged_for_other_review' using errcode = '55000';
    end if;
    return v_existing.id;
  end if;
  insert into public.master_chemical_media (master_chemical_id, registration_identity_key,
    document_sha256, source_url, document_version, physical_page, pdf_path, full_image_path,
    thumbnail_path, preview_id, preview_patch_sha256, cover_confirmed_by, cover_confirmed_at)
  values (p_master_id, v_master.registration_identity_key, p_document_sha256, p_source_url,
    p_document_version, p_physical_page, v_base || 'label.pdf',
    v_base || 'front-p' || p_physical_page || '.png',
    v_base || 'thumb-p' || p_physical_page || '.webp', p_preview_id, p_patch_sha256,
    auth.uid(), (v_declaration->>'reviewed_at')::timestamptz) returning id into v_id;
  return v_id;
end; $$;
revoke all on function public.stage_master_chemical_media(uuid,uuid,text,text,text,text,integer) from public, anon;
grant execute on function public.stage_master_chemical_media(uuid,uuid,text,text,text,text,integer) to authenticated;

-- Separate decision: this does NOT call master_review_apply or approve a candidate Master row.
create or replace function public.approve_master_chemical_media(
  p_media_id uuid, p_expected_revision integer, p_reason text
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_media public.master_chemical_media%rowtype; v_master public.master_chemicals%rowtype;
begin
  if not public.is_system_admin() then raise exception 'not_authorised' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 8 then raise exception 'reason_required' using errcode = '22023'; end if;
  select * into strict v_media from public.master_chemical_media where id = p_media_id for update;
  select * into strict v_master from public.master_chemicals where id = v_media.master_chemical_id for update;
  if v_master.catalogue_version <> p_expected_revision or v_master.review_status <> 'approved'
     or not exists (select 1 from public.master_chemical_review_actions a
       where a.preview_id = v_media.preview_id and a.master_chemical_id = v_media.master_chemical_id
         and a.action = 'refresh_apply' and a.result_revision <= p_expected_revision)
     or v_master.registration_identity_key <> v_media.registration_identity_key
     or v_master.label_version is distinct from v_media.document_version
     or not exists (select 1 from jsonb_array_elements(coalesce(v_master.verification_sources, '[]'::jsonb)) s
       where s->'reviewed_visual_declaration'->>'document_sha256' = v_media.document_sha256
         and s->'reviewed_visual_declaration'->>'source_url' = v_media.source_url
         and (s->'reviewed_visual_declaration'->>'physical_page')::integer = v_media.physical_page
         and s->'reviewed_visual_declaration'->>'document_version' is not distinct from v_media.document_version)
  then raise exception 'catalogue_or_document_review_mismatch' using errcode = '55000'; end if;
  if v_media.document_sha256 is distinct from (
    select s->'reviewed_visual_declaration'->>'document_sha256'
    from jsonb_array_elements(coalesce(v_master.verification_sources, '[]'::jsonb)) s
    where s ? 'reviewed_visual_declaration'
    order by s->'reviewed_visual_declaration'->>'reviewed_at' desc limit 1
  ) then raise exception 'newer_document_requires_review' using errcode = '55000'; end if;
  if v_media.approved_at is null then
    update public.master_chemical_media set approved_at = now(), approved_by = auth.uid(), approval_reason = btrim(p_reason)
      where id = p_media_id;
  end if;
  return p_media_id;
end; $$;
revoke all on function public.approve_master_chemical_media(uuid,integer,text) from public, anon;
grant execute on function public.approve_master_chemical_media(uuid,integer,text) to authenticated;

-- Same small public projection for Portal, iOS and Android. No reviewer or diagnostics.
create or replace function public.get_approved_chemical_media(p_master_ids uuid[])
returns table (master_chemical_id uuid, registration_identity_key text, document_sha256 text,
  source_url text, document_version text, physical_page integer, pdf_path text,
  full_image_path text, thumbnail_path text)
language sql stable security definer set search_path = public as $$
  select distinct on (d.master_chemical_id) d.master_chemical_id, d.registration_identity_key,
    d.document_sha256, d.source_url, d.document_version, d.physical_page,
    d.pdf_path, d.full_image_path, d.thumbnail_path
  from public.master_chemical_media d
  where auth.uid() is not null and d.master_chemical_id = any(p_master_ids[1:100])
    and public.master_media_matches_current(d)
  order by d.master_chemical_id, d.approved_at desc;
$$;
revoke all on function public.get_approved_chemical_media(uuid[]) from public, anon;
grant execute on function public.get_approved_chemical_media(uuid[]) to authenticated;
commit;

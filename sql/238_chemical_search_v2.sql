-- Chemical Search V2: isolated System-Admin catalogue search + label attachments.
-- PREPARED ONLY. Do not apply to production without review.
--
-- This does not alter the legacy chemical-info-lookup function or its strict
-- registered-label save contract. Candidate rows remain candidates.

begin;

insert into public.system_feature_flags
  (key, value, value_type, category, label, description, is_enabled)
values
  ('chemical_search_v2', 'false'::jsonb, 'boolean', 'beta',
   'Chemical Search V2',
   'System-Admin-only direct VineTrack Master Chemical Catalogue search.', false)
on conflict (key) do nothing;

-- V2 keeps complete registered_uses evidence but serves this small vineyard projection.
alter table public.master_chemicals
  add column if not exists viticulture_rates jsonb not null default
    '{"per_hectare":[],"per_100_litres":[]}'::jsonb;

comment on column public.master_chemicals.viticulture_rates is
  'Deterministic registered vineyard label rates grouped by basis; separate from grower-owned saved_chemicals.default_rates.';

alter table public.master_chemicals drop constraint if exists master_chemicals_viticulture_rates_check;
alter table public.master_chemicals add constraint master_chemicals_viticulture_rates_check check (
  jsonb_typeof(viticulture_rates) = 'object'
  and jsonb_typeof(coalesce(viticulture_rates->'per_hectare', '[]'::jsonb)) = 'array'
  and jsonb_typeof(coalesce(viticulture_rates->'per_100_litres', '[]'::jsonb)) = 'array'
);

-- One eligibility contract is shared by search, reporting and the controlled
-- backfill. The earlier 197 figure belonged to an August seed-apply artifact;
-- it was never the current Master catalogue cohort.
create or replace function public.master_chemical_is_v2_eligible(m public.master_chemicals)
returns boolean language sql stable as $$
  select m.registration_country = 'AU'
    and m.registration_scheme = 'apvma'
    and (
      m.review_status = 'approved' or (
    m.review_status = 'candidate'
    and m.source_kind = 'official_register'
    and m.verification_status in ('verified', 'partially_verified')
    and exists (
      select 1 from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) s
      where s->>'kind' = 'official_register'
    )
    and exists (
      select 1 from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) s
      where s->>'kind' = 'viticulture_reference'
        and coalesce(s->>'reference', '') =
          'https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf'
    )
  )
  )
$$;

create or replace function public.master_chemical_has_viticulture_evidence(m public.master_chemicals)
returns boolean language sql stable as $$
  select
    jsonb_array_length(coalesce(m.viticulture_rates->'per_hectare', '[]'::jsonb)) > 0
    or jsonb_array_length(coalesce(m.viticulture_rates->'per_100_litres', '[]'::jsonb)) > 0
    or exists (
      select 1 from jsonb_array_elements(coalesce(m.registered_uses, '[]'::jsonb)) u
      where lower(coalesce(u->>'crop', '')) ~
        '(^|[^a-z])(vines?|vineyards?|grapevines?|grapes?|wine[[:space:]-]*grapes?|table[[:space:]-]*grapes?|dried[[:space:]-]*grapes?)([^a-z]|$)'
    )
    or exists (
      select 1 from jsonb_array_elements(coalesce(m.verification_sources, '[]'::jsonb)) s
      where s->>'kind' = 'viticulture_reference'
    )
$$;

-- viticulture_rates is canonical Master content. Extend the one canonical
-- revision trigger before any controlled backfill runs; the existing AFTER
-- trigger then records the normal full-row history snapshot.
create or replace function public.master_chemicals_before_write()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.catalogue_version := 1;
    new.created_at := now();
    new.updated_at := now();
    return new;
  end if;
  new.id := old.id;
  new.created_at := old.created_at;
  new.updated_at := now();
  if (new.registration_country, new.registration_scheme,
      new.registration_number, new.registrant,
      new.registered_product_name, new.product_category,
      new.form_type, new.active_ingredients,
      new.activity_groups, new.activity_group_scheme,
      new.registered_uses, new.viticulture_rates, new.label_rate_bases,
      new.label_reference, new.label_version,
      new.verification_status, new.verification_sources,
      new.verification_conflicts, new.verification_unresolved_fields,
      new.verified_at, new.activity_group_table_version,
      new.intelligence_schema_version)
     is distinct from
     (old.registration_country, old.registration_scheme,
      old.registration_number, old.registrant,
      old.registered_product_name, old.product_category,
      old.form_type, old.active_ingredients,
      old.activity_groups, old.activity_group_scheme,
      old.registered_uses, old.viticulture_rates, old.label_rate_bases,
      old.label_reference, old.label_version,
      old.verification_status, old.verification_sources,
      old.verification_conflicts, old.verification_unresolved_fields,
      old.verified_at, old.activity_group_table_version,
      old.intelligence_schema_version) then
    new.catalogue_version := old.catalogue_version + 1;
  else
    new.catalogue_version := old.catalogue_version;
  end if;
  return new;
end$$;

-- Remove the superseded competing trigger/function from any reviewed sandbox
-- where an earlier SQL 238 draft was tried.
drop trigger if exists zz_master_chemicals_v2_rate_revision on public.master_chemicals;
drop function if exists public.master_chemicals_v2_rate_revision();

-- SQL 238 intentionally performs no catalogue-rate projection or network work.
-- scripts/backfill_viticulture_rates.ts resolves current authoritative labels,
-- produces a reviewable report, and writes only when separately run --execute.

-- Search is intentionally separate from review_status and viticulture-only.
drop function if exists public.search_master_chemicals_v2(text, integer);
create function public.search_master_chemicals_v2(
  p_query text,
  p_limit integer default 25
)
returns table (
  id uuid,
  registration_country text,
  registration_scheme text,
  registration_number text,
  registrant text,
  registered_product_name text,
  common_names text[],
  product_category text,
  form_type text,
  active_ingredients jsonb,
  activity_groups text[],
  activity_group_scheme text,
  registered_uses jsonb,
  viticulture_rates jsonb,
  has_viticulture_evidence boolean,
  label_rate_bases text[],
  label_reference text,
  label_version text,
  verification_status text,
  verification_sources jsonb,
  verification_conflicts jsonb,
  verification_unresolved_fields text[],
  verified_at timestamptz,
  source_kind text,
  review_status text,
  catalogue_version integer,
  manufacturer_label_url text,
  manufacturer_product_url text,
  regulator_label_url text,
  search_rank integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_query text := left(btrim(coalesce(p_query, '')), 120);
  v_normal text;
  v_digits text;
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 50);
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.system_feature_flags f
    where f.key = 'chemical_search_v2' and f.is_enabled
  ) then
    raise exception 'Chemical Search V2 is disabled' using errcode = '42501';
  end if;
  if length(v_query) < 2 then return; end if;

  v_normal := regexp_replace(lower(v_query), '[^a-z0-9]+', '', 'g');
  v_digits := regexp_replace(v_query, '[^0-9]+', '', 'g');

  return query
  with viticulture_eligible as (
    select m.*, public.master_chemical_has_viticulture_evidence(m) as vineyard_evidence
    from public.master_chemicals m
    where public.master_chemical_is_v2_eligible(m)
  ), ranked as (
    select e.*,
      case
        when regexp_replace(lower(e.registered_product_name), '[^a-z0-9]+', '', 'g') = v_normal then 1
        when regexp_replace(lower(e.registered_product_name), '[^a-z0-9]+', '', 'g') like v_normal || '%' then 2
        when exists (
          select 1 from unnest(e.common_names) n
          where regexp_replace(lower(n), '[^a-z0-9]+', '', 'g') = v_normal
        ) then 3
        when regexp_replace(lower(e.registered_product_name), '[^a-z0-9]+', '', 'g') like '%' || v_normal || '%' then 4
        when v_digits <> '' and regexp_replace(e.registration_number, '[^0-9]+', '', 'g') = v_digits then 5
        when lower(coalesce(e.active_ingredients::text, '')) like '%' || lower(v_query) || '%'
          or lower(coalesce(e.registrant, '')) like '%' || lower(v_query) || '%' then 6
        else 99
      end as calculated_rank
    from viticulture_eligible e
    where e.vineyard_evidence
  )
  select r.id, r.registration_country, r.registration_scheme,
    r.registration_number, r.registrant, r.registered_product_name,
    r.common_names, r.product_category, r.form_type, r.active_ingredients,
    r.activity_groups, r.activity_group_scheme, r.registered_uses,
    r.viticulture_rates, r.vineyard_evidence,
    r.label_rate_bases, r.label_reference, r.label_version,
    r.verification_status, r.verification_sources,
    r.verification_conflicts, r.verification_unresolved_fields,
    r.verified_at, r.source_kind, r.review_status, r.catalogue_version,
    urls.manufacturer_label_url, urls.manufacturer_product_url,
    urls.regulator_label_url, r.calculated_rank
  from ranked r
  cross join lateral (
    select
      coalesce(
        (select s->>'reference'
           from jsonb_array_elements(coalesce(r.verification_sources, '[]'::jsonb)) s
          where s->>'kind' = 'manufacturer_label'
            and lower(coalesce(s->>'name','')) like '%label%'
            and coalesce(s->>'reference','') ~ '^https?://'
            and lower(s->>'reference') !~ '^https?://([^/]+\.)?(apvma\.gov\.au|[^/]+\.gov\.au)(/|$)'
          order by s->>'retrieved_at' desc nulls last limit 1),
        case when r.source_kind = 'manufacturer_label'
          and coalesce(r.source_reference,'') ~ '^https?://'
          and lower(r.source_reference) !~ '^https?://([^/]+\.)?(apvma\.gov\.au|[^/]+\.gov\.au)(/|$)'
          then r.source_reference end
      ) as manufacturer_label_url,
      (select s->>'reference'
         from jsonb_array_elements(coalesce(r.verification_sources, '[]'::jsonb)) s
        where (s->>'kind' in ('manufacturer_product','manufacturer_product_page')
               or lower(coalesce(s->>'name','')) like '%product page%')
          and coalesce(s->>'reference','') ~ '^https?://'
          and lower(s->>'reference') !~ '^https?://([^/]+\.)?(apvma\.gov\.au|[^/]+\.gov\.au)(/|$)'
        order by s->>'retrieved_at' desc nulls last limit 1) as manufacturer_product_url,
      case
        when coalesce(r.label_reference,'') ~ '^https?://'
         and lower(r.label_reference) ~ '^https?://([^/]+\.)?(apvma\.gov\.au|[^/]+\.gov\.au)(/|$)'
          then r.label_reference
        else coalesce(
          (select s->>'reference'
             from jsonb_array_elements(coalesce(r.verification_sources, '[]'::jsonb)) s
            where lower(coalesce(s->>'name','')) like '%label%'
              and coalesce(s->>'reference','') ~ '^https?://'
              and lower(s->>'reference') ~ '^https?://([^/]+\.)?(apvma\.gov\.au|[^/]+\.gov\.au)(/|$)'
            order by s->>'retrieved_at' desc nulls last limit 1),
          case when r.source_kind = 'manufacturer_label'
            and coalesce(r.source_reference,'') ~ '^https?://'
            and lower(r.source_reference) ~ '^https?://([^/]+\.)?(apvma\.gov\.au|[^/]+\.gov\.au)(/|$)'
            then r.source_reference end
        )
      end as regulator_label_url
  ) urls
  where r.calculated_rank < 99
  order by r.calculated_rank,
    length(r.registered_product_name), lower(r.registered_product_name),
    r.registration_number
  limit v_limit;
end;
$$;

revoke all on function public.search_master_chemicals_v2(text, integer) from public, anon;
grant execute on function public.search_master_chemicals_v2(text, integer) to authenticated;

alter table public.saved_chemicals
  add column if not exists entry_source text;

comment on column public.saved_chemicals.entry_source is
  'Origin of the vineyard-level chemical row. Chemical Search V2 writes master_catalogue_v2 or label_lookup_v2; null remains valid for all legacy rows.';

create table if not exists public.saved_chemical_attachments (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  saved_chemical_id uuid not null references public.saved_chemicals(id) on delete cascade,
  storage_path text not null unique,
  kind text not null default 'label_photo' check (kind in ('label_photo')),
  status text not null default 'ready' check (status in ('ready', 'upload_failed')),
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint saved_chemical_attachment_path_scope check (
    split_part(storage_path, '/', 1) = vineyard_id::text
    and split_part(storage_path, '/', 2) = saved_chemical_id::text
  )
);

create index if not exists saved_chemical_attachments_chemical_idx
  on public.saved_chemical_attachments(vineyard_id, saved_chemical_id)
  where deleted_at is null;

alter table public.saved_chemical_attachments enable row level security;

drop policy if exists saved_chemical_attachments_member_read on public.saved_chemical_attachments;
create policy saved_chemical_attachments_member_read
  on public.saved_chemical_attachments for select to authenticated
  using (public.is_vineyard_member(vineyard_id));

drop policy if exists saved_chemical_attachments_member_insert on public.saved_chemical_attachments;
create policy saved_chemical_attachments_member_insert
  on public.saved_chemical_attachments for insert to authenticated
  with check (
    public.has_vineyard_role(vineyard_id, array['owner','manager'])
    and created_by = auth.uid()
    and exists (
      select 1 from public.saved_chemicals c
      where c.id = saved_chemical_id and c.vineyard_id = vineyard_id
    )
  );

drop policy if exists saved_chemical_attachments_member_update on public.saved_chemical_attachments;
create policy saved_chemical_attachments_member_update
  on public.saved_chemical_attachments for update to authenticated
  using (public.has_vineyard_role(vineyard_id, array['owner','manager']))
  with check (public.has_vineyard_role(vineyard_id, array['owner','manager']));

drop policy if exists saved_chemical_attachments_manager_delete on public.saved_chemical_attachments;
create policy saved_chemical_attachments_manager_delete
  on public.saved_chemical_attachments for delete to authenticated
  using (public.has_vineyard_role(vineyard_id, array['owner','manager']));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chemical-label-photos', 'chemical-label-photos', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp']::text[])
on conflict (id) do update set
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']::text[];

drop policy if exists chemical_label_photos_member_read on storage.objects;
create policy chemical_label_photos_member_read on storage.objects
for select to authenticated using (
  bucket_id = 'chemical-label-photos'
  and public.is_vineyard_member((storage.foldername(name))[1]::uuid)
);

drop policy if exists chemical_label_photos_member_insert on storage.objects;
create policy chemical_label_photos_member_insert on storage.objects
for insert to authenticated with check (
  bucket_id = 'chemical-label-photos'
  and public.has_vineyard_role((storage.foldername(name))[1]::uuid, array['owner','manager'])
);

drop policy if exists chemical_label_photos_member_update on storage.objects;
create policy chemical_label_photos_member_update on storage.objects
for update to authenticated using (
  bucket_id = 'chemical-label-photos'
  and public.has_vineyard_role((storage.foldername(name))[1]::uuid, array['owner','manager'])
) with check (
  bucket_id = 'chemical-label-photos'
  and public.has_vineyard_role((storage.foldername(name))[1]::uuid, array['owner','manager'])
);

drop policy if exists chemical_label_photos_member_delete on storage.objects;
create policy chemical_label_photos_member_delete on storage.objects
for delete to authenticated using (
  bucket_id = 'chemical-label-photos'
  and public.has_vineyard_role((storage.foldername(name))[1]::uuid, array['owner','manager'])
);

commit;

-- Post-apply V2 cohort report (read-only). Run after this transaction commits.
with cohort as (
  select m.*, public.master_chemical_has_viticulture_evidence(m) as has_vineyard_evidence
  from public.master_chemicals m
  where public.master_chemical_is_v2_eligible(m)
)
select
  count(*) as v2_eligible_products,
  count(*) filter (where has_vineyard_evidence) as vineyard_evidence_products,
  count(*) filter (where jsonb_array_length(coalesce(viticulture_rates->'per_hectare','[]'::jsonb)) > 0) as per_hectare_products,
  count(*) filter (where jsonb_array_length(coalesce(viticulture_rates->'per_100_litres','[]'::jsonb)) > 0) as per_100_litres_products,
  count(*) filter (where jsonb_array_length(coalesce(viticulture_rates->'per_hectare','[]'::jsonb)) > 0 and jsonb_array_length(coalesce(viticulture_rates->'per_100_litres','[]'::jsonb)) > 0) as both_bases_products,
  count(*) filter (where has_vineyard_evidence and jsonb_array_length(coalesce(viticulture_rates->'per_hectare','[]'::jsonb)) = 0 and jsonb_array_length(coalesce(viticulture_rates->'per_100_litres','[]'::jsonb)) = 0) as vineyard_evidence_without_rate
from cohort;

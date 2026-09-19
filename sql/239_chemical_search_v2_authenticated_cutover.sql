-- Chemical Search V2 production authorization cutover.
-- Keeps the existing search/result contract and changes only the caller gate:
-- authenticated + chemical_search_v2 enabled. Vineyard save permissions remain
-- enforced independently by the existing saved_chemicals rules and RLS.

begin;

create or replace function public.search_master_chemicals_v2(
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
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
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

comment on function public.search_master_chemicals_v2(text, integer) is
  'Searches eligible immutable Master chemical reference data for authenticated users only while chemical_search_v2 is enabled; vineyard save authority remains separate.';

commit;

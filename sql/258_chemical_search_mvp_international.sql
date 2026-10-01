-- Review/apply separately. No Master rows, rates, approvals, or flags are changed.
-- The existing authenticated RPC (SQL 256) retains its signature and ranking.
begin;

create or replace function public.master_chemical_is_v2_eligible(m public.master_chemicals)
returns boolean language sql stable set search_path = public as $$
  select auth.uid() is not null and (
    m.review_status = 'approved'
    or (m.review_status = 'candidate' and public.is_system_admin())
  )
$$;

create or replace function public.master_chemical_has_viticulture_evidence(m public.master_chemicals)
returns boolean language sql stable set search_path = public as $$
  select exists (
    select 1 from jsonb_array_elements(coalesce(m.registered_uses, '[]'::jsonb)) u
    where lower(coalesce(u->>'crop', '')) ~
      '(^|[^a-z])(vines?|vineyards?|grapevines?|grapes?|wine[[:space:]-]*grapes?|table[[:space:]-]*grapes?|dried[[:space:]-]*grapes?)([^a-z]|$)'
  ) or exists (
    select 1 from jsonb_array_elements(
      coalesce(m.viticulture_rates->'per_hectare', '[]'::jsonb) ||
      coalesce(m.viticulture_rates->'per_100_litres', '[]'::jsonb)
    ) r
    where r->>'basis' in ('per_hectare','range_per_hectare','per_100_litres','range_per_100_litres')
      and (coalesce(r->>'value','') ~ '^[0-9]+([.][0-9]+)?$'
        or (coalesce(r->>'min_value','') ~ '^[0-9]+([.][0-9]+)?$'
          and coalesce(r->>'max_value','') ~ '^[0-9]+([.][0-9]+)?$'))
  )
$$;

comment on function public.master_chemical_is_v2_eligible(public.master_chemicals) is
  'International MVP visibility: authenticated approved rows; candidates only for current System Admin. Registration and adapters are optional.';
comment on function public.master_chemical_has_viticulture_evidence(public.master_chemicals) is
  'Structured vineyard/grape crop evidence or actual vineyard numeric rates. Generic reference URLs do not confer vineyard relevance or operational rates.';

commit;

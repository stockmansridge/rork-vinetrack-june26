-- SQL 264: shared financial authority for chemical seasonal costing.
-- MANUAL application only. Requires inventory purchases and SQL 119 vintage resolution.
-- No record rewrites, carry-forward, FX, inventory changes or permission changes.
begin;
create or replace function public.chemical_season_purchase_prices(
  p_vineyard_id uuid, p_vintage integer, p_as_of date default null
) returns table (
  saved_chemical_id uuid, vintage integer, weighted_cost_per_base_unit numeric,
  base_unit text, currency text, purchase_count bigint,
  total_quantity_base numeric, total_purchase_cost numeric,
  pricing_basis text, warning text
)
language plpgsql security definer set search_path = public, pg_temp
as $fn$
begin
  if auth.uid() is null or coalesce(public.vineyard_role(p_vineyard_id), '') not in ('owner','manager') then
    raise exception 'Owner or Manager financial access required' using errcode = '42501';
  end if;
  if p_vintage is null then raise exception 'Vintage required' using errcode = '22023'; end if;
  return query
  with purchases as (
    select p.saved_chemical_id,
      case lower(btrim(p.unit)) when 'l' then p.quantity * 1000 when 'ml' then p.quantity
        when 'kg' then p.quantity * 1000 when 'g' then p.quantity end as qty,
      case lower(btrim(p.unit)) when 'l' then 'mL' when 'ml' then 'mL'
        when 'kg' then 'g' when 'g' then 'g' end as canonical_unit,
      nullif(upper(btrim(p.currency)), '') as purchase_currency, p.total_cost
    from public.chemical_inventory_purchases p
    join public.saved_chemicals c on c.id = p.saved_chemical_id
    where c.vineyard_id = p_vineyard_id
      and public.resolve_vineyard_vintage_year(p_vineyard_id, p.purchase_date) = p_vintage
      and (p_as_of is null or p.purchase_date <= p_as_of)
  ), grouped as (
    select p.saved_chemical_id, count(*) as n, sum(p.qty) as qty, sum(p.total_cost) as cost,
      min(p.canonical_unit) as unit, min(p.purchase_currency) as curr,
      count(distinct p.canonical_unit) as dimensions, count(distinct p.purchase_currency) as currencies,
      bool_or(p.qty is null or not (p.qty > 0 and p.qty < 'Infinity'::numeric)
        or p.total_cost is null or not (p.total_cost >= 0 and p.total_cost < 'Infinity'::numeric)
        or p.purchase_currency is null) as invalid
    from purchases p group by p.saved_chemical_id
  ), resolved as (
    select c.id, g.*, case
      when g.n is null then 'season_purchase_cost_unavailable'
      when g.invalid then 'invalid_purchase_data'
      when g.dimensions <> 1 then 'physical_dimension_conflict'
      when g.currencies <> 1 then 'currency_conflict'
      else 'season_weighted_purchase_average' end as basis
    from public.saved_chemicals c left join grouped g on g.saved_chemical_id = c.id
    where c.vineyard_id = p_vineyard_id
    -- Include archived chemicals: historical sprays may still use them.
  )
  select r.id, p_vintage,
    case when r.basis = 'season_weighted_purchase_average' then r.cost / r.qty end,
    case when r.dimensions = 1 then r.unit end,
    case when r.currencies = 1 then r.curr end, coalesce(r.n, 0),
    case when r.dimensions = 1 and not r.invalid then r.qty end,
    case when r.currencies = 1 and not r.invalid then r.cost end,
    r.basis, case r.basis
      when 'season_purchase_cost_unavailable' then 'Season purchase cost unavailable.'
      when 'currency_conflict' then 'Multiple purchase currencies; no FX conversion applied.'
      when 'physical_dimension_conflict' then 'Volume and mass purchases cannot be averaged.'
      when 'invalid_purchase_data' then 'Purchase quantity, unit, currency or cost is invalid.' end
  from resolved r order by r.id;
end;
$fn$;
revoke all on function public.chemical_season_purchase_prices(uuid,integer,date) from public, anon;
grant execute on function public.chemical_season_purchase_prices(uuid,integer,date) to authenticated;
notify pgrst, 'reload schema';
commit;

-- 234: repair canonical spray report chemical-total aggregation exposed by SQL 233 behavior coverage.
-- SQL 233 is already deployed; this additive migration changes no public signature or report schema.
begin;
select pg_advisory_xact_lock(hashtext('vinetrack:spray-report-chemical-aggregate-fix-v1'));

-- Normalize JSON fields before grouping. The previous report query selected a
-- display-unit CASE over x.value while grouping only by a different dimension
-- CASE, which PostgreSQL correctly rejected at execution with SQLSTATE 42803.
create or replace function public.spray_report_planned_chemical_totals_v1(p_tanks jsonb)
returns jsonb
language sql
immutable
set search_path=public
as $fn$
  with normalized as (
    select
      coalesce(
        chemical->>'savedChemicalId',
        chemical->>'saved_chemical_id',
        lower(btrim(chemical->>'name')) || '|' ||
          case when coalesce(chemical->>'unit', 'Litres') in ('Litres', 'mL') then 'liquid' else 'mass' end
      ) as identity_key,
      coalesce(chemical->>'name', 'Unnamed chemical') as chemical_name,
      case when coalesce(chemical->>'unit', 'Litres') in ('Litres', 'mL') then 'liquid' else 'mass' end as dimension,
      coalesce(
        public.spray_report_safe_number_v1(chemical->>'volumePerTank')::numeric,
        public.spray_report_safe_number_v1(chemical->>'volume_per_tank')::numeric,
        0
      ) as amount_base
    from jsonb_array_elements(coalesce(p_tanks, '[]'::jsonb)) tank
    cross join lateral jsonb_array_elements(coalesce(tank->'chemicals', '[]'::jsonb)) chemical
  ), grouped as (
    select
      identity_key,
      min(chemical_name) as chemical_name,
      dimension,
      sum(amount_base) as total
    from normalized
    group by identity_key, dimension
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'identityKey', identity_key,
        'name', chemical_name,
        'unit', case when dimension='liquid' then 'Litres' else 'Kg' end,
        'actualAmountBase', total
      )
      order by lower(chemical_name), dimension
    ),
    '[]'::jsonb
  )
  from grouped
$fn$;

create or replace function public.spray_report_actual_chemical_totals_v1(p_tanks jsonb)
returns jsonb
language sql
immutable
set search_path=public
as $fn$
  with normalized as (
    select
      coalesce(
        chemical->>'savedChemicalId',
        lower(btrim(chemical->>'name')) || '|' ||
          case when chemical->>'unit' in ('Litres', 'mL') then 'liquid' else 'mass' end
      ) as identity_key,
      coalesce(chemical->>'name', 'Unnamed chemical') as chemical_name,
      case when chemical->>'unit' in ('Litres', 'mL') then 'liquid' else 'mass' end as dimension,
      public.spray_report_safe_number_v1(chemical->>'actualAmountBase')::numeric as amount_base
    from jsonb_array_elements(coalesce(p_tanks, '[]'::jsonb)) tank
    cross join lateral jsonb_array_elements(coalesce(tank->'chemicals', '[]'::jsonb)) chemical
    where chemical->'actualAmountBase' <> 'null'::jsonb
  ), grouped as (
    select
      identity_key,
      min(chemical_name) as chemical_name,
      dimension,
      sum(amount_base) as total
    from normalized
    group by identity_key, dimension
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'identityKey', identity_key,
        'name', chemical_name,
        'unit', case when dimension='liquid' then 'Litres' else 'Kg' end,
        'actualAmountBase', total
      )
      order by lower(chemical_name), dimension
    ),
    '[]'::jsonb
  )
  from grouped
$fn$;

-- Preserve the deployed report wrapper chain and every other canonical-report
-- behavior. Replace only the two invalid aggregate statements in the hidden
-- canonical-facts layer installed by SQL 228 and renamed by SQL 229.
do $patch$
declare
  v_definition text;
  v_old_planned text := $old$
  select coalesce(jsonb_agg(jsonb_build_object('identityKey',identity_key,'name',name,'unit',display_unit,'actualAmountBase',total) order by lower(name),dimension),'[]') into planned_totals from (
    select coalesce(x->>'savedChemicalId',x->>'saved_chemical_id',lower(btrim(x->>'name'))||'|'||case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end) identity_key,
      min(coalesce(x->>'name','Unnamed chemical')) name,case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end dimension,
      case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'Litres' else 'Kg' end display_unit,
      sum(coalesce(public.spray_report_safe_number_v1(x->>'volumePerTank')::numeric,public.spray_report_safe_number_v1(x->>'volume_per_tank')::numeric,0)) total
    from jsonb_array_elements(coalesce(r.tanks,'[]')) tank cross join lateral jsonb_array_elements(coalesce(tank->'chemicals','[]')) x
    group by coalesce(x->>'savedChemicalId',x->>'saved_chemical_id',lower(btrim(x->>'name'))||'|'||case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end),case when coalesce(x->>'unit','Litres') in ('Litres','mL') then 'liquid' else 'mass' end
  ) q;$old$;
  v_old_actual text := $old$
  select coalesce(jsonb_agg(jsonb_build_object('identityKey',identity_key,'name',name,'unit',display_unit,'actualAmountBase',total) order by lower(name),dimension),'[]') into actual_totals from (
    select coalesce(x->>'savedChemicalId',lower(btrim(x->>'name'))||'|'||case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end) identity_key,
      min(coalesce(x->>'name','Unnamed chemical')) name,case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end dimension,
      case when x->>'unit' in ('Litres','mL') then 'Litres' else 'Kg' end display_unit,sum(public.spray_report_safe_number_v1(x->>'actualAmountBase')::numeric) total
    from jsonb_array_elements(payload->'tanks') tank cross join lateral jsonb_array_elements(tank->'chemicals') x
    where x->'actualAmountBase' <> 'null'::jsonb
    group by coalesce(x->>'savedChemicalId',lower(btrim(x->>'name'))||'|'||case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end),case when x->>'unit' in ('Litres','mL') then 'liquid' else 'mass' end
  ) q;$old$;
begin
  if to_regprocedure('public.get_spray_report_v1_pre_weather_provenance_v1(uuid)') is null then
    raise exception 'Expected SQL 229 canonical report layer is missing; SQL 234 made no changes';
  end if;

  v_definition := pg_get_functiondef('public.get_spray_report_v1_pre_weather_provenance_v1(uuid)'::regprocedure);

  if position(v_old_planned in v_definition)=0 then
    if position('spray_report_planned_chemical_totals_v1' in v_definition)=0 then
      raise exception 'Canonical planned-chemical aggregate does not match the expected deployed definition; SQL 234 made no changes';
    end if;
  else
    v_definition := replace(
      v_definition,
      v_old_planned,
      E'\n  planned_totals:=public.spray_report_planned_chemical_totals_v1(r.tanks);'
    );
  end if;

  if position(v_old_actual in v_definition)=0 then
    if position('spray_report_actual_chemical_totals_v1' in v_definition)=0 then
      raise exception 'Canonical actual-chemical aggregate does not match the expected deployed definition; SQL 234 made no changes';
    end if;
  else
    v_definition := replace(
      v_definition,
      v_old_actual,
      E'\n  actual_totals:=public.spray_report_actual_chemical_totals_v1(payload->''tanks'');'
    );
  end if;

  execute v_definition;
end
$patch$;

revoke all on function public.spray_report_planned_chemical_totals_v1(jsonb) from public,anon,authenticated;
revoke all on function public.spray_report_actual_chemical_totals_v1(jsonb) from public,anon,authenticated;
revoke all on function public.get_spray_report_v1_pre_weather_provenance_v1(uuid) from public,anon,authenticated;

commit;

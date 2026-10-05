"""SQL 264 focused rollback checks, disposable local database only."""
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = (root / 'sql/119_vintage_year_assignment.sql').read_text()
def definition(name):
    start = source.index('create or replace function public.' + name + '(')
    tag_match = re.search(r'\bas\s+(\$\w*\$)', source[start:], re.I)
    tag = tag_match.group(1)
    end = source.index(tag, start + tag_match.end()) + len(tag)
    return source[start:end] + ';'

# Focused source contracts complement the behavioral SQL/mobile tests.
android = root / 'android-vinetrack/app/src/main/java/com/rork/vinetrack'
ios = root / 'ios/VineTrack'
for path in [android / 'ui/screens/ChemicalsScreen.kt', ios / 'LegacyImported/Views/SprayManagement/SprayPresetsView.swift']:
    text = path.read_text()
    for label in ['Spray costing settings (optional)', 'Spray costing snapshot', 'Use purchase cost snapshot']:
        assert label not in text, (path, label)
    assert 'Inventory & purchase' in text and 'View Inventory' in text and 'Record Purchase' in text
for path in [android / 'data/TripCostEstimator.kt', ios / 'LegacyImported/Services/TripCostService.swift']:
    text = path.read_text()
    assert 'legacy_stored_spray_snapshot' in text and 'season_weighted_purchase_average' in text
    assert 'purchase.costPerBaseUnit' not in text
print('Source contracts passed: removed pricing UI, existing inventory actions, separate seasonal/legacy bases, no editor-purchase costing fallback.')

sql = """
begin;
do $$ begin
 if current_database() <> 'yield_contract_test' or inet_server_addr() is not null
 or to_regclass('public.paddocks') is not null then raise exception 'Local empty fixture required'; end if;
end $$;
create schema auth;
create function auth.uid() returns uuid language sql as $$ select '00000000-0000-0000-0000-000000000001'::uuid $$;
create function public.vineyard_role(uuid) returns text language sql as $$ select current_setting('test.role',true) $$;
create table public.vineyards(id uuid, season_start_month int, season_start_day int);
create table public.saved_chemicals(id uuid, vineyard_id uuid);
create table public.chemical_inventory_purchases(saved_chemical_id uuid, purchase_date date, quantity numeric, unit text, quantity_base numeric, base_unit text, total_cost numeric, currency text);
insert into public.vineyards values ('00000000-0000-0000-0000-000000000002',7,1);
insert into public.saved_chemicals values ('00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002');
select set_config('test.role','owner',true);
"""
sql += definition('resolve_vintage_year') + definition('resolve_vineyard_vintage_year')
migration = (root / 'sql/264_chemical_season_weighted_purchase_prices.sql').read_text()
migration = re.sub(r'^begin;\s*$|^commit;\s*$', '', migration, flags=re.M)
sql += migration + migration
sql += """
do $$ declare
 v uuid := '00000000-0000-0000-0000-000000000002';
 c uuid := '00000000-0000-0000-0000-000000000003';
 r record;
begin
 select * into r from public.chemical_season_purchase_prices(v,2027);
 if r.pricing_basis <> 'season_purchase_cost_unavailable' or r.weighted_cost_per_base_unit is not null then raise exception 'No purchase'; end if;
 insert into public.chemical_inventory_purchases values(c,'2026-09-01',20,'L',20000,'mL',100,'AUD');
 select * into r from public.chemical_season_purchase_prices(v,2027);
 if r.weighted_cost_per_base_unit <> 0.005 or r.base_unit <> 'mL' then raise exception 'One purchase'; end if;
 insert into public.chemical_inventory_purchases values(c,'2026-12-01',10000,'mL',10000,'mL',80,'AUD');
 select * into r from public.chemical_season_purchase_prices(v,2027);
 if r.weighted_cost_per_base_unit <> 0.006 or r.total_quantity_base <> 30000 or r.total_purchase_cost <> 180 or r.purchase_count <> 2 then raise exception 'Weighted volume'; end if;
 select * into r from public.chemical_season_purchase_prices(v,2027,'2026-09-30');
 if r.weighted_cost_per_base_unit <> 0.005 or r.purchase_count <> 1 then raise exception 'Season to date'; end if;
 insert into public.chemical_inventory_purchases values(c,'2026-06-30',100,'L',100000,'mL',999,'AUD');
 select * into r from public.chemical_season_purchase_prices(v,2027);
 if r.purchase_count <> 2 then raise exception 'Prior season included'; end if;
 if public.resolve_vineyard_vintage_year(v,'2026-06-30') <> 2026 or public.resolve_vineyard_vintage_year(v,'2026-07-01') <> 2027 then raise exception 'Boundary'; end if;
 insert into public.chemical_inventory_purchases values(c,'2026-10-01',1,'L',1000,'mL',5,'USD');
 select * into r from public.chemical_season_purchase_prices(v,2027);
 if r.pricing_basis <> 'currency_conflict' or r.weighted_cost_per_base_unit is not null or r.total_purchase_cost is not null then raise exception 'Currency conflict'; end if;
 delete from public.chemical_inventory_purchases;
 insert into public.chemical_inventory_purchases values(c,'2026-09-01',20,'kg',20000,'g',100,'AUD'),(c,'2026-10-01',10000,'g',10000,'g',80,'AUD');
 select * into r from public.chemical_season_purchase_prices(v,2027);
 if r.weighted_cost_per_base_unit <> 0.006 or r.base_unit <> 'g' then raise exception 'Weighted mass'; end if;
 insert into public.chemical_inventory_purchases values(c,'2026-10-01',1,'L',1000,'mL',5,'AUD');
 select * into r from public.chemical_season_purchase_prices(v,2027);
 if r.pricing_basis <> 'physical_dimension_conflict' or r.weighted_cost_per_base_unit is not null then raise exception 'Dimension conflict'; end if;
 delete from public.chemical_inventory_purchases;
 insert into public.chemical_inventory_purchases values(c,'2026-09-01',1,'L',1000,'mL',0,'AUD');
 select * into r from public.chemical_season_purchase_prices(v,2027);
 if r.weighted_cost_per_base_unit is distinct from 0::numeric or r.pricing_basis <> 'season_weighted_purchase_average' then raise exception 'Free purchase'; end if;
 perform set_config('test.role','manager',true);
 perform * from public.chemical_season_purchase_prices(v,2027);
 perform set_config('test.role','supervisor',true);
 begin perform * from public.chemical_season_purchase_prices(v,2027); raise exception 'Supervisor allowed'; exception when insufficient_privilege then null; end;
 perform set_config('test.role','operator',true);
 begin perform * from public.chemical_season_purchase_prices(v,2027); raise exception 'Operator allowed'; exception when insufficient_privilege then null; end;
 if has_function_privilege('anon','public.chemical_season_purchase_prices(uuid,integer,date)','execute') then raise exception 'Anonymous access'; end if;
 raise notice 'SQL 264 passed: no purchases, exact price, weighted volume/mass, season-to-date, season boundary/exclusion, currency/dimension conflicts, zero cost, owner/manager and supervisor/operator/anonymous privacy, idempotence.';
end $$;
rollback;
"""
result = subprocess.run(['sudo','-u','postgres','psql','-X','-h','/var/run/postgresql','-U','postgres','-d','yield_contract_test','-v','ON_ERROR_STOP=1'], input=sql,text=True,capture_output=True)
print(result.stdout)
print(result.stderr,file=sys.stderr)
sys.exit(result.returncode)

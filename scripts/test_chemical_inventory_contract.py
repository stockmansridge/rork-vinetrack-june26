"""Local-only PostgreSQL inventory contract check against read-only live-definition exports.

Usage: python scripts/test_chemical_inventory_contract.py /tmp/inventory-live-schema.json /tmp/inventory-live-functions.json
Requires a disposable LOCAL database named inventory_contract_test and peer-auth postgres.
Never connects to Supabase or applies SQL to production. Tables are reconstructed from
inspected column metadata (not a full production RLS/trigger/FK clone).
"""
import json
import re
import subprocess
import sys
from pathlib import Path

schema = json.loads(Path(sys.argv[1]).read_text())[0]["jsonb_build_object"]
functions = json.loads(Path(sys.argv[2]).read_text())
setup = """
-- Refuse before any fixture DDL unless this is the dedicated local socket database.
do $$ begin
if current_database() <> 'inventory_contract_test' or inet_server_addr() is not null then
  raise exception 'Inventory contract fixtures require the local inventory_contract_test database';
end if;
end $$;
select set_config('request.inventory_contract_runner','local-fixture',false);
do $$ begin
if not exists(select 1 from pg_roles where rolname='anon') then create role anon; end if;
if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
end $$;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$
select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
create function public.is_system_admin() returns boolean language sql stable as $$
select coalesce(current_setting('request.test_admin',true),'false')::boolean $$;
create table public.vineyards(id uuid primary key, name text not null);
create table public.saved_chemicals(id uuid primary key, vineyard_id uuid references public.vineyards(id), deleted_at timestamptz,
product_form text, purchase jsonb, updated_at timestamptz);
create table public.vineyard_members(vineyard_id uuid,user_id uuid,role text);
create function public.vineyard_role(p_vineyard_id uuid) returns text language sql stable security definer
set search_path=public as $$ select vm.role from public.vineyard_members vm
where vm.vineyard_id=p_vineyard_id and vm.user_id=auth.uid() limit 1 $$;
create function public.has_vineyard_role(p_vineyard_id uuid,allowed_roles text[]) returns boolean
language sql stable security definer set search_path=public as $$
select coalesce(public.vineyard_role(p_vineyard_id)=any(allowed_roles),false) $$;
create table public.spray_tank_actuals(deleted_at timestamptz,confirmed_at timestamptz,chemicals jsonb);
"""
for table in sorted({c["table_name"] for c in schema["columns"]}):
    cols = []
    for c in schema["columns"]:
        if c["table_name"] != table:
            continue
        definition = c["column_name"] + " " + c["data_type"]
        if c["column_default"]:
            definition += " default " + c["column_default"]
        if c["is_nullable"] == "NO":
            definition += " not null"
        cols.append(definition)
    primary = "saved_chemical_id" if table.endswith("settings") else "id"
    cols.append("primary key (" + primary + ")")
    setup += "create table public." + table + "(" + ",".join(cols) + ");\n"
for policy in schema["policies"]:
    setup += "alter table public." + policy["tablename"] + " enable row level security;\n"
    setup += "create policy " + policy["policyname"] + " on public." + policy["tablename"] + " for all using (" + policy["qual"] + ") with check (" + policy["with_check"] + ");\n"
# SQL functions depend on unit helpers: order explicitly, then plpgsql routines.
priority = ["chemical_inventory_canonical_unit", "chemical_inventory_base_unit", "chemical_inventory_to_base"]
for fn in sorted(functions, key=lambda f: priority.index(f["proname"]) if f["proname"] in priority else 99):
    setup += fn["definition"] + ";\n"
setup += """
-- Retain the original summary as a test-only comparator; its body is unmodified.
"""
summary = next(f["definition"] for f in functions if f["proname"] == "chemical_inventory_summary")
setup += summary.replace("public.chemical_inventory_summary(", "public.inventory_test_original_summary(", 1) + ";\n"
root = Path(__file__).resolve().parent.parent
ios_fields = (root / "ios/VineTrack/App/ChemicalIntelligence/ChemicalInventoryTraceability.swift").read_text()
android_fields = (root / "android-vinetrack/app/src/main/java/com/rork/vinetrack/data/chemical/ChemicalInventoryTraceability.kt").read_text()
expected = {"p_batch_number", "p_batch_date", "p_serial_number"}
assert set(re.findall(r'"(p_[a-z_]+)"', ios_fields)) == expected
assert set(re.findall(r'"(p_[a-z_]+)"', android_fields)) == expected
print("PASS: iOS and Android production helpers expose identical RPC traceability keys")
migration = (root / "sql/261_chemical_inventory_traceability_owner_manager.sql").read_text()
setup += migration + "\n" + migration + "\n"
setup += (root / "sql/tests/261_chemical_inventory_traceability_tests.sql").read_text()
result = subprocess.run(["sudo", "-u", "postgres", "psql", "-X", "-h", "/var/run/postgresql", "-p", "5432", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-d", "inventory_contract_test"],
                        input=setup, text=True, capture_output=True)
print(result.stdout)
print(result.stderr, file=sys.stderr)
sys.exit(result.returncode)

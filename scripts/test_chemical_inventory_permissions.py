"""SQL 262 LOCAL disposable contract runner; never applies/reruns SQL 261.

Usage: python scripts/test_chemical_inventory_permissions.py /tmp/inventory-262-live-schema.json /tmp/inventory-262-live-functions.json
Inputs must be read-only schema/function exports AFTER production SQL 261.
Requires an EMPTY local inventory_contract_test database with peer-auth postgres.
This fixture reproduces the vineyard FK and inventory RLS, not every production trigger/FK.
"""
import json
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
schema = json.loads(Path(sys.argv[1]).read_text())[0]["jsonb_build_object"]
functions = json.loads(Path(sys.argv[2]).read_text())
purchase = next(f["definition"] for f in functions if f["proname"] == "chemical_inventory_record_purchase_v2")
assert "p_batch_date date DEFAULT" in purchase and "chemical_inventory_require_manager" in purchase, "Expected post-261 definitions"
setup = """
do $$ begin
  if current_database()<>'inventory_contract_test' or inet_server_addr() is not null then
    raise exception 'Only the disposable local inventory_contract_test database is supported';
  end if;
  if to_regclass('public.saved_chemicals') is not null then raise exception 'Requires an empty disposable database'; end if;
end $$;
select set_config('request.inventory_contract_runner','local-fixture',false);
do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
end $$;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
create function public.is_system_admin() returns boolean language sql stable as $$ select coalesce(current_setting('request.test_admin',true),'false')::boolean $$;
create table public.vineyards(id uuid primary key, name text not null);
create table public.saved_chemicals(id uuid primary key, vineyard_id uuid references public.vineyards(id), deleted_at timestamptz, product_form text, purchase jsonb, updated_at timestamptz);
create table public.vineyard_members(vineyard_id uuid references public.vineyards(id),user_id uuid,role text);
create table public.spray_tank_actuals(deleted_at timestamptz,confirmed_at timestamptz,chemicals jsonb);
grant usage on schema auth, public to authenticated;
grant select on public.saved_chemicals to authenticated;
"""
for table in sorted({c["table_name"] for c in schema["columns"]}):
    assert table in {"chemical_inventory_purchases", "chemical_inventory_stocktakes", "chemical_inventory_settings"}
    cols = []
    for c in schema["columns"]:
        if c["table_name"] != table:
            continue
        definition = c["column_name"] + " " + c["data_type"]
        if c["column_default"]:
            definition += " default " + c["column_default"]
        if c["is_nullable"] == "NO":
            definition += " not null"
        if c["column_name"] == "vineyard_id":
            definition += " references public.vineyards(id)"
        if c["column_name"] == "saved_chemical_id":
            definition += " references public.saved_chemicals(id)"
        cols.append(definition)
    cols.append("primary key (" + ("saved_chemical_id" if table.endswith("settings") else "id") + ")")
    setup += "create table public." + table + "(" + ",".join(cols) + ");\n"
priority = ["vineyard_role", "has_vineyard_role", "chemical_inventory_canonical_unit", "chemical_inventory_base_unit", "chemical_inventory_to_base"]
for fn in sorted(functions, key=lambda f: priority.index(f["proname"]) if f["proname"] in priority else 99):
    setup += fn["definition"] + ";\n"
for policy in schema["policies"]:
    setup += "alter table public." + policy["tablename"] + " enable row level security;\n"
    setup += "create policy " + policy["policyname"] + " on public." + policy["tablename"] + " for " + policy["cmd"].lower() + " to authenticated"
    if policy["qual"]:
        setup += " using (" + policy["qual"] + ")"
    if policy["with_check"]:
        setup += " with check (" + policy["with_check"] + ")"
    setup += ";\n"
    setup += "grant select on public." + policy["tablename"] + " to authenticated;\n"
for name in ["chemical_inventory_summary", "chemical_inventory_purchase_history_v2"]:
    original = next(f["definition"] for f in functions if f["proname"] == name)
    setup += original.replace("public." + name + "(", "public.inventory_test_original_" + name + "(", 1) + ";\n"
setup += "create table inventory_test_signatures as select p.proname,pg_get_function_arguments(p.oid) args,pg_get_function_result(p.oid) result from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'chemical_inventory_%';\n"
migration = (root / "sql/262_chemical_inventory_member_permissions_cost_privacy.sql").read_text()
setup += migration + "\n" + migration + "\n"
setup += (root / "sql/tests/262_chemical_inventory_permissions_tests.sql").read_text()
result = subprocess.run(["sudo", "-u", "postgres", "psql", "-X", "-h", "/var/run/postgresql", "-p", "5432", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-d", "inventory_contract_test"], input=setup, text=True, capture_output=True)
print(result.stdout)
print(result.stderr, file=sys.stderr)
sys.exit(result.returncode)

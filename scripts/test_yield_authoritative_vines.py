"""Focused SQL 263 runner against a disposable LOCAL PostgreSQL database only.

Usage: python scripts/test_yield_authoritative_vines.py
Requires an empty local yield_contract_test database (peer-auth postgres).
Loads real SQL 221 calculator/refresh and supporting production functions, not
copied calculations. Minimal table fixture omits unrelated production triggers/RLS.
Everything, including applying SQL 263 twice, runs inside a rolled-back transaction.
Never connects to a production URL or uses environment credentials.
"""
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent


def function(path: str, name: str) -> str:
    source = (root / path).read_text()
    match = re.search(r"create or replace function public\." + re.escape(name) + r"\s*\(", source, re.I)
    if match is None:
        raise ValueError(f"Missing production function {name}")
    start = match.start()
    delimiter = re.search(r"\bas\s+(\$\w*\$)", source[start:], re.I)
    if delimiter is None:
        raise ValueError(f"Missing body delimiter {name}")
    body_start = start + delimiter.end()
    tag = delimiter.group(1)
    end = source.index(tag, body_start) + len(tag)
    return source[start:end] + ";\n"

setup = """
begin;
do $$ begin
  if current_database() <> 'yield_contract_test' or inet_server_addr() is not null then
    raise exception 'Only the disposable LOCAL yield_contract_test database is supported';
  end if;
  if to_regclass('public.paddocks') is not null then raise exception 'Requires an empty database'; end if;
end $$;
do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
end $$;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
create table auth.users(id uuid primary key);
create table public.vineyards(id uuid primary key, timezone text, season_start_month int, season_start_day int);
create table public.paddocks(id uuid primary key, vineyard_id uuid references public.vineyards(id),
 name text, polygon_points jsonb, rows jsonb, vine_spacing double precision, vine_count_override int,
 variety_allocations jsonb, deleted_at timestamptz);
create table public.pruning_yield_settings(id uuid primary key default gen_random_uuid(), vineyard_id uuid,
 paddock_id uuid, prune_method text default 'spur', bunches_per_bud double precision default 1,
 buds_per_spur double precision default 2, spurs_per_vine double precision default 5,
 buds_per_cane double precision default 10, canes_per_vine double precision default 4,
 bunch_weight_grams double precision default 120, vines_per_ha double precision, deleted_at timestamptz);
create table public.vineyard_grape_varieties(vineyard_id uuid, variety_key text, display_name text, is_active boolean);
create table public.grape_variety_catalog(key text, display_name text);
"""
source221 = (root / "sql/221_season_yield_estimates.sql").read_text()
table_start = source221.index("create table if not exists public.season_yield_estimates (")
table_end = source221.index("\n);", table_start) + 3
setup += source221[table_start:table_end] + "\n"
setup += "create unique index season_yield_estimates_active_key on public.season_yield_estimates(vineyard_id,vintage,paddock_id,planting_group_key) where deleted_at is null;\n"
for path, name in [
    ("sql/119_vintage_year_assignment.sql", "resolve_vintage_year"),
    ("sql/119_vintage_year_assignment.sql", "resolve_vineyard_vintage_year"),
    ("sql/095_admin_hectares_under_management.sql", "_paddock_polygon_area_hectares"),
    ("sql/184_picking_record_planting_groups.sql", "planting_group_key"),
    ("sql/221_season_yield_estimates.sql", "season_yield_estimate_source_rank"),
    ("sql/221_season_yield_estimates.sql", "_season_alloc_text"),
    ("sql/221_season_yield_estimates.sql", "_season_alloc_number"),
    ("sql/221_season_yield_estimates.sql", "_pruning_block_estimate"),
    ("sql/221_season_yield_estimates.sql", "_refresh_pruning_yield_estimates"),
]:
    setup += function(path, name)
migration = (root / "sql/263_yield_authoritative_vine_counts.sql").read_text()
migration = re.sub(r"^begin;\s*$|^commit;\s*$", "", migration, flags=re.M)
setup += migration + "\n" + migration + "\n"
setup += (root / "sql/tests/263_yield_authoritative_vine_counts_tests.sql").read_text()
setup += "\nrollback;\n"
result = subprocess.run(
    ["sudo", "-u", "postgres", "psql", "-X", "-h", "/var/run/postgresql", "-p", "5432",
     "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-d", "yield_contract_test"],
    input=setup, text=True, capture_output=True,
)
print(result.stdout)
print(result.stderr, file=sys.stderr)
sys.exit(result.returncode)

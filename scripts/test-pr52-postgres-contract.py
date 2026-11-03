"""Disposable LOCAL PostgreSQL contract checks; NEVER connects to Supabase.

Uses catalog-derived columns and exact deployed functions/triggers. This reduced
schema does not certify production FK/RLS/index/concurrency or HTTP behavior.
All fixture rows and binaries/data directories remain outside the repository.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'docs/reviews/evidence/ios-pr52-guided-repair-20261103/live-backend-expanded-catalog.json'
BIN = Path('/usr/lib/postgresql/17/bin')


def main():
    catalog = json.loads(CATALOG.read_text())[0]['inspection']
    with tempfile.TemporaryDirectory(prefix='pr52-postgres-') as temporary:
        work = Path(temporary)
        data, socket = work / 'data', work / 'socket'
        socket.mkdir()
        env = {**os.environ, 'PGHOST': str(socket), 'PGPORT': '55452', 'PGDATABASE': 'postgres',
               'PGUSER': os.environ.get('USER', 'user')}
        # Explicit local socket prevents any accidental production connection.
        subprocess.run([str(BIN / 'initdb'), '-D', str(data), '-A', 'trust', '--no-locale'], check=True, capture_output=True)
        subprocess.run([str(BIN / 'pg_ctl'), '-D', str(data), '-l', str(work / 'postgres.log'),
                        '-o', f"-k {socket} -p 55452 -h ''", '-w', 'start'], check=True, capture_output=True)
        try:
            setup = ['create schema auth;',
                     "create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;",
                     'create table public.vineyard_members(vineyard_id uuid,user_id uuid,role text);']
            for table in ['trips', 'spray_records', 'spray_tank_actuals', 'trip_compliance_archive',
                          'trip_activity_cancellation_receipts', 'trip_cost_allocations']:
                columns = []
                for column in catalog['columns']:
                    if column['table'] != table:
                        continue
                    name, kind = column['name'], column['type']
                    if kind == 'ARRAY':
                        kind = 'uuid[]' if name in ('block_ids', 'spray_record_ids') else 'text[]'
                    definition = f'"{name}" {kind}'
                    if name == 'server_revision':
                        definition += ' generated always as identity'
                    elif column['default']:
                        definition += ' default ' + column['default']
                    if column['nullable'] == 'NO':
                        definition += ' not null'
                    columns.append(definition)
                setup.append(f'create table public.{table} (' + ','.join(columns) + ');')
            # Only constraints used by the reviewed contract; not a full schema clone.
            setup.extend([
                'alter table public.trip_activity_cancellation_receipts add unique(operation_id), add unique(trip_id);',
                'alter table public.trip_compliance_archive add unique(operation_id);'])
            names = ['vineyard_role', 'set_updated_at', 'guard_cancelled_trip_v1',
                     'trip_cancellation_immutable_v1', 'trip_cancellation_receipt_json_v1',
                     'spray_tank_actuals_before_write', 'reconcile_deleted_trip_activity_v1']
            for name in names:
                setup.append(next(f['definition'] for f in catalog['functions'] if f['name'] == name) + ';')
            setup.append("create function public.has_vineyard_role(v uuid, roles text[]) returns boolean language sql stable as $$ select public.vineyard_role(v)=any(roles) $$;")
            for table in catalog['tables']:
                if table['name'] not in names:
                    setup.extend(trigger + ';' for trigger in table['triggers'] or [])
            path = work / 'setup.sql'
            path.write_text('\n'.join(setup))
            command = [str(BIN / 'psql'), '-X', '-v', 'ON_ERROR_STOP=1']
            subprocess.run(command + ['-f', str(path)], env=env, check=True, capture_output=True)
            tests = ROOT / 'sql/tests/284_guided_repair_contract_tests.sql'
            subprocess.run(command + ['-v', 'phase=baseline', '-f', str(tests)], env=env, check=True)
            migration = ROOT / 'sql/284_guided_repair_archived_actual_tombstone_contract.sql'
            subprocess.run(command + ['-f', str(migration)], env=env, check=True)
            # Exact hashes make a second application a no-op, not an overwrite.
            subprocess.run(command + ['-f', str(migration)], env=env, check=True)
            subprocess.run(command + ['-v', 'phase=corrected', '-f', str(tests)], env=env, check=True)
            print('LOCAL CONTRACT PASS: baseline reproduced; corrected checks and migration idempotence passed.')
            print('NOT production RLS/FK/HTTP/concurrency or original-iPhone acceptance.')
        finally:
            subprocess.run([str(BIN / 'pg_ctl'), '-D', str(data), '-m', 'immediate', '-w', 'stop'],
                           check=True, capture_output=True)


if __name__ == '__main__':
    main()

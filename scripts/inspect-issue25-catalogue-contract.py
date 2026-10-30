#!/usr/bin/env python3
"""Read-only Issue 25 schema/authority inspection; exports no customer rows."""
import json
import os
import tempfile
import urllib.request
from pathlib import Path

QUERY = """
SELECT jsonb_build_object(
 'functions', (SELECT jsonb_agg(jsonb_build_object('name',p.proname,'definition',pg_get_functiondef(p.oid)))
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.prokind='f' AND
 (p.proname ~ 'chemical_v3.*(approv|add_to_vineyard|propagat)' OR p.proname IN ('search_chemical_v3_catalogue','soft_delete_saved_chemicals','hard_delete_unused_saved_chemical'))),
 'columns', (SELECT jsonb_agg(jsonb_build_object('table',table_name,'column',column_name,'type',data_type))
 FROM information_schema.columns WHERE table_schema='public' AND table_name IN
 ('chemical_v3_products','chemical_v3_product_revisions','chemical_v3_rate_options','saved_chemicals','master_chemicals')),
 'triggers', (SELECT jsonb_agg(jsonb_build_object('table',c.relname,'definition',pg_get_triggerdef(t.oid),'function',pg_get_functiondef(t.tgfoid)))
 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND NOT t.tgisinternal AND c.relname IN
 ('chemical_v3_products','chemical_v3_product_revisions','master_chemicals','saved_chemicals')),
 'policies', (SELECT jsonb_agg(to_jsonb(p)) FROM pg_policies p WHERE schemaname='public' AND tablename IN
 ('chemical_v3_products','chemical_v3_product_revisions','chemical_v3_rate_options','saved_chemicals'))
) inspection;
"""

def main():
    token = os.environ.get('SUPABASE_ACCESS_TOKEN')
    if not token:
        raise SystemExit('Management credential unavailable; no request sent.')
    request = urllib.request.Request('https://api.supabase.com/v1/projects/tbafuqwruefgkbyxrxyb/database/query',
        data=json.dumps({'query': QUERY, 'read_only': True}).encode(), method='POST',
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=45) as response:
        rows = json.load(response)
    directory = Path(tempfile.mkdtemp(prefix='vinetrack-issue25-contract-', dir='/tmp'))
    directory.chmod(0o700)
    output = directory / 'contract.json'
    output.write_text(json.dumps(rows[0]['inspection'], indent=2))
    output.chmod(0o600)
    print(json.dumps({'artifact': str(output), 'read_only': True,
        'functions': [r['name'] for r in rows[0]['inspection']['functions'] or []]}))

if __name__ == '__main__':
    main()

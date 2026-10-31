#!/usr/bin/env python3
"""Read deployed Quadrant guard, admin contract and trigger metadata; no customer rows."""
import json
import os
import urllib.request
import urllib.error

query = """SELECT 'function' AS kind, p.proname AS name, pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN ('guard_quadrant_count_beta','is_system_admin')
UNION ALL
SELECT 'trigger', t.tgname, pg_get_triggerdef(t.oid) || '; enabled=' || t.tgenabled::text
FROM pg_trigger t WHERE t.tgrelid='public.yield_estimation_sessions'::regclass AND NOT t.tgisinternal
AND t.tgname='yield_quadrant_count_admin_beta'
ORDER BY kind, name"""
request = urllib.request.Request(
    'https://api.supabase.com/v1/projects/tbafuqwruefgkbyxrxyb/database/query',
    data=json.dumps({'query': query, 'read_only': True}).encode(),
    headers={'Authorization': 'Bearer ' + os.environ['SUPABASE_ACCESS_TOKEN'], 'Content-Type': 'application/json'},
    method='POST',
)
try:
    with urllib.request.urlopen(request, timeout=45) as response:
        print(json.dumps(json.load(response), indent=2))
except urllib.error.HTTPError as error:
    print(error.read().decode())
    raise

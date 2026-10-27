#!/usr/bin/env python3
"""Read deployed bunch-weight contract metadata only; never queries customer rows."""
import json
import os
import urllib.request

query = "SELECT pg_get_functiondef(p.oid) AS definition FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('resolve_yield_bunch_weight','upsert_yield_bunch_weight','soft_delete_yield_bunch_weight') ORDER BY p.proname"
request = urllib.request.Request(
    'https://api.supabase.com/v1/projects/tbafuqwruefgkbyxrxyb/database/query',
    data=json.dumps({'query': query, 'read_only': True}).encode(),
    headers={'Authorization': 'Bearer ' + os.environ['SUPABASE_ACCESS_TOKEN'], 'Content-Type': 'application/json'},
    method='POST',
)
with urllib.request.urlopen(request, timeout=45) as response:
    print(json.dumps(json.load(response), indent=2))

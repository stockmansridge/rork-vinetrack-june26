#!/usr/bin/env python3
"""Read only the deployed resolver definition; never queries vineyard/customer rows."""
import json
import os
import urllib.request

query = "SELECT pg_get_functiondef(p.oid) AS definition FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='resolve_yield_bunch_weight'"
request = urllib.request.Request(
    'https://api.supabase.com/v1/projects/tbafuqwruefgkbyxrxyb/database/query',
    data=json.dumps({'query': query, 'read_only': True}).encode(),
    headers={'Authorization': 'Bearer ' + os.environ['SUPABASE_ACCESS_TOKEN'], 'Content-Type': 'application/json'},
    method='POST',
)
with urllib.request.urlopen(request, timeout=45) as response:
    print(json.dumps(json.load(response), indent=2))

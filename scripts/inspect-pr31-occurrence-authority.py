#!/usr/bin/env python3
"""Read-only PR31 live function identity/owner-path inspection; no customer rows."""
import json
import os
import urllib.request

QUERY = """
SELECT current_user AS connected_role,
 p.oid::regprocedure::text AS function_identity,
 pg_get_userbyid(p.proowner) AS function_owner,
 md5(pg_get_functiondef(p.oid)) AS definition_md5,
 p.prosecdef AS security_definer, p.proconfig AS function_settings,
 p.proacl::text AS execute_acl,
 pg_has_role(current_user,p.proowner,'USAGE') AS inherits_owner,
 pg_has_role(current_user,p.proowner,'SET') AS may_set_owner_role,
 strpos(pg_get_functiondef(p.oid), 'not provided_blocks ? (i->>''blockId'')') > 0 AS old_comparison_present,
 strpos(pg_get_functiondef(p.oid), 'selected.id::uuid = (i->>''blockId'')::uuid') > 0 AS repaired_comparison_present
FROM pg_proc p
WHERE p.oid='public.create_trip_with_occurrences_v1(uuid,jsonb,jsonb)'::regprocedure;
"""

def main():
    token = os.environ.get('SUPABASE_ACCESS_TOKEN')
    if not token:
        raise SystemExit('Management credential unavailable; no request sent.')
    request = urllib.request.Request(
        'https://api.supabase.com/v1/projects/tbafuqwruefgkbyxrxyb/database/query',
        # SELECT-only metadata query under the normal connected deployment role.
        # The API's read_only=True substitutes supabase_read_only_user, which
        # cannot establish the deployment role's existing owner authority.
        data=json.dumps({'query': QUERY, 'read_only': False}).encode(), method='POST',
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=45) as response:
        print(json.dumps({'sql_read_only': True, 'api_role': 'normal connected deployment role',
                          'project_ref': 'tbafuqwruefgkbyxrxyb',
                          'result': json.load(response)}, indent=2))

if __name__ == '__main__':
    main()

"""SELECT-only PR52 deployment and permission inspection. Never invokes repair RPCs."""
import argparse
import json
import os
from pathlib import Path
import urllib.request

REF = 'tbafuqwruefgkbyxrxyb'  # Existing independently documented VineTrack production ref.
SQL = """
SELECT jsonb_build_object(
 'captured_at', now(), 'role', current_user,
 'functions', (SELECT jsonb_agg(jsonb_build_object(
   'name',p.proname,'identity',p.oid::regprocedure::text,
   'definition',pg_get_functiondef(p.oid),
   'security_definer',p.prosecdef,'search_path',p.proconfig,
   'authenticated_execute',has_function_privilege('authenticated',p.oid,'EXECUTE'),
   'anon_execute',has_function_privilege('anon',p.oid,'EXECUTE')))
   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname IN (
    'reconcile_deleted_trip_activity_v1','correct_spray_tank_actual_v1',
    'cancel_trip_activity_v1','read_trip_activity_cancellation_v1',
    'trip_cancellation_receipt_json_v1','spray_tank_actuals_before_write',
    'complete_spray_record','vineyard_role','guard_cancelled_trip_v1',
    'trip_cancellation_immutable_v1','set_updated_at')),
 'columns', (SELECT jsonb_agg(jsonb_build_object('table',table_name,'name',column_name,
   'type',data_type,'default',column_default,'nullable',is_nullable)) FROM information_schema.columns
   WHERE table_schema='public' AND table_name IN ('trips','spray_records','spray_tank_actuals',
   'trip_compliance_archive','trip_activity_cancellation_receipts','trip_cost_allocations')),
 'tables', (SELECT jsonb_agg(jsonb_build_object('name',c.relname,
   'rls',c.relrowsecurity,'authenticated_select',has_table_privilege('authenticated',c.oid,'SELECT'),
   'policies',(SELECT jsonb_agg(jsonb_build_object('name',pol.polname,
     'using',pg_get_expr(pol.polqual,pol.polrelid),
     'check',pg_get_expr(pol.polwithcheck,pol.polrelid))) FROM pg_policy pol WHERE pol.polrelid=c.oid),
   'triggers',(SELECT jsonb_agg(pg_get_triggerdef(t.oid)) FROM pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal)))
   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relname IN ('trip_compliance_archive',
    'trip_activity_cancellation_receipts','spray_tank_actual_amendments','spray_tank_actuals'))
) AS inspection;
"""

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', default='live-backend-catalog.json')
    args = parser.parse_args()
    if Path(args.output).name != args.output:
        raise SystemExit('Output must be a file name within the evidence directory')
    token = os.environ.get('SUPABASE_ACCESS_TOKEN')
    if not token:
        raise SystemExit('Missing management authentication; no request made')
    request = urllib.request.Request(
        f'https://api.supabase.com/v1/projects/{REF}/database/query',
        data=json.dumps({'query': SQL}).encode(),
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.load(response)
    destination = Path('docs/reviews/evidence/ios-pr52-guided-repair-20261103')
    destination.mkdir(parents=True, exist_ok=True)
    output = destination / args.output
    if output.exists():
        raise SystemExit('Refusing to replace existing evidence; choose a new --output name')
    output.write_text(json.dumps(data, indent=2) + '\n')
    inspection = data[0]['inspection']
    print('Production catalog captured; SELECT only; no customer rows read or RPCs executed.')
    for f in inspection['functions'] or []:
        print(f['name'], 'authenticated_execute=', f['authenticated_execute'], 'anon_execute=', f['anon_execute'])
    print('Reconciliation RPC present:', any(f['name']=='reconcile_deleted_trip_activity_v1' for f in inspection['functions'] or []))

if __name__ == '__main__':
    main()

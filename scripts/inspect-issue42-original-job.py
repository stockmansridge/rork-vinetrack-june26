#!/usr/bin/env python3
"""Issue #42 SELECT-only catalog inspection. Never invokes recovery/mutation RPCs.

Uses existing management authorization; records no credentials or customer payloads.
Outputs are outside the repository by default. Catalogue definitions are metadata.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import urllib.request

REF = 'tbafuqwruefgkbyxrxyb'
CATALOG = """
SELECT jsonb_build_object(
 'captured_at', now(), 'role', current_user,
 'role_bypasses_rls', (SELECT rolbypassrls FROM pg_roles WHERE rolname=current_user),
 'functions', (SELECT jsonb_agg(jsonb_build_object('identity',p.oid::regprocedure::text,
   'owner',pg_get_userbyid(p.proowner),'md5',md5(pg_get_functiondef(p.oid)),
   'definition',pg_get_functiondef(p.oid))) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND (p.proname LIKE '%legacy_spray_pair%' OR p.proname='cancel_trip_activity_v1')),
 'relations', (SELECT jsonb_agg(jsonb_build_object('schema',n.nspname,'name',c.relname,'rls',c.relrowsecurity,
   'can_select',has_table_privilege(current_user,c.oid,'SELECT'),
   'columns',(SELECT jsonb_agg(jsonb_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod)) ORDER BY a.attnum)
       FROM pg_attribute a WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped)))
   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname IN ('public','vinetrack_private') AND c.relkind IN ('r','p') AND
   (c.relname IN ('trips','spray_records','spray_tank_actuals','trip_occurrence_operations','trip_cost_allocations')
    OR c.relname ~ '(legacy.*spray|cancellation|compliance|audit|tombstone)'))
) AS inspection;
"""


# Exact identities from Issues #40/#41/#42, across ALL vineyard/actor scopes.
# No deleted_at filter, current UI slice filter, customer notes or chemical amounts.
EVIDENCE = """
WITH jobs(label,id) AS (VALUES
 ('android42','d9604cde-1544-47e2-b3d1-8d7f1361128a'::uuid),
 ('android41','b1dd59ab-ff1b-4ff4-9af6-a9688425db22'::uuid),
 ('android_cancelled','3bfb7f81-2ae2-4f33-8fd8-6666b2b45393'::uuid),
 ('ios_absent','2be68a70-9582-4981-8a87-e727f113cdf6'::uuid),
 ('ios_other_vineyard','0a5466df-f0c1-4289-b2e2-a832ddb29ae5'::uuid),
 ('ios_deleted1','78bfc262-2620-4833-9d86-a3c5c6f5fb47'::uuid),
 ('ios_deleted2','f2cbf5b2-9ed3-4ac8-bc9d-73b885cbcc52'::uuid),
 ('ios_handoff','6f6754a0-bad1-4e3c-900f-c51580096dec'::uuid)
)
SELECT now() AS captured_at, current_user AS role, j.label,j.id AS original_trip_id,
 (SELECT jsonb_agg(jsonb_build_object('id',t.id,'vineyard_id',t.vineyard_id,
    'is_active',t.is_active,'end_time',t.end_time,'deleted_at',t.deleted_at,
    'sync_version',t.sync_version,'created_by',t.created_by,
    'tank_sessions',t.tank_sessions,'gps_point_count',jsonb_array_length(t.path_points)))
    FROM public.trips t WHERE t.id=j.id) AS trips,
 (SELECT jsonb_agg(jsonb_build_object('id',s.id,'vineyard_id',s.vineyard_id,'trip_id',s.trip_id,'deleted_at',s.deleted_at))
    FROM public.spray_records s WHERE s.trip_id=j.id OR
      (j.label='android42' AND s.id='1b69e888-6a97-4d31-8fbb-ae047a0aff9d'::uuid)) AS sprays,
 (SELECT jsonb_agg(jsonb_build_object('id',a.id,'trip_id',a.trip_id,'spray_record_id',a.spray_record_id,
    'vineyard_id',a.vineyard_id,'tank_session_id',a.tank_session_id,'water_volume_l',a.water_volume_l,
    'chemical_line_count',jsonb_array_length(a.chemicals),'confirmed_at',a.confirmed_at,'deleted_at',a.deleted_at))
    FROM public.spray_tank_actuals a WHERE a.trip_id=j.id OR
      (j.label='android42' AND a.spray_record_id='1b69e888-6a97-4d31-8fbb-ae047a0aff9d'::uuid)) AS actuals,
 (SELECT jsonb_agg(jsonb_build_object('operation_id',r.operation_id,'actor_user_id',r.actor_user_id,
    'vineyard_id',r.vineyard_id,'trip_id',r.trip_id,'spray_record_id',r.spray_record_id,
    'outcome',r.outcome,'failure_code',r.failure_code,'request_sha256',r.request_sha256,'committed_at',r.committed_at))
    FROM vinetrack_private.legacy_spray_pair_receipts_v1 r WHERE r.trip_id=j.id OR
      (j.label='android42' AND r.spray_record_id='1b69e888-6a97-4d31-8fbb-ae047a0aff9d'::uuid)) AS legacy_receipts,
 (SELECT jsonb_agg(jsonb_build_object('operation_id',o.operation_id,'vineyard_id',o.vineyard_id,
    'actor_id',o.actor_id,'accepted_at',o.accepted_at))
    FROM public.trip_occurrence_operations o WHERE o.trip_id=j.id) AS occurrence_receipts,
 (SELECT jsonb_agg(jsonb_build_object('operation_id',c.operation_id,'vineyard_id',c.vineyard_id,
    'status',c.status,'classification',c.application_classification,'compliance_archive_id',c.compliance_archive_id,
    'cancelled_at',c.cancelled_at,'spray_record_ids',c.spray_record_ids,'server_revision',c.server_revision))
    FROM public.trip_activity_cancellation_receipts c WHERE c.trip_id=j.id) AS cancellations,
 (SELECT jsonb_agg(jsonb_build_object('id',c.id,'operation_id',c.operation_id,'vineyard_id',c.vineyard_id,
    'retain_until',c.retain_until,'source',c.source,'created_at',c.created_at))
    FROM public.trip_compliance_archive c WHERE c.trip_id=j.id) AS compliance_archives,
 (SELECT jsonb_agg(jsonb_build_object('manual_entry_id',m.manual_entry_id,'vineyard_id',m.vineyard_id,
    'spray_record_id',m.spray_record_id,'deleted_at',m.deleted_at))
    FROM public.manual_spray_tombstones m WHERE m.trip_id=j.id OR
      (j.label='android42' AND m.spray_record_id='1b69e888-6a97-4d31-8fbb-ae047a0aff9d'::uuid)) AS manual_tombstones,
 (SELECT jsonb_agg(jsonb_build_object('id',a.id,'action',a.action,'entity_type',a.entity_type,
    'entity_id',a.entity_id,'vineyard_id',a.vineyard_id,'created_at',a.created_at))
    FROM public.audit_events a WHERE a.entity_id=j.id OR a.details LIKE '%'||j.id::text||'%' OR
      (j.label='android42' AND (a.entity_id='1b69e888-6a97-4d31-8fbb-ae047a0aff9d'::uuid OR
       a.details LIKE '%1b69e888-6a97-4d31-8fbb-ae047a0aff9d%'))) AS audits,
 (SELECT count(*) FROM public.integration_audit_log a WHERE a.metadata::text LIKE '%'||j.id::text||'%' OR
     (j.label='android42' AND a.metadata::text LIKE '%1b69e888-6a97-4d31-8fbb-ae047a0aff9d%')) AS integration_audit_matches,
 (SELECT jsonb_agg(jsonb_build_object('id',a.id,'vineyard_id',a.vineyard_id,'deleted_at',a.deleted_at,
    'has_worker_snapshot',a.worker_user_id IS NOT NULL,'has_worker_type_snapshot',a.worker_type_id IS NOT NULL,
    'has_labour_hours',a.labour_hours IS NOT NULL,'has_rate_snapshot',a.hourly_rate_snapshot IS NOT NULL,
    'rate_captured_at',a.rate_captured_at,'calculated_at',a.calculated_at))
    FROM public.trip_cost_allocations a WHERE a.trip_id=j.id) AS labour_snapshot_presence
FROM jobs j ORDER BY j.label;
"""


def query(sql):
    token = os.environ.get('SUPABASE_ACCESS_TOKEN')
    if not token:
        raise SystemExit('Management credential unavailable; no request sent.')
    request = urllib.request.Request(
        f'https://api.supabase.com/v1/projects/{REF}/database/query',
        data=json.dumps({'query': sql, 'read_only': True}).encode(), method='POST',
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=('catalog', 'evidence'), default='catalog')
    parser.add_argument('--output')
    args = parser.parse_args()
    args.output = args.output or '/tmp/vinetrack-issue42-' + args.phase + '.json'
    sql = CATALOG if args.phase == 'catalog' else EVIDENCE
    result = query(sql)
    body = json.dumps({'project_ref': REF, 'api_read_only': True,
                       'captured_at_client': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       'sql': sql, 'result': result}, indent=2)
    Path(args.output).write_text(body)
    if args.phase == 'evidence':
        print(body)
        return
    data = result[0]['inspection']
    for function in data['functions']:
        name = function['identity'].split('(')[0]
        Path('/tmp/vinetrack-' + name + '.sql').write_text(function['definition'])
    print(json.dumps({'artifact': args.output, 'sha256': hashlib.sha256(body.encode()).hexdigest(),
                      'role': data['role'], 'role_bypasses_rls': data['role_bypasses_rls'],
                      'functions': [{k: f[k] for k in ('identity','owner','md5')} for f in data['functions']],
                      'relations': data['relations']}, indent=2))


if __name__ == '__main__':
    main()

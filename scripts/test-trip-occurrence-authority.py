#!/usr/bin/env python3
"""Execute the occurrence SQL on a newly initialized Unix-socket-only PostgreSQL.

No project/env database URL is accepted. This cannot connect to production.
Builds a deliberately minimal auth/schema harness; not proof of deployed schema.
"""
from pathlib import Path
import concurrent.futures
import json
import os
import subprocess
import tempfile
import unittest
import uuid
import sys

ROOT = Path(__file__).resolve().parents[1]
BIN = Path('/usr/lib/postgresql/17/bin')
ACTOR = '10000000-0000-4000-8000-000000000001'
OTHER_ACTOR = '10000000-0000-4000-8000-000000000002'
VINEYARD = '20000000-0000-4000-8000-000000000001'
BLOCK = '30000000-0000-4000-8000-000000000001'
BLOCK_Y = '30000000-0000-4000-8000-000000000002'
ENV = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
SOCKET = ''
ROWS = [
    {'id':'31000000-0000-4000-8000-000000000001','number':38,
     'startPoint':{'latitude':-33.4,'longitude':149.1},'endPoint':{'latitude':-33.399,'longitude':149.1}},
    {'id':'31000000-0000-4000-8000-000000000002','number':39,
     'startPoint':{'latitude':-33.4,'longitude':149.10003},'endPoint':{'latitude':-33.399,'longitude':149.10003}},
]


def sql(statement: str, actor: str = ACTOR, role: str = 'authenticated', raw=False):
    prefix = '' if role == 'super' else f"set role {role}; set request.jwt.claim.sub='{actor}';"
    result = subprocess.run([str(BIN/'psql'), '-X', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1',
        '-h', SOCKET, '-p', '55439', '-U', os.environ.get('USER', 'user') if role == 'super' else 'fixture_client',
        '-d', 'postgres', '-c', prefix + statement],
        env=ENV, text=True, capture_output=True, timeout=20)
    if raw:
        return result
    if result.returncode:
        raise RuntimeError(result.stderr)
    output = result.stdout.strip()
    return json.loads(output) if output else None


def literal(value):
    return "'" + json.dumps(value).replace("'", "''") + "'::jsonb"


def document(blocks=None):
    blocks = blocks or [BLOCK, BLOCK]
    plan = str(uuid.uuid4())
    path_ids = {b: str(uuid.uuid4()) for b in blocks}
    items = [{'occurrenceId': str(uuid.uuid4()), 'blockId': b, 'blockNameSnapshot': 'Block X' if b==BLOCK else 'Block Y',
        'physicalPathRef': {'pathId': path_ids[b], 'rowIds': [r['id'] for r in ROWS],
            'rowSnapshots':ROWS,'geometryRevision':'stored-rows-fixture-v1'},
        'pathNumber': 38.5, 'passOrdinal': i+1, 'direction': None} for i, b in enumerate(blocks)]
    ids = [i['occurrenceId'] for i in items]
    return {'contract':'vinetrack.planned-occurrence','schemaVersion':1,'planId':plan,'revision':0,
        'planRevision':1,'items':items,'activeOrder':ids,'retired':[],
        'states':{i: {'status':'incomplete','source':None,'lastOperationId':None,'tankSessionIds':[]} for i in ids},
        'plannedCursorId':ids[0],'selectedOccurrenceId':None}


def create(d=None, active=True):
    d = d or document()
    trip = str(uuid.uuid4())
    fields = {'id':trip,'vineyard_id':VINEYARD,'is_active':active,'start_time':'2026-10-14T08:00:00Z'}
    op = str(uuid.uuid4())
    statement = f"select public.create_trip_with_occurrences_v1('{op}',{literal(fields)},{literal(d)});"
    return trip, sql(statement)['coverage'], statement


def action(trip, d, index=0, to='done', source='manual'):
    item = d['items'][index]
    a = {'kind':'setStatus','planId':d['planId'],'occurrenceId':item['occurrenceId'],
        'blockId':item['blockId'],'expectedBeforeState':d['states'][item['occurrenceId']],
        'toStatus':to,'source':source,'tankSessionIds':[]}
    if source == 'automatic':
        a['evidence']={'occurrenceId':item['occurrenceId'],'ruleVersion':'traversal-v1',
            'runId':str(uuid.uuid4()),'qualifiedSamples':4,'durationSeconds':3,
            'entryFraction':0.05,'exitFraction':0.95,'longitudinalSpan':0.9,'unambiguous':True}
    return a


def request(trip, d, a, op=None):
    op = op or str(uuid.uuid4())
    return f"select public.apply_trip_occurrence_action_v1('{op}','{trip}',{d['revision']},{d['planRevision']},{literal(a)});"


class AuthorityTests(unittest.TestCase):
    def assert_error(self, statement, message, **kwargs):
        response = sql(statement, raw=True, **kwargs)
        self.assertNotEqual(response.returncode, 0)
        self.assertIn(message, response.stderr)

    def states(self, d):
        return [d['states'][i['occurrenceId']]['status'] for i in d['items']]

    def test_native_physical_snapshot_ignores_only_nonphysical_metadata(self):
        d = document()
        snapshots = [dict(row, id=row['id'].upper(), vineCountOverride=999,
            startPoint=dict(row['startPoint'], id=str(uuid.uuid4())), endPoint=dict(row['endPoint'], speed=3)) for row in ROWS]
        for item in d['items']:
            item['physicalPathRef']['rowSnapshots'] = snapshots
        t, accepted, _ = create(d)
        self.assertEqual(accepted, d)
        changed = json.loads(json.dumps(d))
        for item in changed['items']:
            item['physicalPathRef']['rowSnapshots'][0]['startPoint']['latitude'] += 0.000001
        fields = {'id':str(uuid.uuid4()),'vineyard_id':VINEYARD}
        self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal(fields)},{literal(changed)});", 'OCCURRENCE_ROW_SCOPE_CONFLICT')

    def test_native_missing_row_id_is_unresolved_not_snapshot_adoption(self):
        d = document()
        candidate_id = str(uuid.uuid4())
        for item in d['items']:
            item['physicalPathRef'].update(rowIds=[], rowSnapshots=[], geometryRevision='unresolved', candidateRowIds=[candidate_id])
        _, accepted, _ = create(d)
        self.assertEqual(accepted, d)
        for item in d['items']:
            item['physicalPathRef'].update(rowIds=item['physicalPathRef']['candidateRowIds'], rowSnapshots=[dict(ROWS[0], id=item['physicalPathRef']['candidateRowIds'][0])], geometryRevision='native-snapshot-v1')
        self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal({'id':str(uuid.uuid4()),'vineyard_id':VINEYARD})},{literal(d)});", 'OCCURRENCE_ROW_SCOPE_CONFLICT')

    def test_native_snapshot_requires_both_exact_endpoints_and_effective_number(self):
        for mutation in ['missing_endpoint', 'wrong_number', 'out_of_range']:
            d = document()
            for item in d['items']:
                snapshots = json.loads(json.dumps(ROWS))
                if mutation == 'missing_endpoint': snapshots[0].pop('endPoint')
                elif mutation == 'wrong_number': snapshots[0]['number'] = 38.25
                else: snapshots[0]['endPoint']['latitude'] = 91
                item['physicalPathRef']['rowSnapshots'] = snapshots
            self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal({'id':str(uuid.uuid4()),'vineyard_id':VINEYARD})},{literal(d)});", 'OCCURRENCE_ROW_SCOPE_CONFLICT')

    def test_native_create_metadata_superset_preserved(self):
        for platform in ['android','ios']:
            d=document(); t=str(uuid.uuid4()); task=str(uuid.uuid4()); worker=str(uuid.uuid4())
            sql(f"insert into public.work_tasks values('{task}','{VINEYARD}',null); insert into public.worker_types values('{worker}','{VINEYARD}',null);",role='super')
            metadata={'id':t,'vineyard_id':VINEYARD,'paddock_id':BLOCK,'paddock_ids':[BLOCK,BLOCK_Y],
                'paddock_name':'Frozen selection','tracking_pattern':'upAndBack','start_time':'2026-10-14T08:00:00Z',
                'is_active':False,'is_paused':False,'person_name':'Operator','trip_function':'seeding',
                'trip_title':platform+' title','work_task_id':task,'worker_type_id':worker,'operator_user_id':ACTOR,
                'start_engine_hours':120.5,'seeding_details':{'notes':'do not trim','products':[{'name':'Rye','kg_per_ha':12}]},
                'total_tanks':3,'total_distance':12.5,'current_path_distance':4.2,'path_points':[{'latitude':-33.4,'longitude':149.1}],
                'pin_ids':[str(uuid.uuid4())],'pause_timestamps':['2026-10-14T08:01:00Z'],'resume_timestamps':['2026-10-14T08:02:00Z'],
                'tank_sessions':[],'active_tank_number':None,'is_filling_tank':False,'filling_tank_number':None,
                'manual_correction_events':['existing diagnostic'],'completion_notes':'retained note','created_by':ACTOR,
                'client_updated_at':'2026-10-14T08:00:01Z','row_sequence':[38.5,38.5],'sequence_index':0,
                'current_row_number':38.5,'next_row_number':38.5,'completed_paths':[],'skipped_paths':[]}
            stmt=f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal(metadata)},{literal(d)});"
            accepted=sql(stmt); self.assertEqual(sql(stmt),accepted)
            stored=sql(f"select to_jsonb(t) from public.trips t where id='{t}';")
            for key,value in metadata.items():
                if key in ['start_time','client_updated_at']: continue
                self.assertEqual(stored[key],value,(platform,key))
            self.assertEqual(stored['occurrence_coverage'],d)

    def test_create_does_not_silently_override_numeric_projection(self):
        d=document(); fields={'id':str(uuid.uuid4()),'vineyard_id':VINEYARD,'row_sequence':[38.5],'completed_paths':[38.5]}
        self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal(fields)},{literal(d)});",'OCCURRENCE_CREATE_PROJECTION_CONFLICT')
        self.assertIsNone(sql(f"select to_jsonb(t) from public.trips t where id='{fields['id']}';"))

    def test_create_rejects_cross_scope_task_and_worker(self):
        for key,table in [('work_task_id','work_tasks'),('worker_type_id','worker_types')]:
            foreign=str(uuid.uuid4()); sql(f"insert into public.{table} values('{foreign}','20000000-0000-4000-8000-000000000002',null);",role='super')
            fields={'id':str(uuid.uuid4()),'vineyard_id':VINEYARD,key:foreign}
            self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal(fields)},{literal(document())});",'OCCURRENCE_SETUP_SCOPE_CONFLICT')

    def test_recovery_returns_actual_reversible_state_and_exact_receipt(self):
        t,d,_=create(); done=str(uuid.uuid4()); d=sql(request(t,d,action(t,d),done))['coverage']
        skip=str(uuid.uuid4()); skip_stmt=request(t,d,action(t,d,to='skipped'),skip); result=sql(skip_stmt)
        recovery=sql(f"select public.get_trip_occurrence_recovery_v1('{t}',array['{done}'::uuid,'{skip}'::uuid]);")
        self.assertEqual(recovery['coverage'],result['coverage']); self.assertEqual(len(recovery['reversibleOperations']),1)
        recovered=recovery['reversibleOperations'][0]; self.assertEqual(recovered['operationId'],skip)
        self.assertEqual(recovered['previousState']['status'],'done'); self.assertEqual(recovered['resultingState']['status'],'skipped')
        self.assertEqual(recovery['receipts'][-1]['result'],result)
        self.assert_error(f"select public.get_trip_occurrence_recovery_v1('{t}');",'OCCURRENCE_TRIP_FORBIDDEN',actor=OTHER_ACTOR)

    def test_recovery_no_undo_for_retired_or_finalised_occurrence(self):
        t,d,_=create(); d=sql(request(t,d,action(t,d)))['coverage']
        edit={'kind':'editPlan','planId':d['planId'],'items':d['items'],'activeOrder':[d['items'][1]['occurrenceId']],'retired':[d['items'][0]['occurrenceId']]}
        d=sql(request(t,d,edit))['coverage']
        self.assertEqual(sql(f"select public.get_trip_occurrence_recovery_v1('{t}');")['reversibleOperations'],[])
        sql(f"select public.finalize_trip_occurrences_v1('{uuid.uuid4()}','{t}',{d['revision']},{d['planRevision']},{literal(d['states'])},{literal({'endTime':'2026-10-14T09:00:00Z'})});")
        self.assertFalse(sql(f"select public.get_trip_occurrence_recovery_v1('{t}');")['isActive'])

    def test_first_done_second_incomplete(self):
        t,d,_=create(); result=sql(request(t,d,action(t,d)))
        self.assertEqual(self.states(result['coverage']),['done','incomplete'])
        self.assertEqual(result['coverage']['plannedCursorId'],d['items'][1]['occurrenceId'])
        self.assertEqual(sql(f"select completed_paths from public.trips where id='{t}';"),[])

    def test_second_done_first_incomplete(self):
        t,d,_=create(); result=sql(request(t,d,action(t,d,1)))
        self.assertEqual(self.states(result['coverage']),['incomplete','done'])
        self.assertEqual(result['coverage']['plannedCursorId'],d['items'][0]['occurrenceId'])

    def test_done_skip_undo_restores_immediate_done(self):
        t,d,_=create(); d=sql(request(t,d,action(t,d)))['coverage']
        a=action(t,d,to='skipped'); op=str(uuid.uuid4()); d=sql(request(t,d,a,op))['coverage']
        undo={'kind':'undo','planId':d['planId'],'occurrenceId':d['items'][0]['occurrenceId'],
            'blockId':BLOCK,'undoOfOperationId':op}
        d=sql(request(t,d,undo))['coverage']
        self.assertEqual(self.states(d),['done','incomplete'])

    def test_undo_first_preserves_second_skip(self):
        t,d,_=create(); op=str(uuid.uuid4()); d=sql(request(t,d,action(t,d),op))['coverage']
        d=sql(request(t,d,action(t,d,1,to='skipped')))['coverage']
        self.assertEqual(self.states(d),['done','skipped'])
        undo={'kind':'undo','planId':d['planId'],'occurrenceId':d['items'][0]['occurrenceId'],
            'blockId':BLOCK,'undoOfOperationId':op}
        self.assertEqual(self.states(sql(request(t,d,undo))['coverage']),['incomplete','skipped'])

    def test_skip_to_done_preserves_other(self):
        t,d,_=create(); d=sql(request(t,d,action(t,d,to='skipped')))['coverage']
        self.assertEqual(self.states(sql(request(t,d,action(t,d)))['coverage']),['done','incomplete'])

    def test_automatic_each_occurrence_independently(self):
        for i in [0,1]:
            t,d,_=create(); item=d['items'][i]
            selection={'kind':'selectOccurrence','planId':d['planId'],'occurrenceId':item['occurrenceId'],'blockId':item['blockId']}
            d=sql(request(t,d,selection))['coverage']
            result=sql(request(t,d,action(t,d,i,source='automatic')))['coverage']
            self.assertEqual(self.states(result),['done','incomplete'] if i==0 else ['incomplete','done'])

    def test_poor_evidence_or_paused_auto_rejected(self):
        t,d,_=create(); a=action(t,d,source='automatic'); a['evidence']['qualifiedSamples']=1
        self.assert_error(request(t,d,a),'OCCURRENCE_TRAVERSAL_REQUIRED')
        sql(f"update public.trips set is_paused=true where id='{t}';")
        self.assert_error(request(t,d,action(t,d,source='automatic')),'OCCURRENCE_TRAVERSAL_REQUIRED')

    def test_same_label_different_blocks(self):
        t,d,_=create(document([BLOCK,BLOCK_Y])); self.assertEqual(self.states(sql(request(t,d,action(t,d)))['coverage']),['done','incomplete'])
        a=action(t,d,1); a['blockId']=BLOCK
        self.assert_error(request(t,d,a),'OCCURRENCE_REVISION_CONFLICT')

    def test_wrong_trip_plan_block(self):
        t,d,_=create(); a=action(t,d); a['blockId']=BLOCK_Y
        self.assert_error(request(t,d,a),'OCCURRENCE_IDENTITY_CONFLICT')
        a=action(t,d); a['planId']=str(uuid.uuid4())
        self.assert_error(request(t,d,a),'OCCURRENCE_PLAN_CONFLICT')
        t2,d2,_=create(); self.assert_error(request(t2,d2,action(t,d)),'OCCURRENCE_PLAN_CONFLICT')

    def test_duplicate_delayed_ack_returns_original(self):
        t,d,_=create(); stmt=request(t,d,action(t,d)); first=sql(stmt)
        updated=first['coverage']; sql(request(t,updated,action(t,updated,1)))
        self.assertEqual(sql(stmt),first)
        self.assertEqual(sql(f"select occurrence_coverage->'revision' from public.trips where id='{t}';"),2)

    def test_same_operation_different_intent_rejected(self):
        t,d,_=create(); op=str(uuid.uuid4()); sql(request(t,d,action(t,d),op))
        self.assert_error(request(t,d,action(t,d,to='skipped'),op),'OCCURRENCE_OPERATION_ID_CONFLICT')

    def test_stale_competing_action_rejected(self):
        t,d,_=create(); sql(request(t,d,action(t,d)))
        self.assert_error(request(t,d,action(t,d,1)),'OCCURRENCE_REVISION_CONFLICT')

    def test_concurrent_duplicate_applies_once(self):
        t,d,_=create(); stmt=request(t,d,action(t,d))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(sql,[stmt,stmt]))
        self.assertEqual(results[0],results[1])
        self.assertEqual(results[0]['coverage']['revision'],1)

    def test_concurrent_stale_actions_one_wins(self):
        t,d,_=create(); stmts=[request(t,d,action(t,d,i)) for i in [0,1]]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda s:sql(s,raw=True),stmts))
        self.assertEqual(sum(r.returncode==0 for r in results),1)
        self.assertIn('OCCURRENCE_REVISION_CONFLICT',next(r.stderr for r in results if r.returncode))

    def test_route_reorder_preserves_identity_and_state(self):
        t,d,_=create(); d=sql(request(t,d,action(t,d)))['coverage']
        a={'kind':'editPlan','planId':d['planId'],'items':d['items'],'activeOrder':list(reversed(d['activeOrder'])),'retired':[]}
        updated=sql(request(t,d,a))['coverage']
        self.assertEqual(updated['states'],d['states']); self.assertEqual(updated['planRevision'],2)
        a['items'][0]['pathNumber']=108.5
        self.assert_error(request(t,updated,a),'OCCURRENCE_IMMUTABLE_IDENTITY')

    def test_retirement_never_transfers_state(self):
        t,d,_=create(); d=sql(request(t,d,action(t,d)))['coverage']
        replacement=dict(d['items'][0]); replacement['occurrenceId']=str(uuid.uuid4())
        a={'kind':'editPlan','planId':d['planId'],'items':d['items']+[replacement],
           'activeOrder':[d['items'][1]['occurrenceId'],replacement['occurrenceId']],'retired':[d['items'][0]['occurrenceId']]}
        updated=sql(request(t,d,a))['coverage']
        self.assertEqual(updated['states'][replacement['occurrenceId']]['status'],'incomplete')
        self.assertEqual(updated['states'][d['items'][0]['occurrenceId']]['status'],'done')
        self.assert_error(request(t,updated,action(t,updated)),'OCCURRENCE_IDENTITY_CONFLICT')

    def test_selection_never_completes(self):
        t,d,_=create(); a={'kind':'selectOccurrence','planId':d['planId'],'occurrenceId':d['items'][1]['occurrenceId'],'blockId':BLOCK}
        selected=sql(request(t,d,a))['coverage']; self.assertEqual(self.states(selected),['incomplete','incomplete'])
        self.assertEqual(selected['selectedOccurrenceId'],d['items'][1]['occurrenceId'])

    def test_wrong_account_cannot_action_or_replay(self):
        t,d,_=create(); stmt=request(t,d,action(t,d)); sql(stmt)
        self.assert_error(stmt,'OCCURRENCE_TRIP_FORBIDDEN',actor=OTHER_ACTOR)

    def test_old_numeric_route_end_downgrade_rejected(self):
        t,_,_=create()
        for patch in ["completed_paths='[38.5]'", "skipped_paths='[38.5]'", "row_sequence='[108.5]'",
                      "is_active=false,end_time=now()", "occurrence_coverage=null"]:
            self.assert_error(f"update public.trips set {patch} where id='{t}';",'OCCURRENCE_UPDATE_REQUIRED')

    def test_spoofed_guc_cannot_bypass_guard(self):
        t,_,_=create()
        self.assert_error(f"set vinetrack.occurrence_writer='true'; update public.trips set completed_paths='[38.5]' where id='{t}';",'OCCURRENCE_UPDATE_REQUIRED')
        self.assert_error('set role vinetrack_occurrence_writer;','permission denied')

    def test_ledger_cannot_be_mutated_directly(self):
        self.assert_error('delete from public.trip_occurrence_operations;','permission denied')
        self.assert_error('update public.trip_occurrence_operations set result=\'{}\';','permission denied')

    def test_future_version_never_downgrades(self):
        d=document(); d['schemaVersion']=2
        fields={'id':str(uuid.uuid4()),'vineyard_id':VINEYARD}
        self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal(fields)},{literal(d)});",'OCCURRENCE_UNSUPPORTED_VERSION')

    def test_create_idempotent_and_never_adopts_history(self):
        t,d,stmt=create(); self.assertEqual(sql(stmt)['coverage'],d)
        legacy='40000000-0000-4000-8000-000000000001'
        self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal({'id':legacy,'vineyard_id':VINEYARD})},{literal(document())});",'OCCURRENCE_EXISTING_TRIP')

    def test_inactive_plan_cannot_record_coverage_until_activation(self):
        t,d,_=create(active=False)
        self.assert_error(request(t,d,action(t,d)),'OCCURRENCE_TRIP_NOT_ACTIVE')
        start={'startTime':'2026-10-14T08:00:00Z','startEngineHours':100.25}
        stmt=f"select public.activate_trip_occurrences_v1('{uuid.uuid4()}','{t}',0,1,{literal(start)});"
        activated=sql(stmt); self.assertTrue(activated['isActive']); self.assertEqual(sql(stmt),activated)
        self.assertEqual(self.states(sql(request(t,activated['coverage'],action(t,activated['coverage'])))['coverage']),['done','incomplete'])

    def test_duplicate_activation_with_new_operation_rejected(self):
        t,d,_=create(active=False); start={'startTime':'2026-10-14T08:00:00Z'}
        sql(f"select public.activate_trip_occurrences_v1('{uuid.uuid4()}','{t}',0,1,{literal(start)});")
        self.assert_error(f"select public.activate_trip_occurrences_v1('{uuid.uuid4()}','{t}',1,1,{literal(start)});",'OCCURRENCE_ACTIVATION_CONFLICT')

    def test_undo_stale_action_never_changes_newer_status(self):
        t,d,_=create(); op=str(uuid.uuid4()); d=sql(request(t,d,action(t,d),op))['coverage']
        d=sql(request(t,d,action(t,d,to='skipped')))['coverage']
        undo={'kind':'undo','planId':d['planId'],'occurrenceId':d['items'][0]['occurrenceId'],'blockId':BLOCK,'undoOfOperationId':op}
        self.assert_error(request(t,d,undo),'OCCURRENCE_UNDO_CONFLICT')
        self.assertEqual(self.states(sql(f"select occurrence_coverage from public.trips where id='{t}';")),['skipped','incomplete'])

    def test_unrecorded_tank_links_rejected_and_recorded_links_retained(self):
        t,d,_=create(); session=str(uuid.uuid4()); a=action(t,d); a['tankSessionIds']=[session]
        self.assert_error(request(t,d,a),'OCCURRENCE_TANK_LINK_CONFLICT')
        sql(f"update public.trips set tank_sessions={literal([{'id':session,'endTime':'2026-10-14T09:00:00Z'}])} where id='{t}';")
        updated=sql(request(t,d,a))['coverage']
        self.assertEqual(updated['states'][d['items'][0]['occurrenceId']]['tankSessionIds'],[session])
        self.assert_error(f"update public.trips set tank_sessions='[]' where id='{t}';",'OCCURRENCE_TANK_LINK_CONFLICT')

    def test_report_future_document_is_not_legacy(self):
        t,d,_=create()
        sql(f"set request.jwt.claim.sub='{ACTOR}'; set role vinetrack_occurrence_writer; update public.trips set occurrence_coverage=jsonb_set(occurrence_coverage,'{{schemaVersion}}','2') where id='{t}';",role='super')
        self.assert_error(f"select public.get_spray_report_v2('{t}');",'OCCURRENCE_UNSUPPORTED_VERSION')
        v1=sql(f"select public.get_spray_report_v1('{t}');")
        self.assertEqual(v1['coverageBasis'],'occurrenceUnavailable')
        self.assertTrue(all(r['status']=='Not recorded' for r in v1['rows']))

    def test_canonical_document_null_and_duplicate_rows_rejected(self):
        for corrupt in ['null','repeat']:
            doc=json.loads(json.dumps(document()))
            for item in doc['items']:
                if corrupt=='null': item['physicalPathRef']['rowIds'][0]=None
                else: item['physicalPathRef']['rowIds'][1]=item['physicalPathRef']['rowIds'][0]
            fields={'id':str(uuid.uuid4()),'vineyard_id':VINEYARD}
            self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal(fields)},{literal(doc)});",'OCCURRENCE_INVALID_ROW_ID')

    def test_ambiguous_auto_requires_explicit_occurrence(self):
        t,d,_=create()
        self.assert_error(request(t,d,action(t,d,source='automatic')),'OCCURRENCE_SELECTION_REQUIRED')

    def test_auto_evidence_run_cannot_credit_next_pass(self):
        t,d,_=create(); first=d['items'][0]
        d=sql(request(t,d,{'kind':'selectOccurrence','planId':d['planId'],'occurrenceId':first['occurrenceId'],'blockId':BLOCK}))['coverage']
        auto=action(t,d,source='automatic'); run=auto['evidence']['runId']
        d=sql(request(t,d,auto))['coverage']; second=action(t,d,1,source='automatic'); second['evidence']['runId']=run
        self.assert_error(request(t,d,second),'OCCURRENCE_TRAVERSAL_REQUIRED')

    def test_manual_only_geometry_never_allows_auto(self):
        doc=document()
        for item in doc['items']:
            item['physicalPathRef'].update(rowIds=[],rowSnapshots=[],geometryRevision='unresolved')
        t,d,_=create(doc)
        self.assert_error(request(t,d,action(t,d,source='automatic')),'OCCURRENCE_TRAVERSAL_REQUIRED')

    def test_fabricated_row_and_geometry_rejected(self):
        for field in ['id','number']:
            doc=json.loads(json.dumps(document()))
            forged=str(uuid.uuid4()) if field=='id' else 108
            for item in doc['items']:
                item['physicalPathRef']['rowSnapshots'][0][field]=forged
            fields={'id':str(uuid.uuid4()),'vineyard_id':VINEYARD}
            self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal(fields)},{literal(doc)});",'OCCURRENCE_ROW_SCOPE_CONFLICT')

    def test_failed_ledger_insert_rolls_back_trip_state(self):
        t,d,_=create(); op=str(uuid.uuid4())
        sql(f"create function public.fixture_fail_ledger() returns trigger language plpgsql as $$begin if new.operation_id='{op}'::uuid then raise exception 'FIXTURE_DISK_FAILURE'; end if; return new; end$$; create trigger fixture_fail before insert on public.trip_occurrence_operations for each row execute function public.fixture_fail_ledger();",role='super')
        try:
            self.assert_error(request(t,d,action(t,d),op),'FIXTURE_DISK_FAILURE')
            self.assertEqual(sql(f"select occurrence_coverage from public.trips where id='{t}';"),d)
            self.assertEqual(sql(f"select to_jsonb(count(*)) from public.trip_occurrence_operations where operation_id='{op}';"),0)
        finally:
            sql('drop trigger fixture_fail on public.trip_occurrence_operations; drop function public.fixture_fail_ledger();',role='super')

    def test_setup_links_cannot_cross_vineyards(self):
        fields={'id':str(uuid.uuid4()),'vineyard_id':VINEYARD,'operator_user_id':OTHER_ACTOR}
        self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal(fields)},{literal(document())});",'OCCURRENCE_SETUP_SCOPE_CONFLICT')
        fields.pop('operator_user_id'); fields['machine_id']=str(uuid.uuid4())
        self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal(fields)},{literal(document())});",'OCCURRENCE_SETUP_SCOPE_CONFLICT')

    def test_noncanonical_uuid_rejected(self):
        d=document(); old=d['items'][0]['occurrenceId']; new='AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
        d['items'][0]['occurrenceId']=new
        d['activeOrder'][0]=new; d['plannedCursorId']=new
        d['states'][new]=d['states'].pop(old)
        fields={'id':str(uuid.uuid4()),'vineyard_id':VINEYARD}
        self.assert_error(f"select public.create_trip_with_occurrences_v1('{uuid.uuid4()}',{literal(fields)},{literal(d)});",'OCCURRENCE_INVALID_IDENTITY')

    def test_finalize_preserves_incomplete_and_duplicate_result(self):
        t,d,_=create(); d=sql(request(t,d,action(t,d)))['coverage']
        end={'endTime':'2026-10-14T09:00:00Z','completionNotes':'reviewed'}
        statement=f"select public.finalize_trip_occurrences_v1('{uuid.uuid4()}','{t}',{d['revision']},{d['planRevision']},{literal(d['states'])},{literal(end)});"
        first=sql(statement); self.assertEqual(self.states(first['coverage']),['done','incomplete'])
        self.assertFalse(first['isActive']); self.assertEqual(sql(statement),first)
        self.assert_error(request(t,first['coverage'],action(t,first['coverage'],1)),'OCCURRENCE_TRIP_CLOSED')

    def test_finalize_stale_review_rejected(self):
        t,d,_=create(); sql(request(t,d,action(t,d)))
        statement=f"select public.finalize_trip_occurrences_v1('{uuid.uuid4()}','{t}',0,1,{literal(d['states'])},{literal({'endTime':'2026-10-14T09:00:00Z'})});"
        self.assert_error(statement,'OCCURRENCE_REVISION_CONFLICT')

    def test_finalize_requires_explicit_tank_end(self):
        t,d,_=create(); session={'id':str(uuid.uuid4()),'startTime':'2026-10-14T08:00:00Z'}
        sql(f"update public.trips set tank_sessions={literal([session])} where id='{t}';")
        statement=f"select public.finalize_trip_occurrences_v1('{uuid.uuid4()}','{t}',0,1,{literal(d['states'])},{literal({'endTime':'2026-10-14T09:00:00Z'})});"
        self.assert_error(statement,'OCCURRENCE_TANK_REVIEW_REQUIRED')
        self.assertTrue(sql(f"select to_jsonb(is_active) from public.trips where id='{t}';"))

    def test_report_v2_keeps_two_occurrences_v1_never_credits(self):
        t,d,_=create(); d=sql(request(t,d,action(t,d)))['coverage']
        v2=sql(f"select public.get_spray_report_v2('{t}');")
        self.assertEqual([r['state'] for r in v2['rows']],['done','incomplete'])
        self.assertEqual([r['occurrenceId'] for r in v2['rows']],d['activeOrder'])
        self.assertEqual([r['rowNumber'] for r in v2['rows']],[38.5,38.5])
        v1=sql(f"select public.get_spray_report_v1('{t}');")
        self.assertEqual(v1['coverageBasis'],'occurrenceUnavailable')
        self.assertEqual([r['status'] for r in v1['rows']],['Not recorded','Not recorded'])
        for field in ['weather','cost','application']:
            self.assertEqual(v1[field],v2[field])

    def test_report_retired_item_not_reused(self):
        t,d,_=create(); d=sql(request(t,d,action(t,d)))['coverage']
        a={'kind':'editPlan','planId':d['planId'],'items':d['items'],'activeOrder':[d['items'][1]['occurrenceId']],'retired':[d['items'][0]['occurrenceId']]}
        sql(request(t,d,a)); rows=sql(f"select public.get_spray_report_v2('{t}');")['rows']
        self.assertEqual([r['isRetired'] for r in rows],[False,True])
        self.assertEqual([r['state'] for r in rows],['incomplete','done'])

    def test_report_permissions_and_private_alias(self):
        t,_,_=create()
        self.assert_error(f"select public.get_spray_report_v2('{t}');",'REPORT_FORBIDDEN',actor=OTHER_ACTOR)
        self.assert_error(f"select public.get_spray_report_v1_pre_occurrence_v1('{t}');",'permission denied')

    def test_legacy_reports_identical(self):
        self.assertTrue(sql("set request.jwt.claim.sub='10000000-0000-4000-8000-000000000001'; select to_jsonb(bool_and(public.get_spray_report_v1(id)=payload)) from fixture_legacy_reports;",role='super'))
        report=sql("select public.get_spray_report_v2('40000000-0000-4000-8000-000000000002');")
        self.assertEqual(report['coverageBasis'],'legacyNumeric')
        self.assertEqual([r['status'] for r in report['rows']],['Complete','Complete'])
        self.assertTrue(all('occurrenceId' not in r for r in report['rows']))

    def test_legacy_numeric_recovery_cannot_credit_new_trip(self):
        t,_,_=create()
        self.assert_error(f"insert into public.spray_row_assignment_evidence(trip_id,row_number,status) values('{t}',38.5,'Complete');",'OCCURRENCE_UPDATE_REQUIRED',role='super')

    def test_operator_cannot_delete_or_revive_occurrence_trip(self):
        t,_,_=create()
        self.assert_error(f"update public.trips set deleted_at=now() where id='{t}';",'OCCURRENCE_DELETE_FORBIDDEN')

    def test_legacy_rows_unchanged(self):
        self.assertTrue(sql("select to_jsonb(bool_and((to_jsonb(t)-'occurrence_coverage')=b.payload)) from public.trips t join fixture_legacy_before b on t.id=(b.payload->>'id')::uuid;",role='super'))
        self.assertTrue(sql("select to_jsonb(bool_and(occurrence_coverage is null)) from public.trips where id::text like '40000000%';",role='super'))


if __name__ == '__main__':
    if not (BIN/'initdb').exists():
        raise SystemExit('Local PostgreSQL 17 binaries required. No remote DB will be used.')
    with tempfile.TemporaryDirectory(prefix='vinetrack-occurrence-') as work:
        SOCKET=work
        data=Path(work)/'data'
        log=Path(work)/'postgres.log'
        subprocess.run([str(BIN/'initdb'),'-D',str(data),'-A','trust','--no-locale'],env=ENV,check=True,capture_output=True)
        subprocess.run([str(BIN/'pg_ctl'),'-D',str(data),'-l',str(log),'-o',f"-k {work} -p 55439 -c listen_addresses=''",'-w','start'],env=ENV,check=True,capture_output=True)
        try:
            for file in ['sql/tests/276_trip_occurrence_bootstrap.sql','sql/276_trip_occurrence_authority_v1.sql','sql/277_trip_occurrence_reports_v2.sql','sql/278_trip_occurrence_recovery_v1.sql']:
                run=subprocess.run([str(BIN/'psql'),'-X','-v','ON_ERROR_STOP=1','-h',work,'-p','55439','-d','postgres','-f',str(ROOT/file)],env=ENV,text=True,capture_output=True,timeout=30)
                if run.returncode:
                    raise RuntimeError(run.stderr)
            suite=unittest.defaultTestLoader.loadTestsFromTestCase(AuthorityTests)
            result=unittest.TextTestRunner(verbosity=2).run(suite)
            if not result.wasSuccessful():
                raise SystemExit(1)
            if '--export-native-recovery-fixtures' in sys.argv:
                fixtures=[]
                for origin,blocks in [('android-shaped-create',[BLOCK,BLOCK]),('ios-shaped-create',[BLOCK,BLOCK_Y])]:
                    t,d,_=create(document(blocks)); initial=d
                    done=str(uuid.uuid4()); done_result=sql(request(t,d,action(t,d),done)); d=done_result['coverage']
                    skip=str(uuid.uuid4()); skip_result=sql(request(t,d,action(t,d,to='skipped'),skip)); d=skip_result['coverage']
                    recovery=sql(f"select public.get_trip_occurrence_recovery_v1('{t}',array['{done}'::uuid,'{skip}'::uuid]);")
                    undo={'kind':'undo','planId':d['planId'],'occurrenceId':d['items'][0]['occurrenceId'],'blockId':blocks[0],'undoOfOperationId':skip}
                    undo_result=sql(request(t,d,undo)); d=undo_result['coverage']
                    b_result=sql(request(t,d,action(t,d,1,to='skipped'))); d=b_result['coverage']
                    ended=sql(f"select public.finalize_trip_occurrences_v1('{uuid.uuid4()}','{t}',{d['revision']},{d['planRevision']},{literal(d['states'])},{literal({'endTime':'2026-10-14T09:00:00Z'})});")
                    fixtures.append({'origin':origin,'scope':{'ownerId':ACTOR,'vineyardId':VINEYARD,'tripId':t},
                        'initial':initial,'doneResult':done_result,'skipResult':skip_result,'recovery':recovery,
                        'undoResult':undo_result,'bResult':b_result,'finalResult':ended,
                        'backendTrip':sql(f"select to_jsonb(t) from public.trips t where id='{t}';")})
                contents=json.dumps({'evidence':'real-local-postgresql-rpc-transcript-not-device-handover','fixtures':fixtures},indent=2)+'\n'
                for target in ['ios/VineTrackTests/occurrence-recovery-postgres.json','android-vinetrack/app/src/test/resources/occurrence-recovery-postgres.json']:
                    (ROOT/target).write_text(contents)
                print('Exported identical real PostgreSQL recovery transcripts for Kotlin and Swift native tests.')
        finally:
            subprocess.run([str(BIN/'pg_ctl'),'-D',str(data),'-m','immediate','-w','stop'],env=ENV,check=True,capture_output=True)

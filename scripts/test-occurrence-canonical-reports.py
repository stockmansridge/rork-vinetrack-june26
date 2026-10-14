#!/usr/bin/env python3
"""Actual checked-in canonical reader chain on a disposable socket-only PostgreSQL.

Uses a reader-compatible synthetic schema, NOT a full migrated/deployed schema.
No report function is stubbed. Read bodies are extracted verbatim; write RPCs,
asset upload/storage and unrelated migration DDL are intentionally not installed.
"""
import importlib.util
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('authority', ROOT/'scripts/test-trip-occurrence-authority.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


def execute_file(path):
    result = subprocess.run([str(a.BIN/'psql'), '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-h', a.SOCKET,
        '-p', '55439', '-d', 'postgres', '-f', str(ROOT/path)], env=a.ENV, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr)


def reader(path, name):
    source = (ROOT/path).read_text()
    pattern = rf'create or replace function public\.{re.escape(name)}\s*\(.*?\bas\s+(\$[a-zA-Z_]*\$).*?\1;'
    matches = list(re.finditer(pattern, source, flags=re.S | re.I))
    if len(matches) != 1:
        raise RuntimeError(f'Expected exactly one source reader {path}:{name}, got {len(matches)}')
    a.sql(matches[0].group(0), role='super')


def install_read_chain():
    p225 = 'sql/225_get_spray_report_v1.sql'
    p227 = 'sql/227_spray_actual_corrections_v1.sql'
    p228 = 'sql/228_spray_report_canonical_facts_and_trip_corrections_v1.sql'
    for name in ['spray_report_active_seconds_v1', 'spray_report_rows_v1', 'spray_report_tanks_v1', 'get_spray_report_v1']:
        reader(p225, name)
    reader(p227, 'spray_report_tanks_v1')
    reader(p227, 'spray_actual_amendments_v1')
    for path, suffix in [(p227, 'actual_amendments'), (p228, 'canonical_facts'),
                         ('sql/229_trip_hourly_weather_recovery_v1.sql', 'weather_provenance'),
                         ('sql/232_manual_spray_entry_v1.sql', 'manual_entry')]:
        if path == p228:
            reader(path, 'spray_report_safe_number_v1')
        a.sql(f'alter function public.get_spray_report_v1(uuid) rename to get_spray_report_v1_pre_{suffix}_v1;', role='super')
        reader(path, 'get_spray_report_v1')
    # Apply the actual aggregate fix to the actual renamed canonical body.
    execute_file('sql/233_spray_ground_application_intent.sql')
    execute_file('sql/234_spray_report_chemical_aggregate_fix.sql')
    # Readers are security definers as in their migrations; private layers are not entry points.
    for suffix in ['actual_amendments', 'canonical_facts', 'weather_provenance', 'manual_entry']:
        a.sql(f'revoke all on function public.get_spray_report_v1_pre_{suffix}_v1(uuid) from public,anon,authenticated;', role='super')
    a.sql('revoke all on function public.get_spray_report_v1(uuid) from public,anon; grant execute on function public.get_spray_report_v1(uuid) to authenticated;', role='super')


def spray(trip, manual=False):
    sid = str(uuid.uuid4())
    tanks = [{'tankNumber': 1, 'waterVolume': 500, 'chemicals': [
        {'id': 'planned-line', 'name': 'Fixture product', 'unit': 'mL', 'volumePerTank': 250, 'costPerUnit': 0.1}]}]
    a.sql(f"insert into public.spray_records(id,trip_id,vineyard_id,tanks,application_blocks,notes,entry_source,start_time,date) values "
          f"('{sid}','{trip}','{a.VINEYARD}',{a.literal(tanks)},{a.literal([{'blockId':a.BLOCK,'blockName':'Block X','grossAreaHa':2}])},'Retain application notes','{'manual' if manual else 'tracked'}','2026-10-14T08:00:00Z','2026-10-14T08:00:00Z');", role='super')
    chemicals = [{'id':str(uuid.uuid4()), 'plannedChemicalId':'planned-line', 'name':'Fixture product', 'unit':'mL', 'actualAmountBase':200}]
    a.sql(f"insert into public.spray_tank_actuals(id,trip_id,vineyard_id,spray_record_id,tank_number,water_volume_l,chemicals) values "
          f"('{uuid.uuid4()}','{trip}','{a.VINEYARD}','{sid}',1,450,{a.literal(chemicals)});", role='super')
    a.sql(f"insert into public.trip_weather_observations(trip_id,sample_slot,observed_at,source,source_kind,is_stale,temperature_c,provider,retrieval_mode,retrieved_at) values "
          f"('{trip}','2026-10-14T08:00:00Z','2026-10-14T08:00:00Z','Fixture station','observed',false,18.2,'fixture','live','2026-10-14T08:01:00Z');", role='super')
    return sid


class CanonicalReports(unittest.TestCase):
    def report(self, trip, rpc='get_spray_report_v2'):
        return a.sql(f"select public.{rpc}('{trip}');")

    def assert_facts_preserved(self, trip):
        # One transaction shares PostgreSQL now(); live durations must not drift between reads.
        pair = a.sql(f"set request.jwt.claim.sub='{a.ACTOR}'; select jsonb_build_object('before',"
            f"public.get_spray_report_v1_pre_occurrence_v1('{trip}'),'after',public.get_spray_report_v2('{trip}'));", role='super')
        before, after = pair['before'], pair['after']
        for key in ['identity','trip','equipment','application','programStep','tanks','weather','cost',
                    'amendments','metadataAmendments','plannedChemicalTotals','actualChemicalTotals','provenance']:
            self.assertEqual(after.get(key), before.get(key), key)
        self.assertEqual(after['tanks'][0]['plannedWaterLitres'], 500)
        self.assertEqual(after['tanks'][0]['actualWaterLitres'], 450)
        self.assertEqual(after['plannedChemicalTotals'][0]['actualAmountBase'], 250)
        self.assertEqual(after['actualChemicalTotals'][0]['actualAmountBase'], 200)
        self.assertEqual(after['weather'][0]['temperatureC'], 18.2)
        self.assertIsNone(after['cost'])  # synthetic operator, not owner/manager
        return after

    def test_repeated_pass_done_incomplete_and_done_skip(self):
        trip,d,_ = a.create(); spray(trip)
        d = a.sql(a.request(trip,d,a.action(trip,d)))['coverage']
        report = self.assert_facts_preserved(trip)
        self.assertEqual([r['state'] for r in report['rows']], ['done','incomplete'])
        self.assertEqual([r['occurrenceId'] for r in report['rows']],d['activeOrder'])
        self.assertEqual([r['passOrdinal'] for r in report['rows']], [1,2])
        d = a.sql(a.request(trip,d,a.action(trip,d,1,to='skipped')))['coverage']
        self.assertEqual([r['state'] for r in self.report(trip)['rows']], ['done','skipped'])
        self.assertTrue(all(r['status']=='Not recorded' for r in self.report(trip,'get_spray_report_v1')['rows']))

    def test_distinct_blocks_reorder_and_finalise(self):
        trip,d,_ = a.create(a.document([a.BLOCK,a.BLOCK_Y])); spray(trip)
        d = a.sql(a.request(trip,d,a.action(trip,d,1)))['coverage']
        edit = {'kind':'editPlan','planId':d['planId'],'items':d['items'],'activeOrder':list(reversed(d['activeOrder'])),'retired':[]}
        d = a.sql(a.request(trip,d,edit))['coverage']
        a.sql(f"select public.finalize_trip_occurrences_v1('{uuid.uuid4()}','{trip}',{d['revision']},{d['planRevision']},{a.literal(d['states'])},{a.literal({'endTime':'2026-10-14T09:00:00Z'})});")
        report = self.assert_facts_preserved(trip)
        self.assertEqual([r['occurrenceId'] for r in report['rows']], d['activeOrder'])
        self.assertEqual([r['blockId'] for r in report['rows']], [a.BLOCK_Y,a.BLOCK])
        self.assertEqual([r['state'] for r in report['rows']], ['done','incomplete'])
        self.assertIsNotNone(report['trip']['endUtc'])

    def test_retirement_and_exact_tank_links_do_not_use_numeric_ranges(self):
        trip,d,_ = a.create(); spray(trip)
        session = str(uuid.uuid4())
        a.sql(f"update public.trips set tank_sessions={a.literal([{'id':session,'tankNumber':1,'startTime':'2026-10-14T08:00:00Z','endTime':'2026-10-14T08:30:00Z','pathsCovered':[38.5],'startRow':38.5,'endRow':38.5}])} where id='{trip}';")
        action = a.action(trip,d); action['tankSessionIds'] = [session]
        d = a.sql(a.request(trip,d,action))['coverage']
        edit = {'kind':'editPlan','planId':d['planId'],'items':d['items'],'activeOrder':[d['activeOrder'][1]],'retired':[d['activeOrder'][0]]}
        d = a.sql(a.request(trip,d,edit))['coverage']
        report = self.report(trip)
        self.assertEqual([row['state'] for row in report['rows']], ['incomplete','done'])
        self.assertEqual([row['isRetired'] for row in report['rows']], [False,True])
        self.assertEqual(report['rows'][0]['tankSessionIds'],[])
        self.assertEqual(report['rows'][1]['tankSessionIds'],[session])
        self.assertEqual(report['tankSessions'][0]['occurrenceIds'],[d['retired'][0]])
        self.assertEqual(report['tankSessions'][0]['pathsCovered'],[])
        self.assertIsNone(report['tankSessions'][0]['startRow'])

    def test_owner_cost_facts_and_corrections_unchanged_by_coverage(self):
        trip,d,_ = a.create(); spray(trip)
        a.sql(f"insert into public.spray_trip_corrections(trip_id,version,machine_name_snapshot,operator_name_snapshot,fuel_consumption_l_per_hour) values('{trip}',2,'Frozen machine','Frozen operator',10);", role='super')
        a.sql(f"insert into public.fuel_purchases(vineyard_id,total_cost,volume_litres) values('{a.VINEYARD}',200,100);", role='super')
        a.sql(f"update public.vineyard_members set role='owner' where user_id='{a.ACTOR}' and vineyard_id='{a.VINEYARD}';", role='super')
        try:
            pair = a.sql(f"set request.jwt.claim.sub='{a.ACTOR}'; select jsonb_build_object('before',public.get_spray_report_v1_pre_occurrence_v1('{trip}'),'after',public.get_spray_report_v2('{trip}'));", role='super')
            self.assertEqual(pair['before']['cost'],pair['after']['cost'])
            self.assertEqual(pair['after']['cost']['visibility'],'owner_manager')
            self.assertEqual(pair['after']['cost']['fuelPricePerLitre'],2)
            self.assertEqual(pair['after']['equipment']['tractorName'],'Frozen machine')
            self.assertEqual(pair['after']['trip']['operatorName'],'Frozen operator')
            self.assertEqual(pair['after']['metadataCorrectionVersion'],2)
        finally:
            a.sql(f"update public.vineyard_members set role='operator' where user_id='{a.ACTOR}' and vineyard_id='{a.VINEYARD}';", role='super')

    def test_legacy_unique_and_duplicate_reports_unchanged(self):
        for sequence in [[38.5],[38.5,38.5]]:
            trip = str(uuid.uuid4())
            a.sql(f"insert into public.trips(id,vineyard_id,row_sequence,completed_paths) values('{trip}','{a.VINEYARD}',{a.literal(sequence)},'[38.5]');", role='super')
            spray(trip)
            old = self.report(trip,'get_spray_report_v1')
            new = self.report(trip)
            self.assertEqual(new['coverageBasis'],'legacyNumeric')
            self.assertEqual(new['rows'],old['rows'])
            self.assertEqual(len(new['rows']),len(sequence))
            self.assertTrue(all(row['status']=='Complete' for row in new['rows']))

    def test_manual_provenance_and_nonmember_refusal(self):
        trip = str(uuid.uuid4())
        a.sql(f"insert into public.trips(id,vineyard_id,row_sequence) values('{trip}','{a.VINEYARD}','[]');", role='super')
        spray(trip,manual=True)
        report = self.report(trip)
        self.assertTrue(report['provenance']['isManualEntry'])
        self.assertEqual(report['rows'],[]); self.assertEqual(report['plannedChemicalTotals'],[])
        self.assertEqual(report['tanks'][0]['actualWaterLitres'],450)
        result = a.sql(f"select public.get_spray_report_v2('{trip}');", actor=a.OTHER_ACTOR, raw=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('membership',result.stderr.lower())


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='vinetrack-canonical-readers-') as work:
        a.SOCKET = work
        data = Path(work)/'data'
        subprocess.run([str(a.BIN/'initdb'),'-D',str(data),'-A','trust','--no-locale'], env=a.ENV, check=True, capture_output=True)
        subprocess.run([str(a.BIN/'pg_ctl'),'-D',str(data),'-l',str(Path(work)/'postgres.log'),'-o',f"-k {work} -p 55439 -c listen_addresses=''",'-w','start'],env=a.ENV,check=True,capture_output=True)
        try:
            execute_file('sql/tests/276_trip_occurrence_bootstrap.sql')
            execute_file('sql/tests/279_occurrence_canonical_report_fixture.sql')
            install_read_chain()
            for path in ['sql/276_trip_occurrence_authority_v1.sql','sql/277_trip_occurrence_reports_v2.sql','sql/278_trip_occurrence_recovery_v1.sql']:
                execute_file(path)
            result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CanonicalReports))
            raise SystemExit(0 if result.wasSuccessful() else 1)
        finally:
            subprocess.run([str(a.BIN/'pg_ctl'),'-D',str(data),'-m','immediate','-w','stop'],env=a.ENV,check=True,capture_output=True)

#!/usr/bin/env python3
"""Real-HTTP proof of the Trip End path: PostgREST in front of a throw-away local PostgreSQL.

Why this exists. The occurrence/tank-link repair was first proven with psql only. That cannot show
what the iPhone actually receives, because the app talks to PostgREST, not to SQL: the HTTP status,
the JSON error body, the percent-encoding of the compare-and-swap filter and the JWT -> auth.uid()
path all sit between the two. This suite replays the exact wire shapes the app sends
(ios/VineTrack/Backend/Repositories/SupabaseTripSyncRepository.swift) over real HTTP:

  create -> activate -> PATCH tank_sessions (uppercase ids, the app's own text) -> setStatus with
  the journal's lowercase tankSessionIds -> PATCH non-authority fields -> finalise

Safety. It boots its own PostgreSQL 17 on a Unix socket inside a temp directory and its own PostgREST
bound to 127.0.0.1. It reads NO project/env database URL, key or token, so it cannot reach
production or any non-production project. The JWTs are minted here with a throw-away secret.

Stages share one database and run in numbered order on purpose:

  00  static guards: the app's field lists still match the server's, and the golden fixtures the native
      tests replay were generated from the SQL that is in this checkout
  01  the compare-and-swap URL contract (build 214 unencoded '+' -> 400; build 215 '%2B' -> 200;
      stale revision -> zero rows and no write; another positive offset)
  02  BEFORE the repair the app's real sequence is refused with the real answer (status + body),
      deterministically, with the Trip left untouched
  03  the repair is applied while the server is running
  04  the SAME immutable operation (same operation id, same bytes) now completes, and the Trip ends
  05  negative controls stay rejected over HTTP
  06  the server's tank-review rule is unchanged, with the real answer
  07  stale revision and foreign vineyard/anonymous callers are refused
  08  the Android wire shape (lowercase ids) is unaffected
  09  the whole Trip End as ONE chain with the bytes the app produces (create, activate, recovery reads,
      tank CAS, non-authority PATCH, links, skips, finalise): these answers are the golden fixtures

Set TRIP_END_HTTP_CAPTURE=<file.json> to write every captured exchange (method, path, query, request
body, status, response body) plus the SHA-256 of every SQL file the answers came from. The file is
written even when a stage fails. scripts/gen-trip-end-native-fixtures.py turns it into
ios/VineTrackTests/TripEndServerGoldenFixtures.swift, which TripEndServerReplayTests feeds, answer by
answer, to the app's real occurrence journal and failure classifier.

This is a deliberately minimal auth/schema harness. It is not proof of the deployed schema: it has no
GoTrue, none of the Spray/portal triggers and no spray_tank_actuals table. A real non-production
project remains the definitive proof of those parts.
"""
import base64
import hashlib
import hmac
import http.client
import importlib.util
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
SWIFT_REPOSITORY = ROOT / 'ios/VineTrack/Backend/Repositories/SupabaseTripSyncRepository.swift'
SWIFT_TRIP_MODEL = ROOT / 'ios/VineTrack/Backend/Models/BackendTrip.swift'
FIXTURES = ROOT / 'ios/VineTrackTests/TripEndServerGoldenFixtures.swift'


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


T = load('tank_link_case_contract', 'scripts/test-tank-link-case-contract.py')
A = T.A

START = '2026-10-14T08:00:00Z'
END = '2026-10-14T09:00:00Z'
CONFLICT = 'OCCURRENCE_TANK_LINK_CONFLICT'
SECRET = 'local-only-throwaway-secret-' + uuid.uuid4().hex
EXCHANGES = []

# Added on top of the authority harness so PostgREST can connect and so auth.uid() reads the claim
# the way Supabase's own auth.uid() does (request.jwt.claims JSON, falling back to the per-claim GUC
# that the psql based suites set).
HTTP_HARNESS_SQL = """
create role authenticator login noinherit nosuperuser nocreaterole nocreatedb;
grant anon, authenticated to authenticator;
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid
$$;
"""


# -- tiny HTTP + JWT client -----------------------------------------------------------------------
def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def mint(sub, role='authenticated'):
    header = b64(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode())
    payload = b64(json.dumps({'sub': sub, 'role': role, 'aud': 'authenticated', 'exp': int(time.time()) + 3600}).encode())
    signature = b64(hmac.new(SECRET.encode(), f'{header}.{payload}'.encode(), hashlib.sha256).digest())
    return f'{header}.{payload}.{signature}'


class Answer:
    def __init__(self, status, raw):
        self.status, self.raw = status, raw
        try:
            self.json = json.loads(raw) if raw else None
        except ValueError:
            self.json = None

    @property
    def code(self):
        return self.json.get('code') if isinstance(self.json, dict) else None

    @property
    def message(self):
        return self.json.get('message') if isinstance(self.json, dict) else None

    def __repr__(self):
        return f'HTTP {self.status} {self.raw[:300]!r}'


class Server:
    port = 0

    @classmethod
    def call(cls, method, target, token=None, body=None, label=None, prefer=None):
        headers = {'Accept': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        if prefer:
            headers['Prefer'] = prefer
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        connection = http.client.HTTPConnection('127.0.0.1', cls.port, timeout=30)
        try:
            connection.request(method, target, body=data, headers=headers)
            response = connection.getresponse()
            answer = Answer(response.status, response.read())
        finally:
            connection.close()
        if label:
            path, _, query = target.partition('?')
            EXCHANGES.append({'label': label, 'method': method, 'target': path, 'path': path, 'query': query,
                              'request': None if body is None or isinstance(body, bytes) else json.loads(json.dumps(body)),
                              'status': answer.status, 'body': answer.raw.decode('utf-8', 'replace')})
        return answer

    @classmethod
    def rpc(cls, name, params, who=A.ACTOR, label=None):
        return cls.call('POST', f'/rpc/{name}', mint(who) if who else None, params, label or f'rpc/{name}')


def cas_target(trip, vineyard, sync_version, updated_at, encode_plus=True):
    """The tank-session CAS URL exactly as TripTankCASRequestURL builds it.

    URLComponents percent-encodes ':' but leaves '+' alone; build 215 then replaces '+' by %2B. Build
    214 did not, so PostgREST decoded '+00:00' as ' 00:00' and answered HTTP 400 to every request.
    """
    safe = '-._~' if encode_plus else '-._~+'
    items = [('id', f'eq.{trip}'), ('vineyard_id', f'eq.{vineyard}'), ('sync_version', f'eq.{sync_version}'),
             ('updated_at', f'eq.{updated_at}'), ('deleted_at', 'is.null'), ('is_active', 'eq.true'),
             ('end_time', 'is.null'), ('select', 'id')]
    return '/trips?' + '&'.join(f'{name}={quote(value, safe=safe)}' for name, value in items)


# -- iOS wire fixtures ----------------------------------------------------------------------------
def ios_sessions(ids, ended=True):
    """TankSession.encode(to:): camelCase keys, fractional-second ISO-8601, the app's own id text."""
    sessions = []
    for n, session_id in enumerate(ids):
        session = {'id': session_id, 'tankNumber': n + 1, 'startTime': f'2026-10-14T08:{10 + n * 20:02d}:00.250Z',
                   'pathsCovered': [38.0 + n], 'startRow': 38.0 + n, 'endRow': 38.5 + n}
        if ended:
            session['endTime'] = f'2026-10-14T08:{25 + n * 20:02d}:00.750Z'
        sessions.append(session)
    return sessions


def non_authority_fields(sessions, ended=True):
    """What updateOccurrenceNonAuthorityFields PATCHes before the first link operation (a representative subset)."""
    return {'paddock_name': 'Block X', 'person_name': 'Operator', 'trip_function': 'spraying',
            'total_tanks': len(sessions), 'total_distance': 123.4, 'current_path_distance': 0.0, 'path_points': [],
            'pin_ids': [], 'pause_timestamps': [], 'resume_timestamps': [], 'tank_sessions': sessions,
            'active_tank_number': None if ended else 1, 'is_filling_tank': False, 'filling_tank_number': None,
            'manual_correction_events': []}


def link_action(trip, coverage, ids, index=0):
    action = A.action(trip, coverage, index, to='done')
    action['tankSessionIds'] = ids
    return action


def apply_params(trip, coverage, action, op=None):
    return {'p_operation_id': op or str(uuid.uuid4()), 'p_trip_id': trip, 'p_expected_revision': coverage['revision'],
            'p_expected_plan_revision': coverage['planRevision'], 'p_action': action}


def finalize_params(trip, coverage, op=None, end=END):
    return {'p_operation_id': op or str(uuid.uuid4()), 'p_trip_id': trip, 'p_expected_revision': coverage['revision'],
            'p_expected_plan_revision': coverage['planRevision'], 'p_reviewed_states': coverage['states'],
            'p_end': {'endTime': end}}


def app_trip(trip, block):
    """BackendTripUpsert as prepareOccurrenceCreation journals it (the p_trip of the create operation).

    JSONEncoder writes UUIDs in upper case; OccurrenceCreateBlockUUID lower-cases only paddock_id and
    paddock_ids. Optional keys that are nil in the app (end_time, machine_id, ...) are not encoded.
    """
    return {'id': trip.upper(), 'vineyard_id': A.VINEYARD.upper(), 'paddock_id': block, 'paddock_ids': [block],
            'paddock_name': 'Block X', 'tracking_pattern': 'sequential', 'start_time': START, 'is_active': False,
            'is_paused': False, 'total_distance': 0, 'current_path_distance': 0, 'current_row_number': 38.5,
            'next_row_number': 38.5, 'sequence_index': 0, 'row_sequence': [38.5, 38.5, 38.5, 38.5], 'path_points': [],
            'completed_paths': [], 'skipped_paths': [], 'pin_ids': [], 'tank_sessions': [], 'active_tank_number': None,
            'total_tanks': 0, 'pause_timestamps': [], 'resume_timestamps': [], 'is_filling_tank': False,
            'filling_tank_number': None, 'person_name': 'Operator', 'operator_user_id': A.ACTOR.upper(),
            'trip_function': 'spraying', 'created_by': A.ACTOR.upper(), 'client_updated_at': START}


def app_document(passes=4):
    """The planned-occurrence document exactly as TripOccurrencePlanner.commit builds it.

    It differs from the SQL suite's A.document where it matters on the wire: there is no `direction` key, the
    physical reference carries `candidateRowIds` and `boundarySide`, the geometry is a native snapshot, and all
    ids are lower case. The native replay tests compare this shape with the planner's own output key by key.
    """
    row_ids = [r['id'] for r in A.ROWS]
    reference = {'pathId': str(uuid.uuid4()), 'rowIds': row_ids, 'candidateRowIds': row_ids, 'rowSnapshots': A.ROWS,
                 'geometryRevision': 'native-snapshot-v1', 'boundarySide': 'between'}
    ids = [str(uuid.uuid4()) for _ in range(passes)]
    items = [{'occurrenceId': oid, 'blockId': A.BLOCK, 'blockNameSnapshot': 'Block X', 'pathNumber': 38.5,
              'passOrdinal': n + 1, 'physicalPathRef': reference} for n, oid in enumerate(ids)]
    return {'contract': 'vinetrack.planned-occurrence', 'schemaVersion': 1, 'planId': str(uuid.uuid4()), 'revision': 0,
            'planRevision': 1, 'items': items, 'activeOrder': ids, 'retired': [],
            'states': {i: {'status': 'incomplete', 'lastOperationId': None, 'source': None, 'tankSessionIds': []} for i in ids},
            'plannedCursorId': ids[0], 'selectedOccurrenceId': None}


def app_non_authority_fields(sessions):
    """What updateOccurrenceNonAuthorityFields sends at Trip End: the Trip minus authority/route/lifecycle keys."""
    return {'paddock_name': 'Block X', 'is_paused': False, 'total_distance': 123.4, 'current_path_distance': 0,
            'path_points': [], 'pin_ids': [], 'tank_sessions': sessions, 'active_tank_number': None,
            'total_tanks': len(sessions), 'pause_timestamps': [], 'resume_timestamps': [], 'is_filling_tank': False,
            'filling_tank_number': None, 'person_name': 'Operator', 'trip_function': 'spraying',
            'start_engine_hours': 1234.5, 'end_engine_hours': 1240.5, 'completion_notes': 'Golden chain note',
            'client_updated_at': END}


def quoted(text):
    return re.findall(r"'([^']+)'", text)


def sha256_of(relative):
    return hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()


SQL_SOURCES = list(T.BASELINE_SQL) + [str(T.MIGRATION.relative_to(ROOT))]


class TripEndOverHttp(unittest.TestCase):
    incident = None  # the original operation, carried from stage 02 to stage 04

    # -- helpers ---------------------------------------------------------------------------------
    def ok(self, answer, message=''):
        self.assertEqual(answer.status, 200, f'{message} {answer!r}')
        return answer.json

    def start_trip(self, label):
        """create -> activate over HTTP, as the journal's first two operations."""
        trip = str(uuid.uuid4())
        fields = {'id': trip, 'vineyard_id': A.VINEYARD, 'is_active': False, 'start_time': START, 'operator_user_id': A.ACTOR}
        created = self.ok(Server.rpc('create_trip_with_occurrences_v1',
                                     {'p_operation_id': str(uuid.uuid4()), 'p_trip': fields, 'p_coverage': A.document()},
                                     label=f'{label}: create'), 'create')
        coverage = created['coverage']
        activated = self.ok(Server.rpc('activate_trip_occurrences_v1',
                                       {'p_operation_id': str(uuid.uuid4()), 'p_trip_id': trip, 'p_expected_revision': coverage['revision'],
                                        'p_expected_plan_revision': coverage['planRevision'], 'p_start': {'startTime': START}},
                                       label=f'{label}: activate'), 'activate')
        return trip, activated['coverage']

    def row(self, trip, columns='id,is_active,end_time,tank_sessions,occurrence_coverage,sync_version,updated_at', who=A.ACTOR, label=None):
        answer = Server.call('GET', f'/trips?id=eq.{trip}&select={columns}', mint(who), label=label)
        self.assertEqual(answer.status, 200, repr(answer))
        return answer.json[0] if answer.json else None

    def patch_fields(self, trip, fields, label=None, who=A.ACTOR):
        return Server.call('PATCH', f'/trips?id=eq.{trip}&select=id', mint(who), fields, label=label, prefer='return=representation')

    def assert_refused(self, answer, code, status, sqlstate=None):
        self.assertEqual(answer.status, status, repr(answer))
        self.assertEqual(answer.message, code, repr(answer))
        if sqlstate:
            self.assertEqual(answer.code, sqlstate, repr(answer))
        self.assertEqual(set(answer.json), {'code', 'details', 'hint', 'message'}, 'PostgREST error body shape')

    # -- 00 --------------------------------------------------------------------------------------
    def test_00_the_apps_non_authority_strip_list_is_the_servers_protected_list(self):
        """A drift in either list would make the app PATCH a protected column (refused) or silently drop one."""
        swift = SWIFT_REPOSITORY.read_text()
        match = re.search(r'static let authorityKeys: \[String\] = \[(.*?)\]', swift, re.S)
        self.assertIsNotNone(match, 'OccurrenceWirePayload.authorityKeys moved; update this guard')
        # The list is only a guard if the PATCH body really is built by dropping exactly these keys.
        self.assertIn('for key in authorityKeys { fields.removeValue(forKey: key) }', swift)
        stripped = set(re.findall(r'"([a-z_]+)"', match.group(1)))
        sql = (ROOT / 'sql/276_trip_occurrence_authority_v1.sql').read_text()
        guard = re.search(r'fields text\[\]:=array\[(.*?)\];', sql, re.S)
        self.assertIsNotNone(guard, 'the guard trigger field list moved; update this guard')
        protected = set(quoted(guard.group(1)))
        self.assertEqual(stripped, protected | {'occurrence_coverage'})

    def test_00_every_key_the_app_creates_a_trip_with_is_accepted_by_the_create_whitelist(self):
        swift = SWIFT_TRIP_MODEL.read_text()
        upsert = swift[swift.index('struct BackendTripUpsert'):]
        keys = upsert[upsert.index('enum CodingKeys'):upsert.index('func encode(to')]
        wire = {raw or name for name, raw in re.findall(r'case\s+(\w+)(?:\s*=\s*"([^"]+)")?', keys)}
        self.assertGreater(len(wire), 40, wire)
        sql = (ROOT / 'sql/276_trip_occurrence_authority_v1.sql').read_text()
        whitelist = re.search(r'not k=any\(array\[(.*?)\]\)', sql, re.S)
        self.assertIsNotNone(whitelist, 'the create whitelist moved; update this guard')
        # occurrence_coverage travels as p_coverage; prepareOccurrenceCreation removes it from p_trip.
        self.assertEqual((wire - {'occurrence_coverage'}) - set(quoted(whitelist.group(1))), set())
        self.assertEqual(set(app_trip(str(uuid.uuid4()), A.BLOCK)) - set(quoted(whitelist.group(1))), set())

    @unittest.skipIf(os.environ.get('TRIP_END_HTTP_CAPTURE'), 'regenerating the fixtures')
    def test_00_the_golden_fixtures_were_generated_from_the_sql_in_this_checkout(self):
        self.assertTrue(FIXTURES.exists(), 'run scripts/gen-trip-end-native-fixtures.py (see the file header of this script)')
        recorded = dict(re.findall(r'^// sql-sha256: (\S+) ([0-9a-f]{64})$', FIXTURES.read_text(), re.M))
        self.assertEqual(sorted(recorded), sorted(SQL_SOURCES))
        for relative in SQL_SOURCES:
            self.assertEqual(recorded[relative], sha256_of(relative),
                             f'{relative} changed since the fixtures were captured; regenerate them from this script')

    # -- 01 --------------------------------------------------------------------------------------
    def test_01_compare_and_swap_url_contract(self):
        trip, _ = self.start_trip('01')
        row = self.row(trip)
        updated_at = row['updated_at']
        self.assertIn('+', updated_at, 'PostgREST answers a positive offset; that is what the app echoes back in the filter')
        sessions = ios_sessions([str(uuid.uuid4()).upper()])
        body = {'tank_sessions': sessions}
        # Build 214: '+' left unencoded -> decoded as a space -> invalid timestamptz -> HTTP 400 on every attempt.
        broken = Server.call('PATCH', cas_target(trip, A.VINEYARD, row['sync_version'], updated_at, encode_plus=False),
                             mint(A.ACTOR), body, label='01: CAS PATCH, unencoded + (build 214)', prefer='return=representation')
        self.assertEqual(broken.status, 400, repr(broken))
        self.assertTrue(str(broken.code).startswith('22'), repr(broken))
        self.assertEqual(self.row(trip)['tank_sessions'], [], 'a refused request must not write')
        # Build 215: '%2B' -> the exact row, one write.
        fixed = Server.call('PATCH', cas_target(trip, A.VINEYARD, row['sync_version'], updated_at),
                            mint(A.ACTOR), body, label='01: CAS PATCH, %2B (build 215)', prefer='return=representation')
        self.assertEqual(fixed.status, 200, repr(fixed))
        self.assertEqual(fixed.json, [{'id': trip}])
        stored = self.row(trip)
        self.assertEqual([s['id'] for s in stored['tank_sessions']], [sessions[0]['id']], 'the app\'s own (uppercase) id text is stored verbatim')
        self.assertNotEqual(stored['updated_at'], updated_at, 'the write moved the server revision')
        # Stale revision: the same request again matches nothing and writes nothing.
        stale = Server.call('PATCH', cas_target(trip, A.VINEYARD, row['sync_version'], updated_at),
                            mint(A.ACTOR), {'tank_sessions': []}, label='01: CAS PATCH, stale updated_at', prefer='return=representation')
        self.assertEqual(stale.status, 200, repr(stale))
        self.assertEqual(stale.json, [], 'zero rows is the compare-and-swap miss the app reports as casNoMatch')
        self.assertEqual(self.row(trip)['tank_sessions'], stored['tank_sessions'], 'a stale compare-and-swap must not write')
        # The same instant written with a different positive offset still matches (timestamptz equality).
        fresh = self.row(trip)
        instant = subprocess.run([str(A.BIN / 'psql'), '-X', '-A', '-t', '-q', '-h', A.SOCKET, '-p', '55439', '-d', 'postgres', '-c',
                                  f"select to_char(('{fresh['updated_at']}'::timestamptz at time zone 'Australia/Sydney'),"
                                  f"'YYYY-MM-DD\"T\"HH24:MI:SS.US')||'+11:00';"], env=A.ENV, text=True, capture_output=True)
        self.assertEqual(instant.returncode, 0, instant.stderr)
        shifted = Server.call('PATCH', cas_target(trip, A.VINEYARD, fresh['sync_version'], instant.stdout.strip()),
                              mint(A.ACTOR), {'tank_sessions': stored['tank_sessions']}, label='01: CAS PATCH, +11:00 offset', prefer='return=representation')
        self.assertEqual(shifted.status, 200, repr(shifted))
        self.assertEqual(shifted.json, [{'id': trip}])

    # -- 02 --------------------------------------------------------------------------------------
    def test_02_before_the_repair_the_original_sequence_is_refused_with_the_real_answer(self):
        trip, coverage = self.start_trip('02')
        ids = [str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()]
        sessions = ios_sessions(ids)
        patched = self.patch_fields(trip, non_authority_fields(sessions), label='02: PATCH non-authority fields')
        self.assertEqual(patched.status, 200, repr(patched))
        self.assertEqual(patched.json, [{'id': trip}])
        links = [i.lower() for i in ids]  # the journal's canonical form
        params = apply_params(trip, coverage, link_action(trip, coverage, links))
        first = Server.rpc('apply_trip_occurrence_action_v1', params, label='02: setStatus with tank links, BEFORE the repair')
        self.assert_refused(first, CONFLICT, 500, '40001')
        before = self.row(trip)
        # Same bytes again: the answer is deterministic, not transient.
        for attempt in range(2):
            again = Server.rpc('apply_trip_occurrence_action_v1', params)
            self.assertEqual((again.status, again.raw), (first.status, first.raw), f'attempt {attempt + 2}')
        after = self.row(trip)
        self.assertEqual(after, before, 'a refused operation changes nothing')
        self.assertTrue(after['is_active'])
        self.assertIsNone(after['end_time'])
        self.assertEqual(after['occurrence_coverage']['revision'], coverage['revision'])
        self.assertEqual([s['id'] for s in after['tank_sessions']], ids)
        type(self).incident = {'trip': trip, 'coverage': coverage, 'ids': ids, 'links': links, 'params': params, 'refused': first,
                               'sessions': sessions}

    # -- 03 --------------------------------------------------------------------------------------
    def test_03_the_repair_applies_while_the_server_is_running(self):
        before = T.snapshot()
        for signature, row in before.items():
            self.assertEqual(row['old_text_comparison_present'], 't', signature)
        applied = T.run_file(T.MIGRATION)
        self.assertEqual(applied.returncode, 0, applied.stderr)
        after = T.snapshot()
        for signature, row in after.items():
            self.assertEqual(row['case_insensitive_comparison_present'], 't', signature)
            for field in T.IMMUTABLE_FIELDS:
                self.assertEqual(row[field], before[signature][field], f'{signature}.{field}')
        again = T.run_file(T.MIGRATION)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(T.snapshot(), after, 're-running the repair is a no-op')

    # -- 04 --------------------------------------------------------------------------------------
    def test_04_the_same_immutable_operation_completes_and_the_trip_ends(self):
        incident = self.incident
        self.assertIsNotNone(incident, 'stage 02 must have run')
        trip, coverage, ids, links = incident['trip'], incident['coverage'], incident['ids'], incident['links']
        # The very request the app stored before the repair: same operation id, same bytes.
        linked = Server.rpc('apply_trip_occurrence_action_v1', incident['params'], label='04: SAME setStatus operation, AFTER the repair')
        document = self.ok(linked, 'the original operation')['coverage']
        occurrence = [i['occurrenceId'] for i in document['items']]
        self.assertEqual(document['states'][occurrence[0]]['tankSessionIds'], links)
        # The app re-sends its Trip fields after the link exists (same tank_sessions).
        resent = self.patch_fields(trip, non_authority_fields(incident['sessions']), label='04: PATCH non-authority fields after links')
        self.assertEqual(resent.status, 200, repr(resent))
        self.assertEqual(resent.json, [{'id': trip}])
        skipped = Server.rpc('apply_trip_occurrence_action_v1',
                             apply_params(trip, document, A.action(trip, document, 1, to='skipped')), label='04: setStatus skipped')
        document = self.ok(skipped, 'skip')['coverage']
        end_params = finalize_params(trip, document)
        ended = self.ok(Server.rpc('finalize_trip_occurrences_v1', end_params, label='04: finalise'), 'finalise')
        self.assertFalse(ended['isActive'])
        stored = self.row(trip)
        self.assertFalse(stored['is_active'])
        self.assertIsNotNone(stored['end_time'])
        self.assertEqual([s['id'] for s in stored['tank_sessions']], ids, 'stored session ids keep the app\'s original text')
        self.assertEqual(stored['occurrence_coverage']['states'][occurrence[0]]['tankSessionIds'], links)
        self.assertEqual(stored['occurrence_coverage']['states'][occurrence[1]]['tankSessionIds'], [])
        # Interruption after any stage: each operation replays to its stored receipt (same id, same bytes).
        self.assertEqual(Server.rpc('apply_trip_occurrence_action_v1', incident['params']).json, linked.json)
        self.assertEqual(Server.rpc('finalize_trip_occurrences_v1', end_params).json, ended)
        self.assertEqual(self.row(trip), stored, 'replays change nothing')

    # -- 05 --------------------------------------------------------------------------------------
    def test_05_negative_controls_stay_rejected_over_http(self):
        trip, coverage = self.start_trip('05')
        session = str(uuid.uuid4()).upper()
        self.assertEqual(self.patch_fields(trip, non_authority_fields(ios_sessions([session]))).status, 200)
        other, _ = self.start_trip('05 other')
        foreign = str(uuid.uuid4()).upper()
        self.assertEqual(self.patch_fields(other, non_authority_fields(ios_sessions([foreign]))).status, 200)
        flipped = session[:-1] + ('0' if session[-1] != '0' else '1')
        cases = {'unrecorded session': str(uuid.uuid4()), 'one hex digit different': flipped.lower(),
                 'padded with whitespace': ' ' + session.lower() + ' ', 'not a uuid': 'not-a-uuid', 'empty string': '',
                 'recorded only on another Trip': foreign.lower()}
        for label, link in cases.items():
            with self.subTest(label):
                answer = Server.rpc('apply_trip_occurrence_action_v1', apply_params(trip, coverage, link_action(trip, coverage, [link])),
                                    label=f'05: link refused - {label}')
                self.assert_refused(answer, CONFLICT, 500, '40001')
        self.assertEqual(self.row(trip)['occurrence_coverage']['revision'], coverage['revision'])
        accepted = Server.rpc('apply_trip_occurrence_action_v1', apply_params(trip, coverage, link_action(trip, coverage, [session.lower()])))
        self.ok(accepted, 'the recorded session itself')

    # -- 06 --------------------------------------------------------------------------------------
    def test_06_the_tank_review_rule_is_unchanged_with_the_real_answer(self):
        trip, coverage = self.start_trip('06')
        session = str(uuid.uuid4()).upper()
        self.assertEqual(self.patch_fields(trip, non_authority_fields(ios_sessions([session], ended=False), ended=False)).status, 200)
        for index in (0, 1):
            coverage = self.ok(Server.rpc('apply_trip_occurrence_action_v1',
                                          apply_params(trip, coverage, A.action(trip, coverage, index, to='skipped'))), 'skip')['coverage']
        refused = Server.rpc('finalize_trip_occurrences_v1', finalize_params(trip, coverage), label='06: finalise with an open tank')
        self.assert_refused(refused, 'OCCURRENCE_TANK_REVIEW_REQUIRED', 500, '55000')
        self.assertTrue(self.row(trip)['is_active'], 'a refused finalise leaves the Trip active')
        # The data repair the app performs (end the tank), then the same finalise succeeds.
        self.assertEqual(self.patch_fields(trip, non_authority_fields(ios_sessions([session], ended=True), ended=True)).status, 200)
        self.ok(Server.rpc('finalize_trip_occurrences_v1', finalize_params(trip, coverage)), 'finalise after the tank is ended')
        self.assertFalse(self.row(trip)['is_active'])

    # -- 07 --------------------------------------------------------------------------------------
    def test_07_stale_revision_foreign_vineyard_and_anonymous_callers_are_refused(self):
        trip, coverage = self.start_trip('07')
        stale = dict(coverage, revision=coverage['revision'] - 1)
        refused = Server.rpc('apply_trip_occurrence_action_v1', apply_params(trip, stale, A.action(trip, coverage, 0, to='done')),
                             label='07: stale expected revision')
        self.assert_refused(refused, 'OCCURRENCE_REVISION_CONFLICT', 500, '40001')
        action = apply_params(trip, coverage, A.action(trip, coverage, 0, to='done'))
        foreign = Server.rpc('apply_trip_occurrence_action_v1', action, who=A.OTHER_ACTOR, label='07: member of another vineyard')
        self.assert_refused(foreign, 'OCCURRENCE_TRIP_FORBIDDEN', 403, '42501')
        anonymous = Server.rpc('apply_trip_occurrence_action_v1', action, who=None, label='07: no token')
        self.assertIn(anonymous.status, (401, 403), repr(anonymous))
        before = self.row(trip)
        row = self.row(trip, who=A.ACTOR)
        invisible = Server.call('PATCH', cas_target(trip, A.VINEYARD, row['sync_version'], row['updated_at']), mint(A.OTHER_ACTOR),
                                {'tank_sessions': ios_sessions([str(uuid.uuid4()).upper()])}, label='07: CAS PATCH by a foreign vineyard member',
                                prefer='return=representation')
        self.assertEqual((invisible.status, invisible.json), (200, []), 'RLS hides the row; the write matches nothing')
        self.assertIsNone(self.row(trip, who=A.OTHER_ACTOR))
        self.assertEqual(self.row(trip), before, 'no refused caller changed the Trip')

    # -- 08 --------------------------------------------------------------------------------------
    def test_08_android_wire_shape_is_unaffected(self):
        trip, coverage = self.start_trip('08')
        ids = [str(uuid.uuid4()).lower(), str(uuid.uuid4()).lower()]
        self.assertEqual(self.patch_fields(trip, non_authority_fields(ios_sessions(ids))).status, 200)
        document = self.ok(Server.rpc('apply_trip_occurrence_action_v1',
                                      apply_params(trip, coverage, link_action(trip, coverage, ids)), label='08: Android lowercase setStatus'))['coverage']
        document = self.ok(Server.rpc('apply_trip_occurrence_action_v1',
                                      apply_params(trip, document, A.action(trip, document, 1, to='skipped'))))['coverage']
        self.ok(Server.rpc('finalize_trip_occurrences_v1', finalize_params(trip, document), label='08: Android finalise'))
        stored = self.row(trip)
        self.assertFalse(stored['is_active'])
        self.assertEqual([s['id'] for s in stored['tank_sessions']], ids)

    # -- 09 --------------------------------------------------------------------------------------
    def test_09_golden_trip_end_chain_exactly_as_the_app_sends_it(self):
        """The whole Trip End as one chain: the answers captured here are replayed by the native tests.

        Order is the app's: create -> activate -> tank-session CAS -> readback -> non-authority PATCH ->
        links/skips -> finalise -> final PATCH, with the recovery read at the three points the app can be
        interrupted at. Session ids are uppercase (the app's UUID text), links are lowercase (the journal's).
        """
        trip = str(uuid.uuid4())
        document = app_document(4)
        ops = {name: str(uuid.uuid4()) for name in ('create', 'activate', 'done1', 'done2', 'skip', 'review', 'finalize')}
        ids = [str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()]
        links = [i.lower() for i in ids]
        sessions = ios_sessions(ids)

        created = self.ok(Server.rpc('create_trip_with_occurrences_v1', {'p_operation_id': ops['create'], 'p_trip': app_trip(trip, A.BLOCK),
                                                                         'p_coverage': document}, label='golden: 01 create'), 'create')
        coverage = created['coverage']
        activated = self.ok(Server.rpc('activate_trip_occurrences_v1', {
            'p_operation_id': ops['activate'], 'p_trip_id': trip, 'p_expected_revision': coverage['revision'],
            'p_expected_plan_revision': coverage['planRevision'], 'p_start': {'startTime': START, 'startEngineHours': 1234.5}},
            label='golden: 02 activate'), 'activate')
        coverage = activated['coverage']
        first = self.ok(Server.rpc('get_trip_occurrence_recovery_v1', {'p_trip_id': trip, 'p_operation_ids': [ops['create'], ops['activate']]},
                                   label='golden: 03 recovery after create and activate'), 'recovery 1')
        self.assertEqual({r['operationId'] for r in first['receipts']}, {ops['create'], ops['activate']})

        row = self.row(trip, columns='*', label='golden: 04 read the Trip row')
        cas = Server.call('PATCH', cas_target(trip, A.VINEYARD, row['sync_version'], row['updated_at']), mint(A.ACTOR),
                          {'tank_sessions': sessions}, label='golden: 05 CAS PATCH tank_sessions', prefer='return=representation')
        self.assertEqual((cas.status, cas.json), (200, [{'id': trip}]), repr(cas))
        readback = self.row(trip, columns='*', label='golden: 06 read back tank_sessions')
        self.assertEqual([s['id'] for s in readback['tank_sessions']], ids)
        patched = self.patch_fields(trip, app_non_authority_fields(sessions), label='golden: 07 PATCH non-authority fields before the first link')
        self.assertEqual((patched.status, patched.json), (200, [{'id': trip}]), repr(patched))

        for index, (name, label, link) in enumerate((('done1', 'golden: 08 setStatus done, tank 1 linked (manual)', links[0]),
                                                      ('done2', 'golden: 09 setStatus done, tank 2 linked (manual)', links[1]))):
            done = self.ok(Server.rpc('apply_trip_occurrence_action_v1', apply_params(trip, coverage, link_action(trip, coverage, [link], index), op=ops[name]),
                                      label=label), name)
            coverage = done['coverage']
        second = self.ok(Server.rpc('get_trip_occurrence_recovery_v1', {'p_trip_id': trip, 'p_operation_ids': [ops[k] for k in ('create', 'activate', 'done1', 'done2')]},
                                    label='golden: 10 recovery mid-chain'), 'recovery 2')
        self.assertEqual(len(second['reversibleOperations']), 2)
        coverage = self.ok(Server.rpc('apply_trip_occurrence_action_v1', apply_params(trip, coverage, A.action(trip, coverage, 2, to='skipped'), op=ops['skip']),
                                      label='golden: 11 setStatus skipped (manual)'), 'skip')['coverage']
        coverage = self.ok(Server.rpc('apply_trip_occurrence_action_v1', apply_params(trip, coverage, A.action(trip, coverage, 3, to='skipped', source='endReview'), op=ops['review']),
                                      label='golden: 12 setStatus skipped (endReview)'), 'review')['coverage']
        end = {'endTime': END, 'endEngineHours': 1240.5, 'completionNotes': 'Golden chain note'}
        finalize = {'p_operation_id': ops['finalize'], 'p_trip_id': trip, 'p_expected_revision': coverage['revision'],
                    'p_expected_plan_revision': coverage['planRevision'], 'p_reviewed_states': coverage['states'], 'p_end': end}
        ended = self.ok(Server.rpc('finalize_trip_occurrences_v1', finalize, label='golden: 13 finalise'), 'finalise')
        self.assertFalse(ended['isActive'])
        third = self.ok(Server.rpc('get_trip_occurrence_recovery_v1', {'p_trip_id': trip, 'p_operation_ids': list(ops.values())},
                                   label='golden: 14 recovery after finalise'), 'recovery 3')
        self.assertEqual({r['operationId'] for r in third['receipts']}, set(ops.values()))
        self.assertEqual(third['reversibleOperations'], [])
        patched = self.patch_fields(trip, app_non_authority_fields(sessions), label='golden: 15 PATCH non-authority fields after finalise')
        self.assertEqual((patched.status, patched.json), (200, [{'id': trip}]), repr(patched))

        stored = self.row(trip, columns='*', label='golden: 16 read the final Trip row')
        self.assertFalse(stored['is_active'])
        self.assertIsNotNone(stored['end_time'])
        self.assertEqual([s['id'] for s in stored['tank_sessions']], ids, 'the app\'s own uppercase id text survives the whole chain')
        occurrence = [i['occurrenceId'] for i in coverage['items']]
        states = stored['occurrence_coverage']['states']
        self.assertEqual([(states[o]['status'], states[o]['source'], states[o]['tankSessionIds']) for o in occurrence],
                         [('done', 'manual', [links[0]]), ('done', 'manual', [links[1]]), ('skipped', 'manual', []), ('skipped', 'endReview', [])])


# -- environment ----------------------------------------------------------------------------------
def find_postgrest():
    for candidate in (os.environ.get('POSTGREST_BIN'), shutil.which('postgrest'), '/tmp/pgrst/postgrest'):
        if candidate and Path(candidate).is_file():
            return candidate
    raise SystemExit('PostgREST binary required (set POSTGREST_BIN). Nothing remote is contacted.')


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def start_postgrest(work, binary):
    port, admin = free_port(), free_port()
    config = Path(work) / 'postgrest.conf'
    config.write_text(f'''db-uri = "postgresql:///postgres?host={quote(str(work), safe='/')}&port=55439&user=authenticator"
db-schemas = "public"
db-anon-role = "anon"
jwt-secret = "{SECRET}"
server-host = "127.0.0.1"
server-port = {port}
admin-server-port = {admin}
db-pool = 4
log-level = "warn"
''')
    log = open(Path(work) / 'postgrest.log', 'w')
    process = subprocess.Popen([binary, str(config)], stdout=log, stderr=subprocess.STDOUT, env=A.ENV)
    deadline = time.time() + 30
    while time.time() < deadline:
        if process.poll() is not None:
            raise RuntimeError('PostgREST exited: ' + (Path(work) / 'postgrest.log').read_text())
        try:
            probe = http.client.HTTPConnection('127.0.0.1', admin, timeout=2)
            probe.request('GET', '/ready')
            if probe.getresponse().status == 200:
                Server.port = port
                return process, log
        except OSError:
            pass
        time.sleep(0.25)
    process.kill()
    raise RuntimeError('PostgREST did not become ready: ' + (Path(work) / 'postgrest.log').read_text())


def main():
    if not (A.BIN / 'initdb').exists():
        raise SystemExit('Local PostgreSQL 17 binaries required. No remote DB will be used.')
    binary = find_postgrest()
    with tempfile.TemporaryDirectory(prefix='vinetrack-http-') as work:
        A.SOCKET = work
        data, log = Path(work) / 'data', Path(work) / 'postgres.log'
        subprocess.run([str(A.BIN / 'initdb'), '-D', str(data), '-A', 'trust', '--no-locale'], env=A.ENV, check=True, capture_output=True)
        subprocess.run([str(A.BIN / 'pg_ctl'), '-D', str(data), '-l', str(log), '-o', f"-k {work} -p 55439 -c listen_addresses=''", '-w', 'start'],
                       env=A.ENV, check=True, capture_output=True)
        process = None
        try:
            for file in T.BASELINE_SQL:
                source = ROOT / file
                if file.endswith('_bootstrap.sql'):
                    fixture = source.read_text().replace('30000000-0000-4000-8000-000000000001', A.BLOCK)
                    fixture = fixture.replace(r"\ir ../006_trips_sync.sql", "\\ir " + str(ROOT / 'sql/006_trips_sync.sql'))
                    source = Path(work) / 'bootstrap.sql'
                    source.write_text(fixture)
                result = T.run_file(source)
                if result.returncode:
                    raise RuntimeError(f'{file}: {result.stderr}')
            result = T.run_text(HTTP_HARNESS_SQL, 'http-harness.sql')
            if result.returncode:
                raise RuntimeError(f'http harness: {result.stderr}')
            process, postgrest_log = start_postgrest(work, binary)
            suite = unittest.defaultTestLoader.loadTestsFromTestCase(TripEndOverHttp)
            outcome = unittest.TextTestRunner(verbosity=2).run(suite)
            capture = os.environ.get('TRIP_END_HTTP_CAPTURE')
            if capture:
                version = subprocess.run([binary, '--version'], capture_output=True, text=True).stdout.strip()
                Path(capture).write_text(json.dumps({'generator': 'scripts/test-trip-end-http-contract.py',
                                                     'postgrest': version,
                                                     'sqlSha256': {f: sha256_of(f) for f in SQL_SOURCES},
                                                     'suiteSucceeded': outcome.wasSuccessful(), 'exchanges': EXCHANGES}, indent=2))
            print('\nCaptured real answers (status, PostgREST code, message):')
            for item in EXCHANGES:
                try:
                    body = json.loads(item['body'])
                except ValueError:
                    body = None
                detail = f"{body.get('code')} {body.get('message')}" if isinstance(body, dict) else ''
                print(f"  {item['status']}  {item['label']:<58} {detail}")
            if not outcome.wasSuccessful():
                sys.stderr.write('\nPostgREST log:\n' + (Path(work) / 'postgrest.log').read_text())
                raise SystemExit(1)
        finally:
            if process is not None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
            subprocess.run([str(A.BIN / 'pg_ctl'), '-D', str(data), '-m', 'immediate', '-w', 'stop'], env=A.ENV, check=True, capture_output=True)


if __name__ == '__main__':
    main()

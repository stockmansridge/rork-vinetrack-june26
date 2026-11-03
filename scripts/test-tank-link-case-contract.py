#!/usr/bin/env python3
"""Local-PostgreSQL contract proof for sql/occurrence_tank_link_uuid_case_identity.sql.

The defect (build 3.1.9 Trip End): the iOS app stores TankSession.id as an UPPERCASE UUID in
public.trips.tank_sessions, the occurrence journal links tank sessions by canonical LOWERCASE UUID,
and both occurrence authority functions compared the two as exact text. Every iOS Trip that
recorded a tank session therefore failed with OCCURRENCE_TANK_LINK_CONFLICT (40001) on the first
tank-linked setStatus, and could never finalise.

This script boots its own Unix-socket-only PostgreSQL 17 (no project or env database URL is ever
read, so it cannot reach production), applies the repository SQL exactly as shipped, then proves,
in order (the stages share one database, so the method names are numbered on purpose):

  01  the defect reproduces with the real iOS wire shape before the repair
  02  the repair fails closed and changes NOTHING when a function does not look as expected
  03  the repair applies, keeps owner/ACL/security/search_path, is idempotent, completes a half-applied state
  04  the iOS wire shape now completes create -> tank PATCH -> linked setStatus -> PATCH -> finalise,
      without rewriting stored session ids or links
  05  the Android wire shape is unchanged
  06  negative controls stay rejected (unrecorded / one-digit-off / padded / malformed / cross-Trip / no sessions)
  07  a linked session can still not be removed or replaced
  08  the server's finalise tank-review rule is unchanged
  00  (runs first) the production REHEARSAL file is derived from the repair, always ends in an exception,
      keeps nothing, reports what the repair would do, and refuses exactly where the repair refuses

Builds a deliberately minimal auth/schema harness; it is not proof of the deployed schema. VineTrack has
no non-production Supabase project, so the substitute is sql/occurrence_tank_link_uuid_case_identity_rehearsal.sql
run against the real deployed functions (it cannot commit), followed by the original-device acceptance.
"""
import csv
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('occurrence_authority_tests', ROOT / 'scripts/test-trip-occurrence-authority.py')
A = importlib.util.module_from_spec(spec)
spec.loader.exec_module(A)

MIGRATION = ROOT / 'sql/occurrence_tank_link_uuid_case_identity.sql'
VERIFY = ROOT / 'sql/occurrence_tank_link_uuid_case_identity_verify.sql'
REHEARSAL = ROOT / 'sql/occurrence_tank_link_uuid_case_identity_rehearsal.sql'
GENERATOR = ROOT / 'scripts/build-tank-link-rehearsal-sql.py'
GUARD = 'public.guard_trip_occurrence_authority_v1()'
ACTION = 'public.apply_trip_occurrence_action_v1(uuid,uuid,bigint,bigint,jsonb)'
# The verify script prints regprocedure text, which omits `public.` when it is on the search_path.
GUARD_KEY = 'guard_trip_occurrence_authority_v1()'
ACTION_KEY = 'apply_trip_occurrence_action_v1(uuid,uuid,bigint,bigint,jsonb)'
KEYS = {GUARD: GUARD_KEY, ACTION: ACTION_KEY}
# Same order and files the authority suite applies, WITHOUT the repair under test.
BASELINE_SQL = [
    'sql/tests/276_trip_occurrence_bootstrap.sql',
    'sql/276_trip_occurrence_authority_v1.sql',
    'sql/277_trip_occurrence_reports_v2.sql',
    'sql/278_trip_occurrence_recovery_v1.sql',
    'sql/occurrence_setup_uuid_case_identity.sql',
]
IMMUTABLE_FIELDS = ('function_owner', 'security_definer', 'function_acl', 'function_search_path')
CONFLICT = 'OCCURRENCE_TANK_LINK_CONFLICT'


def psql(args, timeout=30):
    return subprocess.run([str(A.BIN / 'psql'), '-X', '-v', 'ON_ERROR_STOP=1', '-h', A.SOCKET, '-p', '55439', '-d', 'postgres'] + args,
                          env=A.ENV, text=True, capture_output=True, timeout=timeout)


def run_file(path):
    return psql(['-f', str(path)])


def run_text(text, name='scratch.sql'):
    scratch = Path(A.SOCKET) / name
    scratch.write_text(text)
    return run_file(scratch)


def snapshot():
    """The shipped read-only verify script, parsed. Exercising it here proves it works for the operator."""
    result = psql(['--csv', '-f', str(VERIFY)])
    if result.returncode:
        raise RuntimeError(result.stderr)
    return {row['function_signature']: row for row in csv.DictReader(io.StringIO(result.stdout))}


def rehearsal_report(stderr):
    """The JSON the rehearsal raises: 'ERROR:  REHEARSAL_PASSED_NOTHING_CHANGED: {...}'."""
    marker = 'REHEARSAL_PASSED_NOTHING_CHANGED: '
    start = stderr.index(marker) + len(marker)
    return json.loads(stderr[start:].splitlines()[0])


def function_definition(signature):
    return A.sql(f"select to_jsonb(pg_get_functiondef('{signature}'::regprocedure));", role='super')


def redefine(definition):
    # pg_get_functiondef() has no trailing semicolon; psql needs one to run the statement from a file.
    result = run_text(definition.rstrip() + ';\n', 'redefine.sql')
    if result.returncode:
        raise RuntimeError(result.stderr)


def new_session(upper):
    value = str(uuid.uuid4())
    return value.upper() if upper else value.lower()


def session_docs(ids, ended=True):
    return [{'id': i, 'tankNumber': n + 1, 'startTime': '2026-10-14T08:10:00Z',
             **({'endTime': '2026-10-14T08:40:00Z'} if ended else {})} for n, i in enumerate(ids)]


def stage_sessions(trip, ids, ended=True):
    """What iOS PATCHes: the Trip's tank_sessions array carrying the app's own id text."""
    docs = session_docs(ids, ended)
    A.sql(f"update public.trips set tank_sessions={A.literal(docs)} where id='{trip}';")
    return docs


def done_with_links(trip, coverage, ids, index=0):
    action = A.action(trip, coverage, index, to='done')
    action['tankSessionIds'] = ids
    return A.request(trip, coverage, action)


def finalize(trip, coverage, end='2026-10-14T09:00:00Z'):
    return (f"select public.finalize_trip_occurrences_v1('{uuid.uuid4()}','{trip}',{coverage['revision']},{coverage['planRevision']},"
            f"{A.literal(coverage['states'])},{A.literal({'endTime': end})});")


def trip_row(trip):
    return A.sql(f"select to_jsonb(x) from (select is_active,end_time,tank_sessions,occurrence_coverage from public.trips where id='{trip}') x;")


class TankLinkCaseContract(unittest.TestCase):
    original = None
    original_definitions = None

    @classmethod
    def setUpClass(cls):
        cls.original = snapshot()
        cls.original_definitions = {GUARD: function_definition(GUARD), ACTION: function_definition(ACTION)}

    # -- helpers ---------------------------------------------------------------------------------
    def assert_rejected(self, statement, code, **kwargs):
        result = A.sql(statement, raw=True, **kwargs)
        self.assertNotEqual(result.returncode, 0, f'expected {code}; statement succeeded: {statement[:140]}')
        self.assertIn(code, result.stderr)

    def assert_catalog_identity_unchanged(self, current):
        self.assertEqual(set(current), {GUARD_KEY, ACTION_KEY}, 'verify script must report exactly the guard and the action function')
        for signature, row in current.items():
            for field in IMMUTABLE_FIELDS:
                self.assertEqual(row[field], self.original[signature][field], f'{signature}.{field} must not change')

    def run_ios_flow(self, upper):
        trip, coverage, _ = A.create()
        sessions = [new_session(upper), new_session(upper)]
        stage_sessions(trip, sessions)
        occurrence = [i['occurrenceId'] for i in coverage['items']]
        links = [s.lower() for s in sessions]  # the journal's canonical form
        coverage = A.sql(done_with_links(trip, coverage, links, 0))['coverage']
        self.assertEqual(coverage['states'][occurrence[0]]['tankSessionIds'], links)
        # updateOccurrenceNonAuthorityFields: the app re-sends the same tank_sessions after links exist.
        A.sql(f"update public.trips set tank_sessions={A.literal(session_docs(sessions))},active_tank_number=null,"
              f"is_filling_tank=false,total_tanks=2,total_distance=123.4 where id='{trip}';")
        coverage = A.sql(A.request(trip, coverage, A.action(trip, coverage, 1, to='skipped')))['coverage']
        ended = A.sql(finalize(trip, coverage))
        self.assertFalse(ended['isActive'])
        row = trip_row(trip)
        self.assertFalse(row['is_active'])
        self.assertIsNotNone(row['end_time'])
        self.assertEqual([s['id'] for s in row['tank_sessions']], sessions, 'stored session ids must keep their original text')
        self.assertEqual(row['occurrence_coverage']['states'][occurrence[0]]['tankSessionIds'], links)
        self.assertEqual(row['occurrence_coverage']['states'][occurrence[1]]['tankSessionIds'], [])
        return trip

    # -- 01 --------------------------------------------------------------------------------------
    def test_01_defect_reproduces_with_the_real_ios_wire_shape_before_the_repair(self):
        for signature, row in self.original.items():
            self.assertEqual(row['old_text_comparison_present'], 't', signature)
            self.assertEqual(row['case_insensitive_comparison_present'], 'f', signature)
        # iOS: uppercase stored id, journal link lowercase -> the production failure.
        trip, coverage, _ = A.create()
        session = new_session(upper=True)
        stage_sessions(trip, [session])
        self.assert_rejected(done_with_links(trip, coverage, [session.lower()]), CONFLICT)
        # Control: Android writes lowercase and has never been affected.
        android, android_coverage, _ = A.create()
        lowered = new_session(upper=False)
        stage_sessions(android, [lowered])
        accepted = A.sql(done_with_links(android, android_coverage, [lowered]))['coverage']
        self.assertEqual(accepted['states'][android_coverage['items'][0]['occurrenceId']]['tankSessionIds'], [lowered])

    # -- 00 --------------------------------------------------------------------------------------
    def test_00_rehearsal_is_derived_cannot_commit_and_reports_what_the_repair_would_do(self):
        stale = subprocess.run([sys.executable, str(GENERATOR), '--check'], text=True, capture_output=True)
        self.assertEqual(stale.returncode, 0, stale.stdout + stale.stderr)
        result = run_file(REHEARSAL)
        self.assertNotEqual(result.returncode, 0, 'the rehearsal must always end in an exception')
        self.assertIn('REHEARSAL_PASSED_NOTHING_CHANGED', result.stderr)
        report = rehearsal_report(result.stderr)
        self.assertEqual(report['live_state_before_repair'], {'guard': 'unpatched', 'action': 'unpatched'})
        before = {row['function']: row for row in report['catalog_before']}
        after = {row['function']: row for row in report['catalog_after_inside_this_statement']}
        self.assertEqual(set(before), {GUARD_KEY, ACTION_KEY})
        self.assertEqual(set(after), set(before))
        for key in before:
            self.assertEqual(before[key]['definition_md5'], self.original[key]['definition_md5'],
                             'the rehearsal reads the same catalog the verify script reads')
            self.assertNotEqual(after[key]['definition_md5'], before[key]['definition_md5'],
                                'inside the statement the repair rewrote the function')
            for field in ('owner', 'security_definer', 'acl', 'search_path'):
                self.assertEqual(after[key][field], before[key][field], f'{key}.{field} must not change')
        self.assertEqual(snapshot(), self.original, 'the rehearsal must leave nothing behind')

    # -- 02 --------------------------------------------------------------------------------------
    def test_02_repair_fails_closed_and_changes_nothing_on_unexpected_function_text(self):
        guard, action = self.original_definitions[GUARD], self.original_definitions[ACTION]
        old_guard, old_action = "s->>'id'=linked", "s->>'id'=session_id"
        new_action = "lower(s->>'id')=lower(session_id)"
        self.assertEqual(guard.count(old_guard), 1)
        self.assertEqual(action.count(old_action), 1)
        variants = [
            ('action comparison reformatted (old text absent, new text absent)', ACTION, action.replace(old_action, "s->>'id' = session_id")),
            ('guard comparison present twice', GUARD, guard.replace('  return new;', f"  -- {old_guard}\n  return new;")),
            ('action carries both the old and the new comparison', ACTION, action.replace('  return result;', f"  -- {new_action}\n  return result;")),
        ]
        for label, signature, variant in variants:
            with self.subTest(label):
                self.assertNotEqual(variant, self.original_definitions[signature], 'the variant must differ from the original')
                redefine(variant)
                try:
                    before = snapshot()
                    result = run_file(MIGRATION)
                    self.assertNotEqual(result.returncode, 0, 'the repair must refuse an unexpected definition')
                    self.assertIn('Occurrence tank-link comparison changed', result.stderr)
                    after = snapshot()
                    self.assertEqual({k: v['definition_md5'] for k, v in after.items()},
                                     {k: v['definition_md5'] for k, v in before.items()},
                                     'a refused repair must change neither function (validated before any change)')
                    rehearsal = run_file(REHEARSAL)
                    self.assertNotEqual(rehearsal.returncode, 0)
                    self.assertIn('Occurrence tank-link comparison changed', rehearsal.stderr)
                    self.assertNotIn('REHEARSAL_PASSED_NOTHING_CHANGED', rehearsal.stderr,
                                     'the rehearsal must refuse exactly where the repair refuses')
                finally:
                    redefine(self.original_definitions[signature])
                self.assertEqual(snapshot(), self.original, 'the original definitions must be restored exactly')

    # -- 03 --------------------------------------------------------------------------------------
    def test_03_repair_preserves_catalog_identity_is_idempotent_and_completes_a_half_applied_state(self):
        first = run_file(MIGRATION)
        self.assertEqual(first.returncode, 0, first.stderr)
        applied = snapshot()
        self.assert_catalog_identity_unchanged(applied)
        for signature, row in applied.items():
            self.assertNotEqual(row['definition_md5'], self.original[signature]['definition_md5'], signature)
            self.assertEqual(row['old_text_comparison_present'], 'f', signature)
            self.assertEqual(row['case_insensitive_comparison_present'], 't', signature)
        second = run_file(MIGRATION)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(snapshot(), applied, 're-running the repair must be a no-op')
        already = run_file(REHEARSAL)
        self.assertNotEqual(already.returncode, 0)
        self.assertEqual(rehearsal_report(already.stderr)['live_state_before_repair'],
                         {'guard': 'patched', 'action': 'patched'})
        self.assertEqual(snapshot(), applied, 'a rehearsal on an already repaired database keeps nothing')
        # Half-applied (guard reverted, action patched): re-running completes it.
        redefine(self.original_definitions[GUARD])
        self.assertEqual(snapshot()[GUARD_KEY]['old_text_comparison_present'], 't')
        third = run_file(MIGRATION)
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertEqual(snapshot(), applied)

    # -- 04 / 05 ---------------------------------------------------------------------------------
    def test_04_ios_wire_shape_completes_trip_end_after_the_repair(self):
        self.run_ios_flow(upper=True)

    def test_05_android_wire_shape_is_unchanged(self):
        self.run_ios_flow(upper=False)

    # -- 06 --------------------------------------------------------------------------------------
    def test_06_negative_controls_remain_rejected(self):
        trip, coverage, _ = A.create()
        session = new_session(upper=True)
        stage_sessions(trip, [session])
        flipped = session[:-1] + ('0' if session[-1] != '0' else '1')
        other_trip, _, _ = A.create()
        foreign = new_session(upper=True)
        stage_sessions(other_trip, [foreign])
        cases = {
            'unrecorded session': str(uuid.uuid4()),
            'one hex digit different': flipped.lower(),
            'padded with whitespace': ' ' + session.lower() + ' ',
            'not a uuid': 'not-a-uuid',
            'empty string': '',
            'session recorded only on another Trip': foreign.lower(),
        }
        for label, link in cases.items():
            with self.subTest(label):
                self.assert_rejected(done_with_links(trip, coverage, [link]), CONFLICT)
        untouched = trip_row(trip)['occurrence_coverage']
        self.assertEqual(untouched['revision'], coverage['revision'], 'rejected links must not change the document')
        bare, bare_coverage, _ = A.create()  # no tank_sessions at all
        self.assert_rejected(done_with_links(bare, bare_coverage, [str(uuid.uuid4())]), CONFLICT)
        # The recorded session itself is accepted: the iOS-stored uppercase id with the canonical lowercase link.
        fresh, fresh_coverage, _ = A.create()
        stage_sessions(fresh, [session])
        A.sql(done_with_links(fresh, fresh_coverage, [session.lower()]))

    # -- 07 --------------------------------------------------------------------------------------
    def test_07_linked_session_cannot_be_removed_or_replaced(self):
        trip, coverage, _ = A.create()
        session = new_session(upper=True)
        stage_sessions(trip, [session])
        A.sql(done_with_links(trip, coverage, [session.lower()]))
        end = '2026-10-14T09:00:00Z'
        for label, sessions in {
            'removed': [],
            'replaced by another id': [{'id': str(uuid.uuid4()), 'endTime': end}],
            'id padded': [{'id': session + ' ', 'endTime': end}],
        }.items():
            with self.subTest(label):
                self.assert_rejected(f"update public.trips set tank_sessions={A.literal(sessions)} where id='{trip}';", CONFLICT)
        # The same session re-sent in another letter case is the same identity, not a removal.
        A.sql(f"update public.trips set tank_sessions={A.literal([{'id': session.lower(), 'endTime': end}])} where id='{trip}';")

    # -- 08 --------------------------------------------------------------------------------------
    def test_08_finalise_tank_review_rule_is_unchanged(self):
        trip, coverage, _ = A.create()
        open_session = new_session(upper=True)
        stage_sessions(trip, [open_session], ended=False)
        coverage = A.sql(A.request(trip, coverage, A.action(trip, coverage, 0, to='skipped')))['coverage']
        coverage = A.sql(A.request(trip, coverage, A.action(trip, coverage, 1, to='skipped')))['coverage']
        self.assert_rejected(finalize(trip, coverage), 'OCCURRENCE_TANK_REVIEW_REQUIRED')
        self.assertTrue(trip_row(trip)['is_active'], 'a refused finalise must leave the Trip active')


def main():
    if not (A.BIN / 'initdb').exists():
        raise SystemExit('Local PostgreSQL 17 binaries required. No remote DB will be used.')
    with tempfile.TemporaryDirectory(prefix='vinetrack-tank-link-') as work:
        A.SOCKET = work
        data, log = Path(work) / 'data', Path(work) / 'postgres.log'
        subprocess.run([str(A.BIN / 'initdb'), '-D', str(data), '-A', 'trust', '--no-locale'], env=A.ENV, check=True, capture_output=True)
        subprocess.run([str(A.BIN / 'pg_ctl'), '-D', str(data), '-l', str(log), '-o', f"-k {work} -p 55439 -c listen_addresses=''", '-w', 'start'],
                       env=A.ENV, check=True, capture_output=True)
        try:
            for file in BASELINE_SQL:
                source = ROOT / file
                if file.endswith('_bootstrap.sql'):
                    # Same fixture handling as the authority suite: block-UUID substitution and an absolute include path.
                    fixture = source.read_text().replace('30000000-0000-4000-8000-000000000001', A.BLOCK)
                    fixture = fixture.replace(r"\ir ../006_trips_sync.sql", "\\ir " + str(ROOT / 'sql/006_trips_sync.sql'))
                    source = Path(work) / 'bootstrap.sql'
                    source.write_text(fixture)
                result = run_file(source)
                if result.returncode:
                    raise RuntimeError(f'{file}: {result.stderr}')
            suite = unittest.defaultTestLoader.loadTestsFromTestCase(TankLinkCaseContract)
            outcome = unittest.TextTestRunner(verbosity=2).run(suite)
            if not outcome.wasSuccessful():
                raise SystemExit(1)
        finally:
            subprocess.run([str(A.BIN / 'pg_ctl'), '-D', str(data), '-m', 'immediate', '-w', 'stop'], env=A.ENV, check=True, capture_output=True)


if __name__ == '__main__':
    main()

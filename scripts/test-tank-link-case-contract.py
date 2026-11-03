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
  02b the production APPLY file (one paste: repair + verify + readback) applies, reports the committed
      catalog, writes exactly what the repair writes, is idempotent and completes a half-applied state -
      in the SQL editor's one-query mode and in psql -f mode
  02c the APPLY file turns a session that may not replace the writer-owned functions (the production
      `postgres` topology) into a NORMAL result row with the session, owner and membership facts and
      changes nothing; it applies when PostgreSQL would allow it and says ALREADY_APPLIED when nothing is needed
  02d the APPLY file rolls back everything when owner/ACL/security flag/search_path would change or anything fails
  09  the read-only readback reports the server's Trip End state, never raises and writes nothing
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
import re
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
APPLY = ROOT / 'sql/occurrence_tank_link_uuid_case_identity_apply.sql'
READBACK = ROOT / 'sql/trip_end_recovery_readback.sql'
GENERATOR = ROOT / 'scripts/build-tank-link-rehearsal-sql.py'
INCIDENT_TRIP = '492ebafc-b996-4ec4-8ea9-4261a3056810'
WRITER = 'vinetrack_occurrence_writer'
OPERATOR = 'vinetrack_test_postgres'  # stands in for the project's `postgres` login in the SQL editor
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


# -- the production pastes, run the two ways an operator can run them ---------------------------------
def admin(statement):
    """Superuser statement for harness set-up and clean-up. The cluster is throw-away and socket-only."""
    result = psql(['-q', '-c', statement])
    if result.returncode:
        raise RuntimeError(f'{statement[:160]}: {result.stderr}')


def as_role(role, statement):
    return psql(['-q', '-c', f'set role {role}; {statement}'])


def run_editor(text):
    """The Supabase SQL editor: the whole paste is ONE query string, run as one implicit transaction."""
    return psql(['-q', '--csv', '-c', text], timeout=90)


def run_script(text):
    """psql -f: statement by statement, each statement its own transaction."""
    scratch = Path(A.SOCKET) / 'paste.sql'
    scratch.write_text(text)
    return psql(['-q', '--csv', '-f', str(scratch)], timeout=90)


def one_row(done):
    if done.returncode:
        raise AssertionError(f'the paste failed (rc {done.returncode}): {done.stderr}')
    rows = list(csv.DictReader(io.StringIO(done.stdout)))
    if len(rows) != 1:
        raise AssertionError(f'a paste must return exactly one result row, got {len(rows)}: {done.stdout[:300]}')
    return rows[0]


def paste_text(path, trip=None, prefix='', mutate=None):
    text = path.read_text()
    assert text.count(INCIDENT_TRIP) == 1, f'{path.name} must name the incident Trip exactly once'
    if trip:
        text = text.replace(INCIDENT_TRIP, trip)
    return prefix + (mutate(text) if mutate else text)


def inject_before(text, marker, statement):
    assert text.count(marker) == 1, f'{marker!r} must occur exactly once'
    return text.replace(marker, statement + marker, 1)


def apply_result(runner=run_editor, **kwargs):
    row = one_row(runner(paste_text(APPLY, **kwargs)))
    details = json.loads(row['details'])
    repair = details['repair']
    assert repair['result'] == row['result'], 'the repair must run exactly once per paste: column and details disagree'
    return row['result'], details, repair


def readback_result(trip, runner=run_editor, prefix=''):
    row = one_row(runner(paste_text(READBACK, trip=trip, prefix=prefix)))
    return json.loads(row['readback'])


def md5s(report):
    return {row['function']: row['definition_md5'] for row in report}


def snapshot_md5s(current):
    return {key: row['definition_md5'] for key, row in current.items()}


def real_table_ddl(path, table):
    """The repository's own CREATE TABLE, so the readback is proven against the real columns."""
    match = re.search(rf'create table if not exists public\.{table} \(.*?\n\);', (ROOT / path).read_text(), re.S)
    if not match:
        raise AssertionError(f'{table}: CREATE TABLE not found in {path}')
    return match.group(0)


def table_digest(*tables):
    """One md5 over every row of the named tables, taken by a fresh superuser session: proves a paste wrote nothing."""
    parts = " || '|' || ".join(
        f"(select md5(coalesce(string_agg(x::text, ',' order by x::text), '')) from public.{table} x)" for table in tables)
    return A.sql(f'select to_jsonb({parts});', role='super')


def persistent_vinetrack_functions():
    """The pastes only create session-local (pg_temp) functions: nothing named vinetrack* may exist anywhere else."""
    return A.sql("select to_jsonb(count(*)) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                 "where p.proname like 'vinetrack%' and n.nspname !~ '^pg_temp';", role='super')


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
            ('action comparison reformatted (old text absent, new text absent)', ACTION, action.replace(old_action, "s->>'id' = session_id"), "s->>'id' = session_id"),
            ('guard comparison present twice', GUARD, guard.replace('  return new;', f"  -- {old_guard}\n  return new;"), f"-- {old_guard}"),
            ('action carries both the old and the new comparison', ACTION, action.replace('  return result;', f"  -- {new_action}\n  return result;"), f"-- {new_action}"),
        ]
        for label, signature, variant, fragment in variants:
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
                    # The production paste does not fail red: it returns a NORMAL row that changes nothing and
                    # carries the live comparison lines, in either way an operator can run it.
                    for runner in (run_editor, run_script):
                        result, _, repair = apply_result(runner)
                        self.assertEqual(result, 'NOT_APPLIED_LIVE_FUNCTION_DIFFERS')
                        self.assertFalse(repair['changed'])
                        self.assertIn('unexpected', repair['live_state_before'].values())
                        lines = repair['live_comparison_lines']
                        key = 'guard' if signature == GUARD else 'action'
                        self.assertTrue(any(fragment in line for line in lines[key]),
                                        f'the live line must be returned so no second run is needed: {lines}')
                        self.assertEqual(repair['definition_md5'], {'guard': before[GUARD_KEY]['definition_md5'],
                                                                    'action': before[ACTION_KEY]['definition_md5']})
                        self.assertEqual(snapshot_md5s(snapshot()), snapshot_md5s(before), 'a refusal must change nothing')
                finally:
                    redefine(self.original_definitions[signature])
                self.assertEqual(snapshot(), self.original, 'the original definitions must be restored exactly')

    # -- 02b -------------------------------------------------------------------------------------
    def test_02b_apply_paste_repairs_reports_the_committed_catalog_and_is_idempotent(self):
        # An ACTIVE harness Trip stands in for the incident Trip, so the readback inside the paste has a row to read.
        trip, _, _ = A.create()
        guard, action = self.original_definitions[GUARD], self.original_definitions[ACTION]

        def restore():
            redefine(guard)
            redefine(action)

        try:
            for label, runner in (('SQL editor (one query)', run_editor), ('psql -f (statement by statement)', run_script)):
                with self.subTest(label):
                    restore()
                    self.assertEqual(snapshot(), self.original)
                    result, details, repair = apply_result(runner, trip=trip)
                    self.assertEqual(result, 'APPLIED')
                    self.assertTrue(repair['changed'])
                    self.assertEqual(repair['live_state_before'], {'guard': 'unpatched', 'action': 'unpatched'})
                    self.assertTrue(repair['identity_unchanged'])
                    applied = snapshot()
                    self.assert_catalog_identity_unchanged(applied)
                    for key, row in applied.items():
                        self.assertEqual(row['old_text_comparison_present'], 'f', key)
                        self.assertEqual(row['case_insensitive_comparison_present'], 't', key)
                    # The report describes the catalog that was COMMITTED, not a transient state inside the statement.
                    self.assertEqual(md5s(repair['catalog_before']), snapshot_md5s(self.original))
                    self.assertEqual(md5s(repair['catalog_after']), snapshot_md5s(applied))
                    before_rows = {row['function']: row for row in repair['catalog_before']}
                    for row in repair['catalog_after']:
                        for field in ('owner', 'security_definer', 'acl', 'search_path'):
                            self.assertEqual(row[field], before_rows[row['function']][field], f"{row['function']}.{field}")
                    # The readback travels with the result: this Trip is active, so the server has not ended it.
                    readback = details['original_trip_readback']
                    self.assertEqual(readback['trip_id'], trip)
                    self.assertTrue(readback['trip']['found'])
                    self.assertEqual(readback['trip']['vineyard_id'], A.VINEYARD)
                    self.assertFalse(readback['summary']['trip_ended_on_server'])
                    self.assertEqual([op['kind'] for op in readback['occurrence_operations']['accepted']], ['create'])
                    # The paste writes exactly what the repository repair writes.
                    via_paste = {GUARD: function_definition(GUARD), ACTION: function_definition(ACTION)}
                    restore()
                    migrated = run_file(MIGRATION)
                    self.assertEqual(migrated.returncode, 0, migrated.stderr)
                    self.assertEqual({GUARD: function_definition(GUARD), ACTION: function_definition(ACTION)}, via_paste,
                                     'the paste must write exactly what the repository repair writes')
                    self.assertEqual(snapshot(), applied)
                    # Idempotent, whichever way it is run.
                    for again in (run_editor, run_script):
                        result, _, repair = apply_result(again, trip=trip)
                        self.assertEqual(result, 'ALREADY_APPLIED')
                        self.assertFalse(repair['changed'])
                        self.assertEqual(repair['catalog_before'], repair['catalog_after'])
                        self.assertEqual(snapshot(), applied)
                    # Half applied (guard reverted, action repaired): the paste completes it.
                    redefine(guard)
                    result, _, repair = apply_result(runner, trip=trip)
                    self.assertEqual(result, 'APPLIED')
                    self.assertEqual(repair['live_state_before'], {'guard': 'unpatched', 'action': 'patched'})
                    self.assertEqual(snapshot(), applied)
            # With the repair in place the server completes a Trip End for the iOS wire shape.
            self.run_ios_flow(upper=True)
        finally:
            restore()
        self.assertEqual(snapshot(), self.original)
        self.assertEqual(persistent_vinetrack_functions(), 0)

    # -- 02c -------------------------------------------------------------------------------------
    def test_02c_apply_paste_explains_a_session_that_may_not_replace_the_functions(self):
        # Production topology (docs/reviews/spray-start-yield-recovery-sync-20261101.md): the project's `postgres` login
        # owns the guard, but the action belongs to the NOLOGIN writer role, which `postgres` neither is nor inherits.
        # PostgreSQL then answers 42501 "must be owner of function". OPERATOR stands in for that login.
        guard, action = self.original_definitions[GUARD], self.original_definitions[ACTION]
        guard_owner = self.original[GUARD_KEY]['function_owner']
        self.assertEqual(self.original[ACTION_KEY]['function_owner'], WRITER)
        prefix = f'set role {OPERATOR};\n'
        admin(f'create role {OPERATOR} login createrole bypassrls; grant all on schema public to {OPERATOR}; '
              f'grant select on all tables in schema public to {OPERATOR}')

        def replace_directly(definition):
            return as_role(OPERATOR, definition.rstrip() + ';')

        def refused(label):
            session = None
            for runner in (run_editor, run_script):
                result, details, repair = apply_result(runner, prefix=prefix)
                self.assertEqual(result, 'NOT_APPLIED_ROLE_CANNOT_REPLACE_FUNCTIONS', label)
                self.assertFalse(repair['changed'], label)
                self.assertEqual(repair['role'], OPERATOR)
                self.assertEqual(snapshot_md5s(snapshot()), snapshot_md5s(self.original),
                                 f'{label}: a refused paste must change neither function, not even one it could replace')
                self.assertIn('original_trip_readback', details)
                session = repair['session']
            return session

        def by_function(session):
            return {row['function']: row for row in session['functions']}

        try:
            # A. Owns nothing and belongs to no role: what production's `postgres` showed on 1 Nov (42501).
            direct = replace_directly(action)
            self.assertNotEqual(direct.returncode, 0)
            self.assertIn('must be owner of function', direct.stderr, "the harness must reproduce production's 42501")
            session = refused('A: no ownership, no membership')
            self.assertEqual(session['current_user'], OPERATOR)
            self.assertFalse(session['current_role_attributes']['rolsuper'])
            self.assertTrue(session['may_create_in_schema_public'])
            facts = by_function(session)
            self.assertEqual(set(facts), {GUARD_KEY, ACTION_KEY})
            self.assertEqual(facts[ACTION_KEY]['owner'], WRITER)
            self.assertEqual(facts[GUARD_KEY]['owner'], guard_owner)
            for row in facts.values():
                self.assertFalse(row['session_is_member_of_owner'])
                self.assertFalse(row['session_has_owner_privileges'])
            self.assertEqual(session['session_role_memberships'], [])
            self.assertIn(ACTION_KEY, [row['function'] for row in session['occurrence_functions']])

            # B. Owns the guard and is a member of the writer WITHOUT inheriting its privileges: still refused, and
            #    the guard it COULD replace stays untouched (both are validated before either is changed).
            admin(f'alter function {GUARD} owner to {OPERATOR}')
            admin(f'grant {WRITER} to {OPERATOR} with inherit false, set false')
            self.assertIn('must be owner of function', replace_directly(action).stderr)
            session = refused('B: owns the guard, member of the writer without inheriting it')
            facts = by_function(session)
            self.assertTrue(facts[GUARD_KEY]['session_has_owner_privileges'])
            self.assertTrue(facts[ACTION_KEY]['session_is_member_of_owner'])
            self.assertFalse(facts[ACTION_KEY]['session_has_owner_privileges'])
            self.assertEqual(session['session_role_memberships'], [WRITER])
            membership = [row for row in session['owner_role_memberships'] if row['member'] == OPERATOR]
            self.assertEqual(len(membership), 1)
            self.assertEqual((membership[0]['role'], membership[0]['inherit_option'], membership[0]['set_option']),
                             (WRITER, False, False))
            self.assertEqual({row['owner']: row['session_can_set_role_to_owner'] for row in session['set_role_to_owner']},
                             {OPERATOR: True, WRITER: False})

            # C. Inherits the writer's privileges (what PostgreSQL itself requires): a plain non-superuser applies it.
            admin(f'revoke {WRITER} from {OPERATOR}')
            admin(f'grant {WRITER} to {OPERATOR} with inherit true, set false')
            result, _, repair = apply_result(run_editor, prefix=prefix)
            self.assertEqual(result, 'APPLIED', repair)
            self.assertTrue(repair['changed'])
            self.assertTrue(repair['identity_unchanged'])
            applied = snapshot()
            self.assertEqual(md5s(repair['catalog_after']), snapshot_md5s(applied))
            self.assertEqual({key: row['function_owner'] for key, row in applied.items()},
                             {GUARD_KEY: OPERATOR, ACTION_KEY: WRITER}, 'owners must be preserved')
            for key, row in applied.items():
                self.assertEqual(row['case_insensitive_comparison_present'], 't', key)
            result, _, repair = apply_result(run_script, prefix=prefix)
            self.assertEqual(result, 'ALREADY_APPLIED')
            self.assertFalse(repair['changed'])

            # D. May act as the owners but may not create in the schema: refused, with that fact reported.
            restore_both = (guard, action)
            for definition in restore_both:
                redefine(definition)
            self.assertEqual(snapshot_md5s(snapshot()), snapshot_md5s(self.original))
            admin(f'revoke create on schema public from {OPERATOR}')
            self.assertIn('permission denied for schema public', replace_directly(guard).stderr)
            session = refused('D: may act as the owners but not create in the schema')
            self.assertFalse(session['may_create_in_schema_public'])

            # E. Nothing to replace: an already repaired pair is reported as such, for a session with no privileges at all.
            admin(f'revoke {WRITER} from {OPERATOR}')
            migrated = run_file(MIGRATION)
            self.assertEqual(migrated.returncode, 0, migrated.stderr)
            result, _, repair = apply_result(run_editor, prefix=prefix)
            self.assertEqual(result, 'ALREADY_APPLIED')
            self.assertFalse(repair['changed'])
        finally:
            for statement in (f'revoke {WRITER} from {OPERATOR}',
                              f'alter function {GUARD} owner to "{guard_owner}"',
                              f'drop owned by {OPERATOR}',
                              f'drop role {OPERATOR}'):
                psql(['-q', '-c', statement])
            redefine(guard)
            redefine(action)
        self.assertEqual(snapshot(), self.original)
        self.assertEqual(persistent_vinetrack_functions(), 0)

    # -- 02d -------------------------------------------------------------------------------------
    def test_02d_apply_paste_rolls_back_everything_when_anything_goes_wrong(self):
        flag = 'security invoker' if self.original[GUARD_KEY]['security_definer'] == 't' else 'security definer'
        after_marker = '  after_report := (\n'
        breaks = {
            'search_path changed': f'alter function {GUARD} set search_path = pg_catalog, public, extensions',
            'security flag flipped': f'alter function {GUARD} {flag}',
            'grant added': f'grant execute on function {GUARD} to fixture_client',
        }
        for label, statement in breaks.items():
            with self.subTest(label):
                injected = f"  execute '{statement}';\n"
                for runner in (run_editor, run_script):
                    done = runner(paste_text(APPLY, mutate=lambda text: inject_before(text, after_marker, injected)))
                    self.assertNotEqual(done.returncode, 0, 'the paste must fail red when the catalog identity would change')
                    self.assertIn('would change owner, grants, security flag or search_path', done.stderr)
                    self.assertEqual(snapshot(), self.original, 'a failed paste must leave NOTHING behind')
                rehearsal = run_text(inject_before(REHEARSAL.read_text(), after_marker, injected))
                self.assertNotEqual(rehearsal.returncode, 0)
                self.assertIn('REHEARSAL_FAILED_CATALOG_IDENTITY_CHANGED', rehearsal.stderr)
                self.assertEqual(snapshot(), self.original)
        # Any failure AFTER both functions were rewritten discards the rewrite as well.
        forced = ("  raise exception 'forced failure after the rewrite: action md5 %', "
                  f"md5(pg_get_functiondef('{ACTION}'::regprocedure));\n")
        for runner in (run_editor, run_script):
            done = runner(paste_text(APPLY, mutate=lambda text: inject_before(text, '  -- Post-condition', forced)))
            self.assertNotEqual(done.returncode, 0)
            match = re.search(r'forced failure after the rewrite: action md5 ([0-9a-f]{32})', done.stderr)
            self.assertIsNotNone(match, done.stderr)
            self.assertNotEqual(match.group(1), self.original[ACTION_KEY]['definition_md5'],
                                'by then the action had been rewritten ...')
            self.assertEqual(snapshot(), self.original, '... and the failure rolled the rewrite back')
        self.assertEqual(persistent_vinetrack_functions(), 0)

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

    # -- 09 --------------------------------------------------------------------------------------
    def test_09_readback_is_read_only_never_raises_and_reports_the_server_state(self):
        # Static: outside comments there is no data or privilege statement, and only session-local functions.
        def code(path):
            return '\n'.join(line for line in path.read_text().splitlines() if not line.lstrip().startswith('--'))

        def creates(path):
            return re.findall(r'\bcreate\s+or\s+replace\s+function\s+([\w.]+)', code(path), re.I)

        forbidden = r'\b(?:insert|update|delete|drop|truncate|alter|grant|revoke|copy|vacuum)\b'
        for path in (READBACK, APPLY):
            self.assertEqual(re.findall(forbidden, code(path), re.I), [], f'{path.name} must contain no data or privilege statement')
        self.assertEqual(creates(READBACK), ['pg_temp.vinetrack_trip_readback'])
        self.assertEqual(len(re.findall(r'\bcreate\b', code(READBACK), re.I)), 1)
        self.assertEqual(creates(APPLY), ['pg_temp.vinetrack_session_facts', 'pg_temp.vinetrack_apply_tank_link_repair',
                                          'pg_temp.vinetrack_trip_readback'])

        # A Trip that does not exist is reported, not raised.
        missing = readback_result(str(uuid.uuid4()))
        self.assertEqual(missing['trip'], {'found': False})
        self.assertFalse(missing['summary']['trip_ended_on_server'])

        # The server state after the iOS flow: ended, original (uppercase) session ids, lowercase links, four operations.
        trip = self.run_ios_flow(upper=True)
        stored = [s['id'] for s in trip_row(trip)['tank_sessions']]
        digest_before = table_digest('trips', 'trip_occurrence_operations')
        for label, runner in (('SQL editor (one query)', run_editor), ('psql -f', run_script)):
            with self.subTest(label):
                readback = readback_result(trip, runner)
                self.assertEqual(readback['trip_id'], trip)
                facts = readback['trip']
                self.assertTrue(facts['found'])
                self.assertIs(facts['is_active'], False)
                self.assertTrue(facts['end_time'].startswith('2026-10-14T09:00:00'), facts['end_time'])
                self.assertIsNone(facts['deleted_at'])
                self.assertEqual(facts['vineyard_id'], A.VINEYARD)
                self.assertEqual(facts['tank_session_ids'], sorted(stored), 'the stored session ids keep the app text')
                self.assertEqual(facts['occurrence_linked_tank_session_ids'], sorted(s.lower() for s in stored))
                self.assertEqual(facts['occurrence_status_counts'], {'done': 1, 'skipped': 1})
                self.assertIs(readback['summary']['trip_ended_on_server'], True)
                self.assertEqual(readback['summary']['tank_session_count'], 2)
                operations = readback['occurrence_operations']
                self.assertEqual(operations['count'], 4)
                accepted = operations['accepted']
                self.assertEqual([(op['kind'], op['to_status'], op['resulting_status']) for op in accepted],
                                 [('create', None, None), ('setStatus', 'done', 'done'),
                                  ('setStatus', 'skipped', 'skipped'), ('finalize', None, None)])
                self.assertEqual(sorted(accepted[1]['linked_tank_session_ids']), sorted(s.lower() for s in stored))
                self.assertEqual(accepted[3]['requested_end_time'], '2026-10-14T09:00:00Z')
                self.assertTrue(accepted[3]['result_end_time'].startswith('2026-10-14T09:00:00'), accepted[3]['result_end_time'])
                self.assertEqual(accepted[3]['result_is_active'], 'false')
                # Neither Spray table exists in this harness yet: each section says so and the summary says -1.
                self.assertEqual(readback['tank_actuals']['sqlstate'], '42P01')
                self.assertEqual(readback['spray_records']['sqlstate'], '42P01')
                self.assertEqual(readback['summary']['tank_actual_count'], -1)
                self.assertEqual(readback['summary']['spray_completed_count'], -1)
        self.assertEqual(table_digest('trips', 'trip_occurrence_operations'), digest_before, 'the readback must write nothing')

        # A table with the wrong columns is reported inside its own section and hides nothing else.
        admin('create table public.spray_tank_actuals (id uuid)')
        try:
            readback = readback_result(trip)
            self.assertEqual(readback['tank_actuals']['sqlstate'], '42703')
            self.assertEqual(readback['summary']['tank_actual_count'], -1)
            self.assertIs(readback['summary']['trip_ended_on_server'], True)
        finally:
            admin('drop table public.spray_tank_actuals')

        # The repository's REAL Spray tables: every column the readback names must exist, and the counts must be right.
        created = run_text(real_table_ddl('sql/007_spray_records_sync.sql', 'spray_records') + '\n'
                           + real_table_ddl('sql/223_spray_tank_actuals.sql', 'spray_tank_actuals'), 'spray-tables.sql')
        self.assertEqual(created.returncode, 0, created.stderr)
        try:
            record, template, withdrawn = (str(uuid.uuid4()) for _ in range(3))
            third_session = new_session(upper=True)
            admin(f"insert into public.spray_records (id, vineyard_id, trip_id, start_time, is_template) values "
                  f"('{record}', '{A.VINEYARD}', '{trip}', '2026-10-14T08:00:00Z', false), "
                  f"('{template}', '{A.VINEYARD}', '{trip}', null, true)")
            admin(f"insert into public.spray_records (id, vineyard_id, trip_id, start_time, end_time, is_template, deleted_at) values "
                  f"('{withdrawn}', '{A.VINEYARD}', '{trip}', '2026-10-14T07:00:00Z', '2026-10-14T07:30:00Z', false, now())")
            values = [(str(uuid.uuid4()), stored[0], 1, 41.5, False), (str(uuid.uuid4()), stored[1], 2, 38.25, False),
                      (str(uuid.uuid4()), third_session, 3, 10, True)]
            admin('insert into public.spray_tank_actuals (id, vineyard_id, spray_record_id, trip_id, tank_session_id, tank_number, '
                  'water_volume_l, confirmed_at, confirmed_by, client_updated_at, deleted_at) values ' + ', '.join(
                      f"('{i}', '{A.VINEYARD}', '{record}', '{trip}', '{s}', {n}, {w}, '2026-10-14T08:45:00Z', '{A.ACTOR}', "
                      f"'2026-10-14T08:45:00Z', {'now()' if gone else 'null'})" for i, s, n, w, gone in values))
            digest_before = table_digest('trips', 'trip_occurrence_operations', 'spray_records', 'spray_tank_actuals')
            for label, runner in (('SQL editor (one query)', run_editor), ('psql -f', run_script)):
                with self.subTest(f'spray tables, {label}'):
                    readback = readback_result(trip, runner)
                    actuals = readback['tank_actuals']
                    self.assertEqual(actuals['count'], 2, 'a withdrawn (soft-deleted) actual is not counted')
                    self.assertEqual([(row['tank_number'], row['tank_session_id'], row['water_volume_l']) for row in actuals['rows']],
                                     [(1, stored[0], 41.5), (2, stored[1], 38.25)])
                    self.assertEqual({row['spray_record_id'] for row in actuals['rows']}, {record})
                    spray = readback['spray_records']
                    self.assertEqual(spray['count'], 2, 'templates are excluded; the withdrawn record is listed')
                    self.assertEqual(spray['completed_count'], 0, 'an open record, and a withdrawn completed one, do not count')
                    self.assertEqual({row['id'] for row in spray['rows']}, {record, withdrawn})
                    self.assertEqual(readback['summary']['tank_actual_count'], 2)
                    self.assertEqual(readback['summary']['spray_completed_count'], 0)
                    self.assertIs(readback['summary']['trip_ended_on_server'], True)
            self.assertEqual(table_digest('trips', 'trip_occurrence_operations', 'spray_records', 'spray_tank_actuals'),
                             digest_before, 'the readback must write nothing')
            admin(f"update public.spray_records set end_time = '2026-10-14T09:00:00Z' where id = '{record}'")
            readback = readback_result(trip)
            self.assertEqual(readback['spray_records']['completed_count'], 1)
            self.assertEqual(readback['summary']['spray_completed_count'], 1)
            # A session that may read nothing gets a section error for every section, never a raised error.
            admin('create role vinetrack_test_nogrant login')
            try:
                denied = readback_result(trip, prefix='set role vinetrack_test_nogrant;\n')
            finally:
                psql(['-q', '-c', 'drop owned by vinetrack_test_nogrant; drop role vinetrack_test_nogrant'])
            for section in ('trip', 'occurrence_operations', 'tank_actuals', 'spray_records'):
                self.assertEqual(denied[section]['sqlstate'], '42501', section)
            self.assertIs(denied['summary']['trip_ended_on_server'], False)
            self.assertEqual(denied['summary']['tank_actual_count'], -1)
            self.assertEqual(denied['summary']['spray_completed_count'], -1)
        finally:
            admin('drop table if exists public.spray_tank_actuals; drop table if exists public.spray_records')
        self.assertEqual(persistent_vinetrack_functions(), 0)


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

#!/usr/bin/env python3
"""Disposable PostgreSQL tests of real Issue54 migrations; never accepts a DB URL.
Requires local PostgreSQL binaries, or --pg-root pointing at unpacked packages.
Only the auth/membership and unrelated parent/projection tables are fixtures.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
V = '10000000-0000-0000-0000-000000000001'
FOREIGN = '10000000-0000-0000-0000-000000000002'
BLOCK = '20000000-0000-0000-0000-000000000001'
OP = '30000000-0000-0000-0000-000000000001'
LEAD = '30000000-0000-0000-0000-000000000002'
OUTSIDER = '30000000-0000-0000-0000-000000000003'

def ident():
    return str(uuid.uuid4())

def quote(value):
    return "'" + str(value).replace("'", "''") + "'"

class SecurityTests(unittest.TestCase):
    @classmethod
    def sql(cls, query, user=LEAD, ok=True):
        prefix = '' if user is None else f"SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','{user}',false);"
        result = subprocess.run(cls.command + ['-c', prefix + query], text=True, capture_output=True, env=cls.env)
        if ok and result.returncode:
            raise AssertionError(result.stderr + '\n' + query)
        if not ok and result.returncode == 0:
            raise AssertionError('Expected server rejection: ' + query)
        return result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ''

    def session(self, completed=False, vineyard=V, payload=None):
        sid = ident()
        body = payload or {'isCompleted': completed, 'countMethod': 'per_vine', 'sampleSites': []}
        self.sql(f"INSERT INTO yield_estimation_sessions(id,vineyard_id,payload,is_completed,completed_at) VALUES('{sid}','{vineyard}',{quote(json.dumps(body))}::jsonb,{str(completed).lower()},{'now()' if completed else 'NULL'})", user=None)
        return sid

    def sites(self):
        block, key, first, second, physical, row, copied = [ident() for _ in range(7)]
        self.sql(f"INSERT INTO paddocks(id,vineyard_id) VALUES('{block}','{V}')", user=None)
        self.sql(f"INSERT INTO yield_sample_site_sets(id,vineyard_id,paddock_id,set_key,version) VALUES('{first}','{V}','{block}','{key}',1)")
        self.sql(f"INSERT INTO yield_sample_sites(id,site_set_id,vineyard_id,paddock_id,site_id,site_number,name,latitude,longitude) VALUES('{row}','{first}','{V}','{block}','{physical}',1,'Sample 1',-34,149)")
        self.sql(f"SELECT id FROM confirm_yield_sample_site_set('{first}',1)")
        self.sql(f"INSERT INTO yield_sample_site_sets(id,vineyard_id,paddock_id,set_key,version) VALUES('{second}','{V}','{block}','{key}',2)")
        self.sql(f"INSERT INTO yield_sample_sites(id,site_set_id,vineyard_id,paddock_id,site_id,site_number,name,latitude,longitude) VALUES('{copied}','{second}','{V}','{block}','{physical}',1,'Sample 1',-34,149)")
        return block, first, second, physical, row, copied

    def delete_session(self, sid, completed=False, user=OP, ok=True, vineyard=V):
        return self.sql(f"SELECT hard_delete_yield_estimation_session('{sid}','{vineyard}',{str(completed).lower()})", user, ok)

    def test_operator_draft_delete_receipt_absence_and_idempotence(self):
        sid = self.session()
        self.assertEqual('t', self.delete_session(sid))
        self.assertEqual('t', self.delete_session(sid))
        self.assertEqual('0', self.sql(f"SELECT count(*) FROM yield_estimation_sessions WHERE id='{sid}'"))
        self.assertEqual('1', self.sql(f"SELECT count(*) FROM yield_estimation_session_deletion_receipts WHERE session_id='{sid}' AND NOT was_completed"))

    def test_operator_cannot_delete_completed_rpc_or_direct(self):
        sid = self.session(True)
        self.delete_session(sid, True, ok=False)
        self.sql(f"DELETE FROM yield_estimation_sessions WHERE id='{sid}'", OP)
        self.assertEqual('1', self.sql(f"SELECT count(*) FROM yield_estimation_sessions WHERE id='{sid}'"))

    def test_completed_nonpanel_cannot_be_downgraded_or_reidentified(self):
        for method in ('per_vine', 'quadrant'):
            sid = self.session(True, payload={'isCompleted': True, 'countMethod': method})
            self.sql(f"UPDATE yield_estimation_sessions SET is_completed=false,payload='{{\"isCompleted\":false}}' WHERE id='{sid}'", OP, False)
            self.sql(f"UPDATE yield_estimation_sessions SET id='{ident()}' WHERE id='{sid}'", OP, False)
            self.sql(f"UPDATE yield_estimation_sessions SET vineyard_id='{FOREIGN}' WHERE id='{sid}'", LEAD, False)

    def test_leadership_completed_delete_and_projection_invalidation(self):
        for direct in (True, False):
            sid = self.session(True)
            self.sql(f"INSERT INTO season_yield_estimates(vineyard_id,source_session_id,estimate_source,base_estimate_tonnes,is_estimate_available) VALUES('{V}','{sid}','bunch_count',12,true)", user=None)
            if direct:
                self.sql(f"DELETE FROM yield_estimation_sessions WHERE id='{sid}'")
            else:
                self.delete_session(sid, True, LEAD)
            self.assertEqual('0', self.sql(f"SELECT count(*) FROM season_yield_estimates WHERE source_session_id='{sid}'", user=None))
            self.assertEqual('1', self.sql(f"SELECT count(*) FROM yield_estimation_session_deletion_receipts WHERE session_id='{sid}' AND was_completed"))

    def test_manager_and_owner_can_delete_confirmed_sites_and_sessions(self):
        for user in ('30000000-0000-0000-0000-000000000004', '30000000-0000-0000-0000-000000000005'):
            sid = self.session(True)
            self.assertEqual('t', self.delete_session(sid, True, user))
            self.assertEqual('0', self.sql(f"SELECT count(*) FROM yield_estimation_sessions WHERE id='{sid}'"))
            _, first, _, _, row, _ = self.sites()
            self.assertEqual('t', self.sql(f"SELECT hard_delete_yield_sample_site('{row}','{first}','{V}','confirmed')", user))
            self.assertEqual('0', self.sql(f"SELECT count(*) FROM yield_sample_sites WHERE id='{row}'"))

    def test_stale_completion_and_foreign_membership_rejected(self):
        sid = self.session(True)
        self.delete_session(sid, False, LEAD, False)
        self.delete_session(sid, True, OUTSIDER, False)
        self.delete_session(sid, True, LEAD, False, FOREIGN)
        self.assertEqual('0', self.sql('SELECT count(*) FROM yield_estimation_session_deletion_receipts', OUTSIDER))

    def test_local_only_draft_gets_durable_receipt_and_replay_is_rejected(self):
        sid = ident()
        self.assertEqual('t', self.delete_session(sid))
        self.sql(f"INSERT INTO yield_estimation_sessions(id,vineyard_id,payload) VALUES('{sid}','{V}','{{}}')", OP, False)
        self.assertEqual('f', self.delete_session(ident(), True, LEAD))

    def test_foreign_id_cannot_be_reserved(self):
        sid = self.session(vineyard=FOREIGN)
        self.delete_session(sid, False, OP, False)
        self.assertEqual('0', self.sql(f"SELECT count(*) FROM yield_estimation_session_deletion_receipts WHERE session_id='{sid}'", user=None))

    def test_receipts_are_not_client_writable(self):
        sid = ident()
        self.sql(f"INSERT INTO yield_estimation_session_deletion_receipts VALUES('{sid}','{V}',false,'{OP}',now())", OP, False)
        self.sql('DELETE FROM yield_sample_site_deletion_receipts', LEAD, False)

    def test_confirmed_site_delete_removes_copied_draft_but_preserves_observations(self):
        block, first, second, physical, row, copied = self.sites()
        body = {'isCompleted': True, 'countMethod': 'per_vine', 'sampleSites': [{'id': physical, 'latitude': -34, 'longitude': 149, 'rowNumber': 12, 'yieldPanelReference': 'P3'}]}
        sid = self.session(True, payload=body)
        before = self.sql(f"SELECT payload FROM yield_estimation_sessions WHERE id='{sid}'")
        self.assertEqual('t', self.sql(f"SELECT hard_delete_yield_sample_site('{row}','{first}','{V}','confirmed')"))
        self.assertEqual('0', self.sql(f"SELECT count(*) FROM yield_sample_sites WHERE id IN ('{row}','{copied}')"))
        self.assertEqual('2', self.sql(f"SELECT count(*) FROM yield_sample_site_deletion_receipts WHERE site_id='{physical}'"))
        self.assertEqual(before, self.sql(f"SELECT payload FROM yield_estimation_sessions WHERE id='{sid}'"))
        self.sql(f"SELECT confirm_yield_sample_site_set('{second}',2)", LEAD, False)
        self.sql(f"INSERT INTO yield_sample_sites(id,site_set_id,vineyard_id,paddock_id,site_id,site_number,name,latitude,longitude) VALUES('{ident()}','{second}','{V}','{block}','{physical}',1,'replay',-34,149)", LEAD, False)

    def test_draft_delete_blocks_fresh_row_uuid_in_same_revision_only(self):
        block, first, second, physical, row, copied = self.sites()
        self.assertEqual('t', self.sql(f"SELECT hard_delete_yield_sample_site('{copied}','{second}','{V}','draft')", OP))
        self.assertEqual('1', self.sql(f"SELECT count(*) FROM yield_sample_sites WHERE id='{row}'"))
        self.sql(f"INSERT INTO yield_sample_sites(id,site_set_id,vineyard_id,paddock_id,site_id,site_number,latitude,longitude) VALUES('{ident()}','{second}','{V}','{block}','{physical}',1,-34,149)", OP, False)

    def test_operator_confirmed_site_api_and_direct_delete_denied(self):
        _, first, _, _, row, _ = self.sites()
        self.sql(f"SELECT hard_delete_yield_sample_site('{row}','{first}','{V}','confirmed')", OP, False)
        self.sql(f"DELETE FROM yield_sample_sites WHERE id='{row}'", OP)
        self.assertEqual('1', self.sql(f"SELECT count(*) FROM yield_sample_sites WHERE id='{row}'"))
        self.sql(f"SELECT hard_delete_yield_sample_site('{row}','{first}','{V}','draft')", LEAD, False)

    def test_direct_set_confirmation_cannot_reconfirm_tombstoned_site(self):
        # Simulate a pre-migration copied draft remaining beside an old receipt.
        _, _, second, physical, _, copied = self.sites()
        self.sql(f"INSERT INTO yield_sample_site_deletion_receipts(deleted_row_id,site_set_id,site_id,vineyard_id,paddock_id,was_confirmed,deleted_by) SELECT '{ident()}',site_set_id,site_id,vineyard_id,paddock_id,true,'{LEAD}' FROM yield_sample_sites WHERE id='{copied}'", user=None)
        self.sql(f"UPDATE yield_sample_site_sets SET status='confirmed' WHERE id='{second}'", LEAD, False)
        self.sql(f"UPDATE yield_sample_sites SET name='stale edit' WHERE id='{copied}'", LEAD, False)

    def test_repeatable_read_writes_fail_closed(self):
        self.sql(f"BEGIN ISOLATION LEVEL REPEATABLE READ; INSERT INTO yield_estimation_sessions(id,vineyard_id,payload) VALUES('{ident()}','{V}','{{}}'); COMMIT", OP, False)

    def test_inflight_upload_then_delete_is_atomic(self):
        sid = ident()
        # First transaction uploads while owning the identity lock. The delete
        # must wait, observe the committed upload and physically remove it.
        args = self.command + ['-c', f"SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','{OP}',false); BEGIN; INSERT INTO yield_estimation_sessions(id,vineyard_id,payload) VALUES('{sid}','{V}','{{}}'); SELECT pg_sleep(1); COMMIT;"]
        upload = subprocess.Popen(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event='PgSleep'", user=None) != '0':
                break
            if upload.poll() is not None:
                self.fail('Upload fixture did not acquire the lock: ' + str(upload.communicate()))
        else:
            upload.kill()
            self.fail('Timed out waiting for upload lock')
        self.assertEqual('t', self.delete_session(sid))
        _, error = upload.communicate(timeout=10)
        self.assertEqual(0, upload.returncode, error)
        self.assertEqual('0', self.sql(f"SELECT count(*) FROM yield_estimation_sessions WHERE id='{sid}'"))
        self.assertEqual('1', self.sql(f"SELECT count(*) FROM yield_estimation_session_deletion_receipts WHERE session_id='{sid}'"))

    def begin_sleeping_transaction(self, query, user=LEAD):
        args = self.command + ['-c', f"SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','{user}',false); BEGIN; {query}; SELECT pg_sleep(2); COMMIT;"]
        process = subprocess.Popen(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event='PgSleep'", user=None) != '0':
                return process
            if process.poll() is not None:
                self.fail('Concurrent fixture failed: ' + str(process.communicate()))
            time.sleep(0.01)
        self.fail('Concurrent fixture did not acquire its lock')

    def finish_transaction(self, process):
        _, error = process.communicate(timeout=10)
        self.assertEqual(0, process.returncode, error)

    def test_delete_first_blocks_inflight_upload_and_later_replay(self):
        sid = ident()
        deletion = self.begin_sleeping_transaction(f"SELECT hard_delete_yield_estimation_session('{sid}','{V}',false)", OP)
        insert = f"INSERT INTO yield_estimation_sessions(id,vineyard_id,payload) VALUES('{sid}','{V}','{{}}')"
        self.sql(insert, OP, False)
        self.finish_transaction(deletion)
        self.sql(insert, OP, False)
        self.assertEqual('0', self.sql(f"SELECT count(*) FROM yield_estimation_sessions WHERE id='{sid}'"))
        self.assertEqual('1', self.sql(f"SELECT count(*) FROM yield_estimation_session_deletion_receipts WHERE session_id='{sid}'"))

    def test_site_scope_contention_fails_closed_without_deadlock(self):
        _, first, second, physical, row, copied = self.sites()
        deletion = self.begin_sleeping_transaction(f"SELECT hard_delete_yield_sample_site('{row}','{first}','{V}','confirmed')")
        # Confirmation holds the parent tuple before its scope trigger. It must
        # abort immediately rather than wait behind the deleting transaction.
        self.sql(f"UPDATE yield_sample_site_sets SET status='confirmed' WHERE id='{second}'", LEAD, False)
        self.finish_transaction(deletion)
        self.assertEqual('0', self.sql(f"SELECT count(*) FROM yield_sample_sites WHERE id IN ('{row}','{copied}')"))
        self.assertEqual('2', self.sql(f"SELECT count(*) FROM yield_sample_site_deletion_receipts WHERE site_id='{physical}'"))

    def test_legacy_wrapper_waits_for_identity_before_taking_row_lock(self):
        sid = self.session()
        holder = self.begin_sleeping_transaction(f"SELECT pg_advisory_xact_lock(hashtextextended('yield-session:{sid}',0))")
        args = self.command + ['-c', f"SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','{OP}',false); SELECT hard_delete_yield_estimation_session_by_id('{sid}');"]
        legacy = subprocess.Popen(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        self.addCleanup(lambda: legacy.kill() if legacy.poll() is None else None)
        deadline = time.monotonic() + 1.5
        while time.monotonic() < deadline:
            if self.sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event='advisory'", user=None) != '0':
                break
            time.sleep(0.01)
        else:
            self.fail('Legacy wrapper did not wait on the identity lock')
        # Under the old wrapper this NOWAIT probe failed: legacy already held
        # the tuple while waiting for the advisory lock, enabling a deadlock.
        self.assertEqual(sid, self.sql(f"SELECT id FROM yield_estimation_sessions WHERE id='{sid}' FOR UPDATE NOWAIT", user=None))
        self.finish_transaction(holder)
        self.finish_transaction(legacy)
        self.assertEqual('0', self.sql(f"SELECT count(*) FROM yield_estimation_sessions WHERE id='{sid}'"))
        self.assertEqual('1', self.sql(f"SELECT count(*) FROM yield_estimation_session_deletion_receipts WHERE session_id='{sid}'"))
        confirmed = self.session(True)
        self.sql(f"SELECT hard_delete_yield_estimation_session_by_id('{confirmed}')", OP, False)
        self.delete_session(confirmed, True, LEAD)
        self.sql(f"SELECT hard_delete_yield_estimation_session_by_id('{confirmed}')", OP, False)

    def test_draft_confirmation_first_rejects_stale_draft_delete(self):
        _, _, second, _, _, copied = self.sites()
        confirmation = self.begin_sleeping_transaction(f"SELECT confirm_yield_sample_site_set('{second}',2)")
        self.sql(f"SELECT hard_delete_yield_sample_site('{copied}','{second}','{V}','draft')", OP, False)
        self.finish_transaction(confirmation)
        self.assertEqual('1', self.sql(f"SELECT count(*) FROM yield_sample_sites WHERE id='{copied}'"))
        self.assertEqual('0', self.sql(f"SELECT count(*) FROM yield_sample_site_deletion_receipts WHERE deleted_row_id='{copied}'"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pg-root', type=Path)
    args = parser.parse_args()
    env = os.environ.copy()
    if args.pg_root:
        pg = args.pg_root.resolve()
        bindir = pg / 'usr/lib/postgresql/17/bin'
        env['LD_LIBRARY_PATH'] = str(pg / 'usr/lib/x86_64-linux-gnu') + ':/usr/lib/x86_64-linux-gnu'
    else:
        pg_config = shutil.which('pg_config')
        bindir = Path(subprocess.check_output([pg_config, '--bindir'], text=True).strip()) if pg_config else Path('/usr/lib/postgresql/16/bin')
    if not (bindir / 'initdb').exists():
        parser.error('Local PostgreSQL binaries required; no remote/production database is permitted.')
    with tempfile.TemporaryDirectory(prefix='issue54-pg-', dir=os.environ.get('TMPDIR')) as temp:
        temp = Path(temp)
        data, socket = temp / 'data', temp / 'socket'
        socket.mkdir()
        subprocess.run([str(bindir/'initdb'), '-D', str(data), '-A', 'trust', '--no-locale'], env=env, check=True, stdout=subprocess.DEVNULL)
        subprocess.run([str(bindir/'pg_ctl'), '-D', str(data), '-l', str(temp/'postgres.log'), '-o', f"-k {socket} -h '' -p 55454", '-w', 'start'], env=env, check=True)
        SecurityTests.command = [str(bindir/'psql'), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', str(socket), '-p', '55454', '-d', 'postgres']
        SecurityTests.env = env
        try:
            SecurityTests.sql((ROOT/'scripts/issue54_security_fixture.sql').read_text(), user=None)
            base = (ROOT/'sql/014_work_maintenance_yield_sync.sql').read_text()
            SecurityTests.sql(base[base.index('create table if not exists public.yield_estimation_sessions ('):base.index('-- damage_records')], user=None)
            SecurityTests.sql('GRANT SELECT,INSERT,UPDATE ON yield_estimation_sessions TO authenticated;', user=None)
            for migration in ('20261105060200_issue54_yield_sampling_site_sets.sql', '20261105065000_issue54_yield_site_history_guard.sql', '20261105074500_issue54_panel_count_evidence_guard.sql', '20261105093000_issue54_hard_delete_yield_sessions.sql', '20261105094500_issue54_hard_delete_queue_compat.sql', '20261105101500_issue54_hard_delete_sampling_sites.sql', '20261105120000_issue54_hard_delete_replay_safety.sql'):
                SecurityTests.sql((ROOT/'supabase/migrations'/migration).read_text(), user=None)
            result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SecurityTests))
            return 0 if result.wasSuccessful() else 1
        finally:
            subprocess.run([str(bindir/'pg_ctl'), '-D', str(data), '-m', 'immediate', '-w', 'stop'], env=env, check=True)

if __name__ == '__main__':
    raise SystemExit(main())

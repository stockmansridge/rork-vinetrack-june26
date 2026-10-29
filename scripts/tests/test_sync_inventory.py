import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'audit_sync_inventory.py'
spec = importlib.util.spec_from_file_location('audit_sync_inventory', SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class SyncInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.registry = {
            'reviewed_source': 'fixture-only',
            'ios_coordinator_calls': ['pinSync.syncPinsForSelectedVineyard'],
            'android_pending_entities': ['pin'],
            'independent_surfaces_requiring_separate_review': ['photos'],
            'released_318_source_verified': False,
            'native_319_acceptance_complete': False,
        }
        self.write(audit.IOS, 'await pinSync.syncPinsForSelectedVineyard()\n')
        self.write(audit.ANDROID, 'object PendingEntityType {\n const val PIN = "pin"\n}\nobject PendingOpType {\n const val CREATE = "create"\n}\n')
        self.write(audit.REGISTER, json.dumps(self.registry))

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')

    def test_reviewed_fixture_has_no_drift(self):
        report = audit.inventory(self.root, self.registry)
        self.assertEqual(report['observed']['android_pending_entities'], ['pin'])
        self.assertTrue(all(not x['unregistered'] and not x['registered_but_missing'] for x in report['drift'].values()))

    def test_new_ios_service_requires_review(self):
        self.write(audit.IOS, 'await pinSync.syncPinsForSelectedVineyard()\nawait newSync.syncForSelectedVineyard()')
        report = audit.inventory(self.root, self.registry)
        self.assertEqual(report['drift']['ios_coordinator_calls']['unregistered'], ['newSync.syncForSelectedVineyard'])

    def test_changed_persisted_discriminator_is_reported_both_ways(self):
        self.write(audit.ANDROID, 'object PendingEntityType {\n const val PIN = "pin_v2"\n}\n')
        report = audit.inventory(self.root, self.registry)
        self.assertEqual(report['drift']['android_pending_entities']['unregistered'], ['pin_v2'])
        self.assertEqual(report['drift']['android_pending_entities']['registered_but_missing'], ['pin'])

    def test_source_comments_do_not_add_fake_services(self):
        self.assertEqual(audit.ios_calls('// await fake.sync()\n/* await other.sync() */\nawait real.sync()'), {'real.sync'})

    def test_literal_and_dynamic_routes_are_reported_separately(self):
        self.write(Path('ios/VineTrack/Repository.swift'), 'client.from("trips").select()\nclient.rpc("some_rpc")\nrestUrl(dynamicTable)\n')
        report = audit.inventory(self.root, self.registry)
        self.assertEqual({r['value'] for r in report['literal_routes']}, {'trips', 'some_rpc'})
        self.assertEqual([r['value'] for r in report['dynamic_routes_require_manual_review']], ['dynamicTable'])

    def test_release_gate_cannot_pass_on_inventory_alone(self):
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root), '--release-gate'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('native acceptance evidence', result.stdout)

    def test_missing_source_does_not_become_an_empty_success(self):
        (self.root / audit.ANDROID).unlink()
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root), '--verify-inventory'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('could not be established', result.stderr)


if __name__ == '__main__':
    unittest.main()

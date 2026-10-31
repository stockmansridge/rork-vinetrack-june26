#!/usr/bin/env python3
"""Inventory this Android-only recovery delta without modifying historical inventories."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PARENT = '7e6ffb2b57aa397ad2e6b1c7ced9316a26ba24dd'
PREFIX = 'android-vinetrack/app/src/'
PRODUCTION = [
    'main/java/com/rork/vinetrack/data/auth/' + name + '.kt' for name in
    ['SessionStore', 'AccountTransitionEvidence', 'CleanExitCacheContract', 'RetainedPlanningContract',
     'AuthRecoveryFailure', 'AuthRecoveryRepository']
] + ['main/java/com/rork/vinetrack/ui/auth/ProtectedWorkRecoveryViewModel.kt']
TESTS = ['androidTest/java/com/rork/vinetrack/data/auth/' + name + '.kt' for name in
         ['AuthRetentionAndroidTest', 'PopulatedCleanExitActivityTest']]
TESTS += ['test/java/com/rork/vinetrack/data/' + name + '.kt' for name in
          ['AuthRecoverySurfaceTest', 'RetainedPlanningContractTest']]
PATHS = [PREFIX + path for path in PRODUCTION + TESTS] + [
    'scripts/run-android-populated-auth-host-tests.py', 'scripts/snapshot-android-populated-auth-source.py']

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def sha(data):
    return hashlib.sha256(data).hexdigest()

assert git('rev-parse', 'HEAD').decode().strip() == PARENT, 'Managed revision changed; re-review provenance before rerunning'
changed_native = set(git('diff', PARENT, '--name-only', '--', 'ios', 'android-vinetrack').decode().splitlines())
assert changed_native <= {PREFIX + name for name in PRODUCTION + TESTS}, 'Unexpected native source delta'
prior_path = 'docs/reviews/pr26-quadrant-source-manifest-20261031.json'
prior_raw = (ROOT / prior_path).read_bytes()
assert sha(prior_raw) == 'ff3f004f6f3d893abdf315ebee9845f4eb9a057d4caa23a370d56049fa6f5337'
prior = json.loads(prior_raw)
for item in prior['files']:
    assert sha((ROOT / item['path']).read_bytes()) == item['sha256'], 'Quadrant input changed: ' + item['path']
config = prior['preserved_ignored_generated_configuration']
assert sha((ROOT / config['path']).read_bytes()) == config['sha256']
files = []
for path in sorted(PATHS):
    before = subprocess.run(['git', 'show', f'{PARENT}:{path}'], cwd=ROOT, capture_output=True)
    files.append({'path': path, 'sha256': sha((ROOT / path).read_bytes()),
                  'parent_sha256': sha(before.stdout) if before.returncode == 0 else None})
manifest = {
    'managed_source_parent': PARENT, 'repaired_managed_revision': None,
    'scope': 'Bounded Android auth/recovery inventory, not original-device or signed candidate certification',
    'user_cited_revision': '136e5ee710a5798e3847af3b9bcb8d08f65e8b6a',
    'user_cited_revision_is_ancestor_of_parent': False,
    'protected': {'ios_tracked_source_unchanged_from_parent': True, 'pr26_manifest': prior_path,
                  'pr26_manifest_sha256': sha(prior_raw), 'all_26_pr26_inputs_unchanged': True,
                  'generated_ios_configuration': config,
                  'native_changes_limited_to_listed_auth_and_tests': True},
    'validation': {
        'final_auth_instrumentation': {'passed': 59, 'failed': 0, 'skipped': 0, 'seconds': 13},
        'focused_host_selection': {'passed': 25, 'failed': 0, 'errors': 0, 'skipped': 0},
        'unnarrowed_host_attempt': 'Compile blocked by seven unrelated stale test signatures; zero tests executed',
        'rendered_journey': 'FAIL: recovery/Home/full vineyard publication and byte preservation reached; Work Task form ComposeNotIdleException at No block; downstream block/Trip checks not executed',
        'android_normal_build': 'PASS via runChecks after final production/test changes',
        'original_device_recovery': 'NOT ACCEPTED; actual retained evidence/diagnostics unavailable',
        'candidate': 'NO-GO; no counter changes, test-only delivery or install',
    },
    'files': files,
}
out = ROOT / 'docs/reviews/android-populated-auth-source-manifest-20261031.json'
out.write_text(json.dumps(manifest, indent=2) + '\n')
print(f'{len(files)} inputs; manifest_sha256={sha(out.read_bytes())}')
print('All historical PR26 inputs and preserved iOS configuration verified unchanged.')

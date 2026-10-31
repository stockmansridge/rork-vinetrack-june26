#!/usr/bin/env python3
"""Separate continuation inventory; historical recovery/Quadrant inventories remain immutable."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PARENT = 'da345bd992f734fd3ea2b90db00fcaa7e4339311'
PUBLIC = '20dc66e7f1027d996102777c2c66901fda6a4c77'
PREFIX = 'android-vinetrack/app/src/'
PRODUCTION = ['main/java/com/rork/vinetrack/' + path + '.kt' for path in [
    'data/auth/AuthRecoveryRepository', 'data/auth/FieldStoreAccess', 'data/DomainCacheStore',
    'ui/AppViewModel', 'ui/components/GuardedSheetState']]
TESTS = ['androidTest/java/com/rork/vinetrack/' + path + '.kt' for path in [
    'data/auth/PopulatedCleanExitActivityTest', 'data/auth/FieldSaveContentionAndroidTest',
    'ui/GuardedSheetStateAndroidTest']]
PATHS = [PREFIX + path for path in PRODUCTION + TESTS] + ['scripts/' + path + '.py' for path in [
    'extract-android-recovery-evidence', 'inspect-android-recovery-apk',
    'retain-android-recovery-evidence', 'snapshot-android-recovery-journeys-source']]

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def sha(data):
    return hashlib.sha256(data).hexdigest()

assert git('rev-parse', 'HEAD').decode().strip() == PARENT
assert not git('diff', PARENT, '--name-only', '--', 'ios').strip()
changes = set(git('diff', PARENT, '--name-only', '--', 'android-vinetrack').decode().splitlines())
assert changes <= {PREFIX + path for path in PRODUCTION + TESTS}, changes
public_tree = Path('/tmp/vinetrack-requested-main/android-vinetrack')
managed_tree = Path('/tmp/vinetrack-managed-main/android-vinetrack')
assert public_tree.is_dir() and managed_tree.is_dir()
public_files = {p.relative_to(public_tree): p.read_bytes() for p in public_tree.rglob('*') if p.is_file()}
managed_files = {p.relative_to(managed_tree): p.read_bytes() for p in managed_tree.rglob('*') if p.is_file()}
assert public_files == managed_files, 'Public latest-main Android/source parent parity changed'
prior_path = 'docs/reviews/android-populated-auth-source-manifest-20261031.json'
assert sha((ROOT / prior_path).read_bytes()) == '246fac87d0aff85da70038a489dd4c8ddd9f9a31d4780dc0a231eb495331b391'
quadrant_path = 'docs/reviews/pr26-quadrant-source-manifest-20261031.json'
quadrant_raw = (ROOT / quadrant_path).read_bytes()
assert sha(quadrant_raw) == 'ff3f004f6f3d893abdf315ebee9845f4eb9a057d4caa23a370d56049fa6f5337'
quadrant = json.loads(quadrant_raw)
normalized = []
for item in quadrant['files']:
    current = (ROOT / item['path']).read_bytes()
    if item['path'] == PREFIX + 'main/java/com/rork/vinetrack/ui/AppViewModel.kt':
        # Exactly diagnostics/rethrow only; do not mask any functional AppViewModel edits.
        before = git('show', f'{PARENT}:{item["path"]}')
        added = '''            com.rork.vinetrack.data.auth.CleanExitDiagnostics.checkpoint("vineyard.load.begin")
'''
        catch = '''        } catch (failure: Exception) {
            com.rork.vinetrack.data.auth.CleanExitDiagnostics.checkpoint("vineyard.load.failure.${failure.javaClass.simpleName}")
            if (failure is com.rork.vinetrack.data.auth.FieldSaveBusy) {
                com.rork.vinetrack.data.auth.CleanExitDiagnostics.checkpoint("vineyard.load.contention.at.${failure.stackTrace.filter { it.className.startsWith("com.rork.vinetrack") }.take(8)}")
            }
            throw failure
'''
        text = current.decode().replace(added, '', 1).replace(catch, '', 1).replace(
            '            com.rork.vinetrack.data.auth.CleanExitDiagnostics.checkpoint("vineyard.load.finished")\n', '', 1)
        assert text.encode() == before, 'Functional AppViewModel delta beyond diagnostics'
        assert sha(before) == item['sha256']
        normalized.append(item['path'])
    else:
        assert sha(current) == item['sha256'], item['path']
config = quadrant['preserved_ignored_generated_configuration']
assert sha((ROOT / config['path']).read_bytes()) == config['sha256']
files = []
for path in sorted(PATHS):
    before = subprocess.run(['git', 'show', f'{PARENT}:{path}'], cwd=ROOT, capture_output=True)
    files.append({'path': path, 'sha256': sha((ROOT / path).read_bytes()),
                  'parent_sha256': sha(before.stdout) if before.returncode == 0 else None})
evidence = [{'path': str(p.relative_to(ROOT)), 'sha256': sha(p.read_bytes())}
            for p in sorted((ROOT / 'docs/reviews/evidence/android-recovery-20261031').iterdir()) if p.is_file()]
manifest = {
    'managed_source_parent': PARENT, 'repaired_managed_revision': None,
    'public_main': PUBLIC, 'public_android_tree_byte_identical_to_parent': True,
    'public_android_file_count': len(public_files),
    'scope': 'Android populated recovery, bounded cache admission and resting-sheet idling; no public release',
    'protected': {'ios_tracked_source_unchanged': True, 'ios_generated_configuration': config,
                  'historical_recovery_inventory': prior_path, 'historical_quadrant_inventory': quadrant_path,
                  'quadrant_inputs_byte_unchanged': 25, 'diagnostics_only_normalized_inputs': normalized,
                  'version_and_build_settings_unchanged': True},
    'validation': {'final_instrumentation': {'passed': 90, 'failed': 0, 'skipped': 0, 'seconds': 65},
                   'classes': {'AuthRetentionAndroidTest': 59, 'PopulatedCleanExitActivityTest': 13,
                               'FieldSaveContentionAndroidTest': 16, 'GuardedSheetStateAndroidTest': 2},
                   'five_independent_rendered_journeys_passed': True,
                   'prior_focused_host_25': 'historical unchanged-contract evidence, not rerun',
                   'normal_android_build': 'PASS after final native changes',
                   'original_device': 'NOT ACCEPTED; no device/evidence/installed signer access'},
    'inspected_release_build': json.loads(Path('/tmp/vinetrack-recovery-release-20261031/summary.json').read_text()),
    'delivery': {'verified_update_candidate': False, 'counter_changed': False, 'uploaded_to_store': False,
                 'installed_in_place': False, 'public_release': False,
                 'blockers': ['Final repaired managed SHA not yet available',
                              'Installed signing identity/version and unused code unverified',
                              'Tester delivery availability and durable matching artifact/source retention unverified']},
    'files': files, 'evidence': evidence,
}
out = ROOT / 'docs/reviews/android-recovery-journeys-source-manifest-20261031.json'
out.write_text(json.dumps(manifest, indent=2) + '\n')
print(f'{len(files)} inputs; {len(evidence)} retained evidence files; manifest_sha256={sha(out.read_bytes())}')

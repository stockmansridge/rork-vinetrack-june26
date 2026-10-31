#!/usr/bin/env python3
"""Bounded PR26 provenance; no Git/backend/release mutations or old inventory writes."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
PARENT = 'afce8dc1695f1d451475353260208458c8a3bc20'
BASE = '50438333921355136fc8d81a375affc8a3334da0'
HEAD = 'e681f2796b22bd9d94bdd936a8fd9ea388584191'
EXTRA = {
    'android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/YieldTripNavigationAndroidTest.kt',
    'ios/VineTrack/App/SystemAdminService.swift',
    'ios/VineTrackTests/QuadrantCountNativeTests.swift',
    'ios/VineTrackUITests/QuadrantCountUITests.swift',
    'scripts/inspect-quadrant-count-contract.py',
    'scripts/prepare-pr26-source.py',
    'scripts/review-quadrant-source.py',
    'scripts/snapshot-pr26-quadrant-source.py',
}
GENERATED_CONFIG = 'ios/VineTrack/Config.swift'
GENERATED_CONFIG_SHA256 = '71301cf111ea1855e8c86d50dd9a2675bab62550aa09f872aae83ccf8374508b'
PROTECTED = [
    'ios/VineTrack/App/SprayProgram/SprayProgramProgression.swift',
    'ios/VineTrack.xcodeproj/project.pbxproj',
    'android-vinetrack/app/build.gradle.kts',
    'android-vinetrack/gradle.properties',
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def parent_bytes(name):
    result = subprocess.run(['git', 'show', f'{PARENT}:{name}'], cwd=ROOT, capture_output=True)
    return result.stdout if result.returncode == 0 else None


meta = json.loads(Path('/tmp/vinetrack-quadrant-pr.json').read_text())
assert meta['head']['sha'] == HEAD and meta['base']['sha'] == BASE
reviewed = {item['filename'] for item in json.loads(Path('/tmp/vinetrack-quadrant-files.json').read_text())}
assert len(reviewed) == 18
paths = reviewed | EXTRA
assert sha((ROOT / GENERATED_CONFIG).read_bytes()) == GENERATED_CONFIG_SHA256, 'Generated configuration changed'
for name in PROTECTED:
    assert (ROOT / name).read_bytes() == parent_bytes(name), f'Protected source changed: {name}'
files = []
with tarfile.open('/tmp/vinetrack-quadrant-head.tar.gz') as archive:
    prefix = archive.getnames()[0] + '/'
    for name in sorted(paths):
        current = (ROOT / name).read_bytes()
        before = parent_bytes(name)
        upstream = archive.extractfile(prefix + name).read() if name in reviewed else None
        files.append({'path': name, 'sha256': sha(current),
                      'parent_sha256': sha(before) if before is not None else None,
                      'reviewed_pr26_head_sha256': sha(upstream) if upstream is not None else None,
                      'matches_reviewed_head': current == upstream if upstream is not None else None})
    # Prove that the newer AppViewModel remainder was not replaced by old PR bytes.
    name = 'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt'
    marker = b'    fun saveYieldSession(session: YieldEstimationSession, onResult: (Boolean) -> Unit = {}) {\n'
    current = (ROOT / name).read_bytes()
    before = parent_bytes(name)
    assert current.count(marker) == before.count(marker) == 1
    cpre, cpost = current.split(marker)
    bpre, bpost = before.split(marker)
    assert cpre == bpre and cpost.endswith(bpost)
    insertion = cpost[:-len(bpost)]
    assert b'previousIsQuadrant' in insertion and b'onResult(false)' in insertion

manifest = {
    'managed_source_parent': PARENT,
    'integration_commit': None,
    'reviewed_pr26_head': HEAD,
    'reviewed_pr26_base': BASE,
    'scope': 'Bounded source inventory, not full source/archive or installed-binary certification',
    'integration': '17 exact paths initially applied; only PR26 insertion reconciled into newer AppViewModel; subsequent local safety, fixture and test deltas are individually hashed',
    'protected_source_unchanged': PROTECTED,
    'preserved_ignored_generated_configuration': {'path': GENERATED_CONFIG, 'sha256': GENERATED_CONFIG_SHA256},
    'validation': {
        'ios_final_native_selection': {'passed': 70, 'seconds': 81},
        'ios_final_ui_selection': {'passed': 4, 'failed': 1, 'blocker': 'Quadrant normalization/process-relaunch scenario; most recent runner error is a location main-thread warning, not established root cause'},
        'android_instrumentation': {'passed': 21, 'failed': 0, 'skipped': 0, 'seconds': 29},
        'ios_normal_simulator_build': 'PASS; device Release unverified',
        'android_normal_build': 'PASS',
        'supplemental_host_harness': 'Imported, not executed in this integration',
        'live_authenticated_replay_and_original_device_acceptance': 'UNVERIFIED',
        'test_candidate_delivery': 'NOT PREPARED; required gates open',
    },
    'backend': 'Read-only metadata confirmed deployed admin guard and enabled trigger; SQL not executed; no customer rows queried or written',
    'files': files,
}
out = ROOT / 'docs/reviews/pr26-quadrant-source-manifest-20261031.json'
out.write_text(json.dumps(manifest, indent=2) + '\n')
print(f'{len(files)} inputs; manifest_sha256={sha(out.read_bytes())}')
print('Protected configuration/Home source unchanged; newer AppViewModel remainder preserved.')

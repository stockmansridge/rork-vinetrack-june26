#!/usr/bin/env python3
"""Record bounded consolidated source provenance; never overwrite historical manifests."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PARENT = '687fa6d03c80a33a7399a8cc4a75e2423c037f5f'
PATHS = [
    'android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/MobileSprayUXParityAndroidTest.kt',
    'android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/SprayPhase1CalculatorAndroidTest.kt',
    'android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/auth/AuthRetentionAndroidTest.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/data/auth/RefreshRejection.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/SyncDownloadStatus.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/components/SprayCanopySelector.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/components/SprayPlanningCards.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SyncStatusScreen.kt',
    'android-vinetrack/app/src/test/java/com/rork/vinetrack/data/auth/RefreshRejectionLegacyTest.kt',
    'android-vinetrack/app/src/test/java/com/rork/vinetrack/ui/SyncDownloadStatusTest.kt',
    'docs/reviews/android-block-download-auth-status-20261030.md',
    'docs/reviews/spray-flow-human-testing-20261030.md',
    'ios/VineTrack/App/SprayCalculatorView.swift',
    'ios/VineTrack/App/SprayCanopyControls.swift',
    'ios/VineTrack/App/SprayPlanningCardsView.swift',
    'ios/VineTrack/App/SprayProgram/SprayProgramProgression.swift',
    'ios/VineTrackTests/SprayProgramRound2Tests.swift',
    'ios/VineTrackUITests/MobileSprayUXParityUITests.swift',
    'scripts/inspect-issue25-catalogue-contract.py',
    'scripts/prepare-pr27-pr28-source.py',
    'scripts/run-pr27-auth-download-host-tests.py',
    'scripts/test_android_download_status_host.py',
    'scripts/tests/test_spray_flow_human_testing.py',
    'scripts/snapshot-consolidated-pr27-pr28-source.py',
]

def sha(data):
    return hashlib.sha256(data).hexdigest()

entries = []
for name in sorted(PATHS):
    old = subprocess.run(['git', 'show', PARENT + ':' + name], cwd=ROOT, capture_output=True)
    entries.append({'path': name, 'sha256': sha((ROOT / name).read_bytes()),
                    'parent_sha256': sha(old.stdout) if old.returncode == 0 else None})
manifest = {
    'scope': 'PR27/PR28 integration, Android validation fixtures, Home completion-join optimization and read-only catalogue inspection tooling',
    'managed_source_parent': PARENT,
    'inspected_public_main': '8543d725cfdfc8d20c2eaecc4cf265b49538540b',
    'reviewed_pr_heads': {'27': 'aef91ca05ededd6fe3690ef5e5ccc79d2dc8af69', '28': 'ec839e830879a9461811f413c5ec289cc609d82a'},
    'final_integration_sha': None,
    'boundary': 'Bounded source inventory only. No signed candidate, backend propagation deployment, original-device acceptance or released-binary certification.',
    'files': entries,
}
encoded = json.dumps(manifest, indent=2) + '\n'
output = ROOT / 'docs/reviews/consolidated-pr27-pr28-source-manifest-20261030.json'
if output.exists() and output.read_text() != encoded:
    raise SystemExit('Existing inventory differs. Preserve it; use a new explicitly reviewed inventory for later source.')
output.write_text(encoded)
print(json.dumps({'path': str(output.relative_to(ROOT)), 'inputs': len(entries), 'sha256': sha(encoded.encode())}))

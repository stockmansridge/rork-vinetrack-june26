#!/usr/bin/env python3
"""Read-only source inventory for the separate Android task-write recovery review."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PARENT = 'feee81254d11c4910bc1ca105f7ea019cc8472ac'
BASE = 'android-vinetrack/app/src/'
FILES = [BASE + 'main/java/com/rork/vinetrack/' + p for p in [
    'data/SupabaseClient.kt', 'data/WorkTaskPlanningDraftStore.kt',
    'data/WorkTaskPlanningRepository.kt', 'data/WorkTaskWriteCoordinator.kt',
    'data/WorkTaskWriteRecovery.kt', 'ui/AppViewModel.kt', 'ui/screens/WorkTasksScreen.kt',
]] + [
    BASE + 'test/java/com/rork/vinetrack/data/WorkTaskWriteRecoveryTest.kt',
    BASE + 'androidTest/java/com/rork/vinetrack/data/WorkTaskWriteRecoveryAndroidTest.kt',
    'scripts/run-work-task-write-recovery-tests.py',
    'scripts/snapshot-work-task-write-recovery-source.py',
]

def digest(data):
    return hashlib.sha256(data).hexdigest()

def main():
    entries = []
    for name in FILES:
        current = (ROOT / name).read_bytes()
        before = subprocess.run(['git', 'show', f'{PARENT}:{name}'], cwd=ROOT, capture_output=True)
        entries.append({'path': name, 'sha256': digest(current), 'bytes': len(current),
                        'parent_sha256': digest(before.stdout) if before.returncode == 0 else None})
    document = {'scope': 'Android Work Task header write recovery; separate from iOS Trip deletion',
                'source_parent': PARENT, 'integration_commit': None, 'inputs': entries}
    output = ROOT / 'docs/reviews/android-work-task-write-recovery-source-manifest-20261030.json'
    output.write_text(json.dumps(document, indent=2) + '\n')
    print(json.dumps({'path': str(output.relative_to(ROOT)), 'inputs': len(entries), 'sha256': digest(output.read_bytes())}))

if __name__ == '__main__':
    main()

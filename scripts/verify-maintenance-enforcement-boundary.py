#!/usr/bin/env python3
"""Source-only scope/manifest check. No network, build, auth or app data access."""
import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FILES = sorted([
    'ios/VineTrack/Backend/Repositories/SupabaseOperationsSyncRepositories.swift',
    'ios/VineTrack/Backend/Storage/MaintenancePhotoStorageService.swift',
    'ios/VineTrack/Backend/Subscription/VineyardMutationAdmission.swift',
    'ios/VineTrack/Backend/Sync/OperationsSyncServices.swift',
    'ios/VineTrackTests/MaintenancePhotoAdmissionTests.swift',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogRepository.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogCreateSync.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogUpdateSync.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogDeleteSync.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PendingWriteRepository.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenancePhotoRepository.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenancePhotoEvidenceStore.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceWriteScope.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt',
    'android-vinetrack/app/src/test/java/com/rork/vinetrack/data/MaintenancePhotoEvidenceStoreTest.kt',
    'android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/MaintenancePhotoAdmissionAndroidTest.kt',
    'android-vinetrack/entitlement-tests.init.gradle',
    'scripts/run-read-only-entitlement-contract.py',
    'scripts/prepare-isolated-read-only-acceptance.py',
    'scripts/verify-isolated-acceptance-preparer.py',
    'scripts/verify-maintenance-enforcement-boundary.py',
])
REPORT = 'docs/reviews/final-mobile-acceptance-legacy-save-recovery-2026-10-15.md'


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True)


def main():
    changed = set(git('diff', 'HEAD', '--name-only').splitlines())
    changed.update(git('ls-files', '--others', '--exclude-standard').splitlines())
    unexpected = sorted(path for path in changed if path not in FILES and path != REPORT and not path.startswith('.rork/'))
    assert not unexpected, f'Unexpected changes: {unexpected}'
    vm = 'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt'
    original = git('show', f'HEAD:{vm}')
    current = (ROOT / vm).read_text()
    current = re.sub(r'    private val maintenancePhotoEvidence by lazy \{\n.*?\n    \}\n', '', current, count=1, flags=re.S)
    def outside_photo_callers(text):
        start = text.index('    fun uploadMaintenancePhoto(')
        end = text.index('    /** Mint a signed URL so Coil', start)
        return text[:start] + text[end:]
    assert outside_photo_callers(original) == outside_photo_callers(current), 'Unrelated ViewModel startup/costing/recovery source changed'
    for file in FILES:
        if file.endswith('.py'):
            ast.parse((ROOT / file).read_text(), filename=file)
    subprocess.run(['git', 'diff', 'HEAD', '--check'], cwd=ROOT, check=True)
    manifest = ''.join(f'{hashlib.sha256((ROOT / file).read_bytes()).hexdigest()}  {file}\n' for file in FILES)
    if '--verify-report' in sys.argv:
        section = (ROOT / REPORT).read_text().split('### I. Source identity and protected boundaries', 1)[1].split('### J. Remaining checkpoint', 1)[0]
        recorded = re.search(r'```text\n(.*?)```', section, re.S)
        assert recorded and recorded.group(1) == manifest, 'Report manifest does not match current file bytes'
        assert hashlib.sha256(manifest.encode()).hexdigest() in section, 'Report manifest digest mismatch'
    print(json.dumps({'starting_head': git('rev-parse', 'HEAD').strip(), 'source_files': len(FILES),
                      'manifest_sha256': hashlib.sha256(manifest.encode()).hexdigest(),
                      'scope_whitespace_python_syntax': 'PASS',
                      'unrelated_viewmodel_startup_costing_recovery': 'UNCHANGED',
                      'manifest': manifest}, indent=2))


if __name__ == '__main__':
    main()

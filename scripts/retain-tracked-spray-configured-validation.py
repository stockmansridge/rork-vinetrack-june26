#!/usr/bin/env python3
"""Retain exact-commit configured test receipts, never raw generated configuration."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

OUT = Path('docs/reviews/evidence/android-tracked-spray-configured-6baaed77')
ROOT = Path('/tmp/spray-config-6baaed77')
EXPECTED = {'TrackedSprayCompletionSyncTest': 19, 'TripClosureStatusPhaseCTest': 13,
            'TankDependencyPhaseBTest': 10, 'OccurrenceTankConflictHoldTest': 3,
            'AccountScopedTankSafetyTest': 16}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    assert not OUT.exists(), 'Never overwrite retained evidence'
    manifest_path = Path('docs/reviews/evidence/android-tracked-spray-completion-20261102/source-manifest.json')
    manifest = json.loads(manifest_path.read_text())
    for e in manifest:
        assert sha(ROOT/e['path']) == e['sha256']
        assert (ROOT/e['path']).read_bytes() == Path(e['path']).read_bytes()
    config = json.loads(Path('/tmp/spray-config-input-receipt.json').read_text())
    xml_dir = ROOT/'android-vinetrack/app/build/test-results/testDebugUnitTest'
    files = sorted(xml_dir.glob('TEST-*.xml'))
    assert len(files) == 5
    rows = []
    for file in files:
        root = ET.parse(file).getroot()
        assert int(root.attrib['tests']) == EXPECTED[root.attrib['name'].split('.')[-1]]
        assert all(int(root.attrib[k]) == 0 for k in ('failures', 'errors', 'skipped'))
        rows.append({'file': file.name, 'sha256': sha(file), **root.attrib})
    log = Path('/tmp/spray-config-6baaed77-jvm.log')
    assert 'BUILD SUCCESSFUL' in log.read_text()
    # Guard evidence export against accidentally including configured values.
    import re
    config_text = Path('android-vinetrack/app/src/main/java/com/rork/vinetrack/Config.kt').read_text()
    configured_values = re.findall(r'const val \w+\s*=\s*"([^"\n]*)"', config_text)
    exported_text = log.read_text() + ''.join(f.read_text() for f in files)
    assert not any(v in exported_text for v in configured_values if len(v) > 12), 'Do not export a configuration value'
    OUT.mkdir(parents=True)
    for file in files:
        shutil.copyfile(file, OUT/file.name)
    shutil.copyfile(log, OUT/'focused-jvm.log')
    (OUT/'configuration-receipt.json').write_text(json.dumps(config, indent=2)+'\n')
    result = {
        'publicCommit': '6baaed77ef0a9af5b06143cdd1115a1805368382',
        'archiveSha256': sha(Path('/tmp/spray-config-6baaed77.tar.gz')),
        'sourceManifestSha256': sha(manifest_path), 'comparedAndroidFiles': 1274,
        'sourceDifferences': [], 'applicationSourceModified': False,
        'managedHeadAtValidation': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        'androidTreeAtValidation': subprocess.check_output(['git', 'rev-parse', 'HEAD:android-vinetrack'], text=True).strip(),
        'configurationReceipt': 'configuration-receipt.json',
        'tests': {'kind': 'host JVM debug variant', 'executed': 61, 'failures': 0, 'errors': 0, 'skipped': 0, 'suites': rows},
        'normalAndroidBuild': {'tool': 'runChecks', 'appPath': 'android-vinetrack', 'success': True,
                               'scope': 'Managed workspace with all 1274 tracked Android files identical to pinned public source'},
        'signingBuildRequest': {'tool': 'generatePlayAab', 'result': 'The current project has unsynced source changes. Finish this turn, then retry publishing.',
                               'runId': None, 'retryAttempted': False},
        'playSetup': {'connected': True, 'existingPackageAccess': 'ok', 'packageName': 'com.rork.vinetrack'},
        'versionName': '3.1.9', 'minimumExclusiveVersionCode': 1793604728,
        'signedVersionCode': None, 'submissionId': None, 'published': False,
        'status': 'VALIDATION_PASSED_SIGNED_BUILD_BLOCKED_PENDING_MANAGED_SYNC',
        'deviceOrPortalAcceptance': 'Not executed; JVM tests and normal build are not device lifecycle acceptance',
        'productionMutations': False, 'customerRecordMutations': False,
        'historicalSweeps': False, 'retainedOperationChanges': False,
        'nextAction': 'After automatic managed sync, list exact-source publishable builds and generate only if no matching build; verify assigned code >1793604728 before Internal publication. Existing user authorisation remains sufficient.'
    }
    (OUT/'validation-results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({'receipt': str(OUT), 'tests': 61, 'failures': 0, 'status': result['status']}, indent=2))


if __name__ == '__main__':
    main()

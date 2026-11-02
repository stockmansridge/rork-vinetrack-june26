#!/usr/bin/env python3
"""Retain the 2 November approved-configuration rerun and typed Play receipts.
Generated configuration, credentials and downloaded artifacts never enter evidence.
Provider receipts below are projections of observed tool responses, not new queries.
"""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

OUT = Path('docs/reviews/evidence/android-tracked-spray-published-1793612738')
ARCHIVE = Path('/tmp/spray-config-6baaed77')
CONFIG = Path('android-vinetrack/app/src/main/java/com/rork/vinetrack/Config.kt')
APPROVED_CONFIG_SHA = 'a1da2e0589dbe2e6430459e36a7e32dc93c4b15c846e6bc7cccbc1499a4712e8'
SOURCE = '6baaed77ef0a9af5b06143cdd1115a1805368382'
HEAD = 'e5e3582bbfdb97b76b4f0ba6a427018ea01f5514'
RUN = 'ffabeb5a-b005-4f73-8991-0332c75d8867'
EXPECTED = {'TrackedSprayCompletionSyncTest': 19, 'TripClosureStatusPhaseCTest': 13,
            'TankDependencyPhaseBTest': 10, 'OccurrenceTankConflictHoldTest': 3,
            'AccountScopedTankSafetyTest': 16}


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')


def main():
    assert not OUT.exists(), 'Never overwrite a delivery checkpoint'
    manifest_path = Path('docs/reviews/evidence/android-tracked-spray-completion-20261102/source-manifest.json')
    manifest = json.loads(manifest_path.read_text())
    assert len(manifest) == 1274
    for entry in manifest:
        p = Path(entry['path'])
        assert sha(p) == entry['sha256'] and p.read_bytes() == (ARCHIVE / p).read_bytes()
    assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == HEAD
    assert sha(CONFIG) == APPROVED_CONFIG_SHA == sha(ARCHIVE / CONFIG)
    subprocess.run(['git', 'check-ignore', '--quiet', str(CONFIG)], check=True)
    assert not subprocess.check_output(['git', 'ls-files', '--', str(CONFIG)]).strip()
    text = CONFIG.read_text()
    values = dict(re.findall(r'const val (\w+)\s*=\s*"([^"\n]*)"', text))
    assert len(values) == 14 and all(values.values())
    assert 'package com.rork.vinetrack' in text and 'object Config' in text
    assert re.search(r'val allValues\s*:\s*Map<String,\s*String>', text)
    for key in values:
        assert re.search(r'"' + key + r'"\s+to\s+' + key + r'\b', text)
    assert values['EXPO_PUBLIC_SUPABASE_URL'].rstrip('/') == 'https://tbafuqwruefgkbyxrxyb.supabase.co'
    files = sorted((ARCHIVE / 'android-vinetrack/app/build/test-results/testDebugUnitTest').glob('TEST-*.xml'))
    assert len(files) == 5
    rows = []
    for file in files:
        attrs = ET.parse(file).getroot().attrib
        assert int(attrs['tests']) == EXPECTED[attrs['name'].split('.')[-1]]
        assert all(int(attrs[k]) == 0 for k in ('failures', 'errors', 'skipped'))
        rows.append({'file': file.name, 'sha256': sha(file), **attrs})
    log = Path('/tmp/spray-restored-6baaed77-jvm.log')
    assert 'BUILD SUCCESSFUL' in log.read_text()
    exported = log.read_text() + ''.join(f.read_text() for f in files)
    assert not any(v in exported for v in values.values() if len(v) > 12), 'Refuse configuration disclosure'
    OUT.mkdir(parents=True)
    for f in files:
        shutil.copyfile(f, OUT / f.name)
    shutil.copyfile(log, OUT / 'focused-jvm.log')
    save('configuration-attestation.json', {
        'priorBlankGeneratedSha256': 'c79d68f9e9dc96559263dee80de69190df5c3886eab29a2f613104989d78eab7',
        'differenceClassification': 'Semantic: all 14 generated constant values were empty, versus 14 nonempty approved values. Not formatting-only.',
        'changedValueKeys': sorted(values),
        'restoration': 'Byte-for-byte reuse of protected prior Rork-materialised Config.kt from exact-source isolated validation archive; no invented configuration or new generator.',
        'initialCopyAttempt': 'Read-only generated file refused write; no tests ran. Inspected owner/mode and unchanged hash, temporarily enabled owner write, restored exact bytes, restored original read-only mode 0444.',
        'restoredSha256': APPROVED_CONFIG_SHA,
        'matchesHistoricalApprovedConfiguration': True,
        'identity': 'com.rork.vinetrack.Config',
        'contract': 'allValues: Map<String, String>; all 14 nonempty constants bound by name',
        'supabaseProjectMatchesApproved': True,
        'configurationIgnoredAndNotTracked': True,
        'configurationMatchesAfterNormalBuildAndSignedBuild': True,
        'serverConfigurationStoreUpdated': False,
        'limit': 'Attests local generated input used for host JVM and normal Android build. Typed signed-build/Play responses expose source identity but no generated-configuration digest, upload-certificate fingerprint or binary digest; those are not independently attested here. Live authentication, Maps, purchases and backend acceptance were not tested.',
        'configurationValuesExported': False, 'signingCredentialsRead': False,
    })
    save('play-delivery-receipt.json', {
        'receiptKind': 'Projection of observed typed Rork responses',
        'build': {'runId': RUN, 'snapshotId': HEAD, 'sourceHash': 'src_55394e1c1ef02abe9',
                  'appPath': 'android-vinetrack', 'framework': 'kotlin', 'status': 'completed',
                  'packageName': 'com.rork.vinetrack', 'matchesCurrentSourceBeforePublication': True},
        'validation': {'status': 'validated', 'track': 'internal', 'editId': '16237501823384530206',
                       'versionCode': '1793612738', 'releaseStatus': 'completed',
                       'submissionId': '79e05adc-7646-467f-94f3-8f69debaa287'},
        'committedPublication': {'status': 'published', 'packageName': 'com.rork.vinetrack',
            'track': 'internal', 'editId': '17995010067933895863', 'versionCode': '1793612738',
            'releaseName': '3.1.9 tracked Spray completion', 'releaseStatus': 'completed',
            'submissionId': 'a9729895-0ba3-4110-a64b-4ad45462498b'},
        'versionNameFromUnchangedSource': '3.1.9',
        'minimumExclusiveCode': 1793604728, 'assignedCodeVerifiedBeforeCommit': True,
        'productionPublication': False, 'testerOptInLinkReturned': False,
    })
    save('validation-results.json', {
        'publicCorrectionCommit': SOURCE, 'managedSigningSnapshot': HEAD,
        'androidTree': '55394e1c1ef02abe9d425f9d257f092e8b7a364f',
        'sourceManifestSha256': sha(manifest_path), 'sourceFilesCompared': 1274, 'sourceDifferences': [],
        'applicationSourceModified': False,
        'tests': {'kind': 'host JVM debug', 'forcedRerun': True, 'executed': 61,
                  'failures': 0, 'errors': 0, 'skipped': 0, 'suites': rows},
        'normalAndroidBuild': {'tool': 'runChecks', 'appPath': 'android-vinetrack', 'passed': True,
            'nonblockingWarnings': 'Two existing storage image URLs have preferred asset addresses; unchanged to preserve exact correction source.'},
        'configurationReceipt': 'configuration-attestation.json',
        'deliveryReceipt': 'play-delivery-receipt.json', 'status': 'PUBLISHED_INTERNAL_TESTING',
        'acceptanceNotExecuted': ['Android instrumentation', 'physical-device/process-death/reopen lifecycle',
            'authenticated backend/Portal journey', 'full unfiltered JVM suite', 'live authentication/purchase acceptance'],
        'preserved': ['350 L / 702 g historical application', 'original operation identities and queues',
                      'LEGACY_ORIGINAL_HELD protections', 'Issue #43 source and baseline'],
        'customerDataMutations': False, 'historicalSweeps': False, 'productionPublication': False,
    })
    for name in ['run-41411189793', 'jobs-41411189793', 'artifacts-41411189793', 'annotations-125164374394']:
        src = Path('/tmp/spray-delivery-ios-' + name + '.json')
        if src.exists():
            shutil.copyfile(src, OUT / ('ios-' + name + '.json'))
    save('ios-testflight-status.json', {
        'receiptKind': 'Projection of observed authenticated asc builds info response',
        'appId': '6761143377', 'version': '3.1.9', 'buildNumber': '201',
        'buildId': 'c56b4cb3-cf80-4595-b5cb-0aeb3630fc28', 'processingState': 'VALID', 'expired': False,
        'internalBuildState': 'IN_BETA_TESTING', 'externalBuildState': 'READY_FOR_BETA_SUBMISSION',
        'group': {'name': 'Internal Testing', 'id': '1a8d95a6-44ec-47ac-8754-47a0a283582e', 'isInternalGroup': True},
        'testNotes': {'locale': 'en-US', 'whatsNew': None},
        'currentSourceInspected': HEAD, 'currentSourceBoundToBuild201': False,
        'iosUploadOrSourceChangePerformed': False,
        'pinnedNativeRun': {'id': 41411189793, 'sourceSha': '61877aec62f9ab855e7fb4d3107b244c34e7e5c6',
            'status': 'completed', 'conclusion': 'failure', 'jobId': 125164374394,
            'failedStep': 'Compile app and run selected native safety tests', 'exitCode': 65,
            'artifactId': 13126367820, 'artifactName': 'issue43-main-ios-trip-queue-native-receipts',
            'namedTestResultsInspected': False,
            'limit': 'Public run/job/annotations establish failure, not its underlying compiler/test cause or executed test counts. Artifact/log inspection remains necessary.'},
    })
    print(json.dumps({'evidence': str(OUT), 'testsPassed': 61,
                      'publishedInternalVersionCode': 1793612738,
                      'submissionId': 'a9729895-0ba3-4110-a64b-4ad45462498b'}, indent=2))


if __name__ == '__main__':
    main()

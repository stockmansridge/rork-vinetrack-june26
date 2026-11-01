#!/usr/bin/env python3
"""Record bounded PR34 consolidation evidence, not a signed-release certificate.
Tool-result transcriptions are separate from raw logs; successful managed runs
may leave an old temporary failure log, so no success is inferred from its path.
"""
from pathlib import Path
import hashlib
import json
import subprocess
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/reviews/evidence/pr34-consolidation'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

integration = json.loads((OUT / 'integration.json').read_text())
paths = [change['path'] for change in integration['changes']] + [
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/TripsScreen.kt',
    'android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/SprayReleasePresentationAndroidTest.kt',
    'android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/TripOccurrencePersistenceAndroidTest.kt',
    'ios/VineTrack/LegacyImported/Views/Trips/ActiveTripView.swift',
    'ios/VineTrack/LegacyImported/Views/Trips/TripDetailView.swift',
    'ios/VineTrackUITests/SprayEditingAcceptanceUITests.swift',
]
protected = {path: {'expectedSha256': digest, 'observedSha256': sha(ROOT / path)}
             for path, digest in integration['protectedHashes'].items()}
for entry in protected.values():
    entry['matches'] = entry['expectedSha256'] == entry['observedSha256']
results = {
    'schema': 1,
    'createdAt': datetime.now(timezone.utc).isoformat(),
    'managedParentNotFinalRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'upstream': {'pr34Head': integration['pr34Head'], 'pr33Head': integration['pr33Head']},
    'changedApplicationAndTestFiles': {path: sha(ROOT / path) for path in sorted(paths)},
    'protectedConfiguration': protected,
    'managedResults': [
        {'tool': 'androidTest', 'onlyTesting': ['com.rork.vinetrack.data.SprayReleasePresentationAndroidTest'],
         'passed': 4, 'failed': 0, 'skipped': 0, 'seconds': 25,
         'evidence': 'Tool-result transcription; prior temporary log remained a 2-failure run. The later broad log also contains four named passing presentation cases.'},
        {'tool': 'androidTest', 'onlyTesting': [
            'com.rork.vinetrack.data.SprayReleasePresentationAndroidTest',
            'com.rork.vinetrack.data.SprayFieldLayoutAndroidTest',
            'com.rork.vinetrack.data.MobileSprayUXParityAndroidTest',
            'com.rork.vinetrack.data.SprayStartProductionAndroidTest',
            'com.rork.vinetrack.data.TripOccurrencePersistenceAndroidTest'],
         'passed': 44, 'failed': 7, 'skipped': 0,
         'evidence': 'android-focused-initial.log (truncated middle; retain aggregate and failure list, not complete named discovery)',
         'diagnosis': 'Seven occurrence fixtures exposed shared files/cache/applicationInfo despite isolated preference names. Production admission correctly refused; production guard unchanged.'},
        {'tool': 'androidTest', 'onlyTesting': ['com.rork.vinetrack.data.TripOccurrencePersistenceAndroidTest'],
         'passed': 7, 'failed': 0, 'skipped': 0, 'seconds': 11,
         'evidence': 'Tool-result transcription after filesystem fixture correction. Temporary log remained the previous 51-case failure; no fresh success log exported.'},
        {'tool': 'swiftTest', 'onlyTesting': [
            'VineTrackUITests/SprayEditingAcceptanceUITests/testConfiguredByAreaReviewReachesEnabledStartInSameCalculator',
            'VineTrackTests/DeviceTripOwnershipTests',
            'VineTrackTests/SprayInitialTankAmountsTests',
            'VineTrackTests/SprayApplicationGeometryTests',
            'VineTrackTests/SprayTripPhase5FinalisationTests'],
         'passed': 88, 'seconds': 200, 'failed': 0,
         'skipped': None, 'namedPassingExport': False,
         'evidence': 'Aggregate managed tool result. Existing temporary log is an older TripDeletionRecovery failure, not this run. Screenshot attachment was requested by the UI test but not independently exported/inspected.'},
        {'tool': 'runChecks', 'appPath': 'android-vinetrack', 'result': 'passed',
         'evidence': 'Normal Android build, separate from instrumentation; no candidate provenance/signing receipt supplied.'},
        {'tool': 'runChecks', 'appPath': 'ios', 'result': 'passed',
         'evidence': 'Simulator build; device/Release and store delivery not verified.'},
    ],
    'jvmAndReleasePreflight': {
        'command': 'python3 scripts/pr33-preflight.py --run-jvm', 'exitCode': 1,
        'jvmNamedPassed': 102, 'jvmRequired': 102, 'androidNamedRequiredPassed': 53,
        'androidRequired': 238, 'iosNamedRequiredPassed': 0, 'iosRequired': 57,
        'releaseGatePassed': False, 'blockerCount': 250,
        'report': '../pr33-preflight/preflight.json',
    },
    'configurationObservation': 'Ignored Android Config matched the protected hash at import. It differed after the native-tool interval. Current focused tests and normal builds left observed hash a1da2e0589dbe2e6430459e36a7e32dc93c4b15c846e6bc7cccbc1499a4712e8 unchanged. Origin and effective release equivalence are not attested; no expected hash was replaced and no values are disclosed.',
    'activeTripManagement': {
        'customerStateFetched': False, 'customerStateMutated': False,
        'managementRpcImplemented': False, 'deploymentAttempted': False,
        'status': 'blocked_pending_verified_live_contract_and_authorised_deployment_path',
        'boundary': 'Read-only explanation only. No takeover, arbitrary deletion, tank closure, reopening, GPS deletion or completion from path counts.'
    },
    'acceptanceStillUnverified': [
        'Full-screen light/dark/enlarged-text and scrolling inspection on both platforms',
        'Rendered occurrence-summary and foreign-vineyard geometry boundary scenarios',
        'Fresh September24 JH Testing server Trip state and retained-work/tank reconciliation',
        'Shared Android/iOS/Portal Owner/Manager audited idempotent management contract',
        'Complete historical writer formats and named required native test receipts',
        'Original Android populated in-place recovery and iOS actual-use queue drain',
        'Final automatic GitHub revision/snapshot/sourceHash and effective configuration mapping',
        'Signed candidate artifacts, iOS build/Android managed upload code and test-store delivery',
    ],
    'signedArtifact': None, 'iosDeliveryBuild': None, 'androidDeliveryCode': None,
    'finalManagedRevision': None, 'sourceHash': None, 'publication': None,
    'incident': 'OPEN', 'releaseGatePassed': False,
    'rawEvidence': {path.name: sha(path) for path in sorted(OUT.glob('*.log'))},
}
(OUT / 'validation-results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps({'receipt': str((OUT / 'validation-results.json').relative_to(ROOT)),
                  'releaseGatePassed': False, 'incident': 'OPEN'}, indent=2))

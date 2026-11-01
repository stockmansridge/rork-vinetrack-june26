#!/usr/bin/env python3
"""Record the explicit PR33 test selection once. Review changes to this manifest, never shrink it to pass."""
from pathlib import Path
import json
import re
ROOT = Path(__file__).resolve().parents[1]
JVM = ['auth/RecoveryWriterCompatibilityTest', 'auth/SavedChemicalRecoveryContractTest',
    'auth/DomainCacheRecoveryContractTest', 'auth/PruningRecoveryVerifierTest',
    'auth/TankActualRecoveryVerifierTest', 'RetainedPlanningContractTest',
    'SprayTankActualTest', 'CropSilRateRegressionTest', 'SprayStartActualAmountsTest']
ANDROID = ['auth/ChemicalRecoveryPreflightAndroidTest', 'auth/PopulatedCleanExitActivityTest',
    'auth/DomainCacheRecoveryAndroidTest', 'auth/AuthRetentionAndroidTest',
    'auth/RecoveryStorageInventoryAndroidTest', 'auth/ProfileInstallerRecoveryAndroidTest',
    'auth/GoogleMapsRecoveryAndroidTest', 'PreparedRecoveryAndroidTest', 'SprayStartProductionAndroidTest',
    'SprayReleaseGateAndroidTest', 'SprayProgramTankProcessAndroidTest', 'LegacySpraySaveAndroidTest',
    'ChemicalConditionPersistenceAndroidTest', 'WorkTaskWriteRecoveryAndroidTest',
    'TripOccurrencePersistenceAndroidTest', 'OfflineQuickActionsAndroidTest', 'HomeHydrationAndroidTest',
    'VineyardLogoCacheAndroidTest', 'MobileSprayUXParityAndroidTest', 'SprayFieldLayoutAndroidTest']
IOS = ['SprayInitialTankAmountsTests', 'SprayTripPhase5FinalisationTests', 'SprayTankActualTests',
    'StartTankCommitCoordinatorTests', 'SprayFinalisationDiagnosticsTests']
def kotlin(surface, names):
    required = []
    for name in names:
        p = ROOT / f'android-vinetrack/app/src/{surface}/java/com/rork/vinetrack/data/{name}.kt'
        content = p.read_text()
        package = re.search(r'package (\S+)', content)[1]
        methods = re.findall(r'@Test\b[\s\S]*?\bfun\s+(`[^`]+`|\w+)\s*\(', content)
        assert methods, name
        required.extend(package + '.' + name.split('/')[-1] + '#' + method.strip('`') for method in methods)
    return required
path = ROOT / 'scripts/pr33-required-tests.json'
if path.exists(): raise SystemExit('Manifest already exists; review explicit edits instead of regenerating requirements.')
manifest = {'schema': 1, 'jvm': kotlin('test', JVM), 'android': kotlin('androidTest', ANDROID),
    'ios': ['VineTrackTests/' + suite + '/' + method for suite in IOS for method in
        re.findall(r'\bfunc\s+(test\w+)\s*\(', (ROOT / f'ios/VineTrackTests/{suite}.swift').read_text())],
    'nativeLogs': ['native-broad-before/run.log', 'native-condition-final/run.log'],
    'unverifiedAcceptanceGates': ['ALL_38_STORE_WRITER_HISTORICAL_CONTRACTS_NOT_FULLY_REPRODUCED',
        'ANDROID_SPRAY_TANK_ACTUAL_QUEUE_AND_OPERATIONAL_BUNDLE_NATIVE_SUITES_MISSING',
        'POPULATED_RECOVERY_VINEYARD_SWITCH_ACTUAL_PROCESS_RESTART_NOT_EXECUTED',
        'POPULATED_IN_PLACE_UPGRADE_NOT_EXECUTED', 'ORIGINAL_INSTALLATION_ACCEPTANCE_REQUIRED',
        'EFFECTIVE_MANAGED_CONFIGURATION_AND_MERGED_MANIFEST_NOT_ATTESTED',
        'EXACT_MANAGED_SOURCE_SNAPSHOT_BUILD_UPLOAD_MAPPING_NOT_AVAILABLE']}
path.write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({k:len(manifest[k]) for k in ('jvm','android','ios')}))

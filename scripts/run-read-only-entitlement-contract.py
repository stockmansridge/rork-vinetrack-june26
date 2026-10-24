#!/usr/bin/env python3
"""Host-only entitlement contract/cache preparation and existing regressions.

This does not certify read-only UI/mutation/replay enforcement. All reports and
logs stay outside the managed project. No app data or store actions are used.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('host_runner', Path(__file__).with_name('run-costing-baseline-comparison.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def main(output):
    app = ROOT / 'android-vinetrack'
    init = app / 'entitlement-tests.init.gradle'
    metadata = {'starting_head': runner.git('rev-parse', 'HEAD'), 'scope': 'contract/cache, write authority and scoped queue admission; not complete feature acceptance'}
    (output / 'metadata.json').write_text(json.dumps(metadata, indent=2))
    focused = runner.run_stage('contract', app, ['*.ReadOnlyEntitlementContractTest', '*.VineTrackAccessRowCompatTest', '*.VineyardWriteAuthorityTest', '*.PinPhotoWorkflowTest', '*.FertigationMobileWorkflowTest', '*.ResistancePlanRepositoryTest', '*.ResistancePlanRevisionSyncTest', '*.FertigationDomainTest', '*.TripOccurrenceJournalTest', '*.StartTankCommitCoordinatorTest', '*.TripWriteAdmissionTest'], output, init)
    if focused['exit'] != 0:
        return 1
    regressions = runner.run_stage('existing-regressions', app, [
        '*.' + name for name in ['RetainedStartupTest', 'SyncRecoveryStorageTest', 'SyncCrashIsolationTest',
                                'ActiveTripStoreTest', 'OfflineQuickActionsTest', 'TripEndGateTest']
    ], output, init)
    (output / 'finished.json').write_text(json.dumps({'contract': focused['totals'], 'regressions': regressions['totals'],
                                                     'regression_exit': regressions['exit']}, indent=2))
    return regressions['exit']


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--launch', action='store_true')
    parser.add_argument('--output')
    args = parser.parse_args()
    output = Path(args.output) if args.output else Path(tempfile.mkdtemp(prefix='vinetrack-read-only-contract-'))
    if args.launch:
        with (output / 'runner.log').open('w') as log:
            process = subprocess.Popen([sys.executable, __file__, '--output', str(output)], cwd=ROOT,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        print(json.dumps({'pid': process.pid, 'output': str(output)}))
    else:
        sys.exit(main(output))

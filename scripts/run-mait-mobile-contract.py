#!/usr/bin/env python3
"""Synthetic Android MAIT/weather contracts plus retained native regression gates.

Reuses the existing host runner. Logs/results stay outside the managed project;
no backend, account data, device, release or version operations are performed.
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
    init = app / 'mait-tests.init.gradle'
    stages = [
        ('weather-irrigation', ['MAITCurrentObservationContractTest', 'CurrentObservationRepositoryTest',
                               'ForecastParityContractTest', 'SprayForecastWindowsTest',
                               'IrrigationCalculatorFixtureTest', 'IrrigationRegionalAdviceTest']),
        ('authority-isolation', ['ReadOnlyEntitlementContractTest', 'VineTrackAccessRowCompatTest',
                                'VineyardWriteAuthorityTest', 'PinPhotoWorkflowTest', 'FertigationMobileWorkflowTest',
                                'ResistancePlanRepositoryTest', 'ResistancePlanRevisionSyncTest', 'FertigationDomainTest',
                                'TripOccurrenceJournalTest', 'StartTankCommitCoordinatorTest', 'TripWriteAdmissionTest']),
        ('startup-offline', ['RetainedStartupTest', 'SyncRecoveryStorageTest', 'SyncCrashIsolationTest',
                             'ActiveTripStoreTest', 'OfflineQuickActionsTest', 'TripEndGateTest']),
    ]
    results = {}
    for name, classes in stages:
        result = runner.run_stage(name, app, ['*.' + item for item in classes], output, init)
        results[name] = {'exit': result['exit'], 'seconds': result['seconds'], 'totals': result['totals']}
        (output / 'summary.json').write_text(json.dumps(results, indent=2))
        if result['exit'] != 0:
            return result['exit']
    return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--launch', action='store_true')
    parser.add_argument('--output')
    args = parser.parse_args()
    output = Path(args.output) if args.output else Path(tempfile.mkdtemp(prefix='vinetrack-mait-contract-'))
    if args.launch:
        with (output / 'runner.log').open('w') as log:
            process = subprocess.Popen([sys.executable, __file__, '--output', str(output)], cwd=ROOT,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        print(json.dumps({'pid': process.pid, 'output': str(output)}))
    else:
        sys.exit(main(output))

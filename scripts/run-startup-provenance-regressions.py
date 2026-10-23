#!/usr/bin/env python3
"""Run source-order negative control, clean repaired startup gate, and protected costing.

The negative control is a SOURCE guard against the actual historical file, not a
claim to have executed the old Application constructor on a device.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import argparse
import importlib.util

spec = importlib.util.spec_from_file_location('costing_runner', Path(__file__).with_name('run-costing-baseline-comparison.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
run_stage = runner.run_stage

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'android-vinetrack'
BAD = 'e4d148096ebb0dc07f40eb9ef063b9e8bed3faee'

def main(resume_costing=None):
    output = Path(resume_costing) if resume_costing else Path(tempfile.mkdtemp(prefix='vinetrack-fatal-regression-'))
    if resume_costing:
        costing = run_stage('protected-costing-exact', APP, ['*.' + name for name in runner.CLASSES], output, APP / 'costing-tests.init.gradle')
        assert costing['exit'] == 0 and costing['totals']['tests'] == 205 and costing['totals']['failures'] == 0
        (output / 'costing-finished.json').write_text(json.dumps(costing, indent=2))
        print('EXACT_COSTING_GATE_PASSED', flush=True)
        return
    print(str(output), flush=True)
    bad_source = output / 'bad-AppViewModel.kt'
    bad_source.write_bytes(subprocess.check_output(['git', 'show', f'{BAD}:android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt'], cwd=ROOT))
    metadata = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'negative_control': BAD, 'kind': 'source guard, not old device execution'}
    (output / 'metadata.json').write_text(json.dumps(metadata, indent=2))
    with (output / 'clean.log').open('w') as log:
        subprocess.run(['./gradlew', 'clean', '--console=plain'], cwd=APP, stdout=log, stderr=subprocess.STDOUT, check=True)
    # Test environment is inherited by the Gradle test worker; no source/config override.
    os.environ['VINETRACK_STARTUP_SOURCE'] = str(bad_source)
    before = run_stage('historical-source-guard', APP,
        ['com.rork.vinetrack.data.RetainedStartupTest.observerStartupIsLastAndConnectivityCannotDirectlyReachReplayDelegate'],
        output, APP / 'startup-tests.init.gradle')
    assert before['totals']['tests'] == 1 and before['totals']['failures'] == 1 and before['exit'] != 0
    del os.environ['VINETRACK_STARTUP_SOURCE']
    current = run_stage('repaired-startup', APP, ['com.rork.vinetrack.data.*'], output, APP / 'startup-tests.init.gradle')
    assert current['exit'] == 0 and current['totals']['tests'] >= 33 and current['totals']['failures'] == 0
    costing = run_stage('protected-costing', APP, ['*.' + name for name in runner.CLASSES], output, APP / 'costing-tests.init.gradle')
    assert costing['exit'] == 0 and costing['totals']['tests'] == 205 and costing['totals']['failures'] == 0
    (output / 'finished.json').write_text(json.dumps({'metadata': metadata, 'before': before['totals'],
        'startup': current['totals'], 'costing': costing['totals']}, indent=2))
    print('ALL_REQUESTED_HOST_GATES_PASSED', flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--resume-costing')
    main(parser.parse_args().resume_costing)

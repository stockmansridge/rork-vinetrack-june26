#!/usr/bin/env python3
"""Compare the exact five completion failures with an untouched pre-costing tree.

Only host tests run. Baseline extraction, logs and copied XML stay outside the
workspace. No APK assembly, installs, network replay or application edits.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BASELINE = '83d6b0f819a8e6f22f610f98d5f1dcd540b4f8cf'
ACCEPTED = 'a6f2d4fbb10f4154427b62145c9a872495bf754c'
METHODS = [
    'Sydney Work Date selection round trips the UTC picker calendar day',
    'new local midnight Work Date resolves through vineyard timezone',
    'customer A B C keeps work date and separate audit',
    'offline update survives restart overlay full refresh and replay with original audit',
    'duplicate pending create patches folded completion before acknowledgement',
]
CLASSES = [
    'MobileCostingParityTest', 'WorkTaskCostRollupTest', 'WorkTaskLabourCostingTest',
    'WorkTaskMachineCostingTest', 'PieceRateCostingTest', 'EffectiveLabourCostTest',
    'PruningWorkTaskCostingCreateTest', 'WorkTaskMaterialCostsTest',
    'WorkerTypeIntegrityTest', 'PruningActivityWorkTaskLinkTest',
    'PruningActivityLabourLineTest', 'PruningWorkTaskRepairTest',
]

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT).decode().strip()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run_stage(name, app, selectors, output, init):
    dest = output / name
    dest.mkdir()
    command = ['./gradlew', ':app:testDebugUnitTest', '--init-script', str(init),
               '--console=plain', '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC']
    for selector in selectors:
        command += ['--tests', selector]
    started = time.monotonic()
    started_wall_ns = time.time_ns()
    with (dest / 'gradle.log').open('w') as log:
        result = subprocess.run(command, cwd=app, stdout=log, stderr=subprocess.STDOUT)
    suites = []
    cases = []
    for file in sorted((app / 'app/build/test-results/testDebugUnitTest').glob('TEST-*.xml')):
        if file.stat().st_mtime_ns < started_wall_ns:
            continue  # Never count earlier XML after a compilation/discovery failure.
        shutil.copy2(file, dest / file.name)
        suite = ET.parse(file).getroot()
        suites.append(dict(suite.attrib))
        for case in suite.findall('testcase'):
            issue = case.find('failure')
            if issue is None:
                issue = case.find('error')
            cases.append({'class': case.get('classname'), 'name': case.get('name'),
                          'status': 'FAIL' if issue is not None else 'SKIP' if case.find('skipped') is not None else 'PASS',
                          'message': issue.get('message') if issue is not None else None,
                          'stack': issue.text if issue is not None else None})
    summary = {'exit': result.returncode, 'seconds': round(time.monotonic() - started, 3),
               'command': command, 'suites': suites, 'cases': cases,
               'totals': {key: sum(int(s.get(key, 0)) for s in suites) for key in ['tests', 'failures', 'errors', 'skipped']}}
    (dest / 'result.json').write_text(json.dumps(summary, indent=2))
    print(name, summary['exit'], summary['totals'], flush=True)
    return summary

def main(output, resume_current=False):
    assert git('diff', '--name-only', ACCEPTED, 'HEAD', '--', 'android-vinetrack') == ''
    assert git('diff', 'HEAD', '--name-only', '--', 'android-vinetrack') == ''
    if not resume_current:
        archive = subprocess.check_output(['git', 'archive', BASELINE, 'android-vinetrack'], cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(output / 'baseline', filter='data')
    baseline_app = output / 'baseline/android-vinetrack'
    current_app = ROOT / 'android-vinetrack'
    test_path = 'app/src/test/java/com/rork/vinetrack/data/WorkTaskCompletionTest.kt'
    assert digest(baseline_app / test_path) == digest(current_app / test_path)
    init = current_app / 'costing-tests.init.gradle'
    metadata = {'baseline': BASELINE, 'accepted': ACCEPTED, 'current': git('rev-parse', 'HEAD'),
                'baseline_android_tree': git('rev-parse', BASELINE + ':android-vinetrack'),
                'current_android_tree': git('rev-parse', 'HEAD:android-vinetrack'),
                'completion_test_sha256': digest(current_app / test_path), 'init_sha256': digest(init),
                'java': subprocess.run(['java', '-version'], capture_output=True, text=True).stderr,
                'environment': {k: os.environ.get(k) for k in ['LANG', 'LC_ALL', 'TZ', 'JAVA_HOME', 'ANDROID_HOME', 'GRADLE_USER_HOME']}}
    if resume_current:
        assert json.loads((output / 'metadata.json').read_text()) == metadata
        before = json.loads((output / 'baseline-five/result.json').read_text())
    else:
        (output / 'metadata.json').write_text(json.dumps(metadata, indent=2))
        before = None
    selection = ['com.rork.vinetrack.data.WorkTaskCompletionTest.' + name for name in METHODS]
    if before is None:
        before = run_stage('baseline-five', baseline_app, selection, output, init)
    # A blocked baseline must remain unverified, but does not prevent the current gate.
    comparable = len(before['cases']) == 5 and {c['name'] for c in before['cases']} == set(METHODS)
    after = run_stage('current-five', current_app, selection, output, init)
    assert len(after['cases']) == 5 and {c['name'] for c in after['cases']} == set(METHODS)
    gate = run_stage('current-costing', current_app,
                     ['*.' + name for name in CLASSES], output, init)
    (output / 'finished.json').write_text(json.dumps({'baseline': before['totals'], 'baseline_comparable': comparable,
                                                       'current': after['totals'], 'costing': gate['totals'],
                                                       'costing_exit': gate['exit'],
                                                       'costing_discovery_valid': len(gate['suites']) == 12 and gate['totals']['tests'] == 205}, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--launch', action='store_true')
    parser.add_argument('--output')
    parser.add_argument('--resume-current', action='store_true')
    args = parser.parse_args()
    output = Path(args.output) if args.output else Path(tempfile.mkdtemp(prefix='vinetrack-costing-baseline-'))
    if args.launch:
        log_name = 'runner-current.log' if args.resume_current else 'runner.log'
        with (output / log_name).open('w') as log:
            command = [sys.executable, __file__, '--output', str(output)]
            if args.resume_current:
                command.append('--resume-current')
            process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        print(json.dumps({'pid': process.pid, 'output': str(output)}))
    else:
        main(output, resume_current=args.resume_current)

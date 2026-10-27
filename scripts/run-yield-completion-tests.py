#!/usr/bin/env python3
"""Yield-only Android host tests; artifacts remain outside the managed project."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('host_runner', Path(__file__).with_name('run-costing-baseline-comparison.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def main(output, debug_build=False):
    app = ROOT / 'android-vinetrack'
    if debug_build:
        command = ['./gradlew', ':app:assembleDebug', '--console=plain',
                   '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC']
        started = time.monotonic()
        with (output / 'debug-build.log').open('w') as log:
            build = subprocess.run(command, cwd=app, stdout=log, stderr=subprocess.STDOUT)
        result = {'exit': build.returncode, 'seconds': round(time.monotonic() - started, 3),
                  'command': command}
        (output / 'finished.json').write_text(json.dumps(result, indent=2))
        return build.returncode
    result = runner.run_stage('yield', app, ['*.' + name for name in [
        'YieldCompletionPersistenceTest', 'YieldVintageReportTest', 'YieldAuthoritativeVineCountTest',
        'SeasonYieldDamageParityTest', 'PruningYieldFormulaParityTest', 'PruningYieldSettingsRevisionSyncTest',
    ]], output, app / 'yield-tests.init.gradle')
    (output / 'finished.json').write_text(json.dumps({'exit': result['exit'], 'totals': result['totals']}, indent=2))
    return result['exit']


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--launch', action='store_true')
    parser.add_argument('--output')
    parser.add_argument('--debug-build', action='store_true')
    args = parser.parse_args()
    output = Path(args.output) if args.output else Path(tempfile.mkdtemp(prefix='vinetrack-yield-completion-'))
    output.mkdir(parents=True, exist_ok=True)
    if args.launch:
        with (output / 'runner.log').open('w') as log:
            command = [sys.executable, __file__, '--output', str(output)]
            if args.debug_build:
                command.append('--debug-build')
            process = subprocess.Popen(command, cwd=ROOT,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        print(json.dumps({'pid': process.pid, 'output': str(output)}))
    else:
        sys.exit(main(output, args.debug_build))

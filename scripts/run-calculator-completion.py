#!/usr/bin/env python3
"""Run the bounded Android calculator regression selection without terminal timeout loss."""
import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--launch', action='store_true')
args = parser.parse_args()
stdout = ROOT / '.rork-tmp/calculator-completion.stdout.log'
stderr = ROOT / '.rork-tmp/calculator-completion.stderr.log'
if args.launch:
    with stdout.open('w') as out, stderr.open('w') as err:
        child = subprocess.Popen([sys.executable, __file__], stdout=out, stderr=err, start_new_session=True)
    print(f'CALCULATOR_REGRESSION_PID={child.pid}')
else:
    result = subprocess.run(['./gradlew', ':app:testDebugUnitTest', '--init-script', '../.rork-tmp/calculator-completion.init.gradle',
        '--console=plain', '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC -XX:SoftRefLRUPolicyMSPerMB=50'],
        cwd=ROOT / 'android-vinetrack')
    print(f'CALCULATOR_REGRESSION_EXIT={result.returncode}', flush=True)
    sys.exit(result.returncode)

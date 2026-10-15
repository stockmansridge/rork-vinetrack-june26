#!/usr/bin/env python3
"""Bounded debug-only MVP regression. No upload, install, release or database access."""
import argparse
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--launch', action='store_true')
parser.add_argument('--combined', action='store_true')
parser.add_argument('--status', action='store_true')
parser.add_argument('--build', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
label = 'combined' if args.combined else 'focused'
if args.status:
    import xml.etree.ElementTree as ET
    log = Path(f'/tmp/vinetrack-spray-mvp-{label}.log')
    text = log.read_text() if log.exists() else 'No run log'
    print('\n'.join(line for line in text.splitlines() if 'e: ' in line or ' FAILED' in line or 'Exception:' in line or 'expected' in line or ' PASSED' in line))
    print(text[-2000:])
    totals = dict(tests=0, failures=0, errors=0, skipped=0)
    suites = list((root / 'android-vinetrack/app/build/test-results/testDebugUnitTest').glob('TEST-*.xml'))
    for file in suites:
        suite = ET.parse(file).getroot()
        for name in totals:
            totals[name] += int(suite.attrib.get(name, 0))
    print(f'XML suites={len(suites)} totals={totals}')
    sys.exit(0)
if args.launch:
    with open(f'/tmp/vinetrack-spray-mvp-{label}.log', 'w') as out:
        cmd = [sys.executable, __file__] + (['--combined'] if args.combined else []) + (['--build'] if args.build else [])
        child = subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    print(f'PID={child.pid}; log=/tmp/vinetrack-spray-mvp-{label}.log')
else:
    command = ['./gradlew', ':app:testDebugUnitTest', '--init-script', '../scripts/spray-mvp-tests.init.gradle',
        '--console=plain', '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC']
    if args.combined:
        command.append('-DsprayMvpCombined=true')
    if args.build:
        command.append(':app:assembleDebug')
    result = subprocess.run(command, cwd=root / 'android-vinetrack', timeout=900)
    print(f'MVP_REGRESSION_EXIT={result.returncode}', flush=True)
    sys.exit(result.returncode)

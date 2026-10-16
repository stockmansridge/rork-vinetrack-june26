#!/usr/bin/env python3
"""Focused Android field-follow-up regressions and Debug-only validation. Never uploads."""
import argparse
import subprocess
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--launch', action='store_true')
parser.add_argument('--status', action='store_true')
args = parser.parse_args()
log = Path('/tmp/vinetrack-spray-field-followup.log')
if args.status:
    text = log.read_text() if log.exists() else 'Not started'
    print('\n'.join(line for line in text.splitlines() if any(word in line for word in ['e: ', ' FAILED', 'BUILD ', 'FIELD_FOLLOWUP_EXIT='])))
    totals = dict(tests=0, failures=0, errors=0, skipped=0)
    files = list((root / 'android-vinetrack/app/build/test-results/testDebugUnitTest').glob('TEST-*.xml'))
    for file in files:
        suite = ET.parse(file).getroot()
        for key in totals:
            totals[key] += int(suite.attrib.get(key, 0))
    print(f'XML suites={len(files)} totals={totals}; XML is final only after FIELD_FOLLOWUP_EXIT=0')
elif args.launch:
    with log.open('w') as out:
        process = subprocess.Popen([sys.executable, __file__], stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    print(f'PID={process.pid}; log={log}')
else:
    result = subprocess.run(['./gradlew', ':app:testDebugUnitTest', ':app:assembleDebug', '--init-script', '../scripts/spray-field-followup-tests.init.gradle', '--console=plain', '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC'], cwd=root / 'android-vinetrack', timeout=900)
    print(f'FIELD_FOLLOWUP_EXIT={result.returncode}', flush=True)
    sys.exit(result.returncode)

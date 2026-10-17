#!/usr/bin/env python3
"""Bounded Debug-only Live Trip validation; no installation, publishing or data operations."""
import argparse
import json
import subprocess
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--background', action='store_true')
args = parser.parse_args()
log = Path('/tmp/vinetrack-live-trip-ui-validation.log')
if args.background:
    with log.open('w') as output:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve())], cwd=root, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    print(json.dumps({'pid': process.pid, 'log': str(log)}))
    sys.exit(0)
command = ['./gradlew', ':app:testDebugUnitTest', ':app:assembleDebug', ':app:assembleDebugAndroidTest', '--init-script', '../scripts/live-trip-ui-tests.init.gradle', '--console=plain', '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC']
result = subprocess.run(command, cwd=root / 'android-vinetrack', timeout=1200)
if result.returncode == 0:
    suites = []
    for name in ['LiveTripGuidanceTest', 'OccurrenceTraversalTrackerTest', 'TripOccurrenceJournalTest']:
        path = root / 'android-vinetrack/app/build/test-results/testDebugUnitTest' / f'TEST-com.rork.vinetrack.data.{name}.xml'
        if not path.exists():
            raise RuntimeError(f'Missing expected test result: {name}')
        node = ET.parse(path).getroot()
        suites.append({key: node.attrib.get(key) for key in ['name', 'tests', 'failures', 'errors', 'skipped']})
    print(json.dumps({'suites': suites}), flush=True)
sys.exit(result.returncode)

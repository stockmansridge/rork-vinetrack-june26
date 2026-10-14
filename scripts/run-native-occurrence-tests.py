#!/usr/bin/env python3
"""Focused Android host occurrence tests. Outputs stay outside the repository; no network fixtures."""
import json
import pathlib
import subprocess
import time
import sys
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parents[1]
output = pathlib.Path('/tmp/vinetrack-native-occurrence-host')
output.mkdir(exist_ok=True)
if '--background' in sys.argv:
    (output / 'result.json').unlink(missing_ok=True)
    with (output / 'runner.log').open('w') as stdout, (output / 'runner-error.log').open('w') as stderr:
        process = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve())], cwd=root,
                                   stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True)
    print(json.dumps({'status': 'started', 'pid': process.pid, 'output': str(output)}))
    raise SystemExit(0)
if '--report' in sys.argv:
    result_file = output / 'result.json'
    print(result_file.read_text() if result_file.exists() else 'Host suite has not finished')
    for name in ('stderr.log', 'stdout.log'):
        file = output / name
        if file.exists():
            lines = file.read_text().splitlines()
            diagnostics = [line for line in lines if line.startswith('e:') or 'error:' in line.lower()]
            print(name + ':\n' + '\n'.join(diagnostics + lines[-100:]))
    raise SystemExit(0)
app = root / 'android-vinetrack'
command = [str(app / 'gradlew'), '-p', str(app), '--no-daemon',
           '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC',
           '-PoccurrenceFocusedTests=true', ':app:testDebugUnitTest',
           '--tests', 'com.rork.vinetrack.data.TripOccurrenceJournalTest',
           '--tests', 'com.rork.vinetrack.data.OccurrenceTraversalTrackerTest', '--console=plain']
started = time.time()
with (output / 'stdout.log').open('w') as stdout, (output / 'stderr.log').open('w') as stderr:
    result = subprocess.run(command, cwd=root, stdout=stdout, stderr=stderr, timeout=1500)
report = {'exitCode': result.returncode, 'elapsedSeconds': round(time.time()-started, 2), 'suites': []}
for path in sorted((app / 'app/build/test-results/testDebugUnitTest').glob('TEST-*.xml')):
    if path.stat().st_mtime < started:
        continue
    suite = ET.parse(path).getroot()
    report['suites'].append({key: suite.attrib.get(key) for key in ('name', 'tests', 'failures', 'errors', 'skipped')})
(output / 'result.json').write_text(json.dumps(report, indent=2))
raise SystemExit(result.returncode)

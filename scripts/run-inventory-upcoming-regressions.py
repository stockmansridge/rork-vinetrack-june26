#!/usr/bin/env python3
"""Scoped Android tests; optional immutable Git archive baseline, never a checkout."""
import argparse
import hashlib
import io
import json
import pathlib
import subprocess
import sys
import tarfile
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', help='Read-only Git revision to export under /tmp')
parser.add_argument('--label', default='validation')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
output = pathlib.Path('/tmp') / ('vinetrack-inventory-upcoming-' + args.label)
output.mkdir(exist_ok=True)
app = root / 'android-vinetrack'
verified = 0
if args.baseline:
    archive = subprocess.check_output(['git', 'archive', '--format=tar', args.baseline, 'android-vinetrack'], cwd=root)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(output, filter='data')
    app = output / 'android-vinetrack'
    paths = subprocess.check_output(['git', 'ls-tree', '-rz', args.baseline, '--', 'android-vinetrack'], cwd=root)
    for entry in paths.split(b'\0'):
        if not entry:
            continue
        metadata, name = entry.split(b'\t', 1)
        _, kind, digest = metadata.split()
        if kind != b'blob':
            continue
        exported = output / name.decode()
        content = exported.read_bytes()
        actual = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
        if actual != digest.decode():
            raise RuntimeError('Baseline byte verification failed: ' + name.decode())
        verified += 1
    # Config is generated/ignored by Rork, not tracked application source. No real endpoint/key.
    companion = app / 'app/src/main/java/com/rork/vinetrack/Config.kt'
    companion.write_text('package com.rork.vinetrack\nobject Config { val allValues: Map<String, String> = mapOf("EXPO_PUBLIC_SUPABASE_URL" to "https://baseline.invalid", "EXPO_PUBLIC_SUPABASE_ANON_KEY" to "synthetic-not-a-credential", "EXPO_PUBLIC_GOOGLE_WEB_CLIENT_ID" to "synthetic.invalid") }\n')
command = [str(app / 'gradlew'), '-p', str(app), '--no-daemon', '-I',
           str(root / 'scripts/inventory-upcoming-tests.init.gradle'),
           '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC -XX:SoftRefLRUPolicyMSPerMB=50',
           ':app:testDebugUnitTest']
started = time.time()
with (output / 'stdout.log').open('w') as stdout, (output / 'stderr.log').open('w') as stderr:
    result = subprocess.run(command, cwd=root, stdout=stdout, stderr=stderr)
report = {'command': command, 'exitCode': result.returncode, 'baseline': args.baseline,
          'verifiedTrackedFiles': verified, 'elapsedSeconds': round(time.time() - started, 2), 'suites': []}
folder = app / 'app/build/test-results/testDebugUnitTest'
for path in sorted(folder.glob('TEST-*.xml')):
    if path.stat().st_mtime < started:
        continue
    suite = ET.parse(path).getroot()
    details = {key: suite.attrib.get(key) for key in ('name', 'tests', 'failures', 'errors', 'skipped', 'timestamp')}
    details['failedCases'] = [{'name': case.attrib['name'], 'message': case.find('failure').attrib.get('message')}
                              for case in suite.findall('testcase') if case.find('failure') is not None]
    report['suites'].append(details)
(output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
sys.exit(result.returncode)

#!/usr/bin/env python3
"""Focused pin-capture JVM validation. No install, upload, or store action."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--background', action='store_true')
args = parser.parse_args()
log = Path('/tmp/vinetrack-pin-capture-validation.log')
if args.background:
    with log.open('w') as output:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve())], cwd=root,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    print(json.dumps({'pid': process.pid, 'log': str(log)}))
    sys.exit(0)
result = subprocess.run(['./gradlew', ':app:testDebugUnitTest', '--init-script',
                         '../scripts/pin-capture-tests.init.gradle', '--console=plain',
                         '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC'],
                        cwd=root / 'android-vinetrack', timeout=1200)
if result.returncode == 0:
    for name in ['PinTravelDirectionTest', 'PinAisleAttachmentTest', 'PinCaptureEvidenceContractTest', 'PinCaptureCoordinatorTest', 'PinConfirmationReplayTest', 'PinReconciliationCorrectionTest']:
        path = root / 'android-vinetrack/app/build/test-results/testDebugUnitTest' / f'TEST-com.rork.vinetrack.data.{name}.xml'
        node = ET.parse(path).getroot()
        print(json.dumps({key: node.attrib.get(key) for key in ['name', 'tests', 'failures', 'errors', 'skipped']}), flush=True)
sys.exit(result.returncode)

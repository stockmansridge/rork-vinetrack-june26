#!/usr/bin/env python3
"""Bounded non-release Android sync regression runner; outputs stay outside the repo."""
import argparse
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--launch', action='store_true')
args = parser.parse_args()
if args.launch:
    with open('/tmp/vinetrack-sync-tests.stdout.log', 'w') as out, open('/tmp/vinetrack-sync-tests.stderr.log', 'w') as err:
        child = subprocess.Popen([sys.executable, __file__], stdout=out, stderr=err, start_new_session=True)
    print(f'PID={child.pid}')
else:
    result = subprocess.run(['./gradlew', ':app:testDebugUnitTest', '--init-script', '../scripts/sync-recovery-tests.init.gradle',
        '--console=plain', '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC'], cwd=root / 'android-vinetrack', timeout=900)
    print(f'SYNC_REGRESSION_EXIT={result.returncode}', flush=True)
    sys.exit(result.returncode)

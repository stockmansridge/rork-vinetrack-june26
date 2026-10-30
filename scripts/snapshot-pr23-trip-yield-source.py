#!/usr/bin/env python3
"""Inventory PR23 integration without changing Git, old manifests or release state."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
PARENT = 'c6bf17ce7e046efa25e120c8dd148ae56371e4cd'
BASE = '58dc23dffc7340a56ebebc36868a6eeda40c4081'
HEAD = 'eea8b318d2275da4b32389fba63ba955d317ec76'

def sha(data):
    return hashlib.sha256(data).hexdigest()

comparison = json.loads(Path('/tmp/vinetrack-pr23-compare.json').read_text())
paths = {f['filename'] for f in comparison['files']}
paths.update(['scripts/prepare-pr23-source.py', 'scripts/run-pr23-yield-host-tests.py',
              'scripts/snapshot-pr23-trip-yield-source.py'])
files = []
with tarfile.open('/tmp/vinetrack-pr23.tar.gz') as archive:
    prefix = archive.getnames()[0] + '/'
    for name in sorted(paths):
        data = (ROOT / name).read_bytes()
        before = subprocess.run(['git', 'show', f'{PARENT}:{name}'], cwd=ROOT, capture_output=True)
        upstream = archive.extractfile(prefix + name).read() if name in {f['filename'] for f in comparison['files']} else None
        if upstream is not None:
            assert upstream == data, f'Local divergence requires review: {name}'
        files.append({'path': name, 'sha256': sha(data),
                      'parent_sha256': sha(before.stdout) if before.returncode == 0 else None,
                      'reviewed_pr_head_sha256': sha(upstream) if upstream is not None else None})
manifest = {'managed_source_parent': PARENT, 'integration_commit': None,
            'reviewed_pr23_head': HEAD, 'reviewed_pr23_base': BASE,
            'existing_native_before_images': 'All 14 modified upstream files matched reconciled base; 9 upstream additions had no local conflict',
            'validation': {'ios_tests': {'passed': 94, 'seconds': 134},
                           'android_instrumentation': {'passed': 14, 'failed': 0, 'skipped': 0, 'seconds': 14},
                           'android_host': {'passed': 15, 'failures': 0, 'errors': 0, 'skipped': 0},
                           'ios_normal_simulator_build': 'PASS', 'android_normal_build': 'PASS',
                           'original_phone_and_portal_sync_acceptance': 'UNVERIFIED'},
            'files': files}
out = ROOT / 'docs/reviews/pr23-trip-yield-source-manifest-20261030.json'
out.write_text(json.dumps(manifest, indent=2) + '\n')
print(f'{len(files)} inputs; manifest_sha256={sha(out.read_bytes())}')

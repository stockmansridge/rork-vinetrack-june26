#!/usr/bin/env python3
"""Record hashes of PR22 validation inputs without modifying native sources.

Run after validation, while the reviewed head archive is retained in /tmp.
The managed parent is not claimed as the unpublished integration revision.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
REVIEWED = Path('/tmp/vinetrack-pr22.tar.gz')
archive = tarfile.open(REVIEWED, 'r:gz')
reviewed_files = {member.name.split('/', 1)[1]: member for member in archive.getmembers()
                  if member.isfile() and '/' in member.name}
OUTPUT = ROOT / 'docs/reviews/pr22-native-source-manifest-20261030.json'
parent = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
names = subprocess.check_output(
    ['git', 'diff', '--name-only', 'HEAD', '--', 'ios', 'android-vinetrack', 'scripts'],
    cwd=ROOT, text=True).splitlines()
names += ['scripts/snapshot-pr22-source.py']
rows = []
for name in sorted(set(names)):
    path = ROOT / name
    if not path.is_file() or path.is_symlink():
        raise ValueError(f'Expected regular validation input: {name}')
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    reviewed = reviewed_files.get(name)
    comparison = ('matches_reviewed_head' if archive.extractfile(reviewed).read() == path.read_bytes()
                  else 'local_difference') if reviewed else 'not_in_reviewed_head'
    rows.append({'path': name, 'sha256': digest, 'reviewed_head_comparison': comparison})
OUTPUT.write_text(json.dumps({
    'reviewed_public_head': '07ddba427a3edb49a5aafb9f639f29c59e7d2fe8',
    'managed_source_parent': parent,
    'integration_commit': None,
    'scope': 'Changed native and validation-script inputs relative to managed parent; not a full repository archive.',
    'files': rows,
}, indent=2) + '\n')
print(f'{len(rows)} inputs: {OUTPUT.relative_to(ROOT)}')
print('manifest_sha256=' + hashlib.sha256(OUTPUT.read_bytes()).hexdigest())
for row in rows:
    if row['reviewed_head_comparison'] == 'local_difference':
        print('local_difference:', row['path'])

#!/usr/bin/env python3
"""Record deletion-only native delta without touching Git or delivery state."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PARENT = 'fb4b6ec591559c3391e74a5463000c9320549338'
PUBLIC_PR22 = '07ddba427a3edb49a5aafb9f639f29c59e7d2fe8'

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).splitlines()

paths = set(git('diff', '--name-only', PARENT, '--', 'ios'))
paths.update(git('ls-files', '--others', '--exclude-standard', '--', 'ios'))
paths.add('scripts/snapshot-trip-deletion-source.py')
files = []
for name in sorted(paths):
    path = ROOT / name
    if path.is_file():
        files.append({'path': name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
manifest = {
    'reviewed_public_pr22_head': PUBLIC_PR22,
    'managed_source_parent': PARENT,
    'integration_commit': None,
    'scope': 'iOS Trip deletion recovery and diagnostics; no release counter or backend changes',
    'files': files,
}
out = ROOT / 'docs/reviews/pr22-trip-deletion-source-manifest-20261030.json'
out.write_text(json.dumps(manifest, indent=2) + '\n')
print(f'{len(files)} inputs; manifest_sha256={hashlib.sha256(out.read_bytes()).hexdigest()}')

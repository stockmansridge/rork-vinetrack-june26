#!/usr/bin/env python3
"""Reconcile exact PR22 native source without checkout, merge, push or database work.

Archives and API metadata must already exist outside the project. Every existing
changed file must match the reviewed base or head before any write is permitted.
Local configuration and all paths outside the reviewed native delta are untouched.
"""
import filecmp
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEAD = Path('/tmp/vinetrack-pr22')
BASE = Path('/tmp/vinetrack-pr22-base')
SHA = '07ddba427a3edb49a5aafb9f639f29c59e7d2fe8'
metadata = json.loads(Path('/tmp/vinetrack-pr22.json').read_text())
assert metadata['head']['sha'] == SHA
files = json.loads(Path('/tmp/vinetrack-pr22-files.json').read_text())
prepared = []
for entry in files:
    name = entry['filename']
    if not name.startswith(('ios/VineTrack/', 'ios/VineTrackTests/', 'ios/VineTrackUITests/', 'android-vinetrack/app/src/', 'docs/sync/', 'scripts/repairs/', 'scripts/tests/', 'scripts/audit_sync_inventory.py')):
        continue
    relative = Path(name)
    assert not relative.is_absolute() and '..' not in relative.parts
    source, base, target = HEAD / relative, BASE / relative, ROOT / relative
    assert source.is_file() and not source.is_symlink() and not target.is_symlink()
    if target.exists():
        if filecmp.cmp(target, source, shallow=False):
            continue
        assert base.exists() and filecmp.cmp(target, base, shallow=False), f'Needs reconciliation: {name}'
    else:
        assert not base.exists(), f'Missing existing file: {name}'
    prepared.append((source, target))
for source, target in prepared:
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(source.read_bytes())
    print(hashlib.sha256(target.read_bytes()).hexdigest(), target.relative_to(ROOT))
print(f'Prepared {len(prepared)} exact reviewed files from {SHA}; no workflow or migration installed/executed.')

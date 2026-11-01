#!/usr/bin/env python3
"""Apply reviewed PR31 textual deltas once; preserve newer managed source and config."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
HEAD = '7c344904de0c8b6c636b17935a5c77c04e84497a'
OUT = ROOT / 'docs/reviews/evidence/pr31-20261101/integration.json'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def main():
    assert not OUT.exists(), 'Integration already recorded; do not rerun'
    metadata = json.loads(Path('/tmp/vinetrack-pr31.json').read_text())
    assert metadata['head']['sha'] == HEAD
    changes = json.loads(Path('/tmp/vinetrack-pr31-compare.json').read_text())['files']
    excluded = '.github/workflows/incident-source-review.yml'
    config = ROOT / 'ios/VineTrack/App/AppConfig.swift'
    protected = config.read_bytes()
    plans = []
    with tarfile.open('/tmp/vinetrack-pr31.tar.gz') as archive:
        prefix = archive.getmembers()[0].name.split('/')[0] + '/'
        for change in changes:
            rel = change['filename']
            if rel == excluded:
                continue
            assert rel.startswith(('ios/', 'android-vinetrack/', 'scripts/', 'docs/reviews/', 'sql/'))
            path = ROOT / rel
            expected = archive.extractfile(prefix + rel).read()
            before = path.read_bytes() if path.exists() else b''
            patch = None
            if change['status'] == 'added':
                assert not path.exists(), rel
            else:
                assert change['status'] == 'modified' and path.exists()
                patch = f'--- {rel}\n+++ {rel}\n' + change['patch'] + '\n'
                subprocess.run(['patch', '--dry-run', '--batch', '--fuzz=0', str(path)], input=patch.encode(), check=True, cwd=ROOT)
            plans.append((path, before, expected, patch))
        receipt = {'startingManagedRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip(),
                   'prHead': HEAD, 'productionCheckpoint': '43446a0ff85dac5d0a19ff9b35e2473fe765cf12',
                   'excluded': {excluded: 'Branch-only self-committing/pushing workflow and synthetic CI config; not appropriate for managed source or release validation.'},
                   'method': 'All deltas dry-run with fuzz zero before mutation; additions absent-only; no baseline replacement.', 'changes': []}
        for path, before, expected, patch in plans:
            if patch:
                subprocess.run(['patch', '--batch', '--fuzz=0', '--no-backup-if-mismatch', '--reject-file=/tmp/vinetrack-pr31-rejected.patch', str(path)], input=patch.encode(), check=True, cwd=ROOT)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(expected)
            after = path.read_bytes()
            receipt['changes'].append({'path': str(path.relative_to(ROOT)), 'beforeSha256': sha(before), 'afterSha256': sha(after), 'prSnapshotSha256': sha(expected), 'snapshotParity': after == expected})
        assert config.read_bytes() == protected
        receipt['protectedIosConfigSha256'] = sha(protected)
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt, indent=2))

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Apply PR32 reviewed deltas only; protect newer managed files and release config."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
ROOT = Path(__file__).resolve().parents[1]
HEAD = 'dd021b953c284b61f5d334051a5fa18254048c71'
OUT = ROOT / 'docs/reviews/evidence/pr32-20261101/integration.json'
def digest(data): return hashlib.sha256(data).hexdigest()
def main():
    assert not OUT.exists(), 'Already integrated; do not rerun'
    metadata = json.loads(Path('/tmp/vinetrack-pr32.json').read_text())
    assert metadata['head']['sha'] == HEAD
    changes = json.loads(Path('/tmp/vinetrack-pr32-compare.json').read_text())['files']
    protected = ['ios/VineTrack/App/AppConfig.swift', 'android-vinetrack/app/build.gradle.kts', 'android-vinetrack/app/src/main/java/com/rork/vinetrack/Config.kt']
    originals = {p: (ROOT / p).read_bytes() for p in protected}
    plans = []
    with tarfile.open('/tmp/vinetrack-pr32.tar.gz') as archive:
        prefix = archive.getmembers()[0].name.split('/')[0] + '/'
        for change in changes:
            rel = change['filename']
            if rel.startswith('.github/'): continue
            assert rel.startswith(('android-vinetrack/', 'scripts/', 'docs/reviews/'))
            path = ROOT / rel
            expected = archive.extractfile(prefix + rel).read()
            before = path.read_bytes() if path.exists() else b''
            patch = None
            if change['status'] == 'added': assert not path.exists(), rel
            else:
                assert change['status'] == 'modified' and path.exists()
                patch = f'--- {rel}\n+++ {rel}\n' + change['patch'] + '\n'
                subprocess.run(['patch', '--dry-run', '--batch', '--fuzz=0', str(path)], input=patch.encode(), cwd=ROOT, check=True)
            plans.append((path, before, expected, patch))
        receipt = {'startingManagedRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip(), 'prHead': HEAD, 'productionCheckpoint': 'f511b0a9e96518f4ee3176775b2f812b2e927a44', 'excluded': {'.github/workflows/android-chemical-recovery.yml': 'Branch-specific workflow and synthetic configuration are not managed release validation'}, 'method': 'All modified deltas dry-run with fuzz zero; absent-only additions, no source tree replacement', 'changes': []}
        for path, before, expected, patch in plans:
            if patch:
                subprocess.run(['patch', '--batch', '--fuzz=0', '--no-backup-if-mismatch', '--reject-file=/tmp/vinetrack-pr32-rejected.patch', str(path)], input=patch.encode(), cwd=ROOT, check=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(expected)
            after = path.read_bytes()
            receipt['changes'].append({'path': str(path.relative_to(ROOT)), 'beforeSha256': digest(before), 'afterSha256': digest(after), 'prSnapshotSha256': digest(expected), 'snapshotParity': after == expected})
        for p, before in originals.items(): assert (ROOT / p).read_bytes() == before, p
        receipt['protectedConfigurationHashes'] = {p: digest(v) for p, v in originals.items()}
        OUT.parent.mkdir(parents=True, exist_ok=True); OUT.write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt, indent=2))
if __name__ == '__main__': main()

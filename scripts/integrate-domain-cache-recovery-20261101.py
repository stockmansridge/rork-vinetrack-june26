#!/usr/bin/env python3
"""Guarded PR30 delta integration and source reconciliation; Git remains read-only."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
SHA = 'b43fcdd17e9ba439edd8aa9947d58be1e2975bde'
BASE = '292cd8da2b089ee7729b32537793c8f55549d362'
OUT = ROOT / 'docs/reviews/evidence/domain-cache-recovery-20261101'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    commit = json.loads(Path('/tmp/vinetrack-repair-c.json').read_text())
    assert commit['sha'] == SHA and [p['sha'] for p in commit['parents']] == [BASE]
    mismatches = []
    compared = 0
    with tarfile.open('/tmp/vinetrack-checkpoint.tar.gz') as archive:
        prefix = archive.getmembers()[0].name.split('/')[0] + '/'
        for item in archive.getmembers():
            if not item.isfile() or not item.name.startswith(prefix + 'android-vinetrack/'):
                continue
            rel = item.name[len(prefix):]
            local = ROOT / rel
            expected = archive.extractfile(item).read()
            compared += 1
            if not local.exists() or local.read_bytes() != expected or bool(local.stat().st_mode & 0o111) != bool(item.mode & 0o111):
                mismatches.append(rel)
    managed = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip()
    tree = subprocess.check_output(['git', 'rev-parse', 'HEAD:android-vinetrack'], cwd=ROOT).decode().strip()
    # This is the exact source tree identifier returned by the completed managed AAB listing.
    assert 'src_' + tree[:17] == 'src_19b29f94226c46f01'
    assert not mismatches, mismatches  # Stop rather than overwrite newer work.
    changes = []
    patches = []
    with tarfile.open('/tmp/vinetrack-repair-c.tar.gz') as archive:
        prefix = archive.getmembers()[0].name.split('/')[0] + '/'
        for change in commit['files']:
            rel = change['filename']
            assert rel.startswith(('android-vinetrack/', 'docs/reviews/'))
            assert change['status'] in ('added', 'modified')
            path = ROOT / rel
            before = path.read_bytes() if path.exists() else b''
            expected = archive.extractfile(prefix + rel).read()
            if change['status'] == 'added':
                assert not path.exists(), rel
            else:
                assert path.exists() and change.get('patch')
                patch = f'--- {rel}\n+++ {rel}\n' + change['patch'] + '\n'
                subprocess.run(['patch', '--dry-run', '--batch', '--fuzz=0', str(path)], input=patch.encode(), check=True, cwd=ROOT)
                patches.append((path, patch))
            changes.append({'path': rel, 'status': change['status'], 'beforeSha256': digest(before), 'repairSha256': digest(expected)})
        for path, patch in patches:
            subprocess.run(['patch', '--batch', '--fuzz=0', '--no-backup-if-mismatch', '--reject-file=/tmp/vinetrack-domain-rejected.patch', str(path)], input=patch.encode(), check=True, cwd=ROOT)
        for change in changes:
            path = ROOT / change['path']
            expected = archive.extractfile(prefix + change['path']).read()
            if change['status'] == 'added':
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(expected)
            assert path.read_bytes() == expected, change['path']
            change['integratedSha256'] = digest(path.read_bytes())
    OUT.mkdir(parents=True, exist_ok=True)
    receipt = {
        'reportedInstalledCode': 1793504699,
        'startingManagedRevision': managed,
        'androidTree': tree,
        'completedManagedBuild': {'runId': 'a181d5f1-0d78-4e45-9df8-d4d00adb9308', 'snapshotId': '5jro96dg5cnmlhixk43ev', 'sourceHash': 'src_19b29f94226c46f01', 'packageName': 'com.rork.vinetrack', 'status': 'completed'},
        'mappingBoundary': 'Completed build sourceHash exactly matches managed Android tree. Tools expose no version code or committed submission for this run, so linkage to reported installed1793504699 remains unverified. No manual push; managed sync only.',
        'publicCheckpoint': BASE, 'androidFilesCompared': compared, 'mismatches': mismatches,
        'pruningAtCheckpoint': 'Empty-only admission remains; no completed pruning implementation found in current managed source.',
        'repair': SHA, 'method': 'Dry-run then apply exact textual delta with fuzz zero; additions only when absent. No branch swap or baseline overwrite.',
        'changes': changes,
    }
    (OUT / 'integration-and-reconciliation.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()

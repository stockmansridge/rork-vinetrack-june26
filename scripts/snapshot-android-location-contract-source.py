#!/usr/bin/env python3
"""Immutable read-only source/evidence checkpoint for the Android location correction."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PARENT = 'fd7f0428c9f514d93b9e05c2a2bb1c9fa49784a7'
PUBLIC = '6efee9e4db21d11b8a1963b0e60f3e7aa489deda'
PREFIX = 'android-vinetrack/'
EVIDENCE = 'docs/reviews/evidence/android-location-contract-20261031'
OUT = ROOT / 'docs/reviews/android-location-contract-source-manifest-20261031.json'
CHANGED = {
    PREFIX + 'app/src/main/java/com/rork/vinetrack/data/auth/AccountTransitionEvidence.kt',
    PREFIX + 'app/src/main/java/com/rork/vinetrack/data/auth/RecoveryLocationContract.kt',
    PREFIX + 'app/src/androidTest/java/com/rork/vinetrack/data/auth/AuthRetentionAndroidTest.kt',
    PREFIX + 'app/src/androidTest/java/com/rork/vinetrack/data/auth/PopulatedCleanExitActivityTest.kt',
}

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def object_hash(kind, data):
    return hashlib.sha1(kind.encode() + b' ' + str(len(data)).encode() + b'\0' + data).digest()

def tree_hash(entries):
    tree = {}
    for path, mode, blob in entries:
        node = tree
        parts = path.split('/')
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node[parts[-1]] = (mode, blob)
    def encode(node):
        data = b''
        for name, value in sorted(node.items(), key=lambda item: (item[0] + ('/' if isinstance(item[1], dict) else '')).encode()):
            mode, digest = ('40000', encode(value)) if isinstance(value, dict) else value
            data += mode.encode() + b' ' + name.encode() + b'\0' + digest
        return object_hash('tree', data)
    return encode(tree).hex()

assert git('rev-parse', 'HEAD').decode().strip() == PARENT, 'Parent fence; do not regenerate against a later revision'
assert not git('diff', PARENT, '--name-only', '--', 'ios').strip()
assert not OUT.exists(), 'Historical checkpoint must not be overwritten'
paths = sorted(set(git('ls-files', '--cached', '--others', '--exclude-standard', '--', PREFIX).decode().splitlines()))
full, entries, changed = [], [], set()
for path in paths:
    file = ROOT / path
    assert file.is_file() and not file.is_symlink(), path
    raw = file.read_bytes()
    mode = '100755' if file.stat().st_mode & 0o111 else '100644'
    entries.append((path[len(PREFIX):], mode, object_hash('blob', raw)))
    full.append({'path': path, 'mode': mode, 'sha256': sha(raw)})
    before = subprocess.run(['git', 'show', f'{PARENT}:{path}'], cwd=ROOT, capture_output=True)
    if before.returncode or before.stdout != raw:
        changed.add(path)
assert changed == CHANGED, changed
parent_entries, parent_full = [], []
for entry in git('ls-tree', '-r', '-z', PARENT, '--', PREFIX).split(b'\0'):
    if not entry:
        continue
    metadata, encoded_path = entry.split(b'\t')
    mode, kind, oid = metadata.decode().split()
    path = encoded_path.decode()
    assert kind == 'blob'
    parent_entries.append((path[len(PREFIX):], mode, bytes.fromhex(oid)))
    parent_full.append({'path': path, 'mode': mode, 'sha256': sha(git('show', f'{PARENT}:{path}'))})
parent_tree = git('rev-parse', f'{PARENT}:{PREFIX[:-1]}').decode().strip()
assert tree_hash(parent_entries) == parent_tree
# Public archive was fetched read-only at exact PUBLIC. Compare every Android byte and executable mode.
public_root = Path('/tmp/vinetrack-location-main')
public_paths = {PREFIX + str(p.relative_to(public_root / PREFIX)) for p in (public_root / PREFIX).rglob('*') if p.is_file()}
assert public_paths == {item['path'] for item in parent_full}
for item in parent_full:
    file = public_root / item['path']
    assert sha(file.read_bytes()) == item['sha256'], item['path']
    assert ('100755' if file.stat().st_mode & 0o111 else '100644') == item['mode'], item['path']
historical = {}
for name, expected in {
    'android-retained-contract-source-manifest-20261031.json': 'dd10d3b690f46a033eac24f1816afa3185ad0f857bf75e02701671d380897c41',
    'android-recovery-journeys-source-manifest-20261031.json': 'a2fa283409697f5755891a6e82b0f2a4aa20ffd62a037fbd748115e4889e8015',
    'pr26-quadrant-source-manifest-20261031.json': 'ff3f004f6f3d893abdf315ebee9845f4eb9a057d4caa23a370d56049fa6f5337',
}.items():
    path = 'docs/reviews/' + name
    assert sha((ROOT / path).read_bytes()) == expected, path
    historical[path] = expected
prior = json.loads((ROOT / 'docs/reviews/android-retained-contract-source-manifest-20261031.json').read_bytes())
config = prior['protected']['ios_configuration']
assert sha((ROOT / config['path']).read_bytes()) == config['sha256']
# Every pre-existing Android path outside the explicit four-path delta is identical to the parent.
inputs = CHANGED | {
    PREFIX + 'app/src/main/java/com/rork/vinetrack/data/VineyardLogoCache.kt',
    PREFIX + 'app/src/main/java/com/rork/vinetrack/data/auth/AuthRecoveryRepository.kt',
    PREFIX + 'app/src/main/java/com/rork/vinetrack/data/auth/RecoveryDiagnostics.kt',
    PREFIX + 'app/src/main/java/com/rork/vinetrack/data/auth/SessionStore.kt',
    PREFIX + 'app/src/main/java/com/rork/vinetrack/ui/auth/ProtectedWorkRecoveryViewModel.kt',
    'scripts/snapshot-android-location-contract-source.py',
    'scripts/inspect-android-recovery-apk.py',
}
files = []
for path in sorted(inputs):
    before = subprocess.run(['git', 'show', f'{PARENT}:{path}'], cwd=ROOT, capture_output=True)
    files.append({'path': path, 'sha256': sha((ROOT / path).read_bytes()), 'parent_sha256': sha(before.stdout) if before.returncode == 0 else None})
evidence = [{'path': str(p.relative_to(ROOT)), 'sha256': sha(p.read_bytes())} for p in sorted((ROOT / EVIDENCE).iterdir()) if p.is_file()]
current_tree = tree_hash(entries)
manifest = {
    'managed_source_parent': PARENT,
    'repaired_managed_revision': None,
    'note': 'Parent is not repaired revision. Record backend-resolved repaired revision and Play artifact identity separately after sync.',
    'public_main': PUBLIC,
    'parent_public_parity': {'files': len(parent_full), 'changed': 0, 'added': 0, 'removed': 0, 'modes_identical': True, 'inventory_sha256': sha(json.dumps(sorted(parent_full, key=lambda x: x['path']), sort_keys=True).encode())},
    'parent_android_tree': parent_tree,
    'current_android_tree': current_tree,
    'source_label': 'src_' + current_tree[:17],
    'changed_android_paths': sorted(CHANGED),
    'protected': {'all_other_android_paths_unchanged': True, 'ios_tracked_unchanged': True, 'ios_configuration': config, 'historical_manifests': historical},
    'files': files,
    'all_android_files': full,
    'evidence': evidence,
    'validation': json.loads((ROOT / EVIDENCE / 'validation-results.json').read_bytes()),
    'local_release_inspection': json.loads((ROOT / EVIDENCE / 'local-release-inspection.json').read_bytes()),
    'latest_affected_installed_code': 1793486039,
    'handset_exact_location_known': False,
    'original_device_acceptance': False,
    'public_release': False,
}
OUT.write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({'source_inputs': len(files), 'evidence_files': len(evidence), 'android_files': len(full), 'android_tree': current_tree, 'source_label': manifest['source_label'], 'manifest_sha256': sha(OUT.read_bytes())}, indent=2))

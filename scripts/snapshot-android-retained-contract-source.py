#!/usr/bin/env python3
"""Inventory this correction without rewriting historical manifests or Git objects."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PARENT = '22f977512f69f508bfd78c1f47f2cadb61c224f7'
PUBLIC = 'ee8c38588106bbcee90d0f7ff5ca1a2253cc33a8'
PREFIX = 'android-vinetrack/'
EVIDENCE = 'docs/reviews/evidence/android-retained-contract-20261031'
OUT = ROOT / 'docs/reviews/android-retained-contract-source-manifest-20261031.json'

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def object_hash(kind, data):
    return hashlib.sha1(kind.encode() + b' ' + str(len(data)).encode() + b'\0' + data).digest()

def tree_hash(entries):
    tree = {}
    for path, mode, blob in entries:
        parts = path.split('/')
        parent = tree
        for part in parts[:-1]:
            parent = parent.setdefault(part, {})
        parent[parts[-1]] = (mode, blob)
    def encode(node):
        ordered = sorted(node.items(), key=lambda item: (item[0] + ('/' if isinstance(item[1], dict) else '')).encode())
        data = b''
        for name, value in ordered:
            mode, digest = ('40000', encode(value)) if isinstance(value, dict) else value
            data += mode.encode() + b' ' + name.encode() + b'\0' + digest
        return object_hash('tree', data)
    return encode(tree).hex()

assert git('rev-parse', 'HEAD').decode().strip() == PARENT, 'Parent fence: do not rerun on a later revision'
assert not git('diff', PARENT, '--name-only', '--', 'ios').strip()
paths = sorted(set(git('ls-files', '--cached', '--others', '--exclude-standard', '--', PREFIX).decode().splitlines()))
entries = []
full = []
for path in paths:
    file = ROOT / path
    assert file.is_file() and not file.is_symlink(), path
    raw = file.read_bytes()
    mode = '100755' if file.stat().st_mode & 0o111 else '100644'
    entries.append((path[len(PREFIX):], mode, object_hash('blob', raw)))
    full.append({'path': path, 'mode': mode, 'sha256': sha(raw)})

changed = set(git('diff', PARENT, '--name-only', '--', PREFIX).decode().splitlines())
changed.update(path for path in paths if subprocess.run(['git', 'cat-file', '-e', f'{PARENT}:{path}'], cwd=ROOT, capture_output=True).returncode != 0)
files = []
for path in sorted(changed | {'scripts/snapshot-android-retained-contract-source.py'}):
    before = subprocess.run(['git', 'show', f'{PARENT}:{path}'], cwd=ROOT, capture_output=True)
    files.append({'path': path, 'sha256': sha((ROOT / path).read_bytes()), 'parent_sha256': sha(before.stdout) if before.returncode == 0 else None})

historical = {}
for name, expected in {
    'android-recovery-journeys-source-manifest-20261031.json': 'a2fa283409697f5755891a6e82b0f2a4aa20ffd62a037fbd748115e4889e8015',
    'android-populated-auth-source-manifest-20261031.json': '246fac87d0aff85da70038a489dd4c8ddd9f9a31d4780dc0a231eb495331b391',
    'pr26-quadrant-source-manifest-20261031.json': 'ff3f004f6f3d893abdf315ebee9845f4eb9a057d4caa23a370d56049fa6f5337',
}.items():
    path = 'docs/reviews/' + name
    actual = sha((ROOT / path).read_bytes())
    assert actual == expected, path
    historical[path] = actual
quadrant = json.loads((ROOT / 'docs/reviews/pr26-quadrant-source-manifest-20261031.json').read_bytes())
config = quadrant['preserved_ignored_generated_configuration']
assert sha((ROOT / config['path']).read_bytes()) == config['sha256']
# AppViewModel has an explicit narrow reconciliation boundary delta; never normalize it away.
protected_unchanged = []
for item in quadrant['files']:
    if item['path'] != PREFIX + 'app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt':
        assert sha((ROOT / item['path']).read_bytes()) == item['sha256'], item['path']
        protected_unchanged.append(item['path'])

parent_tree = git('rev-parse', f'{PARENT}:{PREFIX[:-1]}').decode().strip()
assert parent_tree == '4133d87d1152dd0d9639556504914a8f1a7ac851'
# Verify our independent read-only tree encoding against Git's parent tree.
parent_entries = []
for entry in git('ls-tree', '-r', '-z', PARENT, '--', PREFIX).split(b'\0'):
    if not entry:
        continue
    metadata, path = entry.split(b'\t')
    mode, kind, oid = metadata.decode().split()
    assert kind == 'blob'
    parent_entries.append((path.decode()[len(PREFIX):], mode, bytes.fromhex(oid)))
assert tree_hash(parent_entries) == parent_tree
current_tree = tree_hash(entries)
evidence = [{'path': str(p.relative_to(ROOT)), 'sha256': sha(p.read_bytes())} for p in sorted((ROOT / EVIDENCE).iterdir()) if p.is_file()]
manifest = {
    'managed_source_parent': PARENT,
    'repaired_managed_revision': None,
    'note': 'Final backend-resolved build revision belongs in a separate delivery record; parent is not repaired revision.',
    'public_main': PUBLIC,
    'parent_android_tree': parent_tree,
    'parent_public_parity': {'files': 1224, 'changed': 0, 'added': 0, 'removed': 0, 'modes_identical': True, 'sorted_manifest_sha256': '46e100ed19a7639a0e1bcb6307817c75f9df5f33e771e759b23c6cd6127e21b8'},
    'current_android_tree': current_tree,
    'source_label': 'src_' + current_tree[:17],
    'scope': 'Android retained evidence recovery and local safe diagnostics; bounded outer Chemical Store reconciliation admission; test-only Play delivery',
    'protected': {'ios_tracked_unchanged': True, 'ios_configuration': config, 'quadrant_unchanged_inputs': protected_unchanged, 'historical_manifests': historical},
    'validation': json.loads((ROOT / EVIDENCE / 'validation-results.json').read_bytes()),
    'local_release_inspection': json.loads((ROOT / EVIDENCE / 'local-release-inspection.json').read_bytes()),
    'files': files,
    'all_android_files': full,
    'evidence': evidence,
    'original_device_acceptance': False,
    'public_release': False,
}
assert not OUT.exists(), 'Do not overwrite this checkpoint; retain new provenance separately'
OUT.write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({'source_inputs': len(files), 'evidence_files': len(evidence), 'android_files': len(full), 'android_tree': current_tree, 'source_label': manifest['source_label'], 'manifest_sha256': sha(OUT.read_bytes())}, indent=2))

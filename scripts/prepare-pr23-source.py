#!/usr/bin/env python3
"""Apply only reviewed PR23 paths whose workspace bytes match its reconciled base.
Archives and public compare response are downloaded under /tmp beforehand.
No Git mutation, archive-wide extraction or backend operations.
"""
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
comparison = json.loads(Path('/tmp/vinetrack-pr23-compare.json').read_text())
assert comparison['base_commit']['sha'] == '58dc23dffc7340a56ebebc36868a6eeda40c4081'
with tarfile.open('/tmp/vinetrack-pr23-base.tar.gz') as base, tarfile.open('/tmp/vinetrack-pr23.tar.gz') as head:
    base_prefix, head_prefix = base.getnames()[0] + '/', head.getnames()[0] + '/'
    changes = []
    for item in comparison['files']:
        name = item['filename']
        assert name.startswith(('ios/', 'android-vinetrack/', 'scripts/', 'docs/sync/')) and '..' not in Path(name).parts
        target = ROOT / name
        if item['status'] == 'added':
            assert not target.exists(), f'Newer local file exists: {name}'
        else:
            assert item['status'] == 'modified'
            assert target.read_bytes() == base.extractfile(base_prefix + name).read(), f'Local divergence: {name}'
        changes.append((target, head.extractfile(head_prefix + name).read()))
    for target, content in changes:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        print(target.relative_to(ROOT))
print(f'Applied {len(changes)} reviewed paths; all existing before-images matched reconciled base.')

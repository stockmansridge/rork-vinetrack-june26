#!/usr/bin/env python3
"""Apply reviewed PR26 delta once; retain newer AppViewModel and all unrelated source.
Requires exact review artifacts in /tmp; no Git or backend mutations.
"""
import hashlib
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
meta = json.loads(Path('/tmp/vinetrack-quadrant-pr.json').read_text())
assert meta['head']['sha'] == 'e681f2796b22bd9d94bdd936a8fd9ea388584191'
assert meta['base']['sha'] == '50438333921355136fc8d81a375affc8a3334da0'
files = json.loads(Path('/tmp/vinetrack-quadrant-files.json').read_text())
assert len(files) == 18
special = 'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt'
with tarfile.open('/tmp/vinetrack-quadrant-base.tar.gz') as base, tarfile.open('/tmp/vinetrack-quadrant-head.tar.gz') as head:
    bp, hp = base.getnames()[0] + '/', head.getnames()[0] + '/'
    changes = []
    for item in files:
        name = item['filename']
        assert name.startswith(('ios/', 'android-vinetrack/', 'docs/', 'scripts/', 'sql/')) and '..' not in Path(name).parts
        target = ROOT / name
        after = head.extractfile(hp + name).read()
        if item['status'] == 'added':
            assert not target.exists(), f'Existing addition: {name}'
        else:
            assert item['status'] == 'modified'
            before = base.extractfile(bp + name).read()
            current = target.read_bytes()
            if name == special:
                # The feature changes this entry point only. Derive and assert the
                # exact insertion; never replace this newer file with branch bytes.
                marker = b'    fun saveYieldSession(session: YieldEstimationSession, onResult: (Boolean) -> Unit = {}) {\n'
                assert before.count(marker) == after.count(marker) == current.count(marker) == 1
                bpre, bpost = before.split(marker)
                apre, apost = after.split(marker)
                assert apre == bpre and apost.endswith(bpost)
                addition = apost[:-len(bpost)]
                assert b'previousIsQuadrant' in addition and b'onResult(false)' in addition
                assert b'previousIsQuadrant' not in current
                after = current.replace(marker, marker + addition, 1)
            else:
                assert current == before, f'Newer local divergence: {name}'
        changes.append((target, after))
    for target, data in changes:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        print(hashlib.sha256(data).hexdigest(), target.relative_to(ROOT))
print('Applied 17 exact protected paths and one insertion into newer AppViewModel; no backend writes.')

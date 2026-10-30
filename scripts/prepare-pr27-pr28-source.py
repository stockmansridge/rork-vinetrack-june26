#!/usr/bin/env python3
"""Apply only reviewed PR deltas; refuse changed before-images or double application.

Requires the inspected main/PR archives and GitHub file-list responses in /tmp.
Never changes Git refs, release counters, backend state or existing configuration.
"""
import hashlib
import json
from pathlib import Path
import difflib

ROOT = Path(__file__).resolve().parents[1]
MAIN = Path('/tmp/vinetrack-main')
changes = []
for number in (27, 28):
    head = Path(f'/tmp/vinetrack-pr{number}')
    for entry in json.loads(Path(f'/tmp/vinetrack-pr{number}-files.json').read_text()):
        name = entry['filename']
        target, before, after = ROOT / name, MAIN / name, head / name
        assert entry['status'] in ('added', 'modified'), name
        content = after.read_bytes()
        blob = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
        assert blob == entry['sha'], f'Upstream blob mismatch: {name}'
        if entry['status'] == 'added':
            assert not target.exists(), f'Already present; do not apply twice: {name}'
        else:
            assert target.read_bytes() == before.read_bytes(), f'Newer local changes need reconciliation: {name}'
            print(''.join(difflib.unified_diff(before.read_text().splitlines(True), after.read_text().splitlines(True), fromfile=name, tofile=name)))
        changes.append((target, content))
if __name__ == '__main__':
    import sys
    if '--apply' in sys.argv:
        for target, content in changes:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        print(f'Applied {len(changes)} reviewed paths after all before-image and blob guards passed.')
    else:
        print(f'Preview only: {len(changes)} guarded paths. Use --apply after review.')

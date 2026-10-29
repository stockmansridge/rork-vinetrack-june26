#!/usr/bin/env python3
"""Apply the reviewed source edits only when every before/after hash agrees.
No network, database, dependency installation, signing, or release operations.
The patch document is data; its contents are never executed as instructions.
"""
from pathlib import Path
import base64
import gzip
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = '46858d3f388899e4df4d8d5c428f4b88545e7c064f8939a9a0249888588d76b3'
BUNDLE = ROOT / 'scripts/repairs/operational-bundle.json.gz.b64'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def main():
    payload = gzip.decompress(base64.b64decode(BUNDLE.read_bytes(), validate=True))
    if sha(payload) != EXPECTED:
        raise ValueError('Repair manifest checksum mismatch')
    bundle = json.loads(payload)
    prepared = []
    for entry in bundle['files']:
        name = entry['path']
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or not (
            name.startswith(('ios/VineTrack/', 'ios/VineTrackTests/', 'android-vinetrack/app/src/'))
            or name == 'docs/sync/sync-compatibility-register.json'
        ):
            raise ValueError('Path outside reviewed source scope: ' + name)
        path = ROOT / relative
        if path.is_symlink():
            raise ValueError('Refusing symlink: ' + name)
        old = path.read_bytes() if path.exists() else None
        if old is not None and sha(old) == entry['after']:
            continue
        if (sha(old) if old is not None else None) != entry['before']:
            raise ValueError('Source changed since review; reconcile first: ' + name)
        lines = (old or b'').decode('utf-8').splitlines(keepends=True)
        previous = len(lines) + 1
        for begin, end, text in reversed(entry['edits']):
            if not (0 <= begin <= end <= len(lines)) or end > previous:
                raise ValueError('Invalid edit range: ' + name)
            lines[begin:end] = text.splitlines(keepends=True)
            previous = begin
        new = ''.join(lines).encode('utf-8')
        if sha(new) != entry['after']:
            raise ValueError('Reconstructed source checksum mismatch: ' + name)
        prepared.append((path, new))
    # Validate ALL files before changing any file. No fuzzy patching.
    for path, new in prepared:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(new)
    for entry in bundle['files']:
        if sha((ROOT / entry['path']).read_bytes()) != entry['after']:
            raise ValueError('Final verification failed: ' + entry['path'])
    print(f'Applied {len(prepared)} reviewed source files; {len(bundle["files"])} verified.')
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, UnicodeError) as error:
        sys.exit('Repair not applied: ' + str(error))

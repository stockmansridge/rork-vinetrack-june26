#!/usr/bin/env python3
"""Apply the second, checksum-verified correction to the existing repair branch.
Every before image is from 6416e00; all prior source changes are already committed.
No fuzzy patching, remote writes, database calls, or release operations occur here.
"""
from pathlib import Path
import base64
import gzip
import hashlib
import json
import sys
from trip_summary_compile import PATH as SUMMARY_PATH, AFTER as SUMMARY_AFTER, apply as apply_summary

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = 'd4ef9b46bf712d98c5c91eecace9d9f1f167cb4fc53da66248b4c23bac475270'
BUNDLE = ROOT / 'scripts/repairs/operational-followup.json.gz.b64'

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
        if relative.is_absolute() or '..' in relative.parts or not name.startswith((
            'ios/VineTrack/', 'ios/VineTrackTests/', 'ios/VineTrackUITests/', 'android-vinetrack/app/src/'
        )):
            raise ValueError('Path outside reviewed source scope: ' + name)
        path = ROOT / relative
        if path.is_symlink():
            raise ValueError('Refusing symlink: ' + name)
        old = path.read_bytes() if path.exists() else None
        if old is not None and (sha(old) == entry['after'] or
            (name == SUMMARY_PATH and sha(old) == SUMMARY_AFTER)):
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
    for path, new in prepared:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(new)
    for entry in bundle['files']:
        current = sha((ROOT / entry['path']).read_bytes())
        if current != entry['after'] and not (entry['path'] == SUMMARY_PATH and current == SUMMARY_AFTER):
            raise ValueError('Final verification failed: ' + entry['path'])
    apply_summary(ROOT)
    print(f'Applied {len(prepared)} reviewed files; {len(bundle["files"])} verified.')
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, UnicodeError) as error:
        sys.exit('Repair not applied: ' + str(error))

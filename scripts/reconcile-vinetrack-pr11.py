#!/usr/bin/env python3
"""Reconcile the reviewed PR11 unified diff without a checkout or Git mutation.

Usage: python3 scripts/reconcile-vinetrack-pr11.py /tmp/vinetrack-pr11.diff [--apply]
Exact hunk context must occur once. Validate every file before changing any file.
The source diff must be fetched from the verified PR head before use.
"""
import argparse
import hashlib
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('patch', type=Path)
parser.add_argument('--apply', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
patch = args.patch.read_text()
updates = []
for section in patch.split('diff --git ')[1:]:
    lines = section.splitlines(keepends=True)
    match = re.fullmatch(r'a/(\S+) b/(\S+)\n', lines[0])
    if not match or match[1] != match[2]:
        raise SystemExit('Renames or malformed paths require separate review')
    name = match[1]
    if not name.startswith(('ios/VineTrack/', 'ios/VineTrackTests/', 'ios/VineTrackUITests/', 'android-vinetrack/app/src/')):
        raise SystemExit(f'Outside native source scope: {name}')
    file = root / name
    original = file.read_text() if file.exists() else ''
    proposed = original
    hunks = re.split(r'^@@[^\n]*@@[^\n]*\n', ''.join(lines[1:]), flags=re.M)[1:]
    for hunk in hunks:
        before, after = [], []
        for line in hunk.splitlines(keepends=True):
            if line.startswith(' '):
                before.append(line[1:]); after.append(line[1:])
            elif line.startswith('-'):
                before.append(line[1:])
            elif line.startswith('+'):
                after.append(line[1:])
            elif line.startswith('\\'):
                raise SystemExit(f'Non-newline hunk requires review: {name}')
            else:
                raise SystemExit(f'Unexpected hunk content: {name}')
        old, new = ''.join(before), ''.join(after)
        if old:
            if proposed.count(old) != 1:
                raise SystemExit(f'Overlapping or ambiguous hunk: {name}')
            proposed = proposed.replace(old, new, 1)
        elif not proposed:
            proposed = new
        else:
            raise SystemExit(f'Unexpected creation hunk: {name}')
    updates.append((file, original, proposed))
for file, original, proposed in updates:
    print(file.relative_to(root), hashlib.sha256(original.encode()).hexdigest(), '->', hashlib.sha256(proposed.encode()).hexdigest())
if args.apply:
    for file, original, proposed in updates:
        if (file.read_text() if file.exists() else '') != original:
            raise SystemExit('Source changed during validation; no further writes')
        file.write_text(proposed)
    print(f'Applied {len(updates)} reviewed file deltas; no checkout, staging, commit or push.')
else:
    print(f'Validated {len(updates)} file deltas; source untouched.')

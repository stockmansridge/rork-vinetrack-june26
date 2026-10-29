#!/usr/bin/env python3
"""Apply only reviewed, non-overlapping PR15 hunks with exact unique context.
Usage: python3 scripts/reconcile-vinetrack-pr15.py /tmp/vinetrack-pr15.diff [--apply]
UI and tracking conflicts are reconciled separately; no checkout or Git writes.
"""
import argparse
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('patch', type=Path)
parser.add_argument('--apply', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
allowed = {
    'ios/VineTrack/Backend/Subscription/PaywallView.swift',
    'ios/VineTrack/Backend/Sync/TripOccurrenceJournal.swift',
    'ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift',
    'ios/VineTrackTests/SprayOccurrenceRecoveryHotfixTests.swift',
    'ios/VineTrackTests/TripOccurrenceJournalTests.swift',
}
updates = []
for section in args.patch.read_text().split('diff --git ')[1:]:
    lines = section.splitlines(keepends=True)
    match = re.fullmatch(r'a/(\S+) b/(\S+)\n', lines[0])
    if not match or match[1] != match[2]:
        raise SystemExit('Malformed path or rename')
    name = match[1]
    if name not in allowed:
        print('Separate reconciliation:', name)
        continue
    file = root / name
    original = file.read_text()
    proposed = original
    for hunk in re.split(r'^@@[^\n]*@@[^\n]*\n', ''.join(lines[1:]), flags=re.M)[1:]:
        before, after = [], []
        for line in hunk.splitlines(keepends=True):
            if line.startswith(' '):
                before.append(line[1:]); after.append(line[1:])
            elif line.startswith('-'):
                before.append(line[1:])
            elif line.startswith('+'):
                after.append(line[1:])
            else:
                raise SystemExit('Unexpected hunk content: ' + name)
        old, new = ''.join(before), ''.join(after)
        if not old or proposed.count(old) != 1:
            raise SystemExit('Non-unique context: ' + name)
        proposed = proposed.replace(old, new, 1)
    updates.append((file, original, proposed))
if {str(file.relative_to(root)) for file, _, _ in updates} != allowed:
    raise SystemExit('Expected file missing')
for file, original, proposed in updates:
    if file.read_text() != original:
        raise SystemExit('Source changed during validation')
    print('Validated:', file.relative_to(root))
if args.apply:
    for file, _, proposed in updates:
        file.write_text(proposed)
    print('Applied five reviewed file deltas; no Git mutation.')

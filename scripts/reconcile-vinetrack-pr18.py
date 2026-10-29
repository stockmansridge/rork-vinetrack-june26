#!/usr/bin/env python3
"""Reconcile the seven reviewed PR18 deltas by unique exact context; no Git writes."""
import argparse
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('patch', type=Path)
parser.add_argument('--apply', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
allowed = {
    'ios/VineTrack/App/SprayProgram/SprayCompletionResolver.swift',
    'ios/VineTrack/Backend/Repositories/SupabaseSprayRecordSyncRepository.swift',
    'ios/VineTrack/LegacyImported/Models/SprayRecord.swift',
    'ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift',
    'ios/VineTrack/LegacyImported/Services/TripTrackingService.swift',
    'ios/VineTrack/LegacyImported/Views/Trips/TripDetailView.swift',
    'ios/VineTrackTests/SprayOccurrenceRecoveryHotfixTests.swift',
}
updates = []
for section in args.patch.read_text().split('diff --git ')[1:]:
    lines = section.splitlines(keepends=True)
    match = re.fullmatch(r'a/(\S+) b/(\S+)\n', lines[0])
    if not match or match[1] != match[2] or match[1] not in allowed:
        raise SystemExit('Unexpected path')
    file = root / match[1]
    original = file.read_text()
    proposed = original
    for hunk in re.split(r'^@@[^\n]*@@[^\n]*\n', ''.join(lines[1:]), flags=re.M)[1:]:
        before, after = [], []
        for line in hunk.splitlines(keepends=True):
            if line.startswith(' '):
                before.append(line[1:]); after.append(line[1:])
            elif line.startswith('-'): before.append(line[1:])
            elif line.startswith('+'): after.append(line[1:])
            else: raise SystemExit('Unexpected hunk')
        old, new = ''.join(before), ''.join(after)
        if not old or proposed.count(old) != 1:
            raise SystemExit('Non-unique context: ' + match[1])
        proposed = proposed.replace(old, new, 1)
    updates.append((file, original, proposed))
if {str(f.relative_to(root)) for f, _, _ in updates} != allowed:
    raise SystemExit('Expected file missing')
for file, original, _ in updates:
    if file.read_text() != original: raise SystemExit('Source changed')
    print('Validated:', file.relative_to(root))
if args.apply:
    for file, _, proposed in updates: file.write_text(proposed)
    print('Applied seven reviewed deltas atop current source; no Git mutation.')

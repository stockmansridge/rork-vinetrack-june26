#!/usr/bin/env python3
"""Presentation-only compiler repair for the exact reviewed Trip Details source.
No sync, data, start checks, text, or row ordering are changed.
"""
from pathlib import Path
import hashlib

PATH = 'ios/VineTrack/LegacyImported/Views/Trips/TripDetailView.swift'
BEFORE = '48a95e9026587a7e22764c0aa8cf9e0b5da50aba32cbc01c35a5e78a995679b4'
AFTER = '95aa1d8d69c77a0d5dee8089176a398ae72d78f42c64e0fd61f2d33b996276a2'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def apply(root: Path):
    path = root / PATH
    if path.is_symlink():
        raise ValueError('Refusing symlink')
    original = path.read_bytes()
    if digest(original) == AFTER:
        return
    if digest(original) != BEFORE:
        raise ValueError('Trip Details changed since review; reconcile first')
    old = original.decode('utf-8')
    start = old.index('            Section("Trip Summary") {\n')
    end = old.index('\n            if let record = sprayRecord {', start)
    section = old[start:end]
    if not section.endswith('            }\n'):
        raise ValueError('Unexpected Trip summary shape')
    inner = section[len('            Section("Trip Summary") {\n'):-len('            }\n')]
    points = [0, inner.index('                if !trip.paddockName.isEmpty {'),
        inner.index('                if !trip.rowSequence.isEmpty {'),
        inner.index('                if pinsForTrip.count > 0 {'), len(inner)]
    names = ['tripSummaryIdentityRows', 'tripSummaryScopeRows',
        'tripSummaryCoverageRows', 'tripSummaryPinRows']
    helpers = '    // Type-check summary branches separately; presentation and all start gates are unchanged.\n'
    helpers += '    private var tripSummarySection: some View {\n        Section("Trip Summary") {\n'
    helpers += ''.join('            ' + name + '\n' for name in names)
    helpers += '        }\n    }\n\n'
    for i, name in enumerate(names):
        body = ''.join(line[8:] if line.startswith('        ') else line
            for line in inner[points[i]:points[i+1]].splitlines(keepends=True))
        helpers += '    @ViewBuilder\n    private var ' + name + ': some View {\n' + body + '    }\n\n'
    anchor = '    /// Recover exact on-device WAL first.'
    if old.count(anchor) != 1:
        raise ValueError('Trip Details recovery anchor changed')
    new = (old[:start] + '            tripSummarySection\n' + old[end:]).replace(anchor, helpers + anchor).encode('utf-8')
    if digest(new) != AFTER:
        raise ValueError('Compiler repair differs from reviewed source')
    path.write_bytes(new)

if __name__ == '__main__':
    apply(Path(__file__).resolve().parents[2])

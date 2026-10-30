#!/usr/bin/env python3
"""Presentation-only compiler repair for the exact reviewed Trip Details source.
No sync, data, start checks, text, or row ordering are changed.
"""
from pathlib import Path
import hashlib

PATH = 'ios/VineTrack/LegacyImported/Views/Trips/TripDetailView.swift'
BEFORE = '48a95e9026587a7e22764c0aa8cf9e0b5da50aba32cbc01c35a5e78a995679b4'
INTERMEDIATE = '95aa1d8d69c77a0d5dee8089176a398ae72d78f42c64e0fd61f2d33b996276a2'
AFTER = '33408770bdc5ad8ffa6d06b89f74a640a1e9764bf4a7db06fa9cb86b09ac0ecb'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def decompose(old: str) -> str:
    start = old.index('    var body: some View {\n')
    end = old.index('    // Type-check summary branches separately;', start)
    list_start = old.index('        List {\n', start)
    list_end = old.index('        }\n        .navigationTitle("Trip")', list_start)
    inner = old[list_start + len('        List {\n'):list_end]
    markers = [
        ('tripHeaderSection', '            Section {\n'),
        ('tripRecoverySection', '            if mayRecoverSavedOccurrenceSpray {\n'),
        ('tripSummarySection', '            tripSummarySection\n'),
        ('tripSprayRecordSection', '            if let record = sprayRecord {\n'),
        ('tripRowsSection', '            if !rowCompletionResults.isEmpty {\n'),
        ('tripTrailSection', '            if trip.pathPoints.count > 1 {\n'),
        ('tripPathSummarySection', '            if !trip.rowSequence.isEmpty {\n'),
        ('tripSeedingSection', '            if let details = trip.seedingDetails, details.hasAnyValue {\n'),
        ('tripCostSection', '            if accessControl.canViewCosting && !mayRecoverSavedOccurrenceSpray {\n'),
        ('tripCompletionSection', '            if let notes = trip.completionNotes?\n'),
        ('tripPinsSection', '            if !pinsForTrip.isEmpty {\n'),
    ]
    positions = []
    at = 0
    for name, mark in markers:
        at = inner.index(mark, at)
        positions.append(at)
        at += len(mark)
    positions.append(len(inner))
    helpers = ''
    for i, (name, _) in enumerate(markers):
        if name == 'tripSummarySection':
            if inner[positions[i]:positions[i + 1]].strip() != 'tripSummarySection':
                raise ValueError('Unexpected summary section')
            continue
        if ('private var ' + name + ':') in old:
            raise ValueError('Helper already exists: ' + name)
        text = inner[positions[i]:positions[i + 1]].rstrip() + '\n'
        text = ''.join(line[4:] if line.startswith('    ') else line for line in text.splitlines(keepends=True))
        helpers += '    @ViewBuilder\n    private var ' + name + ': some View {\n' + text + '    }\n\n'
    first_sheet = old.index('        .sheet(isPresented: $showSummary) {', list_end)
    editing = old.index('        .sheet(item: $pendingRateReviewTrip,', first_sheet)
    alerts = old.index('        .alert("Spray Report Unavailable",', editing)
    lifecycle = old.index('        .task(id:', alerts)
    nav = old[list_end + len('        }\n'):first_sheet]
    parts = '    private var tripListContent: some View {\n        List {\n'
    parts += ''.join('            ' + name + '\n' for name, _ in markers) + '        }\n' + nav + '    }\n\n'
    parts += '    private var tripDetailSheets: some View {\n        tripListContent\n' + old[first_sheet:editing] + '    }\n\n'
    parts += '    private var tripDetailEditingSheets: some View {\n        tripDetailSheets\n' + old[editing:alerts] + '    }\n\n'
    parts += '    private var tripDetailAlerts: some View {\n        tripDetailEditingSheets\n' + old[alerts:lifecycle] + '    }\n\n'
    body = '    var body: some View {\n        tripDetailAlerts\n' + old[lifecycle:end]
    return old[:start] + body + parts + helpers + old[end:]


def apply(root: Path):
    path = root / PATH
    if path.is_symlink():
        raise ValueError('Refusing symlink')
    original = path.read_bytes()
    if digest(original) == AFTER:
        return
    if digest(original) == INTERMEDIATE:
        new = decompose(original.decode('utf-8')).encode('utf-8')
        if digest(new) != AFTER:
            raise ValueError('Full Trip Details decomposition differs from reviewed source')
        path.write_bytes(new)
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
    new = decompose(new.decode('utf-8')).encode('utf-8')
    if digest(new) != AFTER:
        raise ValueError('Compiler repair differs from reviewed source')
    path.write_bytes(new)

if __name__ == '__main__':
    apply(Path(__file__).resolve().parents[2])

#!/usr/bin/env python3
"""Retain bounded synthetic instrumentation evidence; remove only exported image packets."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/reviews/evidence/android-recovery-20261031'
OUT.mkdir(parents=True, exist_ok=True)
NAMES = [
    'vinetrack-editor-ab-initial', 'vinetrack-editor-ab-clock',
    'vinetrack-recovery-load-busy', 'vinetrack-editor-ab-reflection',
    'vinetrack-editor-event-driven', 'vinetrack-domain-admission-focused',
    'vinetrack-five-journeys-sheet-gates', 'vinetrack-drag-and-pin-diagnostics',
    'vinetrack-sheet-current-offset', 'vinetrack-sheet-unsettled-virtual-clock',
]
for name in NAMES:
    source = Path('/tmp') / f'{name}.log'
    text = source.read_text()
    assert 'synthetic-password' not in text, 'Credential unexpectedly logged'
    # PNG/WEBP packets are extracted separately; keep every assertion/stack/status unchanged.
    text = re.sub(r'^RECOVERY_SCREEN_.+_\d+=[A-Za-z0-9+/=]+$', '[native image packet extracted separately]', text, flags=re.M)
    (OUT / source.name).write_text(text)
    print(f'{source.name}: {len(text.encode())} bytes')

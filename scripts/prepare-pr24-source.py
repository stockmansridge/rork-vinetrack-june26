#!/usr/bin/env python3
"""Apply reviewed PR24 paths only after verifying the reconciled production before-image."""
import sys
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
HEAD = '9f9f5ada0c7620c9ed4b85292e753190ca583e3c'
BASE = '13f412660355939343d716fe46aa4354c6068d7f'
PREFIX = 'https://raw.githubusercontent.com/stockmansridge/rork-vinetrack-june26/'
paths = ['docs/reviews/ios-build189-chemical-stack-overflow-20261030.md',
         'ios/VineTrack/App/SprayCalculatorView.swift', 'scripts/tests/test_spray_product_recursion.py']
test_only = '--test-only' in sys.argv
changes = []
for name in paths:
    if test_only and not name.startswith('scripts/tests/'):
        continue
    path = ROOT / name
    if name.endswith('SprayCalculatorView.swift'):
        assert path.read_bytes() == urlopen(PREFIX + BASE + '/' + name).read(), 'Preserve newer production work; reconcile manually'
    content = urlopen(PREFIX + HEAD + '/' + name).read()
    if not name.endswith('SprayCalculatorView.swift') and path.exists():
        assert path.read_bytes() == content, f'Newer local file exists: {name}'
    changes.append((path, content))
for path, content in changes:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    print(path.relative_to(ROOT))

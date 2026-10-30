#!/usr/bin/env python3
"""Record bounded PR24 source and sanitized Apple crash evidence; no store writes."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
PARENT = 'fe60fd5902c3f341c4a73e2dc5512092ae8d4e13'
HEAD = '9f9f5ada0c7620c9ed4b85292e753190ca583e3c'
BASE = '13f412660355939343d716fe46aa4354c6068d7f'
UUID = '427604DE-2A8C-34E4-8744-979847C2C1E1'

def sha(data):
    return hashlib.sha256(data).hexdigest()

crashes = []
for key, base in [('first', 0x100350000), ('second', 0x102994000)]:
    raw = Path(f'/tmp/vinetrack-build189-crash-{key}.json').read_bytes()
    log = json.loads(raw)['data']['attributes']['logText']
    assert UUID.replace('-', '').lower() in log.lower()
    assert '3.1.9 (189)' in log and 'Thread stack size exceeded' in log
    frames = {}
    for offset in [11291424, 11297652]:
        address = format(base + offset, 'x')
        matches = [line for line in log.splitlines() if re.search(r'\bVineTrack\s+0x0*' + address + r'\b', line)]
        assert len(matches) > 1, f'Repeated offset not confirmed: {key}/{offset}'
        frames[str(offset)] = {'address': hex(base + offset), 'occurrences': len(matches),
                              'apple_returned_symbol': re.split(r'0x[0-9a-fA-F]+\s+', matches[0], maxsplit=1)[1]}
    crashes.append({'report': key, 'raw_response_sha256': sha(raw),
                    'crash_log_sha256': sha(log.encode()), 'binary_uuid': UUID,
                    'image_base': hex(base), 'stack_overflow': True, 'frames': frames})
evidence = ROOT / 'docs/reviews/pr24-build189-crash-evidence-20261030.json'
evidence.write_text(json.dumps({'source': 'asc testflight crashes log, read-only, 2026-10-30',
    'build_id': '6149aea9-778f-42c5-81e2-78a03d07749b',
    'symbolication': 'Apple API returned these labels. Matching archive/dSYM unavailable; no independent atos/dwarfdump verification performed. Raw reports are not committed.',
    'apple_dsym_files': [], 'reports': crashes}, indent=2) + '\n')

upstream_paths = ['docs/reviews/ios-build189-chemical-stack-overflow-20261030.md',
                  'ios/VineTrack/App/SprayCalculatorView.swift', 'scripts/tests/test_spray_product_recursion.py']
paths = upstream_paths + ['ios/VineTrack/App/Keyboard/SprayCalculatorKeyboardValidationView.swift',
    'ios/VineTrackUITests/MobileSprayUXParityUITests.swift',
    'ios/VineTrackTests/SprayProductRecursionExpressionTests.swift',
    'scripts/prepare-pr24-source.py', 'scripts/generate-pr24-native-expression-test.py',
    'scripts/snapshot-pr24-chemical-recursion-source.py', str(evidence.relative_to(ROOT))]
files = []
for name in sorted(paths):
    data = (ROOT / name).read_bytes()
    before = subprocess.run(['git', 'show', f'{PARENT}:{name}'], cwd=ROOT, capture_output=True)
    upstream = urlopen(f'https://raw.githubusercontent.com/stockmansridge/rork-vinetrack-june26/{HEAD}/{name}').read() if name in upstream_paths else None
    if upstream is not None:
        assert data == upstream, f'Unreviewed upstream divergence: {name}'
    files.append({'path': name, 'sha256': sha(data),
                  'parent_sha256': sha(before.stdout) if before.returncode == 0 else None,
                  'reviewed_pr_head_sha256': sha(upstream) if upstream is not None else None})
# Verify every historical PR23 inventory input is unchanged, including its tooling.
prior = json.loads((ROOT / 'docs/reviews/pr23-trip-yield-source-manifest-20261030.json').read_text())
for item in prior['files']:
    assert sha((ROOT / item['path']).read_bytes()) == item['sha256'], f'PR23 preservation failed: {item["path"]}'
manifest = {'managed_source_parent': PARENT, 'integration_commit': None, 'reviewed_pr24_head': HEAD,
    'reviewed_pr24_base': BASE, 'production_view_matches_reviewed_head': True,
    'pr23_manifest_all_26_inputs_unchanged': True,
    'validation': {'python_before': {'passed': 1, 'failed': 2, 'skipped': 1},
        'python_after': {'passed': 3, 'failed': 0, 'skipped': 1, 'reason': 'No local Swift compiler'},
        'mandatory_native_ui': {'passed': 4, 'seconds': 338},
        'additional_native_ui': {'passed': 3, 'seconds': 287},
        'focused_native_calculator': {'passed': 144, 'seconds': 25, 'includes_exact_expression_111_scenarios': True},
        'ios_normal_simulator_build': 'PASS', 'device_release_and_original_phone': 'UNVERIFIED',
        'independent_matching_dsym_symbolication': 'BLOCKED: no dSYM returned by Apple'},
    'release': {'version': '3.1.9', 'verified_next_build_number': '190',
        'number_reserved_or_applied': False, 'candidate_prepared': False, 'uploaded': False},
    'files': files}
out = ROOT / 'docs/reviews/pr24-chemical-recursion-source-manifest-20261030.json'
out.write_text(json.dumps(manifest, indent=2) + '\n')
print(f'{len(files)} inputs; manifest_sha256={sha(out.read_bytes())}')
print(evidence.read_text())

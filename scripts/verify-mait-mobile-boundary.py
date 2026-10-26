#!/usr/bin/env python3
"""Source-only MAIT boundary audit; never contacts an upstream or a backend."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
production = [ROOT / 'ios/VineTrack', ROOT / 'android-vinetrack/app/src/main/java']
problems = []
for directory in production:
    for path in directory.rglob('*'):
        if path.suffix not in {'.swift', '.kt'}:
            continue
        text = path.read_text()
        # These names would introduce mobile MAIT configuration/credential state.
        if re.search(r'intelliweb\.mait\.com\.au|mait(?:Username|Password|Network_?Id|Credentials|Mappings?)\b', text, re.I):
            problems.append(str(path.relative_to(ROOT)))

changed = subprocess.check_output(['git', 'diff', 'HEAD', '--name-only'], cwd=ROOT, text=True).splitlines()
assert not any(p.endswith('.sql') or p.startswith(('supabase/', 'backend/', 'functions/')) for p in changed), 'Backend/schema change in mobile-only scope'
addition_diff = subprocess.check_output(['git', 'diff', 'HEAD', '--unified=0', '--',
                                         'ios/VineTrack', 'android-vinetrack/app/src/main/java'], cwd=ROOT, text=True)
additions = '\n'.join(line[1:] for line in addition_diff.splitlines() if line.startswith('+') and not line.startswith('+++'))
assert not re.search(r'sync_usage|service_role|SERVICE_ROLE|intelliweb\.mait\.com\.au', additions), 'Prohibited new transport/service-role operation'
assert not problems, 'Direct MAIT endpoint or mobile MAIT credential/configuration state: ' + ', '.join(problems)
print('PASS: no direct MAIT endpoint/configuration credentials, new service-role/sync_usage operation, or backend/schema edit')
print('Request-body/JWT/provider/no-fallback assertions are in the native suites; this audit is source-only, not live backend acceptance.')

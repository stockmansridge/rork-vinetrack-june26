#!/usr/bin/env python3
"""Hash PR31 managed source/configuration/evidence without secrets or git mutation."""
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = 'docs/reviews/evidence/pr31-20261101/validated-checkpoint.json'
EVIDENCE = 'docs/reviews/evidence/pr31-20261101/'
PROTECTED = [
    'ios/VineTrack/App/AppConfig.swift',
    'ios/VineTrack.xcodeproj/project.pbxproj',
    'android-vinetrack/app/build.gradle.kts',
    'android-vinetrack/gradle/libs.versions.toml',
    'android-vinetrack/app/src/main/AndroidManifest.xml',
]

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def entry(name):
    p = ROOT / name
    if p.is_symlink():
        raise RuntimeError(f'Unexpected symlink in checkpoint: {name}')
    data = p.read_bytes()
    return {'path': name, 'sha256': hashlib.sha256(data).hexdigest(),
            'bytes': len(data), 'mode': oct(stat.S_IMODE(p.stat().st_mode))}

def main():
    names = set(git('ls-files', '--cached', '--others', '--exclude-standard', '-z').decode().split('\0'))
    source_names = sorted(n for n in names if n.startswith(('ios/', 'android-vinetrack/', 'scripts/', 'sql/')) and (ROOT / n).is_file())
    # Managed configuration may be ignored by git; record hashes only, never values.
    config = 'android-vinetrack/app/src/main/java/com/rork/vinetrack/Config.kt'
    if not (ROOT / config).is_file():
        raise RuntimeError('Real managed Android configuration missing')
    source_names = sorted(set(source_names + [config]))
    protected = []
    for name in PROTECTED:
        current = entry(name)
        original = hashlib.sha256(git('show', f'HEAD:{name}')).hexdigest()
        if original != current['sha256']:
            raise RuntimeError(f'Protected configuration changed: {name}')
        protected.append({**current, 'identical_to_starting_head': True})
    if protected[0]['sha256'] != 'b7a7f3cdefd26ae5304d25ec293d7fa567bf62339b3ad9e35011097b9a3efa51':
        raise RuntimeError('Unexpected real iOS configuration hash')
    reports = []
    totals = [0, 0, 0, 0]
    for p in sorted((ROOT / EVIDENCE / 'jvm-final').glob('TEST-*.xml')):
        suite = ET.parse(p).getroot()
        values = [int(suite.get(k, '0')) for k in ('tests', 'failures', 'errors', 'skipped')]
        totals = [a + b for a, b in zip(totals, values)]
        reports.append({'path': str(p.relative_to(ROOT)), 'suite': suite.get('name'), 'counts': values})
    if len(reports) != 9 or totals != [93, 0, 0, 0]:
        raise RuntimeError(f'Unexpected JVM discovery/results: {len(reports)} {totals}')
    evidence_names = sorted(str(p.relative_to(ROOT)) for p in (ROOT / EVIDENCE).rglob('*') if p.is_file() and str(p.relative_to(ROOT)) != OUT)
    source = [entry(n) for n in source_names]
    manifest = {
        'date': '2026-11-01',
        'starting_managed_head_not_final_repaired_revision': git('rev-parse', 'HEAD').decode().strip(),
        'scope': 'Both native apps, tracked/nonignored scripts and SQL; real managed configuration hash included explicitly',
        'source_count': len(source), 'source': source,
        'protected_configuration': protected,
        'evidence': [entry(n) for n in evidence_names],
        'jvm_reports': reports, 'jvm_totals_tests_failures_errors_skipped': totals,
        'excluded': ['Rork conversation history', 'Ignored build outputs and caches', 'Secrets and configuration contents'],
        'limitations': ['Not a signed build or installed-binary mapping', 'Final native success raw logs unavailable; see labeled tool-result transcriptions', 'Final repaired managed/public revision not yet confirmed', 'Backend deployment and original-device acceptance remain blocked/open'],
        'delivery': {'counter_changed': False, 'signed_candidate': False, 'uploaded': False},
    }
    (ROOT / OUT).write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'manifest': OUT, 'source_count': len(source), 'evidence_count': len(evidence_names),
                      'jvm_totals': totals, 'sha256': entry(OUT)['sha256']}, indent=2))

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Preserve PR32 source/config/test evidence using hashes and read-only Git commands."""
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = 'docs/reviews/evidence/pr32-20261101/'
OUT = EVIDENCE + 'validated-checkpoint.json'
PLAN = '.rork/plans/android-live-trip-safe-automatic-complet_1791964262830.plan.md'
REVIEWS = [PLAN, 'docs/reviews/android-chemical-recovery-preflight-20261101.md',
           'docs/reviews/final-mobile-acceptance-legacy-save-recovery-2026-10-15.md']
START = '1973aa4c44b947b43c149660a8f7380a8b5aa5c1'


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def entry(name):
    p = ROOT / name
    if p.is_symlink():
        raise RuntimeError(f'Unexpected source/evidence symlink: {name}')
    data = p.read_bytes()
    return {'path': name, 'sha256': hashlib.sha256(data).hexdigest(),
            'bytes': len(data), 'mode': oct(stat.S_IMODE(p.stat().st_mode))}


def main():
    if git('rev-parse', 'HEAD').decode().strip() != START:
        raise RuntimeError('Starting managed revision changed; reconcile before rewriting the checkpoint')
    integration = json.loads((ROOT / EVIDENCE / 'integration.json').read_text())
    protected = []
    for name, expected in integration['protectedConfigurationHashes'].items():
        current = entry(name)
        protected.append({**current, 'expected_integration_sha256': expected,
                          'unchanged_from_integration': current['sha256'] == expected})
    configuration_verified = all(row['unchanged_from_integration'] for row in protected)
    for name in ['rork.json', 'ios/VineTrack.xcodeproj/project.pbxproj',
                 'android-vinetrack/gradle/libs.versions.toml',
                 'android-vinetrack/app/src/main/AndroidManifest.xml']:
        current = entry(name)
        if current['sha256'] != hashlib.sha256(git('show', f'{START}:{name}')).hexdigest():
            raise RuntimeError(f'Protected build/signing/package input changed: {name}')
        protected.append({**current, 'identical_to_starting_managed_revision': True})
    protected_changes = git('diff', START, '--name-only', '--', 'ios', 'sql', 'supabase', 'migration', 'rollback', '.github').decode().splitlines()
    if protected_changes:
        raise RuntimeError(f'Unexpected protected-tree changes: {protected_changes}')
    production_parity = []
    for change in integration['changes']:
        if '/src/main/' not in change['path']:
            continue
        current = entry(change['path'])
        if current['sha256'] != change['afterSha256']:
            raise RuntimeError(f'Production no longer matches exact PR import: {change["path"]}')
        production_parity.append({**current, 'matches_exact_import': True})
    tests = []
    totals = [0, 0, 0, 0]
    for p in sorted((ROOT / EVIDENCE / 'jvm-final').glob('TEST-*.xml')):
        suite = ET.parse(p).getroot()
        counts = [int(suite.get(k, '0')) for k in ('tests', 'failures', 'errors', 'skipped')]
        totals = [a + b for a, b in zip(totals, counts)]
        tests.append({'path': str(p.relative_to(ROOT)), 'suite': suite.get('name'), 'counts': counts})
    if len(tests) != 5 or totals != [62, 0, 0, 0]:
        raise RuntimeError(f'Unexpected actual JVM discovery/results: {len(tests)}, {totals}')
    result = json.loads((ROOT / EVIDENCE / 'validation-results.json').read_text())
    if result['native']['runs'][2]['passed'] != 255 or result['native']['runs'][3]['passed'] != 5:
        raise RuntimeError('Native tool-result transcription changed')
    for name in ['actions-run.json', 'actions-jobs.json']:
        data = json.loads((ROOT / EVIDENCE / name).read_text())
        rows = data['jobs'] if 'jobs' in data else [data]
        if not all(row['status'] == 'completed' and row['conclusion'] == 'success' for row in rows):
            raise RuntimeError('Actions final status is not successful')
    names = set(git('ls-files', '--cached', '--others', '--exclude-standard', '-z').decode().split('\0'))
    source_names = sorted(n for n in names if n.startswith(('android-vinetrack/', 'ios/', 'scripts/', 'sql/', 'supabase/')) and (ROOT / n).is_file())
    config = 'android-vinetrack/app/src/main/java/com/rork/vinetrack/Config.kt'
    source_names = sorted(set(source_names + [config, 'rork.json']))
    source = [entry(n) for n in source_names]
    fingerprint = hashlib.sha256(json.dumps(source, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    evidence_names = sorted(str(p.relative_to(ROOT)) for p in (ROOT / EVIDENCE).rglob('*')
                            if p.is_file() and str(p.relative_to(ROOT)) != OUT)
    manifest = {
        'date': '2026-11-01', 'starting_managed_revision_not_final_repaired_revision': START,
        'scope': 'Current nonignored Android, iOS, scripts, SQL/Supabase and app registration; ignored real Android configuration recorded by hash only',
        'checkpoint_status': 'source_identity_pending' if configuration_verified else 'blocked_configuration_mismatch',
        'protected_configuration_verified': configuration_verified,
        'release_gate_passed': False,
        'source_count': len(source), 'source': source,
        'source_inventory_sha256_not_managed_sourceHash': fingerprint,
        'protected_configuration': protected, 'unchanged_protected_trees': ['ios', 'sql', 'supabase', 'migration', 'rollback', '.github'],
        'production_exact_import_parity': production_parity,
        'post_import_native_fixture_improvements': [entry('android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/auth/' + name)
                                                  for name in ['ChemicalRecoveryPreflightAndroidTest.kt', 'PopulatedCleanExitActivityTest.kt']],
        'reviews': [entry(n) for n in REVIEWS], 'evidence': [entry(n) for n in evidence_names],
        'jvm_reports': tests, 'jvm_totals_tests_failures_errors_skipped': totals,
        'native_success_is_tool_result_transcription_not_raw_log': True,
        'delivery': result['delivery'],
        'limitations': ['Current ignored Config.kt differs from import-time hash; cause and validation-time equivalence unverified. No guessed restoration or exact-source certification until reconciled.' if not configuration_verified else 'Protected configuration hashes match import receipt',
                        'Not a managed snapshot/sourceHash, signed Play build or installed-device mapping',
                        'Final automatic managed/public sync not confirmed',
                        'Original handset incident OPEN; prior iOS/backend incidents remain separately OPEN',
                        'Historical cross-platform spray lifecycle/queue/export gates not newly certified'],
        'excluded': ['Rork conversation history', 'Ignored build outputs and caches', 'Secrets and configuration values'],
    }
    (ROOT / OUT).write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'manifest': OUT, 'source_count': len(source), 'evidence_count': len(evidence_names),
                      'checkpoint_status': manifest['checkpoint_status'],
                      'jvm_totals': totals, 'sha256': entry(OUT)['sha256'], 'inventory_sha256': fingerprint}, indent=2))


if __name__ == '__main__':
    main()

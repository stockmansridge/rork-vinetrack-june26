#!/usr/bin/env python3
"""Record immutable Android PR30 validation inputs without modifying Git or history."""
import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/reviews/evidence/domain-cache-recovery-20261101'

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def main():
    target = OUT / 'validated-checkpoint.json'
    assert not target.exists(), 'Preserve previous checkpoint; do not overwrite.'
    receipt = json.loads((OUT / 'integration-and-reconciliation.json').read_text())
    for change in receipt['changes']:
        assert sha((ROOT / change['path']).read_bytes()) == change['integratedSha256'], change['path']
    paths = sorted(set(git('ls-files', '--cached', '--others', '--exclude-standard', '--', 'android-vinetrack').decode().splitlines()))
    inventory = [{'path': p, 'sha256': sha((ROOT / p).read_bytes()),
                  'executable': bool((ROOT / p).stat().st_mode & 0o111)} for p in paths]
    changed = git('diff', 'HEAD', '--name-only', '--', 'android-vinetrack').decode().splitlines()
    assert set(changed) == {c['path'] for c in receipt['changes'] if c['path'].startswith('android-vinetrack/')} | {
        'android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/SprayStartProductionAndroidTest.kt'}
    assert not git('diff', 'HEAD', '--name-only', '--', 'ios', 'sql', 'supabase').strip()
    config_path = 'ios/VineTrack/App/AppConfig.swift'
    config = (ROOT / config_path).read_bytes()
    assert config == git('show', 'HEAD:' + config_path)
    suites = []
    for p in sorted(OUT.glob('TEST-*.xml')):
        suite = ET.parse(p).getroot()
        suites.append({key: suite.attrib[key] for key in ('name', 'tests', 'failures', 'errors', 'skipped')})
    assert len(suites) == 8 and sum(int(s['tests']) for s in suites) == 77
    assert all(int(s[k]) == 0 for s in suites for k in ('failures', 'errors', 'skipped'))
    evidence = [{'path': p.relative_to(ROOT).as_posix(), 'sha256': sha(p.read_bytes())}
                for p in sorted(OUT.iterdir()) if p.is_file()]
    checkpoint = {
        'date': '2026-11-01', 'startingManagedRevision': git('rev-parse', 'HEAD').decode().strip(),
        'finalManagedRevision': None, 'publicSyncConfirmed': False,
        'installed1793504699SourceLinkVerified': False,
        'repair': receipt['repair'], 'androidInventory': inventory,
        'subsequentCorrection': 'SprayStartProductionAndroidTest selectors and complete synthetic bootstrap/auth/access fixture only; production replay admission unchanged.',
        'protectedIosConfig': {'path': config_path, 'sha256': sha(config), 'matchesStartingManagedHead': True,
            'historical71301HashReproduced': False},
        'jvmSuites': suites,
        'native': {'evidenceKind': 'Tool-result transcription, not raw success log',
                   'finalCombined': {'passed': 197, 'failed': 0, 'skipped': 0, 'seconds': 169},
                   'initialPr30': {'passed': 6, 'failed': 0, 'skipped': 0, 'seconds': 15},
                   'focusedActivation': {'passed': 1, 'failed': 0, 'skipped': 0, 'seconds': 21},
                   'overlappingCountsMustNotBeSummed': True},
        'normalAndroidBuild': 'runChecks PASS; two pre-existing nonblocking asset-address advisories',
        'pruningRecoveryImplemented': False, 'storeCandidatePreparedOrPublished': False,
        'originalDeviceAcceptance': 'NOT OBSERVED; incident OPEN', 'evidence': evidence,
    }
    target.write_text(json.dumps(checkpoint, indent=2) + '\n')
    print(json.dumps({'checkpoint': str(target.relative_to(ROOT)), 'sha256': sha(target.read_bytes()),
                      'androidFiles': len(inventory), 'jvmTests': 77, 'nativeTests': 197}, indent=2))

if __name__ == '__main__':
    main()

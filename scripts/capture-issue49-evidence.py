"""Capture Issue #49 validation identity without exporting configuration or customer data.
Run from the project root after validation; public archive stays outside the project.
"""
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/reviews/evidence/android-issue49-field-controls-20261102'
PUBLIC = Path('/tmp/issue49-final-public-main')
OUT.mkdir(parents=True, exist_ok=True)

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT).decode().strip()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

paths = git('ls-files', '--', 'android-vinetrack').splitlines()
manifest = [{'path': p, 'sha256': digest(ROOT / p)} for p in sorted(paths) if (ROOT / p).is_file()]
manifest_path = OUT / 'android-source-manifest.json'
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
public_sha = json.loads(Path('/tmp/issue49-final-public-main.json').read_text())['sha']
changed = [r['path'] for r in manifest if not (PUBLIC / r['path']).is_file() or digest(PUBLIC / r['path']) != r['sha256']]
public_android = {str(p.relative_to(PUBLIC)) for p in (PUBLIC / 'android-vinetrack').rglob('*') if p.is_file()}
local_android = {r['path'] for r in manifest}
(OUT / 'source-identity.json').write_text(json.dumps({
    'captured_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'managed_head': git('rev-parse', 'HEAD'),
    'branch': git('branch', '--show-current'),
    'public_main_inspected': public_sha,
    'public_archive_sha256': digest(Path('/tmp/issue49-final-public-main.tar.gz')),
    'android_source_manifest_sha256': digest(manifest_path),
    'android_file_count': len(manifest),
    'different_or_new_android_paths_vs_public': changed,
    'public_only_android_paths': sorted(public_android - local_android),
    'ios_diff_vs_managed_head': git('diff', 'HEAD', '--name-only', '--', 'ios'),
    'status': 'Validated workspace is not yet the inspected public main. Managed synchronisation/source pin and signing remain open.',
    'configuration': 'Ignored generated configuration excluded. No secrets captured; signed configuration/binary identity unverified.',
}, indent=2) + '\n')

results = []
xml_dir = ROOT / 'android-vinetrack/app/build/test-results/testDebugUnitTest'
(OUT / 'jvm-xml').mkdir(exist_ok=True)
for path in sorted(xml_dir.glob('TEST-*.xml')):
    root = ET.parse(path).getroot()
    results.append({k: root.attrib.get(k, '0') for k in ['name', 'tests', 'failures', 'errors', 'skipped', 'timestamp', 'time']})
    shutil.copy2(path, OUT / 'jvm-xml' / path.name)
(OUT / 'jvm-results.json').write_text(json.dumps({
    'selection': results,
    'total': {k: sum(int(r[k]) for r in results) for k in ['tests', 'failures', 'errors', 'skipped']},
    'method': 'Bounded host JVM selection via scripts/issue49-field-tests.init.gradle; not full unit suite or device acceptance.',
}, indent=2) + '\n')

logs = {
    '/tmp/issue49-jvm-final-validated.log': 'jvm-final.log',
    '/tmp/issue49-jvm-final.log': 'jvm-earlier-141.log',
    '/tmp/issue49-jvm3.log': 'jvm-earlier-137.log',
    '/tmp/issue49-badge-diagnostic-instrumentation.log': 'instrumentation-historical-badge-diagnostic.log',
    '/tmp/issue49-instrumentation-13pass-5fail.log': 'instrumentation-historical-13pass-5fail.log',
    '/tmp/issue49-instrumentation-2pass-3fail.log': 'instrumentation-historical-2pass-3fail.log',
    '/tmp/issue49-instrumentation-3pass-2fail.log': 'instrumentation-historical-3pass-2fail.log',
    '/tmp/issue49-instrumentation-0pass-2fail.log': 'instrumentation-historical-0pass-2fail.log',
    '/tmp/issue49-instrumentation-action-layout-diagnostic.log': 'instrumentation-historical-action-layout-diagnostic.log',
}
for source, name in logs.items():
    if Path(source).is_file():
        shutil.copy2(source, OUT / name)
print(json.dumps({'evidence': str(OUT.relative_to(ROOT)), 'source_files': len(manifest), 'public_source_differences': len(changed), 'jvm_total': sum(int(r['tests']) for r in results), 'manifest_sha256': digest(manifest_path)}, indent=2))

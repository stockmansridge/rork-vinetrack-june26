#!/usr/bin/env python3
"""Read-only Git comparisons and a scoped PR transfer patch; never updates the linked repo."""
import difflib
import hashlib
import io
import json
import pathlib
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parents[1]
linked = root / 'linked-repos/vinetrack-review'
base = '3dc0f247c092be10e2a5514754ce41a4aedf2854'
pr = '0889a6614bc77fa9ece468d5020f83fc288884ff'

def git(directory, *args):
    return subprocess.check_output(['git', *args], cwd=directory)

paths = git(root, 'diff', '--name-only', base, '--', 'ios', 'android-vinetrack',
            'scripts/inventory-upcoming-tests.init.gradle', 'scripts/run-inventory-upcoming-regressions.py').decode().splitlines()
if not paths or any(not path.startswith(('ios/', 'android-vinetrack/', 'scripts/')) for path in paths):
    raise RuntimeError('Unexpected scope')
patch = []
manifest = []
for path in paths:
    exists = git(linked, 'ls-tree', '-r', '--name-only', pr, '--', path).decode().strip() == path
    previous = git(linked, 'show', pr + ':' + path) if exists else b''
    current = (root / path).read_bytes()
    manifest.append({'path': path, 'sha256': hashlib.sha256(current).hexdigest(), 'existsInPR': exists})
    if previous != current:
        patch.append('diff --git a/' + path + ' b/' + path + '\n')
        if not exists:
            patch.append('new file mode 100644\n')
        patch.extend(difflib.unified_diff(previous.decode().splitlines(keepends=True), current.decode().splitlines(keepends=True),
                                         fromfile='a/' + path if exists else '/dev/null', tofile='b/' + path))
# Git accepts an empty context line without its optional leading space.
patch_bytes = ''.join('\n' if line == ' \n' else line for line in patch).encode()
output = root / 'docs/reviews'
patch_path = output / 'inventory-upcoming-option-b-pr2.patch'
patch_path.write_bytes(patch_bytes)
# Prove applicability against an isolated copy of the exact PR source, never against the linked workspace.
with tempfile.TemporaryDirectory(prefix='vinetrack-pr2-patch-check-') as temporary:
    existing = [item['path'] for item in manifest if item['existsInPR']]
    archive = git(linked, 'archive', '--format=tar', pr, '--', *existing)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(temporary, filter='data')
    check = subprocess.run(['git', 'apply', '--check', str(patch_path)], cwd=temporary, capture_output=True, text=True)
    if check.returncode:
        raise RuntimeError(check.stderr)

def results(folder):
    found = {}
    for path in pathlib.Path(folder).glob('TEST-*.xml'):
        suite = ET.parse(path).getroot()
        for case in suite.findall('testcase'):
            failure = case.find('failure')
            error = case.find('error')
            status = 'failed' if failure is not None else 'error' if error is not None else 'skipped' if case.find('skipped') is not None else 'passed'
            diagnostic = failure if failure is not None else error
            found[(suite.attrib['name'], case.attrib['name'])] = (status, diagnostic.attrib.get('message') if diagnostic is not None else None)
    return found

verified_baseline = 0
for entry in git(root, 'ls-tree', '-rz', base, '--', 'android-vinetrack').split(b'\0'):
    if not entry:
        continue
    metadata, name = entry.split(b'\t', 1)
    _, kind, digest = metadata.split()
    if kind != b'blob':
        continue
    content = (pathlib.Path('/tmp/vinetrack-inventory-upcoming-baseline') / name.decode()).read_bytes()
    actual = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
    if actual != digest.decode():
        raise RuntimeError('Baseline source changed during execution: ' + name.decode())
    verified_baseline += 1

current = results(root / 'android-vinetrack/app/build/test-results/testDebugUnitTest')
baseline = results('/tmp/vinetrack-inventory-upcoming-baseline/android-vinetrack/app/build/test-results/testDebugUnitTest')
common = baseline.keys() & current.keys()
changed = [key for key in common if baseline[key] != current[key]]
added = current.keys() - baseline.keys()
report = {
    'workspaceHeadAtPackaging': git(root, 'rev-parse', 'HEAD').decode().strip(), 'startingRevision': base, 'prHead': pr,
    'sourceManifest': manifest,
    'sourceFingerprintSHA256': hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
    'patch': patch_path.relative_to(root).as_posix(), 'patchSHA256': hashlib.sha256(patch_bytes).hexdigest(),
    'patchApplyCheckAgainstExactPR': 'passed',
    'androidBaselineTrackedFilesVerifiedAfterExecution': verified_baseline,
    'androidComparison': {'commonCases': len(common), 'missingCases': len(baseline.keys() - current.keys()),
        'changedCases': changed, 'addedCases': [{'suite': key[0], 'test': key[1], 'result': current[key][0]} for key in sorted(added)],
        'current': {status: sum(value[0] == status for value in current.values()) for status in ('passed', 'failed', 'error', 'skipped')},
        'baseline': {status: sum(value[0] == status for value in baseline.values()) for status in ('passed', 'failed', 'error', 'skipped')},
        'baselineMatchingFailures': [{'suite': key[0], 'test': key[1], 'message': current[key][1]} for key in sorted(common) if current[key][0] == 'failed']},
}
(output / 'inventory-upcoming-option-b-source.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({key: value for key, value in report.items() if key != 'sourceManifest'}, indent=2))
if changed or baseline.keys() - current.keys() or any(current[key][0] != 'passed' for key in added):
    raise SystemExit('Unexpected regression or missing baseline case')

#!/usr/bin/env python3
"""Repeatable, fail-closed PR33 evidence check. Does not publish or certify a release.
Run: python3 scripts/pr33-preflight.py --run-jvm
Native runners remain sequential managed operations; their per-test evidence is checked,
not inferred from aggregate tool counts. Unavailable acceptance/provenance stays blocked.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from datetime import datetime, timezone
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'docs/reviews/evidence/pr33-preflight'
MANIFEST = ROOT / 'scripts/pr33-required-tests.json'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def inventory():
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    chosen = {p for p in paths if p and (p.startswith(('android-vinetrack/', 'ios/')) or p in ('rork.json', 'scripts/recovery-writer-tests.init.gradle', 'scripts/pr33-required-tests.json'))}
    chosen.update(json.loads((EVIDENCE / 'integration.json').read_text())['protectedHashes'])
    return {p: sha(ROOT / p) for p in sorted(chosen) if (ROOT / p).is_file()}

def native_cases(path):
    result = {}; fields = {}
    for line in path.read_text().splitlines():
        match = re.match(r'INSTRUMENTATION_STATUS: (class|test)=(.*)', line)
        if match: fields[match[1]] = match[2]
        code = re.match(r'INSTRUMENTATION_STATUS_CODE: (-?\d+)', line)
        if code:
            if code[1] != '1' and all(k in fields for k in ('class', 'test')):
                result[fields['class'] + '#' + fields['test']] = 'passed' if code[1] == '0' else 'failed_or_skipped'
            fields = {}
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-jvm', action='store_true')
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    before = inventory()
    evidence = {'schema': 1, 'createdAt': datetime.now(timezone.utc).isoformat(), 'sourceFiles': before,
        'sourceInventorySha256': hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest(),
        'managedSourceHash': None, 'releaseGatePassed': False, 'requiredResults': {}, 'blockers': []}
    jvm_dir = EVIDENCE / 'jvm-final'
    if args.run_jvm:
        jvm_dir.mkdir(parents=True, exist_ok=True)
        cmd = ['./gradlew', ':app:testDebugUnitTest', '--max-workers=1', '-Pkotlin.compiler.execution.strategy=in-process',
            '-Dorg.gradle.jvmargs=-Xmx4096m -XX:MaxMetaspaceSize=768m -XX:+UseParallelGC -XX:SoftRefLRUPolicyMSPerMB=50 -Dfile.encoding=UTF-8',
            '--init-script', str(ROOT / 'scripts/recovery-writer-tests.init.gradle'), '--console=plain']
        started = datetime.now(timezone.utc).timestamp()
        with (jvm_dir / 'run.log').open('w') as output:
            completed = subprocess.run(cmd, cwd=ROOT / 'android-vinetrack', stdout=output, stderr=subprocess.STDOUT)
        files = list((ROOT / 'android-vinetrack/app/build/test-results/testDebugUnitTest').glob('TEST-*.xml'))
        fresh = [p for p in files if p.stat().st_mtime >= started]
        # Overwrite only this current run's XML; a missing suite is not filled by an old report.
        reports = {}
        for path in fresh:
            destination = jvm_dir / path.name
            destination.write_bytes(path.read_bytes()); reports[path.name] = sha(destination)
        (jvm_dir / 'receipt.json').write_text(json.dumps({'returnCode': completed.returncode, 'reports': reports,
            'sourceInventorySha256': evidence['sourceInventorySha256']}, indent=2) + '\n')
    receipt_path = jvm_dir / 'receipt.json'
    jvm = {}
    if receipt_path.exists():
        receipt = json.loads(receipt_path.read_text())
        if receipt['sourceInventorySha256'] != evidence['sourceInventorySha256']:
            evidence['blockers'].append('JVM_SOURCE_CHANGED_SINCE_EXECUTION')
        if receipt['returnCode'] != 0: evidence['blockers'].append('JVM_COMMAND_FAILED')
        for name, digest in receipt['reports'].items():
            path = jvm_dir / name
            if not path.exists() or sha(path) != digest:
                evidence['blockers'].append('JVM_REPORT_CHANGED:' + name); continue
            for case in ET.parse(path).getroot().iter('testcase'):
                jvm[case.attrib['classname'] + '#' + case.attrib['name']] = 'passed' if not any(case.find(x) is not None for x in ('failure','error','skipped')) else 'failed_or_skipped'
    native = {}
    for name in manifest['nativeLogs']:
        path = EVIDENCE / name
        if path.exists(): native.update(native_cases(path))
    # Do not turn aggregate Swift tool counts into named-test results.
    for surface, actual in [('jvm', jvm), ('android', native), ('ios', {})]:
        required = manifest[surface]
        statuses = {name: actual.get(name, 'unexecuted_or_no_named_receipt') for name in required}
        evidence['requiredResults'][surface] = statuses
        evidence['blockers'].extend(surface + ':' + k + ':' + v for k,v in statuses.items() if v != 'passed')
    protected = json.loads((EVIDENCE / 'integration.json').read_text())['protectedHashes']
    evidence['protectedConfiguration'] = {p: {'expectedSha256': digest, 'observedSha256': before.get(p), 'matches': before.get(p) == digest} for p,digest in protected.items()}
    for p, entry in evidence['protectedConfiguration'].items():
        if not entry['matches']: evidence['blockers'].append('CONFIGURATION_FINGERPRINT_MISMATCH:' + p)
    if before != inventory(): evidence['blockers'].append('SOURCE_CHANGED_DURING_PREFLIGHT')
    evidence['blockers'].extend(manifest['unverifiedAcceptanceGates'])
    evidence['releaseGatePassed'] = not evidence['blockers']
    evidence['evidenceSha256'] = {str(p.relative_to(EVIDENCE)): sha(p) for p in sorted(EVIDENCE.rglob('*')) if p.is_file() and p.name not in ('preflight.json',)}
    (EVIDENCE / 'preflight.json').write_text(json.dumps(evidence, indent=2) + '\n')
    summary = {k: {'required':len(v), 'namedPassed':sum(s == 'passed' for s in v.values())} for k,v in evidence['requiredResults'].items()}
    print(json.dumps({'results': summary, 'releaseGatePassed': evidence['releaseGatePassed'], 'blockerCount': len(evidence['blockers']), 'report': str((EVIDENCE / 'preflight.json').relative_to(ROOT))}, indent=2))
    return 0 if evidence['releaseGatePassed'] else 1

if __name__ == '__main__': sys.exit(main())

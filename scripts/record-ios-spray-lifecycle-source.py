"""Read-only GitHub main/source audit for the isolated iOS lifecycle acceptance.
Does not stage, commit, push, deploy, or access any backend customer data.
"""
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/reviews/evidence/ios-spray-lifecycle/source-validation.json'
BASE = 'https://api.github.com/repos/stockmansridge/rork-vinetrack-june26/'

def api(path):
    request = urllib.request.Request(BASE + path, headers={
        'Accept': 'application/vnd.github+json', 'User-Agent': 'VineTrack-source-audit'})
    with urllib.request.urlopen(request, timeout=50) as response:
        return json.load(response)

def relevant(path):
    return path.startswith(('ios/', '.github/workflows/'))

def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()

main = api('branches/main')['commit']['sha']
tree = api('git/trees/' + main + '?recursive=1')
if tree.get('truncated'):
    raise RuntimeError('Refusing incomplete recursive source comparison')
remote = {row['path']: row['sha'] for row in tree['tree'] if row['type'] == 'blob' and relevant(row['path'])}
paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
local = {path: (ROOT / path).read_bytes() for path in set(paths) if relevant(path) and (ROOT / path).is_file()}
changes = []
for path in sorted(set(remote) | set(local)):
    if path not in local:
        changes.append({'path': path, 'change': 'missing-locally'})
    elif path not in remote:
        changes.append({'path': path, 'change': 'added-in-workspace'})
    elif blob(local[path]) != remote[path]:
        changes.append({'path': path, 'change': 'modified-in-workspace'})
manifest = {path: hashlib.sha256(data).hexdigest() for path, data in sorted(local.items())}
result = {
    'recordedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'githubMainObserved': main,
    'managedHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'githubFileCount': len(remote), 'workspaceFileCount': len(local),
    'identicalFileCount': sum(path in remote and blob(data) == remote[path] for path, data in local.items()),
    'workspaceDeltaFromMain': changes,
    'sourceIdentityCaveat': 'The publish source is the validated workspace snapshot, not a claim that the uncommitted harness delta already exists at the observed GitHub SHA. Managed synchronization records the final commit after this turn.',
    'sourceManifestSha256': hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest(),
    'sourceSha256': manifest,
    'preservedSha256': {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in [
        'ios/VineTrack/Config.swift', 'sql/occurrence_tank_link_uuid_case_identity.sql']},
    'nativeUnitRuns': [
        {'passed': 267, 'failed': 0, 'seconds': 31, 'selection': 'Start/planning, receipt, tank commit/lifecycle, completion, occurrence and anti-resurrection suites'},
        {'passed': 301, 'failed': 0, 'seconds': 26, 'selection': 'Calculation parity/contract, chemistry/carrier, handoff, initial amounts, tank actuals, geometry, guided parity, setup/planning suites'}],
    'uiRuns': [
        {'selector': 'VineTrackUITests/SprayLifecycleAcceptanceUITests/testSingleRowManual800LTwoTankLifecycleAndRestart', 'passed': 1, 'failed': 0, 'seconds': 90},
        {'selector': 'VineTrackUITests/SprayLifecycleAcceptanceUITests/testTwoRowManual800LTwoTankLifecycleAndRestart', 'passed': 1, 'failed': 0, 'seconds': 83}],
    'uiEvidence': 'Actual Calculator review, entered first-tank actuals, explicit Free Drive, foreground ActiveTripView, End Tank 1, confirm Tank 2, End Trip closes Tank 2 durably before Trip, two actual records, linked Spray completion, real terminate/relaunch with same completed Trip ID. Screenshots retained as XCTest attachments.',
    'earlierHarnessFailures': 'Repaired missing simulated tank operator, ambiguous confirmation query, and offscreen activation-point helper before the two passing UI runs. Earlier unconfigured presentation fixture was not evidence of a release defect.',
    'simulatorBuild': 'runChecks(ios) PASS after final iOS source edits',
    'boundaries': 'DEBUG UUID opt-in only. Simulated identity and receipts, separately persisted device/server stores, production replay and receipt validation, fail-closed invalid Supabase URL. Not full TripSyncService HTTP; not live Supabase sync; no live queue acknowledgement; planned occurrence UI route not exercised.',
    'incident': 'OPEN: original customer Trip still requires authorised server readback; operation 2be68a70-9582-4981-8a87-e727f113cdf6 remains held. No Android edits, migrations, production customer writes or storage clearing.'
}
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({key: result[key] for key in ['githubMainObserved', 'managedHead', 'githubFileCount', 'workspaceFileCount', 'identicalFileCount', 'workspaceDeltaFromMain', 'sourceManifestSha256', 'preservedSha256']}, indent=2))

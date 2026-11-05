"""Read-only source provenance; does not sync Git or touch customer data."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BASE = 'https://api.github.com/repos/stockmansridge/rork-vinetrack-june26/'
parser = argparse.ArgumentParser()
parser.add_argument('--base', default='e2c68db21d1cbbd049ee06fea2a28b74b92628a3')
parser.add_argument('--output', default='docs/reviews/evidence/ios-build223-performance/source-validation.json')
args = parser.parse_args()
REQUESTED = args.base
OUT = ROOT / args.output


def api(path):
    request = urllib.request.Request(BASE + path, headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'VineTrack-source-audit'})
    with urllib.request.urlopen(request, timeout=50) as response:
        return json.load(response)


def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def source_path(path):
    return path.startswith(('ios/', '.github/workflows/', 'android-vinetrack/')) or path == 'sql/occurrence_tank_link_uuid_case_identity.sql'


main = api('branches/main')['commit']['sha']
tree = api('git/trees/' + REQUESTED + '?recursive=1')
if tree.get('truncated'):
    raise RuntimeError('Incomplete recursive tree; source audit refused')
remote = {row['path']: row['sha'] for row in tree['tree'] if row['type'] == 'blob' and source_path(row['path'])}
paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
local = {p: (ROOT / p).read_bytes() for p in set(paths) if source_path(p) and (ROOT / p).is_file()}
delta = []
for path in sorted(set(local) | set(remote)):
    if path not in local:
        delta.append({'path': path, 'change': 'missing-locally'})
    elif path not in remote:
        delta.append({'path': path, 'change': 'added-in-workspace'})
    elif blob(local[path]) != remote[path]:
        delta.append({'path': path, 'change': 'modified-in-workspace'})
manifest = {p: hashlib.sha256(data).hexdigest() for p, data in sorted(local.items())}
result = {
    'recordedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'requestedBaseSHA': REQUESTED,
    'latestGitHubMainObserved': main,
    'managedHEAD': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'comparedTo': 'requestedBaseSHA (not a claim the workspace is that exact commit)',
    'remoteFileCount': len(remote), 'workspaceFileCount': len(local),
    'identicalFileCount': sum(p in remote and blob(data) == remote[p] for p, data in local.items()),
    'delta': delta,
    'androidUnchangedFromRequestedBase': not any(row['path'].startswith('android-vinetrack/') for row in delta),
    'protectedFilesUnchangedFromRequestedBase': {
        p: blob(local[p]) == remote[p] for p in ['ios/VineTrack/Config.swift', 'sql/occurrence_tank_link_uuid_case_identity.sql']
    },
    'manifestSHA256': hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest(),
    'filesSHA256': manifest,
    'releaseGate': 'NOT APPROVED: no signed archive-only capability; no upload attempted. Crash cause and physical-device acceptance remain open.'
}
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k: v for k, v in result.items() if k != 'filesSHA256'}, indent=2))

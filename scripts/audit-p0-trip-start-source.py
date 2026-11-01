"""Read-only upstream/managed comparison; downloads only into /tmp/vt-p0."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TMP = Path('/tmp/vt-p0')
BASE = 'https://raw.githubusercontent.com/stockmansridge/rork-vinetrack-june26/'

def sha(data): return hashlib.sha256(data).hexdigest()
def fetch(item):
    revision, path = item
    target = TMP / 'sources' / revision / path
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(BASE + revision + '/' + path, timeout=40) as r:
            target.write_bytes(r.read())
    return item, target.read_bytes()

prs = {n: json.loads((TMP / f'pr{n}.json').read_text()) for n in (29,31,33,37)}
files = {n: json.loads((TMP / f'pr{n}-files.json').read_text()) for n in prs}
main = json.loads((TMP / 'main.json').read_text())['commit']['sha']
jobs = set()
for n, rows in files.items():
    for row in rows:
        if row['status'] != 'removed':
            jobs.add((prs[n]['head']['sha'], row['filename']))
            if row['filename'].startswith(('ios/', 'android-vinetrack/', 'sql/')):
                jobs.add((main, row['filename']))
data, failures = {}, []
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    tasks = {pool.submit(fetch, job): job for job in jobs}
    for task, job in tasks.items():
        try:
            key, value = task.result(); data[key] = value
        except Exception as e: failures.append({'revision':job[0], 'path':job[1], 'error':type(e).__name__})
result = {'managedHead':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(), 'publicMain':main, 'prs':[], 'downloadFailures':failures,
          'installedSourceMapping':'UNVERIFIED: current installed build receipts/identifiers not provided',
          'note':'Exact equality is strong evidence only for that file. Divergence can preserve/adapt hunks; it is not evidence a repair is missing. Open PR status is not build inclusion.'}
for n, rows in files.items():
    changes=[]
    for row in rows:
        path=row['filename']; local=ROOT/path
        prior=data.get((prs[n]['head']['sha'],path)); public=data.get((main,path))
        changes.append({'path':path,'managedExists':local.exists(), 'managedSha256':sha(local.read_bytes()) if local.exists() else None,
            'prSha256':sha(prior) if prior is not None else None,'publicMainSha256':sha(public) if public is not None else None,
            'managedEqualsPR':local.exists() and prior is not None and local.read_bytes()==prior,
            'managedEqualsPublicMain':local.exists() and public is not None and local.read_bytes()==public})
    result['prs'].append({'number':n,'head':prs[n]['head']['sha'],'base':prs[n]['base']['sha'],'merged':prs[n]['merged'],'files':changes})
out=ROOT/'docs/reviews/evidence/p0-trip-start/source-audit.json'; out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps(result,indent=2)+'\n')
for pr in result['prs']:
    app=[r for r in pr['files'] if r['path'].startswith(('android-vinetrack/','ios/','sql/'))]
    print('PR',pr['number'],'open=',not pr['merged'],'files=',len(app),'exact PR=',sum(r['managedEqualsPR'] for r in app),'exact public main=',sum(r['managedEqualsPublicMain'] for r in app))
    for r in app:
        if not r['managedEqualsPR']: print(' REVIEW',r['path'])
print('download failures',len(failures))

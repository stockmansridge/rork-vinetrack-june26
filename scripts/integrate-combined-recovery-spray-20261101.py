#!/usr/bin/env python3
"""Apply the two exact sibling repairs as guarded textual deltas, never branch checkout.
Inputs are GitHub commit JSON and exact archives downloaded outside the workspace.
Git is read-only. Rork records the integration revision automatically after sync.
"""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
BASE = 'f8d36eec3298071b92cb0d653e3b74d0d27ecc12'
REPAIRS = [('repair-a','d3b7f7ace498de5d4b24b83891815833765024e0'),('repair-b','dc603d8c4ad445da502ce9610f19dd30ecfbb681')]

def run():
    assert json.loads(Path('/tmp/vinetrack-combined-main.json').read_text())['sha'] == BASE
    evidence=[]
    # Both exact API patches have matching base; patch applies hunks, not whole-file replacement.
    for name, sha in REPAIRS:
        commit=json.loads(Path(f'/tmp/vinetrack-{name}.json').read_text())
        assert commit['sha']==sha and [p['sha'] for p in commit['parents']]==[BASE]
        with tarfile.open(f'/tmp/vinetrack-{name}.tar.gz') as archive:
            prefix=archive.getmembers()[0].name.split('/')[0]+'/'
            for change in commit['files']:
                rel=change['filename']; path=ROOT/rel
                assert not rel.startswith(('.rork/','supabase/','sql/'))
                assert change['status'] in ['added','modified'], (rel,change['status'])
                content=archive.extractfile(prefix+rel).read()
                before=path.read_bytes() if path.exists() else b''
                if change['status']=='added':
                    assert not path.exists(), f'Already exists: {rel}'
                    path.parent.mkdir(parents=True,exist_ok=True)
                    path.write_bytes(content)
                else:
                    assert path.exists() and change.get('patch'), rel
                    patch=f'--- {rel}\n+++ {rel}\n'+change['patch']+'\n'
                    subprocess.run(['patch','--batch','--fuzz=0','--no-backup-if-mismatch','--reject-file=/tmp/vinetrack-combined-rejected.patch',str(path)],input=patch.encode(),check=True,cwd=ROOT)
                    # Only AccountTransitionEvidence overlaps; all other outputs must match archive exactly.
                    if not rel.endswith('/AccountTransitionEvidence.kt'): assert path.read_bytes()==content, rel
                evidence.append({'repair':sha,'path':rel,'status':change['status'],'beforeSha256':hashlib.sha256(before).hexdigest(),'repairSha256':hashlib.sha256(content).hexdigest(),'integratedSha256':hashlib.sha256(path.read_bytes()).hexdigest()})
    out=ROOT/'docs/reviews/evidence/combined-recovery-spray-20261101'
    out.mkdir(parents=True,exist_ok=True)
    (out/'repair-integration.json').write_text(json.dumps({'basePublicMain':BASE,'startingManagedRevision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT).decode().strip(),'method':'Exact GitHub API hunks with fuzz zero; no checkout, wholesale branch overwrite, reset, cherry-pick, commit or push. AccountTransitionEvidence retains both disjoint deltas.','changes':evidence},indent=2)+'\n')

if __name__=='__main__': run()

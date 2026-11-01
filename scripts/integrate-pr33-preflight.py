#!/usr/bin/env python3
"""Apply only reviewed recovery/sync deltas; never import configuration or cosmetics."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/reviews/evidence/pr33-preflight/integration.json'
SKIP = {'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt',
        'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayStartActualFields.kt',
        'ios/VineTrack/App/SprayCalculatorView.swift', 'ios/VineTrack/App/SprayStartRateReview.swift'}
PROTECTED = ['android-vinetrack/app/src/main/java/com/rork/vinetrack/Config.kt',
             'android-vinetrack/app/build.gradle.kts', 'ios/VineTrack/App/AppConfig.swift',
             'ios/VineTrack.xcodeproj/project.pbxproj', 'rork.json']
def sha(b): return hashlib.sha256(b).hexdigest()
def main():
    assert not OUT.exists(), 'Already applied; do not rerun'
    changes = json.loads(Path('/tmp/vinetrack-pr33-compare.json').read_text())['files']
    originals = {p:(ROOT/p).read_bytes() for p in PROTECTED}
    plans = []
    with tarfile.open('/tmp/vinetrack-pr33.tar.gz') as archive:
        prefix=archive.getmembers()[0].name.split('/')[0]+'/'
        for change in changes:
            name=change['filename']
            if name in SKIP: continue
            path=ROOT/name
            expected=archive.extractfile(prefix+name).read()
            before=path.read_bytes() if path.exists() else b''
            if before == expected: plans.append((name,before,expected,None));continue
            if change['status']=='added':
                assert not path.exists(), name
                patch=None
            else:
                assert change['status']=='modified' and path.exists(),name
                patch=f'--- {name}\n+++ {name}\n'+change['patch']+'\n'
                subprocess.run(['patch','--dry-run','--batch','--fuzz=0',str(path)],input=patch.encode(),cwd=ROOT,check=True)
            plans.append((name,before,expected,patch))
    receipt={'startingManagedRevision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT).decode().strip(),
             'prHead':'33fc6a20427f14250ced5ec1c4162e3dcac56cdc','testedUpstreamCheckpoint':'c1a8075d0bbfa613efcd95f03bf683ee8fe218ee',
             'excludedCosmeticFiles':sorted(SKIP),'changes':[]}
    for name,before,expected,patch in plans:
        path=ROOT/name
        if patch: subprocess.run(['patch','--batch','--fuzz=0','--no-backup-if-mismatch','--reject-file=/tmp/pr33-reject',str(path)],input=patch.encode(),cwd=ROOT,check=True)
        elif before!=expected: path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(expected)
        receipt['changes'].append({'path':name,'beforeSha256':sha(before),'afterSha256':sha(path.read_bytes()),'upstreamSha256':sha(expected)})
    for p,b in originals.items(): assert (ROOT/p).read_bytes()==b,p
    receipt['protectedHashes']={p:sha(b) for p,b in originals.items()}
    OUT.parent.mkdir(parents=True,exist_ok=True);OUT.write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))
if __name__=='__main__':main()

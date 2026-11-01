"""Apply only reviewed PR37 app/test hunks, preserving all surrounding managed work."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TMP = Path('/tmp/vt-p0')
meta = json.loads((TMP/'pr37.json').read_text())
rows = json.loads((TMP/'pr37-files.json').read_text())
changes=[]
prepared=[]
for row in rows:
    path = row['filename']
    if path.startswith('.github/'): continue
    target=ROOT/path
    before=target.read_text() if target.exists() else ''
    after=before
    patch=row['patch']
    hunks=re.split(r'^@@[^\n]*\n',patch,flags=re.M)[1:]
    for hunk in hunks:
        lines=hunk.splitlines(keepends=True)
        old=''.join(line[1:] for line in lines if line[:1] in (' ','-')).rstrip('\n')
        new=''.join(line[1:] for line in lines if line[:1] in (' ','+')).rstrip('\n')
        if old:
            assert after.count(old)==1, f'Context mismatch: {path}'
            after=after.replace(old,new,1)
        else:
            assert not target.exists(), f'Already exists: {path}'
            after=new+'\n'
    expected=(TMP/'sources'/meta['head']['sha']/path).read_text()
    assert after==expected, f'Unexpected divergence from reviewed PR: {path}'
    prepared.append((target,after))
    changes.append({'path':path,'beforeSha256':hashlib.sha256(before.encode()).hexdigest(),'afterSha256':hashlib.sha256(after.encode()).hexdigest()})
parent=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
for target,after in prepared:
    target.parent.mkdir(parents=True,exist_ok=True); target.write_text(after)
receipt={'pr':37,'head':meta['head']['sha'],'managedParent':parent,'changes':changes,
         'excluded':'Branch-only synthetic CI workflow', 'limits':'Integration is not proof of original-device recovery or live backend acknowledgement; subsequent safety refinements recorded separately'}
out=ROOT/'docs/reviews/evidence/p0-trip-start/pr37-integration.json';out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(receipt,indent=2)+'\n')
print('Applied four exact app/test files; excluded synthetic workflow; configuration untouched.')

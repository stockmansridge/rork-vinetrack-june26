#!/usr/bin/env python3
"""Integrate reviewed PR35 exact unique hunks, never branch-swap or alter config."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/reviews/evidence/pr35-hotfix/integration.json'
PROTECTED = ['android-vinetrack/app/src/main/java/com/rork/vinetrack/Config.kt', 'android-vinetrack/app/build.gradle.kts', 'ios/VineTrack/App/AppConfig.swift', 'ios/VineTrack.xcodeproj/project.pbxproj', 'rork.json']
def sha(b): return hashlib.sha256(b).hexdigest()
def main():
    assert not OUT.exists(), 'Already integrated; inspect receipt'
    metadata = json.loads(Path('/tmp/vt-pr35.json').read_text())
    assert metadata['head']['sha'] == '38e0485aeea7d8504f068151a469be6d78f08179'
    protected = {p: sha((ROOT / p).read_bytes()) for p in PROTECTED}
    plans = []
    for change in json.loads(Path('/tmp/vt-pr35-files.json').read_text()):
        p = change['filename']
        if p.startswith('.github/'): continue  # Branch-only synthetic CI is not shipping configuration.
        assert p.startswith(('ios/', 'android-vinetrack/', 'docs/reviews/'))
        target = ROOT / p
        before = target.read_text() if target.exists() else ''
        after = before
        for hunk in re.split(r'^@@[^\n]*\n', change['patch'], flags=re.M)[1:]:
            lines = hunk.splitlines(keepends=True)
            old = ''.join(l[1:] for l in lines if l.startswith((' ', '-')))
            new = ''.join(l[1:] for l in lines if l.startswith((' ', '+')))
            if old:
                assert after.count(old) == 1, 'Conflict; inspect ' + p
                after = after.replace(old, new, 1)
            else:
                assert not target.exists()
                after = new
        plans.append((p, before, after))
    receipt = {'pr': 35, 'head': metadata['head']['sha'], 'base': metadata['base']['sha'], 'managedParent': subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip(), 'protectedConfiguration': protected, 'excluded': 'Two branch-only CI workflows with synthetic build configuration', 'changes': [{'path':p,'beforeSha256':sha(b.encode()),'afterSha256':sha(a.encode())} for p,b,a in plans]}
    for p,b,a in plans:
        (ROOT/p).parent.mkdir(parents=True, exist_ok=True)
        (ROOT/p).write_text(a)
    assert protected == {p:sha((ROOT/p).read_bytes()) for p in PROTECTED}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(receipt, indent=2))
if __name__ == '__main__': main()

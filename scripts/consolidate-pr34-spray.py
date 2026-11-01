#!/usr/bin/env python3
"""Apply reviewed PR34 Android/remaining PR33 iOS presentation hunks by unique exact context.
Usage: python3 scripts/consolidate-pr34-spray.py [--apply]
Downloaded GitHub metadata stays in /tmp; no Git mutations or configuration replacement.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/reviews/evidence/pr34-consolidation/integration.json'
PROTECTED = ['android-vinetrack/app/src/main/java/com/rork/vinetrack/Config.kt',
             'android-vinetrack/app/build.gradle.kts', 'ios/VineTrack/App/AppConfig.swift',
             'ios/VineTrack.xcodeproj/project.pbxproj', 'rork.json']
ANDROID = {
 'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/components/SprayPlanningCards.kt',
 'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/CatalogueSavedChemical.kt',
 'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt',
 'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayStartActualFields.kt',
}
IOS = {'ios/VineTrack/App/SprayCalculatorView.swift', 'ios/VineTrack/App/SprayStartRateReview.swift'}
def sha(b): return hashlib.sha256(b).hexdigest()

def main():
 parser = argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--apply', action='store_true')
 args = parser.parse_args()
 assert not OUT.exists(), 'Already integrated; inspect receipt instead of rerunning'
 protected = {p: sha((ROOT/p).read_bytes()) for p in PROTECTED}
 changes = json.loads(Path('/tmp/vinetrack-pr34-files.json').read_text())
 assert {c['filename'] for c in changes} == ANDROID
 changes += [c for c in json.loads(Path('/tmp/vinetrack-pr33-compare.json').read_text())['files'] if c['filename'] in IOS]
 assert {c['filename'] for c in changes} == ANDROID | IOS
 plans = []
 for c in changes:
  path = ROOT/c['filename']; before = path.read_text(); after = before; outcomes = []
  for h in re.split(r'^@@[^\n]*\n', c['patch'], flags=re.M)[1:]:
   lines = h.splitlines(keepends=True)
   old = ''.join(line[1:] for line in lines if line.startswith((' ', '-')))
   new = ''.join(line[1:] for line in lines if line.startswith((' ', '+')))
   if not old.endswith('\n'): old += '\n'
   if not new.endswith('\n'): new += '\n'
   if after.count(old) == 1:
    after = after.replace(old, new, 1); outcomes.append('applied_exact_unique_context')
   elif after.count(new) == 1: outcomes.append('already_present')
   else: raise RuntimeError('Explicit conflict requires review: ' + c['filename'])
  plans.append((c['filename'], before, after, outcomes))
 receipt = {'startingManagedRevision': subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT).decode().strip(),
   'pr34Head': '7ff419e392ebae3dba2294dcbee876f08398de21',
   'pr33Head': '33fc6a20427f14250ced5ec1c4162e3dcac56cdc', 'protectedHashes': protected,
   'scope': 'Six presentation files only; earlier recovery/sync integration preserved',
   'changes': [{'path':p, 'beforeSha256':sha(b.encode()), 'afterSha256':sha(a.encode()), 'hunks':o} for p,b,a,o in plans]}
 if args.apply:
  for p,b,a,o in plans: (ROOT/p).write_text(a)
  assert protected == {p: sha((ROOT/p).read_bytes()) for p in PROTECTED}
  OUT.parent.mkdir(parents=True, exist_ok=True)
  OUT.write_text(json.dumps(receipt, indent=2)+'\n')
 print(json.dumps(receipt, indent=2))
if __name__ == '__main__': main()

"""Bounded host checks; not an Android/Compose or pinned kotlinx JSON run.

Run: python3 scripts/test_android_download_status_host.py
Requires existing kotlinc/java; never installs dependencies.
"""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
base = root / 'android-vinetrack/app/src/main/java/com/rork/vinetrack'
# Reproduce only the original parser's precedence using Python JSON.
body = json.loads('{"code":400,"error_code":"refresh_token_not_found"}')
selected = body['code'] if body.get('code') is not None else body.get('error_code')
assert selected == 400
print('Before: legacy numeric code masks the original error_code lookup.', flush=True)

screen = (base / 'ui/screens/SyncStatusScreen.kt').read_text()
checks = [
    screen.count('state = state,') >= 3,
    '"paddocks" -> state.blocksKnowledge' in screen,
    '"pins" -> state.pinsKnowledge' in screen,
    '"spray" -> state.spraysKnowledge' in screen,
    'readError = if (spec.id == "paddocks") state.paddockError else null' in screen,
    'syncDownloadStatus(readKnowledge' in screen,
    '?: "Up to date"' not in screen,
    '${spec.title} refreshed.' not in screen,
]
assert all(checks), f'Wiring failures: {[i for i, ok in enumerate(checks) if not ok]}'
print('Production source wiring: 8 checks passed', flush=True)
if not shutil.which('kotlinc') or not shutil.which('java'):
    raise SystemExit('JVM checks NOT RUN: kotlinc/java unavailable. Run native tests in Rork.')

source = (base / 'data/auth/RefreshRejection.kt').read_text()
policy = 'package com.rork.vinetrack.data.auth\n\n' + source[source.index('internal object RefreshRejectionCodes'):]
probe = '''package com.rork.vinetrack.ui
import com.rork.vinetrack.data.HomeReadKnowledge
import com.rork.vinetrack.data.auth.RefreshRejectionCodes
fun main() {
 var count=0
 val codes=listOf("refresh_token_not_found","refresh_token_already_used","session_not_found","session_expired","user_banned","user_not_found")
 for (status in listOf(400,401,403)) for (code in codes) {
  check(RefreshRejectionCodes.isDefinitive(status,code,null)); count++
  check(RefreshRejectionCodes.isDefinitive(status,null,code)); count++
  check(RefreshRejectionCodes.isDefinitive(status,code,status.toString())); count++
 }
 for (status in listOf(200,429,500,503)) {
  check(!RefreshRejectionCodes.isDefinitive(status,"refresh_token_not_found",null));count++
 }
 for (code in listOf("invalid_grant","insufficient_aal","over_request_rate_limit","unknown","400", "")) {
  check(!RefreshRejectionCodes.isDefinitive(400,null,code));count++
 }
 check(!RefreshRejectionCodes.isDefinitive(400,"refresh_token_not_found","insufficient_aal"));count++
 check(!RefreshRejectionCodes.isDefinitive(400,null,null));count++
 check(RefreshRejectionCodes.isDefinitive(400,"session_expired","session_expired"));count++
 println("Refresh rejection policy: $count cases passed")
 var readCount=0
 for (knowledge in listOf(null,HomeReadKnowledge.Unknown,HomeReadKnowledge.Cached,HomeReadKnowledge.Fresh))
 for (hasTime in listOf(false,true)) for (failed in listOf(false,true)) for (online in listOf(false,true)) {
  val actual=syncDownloadStatus(knowledge,hasTime,failed,online)
  val shouldBeCurrent=knowledge==HomeReadKnowledge.Fresh && !failed && online
  check((actual.tone==SyncDownloadTone.Current)==shouldBeCurrent)
  if(knowledge==HomeReadKnowledge.Unknown && !failed) check(actual.label=="Not downloaded")
  if(failed) check(actual.tone==SyncDownloadTone.Attention)
  if(knowledge==null && hasTime && !failed) check(actual.label=="Last download recorded")
  readCount++
 }
 println("Download status policy: $readCount cases passed")
}
'''
with tempfile.TemporaryDirectory(prefix='vinetrack-download-check-') as tmp:
    work = Path(tmp)
    (work / 'RefreshRejectionCodes.kt').write_text(policy)
    (work / 'Probe.kt').write_text(probe)
    subprocess.run(['kotlinc', str(work / 'RefreshRejectionCodes.kt'),
        str(base / 'data/HomeReadKnowledge.kt'), str(base / 'ui/SyncDownloadStatus.kt'),
        str(work / 'Probe.kt'), '-include-runtime', '-d', str(work / 'checks.jar')],
        check=True, timeout=90)
    subprocess.run(['java', '-jar', str(work / 'checks.jar')], check=True, timeout=30)
print('Native JSON/Android/Compose and original-device recovery remain unverified.')

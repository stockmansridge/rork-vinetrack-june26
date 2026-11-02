#!/usr/bin/env python3
"""Verify exact public Android source and reuse Rork's materialised generated config.
No configuration values are printed or retained in evidence. No application edits.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path('/tmp/spray-config-6baaed77')
CONFIG = Path('android-vinetrack/app/src/main/java/com/rork/vinetrack/Config.kt')
EXPECTED = 'a1da2e0589dbe2e6430459e36a7e32dc93c4b15c846e6bc7cccbc1499a4712e8'
OUT = Path('/tmp/spray-config-input-receipt.json')


def main():
    manifest = json.loads(Path('docs/reviews/evidence/android-tracked-spray-completion-20261102/source-manifest.json').read_text())
    for e in manifest:
        assert hashlib.sha256((ROOT/e['path']).read_bytes()).hexdigest() == e['sha256']
        assert (ROOT/e['path']).read_bytes() == Path(e['path']).read_bytes()
    subprocess.run(['git', 'check-ignore', '--quiet', str(CONFIG)], check=True)
    assert not subprocess.check_output(['git', 'ls-files', '--', str(CONFIG)]).strip()
    data = CONFIG.read_bytes()
    assert hashlib.sha256(data).hexdigest() == EXPECTED, 'Existing managed environment fingerprint changed'
    text = data.decode()
    assert 'package com.rork.vinetrack' in text and 'object Config' in text
    assert re.search(r'val allValues\s*:\s*Map<String,\s*String>', text)
    values = dict(re.findall(r'const val (\w+)\s*=\s*"([^"\n]*)"', text))
    assert len(values) == 14 and all(values.values())
    assert values['EXPO_PUBLIC_SUPABASE_URL'].rstrip('/') == 'https://tbafuqwruefgkbyxrxyb.supabase.co'
    assert values['EXPO_PUBLIC_GOOGLE_WEB_CLIENT_ID'].endswith('.apps.googleusercontent.com')
    assert values['EXPO_PUBLIC_REVENUECAT_ANDROID_API_KEY'].startswith('goog_')
    # Require the map to bind each named constant, not dummy or unrelated values.
    for key in values:
        assert re.search(r'"' + key + r'"\s+to\s+' + key + r'\b', text), key
    env_matches = {k: os.environ[k] == v for k,v in values.items() if k in os.environ}
    assert all(env_matches.values()), 'Managed environment mismatch'
    destination = ROOT/CONFIG
    assert not destination.exists(), 'Do not replace a generated input'
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(CONFIG, destination)
    destination.chmod(0o600)
    result = {
        'publicCommit': '6baaed77ef0a9af5b06143cdd1115a1805368382',
        'sourceFilesCompared': len(manifest), 'sourceDifferences': [],
        'configurationMethod': 'Use existing Rork-managed Config.kt materialised in sandbox, validated by normal runChecks; copy byte-for-byte into isolated exact-commit validation archive. No custom generator, dummy values or application changes.',
        'configurationIdentity': 'com.rork.vinetrack.Config', 'allValuesContract': 'Map<String, String>; all 14 constants mapped by name',
        'configurationSha256': EXPECTED,
        'matchesPreviouslyRecordedVineTrackEnvironment': True,
        'supabaseProjectMatchesExistingVineTrack': True,
        'googleWebClientShapeValid': True, 'revenueCatAndroidProductionKeyShapeValid': True,
        'all14ValuesPresent': True, 'availableProcessEnvironmentMatches': env_matches,
        'environmentComparisonLimit': 'Full generated input exactly matches protected prior successful VineTrack environment fingerprint; not live service authentication or purchase testing.',
        'configTracked': False, 'signedCredentialsRead': False,
        'normalAndroidBuild': 'runChecks passed on identical 1274-file application source with this managed configuration'
    }
    OUT.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

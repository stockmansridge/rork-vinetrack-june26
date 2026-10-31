#!/usr/bin/env python3
"""Inspect a locally built APK; never certify update compatibility or distribute it."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('apk', type=Path)
parser.add_argument('output', type=Path, help='Ignored/output directory, normally outside the project')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
sdk = Path('/opt/android-sdk')
analyzer = sdk / 'cmdline-tools/latest/bin/apkanalyzer'

def run(*command):
    return subprocess.check_output([str(value) for value in command], text=True)

def code(name):
    return run(analyzer, 'dex', 'code', '--class', name, args.apk)

signature = run(sdk / 'build-tools/35.0.0/apksigner', 'verify', '--verbose', '--print-certs', args.apk)
manifest = run(analyzer, 'manifest', 'print', args.apk)
badging = run(sdk / 'build-tools/35.0.0/aapt', 'dump', 'badging', args.apk)
assert run(analyzer, 'manifest', 'debuggable', args.apk).strip() == 'false'
assert '<instrumentation' not in manifest
config = code('com.rork.vinetrack.BuildConfig')
assert '.field public static final DEBUG:Z = false' in config
assert '.field public static final FIELD_STORAGE_ISOLATION_ACTIVATED:Z = false' in config
factory = code('com.rork.vinetrack.data.auth.AuthRecoveryRepository$Companion')
new_client = re.search(r'\.method private final newIsolatedClient\(\).*?\.end method', factory, re.S).group()
assert 'engine/android/Android' in new_client
assert 'instrumentationClientFactory' not in new_client
registration = re.search(r'\.method public final installInstrumentationTransport\$app_release.*?\.end method', factory, re.S).group()
assert 'IllegalStateException' in registration and 'throw ' in registration
packages = run(analyzer, 'dex', 'packages', '--defined-only', args.apk)
classes = [line.split()[-1] for line in packages.splitlines() if line.startswith('C d ')]
for forbidden in ('CleanExitFixtureApplication', 'CleanExitTestRunner', 'PopulatedCleanExitActivityTest',
                  'FieldSaveContentionAndroidTest', 'GuardedSheetStateAndroidTest', 'io.ktor.client.engine.mock.', 'androidx.test.'):
    assert not any(forbidden in name for name in classes), forbidden
assert '.line ' in factory, 'No source-line metadata in inspected recovery bytecode'
summary = {
    'apk_sha256': hashlib.sha256(args.apk.read_bytes()).hexdigest(),
    'bytes': args.apk.stat().st_size,
    'package': re.search(r"name='([^']+)'", badging).group(1),
    'version_name': re.search(r"versionName='([^']+)'", badging).group(1),
    'version_code': int(re.search(r"versionCode='([^']+)'", badging).group(1)),
    'signer_certificate_sha256': re.search(r'certificate SHA-256 digest: (\w+)', signature).group(1),
    'verified_v2_signature': 'Verified using v2 scheme (APK Signature Scheme v2): true' in signature,
    'release_debuggable': False,
    'release_debug_constant': False,
    'storage_isolation_activation': False,
    'test_fixture_classes_and_mock_engine_absent': True,
    'recovery_factory_uses_android_engine_only': True,
    'release_recovery_transport_registration_throws': True,
    'recovery_source_line_metadata_present': True,
    'installed_signature_and_version_verified': False,
    'update_compatibility': 'UNVERIFIED; original installed package/version/certificate unavailable',
    'tester_availability': 'UNESTABLISHED; local inspected build is not a delivered update candidate',
}
shutil.copy2(args.apk, args.output / 'vinetrack-recovery-inspected.apk')
(args.output / 'signature.txt').write_text(signature)
(args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))

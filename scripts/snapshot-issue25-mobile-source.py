#!/usr/bin/env python3
"""Record bounded Issue 25 source provenance; no credentials or customer rows."""
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    'ios/VineTrack/App/ChemicalIntelligence/CatalogueSearchView.swift',
    'ios/VineTrack/App/NewMainTabView.swift',
    'ios/VineTrack/Backend/Storage/VineyardHomeLogoRefresh.swift',
    'ios/VineTrack/Backend/Storage/VineyardLogoStorageService.swift',
    'ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift',
    'ios/VineTrack/LegacyImported/Views/Vineyard/BackendVineyardDetailSheet.swift',
    'ios/VineTrack/LegacyImported/Views/Vineyard/BackendVineyardListView.swift',
    'ios/VineTrackTests/VineyardHomeLogoRefreshTests.swift',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt',
    'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/CatalogueSearchSheet.kt',
    'android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/VineyardLogoCacheAndroidTest.kt',
    'scripts/inspect-issue25-catalogue-contract.py',
    'scripts/snapshot-issue25-mobile-source.py',
]

def main():
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    manifest = {
        'scope': 'Issue 25 partial implementation: management entry and logo refresh; catalogue propagation remains open',
        'starting_managed_sha': 'a153dfc56503ee98aae79dba6a7ba1807de4e3bf',
        'observed_managed_head_at_snapshot': head,
        'public_main_pointer_inspected': '50438333921355136fc8d81a375affc8a3334da0',
        'ancestry_verified': False,
        'final_integration_sha': None,
        'files': [{'path': name, 'sha256': hashlib.sha256((ROOT / name).read_bytes()).hexdigest()} for name in FILES],
        'validation': {
            'ios_before_orphan_cache_regression': {'passed': 0, 'failed': 1},
            'ios_initial_selection': {'passed': 106, 'failed': 2,
                'failures': ['HomeSyncPerformanceTests 40.543 ms versus 16 ms', 'offline logo fixture missing records directory']},
            'ios_intermediate_logo_selection': {'passed': 9, 'failed': 1,
                'failure': 'offline logo fixture still missing records directory; redundant load did not correct fixture'},
            'ios_final_logo_selection': {'passed': 10, 'failed': 0, 'seconds': 39},
            'android_instrumentation': {'passed': 0, 'failed': 0, 'skipped': 0, 'status': 'infra-failed HTTP 503; not retried'},
            'ios_simulator_build': 'PASS',
            'android_normal_build': 'PASS',
            'device_acceptance': 'NOT RUN',
            'exact_3_1_8_binary_compatibility': 'NOT ESTABLISHED',
            'candidate_delivery': 'NOT PREPARED OR UPLOADED',
        },
    }
    output = ROOT / 'docs/reviews/issue25-mobile-source-manifest-20261030.json'
    output.write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'manifest': str(output.relative_to(ROOT)), 'inputs': len(FILES),
        'sha256': hashlib.sha256(output.read_bytes()).hexdigest()}))

if __name__ == '__main__':
    main()

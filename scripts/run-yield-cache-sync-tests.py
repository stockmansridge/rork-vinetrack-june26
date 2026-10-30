#!/usr/bin/env python3
"""Production cache/row/estimate logic with SDK/input-model boundary stubs.
Host only: remove the Observation macro (not logic); this Linux runtime cannot link it.
Does not validate Supabase transport or replace a native iOS build.
"""
import pathlib, tempfile, shutil, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='vt-yield-cache-') as temp:
    p=pathlib.Path(temp); src=p/'Sources/VineTrack'; tests=p/'Tests/VineTrackTests'
    for d in [src, tests, p/'Sources/Supabase', p/'Sources/PostgREST']: d.mkdir(parents=True)
    for name in ['ios/VineTrack/Backend/Repositories/YieldMasterWeightCache.swift',
                 'ios/VineTrack/LegacyImported/Models/CurrentYieldEstimate.swift',
                 'scripts/fixtures/yield-sync/BoundaryStubs.swift']:
        shutil.copy(root/name, src)
    cache=src/'YieldMasterWeightCache.swift'
    cache.write_text(cache.read_text().replace('import Observation\n', '').replace('@MainActor @Observable final class', '@MainActor final class'))
    rows=(root/'ios/VineTrack/Backend/Repositories/YieldBunchWeightsRepository.swift').read_text().split('@MainActor\nstruct YieldBunchWeightsRepository')[0]
    (src/'YieldBunchWeightRow.swift').write_text(rows.replace('import Observation\n', ''))
    shutil.copy(root/'scripts/fixtures/yield-sync/Supabase.swift',p/'Sources/Supabase')
    (p/'Sources/PostgREST/Placeholder.swift').write_text('// SDK boundary unused by these injected-read tests.\n')
    for name in ['YieldMasterWeightCacheTests.swift', 'YieldMasterFullSyncTests.swift']:
        shutil.copy(root/'ios/VineTrackTests'/name, tests)
    (p/'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "YieldCacheSync", targets: [
.target(name: "Supabase"), .target(name: "PostgREST"),
.target(name: "VineTrack", dependencies: ["Supabase","PostgREST"], swiftSettings: [.defaultIsolation(MainActor.self)]),
.testTarget(name: "VineTrackTests", dependencies: ["VineTrack"])], swiftLanguageModes: [.v5])
''')
    result=subprocess.run(['swift','test','--package-path',str(p),'--jobs','2'],timeout=240)
    raise SystemExit(result.returncode)

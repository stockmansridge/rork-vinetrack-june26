#!/usr/bin/env python3
"""Compile unchanged production deletion journal and native tests on Swift 6.2.
Only PersistenceStore's interface is substituted by a deterministic disk adapter.
Does not substitute for Xcode, the real persistence suite or original-device acceptance.
"""
import pathlib, tempfile, shutil, subprocess
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='vt-delete-') as tmp:
    p=pathlib.Path(tmp)
    src=p/'Sources/VineTrack'; tests=p/'Tests/VineTrackTests'
    src.mkdir(parents=True); tests.mkdir(parents=True)
    for f in ['ios/VineTrack/Backend/Sync/TripDeletionJournal.swift','scripts/fixtures/trip-deletion/PersistenceHarness.swift']:
        shutil.copy(root/f,src)
    shutil.copy(root/'ios/VineTrackTests/TripDeletionPersistenceIdentityTests.swift',tests)
    (p/'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TripPersistenceIdentityTests", targets: [
.target(name: "VineTrack", swiftSettings: [.defaultIsolation(MainActor.self)]),
.testTarget(name: "VineTrackTests", dependencies: ["VineTrack"])], swiftLanguageModes: [.v5])
''')
    result=subprocess.run(['swift','test','--package-path',str(p),'--jobs','2'],timeout=240)
    raise SystemExit(result.returncode)

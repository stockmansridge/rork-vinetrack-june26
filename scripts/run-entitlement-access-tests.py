#!/usr/bin/env python3
"""Run focused iOS access regressions using Swift 6.2+ on macOS or Linux.

Production gate, decoder, cache and presentation are compiled unchanged. Only
RevenueCat and RPC transport dependencies are replaced by deterministic fakes.
Vineyard matrix models are copied from their production repository source.
This does not build SwiftUI, link the iOS app, or substitute for device testing.

Usage: python3 scripts/run-entitlement-access-tests.py [--swift /path/to/swift]
"""
import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    fixture = root / "scripts/fixtures/entitlement"
    sources = [
        "ios/VineTrack/Backend/Models/BackendVineTrackAccess.swift",
        "ios/VineTrack/Backend/Subscription/EntitlementGate.swift",
        "ios/VineTrack/Backend/Subscription/EntitlementVerificationStore.swift",
        "ios/VineTrack/Backend/Subscription/EntitlementAccessPresentation.swift",
        "ios/VineTrack/Backend/Subscription/StorePurchaseSync.swift",
    ]
    tests = [
        "ios/VineTrackTests/EntitlementDecisionTests.swift",
        "ios/VineTrackTests/EntitlementAccessRegressionTests.swift",
        "ios/VineTrackTests/StorePurchaseSyncTests.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="vinetrack-access-tests-") as directory:
        package = Path(directory)
        target = package / "Sources/VineTrack"
        test_target = package / "Tests/VineTrackTests"
        target.mkdir(parents=True)
        test_target.mkdir(parents=True)
        for source in sources:
            shutil.copyfile(root / source, target / Path(source).name)
        for test in tests:
            shutil.copyfile(root / test, test_target / Path(test).name)
        matrix = (root / "ios/VineTrack/Backend/Repositories/VineyardAccessMatrixRepository.swift").read_text()
        marker = "// MARK: - Repository"
        if matrix.count(marker) != 1:
            raise RuntimeError("Vineyard matrix source boundary changed; review the harness extraction")
        matrix_models = matrix.split(marker)[0].replace("import Supabase\n", "")
        (target / "VineyardAccessMatrixModels.swift").write_text(matrix_models)
        shutil.copyfile(fixture / "EntitlementGateHarnessSupport.swift", target / "HarnessSupport.swift")
        shutil.copyfile(fixture / "EntitlementGateHarnessTests.swift", test_target / "EntitlementGateHarnessTests.swift")
        (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "VineTrackAccessTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "VineTrack", swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "VineTrackTests", dependencies: ["VineTrack"])
    ],
    swiftLanguageModes: [.v5]
)
''')
        environment = os.environ.copy()
        environment["CLANG_MODULE_CACHE_PATH"] = str(package / "ModuleCache")
        environment["XDG_CACHE_HOME"] = str(package / "Caches")
        environment["XDG_CONFIG_HOME"] = str(package / "Configuration")
        subprocess.run([args.swift, "--version"], env=environment, check=True)
        result = subprocess.run(
            [args.swift, "test", "--package-path", str(package), "--jobs", "2",
             "--cache-path", str(package / "Caches"),
             "--config-path", str(package / "Configuration"),
             "--security-path", str(package / "Security")],
            env=environment,
            timeout=300,
        )
        print(f"ENTITLEMENT_ACCESS_TEST_EXIT={result.returncode}", flush=True)
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())

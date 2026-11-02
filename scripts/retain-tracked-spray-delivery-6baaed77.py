#!/usr/bin/env python3
"""Retain the stopped exact-public-commit validation, without live data or Git mutations."""
import hashlib
import json
from pathlib import Path
import shutil

COMMIT = "6baaed77ef0a9af5b06143cdd1115a1805368382"
BASE = Path("/tmp/spray-delivery-6baaed77")
OUT = Path("docs/reviews/evidence/android-tracked-spray-delivery-6baaed77")
OLD = Path("docs/reviews/evidence/android-tracked-spray-completion-20261102/source-manifest.json")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    assert not OUT.exists(), "Never overwrite receipts"
    metadata = json.loads(Path("/tmp/spray-delivery-commit.json").read_text())
    assert metadata["sha"] == COMMIT
    manifest = json.loads(OLD.read_text())
    assert len(manifest) == 1274
    for entry in manifest:
        assert sha(BASE / entry["path"]) == entry["sha256"], entry["path"]
        assert (BASE / entry["path"]).read_bytes() == Path(entry["path"]).read_bytes()
    log = Path("/tmp/spray-delivery-6baaed77-jvm.log")
    assert "Unresolved reference 'Config'" in log.read_text()
    assert not list((BASE / "android-vinetrack/app/build/test-results").glob("**/TEST-*.xml"))
    OUT.mkdir(parents=True)
    shutil.copyfile(log, OUT / "exact-commit-jvm-compilation-failure.log")
    result = {
        "publicCommit": COMMIT,
        "archiveSha256": sha(Path("/tmp/spray-delivery-6baaed77.tar.gz")),
        "priorPassingSourceManifestSha256": sha(OLD),
        "comparedAndroidFiles": 1274,
        "priorPassingFingerprintDifferences": [],
        "workspaceTrackedAndroidDifferences": [],
        "sourceChangesMade": False,
        "jvmSelection": {"TrackedSprayCompletionSyncTest": 19, "TripClosureStatusPhaseCTest": 13,
                         "TankDependencyPhaseBTest": 10, "OccurrenceTankConflictHoldTest": 3,
                         "AccountScopedTankSafetyTest": 16},
        "result": "STOPPED_COMPILATION_FAILURE",
        "failedTask": ":app:compileDebugKotlin",
        "executedTests": 0,
        "testXmlReceipts": [],
        "failure": "AppConfig.kt:5:27, 116:29, 148:25 and 148:48: unresolved Config; cascading trim/not errors",
        "cause": "Public archive omits gitignored Rork-generated Config.kt; workspace has that generated file. No injection or retry performed after failure.",
        "log": {"file": "exact-commit-jvm-compilation-failure.log", "sha256": sha(log)},
        "normalAndroidBuild": "NOT RUN after compilation failure: user stop condition",
        "googlePlayConnection": "connected",
        "googlePlayPackageAccess": "ok; com.rork.vinetrack; existing app",
        "signedBuildRequested": False,
        "publishRequested": False,
        "submissionId": None,
        "versionNameInSource": "3.1.9",
        "deliveredVersionCode": None,
        "rpcVerification": "User independently verified deployed signature, auth, original Trip end time and idempotency; not reverified or invoked by agent",
        "customerMutations": False,
        "historicalSweeps": False,
        "retainedOperationChanges": False,
        "deviceAcceptance": "NOT EXECUTED",
        "nextStep": "Authorise validation of the exact committed application source with normal Rork-generated configuration, fingerprinting that separate generated input; do not publish until tests and normal build pass."
    }
    (OUT / "validation-results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

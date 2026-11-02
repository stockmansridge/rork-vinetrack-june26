#!/usr/bin/env python3
"""Retain bounded Android JVM receipts and source identity; never run live requests.

Run from repository root with the already downloaded exact public-main snapshot:
  python3 scripts/retain-tracked-spray-completion-evidence.py /tmp/spray-current-main
The immutable checkpoint refuses overwrite. No Git mutation or secret values.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

APP = "android-vinetrack"
PUBLIC = "63848ddc392828901fd90f13212e8d74281bc753"
MANAGED = "631ec5636a40a98bafa83480a20459fad9345617"
OUT = Path("docs/reviews/evidence/android-tracked-spray-completion-20261102")
SUITES = {"TrackedSprayCompletionSyncTest": 19, "TripClosureStatusPhaseCTest": 13,
          "TankDependencyPhaseBTest": 10, "OccurrenceTankConflictHoldTest": 3,
          "AccountScopedTankSafetyTest": 16}


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    baseline = Path(sys.argv[1])
    assert git("branch", "--show-current") == "main"
    assert git("rev-parse", "HEAD") == MANAGED, "Checkpoint base changed; review before recording"
    assert not OUT.exists(), "Preserve the existing checkpoint"
    paths = sorted(git("ls-files", "--", APP).splitlines())
    entries = []
    changes = []
    for name in paths:
        data = Path(name).read_bytes()
        entry = {"path": name, "sha256": digest(data), "bytes": len(data),
                 "executable": bool(Path(name).stat().st_mode & 0o111)}
        entries.append(entry)
        original = baseline / name
        if not original.exists() or data != original.read_bytes():
            changes.append({**entry, "baselineSha256": digest(original.read_bytes()) if original.exists() else None})
    assert len(paths) == 1274 and len(changes) == 10
    receipts = []
    for suite, count in SUITES.items():
        path = Path(APP) / "app/build/test-results/testDebugUnitTest" / f"TEST-com.rork.vinetrack.data.{suite}.xml"
        root = ET.parse(path).getroot()
        assert int(root.attrib["tests"]) == count
        assert all(int(root.attrib[k]) == 0 for k in ("failures", "errors", "skipped"))
        receipts.append({"suite": root.attrib["name"], "tests": count, "timestamp": root.attrib["timestamp"],
                         "sha256": digest(path.read_bytes()), "file": path.name})
    OUT.mkdir(parents=True)
    for receipt in receipts:
        shutil.copyfile(Path(APP) / "app/build/test-results/testDebugUnitTest" / receipt["file"], OUT / receipt["file"])
    manifest_bytes = (json.dumps(entries, sort_keys=True, indent=2) + "\n").encode()
    (OUT / "source-manifest.json").write_bytes(manifest_bytes)
    result = {
        "publicBaselineCommit": PUBLIC, "managedBaseCommit": MANAGED, "branch": "main",
        "correctionCommit": None, "sourceState": "Working-tree/index overlay; bases do not contain correction",
        "sourceManifestSha256": digest(manifest_bytes), "androidFileCount": len(entries),
        "changedAndroidFilesAgainstPublicBaseline": changes,
        "nativeValidation": {"kind": "host JVM", "tests": 61, "failures": 0, "errors": 0, "skipped": 0,
                             "receipts": receipts, "selection": APP + "/tracked-spray-tests.init.gradle",
                             "finalLogSha256": digest(Path("/tmp/tracked-spray-native-tests-final-source.log").read_bytes()),
                             "productionSourceExclusions": False},
        "normalAndroidBuild": "runChecks passed on final application source; not device execution or delivery acceptance",
        "earlierAttempts": ["Production compilation OOM: zero assertions", "Test fixture compilation missing shared helpers: zero assertions", "57 passes before final safety review; superseded, not additive"],
        "notExecuted": ["Device instrumentation", "Real process-death lifecycle", "Authenticated backend/Portal acceptance",
                        "Deployed SQL 259 verification", "Full unfiltered unit suite", "Signed testing candidate request", "Store publication", "Customer-record repair"],
        "scope": "New explicit tracked End intents only; no historical scan; existing operations/actuals/manual workflow preserved",
        "retentionModel": "Reopen tests reconstruct coordinator/repository over shared in-memory persisted state, not Android process death",
    }
    (OUT / "validation-results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"checkpoint": str(OUT), "tests": 61, "sourceManifestSha256": result["sourceManifestSha256"]}, indent=2))


if __name__ == "__main__":
    main()

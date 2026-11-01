#!/usr/bin/env python3
"""Retain exact imported-source parity and fresh Gradle inventory evidence.

Run from the repository root with the exact public commit archive as argument.
Never overwrites a checkpoint. Supplemental instrumentation remains outside the
shipping app; see the retained shipping harness and native-tool transcription.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

PUBLIC = "7947edc7d52ee483288783525b54b112c11d1581"
MANAGED = "5d4e99e5e301c8ada3a4795d826cc537a3b0ccba"
APP = "android-vinetrack"
OUT = Path("docs/reviews/evidence/android-recovery-inventory-validation-20261101")
GRADLE = Path("/tmp/vinetrack-inventory-gradle-y4m5bpse")


def git(*args):
    return subprocess.check_output(["git", *args]).decode().strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    archive_path = Path(sys.argv[1])
    assert git("rev-parse", "HEAD") == MANAGED, "Use only on the reviewed imported revision"
    subprocess.run(["git", "diff", "--exit-code", "HEAD", "--", APP, "ios", "supabase"], check=True)
    assert not (OUT / "source-manifest.json").exists(), "Checkpoint already exists; preserve it"
    entries = []
    with tarfile.open(archive_path) as archive:
        members = archive.getmembers()
        prefix = members[0].name.split("/")[0] + "/"
        archived = {m.name[len(prefix):]: m for m in members if m.isfile() and m.name.startswith(prefix + APP + "/")}
        tracked = git("ls-files", APP).splitlines()
        assert set(archived) == set(tracked), "Archive/tracked file sets differ"
        for path in tracked:
            data = Path(path).read_bytes()
            member = archived[path]
            assert data == archive.extractfile(member).read(), path
            executable = bool(Path(path).stat().st_mode & 0o111)
            assert executable == bool(member.mode & 0o111), path
            entries.append({"path": path, "sha256": digest(data), "bytes": len(data), "executable": executable})
    tree = git("rev-parse", f"HEAD:{APP}")
    assert tree == "fb088acc24288469f653b6bb98ed761121564f1d"
    assert len(entries) == 1234
    ios_hash = digest(Path("ios/VineTrack/Config.swift").read_bytes())
    assert ios_hash == "71301cf111ea1855e8c86d50dd9a2675bab62550aa09f872aae83ccf8374508b"
    OUT.mkdir(parents=True, exist_ok=True)
    jvm = OUT / "gradle"
    jvm.mkdir(exist_ok=True)
    for name in ["result.json", "gradle.log", "TEST-com.rork.vinetrack.data.auth.RecoveryStorageReportTest.xml"]:
        assert not (jvm / name).exists()
        shutil.copyfile(GRADLE / "inventory-report" / name, jvm / name)
    shutil.copyfile(GRADLE / "inventory-tests.init.gradle", jvm / "inventory-tests.init.gradle")
    manifest = {
        "publicCommit": PUBLIC, "managedImportedRevision": MANAGED,
        "githubSnapshotId": "tp93n3fea9daji4331aq1",
        "githubDeliveryId": "c83b7ba6e2c5f7144bd8d90bff20ef3f787f5e170c1cb8c77865ca2c70850cbd",
        "androidTree": tree, "sourceHashLabel": "src_" + tree[:16],
        "archiveSha256": digest(archive_path.read_bytes()),
        "exactArchiveParity": True, "fileCount": len(entries),
        "protectedIosConfigSha256": ios_hash,
        "shippingHarness": {
            "path": "scripts/fixtures/android-recovery-inventory/ShippingInventoryAcceptanceTest.kt",
            "sha256": digest(Path("scripts/fixtures/android-recovery-inventory/ShippingInventoryAcceptanceTest.kt").read_bytes()),
            "temporaryRunnerDelta": "super.newApplication(cl, CleanExitFixtureApplication::class.java.name, context) -> super.newApplication(cl, className, context)",
            "restoredBeforeNormalBuildAndPlayAttempt": True,
            "notPartOfAndroidShippingTree": True,
        },
        "entries": entries,
    }
    dest = OUT / "source-manifest.json"
    dest.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"files": len(entries), "manifest": str(dest), "sha256": digest(dest.read_bytes()), "androidTree": tree}, indent=2))


if __name__ == "__main__":
    main()

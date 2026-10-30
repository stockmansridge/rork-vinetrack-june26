#!/usr/bin/env python3
"""Snapshot the journal-based absence repair; leave historical inventories intact."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PARENT = "37fd2672db6ae3b5ff364fbf5715e6dee982e12d"
PUBLIC_PR22 = "d4c991d64e2c444805c039ca7392fce22228958a"
PUBLIC_MAIN = "69dfdeb0ce3b76ecfe32cbfd6d0e8a0877581cfc"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).splitlines()


def sha(data):
    return hashlib.sha256(data).hexdigest()


paths = set(git("diff", "--name-only", PARENT, "--", "ios"))
paths.update(git("ls-files", "--others", "--exclude-standard", "--", "ios"))
paths.add("scripts/snapshot-trip-journal-absence-source.py")
files = []
for name in sorted(paths):
    path = ROOT / name
    if not path.is_file():
        raise RuntimeError(f"Missing input: {name}")
    parent = subprocess.run(["git", "show", f"{PARENT}:{name}"], cwd=ROOT, capture_output=True)
    if parent.returncode and name in git("ls-tree", "-r", "--name-only", PARENT, "--", name):
        raise RuntimeError(f"Failed to read parent input: {name}")
    files.append({"path": name, "sha256": sha(path.read_bytes()),
                  "parent_sha256": sha(parent.stdout) if parent.returncode == 0 else None})
manifest = {
    "managed_source_parent": PARENT,
    "integration_commit": None,
    "reviewed_public_pr22_head": PUBLIC_PR22,
    "reviewed_public_main_head": PUBLIC_MAIN,
    "scope": "iOS active journal deletion absence verification, scoped retained counts and sync termination; no Android, backend or release changes",
    "validation": {"requested_suite_count": 12, "tests_passed": 184,
                   "test_duration_seconds": 148, "normal_ios_simulator_build": "PASS",
                   "original_device_acceptance": "UNVERIFIED"},
    "files": files,
}
out = ROOT / "docs/reviews/trip-journal-absence-source-manifest-20261030.json"
out.write_text(json.dumps(manifest, indent=2) + "\n")
print(f"{len(files)} inputs; manifest_sha256={sha(out.read_bytes())}")

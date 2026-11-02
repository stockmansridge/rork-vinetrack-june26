#!/usr/bin/env python3
"""Retain non-secret simulator logs and content fingerprints; never mutate Git."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/reviews/evidence/ios-tracked-spray-completion-20261102"


def save_json(name, value):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def retain_log(path, label):
    data = Path(path).read_bytes()
    # Refuse evidence publication if any protected generated value appears.
    # No configuration values are printed or copied, even on refusal.
    configs = list(Path("/tmp").glob("limsync-cache-ios-*/VineTrack/Config.swift"))
    configs.append(ROOT / "ios/VineTrack/Config.swift")
    for config in configs:
        if not config.is_file():
            continue
        for value in re.findall(rb'=\s*"([^"\n]+)"', config.read_bytes()):
            if len(value) >= 20 and value in data:
                raise SystemExit("Refusing evidence copy: generated configuration value detected")
    if re.search(rb'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}', data):
        raise SystemExit("Refusing evidence copy: JWT-shaped value detected")
    OUT.mkdir(parents=True, exist_ok=True)
    filename = label + ".log"
    (OUT / filename).write_bytes(data)
    save_json(label + "-log-receipt.json", {
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "file": filename, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
        "configuration_values_included": False,
        "scope": "Managed iOS simulator output only; not physical device or signed Release acceptance",
    })


def manifest(label):
    paths = subprocess.check_output(
        ["git", "ls-files", "-c", "-o", "--exclude-standard", "-z", "--", "ios"], cwd=ROOT
    ).decode().split("\0")
    entries = []
    for path in sorted(set(paths) - {"", "ios/VineTrack/Config.swift"}):
        file = ROOT / path
        if not file.is_file():
            continue
        data = file.read_bytes()
        blob = b"blob " + str(len(data)).encode() + b"\0" + data
        entries.append({"path": path, "bytes": len(data),
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "git_blob_sha1": hashlib.sha1(blob).hexdigest()})
    canonical = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    save_json(label + "-source-manifest.json", {
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "managed_base_sha_not_current_source": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT).decode().strip(),
        "scope": "Current tracked and unignored iOS working files; generated Config.swift excluded",
        "public_commit_for_current_source": None,
        "source_manifest_sha256": hashlib.sha256(canonical).hexdigest(),
        "file_count": len(entries), "files": entries,
    })
    print(json.dumps({"file_count": len(entries), "source_manifest_sha256": hashlib.sha256(canonical).hexdigest()}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("label")
    parser.add_argument("--log")
    parser.add_argument("--manifest", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9-]+", args.label):
        parser.error("label must use lowercase letters, numbers and hyphens")
    if args.log:
        retain_log(args.log, args.label)
    if args.manifest:
        manifest(args.label)

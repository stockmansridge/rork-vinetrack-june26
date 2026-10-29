#!/usr/bin/env python3
"""Inventory discovery, NOT an end-to-end sync validator. Standard library only.

Run in the repository checkout:
  python3 scripts/audit_sync_inventory.py --verify-inventory --output sync-audit.json
  python3 scripts/audit_sync_inventory.py --release-gate --output sync-release.json

The release gate intentionally fails until exact 3.1.8 and native 3.1.9 evidence
is recorded. Neither a source inventory nor compilation certifies device safety.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

IOS = Path("ios/VineTrack/App/NewMainTabView.swift")
ANDROID = Path("android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/PendingWrite.kt")
REGISTER = Path("docs/sync/sync-compatibility-register.json")
CALL = re.compile(r"\bawait\s+(\w+(?:\.\w+)*\.(?:sync\w*))\s*\(")
CONSTANT = re.compile(r'\bconst\s+val\s+\w+\s*=\s*"([^"\n]+)"')
ROUTE = re.compile(r'(\.from|\.rpc|\brestUrl|\brpcUrl)\s*\(\s*"([^"\n]*)"')
DYNAMIC = re.compile(r'(\.from|\.rpc|\brestUrl|\brpcUrl)\s*\(\s*(?!["\s])([A-Za-z_]\w*)')


def uncomment(text: str) -> str:
    # Preserve line count. This is intentionally lexical, not a full language parser.
    text = re.sub(r"/\*[\s\S]*?\*/", lambda m: "\n" * m.group().count("\n"), text)
    return re.sub(r"(?m)^\s*//[^\n]*", "", text)


def ios_calls(text: str) -> set[str]:
    return set(CALL.findall(uncomment(text)))


def pending_entities(text: str) -> set[str]:
    cleaned = uncomment(text)
    match = re.search(r"\bobject\s+PendingEntityType\s*\{([\s\S]*?)\n\}", cleaned)
    if not match:
        raise ValueError("PendingEntityType was not found; parser/source shape requires review")
    return set(CONSTANT.findall(match.group(1)))


def inventory(root: Path, registry: dict) -> dict:
    observed = {
        "ios_coordinator_calls": sorted(ios_calls((root / IOS).read_text(encoding="utf-8"))),
        "android_pending_entities": sorted(pending_entities((root / ANDROID).read_text(encoding="utf-8"))),
    }
    drift = {}
    for key, values in observed.items():
        approved = set(registry[key])
        drift[key] = {
            "unregistered": sorted(set(values) - approved),
            "registered_but_missing": sorted(approved - set(values)),
        }
    routes, dynamic = [], []
    for source_root in (root / "ios/VineTrack", root / "android-vinetrack/app/src/main"):
        for path in sorted(source_root.rglob("*")):
            if path.suffix not in {".swift", ".kt"} or not path.is_file():
                continue
            content = uncomment(path.read_text(encoding="utf-8"))
            relative = path.relative_to(root).as_posix()
            for regex, destination in ((ROUTE, routes), (DYNAMIC, dynamic)):
                for match in regex.finditer(content):
                    destination.append({"file": relative, "line": content.count("\n", 0, match.start()) + 1,
                                        "api": match.group(1), "value": match.group(2)})
    return {
        "schema_version": 1,
        "evidence_level": "source-inventory-only; independent queues and per-entity semantics require review",
        "reviewed_source": registry.get("reviewed_source"),
        "observed": observed,
        "drift": drift,
        "literal_routes": routes,
        "dynamic_routes_require_manual_review": dynamic,
        "independent_surfaces": registry["independent_surfaces_requiring_separate_review"],
        "release_baselines": {
            "released_318_source_verified": registry.get("released_318_source_verified", False),
            "native_319_acceptance_complete": registry.get("native_319_acceptance_complete", False),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify-inventory", action="store_true")
    parser.add_argument("--release-gate", action="store_true")
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        registry = json.loads((root / REGISTER).read_text(encoding="utf-8"))
        report = inventory(root, registry)
    except (OSError, ValueError, KeyError) as exc:
        parser.exit(2, f"Sync inventory could not be established: {exc}\n")
    payload = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
    else:
        print(payload, end="")
    has_drift = any(v["unregistered"] or v["registered_but_missing"] for v in report["drift"].values())
    if (args.verify_inventory or args.release_gate) and has_drift:
        print("FAIL: sync surface changed without a register/compatibility review")
        return 1
    if args.release_gate and not all(report["release_baselines"].values()):
        print("FAIL: exact released baseline and native acceptance evidence are not yet verified")
        return 1
    print("PASS: requested inventory checks only; not a device or data-integrity certification")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

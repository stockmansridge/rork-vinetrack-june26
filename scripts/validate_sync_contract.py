#!/usr/bin/env python3
"""Read-only structural gate: validates governance artifacts, NEVER certifies app/device sync."""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SYNC = ROOT / "docs/sync"
CONTRACT = SYNC / "CANONICAL_SYNC_CONTRACT_V1.md"
REGISTRY = SYNC / "sync-domain-contracts-v1.json"
SNAPSHOT = SYNC / "live-public-schema-snapshot-20261102.json"
TEMPLATE = SYNC / "SYNC_CHANGE_REQUEST_TEMPLATE.md"
OLD = SYNC / "sync-compatibility-register.json"

def fail(reason):
    raise ValueError(reason)

def run():
    for path in (CONTRACT, REGISTRY, SNAPSHOT, TEMPLATE, OLD, ROOT / "scripts/audit_sync_inventory.py"):
        if not path.is_file() or not path.read_text(encoding="utf-8").strip():
            fail(f"Missing/nonempty required contract file: {path.relative_to(ROOT)}")
    contracts = json.loads(REGISTRY.read_text(encoding="utf-8"))
    schema = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    prior = json.loads(OLD.read_text(encoding="utf-8"))
    if contracts.get("schema_version") != 1 or schema.get("snapshot_version") != 1:
        fail("Unsupported contract or DB schema snapshot version")
    if contracts.get("live_db_metadata") != SNAPSHOT.name or contracts.get("source_inventory") != OLD.name:
        fail("Contract registry references wrong source evidence")
    if schema.get("project_ref") != "tbafuqwruefgkbyxrxyb":
        fail("Schema snapshot has wrong project ref")
    if prior.get("released_318_source_verified") is not False or prior.get("native_319_acceptance_complete") is not False:
        fail("Existing release inventory flags require independent acceptance; do not auto-flip")
    if contracts.get("release_certified") is not False or contracts.get("contract_complete") is not False:
        fail("Governance draft cannot declare acceptance complete")
    domains = contracts.get("domains")
    if not isinstance(domains, list) or len(domains) < 25:
        fail("Domain register incomplete")
    ids = [d.get("id") for d in domains]
    if any(not isinstance(x, str) or not re.fullmatch(r"[a-z][a-z0-9_]+", x) for x in ids) or len(ids) != len(set(ids)):
        fail("Invalid/duplicate domain ID")
    allowed = {"unverified", "in_review", "verified"}
    mandatory = ("id","primary_table","description","ownership","identity_rule",
                 "merge_policy","delete_rule","dependency_rule","review_status",
                 "ios_codec","android_codec","portal_reader","server_api",
                 "released_318_compatibility","native_319_compatibility","fixture","cross_device_qa")
    for row in domains:
        for k in mandatory:
            if not isinstance(row.get(k), str) or not row[k].strip():
                fail(f"{row.get('id', '?')} missing required {k}")
        if row["review_status"] not in allowed:
            fail(f"Invalid status: {row['id']}")
        if row["review_status"] == "verified":
            if any("pending" in row[x] or "unverified" in row[x] or "not_run" in row[x] for x in
                   ("ios_codec","android_codec","portal_reader","server_api",
                    "released_318_compatibility","native_319_compatibility","fixture","cross_device_qa")):
                fail(f"{row['id']} marked verified without provenance/acceptance")
        tab = row["primary_table"]
        if tab not in ("*", "storage.objects") and tab not in schema["tables"]:
            # Cross-domain references absent from the deliberately scoped 26-table snapshot
            # are allowed only as explicitly unverified until schema snapshot is expanded.
            if row["review_status"] == "verified":
                fail(f"Verified domain has no live database metadata: {tab}")
    required = {"trip","trip_occurrence","spray_record","tank_session","tank_actual",
                "spray_job","account_vineyard_access","chemical_store","equipment",
                "pruning","yield","pin","work_tasks","entitlement"}
    if not required.issubset(ids):
        fail(f"Missing critical domain coverage: {sorted(required-set(ids))}")
    md = CONTRACT.read_text(encoding="utf-8")
    for phrase in ("3.1.8", "3.1.9", "UNKNOWN", "CONFLICT", "idempotency",
                   "server_revision", "Hard Stop", "operator-entered", "parent",
                   "CANONICAL", "release"):
        if phrase.lower() not in md.lower():
            fail(f"Required invariant not documented: {phrase}")
    for tab, fields in schema["tables"].items():
        if not isinstance(fields, list) or len(fields)==0:
            fail(f"Missing columns: {tab}")
        names = [f["column"] for f in fields]
        if len(names)!=len(set(names)):
            fail(f"Duplicate field: {tab}")
        if any(not isinstance(f.get("nullable"), bool) or not f.get("db_type") for f in fields):
            fail(f"Incomplete DB metadata: {tab}")
    print("PASS: sync governance structure, coverage, and unverified-baseline guards")
    print(f"Evidence: {len(domains)} domains; {len(schema['tables'])} tables; "
          f"{sum(map(len,schema['tables'].values()))} columns; release NOT certified")

if __name__ == "__main__":
    try:
        run()
    except (ValueError, KeyError, OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: sync contract: {exc}", file=sys.stderr)
        sys.exit(1)

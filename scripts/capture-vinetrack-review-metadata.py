#!/usr/bin/env python3
"""Read-only authorised management API metadata; NOT a schema or role restore dump."""
import json
import os
from pathlib import Path
import tempfile
import urllib.request

REF = "tbafuqwruefgkbyxrxyb"
EXPECTED = {"tables": 188, "views": 12, "functions": 759, "triggers": 180, "policies": 506}


def main() -> None:
    token = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if not token:
        raise SystemExit("Authorise the Supabase CLI token first; do not put credentials in chat or code.")
    sql = Path(__file__).with_name("vinetrack-review-catalog.sql").read_text()
    request = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{REF}/database/query",
        data=json.dumps({"query": sql, "read_only": True}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=45) as response:
        rows = json.load(response)
    if len(rows) != 1 or len(rows[0]) != 1:
        raise SystemExit("Unexpected catalog response; no restore claim can be made.")
    catalog = next(iter(rows[0].values()))
    if isinstance(catalog, str):
        catalog = json.loads(catalog)
    counts = {
        "tables": sum(row["nspname"] == "public" and row["relkind"] in ("r", "p") for row in catalog["relations"]),
        "views": sum(row["nspname"] == "public" and row["relkind"] == "v" for row in catalog["relations"]),
        "functions": sum(row["nspname"] == "public" for row in catalog["functions"]),
        "triggers": sum(row["nspname"] == "public" for row in catalog["triggers"]),
        "policies": sum(row["schemaname"] == "public" for row in catalog["policies"]),
    }
    if counts != EXPECTED or not catalog["native_auth_users_present"] or not catalog["server_version"].startswith("17."):
        raise SystemExit(f"Source catalog does not match the approved inventory: {counts}")
    output = Path(tempfile.mkdtemp(prefix="vinetrack-metadata-private.", dir="/tmp"))
    output.chmod(0o700)
    artifact = output / "source-catalog.json"
    artifact.write_text(json.dumps(catalog, sort_keys=True, indent=2))
    artifact.chmod(0o600)
    print(json.dumps({"ref": REF, "counts": counts, "version": catalog["server_version"], "native_auth": True, "metadata_artifact": str(artifact), "restore_dump": False}))


if __name__ == "__main__":
    main()

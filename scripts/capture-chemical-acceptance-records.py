#!/usr/bin/env python3
"""Read only the three owner-authorised chemical rows into private local evidence."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.error
import urllib.request
import sys

REF = "tbafuqwruefgkbyxrxyb"
IDS = ["ae9a8166-a052-41d4-af07-d7bc4de01c9a", "a135e1cf-8dc1-48ee-8998-ecc50219109e", "f0244e28-c065-4124-a48f-a19994c7f236"]


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--export-test-fixtures":
        records = json.loads(Path(sys.argv[2]).read_text())
        by_id = {row["id"]: row for row in records}
        assert set(by_id) == set(IDS)
        fixtures = []
        for identifier in IDS:
            row = dict(by_id[identifier])
            # Preserve all columns and complete chemical evidence; redact only private scope/audit identity.
            row["vineyard_id"] = "11111111-1111-4111-8111-111111111111"
            for key in ["created_by", "updated_by"]:
                if row.get(key) is not None:
                    row[key] = "22222222-2222-4222-8222-222222222222"
            assert row.get("notes") == "", "Unexpected private note: do not export into fixtures"
            fixtures.append(row)
        content = json.dumps(fixtures, ensure_ascii=False, indent=2)
        for fixture_path in ["ios/VineTrackTests/Fixtures/production_chemical_registered_uses.json", "android-vinetrack/app/src/androidTest/assets/production_chemical_registered_uses.json"]:
            destination = Path(fixture_path)
            assert destination.parent.is_dir()
            destination.write_text(content + "\n")
            print(f"Exported redacted full-record fixture: {fixture_path}; chemical data unchanged.")
        return
    if len(sys.argv) == 2:
        records = json.loads(Path(sys.argv[1]).read_text())
        for fixture_path in ["ios/VineTrackTests/Fixtures/production_chemical_registered_uses.json", "android-vinetrack/app/src/androidTest/assets/production_chemical_registered_uses.json"]:
            fixtures = json.loads(Path(fixture_path).read_text())
            by_id = {record["id"]: record for record in records}
            assert len(fixtures) == 3
            for fixture in fixtures:
                record = by_id[fixture["id"]]
                assert fixture.keys() == record.keys(), "Full REST column inventory differs"
                for key in record.keys() - {"vineyard_id", "created_by", "updated_by"}:
                    assert fixture[key] == record[key], f"Captured evidence mismatch: {fixture['id']} {key}"
            print(f"PASS: {fixture_path} exact captured uses/name/unit/defaults; synthetic vineyard only.")
        return
    token = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if not token:
        raise SystemExit("Read-only Management API access unavailable; no request attempted.")
    literals = ",".join("'" + value + "'::uuid" for value in IDS)
    query = f"select to_jsonb(s) as record from public.saved_chemicals s where id in ({literals}) order by id"
    request = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{REF}/database/query",
        data=json.dumps({"query": query, "read_only": True}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            rows = json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Read-only capture failed HTTP {error.code}; credentials and response not logged.") from None
    records = [row["record"] for row in rows]
    if {row["id"] for row in records} != set(IDS):
        raise SystemExit("Capture incomplete; all three authorised IDs required.")
    directory = Path(tempfile.mkdtemp(prefix="vinetrack-chemical-acceptance-private.", dir="/tmp"))
    directory.chmod(0o700)
    artifact = directory / "records.json"
    content = json.dumps(records, indent=2).encode()
    artifact.write_bytes(content)
    artifact.chmod(0o600)
    # Only the specifically authorised product evidence is printed, never account/audit data.
    print(json.dumps({"artifact": str(artifact), "sha256": hashlib.sha256(content).hexdigest(),
        "read_only": True, "products": [{"id": r["id"], "name": r["name"], "unit": r["unit"],
            "registered_uses": r.get("registered_uses"), "default_rates": r.get("default_rates")} for r in records]}, indent=2))


if __name__ == "__main__":
    main()

"""Record bounded source verification; does not mutate app or customer data."""
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PARENT = "092fd21d70a2015076fdc5a1f3bb49daf8ef65c4"
ANDROID = "android-vinetrack/app/src/main/java/com/rork/vinetrack/data/VineyardRepository.kt"
IOS = "ios/VineTrack/Backend/Repositories/SupabaseManagementSyncRepositories.swift"
TRIPS = "ios/VineTrack/LegacyImported/Views/Trips/TripView.swift"

def digest(data):
    return hashlib.sha256(data).hexdigest()

def previous(path):
    return subprocess.check_output(["git", "show", f"{PARENT}:{path}"], cwd=ROOT)

changes = []
for path in (ANDROID, IOS):
    before = previous(path)
    old = b'get("saved_chemicals?' if path == ANDROID else b'            let q = provider.client.from("saved_chemicals").select()'
    new = b'get("saved_chemicals_effective?' if path == ANDROID else (
        b'            // The current APPROVED catalogue is authoritative on reads only.\n'
        b'            // Keep writes, retained local work and pinned revision fences on saved_chemicals.\n'
        b'            let q = provider.client.from("saved_chemicals_effective").select()'
    )
    assert before.count(old) == 1, path
    after = (ROOT / path).read_bytes()
    assert before.replace(old, new, 1) == after, f"Unexpected source changes: {path}"
    changes.append({"path": path, "beforeSha256": digest(before), "afterSha256": digest(after)})

trip = (ROOT / TRIPS).read_bytes()
for forbidden in (b'.swipeActions', b'.onDelete', b'store.deleteTrip', b'tripToDelete', b'showDeleteConfirmation'):
    assert forbidden not in trip, forbidden
changes.append({"path": TRIPS, "beforeSha256": digest(previous(TRIPS)), "afterSha256": digest(trip)})

protected = json.loads((ROOT / "docs/reviews/evidence/pr35-hotfix/integration.json").read_text())["protectedConfiguration"]
configuration = []
for path, template_hash in protected.items():
    actual = digest((ROOT / path).read_bytes())
    expected = "a1da2e0589dbe2e6430459e36a7e32dc93c4b15c846e6bc7cccbc1499a4712e8" if path.endswith("/Config.kt") else template_hash
    assert actual == expected, f"Protected configuration differs: {path}"
    configuration.append({"path": path, "protectedTemplateSha256": template_hash, "observedSha256": actual, "matchesPreviouslyObserved": True})

receipt = {
    "pr": 36,
    "upstreamHead": "8d36a996f8d39ad3d8c27422bd63ae8aec65f779",
    "upstreamBase": "7ef10999975b18790f4940f1ac62f070a9a21d81",
    "managedParent": PARENT,
    "scope": "Exact two PR36 read-selector hunks plus authorised iOS history swipe-delete disablement",
    "changes": changes,
    "protectedConfiguration": configuration,
    "writePathsUnchanged": True,
    "historySwipeDeleteAvailable": False,
    "limitations": ["No signed-artifact/configuration equivalence established", "No live view/RLS, populated device sync, spray journey or Portal acceptance established", "Managed final commit is assigned after this receipt; hashes identify the checked source files"],
}
out = ROOT / "docs/reviews/evidence/pr36-release-gate/integration.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(receipt, indent=2) + "\n")
print(f"PASS: exact read hunks, history swipe-delete disabled, protected fingerprints unchanged; receipt: {out.relative_to(ROOT)}")

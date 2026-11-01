# iOS pending Trip: current status

2026-11-01. Incident OPEN; this is not an installed-app repair confirmation.

The supplied report says Trips=1 and failed_items=0. Those values come from separate queue and error trackers, so they do not identify the held Trip or prove server acceptance. A newer download timestamp does not establish that uploads cleared.

Source commit 43446a0ff85dac5d0a19ff9b35e2473fe765cf12 changes iOS Retry so it no longer erases the last error before requesting sync. Copy diagnostics now includes a read-only examination of persisted pending Trip stages. No record is deleted, adopted, recreated or force-started by that inspection. Android's inspected retry code already retains failed entries.

The related block-ID case repair passes a 56-test disposable PostgreSQL suite. Its live deployment was rejected because the migration connection is not authorised to replace the function owned by vinetrack_occurrence_writer. The unchanged live function hash was verified. Production permissions and function ownership were not altered.

The snapshot codec harness passed14 checks upstream. Since the imported branch checkpoint, the managed integration resolved Swift compiler complexity and passed separate normal iOS simulator and Android builds with real configuration; no synthetic CI configuration was imported. After a genuine failing-before regression, TripSyncService also stopped clearing its service-level error when Retry begins: the old error persists until successful completion. Final affected iOS model/native selection115 passed in52s, including the Retry regression; one targeted actual-entry/help/route UI journey passed in167s. Android93 JVM and202 instrumentation passes are separate surfaces. Native successes are observed tool-result records, not recovered raw success logs; counts overlap preceding selections. These results do not certify the actual pending Trip's acknowledgement, full lifecycle, original installation, signed Release build or delivery. See evidence/pr31-20261101/validation-results.json.

Fresh SELECT-only normal-role inspection confirms the connected postgres role cannot inherit or SET the function-owner role. The live definition remains b0e166d78be75c8ba770b2dccfd14256 with the old comparison; security/search path/ACL unchanged. No denied migration retry or role/ownership change. An already-authorised deployment path is still required.

The queued Trip has not been confirmed recovered. No TestFlight or Play upload has been made by this investigation. Keep the existing installations and retained storage intact. The complete source, validation and authorised-deployment handoff is in spray-start-yield-recovery-sync-20261101.md in this directory.

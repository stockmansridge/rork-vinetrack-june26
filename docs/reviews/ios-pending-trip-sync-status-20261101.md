# iOS pending Trip: current status

2026-11-01. Incident OPEN; this is not an installed-app repair confirmation.

The supplied report says Trips=1 and failed_items=0. Those values come from separate queue and error trackers, so they do not identify the held Trip or prove server acceptance. A newer download timestamp does not establish that uploads cleared.

Source commit 43446a0ff85dac5d0a19ff9b35e2473fe765cf12 changes iOS Retry so it no longer erases the last error before requesting sync. Copy diagnostics now includes a read-only examination of persisted pending Trip stages. No record is deleted, adopted, recreated or force-started by that inspection. Android's inspected retry code already retains failed entries.

The related block-ID case repair passes a 56-test disposable PostgreSQL suite. Its live deployment was rejected because the migration connection is not authorised to replace the function owned by vinetrack_occurrence_writer. The unchanged live function hash was verified. Production permissions and function ownership were not altered.

The snapshot codec harness passed 14 checks. Full mobile validation remains a separate gate: the prior iOS app build stopped at an unchanged VintageReportExport.swift expression; current native results must be checked in Actions run 41279436458. The Android CI configuration is synthetic and is not a signed managed release.

The queued Trip has not been confirmed recovered. No TestFlight or Play upload has been made by this investigation. Keep the existing installations and retained storage intact. The complete source, validation and authorised-deployment handoff is in spray-start-yield-recovery-sync-20261101.md in this directory.

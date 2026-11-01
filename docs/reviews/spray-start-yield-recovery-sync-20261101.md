# Spray start, retained Android recovery and pending iOS Trip incident

Date: 2026-11-01
Status: OPEN. Source repair under review; not a delivered or handset-accepted fix.

## Source boundary

Repository: stockmansridge/rork-vinetrack-june26.
Branch: fix/spray-start-yield-recovery-20261101.
Base inspected: 2047a0e48f2d4b9c1a0d9f1c47eccef2cc849afd.
Initial repair: 6027e11171a4bf901db4e4318e30afd2e21927ef.
Pending-Trip diagnostic follow-up: 43446a0ff85dac5d0a19ff9b35e2473fe765cf12.

Documentation commits do not change that production-code checkpoint. Reconcile this branch as a delta with newer managed/main work; never replace a newer source tree with this snapshot. No app-store upload, signing change, storage reset, forced trip ending or account adoption was performed in this investigation.

## Latest iOS observation

The supplied Sync report, generated 2026-11-01T05:32:34Z, reports Trips=1 and failed_items=0. The screen shows a later download than its last upload-cleared/full-sync timestamp.

This is not proof that a Trip was accepted, lost or definitely rejected by the server. The old report reads a cached queue count and a separate in-memory failure registry; it does not inspect the persisted Trip metadata or occurrence journal. A held stage or a stale count can therefore appear as a waiting Trip with no error. The specific queued Trip and its hold reason are not identified by the supplied report.

### Confirmed reporting defect and bounded source correction

The iOS entity Retry action cleared matching issues before requesting sync. A retry request is not an acknowledgement; removing the last error could leave a still-held Trip with an empty failure list.

The follow-up removes that pre-retry clearing. It adds a read-only pending-Trip inspection to Copy diagnostics and replaces the generic Trips fallback explanation with upload/reconciliation wording. The inspection reports fixed reason codes and counts, not record IDs, account identifiers, locations, tank quantities or raw retained values. It distinguishes the signed-in account/selected slice, write-access holds, legacy reconciliation, finalisation prerequisites, occurrence create/activation/finalisation stages, absent journal and unreadable journal.

The inspection must not create an absent journal directory, replay requests, change ownership, clear queues or modify retained work. Tests were added for these boundaries. Push completion now refreshes its pending count even when preflight fails or there is no dirty list.

This is a reporting repair, not proof that the existing queued Trip is recovered. An end-to-end check must also verify that a successful pull/reconciliation clears stale UI counts and obsolete errors. Do not treat a selected-slice miss as lost data, or clear pending metadata merely to make the UI green.

### Android comparison

The inspected AppViewModel retry entry points already preserve failed queue rows and attempt counts until the ordered replay pipeline completes. The specific iOS pre-retry error-clearing defect was not found there. This does not establish broader Android parity or original-device recovery.

## Related spray start findings

1. `create_trip_with_occurrences_v1` checks a supplied block-ID JSON array against coverage block IDs using case-sensitive JSON text membership. iOS can encode the selected UUIDs in uppercase while canonical coverage IDs are lowercase. A local PostgreSQL regression reproduces the false scope conflict and validates typed UUID equality without permitting a different block/vineyard.
2. The retained actual-tank snapshot comparison can be affected by serialization timestamp precision and an omitted classification field. The proposed source repair preserves that field and compares the persisted recipe without changing the entered actual quantities or original identities. Genuine recipe differences still fail.
3. The source delta includes larger actual-entry controls, explicit tracking-pattern selection and expandable/scrollable information presentation on the relevant iOS/Android screens. Native UI and large-text acceptance remain required.
4. Read-only server inspection found an open spray record with no linked Trip. That alone cannot establish that another device owns an active trip. No business record was force-closed or reassigned.
5. A bounded server-log query for 04:40-05:40 UTC found `OCCURRENCE_SETUP_SCOPE_CONFLICT` at 04:50:28 UTC. This is consistent with the earlier start screenshot but does not identify the later queued Trip.

## Backend deployment is blocked, not complete

The guarded SQL repair is in `sql/occurrence_setup_uuid_case_identity.sql`. It replaces only the block-membership comparison in the existing function, preserving its other logic and access controls.

Applying it through the connected migration tool failed with SQLSTATE 42501: must be owner of function create_trip_with_occurrences_v1. The function is owned by `vinetrack_occurrence_writer`. The connected postgres role does not inherit that role and does not have permission to SET ROLE to it.

The live function definition was verified unchanged after the rejected migration:

- Current definition MD5: b0e166d78be75c8ba770b2dccfd14256.
- Expected MD5 for the exact inspected narrow replacement: 41ae711b14e18de51795c5aa11f98caf.
- Existing SECURITY DEFINER owner, search path and execute ACL were not changed.

Use an already-authorised function-owner/deployment path to review and apply this repair. Do not grant new role membership/options, change the owner, drop/recreate the endpoint or bypass the denial as a workaround. Re-inspect the live function if it has changed; the hashes above describe the inspected version only. No customer records were mutated by the attempted migration.

## Android retained-data boundary

The latest supplied handset diagnostic is app 3.1.9 / code 1793509602, RETAINED_EVIDENCE, vinetrack_domain_cache, DOMAIN_YIELD_SESSION_RECOVERY_SCOPE. The inventory contains substantial populated domain and pruning stores. Empty-store or key-count tests cannot establish recovery.

The proposed Android delta handles UUID case in scope checks and adds populated-pruning verification against isolated, authenticated recovery reads. Unknown, conflicting or unverified retained work must remain held. Do not infer ownership from an email match alone. Source linkage to installed code 1793509602 and successful recovery on the original handset remain unverified.

## Validation evidence and its limits

GitHub Actions run 41279436458 checks production source 43446a0ff85dac5d0a19ff9b35e2473fe765cf12.

- Disposable local PostgreSQL authority suite: 56 tests passed, no failures. Includes mixed-case selected UUIDs, preserved request/idempotency, wrong-block/wrong-account rejection and unchanged legacy behavior. It uses fixture data, not the live project.
- Production snapshot codec harness: 14 checks passed locally and in the macOS job. This compiles the relevant production codec components; it is not a full iOS app build.
- Modified iOS source/test files passed Swift syntax parsing and git diff whitespace checks. Syntax parsing is not type checking or XCTest execution.
- The earlier full iOS job in run 41278989293 failed at the unchanged `ios/VineTrack/App/Insights/VintageReportExport.swift:13` expression with a compiler type-check time limit. Focused native XCTest acceptance was not established by that run.
- Earlier Android compile was blocked by the missing Rork-managed Config.kt. The current CI job uses an uncommitted synthetic configuration with an invalid backend URL solely for compilation and selected real-serializer JVM tests. It cannot certify a normal managed release, authentication, live integration or signing.
- At this report checkpoint, final current iOS/Android job results were not yet established. Consult that run's final job logs before citing any additional pass. Do not equate Android instrumentation compilation with executing instrumentation tests.

The Android JVM selector explicitly includes the nine classes listed in scripts/combined-recovery-spray-tests.init.gradle. It is not the entire Android test suite. The incident workflow must be reviewed/cleaned up before merging; it is branch-specific and does not publish app builds.

## Mandatory completion gates

1. Preserve and identify the existing queued Trip from on-device metadata/journal diagnostics; do not delete, duplicate or recreate it to pass a test. Prove whether it is held, stale UI, an unacknowledged create, activation, finalisation or metadata upload.
2. Apply and verify the narrow SQL repair through the authorised owner path, or document it as a remaining blocker. Old frozen requests must remain unchanged; do not rewrite operation IDs or payloads to conceal an idempotency conflict.
3. Build the combined current managed source normally on both platforms. Run the added XCTest/JVM tests and affected recovery/spray regressions. Resolve build/toolchain blockers without labelling skipped tests as passes.
4. On original installations, confirm retained actual water and chemical amounts, explicit tracking-pattern choice, readable help, one successful start, pause/resume/end as applicable, close/reopen and actual queue drain. Verify the server result and corresponding acknowledgement before reporting sync success.
5. Exercise Android recovery with populated pruning/yield/actuals and the original account, plus wrong-account and revoked-membership refusals. Preserve all retained bytes and isolation safeguards.
6. Produce exact source-to-build receipts before another human-testing candidate. Original-device recovery and the existing queued Trip remain OPEN until confirmed; do not claim an app-store or TestFlight fix from this source branch alone.

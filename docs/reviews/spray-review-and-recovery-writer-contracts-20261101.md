# Spray review and recovery writer compatibility - 2026-11-01

## Current 3.1.9 consolidation — presentation integrated, release held, 1 November 2026

PR #34 `7ff419e392ebae3dba2294dcbee876f08398de21` and the two remaining PR #33 iOS presentation files are now selectively consolidated onto managed parent `88b0bc36746e18114747c06433f28854096bfbae`. Earlier presentation exclusions below are historical. Exact import, source fingerprints and separate execution-result transcriptions are under `evidence/pr34-consolidation/`; the cumulative acceptance report contains current qualification.

Android rendered segment regression:4 cases pass after reproducing clipping and correcting equal-height single-line accessibility scrolling. Focused broader run44 pass/7 fail/0 skip; all seven occurrence-fixture failures were diagnosed to unisolated filesystem roots, corrected in tests only, then the class passed7/0/0. Preserve the broad failure; do not sum overlapping results. iOS selected actual-entry/route journey plus ownership/amounts/geometry/finalisation:88 aggregate passes. Separate Android normal and iOS simulator builds pass; fresh JVM run102 named passes. The fixed release preflight still fails with250 blockers; current normal build configuration remains fingerprint-mismatched. No candidate or store delivery.

### Active Trip management — required contract, NOT implemented or deployed

Both mobile detail screens explain read-only status when no original tracking claim exists. Device-owned controls remain restricted. This does not establish that another device is online, recover a tracking claim or confirm the fresh September24 JH Testing server state. No customer record was mutated and no new deployment was attempted.

The checked-in `006_trips_sync.sql` broad update policies and `soft_delete_trip` cannot be used as a remote-completion workaround. They are baseline source, not verification of live permissions or deployment. A safe shared Portal/iOS/Android management route requires all of the following before implementation/delivery:

- Authenticate the original actor and check current Owner/Manager membership for the exact Trip vineyard on the server; no client role assertion, Supervisor/Operator fallback or broad direct update.
- Read fresh Trip/tank/actual/occurrence/GPS/deletion/queue state. Obtain original-device pending-work reconciliation evidence; absence of locally retained work cannot be inferred from the server. If the original device is unavailable and unresolved retained work cannot be ruled out, refuse completion and retain a review hold.
- Use an explicit reviewed action/reason and idempotency key, with expected server revision/state and original identity. Lock and recheck in one transaction; stale versions, active dependencies, account changes and already-ended Trips fail closed without reopening or retimestamping.
- Require exact reconciled tank and actual-use acknowledgements before closure; never infer amounts, delete GPS, discard pending operations, replace request/record IDs, adopt ownership or mark all planned paths complete. A read-only planned path count is not coverage or geometry proof.
- Write an immutable actor/action/reason/before/after/reconciliation/version audit atomically with any approved state change. Reusing the same idempotency key returns its original result; conflicting reuse is refused.
- Share the same request/response/refusal semantics across Portal and both apps. Verify permission denial, stale/concurrent requests, lost-response retry, retained-work/tank holds and ended-Trip refusal before exposing an action.
- Obtain an already-authorised deployment path and verify live definitions/access controls without changing ownership or granting new privileges. The prior function-owner denial remains unresolved; do not retry it unchanged.

Current geometry corrections only fence lookup to the selected/Trip vineyard and use occurrence-aware Android summary counts. They do not invent or persist coordinates, infer geometry from saved path counts, or complete missing geometry. Full rendered boundary scenarios and original-phone acceptance remain open.

## Preceding managed preflight continuation — 1 November 2026

This preceding phase initially excluded unrelated review/calculator presentation files; the later consolidation above explicitly integrates them. Preserve this phase's results as historical context, not a claim of current release readiness. Its evidence is in `evidence/pr33-preflight/` and the cumulative acceptance report.

Current executed results:102 explicit JVM passes (original two catalogue failures reproduced and narrowly corrected); Android broad run236 pass/1 fail followed by2 focused passes after diagnosing a stale full-replacement-versus-sparse-note fixture; selected iOS suites57 aggregate passes. Separate normal Android and iOS simulator builds pass. Available native raw logs do not prove all required named methods; the repeatable preflight intentionally FAILS rather than infer execution. Do not sum overlapping runs or relabel the broad run green.

Real-writer corrected/shared actual history now requires exact isolated server proof, distinct from pending authored work. Unverified history, edited pending corrections and unknown/lossy evidence stay protected. All38 inspected stores have an inventory, but complete historical reproduction, detailed allowlisted chemical field/type diagnostics and the combined vineyard-switch/fresh-process/upgrade acceptance remain incomplete. Managed Config provenance is still unresolved. No candidate, upload, sourceHash/build mapping or original-phone recovery/queue-drain acceptance is claimed; incident OPEN.

## Upstream status and source (historical handoff)

Incident remains OPEN. No handset recovery, native iOS acceptance, signed release or store upload is claimed.

Repository baseline: `a50b35caae65412a949688a2d0a03b5119b718d5`.
Production/test correction: `f1a5115eb7ff15538a612817c5992d09110ca22f`.
Branch: `fix/spray-review-recovery-contracts-20261101`.
Latest reported handset: Android 3.1.9 / 1793523225. Its exact source-to-installed-binary mapping is still unverified. Do not describe it as simply the old build: its diagnostics include PR #32's multi-store reporting.

## Android: compare the validator with the real writer

The normal saved-chemical local reader uses `ignoreUnknownKeys=true`. Its custom chemical serializers preserve unsupported label wording and nested metadata instead of making them executable choices. The recovery validator used `ignoreUnknownKeys=false`, so it rejected some values which the normal writer can persist without losing information. This happens before PR #32's supplied-field preservation check.

A demonstrated example is an unresolved concentration unit such as `%`, which the normal writer preserves but the strict recovery decoder rejects. Read-only aggregate backend inspection corroborated this shape; no customer records are included in fixtures or this branch. Correction to the initial test explanation: `powdery_mildew` is a KNOWN disease target, not an unsupported token. The negative fixture now uses `synthetic_unmapped_target`, and a separate positive test protects the recognised disease target. The phone's private chemical JSON was NOT supplied, so this remains a demonstrated compatibility defect, not proof of the exact failing field on that device.

The bounded correction uses the normal chemical codec ONLY for this store, then retains `RetainedJsonFields.preserves` over every supplied field/value/type/array position. Unknown fields that would be dropped, malformed rates, missing identity, cross-account/cross-vineyard rows, invalid preferred rates and unsupported pending operations remain rejected. The strict codec for other stores is unchanged. Nothing is rewritten, deleted, adopted, marked synced or made an approved rate by this check.

RegionSettings can persist the server/iOS terminology token `AU_NZ`, whereas recovery only accepted `au_nz`. Validation now compares known tokens case-insensitively using Locale.ROOT, without rewriting bytes or accepting unknown tokens. Other regional field validation is unchanged.

The local copy-diagnostics path has no live pruning proof. `PRUNING_SERVER_CONFIRMATION_REQUIRED` for pruning and yield settings therefore does not establish corrupt records or four independent failed repairs. Original-account recovery must still perform isolated authentication, identity, current membership and read-only pruning verification before admission. Never bypass these checks to make the report green.

Tests added use real production serializers and the real SavedChemicalLocalStore/RegionSettings writers. They include 27 synthetic rich rows, unsupported-but-preserved label evidence, uppercase region tokens, lossy-content refusals and wrong-account/access refusals. They are not a copy of handset storage.

## Spray review presentation, both platforms

- Calculated water/product quantities are larger, bold and bright cyan in dark mode / blue in light mode. The name and calculated value share a line where they fit; long product names and accessibility text wrap without clipping.
- Generic orange concentration-warning components are hidden on Review Spray Mix and Calculator Review. The concentration-factor summary, product-specific validation, label information and actual-entry gates are retained.
- Calculator Review no longer displays Selected Physical Work or Actual Spray Coverage. Route admission, planning data and tracked coverage logic are unchanged.
- Weather information explicitly says start, every hour during spraying, and end; unavailable readings remain honestly unavailable. The hourly capture scheduler is not changed by this wording edit.
- Actual fields remain operator-entered; calculated quantities are never silently saved as actuals.

## iOS actual-use dependency repair

`TRIP_WAITING_FOR_ACTUAL_USE` means the final Trip upload is held by pending actual-use rows or a retained initial-mix handoff. It is not a reason to remove the Trip or reopen a completed one.

The previous actual-use RPC catch retained the row but hid its error from SyncIssueCenter. Errors now appear under Tank actuals with safe classified codes, and Copy diagnostics includes actual-use dependency counts. No recipe values, record IDs, names or raw server error bodies are added to that inspection.

An interrupted final local handoff can remain pending after the corresponding real actual record was already saved. Full/manual sync now retries only that final local handoff acknowledgement, using durable Trip/Spray records, matching owner/vineyard/recipe and the existing exact real-session/actual-evidence check. It does not create an actual, infer missing amounts or clear unmatched input. Failed persistence keeps the handoff pending.

An older upload completion now acknowledges only the unchanged submitted local revision. It cannot clear a newer actual edit. Parent-before-child upload and ended-Trip finalisation gates remain in place.

The handset report does not distinguish an RPC failure from an unmatched handoff or parent dependency. These changes address concrete code gaps and improve that distinction; they do not prove the specific pending handset Trip has cleared.

The live actual-use RPC requires p_water_volume_l with no default, while its database column explicitly permits null. The iOS request previously omitted nil water via encodeIfPresent. It now always sends that argument, preserving Not recorded as null and explicit zero as zero. This fixes a demonstrated legacy-data API contract defect without inventing quantities or relaxing new-spray entry validation. Its exact contribution to the handset pending Trip remains unverified.

## Validation boundary

Local `git diff --check` and Swift parsing passed. macOS Actions Swift parsing passed; parsing is NOT native compilation, type checking, UI verification or execution of XCTest.

Initial Actions run 41292850182 applied the exact checksum-verified patch and passed Swift parsing. Its Android job failed before compilation because setup-android's default obsolete `tools` package was unavailable. That was infrastructure, not a test pass or a production-code failure.

Replacement Actions run 41293007162 explicitly installs platform-tools and checks out the exact correction `f1a5115eb7ff15538a612817c5992d09110ca22f`. Its final result must be read before quoting pass counts. The workflow uses a synthetic, uncommitted Config.kt with no live backend access. Even a successful result cannot certify production configuration, signed packaging or actual credentials.

The explicit Gradle init script includes RecoveryWriterCompatibilityTest and the affected chemical/domain/pruning/planning/tank/rate/actual-entry suites, because the normal repository JVM test source filter does not automatically compile every new test. The emulator selection includes ChemicalRecoveryPreflightAndroidTest and DomainCacheRecoveryAndroidTest. Five new iOS handoff/revision/RPC-encoding tests require native execution by Rork.

## Rork integration and release checks

Reconcile the correction onto current managed source without reverting newer changes. Temporary patch transport and branch-specific workflows were removed after their jobs started; their exact-source validation receipts remain in Actions history. Do not import the synthetic CI Config.kt.

Complete normal iOS and Android builds. Explicitly run the new JVM tests and iOS SprayInitialTankAmountsTests, affected sync/start tests and combined populated recovery tests. Render the two review screens in light/dark mode and large text. Confirm actual entry remains before and independent of tracking-pattern selection.

For iOS exercise Trip -> Spray Record -> Tank Actual -> final ended Trip ordering, interrupted handoff replay, child upload failure visibility, retry, close/reopen and older responses arriving after newer local edits. Do not mark the original pending Trip cleared until the server and local pending evidence agree. Never fabricate actual use or reopen completed Trips.

Resolve configuration provenance as a separate release-engineering issue: identify each changed configuration input and its approved source, restore the legitimate managed configuration or document the intentional approved generation difference, then seal a fresh exact source/config/build inventory. Do not simply replace the expected hash to conceal an unexplained difference, disable the check, rotate credentials or change production settings. Do not print credentials into logs or the report.

After the combined tests and provenance checks pass, prepare in-place testing candidates using existing bundle/package IDs and signing. Android version code must exceed 1793523225 and every later uploaded version. Provide source revision, configuration provenance, version/build, artifact checksum and delivery receipt. No public release in this task.

Original-device acceptance remains essential: recover the existing Android installation, verify retained chemical/pruning/yield/tank records, reach Home and close/reopen; on iOS verify actual-use upload and final Trip completion. No clearing storage, reinstalling, deleting unknown evidence, cloud-overwriting local records or widening access.

## Expanded validation update

Run 41293007162 compiled Android production Kotlin and Java and executed 92 JVM tests: 89 passed, three failed. Native execution was skipped in that run. One failure was an incorrect assertion in the new test: it expected the recognised `powdery_mildew` token to fail strict decoding. Commit c1a8075d0bbfa613efcd95f03bf683ee8fe218ee corrects that fixture and adds a positive known-target test; production recovery code was not changed to accommodate the assertion. The two other failures are in unchanged CropSilRateRegressionTest: captured competing fixed rates expected two rows but received none; incompatible product-unit reference expected three rows but received none. They exercise the existing catalogue-rate path, not the recovery gate. Their tests and production rate-selection code have NOT been weakened, excluded or altered to obtain a green run. A comparison against baseline a50b35c and an independent native run are requested by the final-comparison workflow. Its results must be read before claiming baseline reproduction or native success. Full release readiness is not established.

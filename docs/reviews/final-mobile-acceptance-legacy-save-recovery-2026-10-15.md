# Mobile source closeout / legacy Save for Later — 15 October 2026

## PR #20 v186 Trip UTC / Growth mirror validation — LOCAL CORRECTIONS PASS; PR HEAD BLOCKED; NO MERGE OR UPLOAD

### Source and scope

- Repository `stockmansridge/rork-vinetrack-june26`, PR20 branch `fix/ios-trip-legacy-utc-growth-mirror-20261030`, exact reviewed head `8a81ade2396daca314bcf24ad962ad60c9523e33`, base `447f054100e3c09fd0b3bc7188b80901d703090c`. Read-only GitHub API verified open/unmerged at start and final check. Returned potential merge SHA is not an actual merged-source receipt and is not used as delivery provenance.
- Managed workspace starting/current HEAD `9f011341d97336b85f928a98968f865c482de648` is the source parent, NOT the corrected integration SHA. Downloaded exact head/base archives outside the project; app/unit source parity with base differs only in existing `Config.swift`, preserved. Initially applied all five PR files and confirmed parity with PR head except configuration, before adding the supplemental regressions/corrections below. No checkout/reset/manual commit/push/GitHub merge.
- Only the five PR iOS source/test paths changed, plus this report and approved plan. No Android, SQL, backend/customer-record writes, queue clearing, original-trip recreation, chemical-hold bypass, signing/version change or upload. User's reported230 canonical records/230 unique matching Pins/zero note differences/zero deletions/enforced unique index is supplied live investigation evidence, not independently queried by this validation.

### Exact execution sequence and failures

1. Exact PR `VineTrackTests/TankSessionLegacyUTCDecodeTests`: **6 passed in149s**. Original methods: `testHistoricalTimezoneLessTankDateDecodesAsUTC`, `testMicrosecondSnakeCaseUTCStillDecodes`, `testExplicitOffsetStillPreserved`, `testStrictLegacyFormatDoesNotInventUnclearDates`, `testContradictoryTankAliasesStillRejectEntireRecord`, `testLocalNumericDateEncodingRemainsCompatible`.
2. Exact PR `VineTrackTests/GrowthStageMirrorReplayTests`: **24 passed in23s**, full suite including230 mirrors/restart/no uploads/original evidence, display-name fallback with immutable author UUID, bounded delayed capture with independent save-time evidence, clean stale canonical cache, changed/ambiguous mirrors, pending canonical edits/deletes, disk failure, edit/photo/delete races, account incarnation and scope fences, independent Trip push.
3. Exact PR sixteen retained-data/compatibility/recovery selectors listed below: **165 passed in25s**.
4. Supplemental reproducing selection: `VineTrackTests/TankSessionLegacyUTCDecodeTests/testImpossibleCalendarDatesAndTrailingTextAreRejected` and `VineTrackTests/GrowthStageMirrorReplayTests/heldEvidenceConflictCannotReplaceCanonicalCacheWhenAnotherMirrorAcknowledges()`: **0 passed/2 failed**. Assertions demonstrated Foundation normalizing `2026-02-30T01:21:27.000` to March2 and a held identity-evidence conflict losing its clean cached canonical when another candidate commits. No compiler/runner failure; no original tests weakened.
5. Corrected workspace tank/Growth suites: **33 passed in81s** (source inventory8 UTC methods and25 Growth methods; tool gives aggregate, not per-suite passing-name discovery). Includes an additional mixed historical/modern `[BackendTrip]` response test preserving trip/tank IDs, tank numbers and paths, plus explicit whole-response failure with coding index/key on malformed date; valid leap years covered.
6. Same sixteen retained-data/compatibility/recovery selectors on final corrected source: **165 passed in20s**. Final combined executed result **198 passed,0 reported failures**; skipped count not supplied by the tool. This is a targeted selection, not the entire app suite. Earlier2 failing safety regressions are fixed locally, not erased from this history.
7. Exactly one separate final `runChecks({appPath:"ios"})` after tests: **simulator build PASS**. Two unrelated existing asset URL notices remain untouched. Device/Release validation and physical/interactive acceptance not performed.

Sixteen regression selectors, each prefixed `VineTrackTests/`:

```text
SyncCompatibilityTests
RetainedRecoveryDiagnosticExportTests
TripOccurrenceJournalTests
LegacySprayPairReceiptTests
SpraySaveForLaterTests
RecoveredSprayApplicationSafetyTests
StartTankCommitCoordinatorTests
SprayOccurrenceRecoveryHotfixTests
SprayTripStartAdmissionTests
SpraySavedJobActivationIntegrationTests
TankSessionLifecycleTests
MobileRequestSyncSafeguardTests
ActiveTripRouteRecoveryTests
DeviceTripOwnershipTests
VineyardWriteAuthorityTests
GrowthStageLiveDecodingTests
```

### Local corrections beyond unchanged upstream PR

- Enforce complete timestamp syntax plus Gregorian year/month/day/hour/minute/second validity before invoking Foundation, rejecting normalization and trailing text. Exact timezone-less historical forms are UTC; modern fractional Z/offset forms and local numeric cache decoding remain supported. Contradictory aliases still throw; no skipped records, default dates, remote JSON rewrites or lost decode-path reporting.
- Validate the retained original/canonical evidence match BEFORE staging a clean canonical cache replacement. Otherwise an unrelated successful candidate can commit the held candidate's staged overwrite. New mixed-batch regression checks both in-memory and durable cache, queued original, retained evidence and no remote upsert.
- Growth reconciliation still requires unique scoped positive server identity, immutable author UUID, matching substantive observation, timestamp/coordinate/photo constraints, no dirty/delete/photo/unknown canonical intent and strictly newer server cache time. Original mirror evidence is durably written before replacing visible aliases; unknown/mismatched identity remains queued with `GROWTH_PIN_IDENTITY_REVIEW`. Newer local edits and account changes retain their existing protections; no uniqueness bypass or server inserts/deletions added.
- Focused second read-only review found no further concrete must-fix in these corrections. It did not execute independent tests.

### Final corrected source SHA256 (not an invented merged commit)

```text
33b5b22bcdd0834921531a82d34f47c04121d60be691f6de5fa8e5cbd084b534 ios/VineTrack/LegacyImported/Models/Trip.swift
5ed56669596e4bc51c8c743983810b7d12425acbb145f990e8a97993c65fa882 ios/VineTrack/Backend/Sync/GrowthStageMirrorReplay.swift
096b022e0de3ba1a87265ab41749c2d82046c841a6a343b4929f2b1c1d440e89 ios/VineTrack/Backend/Sync/GrowthStageRecordSyncService.swift
4a5739f181e485595eb311342898c3507b719cc05b2a6b81bd08e8d40857e308 ios/VineTrackTests/TankSessionLegacyUTCDecodeTests.swift
7a83c024bdb6406769e3fbaf207063d67392c1ecebee1e7cf6b1b63257515cf9 ios/VineTrackTests/GrowthStageMirrorReplayTests.swift
```

`git diff --check` passed. A corrected managed commit SHA is not yet available during this turn; source hashes pin the tested bytes. The original PR head must not be described as passing these added regressions. Incorporate these corrections upstream and verify the actual merged source SHA/parity before preparing TestFlight. No TestFlight candidate was uploaded or independently marked v186-ready.

### Original-iPhone acceptance remains open

After a safe merged candidate is delivered and installed in place (never uninstall/reset/clear queues):

1. Capture build/account/vineyard and pre-sync per-entity pending counts; preserve a private retained-evidence export if available before an explicit sync.
2. Confirm Trips sync completes without incorrect-format error. Any remaining failure must retain exact local-versus-response operation/coding path, not be treated as successful empty data.
3. Confirm proven Growth mirrors resolve to existing canonical server IDs, with no duplicate inserts/deletions.230 pending entries clear only where identity is actually proven; do not infer clearance from synthetic230 coverage.
4. Retain genuinely changed/ambiguous/photo-bearing entries with review reasons and compare their original values/evidence. No forced acknowledgement of all230.
5. Confirm the original116-path/eight-block/two-tank Trip/spray, original IDs, zero completed paths if unchanged, WAL/journals/receipts and quantities remain intact. Do not Start or apply chemicals to validate sync; authorized documented chemical-rate approval remains separate.
6. List remaining pending uploads by entity separately from Growth Stages. Capture after-sync diagnostics and original phone confirmation. Incident is NOT resolved by simulator/test/build success.

## Original iPhone retained-evidence export — 29 October 2026 — 147 TESTS PASS; ORIGINAL INCIDENT UNPROVEN; NO UPLOAD

### Provenance and production evidence

- Current managed source parent `21c82de4ffd1134691b74f3f4b11a0da71f46a3d`; public main independently verified at `a0db9aa9050c86e33cf0f67640594ae37ef8522b`. Downloaded exact public archive outside project; recursive source comparison differs only in generated `ios/VineTrack/Config.swift` (preserved). Unit and UI test directories match. No checkout/reset, merge, manual commit/push or upstream replacement.
- User reports original iPhone has v185. This is user-supplied installation evidence, not independent Apple processing verification. Source project build counters are not delivery evidence. No store command, version/signing change or upload this scope.
- Read-only Supabase `fetchProjectLogs`: latest60 entries matching `/trips`, occurrence RPC and legacy pair routes are Trip GET/HEAD/OPTIONS with HTTP200 on29October. This does not identify a device, provide response bodies, establish successful client decoding, prove complete RPC absence, or establish the original Trip's server presence. No migration or customer-data writes.
- Actual failure operation/path and original-device bytes are still missing. Strict `[BackendTrip]` decoding means a malformed nested field can fail a complete response; `TankSession.id` versus historical `tank_session_id` compatibility remains a code-contract hypothesis only. No speculative lossy decoder/default/skip was added.

### Read-only export and exact future decode evidence

- Existing inspected v185 UI supports Settings → Sync Diagnostics → Copy sync diagnostics and original Trip → Start diagnostics → Share diagnostics, if a prior start diagnostic exists. It does **not** expose a full retained-store export; report/PDF/CSV exports are not forensic substitutes. No file-sharing build setting was found. Do not claim the newly added action is already on the original phone.
- New Settings → Sync Diagnostics → Export retained recovery evidence requires explicit sensitive-data confirmation, then prepares a JSON document off the main actor for the system file exporter. Copies raw `Data` as base64 plus SHA256, relative path, per-file capture/status and bundle start/end/version/build. No source decoding/re-encoding, repair, normalization, replay, sync, acknowledgement, source directory creation, or recipe approval.
- Explicit allowlist covers Trip/spray/planned tanks, actual tank envelope, start-tank commit, legacy save WAL including original embedded bytes/candidate/verified receipts, occurrence and planning journal trees, Trip/Growth/other queue metadata and pending-photo evidence. Includes malformed records and raw retained receipt evidence; no live server reads or fabricated receipts. Full journal history retained. Missing files remain `missing`, not empty success. Read/enumeration/verification errors and concurrent changes are marked; cross-file capture is explicitly sequential, not atomic.
- Excludes Keychain, auth/session stores, whole preferences, HTTP cache and separate media files. Raw allowlisted archives **can include embedded pending photographs**, GPS, operator/chemical data and records from other accounts/vineyards retained on this phone; confirmation and manifest disclose this. Share privately. This is not a complete operational backup or complete payload export of every unrelated queued entity.
- `RecoveryDecodeEvidence` writes separate append-only diagnostic files, not original operational stores. Captures only failure category, source, operation, coding path, missing key/expected type and time, never response body, free-form debug description or credentials. Instrumented local persistence, occurrence snapshot, embedded legacy WAL Trip/spray, legacy pair receipt responses, Trip fetch/exact lookup/all-accessible fetch, occurrence PATCH/RPC decoding. Errors are rethrown unchanged; no receipt, queue or checkpoint clearing. Earlier paths/bodies cannot be recreated retroactively.
- Export embeds current Sync diagnostics, the read-only issue-center report and already-retained Start diagnostic; it does not create a Start attempt. Account change prevents presenting the prepared document. No original iPhone data has been accessed from this sandbox.

### Validation and remaining gate

- Initial selected run:0 executed, compile failed because `UniformTypeIdentifiers` import was missing in the new view; fixed.
- Next selected run:65 passed/1 failed. Raw-preservation regression found a journal relative-path mismatch; replaced string-offset path derivation with canonical path-component validation. No preservation assertion weakened.
- Focused rerun:5 export tests passed in84s. Covers exact malformed Trip/spray/WAL/journal/queue/receipt bytes and hashes, unchanged source bytes/modification dates/file tree, missing directories not created, auth-store omission, symlink rejection, exact missing-key/index/source decoding evidence and omission of free-form secret-bearing debug text.
- Final broader run:147 passed in27s. Selectors under `VineTrackTests/`: `RetainedRecoveryDiagnosticExportTests`, `TripOccurrenceJournalTests`, `LegacySprayPairReceiptTests`, `SpraySaveForLaterTests`, `RecoveredSprayApplicationSafetyTests`, `GrowthStageMirrorReplayTests`, `StartTankCommitCoordinatorTests`, `SprayOccurrenceRecoveryHotfixTests`, `SprayTripStartAdmissionTests`, `SpraySavedJobActivationIntegrationTests`, `TankSessionLifecycleTests`, `TankMixPresentationTests`, `MobileRequestSyncSafeguardTests`. Aggregate supplies no skipped count. This is not the entire previous18-selector final selection.
- Simulator checks/build passed. Final review corrected a privacy disclosure: embedded pending photographs are included, despite separate media files being excluded. Final separate `runChecks({appPath:"ios"})` after that wording change also passed. Existing two unrelated asset-URL notices remain unchanged. No physical/device/Release acceptance, native UI/file-picker interaction, actual offline/restart recovery, original-trip/server receipt or GPS acceptance is claimed.
- User selected **authorized vineyard manager using documented label directions** as approval authority. Exact product/basis/water/recalculated amounts and authoritative auditable approval contract remain required. Original wrong-basis values stay untouched and the chemical hold stays active. No local review checkbox or identity/link receipt substitutes for chemical approval.
- **No TestFlight upload until production root causes are identified and tested and actual recovery evidence satisfies the gate.** Pending: original-device diagnostic text/screenshots, actual failing contract reproduction, approved corrected-recipe workflow, full online/offline/duplicate/interruption/navigation acceptance. The new export cannot be retrofitted to installed v185 without a separately authorized delivery; collect existing diagnostics first, not another speculative release.

### Final iOS source/test SHA256 manifest

```text
ea4800f8f6ca3f8af5ce0a1b5f3245d182197295a715279de86298888376124d ios/VineTrack/Backend/Sync/RecoveryDecodeEvidence.swift
ac19e3bebbffa383b06cbf55662fbc1ebf9ca8ca3def6f2b0715c5656a3afa97 ios/VineTrack/Backend/Sync/RetainedRecoveryDiagnosticExport.swift
31d37e17139b12685797f226067f87abf86a073a09ea03a39c21c78e94aeed39 ios/VineTrack/Backend/Repositories/SupabaseTripSyncRepository.swift
0f6aadb77531a819efb1ce40db187fef3a85655bea561f6b0b1de8c589f90617 ios/VineTrack/Backend/Sync/TripOccurrenceJournal.swift
b317ba797a2eb826444cc7ab9e5e6a0afe51c2d595a445fe91a2afe8d89c1a42 ios/VineTrack/LegacyImported/Repositories/LegacyStorage.swift
e522109850d76378ac555ab61d6625853700f39232b1e8fba1acdc9a6623b348 ios/VineTrack/LegacyImported/Services/LegacySpraySaveRecovery.swift
5f6e103b4ddb40f7396c21b7fa63a0353d152ad14e5208c48384b929ba11f7ff ios/VineTrack/App/SyncDiagnosticsView.swift
54d61dfb5b7ffa5bf462cd77b77434421e2e9f8db04365836d84581cba752f2d ios/VineTrackTests/RetainedRecoveryDiagnosticExportTests.swift
```

`git diff --check HEAD` passed. Android, SQL/schema, original operational data, approval holds and release configuration unchanged; `.rork/history` changes are managed state and were not edited by this work.

## PR #19 Growth pin conflicts / original spray safety — 29 October 2026 — SIMULATOR PASS; FINAL TEST EXECUTION BLOCKED; NO UPLOAD

### Provenance and delivery boundary

- Starting/current managed source parent at final inspection: `c8beaa42ba13161116facaafb211cf44037c0333`; this is not the integration commit. Public latest main verified at `1cece99e3ced076da7d96d39fbe4d2434dafcc34`. Exact archive comparison found only local `ios/VineTrack/Config.swift` differed among upstream Swift files; retained local configuration. PR18 recovery was already present, not replaced with an older checkout.
- Draft PR #19 branch `hotfix/ios-growth-pin-conflict-20261029`, head `2cf9544780578da7ac64394d8ff44cd495393046`, base main above: open, draft, unmerged; all four changed files reviewed and adapted atop current source. No GitHub merge, checkout/reset, manual commit or push. Final source differs intentionally from the draft through additional preservation/safety guards.
- Existing Apple build **3.1.9 (184)** independently confirmed **VALID**, not expired, **IN_BETA_TESTING**, linked to existing Internal Testing group `1a8d95a6-44ec-47ac-8754-47a0a283582e`. Build `31ee7e54-c9be-4c4a-a788-6b58cbd7f1d4`, app6761143377, bundle `app.rork.nt0v48tayl7v8noxcfe74`, team8Y879855VK. This supersedes the pending184 checkpoint below. **No new upload or signed Release validation this scope;184 predates these changes.**
- Eleven iOS source/test files changed; Android, SQL/schema/backend, chemical originals, calculator, prices, configuration, release version/signing/project settings untouched. No live customer records inspected or modified.

### Conflict resolution and preservation

- Root cause: generated mirror UUID conflicts with an existing active row for the same pin (`uq_growth_stage_records_pin_id_active`,23505). Production positive lookup is explicitly vineyard/pin scoped in80-pin chunks, never capped vineyard-wide absence inference.
- Alias only a uniquely owned, provably unchanged historical mirror. Match observation/stage, notes, photos, timestamps, owner and historical variety/operator/block/row/side/location evidence. Preserve the full original snapshot and canonical alias durably under `vinetrack_growth_mirror_identity_evidence_v1` before canonical collection/metadata acknowledgement. Corrupt archive load fails closed.
- Edited, ambiguous, unknown-owner or dirty/deleted/photo-pending canonical collisions remain queued and held without remote upsert/delete. Exact persistent permanently-rejected snapshots suppress repeat uploads across restart; deliberate changes can retry. Pull does not consume unsent upserts/photos/unknown outcomes. Old upload acknowledgement cannot clear a newer edit.
- Protect edits/deletes/photos during lookup, account incarnation/authority/selection changes across pull, photo upload/reference/acknowledgement, upsert and linked delete. A scope-invalid upsert aborts later phases rather than switching accounts mid-operation. Ordinary independent failures may still allow unrelated photo/delete work.
- Fix final-review photo deadlock: a new or same-ID observation with a pending photo may upsert before attachment sync; different-ID alias with pending photo remains held. Trips already run before Growth on Home, and Growth failures do not gate Trip operations. Terminal retained-observation message is attention/failure, never false success or endless syncing.

### Original spray and chemical hold

- Start Trip directly enters recovery/review; expose classified start-stage/code/technical diagnostics for sharing. Saved review shows unchanged raw mL/g and exact L/kg equivalents; per100L and perha remain separate recorded fields/bases, never substituted.
- `RECOVERED_MIX_QUANTITY_LABEL_UNVERIFIED` blocks recovered orphan mix application before activation/journal side effects and before a new tank operation. Reviewed identity/link receipt is not label/quantity approval. No authoritative exact-recipe quantity/applicable-label verification contract is available, so do not silently authorize application.
- Final-review correction also blocks interrupted tank recovery when an actual is already durable but the operation is not established. Retain that actual, source trip and frozen journal byte-equivalent; do not erase evidence or rewrite originals to force a start.
- Preserve original29October1:07pm trip,116planned/0completed/eightblocks, two saved tanks, SPRAY.SEED/Spotlight Plus, original trip/spray/occurrence/operation IDs, equipment/snapshots, WAL and occurrence journal. Synthetic fixtures are not proof of those customer records or chemical correctness.

### Executed tests, intermediate failures and build

- Draft edit-during-lookup reproduction: **0 passed/1 assertion failure**, `GrowthStageMirrorReplayTests/editDuringLookupMustSurviveAndStayQueued()`, original ID disappeared after a newer note. Corrected production race; no weakening of preservation assertions.
- Intermediate selection: **25 passed in147s** (Growth mirror, recovered spray safety, tank commit). Expanded focused selection: **194 passed in145s** before final-review corrections. Includes six PR19 matcher regressions and synthetic230 canonical aliases with zero remote writes, full archive/restart, edited/ambiguous conflicts, account roundtrip, disk failures, Trip independence and original recovery/receipt/tank regressions.
- After final-review photo/scope/partial-tank corrections, **31 passed in94s** for `VineTrackTests/GrowthStageMirrorReplayTests` and `VineTrackTests/StartTankCommitCoordinatorTests`. This covers the new pending-photo upsert, pull/photo account-roundtrip and partial-actual recovery hold. Aggregate tool supplied no skipped count.
- Added one further combined scope-change regression for aborting later phases and retaining delete acknowledgements, plus an explicit post-reconciliation scope check. **Final expanded run reported0 passed/0 failed**: log confirms `Test Build Succeeded`,52.824567s, then ends at `Syncing test products to simulator...`. No compiler error or assertion result. Warnings are not the stopping cause. Test execution is **unknown/incomplete**, not a regression pass. No unchanged automatic retry. Latest combined scope/deletion regression is compiled but unexecuted; earlier194/31 results are intermediate, not final-source acceptance.
- Final requested selectors, each under `VineTrackTests/`: `GrowthStageMirrorReplayTests`, `RecoveredSprayApplicationSafetyTests`, `MobileRequestSyncSafeguardTests`, `LinkedPinGrowthDeletionWorkflowTests`, `PinPhotoWorkflowTests`, `GrowthStageVarietyParityTests`, `SyncQueueRegressionTests`, `SyncStatusTimestampTests`, `SprayOccurrenceRecoveryHotfixTests`, `TripOccurrenceJournalTests`, `SpraySaveForLaterTests`, `LegacySprayPairReceiptTests`, `SprayTripStartAdmissionTests`, `SpraySavedJobActivationIntegrationTests`, `StartTankCommitCoordinatorTests`, `TankSessionLifecycleTests`, `TankMixPresentationTests`, `SprayProgramRound2Tests`.
- Exactly **one separate final `runChecks({appPath:"ios"})` PASS**, simulator build succeeded. No device/Release build validation, interactive simulator navigation, physical-device/GPS or live-server acceptance. Existing unrelated UI failure remains open/not rerun. Two unchanged storage-asset notices out of scope. Whitespace validation passes including managed staged changes.

### Final source SHA256 manifest

```text
2494a82c06d5c444c7a6a10ffff5397b29f9eb2b85dc8c4e41342a1ece803dd5 ios/VineTrack/Backend/Repositories/GrowthStageRecordSyncRepositoryProtocol.swift
de430ac8ec1734405a39db1d731a5a547b783a27c6c295761a14940f8c853e21 ios/VineTrack/Backend/Repositories/SupabaseGrowthStageRecordSyncRepository.swift
4fa045de0871e1b08142fc1a4352569ca5083f3903325e64ba6decd475c1b85f ios/VineTrack/Backend/Sync/GrowthStageMirrorReplay.swift
26b0b879ba01fe82141a210bc8c5971b91637c1b1eb775a39f7f5cc62a6b76fa ios/VineTrack/Backend/Sync/GrowthStageRecordSyncService.swift
d05f59346ca3f66ca0c364744f7518db41f885391e21f5ef2f7bd69dee2150a9 ios/VineTrackTests/GrowthStageMirrorReplayTests.swift
a2ef2bddc1548063fcba8808f942e7bb5083b8445ce01169a2c0c1ac7b16aa66 ios/VineTrack/LegacyImported/Services/RecoveredSprayApplicationSafety.swift
5f4c2cccbee3d68cdb6b0399c6ae1770d50990cf7fd23951860647dfc3269006 ios/VineTrackTests/RecoveredSprayApplicationSafetyTests.swift
2a9419a0aed2397dd54632d330cdd15fdd12c7bf75045b3e673c40a9b005c951 ios/VineTrack/LegacyImported/Services/TripTrackingService.swift
8cfc64ab3729a3eed26b7c8d77feebd06b32d2dfedec1c318536849b16a2983c ios/VineTrack/LegacyImported/Views/Trips/TripDetailView.swift
721d8e26bc308fa3cc2668c0a88180b925f070bf0fcd702aab022ff07f873143 ios/VineTrack/LegacyImported/Services/StartTankCommitCoordinator.swift
0681436f0c57c577b7ac9cdafd96dce191d7e7de352bfb727524148d0fe8005c ios/VineTrackTests/StartTankCommitCoordinatorTests.swift
```

### Acceptance still required

- Rerun the final expanded test selection only with explicit authorization after the transfer failure; do not call the source fully green yet.
- Actual230 conflicts must each meet positive evidence rules; the synthetic230 pass does not establish all actual230 qualify. Preserve nonqualifying observations for review.
- On the original iPhone only, retain installation/storage and inspect original queued trip, both saved tanks, IDs, WAL/journal and actual link receipts. **Do not apply chemicals while exact original quantities, units and applicable label directions are unverified.** This supersedes historical start instructions below. Application remains intentionally held; live receipt recovery and GPS acceptance remain open.

## PR #18 verified original server spray — 29 October 2026 — HISTORICAL135 TESTS GREEN; SIMULATOR PASS; RELEASE184 NOW CONFIRMED VALID/INTERNAL

### Source provenance and bounded reconciliation

- Starting managed HEAD/source parent **`8a0fea46e61e39f438a5186473c7388504bfbe76`**. Public branch `hotfix/ios-verified-orphan-spray-recovery-20261029` and PR #18 head independently verified before and after integration at **`d6dc03b4082f4cd55453ec862702801323bb8e35`**; base `5edff60f755376b124f7d42922b990c1f844209e`, 24 commits, seven changed files. PR remains open/unmerged.
- Reviewed all seven PR-changed files before compiling. Applied their exact-context source deltas atop the newer workspace using retained `scripts/reconcile-vinetrack-pr18.py`, not an older branch checkout or ancestry merge. No manual commit/push/reset/cherry-pick. The external SHA is reviewed provenance, not a claim that the final native source is byte-identical to it.
- Newer calculator (#11), initial subscription verification (#17), prior original-occurrence/WAL/receipt protections and access enforcement retained. Native changes confined to eight iOS files: the seven reviewed PR files plus directly related `SprayRecordSyncService.swift` safety correction. Android, SQL/migrations, calculator and release project settings untouched; no live customer records read or changed during validation.

### Recovery and additional corrections beyond the PR

- Atomic operational-trip link updates provenance and payload together. Discovery requires the authenticated owner, vineyard, absolute timestamp difference under60seconds, exact block set and valid original saved tanks. Refuses ambiguous matches and active/completed/progressed trips. No replacement spray/trip or new occurrence/operation identities.
- Locate Original Spray → Review Saved Tank Mix → explicit “I have reviewed the saved tanks” → Confirm Saved Mix & Start Trip. Dismissing the review is not acknowledgement. Re-fetch and compare the full normalized snapshot before installation. Concise mutually exclusive guidance; longer explanation behind information control.
- Review displays both tanks and raw recorded quantities/base units, both rate fields and recorded rate basis. Spotlight Plus per100L versus perha warning is explicit; SPRAY.SEED and every saved amount remain unchanged. No conversions/recalculation and **no label-compliance approval**.
- Added durable recovered-orphan provenance and exact-link acceptance receipt. Pending repairs hold ordinary spray upsert/delete/bootstrap so no generic sync bypass or recreation of a missing original server row is possible. Stale unlinked/same-link/deleted snapshots cannot discard recovered local evidence, including the off-selected-vineyard disk slice.
- Retain original queued trip/time through parent activation and interrupted link acceptance, including remote trip pulls/deletes and restart. Fetch exact accepted parent, not a capped vineyard list. Persist exact conditional spray-link receipt before publishing Active Trip/GPS. Recheck actor/scope/unchanged recipe across asynchronous work; recovered historical dates are not reset to activation time.
- Linked receipts validate owner/vineyard/tanks/nondeleted/unfinished state; recovered records still require strict original evidence. Ordinary historically linked starts remain compatible with absent block IDs; this does not loosen orphan discovery. Explicit `hasVerifiedSavedTripLink` distinguishes operational/WAL evidence from legacy cached nonnil UUIDs, retaining legitimate unlinked-spray completion behavior.
- Preserve richer local tanks, chemicals, equipment, calculation snapshots, WAL/journal and queued intents. No forced WAL rewrite/deletion or receipt fabrication. New provenance fields decode false for old caches.

### Executed validation and failures

- New active/completed matcher assertions reproduced the PR defect: **0 passed/1 failed** before correction. Intermediate recovery/journal selection **48 passed in138s**.
- Broad focused run **134 passed/1 failed**: existing `SprayProgramRound2Tests/unlinkedCompletionThenPersistedOrdinaryEditKeepsNullTrip()` caught overbroad link preservation. Corrected production provenance logic; did not weaken the legitimate-null regression. Subsequent run **135 passed in86s**; final unchanged-source run **135 passed in56s**. Aggregate results supplied no skipped count.
- Final selectors, each under `VineTrackTests/`: `SprayOccurrenceRecoveryHotfixTests`, `TripOccurrenceJournalTests`, `SpraySaveForLaterTests`, `LegacySprayPairReceiptTests`, `SprayTripStartAdmissionTests`, `SpraySavedJobActivationIntegrationTests`, `StartTankCommitCoordinatorTests`, `TankSessionLifecycleTests`, `TankMixPresentationTests`, `SprayProgramRound2Tests`.
- Includes all five PR18 methods: `testOperationalTripLinkUpdatesProvenanceAndServerPayloadTogether`, `testVerifiedOrphanRequiresSameOwnerVineyardMinuteBlocksAndValidTanks`, `testStaleServerSnapshotCannotClearVerifiedRecoveredTripLink`, `testExactOrphanServerSnapshotRestoresOriginalTwoTankMixWithoutNewTrip`, `testOriginalWalRepairsFalseTripLinkWithoutChangingFrozenRecipeOrTrip`.
- Expanded synthetic fixture: **116 planned paths, eight blocks, two tanks**, Spotlight Plus/SPRAY.SEED, owner/vineyard/read-only refusal, disk reload, interrupted active-parent pull/delete, stale same-link retention, edit/delete hold, ordinary sync no insert/write/delete, dirty-intent retention, durable exact-link receipt and deleted-receipt refusal. These are production-code/transport-probe regressions, not authenticated original-customer acceptance.
- Exactly **one separate iOS `runChecks` PASS: simulator build succeeded**. No interactive simulator navigation or physical-device checks. Historical unrelated six-journey UI failure remains open and was not rerun. No Android or unrelated suites. Two unchanged storage-asset notices out of scope. `git diff --check HEAD` PASS.

### Signed delivery checkpoint

- Existing app confirmed (`created:false`): ASC **6761143377**, bundle **`app.rork.nt0v48tayl7v8noxcfe74`**, team **`8Y879855VK`**, version **3.1.9**. Existing distribution certificate ready; capabilities synchronized with no changes.
- Apple build183 now independently **VALID**, not expired, nonexempt encryption false; beta detail **IN_BETA_TESTING**, relationship to existing `Internal Testing` group **`1a8d95a6-44ec-47ac-8754-47a0a283582e`** confirmed. This supersedes the pending183 checkpoint below; it is not proof of a handset install.
- Exact all-state build184 lookup returned no build; upload lookup for3.1.9/184/IOS returned zero records. Select next available **184**, explicitly overriding historical local139 in the managed signed Release pipeline, same app/team/version. Managed signed production Release build/upload **SUCCEEDED on the first attempt** as **3.1.9 (184)**. Submission **`571b4442-1af7-4547-9270-88ebc0fadb2e`**, `currentBuildStep:complete`, no error, correct `appPath:ios`/`framework:swift`/bundle/team/version/build. Publish status reports pinned archive source `supplied-snapshot`, Xcode27.1. This is the signed Release/IPA pipeline, not the earlier simulator artifact; no local IPA download/independent binary inspection. No public review/release.
- Independent Apple upload receipt **`31ee7e54-c9be-4c4a-a788-6b58cbd7f1d4`**, version3.1.9/build184/IOS, uploaded **2026-10-29T06:41:06Z** (returned `2026-10-28T23:41:06-07:00`). Bounded50s wait returned **pending**, discovery phase, upload **PROCESSING**, not yet visible as a build. Exit7 is pending, not a failed build. Stopped processing polls after this result; no duplicate upload.
- **Superseded by PR19 checkpoint above:**184 is now independently VALID, not expired, IN_BETA_TESTING and linked to the existing Internal Testing group. No duplicate upload. Original-iPhone install/acceptance remains open;184 does not include PR19/current safety changes.

### Eight-file source/test SHA256 manifest before signed delivery

```text
cd2303ad819bd3d7e0c51407820f903e2c308ba3082e55ecca37a0ffae75c14b ios/VineTrack/App/SprayProgram/SprayCompletionResolver.swift
b2fcaae09e090b46f27be08050d5a63aab4f5d21ec2014ade6c4c808014656e5 ios/VineTrack/Backend/Repositories/SupabaseSprayRecordSyncRepository.swift
d204df582cc450eb3ac3c86287020787b0b45950e20fb8887e7f3adc8038450b ios/VineTrack/Backend/Sync/SprayRecordSyncService.swift
7cb988d37a9a4977453406ec2d2de5d1e52c11960498eb930b4477e655b7356c ios/VineTrack/LegacyImported/Models/SprayRecord.swift
85d175e88ea54873ff5d6389889cfdf6392fb2a5c76d1d2a2511184d31038892 ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift
093134c361597a9e7ee10cc9b4af8c6cbff357b5961591911e11b87ca94e3c62 ios/VineTrack/LegacyImported/Services/TripTrackingService.swift
f62a0b4c16b9085d998948c45f5f9a6969c38fc833f78f2d9acf9a80cb7cb9f1 ios/VineTrack/LegacyImported/Views/Trips/TripDetailView.swift
29eef17edd58cc3d4522ae242c94ec47ac0055282dcc64f0730027670d8e926a ios/VineTrackTests/SprayOccurrenceRecoveryHotfixTests.swift
```

### Original iPhone acceptance remains open

Install in place over the retained existing install, **never uninstall, clear data or delete/recreate the trip**. Same account/vineyard: open **29 October2026, 1:07pm**, verify **Queued,116planned/0completed/eightblocks**. Start Trip → Locate Original Spray → Review Saved Tank Mix; check both original tanks, unchanged quantities/chemicals/equipment/snapshots, Spotlight Plus basis warning and SPRAY.SEED. Explicitly acknowledge review and Confirm Saved Mix & Start Trip. Confirm the same original trip/spray/occurrence/operation IDs, exact accepted parent/link receipts, Active Trip, retained offline evidence and real GPS. On any mismatch/ambiguity/receipt failure, stop and retain evidence; do not create a replacement. Synthetic tests and signed builds cannot close this physical/live-data requirement.

## PR #15 original queued spray / TestFlight checkpoint — 29 October 2026 — 182 TESTS GREEN; SIGNED BUILD183 UPLOADED; APPLE PROCESSING PENDING

### Verified source and reconciliation

- Starting managed main HEAD: `d595dad4364129f1f95f749237f02e0abc0d111f`, containing the preceding #11/#16/#17 integration. No checkout, reset, cherry-pick, manual commit, push or GitHub merge.
- Public hotfix branch `hotfix/ios-occurrence-retry-and-access-20261029` and PR #15 head both verified before and after integration as **`94db356c9379a26264b0239bf7c90544f90064d9`**. PR remains open/unmerged; base `12dcb10e4724852c21af5f840be293d3a390a882`, 17 commits. Required head commit repairs a historical title string; its full source archive was downloaded at that exact SHA, tree `ebca955c3b02adf2e02539377958845670396f7a`. Its correct title string was already present in newer local source.
- This is a source-delta integration atop newer managed main, **not a Git ancestry merge or byte-identical branch checkout**. The retained helper `scripts/reconcile-vinetrack-pr15.py` validated/applied five exact-context file deltas atomically after review. Tracking and Trip Details overlapped #12/#16 and were reconciled manually, retaining newer failure callbacks, receipt gates and historical duplicate-scan protections.
- Start Trip plus help and original-plan confirmation for eligible never-started occurrence sprays; Not started status replaces misleading elapsed duration. Queued deletion remains protected; no original identity or queued evidence is removed. Existing active-trip navigation and Spray Trip title retained.
- Missing recipe restoration uses only the immutable completed local WAL with exact actor, vineyard, trip and coverage. Session rotation is allowed only for the same actor. Different linked recipes are never overwritten. Write authority is checked before durable restoration, and publication follows disk save.
- Retry clears only the held flag of the original exact create/activate pair after authenticated, exact trip-ID/vineyard lookup establishes absence. The PR's capped vineyard-list absence inference was replaced with a scoped exact query; existing remote trips still require normal receipt recovery. History entries, operation IDs, original start metadata, acknowledged coverage and pending requests are retained. Added authority/history/body checks fail closed. Concurrent saved starts are blocked through completion; stale local trip snapshots and cross-vineyard recipes are rejected.
- PR paywall entry rechecks existing current customer info and forces the existing combined server gate before showing products. Preserved the newer #17 initial force-current fetch, checking route and stale-identity fences unchanged. No new subscription products, purchase/restore automation or permission bypass.
- The PR's SQL276 ownership/membership migration delta is **excluded** per scope; no SQL, backend, schema, customer records, Android or calculator files changed. Source comments describing deployment are not independent proof of the live backend.

### Executed focused validation

- First recovery/journal selection: **42 passed, 1 failed**. The new disk-reload assertion used fractional-second fixture dates against the existing whole-second cache codec. Corrected only the fixture to whole-second event dates; no persistence codec or production timestamp change.
- Final requested focused `swiftTest`: **182 passed in 229s**; aggregate tool returned no skipped count. Selectors (each prefixed `VineTrackTests/`): `SprayOccurrenceRecoveryHotfixTests`, `TripOccurrenceJournalTests`, `SpraySaveForLaterTests`, `LegacySprayPairReceiptTests`, `SprayTripStartAdmissionTests`, `SpraySavedJobActivationIntegrationTests`, `StartTankCommitCoordinatorTests`, `TankSessionLifecycleTests`, `TankMixPresentationTests`, `SubscriptionInitialVerificationTests`, `EntitlementDecisionTests`, `EntitlementAccessRegressionTests`, `ReadOnlyEntitlementContractTests`.
- Extended restoration fixture asserts **116 frozen planned paths**, original coverage/recipe/tank IDs, unchanged WAL, actor mismatch refusal, same-actor session rotation, read-only refusal and subsequent authorised restoration, repeated restoration without duplicates, plus disk reload. Other imported tests cover different-recipe refusal, original never-started eligibility, missing-store callback completion, same original held requests and mismatched coverage retention. Concurrent recovery taps are rejected. These are synthetic production-code tests, **not original-handset or authenticated-server recovery**.
- Separate final `runChecks({appPath: "ios"})`: **PASS, simulator build succeeded**. No Android build/tests or unrelated calculator/UI suites. Two existing asset URL notices unchanged. `git diff --check HEAD` PASS before release.
- Previous six-journey calculator UI runner failure remains historical/open; not retried or converted to a pass. No simulator navigation, live customer entitlement/purchase, physical GPS or original-iPhone checks performed in this scope.

### Release preparation and remaining delivery

- Existing Apple app confirmed: ASC `6761143377`, bundle `app.rork.nt0v48tayl7v8noxcfe74`, team `8Y879855VK`, marketing version **3.1.9**. Existing distribution certificate ready; capabilities synchronized with **no changes**. `ensureApp` found the existing app (`created: false`).
- Apple latest uploads showed **182 VALID**. Exact all-processing-state lookup for **3.1.9 (183)** returned no build. Request **183** explicitly via managed signing/upload; project file's historical139 is not evidence of the requested IPA version. Retain existing signing and bundle identity; final binary version must be confirmed by release/Apple results.
- Existing `Internal Testing` group `1a8d95a6-44ec-47ac-8754-47a0a283582e` has access to all builds. No replacement group or new testers created. Managed signed Release build/upload **SUCCEEDED** on the first attempt as **3.1.9 (183)**, same bundle/team. `submitBuild` returned `status: ok`, submission **`f6143a90-2d51-4e63-a636-d3869f5fced0`**, build183 uploaded to App Store Connect. This is the supported signed Release/IPA pipeline, not the earlier simulator build. No separate local IPA download or binary inspection was performed.
- Persisted publish status verified selected `appPath: ios`, `framework: swift`, `currentBuildStep: complete`, correct app/version/bundle/build183, no error, archive source `supplied-snapshot`, Xcode27.1. The managed submission identifies the pinned compiled/uploaded snapshot; local parent remains `d595dad…` plus the eight-file manifest rather than falsely claiming the external hotfix commit is a local ancestor.
- Independent Apple receipt: upload **`17077250-d5e8-483e-82d8-e0d964636bd1`**, **3.1.9 (183), IOS**, uploaded **2026-10-29T05:15:19Z** (Apple returned `2026-10-28T22:15:19-07:00`), state **PROCESSING**. Initial exact build lookup was empty while Apple's upload record was being discovered. A bounded50s wait confirmed processing; after the interrupted connection was resumed, one further bounded50s check still reported `pending`, phase `discovery`, upload PROCESSING/not yet visible as a build. Neither pending exit7 is a build failure. No duplicate build/upload or processing polls after the final pending result.
- **Not yet confirmed:** terminal Apple VALID processing, TestFlight install availability or final build-to-internal-group relationship. Backend automatic invite handling is retained; the existing all-build internal group is configured but this alone is not availability proof. No public App Store submission, review request or store release.
- Next-message resume command: `asc builds wait --app 6761143377 --build-number 183 --version 3.1.9 --platform IOS --fail-on-invalid --poll-interval 10s --report-pending --timeout 50s`. After VALID, inspect the build's beta detail/group relationship before claiming internal availability; do not upload again.
- Before native release, recursive local iOS source digest: `bfecb0ab40a9efbd9e6ccd42a8283ca7ba62cb308181d0ba38fe6cdd74b7c43d` (sorted iOS paths plus bytes; excludes build/cache directories). Managed publish will pin its own source snapshot; current HEAD remains the source parent, not a commit of this turn's changes.

### Eight-file native/test SHA256 manifest before release

```text
c02f9192f4a4c17470a3e5afdc0e6daad083ca7f30d21d160288d4c7312ade16 ios/VineTrack/Backend/Repositories/SupabaseTripSyncRepository.swift
00a58e1a0e9e6b13a6b92f5e097b0c6ba80ffa1d751ca814d1725f0aa08dd049 ios/VineTrack/Backend/Subscription/PaywallView.swift
628ed8281aff658c676c58313b7ec3d5e44b18e879f78453ba01db0767ff43e2 ios/VineTrack/Backend/Sync/TripOccurrenceJournal.swift
c57d282fe536ee60628881f661275d77198efdc4d946763133fb60500d2bab10 ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift
902da3bad22095e959e1006d9cf47c4b701577d1bf5ad493ac582ed568a3a0d0 ios/VineTrack/LegacyImported/Services/TripTrackingService.swift
974b989ab8dea54d9e7067856603d49a3a197ab338842d9bde5e3801afea3f90 ios/VineTrack/LegacyImported/Views/Trips/TripDetailView.swift
2cc0abc1bcbe87675f9d341331d7e206d0218c5607e8af39f4bad7efee836ffe ios/VineTrackTests/SprayOccurrenceRecoveryHotfixTests.swift
39a5ecb34a0c401f0992d5493f9a6574f6aeeede66807e54850b1ff7815e3407 ios/VineTrackTests/TripOccurrenceJournalTests.swift
```

### Original iPhone acceptance remains mandatory

Install the TestFlight update **over build182**, never uninstall, clear storage, delete or recreate the original spray. On the same account/vineyard, open the **29 October 2026, 1:07 pm** original queued spray; verify **116 planned, zero completed, 0m**, Start Trip/help and retained tank recipe. Start once while online, then confirm the same trip/recipe/occurrence IDs and server-confirmed original operations, Active Trip and tank availability. If held, preserve the error/evidence; never bypass receipts or start a replacement. Only the original handset can establish that these particular saved records survived and recovered.

## Latest main / PR #11, #16, #17 reconciliation — 29 October 2026 — BUILDS AND FOCUSED LOGIC GREEN; iOS UI RUN INCOMPLETE; ORIGINAL HANDSET RECOVERY OPEN

### Exact provenance and integration method

- Local branch remains `main`; current managed HEAD/source parent at final inspection is **`38a33fb81c81ab58fafe11a04116a2841ee09344`**, the preceding #12 emergency checkpoint, NOT a commit containing this integration. The final managed integration commit does not exist yet at inspection; no manual commit/push was attempted. The 44-file SHA256 manifest below identifies this turn's native/test/runner source.
- Public refs were queried before integration and rechecked after final builds, unchanged: main **`12dcb10e4724852c21af5f840be293d3a390a882`**; #11 **`017ae7b23eb7fe82bb76a69765214f37deb38167`**; #12 **`7060f992a90e1225eaa2eb42700ad626923f3fe7`**; #16 **`4cfda28e908c4a87ccf96ef5f22c2657a02b51ee`**; #17 **`c794e4c2ab43d8dee9b1f65a1f02ca38e16b5810`**.
- Downloaded main's exact archive and the reviewed PR diffs/metadata over HTTPS; no `git fetch`, checkout, reset, cherry-pick or GitHub merge. Local origin is the managed Rork router. Comparing native source with that main archive found only local generated configuration differences (`Config.swift`, Android configuration/environment); functional native source already matched main before these edits. Those local files were retained.
- #11 base `93fe2521f624c1d676b5aa88d71192a29a5dfcc6`; #16 and #17 base `12dcb10e4724852c21af5f840be293d3a390a882`. All three were open/unmerged when reviewed. All three diffs passed a dry apply check. The retained exact-context helper applied 27 reviewed #11 file deltas; #16/#17 were integrated surgically into current source. PR #12's newer exact-parent legacy admission and read-only duplicate scan were retained, not duplicated or replaced.

### Semantic reconciliation, not just a clean textual apply

- Calculator: compact product/rate controls with See details, Label and Product Page actions; separate Per ha and Per 100 L label options; neutral minimum/midpoint/maximum range choices. Application remains available and requires deliberate operation confirmation on Program as well as One-off starts. Existing explicit Continue progression remains; selection does not automatically close the current card. Reviewed pass-profile wording is `2 Row`.
- New Banded area-based lines default to treated area with a visible whole-block override. Per-100-L products remain volume-based. Historical saved applications do not receive the new Banded default, including Android direct non-template job prefills.
- Android previously discarded object-shaped `rates`. It now retains the original V3 JSON through cache encode/decode, including unknown fields, without treating it as a legacy scalar array. Only an approved revision exposes usable positive finite, non-review ranges on their own basis. Presence of V3 evidence prevents obsolete legacy/confirmed-default fallback; multiple bases never automatically choose a dose. Existing explicit Program and vineyard preferences remain separately attributed operational choices.
- iOS V3 unresolved/unapproved/missing options now fail closed rather than reviving old structured/legacy rates. Old default-rate range gates do not override current V3 label choices on either phone. Reopening an iOS non-template application restores its recorded base dose, unit and basis rather than today's defaults; UI provenance explicitly says Saved application rate. The historical source record is not edited by this prefill.
- #16: queued occurrence Spray Trip detail has an explicit Recover & Start action, original-plan confirmation, spinner and actionable failure. It reconciles retained local evidence, locates the original trip/open recipe, and calls existing dedicated activation. Queued-plan deletion is hidden. All synchronous activation rejection paths finish `onStarted(false)`, including two persistence-rejection paths missing from the PR. No replacement trip, new recipe identity, receipt fabrication, journal bypass or offline operation deletion.
- #17: initial login now forces RevenueCat `.fetchCurrent` after identifying the customer, not a default cache-policy refresh. Cached login/stream emissions cannot resolve startup mid-verification; root routing shows checking until initial verification finishes and then refreshes the existing combined entitlement gate. Async identity generations fence stale login/fetch results. Deterministic service tests cover pending, current entitled, expired, unentitled, fetch failure and old-login failure after a newer identity. No automatic purchase/restore or changed backend billing/write authority.
- RevenueCat dashboard integration doctor reported NOT CONNECTED; public native configuration already exists. No dashboard, product, billing or credential configuration was changed. Synthetic SDK decoding tests are not live store/RevenueCat acceptance.

### Executed validation, including failures

- Final iOS focused `swiftTest`: **218 passed in 38s**. Selection: `VineTrackTests/` plus each of `ChemicalV3SprayRateOptionsTests`, `SubscriptionInitialVerificationTests`, `EntitlementDecisionTests`, `EntitlementAccessRegressionTests`, `ReadOnlyEntitlementContractTests`, `SprayOccurrenceRecoveryHotfixTests`, `TripOccurrenceJournalTests`, `SpraySaveForLaterTests`, `LegacySprayPairReceiptTests`, `SprayTripStartAdmissionTests`, `SpraySavedJobActivationIntegrationTests`, `SprayRateBasisPreferenceTests`, `SprayRegisteredUseRateTests`, `SprayVineyardRateScopingTests`, `SprayCanopyAndRatePresetTests`. Aggregate tool result; no skipped count was supplied.
- Initial focused run158 passed/1 failed: new SDK CustomerInfo fixture needed snake-case keys/date decoding. Corrected fixture decoding; next160 passed in47s. Broadened run216 passed/2 failed exposed old expectations for pre-existing canopy wording and fixed-dose safety warning. Updated only those expectations: Confirm canopy remains required; unchanged fixed dose is quiet and a changed dose must show the existing label warning. No warning or production gate was weakened. Final218 pass includes those corrections and the added account-fencing test.
- iOS production-calculator UI selection requested all six `VineTrackUITests/MobileSprayUXParityUITests/testPhase2{RecommendedToReview,CustomToReview,BandedToReview,SpreaderToReview,EditBlocks,ProgramPrefill}` journeys. **INCOMPLETE: 0 passed, 1 reported failure**, first selected Banded journey: `Failed to application app.rork.nt0v48tayl7v8noxcfe74 is not running`. Test build succeeded (5.857s), products synced, but no successful UI journey was reported. Cause is not established as app versus simulator/runner. Runtime log query returned no logs. No unchanged automatic rerun and no claim that iOS rendered progression passed this turn. Temporary runner log was subsequently overwritten by final host selection.
- Android host command: `python3 scripts/run-spray-phase1-regressions.py ChemicalV3SprayRateOptionsTest SprayRegisteredUseRatesTest SprayBandedGroundCarrierTest SprayGuidedFlowTest VineyardPreferredRateTest`. Final **68 tests, 0 failures, 0 errors, 0 skipped**, artifacts `/tmp/vinetrack-spray-phase1-m6puylyq`. New V3 tests assert separate ranges/presets, stable offers, exact original-object cache round trip, pending approval and review/incomplete rejection. Initial compilation failed with zero tests because PR #11 used Checkbox without importing it; imported the existing Material control, then68 passed. After the final V3 default-gate repair, reran and again68 passed.
- Final Android `androidTest`, selection `com.rork.vinetrack.data.SprayPhase1CalculatorAndroidTest`: **6 passed, 0 failed, 0 skipped in54s**. Previous source checkpoint also passed6 in55s. Real local production-calculator controls cover recommended/custom Foliar, Banded, Spreader, edit Blocks and supplied Program prefill with explicit Application confirmation; these are isolated fixtures, not authenticated customer Program journeys.
- Exactly one separate normal iOS `runChecks`: **PASS, simulator build succeeded**. Exactly one separate normal Android `runChecks`: **PASS, build succeeded**. Neither tool is a test result or device/Release-signing acceptance. Existing two direct-storage image URL notices per platform remain unchanged/out of scope.
- Final `git diff --check HEAD` PASS; no differences in iOS project release settings, Android build/version properties or manifest. No Supabase/schema/customer-record changes, SQL execution, version/signing changes, TestFlight/Google Play upload or delivery. SQL276–278 were previously reported applied; not modified or independently reverified in this turn. Managed history/tooling retained.

### Readiness and next controlled acceptance

- Source/build checkpoint is available for controlled device investigation; **not an accepted release and not a green iOS UI acceptance gate**. Re-run/diagnose the incomplete iOS UI selection when authorised and complete authenticated Program/repeat/Label/Product Page and subscription startup checks on the actual phones. Automated arithmetic/journal tests do not prove external links opened or live store entitlements were resolved.
- Original **29 October 2026, 1:07 pm** trip remains unverified: **116 planned paths, zero completed**, original trip/recipe/occurrence IDs and offline actions must remain intact. No original handset journal, authenticated receipt transcript or physical device was available. No production trip was recovered, started, deleted or substituted by this work.
- On the original handset, retain local app data; open that exact queued trip, confirm the original plan/recipe, then use Recover & Start Original Trip online. Stop on any unresolved receipt/held journal or missing recipe; capture the exact error/receipt evidence rather than create another spray or clear data. Acceptance requires the original trip to activate once, with no duplicate start and retained identities/evidence. Signing, archive and store delivery remain separate, unrequested steps.

### Final changed native/test/runner manifest (SHA256)

```text
cc199848fdc572c60c35443500b4c65b673592b4f1b64f84fd611abc010dc7b6 android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/SprayPhase1CalculatorAndroidTest.kt
5f0fe4b1e08a9fb8df536360f3a12e4a24d0bc176321bf1db6b4c6ffbd99ef04 android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/SprayPlanningAndroidTest.kt
8642a139d0ca31ccf9d27da03f4085b102cf987d9978f544d833e229b3519368 android-vinetrack/app/src/main/java/com/rork/vinetrack/data/chemical/CatalogueLegacyRatesSerializer.kt
6001566244eda98af1e31b8b5b50bfa9b1d2dd0d616c16fa5c3092c13674d840 android-vinetrack/app/src/main/java/com/rork/vinetrack/data/chemical/CatalogueRateEvidence.kt
5a13cb7a3cf67d7a2270c028b1f185f0c4fa26e7ae8eed420898bb42ba19af05 android-vinetrack/app/src/main/java/com/rork/vinetrack/data/chemical/SprayConfirmedRateSeeding.kt
fda4299f03f31810fd6b97a5d5cba998d4ee3fd111c66146d935d166f50c746c android-vinetrack/app/src/main/java/com/rork/vinetrack/data/chemical/SprayRegisteredUseRates.kt
ad47cd1bbd4b427660ec13c523d5b9d000f14b5c52dc26cf66a8fce5a18ed9a2 android-vinetrack/app/src/main/java/com/rork/vinetrack/data/chemical/VineyardPreferredRate.kt
11a1c384fbdda562bebe2910e46416334e732f1ed29ad3eeaceb59481eefea74 android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/Models.kt
bbd41155d66af43042e685d72a0888e11f58e04cfbcd5be154b874c68e1ed49a android-vinetrack/app/src/main/java/com/rork/vinetrack/data/spray/SprayPlanningIntent.kt
95115b1508889495374cc3f127d63f9740863d2e6af3e737f68eb46d39e254d0 android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/components/SprayGuidedComponents.kt
b0fdc437de3a87ad09aec39be1b1c0cb6becefbf8db5fbf6958608f1391e7b26 android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/components/SprayLabelRateSheet.kt
2eed16a4f3b6e7faa603e6ce891370b3efcdcfdb4120564f91d08ef87fbc95b5 android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/components/SprayPlanningCards.kt
1965ce50d8107cf741dc5bff73d688196b23b300c7527deae50e7180f133b712 android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/CatalogueSearchSheet.kt
073a03135965b300737ae1d1ccf9c249ad2cace59dff170c4e65a3fe600afb88 android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/CatalogueSearchViewModel.kt
bb6f9a6aab0ade0f5cc158b949580cf4f66b0460b76c77f6dbd7f852d7080396 android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt
2951b13999e9cb83b4dc4928166a7ad9cacf3c18cbb695c2a5501281a5ff3442 android-vinetrack/app/src/test/java/com/rork/vinetrack/data/ChemicalV3SprayRateOptionsTest.kt
97a4511bab89daab764653c231d0cfb02844a5b004805432d93be5d8b24f1872 ios/VineTrack/App/ChemicalIntelligence/CatalogueRepository.swift
b083898eabffb121fb54f14b24fb3fabdd9e7a4be927abc466e3bdc41fc72fcc ios/VineTrack/App/ChemicalIntelligence/CatalogueSavedChemicalView.swift
9fcb0ed4d8aca56fc7917f6b20d95bab410cb868170bc2a106110978f8f8306d ios/VineTrack/App/ChemicalIntelligence/CatalogueSearchModel.swift
bb2a0e59687b18289337d35707bece592889a15a1fa238ae84ee552b76784f7a ios/VineTrack/App/ChemicalIntelligence/CatalogueSearchView.swift
bec43a1c9d4e703d0354faf41556472c33a0d7da1b168e51436b316cc09ecc80 ios/VineTrack/App/ChemicalIntelligence/ChemicalServerDefaultRateOptions.swift
87e68f2ee74119e1938e3cc474e4ed253a5be54b1250c507e21a7e9c37560ee4 ios/VineTrack/App/ChemicalIntelligence/VineyardPreferredRate.swift
9a95273cb6b22884d622ef793ae9b0f2ce28447e81b714423fc530cd94e5240e ios/VineTrack/App/NewBackendRootView.swift
337a716dcabd9cedda40a72af1d6ba43778b8746f82665b9ef1f90df5c24bd2d ios/VineTrack/App/SprayCalculatorView.swift
15b0df91e4556fcf50539f8412940aec8ff11ec5ee701f803fd0f6e51fb3a69a ios/VineTrack/App/SprayEngine/SprayConfirmedRateSeeding.swift
f03758a79528ecb4f2352320fde2951db07f1326db269a9f70c8a6aa70e6c84d ios/VineTrack/App/SprayEngine/SprayPlanningIntent.swift
7f85fe4db9a86a50c1ae04d921255615e4f81315cf171fc50a05c3358b122fb3 ios/VineTrack/App/SprayEngine/SprayRegisteredUseRates.swift
4063951d17c0be3337c2880c74f7e5920bb8a36d013716089479879bac314a46 ios/VineTrack/App/SprayGuidedComponents.swift
2ede04c8164875d51aac2ba1d8c01e1d5451ae977d4726de0123da02cb7807b3 ios/VineTrack/App/SprayLabelRateSelectionView.swift
6ed40aaa32dfaff54a72a6d36a73a5bab855cbb96d586a0b552da6d1c1dfd362 ios/VineTrack/App/SprayPlanningCardsView.swift
188a711a53eead643a3228713e5d4ce202a49ed1cca95cef422ca86def86b0c0 ios/VineTrack/Backend/Models/BackendManagement.swift
f8e85679b0043d46de0ec2f8cd487d4084439028ac8275c0fd8b636b61b9924b ios/VineTrack/Backend/Subscription/SubscriptionService.swift
ad92379867e0caa297a0a9ad64bc23918070c354a1accd024d8a61b57f1d4639 ios/VineTrack/LegacyImported/Models/SavedChemical.swift
992f784d2cea2b1c138cd0e67beedec6456a682adee0cabe490f31d439382320 ios/VineTrack/LegacyImported/Services/TripTrackingService.swift
0d1c0312648c70e106fe577e9f1ef06d64370684f13d678b5661fad21644d8f1 ios/VineTrack/LegacyImported/Views/Spray/SprayLineChemicalPicker.swift
cb1caeee6900c37022d8723185549e92d864f54f41ee1e7e88e537a0cda27681 ios/VineTrack/LegacyImported/Views/Trips/TripDetailView.swift
438b4dce8f69bdb7bdec2a977f73790380d767a97a7d048e814b01a8ccdbbae6 ios/VineTrackTests/ChemicalV3SprayRateOptionsTests.swift
6e4749700dae46d15d7f2bed2b573cdcd09ce541ba2dbfcf86b7a05748c9d073 ios/VineTrackTests/SprayCanopyAndRatePresetTests.swift
f55ae61342b205e8f73139211dbc5375e4dd208fe292f1c5fa0b145d0b9eb388 ios/VineTrackTests/SprayOccurrenceRecoveryHotfixTests.swift
d8c4d8b6842ac1ebc05418789b0b6791bcd06dae225e33fc20004edd51337222 ios/VineTrackTests/SprayRateBasisPreferenceTests.swift
0fd11b69320789dc16ad3f6008ebc87c73a13abd24f8bb25be80ac85c27a7cc8 ios/VineTrackTests/SubscriptionInitialVerificationTests.swift
6f5b6a900397fc188c204b20967a41614c00cfbf38a7eb6ba88889d6c29387a7 ios/VineTrackUITests/MobileSprayUXParityUITests.swift
35eea64f6877b107278d78f5c08bf4ea0040145ac61bd650988a204885d345cd scripts/reconcile-vinetrack-pr11.py
b4adc6084b10e07dc03f7887ed1c62c0a4b0eb2cf6c40451aab8ea7b0080ff54 scripts/run-spray-phase1-regressions.py
```

## Emergency iOS Spray Trip recovery — 29 October 2026 — SOURCE READY FOR CONTROLLED TESTFLIGHT VALIDATION; ORIGINAL DEVICE TRIP UNVERIFIED

### Review and integration

- Reviewed public GitHub PR #12, `https://github.com/stockmansridge/rork-vinetrack-june26/pull/12`, head `7060f992a90e1225eaa2eb42700ad626923f3fe7`, base `97545e13c3b0bef31acc4131a1cac6b395d20105`. GitHub reports open/draft, one commit/one changed file, +12/-6. Its description correctly distinguishes the saved-trip gate fix from unresolved occurrence starts. The PR text calls the method `activateSavedSprayTrip`; the actual diff/current method is `activateSavedTrip`.
- Current local source parent: `025123219e8c5855ec37251e3be9d0cf7f76dd98`. Applied the reviewed hunk semantically to the existing service, not a branch/file replacement, pull, reset, cherry-pick or GitHub merge. No manual commit/push. This is workspace integration; the GitHub PR was not marked merged. The later managed-save hotfix revision is not available during this turn; hashes below identify final tested source.
- The PR gate is now conditional on legacy coverage. Saved occurrence trips reach the existing scoped journal/recovery/activation path instead of demanding a legacy paired-create receipt they cannot obtain. Unsupported coverage still fails in the existing occurrence-document validator, not numeric fallback.

### Additional concrete blockers found and bounded repairs

- `LegacySpraySaveRecovery.prepare` retains occurrence saves as a local recipe/trip WAL, but the legacy RPC explicitly rejects occurrence coverage. Their WAL consequently has no legacy RPC/receipt and remains `isHeld`. The same unconditional legacy `contains` gate was used by Trip/Spray sync writers and pulls, so PR #12 alone would leave those records filtered out even after dedicated activation became reachable.
- Added `requiresLegacyReceipt`: only a locally complete occurrence pair with no legacy request, claim or receipt may leave the legacy gate, and only when its owner/vineyard/trip-scoped occurrence journal contains the exact original creation coverage and entire original create-trip metadata. Missing, malformed or mismatched evidence remains held. Nothing is relabelled as a verified legacy receipt or parent acknowledgement. Trip/Spray sync still uses existing occurrence replay and parent checks; no numeric full-snapshot fallback was added.
- The local WAL, exact recipe, trip and occurrence operations remain unchanged. A held occurrence journal stays held and cannot operate, even when correctly routed away from the irrelevant legacy gate. Shared legacy notice/count/sweep queries use the same evidence check; accepted-legacy lists explicitly remain legacy-only. Legacy RPC preparation/replay, journal schema and backend contracts are unchanged.
- New planned starts previously scanned older occurrence trips using a helper that initializes missing journals with `creationConfirmed = false`, then immediately treated that newly fabricated state as unresolved. The scan is now read-only with respect to journal documents. Existing uncertain creation evidence still blocks duplicate starts; the message names the earlier block/date so it can be recovered rather than recreated. No pre-existing journal is removed, auto-confirmed or repaired from a snapshot.

### Focused validation and intermediate evidence

Final `swiftTest(appPath: ios)` selection (not full app suite):

```text
VineTrackTests/SprayOccurrenceRecoveryHotfixTests
VineTrackTests/TripOccurrenceJournalTests
VineTrackTests/SpraySaveForLaterTests
VineTrackTests/LegacySprayPairReceiptTests
VineTrackTests/SprayTripStartAdmissionTests
VineTrackTests/SpraySavedJobActivationIntegrationTests
```

- Final result: **67 passed in36s**. The runner reports an aggregate and does not provide a skipped count. Latest test log: `/tmp/rork-swift-test-ios.log` (temporary, overwritten by future runs).
- New saved-occurrence regression invokes the real `activateSavedTrip`, preserving original trip/recipe and inactive device state. Deliberately absent authentication must produce the dedicated branch's scope error, not the legacy receipt error. Initial fixture attempts returned0/1 because the synthetic tank lacked a product, then lacked quantity; those are fixture failures, not reproduction evidence. After correcting those inputs, **0 passed /1 failed** specifically on the unconditional legacy receipt error, reproducing PR #12 before repair. Final selection passes after repair.
- New WAL/sync-admission regression uses the real repository creation preparation and real durable journals: missing parent held; exact parent routes away from legacy sync; mismatched metadata held; legacy RPC sends zero; occurrence hold/pending IDs and original local WAL/records unchanged; no invented legacy acceptance. This validates the gate used by production sync, not a live authenticated Trip/Spray sync session.
- New-start preflight regression confirms historical missing journals remain absent and a real unconfirmed create still blocks with unchanged IDs/state. Existing journal tests retain full local offline creation/activation/recreation, scope validation, conflict/hold, per-operation ordering and duplicate-ack protections.
- Added exact create-plus-activation recovery transcript coverage: emulate both responses lost, recreate the journal, validate original actor/request/result receipts, drain only those original operations, repeat recovery idempotently and reject another activation. Transcript is synthetic, not observed server RPC traffic.
- First combined selection: **64 passed /3 failed**, all in existing saved-activation tests whose tank fixtures contained no products and were correctly rejected by the existing recipe-start validator. Added explicit synthetic positive product rates/quantities to those three test inputs only; no assertion, production validator or GPS behaviour change. Final same bounded selection67 green retains actual saved activation/persistence and existing three-block GPS/pin/auto-path assertions.
- Separate normal `runChecks(appPath: ios)` → **PASS, simulator build succeeded**. Only one normal build was requested/run. Two pre-existing unrelated direct-storage image URL notices remain. No signed-device/Release build, TestFlight delivery or UI/device acceptance performed.
- `git diff --check HEAD` PASS. Native changes are exactly three recovery services and three test files. Verified no diff in Android, Spray Calculator or iOS project/release settings. No Supabase/schema/server/customer-data operations. Runtime preview-log search supplied no matching original-device occurrence failure; it cannot diagnose that handset's saved journal.

### Readiness and remaining blockers

**Ready to prepare a controlled TestFlight validation build from the current integrated source**, based on focused automated execution and simulator compilation. This is not an isolated historical 3.1.8 branch rollback: newer workspace work remains intact, and no version, signing or release setting was changed. Release/device signing validation and delivery remain separate; no TestFlight build has been uploaded.

The original 29 October2026,1:07pm trip has not been read, mutated or verified on the original device. Its actual trip ID, scoped journal, pending create/activate IDs and server receipts were not available here. A retained unconfirmed earlier create, absent original create evidence, genuine RPC rejection/coverage mismatch, existing journal hold, account/entitlement mismatch or missing server activation evidence will still block safely; the hotfix does not clear any such condition. A journal previously initialized from a snapshot by the old scan is retained and still requires authentic recovery; it is not silently converted into a new create operation. Therefore the exact cause of that trip's initial start error remains unverified even though the three source-level blockers above are addressed.

Device verification: keep the original installation/data, sign in as the original operator in the original vineyard, open the existing saved trip and attempt its recovery/start once with connectivity. Confirm the same trip/recipe/occurrence identities, one activation and no duplicate trip. If still blocked, retain the displayed message and obtain that original trip's scoped recovery diagnostics before further changes. Do not delete/recreate the trip, reinstall/clear app data or start a replacement job. No claim that the incident trip is fixed or production-release accepted.

### Final native source/test manifest (SHA-256)

```text
787a4929669ec4e08cc557cc73932afe271cb0c6bb66234e7a12b0e492266343  ios/VineTrack/LegacyImported/Services/TripTrackingService.swift
72adcf16d7de021ba3add0fe1759d894579fd74a60c09cdbc7dff775abbb7a0a  ios/VineTrack/LegacyImported/Services/LegacySpraySaveRecovery.swift
c16f86e6de696b37d6062f8e7ae9722851ed7d052ceb50e319283563bc7dc159  ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift
8826c961ae216f83b189ea57bd68eec42df9cb431c1cb7f110274da1a4175d0f  ios/VineTrackTests/SprayOccurrenceRecoveryHotfixTests.swift
1049a2bc36fc74c95dbb4bdc9bd2335f4d66d72e67ce42ffcec527452fa2585d  ios/VineTrackTests/TripOccurrenceJournalTests.swift
b22558adff3d225900550af406659a3f7b3717ae2d131da8be47a2e617ce261d  ios/VineTrackTests/SprayMultiBlockTripTests.swift
```

## Spray Calculator Phase 2A — 28 October 2026 — FOCUSED AUTOMATION AND BUILDS PASS; PHYSICAL ACCEPTANCE OPEN

Phase 2A only: explicit progression through the existing eight calculator cards on iOS and Android. Source-parent HEAD is `e9a69791c7d623442038a8a17b6015315b76fd3e` (the managed Phase 1 repair commit). Supplied baseline `524afcccff7480e2a80e34678b6a784a78af23e9` was inspected without resetting the working tree: native differences before this phase were only the already-absent generated `ios/VineTrack/Config.swift`. It was not restored. Newer work, Phase 1 and managed history are preserved.

### Bounded changes

- Each existing card from Application through Products now supplies a consistent full-width olive Continue action: Blocks → Target → Growth Stage → Equipment → Spray Volume → Products → Review. Both enabled state and action execution require the existing flow engine to complete the current step and unlock the next. Unanswered Application and Carrier actions remain visible but disabled instead of disappearing. There is no separate wizard, new navigation architecture or automatic collapse on answer selection.
- iOS centralizes the seven actions inside its existing guided-card wrapper; Android uses one private shared action within its existing seven card bodies. Existing Review/Tank Mixing handoff is unchanged. Existing field-adjacent guidance and blocker banners remain; added footer guidance is limited to missing guidance, with iOS product footer guidance limited to the empty-products case rather than duplicating per-product rate/basis explanations.
- iOS explicitly rejects attempts to open locked steps and retains generation-fenced, post-expansion single header anchoring. Existing spring expansion/scroll animations are replaced with sequential short ease animations. Android retains its existing single `LaunchedEffect(expandedStep)` animated list anchor; a temporary immediate-scroll experiment was reverted after the failed Review assertion was traced to an invalid numbered-header selector, not demonstrated scroll failure.
- Added only stable iOS accessibility identifiers needed to operate the existing block, growth, equipment, band-width and ground-rate controls. DEBUG-only fresh and Program-prefill variants extend the existing isolated calculator harness. The new fixture supplies a saved synthetic product with its own explicit legacy rate; the test does not bypass production product selection or area-basis confirmation.
- No flow-engine, arithmetic, conversion, CF policy, product/label-rate, band-area, tank, Trip/GPS, persistence/recovery/offline, backend/schema/permission, Single Row/Over-Row routing, performance, version/signing or release changes. Step 6 layout, Pass Setup, Full Tanks visibility and basis controls remain unchanged. Phase 2B is not included.

### Actual production-control journeys

- Both platforms: new One-off starts expanded in Application with Blocks and Continue disabled; deliberately choosing the displayed Foliar operation resolves it without collapsing the card. Each next step is opened by its own Continue action. Heading visibility is asserted after every Continue without manually scrolling the destination into place; iOS additionally checks that the entire heading frame is inside the calculator scroll viewport.
- Recommended Foliar and custom Foliar: choose blocks, Powdery Mildew and Full Canopy; deliberately choose Not Set growth; select and confirm equipment; use the real VSP canopy confirmation and recommended volume, or enter custom `600`; choose the actual synthetic saved product; reach Review. Existing Phase 1 tests separately retain empty-custom-rate gating, single confirmation and live canopy-to-carrier assertions.
- Banded: choose Undervine and band width `0.8`, resolve growth/equipment, enter ground application rate `200`, choose the actual product and explicitly confirm Treated Band Area, then reach Review without a canopy confirmation. Existing host regressions retain Undervine/Midrow, whole-block versus treated-area and independent product-basis protections; only Undervine is the rendered Banded fixture in this phase.
- Spreader: iOS uses the existing Manual basis with `400` total water and reaches Review without canopy confirmation; Android uses its existing non-canopy carrier path and reaches Review. iOS's default legacy water-rate presentation can still show optional canopy controls; this frozen Step 6 presentation was not redesigned, and the test does not claim their absence on that default path.
- Editing Blocks from Equipment: deselect all blocks through the real controls; Target Continue and downstream Equipment header become disabled. Reselect blocks, retain the prior target/growth answers, continue through Equipment and finish at Review. No new invalidation engine or answer-clearing policy is introduced.
- Program prefill: supply a synthetic real template record, genuine block IDs, Powdery Mildew, EL12 and equipment via the production prefill inputs. Check the supplied Application name, keep the target/growth answers resolved, deliberately answer the not-supplied Full Canopy head target and confirm equipment, then complete Carrier/Products to Review. This is a local supplied-prefill journey, not authenticated Program creation or repeat-job acceptance.
- Android uses the real calculator and ViewModel with isolated files/preferences and an intercepted synthetic 503 transport; iOS uses its existing isolated local DEBUG harness. Neither uses customer data or a replacement navigation/confirmation component. Neither starts a real Trip.

### Final validation — separate, non-additive selections

- iOS Phase 2A UI group 1: `VineTrackUITests/MobileSprayUXParityUITests/testPhase2RecommendedToReview`, `.../testPhase2CustomToReview`, `.../testPhase2BandedToReview` → **3 passed in296s**.
- iOS Phase 2A UI group 2: `VineTrackUITests/MobileSprayUXParityUITests/testPhase2SpreaderToReview`, `.../testPhase2EditBlocks`, `.../testPhase2ProgramPrefill` → **3 passed in216s**.
- Separate iOS focused regression selection: `VineTrackTests/SprayGuidedFlowTests`, `VineTrackTests/SprayBandedGroundCarrierTests`, `VineTrackUITests/MobileSprayUXParityUITests/testNewOneOffRecommendedCarrierUnlocksProducts`, `.../testNewOneOffCustomCarrierUnlocksProducts` → **40 passed in79s**. The tool reports an aggregate, not individual passing method discovery or skipped count. The two host suites contain38 cases; the selected prior UI journeys are retained. Latest managed log: `/tmp/rork-swift-test-ios.log`; earlier tool results remain in managed conversation history.
- Android final instrumentation selection: `com.rork.vinetrack.data.SprayPhase1CalculatorAndroidTest` → **6 passed, 0 failed, 0 skipped in58s**. Methods: `newOneOffRecommendedCarrierUnlocksProducts`, `newOneOffCustomCarrierUnlocksProducts`, `bandedContinuesToReview`, `spreaderContinuesToReview`, `editingBlocksRetainsAnswersAndLocksDownstream`, `programPrefillRetainsAnsweredSteps`. All six use the actual calculator controls and check destination headings. Latest log: `/tmp/rork-android-test-android-vinetrack.log`.
- Android host: `python scripts/run-spray-phase1-regressions.py` → **38 tests, 0 failures, 0 errors, 0 skipped**, 23.402s. Exactly `com.rork.vinetrack.data.SprayGuidedFlowTest` (32) and `com.rork.vinetrack.data.SprayBandedGroundCarrierTest` (6). Command/XML/case evidence: `/tmp/vinetrack-spray-phase1-4k5ps9u4/finished.json` and its `spray-phase1/` directory. The existing bounded runner was reused unchanged.
- Separate normal `runChecks(appPath: ios)` → **PASS / simulator build succeeded**. `runChecks(appPath: android-vinetrack)` → **PASS / build succeeded**. Both retain two unrelated existing storage-URL notices. No device/Release validation, store delivery or release acceptance is claimed.
- Source review and `git diff --check HEAD` pass. Only the five native source/test files below differ from this phase's source-parent HEAD, plus this existing report, the approved plan and preexisting managed state/history. No changes to the guided engines, canopy-control implementation, Home/hydration code or test/build configuration.

### Intermediate results retained — not additional green totals

- Android first extended recommended-only run: **0 passed /1 failed**, asserting a numbered Review heading. A subsequent six-case run returned **0 passed /6 failed** while test selectors/fixtures were still incorrect: the prefill test toggled an already-open Application, chip selection lacked selected semantics, Banded used nonexistent `Treated Area` instead of `Treated Band Area`, and the Review selector required `8` even though a completed header displays a checkmark. The immediate-scroll experiment did not fix those authored assumptions and is not retained.
- After restoring the original Android animated anchor, correcting prefill field access and area-basis copy, asserting enabled actions and supplying the synthetic product's actual explicit rate, another run returned **0 passed /6 failed**: remaining failures were numbered Review and duplicate prefilled target matches. Correcting those produced **5 passed /1 failed**, the remaining failure being a duplicated equipment-name selector in the Program test. Program coverage was then extended through Review rather than ending at Equipment.
- Adding per-transition Android header checks exposed another selector ambiguity: **0 passed /6 failed**, because Growth Stage names both its header and expanded body selector. The assertions now select the first matching clickable node, the existing card header. The final six-case selection passes; no production workaround was made for these selector failures.
- iOS first recommended journey returned **0 passed /1 failed** with only `XCTAssertTrue failed` in the managed summary. The block-picker action selector was corrected to match its combined label and test assertions gained specific diagnostics/stop-on-first-failure. Next recommended-only run passed **1 in76s**. No production change was made to address that test failure.
- First iOS six-case selection returned **5 passed /1 failed**: the Spreader test incorrectly expected no VSP control on the existing default legacy water-rate path. The journey was corrected to explicitly choose the real Manual-water path and require no canopy confirmation; selected Spreader then passed **1 in74s**. Step 6 was not changed.
- One larger mixed iOS selection was reported as failed with **40 passed /0 failed**, no compiler error and no completed test-result footer in the log. It is incomplete, not a green46-case run, and the tool/log did not establish the termination reason. The missing Phase 2A coverage was split into the two bounded three-case UI selections above; the separate focused40-case regression selection then completed successfully. Preexisting actor-isolation/deprecation warnings were not changed.

### Revision and remaining physical gaps

Rork manages commits automatically. At closeout `git rev-parse HEAD` still reports `e9a69791c7d623442038a8a17b6015315b76fd3e`, the **Phase 1 source parent, not this Phase 2A repair commit**. A new managed-save commit ID is not yet available; no manual commit, push or reset was performed. The five-file SHA-256 manifest identifies the final tested native source independently. Managed history was not edited, deleted or excluded by the assistant.

Physical iPhone/Android scroll feel, large-text presentation, rapid real touch navigation, authenticated Program/repeat prefills, customer-data and field-operator acceptance remain unexecuted. Tests establish the stated local production-control transitions and heading assertions, not every animation frame, real network behaviour or v3.1.9 acceptance. Stop after Phase 2A; Phase 2B and release clearance remain out of scope.

### Exact Phase 2A source/test manifest (SHA-256)

```text
141a424679f2c99e5474292aace7c40de04e407dd53d9537e0996345f561af48  ios/VineTrack/App/SprayCalculatorView.swift
5244702570fc461ae315b3cdaa66845f122c233b10086c24cda2c597ee4d6a4e  ios/VineTrack/App/Keyboard/SprayCalculatorKeyboardValidationView.swift
b96beeed30f3596d5f0bb8141dc246c747388f1d87d7d6a4b1efd7c26fd3889e  ios/VineTrackUITests/MobileSprayUXParityUITests.swift
c94e8c207f7bdf423a1d19a2032a574fa2df4b412740f9f4b1fe8f812157fce3  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt
ca186478a68ce697511c167cdd7ca43d5f61fc05e6655297cb16d8247122b364  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/SprayPhase1CalculatorAndroidTest.kt
```

## Spray Calculator Phase 1 — 28 October 2026 — FOCUSED AUTOMATION AND BUILDS PASS

Phase 1 only: new One-off Application gating and live canopy → Carrier → Products progression. Starting/source-parent HEAD is `429ccdd21588249d82ddb3d31f74450a48d579c4`. Both supplied references, `4948681b018c39f1b02a9337b11cea60c4ac3fba` and `457758d441d5005d23f057048e72648aa6de5550`, exist and were inspected. The first is not an ancestor of starting HEAD; it was not used to reset the tree. Native differences from that reference before this repair were only the already-absent generated `ios/VineTrack/Config.swift`; no restoration was attempted. Newer Home/hydration work and managed history were preserved.

### Root causes and bounded changes

- Both guided engines treated Application as complete unconditionally because an operation enum already had a default. A displayed Foliar default was therefore incorrectly accepted as the operator's answer. The actual new calculator now starts with a transient unresolved Application decision; Blocks remains locked until the operator selects an operation, including selecting Foliar without switching away first. Continue to Blocks explicitly opens Blocks. Selecting the operation itself does not collapse Application. The flag shares the lifetime of the editing state, not a new persisted record/recovery format.
- Existing record prefills resolve Application from the supplied operation. Compatibility engine callers retain resolved defaults. No operation serialization or Program logic was changed. Banded/Spreader target, basis and band-width decisions remain the existing controls and engine requirements.
- No failed canopy binding was established. iOS still calls `selection.confirm()` on the production binding; Android still confirms its production remembered canopy selection. These actions were retained. The calculator was displaying an extra orange canopy blocker below the real confirmation action; both calculators now suppress that duplicate only, retain specific guidance by the controls and allow the step header to summarize the outstanding action.
- iOS downstream guidance previously fell through to generic legacy carrier-rate guidance for an unanswered custom rate or missing conversion geometry. It now reports **Enter sprayer output** or **Matching row spacing required**, using existing positive-rate validation and existing actual-volume conversions. No rate is copied into a legacy field, and no calculation formula, CF policy, product rate, treated area, tank or full-tank planner changed.
- Changed production files are the two calculator views, two canopy-control presentations and two guided-flow engines. Five test/runner files are included below. No backend/schema, customer records, authentication/billing, permissions, Trip/GPS, persistence/replay, routing, Step 6 redesign, configuration relocation, performance or release/version/signing/upload changes.

### Observed production-calculator progression

- iOS actual calculator UI: new Application body visible; Blocks disabled; no Continue button until the existing Foliar value is deliberately selected. Application remains open after selection; Continue to Blocks opens Blocks.
- iOS actual bound state before confirmation: `application=true canopy=false carrier=Confirm canopy products=false`. One real confirmation action remains. After its tap: `canopy=true carrier=Choose your spray volume products=false`, and **RECOMMENDED SPRAY VOLUME — CF 1.00** renders. Choosing recommended produces `canopy=true carrier=none products=true`. Custom with no output reports **Enter sprayer output**, Products stays locked; entering `600` produces `carrier=none products=true`. Continue to Products opens the real **Add Chemical** control. These are assertions against the mounted calculator's production flow, not a separately configured canopy component.
- iOS uses the existing isolated local calculator harness with a DEBUG-only Phase 1 launch argument and read-only live-state label. It seeds block/target/growth/equipment prerequisites, but leaves Application, canopy and volume unanswered. It does not establish an authenticated full prerequisite-entry journey.
- Android mounts the actual `SprayCalculatorScreen` with an isolated real ViewModel, separate preferences/files and intercepted transport returning synthetic 503; no customer records or successful live network fallback. Both journeys use production controls for displayed Foliar selection, Blocks, target, Not Set growth, equipment selection/confirmation, VSP canopy confirmation and volume. Before confirmation the rate question cannot unlock Products; after confirmation the recommendation and rate question render. Recommended, or custom `600` following the empty-output blocker, makes Continue to Products available and opens the actual **Add Chemical** body. No configured-canopy fixture or replacement confirmation control is used.
- Both mounted journeys leave Carrier open for volume entry after canopy confirmation. Source keeps explicit operator-owned expansion; no new automatic collapse was added. Host tests also verify canopy edits reinstate the confirmation blocker.

### Final focused validation (separate, non-additive runs)

- iOS host `swiftTest(appPath: ios, onlyTesting: [VineTrackTests/SprayGuidedFlowTests, VineTrackTests/SprayBandedGroundCarrierTests])` → **38 passed in196s**, current unchanged iOS source. Tool did not return a skipped count. Includes deliberate Application state, unconfirmed/confirmed canopy, invalid and valid custom rates, recommendation, conversion geometry and existing Banded/ground-carrier regression coverage.
- iOS UI `VineTrackUITests/MobileSprayUXParityUITests/testNewOneOffRecommendedCarrierUnlocksProducts` and `.../testNewOneOffCustomCarrierUnlocksProducts` → **2 passed in177s**, final unchanged iOS UI/production source. These exercise the live production binding and flow described above, not the preceding configured-canopy UI fixture. Latest host run overwrote the managed Swift log; the earlier tool result remains in managed conversation history.
- Android host `python scripts/run-spray-phase1-regressions.py` → **38 tests, 0 failures, 0 errors, 0 skipped**, 24.811s. Exactly `com.rork.vinetrack.data.SprayGuidedFlowTest` (32) and `com.rork.vinetrack.data.SprayBandedGroundCarrierTest` (6). Current XML/case/command evidence: `/tmp/vinetrack-spray-phase1-lqi5ofhk/finished.json` and its `spray-phase1/` directory. Earlier green `/tmp/vinetrack-spray-phase1-kigne4yr` is overlapping evidence, not additional tests.
- Android instrumentation `androidTest(appPath: android-vinetrack, onlyTesting: [com.rork.vinetrack.data.SprayPhase1CalculatorAndroidTest])` → **2 passed, 0 failed, 0 skipped in25s**, after aligning the transient decision flag's lifetime with the existing remembered operation. Both methods `newOneOffRecommendedCarrierUnlocksProducts` and `newOneOffCustomCarrierUnlocksProducts` pass. The preceding23s green run is overlapping, not an additional total. Latest managed log: `/tmp/rork-android-test-android-vinetrack.log`.
- Separate normal builds: `runChecks(appPath: ios)` → **PASS / simulator build succeeded**; `runChecks(appPath: android-vinetrack)` → **PASS / build succeeded**. Both retain their two existing unrelated direct-storage URL notices. iOS device/Release build was not verified. These are not store delivery or release acceptance.
- Final `git diff --check HEAD` → PASS. Only the11 source/test/runner paths below differ in native/script scope from starting HEAD, plus this existing report, the approved plan and preexisting managed history. Accepted Home/hydration changes are not modified by this patch.

### Intermediate failures retained

- Swift initial test compile failed on newly referenced nonexistent `SprayVolumeHelp.rowSpacingRequired` and `SprayVolumeDecision.hasComparableRates`; corrected to literal guidance and existing actual-rate properties before successful validation.
- A mixed Swift selection returned39 passed /2 failed: authored UI assertions incorrectly treated the legitimate header summary **Confirm canopy** as the removed duplicate warning. Assertions were narrowed to the Carrier blocker identifier. Next UI-only run returned0 passed /2 failed on the recommendation title selector, corrected to the actual uppercase title. Final UI selection then passed2/2. The mixed39 is not claimed as the final focused host count or summed with it; an old requested method selector was not proven to execute.
- Android first host attempt failed compilation because the new blocker exclusion lacked a `SprayGuidedBlocker` import; added it, then38 green. Failed artifacts: `/tmp/vinetrack-spray-phase1-4hxs_0a6/spray-phase1/gradle.log`.
- First Android managed test invocation used the incorrect `testClasses` field instead of `onlyTesting` and ended **infra-failed after600s**,0 passed/0 failed/0 skipped. No completed tests or trustworthy narrow-selection evidence came from that attempt. Investigation recovered the historical supported selector and verified Android test Kotlin compilation locally before the corrected focused invocation; no unchanged blind retry.
- Four subsequent correctly selected Android runs each returned0 passed /2 failed while authoring the actual-screen selectors: (1) sole equipment is already selected, so **Select equipment** is absent; (2) the unit name matches both header and summary; (3) the lazy-list header is not necessarily composed, so exactly one **Confirm canopy** summary cannot be assumed; (4) custom numeric input has Default IME action, and Android's actual button text is **  Add Chemical** with leading spaces and needs scrolling into composition. Corrected test selectors/scrolling and removed the unsupported IME action; no production workaround was introduced for those test failures. Final selected2/2 is green.

### Remaining physical acceptance and revision limitation

No physical iPhone/Android, authenticated Program/template/repeated-job, actual connectivity, customer-data or field-operator acceptance was performed. Local synthetic fixtures establish these mounted state transitions, not v3.1.9 acceptance, full workflow acceptance or release clearance. Operator heading/scroll feel and genuine prefills remain handset checks. Stop after Phase 1; no next-phase redesign is included.

Rork manages source commits automatically. At report preparation `git rev-parse HEAD` still returns the source parent `429ccdd21588249d82ddb3d31f74450a48d579c4`; that is **not** a repair commit. A new commit ID cannot truthfully be supplied before managed saving completes, and no manual commit or push was performed. The exact11-file SHA-256 manifest below identifies the tested source independently; managed history was not edited, deleted or excluded by the assistant.

### Exact Phase 1 source/test/runner manifest (SHA-256)

```text
cec6a3b3d97391ec153e3c966fa7b80a80208681d0af314b34c003c7cd711117  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/SprayPhase1CalculatorAndroidTest.kt
6322a334352f2a30da43ed09c7c4d3da667f1f02d1e14729a7822064f0db28ec  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/spray/SprayGuidedFlow.kt
c3655a9df8a213b8544aa91f6b628cd6193285cae3a1f190a437c01a51fa76e2  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/components/SprayCanopySelector.kt
a566c7dd76f9caf93324abd5e04ff3c32d1fd0d465437339ab123a757de810b3  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt
894b776dd995840210418d79b0ea1bce45235a2956e40183fca97b64f221a317  android-vinetrack/app/src/test/java/com/rork/vinetrack/data/SprayGuidedFlowTest.kt
cef7805d40c99f25ce4cc22d15347b574625c218d29cf528590e56d9f92a8768  ios/VineTrack/App/SprayCalculatorView.swift
fc2db55712fcb313924e80821dbfb9a8aa3336709401f4335c609d519d401980  ios/VineTrack/App/SprayCanopyControls.swift
6abc17c937c8dffd0cb628cc2df57e8ec34f1b1e84ce581d9f2be1eb541c8a48  ios/VineTrack/App/SprayEngine/SprayGuidedFlow.swift
b259bbe8b9d31ecb898c51faf0d559f78c89729bfdd2182a276d926c468175de  ios/VineTrackTests/SprayGuidedFlowTests.swift
135cb7e41dba87c936e350cd43cd0bca27a394a55b87577f5af341923ebb8dbf  ios/VineTrackUITests/MobileSprayUXParityUITests.swift
4710feb202db2d7816938c3d0bb37ff824c017cd8588e3feb4b04260dd747821  scripts/run-spray-phase1-regressions.py
```

## Android Home sync chip — 28 October 2026 — FOCUSED AUTOMATION AND BUILD PASS

Android-only presentation/navigation patch against starting HEAD `b39ba18e8df59dd50b14bb92284f83474a1ddec7`. The owner reports the hydration repair at `89fa755df577dd29281e38043dc680299e6b7754` physically looks correct. This records that limited owner observation, not execution of all older physical checklists. No iOS, backend, release/version/signing/upload or operational-write changes.

### Changes and precedence

- Removed only the `SyncStatusCard(...)` invocation from Home. The existing private card declaration remains unrendered; Sync Status itself and every existing `AppUiState` field remain intact. Home tools, summaries, notices, setup decision and hydration code are unchanged.
- Header now shows a compact, always-tappable status chip. Its only action routes to existing `ToolRoute.SyncStatus`; it cannot call refresh. Green check = **Synced**, blue spinner = **Syncing**, neutral cloud-off = **Offline**, orange = **N waiting / N held / Not synced**, red = **Needs attention / Sync error**. Vineyard name retains its existing weighted/ellipsized layout and separate switch target.
- Pure presentation precedence: offline first; online vineyard load, explicit retry or current-scope in-progress queue/photo next; unreadable evidence or blocked work next; entitlement-held or dependency-held work next; genuine failed writes/photos next; remaining waiting work next; online cached fallback next (**Sync error**); unknown/unselected data next (**Not synced**); only fully known fresh core datasets with no preceding issue become **Synced**. Counts combine scoped queued writes and separate attachments, as distinct pending operations, not unique records. Cached knowledge alone never becomes a green success, including saved machine/rig knowledge without the aggregate cache flag. No timestamp is inferred or added to Home.
- `AppViewModel` adds a read-only adapter and read-only references to existing queue observables, not another persisted state/sync engine. It checks current account and selected vineyard, uses existing recovery ownership resolution **without preservation/quarantine**, and reuses the existing dependency display mapper. Pin/trip ID-only ownership may resolve from current loaded records; unresolved/conflicting ownership is not guessed or counted for a vineyard. Attachments filter by vineyard, and chemical labels additionally by current owner. Read-evidence errors remain account-wide attention signals. Existing Sync Status retains its original whole-outbox diagnostics/counts; it is not converted to a filtered queue editor.
- Existing queues are observed for status-only changes as well as count changes, so a photo beginning upload need not change its count to invalidate the chip. No admission/write/replay methods execute from chip derivation. Held presentation uses already-published per-vineyard read-only access and existing dependency labels; it does not establish or clear holds.
- Sync Status retains per-area refresh, Retry all and saved-data/timestamp details. Source inspection found no explicit global-refresh control there, so **Refresh all** is added in its app bar using existing `vm.refresh()`, disabled offline or during vineyard refresh. No automatic refresh occurs on navigation or render.

### Executed focused validation

- Final host command: `python scripts/run-home-sync-regressions.py` → **39 tests, 0 failures, 0 errors, 0 skipped**, 208.391s. Exact classes: `com.rork.vinetrack.ui.HomeSyncStatusTest` (7), `com.rork.vinetrack.data.FieldCacheHydrationTest` (8), `com.rork.vinetrack.data.OperationalToolLayoutTest` (15), `com.rork.vinetrack.data.CacheFirstValidationTest` (9). Latest XML/command/case evidence: `/tmp/vinetrack-home-sync-q5ribwb1/finished.json` and its `home-sync/` folder. Two preceding host runs also passed39/0/0/0; do not add overlapping totals.
- Final `androidTest` selectors: `com.rork.vinetrack.ui.HomeSyncChipAndroidTest`, `com.rork.vinetrack.data.HomeHydrationAndroidTest` → **12 passed, 0 failed, 0 skipped in15s**. Production header is rendered/tapped in all seven principal labels, including syncing/offline; all callbacks are exactly `ToolRoute.SyncStatus`. Rendered A → B → A switch controls remain separate from chip actions. Production global refresh action executes once when enabled and is disabled offline/refreshing. Existing production-ViewModel hydration scenarios run alongside the new synthetic queue-switch test; it checks current-vineyard waiting versus blocked status, immediate loading, blocks/machine/rig knowledge, no previous cache timestamp, unchanged queued rows, no state mutation within the UI-thread derivation, and rejection of mismatched account/vineyard snapshots.
- First emulator selection returned **10 passed / 1 failed / 0 skipped**: the new read-only test compared the entire live state outside the main thread, allowing unrelated asynchronous publications between snapshot and assertion. This was a test race, not evidence that chip derivation mutated hydration. Comparison was moved to one main-thread turn. After adding explicit Refresh all coverage, the next selection passed12/0/0 in19s. Final source also observes existing raw queue status transitions and passed12/0/0 in15s. No unchanged automatic retry.
- Final normal `runChecks(appPath: android-vinetrack)` → **PASS / build succeeded**. Only the existing two unrelated direct-storage URL notices remain. This normal build is not a store release or upload.
- Final `git diff --check HEAD` → PASS. No iOS working diff. `FieldCacheHydration.kt`, `DomainCacheRepository.kt` and `OperationalToolLayoutStore.kt` have no diff against accepted hydration commit `89fa755df577dd29281e38043dc680299e6b7754`. The ViewModel working diff only adds presentation accessors/adapter; selection/load/cache/pending-write observers and recovery functions are unchanged. No 32ms/16ms assertion was changed; performance suites were not rerun in this presentation-only pass.

### Remaining acceptance limits

Synthetic intercepted transport and emulator Compose/queue/hydration checks are not authenticated customer-data or physical-device tests. Actual Stockmans Ridge → JH Testing → Stockmans Ridge, force-close/cached reopen, live connectivity loss/reconnect, real pending/held/error detail journeys and handset spacing remain unexecuted by the assistant. No latest-source simulatorUse run or signed-candidate clearance is claimed. Retain the owner's stated hydration appearance acceptance separately.

### Exact source/test/runner manifest (SHA-256)

```text
8ebb4982547741ed057ad39ffe6f746ef1b9760929f586c6c45704f689a7e424  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt
c57b908b69b6dd46ae6f1c0bfb008cbe23b4d78bbb084d00eca313bf2e964d70  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/HomeSyncStatus.kt
514909b8cc3eeee9942f06f1cc5c59ad852ce69bf64065781eeae9fdab259d39  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/HomeDashboard.kt
12ba6cea8191cb03fbf3ce7b326a40f7a289bdf13fabb4359e7430bff30ef47d  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SyncStatusScreen.kt
2db343f6c1e7edfb22407b82beb9dec708160b7e7d66a301dbe068a57ed90f4e  android-vinetrack/app/src/test/java/com/rork/vinetrack/ui/HomeSyncStatusTest.kt
374c4aee16cc3fe9895b9bd9b9ec1b0aa3f71a69f8da6281ece32d524715b3f9  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/ui/HomeSyncChipAndroidTest.kt
3a0567272ac48081680d396a27087f5aa03566a941504292d0e12879d811800a  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/HomeHydrationAndroidTest.kt
a917d4f1ca3240165a33035b82e4f53dab06f9513beaf68fd0f58e77a4f0d693  scripts/run-home-sync-regressions.py
```


## Mobile operator UX parity — 28 October 2026 — FOCUSED AUTOMATION PASS; PHYSICAL ACCEPTANCE OPEN

Scope compared against `f4951e3a2ae91d3ade2b980cc0612152c50aa653` plus the 29-file working patch below. This supersedes the preceding Android-only UI scope. No Portal, Supabase schema, arithmetic, CF policy, tank splitting, Trip execution, permissions, release versions, signing configuration or upload changes. Existing Android Home hydration/performance repairs remain intact. Normal builds are validation, not signed-candidate preparation or v3.1.9 acceptance.

### Before-platform differences and confirmed header cause

- iOS's plain Button header included a Spacer and padding but no explicit rectangular hit shape; Android already uses a full-width clickable Surface. The iOS label now fills its width and defines a Rectangle content shape **inside the Button label**, not around the section body. Android's header implementation is unchanged.
- The first attempted iOS reproduction used a nonexistent text-field label, so its failure is **not valid causal evidence**. After correcting the selector to the actual field, temporarily restoring the original header hit region produced **0 passed / 1 failed** on an empty-padding tap. Restoring the rectangular label fixed it. Final expanded coverage opens/closes from blank padding, badge, title/summary and right-hand affordance coordinates, then edits the body without collapsing it. This establishes the reproduced hit-region defect, not every possible device/touch/gesture failure.
- iOS previously exposed an unset pass as a conditional “Legacy” segment, disappearing after a choice; Android omitted the unset choice and described it as supported legacy spray. Both now always present **Not Set | Single Row | Over-Row**, mapped to nil/null, existing standard pass and existing over-row respectively.
- Both already separate section expansion from completion after a one-time seed. This is retained. Deliberate Continue actions now name their destinations. iOS waits for the expansion animation's logical completion before a single guarded scroll; Android scrolls its LazyColumn to the destination step on an explicit open-state change. No field completion auto-collapses or moves a section.

### Final operator flow

- By Area says **“Calculate the spray using the selected block area.”** Full-tank guidance says **“Full-tank planning cannot currently start a spray. Choose By Area to continue.”** Compatible input remains in the same draft; operational restrictions and calculations are untouched.
- Missing type says **Choose canopy type**. A selected but unconfirmed canopy says **Confirm canopy**, describes the actual values and offers e.g. **Confirm Canopy — VSP · Medium · Low**. Selecting type/size/density still does not itself confirm.
- Confirmation keeps Canopy open and brings **Spray at the recommended volume?** into view, with recommended/custom choices. Custom input appears on selection. Valid carrier and Products respectively offer **Continue to Products →** and **Continue to Review →**.
- Final iOS rendered regression round-trips all three pass choices, finishes at Not Set, follows both Continue actions and opens Tank Mixing with Start Trip enabled. It does **not** start the Trip. Android rendered tests exercise production pass/full-tank/canopy/header controls; full authenticated calculator-to-Mixing navigation is not proven there.

### Work Task assignment presentation

Both editors now resolve exact-vineyard profile-enriched members and external resources, preferring nonblank full name, display name, then email for members. Scoped picker selections and restored human draft labels are retained in a device-local **presentation-only** directory keyed by original account, vineyard, member-versus-external kind and assignee ID. Missing/inactive roster rows do not erase a previously resolved name; offline reopen uses that retained label. The cache never supplies membership/access or labour authority and never changes assignment IDs.

Known generated UUID/8-hex labels are rejected. An unresolved member displays **Assigned vineyard member**; an unresolved external resource displays **Assigned external resource**; no assignment displays Unassigned in the existing UI. Directory fetch results are fenced against account/session incarnation, selected vineyard/generation and the current assignment. Choosing a different assignment cancels/obsoletes the previous lookup. The existing no-labour-charges note is retained. Android's unrelated general member-name model remains unchanged; the shared assignment picker uses the safe human-name resolver.

Eight isolated resolver/persistence scenarios execute on **each platform**: assigned member, another member/nonblank profile fallback, external resource, unassigned, historical generated label rejection, persisted offline reopen, account/vineyard/kind isolation, and missing/inactive historical name retention. These are production name-resolution/cache tests, **not** eight authenticated rendered task-editor journeys, actual app process-death tests or live profile-RLS/network validation.

### iOS Settings measurement and bounded correction

Mounted the actual Settings Form with isolated storage, a synthetic 3000×3000 JPEG and eight separate sync/account publications. Before correction: initial root bodies=1, initial UIImage constructions=1; unrelated Pin sync-status changes caused **0** root invalidations; account-name changes caused **8** root invalidations and **9** total logo constructions. Measured UIImage construction total was **10.907875ms**. This is construction cost, not full pixel decode, frame pacing or proof of the owner's physical scroll jank. The strengthened expectation failed **0 passed / 1 failed** with these values.

The account rows are now a real child observation boundary. The vineyard thumbnail is content-keyed/view-lifetime cached and downsampled with ImageIO to at most120px on a detached utility task, with cancellation and exact-data checks before presentation; changing vineyard identity discards the preceding thumbnail. No Settings redesign, sync suppression, collection rewrite or Android Settings change.

Final mounted assertions pass: eight sync publications cause0 root invalidations; eight account-name publications cause0 root invalidations; the initial thumbnail prepares exactly once. New logo bytes trigger a second preparation; switching vineyard triggers a third. A separate test verifies3000×1500 becomes120×60 and invalid bytes return nil. Actual idle/sync finger scrolling, admin-row scrolling, image-remount frame cost and handset frame pacing remain unmeasured. Do not attribute the original jank to sync invalidation: this local experiment demonstrated the opposite for that publication.

### Executed validation, intermediate results and limits

- Final iOS managed `swiftTest`: **109 passed in158s**. Exact selectors: `VineTrackTests/WorkTaskAssignmentNamesTests`, `VineTrackTests/SettingsScrollingPerformanceTests`, `VineTrackUITests/MobileSprayUXParityUITests`, `VineTrackTests/SprayGuidedFlowTests`, `VineTrackTests/SprayCalculationContractTests`, `VineTrackTests/SprayPlanningIntentTests`, `VineTrackTests/SprayCanopyCarrierRoutingTests`. Managed output does not expose a skipped count or passing-test discovery list; aggregate109 is reported as returned. Includes three authored UI tests, two Settings tests, eight assignment tests and the selected existing flow/arithmetic regressions.
- Intermediate iOS focused run106 passed. Expanded UI run then returned **2 passed / 1 failed**: ambiguous/off-screen “Not Set” button hittability. Added a stable accessibility identifier to the existing segmented control and narrowed the test to that control; isolated Not Set journey passed **1 in185s**. Final109 above includes that corrected test. These overlapping runs are not additive. The corrected failing-before header reproduction and Settings regression are described above; the original wrong-field-selector failure is not hidden or counted as proof.
- Android managed `androidTest`, exact selectors `com.rork.vinetrack.data.WorkTaskAssignmentNamesAndroidTest` and `com.rork.vinetrack.data.MobileSprayUXParityAndroidTest`: **11 passed / 0 failed / 0 skipped in18s**. Eight assignment seams and three rendered production-control tests. No live customer data, auth bypass or Trip execution.
- Android host command `python3 scripts/run-mobile-spray-ux-regressions.py`: **108 tests / 0 failures / 0 errors / 0 skipped**. Exact selectors `SprayGuidedFlowTest`, `SprayGuidedWorkflowParityTest`, `SprayCanopyParityTest`, `SprayPlanningIntentTest`, `SprayMVPDefectTest`. `RetentionReviewTest.kt` is compiled only as an existing helper dependency, not selected. XML/log/result artifacts: `/tmp/vinetrack-mobile-spray-ux-faeivjmw`; runner retains artifacts outside the project.
- Final normal `runChecks(appPath: "ios")`: **checks passed, simulator build succeeded**. Device build not verified. Final normal `runChecks(appPath: "android-vinetrack")`: **checks passed, build succeeded**. Existing two direct-storage URL notices per platform are nonblocking and unchanged. No new release/version/signing/upload work.
- Interactive Android run was **blocked at sign-in** without an authenticated fixture; no credentials, bypass or customer changes used. Interactive iOS run used a **separate billed iPhone simulator**, not the Android preview. It visibly selected Not Set and followed both Continue actions to Review, but returned **problem/not pass** because the no-save restriction stopped it at “Create Spray Job & View Tank Mix.” Its Start Trip criterion was unverified. The authored isolated iOS UI test separately proves Mixing admission; do not override the interactive verdict. Both interactive runs incurred their own separate simulator use. Neither interactive run checked the latest final app version; retain them only as historical observations, not current-build verification. Final-source evidence is limited to the authored tests and normal builds reported above. No unchanged interactive rerun was performed merely to refresh this status.
- Working-tree whitespace validation `git diff --check HEAD` passes. No manual staging/commit/push. The final managed commit is not exposed during the turn; hashes below identify tested source. Only report/plan bookkeeping follows final builds.

### Exact changed-source SHA-256 manifest

23 production files,5 test files,1 bounded runner; paths relative to project root. This report and the existing plan are separate bookkeeping. Managed history/skill/simulator state is not application source and was not manually edited.

```text
8a611f7f40c69ec41cefbcb840916341c1ae34e40315419c4b26c7759d08fa63  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/MobileSprayUXParityAndroidTest.kt
fd739d1e7e3f8fdabbdbf291ebc9564229a37adc4ffe89de0c3f8e60ec0bd1ae  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/WorkTaskAssignmentNamesAndroidTest.kt
076f03930e7a5c728b469486d2a8e103754cc0f97cf935d6c2e24d0f4a6e2635  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/WorkTaskAssignmentNames.kt
5961810fb7ee17a9a859ac2ccf9a9fadd1a7447939a625829116d721fa12661a  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/spray/LegacySpraySetup.kt
d016368d89c900549385375e5ef87a4087e2ef8bc35010b0116428e9070f15d4  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/spray/SprayCanopySelection.kt
e452c6d2f2544fbf2291d0f55c7ec67cd5b7739dec673ce0c171bd61d6c92393  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt
2583cb5f59d7cd147234fad73b3e0e764420b48601e3d821da3fdda68d0095d2  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/components/PruningResourcePicker.kt
d783789cc6ed28e59491aef53ab611f86606ec2391ffe0f17dd50571baf584ca  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/components/SprayCanopySelector.kt
05596b4ff89f16a3bc6a487b29fa9e0d130b60019b3f66a89062ec4d003ddf3b  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/components/SprayGuidedComponents.kt
52e5dc5a65385ba171ce0bfb0f8892c8e5535681cd4b81d842895d319f56abb0  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/components/SprayPlanningCards.kt
14dce2a6636221c0f1a3cd9f65c6f7df3020b11f2a14a9312d97b8b512742367  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt
f4ce5a645986d27c43cad869c66af02b97c64984df5f224134d092a6fd58f2f1  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/WorkTasksScreen.kt
7fbb3ce8df6d0702974efcd32439f69aafbd4a0ca3a85a617db2b2e8ad3f0ed4  ios/VineTrack/App/BackendSettingsPresentation.swift
ebd3ce9b7fb4d82b04f56c130b7bc45affefd92bfcf50da2822ea77fcf8eefb8  ios/VineTrack/App/BackendSettingsView.swift
6f844521c77d53ef343092d647666128fbde6098e23a4467b37be5c8667ad0e4  ios/VineTrack/App/SettingsRenderProbe.swift
9edd2ab46085ebdb489ce46d86d2ea33cdd6b446b971e3a82ea04d3310ab8e1e  ios/VineTrack/App/SprayCalculatorView.swift
fa7754495d6f3905b9e15a484e2aac4feb2f6e38218efe99a5e20fb6a44d7153  ios/VineTrack/App/SprayCanopyControls.swift
7dd60b26a1f166b447ad160bdc2492a4b8ce422c4089a0a52049f99d1aa33bf1  ios/VineTrack/App/SprayEngine/LegacySpraySetup.swift
5833c036ebd612cccae6a9edac695b2be75389c9c867eb978094124a573fe83b  ios/VineTrack/App/SprayEngine/SprayCanopySelection.swift
06ae79fc33aba12b0dc592710dfe667ac4e1190fda9ff945a5f4dbc4da348a71  ios/VineTrack/App/SprayEngine/SprayGuidedFlow.swift
2bb905256372d593aa6bdfca97d6c7a0cfbf18985f076a298e48c928f9bad967  ios/VineTrack/App/SprayGuidedComponents.swift
5715528dcca2b37c0a1f64844d4d8989378a1587ba5fbf8fc7185e38c4f18bd9  ios/VineTrack/App/SprayPlanningCardsView.swift
d421cf0601625d4d2c3a6f15fc9f7ca285877fc4c77667f7ee1059f3984eb82a  ios/VineTrack/App/WorkTaskAssignmentNames.swift
1bef7bf093c904a5ee57186369f8975549202edbf40d83cd8744284b60c93716  ios/VineTrack/LegacyImported/Views/Pruning/PruningResourcePickerView.swift
086212e392474b59b2ad5b87c2fe9ee7b95336710ba8b2ee046ec9a1a63f569e  ios/VineTrack/LegacyImported/Views/Tasks/AddEditWorkTaskView.swift
15f50135f3b90f160f50d7e4bb1e368b3adb0cc6ce3d4a20c4a0b3852a6a9fe5  ios/VineTrackTests/SettingsScrollingPerformanceTests.swift
1693f93e6ef0382afa2791fd7a1b2035f963638a8019312283a05fd3c7700a38  ios/VineTrackTests/WorkTaskAssignmentNamesTests.swift
48b94c2f6fdc85bf0d7965122208c547a6bb07e6001b7beda42368984f873ef0  ios/VineTrackUITests/MobileSprayUXParityUITests.swift
53de02c789274f572d0d4d519aeb8e75697e537b462f542562ddfea754576fd0  scripts/run-mobile-spray-ux-regressions.py
```

### Short physical acceptance checklist — OPEN, both phones

1. Retain installed data; record device/OS/build/region/text size. Tap header badge/title/summary/blank space/Edit/chevron once; body edits never collapse. Check rapid deliberate section changes and destination heading visibility.
2. Round-trip Not Set→Single Row→Over-Row→Not Set. Use Not Set + By Area through canopy, both Continue actions and Tank Mixing; inspect Start availability without executing an operational Trip unless separately authorised. Full Tanks stays blocked with plain By Area guidance and retained compatible entries.
3. Missing type vs unconfirmed selected values is clear. Confirm canopy, see the rate question immediately, choose custom and see input immediately; edits do not navigate away.
4. Reopen tasks assigned to self/another member/external/unassigned/historical/inactive assignee; resolve once online, reopen offline, then switch vineyards/accounts. Names stay correctly scoped, unresolved labels contain no identifiers and no labour charges appear.
5. iOS Settings: finger-scroll idle and during real sync, before/after a large logo change, vineyard switch and admin-row availability change; verify account values update, logo does not stale/flash from another vineyard and rows/scroll position remain usable. Android Settings unchanged.

No physical handset, live authenticated directory journey or actual Settings frame-pacing acceptance was completed. These are remaining acceptance steps, not a reason to reinterpret green automated checks as release approval.

## Urgent Android Home hydration repair — 28 October 2026 — AUTOMATED PASS; PHYSICAL ACCEPTANCE OPEN

Android only, compared against starting HEAD `c95042132ae3cd538be7eccabc2d4b2738073426`. Signed-candidate preparation remains paused. This checkpoint does **not** accept v3.1.9 or prove that the owner's retained-data handset manifestation is repaired. No project runtime logs were available. iOS, Portal/backend/schema, versions/signing, Spray calculations, access enforcement, offline write admission, active Trip recovery, GPS and Quick Actions remain unchanged. Existing Home summary routes/calculations and device-local tool order/hidden/half-height behaviour are retained.

### Confirmed source causes and performance attribution

- Tool configuration depended on a successful online vineyard-list path. Failed initial transport could hydrate field data without making the signed-in user's tools ready. Configuration now starts from authenticated identity before that read, and selection also ensures readiness.
- Selection cleared collections without clearing the prior vineyard's cached banner/timestamp. Selection now immediately invalidates that presentation and read knowledge.
- Setup inferred missing configuration from empty/unloaded lists; machine/rig failure could fall back to just-cleared UI lists. Persisted, exact-owner/vineyard setup-reference snapshots now hydrate with field data, with explicit Unknown/Cached/Fresh read provenance. Only fresh confirmed absence prompts for missing setup. An unconfirmed setup screen explains uncertainty instead of presenting missing-step actions.
- Home treated unknown blocks as zero. Unknown overview values now show `—`; vintage summary counts are gated by their required datasets. Genuine fresh empty responses still display zero. Current-vineyard fallback datasets determine the saved-data banner/timestamp; fresh recovery clears stale presentation.
- All four defects, including selection clearing, **predate** performance commits `ec48c6c3b0605b01ff8545c44ee074a16f6ffe54` (parent `1c837a738`) and `b3b3b260049240617519685d7c04a6279f64926c` (parent `ec48c6c3`). Parent comparisons do not support blaming these defects on those commits. The later performance pass added loading acknowledgement and moved cache hydration behind recovery preservation; this changes when an existing unknown/empty window is visible, not its underlying semantics. Rolling back accepted performance work would not repair these causes. Exact customer-device causal attribution is unverified without retained-data runtime evidence.
- A separate reproduced crash during test recovery was `FieldSaveBusy` in tool remote-layout cache application while recovery preservation held storage admission. Best-effort refresh now catches fetch **and application/cache-write** failure, rethrows cancellation, and resets current-user refresh throttling. It does not weaken storage admission or recovery preservation.

The new read knowledge is display provenance, not write/access/Trip-recovery authority. Cache hydration retains original-account/selection-generation fences, exact raw-source/owner/timestamp checks, original-list checks and authoritative pending-write overlays. Cache dataset scope now includes machines and spray equipment; successful current-server reads save only owner-matched, vineyard-filtered reference rows.

### Validation and intermediate evidence

- Initial production-seam reproductions `unknownDataMustNotPromptForSetup` and `selectionImmediatelyInvalidatesPreviousCachedPresentation`: **0 passed, 2 failed, 0 skipped**, including `Unloaded setup is unknown, not missing`.
- Intermediate combined instrumentation: **infra-failed; 3 passed, 3 failed before crash**. Fixture errors were expecting polygon-derived area from `savedAreaHa` and omitting local access entitlement for cached bootstrap. Fixtures now use synthetic polygons and a current synthetic session creation time; no customer/backend trial dates changed. The tools-refresh contention crash above required the bounded production repair, not fixture suppression.
- An initial host-run compile failed before tests because `AuthRetentionGateTest` references `ReviewWriteDisk`. `RetentionReviewTest.kt` is now included **only as a compiled fixture dependency**, not as an executed test selector. Initial artifacts: `/tmp/vinetrack-home-hydration-8vnfkjnx`.
- Final host command `python3 scripts/run-home-hydration-regressions.py`: **122 passed, 0 failures, 0 errors, 0 skipped**. Exact selectors/counts: `FieldCacheHydrationTest` 8; `OperationalToolLayoutTest` 15; `OfflineQuickActionsTest` 6; `CacheFirstValidationTest` 9; `ActiveVineyardRestorationTest` 12; `VineyardCachePerformanceTest` 10; `AuthRetentionGateTest` 6; `VineyardWriteAuthorityTest` 17; `ReadOnlyEntitlementContractTest` 16; `FieldIsolationFoundationTest` 23. Final XML/log/structured result artifacts: `/tmp/vinetrack-home-hydration-eh93i83u` (result at `home-hydration/result.json`). No wider host suite selected.
- Final managed `androidTest`, exact selectors `com.rork.vinetrack.data.HomeHydrationAndroidTest` and `com.rork.vinetrack.data.VineyardSwitchPerformanceAndroidTest`: **10 passed, 0 failed, 0 skipped in 38s**. This final run includes the strengthened A→B→A→B fixture: B has fresh confirmed missing rig setup, A is configured, and delayed A responses must not override final B. Earlier green 10/0/0 is historical, not an additional disjoint total.
- Eight Home tests cover configured online summary (8 blocks, 6.1 ha, 22,080 vines), failed list→cached bootstrap/tools→Refresh recovery, transient machine/rig failure without cache, repeated switches/late response, no-cache unknown→fresh, tool preferences/recreated store/account isolation, immediate cached presentation invalidation, and unknown setup suppression. Real AppViewModel/local stores run against intercepted synthetic HTTP, not customer records or a live service. Two added host cache tests distinguish unknown/corrupt from explicit cached empty and verify exact owner/vineyard/raw-byte/timestamp scoping.
- Both existing switch-performance tests retain **32ms selection acknowledgement** and **16ms mounted Home derivation** limits. Extended setup-reference/ownership/tools/provenance assertions remain green. Expected collection requests intentionally increase 25→35 for seven rather than five collections over five switches; no latency threshold was weakened. Managed success reports no stage timings, so none are invented here. The local instrumentation log retained an older failed run and is not evidence for final-run timing.
- Final normal `runChecks(appPath: "android-vinetrack")`: **checks passed; Android build succeeded**. Two pre-existing direct-storage asset-URL notices remain nonblocking and untouched. No separate signed candidate, version change or store upload was prepared. After the final instrumentation run only removal of a trailing blank line in its source and this report/plan bookkeeping occurred; no behaviour changed.
- Working-tree diff whitespace check against starting HEAD passes. iOS and all inspected Gradle/catalog/settings configuration are byte-unchanged against that baseline. An earlier cached-index whitespace check still saw the staged pre-cleanup blank line; working-tree source below contains the cleanup. No manual git staging/commit/push performed.

### Exact repair manifest and source SHA-256

Production (8), tests (3) and bounded runner (1), relative to project root:

```text
ef30d27bfafa50474e10233a427725f1313fd9fe7b5c407c91917e01198fdeec  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/DomainCacheRepository.kt
254b8f7cd9e343c6aa8261a1107d62e7cc5255e90a88263f605773cd5242ff18  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/DomainCacheStore.kt
148d5eb75e8c2c8770155c5ddad742272bd8eb6fdb5a637b6f713cd1554640db  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/FieldCacheHydration.kt
437d183f4ec9e269f31dcc1c39b5b9e3a70aac0d6e1066b87dbf4bec9441cdc2  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/HomeReadKnowledge.kt
c54a75d179dfa9d605d33f0cca436f9dd4604ea88103c143618f250c9bd41d83  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/OperationalToolLayoutStore.kt
892c6e1023c004098a7692ef4f32e9c520b279976b06e572132453882ec739f1  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt
5782f19e6b8d39963d0571f4a0120126f3654a7626e40b0c6532db4b6293af87  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/HomeDashboard.kt
57331262855b83699ef5882d0dbec5ac674e60244e5d47dbf88d1288c421abc9  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SetupWizardScreen.kt
2df274938961ff3dff135e0ff5d455779c6164997a9a70d49b7f16b301071f7c  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/HomeHydrationAndroidTest.kt
326157ffaaf7ce4e589276c7268ee8f71b790acdae5933d80765b72a312fc272  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/VineyardSwitchPerformanceAndroidTest.kt
5635ac8ca8c9caa644ebd3921db0bcabb5b20fa7511ad31038fffcae9edd5ce4  android-vinetrack/app/src/test/java/com/rork/vinetrack/data/FieldCacheHydrationTest.kt
324e7b45b8d00c40d6469b6eec28b10a5daebfbe2b38d3793d1b6a8a4882e101  scripts/run-home-hydration-regressions.py
```

Bookkeeping only: this report (`docs/reviews/final-mobile-acceptance-legacy-save-recovery-2026-10-15.md`) and existing plan (`.rork/plans/android-live-trip-safe-automatic-complet_1791964262830.plan.md`). No other source/configuration files belong to this repair.

### Retained-data physical Android acceptance — still OPEN

Do not clear installed data to bypass the reported problem. Automation above exercises synthetic state/transport, local store recreation and mounted derivation; it does not establish complete app process death/relaunch, rendered scrolling/input, real account/network behaviour or this retained-data handset fix.

- [ ] Cold launch with retained data: configured Stockmans Ridge displays actual blocks/area/vines and tools, without a false tractor/rig setup prompt.
- [ ] Failed initial vineyard-list transport: cached Home and saved tools remain usable; Refresh recovers fresh values without restart and clears saved-data presentation when appropriate.
- [ ] Transient machine/rig read failures: retain correctly scoped cached references when available; without cache show unconfirmed state, not factual missing setup.
- [ ] No-cache loading: show unknown rather than zero; a fresh actual empty response may show zero and genuinely missing setup.
- [ ] A→B→A→B with different setup and summaries: correct final vineyard, no stale late-response collections, setup prompt, cached banner or timestamp. Verify JH Testing actual data independently rather than accepting zeros.
- [ ] Verify current-vineyard saved-data banner/time under partial failure and full fresh recovery alongside Sync status; do not treat an up-to-date unrelated dataset as proof every Home read succeeded.
- [ ] Verify custom tool order, hidden tools and ½-height ON/OFF across switches and retained-data restart; check actual tile rendering and scrolling.

Stop at automated repair/build PASS pending these checks. **v3.1.9 is not physically accepted; signed-candidate preparation remains paused.**

## Final targeted iOS Yield sync scheduling — 27 October 2026 — STRICT HOME 16ms GATE PASS; STOP FOR HANDSET ACCEPTANCE

This supersedes the preceding frozen-Yield29.094ms Home failure as the current automated status. Only Yield remote-row scheduling was unfrozen by the owner. No Yield feature/calculation, master-weight rule, no-150/current resolver, variety key, mixed-variety calculation, base/damage tonnes, sampled-area value, current-trip selection, completion/replay, historical evidence, Bunch Weight management or presentation changed. Home summary derivation, access enforcement, prepared vineyard selection/loading overlay, Android/shared source, Weather/MAIT, backend/Portal, versions, signing and release configuration are unchanged.

Starting HEAD `e127909968e59465f1b251e30d987e476fca9ac3`. Requested source `2a8244c9d396c50670ebd6d75113243a06472851` is retrievable; it is not an ancestor in this checkout's graph, but `git diff` of its iOS source against starting HEAD shows **only the managed Config.swift deletion**. Performance and Yield source match. That managed configuration difference was not reverted or edited. No reset, checkout, commit or push was performed by the agent.

### Bounded production change and safety

- `YieldEstimationSessionSyncService.pull` uses the already accepted `ResponsiveRemoteApplication.forEach`: complete row, yield, revalidate, next row. There is no suspension inside a Yield row. Existing pending-intent/delete checks, tombstone application, mapping, store persistence and metadata acknowledgement remain in their original order. `continue` became closure-local `return`, not early termination of the pull. No multi-row persistence batch, new durability model or changed recovery behavior.
- Capture the existing store scope predicate before fetching: provider account/user, authority identity/binding/incarnation, selected vineyard and selection-request generation. Validate after fetch, after the existing initial seed await, before each row and on resumption after every helper yield, including the last. Service-store identity and cancellation are checked too. Selection A→B→A or same-user sign-out/sign-in cannot revive the original operation.
- The session repository pulls **all vintages** and does not capture a season-filtered result, season-specific current estimate or master cache. Therefore season is not added as an artificial cancellation boundary; it does not authorize applying season-derived state elsewhere.
- Existing row application and repository/persistence implementations are untouched. Original persistence error-handling semantics are retained, not represented as newly strengthened guarantees. No acknowledgement was moved ahead of persistence.
- A DEBUG-only row timing callback instruments the complete actual production row, including conflict checks, mapping, store persistence and metadata. An optional isolated metadata dependency and internal visibility for the existing pull let tests invoke the real service without auth/network or installed metadata. Default production construction and migration behavior are unchanged.
- The mounted fixture's Yield section now supplies synthetic backend responses through that **actual service pull**, not a fixture-only yielding loop. Other Home input/application stages, strict assertion and fixture sizes remain unchanged. The complete application fixture still uses store primitives for other domains; this is not a full authenticated sync sweep.

### Yield sync responsiveness

After numbers below are from the current-source visible fixture capture; the same fixture/source passed the strict XCTest separately. Successful managed test results do not expose the numeric attachment, so these are not falsely labelled as timings extracted from that particular test execution. All values are milliseconds.

| Metric | Before | After |
| --- | ---: | ---: |
| Yield rows applied | 10 | 10 |
| Longest uninterrupted Yield application stage | **29.094**, synchronous10-row loop | **7.126**, longest complete production row |
| Longest individual Yield row | 3.052, store primitive only | **7.126**, full pull row including checks/metadata |
| Total Yield elapsed time | 29.094, synchronous store-application loop | **54.205**, full service pull including yields |

The measurement boundary is deliberately stronger after correction: before timings covered store applications, while after timings include the real pull's pending checks, mapping and metadata. The individual-row and total elapsed columns are therefore not apples-to-apples CPU-speed comparisons. The scheduling result is that the avoidable10-row continuous stage disappears; total elapsed is allowed to remain above16ms and may increase as other MainActor work runs. No claim of faster total Yield completion, fewer persistence operations or fewer publications.

### Mounted Home — current sample and strict gate

- **Largest measured uninterrupted MainActor stage:14.070ms**, `sync spray row` (unchanged production operation). No measured operation in this capture exceeds16ms.
- **`HomeSyncPerformanceTests/testMountedHomeDuringProductionSyncApplication`: PASS**, original strict `XCTAssertLessThan(result.longestMainStage, 16, result.report)` unchanged. The test file's SHA256 remains `ee5db1016848e97d806d703d2e25060b29bf3dfac559e9712847d3d2475dfcdc`.
- **308MainActor persistence calls /144writes**, **133observable collection setter mutations**. These are not SwiftUI invalidation or rendered-publication counts.
- Previous fixture286calls/133writes did not measure the real Yield service. The expanded boundary adds10per-row metadata writes plus1fixture last-sync setup write and corresponding reads/checks. This accounts for the11additional measured writes; it is not a production persistence-semantics change. No durability optimization was attempted. Original store application implementation remains unchanged.
- Home vintage calculation is unchanged. Access/read-only enforcement remains accepted as cleared as a material cause of the measured local stalls; no further optimization or attribution work was performed.

### New Yield-specific tests

Eight XCTest cases in `VineTrackTests/YieldPullResponsivenessTests`, using real service pulls and isolated disk metadata:

1. `testMultiRowPullYieldsBetweenCompleteDurableApplicationsAndAppliesAllRows`: a queued MainActor observer runs between completed rows, disk already contains every completed row, all10identities apply.
2. `testVineyardChangeStopsRemainingRows`: after a complete first row, A→B prevents remaining applications; first durable row retained.
3. `testVineyardRoundTripCannotReviveOriginalPull`: A→B→A leaves only the first completed row, despite original identity being selected again.
4. `testSameUserAccountIncarnationStopsOriginalPull`: sign-out/same-user rebinding invalidates the original incarnation; only first row persists.
5. `testAccountProviderChangeStopsRemainingRows`: provider identity changes invalidate remaining work.
6. `testFetchSuspensionRejectsSelectionRoundTripBeforeFirstApplication`: an A→B→A transition while the repository fetch suspends results in zero applications.
7. `testRowPersistencePrecedesMetadataAndNextRow`: independent disk hooks assert row-persistence → metadata-persistence → row-complete for each of3rows, with no interleaving row mutation inside that sequence.
8. `testScheduledResultsMatchUnscheduledProductionPrimitiveAndRetainPendingCompletion`: byte-equivalent encoded in-memory and reopened records against the original unscheduled production store primitive, with recorded counts, weight evidence, completion dates, vine counts and damage flags preserved; pulled draft still cannot clear the pending completion token or overwrite completion. Existing independent calculation suites are rerun unchanged, not replaced by this comparison.

### Exact serial validation

All selectors below are under `VineTrackTests/`. Successful managed calls return aggregate counts, not per-case discovery/skipped metrics. Overlapping runs are not summed.

- Initial focused `HomeSyncPerformanceTests`, `YieldPullResponsivenessTests`: **7passed/2failed**. Strict Home passed on this first production correction. Both failures were new test fixture setup errors: the separate metadata/control subdirectories were missing, so metadata-write events and control rows were absent. Only directory creation in the tests was corrected; no production behavior, threshold or comparison expectation was changed to make these pass. Historical log was `/tmp/rork-swift-test-ios.log` at that call; later contents are not that preserved run.
- Corrected new suite alone: **8passed in37s**.
- Final Home/Yield/Trip selection: **145passed in21s**. Exact selectors: `HomeSyncPerformanceTests`, `YieldPullResponsivenessTests`, `TripPullResponsivenessTests`, `YieldBunchWeightsManagementTests`, `CurrentYieldMasterParityTests`, `YieldMasterWeightCacheTests`, `YieldCompletionPersistenceTests`, `YieldVintageReportTests`, `YieldAuthoritativeVineCountTests`, `SeasonYieldDamageParityTests`, `PruningYieldSettingsTests`, `PruningYieldSettingsRevisionSyncTests`.
- Separate isolation/recovery/authority/batching/switch selection: **267passed in26s**. Exact selectors: `EquipmentVineyardIsolationTests`, `VineyardMutationAdmissionTests`, `VineyardWriteAuthorityTests`, `ReadOnlyEntitlementContractTests`, `EntitlementAccessRegressionTests`, `EntitlementDecisionTests`, `ActiveTripRouteRecoveryTests`, `DeviceTripOwnershipTests`, `SpraySaveForLaterTests`, `LegacySprayPairReceiptTests`, `TripOccurrenceJournalTests`, `SavedChemicalBatchReconciliationTests`, `WorkTaskBatchReconciliationTests`, `PreparedVineyardSelectionTests`, `VineyardSwitchPerformanceTests`, `MaintenanceDurableRecoveryTests`, `PruningResourceRecoveryAcceptanceTests`, `SyncQueueRegressionTests`, `SyncCompatibilityTests`, `OfflineQuickActionsTests`.
- Final `runChecks(ios)`: **PASS, iOS simulator build**. Two pre-existing direct-storage-URL advisories remain untouched. No Release build, physical install, version/configuration change, upload or backend operation.
- Bounded visible Home report check: **PASS,2/2visible criteria**, after one Home-picker tap. It ran on a **separate billed iPhone simulator**, not the selected Android preview. Screenshots prove only the displayed synthetic numeric report above; not finger smoothness, hidden state or input/render-frame latency. The invocation again supplied an undocumented `setup.configured` object rather than the prescribed launchArguments schema; visible evidence establishes the screen shown, not valid launch-argument delivery. No repeat of that already-successful check is needed.
- Whitespace check `git diff HEAD --check`: **PASS**. Android, shared files, loading/selection/access source and calculation implementations have no diff in this pass; Android was not rerun. Prior Android performance evidence remains accepted, not newly executed evidence.

### Exact source manifest

Three changed/new iOS source/test files; the existing Home strict test is unchanged. Managed history/simulator records and this report/plan are excluded.

```text
f3704ddf14ab31a62c0f39622041091d5e4a84094515e81fb08a043c39c7578d  ios/VineTrack/Backend/Sync/OperationsSyncServices.swift
9b4e7103afd2fae1b9a422267ecc448bf5a1763fdc2beace06f4f94698a03a43  ios/VineTrack/App/SyntheticHomePerformance.swift
077e09214fc787aced85e4fd31ce4fe82eb1eccb0738c57ffd5e867a49aaf841  ios/VineTrackTests/YieldPullResponsivenessTests.swift
```

### Stop condition and final handset gate

**Strict automated Home gate is green. Production changes stop here.** Do not chase the existing18.675ms cold/16.701ms warm synthetic atomic selection commit with more architecture changes. Prepared selection/loading safety remains intact. Actual finger-scroll smoothness during sync, tap→loading surface actually drawn, first accepted input frame and physical vineyard-switch feel are the final handset acceptance checks. No physical-device result or release readiness is claimed. Separate historical safety/backend/release gates elsewhere in this report are not changed by this performance-only closeout.

## iOS mounted Home / full selection continuation — 27 October 2026 — PARTIAL CORRECTION; 16ms ACCEPTANCE REMAINS RED

This section supersedes preceding statements that iOS mounted Home and local access-operation costs are unmeasured. Scope is iOS performance only. Android and shared fixtures are untouched. Yield/Bunch Weights calculations and application, Weather/MAIT, access rules, recovery/receipt ordering, Saved Chemical batching, backend/Portal, versions, signing and release settings remain unchanged. No customer records, authenticated service calls, release build or upload were used.

Starting HEAD: `3dea2d3391cb8aaa5f5b0078ab4c89c37e7f74af`. Requested reference `b3b3b260049240617519685d7c04a6279f64926c` could not be retrieved (`not our ref` / `bad object`); exact comparison to it is unavailable. Accepted performance source present in the checkout was retained without reset/revert. Source hashes below identify this continuation independently of that missing reference.

### What changed and what did not

- Actual `NewHomeTabView` is mounted in an isolated hosting window, with programmatic scroll updates during synthetic store application. Fixture per vineyard: 100 blocks, 2,000 pins, 500 trips/tasks and 250 spray/chemical/maintenance/Yield records. Incoming updates: 200 pins, 100 tasks/chemicals, 50 trips/sprays, 20 maintenance and 10 Yield. A DEBUG-only environment omits the rain transport card, without changing Weather source or normal launches. No live auth or network is required.
- Trip and spray application now yield **between complete rows**; maintenance yields before each complete row. Cancellation, selected vineyard, selection-request generation, account provider, authority identity, account binding and incarnation are checked. A→B→A and same-user sign-out/sign-in cannot resume stale application. Existing per-row conflict/persistence/acknowledgement ordering and admission remain intact; this is scheduling, not new batching.
- Trip cache decoding uses the existing audited worker preparation before a row. Actual repository reads still reread current bytes and reject changed/corrupt memo reuse. The rejected experiment retaining native values immediately after save was removed completely: ISO8601 round-trip semantics must remain authoritative. `LegacyStorage.swift` has no diff.
- Deferred recovery is retained as a cancellable task. New selections cancel prior work, and current generation/vineyard/account/incarnation are checked before both legacy repair and canonicalization. Those repairs still run on Main, now separately measured. Their tested small cost does not establish a bound for arbitrarily large recovery journals.
- Production and the mounted fixture share the exact existing loading overlay: full background, requested vineyard, spinner and disabled underlying hit testing. Its extraction is not a new feature. DEBUG-only measurement hooks cover summary derivation, collection setters, persistence and local access operations.
- The Home vintage calculation was already below16ms and is unchanged. Yield application is explicitly frozen: the observed Yield burst remains a known16ms failure, rather than weakening the assertion or silently omitting it.

### iOS vineyard switch — latest visible mounted capture

Milliseconds; cold is first selection and warm is the maximum of24 subsequent alternating selections. This is an isolated cached-selection fixture, not a successful remote refresh or physical-device claim. Latest visible report: state acknowledgement0.042/0.025ms. Earlier cold commit27.47ms and warm16.09ms are separate historical captures, not a paired comparison with these new values.

| Metric | Cold | Warm |
| --- | ---: | ---: |
| Tap → loading actually drawn | **Unverified** | **Unverified** |
| Snapshot preparation, including suspension/waits | 60.407ms | 0.010ms |
| Atomic authoritative commit, MainActor | **18.675ms** | **16.701ms** |
| Deferred longest stage | 0.088ms canonicalization | 0.076ms canonicalization |
| Loading-state lifetime, not drawn-surface lifetime | 79.375ms | 16.736ms |
| First fully interactive input/rendered frame | **Unverified** | **Unverified** |

Deferred legacy repair separately0.083/0.068ms. Stage durations are nested and must not be added to reconstruct end-to-end values. CADisplayLink samples observe state only; they are not drawn-pixel or accepted-input proof. The loading lifetime ends with cached selection, not remote-sync completion. Atomic commits still exceed16ms and remain an explicit open gate.

Paired warm test uses25 unprepared control switches followed by25 prepared switches in the same test:24 warm observations each, all retained. **Median nonregression within a2ms allowance passed.** Reports retain p50/p95/max/mean, but successful managed test results did not expose attachment numbers. This is not strict zero-regression, randomized-order, p95/max, end-to-end loading or physical-frame nonregression. Do not infer those gates from the passing median assertion.

### iOS Home during sync — strict budget-run evidence

Numbers below come from the explicit before/after budget runs, not from mixing later report-screen captures. The actual Home is mounted, but application invokes production store primitives and the production scheduling helper rather than an entire mocked service/repository pull. Full service reconciliation/metadata costs may be additional.

| Metric | Before | After |
| --- | ---: | ---: |
| Largest uninterrupted measured MainActor stage | **1080.858ms**, 50-trip loop | **29.094ms**, unchanged10-Yield loop — FAIL16ms |
| Individual trip application maximum | 22.780ms | 8.366ms |
| Spray application | 266.406ms uninterrupted50-row loop; row6.137ms | Yielded rows; maximum4.723ms |
| Maintenance application | 104.079ms uninterrupted20-row loop | Yielded rows; maximum5.868ms |
| Pin / task / chemical batch maxima | 19.898 /9.142 /5.490ms | 14.440 /6.285 /3.960ms |
| Home vintage summary maximum | 3.195ms | 2.269ms, unchanged calculation |
| Home overview maximum | 0.474ms | 0.280ms |
| Observable collection setter mutations | 133 | 133 |
| MainActor persistence operations / writes | 286 /133 | 286 /133 |
| Longest measured persistence occupancy | 16.478ms | 12.305ms |

No batch size, persistence-operation or publication reduction is claimed. Setter counts are **not** measured SwiftUI invalidation/render counts. After yielding, vintage computed103times,186.561ms aggregate, with2.269ms maximum; this repeated small work is disclosed, not hidden. The fixture recorded82programmatic scroll updates in that budget run, not actual finger gestures or hardware frame metrics. Later visible Home report maxima1.903–1.907ms are separate samples and do not replace the29.094ms failed acceptance result.

**Home16ms acceptance remains FAIL:** `HomeSyncPerformanceTests/testMountedHomeDuringProductionSyncApplication` retains its original strict16ms assertion. Frozen Yield's10-row burst29.094ms is not corrected under this scope. Whole-collection persistence/repeated per-row application, not an Android-style vintage-date parsing defect, was the material iOS cause. Trip application occupancy is materially improved, but full Home smoothness is not accepted.

### Access attribution — CLEARED AS MATERIAL CAUSE OF MEASURED LOCAL STALLS

Observed budget-run hooks:104account-binding reads, total0.013ms;6effective-role calls, maximum0.031ms, total0.039ms. Separately, a real local-operation stress fixture uses isolated defaults,64synthetic capabilities and32repetitions per operation under each phase label. The phase labels do not simulate an authenticated login or establish actual production frequency. Cache, matrix/legacy role, binding and writable/held outcomes are checked without weakening authorization.

Visible access-report measurements, **maximum / total ms for32operations**:

| Local operation | Switch sample | First Home sample | Sync sample |
| --- | ---: | ---: | ---: |
| Entitlement-cache read | 0.4719 /4.3809 | 0.1306 /3.9971 | 0.1373 /4.0175 |
| Write-authority / hold lookup | 0.0019 /0.0254 | 0.0009 /0.0222 | 0.0008 /0.0219 |

The complete isolated fixture's maximum-operation16ms assertion passed in the264-test selection. On the access screenshot, the switch matrix lookup maximum0.2060ms/total0.3239ms, authority binding0.0014/0.0175ms and role/legacy matrix0.0277/0.1186ms are also small. Local access work is **cleared as a material cause of the measured local switch/Home stalls**; no removed safeguards, authority memo shortcut or policy change. Authenticated-login networking, backend resolution, cold disk under other conditions and customer-device latency remain unmeasured, not exonerated by this sample.

### Serialized validation, historical failures and visible evidence

All Swift selectors below are requested selections; managed success exposes aggregate counts, not per-case discovery or skipped metrics. Overlapping runs are not added into one total.

1. Initial mounted Home fixture compile failed with zero tests: immutable `buttonName` assignment; changed only the fixture mutation to notes. First real budget run then genuinely failed0passed/1failed at1080.858ms.
2. Intermediate scheduling/native-value memo experiment returned0/1 at frozen Yield26.451ms. Native-value memo was subsequently removed. A compile attempt then failed0tests because `persistence` was private in an extension; the existing worker preparation call moved inside its owning store.
3. Corrected preparation/responsiveness/switch selection **10passed in86s**: `TripPullResponsivenessTests`, `PreparedVineyardSelectionTests`, `VineyardSwitchPerformanceTests`. This preceded the added paired warm and access tests.
4. Latest strict mounted Home run **0passed/1failed**,29.094333ms unchanged Yield burst. No unchanged retry or relaxed threshold is represented as green.
5. Focused selection **264passed in152s**, all under `VineTrackTests/`: `VineyardSwitchPerformanceTests`, `PreparedVineyardSelectionTests`, `TripPullResponsivenessTests`, `AccessPerformanceTests`, `PersistencePerformanceTests`, `PerformanceValidationTests`, `EquipmentVineyardIsolationTests`, `VineyardMutationAdmissionTests`, `VineyardWriteAuthorityTests`, `ReadOnlyEntitlementContractTests`, `EntitlementAccessRegressionTests`, `EntitlementDecisionTests`, `OfflineQuickActionsTests`, `ActiveTripRouteRecoveryTests`, `DeviceTripOwnershipTests`, `SpraySaveForLaterTests`, `LegacySprayPairReceiptTests`, `TripOccurrenceJournalTests`, `SavedChemicalBatchReconciliationTests`, `WorkTaskBatchReconciliationTests`.
6. Broader selection **209passed/1failed**, all under `VineTrackTests/`: `YieldBunchWeightsManagementTests`, `CurrentYieldMasterParityTests`, `YieldMasterWeightCacheTests`, `YieldCompletionPersistenceTests`, `YieldVintageReportTests`, `YieldAuthoritativeVineCountTests`, `SeasonYieldDamageParityTests`, `PruningYieldSettingsTests`, `PruningYieldSettingsRevisionSyncTests`, `MAITCurrentObservationTests`, `MAITSupplementarySensorTests`, `CurrentObservationProviderTests`, `RegionFormatterWeatherParityTests`, `MaintenanceDurableRecoveryTests`, `MaintenanceForegroundAdmissionTests`, `MaintenancePhotoAdmissionTests`, `PruningResourceRecoveryAcceptanceTests`, `SyncQueueRegressionTests`, `SyncCompatibilityTests`, `MobileRequestSyncSafeguardTests`. Failure: `healthyBatchUsesFastPath()` expected1call but received22, because its fixture generated22different vineyards and existing access safety intentionally isolates mixed scopes. Production batching/rules were not changed. The healthy-batch fixture now shares one synthetic vineyard; affected `SyncQueueRegressionTests` then **12passed in135s**. The original broader run is still recorded as failed, not retroactively green.
7. Final separate UI selection **4passed in212s**: `VineTrackUITests/YieldTripNavigationUITests`, `VineTrackUITests/LegacySprayRecoveryUITests`.
8. Final source `runChecks(ios)` **PASS**, simulator build, after the debug report's separate sections/direct access launch route. Earlier builds also passed. The two pre-existing storage-URL advisories remain untouched. No release/device validation or upload.
9. `git diff HEAD --check` **PASS**. Android/shared source diff is empty. Android was **not rerun**: retained historical acknowledgement≈7ms, preservation onIO, publication≈1ms, warm≈8–12ms and corrected Home16ms assertion remain the earlier evidence, not new results. Earlier Android focused7/0/0, separate34/0/0 and host60/95/52/209/55 green results are retained without summing overlaps.

Visible fixture checks ran on **separate billed iPhone simulators**, not the selected Android preview. First combined report check failed overall: switch/Home visible, Access not reached. After splitting the report into native sections, the second combined check also failed overall with Switch/Home visible but Access not reached. Those failures are retained; their switch/Home screenshots support only the specific reported numeric text. After adding direct Access selection in the debug report, a separate bounded Access-only check **passed1/1visible criterion**, including the numeric cache/hold values above. Invocations used an undocumented `setup.configured` object rather than the required launchArguments shape; screenshots establish the screen actually shown, not correct launch-argument delivery or use of the new route. Do not repeat that setup form. Runtime-log search did not supply the fixture reports, so successful test attachments were not fabricated into exact numerical evidence.

### Exact changed iOS source/test manifest — SHA256

Configuration, Android, shared fixtures and `LegacyStorage.swift` are unchanged. The20files below exclude this report/plan and unrelated managed `.rork` history/fingerprint updates. No managed history was edited manually.

```text
433d17c1bd1160d069f6197b4625345e935460469bd2eb5b6bdc9834f6e2dd85  ios/VineTrack/App/BackendAccessControl.swift
993eaa78c2be046fd5a2072eaf12341d49e239360d96a79c7317fa012e233757  ios/VineTrack/App/NewMainTabView.swift
3095302965b4f0bd12fd3c5de7e35d7552438e7053f7f8769f72b03a63446862  ios/VineTrack/App/PerformanceCapture.swift
20ee7447a00e3990d04f3386adcf08762991c19476f8fe925f24e8a429b651ab  ios/VineTrack/App/SyntheticAccessPerformance.swift
cbf8bd581ec9e3cf8c437ac5fc5a37d44f3cc9e717e361c557d98197701b8c55  ios/VineTrack/App/SyntheticHomePerformance.swift
cf7cf27a796bdbc369f67fed2b265b280c063ecf7daf413eaef871f05a9c8212  ios/VineTrack/App/SyntheticSwitchPerformanceView.swift
236a71daacdb3211d961470a7e66d8b2b5d709bb49219c1dfc81f50642f1fb9b  ios/VineTrack/App/VineyardLoadingPresentation.swift
42a98ad83182b944d6d2bff2d431023f610862eda236373fd8e7447929003ae3  ios/VineTrack/Backend/Subscription/EntitlementVerificationStore.swift
e724df1c5061665e06ce2984059346966e1a688dbc400c967d2dbabfc3b63838  ios/VineTrack/Backend/Subscription/VineyardWriteAuthority.swift
08991828ba1914bed0b36d3c896415147dd0eb5754ac5de9ccd2dfea01dc6da0  ios/VineTrack/Backend/Sync/OperationsSyncServices.swift
f99eb690e9314efe5f62d99ffecd84852b74b004e6e8e40b96069d27da468082  ios/VineTrack/Backend/Sync/ResponsiveRemoteApplication.swift
85f157b676c8daaa4d2966e1a7c5642c4e7ad73a1d0d563df2d3064b03af2182  ios/VineTrack/Backend/Sync/SprayRecordSyncService.swift
d971b98864bcff5643e23bded593ceda7b6efcc523cff73c53a21ed371391ba7  ios/VineTrack/Backend/Sync/TripSyncService.swift
f6e5adecf3437b3c5ac11864616796955d2abc18d6d2397c8aa12ea4269918bd  ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift
66b5b2cab2e55c2c035c301d0192bb4e0e46044ca8b309bc407c8700ea0ad68e  ios/VineTrackTests/AccessPerformanceTests.swift
ee5db1016848e97d806d703d2e25060b29bf3dfac559e9712847d3d2475dfcdc  ios/VineTrackTests/HomeSyncPerformanceTests.swift
f1ae87a0207caf48d8a5e75eece316317427ac6faf805bd624b4530583c9efc0  ios/VineTrackTests/PreparedVineyardSelectionTests.swift
dec0abaf702b82c40f8b89c50b50346fe83b450b383c3bdd9911061d463de2a2  ios/VineTrackTests/SyncQueueRegressionTests.swift
73baf64f34b3e7b4090ef86bda320d58c5957e1cde11cf7731b097545ae50c1f  ios/VineTrackTests/TripPullResponsivenessTests.swift
14cdd51e585bce03622422df1391ede3fc18ad934635414647b3205eb9e0ce4c  ios/VineTrackTests/VineyardSwitchPerformanceTests.swift
```

### Completion gates

**Not complete / no release clearance.** Remaining: the unchanged29.094ms Yield burst; atomic selection18.675/16.701ms; full real-pull reconciliation/metadata application measurement; actual loading pixels and accepted-input frames; strict warm-tail/end-to-end nonregression; physical iPhone/Android scrolling/switching. Local access attribution is cleared only within the measured scope. No physical devices were attached. The existing overall performance and physical plan gates remain unchecked.

## Cold-switch and Android Home continuation — 27 October 2026 — MATERIAL IMPROVEMENTS; FULL PERFORMANCE ACCEPTANCE STILL OPEN

This supersedes the preceding warm-only checkpoint where explicitly measured below. Performance only: accepted Yield/Bunch Weights, Weather/MAIT, Saved Chemical batching, access/read-only policy, original recovery evidence, backend/Portal, versions, signing and releases remain unchanged. No customer/backend data was used. Starting HEAD is `07dde3babbb2361e2696b30893cffd94b7770c14`. Performance sources matched requested reference `ec48c6c3b0605b01ff8545c44ee074a16f6ffe54`, apart from the pre-existing Config.swift deletion. No reset or revert was performed.

### Boundaries and safety changes

- **A — acknowledgement:** Android publishes the selected ID, cleared old scoped data and loading state immediately. iOS publishes a requested-vineyard/loading presentation immediately, but retains the complete previous operational selection until atomic hydration. Neither callback assertion is a two-visible-frames measurement.
- **B — synchronous UI work:** separately measured from suspended worker spans. `main=true` on an including-waits span describes its completion thread, not continuous blocking.
- **C — cached availability:** Android waits for durable preservation before cache publication; iOS waits for audited worker predecode, then performs its final authoritative atomic reload. These waits are not UI callback latency. Exact current C values were not returned by successful aggregate runners and must not be reconstructed by adding nested timings.
- **D — refresh completion:** the original switch fixture intercepts every request with503; its load lifetime is failed-refresh settlement, NOT successful remote completion. The separate mounted Android Home fixture supplies five successful real repository collection responses per switch; other endpoints still fail locally. No live network or full successful sync sweep is claimed.
- Android freezes raw cache, strict outbox, active-trip and pin-evidence sources before its first suspension. Pin evidence includes retained recovery-file bytes/errors and acknowledgement/unproven relationships. Existing decoding/assembly/encoding/durable commit then runs on IO. A shared nonblocking first-capture reservation spans asynchronous and existing synchronous callers. Failed preservation still prevents remote mutation/reconciliation; cancellation and original FieldStoreAccess admission remain in force. Existing exact-byte memos, corrupt-original refusal and unproven-first-byte durability handling were not replaced by memory-read proof.
- Android cached pin reconciliation and other display overlays now prepare on Default. Publication validates account/incarnation, vineyard/selection epoch/load generation, current source bytes, fresh pending contents and referential identity of affected collections. An intervening foreground/GPS/outbox change invalidates speculative cache publication rather than overwriting it. New probes include both initial and final Main validation; exact timings for these new probes were not returned by the passing runner.
- iOS prepares existing audited Sendable collections without sending the observable store/repositories across actors. No await splits final operational selection/hydration. The loading overlay hides old content and blocks its hit testing during preparation; GPS/sync retain the previous complete slice until commit. Interactive menu/list/Return-to-Trip routes use this path. Noninteractive and other existing synchronous paths remain unchanged. This is audited predecode plus final reload, **not a complete all-collection background snapshot**.
- iOS legacy spray recovery and grape canonicalization defer until after a yield only on this prepared path, with committed generation/account/incarnation/vineyard checks. Existing sync/write preflights remain independent. Clear-store and actual default-selection transitions invalidate preparation generations, including a default A→B→A round trip.

### Android — Stage | Before | After | Thread | Publications

All values below are milliseconds. The precise post-overlay numbers are from the executed four-passing-test portion of a run whose overall result was4 passed/1 class-selector failure; that overall run is NOT represented as green. Later corrected source selection passed7/0/0. The cold/A and B samples are simulator observations, not paired physical-device guarantees.

| Stage | Before | After | Thread | Publications |
| --- | ---: | ---: | --- | --- |
| State/call acknowledgement, first A / first B | 926.818 / 727.427 | 7.217 / 5.631 | Main | Synchronous selection3→1 |
| Repeated acknowledgement | 242–251 (three repeated selections) | 4.636 / 3.783 / 3.547 (three repeated selections) | Main | Synchronous selection3→1 |
| Preservation, first A / B | 759.334 / 681.034 synchronous | Freeze1.441 /2.051; worker867.779 /704.212 | Short freeze Main; decode/encode/commit IO | 0 |
| Cached settings, first A | 156.744 synchronous | Worker62.299; authoritative rows/publication15.844 | IO preparation; fresh overlay/publication Main | 1, unchanged stage |
| Cached overlay preparation | First cold publication83.128 before this additional correction | Worker78.631 cold,14.192–28.220 later | Default, measured off-Main | 0 |
| Cached snapshot publication | 83.128 cold;9.554–16.569 subsequent (preceding cold-refactor capture) | 1.012 cold;0.577–0.789 subsequent | Main; final exact-byte/pending validation still required | 1 |
| D: intercepted503 load settlement, first A | 1768.622 including waits | 1878.477 including waits | Suspended coroutine; completion Main | 4 in overlapping lifetime, unchanged |

The preservation worker is not faster in elapsed time; removing it from Main is the improvement. Final successful tests preserve the all-five-selection32ms callback requirement. They do not enforce16ms on every hydration/validation/persistence stage or measure actual drawn acknowledgement frames. The Main settings sample15.844ms leaves little margin. No successful remote-latency speedup, universal32ms hydration total, or full end-to-end warm nonregression is claimed.

### iOS — Stage | Before | After | Main thread before | Main thread after

Cold / maximum of four subsequent selections, milliseconds. The visible post-change report was verified on a separate billed iPhone simulator at13:32 UTC, not the selected Android preview. The invocation mistakenly supplied an undocumented setup object rather than the required launchArguments shape; the returned screenshot nevertheless directly verified the fixture title and numerical summary. This is visible report evidence, not proof of launch arguments, user interactions or frame latency. Do not repeat that setup form in later runs.

| Stage | Before | After | Main thread before | Main thread after |
| --- | ---: | --- | --- | --- |
| Presentation acknowledgement | No separate visible-frame measurement | All-five state-boundary assertions<32ms; precise values not retrieved | Synchronous selection | Immediate Main presentation; drawn frames unmeasured |
| Core records | 53.09 /4.71 | 7.45 /5.11 | Yes | Final reload Main; audited decode prepared on worker |
| Spray records | 4.38 /3.82 | 5.00 /4.11 | Yes | Yes; not moved by this correction |
| Chemical / spray reference | 10.11 /0.39 | Full after row not retrieved | Yes | Chemical audited decode prepared; final reference hydration Main |
| Yield | 4.19 /2.66 | Full after row not retrieved | Yes | Yes |
| Block / equipment / buttons | 2.23/0.45;0.98/0.66;2.16/1.13 | Full after rows not retrieved | Yes | Audited block decode prepared; final hydration Main |
| Atomic publication / total blocking | 82.51 /15.47 | **27.47 /16.09** | Yes | Yes, bounded complete commit; preparation wait excluded |
| Legacy recovery / canonicalization repairs | 0.61/0.03;0.79/0.47 | Outside prepared first commit; later duration unmeasured | Yes | Still Main, deferred and fenced after yield |

The cold commit improved about66.7% in these separate simulator captures. The warm maximum16.09ms is0.62ms above the earlier15.47ms; these are not paired/JIT-controlled physical measurements, so strict warm nonregression is **not established**. A pass proves the fixture's32ms atomic-commit assertions, not every16ms stage target. Changed-byte memo preparation can still fall back to authoritative Main decode because the existing preparation skips populated memo entries; legacy/ineligible collections also remain synchronous. Those known limitations and other synchronous callers prevent a universal cold-switch completion claim.

### Home during sync — separate table

| Platform / stage | Before | After | Thread / publications / persistence / batch |
| --- | --- | --- | --- |
| Android Home vintage summary | **223.135ms** first populated computation; later populated computations35.716–82.536ms | Executed unchanged **≤16ms Main budget** now passes; exact after timings not exposed | Date filtering/block tally moved to Default; result matches account/vineyard/season and collection identities; cancellation prevents late display |
| Android Home overview | 0.006–0.325ms | Same calculation retained;≤16ms assertion passes | Main; not a demonstrated bottleneck |
| Android sync application / cache persistence | Five real collection responses per selection | Same25 successful collection requests over five selections; remote titles verified |3,350 remote records/selection;2,850 summary inputs. No per-row batching, publication-count reduction or persistence-operation reduction claimed |
| iOS Home rendering during application/scroll | **Not measured** | **Not implemented/verified in this continuation** | Existing Home date filtering and per-row spray/trip sync remain candidates only |

Android fixture mounts the actual HomeDashboard and sends real scroll gestures while the production load is active, including large responses through real repositories/overlays/cache application. Every successful body is synthetic and every other request is intercepted; no network fallback. A first test exposed a fixture-only missing JSON ContentNegotiation plugin; after restoring the existing production-compatible plugin the remote-title assertion passed. Adding the legitimate16ms Home derivation budget then reproduced0 passed/1 failed with the223.135ms Main stage. That same assertion passes after the correction.

Only summary preparation changed: labels/layout/date semantics and source collections remain the same. While a new exact input is computing, summary values briefly show an unavailable dash rather than stale counts from another input. These derived counts cannot authorize a write, change evidence or acknowledge a pending operation. Unrelated publications reuse the identity-keyed preparation instead of reparsing dates. This adds a local presentation-result update; it does **not** reduce sync StateFlow publications or persistent writes.

Important limits: gestures during a load do not prove that a finger gesture overlapped the final publication/persistence span. No hardware frame metrics, FPS, long-frame distribution or visible two-frame acknowledgement assertion was added. The final remote-application reconciliation/serialization stages are not independently bounded below16ms. Android Home's measured expensive derivation is materially improved, but full Home-during-sync contention acceptance and iOS Home remain open.

### Root causes proven

1. **Android cold recovery codecs/durable preservation on Main:** freezing original evidence before suspension and retaining the durable gate reduced observed cold call acknowledgement926.8ms to7.2ms without allowing remote work before preservation.
2. **Android cached pin reconciliation on Main:** moving immutable display overlays to a worker reduced the observed cold publication83.128ms to1.012ms. Main revalidation remains necessary and newly separately instrumented.
3. **Android Home vintage derivation:** real mounted Home computation took223.135ms after cached collection publication and35.716–82.536ms subsequently. Moving that read-only calculation off Main changes the same executed16ms Main-stage failure to a pass.
4. **iOS cold core hydration:** audited predecode reduced measured Main core53.09ms to7.45ms and cold atomic commit82.51ms to27.47ms. This does not attribute every collection cost to JSON or establish a full background snapshot.

### Apple Portal Login / read-only conclusion

No login, Portal or read-only safeguard was removed. Existing final access/isolation selections pass, but operation-level entitlement-cache, access-matrix, hold-ledger and binding counts/timings were **not captured in this continuation**. The six prior commits remain source candidates, not proven causes or exonerated paths. These measurements support neither blaming Apple Portal Login nor declaring its added work negligible. Awaited network time must not be called synchronous UI blocking. Access-cost attribution remains an independent open goal.

### Serialized validation — exact current-source results

- Android focused managed selection: **7 passed/0 failed/0 skipped in32s**. Exact selectors: `com.rork.vinetrack.data.VineyardSwitchPerformanceAndroidTest` (callback fixture plus mounted Home fixture), `com.rork.vinetrack.data.PreparedRecoveryAndroidTest`, `com.rork.vinetrack.data.SavedChemicalDecodeMemoAndroidTest`. Frozen-source original bytes survive a suspended source change; concurrent capture refuses; rejected ordinary account transition revokes prepared commit; corrupt originals remain untouched; legacy chemical-generated identities/current bytes remain authoritative. Class-level aggregate result does not supply numeric successful attachments.
- Android separate final device regressions: **34 passed/0 failed/0 skipped in18s**. Exact selectors: `com.rork.vinetrack.data.OfflineQuickActionsAndroidTest`, `com.rork.vinetrack.data.ReadOnlyEntitlementCacheTest`, `com.rork.vinetrack.data.YieldMasterWeightCacheAndroidTest`, `com.rork.vinetrack.data.YieldTripNavigationAndroidTest`, `com.rork.vinetrack.data.MAITCurrentObservationAndroidTest`, `com.rork.vinetrack.data.auth.RetainedStartupConstructionTest`.
- Android host: recovery/chemical **60/0/0/0,18.177s**, Yield **95/0/0/0,18.651s**, weather **52/0/0/0,22.593s**, authority/isolation **209/0/0/0,10.516s**, startup/offline **55/0/0/0,10.852s**. Commands are the unchanged `run-switch-performance-regressions.py`, `run-yield-completion-tests.py`, `run-mait-mobile-contract.py` with outputs `/tmp/vinetrack-cold-home-{recovery,yield,weather}`. Exact host class lists remain those recorded in the preceding checkpoint and checked into these runners. Results overlap and are not summed.
- iOS focused switch/storage/access selection: **136 passed in137s**. Exact selectors, all `VineTrackTests/`: `PreparedVineyardSelectionTests`, `VineyardSwitchPerformanceTests`, `PersistencePerformanceTests`, `PerformanceValidationTests`, `SavedChemicalBatchReconciliationTests`, `EquipmentVineyardIsolationTests`, `VineyardWriteAuthorityTests`, `ReadOnlyEntitlementContractTests`, `OfflineQuickActionsTests`, `ActiveTripRouteRecoveryTests`, `DeviceTripOwnershipTests`, `SpraySaveForLaterTests`. Includes superseded preparation, clear-store invalidation and default-selection A→B→A rejection. New preparation-only selection separately3 passed in150s is overlapping, not additional coverage.
- iOS separate accepted-feature selection: **192 passed in54s**. Exact16 selectors are unchanged from the preceding192 selection: `YieldBunchWeightsManagementTests`, `CurrentYieldMasterParityTests`, `YieldMasterWeightCacheTests`, `YieldCompletionPersistenceTests`, `YieldVintageReportTests`, `YieldAuthoritativeVineCountTests`, `SeasonYieldDamageParityTests`, `PruningYieldSettingsTests`, `PruningYieldSettingsRevisionSyncTests`, `MAITCurrentObservationTests`, `MAITSupplementarySensorTests`, `CurrentObservationProviderTests`, `RegionFormatterWeatherParityTests`, `EquipmentVineyardIsolationTests`, `SavedChemicalBatchReconciliationTests` under `VineTrackTests/`, plus `VineTrackUITests/YieldTripNavigationUITests`. Skipped/per-case discovery metrics are not returned; overlapping results are not summed.
- Final iOS source `runChecks(ios)` **PASS**, simulator build. No subsequent iOS source edits; the unchanged-source regression selections above followed that build. Two pre-existing direct-storage-URL advisories remain untouched.
- Separate final Android **Debug-only build PASS**, exit0 in**9.121s**, `python3 scripts/run-yield-completion-tests.py --debug-build --output /tmp/vinetrack-cold-home-final-debug`. Generic Android runChecks was not run because it builds Release, prohibited by this task. No Release assembly, store upload, physical-device installation or version/configuration operation.
- `git diff --check HEAD` **PASS**. Numerical temporary evidence copied to `/tmp/vinetrack-pre-overlay-2026-10-27.log` and `/tmp/vinetrack-home-before-2026-10-27.log`; this report retains the durable values. Success does not refresh the managed failure-log file; do not mislabel a retained older failure log as a newer passing run.

Historical development failures retained, not counted as passes: first recovery/device selection5 passed/1 failed because ordinary different-user SessionStore replacement was correctly denied; corrected the test to assert denial rather than relaxing policy. A later4 passed/1 failed run used nonexistent `SavedChemicalLocalStoreAndroidTest`; corrected the selector to the existing decode-memo class. The first mounted Home selection2 passed/1 failed lacked the fixture JSON plugin; no production parser changed. The legitimate before-optimization Home budget failure was0/1/0. A host runner initially could not create its output subdirectory because its /tmp parent was absent; created that parent, then executed all three host stages successfully. No product assertion was disabled or budget relaxed.

### Exact source manifest

Native/test/harness diff SHA-256 against starting HEAD, `git diff HEAD --binary -- ios android-vinetrack scripts`: **`7b18d806a71a196967ce64013db39fdddac27663bfceb3e5a803acd03307a0a1`**. Exact16 files (this report, existing plan and tool-managed simulator state excluded):

- `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/PreparedRecoveryAndroidTest.kt`
- `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/VineyardSwitchPerformanceAndroidTest.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/ActiveTripStore.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/DomainCacheStore.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PendingWriteStore.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PinCaptureEvidenceStore.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/RecoverySnapshotStore.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/HomeDashboard.kt`
- `ios/VineTrack/App/NewMainTabView.swift`
- `ios/VineTrack/App/SyntheticSwitchPerformanceView.swift`
- `ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift`
- `ios/VineTrack/LegacyImported/Views/Trips/TripView.swift`
- `ios/VineTrack/LegacyImported/Views/Vineyard/BackendVineyardListView.swift`
- `ios/VineTrackTests/PreparedVineyardSelectionTests.swift`
- `ios/VineTrackTests/VineyardSwitchPerformanceTests.swift`

### Remaining physical-device gate

**NOT COMPLETE / NO RELEASE CLEARANCE.** Cold callback/commit blocking and one measured Android Home hotspot materially improved; this is not full both-platform Home acceptance. Still required: mounted iOS Home during representative real application batches, independently timed remote application/persistence and complete hydration/validation stages, actual drawn acknowledgement/frame measurements, strict warm nonregression, measured entitlement/authority/hold/binding attribution, and physical iPhone/Android confirmation. Android rapid A→B→A/identity-incarnation races at every new overlay publication boundary also lack a new deterministic end-to-end device fixture; existing guards and focused recovery/isolation tests are not that journey. No physical device is attached, and simulator smoothness is not physical smoothness. Keep the corrective-performance and Home/physical plan goals unchecked until those done-when conditions hold.

## Measured mobile responsiveness — 27 October 2026 — PARTIAL WARM-SWITCH IMPROVEMENT; COLD/HOME/PHYSICAL GATES OPEN

This section supersedes the earlier absence of switch timing evidence, not the accepted feature behavior. No backend, Portal, customer-data, access-policy, version, signing, release configuration or release-artifact changes. No ordinary authentication bypass. The isolated fixtures use local synthetic contents and intercepted-only Android HTTP, never a real customer account. Requested accepted baseline `1c837a738bf69a018bdc9fae3ef36060b318747d` was unavailable (`not our ref` / `Not a valid commit name`); no reset/revert was attempted. The clean starting revision `6893beb87cf6ab3e6f96f0de1cfc99551d6bc23d` plus stage instrumentation is the measured baseline. These results do not retrospectively prove performance at the unavailable accepted revision.

### Fixture and measurement boundaries

- iOS: real `MigratedDataStore.selectVineyard`, fresh temporary injected persistence, seeds written AFTER store initialization. Per vineyard: 2,000 pins, 500 trips, 500 Work Tasks, 250 spray records, 250 Saved Chemicals, 250 maintenance records, 250 Yield sessions, 100 blocks and 50 tractors; 20 pins have 16 KiB synthetic photo data. A/B/A/B/A selections. Assertions verify counts and pin vineyard ownership. No sync sweep/network included. Buttons now use the store's injected persistence instead of shared persistence; production default injection is unchanged.
- Android: real `AppViewModel.selectVineyard` with isolated preference/file namespace, synthetic authenticated-offline state, intercepted 503-only Ktor transport. Per vineyard: 2,000 pins, 500 trips, 500 Work Tasks, 250 spray records, 250 Saved Chemicals, 250 maintenance records, 250 Yield sessions, 100 blocks. Equipment/images not seeded. A/B/A/B/A; wait for cached collection counts and load settlement. Existing startup occurs before isolated seeding. This is a substantial switch fixture, not a Home-rendering, equipment-complete or live-network benchmark.
- Android stage milliseconds are synchronous elapsed spans except `background-load-including-waits`, which includes suspensions and its initial synchronous recovery work. `main=true` there describes the completion thread, NOT proof its entire elapsed duration blocked UI. Publications count successful changed StateFlow CAS transitions, not retries, collection count or Compose renders. Nested span publication totals must not be added.
- iOS timings below are the second simulator baseline capture: cold first selection / maximum across four subsequent selections. Stage maxima can belong to different selections and must not be summed. No iOS performance correction or new after-timing capture was made in this checkpoint. Two earlier successful visible captures used separate per-minute-billed iPhone simulators rather than the selected Android preview. Their submitted setup object was not in the documented launch-argument shape; the tool nevertheless reported success and visible timing evidence. Future fixture runs must explicitly pass `launchArguments: ["--keyboard-validation", "--synthetic-switch-performance"]`.

### iOS — Stage | Before ms | After ms | Main thread before? | Main thread after?

`—` means no remediation/after measurement, not zero or an implied improvement.

| Stage | Before ms (cold / warm max) | After ms | Main thread before? | Main thread after? |
| --- | ---: | --- | --- | --- |
| Entry | 0.00 / 0.00 | — | Yes | Not remeasured |
| Core records | 53.09 / 4.71 | — | Yes | Not remeasured |
| Spray records | 4.38 / 3.82 | — | Yes | Not remeasured |
| Legacy spray recovery | 0.61 / 0.03 | — | Yes | Not remeasured |
| Chemical/spray reference | 10.11 / 0.39 | — | Yes | Not remeasured |
| Yield records | 4.19 / 2.66 | — | Yes | Not remeasured |
| Block cache | 2.23 / 0.45 | — | Yes | Not remeasured |
| Equipment cache | 0.98 / 0.66 | — | Yes | Not remeasured |
| Button cache | 2.16 / 1.13 | — | Yes | Not remeasured |
| Variety canonicalization | 0.79 / 0.47 | — | Yes | Not remeasured |
| Selection total | **82.51 / 15.47** | — | Yes | Not remeasured |

The demonstrated largest iOS cold UI stage is core-record hydration, 53.09 ms. Selection remains synchronous MainActor work; the fixture has no independent background completion or Home scroll measurement. Existing speculative persistence preparation does not by itself provide safe asynchronous central-store hydration: publishing cleared writable slices before their complete load can race foreground edits/GPS/sync and overwrite existing evidence. No blanket actor/Sendable or observable-store worker move was made.

### Android — Stage | Before ms | After ms | UI publications before | UI publications after

Paired **third selection, A** (index2), after both vineyards were first visited. Both captures enable the same debug stage recording and preserve the same synchronous production ordering. All synchronous stages below still execute on main.

| Stage | Before ms | After ms | UI publications before | UI publications after |
| --- | ---: | ---: | ---: | ---: |
| Selection clear | 0.790 | 0.825 | 1 | 1 |
| First quick actions | 0.140 | 0.175 | 0 | 0 |
| Cached settings/chemicals | **41.465** | **8.330** | 1 | 1 |
| Decoration kickoff | 0.743 | 0.858 | 0 | 0 |
| Repeated quick actions | 0.157 | 0.229 | 0 | 0 |
| Recovery preservation | **202.776** | **0.147** | 0 | 0 |
| Synchronous selection call | **247.037** | **11.603** | 3 | 3 |
| Load lifetime, including waits and recovery | 967.488 | 724.515 | 4 | 4 |

All iterations; acknowledgement is measured inside the UI call, settlement includes test/UI scheduling and is not CPU time:

| Selection | Before ack ms | After ack ms | Before settled ms | After settled ms | Before load lifetime ms | After load lifetime ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0, first A | 926.818 | 932.632 | 1945.483 | 1856.820 | 1768.622 | 1667.571 |
| 1, first B | 727.427 | 758.478 | 1533.604 | 1552.011 | 1475.697 | 1476.398 |
| 2, repeated A | 247.046 | 11.613 | 1023.120 | 746.761 | 967.488 | 724.515 |
| 3, repeated B | 242.115 | 9.684 | 989.557 | 734.847 | 934.938 | 714.136 |
| 4, repeated A | 250.992 | 8.486 | 977.534 | 687.432 | 925.917 | 667.479 |

- Repeated selection acknowledgement improved **95.3–96.6%**, from 242–251 ms to 8.5–11.6 ms in this fixture. This is actual reduced synchronous elapsed work, not just a deferred selection return. Publications did not decrease: the synchronous-call span remains3 and overlapping load-lifetime span4. No UI re-render reduction is claimed.
- First-time switches are **not improved**. Cold recovery remains the largest measured blocker: before759.334/681.034 ms, after754.033/693.712 ms. Cold settings/chemicals were before156.744/42.586 ms and after170.496/61.202 ms. No causal regression attribution is inferred from one unpaired cold/JIT capture, but these after values are explicitly not a cold-speedup result. Warm recovery is now0.090–0.147 ms and warm settings/chemicals5.828–8.330 ms.
- The <=32 ms requirement across ALL five selections still fails. Baseline fixture: **0 passed,1 failed,0 skipped**. Partial-after capture with new chemical tests: **2 passed,1 failed,0 skipped**; genuine failure `Selection blocked the UI for >32ms.` It was not disabled, relaxed or converted to a pass. Before log retained at `/tmp/vinetrack-switch-before-2026-10-27.log`; after log retained at `/tmp/vinetrack-switch-partial-after-2026-10-27.log`. The durable numerical report is this section; temporary runner artifacts are not release artifacts.

### Root cause(s) found

1. **Android repeated recovery JSON decoding:** an unchanged immutable snapshot was decoded again for every selection because each capture constructs a new store handle. Removing that repeat reduced the paired recovery stage202.776 →0.147 ms without changing preservation order or durability checks.
2. **Android repeated chemical snapshot decoding:** unchanged local snapshots were decoded repeatedly, with loading/overlay evaluation inside retryable state transforms. Decode reuse and computing once before publication reduced the paired stage41.465 →8.330 ms. Pending-intent overlay and sorting still run fresh; old data is still cleared first.
3. **Cold work remains:** iOS core decode/hydration53.09 ms; Android first snapshot collection/codec/durable preservation about0.7 s. These are measured switch-path costs. Their individual codec/read/fsync shares and connection to the six earlier commits are not yet established.

### Changes made and preserved safety

- Added opt-in bounded DEBUG stage probes and isolated actual-path fixtures. No customer identities or field contents are recorded. Ordinary disabled Android probe operation now avoids deep AppUiState comparisons; only explicit DEBUG captures pay that instrumentation cost.
- Added a thread-safe, bounded exact-source-byte decode memo: recovery permits four entries/24 MiB source-string accounting, chemicals four entries/4 MiB. This bounds retained encoded sources/entry count, not measured total decoded heap. Decode runs outside the short memo lock. Every load rereads actual storage; different, missing or corrupt bytes cannot be replaced by a stale memo.
- Chemical reuse is limited to an exact canonical local re-encoding, so legacy omitted generated rate identities retain their existing decode behavior rather than being frozen by reuse. No input rows are reused directly on save; memo values come from actual decoded bytes. Account/vineyard keys and fresh pending-create/preference overlays remain in force.
- Recovery `commit()` proof, failed/unproven-write tracking, retained first bytes, unreadable-original refusal, first-original ordering, tombstone receipt logic, selection epoch, generation/account fences, read-only admission and error behavior were not weakened. No background snapshot capture, new async publication, hold bypass or queue rewrite was introduced.
- Cold off-main capture was researched but not implemented blindly. It needs an original-incarnation-bound frozen raw snapshot including pin-evidence recovery files and unproven state, plus shared first-capture reservation across refresh/replay/export callers. Current helpers read sources live and do not supply that asynchronous reservation. A simple dispatcher switch can race evidence mutation/account replacement and is not an acceptable correction.
- Existing Yield/Bunch Weights/weather/MAIT calculations and UI are unchanged; iOS Saved Chemical batching remains intact. Multi-vineyard persistence, repairs and grape canonicalization are not removed. iOS buttons honor injected persistence for fixture isolation; default production persistence remains the same.

### Home scroll

**Not measured or corrected in this checkpoint.** The native switch fixtures do not mount/scroll Home during a real sweep. No hitch/FPS/long-frame, Home publication, or before/after scroll result is claimed. Cache decode reuse may remove one repeated switch stall, but cannot establish Home smoothness. Independent Home-during-sync profiling and the next physical iPhone/Android check remain open.

### Apple Portal Login/read-only work

No Apple login, Portal or read-only safeguards were removed/changed. Earlier source inspection of commits `60cacb0300d608495293b69fd3f3860281eb4577`, `04923f6e4a0149d7bd19f7f7718789dda895f256`, `1f9f0d07c77512efe28854508fb6f7a88a96c6f8`, `91f4b3d3d502eab700e71bb5ed46e170fb84e8ed`, `3a20ec8a76b03ed4c9d8da88995c6ca388eece09`, `54d01831d20f2b2985d43e294bdab6b922099f96` remains candidate analysis only. Individual added-operation timings/counts and causal comparison against those revisions were not captured. Awaited ownership network reads are not automatically UI-thread blocking; UserDefaults writes are not proof of synchronous disk flush. No attribution to Apple login is supported by these measurements.

### Final serialized validation

- Android focused host: **60 tests,0 failures,0 errors,0 skipped in167.683s**. `python3 scripts/run-switch-performance-regressions.py`; exact `*.` classes: `ExactBytesDecodeMemoTest`, `RecoverySnapshotStoreTest`, `SyncRecoveryStorageTest`, `SavedChemicalCreateSyncTest`, `SavedChemicalReconciliationTest`, `RecoveryRefusalValidationTest`, `RecoveryPermitSafetyTest`, `SelectiveRecoveryReplayTest`. Output `/tmp/vinetrack-switch-regressions-e6cyb6eg`. Covers byte-change/removal/corruption after memoization, eviction, oversized/ineligible/failed decodes and existing recovery/durable-failure/original-evidence cases.
- Partial-after instrumentation noted above: two chemical-cache checks passed; full responsiveness assertion failed. The warm timing capture preceded only a disabled-probe guard refinement; enabled capture accounting is unchanged. No cold responsiveness pass is claimed.
- Final Android regression instrumentation: **23 passed,0 failed,0 skipped in14s**. Exact selectors: `com.rork.vinetrack.data.SavedChemicalDecodeMemoAndroidTest`, `com.rork.vinetrack.data.OfflineQuickActionsAndroidTest`, `com.rork.vinetrack.data.ReadOnlyEntitlementCacheTest`, `com.rork.vinetrack.data.YieldMasterWeightCacheAndroidTest`, `com.rork.vinetrack.data.YieldTripNavigationAndroidTest`, `com.rork.vinetrack.data.MAITCurrentObservationAndroidTest`. Chemical tests cover actual preference changes/removal/corruption, account/vineyard keys, canonical reuse and legacy generated rate identity. This passing regression selection does NOT include or supersede the failed responsiveness selection.
- Final Android Yield host: **95/0/0/0**, output `/tmp/vinetrack-switch-final-yield-host`, existing `scripts/run-yield-completion-tests.py` selectors unchanged. Weather **52/0/0/0 in22.478s**, authority/isolation **209/0/0/0 in10.826s**, startup/offline **55/0/0/0 in10.525s**, output `/tmp/vinetrack-switch-final-weather-host`; existing `scripts/run-mait-mobile-contract.py` selectors remain exactly those documented in the preceding checkpoint. Do not sum overlapping results.
- iOS performance/storage/isolation selection: **53 passed in153s**. Exact selectors: `VineTrackTests/VineyardSwitchPerformanceTests`, `VineTrackTests/PersistencePerformanceTests`, `VineTrackTests/PerformanceValidationTests`, `VineTrackTests/SavedChemicalBatchReconciliationTests`, `VineTrackTests/EquipmentVineyardIsolationTests`. Aggregate success verifies executed assertions, not new timing output or physical smoothness; the shared fixture retains its string report as an XCTest attachment.
- Final expanded iOS accepted-feature selection: **192 passed in306s**. Exact16 selectors are unchanged from the preceding checkpoint's192 selection (listed immediately below in its validation section). This includes Yield/Bunch Weights, MAIT/current/supplementary weather, equipment isolation, Saved Chemical batching and Yield navigation. Managed tool exposes aggregate pass count/duration, not per-test discovery or skipped count. These overlapping runs are not245 distinct cases.
- Final separate **iOS `runChecks` PASS**, normal simulator build; Device/Release not verified. The two pre-existing unrelated direct-storage-URL warnings remain unchanged. Final separate **Android Debug-only assembly PASS**, exit0 in**8.934s**, `python3 scripts/run-yield-completion-tests.py --debug-build --output /tmp/vinetrack-switch-final-debug`, `:app:assembleDebug`. Android generic `runChecks` was not used because it assembles Release, outside the requested Debug-only scope.
- Shared Yield parity fixtures remain byte-identical with SHA-256 `1b6eda2b9e8efa6189501bd750c90ae0e28e08a44a20052f421e4e01b1d5b818`. Whitespace validation `git diff --check HEAD` passes. No store/release operation.

### Source manifest and remaining gate

Source/test/harness diff SHA-256 against starting HEAD: **`3e9dbe5951efb509baef83035b6b40b79e5205ea2fcd93744ba7278e68d4bb2f`**, computed with `git diff HEAD --binary -- ios android-vinetrack scripts`. Exact16 changed source/test/harness files (excludes this report, existing plan and Rork-managed simulator evidence):

- `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/SavedChemicalDecodeMemoAndroidTest.kt`
- `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/VineyardSwitchPerformanceAndroidTest.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/ExactBytesDecodeMemo.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/RecoverySnapshotStore.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/SavedChemicalLocalStore.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/VineyardSwitchPerformanceProbe.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt`
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/ExactBytesDecodeMemoTest.kt`
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/RecoverySnapshotStoreTest.kt`
- `ios/VineTrack/App/SyntheticSwitchPerformanceView.swift`
- `ios/VineTrack/App/VineyardSwitchPerformanceProbe.swift`
- `ios/VineTrack/LegacyImported/Services/MigratedDataStore+Buttons.swift`
- `ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift`
- `ios/VineTrack/VineTrackApp.swift`
- `ios/VineTrackTests/VineyardSwitchPerformanceTests.swift`
- `scripts/run-switch-performance-regressions.py`

**Performance remains OPEN:** measured Android warm switching materially improved, but cold blocking still fails, iOS has no after correction, Home-during-sync and per-commit authority costs remain unmeasured, and physical-device acceptance has not occurred. Regression/build success is not release clearance or completion of the responsiveness request.

## Mobile UX, shared Bunch Weights and weather — 27 October 2026 — AUTOMATED SOURCE GATES PASS; PERFORMANCE UNPROVEN

This checkpoint supersedes the earlier read-only weight viewer and compact-history presentation, not the accepted Yield calculations or safety contracts. No backend/schema/SQL/Portal changes, customer-row reads, release/upload, signing/configuration or version/build-number changes. Versions remain iOS3.1.9/build139 and Android3.1.9/versionCode12. Metadata-only reads inspected the three existing weight function definitions; they do not establish authenticated live-service behavior.

### Yield UX

- Both hubs expose **Bunch Weights** beside Yield Estimate. The native manager groups canonical planting keys, shows grams and vineyard masters, and expands only planted blocks to show inherited values or explicit overrides. Owners/Managers/Supervisors can edit; other members can view. Existing backend authorization and authoritative read-only admission remain required; this is not UI-only security.
- Existing contracts only: `yield_bunch_weights`, `resolve_yield_bunch_weight`, `upsert_yield_bunch_weight`, `soft_delete_yield_bunch_weight`. Masters send an explicit null `p_paddock_id`; input must be finite, greater than0 and at most5000g. Initial editor values preserve fractional precision. Canonical keys are never substituted with current display names.
- Confirm absence only after complete, counted, authenticated pagination of active rows, stable `updated_at.desc,id.asc`, pages of200 and consistent bounded counts. Reject missing/changing counts, duplicate IDs, wrong vineyard, invalid values and premature empty pages; retain the last confirmed list on failure. Complete confirmed lists update the current-weight resolver caches, with iOS request invalidation and Android serialization under the existing resolver mutex.
- Current precedence remains exact block/key override → vineyard/key master → Not configured. No historical150g/local default, offline mutation queue or speculative success/cache. Delete resolves the actual authenticated row owner before its ID-only RPC. Original-account/incarnation checks fence reads, mutations and publication; editor targets cannot switch to a newly selected vineyard. A confirmed mutation followed by failed list refresh is reported distinctly from an unconfirmed mutation.
- Failed editor saves keep the entered number and provide a refresh-without-discarding-entry action. Android delete failures remain visible in the confirmation dialog with a refresh action. Lost-response uncertainty is stated explicitly; no claim that a failed response proves a server rejection.
- Completed trips now show actual block names, variety names, date, total estimated tonnes or required-weight state and disclosure, with full-row opening. Detailed diagnostics/provenance remain in trip details. Android hoists the history resolver refresh once per list rather than once per row; outer history layouts remain eager. This is a bounded source change, not measured scroll remediation.
- Accepted arithmetic, exact recorded averages, authoritative current vines, contributing mixed-variety completeness, base/damage separation, sampled physical area, completion/replay, historical evidence and GPS logic were not changed.

### Performance — evidence before remediation

- Before application edits, `swiftTest` requested `VineTrackTests/PersistencePerformanceTests` and `VineTrackTests/PerformanceValidationTests`: **23 passed in237s**. The managed result supplied no per-switch, hydration-stage, main-thread or hitch timings. Total runner duration includes build/execution overhead and is not a vineyard-switch benchmark.
- Runtime query `rork-agent logs runtime --limit 100 | rg -i 'performance|vineyard.*(select|hydrat)|main.thread|hitch|freeze'` returned exit1/no matches; older logs were available before79993. No before/after device capture was obtained. Neither tests nor absence of matching logs proves smoothness.
- Source candidates on iOS: synchronous MainActor `MigratedDataStore.reloadCurrentVineyardData` core/spray/yield/block/equipment/button hydration and canonicalization; recovery remains a safety operation. Existing async decode preparation does not remove exact-byte authoritative rereads. On Android: selection quick-action hydration duplication, cache/pending-overlay decoding and saved-chemical/region work inside `_ui.update`; retryable update lambdas must not gain side effects. Existing recovery snapshots are mutating safety work, not speculative reads.
- No central hydration/state-store optimization or guard reversal was attempted without timing evidence. The iOS sync batching around `3097a0859c303f934cd84aef95965283313d4f22` and its regression tests are preserved; central store files are absent from this checkpoint's manifest.

**All six specified read-only/login commits were inspected. Contribution is unproven for each; it is not established that all six—or any one—caused the reported scroll/switch regression.** Added source work is separated below from measured cause:

- `60cacb0300d608495293b69fd3f3860281eb4577`: entitlement snapshot decode/encode and `UserDefaults.set` on existing iOS entitlement-refresh paths; no additional Android matrix fetch in the inspected hunk. `UserDefaults.set` does not establish a synchronous physical disk flush. No direct general-list/hydration rewrite or measured attribution.
- `04923f6e4a0149d7bd19f7f7718789dda895f256`: cached-hold/account binding and per-vineyard verification; writable entries can also be persisted, while existing holds short-circuit trial work. Candidate refresh/cache cost only; no measured switch/scroll attribution.
- `1f9f0d07c77512efe28854508fb6f7a88a96c6f8`: iOS `updatePinNotesDurably` adds whole-pin-cache load/decode and membership scan via `loadAllForDurableUpdate`; Android pending-write eligibility/reset/retention paths add hold checks, recursive payload vineyard scans and original-claim bookkeeping. Ownership reads are awaited network requests, not synchronous network blocking. No measured general-scroll attribution.
- `91f4b3d3d502eab700e71bb5ed46e170fb84e8ed`: iOS per-location authority lookup and active-trip/journal projection resolution; active getter also stops initializing missing journals. Android command admission scans trips and publishes denial state; patch/delete/occurrence transport adds awaited ownership reads. These affect particular active-command/sync paths, not a demonstrated general rendering regression.
- `3a20ec8a76b03ed4c9d8da88995c6ca388eece09`: iOS `PinSyncService.pushPendingConfirmations` adds a synchronous full durable pin load and owner scans; pending-owner/hold and original-evidence bookkeeping adds safety persistence. Pin/Growth batch repositories add sequential awaited authenticated ownership GETs before writes, increasing possible sync latency without blocking the thread on network IO. Android adds active tank/draft/command admission and skips repair while held. No direct general hydration/scroll rewrite; sync overlap remains a profiling candidate, not proven causation.
- `54d01831d20f2b2985d43e294bdab6b922099f96`: iOS maintenance CRUD adds authoritative whole-store/slice reads and synchronous saves on the action path. Android maintenance commands add original-account/owner checks, list scans/restoration and queue coalescing/cancellation; `PendingWriteRepository` synchronizes original-payload scans and durable updates. These are maintenance-action costs; no direct general selection/render rewrite or measured contribution.

Actual physical scroll responsiveness, vineyard-switch before/after stage timings, long-frame capture and causal attribution remain **NOT VERIFIED**. The performance goal stays unchecked. No physical-device access, interactive simulator operation or invented timing claim was used.

### MAIT / Weather

- Both weather roots now use **Current Weather**, **Chosen Sources**, **Weather Providers**. All five providers remain visible: MAIT iNTELLiWeb, Davis, Weather Underground, WillyWeather, Open-Meteo. Provider/source destinations retain the existing configuration controls and role boundaries instead of inventing a new routing system.
- Exact MAIT text: **“Configured in the VineTrack Portal by a Vineyard Owner or Manager”**. Setup, connection tests and controller mapping remain Portal-managed; mobile has no MAIT configuration/disconnect substitute.
- Current sections reuse server-normalized selected observations and supplementary sensors: provider/station/time/status, available metrics,16-point wind compass and missing/unavailable states. Explicit refresh preserves last-known readings, provider-specific errors and MAIT no-newer behavior. Forecast preferences remain distinct from selected station observations; refresh failure does not choose another observation provider.
- New content is recreated on account/incarnation/vineyard scope changes and checks original scope after async reads. Unknown integration/selection reads stay unconfirmed rather than being labelled unconfigured or Automatic. iOS WillyWeather preference loading copies the latest configuration after the await even when it fails, avoiding overwrite of a newer observation selection.
- Normalized observation services, forecasts/rainfall calculations, imported-irrigation labels/records, operational commands and account enforcement are unchanged. Existing service/isolation regressions pass; rendered settings navigation, account-switch UI journeys and live-station no-data/stale/no-newer acceptance remain unexecuted.

### Final executed validation — serialized; do not sum overlapping runs

- **iOS192 passed in159s**. Exact managed selectors: `VineTrackTests/YieldBunchWeightsManagementTests`, `VineTrackTests/CurrentYieldMasterParityTests`, `VineTrackTests/YieldMasterWeightCacheTests`, `VineTrackTests/YieldCompletionPersistenceTests`, `VineTrackTests/YieldVintageReportTests`, `VineTrackTests/YieldAuthoritativeVineCountTests`, `VineTrackTests/SeasonYieldDamageParityTests`, `VineTrackTests/PruningYieldSettingsTests`, `VineTrackTests/PruningYieldSettingsRevisionSyncTests`, `VineTrackTests/MAITCurrentObservationTests`, `VineTrackTests/MAITSupplementarySensorTests`, `VineTrackTests/CurrentObservationProviderTests`, `VineTrackTests/RegionFormatterWeatherParityTests`, `VineTrackTests/EquipmentVineyardIsolationTests`, `VineTrackTests/SavedChemicalBatchReconciliationTests`, `VineTrackUITests/YieldTripNavigationUITests`. Runner returns aggregate passes, not per-test discovery or skipped metric. Earlier new-management-only14 passed in152s is overlapping, not additional coverage.
- Separate final **iOS `runChecks` PASS**, simulator build succeeded. Device/Release success not verified. Two pre-existing unrelated direct-storage-URL warnings remain unchanged.
- **Android instrumentation27 passed,0 failed,0 skipped in11s**. Exact selectors: `com.rork.vinetrack.data.YieldBunchWeightsManagementAndroidTest`, `com.rork.vinetrack.data.YieldMasterWeightCacheAndroidTest`, `com.rork.vinetrack.data.YieldTripNavigationAndroidTest`, `com.rork.vinetrack.data.MAITCurrentObservationAndroidTest`, `com.rork.vinetrack.data.ReadOnlyEntitlementCacheTest`. New management suite separately8/0/0 in7s before expansion; overlapping, not summed. These include production repository/transport and existing trip navigation, not a rendered Bunch Weights/weather-settings test suite or physical acceptance.
- **Android Yield host95 tests,0 failures,0 errors,0 skipped in17.626s**: `python3 scripts/run-yield-completion-tests.py --output /tmp/vinetrack-mobile-ux-final-yield-host`. Exact classes prefixed `*.`: `YieldCompletionPersistenceTest`, `YieldVintageReportTest`, `YieldAuthoritativeVineCountTest`, `CurrentYieldMasterParityTest`, `SeasonYieldDamageParityTest`, `PruningYieldFormulaParityTest`, `PruningYieldSettingsRevisionSyncTest`.
- **Android weather/irrigation host52/0/0/0 in22.064s**, authority/isolation209/0/0/0 in10.578s, startup/offline55/0/0/0 in10.308s: `python3 scripts/run-mait-mobile-contract.py --output /tmp/vinetrack-mobile-ux-final-weather-host`. Weather selectors prefixed `*.`: `MAITCurrentObservationContractTest`, `CurrentObservationRepositoryTest`, `ForecastParityContractTest`, `SprayForecastWindowsTest`, `IrrigationCalculatorFixtureTest`, `IrrigationRegionalAdviceTest`. Authority: `ReadOnlyEntitlementContractTest`, `VineTrackAccessRowCompatTest`, `VineyardWriteAuthorityTest`, `PinPhotoWorkflowTest`, `FertigationMobileWorkflowTest`, `ResistancePlanRepositoryTest`, `ResistancePlanRevisionSyncTest`, `FertigationDomainTest`, `TripOccurrenceJournalTest`, `StartTankCommitCoordinatorTest`, `TripWriteAdmissionTest`. Startup: `RetainedStartupTest`, `SyncRecoveryStorageTest`, `SyncCrashIsolationTest`, `ActiveTripStoreTest`, `OfflineQuickActionsTest`, `TripEndGateTest`. Result evidence under that output's `summary.json` and individual stage `result.json` files.
- Separate final **Android Debug-only assembly PASS**, exit0 in8.803s: `python3 scripts/run-yield-completion-tests.py --debug-build --output /tmp/vinetrack-mobile-ux-final-debug`, `:app:assembleDebug`. Generic Android `runChecks` assembles Release and was deliberately not used under the Debug-only authorization. No release/upload/distribution.
- All three shared parity fixtures retain SHA-256 `1b6eda2b9e8efa6189501bd750c90ae0e28e08a44a20052f421e4e01b1d5b818`; accepted6.8t base/5.56t adjusted fixture expectations remain unchanged. Both staged and working-tree whitespace checks pass.

### Intermediate failures and limits retained

- Initial iOS build failed due to editor catch-variable shadowing; corrected to `self.error`. Earlier passing normal build preceded transport/weather refinements; the final build above validates current source.
- First Android Debug build failed at missing `widthIn` import; fixed. First new instrumentation build then failed on an invalid multiple-variable Kotlin declaration/reserved `override` test variable. Local compile-only diagnostics confirmed the exact test line; split declarations/use `blockOverride`, then8 and expanded27 executed successfully. This was not a production assertion failure.
- First weather host-script invocation stopped before tests because its supplied output root did not exist. Confirmed the missing directory, created it outside the project and reran successfully; no app/test assertion changed.
- New management tests cover real repository admission/paging/cache/encoding and transport interception, not a live server write. Existing trip navigation tests do not prove weight-manager role dialogs, settings provider navigation, live account transitions, full app process-death recovery, physical GPS, VoiceOver/dynamic type or scroll smoothness. No physical/live-service or overall release clearance is claimed.

### Exact source identity and manifest

Baseline `5eca094f0b0921cbc9c09b776ba9c51e94cbcc89` plus managed changes. SHA-256 of `git diff HEAD --binary -- ios android-vinetrack scripts/inspect-yield-weight-contract.py`: **`cb7afdc925589bbd94b334f9f1cf18d1814ec347594d49593874d7901b64490f`**. Final Debug APK SHA-256 **`c74cf7d0c2a3217585c4087fa66aea75a2f5c6057c5fb9bdbbe6636582253a42`**. No manual commit/push; plan/report/Rork-managed state excluded from this19-file source manifest:

- `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/YieldBunchWeightsManagementAndroidTest.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/YieldBunchWeightsRepository.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/YieldMasterWeightRepository.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/CurrentWeatherSettingsSection.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/RainAndForecastScreen.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/WeatherDataScreen.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/YieldEstimationScreen.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/YieldScreen.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/YieldSettingsScreen.kt`
- `ios/VineTrack/App/BackendAccessControl.swift`
- `ios/VineTrack/App/CurrentWeatherSettingsSection.swift`
- `ios/VineTrack/App/WeatherDataSettingsView.swift`
- `ios/VineTrack/Backend/Repositories/YieldBunchWeightsRepository.swift`
- `ios/VineTrack/Backend/Repositories/YieldMasterWeightCache.swift`
- `ios/VineTrack/LegacyImported/Views/Yield/YieldEstimationView.swift`
- `ios/VineTrack/LegacyImported/Views/Yield/YieldHubView.swift`
- `ios/VineTrack/LegacyImported/Views/Yield/YieldSettingsView.swift`
- `ios/VineTrackTests/YieldBunchWeightsManagementTests.swift`
- `scripts/inspect-yield-weight-contract.py`


## Yield master authority and trip parity — 27 October 2026 — AUTOMATED SOURCE GATE PASS

Latest scope was limited to Yield Estimates, Bunch Sampling and shared Master Bunch Weight reads. Accepted completion/outbox safeguards and historical payloads remain intact. No SQL/Portal/server mutation, customer-record access, release/upload, signing/version/build-number change or physical-device acceptance occurred. Read-only deployed schema/resolver metadata was inspected; that is not authenticated live resolver acceptance.

### iOS implementation

- Current calculations and list/detail/report presentation use exact canonical planting keys, authenticated server-confirmed weights and current authoritative vines. Resolver order is exact block/key override, vineyard/key master, then not configured. Name fallback is used only without a stored key. Historical trip weights are displayed separately and never fill missing current authority.
- Every contributing mixed-variety weight is required. Exact recorded averages drive base tonnes; damage-adjusted tonnes remain separate and `applyDamage` chooses presentation without altering observations. Only blocks with recorded counts contribute physical area. Any unresolved sampled block withholds the whole-trip numeric tonnes and Per ha, while observations remain saveable.
- Confirmed cache is scoped by account/vineyard/block/key, fences request UUID and account incarnation, retains last confirmed values on failed reads and replaces availability with confirmed absence. Malformed, mismatched-key, nonpositive/nonfinite or record-ID-free available responses are rejected.
- Final source audit found active legacy calculations in the report overview, session list and archive preparation. These now use current authority; archiving is unavailable for unresolved totals. Past-vintage historical estimate/actual paths and codecs remain unchanged. Report detail explicitly shows Draft/Completed and Current Estimate when applicable. Settings is a read-only shared-master viewer, not a local override editor.
- DEBUG-only launch fixture has dedicated local storage and no shared-default/master reads. Native tests exercise production trips list → resume → Back, completion returning/refreshing the list, completed read-only reopen and real app terminate/relaunch. One process-static fixture store prevents SwiftUI reconstruction from resetting/reseeding completed storage. No production-visible fixture controls were added.

### Android implementation

- Mirrored current engine, confirmed account/vineyard/block/key cache, mixed-variety requirements, exact averages, current vines, damage separation and sampled-area rules. Current trip/list/report summaries and read-only shared-master settings use this engine. Deliberate shared-weight refresh is exposed; historical record totals are labelled archived rather than current estimates.
- Cache captures the original account before waiting on its mutex, sends account-scoped RPC requests and fences synchronous durable commits. Failed cache persistence never publishes newly confirmed values into memory. Account-incarnation and malformed-response tests exercise the production repository with intercepted HTTP only.
- Two native Compose tests use the production workflow and AppViewModel save with isolated preferences/files and HTTP interception. They assert Back returns to trips, completion refreshes the list, recreated outbox retains the original completed trip ID/time/count, and the completed trip reopens without a save action. This is **not Android main-app process-death acceptance**.
- Test composition excludes only the map-preview renderer after an observed emulator microG/Mapbox teardown exception. Normal composition retains the existing map and GPS behavior; map rendering/GPS acceptance is not claimed by these navigation tests. Production account-switch retention safety was preserved: the cache test now asserts direct replacement is denied, then checks another separately admitted auth store against the same shared cache disk.

### Final executed validation — keep platforms and overlapping runs separate

- **iOS: 121 passed in146s**, final managed selection successful after the final report status change. The selection requests the preceding99 plus15 current-master calculation cases,5 cache cases and2 native UI cases; the runner exposes an aggregate count, not independent per-test discovery or a skipped metric. Exact selectors: `VineTrackTests/CurrentYieldMasterParityTests`, `VineTrackTests/YieldMasterWeightCacheTests`, `VineTrackTests/YieldCompletionPersistenceTests`, `VineTrackTests/YieldVintageReportTests`, `VineTrackTests/YieldAuthoritativeVineCountTests`, `VineTrackTests/SeasonYieldDamageParityTests`, `VineTrackTests/PruningYieldSettingsTests`, `VineTrackTests/PruningYieldSettingsRevisionSyncTests`, `VineTrackUITests/YieldTripNavigationUITests`.
- Separate final `runChecks(appPath: "ios")`: **PASS**, simulator build only. Two pre-existing unrelated direct-storage-URL warnings remain unchanged; no device/Release artifact verified.
- **Android host:95 tests,0 failures,0 errors,0 skipped**, exit0,20.766s. Command: `python3 scripts/run-yield-completion-tests.py --output /tmp/vinetrack-yield-master-final-host`. Exact class selectors, each prefixed `*.`: `YieldCompletionPersistenceTest`, `YieldVintageReportTest`, `YieldAuthoritativeVineCountTest`, `CurrentYieldMasterParityTest`, `SeasonYieldDamageParityTest`, `PruningYieldFormulaParityTest`, `PruningYieldSettingsRevisionSyncTest`. Retains the preceding80 regressions plus15 current-master cases. Evidence: `/tmp/vinetrack-yield-master-final-host/{yield/result.json,finished.json}`.
- **Android emulator:7 passed,0 failed,0 skipped in11s**. Exact selectors: `com.rork.vinetrack.data.YieldTripNavigationAndroidTest`, `com.rork.vinetrack.data.YieldMasterWeightCacheAndroidTest`. Five production cache tests and two production Compose workflow tests; not JVM tests or live-service acceptance.
- Separate final Android **Debug-only assembly PASS**, exit0 in9.661s: `python3 scripts/run-yield-completion-tests.py --debug-build --output /tmp/vinetrack-yield-master-final-debug`, running `:app:assembleDebug`. Generic Android `runChecks` was not invoked because it assembles Release, outside the authorised Debug-only scope. No new Release build/upload was run.
- All three shared fixtures are byte-identical: SHA-256 `1b6eda2b9e8efa6189501bd750c90ae0e28e08a44a20052f421e4e01b1d5b818`. Both index and working-tree whitespace checks pass.

### Shared deterministic fixture — side-by-side validated expectations

| Quantity | iOS | Android |
|---|---:|---:|
| North Shiraz weight; current vines; recorded average |120g;1,000;20|120g;1,000;20|
| North Shiraz base / damage-adjusted tonnes |2.4 /2.16|2.4 /2.16|
| River Merlot weight; current vines; recorded average |200g;500;20|200g;500;20|
| River Merlot base / damage-adjusted tonnes |2.0 /1.6|2.0 /1.6|
| Mixed Hill50% Shiraz +50% Merlot weight; vines; average |160g;600;25|160g;600;25|
| Mixed Hill base / damage-adjusted tonnes |2.4 /1.8|2.4 /1.8|
| Whole-trip base / damage-adjusted tonnes |6.8 /5.56|6.8 /5.56|
| Sampled physical area |approximately3ha|approximately3ha|
| Adjusted Per ha |approximately1.8533333333t/ha|approximately1.8533333333t/ha|
| Planned Only9000 vines /100ha, no count |excluded from sampled area/total|excluded from sampled area/total|
| Missing contributing Merlot master |mixed block +whole-trip totals withheld|mixed block +whole-trip totals withheld|

These are fixture expectations asserted against each production engine, not measured customer yields. Weight/tonnes tolerance is1e-12; polygon-derived area/Per ha tolerance is1e-8. Historical150g weights and snapshot vine counts of1 deliberately conflict with current authority. Zero recorded counts are valid samples; no recorded samples yield no numeric trip estimate. Damage-off restores6.8t without modifying count evidence.

### Intermediate failures retained, not superseded as if they never occurred

- Initial iOS normal build lacked Supabase/PostgREST imports; corrected. Calculation-only selection then15 passed in135s. Cache closure actor annotations initially failed compilation with zero executed; corrected.
- Expanded iOS selection initially120 passed/1 failed, followed by narrow1/1 navigation runs while map-edge scrolling, transition waits and fixture reset were diagnosed. Latest earlier failure was “Persisted completion must not reload as a draft”; fixed process-static fixture initialization. Narrow2 passed in219s, then expanded121 passed in91s; final report-status refinement was followed by the final121/146s and separate passing simulator build. These overlapping runs are not summed.
- First Android instrumentation infrastructure failure executed0 passes/1 failure due to the emulator map teardown exception. After the test-only renderer seam,5 passed/2 failed: non-scrollable Complete action incorrectly used `performScrollTo`, and a direct account replacement hit retention protection. Direct click and isolated fixture directories improved the selection to6/1; inspecting SessionStore established direct account replacement is intentionally forbidden even with empty fixture files. Test corrected to assert that denial and use a separately admitted auth store; final7/0/0 passes. Production retention guard was not weakened.
- Earlier Android host95/0/0/0 and initial Debug pass are historical; final host/Debug results above identify the final Android source.

### Exact source/artifact identity and manifest

Visible baseline remains `16c19e54eaa9c3ecc990a54923f986be539bf223` plus managed changes, not HEAD alone. SHA-256 of `git diff HEAD --binary -- ios android-vinetrack fixtures scripts/inspect-yield-weight-contract.py scripts/run-yield-completion-tests.py`: **`12a90e6da2ffb0b4c167dfa0148bac2372544796160efe2568712b869f9e689b`**. Final managed commit is not yet exposed; no manual commit/push. Final Debug APK `android-vinetrack/app/build/outputs/apk/debug/app-debug.apk` SHA-256 **`c108efe9622e6197b7fd8ce1a45d5d1856569a7d1c5223d55686ed2e14d9338f`**; no signed handset iOS artifact or distribution claim.

Exact27-file implementation/test/fixture/tooling manifest relative to that baseline (plan/report and Rork-managed history/state excluded):

- `ios/VineTrack/App/YieldTripValidationView.swift`
- `ios/VineTrack/Backend/Repositories/YieldMasterWeightCache.swift`
- `ios/VineTrack/LegacyImported/Models/CurrentYieldEstimate.swift`
- `ios/VineTrack/LegacyImported/Views/Yield/CurrentYieldEstimateSummary.swift`
- `ios/VineTrack/LegacyImported/Views/Yield/YieldEstimationView.swift`
- `ios/VineTrack/LegacyImported/Views/Yield/YieldReportView.swift`
- `ios/VineTrack/LegacyImported/Views/Yield/YieldReportsListView.swift`
- `ios/VineTrack/LegacyImported/Views/Yield/YieldSettingsView.swift`
- `ios/VineTrack/VineTrackApp.swift`
- `ios/VineTrackTests/CurrentYieldMasterParityTests.swift`
- `ios/VineTrackTests/YieldMasterWeightCacheTests.swift`
- `ios/VineTrackTests/yield-master-parity.json`
- `ios/VineTrackUITests/YieldTripNavigationUITests.swift`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/CurrentYieldEstimate.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/YieldMasterWeightRepository.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/CurrentYieldEstimateSummary.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/YieldEstimationScreen.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/YieldScreen.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/YieldSettingsScreen.kt`
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/CurrentYieldMasterParityTest.kt`
- `android-vinetrack/app/src/test/resources/yield-master-parity.json`
- `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/YieldMasterWeightCacheAndroidTest.kt`
- `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/YieldTripNavigationAndroidTest.kt`
- `android-vinetrack/yield-tests.init.gradle`
- `fixtures/yield-master-parity.json`
- `scripts/inspect-yield-weight-contract.py`
- `scripts/run-yield-completion-tests.py`

### Remaining acceptance boundaries

Automated native calculation/cache/navigation/completion source gate is green; full operational acceptance and release clearance are not claimed. Still unexecuted: authenticated live master edits/removal/reconnect, concurrent actual server completion/replay receipts, Android main-app process death, physical GPS/map/navigation, configured account-switch UI and handset dark/large-text acceptance. iOS terminate/relaunch proves the isolated local completion fixture, not OS kill during a write or server acknowledgement. Historical compatibility150g getters/calculators remain only in inactive current code or explicitly past-vintage historical paths; no historical payload rewrite was made. Independent maintenance synthetic entitlement fixture remains stopped under its preceding scope; this Yield work does not unblock it.

## Bounded maintenance durable recovery — 27 October 2026 — GREEN SOURCE FREEZE; FIXTURE PREPARATION STOPPED

This checkpoint supersedes the concrete maintenance implementation blockers listed in the older attachment checkpoint below, not its unexecuted operational acceptance. Scope remained maintenance foreground save/edit/delete, photo evidence and existing replay/receipt paths. Accepted Yield and earlier work were preserved. No authentication/customer-record read, synthetic signup, server mutation/deployment, trial-date or billing edit, rollout flag change, historical-entry/purchase UX enabling, store delivery, version/signing change or retained-device reset occurred.

### A–D. Actual implementation and reproduced defects

- iOS now atomically persists maintenance records plus original-account intents, full photo bytes and delete tombstones under the existing storage key; legacy bare arrays remain readable without inventing pending work. Actual foreground save/edit/delete commits before publishing memory, callbacks or success. An injected durable create failure was executed before repair: **0 passed/1 failed** in `MaintenanceForegroundAdmissionTests/failedDurableCreatePublishesNeitherRowNorSuccess()`. Final tests exercise the real store, callback-free restart recovery and failed commits preserving disk and memory.
- iOS UUID acknowledgement tokens protect same-timestamp/newer revisions. Original-account/vineyard replay reads persisted records, retains genuine photo paths durably before metadata, exact-acknowledges only delivered revisions and preserves pending rows/tombstones during refresh. Entire maintenance sweeps are serialized; pending counts include atomic intents as well as legacy markers. Six new `MaintenanceDurableRecoveryTests` cover these persistence seams; the earlier focused repaired selection returned19 passed in72s before final broader validation.
- Android actual online/offline create/update/delete writes intent durably before transport and uses the existing exact account-bound queue claims. Failed enqueue publishes no optimistic success. Only a never-attempted PENDING create can absorb an edit or be canceled; uncertain originals remain distinct from dependent updates. Confirmed row/removal cache commits synchronously before acknowledgement. Stale refreshes and replay callbacks preserve current pending overlays and original vineyard/account incarnation.
- Android CREATE409 is no longer a receipt by itself. Same-account readback must match the original ID, vineyard, author, timestamp, date, editable fields and nondeleted state; otherwise the original evidence remains BLOCKED. Interrupted/unknown delivery remains FAILED. Concurrent hold does not consume retry attempts or turn a possibly delivered insert back into an unsent/foldable create.
- Additional executed failing-before case: `RetainedStartupConstructionTest#maintenanceUncertainServerErrorDuringExpiryRetainsAttemptedInsert` returned **0 passed/1 failed/0 skipped**, expected FAILED but found PENDING. First repair of foreground5xx handling was insufficient: expanded selection **23 passed/1 failed/0 skipped** exposed maintenance transport admission classifying an unrelated5xx as a known rejection merely because expiry arrived concurrently. Maintenance-specific admission now distinguishes explicit structured read-only rejection from unknown5xx delivery. Final24-test selection passes. No shared Trip admission or unrelated workflow changed.
- Android photo bytes are staged before create metadata transport with original identity/time; evidence enumeration drives automatic replay after create recovery. Upload/removal reference phases share a mutex, original upload/removal receipts survive restart, and cache receipt commits before evidence completion. Deletion journals storage removal separately from reference clearing. Known holds retain evidence. These are implemented production paths with lower-level evidence/transport assertions, not an executed full process-death/photo journey.

### E. Final iOS execution

- Final enforcement/recovery selection: **301 passed in154s**, managed runner successful. Skipped metric is not exposed. Exact selectors, each prefixed `VineTrackTests/`: `MaintenanceForegroundAdmissionTests`, `MaintenanceDurableRecoveryTests`, `MaintenancePhotoAdmissionTests`, `DeviceTripOwnershipTests`, `VineyardWriteAuthorityTests`, `ReadOnlyEntitlementContractTests`, `SpraySaveForLaterTests`, `EntitlementDecisionTests`, `EntitlementAccessRegressionTests`, `OfflineQuickActionsTests`, `ResistancePlanRepositoryTests`, `ResistancePlanRevisionSyncTests`, `FertigationMobileWorkflowTests`, `FertigationDomainTests`, `TripOccurrenceJournalTests`, `StartTankCommitCoordinatorTests`, `PinPhotoWorkflowTests`, `VineyardMutationAdmissionTests`, `LinkedPinGrowthDeletionWorkflowTests`, `MobileRequestSyncSafeguardTests`.
- The runner allows20 selectors. The unchanged preceding `VineTrackTests/GrowthStageVarietyParityTests` selection ran separately: **2 passed in93s**. Do not sum overlapping historical runs or represent aggregate counts as independently confirmed test-name discovery.
- Separate final `runChecks(appPath: "ios")`: **PASS**, simulator build only; device/Release validation not established. The two existing unrelated storage URL warnings remain untouched.

### F. Final Android execution and historical failures

- Final host runner `python scripts/run-read-only-entitlement-contract.py`: **focused222 passed in25.436s; existing regressions55 passed in10.999s**, each zero failures/errors/skips and exit0. Artifacts: `/tmp/vinetrack-read-only-contract-v0xji5y9/{contract/result.json,existing-regressions/result.json,finished.json}`. Earlier intermediate222/55 successful runs did not freeze later production refinements.
- Exact focused selectors, each prefixed `*.`: `ReadOnlyEntitlementContractTest`, `VineTrackAccessRowCompatTest`, `VineyardWriteAuthorityTest`, `PinPhotoWorkflowTest`, `FertigationMobileWorkflowTest`, `ResistancePlanRepositoryTest`, `ResistancePlanRevisionSyncTest`, `FertigationDomainTest`, `TripOccurrenceJournalTest`, `StartTankCommitCoordinatorTest`, `TripWriteAdmissionTest`, `MaintenancePhotoEvidenceStoreTest`, `MaintenanceForegroundQueueTest`. Exact regression selectors: `RetainedStartupTest`, `SyncRecoveryStorageTest`, `SyncCrashIsolationTest`, `ActiveTripStoreTest`, `OfflineQuickActionsTest`, `TripEndGateTest`.
- Final instrumentation: **24 passed/0 failed/0 skipped in8s**. Exact class selectors: `com.rork.vinetrack.data.MaintenancePhotoAdmissionAndroidTest`, `com.rork.vinetrack.data.auth.RetainedStartupConstructionTest`, `com.rork.vinetrack.data.KnownAttachmentAdmissionAndroidTest`. Disposable synthetic Application and intercepted Ktor transport only; no live HTTP fallback. Managed final log `/tmp/rork-android-test-android-vinetrack.log`.
- Added actual-ViewModel CREATE lost-response journeys, including expiry and uncertain503; recreated repository/replay verifies original INSERT and exact409 readback before durable receipt/ack. Held unknown delivery retains FAILED with zero attempts and cannot be folded/canceled after reactivation. Added actual foreground UPDATE/DELETE lost-response journeys; recreated replay sends byte-identical original bodies and asserts cache commit occurs while intent still exists, before acknowledgement. These tests recreate repositories, not the Android process.
- Earlier instrumentation failures are preserved historically: initial class7 passed/2 failed; diagnostic0 passed/1 failed. Test-side construction of `PendingWriteStore` inside in-flight HTTP inspection installed another SessionStore/global authority, invalidating the captured production admission. Replaced those inspections with raw SharedPreferences decode, without changing auth/startup production. Corrected intermediate class9 passed/0 failed/0 skipped in13s. Subsequent held-loss smallest1 passed in7s; expanded21 passed in8s; added UPDATE/DELETE smallest2 passed in7s. These are intermediate selections, not additional final totals. Initial failure log `/tmp/vinetrack-maintenance-instrumentation-initial.log`; later503 failing-before log `/tmp/vinetrack-maintenance-held-503-failing-before.log`.
- Separate final `runChecks(appPath: "android-vinetrack")`: **PASS**, normal build. No store upload/release operation. The two existing unrelated storage URL warnings remain unchanged. Host/device executions and builds were serialized.

### G–H. Fixture stop and smallest server-side prerequisite

- No approved reversible synthetic-user-only entitlement transition control was found in repository SQL or Supabase migrations. Existing rollout allowlisting in `sql/132_shared_entitlement_resolver.sql` is not an entitlement override; it also includes internal grants/admin cohorts. `admin_grant_unlimited_access`/revoke and authoritative trial administration are not approved synthetic-expiry controls. Feature flag updates can overwrite JSON if incomplete; no flag was changed. The existing materialized refresh is `_admin_refresh_entitlement_state` in `supabase/migrations/20261021040736_shared_access_correction.sql`.
- Earlier read-only backend discovery identified native Supabase Auth at production ref `tbafuqwruefgkbyxrxyb`, no preview and no deployed functions reported. This checkpoint did not authenticate or inspect customer rows. Live deployed SQL-function/control availability remains **unverified**, so repository absence is not claimed as proof of live absence. No safe control is verified; fail closed and stop fixture preparation.
- **Smallest prerequisite (specification only, not deployed):** an admin-operated TEST-ONLY override limited to an explicitly registered synthetic auth user and dedicated synthetic vineyard, rejected for every other target. Allow only WRITABLE → EXPIRED/READ-ONLY → REACTIVATED/WRITABLE, plus reversible removal; apply a server-side expiry/kill switch. Require actor, target, old/new state, reason, request identity and time in an audit trail. Normal test credentials may read effective access but must never set their own override; privileged control stays server-side.
- The override must feed the same authoritative access resolver and its materialized `vinetrack_entitlement_state` refresh. EXPIRED must explicitly deliver historical entry allowed, writes denied and `trial_expired`; reactivation must explicitly verify writes allowed. Refresh must not disagree with the materialized row. Keep real trial timestamps, billing/provider records, ordinary membership/role checks and all nonfixture users untouched. Removing the override restores baseline resolution. An exact synthetic rollout binding, if separately needed, must preserve the complete pre-existing flag/cohort JSON and be independently reversible; no customer-wide enabling.
- **Actual backend identifiers:** auth user NOT CREATED; vineyard NOT CREATED; fixture records NOT CREATED. The UUIDs in native tests are local disposable fixtures, not backend IDs. Intended ordinary method is existing native email/password signup/login (normal confirmation if required), never manual auth insertion, owner credentials or elevated client keys. No credentials requested/stored. Only after the control is delivered and verified may ordinary signup and dedicated vineyard preparation proceed and real IDs be reported.
- Historical entry and notice/purchase UX remain disabled. Intended isolated notice remains “Your trial has ended. VineTrack is currently read-only. Purchase a subscription to make changes.” Primary View plans / Purchase; secondary Cancel / Keep viewing; existing billing only. No substitute purchase/receipt was fabricated.

### I. Explicit acceptance limits

Durable local acceptance is not server receipt; verified intercepted readback is not live backend acceptance; recreated stores are not actual process death. Actual app-process termination/relaunch, concurrent live-service sends, full automatic photo upload/delete receipt replay and physical iPhone/Android journeys remain unexecuted. This checkpoint freezes the bounded, tested native implementation, not every operational acceptance condition or native-wide caller inventory. No new general audit category was added. **NOT READY FOR CONTROLLED PHYSICAL DEVICE ACCEPTANCE TESTING** because the isolated control/fixture/UX condition is unavailable; physical/process-death acceptance is not claimed. Unfinished Yield parity remains separate and unchanged.

### J. Exact frozen source identity

Base HEAD `3bd4c2bb0d173cf7fdc332cc2261faffb7d344ac` plus exactly19 application/test files below. Final source review and `git diff HEAD --check` PASS. Manifest is sorted UTF-8 `sha256  path\n`; SHA256 **`23d24fc18fa489a291474c248f1c28974ac7fdfcdcd50da87e2e5208a32b168f`**. Plan/report and managed fingerprint/history are excluded and preserved. No production/test change followed the final applicable test/build results; later source changes invalidate this freeze.

```text
b9c50d42bdfad85a341be9818f9b3789d82eedbfbbedd9d354ac8d2f3f1ad2d5  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/auth/RetainedStartupConstructionTest.kt
698747f4dab351f35b8cab0553c535e755cb356aaf2577b89ddcdede3fcd3735  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/DomainCacheRepository.kt
e32f5594a29b91913d3d6c3e7545102bddb2f3dcc57bae8fe786bc51704beffe  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/DomainCacheStore.kt
b091a9a9a49478759987e6171fa8b93b8a20b61b318ec8de28a8e6c77562740c  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogCreateSync.kt
2e1746ea28a48d2114758126c88fc0250f8b10b59a9b1e09a31e9e5e7bfc2f34  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogDeleteSync.kt
209f8680eabed7b5b424e8972c4911349e55ca10fa0130223f14ba62c39be5e5  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogRepository.kt
decd0f8fed9c1f435b23d9415a65ae0417162f38b1e90003e26dd8e3e1ff282d  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogUpdateSync.kt
04c0b23d71c3b43efe140f7de67e7d5e8bd27f0135ed37d762e418f99e6edf2c  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenancePhotoEvidenceStore.kt
fcdcf5e10ca23dc88014250af9627929526bff85e2e400fb513bdf5ef98e20b7  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceWriteScope.kt
3b0316f0c95f4758864f8c118b19ec9f35abebcee8ddd5c1cf4b9cbb5a72495d  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/Models.kt
7def8b420b2eff4b83a4c2d57af1b447db6697c46860fabf245a602d29b24e3b  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt
58d2e638b4caf04328605beaa5673f4d3b86b05c90d03aad4691e5cc08300f34  android-vinetrack/app/src/test/java/com/rork/vinetrack/data/MaintenanceForegroundQueueTest.kt
abff7bb718a2a2b2e0e931eca77015f85a2d0968f8a3173a52a5b1b0e92061aa  android-vinetrack/app/src/test/java/com/rork/vinetrack/data/MaintenancePhotoEvidenceStoreTest.kt
e477cd8c388325d5630e130ca36f5902183458b63eb998d707274a7ec8da57df  ios/VineTrack/Backend/Sync/OperationsSyncServices.swift
d0a6bbf7d148c917669d14db49f28f327e63beffb2415a93672daee8d6d98f1f  ios/VineTrack/LegacyImported/Repositories/MaintenanceLogRepository.swift
cfb77bf344656acbc42cde1f45cdccb362afbd336bab24398c7db129ee424136  ios/VineTrack/LegacyImported/Services/MigratedDataStore+Operations.swift
a8c6e6f52c25ce1fb859bd99811ddfb608d8c10230a6afa6aef7912f930791bb  ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift
175d435e6acae7d31a8a15f94e27dc75cc2441217cf5553c2366c1208d647a58  ios/VineTrackTests/MaintenanceDurableRecoveryTests.swift
ff0513d91d4c7c13fdee2325560936c9340caf6589372c8a90e84b355343a71f  ios/VineTrackTests/MaintenanceForegroundAdmissionTests.swift
```

## Yield completion checkpoint — 27 October 2026 — PARTIAL, NOT FULL YIELD PARITY

Scope is only Yield Estimate/Bunch Count Trip completion persistence/replay, promoted completion decoding and associated Back/save outcomes. No backend/schema/Portal, release/upload, version/signing, billing/authentication, spraying, fertigation, costing, weather, irrigation or other workflow change was made. Shared files were edited only in their Yield sections. No failing-before Yield reproduction was executed; new tests are post-repair regressions. Earlier unrelated results below are not added to these counts.

### iOS — implemented and validated seams

- Cause: local sessions and independent dirty markers were separate commits; an older in-flight draft acknowledgement could clear a newer completion. A session could also acquire a different identity on repeated serialization if a caller skipped new-trip initialization.
- Fix: a backward-compatible atomic sessions-plus-save-intents envelope at the existing `vinetrack_yield_sessions` key; actual completion timestamp required; each save carries an exact UUID acknowledgement token, including saves within the same serialized second. Commit precedes memory updates and notifications. Failed commits return false and keep completion UI open with an error. Exact acknowledgement removes only its intent and leaves the completed record durable.
- Replay recovers durable intents independently of legacy notifications, reads all persisted sessions rather than only the selected slice, suppresses overlapping sweeps, checks original user ID after upload and protects pending saves/deletes during pull. Stable trip ID/creation time survives repeated serialization. Promoted server completion/creation fields override stale payload fields; legacy payload-only rows remain readable; deleted/ID-mismatched rows are omitted.
- Navigation code directs trip/sampling/completion/report Back or successful finish to the trips list; normal list-to-hub navigation is retained. This was compiled, not interactively exercised. Richer list/detail names, master provenance, sampled area and current-trip labels are not implemented by this checkpoint.
- Final focused selection: **99 passed in 32s**, runner successful; skipped count not exposed. Exact selectors, all prefixed `VineTrackTests/`: `YieldCompletionPersistenceTests`, `YieldVintageReportTests`, `YieldAuthoritativeVineCountTests`, `SeasonYieldDamageParityTests`, `PruningYieldSettingsTests`, `PruningYieldSettingsRevisionSyncTests`. Includes **15 new completion tests**. Initial selection was 98 passed/1 failed: the existing financial fixture expected 2 tonnes × 1500 = 3, corrected to 3000 in the test only.
- Final normal simulator build via `runChecks(appPath: "ios")`: **PASS**. Existing unrelated storage URL warnings in `TripTypeChoiceSheet.swift:18` and `UCRInfoSheet.swift:23` left untouched. No release/export/upload.
- This evidence covers repository restart, exact stale acknowledgements, failed durable commit/ack, legacy arrays, pending replacement/vineyard retention, stable ID/time and completion serialization/mapping. It does **not** establish actual app process death, live service acknowledgement/reload, same-account session-incarnation fencing or a rendered completion-save journey.

Exact iOS source/test files (9):

```text
ios/VineTrack/Backend/Models/BackendOperations.swift
ios/VineTrack/Backend/Sync/OperationsSyncServices.swift
ios/VineTrack/LegacyImported/Repositories/YieldRepository.swift
ios/VineTrack/LegacyImported/Services/MigratedDataStore+Yield.swift
ios/VineTrack/LegacyImported/Views/Yield/YieldEstimationView.swift
ios/VineTrack/LegacyImported/Views/Yield/YieldEstimationViewModel.swift
ios/VineTrack/LegacyImported/Views/Yield/YieldSamplingNavigationView.swift
ios/VineTrackTests/YieldCompletionPersistenceTests.swift
ios/VineTrackTests/YieldVintageReportTests.swift
```

### Android — implemented and validated seams

- Cause: online saves could send before durable intent existed, queue coalescing removed then enqueued in separate commits, and stale draft success/failure could consume or publish over a newer completion. A transport response previously fell back to the submitted payload rather than requiring genuine acknowledgement.
- Fix: both online/offline saves atomically enqueue before optimistic memory or transport; durable failure returns false and leaves completion open with an error. Existing bounded replay sends the same trip ID and timestamp. Exact claim/current/remove/retry operations prevent stale acknowledgement/failure from consuming a replacement. Interrupted/typed-held claims restore the original state. Server-confirmed snapshot must commit into original-account/vineyard cache before the current claim can be acknowledged. Account-incarnation check suppresses stale-account retention.
- Upsert requires completed timestamp, parses it and checks a real returned acknowledgement for identity, vineyard, completion and time. Promoted completion/creation fields are decoded over stale payloads; deleted rows are omitted. Domain cache Yield writes use synchronous durable commit and propagate its Boolean result.
- Navigation code sends system/toolbar Back from trip workflow/sampling/completion to the trips list. Completion exits only after durable local acceptance, not server acknowledgement. Richer list/detail presentation remains unfinished; no interactive navigation run was performed.
- Final focused selection: **80 passed / 0 failures / 0 errors / 0 skipped in 25.419s**, exit 0. Exact selectors, each prefixed `*.`: `YieldCompletionPersistenceTest` (15), `YieldVintageReportTest` (9), `YieldAuthoritativeVineCountTest` (17), `SeasonYieldDamageParityTest` (16), `PruningYieldFormulaParityTest` (7), `PruningYieldSettingsRevisionSyncTest` (16). New completion tests cover queue restart/interrupted claim, atomic replacement failure, stale ack/failure, unknown-outcome retry, cache-before-ack, timestamp validation, delete precedence, promoted/legacy/deleted mapping, serialization and stale-account acknowledgement. These are host tests, not instrumentation or live backend acceptance.
- Runner: `python3 scripts/run-yield-completion-tests.py --launch`; final external artifacts `/tmp/vinetrack-yield-completion-o64pila8/{finished.json,yield/result.json,yield/gradle.log}` plus suite XML. First run `/tmp/vinetrack-yield-completion-m_taloxa`: 80 tests/2 failures. Intermediate `/tmp/vinetrack-yield-completion-b3hgoy21`: 80 tests/2 failures in 27.093s. All 15 new completion tests passed on every run. Both failures were existing damage-report fixtures with no polygon/vintage or physical block geometry. Corrected fixtures supply fixed 2026 vintage and matching mapped block/damage polygons; intermediate saved-area-only fix was insufficient because production reads polygon-derived physical area. Assertions remain 3.0 base, 2.4/1.5 adjusted. No damage production logic changed.
- Final separate **Debug build PASS**, `:app:assembleDebug`, exit 0 in **85.628s** (Gradle reports 1m 25s). Runner `python3 scripts/run-yield-completion-tests.py --debug-build --launch`; external artifacts `/tmp/vinetrack-yield-completion-3o_nhjms/{finished.json,debug-build.log}`. Initial foreground invocation timed out at 60s during dex generation; inspected process/artifact state, confirmed no Gradle process remained, then resumed via the background runner. No Release task or upload ran. `runChecks` was not used for Android because its documented operation assembles Release, outside the explicitly authorised Debug-only scope.

Exact Android application/test files (8), plus shared host tooling (2):

```text
android-vinetrack/app/src/main/java/com/rork/vinetrack/data/DomainCacheRepository.kt
android-vinetrack/app/src/main/java/com/rork/vinetrack/data/DomainCacheStore.kt
android-vinetrack/app/src/main/java/com/rork/vinetrack/data/YieldEstimationSessionRepository.kt
android-vinetrack/app/src/main/java/com/rork/vinetrack/data/YieldSessionSaveSync.kt
android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt
android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/YieldEstimationScreen.kt
android-vinetrack/app/src/test/java/com/rork/vinetrack/data/YieldCompletionPersistenceTest.kt
android-vinetrack/app/src/test/java/com/rork/vinetrack/data/YieldVintageReportTest.kt
android-vinetrack/yield-tests.init.gradle
scripts/run-yield-completion-tests.py
```

### Master weights, no-150 paths and parity — NOT COMPLETE on either platform

- **No current 150 g authority path was removed in this checkpoint.** iOS still has `YieldEstimationViewModel.bunchWeightKg(for:)` fallback `0.15`, `YieldEstimationView` initial `"150"` and `applyDefaultBunchWeights()`, plus snapshot-based model/report calculations. Android still has `BunchWeightDefaultsStore.DEFAULT_BUNCH_WEIGHT_GRAMS = 150.0`, local preference/editor seeding and existing session/default-based calculations. These remain active current fallbacks, not justified historical-only retention.
- Historical `blockBunchWeightsKg`, `averageBunchWeightKg`, counts and snapshots were not rewritten. Separating/labeling historical weights from current authority remains outstanding.
- Neither platform yet reads/caches `public.yield_bunch_weights` or integrates `resolve_yield_bunch_weight(p_vineyard_id,p_paddock_id,p_variety_key)`. No exact canonical-key block-override → vineyard-master → required resolver or account/vineyard/block/key master cache is claimed. The changed Android cache is for confirmed **trip sessions**, not master weights.
- Missing work: every mixed-block contributing canonical allocation, fail-closed missing master, current authoritative vines, sampled-block-only physical-area denominator, current completed trip retained as “Bunch weight required” rather than pruning fallback, and complete provenance/count/area/status presentation across all production calculation entry points.
- There are **15 new completion cases per platform, not the requested minimum 26**, and no newly executed shared fixture parity matrix. Existing mirrored pruning/damage/report suites passing does not establish the new Portal master-weight contract. No tested no-150 acceptance, interactive save/Back/reload flow, actual process-death replay or live Supabase acceptance is claimed. Overall Yield plan checkboxes remain open.
- Source base: `47d082d0b80e363962f7cd873c7b3c818906fded` plus exactly the 19 application/test/tooling files listed above. Sorted UTF-8 manifest format is `sha256  path\n`; manifest SHA256 `2ebf6fe86188f7b25da8cb343b7ad3f807791f0b56cd762e26721badbb7fe742`. Existing plan/report and managed history/fingerprint changes are excluded and preserved. No release or readiness clearance follows from this partial checkpoint.

## Acceptance-mode attachment checkpoint — 27 October 2026 — NOT YET A PHYSICAL CANDIDATE

The owner's bounded acceptance-mode instruction supersedes the older open-ended caller audit and automatic full23-case/backend prerequisite for starting physical acceptance. Scope is only known attachment families, independent journal/replay callers and maintenance unknown-outcome/process-death recovery. The dedicated synthetic account/vineyard option was selected by the owner; identifiers, ordinary test login method and safe expiry/reactivation control remain unsupplied. No customer-wide enablement, backend authentication/customer-data access, server change, store upload, version/signing change, retained-install reset or evidence purge occurred.

### A–D. Bounded implementation and remaining actual blockers

- Both apps now admit known vineyard-logo, custom growth-reference, scouting-photo and chemical-label mutations against the original owning vineyard/account rather than the currently selected writable vineyard. Canonical path validation rejects traversal/unresolved ownership. ID-only growth-image deletion resolves its exact metadata owner; chemical-label sends resolve their exact saved-chemical parent. Scouting parent/child push admission was also tightened. These edits do not certify every independent Insights RPC or replay caller.
- Android captures the account incarnation before dispatcher suspension, attaches the existing scoped transport attributes and checks the original account before publishing a successful receipt. Genuine success during expiry does not grant permission for a separate metadata/delete follow-up. Chemical replay receives the production session and restores original attachment state on a typed hold.
- iOS maintenance metadata acknowledgement compares the captured original revision, does not erase newer edits or separate pending-photo work, and checks the original account. Pull skips pending local upserts/deletes instead of overwriting their retained evidence. Delete acknowledgements compare their original timestamp.
- No new failing-before reproduction was executed for these new repairs. The added tests are post-repair regressions, not evidence of a separately executed old-source failure.
- **Concrete existing maintenance blockers remain, not theoretical new categories:** Android foreground create/update/delete sends still precede durable intent persistence (`AppViewModel.kt` online branches around14824,14911,15022); online create-photo staging follows the create receipt and is skipped for the offline-create branch; photo recovery still requires the original URI and lacks automatic evidence enumeration/replay; upload receipt/reference and delete/reference phases are not complete durable recovery transactions. iOS record persistence and separate sync-marker persistence are not one durable write-ahead commit. The revision acknowledgement repair does not close those crash windows. These can lose intent/evidence or permit duplicate recovery and must be repaired before the candidate is declared ready.
- The known independent journal/replay continuation is not completed by attachment transport admission. No fresh general audit category was added. Historical entry and persistent notice/purchase UX remain unchanged; this is not READY FOR CONTROLLED PHYSICAL DEVICE ACCEPTANCE TESTING.

### E–F. Current requested automated evidence

- iOS selected enforcement/regressions: **296 passed in226s**, successful managed runner. Skipped metric unavailable. Exact selectors, each prefixed `VineTrackTests/`: `MaintenanceForegroundAdmissionTests`, `MaintenancePhotoAdmissionTests`, `DeviceTripOwnershipTests`, `VineyardWriteAuthorityTests`, `ReadOnlyEntitlementContractTests`, `SpraySaveForLaterTests`, `EntitlementDecisionTests`, `EntitlementAccessRegressionTests`, `OfflineQuickActionsTests`, `ResistancePlanRepositoryTests`, `ResistancePlanRevisionSyncTests`, `FertigationMobileWorkflowTests`, `FertigationDomainTests`, `TripOccurrenceJournalTests`, `StartTankCommitCoordinatorTests`, `PinPhotoWorkflowTests`, `VineyardMutationAdmissionTests`, `LinkedPinGrowthDeletionWorkflowTests`, `MobileRequestSyncSafeguardTests`, `GrowthStageVarietyParityTests`. Includes two added revision-recreation/path-validation assertions; does not simulate actual app process death.
- Android focused/regression runner: `python3 scripts/run-read-only-entitlement-contract.py --launch`, artifacts `/tmp/vinetrack-read-only-contract-gz36evkr`; **focused217 passed in484.695s; regressions55 passed in240.027s**, each zero failures/errors/skips and exit0. Exact focused selectors: `ReadOnlyEntitlementContractTest`, `VineTrackAccessRowCompatTest`, `VineyardWriteAuthorityTest`, `PinPhotoWorkflowTest`, `FertigationMobileWorkflowTest`, `ResistancePlanRepositoryTest`, `ResistancePlanRevisionSyncTest`, `FertigationDomainTest`, `TripOccurrenceJournalTest`, `StartTankCommitCoordinatorTest`, `TripWriteAdmissionTest`, `MaintenancePhotoEvidenceStoreTest`, `MaintenanceForegroundQueueTest`. Exact regression selectors: `RetainedStartupTest`, `SyncRecoveryStorageTest`, `SyncCrashIsolationTest`, `ActiveTripStoreTest`, `OfflineQuickActionsTest`, `TripEndGateTest`. All prefixed `*.` in the existing runner. Android operations were serial.
- Android instrumentation: **19 passed/0 failed/0 skipped in11s**, successful managed runner with exact selectors `com.rork.vinetrack.data.MaintenancePhotoAdmissionAndroidTest`, `com.rork.vinetrack.data.auth.RetainedStartupConstructionTest`, `com.rork.vinetrack.data.KnownAttachmentAdmissionAndroidTest`. The last class executes two production-repository/MockEngine assertions: nine held known-family actions make zero mutation sends with writable B selected; a genuine logo receipt during expiry cannot authorize the separate growth-reference write or delete after session recreation. Disposable synthetic Application and intercepted HTTP, no live fallback. Not actual process-death, physical or backend acceptance.
- Separate normal iOS build: **PASS**, simulator artifact only. Separate normal Android build: **PASS**, after host checks and instrumentation. No store delivery. All six requested automated surfaces passed for this partial checkpoint, but the bounded native repair pass is not complete. The earlier294/17/217/55 results and weather142/52/209/55/9 remain historical separate selections, not current results.
- These gates began before the whole bounded repair pass was complete. Any later source repair requires appropriate revalidation; no claim of a final green native freeze is made from this checkpoint.

### G–J. Isolation, intended candidate and source identity

Actual expired login/history, creation/edit/completion/reopening/attachment denial, GPS/Tank/Pin/Fertigation denial, deliberate purchase prompt, offline/restart hold, account/vineyard isolation and exact-once reactivation remain unexecuted physical journeys. Once native blockers are repaired and the exact isolated condition is supplied, prepare only that condition, retaining authority-level denial and existing billing. Required copy remains “Your trial has ended. VineTrack is currently read-only. Purchase a subscription to make changes.” Primary View plans / Purchase; secondary Cancel / Keep viewing. Do not infer synthetic safety from a name/email or enable this for general customers.

Source base `4bbbaf77` plus the following19 application/test files; approved-plan/report and preexisting managed state excluded. Final exact changed-file/hash/manifest comparison PASS; `git diff HEAD --check` PASS. No accepted weather, startup, Trip/Spray/tank recovery, costing, billing configuration, version/signing or server file was changed. Sorted UTF-8 manifest SHA256 **`6d862406ee0920a8536d4e7fa1712eedb69d78accf368e642087bec4392265e0`**. This identifies the partial checkpoint, not a completed acceptance candidate:

```text
a581ce07e86b0c7296ff51e574158705e6d3e9f6851b34cf05dd8932123c6505  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/KnownAttachmentAdmissionAndroidTest.kt
69ced412f048ce0e238915e86c4d8ad9b1fa963ec1fcdd3331cd1daf659643ef  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/ChemicalLabelPhotoSync.kt
56b3ba4074c67f672643927ab384312f634639f984e542fc41445ebc1e1bb2f7  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/GrowthStageImageRepository.kt
787c9d042a6491f0451b99e55e345eb9e8ef5e52a69dcece911e4712ad7c9629  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceWriteScope.kt
5d783ba6a0c59f10f61ab945ae6084643635b996390bfe51df018aa66a04d0e2  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/VineyardAttachmentWrite.kt
2b68623e895911c516ff49c41876a6bec48c1b450b5c90f0ab5d06ea93a420cb  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/VineyardLogoRepository.kt
4804c003b411ee39f217ac201fc1b2f52ef7e3a0afef842d564af9fa2dbac5f5  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/chemical/ChemicalSearchV2.kt
222f33346d957fd89e0b839e81585a1fdffc59484e1369b3f578f3c9ef1be49b  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/insights/VineyardInsightsSyncRepository.kt
734d92f4243bade6d3eed654bd3fc5abd9abfbd171344ead1d242eaeb8ce1b13  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt
8dc1bf647fc868dc5b9e3b1e221ff06092d29620ff5312b5036d666027cd419e  ios/VineTrack/App/ChemicalIntelligence/ChemicalSearchV2View.swift
c24c89840d94b550ad971b4a206ed55764c0710c233ea1ea0ef0e1da320254d2  ios/VineTrack/App/Insights/VineyardInsightsSyncRepository.swift
bf7f2467d251e0f83790e126d5731b1b62d41c80615ecafb2e7b4316e620cb15  ios/VineTrack/Backend/Repositories/SupabaseGrowthStageImageSyncRepository.swift
0d141b26d465734f4593e4225c60897ba290ef2725dfb2bc7c63d71dd20ebd9a  ios/VineTrack/Backend/Repositories/SupabaseVineyardRepository.swift
1d897cea1f48e16784f00d8e0de71275a0fed9f35e6ba2b7c7bb7c6cebd0d7d1  ios/VineTrack/Backend/Storage/ELStageImageStorageService.swift
31cd1a0a0099c8f2182f6374a60e3ecee1cdde437ddb098401909f770964fb16  ios/VineTrack/Backend/Storage/VineyardAttachmentPath.swift
d432b3399716813249ac834c09590031bfb6d7bf2615d7ea680ad4c130a6a0f9  ios/VineTrack/Backend/Storage/VineyardLogoStorageService.swift
6270259d47f8c7ad6aa6be6f3440ccfafc1eb4df4e8483e72d40fd8807f42147  ios/VineTrack/Backend/Subscription/VineyardMutationAdmission.swift
e1b228b2afd1f50ea7af74c129932b4ecef4f2f6d419e161edad2575b180f751  ios/VineTrack/Backend/Sync/OperationsSyncServices.swift
87988754352f80b49203aaf62f31fa3fd7f565424be91f25a60f950b9608aa15  ios/VineTrackTests/MaintenancePhotoAdmissionTests.swift
```

## Mobile weather parity / supplementary MAIT sensors — 26 October 2026 — AUTOMATED GATES PASS

Latest bounded weather continuation. This supersedes the earlier weather-source freeze only for the changes listed here; it does not close native-wide enforcement, authenticated backend, physical-device or release gates. Base revision `de8d6cc9560d660e2b1758618ae232d8febb6e6b` plus the exact eleven-file application/test manifest below identifies this source. Managed history/state changes are excluded from that application manifest and preserved.

### Source audit reported before application edits

Both existing Current Conditions cards already used the same normalized nullable primary model. No architecture unification was needed. The grouped parity matrix was reported in chat before application edits; the seventeen individually exposed behaviours are expanded here:

| Exposure / behaviour | iOS before | Android before | Final bounded change |
|---|---|---|---|
| Primary provider label | Present | Present | Existing canonical labels retained |
| Station name | Present | Present | Unchanged |
| Observation timestamp | Present | Present | Unchanged |
| Temperature | Non-null only | Non-null only | Unchanged |
| Humidity | Non-null only | Non-null only | Unchanged |
| Wind speed | Non-null only | Non-null only | Unchanged |
| Wind direction | 16-point compass | Rounded degrees | Android now uses matching compass; 133 degrees is SE |
| Wind gust | Non-null only | Non-null only | Unchanged |
| Rain today | Non-null only, includes actual zero | Same | Unchanged |
| Rain rate | Non-null only | Non-null only | Unchanged |
| Leaf wetness | Non-null only | Non-null only | Unchanged |
| Stale status / retained readings | Present | Present | Preserved |
| Refresh-error copy | Source-specific rain page; variable settings copy | Same | Settings use source-specific wording |
| No-newer MAIT feedback | Present | Present | Preserved |
| Portal-only MAIT guidance/read-only status | Present | Present | Preserved; no setup controls added |
| Additional MAIT sensors / scoped partial warning | Absent | Absent | Added independent section on both rain pages |
| Exact frozen MAIT irrigation label | Present | Present | Unchanged and regression-selected |

The existing rain-page user refresh was stale-only on both platforms. Deliberate refresh now forces only the resolved primary provider, follows its normalized reread, then independently reads supplementary sensors. Automatic loads remain stale-only. No client current-weather throttle existed in either repository, so none was added. Provider resolution still precedes routing, and unresolved/auth/network selection failure cannot become a fallback. Explicit `none` makes no primary-provider refresh. The Davis/WU legacy null-selection path remains distinct from explicit selection.

### Delivered boundaries

- Primary weather remains `get_vineyard_current_weather(p_vineyard_id)`. No second primary MAIT observation model. The supplied primary fixture retains temperature14.5, humidity54.4, wind4/direction133/gust14.5, actual rain0, station/time and two absent metrics; wind uses SE on both platforms.
- Supplementary reads use the authenticated VineTrack `mait-intelliweb-proxy` only, with exactly `vineyardId` and `action: supplementary_current`. iOS reuses the primary MAIT request builder/session and account-generation checks; Android reuses the signed-in bearer token and `accountRequestScope` through the existing HTTP client. No service-role token, Network ID, MAIT credential, upstream host or management action was added.
- The independent supplementary read discovers available modules, including alongside a non-MAIT primary source; it is not a selected-primary refresh or fallback. No modules means no Additional MAIT sensors section. A failed discovery with no previously returned modules also leaves the section hidden. Existing same-scope modules can remain with the scoped warning after a failed reload.
- Modules show friendly names, actual observed timestamps, status and available normalized readings. Soil moisture uses `value` with the supplied unit; soil temperature uses `value` in Celsius; leaf wetness uses `value` and its supplied unit when present. `raw_value` is never used for conversion. Null readings are hidden, not fabricated as zero. `no_data` says “No recent data”; `error` says “Sensor data unavailable”. Successful modules are not suppressed by another module's error.
- HTTP206 is decoded as usable data with the warning “Some MAIT sensor data may be incomplete. Primary weather is unaffected.” Payload/module partial and module-error conditions also yield that scoped warning. Supplementary errors never replace primary readings, timestamps or primary-refresh feedback.
- iOS current/supplementary presentation is fenced by existing vineyard/account binding/generation, cleared before unrelated reload work, and asynchronous publication additionally checks the current request identity. Its forecast-before-rainfall sequence is preserved so persisted-rainfall day calculation still uses the resolved forecast timezone. The existing root removes the signed-in shell on sign-out; shared authority/auth/session code was not changed.
- Android rain and weather-settings holders are disposed/recreated using selected vineyard, signed-in account and the existing identity epoch. Old coroutine/UI holders cannot become the new screen's state. The supplementary repository also rejects account-incarnation and selected-vineyard changes across transport.
- Forecast selection, Davis/WU primary fallback rules, persisted rainfall sources/calculations, irrigation usage, frozen irrigation provenance, session volumes/durations and field-operation/startup/costing/entitlement code were not changed. No migration, Portal/server, version/build-number, signing, release or store upload operation was performed. Historical read-only entry and notice/purchase UX remain disabled.

### Executed validation — separate results, never combined with historical gates

**iOS final exact11-suite selection:** managed `swiftTest(ios)` returned **142 passed in58s**. Tool success, zero failures reported. Skipped count and per-suite discovery manifest are not exposed, so skipped is **unavailable**, not inferred zero. All selectors under `VineTrackTests/`:

`MAITSupplementarySensorTests`, `MAITCurrentObservationTests`, `CurrentObservationProviderTests`, `ReadOnlyEntitlementContractTests`, `VineyardWriteAuthorityTests`, `EntitlementAccessRegressionTests`, `EquipmentVineyardIsolationTests`, `ForecastParityContractTests`, `ForecastSupplementationFocusedTests`, `IrrigationCalculatorFixtureTests`, `RegionFormatterWeatherParityTests`.

New Swift coverage exercises exact supplementary host/path/method/body/member JWT, HTTP206 and partial warning, supplied names/time/normalized values, empty modules, independent module error/no-data, null/zero and supplied units, obsolete-scope rejection before/after transport, sanitized supplementary failure, primary fixture/nulls/compass, forced fresh refresh, explicit MAIT/Davis/WU/none exclusivity and unresolved-selection zero-send. These are production decoding/formatting/routing and injected transport/scope assertions, not rendered-screen or live-backend acceptance.

Earlier runs in this continuation: first failed at compile with **0 passed/0 failed**, missing `Supabase` import in the new supplementary file; import corrected. Next selection **142 passed in73s** and a normal simulator build passed, before the final view-only restoration of forecast/rainfall ordering/request-publication fencing. Final142/58s above and a new separate normal simulator build **PASS** cover the final iOS source. Do not combine the overlapping142 results. The historical297 gate was not rerun.

**Android host:** unchanged `scripts/run-mait-mobile-contract.py`, serial stages, artifact root `/tmp/vinetrack-mait-contract-o0mlbrtq`. Each stage exit0, failures0, errors0, skipped0:

- Weather/irrigation **52 passed in215.740s**: `MAITCurrentObservationContractTest`, `CurrentObservationRepositoryTest`, `ForecastParityContractTest`, `SprayForecastWindowsTest`, `IrrigationCalculatorFixtureTest`, `IrrigationRegionalAdviceTest`.
- Authority/isolation **209 passed in12.488s**: `ReadOnlyEntitlementContractTest`, `VineTrackAccessRowCompatTest`, `VineyardWriteAuthorityTest`, `PinPhotoWorkflowTest`, `FertigationMobileWorkflowTest`, `ResistancePlanRepositoryTest`, `ResistancePlanRevisionSyncTest`, `FertigationDomainTest`, `TripOccurrenceJournalTest`, `StartTankCommitCoordinatorTest`, `TripWriteAdmissionTest`.
- Startup/offline **55 passed in12.037s**: `RetainedStartupTest`, `SyncRecoveryStorageTest`, `SyncCrashIsolationTest`, `ActiveTripStoreTest`, `OfflineQuickActionsTest`, `TripEndGateTest`.

Artifacts include each stage's `result.json`, exact Gradle command, suite/case XML and `gradle.log`; aggregate `summary.json`. All application/host-test source remained unchanged after these results. The subsequent change was instrumentation-fixture-only.

**Android instrumentation:** final `com.rork.vinetrack.data.MAITCurrentObservationAndroidTest` returned **9 passed/0 failed/0 skipped in12s**. Production repositories and disposable synthetic sessions, MockEngine HTTP; no live customer/station connection. New methods cover exact supplementary member JWT/body/request-scope under a read-only vineyard,206 and independent module failure, unchanged primary reread, sanitized supplementary failure, switched vineyard/account and recovered same-account incarnation rejecting old responses, explicit WU/Davis failures never invoking another primary provider and explicit none sending no primary refresh.

Initial instrumentation selection returned **4 passed/5 failed/0 skipped**. The new incarnation scenario left its test-only in-memory guard locked; subsequent tests failed at synthetic `SessionStore.save`, not a weather assertion. Test fixture corrected to call the existing verified-original restoration seam with a synthetic original principal before returning the delayed response. The response must now be rejected even with the same account restored and guard unlocked, and subsequent tests remain isolated. No production recovery or session relaxation. Final nine-test selection above passed after that correction; do not add overlapping executions.

**Final builds:** separate normal `runChecks(ios)` **PASS, simulator build succeeded**; normal `runChecks(android-vinetrack)` **PASS, build succeeded**, after their focused test gates. No overlapping Android Gradle operations. Existing nonblocking legacy asset-address advisories remain unchanged. `git diff HEAD --check` PASS. No dependency, project/scheme, manifest, version, release or signing configuration edits.

### Exact changed application/test files and source identity

Eleven-file delta manifest relative to base `de8d6cc9560d660e2b1758618ae232d8febb6e6b`; SHA256 of the ordered lines below, including their newline separators, is `446b4ee1ea07e83cc29558505acc491af10100a0737373842d454d1822e97bb1`:

```text
aa6a664b73c39a4424ac6ee2b73d61417f05807dc28649d5a6f0e18beb074ffe  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/MAITCurrentObservationAndroidTest.kt
23b5b781a7e9f0e2d7953bc11cb33692d3f9674a321de2c7c10ffdbbbd47f652  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/CurrentObservationRepository.kt
79d0c76632a9216a6f35f05efa1a9e160854ae409a049a2a397bd221ede75c2c  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MAITSupplementarySensors.kt
adb5f1d2506a04ef3a116ff5585e9a34d5d9ea9abc5197dab4610124b3dffd6a  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/RainAndForecastScreen.kt
8fce9572d64489467934966cc4f23ce0bc8028d515e099b7cb7cca3f14049bf2  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/WeatherDataScreen.kt
380b53ee543882f94a23078cc78025ae3a647d46e8b028321af3317494b931ad  android-vinetrack/app/src/test/java/com/rork/vinetrack/data/MAITCurrentObservationContractTest.kt
1264ef4fa8ee40b529a8e71c398cefe02aed161e85bbd34499deed7fc0338d66  ios/VineTrack/App/MAITSupplementarySensors.swift
f563249e6a7448c22dd4bded4fbf06d9dea54c11f9d3b037c78eb0ca4cc3eccc  ios/VineTrack/App/RainAndForecastView.swift
b712471685d5b3ead55d362b16d78137e19a8439f1e83de858cad22fa28487b3  ios/VineTrack/App/WeatherCurrentService.swift
e1a756b29f7735da518f03ef0f97456f93003cec26ddc4887af2acc9d1bf2fe1  ios/VineTrack/App/WeatherDataSettingsView.swift
2d95b4adc748813f3b2e9df2258d8b6ef80c5d93242156fe8741c24a9d5140e8  ios/VineTrackTests/MAITSupplementarySensorTests.swift
```

The existing approved plan and this existing report were updated separately. No additional reporting scripts, new documentation files or backend files were created. Managed project state/history changes are not application code and were preserved.

### Remaining acceptance / limits

No configured-vineyard live backend response was fetched or verified; the supplied contract/fixtures are the implementation basis. No physical iPhone/Android device, interactive screen QA, actual account-switch UI journey, station outage or Portal-change propagation acceptance was performed. Confirm friendly names/timestamps/readings for configured additional modules, nulls/statuses/206, manual refresh/no-newer and primary retention, immediate clearing during real account/vineyard switches, unchanged forecasts/rainfall and exact frozen irrigation labels on physical devices. Authenticated RLS/member access and real token refresh/retry are not established by synthetic HTTP. Device/Release iOS build is not verified. Native-wide enforcement, unknown-outcome/process-death recovery, the separate23-case backend fixture and all release gates remain independently open.


## Exact expanded iOS MAIT regression rerun — 26 October 2026 — PASS

**Expanded iOS MAIT regression gate: PASS.** Explicitly authorised exact20-suite rerun against unchanged current application and test source. Managed `swiftTest(ios)` returned: **“Swift tests passed for ios: 297 passed in 78s.”** This is a genuinely executed successful result, not the preceding zero-test framework-loading failure and not a union of earlier selections.

- Tests executed: **297 confirmed passing executions**; the runner exposes no separate total including skipped tests.
- Passed: **297**.
- Failed: **0 reported; tool returned success**.
- Skipped: **not reported by the runner; do not infer zero**.
- Duration: **78 seconds**, as returned by the runner; no separate build/execution timing supplied.
- Final tested application/test source revision: **`601d581867e69bad5a03d0725eaabdf077f568e1`**. `git diff HEAD -- ios android-vinetrack` empty before execution; no app, test, scheme, project, dependency, startup/session, MAIT, authority, version, signing or backend edits. Subsequent changes are this report and the existing approved plan only, apart from preserved managed state. The later documentation save does not change the tested source identity.

Exact submitted selectors (all under `VineTrackTests`):

1. `MAITCurrentObservationTests`
2. `CurrentObservationProviderTests`
3. `DeviceTripOwnershipTests`
4. `VineyardWriteAuthorityTests`
5. `ReadOnlyEntitlementContractTests`
6. `SpraySaveForLaterTests`
7. `EntitlementDecisionTests`
8. `EntitlementAccessRegressionTests`
9. `OfflineQuickActionsTests`
10. `ResistancePlanRepositoryTests`
11. `ResistancePlanRevisionSyncTests`
12. `FertigationMobileWorkflowTests`
13. `FertigationDomainTests`
14. `TripOccurrenceJournalTests`
15. `StartTankCommitCoordinatorTests`
16. `PinPhotoWorkflowTests`
17. `VineyardMutationAdmissionTests`
18. `LinkedPinGrowthDeletionWorkflowTests`
19. `MobileRequestSyncSafeguardTests`
20. `GrowthStageVarietyParityTests`

The result is the managed runner's aggregate for that exact request, not a per-suite/per-method discovery manifest. Do not add the earlier78, focused11, maintenance302 or separate79 results: they overlap or select different boundaries.

Environment handling: inspected the existing shared Debug Test action, enabled hosted `VineTrackTests`, `TEST_HOST`/`BUNDLE_LOADER`, iOS18 deployment settings and Swift Testing imports without edits. The managed runner builds and executes the test products; no exposed parameter permits remote derived-data cleaning, test-host reconstruction or independent SDK/runtime framework inspection. One explicitly authorised rerun succeeded, so no speculative environment patch or repeated retry was made. The local `/tmp/rork-swift-test-ios.log` was inspected but is **stale** (mtime05:17 UTC versus this run around06:44 UTC) and ends in an earlier hosted-bundle connection failure; its SDK, dependency versions, failure and timing are not evidence for this successful run. No current detailed result bundle, skipped metric or runtime inventory was exposed. The historical Apple `Testing.framework` failure remains recorded as infrastructure/unverified, not a MAIT product failure; its root cause is not claimed fixed or diagnosed.

**MAIT mobile source frozen for the next stage: configured-vineyard physical acceptance.** Android's accepted311 host plus5 MAIT instrumentation and normal build results remain accepted; no Android work rerun. Both existing normal builds are retained; no unnecessary build, preview, release/upload, owner-data or operational action performed.

Physical acceptance remains separate and unexecuted: selected MAIT/source/station and timestamp; available temperature/humidity/wind/rain; absent metrics staying absent; stale state; failed refresh retaining last-known readings; same-timestamp/no-newer feedback; account/vineyard switching; unchanged forecasts; Portal-only configuration; frozen MAIT irrigation source label and no historical recalculation. This closes the requested automated MAIT gate only, not the independent23-case read-only/native/backend or release gates below.

## Maintenance foreground / attachment enforcement and fixture preparation — 26 October 2026 — PARTIAL, NOT NATIVE-COMPLETE

**Maintenance transports are guarded; overarching native enforcement and authenticated 23-case acceptance remain incomplete.** Do not claim NATIVE ENFORCEMENT COMPLETE — BACKEND FIXTURE READY FOR 23-CASE ACCEPTANCE. Historical entry and notice/purchase UX remain disabled. This supersedes the earlier MAIT-only latest-scope label, not its accepted implementation.

### A. Delivered iOS maintenance boundaries

`MaintenancePhotoStorageService` now uses the shared `VineyardMutationAdmission` account incarnation and owning vineyard. Known-held uploads/deletes stop before ownership reads or storage mutation. Upload resolves exact maintenance-row ownership; only an explicit local-first upload permits an absent remote parent. Delete requires the exact canonical vineyard/maintenance-record object path, validates optional hints and resolves the actual parent; malformed, wrong-parent or unresolved paths cannot send or clear cached evidence. The injected seam replaces external I/O only, not production admission/cache behavior.

`SupabaseMaintenanceLogSyncRepository` now scopes maintenance upsert/delete requests through exact row ownership and the same captured account admission. Upserts are sent by owning vineyard; successful storage receipts remain acknowledged if expiry arrives in flight, while subsequent metadata writes are held. Shared admission recognizes **only** structured `PostgrestError.code` or SDK `StorageError.error == VT_READ_ONLY`; HTTP403 or a message containing that text is not inferred expiry. Official supabase-swift2.44.1 `StorageError` declaration was inspected; deployed storage error representation is still a delivered-contract requirement.

Foreground continuation: `MigratedDataStore` maintenance add/edit/delete now returns an accepted/denied result and admits the original owning vineyard before persistence or callbacks. Exact persisted ownership wins over stale loaded/editor data; ambiguous or duplicate originals and forged vineyard edits fail closed. Add no longer substitutes the selected vineyard. Scoped slice persistence does not overwrite another loaded vineyard. Update retains the original author. `AddEditMaintenanceLogView` captures account-incarnation/vineyard scope once, preserves its draft through repeated appearances, uses a stable new-record identity, rejects Save after selection changes, and dismisses only after an admitted Save/Delete. Delete rechecks ordinary permission. These are bounded foreground/store changes, not all local-first forms or process-death draft acceptance.

### B. iOS original retry/evidence retention

Maintenance sync admits each record's own vineyard before saving cache/uploading and rechecks its original account admission before the following metadata request. A successful metadata acknowledgement cannot clear a record still awaiting its photo: the original dirty timestamp is retained, not regenerated or counted as an ordinary failed retry. Missing records in the currently loaded slice no longer cause original retry markers to be discarded. A genuine upload path is persisted even if a following send is held. Existing immutable Start-receipt recovery, original Tank1/GPS gate and prior field-operation contracts were not changed.

### C. Delivered Android boundaries and retained evidence

`MaintenanceWriteScope` captures the existing account incarnation/authority instance, validates identifiers, performs authenticated exact maintenance-row ownership lookup and rechecks after suspension. Maintenance upload, delete, photo-reference update and maintenance CRUD use shared `TripWriteAdmission`; both account-request and operational-vineyard attributes reach the existing refresh/retry interceptor. Structured rejection is classified before ordinary401/403 mapping. Existing-parent photo upload/delete fails closed on missing/ambiguous/mismatched ownership; selection cannot authorize another object's mutation.

`removeMaintenancePhoto` no longer swallows failed/held storage deletion and clears the reference anyway. Follow-up upload-reference/delete-reference writes are separately admitted and cannot switch accounts; stale-account failures do not sign out the next user. `MaintenancePhotoEvidenceStore` retains original compressed bytes, author/vineyard/record, original staging timestamp/revision and real successful upload path in account/vineyard-scoped files. Explicit retries reuse those original bytes/path rather than overwriting the staged evidence with a newly picked image. Evidence is removed only after successful metadata acknowledgement. No automatic maintenance-photo replay, retry counter, startup observer or new background worker was introduced. Full UI/process-death/concurrent retry and delete-acknowledgement recovery remain unverified; the evidence-store timestamp is staging time, not a rewrite of the maintenance row's authored timestamp.

Android maintenance create/update/delete replay now freezes candidate versions to the existing account scope, claims each exact original, and uses compare-and-acknowledge/status/retry outcomes. Typed admission denial restores the original payload, identity, status, error, attempts and timestamps, including ID-only deletes. Waiting on unresolved same-log dependencies also restores the original rather than rewriting it as FAILED. Cancellation is rethrown after exact-claim restoration; stale-account completions cannot remove another account's queue row or publish a success callback. A failed local restoration retains that precise restoration outcome for bounded persistence recovery rather than converting it into an ordinary network retry. This is bounded replay repair, not foreground/local-command or process-death acceptance.

Foreground continuation: Android's editor captures original vineyard/session incarnation/authority once. Actual ViewModel create/update/delete admit before local UI or queue changes; update/delete resolve exactly one original row instead of selected vineyard. Suspended transports retain original owner hints, recheck captured admission, reject stale-account completion, and restore only the attempted row rather than a stale whole list. Successful metadata responses received during expiry remain acknowledged; held success UX is suppressed and photo follow-up is independently withheld. Stable editor create ID/time survive explicit retries. A final executed regression exposed duplicate optimistic rows and a second create after an acknowledged response during expiry; the repaired caller now rejects another create for that already loaded draft ID without replacing its genuine acknowledgement.

`coalesceMaintenanceIntent` and `cancelUnsentMaintenanceCreate` replace remove-before-enqueue with one durable commit after original-owner admission. Coalescing retains operation ID, original creation baseline and attempts; matching duplicate/blocked/in-flight evidence fails closed. Cancellation removes only genuinely unattempted PENDING originals and rejects attempted/failed/blocked evidence. Retained legacy ID-only delete bytes still decode; newly enqueued deletes require explicit original vineyard. Repository CRUD scopes are captured at invocation before the dispatcher suspension, not after it. ViewModel and Compose callbacks report denial without dismissing the editor. No startup, costing, shared-authority architecture or accepted receipt-recovery redesign.

### D. Additional direct-attachment audit — source gaps remain

Source search covered native `.upload`, storage object POST/DELETE and iOS `remove(paths:)` sites; these are boundary findings, not live exploit proofs or complete caller/replay acceptance:

- iOS `Backend/Storage/VineyardLogoStorageService.swift:29,69` and Android `data/VineyardLogoRepository.kt:42,107`: direct logo upload/delete lacks shared operational/account admission.
- iOS `Backend/Storage/ELStageImageStorageService.swift:45,85` and Android `data/GrowthStageImageRepository.kt:83,105,128,185`: custom reference-image object/metadata changes lack shared admission.
- iOS `App/Insights/VineyardInsightsSyncRepository.swift:394–408,430` and Android `data/insights/VineyardInsightsSyncRepository.kt:96–116,162`: scouting photo metadata/upload and orphan-object cleanup need per-send original-owner/account admission; cleanup is still an operational delete.
- iOS `App/ChemicalIntelligence/ChemicalSearchV2View.swift:325,329` and Android `data/chemical/ChemicalSearchV2.kt:242,248`: label upload and attachment-row insert need separate admission across suspension; existing stable-path recovery is not an authority check.
- Previously guarded Pin/Growth storage remains unchanged. Support attachment uploads and catalogue `search-inputs/{user}` uploads are separately inventoried account/support/discovery paths, not silently vineyard-blocked here. Their account-incarnation behavior/read-only exceptions still need explicit acceptance. Reference/master image/report downloads are reads, not prohibited storage mutations.

These concrete bypasses prevent case13 and native completeness from being signed off. The initially discovered legacy maintenance metadata replay/attempt gap was subsequently repaired as described in C and exercised in F. A further actual replay regression first reproduced dependency deferral rewriting a held ID-only delete's status/error/timestamp; that path is now repaired too. The subsequently reproduced foreground/store/folding/cancellation failures are now repaired within the bounded seams in A/C and validated below; they were not covered by the preceding photo-only result. This still does not establish maintenance-wide safety: online unknown outcomes, durable foreground drafts/metadata acknowledgements across actual process death, automatic photo replay, concurrent attempts and delete-receipt recovery remain open. The create receipt regression verifies loaded acknowledgement preservation and duplicate prevention, not a durable receipt worker or restart acceptance. Other preceding gaps remain: Growth original-author replay, independent Insights/planning journals, resistance/fertigation retry callers, suspended Spray/occurrence/GPS acknowledgements, real SDK/HTTP refresh-retry behavior, all exposed completed-history mutations and full offline/restart/account/vineyard permutations. Closing maintenance does not make backend access the sole blocker.

Additional read-only logo audit: `BackendVineyardDetailSheet` shows controls using `canChangeSettings`, but does not capture original account/vineyard admission across upload/reference/delete awaits and falls back to `initialVineyard`. `VineyardLogoStorageService` has configuration-only mutation checks and caches successful upload/path before metadata. `SupabaseVineyardRepository` updates the supplied vineyard ID without operational account-generation admission. Fixed-path `<vineyard UUID>/logo.jpg` upsert can change the object before reference failure; post-await cache/store writes lack stale-account fencing. No durable account-bound receipt/retry record was established. This is source audit evidence only; no failing-before logo execution or repair is claimed.

### E. iOS behavioral evidence

- New seven-method `MaintenancePhotoAdmissionTests`: held upload/delete zero read/send plus unchanged cached bytes/path; restored hold/other-vineyard non-release; exact writable path/bytes; expiry during successful upload retains receipt and stops subsequent delete; malformed/wrong-owner/hint rejection; same-user new-incarnation suspension rejection; exact structured SDK error versus ordinary forbidden; original metadata/photo retry timestamp across store recreation. These are synthetic production-service seams, not authenticated SDK/RLS or historical-screen UI journeys.
- Initial expanded20-suite selection after first maintenance changes: **301 passed in244s**. After SDK error/cache assertions: **302 passed in120s**. After retaining missing-slice markers, final same20-suite selection: **302 passed in56s**. Successful runner aggregates, not a per-method XML discovery manifest.
- Final selection: `MaintenancePhotoAdmissionTests`, `DeviceTripOwnershipTests`, `VineyardWriteAuthorityTests`, `ReadOnlyEntitlementContractTests`, `SpraySaveForLaterTests`, `EntitlementDecisionTests`, `EntitlementAccessRegressionTests`, `OfflineQuickActionsTests`, `ResistancePlanRepositoryTests`, `ResistancePlanRevisionSyncTests`, `FertigationMobileWorkflowTests`, `FertigationDomainTests`, `TripOccurrenceJournalTests`, `StartTankCommitCoordinatorTests`, `PinPhotoWorkflowTests`, `VineyardMutationAdmissionTests`, `LinkedPinGrowthDeletionWorkflowTests`, `MobileRequestSyncSafeguardTests`, `GrowthStageVarietyParityTests`, `MAITCurrentObservationTests` under `VineTrackTests`.
- Separate six-suite weather/current-provider/forecast/irrigation gate: **79 passed in20s** (`MAITCurrentObservationTests`, `CurrentObservationProviderTests`, `ForecastParityContractTests`, `RegionFormatterWeatherParityTests`, `IrrigationCalculatorFixtureTests`, `FertigationHistoryTests`). This preceded only the last maintenance missing-slice marker adjustment, not weather changes. Together the selections cover the previously blocked expanded MAIT selection; no speculative startup repair. Its zero-test failure remains historical.
- Separate final `runChecks(ios)` **PASS: simulator build succeeded**. Physical-device/Release build not verified. Two existing nonblocking legacy asset-address advisories unchanged.

Foreground failing-before: `MaintenanceForegroundAdmissionTests/heldOriginalCannotBorrowSelectedVineyardForCreateEditOrDelete` executed **0 passed/1 failed** because persisted original A bytes changed while A was held and writable B selected. After the foreground repair, the four maintenance/authority suites passed **38 in137s**; that run preceded the final stable sheet identity change and is intermediate, not the final-source gate.

**Final unchanged iOS-source gate for this continuation:** managed `swiftTest(ios)` executed **294 passed in197s**, tool success/zero failures reported; skipped count is not exposed and is not inferred. Exact20 selectors, all `VineTrackTests/`: `MaintenanceForegroundAdmissionTests`, `MaintenancePhotoAdmissionTests`, `DeviceTripOwnershipTests`, `VineyardWriteAuthorityTests`, `ReadOnlyEntitlementContractTests`, `SpraySaveForLaterTests`, `EntitlementDecisionTests`, `EntitlementAccessRegressionTests`, `OfflineQuickActionsTests`, `ResistancePlanRepositoryTests`, `ResistancePlanRevisionSyncTests`, `FertigationMobileWorkflowTests`, `FertigationDomainTests`, `TripOccurrenceJournalTests`, `StartTankCommitCoordinatorTests`, `PinPhotoWorkflowTests`, `VineyardMutationAdmissionTests`, `LinkedPinGrowthDeletionWorkflowTests`, `MobileRequestSyncSafeguardTests`, `GrowthStageVarietyParityTests`. This selection replaces the preceding maintenance20-suite selection's MAIT suite with the new foreground suite; do not compare or combine its count as if selectors were identical. Accepted exact MAIT297 remains a separate frozen historical gate. A later Android-only duplicate-create fix did not change this tested iOS source. Separate final `runChecks(ios)` **PASS, simulator build succeeded**. Device/Release acceptance remains unverified; existing legacy asset-address advisories unchanged.

### F. Android failing-before, host, instrumentation and normal build

- Before the production Android repair, actual `MaintenancePhotoAdmissionAndroidTest#heldUploadDeleteAndReferenceSendZeroMutations`: **0 passed/1 failed/0 skipped**, assertion **“Held maintenance mutation reached transport expected:<0> but was:<1>”** on upload. This is a genuine intercepted production-repository assertion failure, not a launcher/build failure. It did not reach later loop assertions, so do not claim separate observed delete/reference failing-before executions.
- After guards, three maintenance methods plus the preceding nine recovery/admission instrumentation selectors: **12 passed/0 failed/0 skipped in11s**. After adding structured/ordinary/stale error coverage and five MAIT methods: **18 passed/0 failed/0 skipped in11s**. Disposable synthetic session/MockEngine; no live fallback or owner data. Final post-stale-caller-fence rerun: **18 passed/0 failed/0 skipped in11s**. Exact selectors: `MaintenancePhotoAdmissionAndroidTest`, `PinPhotoAdmissionAndroidTest`, `RetainedStartupConstructionTest#expiredTankPreviewAndCommandsKeepOriginalDiskDraftAndReconciliationMarker`, `SprayStartProductionAndroidTest` methods `expiredCalculatorStartDoesNotPrepareOrSendReplacementWork`, `receiptReadOnlyRestoresUnclaimedOriginalAndStillAllowsRecoveryRead`, `blankHoursActivateOriginalAndKeepFirstTankGpsSafetyGate`, `acceptedButReloadFailedStartsVerifiedOriginalWithoutAnotherCreate`, `lostResponseUsesRecoveryOnlyAndKeepsOriginalOperation`, plus `MAITCurrentObservationAndroidTest`. These are requested selections with aggregate observed counts, not all native instrumentation or process-restart acceptance.
- Initial expanded host runner: **212 focused/0 failures/errors/skips in28.513s**, including three new `MaintenancePhotoEvidenceStoreTest` methods; **55 existing regressions/0 failures/errors/skips in12.133s**, exit0. Artifacts `/tmp/vinetrack-read-only-contract-m82qx9e7`. Final post-caller-fence host rerun: **212 focused/0 failures/errors/skips in193.560s; 55 existing regressions/0 failures/errors/skips in12.140s**, both exit0, `/tmp/vinetrack-read-only-contract-h62tlnv2/{contract,existing-regressions}/result.json`, suite XML and `finished.json`. The unchanged runner's11 original authority suites plus `MaintenancePhotoEvidenceStoreTest` make the focused12-suite selection; existing six regression suites remain separate.
- Subsequent actual-replay tests: the seven-method maintenance class initially passed **7/0/0 in7s** after exact-claim conversion. The added `heldDeleteWithDependencyDoesNotRewriteOriginal` then **failed 0/1/0** before its dependency fix: original PENDING/null error/date became FAILED/“Waiting for this maintenance log's other changes to sync first.”/new date, despite zero retry attempts. This is a distinct observed failing-before assertion, not an inferred transport bypass. The final expanded selection executed **21 passing tests**, but the tool marked the request failed because one startup selector used the wrong package and did not execute. Corrected selector `com.rork.vinetrack.data.auth.RetainedStartupConstructionTest#expiredTankPreviewAndCommandsKeepOriginalDiskDraftAndReconciliationMarker` then passed **1/0/0 in12s**. The successful union is **22 distinct tests** on final source, not one clean22-test tool aggregate; the missing-selector request is retained as a selection failure, not a production assertion failure. Final eight maintenance methods include all three real metadata replay operations under known hold, structured rejection, unchanged original payload/status/error/timestamps/attempts after repository/disk reread, writable-B non-release, explicit writable-A release exactly once, dependent-delete retention and stale-account success with no acknowledgement/callback. Test login/transport remain synthetic; repository recreation is not main-app process death. Earlier18-test results precede this replay change.
- Final host rerun after the dependency and restoration-outcome fixes: **212 focused/0 failures/errors/skips in13.189s; 55 existing regressions/0 failures/errors/skips in12.145s**, both exit0. Artifacts `/tmp/vinetrack-read-only-contract-hptl9b32/{contract,existing-regressions}/result.json`, suite/case XML and `finished.json`. The intermediate post-claim-conversion run `/tmp/vinetrack-read-only-contract-158mzvzy` also passed212/55 but preceded the last dependency/restoration adjustments; it is not substituted for this final result. Production replay behavior is exercised by instrumentation; host suites remain the existing focused authority/evidence and regression selections, not a new maintenance coordinator host suite.
- Host fixture verifies byte-for-byte original file set/timestamp/revision/receipt after recreation and changed retry image; independent account/vineyard evidence; wrong-scope receipt rejection and malformed paths. It does not exercise actual ViewModel photo-picker or process death.
- Separate final `runChecks(android-vinetrack)` after all replay/restoration changes **PASS: build succeeded**. Two existing nonblocking legacy asset-address advisories unchanged. Five historical unrelated completion failures remain unresolved/excluded, not claimed green. Accepted startup final initializer and costing logic remain unchanged; no version/signing/dependency edit.

Foreground failing-before and intermediate records:

- Actual ViewModel held selection: **0 passed/1 failed/0 skipped**, uncaught `VineyardWriteAuthority.Restricted: VT_READ_ONLY` rather than truthful denial.
- `heldForegroundCoalescingAndCancellationRetainExactOriginalQueue`: **0 passed/1 failed/0 skipped**; original queue became `[]` because remove-before-replacement admission discarded the create.
- First expanded post-fix instrumentation: **13 passed/1 failed/0 skipped**, `WRITE_SCOPE_UNRESOLVED` because a legacy ID-only replay fixture used the newly guarded foreground enqueue. Fixture correction seeded historical ID-only payload bytes through low-level `pending.enqueue`; production admission was not relaxed. Expanded same two classes then **16 passed/0 failed/0 skipped in8s**, before the final lazy draft identity/time changes.
- Intermediate host run `/tmp/vinetrack-read-only-contract-y7yyox37`: **217 focused in28.712s / 55 existing regressions in211.167s**, zero failures/errors/skips, both exit0 and completed `finished.json`. Source changed during/after that run; not final frozen-source evidence.
- After stable identity changes, `RetainedStartupConstructionTest#maintenanceCreateReceiptDuringExpiryCannotDuplicateStableDraftOnRetry`: **0 passed/1 failed/0 skipped**, expected one acknowledged row but observed two same-ID acknowledged rows after the second create. This is a product assertion, not infrastructure failure. Added only a same-draft already-loaded guard before optimistic insertion/transport; no recovery redesign.

**Final Android instrumentation:** exact classes `com.rork.vinetrack.data.MaintenancePhotoAdmissionAndroidTest` and `com.rork.vinetrack.data.auth.RetainedStartupConstructionTest`: managed runner **17 passed/0 failed/0 skipped in8s** after the duplicate-create fix. Covers production repository/replay/ViewModel seams with intercepted synthetic transport and disposable Application. No authenticated fallback, retained customer install, actual process death, physical-device or complete UI journey is claimed.

**Final Android focused host gate:** **217 tests, zero failures/errors/skips, exit0 in26.831s**. Exact13 selectors: `ReadOnlyEntitlementContractTest`, `VineTrackAccessRowCompatTest`, `VineyardWriteAuthorityTest`, `PinPhotoWorkflowTest`, `FertigationMobileWorkflowTest`, `ResistancePlanRepositoryTest`, `ResistancePlanRevisionSyncTest`, `FertigationDomainTest`, `TripOccurrenceJournalTest`, `StartTankCommitCoordinatorTest`, `TripWriteAdmissionTest`, `MaintenancePhotoEvidenceStoreTest`, `MaintenanceForegroundQueueTest`. The new five-method queue suite verifies durable-commit failure retention, held exact originals, attempted-create cancellation denial, ambiguity rejection and positive operation-lineage coalescing.

**Final Android existing regressions:** **55 tests, zero failures/errors/skips, exit0 in12.105s**. Exact six selectors: `RetainedStartupTest`, `SyncRecoveryStorageTest`, `SyncCrashIsolationTest`, `ActiveTripStoreTest`, `OfflineQuickActionsTest`, `TripEndGateTest`. Focused/regression artifacts `/tmp/vinetrack-read-only-contract-r7m_wvul/{contract,existing-regressions}/result.json`, per-suite/case XML and `finished.json`. Durations are runner stage wall time, not summed XML test-body time. No Android Gradle operations overlapped.

**Final separate normal Android build:** `runChecks(android-vinetrack)` **PASS, build succeeded** after final host stages completed. Existing two nonblocking legacy asset-address advisories unchanged. Five unrelated historical completion failures are excluded and unresolved, not silently passed. Final source identity is I below; no application or test changes after these final gates.

### G. Offline backend fixture preparation — no authenticated execution

`scripts/prepare-isolated-read-only-acceptance.py --requirements` emits the exact original23 case descriptions read from the existing ledger, never a substitute matrix. `--fixture` is an offline fail-closed validator producing an allowlisted NOT_EXECUTED worklist and fixture-byte SHA256. It has no HTTP/auth client or execute option, accepts no secrets/elevated keys and cannot query owner/customer records. It checks distinct canonical IDs, explicit row/attachment ownership, synthetic-only isolation, controlled A-only state transitions and delivered capability/receipt/storage/readback references. `scripts/verify-isolated-acceptance-preparer.py` passes the valid synthetic schema, exact23 extraction and eight rejected unsafe configurations with **zero authenticated requests**. This is preparation, **not a ready executable authenticated acceptance harness**; a contract-bound authenticated adapter and actual native/UI evidence collection remain unfinished.

Exact minimum fixture inventory requested, not created or queried:

- Two dedicated ordinary synthetic users: operator in synthetic A/B; isolation user in B only, with no A/customer memberships. Use an interactive test-user login or an existing short-lived test session via the approved mechanism. No owner credentials or service-role key are requested. Existing project connection can be reused only after isolation approval; a new backend/key is not a blanket prerequisite.
- Two dedicated synthetic vineyards A/B and a block in each. A must supply exact IDs/relations for completed Spray, completed Trip, completed Tank, planned Spray, active Spray, active Trip, active Tank, GPS evidence, Pin, Growth, maintenance log, fertigation, resistance and scouting rows; B additionally supplies Pin and maintenance controls. Shared roots/FKs must reference only this synthetic fixture. The offline validator requires18 distinct domain-row IDs in total; synthetic user/vineyard IDs are separate.
- Exact attachment bucket/object paths, parent IDs and owning vineyard for every attachment family exercised. Seeded images and any chemical/equipment/product/irrigation/snapshot dependencies must be synthetic and isolated; their exact relation/FK additions depend on the delivered server contract. Native-created held originals need pre-recorded IDs, original payload/journal/receipt/attachment digests and timestamps before expiry; no broad discovery query is permitted.
- Authoritative A writable → controlled expired read-only → reactivated writable states, explicit capabilities and reason, `VT_READ_ONLY`, storage error representation, immutable paired-save/recovery receipt contract and authoritative state readback. B remains writable throughout. The controller method, proof reference and whether it requires a server change must be delivered; none is invented or invoked.

Minimum application permissions: ordinary authenticated test membership with the least existing role that demonstrably succeeds on the writable positive controls for the tested CRUD/storage/delete routes. A manager-level fixture is the proposed bounded role, not a verified backend permission guarantee. The second user must demonstrate B access and A denial. No System Admin, ownership, billing administration or direct subscription-table permission is needed in the harness; controlled transitions must be handled separately by the approved fixture controller, not by giving the test user elevated credentials.

**Can synthetic data reside in the existing production Supabase project? NOT VERIFIED SAFE.** Potentially only if dedicated accounts/vineyards, RLS/storage boundaries, foreign keys, receipt/GPS/export/report behavior and all notification/analytics/integration/billing side effects are demonstrably isolated and approved. Identifiers and a “synthetic” label alone are insufficient. No records should be seeded there on this report's authority. **Are server changes necessary? UNKNOWN** until an approved scoped expiry/reactivation mechanism and delivered contract are verified; if none exists, a separately reviewed test-only control is needed. No server change/deployment is made or authorised here.

### H. Operational23-case status and closed UI gate

The original ledger below remains authoritative. **No case is newly signed off as full both-platform operational/authenticated acceptance.** Cases13/16–18/21–23 now have additional bounded maintenance evidence, but remaining attachment families and all-queue/UI/backend matrices are not complete. No authenticated permitted read, denied-write before/after equality, real exact-once release or deployed receipt/RLS isolation was executed. Zero requests is a safety record, not proof the backend denies writes. Historical entry, persistent notice and deliberate purchase prompt remain disabled; no reset, forced sign-out, release/store/export/version/signing or customer-data operation occurred.

### I. Source identity and protected boundaries

Final continuation source = starting HEAD `fe96f74c907a139bde46eaad33242a86e7715bb3` plus the exact27-file manifest below; inspected `git diff HEAD`, including managed staged edits, rather than unstaged-only diffs. Preexisting skills fingerprint/history retained without manual edits. Source-only allowlist/whitespace/Python syntax verification PASS. Final `PYTHONDONTWRITEBYTECODE=1 python3 scripts/verify-maintenance-enforcement-boundary.py --verify-report` also **PASS**, comparing every embedded manifest line and the aggregate digest against current bytes. The preceding21-file checkpoint had aggregate `66cc8850412874f93e94233de8c63006f210df0ff27e2d8db8ac8ff142031b70` at base `4647bc2fc975d86ae2b0d6872909c4eb90acabf3`; that historical report verification is not substituted for this continuation.

The verifier compares actual ViewModel bytes against current starting HEAD outside only `Maintenance log write path` through the maintenance-photo callers, and compares the iOS store outside only maintenance CRUD. Unrelated startup/session/costing/Start-recovery source is byte-identical. Accepted MAIT, shared authority enforcement and existing iOS receipt-recovery sources are outside the new delta; authority/admission files in this cumulative manifest retain accepted bytes. No version/signing/dependency/billing-routing change. Protected versions remain3.1.8 / iOS139 / Android12. This is source/test/runner identity, not signed-artifact provenance.

Sorted UTF-8 `SHA256(file bytes) + two spaces + project-relative path + newline` manifest SHA256 **`2e652c65c3a39c088b3576bd9f142468d6bd0c776c7b3c296a2c811f23097211`** (report, approved plan and preexisting managed state excluded; some files retain preceding accepted bytes):

```text
7b85f54d8b1131052bf52b7ca5c9f4afc1ead6368af4dc3173cce4ee5dbb8ac3  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/MaintenancePhotoAdmissionAndroidTest.kt
91b01af4f1ebe4d522e7cb6924abcff7d1cd9c00006a34c78162e16c870ba3f3  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/auth/RetainedStartupConstructionTest.kt
bb2d34a83a12766b25945befdc675b35e69c3e2ccc669e65947f38508024a68a  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogCreateSync.kt
6284f6e95064a7ea536f167a2dccfaa0a8f6f7014b4467f2f09a951157068353  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogDeleteSync.kt
33afd7e68cad56482ef363b564ffe4e691ca02af32fc06e1611ef3c9b8bce74f  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogRepository.kt
ecd8095065bdaba7da29c4a618f4b9eca6e7fb852ed0e3c433ecf2a41fdc2c07  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceLogUpdateSync.kt
a972146aa11914f0da80c05efaa239b3058e55dc72a67adf0f8d82d800273636  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenancePhotoEvidenceStore.kt
04408a89910ecb421987c3a28ff67e331180685155d1a30317109097f1822864  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenancePhotoRepository.kt
7772174ebb9ac9f75c2728a91a683cedc232e0fadb6770bd0d2345c3fa79adf9  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/MaintenanceWriteScope.kt
c48d86dc005c0cf439d806003504cf8ab4ebeabadbb7a0fad00fafab53d4b1e6  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PendingWriteRepository.kt
6c1efbc60aa9f648d565d16ce13dc3029cf7fc31b44c36a0f6d6416d82744d16  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt
6ab2dcdd703326304a471d80bd1018004226d70669a1470e82da9e780fbf12b9  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/MaintenanceScreen.kt
fe18c9783a4ebd6c1647fb1e1e6308ae06de5715bbcc4d01c0e3b5875210cbac  android-vinetrack/app/src/test/java/com/rork/vinetrack/data/MaintenanceForegroundQueueTest.kt
ed84e146755aa75646c48f3b6d854624446fe5c216ad1637db189094c74173ed  android-vinetrack/app/src/test/java/com/rork/vinetrack/data/MaintenancePhotoEvidenceStoreTest.kt
fbad5e395f6d37fe2df3a9c0d70b5d85f187c115bf93ba2e67b40f05257d02d8  android-vinetrack/entitlement-tests.init.gradle
6c9829d0657ecc38e40acf544a3c3df2c571b6b18a8ab04889b0ca89971412b1  ios/VineTrack/Backend/Repositories/SupabaseOperationsSyncRepositories.swift
68c9567dc9c8d16317702ebd6fdf859d2e3bc5c9ca30e69795e8c9ef9be7050d  ios/VineTrack/Backend/Storage/MaintenancePhotoStorageService.swift
b94041590ab260d49a783e12c903b48dff13bad09a0c3da07e0768a29c0d8f60  ios/VineTrack/Backend/Subscription/VineyardMutationAdmission.swift
71df9e33902e904030624e8f0e60901b5e921aa9b3b169c2098816b051f1b0c8  ios/VineTrack/Backend/Sync/OperationsSyncServices.swift
5db3943a1fc4f1233ab1b34cb05f52bf0bd5f0794ac3365b5725bd131552c516  ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift
fb4c7cebe47ffd8826f9bc6e619dfc6c166e76c74ff3280c299de28d7ca5cacf  ios/VineTrack/LegacyImported/Views/Maintenance/AddEditMaintenanceLogView.swift
25c888c68d74a93aa164632d94b6e5f510aeb13ea0edb9ba7641ecf8dd0da9f8  ios/VineTrackTests/MaintenanceForegroundAdmissionTests.swift
5947c8f790f960cb52caec6413e4a69d42c84f2b8182280bba3113056741b349  ios/VineTrackTests/MaintenancePhotoAdmissionTests.swift
d17d846a754a5e348acafec8f1f4a57bed8e761e7980747fb251984f2c676ae1  scripts/prepare-isolated-read-only-acceptance.py
83b55e1e9a8a34904c002e2570f98df781d2b54515942e3ef63a534e24af4363  scripts/run-read-only-entitlement-contract.py
d8c3d37a5a86b31d32d6e04bb104abec5e299507786d6333e61268ca0e5268f3  scripts/verify-isolated-acceptance-preparer.py
4aabd221da19adbb8df374a006ff17056bb67eac482db3563c5e10a85b11296f  scripts/verify-maintenance-enforcement-boundary.py
```

### J. Remaining checkpoint

**PARTIAL MAINTENANCE ENFORCEMENT; NOT NATIVE-COMPLETE; BACKEND ACCEPTANCE NOT RUN.** Finish the source gaps in D and preceding native matrices independently of fixture delivery, bind the authenticated adapter only after isolated contract inputs, and run all23 cases before considering historical entry/purchase UX or physical readiness. No overall readiness or release clearance is declared.

## MAIT iNTELLiWeb mobile-only implementation — 26 October 2026 (preceding checkpoint)

**Implementation and both normal builds complete; expanded iOS regression gate remains UNVERIFIED. No overall release or physical-device clearance.** This is the latest scope, not completion of the preceding expired-trial23-case acceptance. Previous enforcement/startup/costing work and its open gates remain unchanged.

### Delivered behavior and architecture

- Audited both native apps before editing. iOS retains its role-aware local-provider enum, resolver, integration cache and `WeatherCurrentService.CachedSnapshot`. Android retains its string-provider repository architecture, expanding the existing normalized `CurrentObservationRepository.CachedRow` rather than adding a MAIT model/cache. Rain & Forecast now uses that normalized row; Scout/Crop Health models remain unchanged.
- Explicit backend `mait_intelliweb` selection is displayed as **MAIT iNTELLiWeb**, current/local only. MAIT is absent from forecast choices and mobile setup options. While MAIT is selected, mobile cannot change/disconnect its source through the existing observation picker. Setup, testing, disconnect and controller mappings remain in the Portal. Ordinary members have the same read/refresh path; backend authentication/membership remains authoritative.
- Refresh POSTs only to VineTrack `mait-intelliweb-proxy`, with the signed-in user's JWT and exactly `vineyardId` plus `action: current`; a successful refresh rereads `get_vineyard_current_weather`. Missing prior normalized rows can refresh an explicitly selected source. An explicit backend `not_configured` status still prevents a refresh.
- No integration/cached MAIT source becomes an automatic fallback. Legacy null selection retains backend-resolved Davis then WU. A genuinely absent older-server selection RPC may use the same legacy route; network/auth/permission errors are not interpreted as null. Failures do not dispatch to a second provider. Existing WillyWeather/Open-Meteo forecast logic is unchanged.
- Current Conditions and Conditions Check show only present normalized metrics: temperature, humidity, wind speed/direction/gust, daily rainfall, rain rate and leaf wetness. No invented zeros or mobile MAIT channel/rainfall aggregation. Existing rainfall/history calculations are unchanged; only canonical MAIT provenance labels were extended.
- Last-known same-source readings, observation time and backend staleness survive failed/missing/no-data refreshes. Feedback uses “Live observations not refreshed — MAIT iNTELLiWeb” and, after an actual same-timestamp refresh, “MAIT iNTELLiWeb returned no newer reading — the station has not reported since the last update.” Account-generation/request-scope checks reject suspended results after account changes; dashboard state is scoped to the account/vineyard. iOS selected-source hydration no longer depends on a successful Davis setup-metadata read. A successful legacy/null selection clears a formerly explicit MAIT configuration, whereas selection transport failure retains the last verified configuration.
- Irrigation labels change **only** for `source_type == controller_api` plus `configuration_snapshot.import.provider == mait_intelliweb`. Other controller, CSV, Galcon and manual labels remain unchanged. `import_info` is not used to infer MAIT. Only minimal frozen source identity is decoded; no usage sync, recalculation, controller import, hardware or scheduling operation was added.

### iOS tests and build — separate evidence

1. Initial six-suite weather/regression selection **78 passed in136s**: `MAITCurrentObservationTests`, `CurrentObservationProviderTests`, `ForecastParityContractTests`, `RegionFormatterWeatherParityTests`, `IrrigationCalculatorFixtureTests`, `FertigationHistoryTests`. This predates the final account/selection handling refinements; it is not represented as a final-source comprehensive regression result.
2. Requested expanded20-suite selection **INCOMPLETE: zero passed/zero failed because zero executed**. The tool reported failure connecting to the hosted test bundle and Apple `Testing.framework` bundle loading (“The bundle couldn't be loaded”; “Referenced from … VineTrack”; “Expected in … Testing.framework”). No compiler error was reported. The underlying framework/runner cause is not proven; this does not establish a production startup regression. Do not change startup or weaken tests to conceal the failure. The unchanged expanded selection was not automatically repeated.
3. After the actual selection-error handling correction and new error-path assertion, the final focused `VineTrackTests/MAITCurrentObservationTests` selection **11 passed in133s**. Covers explicit selection and non-fallback, normalized null metrics, authenticated exact request, refresh/reread ordering, absent prior row, no refresh for fresh readings, failure retention/no fallback, no-data retention, cancellation, selection network errors and frozen irrigation labels. Request construction and injected production workflow are tested separately; this is not live authenticated backend or physical acceptance.
4. Expanded failed selection was the final focused MAIT/current-provider pair plus these18 existing suites: `DeviceTripOwnershipTests`, `VineyardWriteAuthorityTests`, `ReadOnlyEntitlementContractTests`, `SpraySaveForLaterTests`, `EntitlementDecisionTests`, `EntitlementAccessRegressionTests`, `OfflineQuickActionsTests`, `ResistancePlanRepositoryTests`, `ResistancePlanRevisionSyncTests`, `FertigationMobileWorkflowTests`, `FertigationDomainTests`, `TripOccurrenceJournalTests`, `StartTankCommitCoordinatorTests`, `PinPhotoWorkflowTests`, `VineyardMutationAdmissionTests`, `LinkedPinGrowthDeletionWorkflowTests`, `MobileRequestSyncSafeguardTests`, `GrowthStageVarietyParityTests`. Their earlier historical passes are not current MAIT regression evidence. Needs an explicitly authorised rerun.
5. Final separate `runChecks(ios)` **PASS: simulator build succeeded**. Physical-device/Release build and store delivery not attempted. Existing unrelated asset-URL advisories were not changed.

### Android tests and build — separate evidence

- Initial four-test instrumentation attempt: **3 passed/1 failed/0 skipped**. Failure was a test-only invalid cast of Ktor `TextContent` to `ByteArrayContent` while inspecting the request. Corrected the assertion fixture to read the actual `TextContent`; production transport was not changed for this failure. Corrected selection **4 passed/0 failed/0 skipped in10s**.
- After the older-server selection-RPC compatibility correction, final `com.rork.vinetrack.data.MAITCurrentObservationAndroidTest`: **5 passed/0 failed/0 skipped in7s**. Uses the production repository, disposable application/session and MockEngine: exact JWT/body/URL/scope, normalized reread, permitted refresh despite a read-only vineyard hold, no newer/no prior row, HTTP502/403/401 failure sanitization/no fallback/retention, missing older-server RPC versus permission denial, and account change during suspended selection. No production account, credential or backend was used.
- Final `scripts/run-mait-mobile-contract.py` host run at `/tmp/vinetrack-mait-contract-zsspvtsi`: **47/47 weather/irrigation in13.201s; 209/209 authority/isolation in12.442s; 55/55 startup/offline in12.180s**. Every stage has zero failures/errors/skips. The47 includes new six-test MAIT contract/null/full-metric/retention/request/snapshot-label suite plus existing current routing, forecast parity, forecast-window and irrigation calculator/regional-advice suites. Exact selections are retained in the runner; XML/result summaries are outside the project. Earlier run also passed47/209/55, before the final selection-RPC compatibility change.
- Final separate `runChecks(android-vinetrack)` **PASS: normal build succeeded**. No Play/AAB/release/signing/versionCode operation. Existing unrelated asset-URL advisories were not changed. The unrelated five historical completion failures were not repaired or represented as green.

### Security, preserved scope and remaining acceptance

- `python3 scripts/verify-mait-mobile-boundary.py` **PASS**: scans native production source for direct upstream MAIT endpoint/configuration credentials and new service-role/`sync_usage` operations; verifies no backend/schema edit. Native assertions verify the JWT/body/provider boundary. Source audit is not a live-backend security certification.
- `git diff HEAD --check` **PASS**. No SQL, Edge Function, Supabase table, dependency, app version/build/versionCode/signing, startup authority, entitlement authority, costing source or owner-device-data change. No live backend read/write, migration, store upload/release or retained-handset reset. Existing managed history/fingerprint changes were present before this work and are not part of the native source manifest.
- **Still required:** explicitly authorised expanded iOS regression rerun; physical iOS/Android acceptance on a safely configured synthetic/member vineyard for source/status/station/time, each supported/missing metric, stale/error/no-newer behavior, refresh authentication and vineyard/account switching, Portal-only configuration, unchanged forecast and canonical persisted rainfall totals, and correct controller snapshot label without historical volume/duration changes. No live MAIT station or physical device has been exercised here. Retained offline/restart/operator behavior is only partially covered by synthetic tests, not a full live field journey.

### Exact changed native/test/runner files

Starting HEAD **`0af7743a657c5c2775481aa3b5377365c70744e8`** plus the22 files below. Manifest SHA-256 **`e46c66e16d6f6a08a0bf7c5fccb8a4a6cc8b521d6ebabdb76afd8bc6c06402af`**, computed as sorted `path + NUL + lowercase SHA-256(file bytes) + NUL`. Final managed commit is assigned after the turn; do not substitute the starting HEAD for it. Existing report and approved plan updated separately.

```text
88504008222d70dbb16b21aa817e4b07b2e0730b194835c4574b7c6a26e3804e  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/MAITCurrentObservationAndroidTest.kt
58bba9dfd83242c11ec6f857d653dcc7dc205fa61deea4b029aa897cc8a48635  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/CurrentObservationRepository.kt
e3c8d62a7a3b573730e00a6176ee38eca068c49f022ce04b980fa3b5b06a4e2f  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/IrrigationRepository.kt
d4df7adbae6f7f2961605bb057c191ebe20e15f378b5c317054d55ce9d8a8095  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PersistedRainfallRepository.kt
683b44722a90ca8ba625782360a7d1af3659a2ac4b1b52760f247814578cc6d5  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/RainAndForecastScreen.kt
aefc9484f8788fdd8c36dbc812cf56195e7a22abb235810ff5f232bc7ca75c6f  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/RainfallCalendarScreen.kt
b6934105fa1a81556d5300d42ab49c0fcb4b2e3d8a41578d8b98d542945f881b  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/WeatherDataScreen.kt
4b0b90d23874f2edeb412ca686e4d94fbdd712f380159f06ef1c52b3a1e0e0b8  android-vinetrack/app/src/test/java/com/rork/vinetrack/data/MAITCurrentObservationContractTest.kt
00ed49bd392bc9b89938e51fa091fcfdb0c73602261cdd4c3f4b7e10c425cda6  android-vinetrack/mait-tests.init.gradle
b47c0f174c1b3747865ccec0c0967abfbd2d464adaacd077398db364f0d8284e  ios/VineTrack/App/HomeRainSummaryCard.swift
6032d664d7a8443ba5e1b617d1bc42d9d2cb98a051f58268a77b6642891b369b  ios/VineTrack/App/OperationsSetupHubView.swift
3e51f52817e154582f235f89d4cda88d4863557a3186911106153af6f427fb65  ios/VineTrack/App/RainAndForecastView.swift
32c4dba87c5c1a91310c084e70ca6d99281e6f5a1f64fb0d2a5e436bcb4dfa00  ios/VineTrack/App/VineyardWeatherIntegrationCache.swift
73d85175a38d6b134088fa30304ec0e2a500335fecac1f1a1ba43cc364654271  ios/VineTrack/App/WeatherCurrentService.swift
36c7f6b27068560d485de0dff6ec1e7b99a88c95a8bf6afc94397064ee9b4fb8  ios/VineTrack/App/WeatherDataSettingsView.swift
0a8baef1d5b6a1382c4e9444a882eebcff907462280758d603ed50e4f588b926  ios/VineTrack/App/WeatherProvider.swift
7b84201a53708728d695d19af4d831258d55212d13a4d375709e9057cf316d5d  ios/VineTrack/App/WeatherProviderResolver.swift
04cdf87352d8a6f7b2c9f056aa1e337af778b9c569db22c95e5cad505f1ff7b1  ios/VineTrack/Backend/Models/BackendIrrigation.swift
98d8f24efa84ffd7ca0a38d9879135da33cbe2e792b1dc739f9313500a5894c8  ios/VineTrack/LegacyImported/Views/Phenology/RipenessSurfacesViews.swift
1a112fd55af1077551d131728773848c3c1a8ea2c0f8f6ed30609c8767a3cdcd  ios/VineTrackTests/MAITCurrentObservationTests.swift
5a707d29e1cd0acbc3d514a16bc45f177bc3777025417c0db210ba7acfa996c8  scripts/run-mait-mobile-contract.py
6cd9759b2a3bdb820d841d324aaa22b43d486096216adabb1834abf41c85a160  scripts/verify-mait-mobile-boundary.py
```

## Isolated acceptance continuation — 26 October 2026 — NOT READY FOR PHYSICAL DEVICE TESTING

The owner supplied the authoritative23-case matrix and authorised isolated authenticated test-account/test-vineyard acceptance. Those are no longer missing permissions/checklist blockers. **Actual isolated connection details, test credentials, fixture IDs and the expiry/reactivation control contract remain missing.** Native enforcement completeness also remains independently unfinished. Historical entry and notice/purchase UX have NOT been enabled; no store upload/release, production owner-data query/mutation, migration/deployment or retained-device operation occurred.

### A. Changes and accepted recovery contract

Only `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/SprayStartProductionAndroidTest.kt` changed in application/test paths from starting HEAD `7a6fa9b855b384738fc0c1285ffc9aec9e1897ba`. Existing report/approved plan updated separately. Preexisting managed history and skills-mount fingerprint retained. No production recovery, startup, costing, version/signing/dependency or entitlement-routing change.

Confirmed intended behavior from the existing16 October accepted bounded Start closeout below, section A, and `AppViewModel.submitPreparedLegacySprayAwaited`: exact verified immutable Start receipt permits original frozen pair fallback on metadata hydration failure. It does not permit arbitrary history adoption, unknown acceptance, cancellation or unauthorized fallback. The old test's reload-pending assertion was obsolete.

Renamed the test to `acceptedButReloadFailedStartsVerifiedOriginalWithoutAnotherCreate`. It now requires the injected reload failure actually to occur; successful original Start; accepted candidate/verified receipt equality and validation; original operation/Trip/actor/vineyard; original engine hours; one durable original local-first activation marker; unchanged active disk/journal/marker on return through saved-Trip entry; no duplicate create/recovery/activation send; required Tank1 review and no tracking bypass. Working recovery logic unchanged.

### B. Shared enforcement and native gaps

Receipt recovery and operational writes remain separate. This pass corrected a contract expectation, not the enforcement architecture. The previous bounded guards remain in place; the UI is not being used as the security boundary.

Known native gaps remain: full Growth original-owner/account-incarnation replay; independent scouting/Insights/planning/maintenance journals; other direct attachment transports; fertigation/resistance retry callers; suspended active Spray/occurrence/GPS acknowledgements; SDK/HTTP refresh-retry execution; completed-history all-exposed-mutation zero-write; full restart/offline/account/vineyard permutations. Reinspection confirms iOS `MaintenancePhotoStorageService.uploadPhoto/deletePhoto` and Android `MaintenancePhotoRepository.upload/delete` still directly call storage without the vineyard write-admission boundary. That is a concrete source gap for case13, not an authenticated exploit reproduction or a passing case. Do not enable historical entry merely because the narrow regression selection is now green.

### C. Journals, identity and receipt evidence

The corrected test checks the existing verified original pair, not a recreated replacement. Candidate and verified receipt validate the frozen operation, Trip, record and vineyard; returning to the owned Trip preserves the complete stored attempt and active snapshot and the same activation queue row. The request/receipt fixture is synthetic and intercepted; PostgreSQL fingerprint validity, actual deployed atomicity and exact-once server behavior are not thereby proven.

### D. Backend discovery and missing access

`backendStatus` reports only production ref `tbafuqwruefgkbyxrxyb`, native Supabase Auth/RLS, no preview and no deployed Edge Functions. No isolated test URL/accounts/fixture controls were configured in the sandbox; existing scripts contain no authenticated acceptance fixture. **No authenticated request, signup, broad record enumeration, server-data read/write, schema migration or deployment was made.** Production metadata discovery is not owner-data acceptance.

Required next input through secure server-only configuration: test backend URL and anon key; two ordinary synthetic test-account credentials; explicit allowlisted test vineyard A/B and seeded block/completed Spray/Trip/Tank/planned/active record IDs; deployed capability/receipt contract; approved test-only mechanism to move A writable→expired→writable and capture authoritative readback. Do not put a service-role credential into either native client, invent a control endpoint or silently modify production subscriptions.

### E. iOS automated tests and separate build

Fresh requested18-suite selection: **284 passed in106s**, tool success, no reported failures. Selection: DeviceTripOwnershipTests, VineyardWriteAuthorityTests, ReadOnlyEntitlementContractTests, SpraySaveForLaterTests, EntitlementDecisionTests, EntitlementAccessRegressionTests, OfflineQuickActionsTests, ResistancePlanRepositoryTests, ResistancePlanRevisionSyncTests, FertigationMobileWorkflowTests, FertigationDomainTests, TripOccurrenceJournalTests, StartTankCommitCoordinatorTests, PinPhotoWorkflowTests, VineyardMutationAdmissionTests, LinkedPinGrowthDeletionWorkflowTests, MobileRequestSyncSafeguardTests, GrowthStageVarietyParityTests. Aggregate count is not a per-method/discovery/skipped XML manifest or a historical-screen UI journey.

Separate current **`runChecks(ios)` PASS**, simulator build only; physical-device/Release acceptance not established. No post-entry/UX result is claimed because those paths remain disabled.

### F. Android host, instrumentation and separate build

- Fresh host focused11 suites **209/209,27.516s**, separate existing six-suite regressions **55/55,12.051s**, both exit0 and zero failures/errors/skips. Artifacts `/tmp/vinetrack-read-only-contract-7gbss8d_/{contract,existing-regressions}/result.json`, XML and `finished.json`. Runner unchanged; no concurrent normal build during host execution.
- First revised instrumentation selection **8 passed/1 failed/0 skipped,4.020s**: original Start and receipt assertions passed, but new test incorrectly tried a fresh calculator Start after the original Start was already complete/owned. The accepted creation admission correctly refused. Fixture changed to return via the existing saved-Trip entry, as its existing valid-hours regression does; no production change.
- Next selection **8/1/0,4.005s**: it incorrectly required one immediate HTTP activation. Existing architecture activates locally and durably enqueues a marker, with replay separately admitted. Corrected test asserts one exact original activation marker and no additional send/marker on saved-Trip return, rather than forcing replay or changing production startup/session/replay admission.
- Final affected selection: **9 passed/0 failed/0 skipped in15s**, authoritative successful `androidTest` tool result. Three `PinPhotoAdmissionAndroidTest` methods; `RetainedStartupConstructionTest#expiredTankPreviewAndCommandsKeepOriginalDiskDraftAndReconciliationMarker`; `SprayStartProductionAndroidTest` methods `expiredCalculatorStartDoesNotPrepareOrSendReplacementWork`, `receiptReadOnlyRestoresUnclaimedOriginalAndStillAllowsRecoveryRead`, `blankHoursActivateOriginalAndKeepFirstTankGpsSafetyGate`, `acceptedButReloadFailedStartsVerifiedOriginalWithoutAnotherCreate`, `lostResponseUsesRecoveryOnlyAndKeepsOriginalOperation`. Synthetic HTTP/disposable preferences, not live backend or physical GPS. The local `/tmp/rork-android-test-android-vinetrack.log` still contains the preceding failed run; do not mislabel that retained log as the final pass artifact.
- Separate current **`runChecks(android-vinetrack)` PASS**. Existing nonblocking legacy asset-address advisories unchanged. Five unrelated historical completion failures were not repaired or included in this selected host gate; not a whole-project green claim.

### G. Exact23-case acceptance ledger

**23/23 NOT ACHIEVED. None is signed off as complete both-platform operational/authenticated acceptance in this run.** The exact supplied cases are retained below. PARTIAL means bounded native automated evidence exists, not operational PASS. NOT RUN means no authorised isolated execution yet. SOURCE GAP means known unclosed enforcement, not a fabricated runtime failure.

1. **Expired user can authenticate successfully. — NOT RUN:** no genuine expired test-account credentials.
2. **Expired user can enter the app once historical access is intentionally enabled for acceptance. — NOT RUN:** entry not enabled while enforcement remains incomplete; isolated test-candidate entry journey pending.
3. **Expired user can view vineyard/block/history data. — NOT RUN:** no scoped authenticated fixture or expired historical UI journey.
4. **Expired user can open a completed Spray record. — NOT RUN:** no scoped completed Spray fixture/entry journey.
5. **Expired user can open a completed Trip. — NOT RUN:** no scoped completed Trip fixture/entry journey.
6. **Expired user can inspect historical Tank data. — NOT RUN:** no scoped completed Tank fixture/entry journey.
7. **Expired user cannot create a new Spray. — PARTIAL:** held Android Calculator Start sends zero paired-save/activation/recovery and creates no journal; iOS held Save-for-Later/service guards covered. All creation routes/both native apps authenticated acceptance pending.
8. **Expired user cannot start an existing planned Spray. — PARTIAL:** admission/occurrence suites exist; all planned legacy/qualified routes and actual backend zero-write acceptance pending.
9. **Expired user cannot modify an active Trip. — PARTIAL:** held active-command and authoritative Trip tests green; every exposed active transition and suspended acknowledgement pending.
10. **Expired user cannot change Tank/fill actuals. — PARTIAL:** held Tank actual-ViewModel and Start Tank suites green; full exposed actuals and server-state proof pending.
11. **Expired user cannot create or alter GPS evidence. — PARTIAL:** held active GPS/service guards green; full local evidence/transport/restart acceptance pending.
12. **Expired user cannot create or alter Pin/Growth records. — PARTIAL:** direct ownership/transport tests green; Growth author/incarnation replay and every exposed route pending.
13. **Expired user cannot upload or delete photos/attachments. — SOURCE GAP:** Pin/Growth held transport tests green; unguarded maintenance storage paths still exist on both platforms; other attachment families and actual SDK rejection representation pending.
14. **Expired user cannot create or modify Fertigation records. — PARTIAL:** scoped service/role/replay suites green; all independent callers and authenticated before/after proof pending.
15. **Expired user cannot create or modify resistance/scouting or other independent journal records. — PARTIAL/OPEN INVENTORY:** resistance selection green; full independent journal/local-claim/transport inventory incomplete.
16. **Any attempted write while read-only produces zero server mutation and does not consume retry attempts. — PARTIAL:** selected synthetic zero-send and attempt-retention tests green; no exhaustive native route exercise or authenticated database snapshots.
17. **Work created while writable and queued before expiry remains locally intact after expiry. — PARTIAL:** selected outbox/photo/journal retention fixtures green; all original work families not yet accepted.
18. **App restart while expired preserves held work with original IDs, timestamps, ownership, journal/receipt metadata and attachments. — PARTIAL:** selected disk/service/authority recreation fixtures green; full main-app process-restart matrix not executed.
19. **Offline restart while expired does not replay held work. — PARTIAL:** isolated offline/replay admission fixtures green; both-platform full process/offline transport evidence pending.
20. **Fresh read-only authority after reconnect keeps the original work held. — PARTIAL:** capability/hold tests green; genuine reconnect against the deployed server contract pending.
21. **Fresh writable authority for the same account and vineyard releases the exact original held work once, without duplicates. — PARTIAL:** scoped synthetic replay/receipt tests green; real before/after row counts and immutable receipt lineage pending.
22. **Writable Vineyard B must not release work held for read-only Vineyard A, and account switching must not release another account’s held work. — PARTIAL:** selected A/B and stale-account native tests green; comprehensive native queue families and backend RLS/cross-account boundary pending.
23. **Sign-out/sign-in, stale cache, stale entitlement responses and delayed backend responses must not restore write access without a fresh explicit writable result for the owning account/vineyard. — PARTIAL:** same-account incarnation, stale errors and cached-capability fixtures green; full delayed entitlement/SDK retry/main-app transition matrix and genuine backend responses pending.

### H. Authenticated backend, restart/offline, isolation and zero-write results

- **Authenticated backend: NOT RUN/BLOCKED on actual isolated test access and control contract.** Historical reads, denied-mutation before/after equality, exact-once reactivation, journal/receipt lineage and backend account/vineyard isolation are not proven. No deployed contract was inferred from native mocks.
- **Restart/offline: PARTIAL native selection only.** No full both-platform process death/offline reconnect acceptance; no retained-owner-handset operation.
- **Account/vineyard isolation: PARTIAL synthetic/native tests.** Not genuine backend RLS/membership revocation acceptance.
- **Zero-write evidence: bounded only.** Known-held Calculator Start leaves native journal preference map/draft/ActiveTrip unchanged with zero mock save/activation/recovery sends. Pin/Growth held upload/delete and actual-row ownership tests intercept no prohibited mock mutation; held Tank commands preserve disk/marker/draft. These do not cover maintenance/all transports or prove actual server row equality. Zero authenticated requests made in this pass is a safety record, NOT proof the backend denies writes.
- Required backend evidence remains: authenticated permitted scoped reads; each prohibited mutation against seeded isolated records with row/object/receipt snapshot equality; held-native transport counter zero and retries unchanged; original replay once after explicit owning-scope writable verification; exact original IDs/payload/receipt chain and no duplicates; cross-account/vineyard denial without changing A.

### I. Source identity and validation boundary

Starting HEAD **`7a6fa9b855b384738fc0c1285ffc9aec9e1897ba`**, plus one test-file delta. Sorted UTF-8 `SHA256(file bytes) + two spaces + project-relative path + newline` manifest SHA256 **`3d0427151bf17bce0fd0f5e774c791bd7ffa5fb691347bfb4580f5e94d241999`**:

```text
b0c414c6651d6e74a40a46ad99368c7b271c73c3a9bc3bcb0ed45af86f7d6194  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/SprayStartProductionAndroidTest.kt
```

Report/approved plan and preexisting managed state excluded. Production iOS/Android source unchanged relative to this starting HEAD. Prior14-file manifest remains historical in the checkpoint below. Final manifest-byte and whitespace verification recorded before handoff. Starting HEAD is not a final managed-save revision or signed device artifact binding.

### J. Entry/UX gate and physical-only verification

**NOT READY FOR PHYSICAL DEVICE TESTING.** Do not issue READY based on the green narrow selection. Remaining native and isolated authenticated gates above must close first. The intended isolated acceptance entry path for cases2–6 must be deliberately enabled only after shared enforcement is complete; no global early release. Final entry/UX must be followed by fresh relevant automated tests and both builds. No post-UX validation is claimed in this run.

Required eventual copy remains: “Your trial has ended. VineTrack is currently read-only. Purchase a subscription to make changes.” Primary **View plans / Purchase**; secondary **Cancel / Keep viewing**; existing billing/restore, no background prompt stacking and no UI-only boundary.

After software/backend gates pass, exact physical verification still required on both iPhone and Android:
- Source-bound candidate identity/signing and compatible retained-data in-place installation; stable true cold launch/live process and retained originals without uninstall/cache clear/reset.
- Real expired authentication and historical vineyard/block/completed Spray/Trip/Tank screen navigation; no render/open/cancel side effects.
- Foreground/background/OS process termination and real flight-mode restart/reconnect with held work/evidence intact; no automatic replay or retry consumption during expiry.
- Live Trip/Spray entitlement change with actual location permissions/provider, GPS capture state and delayed responses; no unintended completion, tank/fill correction or discarded evidence. Tank1 Actual review must still precede recording.
- Actual camera/photo attachment handling and byte/revision retention through interruption; receipt/reference resumes without duplicate upload once authorised.
- Read-only notice and deliberate-change prompt readability/accessibility, dismissal/keep-viewing, no background stacking; sandbox purchase/restore/cancel and fresh authority restoration through existing billing.
- Owning-vineyard exact-once resumption, vineyard/account switches and sign-out/return with real network delay/reauthentication. Backend row/object counts must corroborate device observations.

No physical verification is represented by these automated counts. No store upload or production release.

## Expired-trial enforcement — independent transports and Spray checkpoint, 24 October 2026

**PARTIAL; ACCEPTANCE NOT GREEN. Historical entry and notice/purchase UX remain closed.** Both current normal builds PASS. Latest Android instrumentation selection is **8 passed /1 failed /0 skipped**; the existing reload-pending expectation remains unresolved. Native completeness, original23-case acceptance, isolated authenticated backend acceptance and physical readiness are not established.

### A. Changed files

Fourteen application/test files relative to observed base `9717a1108a2039dcef471ad20134dfbcc5ab32aa`, listed byte-for-byte in I. Report and approved plan are updated separately. No startup architecture, costing, dependency, version, signing, server or owner-data changes.

- Android `PinPhotoRepository`: canonical original Pin/Growth object path owns upload/delete admission; reject unresolved paths; capture account incarnation and authority registry, attach per-request account/write attributes; preserve successful upload receipts.
- Android `VineyardRowMutation`, `PinRepository`, `GrowthStageRecordRepository`: authenticated exact-one actual row ownership for independent ID-only mutations; duplicates, missing/mismatched IDs and wrong expected vineyard block. Explicit create owner/scope checked before IDs and after linked reads. Do not borrow selected B for held A.
- iOS `VineyardWriteAuthority`, `VineyardMutationAdmission`, `SupabaseFertigationRepository`: runtime account generation distinguishes sign-out/return to the same UUID from uninterrupted refresh; recheck after existing ownership/role suspensions. Durable ledger and operational encoding unchanged.
- Android `AppViewModel`, `LegacySpraySaveStore`, `LegacySprayPairReceipt`: admit new Spray work before IDs/journals/claims, inactive Trip activation and independent paired-save RPC. Validate frozen Trip/record owner and vineyard; opt into refresh/retry request admission. Known-held new saves stop, typed rejection restores the original unclaimed receipt journal; already-claimed receipt recovery remains a read. This is not all active Spray/occurrence acceptance.
- Tests: new `PinPhotoAdmissionAndroidTest`; expanded `SprayStartProductionAndroidTest`, `VineyardMutationAdmissionTests` and `FertigationDomainTests`.

### B. Admission and owning scope

Independent Pin/Growth database writes resolve actual authenticated ownership, not current selection; storage scope comes from strict canonical original keys. Originating account incarnation and registered authority must remain current. The new paired-save boundary validates matching frozen owner/vineyard on both records and classifies structured read-only before ordinary auth/permission mapping. Normal reads, receipt recovery, legacy missing capabilities and paid-vineyard behavior are not deliberately restricted.

### C. Retained journals, receipts and replay

No hold-induced payload/ID/date/attachment recreation or retry consumption is intended in these bounded changes. Known-held Calculator Start leaves the original draft and native journal storage unchanged and sends zero save/activation/recovery calls. Structured paired-save rejection restores its original unclaimed attempt; a direct held save stops before transport while read-only recovery can inspect the same request. Genuine successful object uploads return the original receipt despite in-flight expiry; subsequent independent changes are admitted separately. Post-success cross-account receipt durability and all independent replay/unknown-outcome paths still need exhaustive acceptance.

### D. Isolation and structured errors

A stale account/authority cannot assign another account's hold in the guarded transports. Same-UUID return no longer resumes an iOS admission suspended before sign-out. Ordinary permission/auth/network failures do not imply trial expiry. Actual iOS Storage error representation and SDK refresh/retry interception remain unresolved; Android mock transport bypasses the production HTTP interceptor and therefore does not prove its refresh/retry execution.

### E. iOS tests and separate build

- Explicit authorised unchanged18-suite rerun: **282 passed in110s**, no startup changes; historical hosted-app zero-execution failure is not the current blocker.
- Genuine failing-before same-account reincarnation regression: **0 passed /1 failed**, previous session resumed a suspended write. Added generation fencing and a separate fertigation role-lookup regression.
- Same expanded18-suite selection after those changes: **284 passed in125s**. It covers DeviceTripOwnership, VineyardWriteAuthority, ReadOnlyEntitlementContract, SpraySaveForLater, EntitlementDecision, EntitlementAccessRegression, OfflineQuickActions, ResistancePlanRepository, ResistancePlanRevisionSync, FertigationMobileWorkflow, FertigationDomain, TripOccurrenceJournal, StartTankCommitCoordinator, PinPhotoWorkflow, VineyardMutationAdmission, LinkedPinGrowthDeletionWorkflow, MobileRequestSyncSafeguard and GrowthStageVarietyParity. Aggregate tool count is not a per-method/skipped XML manifest.
- Separate current **`runChecks(ios)` PASS**, simulator only. No later iOS application/test changes after the284 selection; Android Spray changes do not inherit iOS test coverage. Device Release and handset acceptance unverified.

### F. Android tests and separate build

- Genuine held storage failing-before: **0/1**, held mutation escaped admission. Two storage checks then **2/0/0 in7s**.
- Initial ID-only fixture ended on post-send `BackendError.Server(200)` from an empty response; corrected it to distinguish post-send failure from safe admission. Genuine failing-before then **0/1**, one request escaped actual ownership admission. After production fixes, all three photo/ownership methods plus held Tank instrumentation **4/0/0 in10s**.
- Before Spray edits, host focused selection **209/209 in29.542s**, regressions **55/55 in13.274s**, zero failures/errors/skips; artifacts `/tmp/vinetrack-read-only-contract-zlk6vixu/`. These results alone do not validate later Spray edits.
- New Spray hold test first hit a fixture NPE because `storedAttempts()` assumes the key exists. Raw preference snapshot fixed that pre-operation issue. Genuine failing-before **0/1**: known-held Start persisted and completed a new attempt. Production guards now stop that path.
- First expanded eight-case run: **6 passed /2 failed /0 skipped**,3.427s: activation and reload fixture failures. Fixture previously installed synthetic credentials before signed-out startup completed, allowing its startup to revoke them. Fixture-only fix waits for SignedOut and persists selected vineyard; production startup unchanged. Next run **7/1/0**,3.410s. Scoped the injected reload failure to a created Trip, not unrelated empty startup reads.
- Latest nine-case selection: **8 passed /1 failed /0 skipped,4.137s**. Passing: three `PinPhotoAdmissionAndroidTest` methods; retained Tank ViewModel method; held Calculator Start; structured receipt rejection/unclaimed restoration/direct held save/read recovery; blank-hours original activation/GPS safety; lost-response recovery with original operation. Failure: `SprayStartProductionAndroidTest#acceptedButReloadFailedRetriesOriginalWithoutAnotherCreate`, assertion expecting `first.isStarted == false`. Current production code already permits verified original Start receipt fallback after row hydration fails (`submitPreparedLegacySprayAwaited`); no fallback change is part of this delta. This is an unresolved test/behavior mismatch, **not** a passing reload gate or proven failing-before attribution. Assertion remains unchanged; no automatic unchanged rerun.
- Newest host launch `/tmp/vinetrack-read-only-contract-8s9ek3_o/` terminated with **exit143**,5.515s, **zero tests/suites**; no `finished.json` and regressions did not execute. Normal build ran concurrently; causal attribution is unproven. A fresh serialized host attempt is recorded below after both builds finished.
- Serialized current host result after both builds finished: focused11 suites **209/209 in29.293s**, separate existing six-suite regressions **55/55 in13.673s**, zero failures/errors/skips, both exit0. Artifacts `/tmp/vinetrack-read-only-contract-mgljcr6t/{contract,existing-regressions}/result.json`, suite XML and `finished.json`. This closes this host selection only, not the failed instrumentation or full operational gate.
- Separate current **`runChecks(android-vinetrack)` PASS**. Existing asset URL advisories are nonblocking and unchanged. Build success does not override the failed instrumentation gate.

### G. Restart/offline and zero-write scope

Storage authority reconstruction and the synthetic held actual-ViewModel controls are bounded assertions, not process death, all historical exposed mutations, physical GPS or retained-owner installation acceptance. Known-held Start leaves raw journal preferences, recipe and ActiveTrip disk untouched. Receipt recovery is explicitly allowed during a hold. Full account/vineyard/restart/offline permutations and genuine completed-history all-exposed-mutation zero-write acceptance remain unfinished.

### H. Remaining native and original23-case gate

Still incomplete: Growth original-author/account-incarnation replay, orphan cleanup and unknown-outcome claims; maintenance/scouting/Insights storage and independent journals; other Android attachment transports; resistance/fertigation retry callers; suspended active Spray/occurrence/GPS completion and acknowledgement paths; every direct refresh/retry; historical Trip/Spray all-exposed-mutation zero-write and complete restart/isolation acceptance. The attempted subagent residual audit returned token-limit incomplete with **no findings**, not a completed audit.

The original enumerated23-case matrix remains absent from prior recursive searches; do not invent a substitute or count helper cases as operational acceptance. Need the original checklist. Native work remains independently unfinished even when that checklist and backend scope arrive.

### I. Exact source identity

Base **`9717a1108a2039dcef471ad20134dfbcc5ab32aa`** plus the following sorted UTF-8 `SHA256(file bytes) + two spaces + path + newline` manifest. Fourteen files; manifest SHA256 **`eb113df33baa0edfbf3855d34aa2ca6aa88b9501cefd9feb8f1f556331cb3f81`**. Report/plan and two preexisting managed-history changes excluded. Earlier manifests remain historical. `git diff HEAD --check` passed before and after the report/plan update; embedded manifest was recomputed from current bytes and verified. Starting HEAD is not a final managed-save SHA.

```text
e890dfea7ce368a40aa89d0335a6d9f15b56a27cb8f4f04f4f4c2bb99414564c  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/PinPhotoAdmissionAndroidTest.kt
35357f1f32726cc2f40d69efa786d9d2315dbaacd742d458c9d1b483c27ce4e0  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/SprayStartProductionAndroidTest.kt
d8fe77522d8fc91ae4a0132f800eefc59cddd394673d5f0db244077c4aa869c4  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/GrowthStageRecordRepository.kt
f491b06189ae996b3810ed49b01afce6c941bef6aa53602accac6d76e212b0b3  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/LegacySprayPairReceipt.kt
887b2f986f90cef43575af7902373809a8bb06d98e342bb778723728108e5ae9  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/LegacySpraySaveStore.kt
e5944a8b8b71e0a661e2232e1718d5d98c2dde77f6a5a6bcc2e810dc79060491  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PinPhotoRepository.kt
b38398a2ada82dfd420b5f9c1646ac92c536d62de2b4e86ae6c1327fd9828f7b  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PinRepository.kt
1d74136879ac125dcc1334702010a8fd28029269f367b9a60e9e53a34ac15798  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/VineyardRowMutation.kt
abaade3f0752edb1ea325ce74463306929f7ae8f8bf7cb70067eabcda6e9f623  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt
7987e47d3df828c4119e272888f081b9c5d689d69087d597a78549696eb85d1a  ios/VineTrack/Backend/Repositories/SupabaseFertigationRepository.swift
e40a10a4bf0a11ee4b97869a12baf43425151d2b68fe17ab4f16ea93744d5d86  ios/VineTrack/Backend/Subscription/VineyardMutationAdmission.swift
cb685fc1111ebb1342a9048b67a78c6df83bcbfbe806b88ff21da3093350fa91  ios/VineTrack/Backend/Subscription/VineyardWriteAuthority.swift
e74f75f9a048c1ed4300cdb3e68d94d46d92b5246fcf6203b5e31b58adc9705a  ios/VineTrackTests/FertigationDomainTests.swift
faf36455a0234c5f91e860723ff1a0f0525977c01e2602096dc0d8f96e9409d6  ios/VineTrackTests/VineyardMutationAdmissionTests.swift
```

### J. Backend, UX and physical limitations

No authorised isolated non-owner account/vineyard/credentials or delivered server contract is available. Production discovery is not permission to query or mutate owner data; no authenticated backend acceptance, deployment or migration performed. Need the explicit isolated scope and original23 cases. Historical entry, persistent notice and deliberate purchase prompt remain disabled until **all** native/backend/operational gates pass. No physical readiness, handset reset/install/logout, store export/upload, version or signing change claimed or performed.

## Expired-trial read-only access — independent attachment and tank admission checkpoint, 24 October 2026

**PARTIAL IMPLEMENTATION; HISTORICAL ENTRY REMAINS CLOSED.** Final iOS selection282 PASS; Android focused209 PASS, regressions55 PASS and one actual ViewModel instrumentation regression PASS. Both normal builds PASS, separately from tests. These are bounded source checks, not the full23-case gate, authenticated backend acceptance or physical-device readiness.

### A. Changed files

Thirteen application/test files relative to observed base `cdb0ac52461945846f6bec8ed6f3ec9b70ad929c`; exact paths/hashes are in I. Existing report/approved plan updated separately. No dependency, project-target, startup architecture, costing, version/build-number or server changes.

- iOS `VineyardMutationAdmission.swift`: new per-operation originating-account and actual-vineyard boundary shared by independent Pin/Growth database/storage sends. A restored SDK session cannot bypass the durable ledger before account binding.
- `SupabasePinSyncRepository.swift`, `SupabaseGrowthStageRecordSyncRepository.swift`: authenticated exact-one-row ID ownership for photo-reference/confirmation/delete; expected-vineyard validation for existing upsert IDs; explicit authenticated absent-row allowance only for create. Reject mixed-vineyard direct batches rather than misattribute a rejection. Every independent mutation is readmitted.
- `PinPhotoStorageService.swift`: guard Pin/Growth uploads and object deletion. Deletion scope comes from the canonical path, not optional selected-vineyard hints; downloads remain available.
- `PinSyncService.swift`: held independent photos/evidence/confirmations retain originals, successful uploads retain their receipt before separately admitting photo-path PATCH; capture owner/account/sequence fences; delete replay retains unknown/foreign owner work; initial empty-remote fallback does not reattribute foreign work or regenerate queued timestamps. New attachment/confirmation creation is admitted before queue/cache changes. New delete queue callbacks capture the current author in the existing owner sidecar.
- `PinCaptureEvidence.swift`: read-only owner/vineyard accessors on the existing immutable upload wrapper; encoding and payload unchanged.
- `GrowthStageRecordSyncService.swift`: admit local-only delete/photo/mirroring, known-held replay, independent attachment reference sends and linked-delete fallback; do not turn a known hold into deletion-permission rollback. Restore newly established unknown-outcome claim metadata on typed hold without replacing original queued dates. This is not complete Growth account-incarnation acceptance.
- Android `AppViewModel.kt`: held tank preview returns original without repairing disk, changing reconciliation markers or enqueueing; admit legacy Start Tank, tank drafts and End/Start Fill/Stop Fill controls before changes.
- Tests: `DeviceTripOwnershipTests.swift`, `PinPhotoWorkflowTests.swift`, `LinkedPinGrowthDeletionWorkflowTests.swift`, new `VineyardMutationAdmissionTests.swift`, Android `RetainedStartupConstructionTest.kt`.

### B. Admission and authoritative ownership

The accepted separate durable owner/vineyard authority is unchanged. The new iOS boundary requires an authenticated SDK account matching the bound ledger and captures that binding across suspensions. ID mutations read authenticated `id,vineyard_id` without `limit(1)` and reject missing/duplicate/mismatched rows; writable selection B never authorizes held actual A. Create can accept an absent row only with an explicit original vineyard and current write admission. Existing-ID upserts cannot silently move another vineyard's record. Scope ambiguity is a local unresolved restriction, not a newly inferred trial-expiry hold. No personal trial-date inference or capability-entry change.

### C. Originals, independent queues and receipts

Known-held Pin photos/evidence/confirmations are skipped without rewriting originals, consuming retry budgets or producing ordinary upload failures. A real successful object upload remains durably referenced by its original pending revision when expiry arrives in flight; the subsequent reference send stops, and fresh explicit same-owner/same-vineyard permission later uses that receipt rather than uploading again. Read/evidence hydration remains ungated. Existing operational payload formats, IDs, attachment revisions, evidence timestamps and receipts were not recreated. Pin/Growth direct mutations and storage deletion are guarded, but this checkpoint is not exhaustive attachment/remove/cleanup/manual-retry acceptance across both apps.

### D. Structured responses and account isolation

Exact structured `VT_READ_ONLY` establishes a hold only while the originating account binding is current; ordinary permission/network/auth failures do not imply expiry. A stale structured response cannot hold a subsequent account. Genuine successful sends are returned normally even when expiry arrives in flight. Helper fixtures cover these boundaries, but are not actual SDK refresh/retry HTTP interception or full session-incarnation acceptance. Pin service also captures sign-out sequence. Growth service account/author isolation and remaining independent journals still need completion.

### E. iOS tests and separate build

- Explicit unchanged13-suite rerun after the earlier zero-test hosted-app connection failure: **249 passed /1 failed**. The failure incorrectly demanded tracking be stopped even though `configure` had already resumed the writable active Trip before expiry. Fixture-only correction captures and compares original tracking/paused state and asserts pre-hold tracking was active; original disk/Trip/ownership/correction/distance assertions remain. No startup/production workaround. Corrected same13-suite selection: **250 passed in31s**.
- Two genuine failing-before Pin regressions: **0 passed /2 failed**; expired independent photo still uploaded, and expiry during successful upload still allowed subsequent photo-reference send. Production fixes above address both.
- First narrow after-fix selection: **15 passed /1 failed** because the fixture compared unsorted JSONEncoder output. Canonical sorted-key comparison preserves all payload equality coverage.
- Expanded18-suite selection: **279 passed /1 failed** because the new Growth fixture used subsecond source dates while existing disk decoding retains whole seconds. Fixed fixture precision, not persistence behavior or assertion coverage. Next selection **280 passed in72s**.
- Final frozen-source18-suite selection, after adding unbound-ledger and explicit-create-scope regressions: **282 passed in120s**, no reported failures. Same prior13 suites plus `PinPhotoWorkflowTests`, `VineyardMutationAdmissionTests`, `LinkedPinGrowthDeletionWorkflowTests`, `MobileRequestSyncSafeguardTests`, `GrowthStageVarietyParityTests`. Aggregate runner result is not a per-method/skipped XML manifest. Latest runner log `/tmp/rork-swift-test-ios.log` is overwritten by later runs.
- Separate final **`runChecks(ios)` PASS**, simulator build only; device Release unverified. Earlier hosted-app failure remains historical with cause unproven, not a current zero-execution blocker.

### F. Android tests and separate build

- Actual production ViewModel instrumentation: `com.rork.vinetrack.data.auth.RetainedStartupConstructionTest#expiredTankPreviewAndCommandsKeepOriginalDiskDraftAndReconciliationMarker` — **1 passed /0 failed /0 skipped,7s**. Uses the existing disposable namespaced fixture Application. Verifies original stale tank pointer, disk snapshot/saved time, draft contents and reconciliation marker remain unchanged after held preview/start/fill/end/draft actions and writable B verification. Not a network interception assertion, full Start/Spray journey or physical retained-install test; no failing-before Android execution claimed.
- Current11-suite focused host selection: **209/209,0 failures/errors/skips,29.077s,exit0**. Separate existing six-suite regressions: **55/55,0 failures/errors/skips,13.067s,exit0**. Artifacts `/tmp/vinetrack-read-only-contract-f7ekb68r/{contract,existing-regressions}/result.json`, suite XML and `finished.json`. Same bounded selection as prior checkpoint; not a replacement23-case matrix.
- Separate final **`runChecks(android-vinetrack)` PASS**. Test/build evidence is separate. No startup/costing/sync-architecture or version change. Existing asset-address advisories remain nonblocking and untouched.

### G. Restart/offline and expired zero-write scope

Pin regression reconstructs the service from isolated disk persistence with the original attachment held; canonical serialized attachment equality, revision, bytes, original upload receipt and no extra upload are asserted. Writable B does not release A; explicit fresh writable A resumes original once. Existing13-suite hold/restart/occurrence/fertigation assertions remain green. Android instrumentation verifies synchronous held tank commands against the actual ViewModel and disk, offline UI scope. This does **not** prove process death, retained-owner handset restart, all account/vineyard permutations, GPS hardware behavior, all completed-history exposed mutations or full expired zero-HTTP-write acceptance.

### H. Remaining native work and the existing23-case gate

Native enforcement remains independently incomplete: Android direct Pin storage upload/delete and other independent attachment/evidence/retry transports; Growth author/account-incarnation queues; scouting/Insights, maintenance attachments, resistance/fertigation direct/retry inventory; Spray activation/completion and occurrence publication after suspended acknowledgements; generic scope/replay fallbacks; historical Trip/Spray all-exposed-mutation zero-write regressions; full restart/isolation matrix and SDK refresh/retry fencing. Preserve genuine server acknowledgements during this work. Neither helper counts nor this checkpoint close those paths.

The authoritative enumerated23-case matrix was **not found** in recursive searches of `docs/`, `.rork/plans/`, `scripts/`, `tests/`, existing iOS test targets and Android unit/instrumentation tests. Existing plan line23 and this report's older contract section reference the count and categories, not the actual case list. The separate ten-case offline Quick Actions matrix is unrelated. Need the original23 numbered cases; no substitute checklist was invented or marked passed. Full physical-device behavior remains UNVERIFIED.

### I. Exact source checkpoint

Base HEAD **`cdb0ac52461945846f6bec8ed6f3ec9b70ad929c`** plus the following13-file delta is the tested source identity; not a new final managed-save SHA. Sorted UTF-8 `SHA256(file bytes) + two spaces + project-relative path + newline`, then hash all lines: **`09aec26f573cf9f434824679cd00cee60f1eb038fbe9f78b8df4c4e98211d6a0`**. Retained at `/tmp/vinetrack-read-only-contract-f7ekb68r/source-manifest.sha256`; complete lines embedded below so evidence is not dependent on ephemeral storage. Prior9/22/29-file manifests below remain historical and are not represented as current. Plan/report/managed history excluded. Application/test source unchanged after final respective checks; `git diff HEAD --check` PASS.

```text
bb5386f29770f2ab2b6c44e6e0b44eefbfa080cae3187e35e4cf0157a658b1cf  android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/auth/RetainedStartupConstructionTest.kt
d98a42506693a463a04a24e4054ac3c6a935dd94b347f70e5324c52463885876  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt
8b90b3482b41b659ea474a1e511e44539f96fcbdb1502ef98e5b8e50043ba877  ios/VineTrack/App/PinCaptureEvidence.swift
b3d4919b6c1809490aede126ad7f3248f14bf60469f735a31fc8103342ba7864  ios/VineTrack/Backend/Repositories/SupabaseGrowthStageRecordSyncRepository.swift
91659de59a6666080816c6739585baf3b72908c58aafe4f5cfa201af4f44e433  ios/VineTrack/Backend/Repositories/SupabasePinSyncRepository.swift
f991f438f8f395dbe13208667eda59584fce823e3a2d53f666bf820076b6e7df  ios/VineTrack/Backend/Storage/PinPhotoStorageService.swift
88229d0495c381557b900b7892ec9ceb18fa7b3c7595c9b81f5c9d0979b92457  ios/VineTrack/Backend/Subscription/VineyardMutationAdmission.swift
c0489e8a9497e11c5007b3aec199f930c3c1ab3e7579bbbc5aaf21f9c31e755c  ios/VineTrack/Backend/Sync/GrowthStageRecordSyncService.swift
1d4770793eb67a4d50c1367e0927c36011e6302196327fd04cb9972a1836fc83  ios/VineTrack/Backend/Sync/PinSyncService.swift
c7b5e74d15885bc4c9d84d7597fa6857a40f646d72942afc03771dfa01e9b924  ios/VineTrackTests/DeviceTripOwnershipTests.swift
73bc1245b1ef5ff7a6c0103dd5b83fe7d19a1f8734f1d30185698179be09d6fc  ios/VineTrackTests/LinkedPinGrowthDeletionWorkflowTests.swift
2ff954de2486df19e47f262ff102bf031f4bf3fe178b28b03fab2ea1d4b42ada  ios/VineTrackTests/PinPhotoWorkflowTests.swift
e261d3d7d1b38e421e4c5e3c90f4583c7a2a0e2bd42cd37560affb4849c53aab  ios/VineTrackTests/VineyardMutationAdmissionTests.swift
```

### J. Backend, intended entry and readiness

Backend discovery reported production only, Supabase ref `tbafuqwruefgkbyxrxyb`, native Supabase Auth/RLS, no preview/automatic rollback. **No authenticated acceptance, live data read/write, migration, deployment or owner-data operation performed.** Need an explicitly authorised isolated non-owner account/vineyard fixture scope and delivered server contract before verifying permitted reads, denied writes/unchanged rows, no duplicates, retained originals/exact-once resumption and receipt lineage, paid/manual/legacy access and `record_my_client_activity`. Credentials must use the secure configuration flow, not this report or chat.

Historical entry remains closed, not toggled for tests. Persistent notice/purchase UX remains unenabled until native completeness, original23-case matrix and isolated backend acceptance pass. Then and only then use explicit `can_enter_vineyard=true`, `can_write=false`, `read_only_reason="trial_expired"` and latest copy: **“Your trial has ended. VineTrack is currently read-only. Purchase a subscription to make changes.”** Primary **“View plans / Purchase”**, secondary **“Cancel / Keep viewing”**, through existing billing. No rollout/readiness declaration, release/upload, device reset/uninstall/cache clear/forced logout or owner queue deletion.

## Expired-trial read-only access — historical active command continuation, 24 October 2026

**PARTIAL IMPLEMENTATION; HISTORICAL ENTRY REMAINS CLOSED.** Both current normal builds pass. Android host checks pass; the current iOS test run executed no tests. The previous248/199/55 source checkpoint below is historical. Neither checkpoint is full operational or backend acceptance.

### A. Changed files

Nine application/test/runner files relative to observed starting HEAD `da4335f3fffbb7ca15e2b7ffc49005c57e0d4245`; existing plan/report updated separately:

- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TripWriteAdmission.kt` — current-account and actual owning-vineyard admission, exact-one-row resolution and structured rejection classification.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TripRepository.kt` — authenticated Trip ownership reads for ID-only PATCH/delete/occurrence mutation; guarded create/imported create/planned initiation; preserve structured403 response bodies. Read-only occurrence recovery stays available.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/SupabaseClient.kt` — opt-in request vineyard attribute rechecked with originating-account admission before execution, after refresh and before retry. Other reads/telemetry are not globally blocked.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt` — active Trip local command, route, occurrence and tank-persistence admission; known-held occurrence replay returns without conflict/retry rewriting; Restricted start/pause does not trigger generic offline fallback.
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/TripWriteAdmissionTest.kt` — ten helper/boundary fixtures for ownership, missing/ambiguous scope, suspended expiry/account change, structured versus ordinary rejection, stale response, successful acknowledgement and original-work resumption.
- `android-vinetrack/entitlement-tests.init.gradle`, `scripts/run-read-only-entitlement-contract.py` — include that existing-target host test; no dependency/build-target changes.
- `ios/VineTrack/LegacyImported/Services/TripTrackingService.swift` — admission before active controls, saved activation, route/corrections, occurrence actions, tank/fill commands and GPS mutation; held tank preview/restart does not reconcile. Active occurrence reads load without initializing a missing journal; service journal uses the store's authority.
- `ios/VineTrackTests/DeviceTripOwnershipTests.swift` — two new isolated service fixtures for held commands/disk/ownership/runtime preservation and durable-hold restart, stale tank pointer, other-vineyard non-release and explicit original-vineyard resumption. Compiled, NOT executed in this run. The fixtures use legacy active Trips; they are not all-occurrence-path or completed-history UI acceptance.

### B. Central admission and scope

The accepted durable owner/vineyard ledger is unchanged. Android ID-only Trip operations resolve an authenticated exact-one-row owning vineyard, then recheck the captured account and capability before sending. Occurrence creation derives scope from the original `p_trip.vineyard_id`; other mutating RPCs resolve `p_trip_id`; recovery remains a read. The per-request vineyard attribute extends existing HTTP refresh/retry account fencing for these guarded Trip writes only. This is not universal native transport coverage. Missing/ambiguous scope blocks without guessing the selection or creating replacement work. No personal trial-date inference or historical-entry change.

### C. Retention and queues

Known-held Android occurrence replay avoids business-conflict holds and retry/fallback recreation. Existing original-work and acknowledgement preservation stays intact. iOS live controls are guarded before runtime state or store/journal changes, and GPS fixes return silently while held. Tank preview/restart avoids stale-pointer reconciliation. Independent planning journals, replay/upload paths and attachments remain an open inventory; this checkpoint does not close their retention or replay acceptance.

### D. Rejection/account behavior

Android exact structured `VT_READ_ONLY` establishes a scoped hold only while the captured account is still current; ordinary403 does not imply entitlement expiry. A genuine in-flight success returns normally rather than being discarded if expiry arrives during transport. Helper tests exercise those boundaries, not the real SDK HTTP refresh interceptor or authenticated server. iOS uniform transport-level structured rejection/account-refresh fencing remains incomplete. No automatic billing prompt or background prompt stacking was introduced.

### E. iOS validation — INCOMPLETE

Requested the same13-suite selection as below, with the expanded `DeviceTripOwnershipTests` (two new methods). Test sources compiled, including `DeviceTripOwnershipTests.swift`, but the runner could not establish the test-bundle connection and reported a likely hosted-app startup crash without a crash log. **0 tests executed /0 passed /0 assertion failures; NOT PASS.** Full returned log: `/tmp/rork-swift-test-ios.log`; it contains no compiler error or actionable fatal stack. Runtime log query returned no logs. No startup workaround, reset, forced logout or unchanged automatic retry was performed. The cause is unverified and is not evidence of either a proven app regression or an infrastructure-only fault.

Separate current `runChecks(ios)` **PASS**, simulator build only; device Release unverified. The old248-test PASS below does not certify the current service changes.

### F. Android validation — PASS, bounded host scope

Unchanged Android source through `/tmp/vinetrack-read-only-contract-5mxvipi6/` execution:

- Focused11-suite selection: **209 executed /209 passed /0 failures /0 errors /0 skipped**,226.840s, exit0. Includes ten `TripWriteAdmissionTest` methods; prior ten suites retained.
- Separate six-suite existing-regression selection: **55 executed /55 passed /0 failures /0 errors /0 skipped**,13.093s, exit0. `RetainedStartupTest`, `SyncRecoveryStorageTest`, `SyncCrashIsolationTest`, `ActiveTripStoreTest`, `OfflineQuickActionsTest`, `TripEndGateTest`.
- Current normal `runChecks(android-vinetrack)` **PASS**. No code/dependency/version/signing or startup architecture changes after these checks. Old asset-address advisories remain nonblocking and untouched.

Results are in `contract/result.json`, `existing-regressions/result.json` and `finished.json` under that directory. This is host helper/domain regression evidence, not Android emulator/handset or all-active-command integration acceptance.

### G. Restart/offline and isolation

The new Android helper fixture recreates authority and an in-memory PendingWrite adapter with the retained original; missing/implicit writable, fresh read-only, writable B and another account do not release held A; fresh explicit same-account A permits original replay once. It is not a real disk-backed process-restart or history-screen fixture. Prior file-backed authority/journal/photo tests remain in the209 selection. The new iOS on-disk service restart and byte-equality fixtures compiled but did not execute. Full native restart, attachment/receipt/attempt equality and account/vineyard isolation permutations remain unaccepted.

### H. Remaining native and physical gaps

Continue active Trip/Spray callers before independent queues/evidence, then all ID-only ownership and real completed historical Trip/Spray exposed-mutation zero-write regressions. Remaining review includes Android tank previews/reconciliation before persistence admission, GPS/evidence replacement, labour/attachments and direct-write fallback callers; iOS occurrence replay rejection/account fencing, direct Trip transport refresh and activation/publication after suspended acknowledgements. Preserve genuine receipts while doing that work. The full23-case matrix is still open.

Physical-device checks are **UNVERIFIED**: retained-data iPhone/Android cold launch and offline restart; expiry during active GPS/Spray/Tank work; full evidence/receipt preservation; same-account/vineyard resume; all completed-history edit/cancel/delete paths; notice/purchase/restore flow; paid/manual/legacy behavior. No handset or owner-data mutation, reset/uninstall, release/export/upload, deployment or version change occurred.

### I. Source identity and frozen manifests

Observed starting HEAD: `da4335f3fffbb7ca15e2b7ffc49005c57e0d4245`. This is the base, not a final managed save revision. Current9-file manifest SHA-256: **`8e2eaa6c39bd7acd8826fc0be67cdf58a3c1f781f2c5a03f3964a7ac829b99e6`**, saved as `/tmp/vinetrack-read-only-contract-5mxvipi6/active-source-manifest.sha256`. Cumulative29-file continuation manifest (prior22 plus these9, two overlapping runner files): **`344ad343d76fbef3302b1e4cd5dca7df36e6f6ba4ebdac99daa0e4faed457ccb`**, saved as `continuation-source-manifest.sha256` there. Sorted UTF-8 `SHA256(bytes)`, two spaces, project-relative path and newline; SHA-256 over those complete lines. Plan/report and managed history are outside these source manifests. All previous22 files except the two intentionally extended runner files retain their exact prior hashes.

```text
39187134eb5968b6bcb7b0f3013ff6ed4b10a97a893997452382bc11d7e730b1  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/SupabaseClient.kt
436d168b07cdb89461af7867d442e0bea642d604b54a595d995ae78fdc9387a2  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TripRepository.kt
0f8479ea42fd9fe8951b44219411fcd2cc9f9ec5daef819c3c9fc84669267d9d  android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TripWriteAdmission.kt
7fe013b8b5fb8b4ee8f159f7d052c262fafb1dfb3c8902d8f7a7af93ffbde7fe  android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt
1833b08a4b0db902813a2837301e75e851834972c5d5e27fc39e2d551a452a9f  android-vinetrack/app/src/test/java/com/rork/vinetrack/data/TripWriteAdmissionTest.kt
8f0de3480b2308180aa37e28f9f4ebd003d30ff5beb4e6ff70990a8b716ead78  android-vinetrack/entitlement-tests.init.gradle
4c150e2f9ba5f27332f7066a901509fc5476278a397e224d654e97cd24ff343f  ios/VineTrack/LegacyImported/Services/TripTrackingService.swift
2061c8189fac0e2300a362b4f9064fe456b68b6d2d0cea2e138c157b7854a61d  ios/VineTrackTests/DeviceTripOwnershipTests.swift
9fd17020582e27190268f41065df3eb3caad4b517681bb0828976f1c510bec7f  scripts/run-read-only-entitlement-contract.py
```

`git diff HEAD --check` PASS at source freeze. Source was not changed after the current tests/builds. Tests/builds certify only their specific bounded scope and source; the iOS execution failure remains unresolved.

### J. Backend, entry and UX gates

No isolated authenticated non-owner backend scope/contract was supplied. Permitted reads, actual denied writes with unchanged rows, held originals, purchase/write restoration and paid/manual/legacy behavior remain unverified. Native completeness is independently unfinished; backend absence is not the only blocker. Historical entry remains disabled until all native23-case and isolated backend gates pass. Only then enable explicit `can_enter_vineyard=true`, `can_write=false`, `read_only_reason="trial_expired"` entry and the persistent notice/deliberate purchase UX. Latest copy: **“Your trial has ended. VineTrack is currently read-only. Purchase a subscription to make changes.”** Primary “View plans / Purchase”; secondary “Cancel / Keep viewing”, via existing billing. Existing entry routes are unchanged and no persistent banner/purchase sheet is claimed complete.

## Expired-trial read-only access — historical enforcement continuation, 24 October 2026

**PARTIAL IMPLEMENTATION; ENTRY REMAINS CLOSED.** This checkpoint extends the accepted enforcement below; it is not the full 23-case native gate or authenticated backend acceptance. No new planning cycle, account/device operation, distribution or server change occurred.

### A. Exact changed application/test/runner files in this continuation

22 files relative to observed starting HEAD `0d82f9fbf4342ed62e0daa25003f8daab5f32786` (existing plan/report updated separately):

- `ios/VineTrack/Backend/Repositories/SupabaseIrrigationRepository.swift` — authenticated exact-one-row owning-vineyard lookup for system/valve/session IDs; scoped mutation wrapper and structured rejection handling.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/IrrigationRepository.kt` — equivalent ID lookup, account/token recheck and actual-scope admission; always encode the existing clock-default pending-session timestamp.
- `ios/VineTrack/Backend/Repositories/SupabaseFertigationRepository.swift` — injectable authority; pre/post-role admission; reversal requires explicit vineyard and authenticated membership read; account-change cancellation before send/error classification.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/FertigationRepository.kt` — matching scoped reversal/role checks; preserve structured response through HTTP mapping and classify only after originating-account check.
- `ios/VineTrack/Backend/Subscription/VineyardWriteAuthority.swift` — read-only account binding for suspended-call fencing.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/VineyardWriteAuthority.kt` — matching account binding accessor.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PendingWriteRepository.kt` — retain pre-claim metadata through GPS evidence replacement; restore original status/error/update time while held; manual retry excludes held rows; stale account/version rejected before holding current account.
- `ios/VineTrack/Backend/Sync/TripOccurrenceJournal.swift` — injectable authority; pre-persistence creation/lifecycle/action admission.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TripOccurrenceJournal.kt` — matching pre-persistence creation/lifecycle/action admission.
- `ios/VineTrack/LegacyImported/Services/StartTankCommitCoordinator.swift` — admission before new journal and before recovery publication/marker/cleanup.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/StartTankCommitCoordinator.kt` — matching admission; held recovery returns without rewriting the frozen journal.
- `ios/VineTrack/Backend/Repositories/SupabaseTripSyncRepository.swift` — owning-vineyard lookup for ID-only Trip changes; admission for upsert and occurrence sends; structured occurrence RPC/PATCH rejection.
- `ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift` — resolve existing Trip/Pin/Spray ownership before scoped changes/deletes; verify on-disk Pin identity before retaining a notes draft.
- `ios/VineTrackTests/FertigationDomainTests.swift` — preserve canonical RPC/null assertions with verified reverse fixture; missing/mismatched scope, membership-read account switch, expiry during role check, held reads and stale-response regression coverage.
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/FertigationDomainTest.kt` — equivalent canonical fixture and focused regressions.
- `ios/VineTrackTests/TripOccurrenceJournalTests.swift` — held creation leaves no document; held action/finalization keeps exact file bytes; real receipt remains acknowledgeable and original state resumes after verification.
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/TripOccurrenceJournalTest.kt` — equivalent exact serialized-journal retention, receipt and resume tests.
- `ios/VineTrackTests/StartTankCommitCoordinatorTests.swift` — interrupted actual remains retained; held recovery publishes no Trip/marker and preserves journal; verified recovery resumes original tank.
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/StartTankCommitCoordinatorTest.kt` — equivalent journal/actual/marker-count/resume checks.
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/VineyardWriteAuthorityTest.kt` — exact original failed timestamp/error/attempts across hold/recreation/resume; stale account response cannot hold another account.
- `android-vinetrack/entitlement-tests.init.gradle` — include existing Fertigation domain, occurrence journal and Start Tank suites in focused host compilation; no target/dependency change.
- `scripts/run-read-only-entitlement-contract.py` — extend focused selectors with those suites; retain separate existing-regression stage.

### B. Authority and scope

The accepted separate durable owner/vineyard ledger is preserved. No personal trial-date inference or newer-server-field default change. ID-only irrigation/Trip operations now resolve actual ownership via authenticated reads, not selected vineyard. Fertigation reverse requires an explicit scope verified by the existing scoped list RPC; absent/unresolved/mismatched scope blocks without manufacturing an operation. That read may omit a raw vineyard field, but an explicit mismatched field is rejected. The role/membership suspension checks retain account identity; this is not a universal session-incarnation fence across every native transport. Auth/roles remain required independently.

### C. Queue and journal preservation

Both occurrence journals gate authored creation/lifecycle/actions before saving, while leaving valid successful-send acknowledgements and authoritative evidence recovery available. Start Tank initiation and recovery are held without discarding frozen journal/actual evidence or publishing completion. Android PendingWrite holds restore the original claimed row's status, prior error and update timestamp without consuming attempts; legitimately retained GPS evidence remains in its payload. Runtime claim metadata is not a new persisted queue format. Known-held failed rows are not manual-retry eligible. Exact GPS replacement/failed-commit/restart permutations and all independent queues are not exhaustively accepted.

An Android test exposed a real linked-envelope timestamp defect: serialization could omit `createdAtEpochMs` when its value equalled the freshly evaluated clock default, causing reload to generate a different timestamp. The existing field is now always encoded; the original whole-session equality assertion is unchanged. Already-missing historical timestamps cannot be reconstructed and no owner payload was rewritten.

### D. Server errors and account changes

Scoped irrigation/occurrence/fertigation boundaries recognize exact structured `VT_READ_ONLY`, not ordinary auth/network status. Fertigation error classification runs after the originating-account check, including ID-only reverse. Android stale PendingWrite responses return before establishing a current-account hold. Tests cover stale fertigation write rejection on both platforms and PendingWrite replay scope on Android; this does not certify account fencing of all direct transports. Generic rejection does not infer trial expiry. No background prompt or automatic purchase route was added.

### E. iOS validation

Final13-suite managed selection: the prior ten suites (`VineyardWriteAuthorityTests`, `ReadOnlyEntitlementContractTests`, `SpraySaveForLaterTests`, `EntitlementDecisionTests`, `EntitlementAccessRegressionTests`, `DeviceTripOwnershipTests`, `OfflineQuickActionsTests`, `ResistancePlanRepositoryTests`, `ResistancePlanRevisionSyncTests`, `FertigationMobileWorkflowTests`) plus `FertigationDomainTests`, `TripOccurrenceJournalTests`, `StartTankCommitCoordinatorTests`.

**248 passed in70s**, no reported failures; aggregate runner result, not a per-method discovery/skipped manifest. Earlier expanded selection passed247 in222s before the final stale-response regression. First normal build failed at three new `guard let` bindings on nonoptional Pin vineyard UUIDs; corrected those bindings, preserving actual-row scope checks. Final normal `runChecks(ios)` **PASS**, simulator build only; device Release is unverified. These tests do not exercise real authenticated ownership lookup against the server.

### F. Android validation

**Final frozen-source focused host selection PASS:10 suites/199 executed/199 passed/0 failures/0 errors/0 skipped,200.533s. Separate existing regressions PASS:55 executed/55 passed/0 failures/0 errors/0 skipped,13.314s.** Both stages exited0; results and suite XML manifests are retained at `/tmp/vinetrack-read-only-contract-yiyk5pdy/`. Final normal `runChecks(android-vinetrack)` **PASS**. These source/host results are not handset, authenticated transport or full operational acceptance.

Initial artifacts `/tmp/vinetrack-read-only-contract-7dq85oow/`:198 tests/197 passed/1 failed/0 errors/skips, exposing the retained irrigation timestamp mismatch. Intermediate `/tmp/vinetrack-read-only-contract-c_k32cfn/`:199 tests/198 passed/1 failed/0 errors/skips at the newly added stale-response cancellation assertion; production compilation overlapped the final correction, so this is not a frozen-source result. Both failures are retained; neither is a feature PASS. No completion/costing repair or version change.

### G. Offline/restart scope

Synthetic tests recreate held occurrence journals and retained PendingWrite repositories, compare original serialized journal bytes/rows, allow genuine receipts and resume after explicit verification. Both Start Tank tests retain already-durable actual evidence and original journal identity while held. This is not a retained-owner install/restart, offline historical-screen journey, handset GPS expiry transition, attachment acceptance or production-data check.

### H. Remaining native work

Overarching enforcement remains incomplete. In particular Android active Trip start/labour/device claims, metadata/add-block/end/route local-first commands and direct Trip transports still need pre-change/per-send admission. Existing journal guards alone do not settle caller handling, GPS evidence retention or occurrence replay error classification. Other gaps include independent planning/manual/labour/evidence journals; attachment/remove/cleanup/retry families; metadata deletes/orphan cleanup/multi-send closures; settings/Insights/chemical/growth/vintage paths; generic missing/multiple-scope queue payloads; malformed Swift hold-ledger recovery; full registry initialization and session-incarnation proof. New ID-only network lookup behavior is compiled but not separately transport-fixture/live accepted. No exhaustive inventory claim.

The persistent scoped notice and deliberate-mutation existing-billing prompt, silent safe-held status, all23 operational cases and opening/editing/cancelling without persistence are still unfinished. Native engineering remains independently outstanding; backend absence is not the sole blocker. Historical entry routes were not changed or enabled for testing.

### I. Source identity and preservation

Observed HEAD remains `0d82f9fbf4342ed62e0daa25003f8daab5f32786`. Current22-file application/test/runner manifest SHA-256 **`8a02d2f76ade157cab9e15af57a95b30139c6b13dbe99792d716d4145b1b1da4`**, using sorted project-relative paths and UTF-8 `SHA256(file bytes) + two spaces + path + newline` lines, then SHA-256 of all lines. Plan/report are outside that source manifest. Final managed-save SHA is not yet assigned; staging performed by the platform is not a new commit identity. Requested baseline/foundation content is preserved without reset; the earlier27-file manifest remains historical.

No app target/build/dependency/signing/version, SQL/Supabase/Portal, costing or Android startup/AppViewModel change in this continuation. Managed fingerprint/history pre-existing changes were not edited. No live row mutation, owner account operation, reset/uninstall/cache clear/logout, queue/draft deletion, store export or upload. Normal native build artifacts are not store delivery.

### J. Backend dependency and rollout

No authenticated isolated backend acceptance ran and no server/schema edit was made. Still require the delivered explicit vineyard contract and an authorised isolated non-owner scope for permitted reads, denied write with unchanged row, original held queue, prompt, purchase and fresh explicit-write restoration, plus paid/manual/legacy regressions and available `record_my_client_activity`. Enable expired-trial history only after all native and backend gates pass and only for explicit `can_enter_vineyard=true`, `can_write=false`, `read_only_reason="trial_expired"`. **Feature incomplete; entry CLOSED; no rollout authorisation.**

## Expired-trial read-only access — historical enforcement implementation checkpoint, 23 October 2026

**PARTIAL IMPLEMENTATION, NOT FEATURE ACCEPTANCE.** This supersedes the audit-only status below: native command admission, durable owner/vineyard holds and several independent replay/error paths are now implemented and tested. Coverage is not exhaustive. Expired-trial historical entry remains CLOSED, with existing routes unchanged. Neither the 23-case operational gate nor authenticated live acceptance is complete. Unfinished native engineering is separate from the server dependency.

### A. Exact changed application/test/runner files

27 files, relative to the project root (existing plan/report updated separately; pre-existing managed fingerprint/history changes preserved):

- `ios/VineTrack/Backend/Subscription/VineyardWriteAuthority.swift` — new scoped admission and durable sidecar hold authority.
- `ios/VineTrack/Backend/Subscription/EntitlementGate.swift` — bind matching owner/cache and process fresh raw matrix write capability.
- `ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift` — injectable authority; guards on main Pin/notes, Paddock, Trip, Spray, maintenance, Work Task/resource/material/pruning-labour and settings commands; Save for Later admission before journal creation.
- `ios/VineTrack/Backend/Sync/WorkTaskWriteCoordinator.swift` — admission before durable intent creation.
- `ios/VineTrack/Backend/Sync/OperationsSyncServices.swift` — Work Task completion admission before either row or completion metadata changes.
- `ios/VineTrack/Backend/Sync/SyncQueueDiagnostics.swift` — shared upsert replay admission, row scope preferred over selected slice, same-vineyard batching and structured read-only handling without per-item retry fan-out.
- `ios/VineTrack/Backend/Sync/FertigationLinkedOutbox.swift` — enqueue/manual retry/dependent-send admission, injectable authority and structured rejection holds.
- `ios/VineTrack/Backend/Repositories/SupabaseIrrigationRepository.swift` — scoped mutation/enqueue/replay guards and structured replay rejection.
- `ios/VineTrack/App/Resistance/ResistancePlanRepository.swift` — local command/send guards and read-only rejection handling; held sync skips adoption/push while retaining pull/reconciliation.
- `ios/VineTrackTests/VineyardWriteAuthorityTests.swift` — 18 new authority/store/shared-replay cases.
- `ios/VineTrackTests/FertigationMobileWorkflowTests.swift` — two parameterized real-file dependent hold/restart/restoration cases, retaining existing workflow tests.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/VineyardWriteAuthority.kt` — new authority, registry and exact structured server-code helper.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/auth/SessionStore.kt` — install authority with owner/cache callbacks and separate synchronously committed hold preferences.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt` — fresh matrix verification only; exactly five added lines. Startup, completion and costing logic untouched.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PendingWriteRepository.kt` — unique explicit-payload scope extraction, enqueue/claim/structured-rejection hold seams.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PendingPhotoRepository.kt` — admission before file/enqueue/claim/retry and conditional read-only claim release retaining upload receipt.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PinPhotoSync.kt` — admission before upload/reference sends; structured rejection bypasses failure budgets and retains file/receipt.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/WorkTaskWriteCoordinator.kt` — admission before intent creation.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/IrrigationRepository.kt` — explicit scoped mutation RPC/enqueue/replay admission and structured rejection.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/FertigationLinkedOutbox.kt` — phase/send/retry admission and typed/structured rejection holding.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/FertigationRepository.kt` — scoped upsert admission before/after suspended admin verification; structured rejection before HTTP permanent-error mapping; reads stay available.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/resistance/ResistancePlanRepository.kt` — local command/send guards; held sync still pulls; entitlement is not generic FAILED.
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/VineyardWriteAuthorityTest.kt` — 15 new authority/outbox cases.
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/PinPhotoWorkflowTest.kt` — two real-file hold/restart/resume/receipt cases.
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/FertigationMobileWorkflowTest.kt` — two dependent-phase hold/restart/restoration cases.
- `android-vinetrack/entitlement-tests.init.gradle` — focused existing/new test selection only, not app build configuration.
- `scripts/run-read-only-entitlement-contract.py` — expanded focused host selection and scope metadata.

### B. Central write authority

Both platforms use one cheap owner/vineyard authority, additional to—not replacing—auth/role checks. No action performs a capability network lookup. A separate sidecar ledger stores `READ_ONLY_TRIAL_EXPIRED` for confirmed trial restrictions and `VT_READ_ONLY` for generic structured server rejection. Keys normalize both account and vineyard. Cache absence, provider refresh and legacy writable defaults do not release known holds; logout/account switching does not erase them. Only fresh raw explicit `can_write=true` plus effective writable/enterable access releases the matching hold. Personal trial dates/status do not participate. Generic server rejection does not infer trial expiry or grant historical entry.

Main-store admission is not universal enforcement: selected-slice methods, public arrays/extensions and direct repositories still need complete caller/scope proof. Android registry relies on SessionStore installation; no new permission/auth bypass is intended. There is no blanket block on persistence, remote reconciliation, reads or telemetry. Shared prompt state is not yet observable/presented.

### C. Queues and hold preservation

- **iOS main Save for Later:** denied before a new recovery attempt or row publication; existing recovery journals remain available for evidence reconciliation. Do not blanket-block their hydration/receipt processing. All later recovery transport paths are not yet closed.
- **iOS shared upsert helper:** known-held payloads are not sent, acknowledged or classified failed. Explicit row scope wins over a different selected sync vineyard; writable records in a mixed-vineyard set can proceed independently. Exact read-only batch rejection does not trigger singleton fan-out. Helper result does not clear retained queue entries for held IDs. Separate deletes, orphan cleanup before the helper and multi-send closures remain gaps.
- **Both Work Task initiation coordinators:** admission precedes new intent creation; original successful-send receipt acknowledgement semantics remain unchanged.
- **Both linked fertigation outboxes:** checks before initiation/retry and each dependent phase's new send. If irrigation is already acknowledged, retain that receipt and pause only the remaining fertigation phase. Read-only denial does not become a permanent phase/error. Tests restore the original application/session IDs rather than recreating irrigation.
- **Both irrigation queues:** scoped enqueue and replay checks are present; retained sessions skip send. Direct ID-only system/valve/session update and reversal still need verified record scope.
- **Both resistance repositories:** local mutation guards, pre-send checks and typed rejection handling added. Held sync skips adoption/push but can pull with existing pending-row protection. Full conflict/adoption/direct-caller acceptance is not yet established.
- **Android shared PendingWrite:** uniquely scoped explicit payloads are held before claim; structured rejection retains ID/payload/createdAt/attempt budget and returns the claim to PENDING. The existing pre-send claim timestamp is NOT restored by this path; exact pre-claim timestamp preservation is still open. Missing/multiple scope and ID-only operations are not universally covered.
- **Android photos:** known hold skips file examination/deletion/claim; per-send checks cover object and linked reference writes. Server restriction releases only the matching claim to its original status/error/update time, without consuming retries; any successful upload path is retained as a receipt. Tests prove no repeated object upload on restored reference replay. Manual status/reset APIs and independent capture-evidence/chemical-photo families remain unverified.

All other independent queue families in the historical inventory below remain open unless explicitly described here. A vineyard sidecar hold is not an assertion that every operation family consults it.

### D. Server-error path

Exact structured `PostgrestError.code` / JSON `code` equal to `VT_READ_ONLY` is recognized in the listed shared/independent seams. HTTP 401/403 by itself is not entitlement. Generic server rejection preserves an already confirmed specific trial reason, but does not invent it. Android Fertigation now checks the code before ordinary permanent HTTP mapping. Android photo object/reference rejection retains evidence and the uploaded path without ordinary retry consumption. Resistance rejection does not mark the repository generic FAILED. No automatic access-refresh/purchase-prompt integration has been completed, and no universal direct-transport classifier is claimed.

### E. iOS tests and build

Final ten-suite selection: `VineyardWriteAuthorityTests`, `ReadOnlyEntitlementContractTests`, `SpraySaveForLaterTests`, `EntitlementDecisionTests`, `EntitlementAccessRegressionTests`, `DeviceTripOwnershipTests`, `OfflineQuickActionsTests`, `ResistancePlanRepositoryTests`, `ResistancePlanRevisionSyncTests`, `FertigationMobileWorkflowTests`.

Final managed result: **191 passed in 138s**, no reported failures. The runner provides aggregate results, not a per-method discovery manifest or skipped count. This includes the two new real-file fertigation scenarios and expanded shared-replay authority cases; it is not the full operational acceptance matrix. Final normal `runChecks(ios)` **PASS**, simulator build only; device Release build not verified.

Earlier implementation run: 118 passed/1 failed because the synthetic Save for Later journal fixture directory did not exist (`NSCocoaErrorDomain Code=4`). Added directory creation in that fixture; the same seven-suite selection then passed119 in177s. Expanded selection subsequently passed189 in142s before the last two fertigation cases; final191 supersedes it. No assertions were weakened.

### F. Android tests and build

Host runner: `python3 scripts/run-read-only-entitlement-contract.py --launch`; final logs/XML/finished summary at `/tmp/vinetrack-read-only-contract-40anc9fj/`.

**134 focused tests passed, zero failures/errors/skips**, seven suites: Fertigation15, PinPhoto23, read-only contract16, resistance repository35, resistance revision19, access compatibility11, authority15. This is four new independent photo/fertigation hold cases plus existing workflow regressions; resistance suites here are existing regressions, not new exhaustive trial-transition acceptance.

**55 existing regressions passed, zero failures/errors/skips**, six suites: ActiveTrip1, OfflineQuickActions6, RetainedStartup13, SyncCrashIsolation5, SyncRecoveryStorage15, TripEndGate15. Both host stages exited0. Earlier narrower run at `/tmp/vinetrack-read-only-contract-waa23q4q/` passed42 focused and55 regressions. Final normal `runChecks(android-vinetrack)` **PASS**. Existing unrelated asset-address advisories untouched. Previously documented five completion failures were not selected, repaired or declared fixed; protected costing was not changed or rerun.

### G. Offline/restart and active-operation status

Synthetic tests establish owner/vineyard isolation, hold persistence across authority recreation without capability snapshot, no legacy release, original PendingWrite retention/claim restoration, Save for Later pre-journal denial and main-store stale Trip/Spray admission. Both platforms test real dependent outbox restart while held and resume using the original irrigation receipt/application ID. Android photo tests retain original bytes/row across repository recreation; structured reference rejection retains the uploaded object path and restores only the original reference operation without a second object upload. iOS tests exercise payload-vineyard isolation and recheck after suspension between sends.

These are native/source tests, not an authenticated app restart, offline historical-screen journey, active handset GPS transition or UI proof. Full journal/evidence/cleanup/active Trip/Spray coverage remains **UNVERIFIED**. No owner device, real account, queue or server record was operated.

### H. Uncovered paths / remaining native work

The feature is not safe to enable yet. Remaining work includes direct and ID-only repository mutations and trustworthy record scopes; full iOS metadata push/delete/orphan/manual retry/force-push closure; main-store extensions/public arrays and equivalent Android pre-enqueue local changes; Insights/vintage, chemical attachments/catalogue, weather/rainfall/settings/configuration/import paths; remaining Trip occurrence/labour, Spray planning/manual/tank and evidence journals; Quick Actions and active Trip/Spray/GPS callbacks. Existing tests do not prove all new sends after suspension within a caller-supplied batch closure are blocked. Generic unscoped payloads remain compatible, not protected by guessing current selection.

Common persistent notice, mutation-only purchase prompt, scoped observable state, server-triggered access reconciliation and eventual explicit-capability historical entry are **not implemented**. No full 23-case operational matrix, opening/editing/cancelling-without-save UI gate or protected telemetry/purchase/support/admin integration acceptance has passed. Swift malformed sidecar recovery, exact Android claimed timestamp retention, account changes during in-flight responses and exhaustive registry initialization order still require review. No native environment blocker is established; these are unfinished engineering, not solely backend access.

### I. Exact source identity and preservation

Observed starting/current managed HEAD: `bc9513910ca11881796a6a833e9d15391a1080e1`. Requested baseline `f4908f430b04b498baec43d296342e8501c3c575` to this HEAD application/test/runner diff is empty. Accepted foundation `60cacb0300d608495293b69fd3f3860281eb4577` is preserved as the content baseline described historically, not asserted to be an ancestor. Do not reset to either SHA or recreate the managed empty Config placeholder.

The 27 changed application/test/runner files above have ordered content manifest SHA-256 **`52caecb5d4ac11c2e4ce602824e2c8cd479dda94f183458926779e95fb73397c`**. Construction: sorted paths; UTF-8 lines `SHA256(file bytes) + two spaces + project-relative path + newline`, then SHA-256 of the combined lines. This binds the validated working source plus base; final managed-save commit is assigned after the turn and is not available yet. No manual Git commit/push.

`git diff HEAD --check` PASS. No Xcode project, app Gradle/dependency/signing/version, SQL/Supabase/Portal or costing edits. Android AppViewModel delta is solely the five matrix-authority lines; accepted final constructor observer/startup replay code is untouched. Versions remain3.1.8/iOS139/Android12. Test/build output is ignored or outside the project. No store export/upload, device reset/uninstall, data/cache clearing, forced logout, queue/draft deletion, production retained-payload rewriting or live server mutation.

### J. Separate server dependency and rollout gate

No authenticated live server check/change was performed. The previously supplied server contract still lacks explicit vineyard write capability. Backend delivery must separately provide effective `can_enter_vineyard=true`, `can_write=false`, `read_only_reason="trial_expired"` only for legitimate expired-trial historical access; preserve genuine revoked/foreign/disabled denials and paid/manual/legacy/admin access; enforce writes at the database with structured `VT_READ_ONLY` while leaving `record_my_client_activity` available.

Release/entry acceptance still requires complete native admission and the23-case gate, then authenticated permitted read, denied write with unchanged database row, retained held queue, correct scoped notice/prompt, purchase and explicit verified write restoration, paid/legacy regressions. **Entry remains closed. This checkpoint does not complete the user request or authorise rollout.**


## Expired-trial read-only access — continuation audit, 23 October 2026

**AUDIT-ONLY CHECKPOINT; FEATURE INCOMPLETE. Expired-trial entry remains closed.** No native enforcement, queue hold, UI or server-error integration was delivered in this continuation. Findings below identify required admission points, not guarded paths. The earlier contract/cache tests remain historical, not operational acceptance. Server delivery is not the only outstanding work.

### A. Exact files changed in this continuation

- `.rork/plans/android-live-trip-safe-automatic-complet_1791964262830.plan.md`: retain incomplete enforcement/acceptance items; add exact current notice/prompt copy, 23-case scope, explicit server-contract gate and this audit status.
- `docs/reviews/final-mobile-acceptance-legacy-save-recovery-2026-10-15.md`: this continuation inventory and A–J status; correct outstanding acceptance count to23.
- No application/test/runner/configuration source edits. Pre-existing managed `.rork/.skills-mount-fingerprint` modification preserved. No managed history edits, manual commit or push.

### B. Guard design and verified gaps

Required, **not implemented**: one cheap owner/vineyard-scoped `canWrite(vineyardId)` over the current verified/cached `VineyardOperationalAccess`, combined with existing auth/role rules. No network request per action; no personal trial/status/date inference; no account billing override of vineyard funding. Unknown older-server write state retains legacy behaviour. Do not open historical entry until all authored-command and outbound-transport admission points are covered.

**iOS confirmed command seam:** `ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift`, before in-memory publication, local persistence or callbacks. `addPinDurably` calls `onPinCreateWillPersist` before saving/publishing. `saveSprayForLater` calls `prepareLegacySpraySave` then `reconcileLegacySpraySaves`; preparation writes a recovery attempt, so a check after preparation or only before server transport is too late. `reconcileLegacySpraySaves` also hydrates retained original work: a blanket write restriction on reconciliation would incorrectly block preservation. `vineyards`, `pins`, `paddocks`, `trips` remain mutable arrays; caller/direct-mutation coverage is not established.

Additional command surfaces are the store's Management/Spray/SavedInputs/Yield/Buttons/GrowthStage/TripCostAllocations extensions and independent Fertiliser, Pruning, Resistance and Insights stores. `Backend/Sync/WorkTaskWriteCoordinator.submit` already accepts `canWrite`, but persists a durable intent before sending and checks the callback again before acknowledgement. Wiring an entitlement callback without distinguishing accepted receipts from new writes could strand successful-send acknowledgement. Existing callback semantics are not new expiry enforcement.

**Android confirmed replay seams:** `ui/AppViewModel.kt` `launchReplayStage` and `automaticReplayIdentity` protect startup/auth/account scope, but contain no write-entitlement check. Preserve the accepted final constructor initializer; no startup repair is needed. `data/PendingWriteRepository.kt` offers an exact-version pre-claim seam, but is not a universal command seam: some local mutations occur before enqueue, and independent queues/direct calls do not claim through it. `FieldStoreAccess` protects reads/cache/evidence too; blanket entitlement blocking there is inappropriate.

### C. Queue inventory and hold status

**No queue below has been given an expired-trial durable hold in this continuation. Inventory is substantial but NOT complete.** Existing conflict/storage/ownership holds must not be relabelled as trial holds. Required held reason: `READ_ONLY_TRIAL_EXPIRED` (or equivalent), preserving original IDs, timestamps, payloads, receipts and attempts. Resume only after verified write restoration; do not recreate/coalesce/replace retained work to represent a hold.

**iOS discovered families** (paths relative to `ios/VineTrack/`):

- `Backend/Sync/OperationsSyncServices.swift`: shared `OperationsSyncMetadata` dirty/delete sets for Work Tasks, labour, machine lines, paddock joins, piece-rate rows, maintenance, yield sessions, damage and historical yield. `WorkTaskMaterialSyncServices.swift` uses the metadata for vineyard and task materials.
- `Backend/Sync/ManagementSyncServices.swift`: `ManagementSyncMetadata` created/dirty/deleted sets for saved chemicals, spray presets/equipment, tractors/machines, fuel purchases/logs, operator categories, task types, equipment and saved inputs. Force-repush, worker-type delete replay and duplicate resolution also need review.
- Dedicated metadata: `PinSyncService.swift`, `TripSyncService.swift`, `SprayRecordSyncService.swift`, `PaddockSyncService.swift`, `GrowthStageRecordSyncService.swift`, `ButtonConfigSyncService.swift`, `GrowthStageImageSyncService.swift`.
- Other pending services located: `FertiliserSyncService.swift`, `PruningSyncService.swift`, `PickingRecordSyncService.swift`, `PruningYieldSettingsSyncService.swift`, `TripCostAllocationSyncService.swift`. Full admission/replay internals are not verified.
- Independent durable attempts/journals: `TripOccurrenceJournal.swift`, `TripLabourSnapshotJournal.swift`, `App/SprayEngine/SprayPlanningAttemptJournal.swift`, `LegacySpraySaveRecovery` used by `MigratedDataStore`, `ManualSprayEntryStore.swift`, `WorkTaskWriteCoordinator.swift`.
- Independent outboxes: `FertigationLinkedOutbox.swift`, `ManualIssueSyncService.swift`, `CustomPinTypeService.swift`, `SprayTargetLibraryService.swift`, `SprayTankActualStore.swift`, `App/Resistance/ResistancePlanRepository.swift` and its store.
- Ancillary evidence queues: Pin pending owners/photos/confirmations, pending pin notes in `LegacyImported/Repositories/PinRepository.swift`, growth photos, `PendingLinkedPinGrowthDeletion.swift`, Insights visits/notes/custom types/photos plus separate object/file cleanup and obligation repair in `App/Insights/VineyardInsightsStore.swift`.
- `FertigationLinkedOutbox.flush` has two sequential writes with retained irrigation acknowledgement before fertigation. It needs admission before each new send, not a whole-loop-only check; already accepted receipt preservation must remain allowed. Current generic catch records an error/permanent phase; it has no trial classification.
- Resistance `sync` first calls `adoptLocalOnlyPlans` and then pushes its own pending IDs. `save`, delete, restore and conflict choices mutate their own storage. Blocking only push would not prevent authored changes or automatic new obligations.

**Android discovered families** (paths relative to `android-vinetrack/app/src/main/java/com/rork/vinetrack/`):

- Shared `data/PendingWriteStore.kt` / `PendingWriteRepository.kt`: Pin create/completion/edit/delete; manual issues/custom types/pins/segments; Trip start/metadata/seeding/GPS/rows/row plan/tank/end/delete/labour; fuel; spray jobs/records; saved chemicals; Work Tasks/labour/machines/paddock joins/materials; vineyard materials; maintenance; yield/picking; paddock edits; pruning-yield settings; growth/damage/buttons; yield sessions; pruning/fertiliser coordinators. This is a coordinator-family inventory, not a proven exhaustive entity/operation/caller list.
- Shared claim mechanics verified: `claimReplay` preserves attempts but changes status/timestamp to IN_PROGRESS; `retryIfCurrent` increments attempts (default max8), returning FAILED/BLOCKED; `removeIfCurrent`/status operations require exact versions. Therefore holds must be admitted before claim and must bypass generic retry handling. Runtime account-incarnation scope is not durable per-operation provenance. ID-only remove/status/attempt APIs, retry reset, prune and queue replacement/coalescing callers still require closure.
- Separate `PendingPhotoRepository.kt`: attachment/file revisions, runtime-scoped claims, attempts and compare-current upload/completion. `PinCaptureEvidenceStore.kt`: owned retained evidence and revision acknowledgement. Full uploader budgets/transport coverage not verified.
- `LegacySpraySaveStore.kt`: actor/vineyard-scoped paired attempts and receipt recovery independent of normal pending rows. `ManualSprayOperationStore`: independent replay; full mechanics unverified. `SprayTankActualStore.kt`: owned pending tank actuals and exact-current acknowledgement.
- `TripOccurrenceNativeStore`: independent scope-keyed journals. Trip labour has additional direct replay callers. Pruning resource retry/generation/link state is not proven covered by generic outbox admission.
- `IrrigationRepository.kt`: separate pending sessions and `flushPending`; `FertigationLinkedOutbox.kt`: owner/vineyard-scoped two-phase queue, `enqueue`, `enqueueExisting`, `retry`, `flush`. No generic PendingWrite claim is used by the linked outbox.
- `data/resistance/ResistancePlanRepository.kt`: own local pending IDs/conflicts; save/delete/restore/conflict commands mutate before `sync`. `sync` adopts local-only plans and directly upserts.
- `data/insights/VineyardInsightsStore.kt` and sync repository: visits/notes/custom types/photos/object cleanup. `VintageReportViewModel.kt`: independent durable report commands, submit/recover/abandon/activate and acknowledgement.
- `ChemicalLabelPhotoRepository.kt` / `ChemicalLabelPhotoSync.kt`: separate attachment queue/replay. Parent CREATE dependency checks do not constitute expiry admission.
- Paired-growth capture journal, spray-target outbox and other Insights/resource internals remain follow-up gaps; no completeness claim.

### D. Server-error path

Native-source search found **no `VT_READ_ONLY` or `READ_ONLY_TRIAL_EXPIRED` handler** on either platform. Generic network/auth/retry handling must not be used as expiry classification. Required integration: recognize the structured server rejection; retain original input/queued evidence; apply an owner/vineyard-scoped durable hold without incrementing retries or acknowledging success; refresh access; show the shared purchase prompt only for the appropriate confirmed trial restriction. No forced logout, global account restriction, retry loop or payload replacement. A server rejection is not proof of a successful write, and does not itself authorize read-only entry.

### E. iOS tests

No tests written or run in this audit-only continuation. Historical accepted eight-suite122-pass and simulator-build result below remain unchanged. No operational Create/Update/Delete/complete/reopen/Quick Action/GPS, held-queue restart/resume, VT_READ_ONLY or UI acceptance has passed in this continuation.

### F. Android tests

No tests written or run in this audit-only continuation. Historical contract27/27, existing regressions55/55, isolated preference3/3 and normal build result below remain unchanged. Those are not expiry enforcement or the23-case operational gate. No owner handset or isolated emulator was operated here.

### G. Offline/restart and validation status

Prepared capability serialization/cache preservation remains accepted; actual offline historical admission, durable original-queue holds, restart survival, write restoration and active GPS/Trip/Spray transitions remain **UNVERIFIED**. No application code changed, so no redundant app build/test run was requested for this documentation-only continuation. Scoped whitespace/source-preservation checks are recorded at closeout; they are not runtime checks.

### H. Uncovered paths and unsafe shortcuts

Confirmed bypass families requiring integration include independent irrigation/fertigation and resistance queues; Insights/vintage; chemical attachments/catalogue RPCs; direct weather/rainfall/settings updates; repository-level configuration/equipment/import writes; public mutable iOS store arrays; Quick Actions and active Trip/GPS callbacks. End-to-end caller coverage remains incomplete for chemical purchases, imports, row configuration, Insights cleanup/recovery, pruning resources and direct backend repositories.

Examples found outside the shared queues:

- iOS `App/ChemicalIntelligence/CatalogueRepository.swift`, `ChemicalInventoryActionsView.swift`, `ChemicalSearchV2View.swift`; `App/Reporting/SprayReportRepository.swift` metadata-correction RPC; `App/Insights/VineyardInsightsSyncRepository.swift` / `VintageReportModel.swift`; `App/IrrigationSetupView.swift`; `RecentRainfallContractService.swift`, `WeatherCurrentService.swift`; `Backend/Sync/GrapeAllocationService.swift`, `VineyardTripFunctionService.swift`. Shared command endpoints include reads too: a blanket RPC prohibition would break browsing.
- Android `ui/screens/IrrigationRecordsScreen.kt` directly invokes system/valve/session methods and independent outbox flushing. `ResistancePlannerScreen.kt` uses its repository's local saves and sync. Weather setup/data screens directly invoke weather integration, station/credential save and backfill repositories. These screen-to-repository paths cannot be covered by only adding a guard to `AppViewModel.replayAllPendingWrites`.
- Android direct mutation surfaces located in `SavedChemicalRepository.kt`, `chemical/CatalogueRepository.kt`, `VineyardRepository.kt`, `RegionSettingsRepository.kt`, `PaddockRepository.kt`, `EquipmentItemRepository.kt`, `VineyardMachineRepository.kt`, `SprayEquipmentRepository.kt`; not all are confirmed UI bypasses because some callers may use central coordinators. Do not equate transport method discovery with a fully traced bypass.

No native implementation blocker is established: the remaining task is unfinished engineering/audit work, not solely missing server access. Keep entry closed rather than enabling a UI-only or transport-only restriction.

### I. Exact source identity

Observed HEAD: `f4908f430b04b498baec43d296342e8501c3c575`. User-accepted foundation: `60cacb0300d608495293b69fd3f3860281eb4577`. Accepted SHA is locally available but `git merge-base --is-ancestor` returned1: content equivalence, **not ancestry**, is the claim.

`git diff --name-status 60cacb0300d608495293b69fd3f3860281eb4577 HEAD -- ios android-vinetrack scripts` returned only deletion of `ios/VineTrack/Config.swift`, the14-line build-generated empty public-config placeholder. It was already absent from tracked HEAD; this continuation did not delete/restore/edit it or inspect injected values. All other tracked application/test/runner content matches the accepted foundation. Android tree IDs for both commits: `f6ec339c2c7509c8c55b6453513bee6646f94c75`. Starting worktree had only the managed fingerprint dirty; no app edits followed. Current HEAD is not a final managed-save SHA for these report/plan edits; that SHA is assigned after turn save.

### J. Server dependency and rollout gate

Live contract, as established by the owner, still has `can_enter_vineyard = has_vineyard_access` and no `can_write`/`read_only_reason`; no live server query/change was made in this continuation. Only explicit verified effective-vineyard `can_enter_vineyard=true`, `can_write=false`, `read_only_reason="trial_expired"` can eventually admit expired-trial historical access. Missing/null write retains legacy behaviour; reason/trial/status/dates alone must not create a restriction. Preserve paid/legacy/admin funding and genuine foreign/revoked/disabled denial.

Separate backend delivery must enforce operational writes with structured `VT_READ_ONLY` while leaving `record_my_client_activity` telemetry available. Final release acceptance additionally requires an authenticated expired-trial read, denied write with unchanged database row, original held queue, correct prompt, purchase/verified-write restoration, and paid/legacy regression checks. Native guards, holds, UI and23-case operational acceptance remain outstanding independently. **No rollout, export/upload, version change, SQL/server change, reset, logout, queue deletion, draft deletion, retained-payload rewrite or owner-data operation performed.**

## Expired-trial read-only access — contract/cache checkpoint, 23 October 2026

**PARTIAL IMPLEMENTATION — NOT READ-ONLY ACCEPTANCE OR RELEASE CLEARANCE.** This checkpoint implements additive decoding, scoped capability preparation and existing-cache persistence only. It does not complete the requested end-to-end native read-only feature. Existing entry routes, write paths and sync behaviour are not changed to admit/restrict expired trials. In particular, receiving `can_write=false` is not yet sufficient to stop a mutation. Do not roll out this checkpoint as read-only enforcement.

Latest scope supersedes every earlier store-delivery authorisation: no store exports/uploads, version/build-number changes, SQL/schema/server changes, owner-device operations, reset or deletion of retained data. Normal validation builds and synthetic namespaced tests only.

### iOS — implemented architecture and exact files

- `ios/VineTrack/Backend/Models/BackendVineTrackAccess.swift`: tolerant optional decoding for `can_enter_vineyard`, `can_write`, `read_only_reason`; account billing fields never override a vineyard row.
- `ios/VineTrack/Backend/Repositories/VineyardAccessMatrixRepository.swift`: decode those fields on each effective-vineyard row; prepare `VineyardOperationalAccess` with separate `canEnter`, `canWrite`, `readOnlyReason`. Missing/null write field preserves writable capability for an otherwise admitted vineyard. Entry denial implies no write and is not displayed as trial expiry. No inference from historical dates/status/source labels. Existing `hasVineyardAccess` and routing helpers intentionally remain unchanged.
- `ios/VineTrack/Backend/Subscription/EntitlementVerificationStore.swift`: optional per-vineyard capability map in the existing snapshot, preserving old snapshot decoding. Matrix verification preserves existing account grace time/result/expiry. Provider-only refreshes retain the same owner's matrix; fresh matrices replace it, including empty/denied results. Lookup requires the exact authenticated UUID owner, not a nil-owner legacy snapshot.
- `ios/VineTrack/Backend/Subscription/EntitlementGate.swift`: capture verified matrix capabilities, restore the exact owner's map on login, clear in-memory state on the existing logout lifecycle, and expose a prepared live-row-first capability lookup. No per-action entitlement requests; no new entry outcome or write admission is enabled.
- `ios/VineTrackTests/ReadOnlyEntitlementContractTests.swift`: contract/cache tests, including backward compatibility, independent funding, explicit denial, non-inference, serialization, owner isolation, unchanged grace and provider/matrix replacement. Names explicitly identify this as preparation, not Save/Create/Delete/Start or replay acceptance.

**Guard/server-error/offline/active-operation status:** no operational mutation guard, `VT_READ_ONLY` classifier, queue-hold integration, banner or purchase prompt has been implemented. The prepared cache is not an independent app-entry/write grant and must still be combined with existing auth/role/offline-write rules in the remaining integration. Cached read-only historical entry is not enabled. Trip/Spray/GPS/evidence and cleanup/completion behaviour remain unchanged, not newly verified under an entitlement transition.

**iOS validation actually executed:** `swiftTest` selection `VineTrackTests/ReadOnlyEntitlementContractTests`, `EntitlementDecisionTests`, `EntitlementAccessRegressionTests`, `StorePurchaseSyncTests`, `SyncQueueRegressionTests`, `OfflineQuickActionsTests`, `ActiveTripRouteRecoveryTests`, `DeviceTripOwnershipTests`: **122 passed in146s**, no reported failures. Success is aggregate-only; no per-suite discovery/skipped metric was returned. Final `runChecks(ios)` **PASS**, simulator build only; not device/App Store validation. Two unrelated existing asset-address advisories left unchanged. No separate iOS startup suite or UI journey was executed.

### Android — implemented architecture and exact files

- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/VineTrackAccessRepository.kt`: optional additive account and effective-vineyard fields; prepare normalized per-vineyard operational capability map with the same missing-write compatibility and denial/non-inference rules as iOS. Existing route/access flags remain unchanged.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/subscription/SubscriptionState.kt`: optional capability map in the existing snapshot; exact-owner scoped lookup, account-isolated provider merge and independent matrix verification preserving grace time/result/expiry. No parallel persistence system.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt`: persist freshly verified matrix capabilities only while the captured user remains current. No mutation/replay/startup/business-logic changes; existing final observer-start initializer is preserved.
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/ReadOnlyEntitlementContractTest.kt`:16 pure contract/serialization/merge cases, not operational action coverage. Seven existing grant labels are checked within one test, not counted as seven executed cases.
- `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/ReadOnlyEntitlementCacheTest.kt`:3 real-preference persistence cases in unique synthetic namespaces: recreation/grace preservation, provider retention/fresh replacement, cross-account/unowned legacy isolation. No owner preference/file is read or cleared; the tests do not invoke the existing fixture reset hook.
- `android-vinetrack/entitlement-tests.init.gradle`: narrow host-test compilation/selection without production configuration changes.
- `scripts/run-read-only-entitlement-contract.py`: reproducible host-only focused-first/regression-second runner; outputs outside the project.

**Guard/server-error/offline/active-operation status:** identical integration gaps to iOS. Android's existing `FieldStoreAccess` admission also protects reads/cache/evidence; adding a blanket entitlement check there would incorrectly prevent permitted reads and preservation. A network-only check would miss local/queued writes. Neither shortcut was used. No `VT_READ_ONLY` classification or automatic-retry suppression has been delivered. Offline historical admission and active-operation entitlement-transition behaviour remain unverified; this checkpoint leaves them unchanged.

**Android validation actually executed:**

- Focused host gate: **27 executed/27 passed/0 failures/errors/skips** = new contract16 plus existing `VineTrackAccessRowCompatTest`11.
- Widened existing host gate: **55 executed/55 passed/0 failures/errors/skips** across `RetainedStartupTest`, `SyncRecoveryStorageTest`, `SyncCrashIsolationTest`, `ActiveTripStoreTest`, `OfflineQuickActionsTest`, `TripEndGateTest`. This includes the existing33 startup/recovery cases. No old-constructor runtime reproduction or handset acceptance is implied.
- `androidTest`, only `com.rork.vinetrack.data.ReadOnlyEntitlementCacheTest`: **3 passed/0 failed/0 skipped,7s**, isolated instrumentation. No owner installation or data is used.
- Final `runChecks(android-vinetrack)` **PASS**. Normal validation build, not Play bundle delivery. Two unrelated existing asset-address advisories left unchanged.
- Host logs, exact selectors, fresh XML and results: `/tmp/vinetrack-read-only-contract-_tvh5q9c/`. Both host stages exited0. The five previously known Android completion failures were not selected, changed, reclassified or declared fixed. Protected costing was not changed or rerun in this checkpoint.

### Outstanding native work and backend dependencies

The latest requested23-case operational acceptance gate has **not** been completed on either platform (superseding the earlier20-case count). Contract tests establish DTO/capability/cache rules only. Outstanding native work: exhaustive operational local/server/queue admission; selected-vineyard read-only entry/browsing; Save/Create/Delete/Start/complete/reopen rejection; common banner/purchase prompt; `VT_READ_ONLY` response classification and held-original replay semantics without retry-budget consumption; telemetry/session/purchase/support/invitation/System Admin exceptions; offline/active Trip/Spray/GPS transition preservation and integration tests. No screenshot, release or full-enforcement claim is made.

The independent backend delivery must supply authenticated effective-vineyard `can_enter_vineyard=true`, `can_write=false`, `read_only_reason="trial_expired"` only for legitimate expired-trial access, retain true denial for revoked/foreign/disabled callers, preserve entitled funding/admin variants, and enforce writes at the database with `VT_READ_ONLY` code/message/hint. `record_my_client_activity` must remain allowed. Native work is still outstanding independently of those backend dependencies; deploying the backend alone does not complete this checkpoint.

### Source identity and preservation

Actual starting/current HEAD observed: `43ad2e542f8c30f66344826559a91b81e242f575`. This is the **base**, not a final managed-save commit. No commit/push was performed. Twelve changed application/test/runner files listed above have ordered SHA-256 manifest `877fa6e8c8e62f7778545b6a602e1f4dba44f7e89ebc766da2f27a9539ba1f4d` (UTF-8 lines: file-content SHA256, two spaces, project-relative path, newline; paths sorted). Final managed-save SHA is not available before turn save. Existing plan/report additionally updated; pre-existing managed history/fingerprint changes preserved.

`git diff HEAD --check` PASS. No changes to Xcode/Gradle version/signing/pricing/dependency settings, SQL/Supabase/Portal, calculators, operational stores, queue/evidence/GPS implementation or Trip/Spray business logic. iOS3.1.8/build139 and Android3.1.8/code12 remain unchanged. No data-clearing, account logout or live record mutation was performed. Native guards/UI/queue integration remain the next implementation checkpoint, not owner field acceptance or store delivery.

## Proven stale-build constructor fatal / fresh-source delivery — 23 October 2026 (current checkpoint)

### Proven fatal and source match

Owner supplies the actual retained-handset Internal Testing failure, package `com.rork.vinetrack`, versionName `3.1.8`, installed versionCode `1792728910`:

`java.lang.NullPointerException: Attempt to invoke interface method 'java.lang.Object kotlin.Lazy.getValue()' on a null object reference`

Frames supplied: `getReplayRunner:3103` → `launchReplayStage:3114` → `replayPendingPinCreates:3239` → `observeConnectivity:4804` → `observeConnectivity:4785` → `AppViewModel.<init>:2700`.

Read-only `git show e4d148096ebb0dc07f40eb9ef063b9e8bed3faee:android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt` confirms the exact mapped lines: early init2687, observer call2700, lazy declaration3103, delegate access3114, launch4785 and first-online replay4804. This establishes the reported constructor-order fatal in that installed build, superseding earlier unknown-root-cause statements. No raw full Logcat attachment or installed AAB bytes were independently retrieved here; the supplied frames and identity are owner evidence. Strict evidence parsing is not the reported fatal.

### Source provenance before validation

- Actual `git rev-parse HEAD`: `b42c384adce6c6cb35d973781f20847ff64a171a`. Requested `d5a478a1f9c0247875fec7b4ee1e4762a4b6426e` is unavailable (`not our ref`); do not claim HEAD equals it.
- At entry, complete Android diff against `cd1bff576f346c0d56872d136e9b1a92bb543398` was empty. Tracked Android tree both `f191bf322f182ea5558de181dfe71f82facafdd0`; production `app/src/main` tree both `8dab6e8b83169291bd54a253436b4d9cd568006b`. After test additions, production diff against that repaired commit remains empty.
- `AppViewModel.kt`: `startAfterConstruction()` at2694; `observeConnectivity()` inside that method at2707, not an early initializer. The sole class init is `init { startAfterConstruction() }` at18037, immediately before the class closing brace, after all property/delegate initializers. `replayRunner by lazy` at3111. Connectivity at4825 is informational only; admission gates replay separately. `StartupReplayAdmission.kt` exists and is unchanged.
- AppViewModel SHA-256: `125026f343894f1d584f8d597da898f2bdae7a9bd0d928a36fca2ec5e788d187`.
- Entry dirty state was three managed history files only. Final changes are three test-only files, new host orchestration script, existing report/plan and managed history. No production/startup/costing/completion/version/signing/dependency edit. Report final managed-save SHA only after Rork assigns it.

### Regression and validation actually executed

1. Added `RetainedStartupTest.observerStartupIsLastAndConnectivityCannotDirectlyReachReplayDelegate`: checks the final initializer, sole init, delegate ordering, no direct replay from transport observer and admission authority. Reads the actual historical source file for the negative control, not a fabricated legacy implementation. Old-file selection:1 executed/1 expected assertion failure/0 errors/skips,20.030s. Same guard in current gate passes. **This is a source guard, not execution of the old Application constructor.**
2. Current host startup/recovery:4 suites/33 executed/33 passed/0 failures/errors/skips,11.343s. Includes unchanged recovery suites plus the added guard.
3. `RetainedStartupConstructionTest`:3 passed/0 failed/0 skipped,7s, isolated emulator. Retains two previous cases and adds real Main.immediate construction with retained synthetic accessToken/userId and no refresh token. Test-only Application returns a null connectivity manager so the real observer's optimistic-online path runs without live network access. Confirms constructor returns, replay lazy delegate exists but is not initialized, admission is null, and online/SignedOut/Login resolves while the synthetic owner remains. **Does not independently timestamp the connectivity emission before constructor return or run the old constructor; the complete requested old-versus-new runtime reproduction remains open.** No owner-device installation/state is used.
4. Host runner initially used a too-broad costing selector:224 executed/219 passed/5 known completion failures/0 errors/skips. Preserved as `protected-costing`; no assertion/source correction or unrelated repair. Corrected only the runner's selection to the12 exact accepted costing classes and resumed costing without rerunning successful startup tests. Final costing205/205,0 failures/errors/skips,11.337s; parity20/20. Completion test SHA-256 remains `72b9bc31bff6c32cd606b8ab2a307b466bc3e0ae6e0b8ac092c13e06a000aae5`; costing runner remains `3390d7ef0df0fed301f0fc4af854d078222c549291c672e035c2c781f19f5e76`.
5. `./gradlew clean` succeeded before host execution. Gradle subsequently used eligible compile caches; this is **not** proof of an uncached clean AAB build. Final `runChecks({appPath:"android-vinetrack"})` PASS; two pre-existing nonblocking asset-address advisories untouched. Normal build check is not a Play AAB export or provenance certificate. Scoped whitespace check PASS; production source diff empty.

Runner: `scripts/run-startup-provenance-regressions.py`; logs/XML/results `/tmp/vinetrack-fatal-regression-suttofg_/`, initial console `/tmp/vinetrack-fatal-regression-runner.log`, exact costing resume `/tmp/vinetrack-fatal-costing-exact.log`. Genuine old-file guard failure and accidental broader completion failures are preserved. No fatal-free handset claim.

### Fresh managed AAB delivery and remaining blocker

Connection and existing package access succeed. A new-to-this-conversation listing is visible: completed run `b10db229-698d-406a-8565-b547b31cab30`, snapshot `osok3p723wih24aeuyknb`, source label `src_f191bf322f182ea55`. The label matches the prefix of the repaired tracked Android tree, unlike the earlier costing-source listing. **It is still an already completed build, not the fresh clean build requested now.** Status exposes only `completed` and an APK storage key, not snapshot contents or inspectable AAB bytes/manifest/certificate. Do not treat a matching label alone as proof of its snapshot contents or reuse it. Listing after the normal build check is unchanged; the check exposes no new managed snapshot/source binding.

The supported generation operation requires snapshotId/sourceHash inputs; no supported operation exposed here creates or inspects a fresh current snapshot. Therefore no guessed identity, reuse of `osok…`/older snapshot, local debug-signing bundle substitution, `generatePlayAab` call, publish validation or upload was made. **Fresh AAB delivery remains blocked_missing_typed_operation.** It requires the managed publishing route to create a fresh snapshot and verify repaired AppViewModel bytes, then build without stale artifact reuse and expose AAB creation timestamp, SHA-256, manifest version/code and registered upload-signing identity before Internal Testing delivery.

Required replacement: `com.rork.vinetrack`, versionName `3.1.8`, valid unused managed versionCode **greater than1792728910**. No code was allocated or guessed. Source code12 remains unchanged and is explicitly NOT a valid replacement code;12/13 must not be used. No candidate AAB path, creation timestamp, checksum or actual candidate versionCode is available to report, and no submission ID exists from this pass.

**No Production release or other track mutation. No owner data/cache/queues/evidence/server records changed.** Decisive acceptance remains a normal in-place Play update of the owner's retained installation and successful launch with retained records. If that proven repaired build fails, capture fresh `adb logcat -b crash -d -v threadtime`, full FATAL EXCEPTION/Caused by/app frames and installed version/code, then compare to this fatal before another repair. Do not claim fixed before that acceptance.

## Android Internal Testing delivery — 23 October 2026 (preceding checkpoint)

Latest owner approval permits Google Play Internal Testing only, superseding earlier no-upload restrictions. Application logic, costing, completion logic and tests remain frozen at repaired commit `cd1bff576f346c0d56872d136e9b1a92bb543398`. Only a verified unused versionCode metadata change is permitted; none has been made. Readiness: **blocked_missing_typed_operation** (also missing current-source bundle/signing evidence).

### A. Highest existing Play version code found

**UNKNOWN.** `setupGooglePlay` returned connected; `ensurePlayAppRecord` returned status `ok`, package `com.rork.vinetrack`, created `false`. These prove connection/package access only. The available typed operations do not expose a complete inventory of all previously uploaded bundle codes including inactive/draft/testing bundles. The managed-build listing is not that inventory. No publish-validation upload was used to probe code availability.

### B. Candidate version code selected

**None.** Code13 has not been confirmed unused. Source remains versionName `3.1.8`, versionCode `12`, package `com.rork.vinetrack`. No speculative increment or signing substitution.

### C. Exact source SHA

Accepted repaired commit: `cd1bff576f346c0d56872d136e9b1a92bb543398`. Actual inspected HEAD: `ba3501ea505a67175af82422b9b517cdadfd74af`. `git diff cd1bff576f346c0d56872d136e9b1a92bb543398 --stat -- android-vinetrack` returned empty: current tracked Android source equals the accepted repaired source, not just the earlier costing tree. Only pre-existing managed history was dirty before this report/plan update. No app source, tests or version metadata changed in this delivery pass.

### D. AAB identity/hash/signing information

**No verified current-source AAB is available.** Latest `listPublishablePlayBuilds` still returns run `6b4346d6-9cd6-449c-90cd-ab2e00a6a022`, snapshot `9iat969ix81rnubopq3d9`, source `src_bb27280d389d866f5`, the pre-startup costing tree. The returned listing provides no AAB path, checksum, manifest version or certificate. No authoritative current snapshot/sourceHash binding is exposed, so no guessed generation or old-source reuse was attempted. There is no candidate AAB path/hash/upload-certificate proof to report before upload.

The historical evaluation APK and its observed certificate below are **not** an owner update artifact or proof of the Play-registered upload identity. Need non-secret Play Console App Bundle Explorer evidence covering all uploads and App integrity's registered upload certificate (plus app-signing/installed compatibility evidence where applicable). Need the supported managed build route to expose a current-source binding and inspectable bundle identity/checksum/signature. Do not request credentials or use a third-party Play CLI.

### E. Internal Testing upload status

**NOT UPLOADED; blocked before candidate selection.** No `generatePlayAab`, `publishInternalBuild` validation/commit, or track mutation was performed in this pass. No submission ID exists for this repair. Do not call publishing to discover missing code/signing/source facts.

### F. Confirmation no Production release occurred

No Production release, promotion, rollout, Closed/Open testing action or listing change was performed. Internal Testing approval does not authorise any of those actions.

### G. Retained-handset acceptance remains pending

**PENDING, not release-cleared.** Owner must perform a normal compatible in-place Play update over the retained installation after the verified Internal Testing build is available. Do not install the local evaluation APK, uninstall/reinstall, clear cache/storage, sign out, reset queues, use Retry All or change server data. Cancel Android's cache prompt. Verify stable screen/live process, retained account/vineyard and pending evidence, repeated relaunch and offline/reconnect stability where practical. If it terminates again, collect `adb logcat -b crash -d -v threadtime` with full FATAL EXCEPTION, Caused by chain and app frames, plus installed versionName/versionCode, before another repair.

Validation in this delivery pass: read-only source equivalence and unchanged metadata checked; no app code changes or redundant build/test execution. Previous frozen-source host32/32, instrumentation2/2, costing205/205 and normal Android build PASS remain the source-level gates, not handset acceptance.

## Android retained-data startup hardening — 23 October 2026 (repaired-source checkpoint)

This checkpoint supersedes earlier fatal-first/source-freeze language only for the owner's newly authorised narrow Android startup repair and deterministic regressions. **Owner-confirmed immediate retained-handset crash; actual cause UNKNOWN; Android 3.1.8 NOT release-cleared.** Cancel Android's cache-clearing prompt. Earlier source/build/sign-in observations are not successful retained-data cold-launch acceptance.

### A. Actual fatal stack, if obtained

No actual handset fatal stack obtained. `adb devices -l` is empty; the earlier runtime-log read returned no logs. No FATAL EXCEPTION, complete cause chain, app frames, installed version/checksum or live handset process was captured. No log buffers, cache or owner data were cleared.

### B. Proven root cause

**The owner's crash root cause remains unproven.** Source inspection showed connectivity's first online event could request automatic replay/refresh before restore completed. It also showed the startup initializer preceded `replayRunner`'s lazy-delegate initialization. These are concrete ordering/admission hazards, not a captured fatal or a deterministic reproduction of the owner's process death. Strict pin evidence failures were already exception-isolated inside bounded replay; do not relabel them as the handset fatal. No manufactured legacy implementation/failing-before result is used.

### C. Startup changes

- `AppViewModel.kt`: final textual initializer starts observers only after all fields/lazy delegates exist. Construction-time Start Tank journal mutation is deferred to authorised vineyard loading; existing journal recovery is not deleted/reset.
- Connectivity observer updates transport/session information only. A distinct admitted-identity edge requests one bounded automatic replay cycle after restored-online authentication, unlocked matching account, Main route, selected membership vineyard and readable evidence. Duplicate post-load fan-out is removed. SignedOut/Restoring/loading/biometric/restricted/paywall/offline states cannot admit replay.
- `StartupReplayAdmission.kt` holds the shared host-testable admission predicate. All replay stages, including Phase 5/Trip and occurrence stages, pass through `launchReplayStage`; scope and admitted identity are checked both before queueing and before work/claim recovery. Existing bounded runner and coordinators remain unchanged.
- Remote snapshot/canopy refresh and foreground refresh use admission guards. Restore/membership/access-resolution requests remain phase B/C work, not automatic domain replay.
- `PinCaptureEvidenceStore.kt`: typed held read preserves strict unknown-field/conflict rejection, updates an issue flow and never persists the held empty items. Save/acknowledgement refuse unreadable source; pending replay reports the held issue. Reads do not use AtomicFile's destructive recovery/open path. Fresh signed-out Login is not mistaken for a pin-storage failure; account-bound evidence is re-read during admitted vineyard resolution.
- `SyncStatusScreen.kt`: displays pin evidence recovery warning and suppresses 'No pending items' while held; retry is disabled while evidence is held. `PendingWriteStore.kt` only extracts its existing strict decoder for direct host coverage; no format, defaults or recovery outcome change.

### D. Retained-data safety

No owner-device install/update, uninstall/reinstall, cache/storage clearing, sign-out, Retry All, queue reset or server-data change was performed. No original evidence files/preferences are deleted by the new read boundary. Malformed/unknown/conflicting pin copies remain held as original bytes; no permissive decoder or empty-authoritative overwrite is added. Pending-write payloads, UUIDs, attempts, trip ownership and GPS identities retain existing contracts. Synthetic host temporary files and namespaced instrumentation fixtures are not the owner's retained installation.

Accepted costing `a6f2d4fbb10f4154427b62145c9a872495bf754c`, all costing fixtures/assertions and the costing runner are protected. The five completion failures remain untouched and pre-costing attribution remains unproven. No iOS, SQL/Supabase/server, version/code, signing, dependency or production Gradle configuration changes are in this checkpoint.

### E. Tests

**Final frozen-source host startup/recovery gate PASS: 4 suites /32 executed /32 passed /0 failures /0 errors /0 skipped, Gradle 3m37s.** `RetainedStartupTest`11, `SyncRecoveryStorageTest`15, `SyncCrashIsolationTest`5, `ActiveTripStoreTest`1. New host scenarios cover immediate-online-before-restore, authorised-route gating, malformed pending writes, malformed/newer/conflicting pin evidence, offline retained identity, bounded online-after-restore edge, pending/pin/Trip restart identities, signed-out admission and storage-read/cancellation handling. Existing suites/assertions unchanged. First host run also passed32 in4m34s; because final fresh-sign-in/pending-read guard edits overlapped that compilation, it was not used as frozen-source certification. The final rerun above follows those concrete edits, not an unchanged retry.

**Instrumentation PASS: `com.rork.vinetrack.data.auth.RetainedStartupConstructionTest`, 2 passed /0 failed /0 skipped, 9s.** Real Main-thread ViewModel construction resolves SignedOut→Login for (1) fresh fixture and (2) incomplete retained synthetic credentials plus malformed pending writes/unknown pin input/torn backup. Original synthetic preference/file bytes remain equal; issue flows are held. Uses the pre-existing `CleanExitFixtureApplication` namespacing; no owner installation or live credentials. This is debug instrumentation/state observation, not release-APK cold launch, Activity screenshot acceptance or a retained-owner in-place update. The host fresh/offline/admission scenarios do not by themselves prove full Application/UI startup; these two construction cases provide a separate, narrower actual ViewModel boundary check.

**Protected costing PASS: 12 suites /205 executed /205 passed /0 failures /0 errors /0 skipped, Gradle24s; parity20/20.** Same12-suite inventory and accepted costing assertions as the earlier checkpoint. No five-completion or other14-completion test execution/repair in this pass; their historical failures/unknown attribution are unchanged. Costing runner SHA-256 remains `3390d7ef0df0fed301f0fc4af854d078222c549291c672e035c2c781f19f5e76`; completion test remains `72b9bc31bff6c32cd606b8ab2a307b466bc3e0ae6e0b8ac092c13e06a000aae5`.

Host command prefix: `./gradlew :app:testDebugUnitTest --init-script <absolute app path>/startup-tests.init.gradle --console=plain '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC'`. Costing uses unchanged `costing-tests.init.gradle` with the12 exact class selectors listed in the historical costing inventory. No competing Gradle runs. Logs: `/tmp/vinetrack-startup-tests.log` (initial), `/tmp/vinetrack-startup-final.log` (final), `/tmp/vinetrack-startup-costing.log`; copied XML in `/tmp/vinetrack-startup-initial-xml`, `/tmp/vinetrack-startup-final-xml`, `/tmp/vinetrack-startup-costing-xml`. Counts above verified from fresh XML before subsequent tasks overwrite test outputs. Environment remains Temurin17/Gradle8.14.3 and existing SDK/config; no timezone override or dependency changes.

### F. Build

**Normal `runChecks({appPath:"android-vinetrack"})` PASS.** Existing two asset-address advisories are nonblocking and untouched as unrelated. Fresh local release APK: `android-vinetrack/app/build/outputs/apk/release/app-release.apk`,77,105,989 bytes, SHA-256 `cf9716d68e3e3247e62a348d52e5b3bb71144ce68abd1ec0b022dab2ac15e9c2`. Manifest: `com.rork.vinetrack`,3.1.8/code12,min24,target36. `apksigner verify --print-certs` PASS; observed certificate SHA-256 `241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3` (CN Rork Kotlin Play Upload), same observed certificate as the historical local APK. Initial inspection tried nonexistent build-tools36.0.0, then used installed35.0.0; no artifact mutation/rebuild was needed for that read-only tooling-path correction.

This is the freshly built validated-worktree APK for internal evaluation only, **not a release-cleared or verified update-compatible owner candidate**, not a Play AAB, and not proof of the owner's installed signing identity/lineage or an unused next Play code. Do not install it over owner data until compatibility is established. No signing substitution/version bump was made.

Metadata-only `listPublishablePlayBuilds` after the successful build returned latest run `6b4346d6-9cd6-449c-90cd-ab2e00a6a022`, snapshot `9iat969ix81rnubopq3d9`, source label `src_bb27280d389d866f5`—the known pre-startup costing tree, not this repaired working tree. No authoritative current managed snapshot/sourceHash pair was exposed, so no guessed/old-source `generatePlayAab` call was made. **Source-bound managed AAB/update-compatible candidate delivery remains BLOCKED.** No upload, publish-validation upload, internal-track commit, distribution or Production action occurred.

Exact source/test/host-runner inventory is8 files: the5 production files described in C, `RetainedStartupTest.kt`, `RetainedStartupConstructionTest.kt`, and `startup-tests.init.gradle`. Ordered lines `SHA256 + two spaces + project-relative path + newline`, paths sorted, produce source-manifest SHA-256 `f0a8ca17c467a0f9382a65a3a6c6cd3bdb535e3f204fff03b31d32ea5f96fb4d`. This plus starting HEAD identifies the validated patch; no final managed-save SHA or remote snapshot binding is invented. Existing report/plan are updated separately; managed history is preserved. Final `git diff HEAD --check` PASS; protected iOS/scripts/SQL/Supabase/dependency/build/version/signing/costing-runner/completion-test path diff empty. Final8-file manifest recomputed after all tests/builds and matched; no app-source edits after frozen-source validation.

### G. Remaining acceptance

Required: supported source-bound internal-test candidate identity/signature verification, owner-controlled compatible in-place update over retained data, cold launch to stable UI with live process and retained records. **NOT PASSED.** No clearing/reset may be used to obtain success. If it closes, capture crash-buffer Logcat including complete causes/application frames before another attempt, plus installed version/code and process identity. Host tests, debug construction and a build PASS cannot close this item.

Starting managed HEAD `fe08140749c3eb5f4a62a88e4afac42072c71172` is a baseline, not the final repaired managed-save SHA.

## Android unchanged baseline comparison and costing gate — 23 October 2026 (historical checkpoint)

This checkpoint supersedes the earlier statement that no rebuilt-baseline experiment was attempted. It does not supersede accepted costing or establish a handset startup result. No application, test fixture, assertion, Gradle runner/configuration, iOS, SQL, server, version, dependency or signing changes were made.

### A. Five-test baseline matrix

**Baseline comparison BLOCKED; current five-test selection RED.** No FAIL/FAIL or PASS/FAIL attribution can be made for any row because the baseline never reached test execution.

- Accepted costing commit: `a6f2d4fbb10f4154427b62145c9a872495bf754c`.
- Exact immediate pre-costing parent selected: `83d6b0f819a8e6f22f610f98d5f1dcd540b4f8cf`. Android tree `bad9b1081a40e6671e9616157686065a5a390491`, identical to accepted sync `019735ad043815c4082a3ee1ad496de0192abb74` and earlier pre-costing `c0e461ec986e7ee105ad39be6e1e4284fd115d12`.
- Current tested HEAD: `c3b4c590d9dca929562e3d3f995885583e76405f`; Android tree `bb27280d389d866f562d3cccc41284c36bbc1583`. Android diff against accepted costing commit is empty.
- Baseline exported using `git archive` into `/tmp/vinetrack-costing-baseline-bv2d8p6m/baseline`; all **1,152 tracked baseline Android files** verified against their Git blob identities, **zero mismatches**. No checkout/reset or baseline modification.
- Baseline command exited1 after77.395s at `:app:compileDebugKotlin`: `AppConfig.kt:5:27 Unresolved reference 'Config'`, also at116:29 and148:25, with downstream trim/not diagnostics. Managed `app/src/main/java/**/Config.kt` is ignored by `android-vinetrack/.gitignore:49` and absent from the Git archive. No substitute/copy/stub/config/source edit was added to force compilation. **Zero tests executed**, not five test failures or a passing zero-test run. This clean exported tree lacks required managed configuration; its runtime behaviour is untested.
- The initial orchestration correctly stopped at its five-test-discovery assertion. Host orchestration was then changed only to resume the two current stages, preserving the original failure/log and recording `baseline_comparable=false`. The failed baseline was not retried or repaired.
- Current exact selection: **5 executed /0 passed /5 failed /0 errors /0 skipped**, exit1,13.036s. Each row below is **baseline NOT EXECUTED → current FAIL**, all in `com.rork.vinetrack.data.WorkTaskCompletionTest`:
  1. `Sydney Work Date selection round trips the UTC picker calendar day` — expected2026-10-05, actual2026-10-04; assertion line46.
  2. `new local midnight Work Date resolves through vineyard timezone` — expected2026-10-04, actual2026-10-05; assertion line72.
  3. `customer A B C keeps work date and separate audit` — expected2026-09-30, actual2026-09-29; assertion line97.
  4. `offline update survives restart overlay full refresh and replay with original audit` — expected `completedBy=original-user`, `completedAt=2026-10-05T01:20:30Z`; restored both NULL at line136. `finalizedBy` and `finalizedAt` remain present. This assertion stops the test before its later replay assertions.
  5. `duplicate pending create patches folded completion before acknowledgement` — `java.util.NoSuchElementException: List is empty.` at line248 (`server.updates.single()`); later assertions not reached.

The completion test is byte-identical between baseline/current (SHA-256 `72b9bc31bff6c32cd606b8ab2a307b466bc3e0ae6e0b8ac092c13e06a000aae5`). Identical completion/sync source remains source evidence only, NOT a proven failing-before experiment. No costing-induced regression or pre-costing failure was established by this blocked comparison; no completion/sync repair is authorised or performed here.

**Same runner/environment:** all stages use unchanged current `costing-tests.init.gradle` (SHA-256 `3390d7ef0df0fed301f0fc4af854d078222c549291c672e035c2c781f19f5e76`), Temurin17.0.13+11, Gradle8.14.3, `JAVA_HOME=/usr/lib/jvm/jdk-17.0.13+11`, `ANDROID_HOME=/opt/android-sdk`, `GRADLE_USER_HOME=/home/user/.gradle`; LANG/LC_ALL/TZ unset. No forced timezone or fixture edits. Baseline/current production configuration availability differs as described above; no claim of fully equivalent executable environments.

Command prefix in each app directory:

```sh
./gradlew :app:testDebugUnitTest \
  --init-script /home/user/rork-app/android-vinetrack/costing-tests.init.gradle \
  --console=plain '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC'
```

For the five-test stages append `--tests 'com.rork.vinetrack.data.WorkTaskCompletionTest.<exact method above>'` once per method. The unchanged init forces actual Test task execution and disables its result cache. Current XML timestamps are new, not reused earlier results; normal production compilation may use Gradle cache.

### B. Costing gate

Fresh current-only gate: **12 suites /205 executed /205 passed /0 failures /0 errors /0 skipped**, exit0,12.630s. All20 `MobileCostingParityTest` cases discovered and PASS. This is a green costing partition, NOT a green full completion suite or rerun of all224 earlier cases. The other14 completion tests were not rerun in this checkpoint.

Exact discovered suite inventory, under `com.rork.vinetrack.data` except the noted material subpackage; each selected using `--tests '*.<ClassName>'`:

- EffectiveLabourCostTest20; MobileCostingParityTest20; PieceRateCostingTest19.
- PruningActivityLabourLineTest19; PruningActivityWorkTaskLinkTest15; PruningWorkTaskCostingCreateTest17; PruningWorkTaskRepairTest9.
- WorkTaskCostRollupTest6; WorkTaskLabourCostingTest24; WorkTaskMachineCostingTest18; WorkerTypeIntegrityTest10.
- `material.WorkTaskMaterialCostsTest`28.

Trip allocation coverage is within parity/rollup/worker-type cases, including GPS marker/slices once, saved allocation decoding, distinct parents and deleted/missing-parent exclusion. There is no separately discovered Android TripCosting-named suite; none is claimed.

Accepted owner-supplied fixture assertions remain green: Stockmans labour **$18,937.00**, fuel **$20.79**, total **$18,957.79**, physical **6.14908359375ha**, **$3,083.03/ha**; Shoot thinning **$810.63/ha**, Removing Guards **$2,622.53/ha**, Mulching **$15.74/ha**, **$96.79 complete**; legacy **10h ×14 ×$36 = $5,040** only without canonical lines. Supplied approximately **37.27ha Treated** remains a separate figure, not the physical denominator: the repeat-operation test checks the separation, not an exact37.27 fixture assertion. No production rows were queried.

### C. Startup evidence

Still **UNVERIFIED**, separate from these host unit results. Fresh `adb devices -l` remains empty. No real FATAL EXCEPTION/full causes/application fatal frames, retained-data cold launch, owner failing-binary identity or physical-device acceptance obtained. Prior separate simulator sign-in observation is not a cold-start PASS. Strict evidence decoding and observer-before-restore remain source hazards only. No startup code edits, storage clear, uninstall, queue reset, Retry All, record replay or server mutation occurred.

### D. Binary provenance

Existing APK remains unchanged: SHA-256 `e2235b6ff4dc50514f60ee6b1330f7b16cb87518301b798fb8b06c771beca788`; previously verified signing certificate SHA-256 `241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3`. Existing output metadata reports release APK, `com.rork.vinetrack`,3.1.8/code12; it contains no commit/snapshot/sourceHash binding. No APK/AAB was assembled to manufacture provenance.

Metadata-only managed reads now also list run `a82da67f-ee7e-4116-b6d6-6777c4142d67`, snapshot `r2can6m70l01s7flg26hx`, source label `src_bad9b1081a40e6671`, Kotlin/android-vinetrack/com.rork.vinetrack. Status returns `completed` and APK key `kotlin-builds/t1ycqwwwkgzt982ur27ya/art_758f9ba453c02491f/app.apk` only. The source label resembles the pre-costing Android tree prefix, but the returned fields do not bind the existing local APK checksum or owner's installed failing binary to a Git commit. No current-costing artifact provenance, downloadable AAB, version/signature mapping or installed compatibility is established. No build generation, provider upload or publication was invoked. Earlier managed run5d3cdb28 remains historical and unmapped.

### E. Changes and retained evidence

- Added host-only `scripts/run-costing-baseline-comparison.py`; updated this existing report and existing approved plan. Python syntax validation PASS. Script records actual discovery, rejects stale XML, retains baseline failure and resumes current stages without altering baseline/application behaviour.
- Raw evidence: `/tmp/vinetrack-costing-baseline-bv2d8p6m/metadata.json`, original `runner.log`, resumed `runner-current.log`, each stage's `gradle.log`/`result.json` and copied fresh TEST XML, plus `finished.json`. Baseline has no test XML. These are temporary host evidence, not handset logs or delivered artifacts; durable counts/assertion boundaries are recorded above.
- Android production/tests/configuration/runner tree remains identical to accepted costing commit. No app-source changes in this pass. Existing unrelated committed iOS Config.swift difference between accepted costing and current HEAD is preserved, not reverted and not represented as cross-platform tree equality. Managed history/fingerprint changes already present at entry were not edited or reverted by the agent.
- Whitespace check PASS. No app checks/build rerun because no app code changed and APK rebuilding was outside this diagnostic scope; earlier normal app build PASS remains historical. The fresh205-test costing gate is successful; the current five-test gate fails and baseline compilation is blocked as explicitly reported.

## Urgent Android startup regression — fatal-first checkpoint, 23 October 2026

Owner requires the first real fatal stack/root cause to be reported before broad changes. No production/test/build configuration edits, new binary builds, owner-handset operations, storage clears, uninstalls, queue resets or server operations were performed in this checkpoint. The requested evidence-reader correction, restore/route replay gate and release acceptance test remain unimplemented pending the fatal-first boundary; no repair or launch PASS is claimed.

### Runtime evidence and access

- `adb devices -l` returns no connected devices. The local SDK has no emulator/system image and `/dev/kvm` is absent. No local device path is available for installing/updating fixture APKs, collecting Logcat, seeding private retained files or checking process survival.
- One `simulatorUse` attempt used a separate disposable Android simulator (billed by the platform), not the owner's handset or open preview. It observed the VineTrack sign-in screen. It returned **could not test**, zero actions: the harness cannot force-stop/relaunch MainActivity, inspect process survival or obtain crash logs; exact artifact/device identity and initial persisted state were unavailable. This proves only the observed sign-in UI, not clean-install/cold-start/release acceptance. No sign-in, record mutation or storage manipulation occurred.
- Runtime CLI retry with valid limit100 returned historical August logs, not an October launch fatal; errors-only lookup returned `No runtime logs found for this project.` No FATAL EXCEPTION, Caused by chain or application fatal frames were captured. The initial limit150 request was rejected by the CLI's limit100 validation; not a runtime result.
- Clean cold launch, retained-v3.1.7 upgrade fixture, actual release-APK launch, process survival, Sync Status held-evidence display and same-signing two-binary bisect are **NOT EXECUTED/UNVERIFIED**. Host/debug tests and prior builds are not substituted for these gates. No testReleaseUnitTest invocation or release certification claim.

### Source and local artifact identity

- Requested bad commit `019735ad043815c4082a3ee1ad496de0192abb74` exists and its parent is exactly `b4f4d24babfa3929418742854e7ed1af0c7477cb`. Accepted Android subtree: `bad9b1081a40e6671e9616157686065a5a390491`.
- Current managed HEAD: `4bc5b7a2989f5d2ef3b7aa2c3cae16ed60a6e834`; current Android subtree: `bb27280d389d866f562d3cccc41284c36bbc1583`. Contrary to the supplied no-later-production-change premise, the accepted later costing checkpoint changed eight Android production paths: CostReportBuilder.kt, PruningActivityTaskLink.kt, model/CostingReadAuthority.kt, model/Models.kt, model/PieceRateCosting.kt, model/WorkTaskCostRollup.kt, ui/screens/CostReportsScreen.kt and ui/screens/WorkTasksScreen.kt. Preserve them; do not roll back current source or call it byte-identical to019735ad. Startup/evidence code examined here remains the accepted implementation.
- Existing local `android-vinetrack/app/build/outputs/apk/release/app-release.apk`: SHA-256 `e2235b6ff4dc50514f60ee6b1330f7b16cb87518301b798fb8b06c771beca788`; aapt reports package `com.rork.vinetrack`, versionName `3.1.8`, versionCode12, launchable `com.rork.vinetrack.MainActivity`. apksigner verification succeeds; certificate SHA-256 `241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3` (CN=Rork Kotlin Play Upload).
- This is a local artifact inspection, NOT proof it is the owner's failing installed APK or proof of its originating Git tree. No authoritative managed snapshot/sourceHash-to-artifact mapping was obtained. Prior run5d3cdb28-4ecf-4885-8fd2-ff5c6344e1a2 / snapshotw90k30g3ec68z9ovelnt6 / src_bc2b045cb71b33f7b remains an unmapped historical reference, not accepted-tree provenance. Version/code/certificate alone cannot establish source identity or in-place installed-signature compatibility.

### Confirmed source hazards, not the captured handset root cause

- PinCaptureEvidenceStore.kt:75 changed ignoreUnknownKeys from true to false in the requested commit. load():93–102 directly calls readRetainedEvidence():140–154; strict decode/file reads and conflicting-copy check can throw. No loadForRecovery-style readable/held result exists. Preserve strict unknown-field detection and all source bytes when a narrow repair is undertaken; never translate unreadability to an authoritative empty store.
- AppViewModel init:2699 calls StartTank recover synchronously, then starts connectivity/pending observers before restore():2723. observeConnectivity():4800 starts replay fan-out on any online emission; launchReplayStage():3113 checks token/account scope/online, but not restore completion or a stable initial route. These are source-order facts, not an executed fatal stack.
- The pin-owner helper at3163 already wraps load in runCatching but substitutes an empty list; pending evidence is also read at3275. This needs typed held-state handling, not blanket lifecycle exception swallowing. The complete PendingWrite/ActiveTrip/RecoverySnapshot/StartTank runtime boundary is not yet proven safe.

**Next required evidence:** the affected APK/build download plus its Rork build identity, and a real Android crash-buffer/Logcat capture covering one cold launch with complete exception/causes/app frames; alternatively an ADB-capable disposable device/emulator supporting retained fixture updates. Do not request raw auth tokens or private owner data. Owner device must retain its installation/storage. Stop at this evidence blocker rather than fabricate the stack or apply broad startup changes.

## Mobile costing correctness / Portal parity — 23 October 2026

**Costing-only correction checkpoint; not a release or handset acceptance.** This approval supersedes the earlier application-source freeze only for the costing/area readers on both platforms. Historical sections below retain their original identities and results; their old Android tree, 116-test gate and artifact identities do NOT describe the changed costing source.

### A. Root causes

- **iOS:** remote generated labour totals were discarded during mapping and recalculated from line inputs; some task-aware labour/pruning readers bypassed historical inline resources. Fuel-only manual machinery was incorrectly incomplete unless both fuel and machine-charge totals existed. The editor independently summed allocations and refreshed retained area snapshots; reports used cumulative treated hectares as a denominator, counted slice rows as Trips, and could overlay current estimated chemical prices onto saved totals. Rollup Double addition exposed `50 + 20.79 = 70.78999999999999` before Decimal conversion. Existing piece-rate tests also exposed binary half-cent rounding and locale-dependent output in explicitly Australian currency labels.
- **Android:** the Work Task reader omitted historical resources and parent hectares, and effective labour filtering could discard a saved line total with no hourly rate. Task detail used the primary block rather than full linked area. Fuel-only completeness was incorrectly rejected; saved allocation/report metadata and parent/marker boundaries were not consistently applied. The existing report re-estimated Trips even when saved allocations existed and divided by repeated treated area. The half-cent regression was separately reproduced at `9.995 -> 9.99` before its Decimal correction.
- **Separate Android regression findings:** five existing completion tests fail in the broader selection. Source inspection confirms date-only parsing takes the first ten timestamp characters without applying the supplied zone. Final XML shows three calendar-day assertion failures, loss of completedBy/completedAt in a restart-overlay comparison, and an empty updates list where the old duplicate-create test expects a PATCH (accepted conflict-preserving replay no longer performs that PATCH). These are observed boundaries, not a fully diagnosed completion repair. The completion/replay files and tests are unchanged from the starting baseline. They were NOT executed against a rebuilt baseline in this pass, so unchanged source is not labelled a failing-before experiment for these five cases. No completion/sync rewrite or weakened assertion was made to obtain a green gate.

### B. Exact file inventory and validated source identity

Starting managed HEAD: `c0e461ec986e7ee105ad39be6e1e4284fd115d12`. Final managed save SHA is assigned after the turn; do not substitute the starting HEAD for it. The 23 changed application/test/runner paths, sorted and hashed as `path + NUL + lowercase SHA-256(file bytes) + NUL`, have manifest SHA-256 **`030e4b3c740a149d64b6d0297128e10943f4da094a3d7a48291783fbc4f2f506`**. This includes the five new files and does not depend on Git's staging state.

Android production:
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/CostReportBuilder.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PruningActivityTaskLink.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/CostingReadAuthority.kt` (new)
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/Models.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/PieceRateCosting.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/WorkTaskCostRollup.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/CostReportsScreen.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/WorkTasksScreen.kt`

Android validation:
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/MobileCostingParityTest.kt` (new)
- `android-vinetrack/costing-tests.init.gradle` (new)

iOS production:
- `ios/VineTrack/Backend/Models/BackendOperations.swift`
- `ios/VineTrack/Backend/Models/BackendPaddock.swift`
- `ios/VineTrack/LegacyImported/Models/CostingReadAuthority.swift` (new)
- `ios/VineTrack/LegacyImported/Models/Paddock.swift`
- `ios/VineTrack/LegacyImported/Models/PieceRateCosting.swift`
- `ios/VineTrack/LegacyImported/Models/PruningWorkTaskLink.swift`
- `ios/VineTrack/LegacyImported/Models/TripCostAllocation.swift`
- `ios/VineTrack/LegacyImported/Models/WorkTaskCostRollup.swift`
- `ios/VineTrack/LegacyImported/Models/WorkTaskLabourCosting.swift`
- `ios/VineTrack/LegacyImported/Models/WorkTaskLabourLine.swift`
- `ios/VineTrack/LegacyImported/Views/CostReports/CostReportsView.swift`
- `ios/VineTrack/LegacyImported/Views/Tasks/AddEditWorkTaskView.swift`

iOS validation:
- `ios/VineTrackTests/MobileCostingParityTests.swift` (new)

Existing acceptance records updated:
- `.rork/plans/android-live-trip-safe-automatic-complet_1791964262830.plan.md`
- `docs/reviews/final-mobile-acceptance-legacy-save-recovery-2026-10-15.md`

Managed history changes already present at entry were left to Rork: `.rork/history/main/00mvhzhznt000_w90k30g3ec68z9ovelnt6_assistant.json`, `.rork/history/main/00mvjc67kc000_pr7rz4q2pbrcrxawq8ym5_assistant.json`, `.rork/history/main/00mvkak1vy001_2kf14qm9r9jttryan5cji_assistant.json`. No agent edits, deletion, exclusion or reset of history or linked repositories.

### C. Final costing authority

**Work Task total = effective labour + saved manual machine charge/fuel + saved linked GPS allocations + frozen materials, each once.** Material visibility continues to use the existing explicit gate.

1. Piece-rate task: saved vine quantity × agreed saved rate, rounded using decimal half-away-from-zero cents; hourly/inline labour never added.
2. Other task: canonical saved labour lines; saved generated hours/cost win, including a cost without a rate. If no saved total exists, use that line's stored inputs, never today's catalogue rate. A live unrated canonical line blocks the inline-resource fallback.
3. Only with no live canonical lines: historical inline resources × saved duration. Task maps, represented pruning helpers and the active single-activity labour reader route through that task-aware resolution. Activity-owned and represented task labour are not summed together; existing activity ownership rules remain otherwise unchanged.
4. Manual machine charge and fuel are independent saved components. Missing machine charge is optional only without a configured hourly charge; missing fuel cost is optional only without positive fuel quantity. A configured unresolved component or a line without either saved amount remains incomplete.
5. Linked allocation IDs are deduplicated, scoped through a live same-vineyard parent, and the saved Trip labour marker is reconciled into slices rather than added twice. No allocation evidence is rewritten. Missing/partial/unavailable saved totals keep completeness false.
6. Frozen material costing and write DTOs are unchanged; current material library prices do not reprice task lines. iOS saved labour totals survive local encode/decode and unchanged assignments; actual count/hour/rate edits invalidate only the corresponding local derived snapshot.

Existing Cost Reports stay **Trip allocation** reports, not the full Portal/Work Task total. Both display that scope. Android prefers saved allocations; its pre-existing estimator fallback remains only for Trips with no saved live allocation and is explicitly labelled `Estimated Trip cost: no saved allocation`. Such estimated/warned rows do not produce an authoritative area/tonne ratio. iOS estimates may explain unresolved rows, but cannot replace a saved total or saved chemical charge; NULL saved totals remain NULL/incomplete. No new reports, tabs, charts or previously absent Cost/ha UI were added.

### D. Area authority

- Positive finite saved parent task hectares first; otherwise the complete set of saved linked-block hectares; otherwise the physical area of ALL linked blocks, optional saved physical hectares first and existing mapped polygon area second. A legacy task with no links may use its sole primary block. An incomplete linked set never falls back to only its primary block or a partial sum.
- Physical vineyard area is the unique live block total once, regardless of repeat operations. A selected block uses that block's physical area. Cumulative Treated Area remains a separate operation-based metric; it is not the season Cost/ha denominator.
- Missing/invalid physical hectares or incomplete costs suppress the ratio. The iOS editor does not produce a second task-wide block ratio where saved parent and link area sums disagree; it preserves both evidence values rather than inventing replacement hectares.
- Geometry uses the existing identical equirectangular/shoelace formula on both platforms, also documented in the existing read-only `sql/095_admin_hectares_under_management.sql` helper. No SQL was changed or executed. Existing schema has no required stored paddock-area column: optional `area_ha` decoding is tolerant of its absence; normal mapped blocks fall back to their existing geometry.
- No geometry fallback is written back as historical task/link area. Retained link hectares, including NULL, are not refreshed on editor save; the saved parent area is not silently backfilled. Explicit new block selection still uses the existing planning workflow, not a historical data repair.

### E. Stockmans Ridge Vintage 2027 reconciliation — owner-supplied fixture

These are source/unit fixtures, NOT a production query or a reconstructed set of 28 task rows.

- Supplied population: **28 Work Tasks**, **543.50 labour hours**, labour **$18,937.00**, machine/fuel **$20.79**, total **$18,957.79**.
- Physical vineyard hectares **6.14908359375**, giving approximately **$3,083.03/ha**. Supplied cumulative Treated Area approximately **37.27ha** is distinct and never substituted as the denominator.
- Function reconciliation: Pruning **$10,678** + Shoot thinning **$4,585** + Removing Guards **$3,465** + Wire Lifting **$133** + Mulching **$96.79** = **$18,957.79**. The fixture asserts function labour including Mulching labour76 sums to18,937, then adds saved fuel20.79 once.
- Shoot thinning: **5.656098046875ha -> $810.63/ha**, not primary Pinot1.804291796875ha/~$2,541.16/ha.
- Removing Guards: **1.32124375ha -> $2,622.53/ha**, not primary Sauvignon Blanc0.414428125ha/~$8,360.92/ha.
- Mulching: **6.14908359375ha -> $15.74/ha**, not primary Cabernet Franc0.491110546875ha/~$197.08/ha. Saved2h machinery,13.6L/$20.79 fuel, NULL hourly machine rate/NULL machine total, plus$76 labour yields **$96.79 and complete**.
- Shiraz physical area **1.075619921875ha**: supplied28/29August$700 with NULL parent/link area resolves at read time to approximately **$650.79/ha**; supplied30August saved same area/$315 gives **$292.85/ha**. No NULL hectare evidence is backfilled.

### F. Legacy compatibility

- Equivalent suites assert **10h ×14 people ×$36 = $5,040**, and140person-hours, only when canonical lines are absent; canonical unrated lines do not unlock legacy substitution. Piece-rate snapshots exclude both canonical hourly and inline costs. Decode/local round-trip and saved-hour/saved-cost precedence are covered.
- Owner estimate of30 active legacy-only tasks/$44,218 remains **unverified production population**, not an executed database reconciliation. No legacy migration, historical rate replacement, task rewrite or catalogue lookup was performed.
- All new persistence/read fields are optional/defaulted. Work Task, Paddock, labour and allocation remote write contracts remain unchanged. No schema/RLS/permissions/authentication change, operational Trip/Spray/sync architecture change, pin/Program change, Target Nutrient work, dependency/signing/version edit or data reset.

### G. Deleted Trips

- Supplied retained allocations for `1423c592-a4ee-4b9e-ab58-30edc7101b8d` (**$0.43**) and `a373b464-4b5f-4e45-82d1-7d8e6213aad4` (**$0.39**) remain immutable fixture inputs; neither contributes to active totals or Trip counts without a live same-vineyard parent. Allocation tombstones are also excluded. Trip count is distinct parent IDs, not allocation row count.
- Android covers explicit deleted and missing parents. iOS has no local Trip.deletedAt property: existing sync consumes tombstones/removes local Trips, so missing-parent exclusion is used. Existing tombstone/sync storage behaviour is deliberately unchanged; the pure reader does not delete inputs. This is not a claim that the existing sync retains tombstoned rows locally or that the two production rows were queried/repaired.

### H. Native regression and build evidence

**Failure history retained, not replaced by a final green costing label:**

- Minimal pre-fix fuel-only regression: iOS **0 passed /1 failed** (`mulchingFuelOnlyIsComplete()`), correct96.79 but false completeness; Android **1 executed /0 passed /1 failed** for its twin. An initial foreground Android command timed out before tests; the subsequent background run obtained the genuine assertion failure.
- iOS first complete new-suite compile attempt: **0 executed**, missing material unit, ambiguous test expression and helper isolation diagnostic corrected. Next **19 passed /1 failed** at exact70.79 versus70.78999999999999; correction converts each saved component to Decimal before summing. Next focused new suite **20 passed**,51s. Android focused new suite **20 passed /0 failed /0 errors /0 skipped**, build4m38s.
- Android first broader9-suite run: **171 executed /166 passed /5 failed /0 errors /0 skipped**,28s. All152 non-completion tests passed; completion14/19. After final-review reader corrections and adding existing Trip/pruning suites: **224 executed /219 passed /5 failed /0 errors /0 skipped**,3m45s, same completion failures. These runs precede the final decimal rounding correction; they are not reused as final-source validation.
- iOS broader15-selector run: **213 executed /208 passed /5 failed**. Four failures were locale-dependent Australian currency text; one was existing `9.995` half-cent rounding. Corrected the costing helper (no test expectation changes): explicit Australian format plus Decimal arithmetic. Narrow rerun of those five cases plus the equivalent piece-rate parity case: **6 passed**,71s. Final same15-selector selection: **213 passed /0 reported failures**,27s. Successful runner reports aggregate counts only, not per-suite discovery/skips.
- Final iOS selection: `VineTrackTests/` MobileCostingParityTests, WorkTaskLabourCostingTests, WorkTaskMachineCostingTests, WorkTaskMaterialCostsTests, PieceRateCostingTests, EffectiveLabourCostTests, PruningWorkTaskCostingCreateTests, WorkTaskCompletionTests, PruningWorkTaskRepairTests, PruningActivityLabourLineTests, PruningActivityWorkTaskLinkTests, PruningActivityReportTests; `VineTrackTripTests/` WorkerTypeDecodingTests, TripLabourCostContractTests, WorkTaskLabourCostingTests. Final new parity suite remains20 cases within this selection.
- Android half-cent failing-before: focused `MobileCostingParityTest.pieceRateExcludesHourlyAndLegacy` **1 executed /0 passed /1 failed**, expected10.0 versus9.99 at9.995. Corrected both money rounding and vine-quantity multiplication using decimal HALF_UP, with equivalent positive/negative half-cent and3×0.335 assertions.
- **Final Android source run: 13 suites,224 executed /219 passed /5 failed /0 errors /0 skipped; Gradle3m43s, exit1.** New MobileCostingParityTest is **20/20**, including final decimal assertions; all205 non-completion cases pass. Completion remains14/19. Final XML suite counts (all zero failures except completion): EffectiveLabourCostTest20; MobileCostingParityTest20; PieceRateCostingTest19; PruningActivityLabourLineTest19; PruningActivityWorkTaskLinkTest15; PruningWorkTaskCostingCreateTest17; PruningWorkTaskRepairTest9; WorkTaskCompletionTest19 (5 failed); WorkTaskCostRollupTest6; WorkTaskLabourCostingTest24; WorkTaskMachineCostingTest18; WorkerTypeIntegrityTest10; material.WorkTaskMaterialCostsTest28. All are under com.rork.vinetrack.data. Evidence: /tmp/vinetrack-costing-final-v2.log and final TEST-*.xml in android-vinetrack/app/build/test-results/testDebugUnitTest/; this is source/unit evidence, not a handset log. Final completion day assertions are expected2026-10-05/actual2026-10-04, expected2026-09-30/actual2026-09-29, and expected2026-10-04/actual2026-10-05; restart comparison loses completedBy/completedAt; duplicate replay observes an empty updates list. Earlier failure details are historical, not substituted for this run.
- Final Android `runChecks`: **PASS, build succeeded** after the final test process exited. Two unrelated existing asset-address advisories remain unchanged. A passing build does not turn the five-failure broader unit gate green or establish handset launch.
- Final iOS `runChecks`: **PASS, simulator build**. Device build is unverified. Two pre-existing asset-address advisories were left unchanged as unrelated; they do not block checks. No release/export/upload or physical launch was performed.

Five Android completion failures retained explicitly: `Sydney Work Date selection round trips the UTC picker calendar day`; `new local midnight Work Date resolves through vineyard timezone`; `customer A B C keeps work date and separate audit`; `offline update survives restart overlay full refresh and replay with original audit`; `duplicate pending create patches folded completion before acknowledgement`. Do not label the broader Android regression gate green.

Validation commands: iOS managed `swiftTest` with the selectors above; Android `./gradlew :app:testDebugUnitTest --init-script costing-tests.init.gradle --console=plain '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC'`. `-PcostingFocusedOnly` narrows compilation to the20 new cases; `--tests` narrowed the actual failing-before test. Both use existing native test infrastructure; no dependencies or test targets were added. Android logs/results are local temporary build evidence, not runtime handset logs.

### I. Preservation and remaining acceptance

- Source checks: scoped `git diff HEAD --check` PASS; no changes to SQL/Supabase, app project/Gradle/version/signing/dependency configuration or linked-reference state. Versions remain **3.1.8, iOS139, Android12**. Existing chemical calculators, pin evidence, Programs, sync concurrency/storage, help/presentation changes and Target Nutrient source are preserved apart from the expressly scoped existing costing report reader changes listed above.
- Unit/source acceptance is not production-data reconciliation, mobile screen acceptance or device performance. Reopen representative existing records on iPhone and Android; compare full task totals, saved/legacy labour, multi-block/NULL hectares, fuel-only completeness, frozen materials, marker/slices, distinct Trips, deleted-parent exclusions and Trip-report scope. Confirm unchanged evidence after reopening/sync; do not save to manufacture a match.
- The earlier owner report that Android will not open remains **unresolved**. No connected handset or runtime logs were available, no actual crash/ANR was captured or diagnosed, and no simulator operation/handset reset/install was used for this costing work. Passing compilation/unit tests do not establish launch or responsiveness. Obtain the affected device's sanitised fatal/ANR evidence and compatible owner-controlled in-place delivery separately.
- No App Store/TestFlight/Play release, signed delivery candidate, backend deployment, production query, upload, distribution, migration, reinstall, storage clear or queue reset was performed or claimed. Preserve the historical candidate/signing blockers and physical acceptance checklist below.

## Android controlled-testing handoff — 23 October 2026

**Accepted source VERIFIED; owner-upload candidate NOT READY (`blocked_missing_typed_operation` / signing evidence unavailable).** The latest approval permits Android build-only test-candidate preparation, not agent upload, distribution or general release. Application logic, versions, dependencies and signing configuration remain frozen. No backend, SQL/Supabase, Portal or iOS changes; Target Nutrient remains CLOSED.

### Accepted source and retained validation

- Accepted commit `019735ad043815c4082a3ee1ad496de0192abb74` is available locally; its recorded parent is `b4f4d24babfa3929418742854e7ed1af0c7477cb`. This supersedes the earlier missing-commit limitation for verifying the newly accepted repair; it does not claim the older parent was separately inspected.
- Current managed HEAD `3fc42be3ac20343f8ac597ecf8e7bc73cdda85e0` and the accepted commit have the identical Android tree `bad9b1081a40e6671e9616157686065a5a390491`. Scoped commit diff is empty, including all Android production files, test sources, runner, version/dependency/signing configuration. No Android working-tree changes.
- Recomputed 1152-file Android manifest remains `aa0965778d1413c59a739446dde45feabcd683cceb8c275c3abf204c8ab58744`. Current final test XML still reports **12 suites / 116 tests / 0 failures / 0 errors / 0 skipped**. Retained final log and final-116 XML directory also remain present in this session. Existing final Android runChecks PASS applies to this unchanged source; no unnecessary unchanged suite/build rerun. Unit tests validate the source; they are not claimed to be packaged or executed inside a release candidate.
- Whole-workspace commits differ in managed/reference state; Android equivalence is verified, not whole-workspace identity. Managed history and previous help/iOS/linked-repository work remain untouched.

### Managed candidate inspection and exact blocker

- `setupGooglePlay` reports connected; `ensurePlayAppRecord` reports `ok`, package `com.rork.vinetrack`, `created:false`. These establish reported connection/package access only, not signing or version readiness.
- `listPublishablePlayBuilds(android-vinetrack)` returned 20 completed rows. Latest listed run: `5d3cdb28-4ecf-4885-8fd2-ff5c6344e1a2`, snapshot `w90k30g3ec68z9ovelnt6`, opaque source hash `src_bc2b045cb71b33f7b`, framework `kotlin`, package `com.rork.vinetrack`. This is an inspected existing build, **not a verified current-source test candidate**. No mapping of that opaque pair to the accepted Android tree was returned.
- `getPlayAabBuildStatus` for that run returned `status:completed` and only `apkKey:kotlin-builds/t1ycqwwwkgzt982ur27ya/art_b75c4798a55a2a3ee/app.apk`. It did not return a downloadable signed AAB, artifact checksum, actual version code or certificate fingerprint. A storage key is not a downloadable artifact URL; no URL was invented and no APK was relabelled an AAB.
- The supported build-only `generatePlayAab` operation requires authoritative current `snapshotId` and `sourceHash`; those current-source values/mapping are not exposed by the available inspection results. Do not supply an older listed pair, a Git SHA or the Android manifest in their place. No new generation was started with guessed identity. No publishing/validation upload was used to discover metadata.
- Source configuration still says **3.1.8 / code12**; this is not proof that code12 is available for a new Play upload. Highest previously used Play code, expected upload certificate, Play App Signing certificate/lineage and the affected installed app's update compatibility remain unverified. Local release configuration uses debug signing and is not a safe substitute for the managed Play route.
- Required handoff: expose the current-source build selection/export in the normal Rork Publish/build UI, linked to the accepted Android tree; generate/download the signed AAB without uploading; record run/snapshot/source identity, bytes, SHA-256, actual package/version/code and upload certificate. Owner verifies unused code against all Play uploads, intended existing test track and upload/App Signing/installed compatibility using non-secret Console evidence. Resolve any required metadata adjustment by explicit approval, not a guessed bump. Until these checks pass, **no upload-ready artifact and no safe in-place install instruction is claimed**. Owner alone handles any later upload; no production rollout authorised.

### Affected-device acceptance checklist — owner-operated, pending compatible candidate

1. **Before updating:** while safely stopped, record installed version/code, device/Android version, time/timezone and current Home/Sync Status counts/status/reasons. Keep originals and any existing authorised private evidence copies; do not export private data into chat. Note existing records/photos, original pending CREATE UUID, held delete, completed-trip status and locally available GPS evidence/count. A screenshot is a reference, not a complete storage backup. Do not log out, uninstall/reinstall, clear storage, reset queues or delete evidence.
2. **Update gate:** use only a verified compatible in-place update through the intended existing Play test route after owner approval/upload. If signature/version compatibility is uncertain or update fails, stop—never uninstall to bypass it. Record installed candidate version/code and source-bound build identity. Confirm original records/photos/queues/evidence remain intact before further sync actions.
3. **Lifecycle/reconnect:** observe normal launch, background/foreground and a few normal reconnects while safely stopped, without force-stop or destructive fault injection. Home and Sync Status should remain responsive. Record each actual result; build/unit success does not prove this.
4. **Retry All:** after recording the original queue state, owner invokes the ordinary Retry All action once when ready for its legitimate writes. Observe responsive UI, independent eligible work and the indication ending only when work actually completes. Compare resulting statuses/attempts and genuine server receipts; do not force repeated replays to manufacture success.
5. **Held versus independent work:** an old unresolved delete must not block unrelated authorised preserved work. Any delete acknowledgement requires exact account/ID/tombstone, dependency and retained-original evidence checks; absence alone is not success. Pending CREATE must retain its original UUID/payload and produce no duplicate. Do not replace its ID.
6. **Completed GPS:** completed-trip status and original ordered GPS must remain unchanged. The supplied 4,584-point server count is not acknowledgement authority. The missing-original-owned-evidence marker must remain held unless the original owned evidence is genuinely recovered and verified. Do not reconstruct, overwrite or clear it to pass.
7. **Stop conditions:** crash/ANR, missing evidence, changed completed-trip state, duplicate CREATE or unexplained record/photo/queue loss means stop acceptance and preserve evidence. No general-release PASS until actual device outcomes are reviewed.

### Fatal / ANR evidence route — no crash captured here

- Fresh `adb devices -l` lists no attached device. `rork-agent logs runtime --errors --limit 30` returns no runtime logs. No reproduction, fatal exception, ANR, source line or observed failing sync stage is available; physical acceptance and actual crash diagnosis remain UNVERIFIED.
- On the owner's authorised computer with the affected phone connected, retain the original local Logcat output **without clearing logs**. Immediately after a crash, `adb logcat -b crash -v threadtime -d > vinetrack-crash-private.txt` reads the retained crash buffer; an empty buffer does not prove no failure. If multiple devices are connected, explicitly select the affected serial with `adb -s <serial>` and keep that serial private.
- For an ANR or missing crash-buffer details, capture `adb logcat -b main -b system -b crash -v threadtime -d > vinetrack-runtime-private.txt` locally or use Android Studio Logcat for `com.rork.vinetrack`. Owner may retrieve the matching Android vitals/ANR trace in Play Console when available. Full Logcat, bug reports and vitals traces may contain private data: retain originals securely, never post raw files publicly or into chat. No `logcat -c`, force-stop, queue reset or diagnostic storage deletion.
- Share only a manually reviewed redacted excerpt: timestamp/timezone, candidate version/code/run identity, device/Android version, exception class and message with private values removed, `Caused by` chain and relevant `com.rork.vinetrack` stack frames with file/line. For ANR, include reason and relevant main-thread/blocking frames. Include the sync-stage label only if present in logs; otherwise record the last observed user action/stage as unverified context. Do not infer a source line or sync stage from timing alone.
- Remove tokens/credentials, URLs containing secrets, account/vineyard/record identifiers, payloads, coordinates/GPS, private paths and unrelated device/user logs from the shared excerpt. Keep original evidence untouched. A safe excerpt can support diagnosis without authorising any reset or backend correction.

## Android sync isolation / retained-evidence repair — 23 October 2026

**Focused automated gate PASS:116 tests,0 failures,0 errors,0 skipped across12 suites; final Android runChecks build PASS. Stop before release.** No physical-device crash or responsiveness acceptance is claimed. No install, reinstall, storage clear, real-queue reset, server mutation, SQL/Supabase/Portal change, iOS change, version/signing edit, store upload or distribution was performed. Target Nutrient remains CLOSED.

### Source, scope and evidence limits

- Starting managed HEAD: `d74db6320c0e6f79dc57491f2d6682cd3b2700c6`. The requested owner-reviewed commit `b4f4d24babfa3929418742854e7ed1af0c7477cb` could not be fetched (`upload-pack: not our ref`); source equivalence to that commit remains UNVERIFIED, not assumed.
- Validated Android tracked-plus-new-file manifest SHA-256: **`aa0965778d1413c59a739446dde45feabcd683cceb8c275c3abf204c8ab58744`**,1152 files. Construction: sort the unique `git ls-files -co --exclude-standard -- android-vinetrack` paths; for each regular file hash the concatenation of UTF-8 path, NUL, lowercase SHA-256 of its bytes, NUL. This includes new production/test/runner files; it excludes ignored build output. Final managed save SHA is assigned after this turn and is not claimed to equal the starting HEAD or unavailable reviewed commit.
- Scope is Android replay admission/concurrency, storage/evidence retention, exact pin identity/tombstone verification and decoded active-snapshot reuse. Preserve completed-trip state/GPS, original queue payload strings/UUIDs/attempts, snapshots, photos and ownership evidence. No GPS reconstruction or count-only/server-existence acknowledgement was introduced.
- No handset queue/snapshot, connected physical device, Logcat/vitals/ANR/tombstone crash signature or authenticated production replay was available. The repairs address source-demonstrated failure paths; they do not establish the actual handset crash cause or prove every replay/UI path on a device. Existing audit tests of intentionally unscoped low-level APIs remain audits, not proof of universal account safety.

### Implemented repair contract

- One finite-key runtime replay worker coalesces reconnect/foreground/Retry All storms, retaining at most one trailing intent per stage. Independent stages continue after ordinary exceptions; cancellation propagates. Retry indication ends at actual runner idle. Awaited push-then-fetch callers share completion without becoming fire-and-forget. Automatic legacy spray recovery is awaited within its stage; explicit user actions retain their existing callback/receipt semantics.
- Stage admission captures account incarnation, rechecks after retained-claim recovery and preservation, and publishes stage failures only to that incarnation. Phase5 now checks account/selection/cancellation between suspended coordinators and before publication; occurrence replay checks scope between trips. Diagnostics added by this repair contain only stage, exception class and version/build, not payloads/GPS/tokens.
- Selective preservation freezes exact original account-bound queue versions. Unknown/conflicting owners and failed-preservation vineyards remain held unchanged, while independent preserved operations may proceed. Dependency rows remain visible, and affected photos receive no replay/cleanup permit. Strict older preservation callers retain their stop-on-unknown behavior.
- Interrupted outbox claims recover in one durable startup mutation, retaining original identity, payload and attempts with entity-correct diagnostics. Thrown/false terminal saves retain the live claim. Same-process recovery retries the already-computed BLOCKED/FAILED outcome verbatim, including attempt increment/cap/reason; failed success/removal acknowledgements become verification retries without invented attempts. Suspended live transports are never reclaimed. A terminal outcome that could not be durably stored is not represented as durable across process death.
- Unreadable initial outbox storage is explicitly held, not silently treated as an empty mutable queue. Mutations stay paused until an exact readable reload succeeds; Sync Status displays an attention warning instead of “No pending items.” Strict decoding also holds newer unrecognised outbox fields before re-encoding.
- Capture evidence recovery reads primary plus AtomicFile base/backup/new sources without modifying them, merges only matching immutable observations, and distinguishes upload metadata. Torn/conflicting/unrecognised evidence holds the store with original sources retained. Failed preference commits cannot prove upload acknowledgement from their in-memory value. Existing fallback files are not truncated after a failed primary save. Per-observation upload/mark failures do not abort independent evidence; cancellation and account switches prevent subsequent upload/acknowledgement. Missing original capture owner stays held.
- Pin CREATE rejects absent/blank/mismatched original IDs before transport and retains original retry identity. BLOCKED delete reconciliation performs an account-bound exact-ID read including tombstones, requires an actual parseable deletion timestamp, exact payload/client ID, unresolved-dependency clearance, durable vineyard preservation and an immutable receipt containing the original queue row. Only then may the exact frozen row be retained as SYNCED. It does not issue another delete, infer success from absence, clear photos or unblock unrelated work. Cancellation is rechecked immediately after preservation.
- Active-trip decoded snapshots are reused only for identical freshly read raw bytes. Changed/corrupt/foreign bytes and ownership checks are re-evaluated. GPS replay work moves to IO and restores guarded callbacks to the caller context; existing exact ordered evidence and completed-trip safeguards remain in force.

### Supplied A/B/C records — facts not independently verified

- A: completed trip `a3d88bdb-a9a4-497d-9a5c-7d14166ddc04`,14 October2026, supplied4,584 server GPS points, BLOCKED0/8 for missing evidence/ownership. **Keep held unless original owned GPS evidence becomes available.** Count or completed-server existence cannot authorise acknowledgement, reconstruction, GPS overwrite or completion change.
- B: pin delete `de6db596-f48b-416e-8af3-6f15c44633ed`, BLOCKED2/8 for missing vineyard linkage; supplied tombstone1 October2026 01:36UTC. The new read-only reconciliation can acknowledge only after its own exact account/identity/tombstone/dependency/preservation checks. No live acknowledgement was executed here.
- C: pin create `e6f85a09-c6fe-4390-9740-018fac176d71`, FAILED0/8, supplied absent server row and incorrect Work Task interruption wording. Retry retains the original UUID/payload; diagnostic is now Pin-specific. No live insert or replacement UUID was created here.

### Actual validation chronology — do not sum overlapping runs

1. Genuine pre-repair production-class execution of `SyncCrashIsolationTest`: **5 executed,5 failed,0 errors/skips**, Gradle22s. Failures cover incorrect interrupted-Pin wording, escaping queue acknowledgement exception, mismatched CREATE identity reaching transport, swallowed cancellation and evidence-mark failure aborting independent evidence. Preserved pre-repair class JAR SHA-256: `9b819daa8dec39c94d31142e3f9b290d50dda5b6c18309fc85f58e7e9cef8a60`. This is a targeted failing-before regression result, not a handset crash reproduction or whole-app baseline pass.
2. Earlier baseline setup attempts executed zero tests: changing test sources encountered new production APIs; excluding compile/bundle tasks produced Kotlin friend-path provider errors. Baseline execution was corrected by allowing the production compile task to complete with `onlyIf { false }`, using the retained pre-repair classes. These setup failures are not baseline assertions.
3. Initial repair compilation failed in the duplicate-evidence-save return expression (`Boolean` versus `Unit`/nullable receiver). Parenthesised the return expression on one line; no test assertions executed in that attempt.
4. Intermediate repaired run: **109 executed,6 failed,0 errors/skips**. All six were `RetentionReviewTest` expectations of the old stranded-IN_PROGRESS defect:15-entity restart audit; process death before request, while suspended, after server acceptance and after acknowledgement-save failure; account switch during request. Updated these tests to verify recovered original fields/attempts, reject stale versions/account permits and actually replay/verify targets. Server-accepted cases require zero duplicate mutations; no authority/payload assertions were weakened for a green result.
5. A subsequent integration attempt compiled production but stopped at test compilation because new completion/authority API callers were edited while the earlier production compilation was running. Zero tests executed. Froze source before the next run; this is retained as a compile/setup failure, not a passing test result.
6. Final frozen-source command: `./gradlew :app:testDebugUnitTest --init-script sync-crash-tests.init.gradle --console=plain '-Dorg.gradle.jvmargs=-Xmx4096m -XX:+UseParallelGC'`. **BUILD SUCCESSFUL in3m42s;116 tests,0 failures,0 errors,0 skipped**, verified from final XML. No unchanged rerun after this success.
7. Final `runChecks(android-vinetrack)`: **PASS, Android build succeeded**. Existing unrelated direct-asset-address advisories in SprayManagementScreen/TripsScreen were not changed. No device installation or release follows from this build.

Final suite counts, each with0 failures/errors/skips:

- ActiveTripStoreTest1; BoundedReplayRunnerTest5; PinCaptureEvidenceContractTest4; PinCreateConflictTest5.
- RecoveryPermitSafetyTest2; RecoverySnapshotStoreTest19; ReplayVersionIntegrityTest19; RetentionReviewTest26.
- SelectiveRecoveryReplayTest4; SyncCrashIsolationTest5; SyncRecoveryStorageTest15; TripGpsRecoveryTest11.

New coverage includes10,000 duplicate triggers producing2 calls/peak concurrency1, shared completion and cancelled-owner completion, independent failure continuation, selective unknown/low-storage/dependency isolation, immutable AtomicFile sources/newer fields, failed BLOCKED/capped/retry-count outcomes, exact tombstone receipts and post-preservation cancellation, account-switch/missing-owner evidence holds, initial unreadable-outbox reload and unchanged/changed/corrupt snapshot reads. Storage/network failures are deterministic host seams; abrupt-process fixtures use synthetic file-backed data, not real handset storage.

### 4,584-point host benchmark

30 measured iterations after5 warmups;4,584 synthetic points,100 independent queued-record fixtures plus one held unknown delete. Timings include assertions and fake preservation admission, not network, Android disk durability, full sync, UI scheduling or handset performance. “Uncached reference” is an explicit decoder reference in the same final run, not a measured pre-repair app baseline.

- Verification plus selective admission: median **0.806338ms**,p95 **3.192446ms**,max **3.569454ms**.
- Uncached snapshot decode reference: median **7.621318ms**,p95 **15.081630ms**,max **18.471078ms**.
- Unchanged snapshot read/cache: median **0.113653ms**,p95 **0.469286ms**,max **0.492952ms**.
- Earlier109/6 run, retained separately: verification/admission1.089087/3.822461/3.935748ms; uncached reference11.305325/20.943440/24.530659ms; unchanged read0.431629/0.532093/0.592512ms (median/p95/max). Do not infer device speedups from host-run variation.

### Inventory, retained evidence and remaining gate

- Production base `android-vinetrack/app/src/main/java/com/rork/vinetrack/`: `data/ActiveTripStore.kt`, new `data/BoundedReplayRunner.kt`, `data/PendingWriteRepository.kt`, `data/PendingWriteStore.kt`, `data/PinCaptureEvidenceReplay.kt`, `data/PinCaptureEvidenceStore.kt`, `data/PinCreateSync.kt`, `data/PinDeleteSync.kt`, `data/PinRepository.kt`, `data/RecoveryPreservation.kt`, `data/RecoverySnapshotStore.kt`, `data/TripGpsSync.kt`, `ui/AppViewModel.kt`, `ui/screens/SyncStatusScreen.kt`.
- Test base `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/`: new `BoundedReplayRunnerTest.kt`, `SelectiveRecoveryReplayTest.kt`, `SyncCrashIsolationTest.kt`, `SyncRecoveryStorageTest.kt`; updated existing `RetentionReviewTest.kt`. Other selected suites unchanged. New focused runner: `android-vinetrack/sync-crash-tests.init.gradle`. No dependency/test-stack changes.
- Session-local evidence retained outside the managed project: `/tmp/vinetrack-sync-baseline-results.xml`, `/tmp/vinetrack-sync-baseline-completed.log`, `/tmp/vinetrack-pre-repair-classes.jar`, `/tmp/vinetrack-sync-final.log`, `/tmp/vinetrack-sync-final2.log`, `/tmp/vinetrack-sync-intermediate-109-results`, `/tmp/vinetrack-sync-final3.log`, `/tmp/vinetrack-sync-final4.log`, `/tmp/vinetrack-sync-final-116-results`. These temporary files are not promised as permanent downloadable artifacts; this report retains actual outcomes and identities.
- Scoped whitespace check PASS. Protected-path diff empty for iOS, scripts, SQL/Supabase, Android version/dependency/signing configuration. Retain3.1.8, iOS139 and Android12. Earlier help/iOS integrations, linked repos and managed history remain intact.
- **Remaining acceptance:** obtain the actual crash trace and authorised compatible in-place Android device/evidence route; preserve original queue/snapshot/photo/GPS records before any separately approved update. Observe foreground/reconnect/Retry All, storage failure recovery and responsive Home/Sync Status with representative existing data. A must remain held without owned evidence; verify B and C against authenticated server responses without forced replays or data resets. No physical PASS or release readiness is inferred from this host suite/build. Stop here before release/upload/distribution.

## PR #9 iOS work-task batching / Home observation integration — 21 October 2026

**Integrated on current source; requested five-suite native gate:72 passed,0 failures,157s. Final iOS simulator build PASS. Home interaction smoke checks and physical-iPhone scrolling acceptance remain NOT EXECUTED.** No merge/readiness transition, upload, distribution, SQL/Portal change or physical-device operation. Target Nutrient remains CLOSED.

### Provenance, inventory and source identity

- Authentic PR #9 implementation `3bb6b1fb4f3c68cb4f1239ad31aad6ad666446f6`, parent `8775e50187484fe285a19e0fe53bf0ba4150a871`, branch `fix/ios-sync-scroll-followup-20261021`. PR head ref verified; isolated supported linked checkout retained at `linked-repos/vinetrack-home-sync-review`; previous linked repositories remain intact.
- Managed pre-integration HEAD `57ade223df83b368a0732885c3bbd75eada23403`. All six touched production files matched upstream parent blob identities exactly before editing. All seven resulting production/test files match implementation commit blob identities exactly afterward. No blind tree replacement, rollback or unrelated adaptation.
- Exact source inventory: `ios/VineTrack/App/NewMainTabView.swift`; `ios/VineTrack/Backend/Sync/OperationsSyncServices.swift`; `ios/VineTrack/LegacyImported/Models/WorkTask.swift`; `ios/VineTrack/LegacyImported/Repositories/WorkTaskRepository.swift`; `ios/VineTrack/LegacyImported/Repositories/WorkTaskLabourLineRepository.swift`; `ios/VineTrack/LegacyImported/Services/MigratedDataStore+Operations.swift`; new `ios/VineTrackTests/WorkTaskBatchReconciliationTests.swift` (599 lines,15 tests). Source delta:7 files,1107 insertions/280 deletions. Additional changes only existing acceptance report/plan and linked-reference connection; managed history preserved.
- Validated application/test/script binary diff SHA-256 versus managed baseline: **`c864cb23274ab34a3575dc7af637a1ec6e5ac4be06098c4693640e6fa84f93e6`**. This includes the added test file. Final managed integration commit is assigned by the save after this turn; latest actual HEAD read during validation remains the pre-integration SHA above. **Final saved SHA is pending a post-save read, not claimed to be baseline or upstream SHA.**
- Protected chemical hashes unchanged: ManagementSyncServices `8ac255ed70536596f178403a95395b4bcb59da056d8a963326dd9643e2b9a88e`; SprayRepository `2d9b6af17d830e119eed1e89a66a6c66ebfafc3ad4741950f7deeeeb660c0037`; MigratedDataStore+Spray `ca54fa3b93957ed77d5812d2de2d9a14f3fa94385e3050ce31a6cc292282dfac`; SavedChemicalBatchReconciliationTests `2ec7d9840eba40f4edcf8cafd60099d3a964a13979c7326ad8f24b0530010c75`. Earlier saved-chemical65/65 remains historical, not a new PR #9 test run.
- Android, scripts, SQL/Supabase and iOS project metadata delta empty. Preserve3.1.8/build139/code12, newer pin evidence/reconciliation, Yield headings, original records/queues and all existing linked/history state. Scoped whitespace check PASS.

### Integrated contract

- Task headers and labour retain full-vineyard pulls and existing first-sync seed behavior. Validate cancellation, store/owner identity and vineyard response before reconciliation; recheck owner/cancellation after seed await.
- Read persisted collection once, retain corrupt evidence, apply mutations in original sequential order, preserve unrelated vineyard slices and local-only rows. Save changed full-value slice once before observable publication and marker acknowledgement. Unchanged collections avoid disk save and observable assignment; matching visible data still repairs stale/missing disk.
- Retain task timestamp ties/local completion authority, labour timestamp tie acceptance, edits made during fetch, duplicate/tombstone/reinsert order and historical costing/planning/version/completion fields. Batch acknowledgement preserves clearDirty/clearDeleted side effects and retries failed metadata persistence on the next unchanged pull.
- Extract setup, active-trip, overview and vintage summary into child observation boundaries. Retain section order, spacing, parent sheet binding, regional formatting and navigation destinations; retain existing performance-capture system and add scoped overview/summary/reconciliation measurements. No physical performance improvement claimed from source structure alone.

### Actual native validation

One `swiftTest(appPath:ios)` call selected only:

1. `VineTrackTests/WorkTaskBatchReconciliationTests`
2. `VineTrackTests/WorkTaskHeaderFullPullTests`
3. `VineTrackTests/WorkTaskCompletionTests`
4. `VineTrackTests/WorkTaskLabourCostingTests`
5. `VineTrackTests/PersistencePerformanceTests`

Runner result: **72 passed in157s**, no reported failures. No failed attempt, unchanged retry, corrective production/test edit or broader suite executed in this checkpoint. Runner exposes aggregate count only: no per-suite passing manifest, skipped metric or separate build timing available. Requested Debug simulator test build/execution succeeded. Subsequent `runChecks(ios)` **PASS — simulator build succeeded; device build not verified**. Two existing asset-address advisories in unrelated TripTypeChoiceSheet/UCRInfoSheet remain unchanged.

### Home smoke matrix — source reviewed, runtime evidence pending

No Home UI assertions/screenshots were executed in this checkpoint. Existing UI tests/launch fixtures target calculators, spray, offline actions and legacy recovery, not Home; an authenticated Home session was not established. No auth bypass, new fixture expansion, data reset, trip creation or unrequested suite was used to manufacture smoke evidence. These are **source checks only**, not a UI PASS:

- Order/spacing: retained header → conditional setup → conditional active trip → Today → permitted Quick Actions → overview → operations → management → vintage; outer spacing20 and existing inner padding/spacing preserved. Empty child conditional sections still require visual spacing confirmation in real rendering.
- Setup sheet: child binding sets parent showSetupWizard; unchanged parent presents SetupWizardView. Permission/enabled/incomplete-setup conditions retained. Opening/dismissing NOT EXECUTED.
- Vineyard details: overview NavigationLink still opens VineyardDetailsView. Tap/back NOT EXECUTED.
- Pins summary: vintage NavigationLink still opens PinsView(initialViewMode:.summary). Tap/back NOT EXECUTED.
- Active-trip navigation: conditional child still selects tab2 for an existing active trip. No active-trip availability established and no trip started. NOT EXECUTED.
- Vineyard switching: unchanged header menu uses store.selectVineyard with same-ID guard. New batch regression covers stale response publication after selection changes; that is not a UI switch verification. Multi-membership tap/switch NOT EXECUTED.

### Remaining acceptance / PR status

- Native build/unit gate is green. **Keep draft/readiness unchanged here**; no remote PR readiness operation performed and full requested Home smoke remains open. Owner may record actual72/0 result; do not imply this is physical-performance acceptance.
- Execute Home visual/interactions above through an authorised preview/owner session, without changing original data or manufacturing an active trip. Record actual screenshots/results and any unavailable active-trip/multi-vineyard case.
- Final performance gate is owner-observed responsive immediate Home scrolling **while Syncing on a physical iPhone**, repeat with unchanged cache and compare existing performance captures. Simulator compilation/unit measurements do not establish this. No physical iPhone/device-signed candidate access established; NOT EXECUTED/NOT ACCEPTED.
- Read actual final managed integration commit after save and append that exact SHA with source-equivalence verification. No merge, store upload, release, SQL/Portal work or Target Nutrient reopening authorised by this integration.

## Owner-upload testing-build handoff — 21 October 2026

**PARTIAL / BLOCKED: no upload-ready IPA or AAB produced. Nothing uploaded or released.** Do not treat the APK below, simulator app or an old managed AAB as the requested final artifacts.

### Frozen source and permitted metadata

- Requested application-logic baseline: `2ae36bd9c7c64a1ac87aeb884778fa7460e77d9a`. Current inspected managed HEAD: `ee1ea8d536192d369e9391c6629ccbce4cc825d2`. Full diff across iOS/Android/scripts contains only the previously approved3.1.7→3.1.8 version metadata and Android version comment. Direct production/test/runner comparison to baseline is empty. Retain3.1.8 for the intended candidates; an exact unmodified baseline would instead be3.1.7.
- No application, SQL, Portal, signing or build-number edit in this checkpoint. Existing managed history modifications preserved. Previous3.1.8 iOS simulator and Android build checks remain green; no unchanged tests/builds repeated. Only existing report/plan updated.

### iOS verified store evidence and export blocker

- `setupAsc(appPath:ios, requireAppleSession:false)` succeeded: team `8Y879855VK`, ASC app `6761143377`, bundle `app.rork.nt0v48tayl7v8noxcfe74`, matching source.
- Paginated all-state iOS lookup for3.1.8 returns existing **174**, VALID, build ID `0edfeea0-507d-4ab7-98eb-7d57aa3549ea`. No assertion that this store build contains the requested frozen source. Existing139 belongs to3.1.3;175 also exists historically under2.6.2. Therefore neither local139 nor a guessed175 is the final proposed new build number.
- Descending build-number lookup returns187 (historical2.6.3). Exact all-state/paginated188 lookup returns zero records. **188 is an observed unused uploaded-build candidate at this checkpoint, not reserved or built; recheck immediately before export/upload and account for in-flight uploads.** Local source remains139 because no export can proceed here.
- Existing active `VineTrack App Store` profile: ID `F8BLLA337M`, UUID `ede50cbf-c7fa-4529-a57e-233792760388`, bundle seed/team `8Y879855VK`, expires2027-04-30T10:29:46Z. Linked Apple Distribution certificate ID `P6K283KAMH`, serial `7E890D09A3ECE63E9E97C0AE4FF90758`, same expiration. These are Apple account records, NOT proof of an exported IPA signature or possession of its private key.
- Exact limitation: no local macOS/Xcode toolchain and no supported signed IPA export-only operation. Managed `submitBuild` uploads to Apple, so it was not called. Creating another certificate would not solve the export gap; no certificate/profile mutation or revocation attempted. API access is working; credential expiry was not demonstrated.
- **Owner action:** on an authorised Mac/export-only CI, obtain the frozen source plus the approved3.1.8 metadata (and normal secure build configuration), sign into team `8Y879855VK`, and ensure Keychain has the private key matching the existing valid Apple Distribution certificate or an owner-approved valid replacement. Use the existing matching App Store profile and required entitlements. Compare the installed app's application/team identifier and keychain/App Group entitlements before updating a data-bearing device. Set a freshly rechecked unused build number (188 is the current candidate), archive Release for generic iOS device, then choose an App Store Connect distribution workflow with **Export**, not Upload. If export is disabled, the account owner must grant the appropriate distribution signing access/role and supply signing through the secure Mac/CI credential mechanism; do not paste private keys into chat. Inspect the resulting IPA's bundle/version/build/team/profile/entitlements/signature, run `shasum -a 256 /path/to/VineTrack.ipa`, and retain the archive/dSYMs. No IPA location/hash currently exists.

### Android verified evidence and remaining gate

- `setupGooglePlay` reports connected; `ensurePlayAppRecord` succeeds for existing `com.rork.vinetrack`. `listPublishablePlayBuilds(android-vinetrack)` returns only older source builds; latest `b41cb33e-6232-4f13-8da4-b75207a8bf52`, source `src_e14325113de07dddc`, is NOT this candidate. No listed build supplies the required current version-code/signing/download evidence.
- The typed read surface does not expose highest-used code across drafts/inactive uploads, registered upload certificate, or Play App Signing certificate/rotation lineage. Current source code12 is not verified unused. Do not guess13 or use publishing validation as a no-upload check: that operation can upload a bundle even without committing a release.
- No authoritative current managed snapshotId/sourceHash pair was supplied for AAB generation; do not fabricate it from a Git commit, reuse an old snapshot, or replace managed signing with a local debug key. No AAB generation invoked and no final AAB path/hash exists.
- **Owner action:** from this existing app in Play Console, provide non-secret evidence of the highest version code including drafts/inactive uploads (App bundle explorer), and App integrity upload-key and app-signing SHA-256 fingerprints plus any key upgrade/rotation details. Confirm the data-bearing handset's installed package/version/signing origin. Then use the existing managed **build/download AAB only** export with current source identity and persistent registered upload key, or an authorised CI using that same registered key, with a verified unused code greater than installed/active codes. Do not use Publish/Internal rollout to obtain the file. Keep package `com.rork.vinetrack` and version3.1.8. Verify the AAB signature/certificate against App integrity, inspect manifest metadata, validate the bundle and record SHA-256 before calling it upload-ready.
- Existing correctness APK only, **not a Play AAB and not cleared for handset installation**: `android-vinetrack/app/build/outputs/apk/release/app-release.apk`,3.1.8/code12, SHA-256 `d85d2be58d6d9937d2cc4285b4641e10fc5e49ff13719db4e8ceeadcbf7c66e0`; APK signature v2 verifies. Observed upload certificate SHA-256 `241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3`, DN `CN=Rork Kotlin Play Upload, OU=Rork, O=Rork, L=San Francisco, ST=CA, C=US`. This is not authoritative Console comparison and not the handset's Play App Signing certificate.

### Owner upload instructions — only after final signed artifacts pass the gates

1. iOS: in Transporter on the Mac, sign in to the authorised App Store Connect account, add the verified exported IPA, and Deliver. Alternatively choose Upload from Xcode Organizer only when you are ready to upload yourself. Wait for processing under VineTrack → TestFlight; verify version/build, complete required export-compliance details, select only the intended internal testers. Do not submit for public App Review/release.
2. Android: in existing VineTrack Play Console → Testing → Internal testing → Create new release, upload the verified AAB, confirm package/version code and signing acceptance, add release notes, review and roll out **only Internal testing** when ready. Use the existing tester list/opt-in link; never promote to production. Play signs delivered APKs with the App Signing key, not necessarily the AAB upload key.
3. Before updating either device, capture existing app/version/signing origin, original trip/tank/pin IDs, raw GPS, pending queues and Sync Status; use the compatible store in-place Update. Do not uninstall, clear storage, log out of a pending-data session, reset sync, downgrade or replace the app with a differently signed APK. Source preservation alone cannot guarantee handset compatibility or data survival; stop if identity/entitlement checks fail.

### Real-device pin acceptance — not yet executed

- Record exact artifact hash/version/build/device/OS. At comparable positions in a verified aisle, capture **north Left, north Right, south Left, south Right**, both standalone and during a live trip. Rotate the phone opposite travel; qualified GPS movement, not compass or reverse-gear inference, must determine side.
- Test stationary/crawl, poor/stale GPS and insufficient observations: no unsupported snap. Include no-side Growth, manual map placement and manual row-only confirmation (no invented snapped coordinate).
- Per new controlled pin record actual UUID/evidence revision, raw coordinates/accuracy, tap/provider times, actual speed/course sample history, diagnostic compass, explicit side, block/driving aisle, physical vine row, snapped coordinate/distance or unresolved reason. Photograph actual rows; do not substitute fixture IDs/results.
- Save offline, safely relaunch/restart with queues intact, reconnect, inspect server confirmation, and refresh the same pin on both platforms. Existing natural stale queued create/content replay must not overwrite newer confirmed placement, including authoritative null/false; raw capture evidence and content must survive. Do not force a destructive replay or manufacture a PASS.
- Reconcile original records/queues/Sync Status afterward. Capture any demonstrated API discrepancy with pin/operation/request/response evidence for ChatGPT; no SQL/Portal/server repair here. Physical PASS remains open.

## Physical acceptance access checkpoint — 21 October 2026

**BLOCKED before installation; no physical acceptance performed.** Application logic remains frozen. No handset install, uninstall, storage clear, sync reset, server change, store upload or distribution performed.

- Current managed source HEAD inspected: `2ae36bd9c7c64a1ac87aeb884778fa7460e77d9a`; initial working tree clean. Recomputed application/test/script binary diff against `ecb36b0b62c69a5becd532066a87f178c49386b1` remains `eb88ef77f79b213e18937b79bb71d652d3dcc1115f09d56c54bce764d51207d8`, matching the validated integration. This identifies the source inspected before this documentation-only checkpoint, not the subsequent managed documentation save.
- Fresh `adb devices -l` returned an empty device list. No installed Android package/version/certificate/lineage could be read; in-place update compatibility remains unverified.
- Existing Android APK re-inspected: package `com.rork.vinetrack`, version3.1.7/code12;77,056,837bytes; modified2026-10-21T05:59:22Z; SHA-256 `6fe20fb13da0be143631acc14fe432def3606d0b518e08c9b930539f0df13324`. Signature v2 verifies; certificate SHA-256 `241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3`, DN `CN=Rork Kotlin Play Upload, OU=Rork, O=Rork, L=San Francisco, ST=CA, C=US`. Candidate exists, but is NOT cleared for a data-bearing handset update.
- Physical iPhone access is not established. Local `xcrun`, `devicectl` and `idevice_id` are unavailable. Reviewed supported publishing workflow still provides no no-upload signed-device IPA export route; `submitBuild` uploads and was not called. No current signed device IPA, provisioning/entitlement identity or installed application identity obtained. The preview cannot substitute for physical GPS acceptance.
- Existing green iOS60/0, Android66/0 and both build results are retained, not rerun on unchanged code. Only the existing report and plan are updated in this checkpoint; no code changes requiring a new build.
- All actual handset cases remain NOT EXECUTED: no physical pin UUIDs, provider/tap GPS history, compass/side/aisle/row/snap results or authenticated server request/response evidence collected. No demonstrated API discrepancy identified; server assumptions remain unverified, not accepted.
- Required handoff: an authorised physical-device access or owner-operated evidence route; Android installed package/version/certificate and any applicable signing lineage; iOS supported no-upload signed export/delivery with installed bundle/team/application identifier and compatible provisioning/entitlements. Verify compatibility and preserve original IDs/GPS/queues/Sync Status before any update. Stop rather than uninstall/reset data. Then execute the retained physical matrix below and report actual evidence.

## PR #6 mobile pin capture integration — 21 October 2026

**Current-source integration implemented; final iOS focused gate60/0, Android66/0/0/0, and both builds PASS. Physical acceptance NOT EXECUTED; no deployment/upload/distribution/handset operation.** Target Nutrient remains CLOSED. Supabase belongs to ChatGPT; no SQL, Edge Function, Portal or historical pin correction performed.

### Provenance and preservation

- Authentic source: PR #6 `fix/pin-capture-travel-direction-ios-android`, HEAD `3f8bcdc45fcc14ff2bba66424b5494f0ff051a94`; reviewed main `8775e50187484fe285a19e0fe53bf0ba4150a871`, merge-base `50aa0f19e7440602765017a3844689c7ff478489`. Linked reference retained at `linked-repos/vinetrack-pin-review`. Original patch:8 files,217 insertions/44 deletions; adapted to newer source, not a blind branch merge or byte-identical import.
- Managed baseline `ecb36b0b62c69a5becd532066a87f178c49386b1` (PR #8). Final application/test/script binary diff SHA-256 against that baseline: **`eb88ef77f79b213e18937b79bb71d652d3dcc1115f09d56c54bce764d51207d8`**. Final managed save commit not yet assigned; do not describe the baseline or PR HEAD as the resulting integration commit.
- Preserve newer Yield Estimate headings and chemical batching/test closeout. Recomputed four protected chemical hashes equal the original `8ac255ed…`, `2d9b6af1…`, `ca54fa3b…`, `2ec7d984…` values recorded below. No app version/project/signing configuration diff, no SQL/Supabase diff; no tracking/completion/tank algorithms or closed nutrient edits. Existing `.rork/history` changes and linked repositories retained.

### Implemented contract

- Each capture freezes original GPS and accuracy, provider observation time and tap time, one pin ID/evidence revision, vineyard/block/trip, actual bounded provider history, actual available diagnostic compass/source/time, aisle evidence and capture-time geometry identity. A delayed picker/photo/retry does not substitute later GPS or geometry. Side-free Growth Stage no longer fabricates Right or nearest-row attachment; the legacy Growth picker now freezes at its initiating tap.
- Automatic direction is **qualified GPS movement**, never handset compass. At least3 distinct observations, each speed≥1m/s and accuracy0–5m, valid course/coordinates, in the15s before tap; latest observation qualifies and is≤5s old, span≥1s, displacement≥5m, circular deviation≤25°, displacement/course disagreement≤30°. Android additionally checks monotonic freshness and both clock identities. A latest observed stop cannot reuse earlier moving samples. These are movement-relative sides, not proven tractor facing/reverse gear.
- Snap requires mapped/verified aisle, qualified movement and explicit Left/Right; projected coordinate remains on the actual selected vine row, not aisle centreline. Raw GPS is stored separately. Missing evidence remains unresolved with provenance/reason. Manual map/row workflows preserved; row-only confirmation does not claim snapped coordinates. iOS live-lock evidence reports supporting count0 where the actual count is unavailable, never invented3; the server must assess actual observations rather than trust this advisory lock.
- Evidence same-ID/revision retry rejects changed capture data; identical retry ignores only delivery acknowledgement. iOS precise-v3 storage wraps exact-date JSON as opaque data within existing persistence, preserves subsecond provider/tap times through restart, reads legacy-v2 records without pretending to recover lost precision, and leaves shared persistence/chemical storage untouched. Android retains existing account-bound durable evidence store and delivery semantics.
- iOS CREATE uses conflict-ignore insert, followed by content-only PATCH with no raw/capture/derived-location or confirmation-version fields. Normal delta reconciliation merges newer location authority independently of offline notes/status and protects a newer local confirmation. Android existing insert/409 account-bound create proof remains unchanged; replay and pending CREATE display/cache merge now use confirmation revision then sync version. Confirmed null/false clears stale snap values; only unconfirmed legacy thin rows retain omitted placement fallback. Notes/photos survive; cross-vineyard identities cannot borrow location authority.
- iOS now performs per-pin content PATCH after insert-ignore; no network/performance acceptance or batching improvement is claimed for this path.

### Exact changed application/test/runner inventory

Paths below are relative to their stated base (not whole-file replacements from the old PR).

- iOS production, base `ios/VineTrack/`: `App/PinCaptureEvidence.swift`, `App/PinCaptureContext.swift`, `App/RepairsGrowthView.swift`, `App/RepairsActionView.swift`, `App/GrowthObservationActionView.swift`, `App/Insights/ScoutGrowthStageCoordinator.swift`, `App/PinDropConfirmationSheet.swift`.
- iOS production, same base: `Backend/Models/BackendPin.swift`, `Backend/Repositories/SupabasePinSyncRepository.swift`, `Backend/Sync/PinSyncService.swift`, `LegacyImported/Models/VinePin.swift`, `LegacyImported/Services/MigratedDataStore+Buttons.swift`, `LegacyImported/Services/TripTrackingService.swift`, `LegacyImported/Views/Buttons/QuickPinSheet.swift`, `LegacyImported/Views/Pins/PinDropView.swift`.
- iOS tests, base `ios/VineTrackTests/`: `PinOfflineCaptureDisplayTests.swift`, `PinAisleAttachmentTests.swift`, `InTripPinDuplicateTests.swift`. Existing `PinManualPlacementTests` and `PinRemoteMergeBatchTests` executed without edits.
- Android production, base `android-vinetrack/app/src/main/java/com/rork/vinetrack/`: `data/QualifiedLocationFix.kt`, `data/PinCaptureEvidenceStore.kt`, `data/PinRepository.kt`, `data/PinReplayMerge.kt`, `data/PendingPinReadOverlay.kt`, `data/model/Models.kt`, `ui/AppViewModel.kt`, `ui/screens/PinsScreen.kt`.
- Android new tests, base `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/`: `PinTravelDirectionTest.kt`, `PinConfirmationReplayTest.kt`. Existing aisle/evidence/coordinator/reconciliation suites executed without edits.
- New focused runners: `scripts/pin-capture-tests.init.gradle`, `scripts/run-pin-capture-validation.py` (host JVM source selection/log/XML summary, no install/upload). Existing docs updated: this report, `docs/core-pin-location-contract.md`, and approved plan `.rork/plans/android-live-trip-safe-automatic-complet_1791964262830.plan.md`. Authentic linked-repo connection adds its `.gitmodules`/submodule entry; existing history edits are not application changes.

### Actual validation and corrections (overlapping runs are NOT summed)

**iOS:** latest `swiftTest(ios)` selects `PinOfflineCaptureDisplayTests`, `PinAisleAttachmentTests`, `PinManualPlacementTests`, `PinRemoteMergeBatchTests`, `InTripPinDuplicateTests`: **60 passed,0 failed,22s**. Final `runChecks(ios)` PASS, simulator build only. Passing selection covers movement/physical-row side matrix, manual placement, exact evidence restart/retry, content-only payload keys, confirmed row-only clearing, independent location merge, batch persistence and duplicate safety. Skipped metric/separate test-build timing/individual passing manifest not exposed by runner.

Retained earlier results/failures:

1. Initial iOS build failed because `rowNumber` was immutable during authoritative location merge; changed only that property to mutable. Subsequent builds pass.
2. Initial two-suite selection50 passed/1 failed: stored-location screenshot fixture expected decimal dot while current locale formats comma. Corrected test expectation to `Locale.current.decimalSeparator`, production formatter unchanged; targeted test1/0,55s.
3. New immutable-restart targeted run first failed to compile optional side at the side-free Growth boundary (0 executed); corrected to explicit point-only attachment, no fake side. Then one executed test failed because ISO-8601 persistence lost `.125` seconds; scoped precise evidence storage correction passes targeted1/0,55s.
4. Five-suite gate59/1 exposed the old duplicate fixture having no device-owned active trip. Added production trip-provider wiring first (still0/1), then actual device ownership claim and active-trip assertion, preserving production identity guards. Targeted1/0,97s; subsequent five-suite60/0,25s.
5. Additional latest-stop assertion reproduced direction reuse (0/1) despite a stationary latest observation; helper now requires latest actual observation to qualify. Targeted1/0,52s; final five-suite60/0,22s above. No unchanged failing test was automatically rerun; no pre-integration baseline execution claimed. Existing unrelated concurrency warnings/asset-address advisories not changed.

**Android:** first four-suite gate50 passed/0 failures/errors/skips (5 travel+37 aisle+4 evidence+4 coordinator),3m48s. Four new confirmation/replay regressions each failed on the old merge/overlay behavior (4 executed/4 assertion failures,22s). Corrected complete confirmation authority/cross-vineyard identity and pending-create overlay; subsequent six-suite gate **66 passed/0 failures/errors/skips,3m39s** (the preceding50 plus4 confirmation+12 reconciliation).

Final tap-relative15s window regression attempt via foreground shell timed out at60s during Kotlin compilation; no executed-result claim for that attempt. Changed the demonstrated source discrepancy (window was measured from provider fix, potentially5s before tap), retained the assertion, and completed background six-suite final validation: **66 passed/0 failures/errors/skips,3m39s**, with XML counts **5 travel+37 aisle+4 evidence+4 coordinator+4 confirmation+12 reconciliation**. Final updated `runChecks(android-vinetrack)` **PASS**. Log `/tmp/vinetrack-pin-capture-validation.log` and XML under `app/build/test-results/testDebugUnitTest` inspected; temporary logs/build outputs are not committed. Host fixtures and serialized restarts are not real handset/GPS/OS-process/network acceptance. No Android instrumentation or simulator interaction was requested/executed in this checkpoint.

### Server API requirements / ownership handoff

No server/API deployment or authenticated HTTP acceptance performed. ChatGPT must verify existing server implementation against these mobile assumptions before physical approval:

- `insert_pin_capture_evidence(p_payload)` supports evidence before/after pin creation, stable `(pin_id,evidence_revision)` immutability/idempotence, returns `inserted`/`identical` (conflict stays unresolved). Top-level snake-case fields include raw/tap/provider times, accuracy, qualified heading/source/time, explicit `Left`/`Right` or no side, context, lock, geometry identity, supported placement and provenance. Observation keys remain `observedAt`, `latitude`, `longitude`, `horizontalAccuracyM`, `courseDegrees`, `speedMps`; diagnostics do not qualify travel.
- Independently validate ≥3 distinct bounded samples, speed≥1m/s, accuracy≤5m, displacement≥5m and consistent course/displacement against capture time. Verify actual mapped geometry, aisle and explicit side before physical-row snapping. Insufficient direction, side, aisle or geometry must stay unresolved with reason. Do not treat advisory iOS lock count0 as sufficient evidence or fill it with an invented count.
- `confirm_saved_pin_location_v2` retains stable operation ID and evidence revision, expected sync version, paddock/driving row/pin row/side and snapped point/distance parameters. It must reject stale/conflicting/unsupported automatic placement; manual row-only confirmation remains non-snap. Existing manual-row route was not replaced with fake snap evidence.
- Return `location_confirmation_revision` plus `sync_version` and complete derived placement in normal `pins` delta responses. Revisions must be monotonic authoritative placement versions; equal revision uses sync version to reject an older response. Intentional null/false must be returned as authoritative clearing, not omitted “thin confirmation” responses. Preserve original raw coordinates/capture identity and unrelated content.
- Database/RLS must enforce correct vineyard/account access, safe conflict-ignore CREATE and content-only updates, tombstones/deleted-pin protection, and server-side protection from older clients still sending full-row upserts. This mobile patch cannot guarantee writes from unmodified clients are blocked. No SQL migration or historical enrichment was run here.

### Physical candidate and acceptance gate — no distribution

- Metadata unchanged: iOS3.1.7/build139; Android `com.rork.vinetrack`3.1.7/code12. Neither number is asserted available/reserved for a new store upload. Do not guess the next code or replace an existing data-bearing install with a mismatched signer.
- iOS final correctness artifact is a simulator app, not a signed iPhone IPA. Current supported tools expose the managed publish/upload flow, but no no-upload signed-device export; no certificate/profile generation, TestFlight upload or unsupported workaround attempted. Need an approved supported compatible device-export/delivery route.
- Android managed correctness APK before the final tap-window change:77,056,837bytes, SHA-256 `a55ff8872d652d375b3c3e3618caa90d439a0ab623a6f7b7026bf4b803797381`; APK Signature v2 verifies, signer `CN=Rork Kotlin Play Upload`, certificate SHA-256 `241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3`. This is observed managed signing, not the older locally debug-signed candidate. Final updated managed `app/build/outputs/apk/release/app-release.apk`: **77,056,837bytes**, SHA-256 **`6fe20fb13da0be143631acc14fe432def3606d0b518e08c9b930539f0df13324`**, modified2026-10-21T05:59:22Z after final source correction/build. Manifest still3.1.7/code12; APK Signature v2 PASS, same observed `241548ef…` signer. The preceding `a55ff887…` binary is superseded and not the final candidate. Matching historical upload identity does NOT prove compatibility with a handset installed from Play (App Signing identity may differ); installed cert/lineage and version compatibility remain required. No install/uninstall/storage clear/store upload/distribution.
- Final scoped whitespace check PASS; application/test/script fingerprint remains `eb88ef77…`; SQL/Supabase/build metadata diff empty. No new build artifacts or temporary logs added to source control.
- All physical checks remain **NOT EXECUTED**. After separately approved safe in-place candidates: record original trip/tank/pin IDs, raw coordinates/provider/tap times, queues and Sync Status first; operate only new controlled test pins, never rewrite historical ones. Test north/south×Left/Right at comparable along-row position, standalone and live trip, rotating phone opposite travel, stationary/crawl/poor/stale GPS, no-side Growth, manual map and manual row-only. Confirm actual mapped vine-row coordinate, raw GPS unchanged, aisle/side/reason, ID/revision and compass diagnostic. Reopen/restart offline; reconnect to server confirmation; repeat old queued create/content replay and cross-platform refresh, retaining confirmations and original evidence. Real movement/sync legitimately adds records; no forced reset/replay or data clearing to obtain a PASS. Photograph actual rows and save pin IDs/screenshots/results; stop on safety-critical failure.

## iOS Saved Chemical test-only closeout — focused native gate GREEN — 21 October 2026

**Status: both authorised test mismatches corrected; two-test selection PASS; original four-suite selection PASS (65 passed, 0 failed); Debug simulator build PASS. Ready for the separately approved iPhone scrolling check, not physical performance acceptance or distribution.**

### Changes and preservation

- Only code file changed: `ios/VineTrackTests/ChemicalStoreConsolidationTests.swift`. Documentation changed: this acceptance report and the existing plan `.rork/plans/android-live-trip-safe-automatic-complet_1791964262830.plan.md`.
- `seedingIsDeterministic()`: test-local normalization replaces only `ChemicalManualActiveDraft.id`, `ChemicalManualRateDraft.id` (product-level and nested), and `ChemicalManualUseDraft.id` with deterministic traversal-order UUIDs. It maps every array without sorting, filtering or changing counts. Full session equality remains, with the nonempty-actives assertion retained. The fixture includes a product-level rate as well as a use and its nested rate, with count assertions. Changing active concentration from 750 to 640 must still produce inequality.
- Every other draft field is copied verbatim, including ambiguity flags and unresolved units. `originalRate` and `originalUse` are passed through intact: no IDs or evidence inside them are normalized. The session is copied before only its editable-row arrays are replaced, so seed/accepted evidence, existing persisted rate IDs, master identity, default selections/values and all other session metadata remain in complete equality. Test description/comments now describe deterministic form contents rather than freshly allocated row identities.
- `hracStaysDistinct()`: expected canonical Glyphosate code changed from `G` to `9`; `.hrac` scheme assertion remains. No classification, production UUID generation or production equality changes.
- Production app trees (`ios/VineTrack` and `android-vinetrack`) have no diff from the pre-correction HEAD. Newer Yield Estimate headings preserved. No performance patch reimported or reapplied; its four file hashes still match the original integration hashes recorded below. No tests skipped or production behavior loosened; no unrelated expansion.

### Actual validation, in requested order

1. `swiftTest(ios)` selecting only `VineTrackTests/ChemicalStoreConsolidationTests/seedingIsDeterministic()` and `VineTrackTests/ChemicalStoreConsolidationTests/hracStaysDistinct()`: **2 passed, 0 failed, runner duration 109s**.
2. One subsequent `swiftTest(ios)` selecting exactly `SavedChemicalBatchReconciliationTests`, `SavedChemicalReconciliationTests`, `ChemicalStoreConsolidationTests`, and `PersistencePerformanceTests` under `VineTrackTests`: **65 passed, 0 failed, runner duration 18s**. This is the requested four-suite gate, not a sum with the overlapping two-test run. No further test expansion or reruns.
3. Final `runChecks(ios)`: **PASS, simulator build succeeded**. Existing scheme TestAction is Debug; successful native test execution includes the Debug test build. Current runner responses do not expose separate build duration, skipped metric or individual passing-test manifest. Device/Release builds not verified. Existing unrelated asset-address advisories left untouched.

The `/tmp/rork-swift-test-ios.log` file was not refreshed by these successful tool calls: it still contains the earlier 63/2 run. It is historical evidence only, not a log for the new passes. New counts/durations above are the actual current `swiftTest` tool results. The original **65 executed / 63 passed / 2 failed** remains below unchanged as history. No pre-patch baseline was executed or claimed.

### Validated source identity and next gate

- Pre-correction managed HEAD: **`ee893f8ac0203644d59d2c7dc671378d12412abf`**, plus the test-only change above. Corrected test file Git blob **`782e3629`** (abbreviated); SHA-256 **`9874fed502bb9e03512a7926e5b8f745adfa33395cb3bcbaffb2514e12c22a91`**. This identifies the tested content, not a final managed commit.
- Owner reports GitHub main **`3097a0859c303f934cd84aef95965283313d4f22`** contains the exact original four-file batching implementation and that PR #7 now records integration/previous results. No upstream import, PR comment or readiness mutation is required/performed here. Current four patch-file hashes independently still equal the original recorded implementation; no claim that the whole current workspace equals that GitHub commit.
- Final managed closeout commit is assigned by the normal Rork save workflow after this turn; it is not yet available. Do not present pre-correction HEAD as that final commit. Corrections are saved in the managed workspace; no manual Git commit/push.
- **Native gate closed; source ready to proceed to the separate iPhone launch/immediate Home-scroll-during-Syncing check**, repeat with unchanged cache and compare existing captures. Physical-device responsiveness remains unexecuted/unaccepted. Device signing/delivery, distribution and performance acceptance require separate approval; nothing uploaded or distributed. Target Nutrient remains closed.

## iOS Saved Chemical sync batching — PR #7 integration / focused validation — 21 October 2026 (historical checkpoint; superseded by closeout above)

**Status: authentic patch integrated; Debug simulator build PASS; four-suite gate NOT GREEN (63 passed, 2 failed). PR update/readiness not performed.** No merge, release, upload, distribution, physical-device operation or performance acceptance.

### Source provenance and scope

- Upstream: `stockmansridge/rork-vinetrack-june26`, PR `https://github.com/stockmansridge/rork-vinetrack-june26/pull/7`, branch `fix/ios-chemical-sync-batching-20261021`, exact implementation **`bbd2b791bb9d4b8c9c036e56fe66839035eb029e`**. Linked source retained at `linked-repos/vinetrack-sync-review`, clean and at that commit.
- Managed baseline **`12cfa4fd9ae1fba508562f81752aa1a818dfd096`**. Before integration, all three affected production files were byte-identical to upstream parent **`50aa0f19e7440602765017a3844689c7ff478489`**. No reset/overwrite of newer accepted work. Both pre/post-upload complete reconciliation calls remain intact.
- Integrated exactly the existing patch, not a recreation: `ManagementSyncServices.swift`, `SprayRepository.swift`, `MigratedDataStore+Spray.swift`, and existing upstream `SavedChemicalBatchReconciliationTests.swift` (440 lines,11 tests). All four integrated files verified byte-identical to upstream HEAD after transfer. Existing synchronized test target and Debug scheme needed no edits.
- SHA-256 in the above file order: `8ac255ed70536596f178403a95395b4bcb59da056d8a963326dd9643e2b9a88e`, `2d9b6af17d830e119eed1e89a66a6c66ebfafc3ad4741950f7deeeeb660c0037`, `ca54fa3b93957ed77d5812d2de2d9a14f3fa94385e3050ce31a6cc292282dfac`, `2ec7d9840eba40f4edcf8cafd60099d3a964a13979c7326ad8f24b0530010c75`.
- No Android, Target Nutrient, backend/schema, version, signing or unrelated application edits. No manual Git commit/push; final managed integration SHA is assigned by Rork after save and is not the baseline SHA.

### Actual native validation

One `swiftTest` invocation, app `ios`, exact selectors:

- `VineTrackTests/SavedChemicalBatchReconciliationTests`
- `VineTrackTests/SavedChemicalReconciliationTests`
- `VineTrackTests/ChemicalStoreConsolidationTests`
- `VineTrackTests/PersistencePerformanceTests`

Runner: **65 executed,63 passed,2 failed**. Xcode27.1(27A9275); log shows `Debug-iphonesimulator/VineTrack.app`, `Test Build Succeeded`, build completed in **1m33.2277s**. Test execution duration/skipped metric not exposed. Full runner log `/tmp/rork-swift-test-ios.log` inspected through its final result: `2 of 65 tests failed`. It contains aggregate results and the two failure names, not a passing-case discovery manifest. Do not invent individual passing-test names/counts from the aggregate. Source inventory:11 batch functions,6 reconciliation functions (one parameterized false/true),29 consolidation functions,18 persistence functions =65 expected cases, consistent with observed total; source inventory is not separate per-suite execution evidence.

The two observed assertion failures:

1. **`ChemicalStoreConsolidationTests/seedingIsDeterministic()`**: `first == second` fails. `ChemicalReviewSession.make` hydrates manual active/use/rate drafts whose IDs default to fresh UUIDs; synthesized equality includes those IDs. These are existing pure draft paths, not the sync service/repository path.
2. **`ChemicalStoreConsolidationTests/hracStaysDistinct()`**: expected code `G`, actual `9`. The existing authoritative table intentionally maps Glyphosate to current numeric HRAC9, with legacy G retained separately. HRAC scheme expectation is not the failing assertion.

Source attribution verified: `ChemicalReviewSession.swift`, `ChemicalManualEntry.swift`, `ChemicalReviewDraft.swift`, `AuthoritativeActivityGroups.swift`, and `ChemicalStoreConsolidationTests.swift` are each identical in the current worktree, pre-integration baseline and upstream parent (full Git blobs respectively `3b83da69c0c5c32219463d728b2edc7de927da61`, `74f5621ce3a93e1dc6fd359a21de210c27c03720`, `7d6d13374847afad020efd2a5d56210d941f8898`, `cf4ba206e77641d318d140c4e7ee4fae32e60441`, `4eeb1aa72d35edacdab371173e1e5e9489569d7a`). This establishes unchanged code/test mismatches, **not an executed baseline failure**. No patch-caused compilation or assertion defect identified; no chemistry changes, assertion weakening, baseline rollback or unchanged rerun performed. Separate approval is required to correct these unrelated mismatches.

Final `runChecks(ios)` **PASS**, simulator build succeeded; device build not verified. Two advisory old asset-address warnings in unrelated TripTypeChoiceSheet/UCRInfoSheet left untouched. Managed build is correctness validation only, not store/device delivery.

### PR and remaining gates

No supported GitHub PR-comment/readiness or branch-write operation is exposed in this session; linked-repo tooling provides source connection/inspection only, and manual commit/push is not permitted. **No PR comment posted, no correction pushed, no ready-for-review transition.** Linked PR branch remains at original verified implementation commit. No patch correction was necessary to push. Four-suite gate is not green, so readiness condition is unmet independently of tooling access. The evidence above is the intended factual PR update, not a claim it was posted.

Physical acceptance remains deferred to separate approval: launch iPhone and immediately scroll Home during Syncing; repeat with unchanged cached data; compare existing performance captures. Automated collection-write/codec assertions do not prove real Home-scroll responsiveness. Prior Target Nutrient workstream remains CLOSED, with historical device acceptance deferred.

## Target Nutrient Calculator — CLOSED: implementation complete, device acceptance deferred — 19 October 2026

Owner accepts the completed iOS and Android source implementation and existing automated validation. **Implementation workstream CLOSED. Physical-device acceptance DEFERRED**, not passed, until compatible signed handset builds are available through a separately approved release process. Signing/delivery limitations do not reopen implementation.

Retain the recorded frozen source revision **`f16e59646144d8d9017ba8c84a6362a9ad0415c0`**, iOS subtree `f2521036894697cec9352a2a4e5eb6969621b2b3`, Android subtree `1e0f350ef55b2e90723343bb1becac2c4360481f`, existing patch/artifact hashes, disclosed failures/limits and eleven-case handset checklist in the preparation checkpoint below. Retained nutrient validation: iOS12 target +12 regional +4 UI passes (skipped metric unavailable); Android74 host and7 Compose/persistence/restoration passes, zero failures/errors/skips; both recorded correctness builds PASS. Historical overlapping runs are not added; no new validation is claimed.

Recorded signing limitations remain: iOS validation is simulator-only with no current signed handset IPA; inspected Android3.1.7/code12 APK is debug-signed and not cleared as a compatible in-place replacement. Historical signed builds predate this implementation and are not substitutes. Mobile System Admin-only preview, disabled saving, original records and offline-work protections remain unchanged.

No further investigation, builds, signing changes, tests or development for this workstream. No release, upload, distribution, deployment or handset operation authorised or performed for this closeout. Documentation-only status update; no code changes or validation reruns. Earlier nutrient signing/handset gates are retained as **deferred future release acceptance**, not active work or failed implementation. Separate spray/row-guidance status is unaffected.

## Final Android row guidance source acceptance — 19 October 2026 — frozen; Play proposal awaits Console facts

### Accepted source and preserved evidence

Owner explicitly accepts movement-relative row-side accuracy/direction correction at **`97575b1e20ed4f7db38f64bea0f9069ac5b434ed`**. Object exists locally; Android tree **`1e0f350ef55b2e90723343bb1becac2c4360481f`**, scripts tree **`ab98d71e6cd4d1a82ef4f8edbafccc26de545146`**, exactly equal latest workspace HEAD **`12a6890895685ef550915372e02a597b983840a0`**. `git diff accepted HEAD -- android-vinetrack scripts` and working-source checks pass. Latest HEAD is the proposed source SHA; accepted commit remains the immutable correction reference. Later documentation commits do not change these application trees.

Retain final **26 host passes /0 failures/errors/skips**, **3 production Compose passes /0 failures/skips (15s)** and **Android runChecks PASS** from the settled correction; previous failure disclosure and fixture limits below remain intact. These results were not rerun or added together with older overlapping counts. No application/build/signing/version/test/script changes this checkpoint. GPS recording, path completion, tanks, offline journals/queues, Start Trip, Quick Actions and newer accepted calculator work remain unchanged. No safety-critical defect demonstrated; no new development cycle authorised.

### Exact field expectations from frozen source

Sources: `ui/screens/LiveRowSideGuidance.kt`, `TripsScreen.kt:1895–1929,2022–2026,2218–2239`, shared `data/PinAisleGeometry.kt`. These are admission conditions for a read-only display, not receiver guarantees or automatic-completion thresholds.

- **Display admission:** Row Tracking enabled in Preferences AND row-label visibility toggle on. Active tracking belongs to this Trip/device and HUD is foreground/STARTED; trip not paused. Sample must be newer than the last HUD STOP boundary and age **0–5,000ms inclusive** with finite valid coordinates. A one-second display timer expires stale evidence even without new fixes. No old label is held through a stale/low-speed fix. Foreground return needs fresh qualified evidence.
- **Speed/course:** finite reported speed **>=1.0m/s (3.6km/h; about2.24mph)** plus valid current course. Course must lie within **30 degrees inclusive of either along-row direction of each bounding segment**. Missing/invalid course or lower speed waits for travel direction; stationary compass/map orientation is not substituted. No independent reverse-gear detection exists. A noisy receiver falsely reporting qualified movement is not disproved by these conditions; observed physical mismatch should be recorded, not described as guaranteed impossible.
- **Mapped scope:** one unambiguous containing non-deleted same-vineyard block in allowed trip scope, valid mapped row endpoints, unique row numbers and a plausible physically containing adjacent pair. No occurrence target, current planned path, camera bearing or numeric lower/higher ordering determines sides. Missing geometry, overlapping block identity, headland/outside rows withhold pair labels with the appropriate waiting/outside message.
- **Two-row uncertainty:** finite reported accuracy radius `a >=0`; on **each** bounding segment, perpendicular distance to its centreline must be **strictly greater than max(a,0.15m)**, and projected distance to **each segment end strictly greater than a**. Equivalently `a` must be smaller than both row clearances and all four endpoint margins, in addition to mapped-aisle admission. Equality fails. No universal3m or8m allowance overrides this stricter display gate. An off-centre fix has less usable margin than a centred fix.
- **2.8/2.9/3.0m parallel spacing, interior centre:** accuracy must be **<1.40/<1.45/<1.50m respectively**, and clear segment ends. **1m can qualify**; **3,5,8m must withhold** both pair labels even if general GPS says Good. At0.8m from a row,1m must withhold. Receiver accuracy is an estimate, not proof that mapped rows or the real position are that accurate.
- **Single/outer known-row exception:** never invent the opposite row. Requires saved finite positive spacing `w`, `a <w/2`, interior endpoint margins >a, along-row course within30 degrees, row offset **>max(a,0.15m)** and **<=0.75w**, and lateral course-relative offset >a. Only that reliably known row is displayed; both chips render independently.
- **Stationary/crawling:** below1m/s, no row-side labels; wait for travel direction. **Reversing:** while opposite along-row course qualifies, Travel left/right swap relative to movement, NOT tractor/driver facing. Visible explanation remains **“Sides follow travel direction, not vehicle facing”**. **Turning:** low-speed, cross-row (>30 degrees), end-margin or block/accuracy failure withholds; an along-row portion of a turn may qualify if all gates pass. There is no blanket turn detector or vehicle-facing promise.
- **Preference off:** no chips, explicit **“Row labels disabled in Preferences · Row Tracking”**. Visibility toggle off hides chips and row-guidance message; it does not change recording/coverage. Preference updates are observed and reloaded on return. North-up/heading-up/map rotation never changes the travel reference.
- **Poor row resolution:** neither pair side is shown; **“Row guidance waiting · GPS cannot distinguish adjacent rows”**. General GPS Good remains a separate recording-quality indicator, not precise adjacent-row identification. Passing source/fixtures does not establish real Samsung GPS/map accuracy.

### Pre-build Play proposal and current read-only results

Latest request accepts the **existing managed AAB signing and Google Play testing update route**, superseding the prior Android no-store-delivery proposal only for preparing a Play candidate. It does NOT authorise building/uploading before the requested exact proposal is returned and approved. The previous local-debug-APK replacement blocker is NOT a reason to substitute sideloading or abandon the existing managed route. iOS is out of scope.

Fresh typed operations: `setupGooglePlay` reports connected; `ensurePlayAppRecord(com.rork.vinetrack)` succeeds (`created:false`). `listPublishablePlayBuilds(android-vinetrack)` returns20 older entries, latest **`b41cb33e-6232-4f13-8da4-b75207a8bf52`**, snapshot `yw4uvmz98o4wfvy3gnmjk`, source **`src_e14325113de07dddc`**. Status completed, returns `apkKey` only. This is older than accepted row-side work, does not match current Android tree, and is not evidence of the existing Play track/highest used code or a committed release. No matching new managed AAB exists in the returned list. No generation, submission (including validation upload), track mutation or developer-verification mutation performed.

| Proposal field | Verified / unresolved |
|---|---|
| Package / name | **com.rork.vinetrack /3.1.7**, unchanged. |
| Source SHA | **12a6890895685ef550915372e02a597b983840a0**, identical Android/scripts to owner-accepted **97575b1e20ed4f7db38f64bea0f9069ac5b434ed**. Revalidate source-bound managed snapshot/hash before an approved build; do not invent snapshot ID. |
| Proposed numeric versionCode | **BLOCKED, not selected.** Local12 is not authoritative highest Play code. Need highest previously used code including uploaded/draft/inactive bundles and any outstanding reservation. Proposed policy: next managed-assigned unused code greater than that verified maximum and compatible with tester install; return exact numeric proposal first. No guessed13 or local Gradle edit. |
| Intended track | **Same existing testing track used by this Samsung tester; exact track ID/name unverified.** Do not silently substitute Internal/alpha/beta or production. If a custom track is involved, typed custom-track automation is unavailable and needs supported/manual handoff. |
| Signing/distribution | **Existing project-managed persistent upload key -> same Google Play package -> existing Play App Signing key/lineage -> eligible tester's in-place Play update.** Historical upload cert SHA-256 **241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3** is a reference only, not newly verified against Console. Current registered upload and app-signing fingerprints/lineage are **unknown**. Upload and delivery signer are different roles; sandbox Debug signer is not the candidate. |

Status **blocked_missing_typed_operation**: current supported tools do not expose track listing, highest-used code history, or authoritative Play signing fingerprints. Do not generate/upload to discover these facts or use raw credentials/third-party CLI. Need owner-provided non-secret Play Console evidence: **existing testing track details (exact ID/name/current release and tester eligibility), App bundle explorer highest used code including drafts/inactive uploads, and App integrity upload/app-signing SHA-256 plus key-rotation lineage if present**. A screenshot of just installed version3.1.7 or local12 is insufficient. Once supplied, return the exact numeric/source/signing/track proposal for approval before building. Managed backend owns version assignment; if a pre-build reservation cannot be confirmed through supported access, report that remaining gate rather than promise a specific generated code.

### Samsung physical field observations — NOT EXECUTED

No physical Samsung connection, installed approved update, real driving telemetry or new field evidence is available in this session. All observations below are **pending**, not fixture-derived field passes. Source acceptance does not close physical or production gates.

1. While stationary before Play update, record model/OS, installed code, account/vineyard, original Trip UUID, tank/session/Actual identities/quantities, GPS evidence count/last timestamp and Sync Status pending/held counts/reasons. Retain evidence without force sync, logout, uninstall, storage clearing or queue reset.
2. After the approved in-place update through the **confirmed same Play track**, record served build/code and verify original identities/evidence still present. Stop on any missing work or a removal/signature/downgrade prompt. No sideloaded debug substitute.
3. Safely drive along actual mapped2.8–3.0m rows; a passenger can record observations, or capture notes/screenshots when stationary. For each event note timestamp, block/row pair/spacing, speed, reported GPS accuracy, course if available, shown Travel left/right OR exact withheld message, physical offset/end proximity, map orientation, forward/reverse and expected/observed result. Do not spoof GPS or handle the phone while driving.
4. Observe available real uncertainty/speed ranges: >=3.6km/h with1m-like interior accuracy may show labels;3/5/8m-like uncertainty must withhold even with Good; low speed/stationary waits; headland/cross-row/turning waits when gates fail. Do not require naturally unavailable accuracy bins; mark unobserved. North-up/heading-up with the same qualified travel must not change identities; reversing is checked against movement, never tractor-facing sides.
5. Recheck Row Tracking disabled/enabled, pause/foreground return and ordinary presentation toggles without altering original work. Compare original Trip/tank/Actual IDs and preserved GPS prefix/Sync Status after update and after field run. Actual driving legitimately adds GPS points and may trigger existing automatic completion or normal sync; retain original evidence and describe legitimate deltas rather than require an unchanged GPS count or falsely blame read-only labels.

**Remaining blockers:** authoritative Play code/track/signing facts; approved exact proposal then managed build/upload to that testing route; actual Samsung observations and retained-evidence comparison. Production release remains prohibited. No further algorithm work unless a demonstrated defect (especially safety-critical) warrants separate bounded correction. Documentation/protected-source whitespace checks only this pass; no new builds/tests because app source is unchanged and the owner explicitly requires a proposal before building.

## Target Nutrient controlled device-testing preparation — 19 October 2026 — source frozen; compatible signed handset delivery BLOCKED

### Approval and exact frozen source

Implementation accepted for controlled physical-device testing only, not production. No further feature development. Portal's wider preview access does not change mobile System Admin-only preview. No application, calculation, permission, SQL/schema, signing configuration or version edits in this preparation. No store upload/distribution, handset install, uninstall, clear storage, queue reset, forced replay or customer-record access.

- **Frozen application source commit: `f16e59646144d8d9017ba8c84a6362a9ad0415c0`.** Initial application/scripts/SQL/Supabase working trees equal this commit; only two managed conversation files initially modified, left untouched. Subsequent documentation-only save is not a new application-source candidate.
- iOS Git subtree: `f2521036894697cec9352a2a4e5eb6969621b2b3`; Android Git subtree: `1e0f350ef55b2e90723343bb1becac2c4360481f`.
- Recomputed `git diff b67126aed4c7f0474207626803f0258ef291ba0c 2f9a376c16c0ee7271aa9f68705d8828b844cbf9 --binary -- ios android-vinetrack scripts` SHA-256 exactly equals accepted nutrient patch **`2315c062ab84a0cdc5b37de25668c6a6e74bc7c9bc913acda7d65b91598ab13c`**. Recomputed `2f9a376...` to frozen HEAD Android patch equals settled row-side patch **`e0cf5b72b57b76472609a89b1c0b605ad75810373dc628685f5db5d99a758fb0`**. Thus current source includes accepted nutrient work plus the subsequent verified Android display correction; neither rolled back.
- Prior nutrient evidence retained, not rerun or inflated: iOS12 target +12 regional and4 UI passes; Android74 host and7 Compose/persistence/restoration passes. These remain automated fixtures, not authenticated/physical acceptance.

### Candidate identity and actual preparation status

| Platform | Identity | Actual status |
|---|---|---|
| iOS | `app.rork.nt0v48tayl7v8noxcfe74`; source **3.1.7 (139)** | Fresh `runChecks(ios)` **PASS, simulator build only**. No current signed device IPA/archive, artifact ID/download URL or IPA SHA-256 returned.139 is project metadata, **not a newly reserved or signed device build**. Historical signed171/ASC build `f5647734-efe7-43e6-b6da-ac43729a6e9b` predates nutrient implementation and MUST NOT be used as this candidate. |
| Android | `com.rork.vinetrack`; APK manifest **3.1.7 / versionCode12**; universal ARM64/ARMv7/x86/x86_64, API24+ | Fresh `runChecks(android-vinetrack)` **PASS**. Local `:app:assembleRelease` **PASS12s**, incremental cached production compilation plus repackaging from unchanged frozen source. Installable APK exists, signature verified, but **not established safe for in-place update**; actual signer is Android Debug, not a managed Play/App Signing candidate. No AAB generated or Play call made this preparation. |

Android local inspection artifact (not distributed): `android-vinetrack/app/build/outputs/apk/release/app-release.apk`, **77,056,837 bytes**, file timestamp **2026-10-19 02:03:29 UTC**. APK SHA-256 **`b1df7051cfc0bf2a19dcf84a5472e1795d42cc445e0847d2e146a0a0c0f30628`**. `apksigner verify --verbose --print-certs` PASS, v2 signature, one signer **CN=Android Debug, O=Android, C=US**; certificate SHA-256 **`37e860204c8bf2d3eea982cf41ff7e3b751590407769f078e75c8fe2c67c1a58`**. `aapt dump badging` independently confirms package/version/API/ABIs. Build output is ignored and ephemeral; no durable hosted/download identity was supplied. Do not confuse this SHA with the pre-repackaging local file or a remote managed build artifact.

**Signing/export blockers, not a request for more feature work:**
1. The available Swift validation route builds a simulator app. The documented managed signed-device route is `submitBuild`, which uploads to ASC/TestFlight; no build-only signed Ad Hoc/development IPA export is exposed. It was deliberately NOT invoked. Need an authorised no-upload signing/export route with existing app/team/entitlement/keychain identity and valid provisioning for test devices, or separate explicit approval of a store route later. Do not invent a new iOS build number (including172) from stale historical metadata. A build-only route must assign/confirm an acceptable identifiable number without altering frozen feature source.
2. Android local release configuration intentionally uses debug signing. Its measured certificate differs from historical signed11/12 certificate **`241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3`**. That historical upload certificate is itself not proof of installed Play App Signing identity. No access to a compatible signed APK export is exposed; managed AAB generation alone does not provide a verified installable replacement signed by Play's app-signing key. Need actual installed certificate/lineage + versionCode and an authorised matching no-upload signed APK export route. Code12 is the exact inspected APK value, not a verified next Play code or a guaranteed upgrade over the installed app. Do not use downgrade flags, re-sign with a new key or uninstall to bypass rejection.
3. Hence **neither platform is currently cleared for an in-place update on the existing data-bearing acceptance devices**. Android is a signed inspection artifact, iOS a simulator validation candidate only. Do not say both signed handset candidates are ready or that handset acceptance has begun. All App Store/TestFlight/Play upload and distribution remain forbidden until separately approved.

### Safe installation/update procedure — only once signing/delivery gates are resolved

1. While stationary and without starting/ending work, record device model/OS, installed bundle/package/version/build, account/vineyard, relevant record IDs, active trip/tank/session/Actual IDs if present, held/pending Sync Status counts and reasons, and last GPS evidence/count if applicable. Use screenshots and existing non-destructive exports; an export is not a guaranteed backup of hidden queues. Do not force synchronization to make the baseline clean. Keep network state unchanged unless deliberately recording the offline baseline.
2. Confirm the exact candidate commit/artifact hash and platform identity. iOS: existing team/app identifier, entitlements/keychain access and valid supported provisioning with the intended device. Android: installed signing certificate or accepted lineage matches candidate, package identical, version not downgraded and installer supports the approved update. A Google Play upload certificate is not an installed APK signer. Use read-only installed-package inspection; never pull private app databases or alter queues for this check.
3. After explicit delivery approval, use only an **in-place Update**, not Delete/Reinstall, Offload/Reinstall, Clear Data/Storage/Cache, package rename, logout/account swap or a different-signature replacement. No install/distribution is authorised by this handoff. Stop if installer proposes removal, signature replacement or downgrade. Preserve the original installation when blocked.
4. Before reconnecting, compare original records, IDs, pending/held reasons and offline work with the baseline in the same account/vineyard. A normal launch may perform legitimate existing sync when online; record this rather than assuming every count change is deletion. Keep held original evidence; do not retry/purge/overwrite it to obtain a green status.
5. Perform calculator tests as local **preview only**. Never Save/Complete/Delete a real record to test the guard. Use pre-existing approved read-only historical examples; if none exist, mark that check unavailable rather than create unsupported records. Verify non-admin using a separate already-provisioned device/session, not by signing out a handset holding work.
6. Relaunch offline only when it is safe to close the app and no active field recording is required; do not stop a real operation just for testing. Record whether a normal relaunch or verified process termination occurred. Return to the same original records and Sync Status. Reconnect/allow ordinary replay only with separate operational approval; correct supported pending writes may legitimately reconcile, while held unsupported evidence must not be discarded. Never manufacture test pending writes in production.

### Physical acceptance checklist — iPhone and Android phone; iPad/Android tablet where available (ALL PENDING)

Record candidate hash/build, device/OS, role, region/units, font size, network state, observed result and screenshot for each applicable case; mark unavailable tablets/records honestly. These are read-only preview checks, not authorisation for real fertiliser application.

- [ ] **Solid reference:** N, elemental16%, target2g/vine -> **12.5g product/vine**. Manual1,000 vines -> **12.5kg product** and **2kg nutrient**. Product form, units and decimal precision must be explicit.
- [ ] **Nutrient retention:** N ->Ca ->micronutrient ->Other retains entered percentage/target (16 and2). Re-confirm elemental analysis as prompted; Other requires a name. Unknown/oxide analysis blocks elemental output; do not interpret the confirmation reset as value loss. Back/dismiss controls do not accidentally save.
- [ ] **Blocks/totals:** Use approved blocks with known saved Actual/Assumed vine counts/areas; total vinesV should give **0.0125×V kg product** at the reference dose. Add/remove blocks and compare with recorded counts, select/deselect manual path, verify Actual/Assumed labels. Missing required counts/area must explain unavailable totals, not silently omit a block. For area mode16% and2kg nutrient/ha ->12.5kg product/ha;2ha ->25kg product,4kg nutrient.
- [ ] **Liquid w/v:**16%w/v and2g/vine -> **12.5mL/vine**, **12.5L for1,000 vines**, without density. Keep unknown basis blocked. Solid w/v is not a valid liquid calculation.
- [ ] **Liquid w/w:**16%w/w,2g/vine and documented **1.25kg/L** density plus nonblank label/technical-sheet source -> **10mL/vine**, **10L for1,000 vines**. With density/source missing or invalid, no invented mL/L result; display honest required **12.5kg product mass** for1,000 vines and explain the density requirement. Restore valid values and confirm volume returns.
- [ ] **Immediate results/keyboard:** Result rate appears without requiring Blocks first; edits recompute. Numeric decimal point/comma where supported, focus/Done/Back/scroll work on real keyboards; fields and results remain reachable above IME, no clipped labels, accidental save, stale result or lost typed values.
- [ ] **Layouts:** iPhone and Android phone show Live Results immediately after inputs, before blocks. iPad regular width and Android tablet >=700dp use Calculator/Live Results columns when applicable; narrow or accessibility sizes may legitimately reflow. Check portrait/landscape and default/larger text, light/dark; no hidden inputs/results/actions. Record unavailable devices rather than accepting tablet layout from phone evidence.
- [ ] **System Admin-only:** Existing verified System Admin sees preview; an already provisioned non-System-Admin session does not, including attempted restored destination. Portal access expansion must NOT grant mobile access. Do not change roles or sign out a working offline handset for the check.
- [ ] **Saving disabled:** Visible preview save unavailable; no new fertiliser/product-analysis record, pending write or completion action from entering/changing preview inputs. Do not use real records to exercise destructive mutation calls.
- [ ] **Unsupported history:** Existing approved unsupported/nutrientTarget/fertigation records retain original mode, values, units and analysis, remain read-only with no Complete/Delete/edit fallback to Per Hectare. Do not create/import a new unsupported production record; mark unavailable if no approved example exists.
- [ ] **Offline safe relaunch:** In the same retained session, enter flight mode, navigate preview/read existing records, then safely close/relaunch. Original records, held/pending work, IDs and reasons remain; no duplicate record or artificial full-sync stamp. Preview draft survival after full termination is not required (preview is local/non-saving); do not confuse lost preview draft with lost saved work. Reconnect reconciliation is separately approved and observed, not forced.

### Validation/scope closeout

Both fresh managed checks passed; no tests rerun or authored because this request is candidate preparation and physical checklist, not a new automated-test suite. Prior automated evidence retained above. Asset-address advisories are pre-existing and left untouched. Final application/scripts/SQL/Supabase `git diff HEAD --exit-code` remains clean; only this existing report/approved-plan documentation changes, plus managed conversation state. No signing provisioning/capability mutation or store provider call made. Physical acceptance and production release remain OPEN/NOT APPROVED.

## Final Android row-side guidance check — 19 October 2026 — display corrections; private candidate NOT generated

### Source and narrow findings

Owner-confirmed GitHub SHA **`e9570d48199368921af0634c8bda8f7d1896267c`** verified through the public repository API. The managed Git origin cannot resolve that external object; no fetch/reset/rollback was used. Its Android tree **`6a3b09dcd9388ee156c743a259f40bdca6e70e06`** exactly matches local correction commit `b67126aed4c7f0474207626803f0258ef291ba0c:android-vinetrack`. Its `LiveRowSideGuidance.kt` bytes match the pre-edit file SHA-256 `fd3277e266e803ffcac5c99be01526db73570a6f5d09a06d22d85c036070117a`. Current application baseline **`2f9a376c16c0ee7271aa9f68705d8828b844cbf9`** additionally includes the subsequently approved Target Nutrient work; that work was preserved, not silently rolled back for a row-side candidate.

Two source-proven gaps mean this was not a no-change verification:

1. **GPS course is not operator facing.** `LocationTracker.MovementSample` carries latitude, longitude, course, speed, accuracy and timestamp, but no vehicle gear, verified mounting/facing or independently validated forward-travel evidence. North-facing reversing south and a vehicle turned around/driving forward south can produce identical samples. The unconditional `true` passed to the pin-facing qualification helper was therefore unsupported. A single GPS sample cannot classify reversing vs turnaround, and map bearing does not establish either. The display no longer calls that facing helper; it independently validates moving course at the same >=1m/s threshold and explicitly says **Travel left / Travel right**, with visible explanation **Sides follow travel direction, not vehicle facing**. A stopped/low-speed or cross-row turning fix hides labels and waits; a qualified opposite along-row course reverses movement-relative sides regardless of map orientation. This is an explicit movement reference, **not proof of vehicle/operator-facing left/right while reversing**. If operator-facing sides are required, that acceptance remains open pending an authorised independent facing/forward-evidence source; do not infer it from these tests or describe the two frames as equivalent.
2. **General GPS Good is not individual-row proof.** The existing shared `PinAisleGeometry.uncertaintyFitsBetweenRows` permits accuracy up to the full aisle width. It must remain unchanged for pin attribution in this display-only task. Row guidance now adds a local stricter check: the reported uncertainty radius must clear **each** bounding mapped row and both row-segment ends. Failure yields **Row guidance waiting · GPS cannot distinguish adjacent rows**, with neither side shown, never another nearest pair or a relaxed threshold. The existing single-mapped-side logic already requires clearance and <half recorded spacing; no opposite side/aisle is invented. Reported Android accuracy is an estimate, not a guarantee that the real vehicle lies within that radius or that row maps are survey-accurate.

### Representative geometry and presentation

Host fixtures contain four parallel mapped rows with 2.8, 2.9 and 3.0m spacing. At an interior aisle centre (1.4–1.5m to each row), expected results are:

| Reported accuracy | Existing general GPS status | Row guidance expectation |
|---|---|---|
|1m|Good|Both travel-relative labels, provided all existing freshness/block/course/geometry checks also pass. |
|3m|Good|Waiting: cannot distinguish adjacent rows; no labels. |
|5m|Good|Same waiting; no labels. |
|8m|Good|Same waiting; no labels. |

Even1m accuracy waits if the fix is only0.8m from a bounding row or an end. The new native production-HUD fixture uses2.8/3.0m spacing and1→3→5→8→1m loss/recovery while asserting that Good and the row-specific waiting state coexist. Original two Compose cases still cover the explicit travel frame, map north/heading-up toggle, row-label/preferences toggles, composition return, pause/freshness/lifecycle and unchanged synthetic trip/tank/GPS evidence. No satellite renderer, actual FusedLocation observations or physical Samsung acceptance is implied.

### Validation and preservation

Retain prior settled **22 host / 2 Compose / successful build** evidence exactly as historical; old captures are not relabelled as today's output. Four focused host regressions added: GPS reverse/turnaround indistinguishability and explicit frame; realistic spacing/accuracy matrix; uncertainty touching row/ends; loss/recovery/block transitions with unchanged original Trip serialization. One production Compose case added for Good-versus-row-confidence loss/recovery and unchanged Trip/device ID/pending writes. The two existing Compose tests retain their checks with explicitly qualified Travel left/right semantics. No skipped transport/export probe is counted as a functional pass.

Final executed evidence: **26 host tests passed /0 failed /0 errors /0 skipped** (19 `LiveRowSideGuidanceTest` +7 unchanged `LiveTripGuidanceTest`, XML inspected;0.076s+0.005s test execution, cold build time separate). **3 production Compose tests passed /0 failed /0 skipped in15s**: `freeDrivePhysicalRowsToggleDirectionPreferenceAndReturnPreserveEvidence`, `rowSidesStaleLowSpeedAndFreshReturnLeaveSavedActionUntouched`, `narrowRowsGpsGoodStillWaitsAndRecoversWithoutChangingEvidence`. **Final `runChecks(android-vinetrack)` PASS**, after the final test correction; two pre-existing asset-address advisories left untouched. Original22/2 remain historical subsets, not additional counts.

Disclosed development failure: the first combined Debug runner completed all26 host assertions successfully, then AndroidTest compilation failed because the newly added test referenced `pending` without declaring its local repository. Added the same existing isolated-fixture reflection lookup used by the preceding queued-work test; no production edit or assertion relaxation. That combined invocation is **failed** (4m57s), not a successful overall build. The subsequent selected native run compiled and passed3/0/0, and final managed build passed. No unchanged retry loop or broad unrelated tests. No physical handset install, live authenticated transport, OS-process or original Samsung acceptance claim.

Frozen tested snapshot identity: exposed baseline **`2f9a376c16c0ee7271aa9f68705d8828b844cbf9`** plus Android binary diff SHA-256 **`e0cf5b72b57b76472609a89b1c0b605ad75810373dc628685f5db5d99a758fb0`** (`git diff HEAD --binary -- android-vinetrack`, including both production and both test files). This baseline is **not** the new correction commit. Final managed end-of-turn Git SHA is unavailable until save and must be read at the next checkpoint before building the private candidate; no fabricated SHA or manual Git write. No further source edits after this validation.

Only production edits are `ui/screens/LiveRowSideGuidance.kt` and the existing `RowSideChip` text/semantics in `ui/screens/TripsScreen.kt`; tests are `src/test/.../LiveRowSideGuidanceTest.kt` and `src/androidTest/.../LiveTripLayoutAndroidTest.kt`. Existing bounded runner reused unchanged. No changes to LocationTracker, row lock, traversal/completion, pin geometry/attribution, ViewModel, tanks, persistence/sync, Quick Actions, historical data, iOS/backend/SQL, version or signing configuration. Scoped protected-path comparison and whitespace pass. The UI is not redesigned.

### Read-only Google Play preflight / proposed candidate

- Typed `setupGooglePlay`: connected. Typed `ensurePlayAppRecord`: package **`com.rork.vinetrack`** accessible, existing (`created:false`). No Google credentials requested or placed in source.
- Typed `listPublishablePlayBuilds(android-vinetrack)` returns20 previous managed entries. Latest returned run **`b41cb33e-6232-4f13-8da4-b75207a8bf52`**, snapshot `yw4uvmz98o4wfvy3gnmjk`, source `src_e14325113de07dddc` is the **older pre-row-side Android tree** from17October. Typed status is completed, but returns only an `apkKey`; this does not establish the AAB identity/versionCode or prove it was committed to a Play track. No returned entry matches today's correction. Do not reuse it as the corrected candidate.
- The current local Gradle version is **3.1.7 /12**. The provider responses expose **no highest previously used Play versionCode, active/testing track, upload certificate or Play App Signing certificate/lineage**. No typed read operation for those facts is exposed. An uploaded predecessor, local12 and historical APK signer do **not** establish that13 (or any guessed number) is compatible. Preflight status: **blocked_missing_typed_operation**, with signing/version unknown, not passed.
- **Proposal only:** a new source-bound **managed Play AAB**, package unchanged, retain versionName3.1.7, on **Internal Testing** for owner-approved private Samsung testers (or the existing private testing track once confirmed). Exact next versionCode must be the backend-assigned unused code above the verified highest previously used code (and compatible with the installed tester version), not a manually invented local override. Obtain Console **App bundle explorer/highest used code, intended testing track, App integrity upload and app-signing certificates/lineage**, or restore a typed read surface, before presenting an exact numeric candidate. Do not treat this proposal as ready-for-internal-testing.
- After separate owner approval to **generate**, use `generatePlayAab` for the then-current verified snapshot/source and the persistent project upload key, poll status, re-list and verify source/package/artifact/version/signing. Generation may reserve a code but is **not authorised now**. After separate upload/distribution approval, validate the exact Internal Testing submission first, then commit only that approved release. No old build, Debug APK, manual re-sign, signature bypass, uninstall or clear-data replacement.
- Google Play must deliver the normal **in-place update** under the existing Play App Signing identity. Verify installed package/signing lineage/tester eligibility, monotonic code, and server-registered upload key before proceeding. Retaining app data is the required update route, not a claim about a handset not accessed here. Stop on incompatibility; never uninstall or clear storage to resolve it.

### Remaining Samsung acceptance — all pending on an approved testing build

1. Before update, record Samsung model/OS, installed package/versionCode, original active Trip UUID, tank/session/Actual IDs and quantities, GPS evidence count/last observation, and complete Sync Status/held queue. Retain offline work; do not force synchronization or clear queues for the test.
2. Install **through the approved private Play track in place**; confirm same package, account/vineyard, original trip/tanks/evidence/Sync Status. Stop on missing evidence or update/signature mismatch.
3. Move along mapped2.8–3.0m vines in Free Drive and existing planned/occurrence journeys. Compare physical rows and **Travel left/right** against actual movement, not camera up or vehicle-facing left during reverse gear. If operator-facing labels are the intended contract, do not accept movement-relative output as satisfying it.
4. While safely reversing, confirm travel-relative sides reverse; a vehicle-facing interpretation must not be inferred. Turn around through slow/cross-row travel: waiting while insufficient direction evidence, then correct qualified travel-relative sides. Record errors while stationary/passenger-assisted.
5. Observe genuine reported1/3/5/8m-like accuracy changes without spoofing receiver evidence: Good may remain while row labels wait. Loss hides stale labels; recovery restores only when the actual fix clears both rows and ends. Record both reported accuracy and map/physical offset; a1m estimate alone is not ground truth.
6. Toggle north-up/heading-up, map type/follow and labels/preferences; row identities must not follow camera rotation. Change between actual blocks and overlapping/unmapped boundaries: no stale previous-block labels or invented pair. Pause/background/return requires fresh current evidence.
7. Repeat original trip/tank/Actual/GPS/Sync Status reconciliation after each **presentation-only** toggle. Direction/accuracy samples during real movement naturally append legitimate GPS evidence; do not demand a frozen GPS count while recording or mistake valid automatic completion/sync for a display mutation. No new trip, tank/Actual, reset GPS tail, changed queue payload or fabricated full-sync stamp may result from display operations.

No private candidate generated, version increment, upload/validation submission, publish/production rollout, device uninstall/storage clearing or customer-record mutation occurred. Final operator-facing, version/signing and handset gates remain explicit.

## Target Nutrient Calculator — 18 October 2026 — iOS/Android implemented; focused validation PASS; handset/release gate OPEN

### Source of truth and exact scope

Read the latest Portal HEAD `c7be056beeb35ec464cdf36254f9f5cffabb2496` from `stockmansridge/vinetrack-a0d975b1`, including `src/components/fertiliser/FertiliserCalculatorDialog.tsx`, `src/lib/targetNutrient.ts` and `docs/target-nutrient-contract.md`. Portal documentation contains older implementation-not-started statements; the current dialog/engine and §9a establish working preview behaviour. Source was read from GitHub; no Portal edits, database access, production records, provisioning or deployment occurred. The advertised linked-repo/testing/debugging skill files are absent here; existing project native test targets, fixture hooks and supported tools were used.

Implemented on **both** production Fertiliser Calculator destinations, exposed by the existing System Admin authority only. Ordinary users do not get the switch, and the preview component itself denies non-admin mounting. No schema/permission/SQL/Edge change, version/signing change, release/submission/distribution or product-analysis writes. Managed build validation is not an authorised App Store/Play candidate or production deployment. Existing Per Hectare/Per Vine equations, row-side/Live Trip, tanks, historical quantities and unrelated operations remain unchanged.

### Delivered workflow

- **Target Nutrient (Preview)** switch in the existing Fertiliser Calculator, not a disconnected demo. Select an existing saved product or enter a manual product/form; choose N/P/K/Ca/Mg/S/Fe/Mn/Zn/Cu/B/Mo/Cl/Si/Co/Other; enter one percentage and one target. There is no analysis-list editor, second nutrient entry or Add Nutrient step.
- Nutrient changes preserve the raw percentage and target while requiring a fresh elemental/oxide confirmation where the new nutrient can be oxide-labelled. Other requires a name. Legacy saved N/P/K is never seeded as verified analysis. Inputs remain local; there is no product-analysis persistence or new table query.
- Product rate appears without waiting for total quantities. Total product and total actual elemental nutrient update with existing block/vine-count authority or manual quantities. Phones put **Live Results immediately after inputs and before Blocks & vine counts**. iOS regular-width/non-accessibility size class and Android widths >=700dp use Calculator left / Live Results right; tablet visual acceptance remains unexecuted. Existing regional area input conversion and volume output formatter/converters are reused; canonical nutrient target units remain explicitly g/vine or kg/ha.
- Existing `FertiliserVineCounts` resolves Actual vs Assumed full and unavailable blocks, with no new estimation formula. Selecting blocks uses their saved area/counts; deselecting restores manual input. Missing any required selected-block count/area holds totals rather than silently dropping that block. Optional packaging/cost disclosure reuses existing packs/productCost helpers. It does not claim to reserve/deduct inventory or introduce a new stock authority. Saved-product costs remain in existing purchase history, rather than using legacy price fields as current prices.
- Confirmed examples on each platform: 16% N at2g/vine ->12.5g product/vine;20% elemental Ca ->10g;16% w/v liquid ->12.5mL without density;16% w/w liquid with documented1.25kg/L ->10mL. Percentage >0 and <=100, finite positive targets, real whole vine counts/usable positive area required. Decimal comma and point supported; no rounding to display precision feeds back into inputs. Derived displays follow Portal three-decimal outputs; regional liquid totals retain up to three decimals rather than rounding small requirements to zero at one decimal.
- Conditional small notation/concentration selectors and information buttons explain elemental vs oxide, w/w vs w/v and density. Oxide/unknown analysis never produces elemental results. Unknown liquid concentration holds results; w/w without positive density **and a nonblank label/technical-sheet source** holds volume, but displays honest required product mass in kg. w/v needs neither density nor its source. Solid w/v is refused.
- Saving is disabled visibly and structurally: preview has no save/write callback; ordinary local stores, coordinator admission and record-upload repositories reject unsupported/nutrientTarget modes. This also prevents a UI-only save bypass. No nutrientTarget record or product analysis was written.

### Unsupported-record safety correction

The pre-existing iOS backend mapper defaulted every unrecognised mode to Per Hectare; Android retained raw mode but rendered every non-Per Vine rate as Per Hectare and offered completion/deletion. Corrected narrowly for the required compatibility boundary:

- iOS mode now remains a raw-preserving single-string Codable value. Only the two existing modes are operational choices. Unknown, nutrientTarget and fertigation are read-only, never aliased to Per Hectare. Local snapshots retain all14 known nutrient contract fields and the arbitrary JSON analysis object, including its saved declaration/provenance. Original rate/product units come from that snapshot, not inferred units. Android retains the complete raw remote JSON object plus stored units in its existing local record cache. Both have a read-only stored-analysis disclosure.
- No Complete/Delete controls for unsupported modes; local stores refuse unsupported creation/mutation and attempts to overwrite an existing unsupported ID with Per Hectare. Remote cache apply remains able to preserve them.
- Existing unsupported queued UPDATE evidence is held without changing its payload/ID/attempt state or posting it. iOS preserves matching pending metadata when pulling; Android retains unknown local records absent from a pull instead of silently dropping/seeding them. No queue reset, uninstall, data clearing or migration occurs.
- Both deletion repositories additionally verify the current remote mode before calling the existing deletion RPC. A missing/unknown/unsupported mode holds deletion rather than risking a legacy pending-delete write to an unsupported record. This check is source/build verified; **no live deletion request or authenticated remote guard acceptance was performed**. Legacy supported deletion continues through the same RPC once that read confirms mode.

### Executed validation — latest per-suite results, overlapping attempts not summed

| Platform/surface | Passed | Failed | Skipped | Evidence and limits |
|---|---:|---:|---|---|
| iOS `TargetNutrientTests` |12|0|Not exposed|Final focused run104s. Numeric examples, density/concentration/oxide safeguards, canonical hectare/regional conversion, count authority, raw draft retention, access/save policy, remote/snapshot Codable preservation, supported store operations and unchanged unsupported file bytes/no sync hooks after rejected local mutations and store recreation. |
| iOS existing `FertiliserRegionParityTests` |12|0|Not exposed|Passed in latest combined selection; unchanged suite. Actual/assumed/row override/allocations, legacy snapshots, regional/date regressions. Not summed with earlier overlapping passes. |
| iOS production `TargetNutrientUITests` |4|0|Not exposed|Final4/0 in76s: actual production UI manual values/results ordering/save disabled, nutrient switch retention, liquid concentration/manual-to-block/Actual-to-Assumed totals, non-admin refusal. Controlled debug launch bypasses normal auth/network and uses synthetic blocks; screenshot attachment retained by XCTest. No physical iPhone/iPad or authenticated-role acceptance claim. |
| iOS final build |PASS|—|—|`runChecks(ios)` simulator success after final production changes. Device/App Store archive validation not run; no publish flow. |
| Android `TargetNutrientTest` |10|0|0|Host engine/snapshot fixtures, same numerical/safety/retention/access cases. |
| Android existing `FertiliserRegionParityTest` + `RegionFormatterTest` |64|0|0|11+53, same bounded selection. **74 host total**, XML checked; final runner BUILD SUCCESSFUL3m21s includes Debug test compilation. |
| Android production `TargetNutrientPreviewAndroidTest` |7|0|0|Final29s. Actual production Compose results/order/retention, documented density, blocks/Actual/Assumed totals, admin denial, unverified legacy-product percentage, real preferences/retained original outbox after forbidden local edits and replay, supported store operations, Compose saved-instance-state restoration of draft and selected block. No real account/network requests; saved-state emulation/store recreation is not OS-process/handset acceptance. |
| Android final build |PASS|—|—|`runChecks(android-vinetrack)` success after final production changes; correctness artifact only, no store/export/publish operation. |

Development failures disclosed: first iOS batch23 passed/2 UI failures on SwiftUI invalid-frame warnings; replaced transient GeometryReader adaptation with size-class layout and removed the redundant debug-fixture keyboard toolbar (existing app keyboard bridge retained). Next UI batch2 passed/1 failed solely because expected dot did not match legitimate comma display; assertion now normalises the decimal separator, not the numeric result. Later combined batch27 passed/1 failed because the new disk fixture had not created its isolated directory; fixed fixture setup plus whole-second synthetic timestamps matching existing ISO cache precision. The final12-unit and4-UI selections above pass. Android successive5-,6-,7-native selections all passed; they overlap and are not added. No unresolved assertion failure, skipped-as-success or production storage rewrite was used to pass.

### File inventory / tested identity

Production iOS: `LegacyImported/Models/{TargetNutrient,FertiliserModels}.swift`; `LegacyImported/Views/Fertiliser/{TargetNutrientPreviewView,FertiliserCalculatorView}.swift`; `LegacyImported/Services/FertiliserStore.swift`; `Backend/Models/BackendFertiliser.swift`; `Backend/Repositories/FertiliserSyncRepository.swift`; `Backend/Sync/FertiliserSyncService.swift`. Debug fixture only: `App/TargetNutrientValidationView.swift` and a sibling branch in the existing DEBUG keyboard-validation launch switch in `VineTrackApp.swift`.

Production Android: `data/model/{TargetNutrient,FertiliserModels}.kt`; `ui/screens/{TargetNutrientPreview,FertiliserCalculatorScreen}.kt`; `data/{FertiliserStore,FertiliserSyncCoordinator,FertiliserSyncRepository}.kt`. Tests: iOS `VineTrackTests/TargetNutrientTests.swift`, `VineTrackUITests/TargetNutrientUITests.swift`; Android `src/test/.../data/TargetNutrientTest.kt`, `src/androidTest/.../data/TargetNutrientPreviewAndroidTest.kt`. Bounded reproducible Debug runner: `scripts/{run-target-nutrient-validation.py,target-nutrient-tests.init.gradle}`. Existing report and plan checkpoint updated; no new unrelated docs.

Baseline/current exposed HEAD **`b67126aed4c7f0474207626803f0258ef291ba0c`** (initial clean source). Native/test/script binary diff SHA-256 against that baseline: **`2315c062ab84a0cdc5b37de25668c6a6e74bc7c9bc913acda7d65b91598ab13c`**, including new tool-staged files (`git diff HEAD --binary -- ios android-vinetrack scripts`). Final managed commit is unavailable before save, not invented or confused with baseline. Scoped whitespace PASS; no SQL/Supabase, version/signing/Xcode project, TripTrackingService or Android TripsScreen delta. No manual Git writes.

### Remaining physical-device acceptance — release remains forbidden

**iOS (iPhone, then iPad):** actual verified admin opens the existing Fertiliser Calculator and sees Target Nutrient; non-admin does not. Enter all four examples using the real keyboard/Done, change N->Ca->micronutrient->Other without losing percentage/target, confirm required label/density source and blocked oxide/unknown states. Verify manual and multi-block Actual/Assumed totals, missing-count explanation, small liquid quantities, regional area/volume, phone result placement and iPad two-column/large-text reflow, light/dark and VoiceOver. Inspect an approved unsupported-record fixture read-only with saved analysis and no completion/deletion/save affordance. Confirm original offline records/pending Sync Status survive navigation/relaunch; no cleanup or production writes to force a pass.

**Android (Samsung phone, then tablet):** same numeric, label/density, product/manual, block/count and non-admin cases through the real existing destination. Test numeric keyboard/comma and dismissal, large Samsung text/rotation/back/return, phone result placement and tablet Calculator/Live Results columns, TalkBack/light/dark and small-volume precision. Confirm original unsupported mode/analysis/units stay read-only and original queues/records remain after offline process relaunch. Compose saved-state and scoped preference tests are lower evidence than this physical journey.

Authenticated live access/transport and conditional remote deletion holds were not exercised against production; no database credentials were requested. No physical handset/tablet installation, TestFlight/Play submission, production release or deployment occurred. **Do not release until handset acceptance and explicit owner approval.**

## Focused Android physical left/right rows — 18 October 2026 — corrected; focused validation PASS; Samsung acceptance pending

Owner reports the redesigned Live Trip works well in actual Samsung field testing, with missing left/right labels in Free Drive. This supersedes the source freeze ONLY for physical row-side presentation and necessary immutable current-fix display wiring. No Play candidate rebuild/export/upload/distribution, version/signing change, production record access, handset installation, backend or iOS change.

### Root cause and focused correction

- `ActiveTripHud` required an occurrence document and a selected target matching the row lock before producing `physicalSides`; genuine Free Drive has no such document. Legacy planned trips were also excluded. `OccurrenceTraversalTracker.adjacentLabels` used **camera** bearing, which is not the operator's travel direction. The surrounding render gate required **both** sides and the Row Tracking preference was loaded only once. An otherwise blue visibility toggle therefore offered no explanation for unavailable/disabled guidance.
- Read-only `LiveRowSideGuidance` resolves the actual containing same-vineyard block using `TripBlockResolver`/`RowAttachment`, respects declared trip block scope, and refuses overlapping/ambiguous block polygons. `PinAisleGeometry.approximateAisle` is used only to distinguish unavailable geometry from poor accuracy, never as row authority. Its qualified `aisleContaining` and `rowOnSide` resolve **actual mapped segments** and operator sides. There is no nearest-number +/-0.5, planned target/cursor, occurrence ID, row-lock confidence or camera bearing dependency.
- Uses saved `calculationRowNumber` for displayed numbering, including decimal/reversed/non-consecutive labels. Oppositely encoded segment endpoints do not change physical sides. Fresh GPS course at >=1m/s (existing shared minimum) and within30 degrees of either along-row direction is required; no stationary-heading default. A fix older than5s, future timestamp, missing/invalid coordinates/accuracy/course, ambiguous geometry, cross-row course or headland yields an explicit waiting/outside state. A true course of0 degrees remains valid.
- Accuracy for two bounding rows follows the existing shared PinAisleGeometry contract: valid uncertainty must be smaller than the full mapped aisle width; no recorder or shared geometry thresholds changed. If only one outer mapped row is reliably known, the read-only fallback requires saved spacing, an interior segment projection, accuracy <half spacing, offset clear of uncertainty and <=0.75 spacing, and an along-row course. It displays only that known row, **not** an invented aisle or opposite label. Both chips render independently.
- `AppUiState.rowSideMovementSample` carries the same already-accepted immutable live sample beside the existing speed/course/accuracy/timestamp fields, reset at the same start/stop points. This is necessary because persisted route points intentionally omit sub-metre movement and cannot be used as the current position. The AppViewModel delta is exactly5 added lines (field/documentation, two clears, one assignment); no GPS callback, recorder, row-lock transition, auto-completion, journal or tank action changed.
- The existing row toggle is blue only when visibility AND saved Row Tracking are enabled. A disabled preference explains **Row labels disabled in Preferences · Row Tracking**; the existing preference is observed through a registered listener and reloaded on foreground return. Display freshness expires on a1s UI timer even without GPS callbacks. STOP hides guidance, and return requires current/fresh evidence newer than the last STOP boundary. No persisted trip/GPS data is cleared or rewritten. There is no new row-configuration UI or broader layout redesign.
- iOS source was inspected, not changed: its floor/ceil labels and default direction assumptions are intentionally not copied into this geometry-qualified Android correction. RowLockTracker and shared helper implementations were inspected/reused, not altered or fed new evidence.

### Files changed

Production:
1. `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/LiveRowSideGuidance.kt` — new pure display projection and conservative one-sided geometry.
2. `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/TripsScreen.kt` — replace occurrence/camera/latching gate, reactive visibility/freshness, independent chips, unavailable states and side accessibility labels.
3. `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt` — only the5 read-only sample wiring lines described above.

Validation/evidence:
4. `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/LiveRowSideGuidanceTest.kt` —15 focused projection tests.
5. `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/LiveTripLayoutAndroidTest.kt` —2 focused production HUD tests, isolated UI preference context, controlled row fixture and explicit screenshot transport probe. Existing test/actions retained.
6. `scripts/row-side-tests.init.gradle` and `scripts/run-row-side-validation.py` — bounded Debug-only15 new +7 existing guidance tests and app/test compilation, no Play calls.
7. `docs/reviews/live-trip-ui-evidence/free-drive-physical-row-sides.webp` — actual production Compose overlay, controlled mapped-row/movement input, satellite renderer explicitly excluded.
8. This existing report and approved plan checkpoint — scope/results/identity/field handoff only.

### Focused executed validation — latest coherent source, counts not summed

| Surface / owner criterion | Result / evidence | Limit |
|---|---|---|
| Free Drive + physical bounding rows | Host `freeDriveUsesPhysicalBoundingRowsNotAnyPlannedPath`; native Free Drive test; inspected capture shows Left12 / Right13. | Synthetic mapped rows/accepted sample, not fused GPS or actual satellite tiles. |
| Reversal / north-up / numbering | Host opposite-course, reversed/non-consecutive numbering, reversed segment orientation and decimal-number tests; native180-degree reversal and map-orientation-toggle invariance. | No physical compass/course accuracy claim. |
| Legacy planned / occurrence identity | Host legacy target108.5/103.5 independent of physical12/13; occurrence same-label identity/document/target unchanged; native planned Done0.5 remains while physical12/13 is shown. | No new occurrence backend capability/handover acceptance. |
| Low speed / stale / weak / headland | Host low/missing/invalid course/speed, future/stale/null fix, missing/NaN/negative/full-width accuracy, cross-row/outside/headland cases. Native stationary and stale states hide labels; fresh input restores them. | Speed below1m/s intentionally waits; no held direction guess. |
| Toggle / preference | Native actual Toggle off/on, registered saved-preference false/true observation and explicit disabled text. | Isolated native preference namespace, no user settings mutated. |
| Multi-block / partial side | Host actual position moves between two blocks, excludes foreign vineyard/unselected blocks, rejects overlapping polygons/duplicate geometry identities, preserves one known single/outer row. | Current declared trip block scope respected; no unrelated block fallback. |
| Background/return | Native controllable LifecycleOwner STOP/START suppresses old input until fresh evidence; composition disposal/return retains identical Trip, original2 GPS points/tank sessions and device active UUID. | Synthetic lifecycle events + real Compose disposal, **not** an actual OS/background/process-death Samsung journey or queued-HTTP acceptance. |
| Host selection | **22 passed /0 failed /0 errors /0 skipped**:15 LiveRowSideGuidanceTest +7 unchanged LiveTripGuidanceTest. Final runner **BUILD SUCCESSFUL in3m41s**, including assembleDebug +assembleDebugAndroidTest; XML counts checked. | Only this focused selection executed; no broader traversal/sync/calculator suite rerun. |
| Native production Compose | **2 passed /0 failed /0 skipped,16s**: `freeDrivePhysicalRowsToggleDirectionPreferenceAndReturnPreserveEvidence`, `rowSidesStaleLowSpeedAndFreshReturnLeaveSavedActionUntouched`. | Existing isolated native app/storage + intercepted-only HTTP harness; live backend/real GPS/OS process not exercised. |
| Final managed correctness build | **runChecks(android-vinetrack) PASS** after final source. | Validation artifact only; not an approved compatible Play candidate, AAB or distribution. Two pre-existing asset-address advisories left untouched. |
| Screenshot extraction | Explicit `exportPhysicalRowSideEvidenceOnly` diagnostic produced both asserted visible sides, then intentionally failed with **Evidence transport probe only** to retain bounded image chunks. WebP extracted, opened and shown to owner. | Tool summary0 passed/1 failed describes the expected transport probe, **not** an extra functional test or an undisclosed assertion regression. Normal suite entry is gated to explicit probe-method selection. |

Development disclosure: initial cold compilation began before the one-sided branches were complete; the first22-test result was20 passed/2 failed in the newly added one-sided cases. A bounded read-only review identified the missing multi-row outer-edge fallback. Completed that branch and its dedicated negative/headland assertions; the final settled-source22-test run above passes. No recorder/threshold/action assertion was weakened. Native functional selection passed first run; screenshot-probe failure is intentional and separately labelled, not automatically retried. The Android testing skill file was absent in this session; the existing project's isolated instrumentation conventions and supported test tool were used.

### Frozen correction identity and protection checks

- Available baseline/HEAD: **`644829978563c87e028f6faa8123656b455d353d`**. This is **not** the new correction commit. Final managed commit SHA is unavailable before end-of-turn save; read it at the next checkpoint rather than inventing or reusing the baseline SHA. No manual Git commit/push.
- Exact Android +validation-script binary diff SHA-256 against that baseline: **`3c742fbc72744fba55e347a1773b3d35c0e222909d805029eb7c8fbf173ccc74`** (`git diff HEAD --binary -- android-vinetrack scripts | sha256sum`, includes tool-staged new helper/tests/scripts).
- Ordered7-file source/test/script checksum-manifest SHA-256: **`5dce3f0725c4606bc156411d6a9db77b9c11aa07c08e5123146b583c415bf9a5`**. Order: LiveRowSideGuidance.kt, TripsScreen.kt, AppViewModel.kt, LiveRowSideGuidanceTest.kt, LiveTripLayoutAndroidTest.kt, scripts/row-side-tests.init.gradle, scripts/run-row-side-validation.py, using their full paths above. This supplements, not replaces, the patch identity.
- `git diff HEAD --check` PASS. No differences under iOS, SQL, Supabase, Android main/data or app/build.gradle.kts. VM diff independently inspected as exactly5 additions; existing row-lock/recorder/traversal, Done/Skip/Undo, occurrence identity, tank/Actual/End Tank, calculator, Quick Actions, ownership/outboxes and historical authorities remain untouched. Main HUD layout hierarchy/map sizing/dock/actions remain as accepted, except the requested row overlay/status.
- Initial only two managed history files differed; preserved. VersionName3.1.7/code12/package/signing configuration unchanged. No original Samsung/session/customer record accessed. No Play access/export/upload/distribution, data clearing, uninstall, queue reset or backend operation performed.

### Specific Samsung field checklist — after separately approved compatible update only

1. Before update/test, record installed version/build, Samsung model/text setting, original Trip UUID, tank/session/Actual IDs (if present), GPS point/evidence indicators and complete Sync Status including warnings/pending work. Do not clean up any history/queues to pass.
2. In a safe non-chemical Slashing Free Drive trip, enable Row Tracking and the blue row-label toggle. Travel centrally along a known mapped aisle with a fresh fix and >=1m/s travel; compare **both actual saved vine row labels** with physical rows. Capture screenshot and timestamp/course/speed/accuracy evidence when stationary safely or through a passenger.
3. Drive the same aisle in the opposite direction. Left/right must reverse even with map north-up; switch north-up/heading-up and pan/rotate the map without changing the physical side meaning.
4. Repeat in a reversed/non-consecutive-numbered block. Check true saved labels, not numeric +/-0.5. Cross into another in-scope block: no prior/foreign rows retained. Outside mapped polygons, headlands, cross-row travel or ambiguous overlaps must not fabricate an aisle.
5. Stop/crawl below the shared1m/s course threshold, lose freshness or obtain uncertainty spanning the aisle. Expect waiting text instead of guessed/old sides. Fresh along-row travel restores them. At a verified outer row where only one side is reliable, show that side only; no invented opposite row.
6. Toggle off/on. Disable Row Tracking in existing Preferences: button must not remain misleadingly blue, and disabled explanation appears. Re-enable and return: current valid labels return without changing the trip/recording.
7. On a legacy mapped trip, verify physical sides while saved/action path differs; Done/Skip/Undo targets/progress must remain unchanged by labels. Where an occurrence trip is already supported, repeat with separately selected same-number passes: labels do not select/credit another UUID. Do not activate unsupported backend capabilities just to test this correction.
8. Background/foreground, rotate and return/relaunch as separately safe. Verify one original active trip/tracker, original GPS points, tank/Actual identities, offline writes/warnings and Sync Status retained. Labels require fresh current evidence, not a planned/camera fallback. The existing foreground-only recording limitations are unchanged.
9. Capture normal and enlarged-text row-label screenshots with toggle/preferences state plus the actual mode/block/direction/accuracy. Report any clipping/overlap or incorrect side with exact timestamp and original IDs. Do not press unrelated tank/end/action controls merely to obtain a display result.
10. Stop on a safety-critical wrong-side/recording/recovery failure; retain original evidence and report the exact state. No uninstall, storage/queue clearing, forced signing, warning deletion or historical rewrite. Return for approval before any Play candidate build/upload; no production release authorised.

## Controlled Samsung acceptance / Play candidate preflight — 17 October 2026 — source verified; candidate BLOCKED

Owner provisionally approves the completed layout for controlled Samsung testing, not final visual acceptance or production release. Application source remains frozen. This checkpoint performs source/evidence review only; no build, test rerun, version increment, signing, AAB generation, Play upload, distribution or handset operation.

### Final frozen Android source — equivalence CONFIRMED

- Supplied commit exists locally: **`2ad48e30d6f0cc9b174375f4d6dcbacb9a1baa02`**, authored/committed 17 October 2026 04:53:16 UTC. Owner reports GitHub visibility; no new remote fetch or Git write was needed.
- Exact baseline-to-commit binary Android diff hash: **`cdd4710df3e99092cc479f24019c6086c78120adb47f1f6e30e35936549931fd`**, identical to the frozen tested patch recorded below. Command: `git diff bac3cb62450abf2d68ec7816042afae3966b2741 2ad48e30d6f0cc9b174375f4d6dcbacb9a1baa02 --binary -- android-vinetrack | sha256sum`.
- Both supplied commit and current checkout have Android Git tree **`e14325113de07dddc85a2971bdb7d695b0f1af91`**. `git diff 2ad48e30d6f0cc9b174375f4d6dcbacb9a1baa02 --exit-code -- android-vinetrack scripts docs/reviews/live-trip-ui-evidence` succeeds with no differences. Initial current managed HEAD: `c78f4147e530fdad60b1986f780c92c1c2e8a9b1`; initial workspace clean. This newer managed HEAD does not imply newer Android implementation.
- Commit delta contains exactly the five Android production/test files listed in the previous checkpoint. Protected Android data, AppViewModel and build/version/signing file have no baseline-to-commit changes. SQL/Supabase are unchanged. Do not claim whole-repository identity: managed state/plan files differ, and generated `ios/VineTrack/Config.swift` is present in the supplied commit but absent in this current checkout. No iOS source was edited to reconcile that generated-file difference.
- The retained **13 native / 52 host passes and final build PASS** attach to this exact Android source via the matching tested patch. They are existing results, not new executions. No reason to repeat broad tests while source is unchanged. No code changes this checkpoint, so no fresh runChecks/build required.

### Final presentation review — evidence level, not a handset PASS

| Criterion | Existing evidence and conclusion | Remaining limit |
|---|---|---|
| Saved action versus detected path | `TripsScreen.kt:1972–1991,2248–2264,2279–2285`: saved/document guidance remains CURRENT / ACTION PATH. Fresh confident numeric disagreement >=0.5 while unpaused renders **GPS detects [X] · planned [Y]. Confirm your path below.** `LiveTripGuidanceTest.legacySavedCursorNotGpsDetectionDefinesAction` retains saved target despite different currentRowNumber. | No retained screenshot specifically shows the mismatch banner. This numeric comparison does not itself prove cross-block same-label disagreement detection. Physical acceptance must verify real context and banner fit. |
| No false GPS confirmation | CURRENT / ACTION PATH comes from saved cursor/occurrence document, not physical row detection. GPS QUALITY is independently labelled; fresh accuracy/confident-lock gates the mismatch. Weak/stale native case retains saved guidance; it does not declare that target GPS-confirmed. | A GPS quality label is a quality indication, not row/pass confirmation. No real GPS accuracy claim. |
| Mapped versus Free Drive | Inspected `planned-active-tank.webp` and `free-drive.webp`; Free Drive has Not planned and no invented progress/Done. Host/native mode tests already passed. | Actual handset mapped/Free Drive screenshots pending. |
| End Tank versus End Trip | End tank is a labelled orange tank action with the existing tank confirmation. End Trip is a separate red stop icon with accessibility label and the existing parent review callback. Native tank cancellation/confirmation and trip callback evidence retained. | Main-dock End Trip is icon-only, not visible text; its real-user clarity remains Samsung acceptance, not claimed unconditionally unambiguous. Secondary sheet has explicit End Trip text. |
| Skip / manual selection / Undo | Path actions menu explicitly exposes Skip/select; existing bounded sheet and picker retained; main Undo and exact Done target remain. Native actual-action, pass-selection and fixed sheet transport tests passed. | Disabled Undo with no eligible action is expected. No new physical touch/gesture acceptance. |
| Normal / enlarged text | Inspected normal and 320dp/1.5× imperial captures; production native rendered-line checks passed with <=1 physical pixel intrinsic rounding allowance and no max-line truncation. | Representative fixture labels only, not arbitrary long titles/block names or mismatch banners at every system size. |
| Short map controls | Under 240dp map height, controls reflow to 2×2; inspected enlarged capture and retained >=48dp displayed-target assertions. | Renderer excluded; real map touch routing not proven. |
| Useful flexible map | Weighted map sits between fixed information and content-sized dock; no expanded nonessential details in main HUD. Normal and enlarged captures retain visible map. | Existing assertion is only >=100 physical pixels, not a universal minimum-dp usability guarantee. Long content, mismatch, Samsung navigation insets, rotation and real vineyard density still require acceptance. |

No demonstrated new acceptance defect was established in this review; no redesign or speculative code/test changes were made. The limitations above must not be turned into unqualified all-screen visual acceptance.

### Google Play preflight — BLOCKED, no exact candidate approved/proposed

The advertised Play connect/preflight/publish workflow files are absent in this session (all three reads return file-not-found), and no typed Android Publisher access tool is exposed. The available CLI help exposes no Google Play read operation. Prior connection/build listing from earlier sessions is historical only, not current Console evidence. No speculative tool invocation, private API bypass, credential extraction or Play mutation was attempted.

| Required candidate fact | Verified status |
|---|---|
| Package / source | `com.rork.vinetrack`; frozen Android source commit **`2ad48e30d6f0cc9b174375f4d6dcbacb9a1baa02`** confirmed above. |
| Existing Samsung testing track / release | **UNKNOWN**. Do not assume internal/closed/open, or infer enrollment from a generic build listing. |
| Highest previously used versionCode | **UNKNOWN**. Local Gradle code12 is not Play history; no claim that13 is available. Need Console bundle/release history including non-active uploads and relevant form-factor tracks. |
| Play App Signing certificate / lineage | **UNKNOWN**. Need Play Console App integrity certificate SHA-256 and any signing-key upgrade/lineage details relevant to this Samsung. Historical upload-signer hash is not the Play-delivered app signer. |
| Managed AAB upload route | Gradle release block documents managed persistent project upload-key injection during AAB export; ordinary local release config uses debug signing. This proves intended configuration only. Actual managed key identity/registration, export job support and source-to-AAB provenance are **NOT VERIFIED**. Do not substitute a local Debug/Release APK. |
| Proposed versionName | Retain3.1.7 unless separately approved; no metadata edit made. |
| Proposed new versionCode | **NOT SELECTED** until authoritative previously-used maximum and update eligibility are known. It must exceed that maximum, remain valid, and be rechecked before upload. |
| Candidate artifact | **NONE**. No AAB generated or selected; no artifact hash or export provenance fabricated. |
| Distribution | **NOT AUTHORISED YET**. Return exact source, numeric code, track/release, registered upload certificate, Play signing identity and managed build route for owner approval before any Play distribution. No production deployment. |

Unblock with restored supported Play Console access, or owner-supplied Console exports/screenshots of (1) testing tracks/releases/versionCodes/tester eligibility, (2) App bundle explorer uploaded-version history, and (3) App integrity App signing and Upload key certificate SHA-256s/upgrade details. Console exports alone do not prove a future managed exporter can use the registered upload key; that route/provenance still needs supported verification. Do not request private keys or keystores in chat. Do not reserve/bump a guessed code, switch tracks or create a release merely to inspect state.

### Physical acceptance and release review — all PENDING

No physical Samsung control/connection is available here; no installed-device IDs, Sync Status, GPS evidence or real screenshots were obtained. This gate requires owner-operated handset observations (or separately available authorised device access), never simulator substitutes. After separately approved compatible Play delivery, upgrade the existing Play installation in place only; do not uninstall, clear storage, reset queues, change identity or force signatures.

**Before testing**, record device/model/Android version, installed versionCode, test track/account eligibility, original trip UUID, active tank session UUID/number and Actual identity, and full Sync Status (pending/held/warnings). Capture timestamps and original GPS point/evidence indicators. Keep private operational IDs/screenshots in the owner's controlled evidence handoff; do not commit customer records or tokens to this report. Take baseline before update as well as before the journey when possible. This session has no actual baseline values.

Execute all12 owner criteria using a non-chemical test journey: (1) header/strips/map/dock; (2) normal and enlarged text/system navigation; (3) real satellite/trail/puck/boundaries/rows/relevant pins/performance; (4) follow/recenter/pan/heading/zoom/control taps; (5) honest Free Drive; (6) correct mapped action/next/progress and mismatch context; (7) independent same-number occurrence passes where supported; (8) Tank1 Actual/Mix/End Tank/next tank; (9) exact Done/Skip/Undo/Pause/Resume/End Trip protections; (10) offline Repairs/Growth return; (11) background/foreground/rotation/relaunch retaining the one original trip/tracker/GPS/tank/outbox; (12) reconnect with original operations/no duplicates. Confirm any intended recording pause or foreground-only limitation explicitly rather than assuming a background service was added.

**Stop immediately on any safety-critical failure.** Record exact version, timestamp, step, original IDs, visible warning and Sync Status; preserve queued work/GPS and report the hold. No destructive recovery, historical warning cleanup, backend bypass or speculative fix during acceptance. Do not make chemical-use records merely to pass the test. If a prerequisite such as supported occurrence capability is unavailable, mark that case blocked; do not deploy backend changes or convert legacy history.

Release review must include actual Samsung normal/enlarged, mapped, Free Drive and active-tank screenshots, observed map/GPS results, before/after original identities and sync evidence, retained automated results with their fixture limits, and all unresolved failures/gates. Existing authenticated/backend/occurrence/Portal gates remain unchanged. **No production release. Next approval gate is successful physical Samsung acceptance, not the source review in this checkpoint.**

## P0 Android Live Trip presentation — 17 October 2026 — source frozen, handset gate OPEN

The owner reports Start Trip, Tank 1 Actual confirmation and recording working on the latest Samsung test. This checkpoint changes only Android Live Trip presentation and directly required state-to-display wiring. It does not reopen the Trip engine or Play publishing. Supplied Samsung/iOS images were inspected alongside both actual implementations.

### Source-backed cause and correction

The old `ActiveTripHud` layered two rows of large translucent statistics, GPS/ETA and Quick Actions over the satellite map. A separate rounded, scrollable bottom panel stacked transport, path controls and tank controls. Its independent overlay measurements, vertically stacked controls and hidden secondary controls produced the poor hierarchy and wasted map/control space. Missing sequence values were rendered as two dashes without distinguishing Free Drive from planned recovery. **The supplied Samsung screenshot's original saved trip/occurrence state was not independently available; the dashes are not proof of a GPS/path-detection defect.**

The same production HUD now uses:
- Fixed opaque header: Back, Recording/Paused and offline status, tappable Spray Record/Trip title and existing options. No new navigation or activation route.
- Equal-width orange/green Repairs/Growth buttons immediately below the header, using the existing launch/return handlers.
- Equal-width Current / Next / Distance / Duration columns; Speed / GPS / Remaining strip; actual pattern, sequence position and separately labelled Done/Skipped progress. At enlarged font scales facts deliberately reflow to two columns.
- A genuinely flexible central map, not a full-screen map obscured by information overlays. Existing satellite/hybrid, puck/heading, recorded display trail, follow/recenter, orientation, row-side toggle and selected boundaries remain. Follow zoom is still stable across location ticks; UI-only follow/orientation/zoom/layer preferences are saveable across view restoration. A short map reflows its controls into a 2×2 cluster, rather than clipping the fourth button.
- Content-sized safe-area dock: explicit current/action path, saved block/pass context, route access, tank status/Mix/End Tank, Undo, exact-target Done, Pause/Resume and distinctly red End Trip. Large text gives transport its own row rather than making Done a tall circular button. Free Drive shows recording status instead of disabled meaningless path actions. Paused tank actions remain disabled; Mix remains inspectable.
- Existing Skip / I'm on this path / Return to Auto in a bounded secondary path sheet. Pause/Resume, End Trip and return remain fixed outside its scrolling details. Existing occurrence confirmations retain their frozen IDs; existing End Tank and parent End Trip review/confirmations are preserved. An already-running fill exposes Stop Fill even if the optional fill-timer preference is subsequently off; this changes visibility, not fill persistence/logic.

### Authoritative display distinctions

`LiveTripGuidance` is a read-only projection, not a second planner, tracker, journal or recovery authority.

| Case | Display / authority |
|---|---|
| Legacy planned sequence | Current/action is the existing saved action cursor, matching the existing Done operation, not the GPS-detected row. Next is a subsequent untreated entry, excluding existing Done/Skipped membership. Legacy numeric/duplicate-label coverage semantics are preserved. |
| Occurrence planned trip | Resolve current/action, next incomplete work, block, pass, position and counts from the existing document and occurrence IDs. Same-number passes remain independent; a selected pass does not become Done merely because it was selected. |
| Genuine Free Drive | Explicit Free Drive, no planned next path, no sequence/progress count, no fabricated ETA, no meaningless path buttons. A detected physical row is not adopted as a plan. |
| Missing planned recovery / unsupported document | Waiting for plan / Recovery required, not an invented Free Drive plan or numeric downgrade. Essential transport controls remain available. |
| Waiting for qualified GPS | Saved guidance remains visible. Live detection/wrong-path warning uses the existing confident lock plus a fresh accuracy observation; it cannot silently change the action target. |
| ETA absent | Existing estimator only. Not planned / Waiting for GPS / Need travel data / Paused / Filling tank / recovery context replaces a misleading finite duration. No ETA, traversal or route-planning algorithm was changed. |

Distance, speed, accuracy source and tank water retain base-unit authorities. Tank water is resolved from the exact confirmed Actual/session when available and formatted using the vineyard's `LocalRegionFormatter` (L or configured gallons); planned water is explicitly Planned and missing Actuals explicitly unavailable. No planned amount is relabelled measured remaining water.

### Exact source/test/tool files changed

Production:
1. `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/TripsScreen.kt` — existing HUD layout, compact variants of existing row/tank controls, secondary controls and map-layer wiring.
2. `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/LiveTripPresentation.kt` — read-only guidance projection and production information strip.
3. `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/VineyardMapScreen.kt` — only expose the existing validated pin-location helper and existing pin renderer as internal for reuse; no alternate pin implementation.

Tests:
4. `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/LiveTripLayoutAndroidTest.kt`.
5. `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/LiveTripGuidanceTest.kt`.

Reproducible validation/evidence utilities:
6. `scripts/run-live-trip-ui-validation.py`.
7. `scripts/live-trip-ui-tests.init.gradle`.
8. `scripts/extract-live-trip-ui-evidence.py`.
9. `scripts/compare-live-trip-ui-evidence.py`.

Existing report and approved plan updated. Visual assets are under `docs/reviews/live-trip-ui-evidence/`: supplied `reference-android.png`, `reference-ios.png`; actual Compose captures `planned-active-tank.webp`, `free-drive.webp`, `paused-trip.webp`, `narrow-large-font-imperial.webp`; labelled `before-after.webp` and `ios-android.webp` comparisons. Intermediate blank/older diagnostic images were removed, not presented as final evidence.

**Protected trees are byte-unchanged against the starting baseline:** iOS, SQL, Supabase/Edge, Android build/version/signing configuration, all Android main/data authorities and `AppViewModel.kt`. No calculator, chemistry, CF, Start receipt/recovery, actual commitment, sync ownership, GPS attribution/traversal, historical record or production-data mutation. Keep-screen-awake remains in the unchanged production TripDetail owner; no new background service or tracking state.

### Final focused validation — latest coherent source, not accumulated attempts

| Surface | Final result | Evidence and limits |
|---|---|---|
| Native production Compose | **13 passed / 0 failed / 0 skipped, 31s** | `LiveTripLayoutAndroidTest` 11 + existing `OfflineQuickActionsAndroidTest` 2. Actual HUD, existing VM/actions, namespaced native preferences, synthetic retained account/trip/Actuals and intercepted-only HTTP. No live service fallback. |
| Host guidance/traversal/journal | **52 passed / 0 failed / 0 errors / 0 skipped** | `LiveTripGuidanceTest` 7 + unchanged `OccurrenceTraversalTrackerTest` 15 + unchanged `TripOccurrenceJournalTest` 30. Final Debug-only validation runner succeeded in 15s, including app and instrumentation APK assembly; XML counts checked individually. Synthetic evaluator/journal evidence, not field traversal. |
| Debug app/test builds | **PASS** | Actual `assembleDebug` / `assembleDebugAndroidTest`, including focused native execution. Not a compatible Play update artifact. |
| Final managed `runChecks(android-vinetrack)` | **PASS** | Managed APK compilation/signing validation only; no Play/AAB publish flow or handset distribution. Two non-blocking pre-existing asset-address advisories outside this HUD correction were left alone. |
| Scoped source whitespace/protection diff | **PASS** | `git diff HEAD --check`; protected source comparisons unchanged. |
| Visual inspection | **Captured and inspected, with explicit renderer exclusion** | Production HUD fixtures, not a recreated alternate UI. Before/after and iOS comparisons shown to the owner; no claim that their before/after images depict the same original trip or same device. |

Native methods cover:
- `plannedRowActiveTankCompactAndActualWater`: current 0.5 / next 2.5, confirmed Actual 581.7 L, Tank 1 of 2, visible 48dp transport/map targets, flexible non-overlapping map/dock, existing route/end callbacks and no duplicate session.
- `freeDriveHasRecordingNotMeaninglessPathButtons`: Tank 1 of 1, Free Drive/Not planned, no Done or sequence progress.
- `narrowLargeFontImperialAndStaleGps`: 320dp, 1.5× font, feet/gallons, Searching/stale, deliberate facts/actions/map-control reflow. Rendered line bounds checked, with only one physical pixel allowance for intrinsic rounding; no max-lines truncation accepted.
- `pauseResumePreservesTripTankAndEvidence`: real production commands, one pause and one resume timestamp, retained trip/session/sequence/two synthetic GPS points; paused End Tank disabled and Resume accessible.
- `doneSkipUndoRemainAccessibleAndUseProductionLegacyActions`: real exact legacy action callbacks and resulting coverage/cursor; secondary-sheet Pause/End Trip visible with >=48dp targets.
- `endTankRequiresExistingConfirmationAndCancellationKeepsSession`: cancel retains the active tank/session; explicit existing confirmation ends that one session without another Actual or tank.
- `occurrencePassSelectionIsGuidanceOnlyThenDoneTargetsOnePass`: select pass 2 via the production picker; no coverage on selection, explicit Done confirmation updates B only, A stays Incomplete.
- `repairsGrowthReturnDoesNotChangeTripOrTank`: actual launch/Back return on both modes, same retained Trip/tank state.
- `disposedHudReturnsToSameOfflineTripWithoutTouchingQueuedWork`: dispose/return through production Back callback and a small fixture host; original Trip, two synthetic GPS points, device-owned UUID and real pending offline metadata operation remain identical. **Composition disposal is not OS rotation/process death.**
- `unavailableAndWeakGpsNeverEraseSavedPlannedGuidance`: stale and weak presentation never replace saved action guidance or fabricate completion.
- `fillingAndSingleTankLargePhone`: 412dp, actual filling state/session, Stop Fill and transport visible, no Done while filling.

Operational Button callbacks use their real accessibility OnClick actions where asynchronous fixture transitions made injected screen-coordinate taps nondeterministic; targets and bounds are separately checked. Quick Actions, route/sheet entry, selection and return also exercise normal injected taps. This is not a physical gloved-operator tap acceptance claim.

Development failures remain explicit: cold local compiles exceeded the 60s shell window; a bounded retained runner completed the coherent build. The first init script registered before Android variant tasks existed and was moved to `projectsEvaluated`. Test compilation caught missing LocalRegionFormatter and an attempted computed `currentRole` constructor input; both fixed in fixtures. Early native selections included 3/8, 9/4 and 11/2 pass/fail results, not final counts. Synthetic session/record IDs were made valid UUIDs; the exact VM session/Actual store was used instead of bypassing its observable authority. Delayed initial empty-install restore legitimately displaced the injected synthetic active trip in wider batches; fixtures now wait for that SignedOut startup boundary before admitting their isolated account and durably saving the owned snapshot. No production auth/ownership safeguard was relaxed. A reported tiny intrinsic text-width overflow is checked against actual rendered line bounds rather than accepting clipping. Visual inspection found and corrected narrow-screen map-control clipping and oversized large-font Done reflow.

The runner only retained diagnostic streams on failure. Explicitly labelled **evidence-transport probes** exported bounded WebP chunks to retrieve real screenshots; those expected probe failures are NOT functional test results or passes. The final test source gates this diagnostic path behind the explicit `captureLiveTripEvidence=true` instrumentation argument; normal tests do not enter it. Failed/truncated initial screenshot exports and the initial blank display screenshot were not accepted. Final functional source passed the separate 13/0/0 selection above. Overlapping runs/probes are never added together.

### Map and lifecycle limits — release gate remains open

- Production uses the real map by default. The test-only `mapPreview` slot replaces only the renderer, explicitly labelled in every capture; statistics, controls, dialogs and handlers are the actual production implementation. These images do not prove satellite tile loading, marker/heading rendering, map SDK touch routing or live overlays.
- Source now reuses the existing configured pin renderer, validated attached coordinates and saved pin IDs. Respect existing showPins/showRowLines defaults; scope to the same vineyard and trip/selected blocks; deduplicate IDs; bound rendering to 250 relevant saved pins and 1,500 row segments. Existing saved pins are shown, not a new synthetic Growth-pin generator. Full iOS density/visibility parity and actual renderer performance need the physical check; no optional parity claim is inferred from compilation.
- No original Samsung trip/document, installed signer or installed GPS evidence was accessed. Genuine OS rotation, app background/foreground, process death/reconnect, live tracker instance counts, screen-awake behaviour and real pending server operations are **not proven** by composition recreation or screenshot pixels. The ownership, Start, tracking and persistence implementations are unchanged, but source preservation is not those runtime guarantees.
- No uninstalls, real app-storage clearing, handset install, Google Play operation, AAB generation or distribution. The managed validation APK is not a proposed replacement for the Play-installed Samsung app. Existing Play track/version/signing preflight remains separate and unresolved.

### Frozen available identity and next physical acceptance

Starting/current exposed managed baseline: **`bac3cb62450abf2d68ec7816042afae3966b2741`**. Final Android source/test binary diff SHA-256 (`git diff HEAD --binary -- android-vinetrack`): **`cdd4710df3e99092cc479f24019c6086c78120adb47f1f6e30e35936549931fd`**. Current Debug APK SHA-256: **`a22b1c8749cc3620da390ec7fdcff47404780d0c04f6687c2944e9d08eb32faf`**, package `com.rork.vinetrack`, unchanged 3.1.7/code12. The final managed end-of-turn commit SHA is not exposed during this turn; the baseline is NOT represented as the redesign commit. No manual commit or push. Read the resulting SHA in the next read-only checkpoint before selecting any future candidate.

**Freeze the application source here. Await owner layout approval and separate approval of an identifiable compatible Play testing candidate; no further unrelated development.** P0 operational release acceptance is still OPEN for:
1. Samsung normal and enlarged text/system navigation: same compact hierarchy, all dock actions visible, no clipping, useful map and unambiguous End Tank versus End Trip.
2. Original mapped legacy and occurrence jobs versus genuine Free Drive; waiting/stale/accurate GPS, selected block/pass, detected-versus-planned warning, exact current/next/progress, no fabricated ETA or changed target.
3. Real hybrid map: boundaries, permitted saved pins/rows, position/heading, original trail, pan/recenter and fixed follow zoom, north/heading-up and row-side controls; performance at actual vineyard density.
4. Original retained Trip/Tank Actuals/GPS and Sync Status before/after opening, rotating, Home/background return and relaunch. Exactly one recording instance; no replacement IDs, missing evidence or discarded queued work. Foreground/background limitations are unchanged.
5. Actual End Tank/filling/next-tank review and Actual confirmation, Pause/Resume, Done/Skip/Undo and manual selected pass; existing confirmations/protections still gate commands. Finish no other pass by numeric label.
6. Offline Repairs/Growth launch/return and original saved pin identities/GPS, followed by authenticated reconnect without duplicate records or queue loss. Preserve all historical evidence; never clear/uninstall to force acceptance.


## Bounded Android calculator Start journey closeout — 16 October 2026 — SOURCE FROZEN

Latest owner instruction authorises only demonstrated production Start wiring gaps. Initial source/index clean at `3cb7040d6d1ec601c52b66878009ce843db66ecf`; managed history changes preserved. The two completed matching corrections and their prior8/8 evidence are reused, not rerun or modified. No calculator/layout redesign, new recovery authority, iOS/SQL/Edge/history/formula/Quick Actions changes, version/signing change, uninstall, real storage clearing, Release build, upload or deployment. No interactive simulator rental.

### A. Demonstrated source defects and bounded correction

Production path inspected and exercised: `SpraysScreen` calculator entry -> `SprayCalculatorScreen` actual Review button -> `SprayTripStartConfirmation` Start Trip Button -> `startJobNow` -> `AppViewModel.startSprayJobNow` -> existing paired save/recovery + existing saved-job activation -> calculator result callback -> `SpraysScreen.onOpenTrip` -> shared `WorkContextViewModel.openCalculatorTrip` (same handler MainScaffold calls) -> controlled selected-trip `TripsScreen` -> `TripDetailView` -> `ConfirmActualTankMixDialog` -> `confirmAndStartTank` -> existing durable Tank Actual/session commitment -> `beginTracking`.

- **Accepted pair unnecessarily depended on row hydration.** `submitPreparedLegacySpray` required both Trip and record reload even after verified immutable paired acceptance. On a reload exception it now permits ONLY the current retained `startRequested` attempt with the exact verified RPC/request and current account to decode the original inactive Trip/linked recipe from its frozen request. It still checks exact trip/record/vineyard links before the existing validation/claim/activation. Cancellation and unauthorized errors do not use this fallback; no old Save-for-Later/history reconstruction, similar-recipe adoption, request rewrite or new IDs. Unknown acceptance remains held until the existing recovery RPC verifies it. Failed metadata hydration is no longer an unnecessary navigation prerequisite.
- **Completion depended on a disposed screen-local callback.** The existing typed Start outcome now carries operation identity, owner/vineyard and explicit inspection identities. AppViewModel retains this PRESENTATION result (not another durable recovery journal); the production MainScaffold's `CalculatorStartDestination` redelivers Ready to the same SavedStateHandle selected-trip/tab handler if the original calculator callback was disposed. Selection is idempotent; no activation call is made by the navigation handler. `TripDetailView` acknowledges only when the correct owned destination is actually composed. The calculator does not mark navigation handled or close before invoking its destination. Disposed callbacks do not navigate; absent destination handlers leave a visible correct-trip message instead of silently dismissing.
- **Inspection was text-only.** Older ambiguous candidates/qualified held identities now explicitly open retained-Start inspection; the view identifies candidate UUIDs, shows the actual reason, offers inspection of an available saved trip, or explains missing rows and unchanged-setup retry. Held/failed uncertain requests expose their original operation/trip and inspection action next to Start. No candidate is automatically adopted or activated. Save for Later remains the intentional separate-job route. Existing recipe validation before saved legacy/qualified activation remains intact; no post-activation failure is reinterpreted as proof of non-activation.
- **Recording refusal could lack a reason.** Missing session operation or location permission now leaves an explicit retained-trip/Tank Actuals message. The same existing first-tank gate still runs before LocationTracker. Missing/unopened first-tank mix has an explicit pending explanation and Review action. No permissions, tank quantities, GPS algorithm or ownership authority is bypassed/cleared.

Nine Android source/test files differ: `data/SprayStartOutcome.kt`, `ui/AppViewModel.kt`, `ui/main/CalculatorStartDestination.kt` (presentation observer only), `ui/main/MainScaffold.kt`, `ui/main/WorkContextViewModel.kt`, `ui/screens/SprayCalculatorScreen.kt`, `ui/screens/SpraysScreen.kt`, `ui/screens/TripsScreen.kt`, `androidTest/.../SprayStartProductionAndroidTest.kt`. All completed matching files, shared input builder, spray-engine/formula subtree and layout components remain byte-unchanged. Historical GPS evidence is not touched and does not become ownership authority.

### Focused executed client evidence — final selection only

**Final7 passed /0 failed /0 skipped,37s**, including Debug app/test compilation. No host suite, previous matching8, broad regressions or additional assemble build was run. Exact selected methods in `com.rork.vinetrack.data.SprayStartProductionAndroidTest`:

| Method | Proven controlled result |
|---|---|
| `calculatorButtonBlankHoursReachesTankThenRecording` | Real calculator UI prefill -> operator confirms equipment -> Create/View Tank Mix -> Start Spray Trip -> blank hours -> callback reaches selected original UUID once -> actual Tank1 dialog, tracking OFF -> press Start recording -> production durable tank session and recording state ON. |
| `calculatorButtonValidHoursAcceptedReloadFailureStillOpensOriginalTank` |123.5 entered via real dialog; paired receipt verified, Trip GET returns503; exact frozen-pair fallback opens correct Tank1 once without waiting for another list read; frozen request/snapshots/IDs/hours unchanged. |
| `calculatorButtonLostReceiptRetryPreservesOriginalAndNavigatesOnce` | Real button loses committed save response; visible inspection/retry, no destination/claim; operator retries with999 hours, receipt recovery + failed reload -> original UUID/request/snapshots and123.5 retained, one create/one destination. |
| `calculatorButtonDelayedResultSurvivesDisposedUiWithoutReactivation` | Controlled delayed receipt, calculator/navigation composition disposed, callback not delivered to disposed screen; retained Ready result survives; recreated production destination observer opens same Tank1, acknowledgment waits for TripDetail; repeated recreation does not activate/create another trip. This is composition recreation, NOT OS-process death. |
| `calculatorButtonLostActivationRestoresSameTankDestination` | Intercepted activation PATCH commits then loses response; original durable active claim/Tank1 selection survives recreation. Existing production sync retry/reconciliation removes the unresolved original TRIP_START marker through read-back, without second activation request, new trip or duplicate navigation. |
| `calculatorButtonOlderAcceptedOpensInspectionWithoutAdoption` | Older-version synthetic accepted-attempt fixture derives from this real button's frozen request plus actual intercepted verified receipt. Retry opens inspection automatically with original UUID; no claim/destination/second create; old bytes unchanged. Not a live old handset record. |
| `calculatorButtonBlockedReceiptShowsInspectionWithOriginalIdentity` | Receipt503 produces visible actual reason and operation/trip inspection with return-to-retained-setup action; no navigation/claim. |

**Evidence limits:** synthetic original actor/vineyard/session and namespaced native storage, no-live-fallback HTTP. Reference catalogue/geometry props are fixed synthetic fixture inputs; startup membership/picker replies are intercepted too. Actual SpraysScreen/calculator/dialog and TripsScreen callbacks render in a small Compose navigation host using the EXACT production WorkContext handler + destination observer, not an entire authenticated MainScaffold shell/login journey. Google Maps Compose `LocalInspectionMode` is enabled only around Trips in the test harness because emulator microG Mapbox threw `LocationComponentNotInitializedException` during teardown; no production map code changed. Production TripDetail, Actual dialog, commit, permission check and LocationTracker execute; the map itself is not rendered/tested. Recording-state ON is not physical GPS samples, location accuracy, background recording or handset acceptance. Delayed response/recreation is not full main-app process death.

Development evidence is not hidden: first compile failed from missing fully qualified SupabaseClient/AlertDialog names (fixed); initial UI selector matched three equipment texts (narrowed to Button semantics); paused test clock stalled scrolling (one600s infrastructure timeout and a bounded90s timeout, then automatic clock restored); lazy offscreen nodes needed scroll-to-node; an older synthetic preference fixture initially omitted required nullable fields (fixed with the store's exact JSON defaults); incidental empty startup picker/catalogue replies erased synthetic selection/products (fixture now returns synthetic membership/picker and retains synthetic reference props). Dialog confirmation uses the real Button semantics action to avoid the emulator IME covering a touch coordinate. The map-renderer crash above was isolated only in the harness. Earlier overlapping7-case batches included3/4 then6/1 results; final7/0 is the only final count, not a sum. No matching assertion was weakened or matcher changed.

### B. Tested source

Available committed baseline **`3cb7040d6d1ec601c52b66878009ce843db66ecf`** already contains both matching corrections. Tested Android binary-diff SHA-256 **`d01d0db7564a70425337f43977523329b24f1e8271d33f73c24fab3db7bdb7df`** (`git diff HEAD --binary -- android-vinetrack`, includes staged new observer). Final managed fix commit is unavailable before this turn saves; baseline is NOT presented as the fix commit. Scoped whitespace PASS. No manual Git commit/push. Source frozen after the passing selection; no further source changes/build loops.

### C. Existing device-testing artifacts — distribution blocker, not more development

- Current local **Debug** `android-vinetrack/app/build/outputs/apk/debug/app-debug.apk` contains this tested correction and both preceding matching fixes. SHA-256 **`872fb72817d934f255db3f9de417a1c730336923cce15936b0489a4b99b81d13`**, package`com.rork.vinetrack`,3.1.7/code12, min24/target36, manifest verified. Signature verification PASS; signer SHA-256 **`2be3dd871ef1b19723becbf8d556099274af3b740fd98ae3e5cfdaa6a3c000ce`** (Android Debug).
- Existing signed device candidate at `.../release/app-release.apk` remains SHA-256 **`8af712194eb7a3a31fd7c3b4d3c4413b948a99a09e64b4c1a4950f62e3756943`**,3.1.7/code12, signer **`241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3`**. It is the older exact-fixture candidate recorded below and does NOT contain the subsequent matching or this navigation correction. It is NOT handed back as a valid corrected test build.
- **No verified compatible corrected in-place handset artifact exists here for that release-signed installation.** The corrected Debug signer differs. In-place use of Debug would be safe only if the installed app already has that exact Debug signer and an allowed version; the installed signer/hash is unknown. Do not uninstall or clear data to force compatibility. A corrected artifact signed compatibly with the installed candidate (or its actual store signing lineage) is the specific distribution blocker. No new distributable/Release/signing/upload operation was created or authorised in this pass.

### D. Remaining handset acceptance — unchanged release boundary

On an identifiable corrected, compatible in-place candidate only: (1) blank/valid-hours Start reaches correct Tank1 confirmation, (2) confirmation enables permitted GPS on Live Trip, (3) interrupted operation/relaunch resumes original IDs/recipe/hours without duplicate activation or navigation. Verify actual installed signer/build/hash first; retain all storage. Original handset failure branch remains unestablished without its runtime/claim evidence. Controlled HTTP/UI results are not deployed authenticated receipt/RLS or real GPS acceptance. This is the single frozen handoff; no further audit/matching-refinement cycle or deployment is authorised.

## Limited Android Start matching correction — 16 October 2026 — SOURCE FROZEN

Owner approval is limited to unchanged-recipe timestamp recovery and older accepted-attempt inspection. Completed Quick Actions, Spray/layout, ownership/receipt verification, historical GPS evidence, formulas and Tank 1 Actual-before-GPS protections are preserved. Initial source/index clean at `919f32094f60d3d9c286d0b09f8539a18fedbc60`; only managed history differed. No production/customer access, database/backend changes, version/signing changes, Release build, distribution/deployment, uninstall or app-data clearing. Instrumentation uses the existing isolated synthetic storage namespace and intercepted-only transport; its fixture cleanup does not clear real retained app storage. No interactive/new paid simulator requested.

### The two corrections only

1. `Attempt.matchesStartInput` compares every chemical snapshot fact and its presence, with one narrow exception: when BOTH snapshots' `capturedAt` values are their respective application `startTime`, compare the candidate using the original capture clock. Generated tank/line IDs and application date/start clocks remain comparison-only normalization. No frozen request, operation/trip/record ID, original input, chemical evidence or hours is rewritten. A foreign explicit parent, product/rate/quantity/water/block/equipment change or other classification/registration/provenance change cannot resume the old job. A non-generated snapshot clock change also remains a mismatch.
2. `olderAcceptedMatch` returns all scoped verified older candidates, not the first similar job. An explicit original parent UUID requires inspection independently of date/recipe changes; it is never auto-adopted. Without that identity, exact recipe/block/pattern evidence plus vineyard-local day produces only an ambiguity notice, not same-job proof. Full ISO offsets are converted to the configured vineyard timezone for comparison; date-only history stays a date, and stored dates are never changed. Missing/invalid zone/date stays conservatively ambiguous rather than guessing the handset zone. The notice identifies candidates and directs existing Sprays/Trips inspection. Legitimate separate same-day work remains possible via explicit Save for Later, inspection and Start of that new saved UUID, demonstrated through the actual saved-job activation entry. Ownership and account-incarnation fences remain in force.

The calculator's existing capture/provenance/input assembly is extracted into `SprayCalculatorInputBuilder`, used by the production screen and focused tests, so tests do not manufacture null-snapshot/fixed-date inputs. The screen retains the same guided-versus-legacy tank-builder decision, metadata and formulas. This is a shared testable assembly seam, not another calculator, receipt store or Start path.

### Focused executed evidence (overlapping runs are NOT added)

- **Before matching correction: 0 passed / 3 failed / 0 skipped.** The three new timestamped production-assembly regressions exercised accepted+reload failure, lost-response recovery and older acceptance across two ISO timestamps. Returned diagnostic included `Original Start ... needs recovery ... Restore its unchanged setup` despite unchanged recipe. The older test also failed its no-auto-create/no-activation assertion. At this red checkpoint the shared assembler used the existing legacy tank builder with real captured/provenance snapshots; it was subsequently strengthened to the screen's actual foliar guided-plan/tank branch and real selected-block scope for the final checks.
- First corrected focused selection: **7 passed / 0 failed / 0 skipped, 8s**. Not an additional count.
- **Final frozen-source selection: 8 passed / 0 failed / 0 skipped, 8s**, Debug app/test compilation succeeded as part of `androidTest`. Exact class `com.rork.vinetrack.data.SprayStartProductionAndroidTest`, selected methods only:
  - `timestampedCalculatorAcceptedReloadFailureRecoversFrozenOriginal`
  - `timestampedCalculatorLostResponseRecoversFrozenOriginal`
  - `timestampedCalculatorOlderAcceptedIsInspectionNotIdentityProof`
  - `timestampedCalculatorChangedEvidenceCannotResumeAcceptedOriginal`
  - `timestampedCalculatorChangedLostResponseStaysHeldThenUnchangedRecovers`
  - `olderAcceptedAmbiguityListsAllAndSeparateSavedJobCanStart`
  - `olderAcceptedUsesParentIdentityAndVineyardDayWithoutRewritingHistory`
  - `olderAcceptedGenuineRecipeChangesAreNotMisidentifiedAsOriginal`
- Final input path: `SprayGuidedFlow.plan/snapshot` -> shared save-time `ChemicalSnapshotCapture` + `SprayConfirmedRateSeeding` -> `SprayGuidedTankBuilder` -> `SprayInput` -> actual ViewModel/repositories/verified-receipt store. Two clocks `2026-10-15T23:59:55Z` and `2026-10-16T00:00:05Z` both map to 16 October in Australia/Sydney; snapshots are asserted non-null with the respective capture clocks and applied rate. Additional local-midnight comparison uses `2026-10-16T12:59:55Z` versus `2026-10-16T13:00:05Z` (different Sydney days despite the same UTC date).
- Accepted reload failure preserves original123.5 hours despite999 retry. Lost response preserves null hours despite999 retry; changed-lost-response hold then unchanged recovery preserves12.25 hours. Tests assert same original trip/record/operation and frozen request/input/snapshot contents, one create, recovery-only after loss, no premature tracking, and intact original older attempts after ambiguity/separate-job activation. Genuine-change matrix includes products, rates, quantities, water, equipment/tractor, blocks, snapshot absence, classification, registration, provenance, captured clock not generated with the application and foreign parent.
- No host suite, broad regression/layout/Quick Actions suite, separate assemble build or managed Release/uploading `runChecks` was run. Only the selected Debug instrumentation compilation/execution was necessary. Previous broad results below remain historical, not new results.

### Exact available identity and remaining acceptance

Tested source = exposed baseline **`919f32094f60d3d9c286d0b09f8539a18fedbc60`** plus Android binary-diff SHA-256 **`ce385adc4f0abaab186fb1034fb1c0bc0daf62a10cc86eed21f20f49d5c5e5c2`** (`git diff HEAD --binary -- android-vinetrack`, includes staged new builder; no untracked Android files). Debug APK SHA-256 **`4af233b635cabdd18e922facc2c3309dd75e6e24bd52f63a55b3cd2704134a19`**; Gradle/version configuration unchanged3.1.7/code12. Scoped whitespace PASS. Only five Android source/test files changed: existing receipt store, ViewModel, calculator screen, production Start test and new shared input builder. Protected iOS/SQL/Supabase/scripts/build configuration/formula/spray-engine/layout component paths have no differences.

**Requested final managed commit SHA is not exposed before this turn is saved.** The baseline above is NOT the committed fix; no manual Git commit/push is permitted/performed, and no fabricated final SHA is supplied. Exact baseline+tested patch identifies the frozen source meanwhile. Application source is now frozen; no further development or build/test loop is authorised by this checkpoint.

**Remaining handset checks:** establish the original installation/hash and retained operation/receipt/claim, then verify same-draft timestamped retry after accepted reload failure/lost response with the same IDs/hours, changed-input refusal, older-job inspection and explicit separate same-day saved job. Confirm required Tank 1 Actuals before permitted GPS and one Live Trip presentation; genuine main-app process restart/reconnect and deployed authenticated receipt/RLS remain unverified. The original handset failure is not declared resolved. No release/deployment/distribution.

## Android Spray Calculator field follow-on — 16 October 2026

**Owner findings recorded separately; Quick Actions changes and open physical acceptance preserved.** Checked-out baseline `1ec5d4654baa4ddb40214dd5c5d81fc91ba1450e`; initial application/index clean (only managed history modified). Android remains **3.1.7 / versionCode 12**, unchanged. No Release build/upload/deployment/distribution, production/customer read/write, schema/SQL/Edge, history, formula/CF policy, path-order or GPS-algorithm changes authorised/performed.

### P0 trace and diagnosis boundaries

The confirmed handset event reaches the engine-hours callback and dismisses its dialog. **The exact handset failure branch is not established**: `rork-agent logs runtime --limit 80 --errors` returned no runtime logs. No retained handset snapshot, operation receipt or installation hash was supplied/read. Do not label one of the following source-proven defects as the observed handset cause without that evidence.

Production chain: `SprayTripStartConfirmation` → `SprayCalculatorScreen.startJobNow` → `AppViewModel.startSprayJobNow` → recipe/planning/scope/device/online admission → nonempty row sequence `createQualifiedSpray`, otherwise `createSprayJobForLater` → immutable paired-save receipt + exact recovery → original trip/recipe reload → `startSprayJob` → durable device claim + activation marker → existing `beginTracking` / required Tank 1 Actual gate. Successful result returns the owned active UUID → `SpraysScreen.onOpenTrip` → `MainScaffold` selects the UUID and Trip tab. No navigation bypass or second trip system was added.

Source-proven problems targeted in this pass:
- Legacy paired receipt can already be accepted when a later reload fails. Previously accepted pairs disappeared from `pending()`/the held gate, so another calculator press could mint a replacement trip/record. Retain Start intent/optional hours in the existing attempt, including accepted-but-unactivated pairs, and recover/reload original IDs without another create. Only a matched unchanged recipe can resume; generated preview tank/chemical IDs and current wall-clock are ignored for matching only, never used to replace frozen request evidence.
- Several foreground early exits never called the completion callback. Ensure terminal outcomes, use a single in-flight Start guard and return the actual active UUID/actionable error, rather than reading stale captured Compose state or a second navigation-time identity lookup.
- Qualified saved activation checked its recipe after confirming server activation and omitted the shared recipe preflight. Validate before activation; pending/accepted-unclaimed qualified starts remain held from replacement creation. Do not weaken occurrence/receipt/ownership contracts to force a start.
- Blank hours are already optional; finite nonnegative entered hours pass into activation. Invalid nonblank input previously became null silently. Confirm/reject explicitly, retain original hours across uncertain retries, and preserve first-tank recording safety.
- Status-only diagnostics distinguish stages, HTTP category and original trip/record/operation UUIDs; no tokens, headers, payloads, user names or backend response bodies are logged. Already active jobs return successfully only when the exact current actor/vineyard/UUID has a retained owned active snapshot; this does not re-claim or launch a second tracker.
- Changing legacy/qualified route branches cannot evade a retained uncertain Start. Older accepted same-day matching pairs without the new Start discriminator are not auto-adopted or reminted: the calculator directs the operator to inspect/recover the original saved job. This intentionally also prevents blindly duplicating an indistinguishable same-day saved recipe; explicit original-job inspection is required. Qualified pending/accepted-unclaimed lifecycle evidence remains held for the existing Trips recovery path, not silently converted to legacy or recreated.

**Historical GPS relevance:** a held `TRIP_GPS` marker alone is not consulted by `canStartDeviceTrip()`. A retained active/unreadable `ActiveTripStore` snapshot or deviceActiveTripId is a separate blocking authority. Its presence on the original handset is unknown. No queue/snapshot was purged or historical record reopened/rewritten to get around this protection.

### Presentation findings

- **P2 Volume Basis:** three equal-width segmented options combined checkmarks with long regional labels; Manual total water was particularly cramped in imperial units. Short visible **Total water** plus full supporting explanation; options reflow to full-width rows on narrow/large-font layouts. All existing basis callbacks/restrictions/calculations retained.
- **P2 Canopy Size:** size buttons previously only prepended a tick to identically styled outlined buttons. Apply lavender selected container, contrasting content/border, icon and selected semantics. No changes to type/size/density values, presets, illustrations or rates.
- **P3 Tracking Pattern:** current iOS Mixing uses spaced icon/title/subtitle selection cards, while Android used a dropdown and compressed direction segments. Android now uses the same hierarchy with wrapped cards, explicit selected appearance and content-driven heights; starting path, direction, sequence planner and physical path order are unchanged.

### Validation and remaining acceptance

| Surface | Final result | Scope and limits |
|---|---|---|
| Android production Start instrumentation | Included in **39 passed / 0 failed / 0 skipped, 50s** | `SprayStartProductionAndroidTest` calls actual `AppViewModel.startSprayJobNow`, repositories and existing scoped native stores with an intercepted, no-live-fallback HTTP transport. Blank/123.5 hours, original accepted reload failure with changed retry hours, rejection, service unavailable, lost successful response/recovery-only, ViewModel recreation from native stores, repeated concurrent presses, same-owned active return, active claim refusal, offline message, route-change escape refusal, older unflagged accepted-pair hold, and held historical GPS marker remaining unchanged. Fixture injects synthetic session/UI scope; not real login, deployed RPC/RLS, process death, UI navigation or GPS evidence. |
| Native durable receipt/restart instrumentation | Included in the same **39**, not additional | `LegacySpraySaveAndroidTest`: checked preferences and original RPC receipt/IDs/bytes across recreation, accepted-but-unactivated Start/optional hours, changed-amount rejection, unknown/rejected cases and existing separate OS-process kill/relaunch probe. That existing process probe retains old/claimed receipt stages; new Start-discriminator acceptance is store/VM recreation, not a new full-main-app process-kill acceptance claim. |
| Responsive native production controls | Included in the same **39**, not additional | `SprayFieldLayoutAndroidTest`: metric 320dp/default and 360dp/1.5× font; imperial 320dp/1.5× and 360dp/default. Actual text layout overflow assertions, >=48dp option bounds, selected semantics, differing selected canopy container pixels, all pattern cards/callbacks, optional/entered/invalid hours dialog. No full authenticated calculator screenshot or physical text-size setting claimed. |
| Quick Actions regression instrumentation | Included in the same **39**, not additional | `OfflineQuickActionsAndroidTest`, `OfflineQuickActionsProcessAndroidTest` retain previous scoped config/pin and isolated secondary-process evidence. iOS/Quick Actions source untouched in this follow-on. |
| Final host selection + local Debug build | **126 passed / 0 failures / 0 errors / 0 skipped across 12 XML suites; assembleDebug PASS; exit 0, 28s** | `scripts/run-spray-field-followup-tests.py`; 12 selected suites including original receipt, planning/CF, canopy/regional, occurrence journal, ownership/GPS and Quick Actions regressions. No Release/uploading `runChecks` invoked because owner forbids Release builds. |
| Exact original handset branch / actual server / field GPS | **NOT VERIFIED** | No original handset runtime log/claim/operation was available. Controlled HTTP acceptance is not deployed contract acceptance. Required Tank 1 Actual confirmation remains before location capture; production tests explicitly assert no premature tracking. Real permissions, physical GPS and exactly-once Live Trip routing remain handset acceptance. |

Development evidence retained: first host compile exposed a nullable retained snapshot smart-cast; fixed with an explicit non-null condition, no assertions ran. First instrumentation batch reported28 passes/4 failures; the isolated diagnostic identified a Tracking Pattern title whose intrinsic measured width was narrower than its paragraph layout despite available card width. Titles/subtitles now take their full weighted column width, retaining wrap/size and the overflow assertions. A later38-case run reported37 passes/1 assertion failure with no individual stack exposed by the runner. The returning-owned-trip test had compared the whole snapshot, including asynchronous save timestamps; it now explicitly checks callback count, owner, UUID, active/end state, engine hours, path and session evidence instead of snapshot-clock equality. The narrowed two-case selection passed, then widened selection passed38; the final added older-accepted-pair regression brings the final selection to39/0/0. Counts overlap and are not summed; no unchanged automatic reruns were used.

Required outstanding gate: identify the original handset build/hash and exact failed stage/operation outcome; blank and entered hours through receipt/activation → Tank 1 Actual confirmation → real permitted GPS → one Live Trip presentation, rejected/unknown outcomes without duplicate rows, true main-app restart and network recovery. Component/native fixtures and intercepted HTTP are not live backend/RLS/handset acceptance. No release/deployment until corrected-candidate approval.

**Final source/artifact identity:** available baseline commit `1ec5d4654baa4ddb40214dd5c5d81fc91ba1450e` plus Android native/test/runner patch SHA-256 `59e910ef18cf3f6b64bb9e955032e4154e74c5561b90eff8315d24259144f7f0` (`git diff HEAD --binary -- android-vinetrack scripts`, includes managed-staged new files; no untracked Android/script files). Local **Debug** APK SHA-256 `06df228894d587a33b8ee8afee171fc5fc255b3b760e7a3c596a1de60be1b0a1`; package `com.rork.vinetrack`, **3.1.7 / versionCode 12**, manifest verified with SDK aapt, unchanged Gradle metadata. Final managed end-of-turn commit is not exposed yet; this baseline is not represented as the committed fix. Scoped whitespace PASS; no iOS/SQL/Supabase/build-version/configuration/chemical-calculator or spray-model/formula subtree differences. No manual Git write, release build, upload, artifact delivery or physical installation. The original reported handset artifact is not identified merely because it may also display code12.

## P0 offline Quick Actions — 16 October 2026

**Source correction implemented on both platforms; native fixture acceptance is distinct from real authenticated/physical acceptance.** No customer/production data was read or changed. No schema/SQL/Edge deployment, store access, version/signing changes, artifact delivery or publishing. Existing Spray/CF/Program/tank calculations and Start pipelines remain unchanged.

### Targeted production changes

- **iOS:** `VerifiedVineyardRoleCache` persists the last successfully verified membership role/worker type by exact user, vineyard and the app's existing retained authenticated-session fence. `BackendAccessControl` restores it before awaiting membership HTTP. Timeouts, DNS, transport, 5xx and unknown failures do not mean membership revocation. Successful absent membership and explicit permission denial persist a negative result; failed cache writes remove obsolete grants rather than deliberately retaining a more privileged role. Request UUID plus current actor/session checks prevent a cancelled/late A result or defer from changing B. Effective permission flags stop immediately on sign-out/account change. The selected-vineyard refresh task also keys on actor/sign-out state, not only vineyard. The manual composer checks the same scoped operational permission before save; no new universal permission bypass.
- **Android:** the existing guarded domain cache now holds verified memberships and launcher configuration by cache owner/vineyard/auth-incarnation. Selection and startup hydrate immediately, before serial server reads; current unresolved button edits overlay that baseline. Only successful server configuration reads are written, including genuinely empty results. A membership RPC's explicit HTTP403 is distinct from an expired/token-hydration HTTP401; transport/401 uncertainty retains prior verified membership while the existing session-rejection policy remains authoritative. Authoritative member changes publish immediately instead of waiting for unrelated reference reads. Actor, authentication, identity epoch, selection epoch and load generation fence delayed cache/publication, including A→B→A. Successful config edits/replay update the retained baseline. The final pending overlay is recomputed at publication, not taken from an earlier pending snapshot.
- **Home routing audit:** Android `HomeDashboard` renders its Quick Actions unconditionally; `MainScaffold` routes Repairs/Growth and Add Pin directly to the existing launcher/composer. No source evidence supports deleting/redesigning that section. Cold offline routing already uses owner-matched cached vineyards and established subscription/offline grace (`hydrateVineyardsFromCache` / `hasLocalOfflineAccess`), which was not bypassed or changed. A separate full-screen disappearance still requires a real runtime capture; component visibility is not proof of authenticated Root routing.
- **Pins:** retain existing UUIDs and local pin/outbox authorities. iOS durably retains the actor responsible for pending pin/photo work; foreign actors cannot take over unresolved work, and push is vineyard/account-scoped. Missing local rows remain unresolved instead of silently clearing their pending IDs; exact dirty timestamps protect newer edits from delayed acknowledgements. Photos remain revision-scoped until their own reference confirmation. Android recovers interrupted PIN markers to retryable state on store recreation with original operation/payload/ID, checks the response's ID/vineyard, holds foreign creators, and reports failed local durability rather than claiming success. Existing account-recovery/retention locks remain intact.
- **GPS/manual placement:** no GPS traversal, location permission or synthetic-location fallback was added. Existing valid device fixes remain usable without internet. The existing unified composer retains point/block/row placement and cached geometry; manually selected coordinates are not described as a received GPS fix. Actual GPS availability and cached-map interaction remain physical acceptance.

### Executed evidence and limits

| Surface | Result | Exact meaning |
|---|---|---|
| Final iOS native + UI selection | **36 passed / 0 failed,39s**; skipped metric not exposed | `OfflineQuickActionsTests`, `PinPhotoWorkflowTests`, `SyncCompatibilityTests`, `SprayProgramTankFollowupTests`, `OfflineQuickActionsUITests`. Owner/manager/supervisor/operator; A/B cache recreation, absent/unvisited/foreign scope, timeout/DNS/500/503 vs403, actual auth-service sign-out/session rotation, stale successful A and cancelled failing A, original pin/photos and matching vineyard replay. Existing Program/tank regressions retained. |
| iOS application UI lifecycle | **PASS in isolated DEBUG fixture**, included above | Production role-cache/access controller and durable pin store; A→B→A, Repairs pin in A/Growth pin in B, Home background/foreground, actual app terminate/relaunch, both pending pins retained in their vineyards. Fixture labels are not the full authenticated Home UI and no OS flight-mode toggle/server session was used. |
| iOS visible simulator check | **3/3 visible criteria passed** | One separate billed iPhone simulator, not the owner's open preview. Local fixture displays all three actions; Switch→Vineyard B→Repairs displays Pending pins:1. Screenshot checks do not establish hidden durability/server guarantees. |
| iOS final simulator build | **PASS** | `runChecks(ios)`; native XCTest builds also compile Debug. No signed physical-device artifact or distribution. Two pre-existing asset URL notices remain nonblocking and untouched. |
| Android host + Debug build | **59 passed /0 failures /0 errors /0 skipped across8 XML suites; assembleDebug PASS; exit0,3m36s** | Final stable-source `scripts/run-offline-quick-actions-tests.py`: OfflineQuickActionsTest, PinOfflinePayloadTest, PinCreateConflictTest, PinDuplicateCheckerTest, PinDuplicateCreateAttemptTest, SessionLifecycleContractTest, SprayProgramTankFollowupTest, UnifiedPinContractTest. Includes exact retry/conflict/account/selection boundaries, unchanged original IDs/payloads, manual point/row/block validation and existing Program/tank regressions. No Android Release/uploading runChecks used. |
| Android instrumentation | **17 passed /0 failed /0 skipped,13s** | `OfflineQuickActionsAndroidTest`, `OfflineQuickActionsProcessAndroidTest`, `auth.FieldSaveContentionAndroidTest`. Production Home Quick Actions controls invoke all three callbacks; actual isolated preferences retain verified configurations/roles, authoritative empty and revocation results, pending edits and account/epoch separation. Process probe kills/relaunches a real secondary Android OS process, verifies changed PID, A/B configurations, stable pin IDs/notes/placement and retained photo bytes; controlled replay runs twice but creates2 rows once each and leaves photos retained for their own upload. Not authenticated main-Activity/RLS/network acceptance. |
| Real authenticated reconnect / physical flight mode | **NOT RUN / gate remains open** | No verified isolated real test-user/vineyard access was supplied. No real server records, receipt, photo object or exactly-one-row read-back is claimed. |

Counts overlap earlier runs and are not added. Development failures are retained: first iOS compile caught a main-actor cache initializer in a default argument (moved into the actor-isolated initializer); one later Swift test request failed with `fetch failed` and executed no reported assertions; newly expanded sign-out/access/photo selection then passed21 and the final widened selection passed36. Android's UI fixture originally searched mixed-case `Quick Actions`, but the actual production `SectionHeader` renders `QUICK ACTIONS`; the assertion was corrected to the real visible text, not removed. Process and Compose hosts were separated and safe-area host padding retained. The widened host run exposed one old test expecting a recreated interrupted PIN to stay IN_PROGRESS forever; it now asserts the original ID/client ID/payload/attempt count unchanged plus the intended retryable FAILED status. No duplicate/foreign/conflict safeguard was removed.

### Mandatory operational acceptance matrix

| Owner criterion | Evidence / remaining acceptance |
|---|---|
| 1 Online sign-in and visit A/B | Real authentication remains unavailable; native fixtures seed server-verified outcomes into the production cache paths. |
| 2 Flight mode on Home | Transport-offline fixtures pass; real OS flight mode on signed-in Home remains unexecuted. |
| 3 A→B→A actions remain | iOS local UI/controller PASS; Android scoped real preferences plus production control callbacks PASS. Full signed-in Home switching remains unexecuted. |
| 4 Offline background/foreground | iOS application fixture PASS; Android main-Activity offline lifecycle still requires handset acceptance. |
| 5 Offline kill/relaunch | iOS fixture app terminate/relaunch PASS; Android secondary OS process kill/relaunch PASS. Neither establishes retained real credentials/main-app network recovery. |
| 6 Create offline pin in A/B | iOS real button-to-durable-pin fixture PASS; Android production queue/payload persistence PASS. Actual Home→launcher/map placement on both signed-in clients remains physical acceptance. |
| 7 Reopen with correct pending pins | Actual iOS atomic-file and Android preference/process evidence PASS for stable IDs, vineyards, notes and photo bytes. |
| 8 Reconnect, one matching server record/photo | Controlled transport replay PASS; live authenticated/RLS/server/photo-object read-back remains NOT RUN. |
| 9 Owner/supervisor/operator | Native scoped-role fixtures PASS (manager also covered); genuine-role server sessions remain unexecuted. |
| 10 Revocation/sign-out/account/stale fetch | iOS explicit denial/empty, real auth-service sign-out with no-network auth repository and late/cancelled requests PASS; Android cache/auth-incarnation/contention and publication-token fixtures PASS. Deployed membership/credential revocation is not claimed. |

**Physical follow-up:** on an approved identifiable device candidate and isolated test accounts, run the complete retained-session flight-mode Home matrix, actual GPS availability versus manual block/row/map placement with cached geometry, real photo acquisition and notes across kill/relaunch, reconnect with one matching original-ID server row/photo per vineyard, genuine membership/session revocation and another-account login. No physical-device build or distribution is authorised/performed by this pass. Definition of Done's real operational/server portion remains open, rather than treating native mocks as a live PASS.

Exact checked-out source baseline: **`35f0912fb5d40ec67081aa5ddfc6b4de0a3324ba`**. Tested native/test/runner patch SHA-256: **`1bf442d26442016a3d2a717764d9b70c017193c2647b24be0643135df838ae97`**, from `git diff HEAD --binary -- ios android-vinetrack scripts` (includes managed-staged additions). Application-scoped whitespace PASS; no SQL/Supabase/Xcode-project/Android-build-configuration or protected SprayCalculator/SprayEngine differences. Final local Android Debug APK SHA-256: `5b4b76e5cf53036c3089fde40b2b0f72b912d66f6e70ea1de55ebbe02b25c10a`; no download link/distribution or handset installation. A new managed end-of-turn commit is not exposed yet; this baseline is not misrepresented as the final committed fix. No manual Git commit/push.

## Spray Program prefill and tank recording follow-up — 16 October 2026

**Mobile source correction implemented; external acceptance explicitly remains open.** Start Spray / non-blocking CF remains the priority and its receipt/ownership/quantity protections are retained. No new calculation, Start or tank commitment engine was introduced. This checkpoint supersedes the older rule that Program canopy values automatically confirm today's conditions.

### Program Step → existing editable calculator

- iOS now decodes/caches the explicit `vsp_canopy_size`, `vsp_canopy_density`, `carrier_volume_basis`, `dilute_litres_per_100m`, `applied_litres_per_100m`, band width and recorded row-spacing context alongside existing `spray_rate_per_ha`, `water_volume`, equipment, tractor, chemical lines and targets. `SprayProgramCatalog.steps` carries these inputs into the selected step's existing calculator prefill. Cache remains the existing typed `BackendSprayJobTemplate` disk cache; no operational Spray Record write.
- Android previously lost transient canopy, growth-stage and raw chemical metadata in `DomainCacheStore`'s serialized SprayRecord list. A cache-only envelope now preserves Program inputs/metadata and restores them on reopening; prior plain-record caches remain readable without inventing lost values. The new handoff remains `@Transient` on SprayRecord, so it never becomes an unapproved REST column. Program cache writes use a checked synchronous commit. Tractor choices also retain an owner/vineyard-scoped cache; async fetch publication is fenced by account incarnation and selected vineyard.
- Both platforms prefill configured canopy values **unconfirmed for today's conditions**, label the source **Spray Program**, and keep controls editable. Equipment confirmation stays independent. Partial/missing canopy is not a resolved answer. A recorded manual basis alone selects total water; a total-water scalar does not silently choose manual mode or become tank capacity. Recorded spacing is shown as Program context, not used to overwrite selected blocks' verified geometry.
- Regional display conversion is through the existing formatter boundaries: canonical L/ha, L/100m and litres are retained, while the fields display local volume/area/length units. Existing canonical iOS carrier bindings and Android regional inputs are reused. Stored chemical rates/bases remain on their original Program rate handoff. An explicit dilute reference now enters the **existing** `SprayVolumeDecisionResolver` after canopy review instead of being ignored in favour of the canopy table. Formula/CF floor remains unchanged; this is an input-selection correction, not a second calculation engine.

### Tank recording audit and correction

- Root cause: neither native legacy completion flow populated session `pathsCovered`; Start created an empty list and End recorded only boundaries/times. GPS coordinates and planned tank ranges cannot establish actual tank attribution. Android replay additionally preferred the local same-ID session without retaining richer server path evidence.
- Existing `TankSessionLifecycle.startResult` and recoverable `StartTankCommitCoordinator` already select and freeze the **actual session UUID, actual tank number and confirmation timestamp** used by Tank Actuals. They remain the authority; no preview ID, planned-tank count or new ID on retry is substituted. Legacy iOS no-mix Start now uses the throwing durable Trip update. End Tank on both platforms requires a single matching open spray session and refuses ambiguous/ended state rather than ending the last matching number.
- `TankPathAttribution` now records future **completion-time** evidence against the one active spray session when the legacy numeric plan/block scope is unambiguous. No end-time range subtraction, GPS-total guess or historical backfill. Multiple blocks/repeated numeric labels remain unknown unless represented by the existing occurrence contract. Completion links are retained as recorded event evidence; guidance Undo does not erase them or manufacture a replacement tank.
- Android persists row coverage and session evidence in the same owned active snapshot before successful publication, queues the existing tank replay authority, and retains sessions when a coverage response arrives. Delayed coverage responses no longer replace a newer local snapshot. iOS stores added links on the same Trip snapshot as the completion. Existing Actual commit ordering, identities and ended-trip replay holds are preserved.
- Occurrence actions now select the **single active spray session**, not all unended sessions (including fill-only sessions). Skip and End Review do not manufacture tank links; delayed End Review cannot assign old work to whichever tank happens to be active later. No numeric pathsCovered projection is added as a second authority for repeated passes.
- Same-session replay preserves already recorded path evidence and refuses identity/number conflicts. Legitimate fill-only→spray transitions retain their original ID even if the offline spray session is already closed. Local report projections no longer guess tank assignments from planned dose ranges or start/end row indices. Empty historical evidence therefore reads as unknown locally, without changing the stored history.
- **Backend boundary:** checked-in canonical legacy report SQL still has its own legacy range-based attribution. No SQL, API/Edge source, schema, deployment or production database operation was performed. The local projection correction is not a claim that the Portal/canonical online report policy has been changed; that remains backend-owner acceptance.

### Executed validation and provenance

| Surface | Result | What it proves / does not prove |
|---|---|---|
| iOS final widened native selection | **133 passed / 0 failed, 61s** | `SprayProgramTankFollowupTests`, `SprayMVPDefectTests`, `SprayPlanningIntentTests`, `TankSessionLifecycleTests`, `StartTankCommitCoordinatorTests`, `SprayGuidedFlowTests`, `SprayCalculationContractTests`, `LegacySprayPairReceiptTests`. Program row→real disk cache→selected-step handoff, metric/US conversion, unreviewed canopy,715/600 input, unchanged chemistry, exact session IDs/numbers, two persisted Actual links and dated history shapes, fill-upgrade replay, nearby Start/CF protections. Skipped metric not exposed. |
| iOS simulator build | **PASS** | Final runChecks succeeded. Not a signed handset build, live GPS or new UI acceptance. Earlier overlapping132-wide and30-focused passes are not added. |
| Android host selection | **193 passed / 0 failed / 0 errors / 0 skipped across19 suites** | Combined debug regression runner, including the new Program/cache/region/tank/history tests, existing StartTank commitment/recovery and Trip tank queue authority. Final combined runner + assembleDebug exit0 in27s; current XML totals confirmed. Earlier failing selection disclosed below. |
| Android native instrumentation | **32 passed / 0 failed / 0 skipped,58s** | `SprayProgramTankProcessAndroidTest`, `SprayReleaseGateAndroidTest`, `SprayPlanningAndroidTest`, `LegacySpraySaveAndroidTest`, `SprayChemicalEditorAndroidTest`. New debug-only isolated secondary-process probe decodes an actual Program row through the production repository adapter, writes production Program cache + two sessions/two Actuals, kills that OS process and relaunches it; verifies original IDs/numbers/paths and Actual links without network. Existing receipt/CF/warning/editor tests retained. This is not authenticated main-app field use. |
| Android non-release build | **PASS, local assembleDebug** | Managed Android runChecks deliberately not invoked because it builds/uploads Release; local debug and instrumentation compilation are the validation surfaces. No Release build/distribution, store access or publishing. |
| Three owner-reported historical cases | **Structural regressions PASS; exact private-record acceptance OPEN** | Synthetic14 October two-session/two-Actual shape;4 September and23 September two planned/only Tank1 shape. Encode/reopen preserves numbers, session IDs, Actual links and empty paths; ended records cannot acquire new links or planned Tank2. Local report cannot infer a tank from start/end bounds. These are NOT the original private export bytes. Original fixtures must be supplied again for exact cross-platform comparison; no production fetch was attempted. |
| iOS true OS-process restart; authenticated HTTP/network replay; physical devices | **Not executed / still open** | iOS tests use actual atomic-file and Actual-store recreation, not process termination. Android's isolated process probe does not establish main-app network recovery or field GPS. No new rendered-screen or real-Portal selected-step journey is claimed. |

Development failures retained: first iOS compile exposed the carrier helper's private `positive` visibility; changed only its access and reran successfully. First Android host compile exposed the new fixture's wrong region-settings type; corrected to the established regional preset. The next193-test run had192 passes/1 failure: replay identity checking incorrectly rejected a legitimate fill-only→already-ended spray transition. Production merge was corrected to preserve that same session, not the test assertion; final host pass and a specific Swift fill-upgrade regression followed. Overlapping runs are not summed.

Tested source baseline **`81bd9bd1ee9f6df12762d940c72f373edf848e1a`**, retaining the preceding Start/CF repair, plus native/test/runner binary diff SHA-256 **`7456e1de9a5ead858fbba2e5d5641f5bacb1b83c88b3a666f43983bf7728ab43`** (`git diff HEAD --binary -- ios android-vinetrack scripts`; no untracked native/script files). The final managed commit SHA is not exposed during this turn; the baseline is not mislabelled as that commit. Scoped whitespace PASS. No version, signing/project metadata, SQL/Edge, production/history mutation, store access, publishing or distribution. All native fixtures are synthetic and isolated.

## CF never blocks Start / Save / Mixing — preceding checkpoint, 16 October 2026

**CF correction PASS at native client/test level on both platforms.** This instruction supersedes the earlier incorrect policy rejecting CF below1/nonfinite. The preceding same-draft supported By Area Start repair is retained. Authenticated receipt→original Trip→Tank1→GPS and physical-device acceptance remain OPEN, not inferred from the results below.

### Implemented correction

- Removed CF-only denial from both operational gate overloads, iOS per-tank compliance gate, both frozen-resolution validators and both planning snapshot admission checks. Explicit ambiguous rate basis, positive/finite water, chemical rate/quantity, changed frozen mix, physical/controller consistency, unsupported planning, receipt, ownership and active-Trip protections remain. No acknowledgement field or policy flag was added.
- Existing valid-volume calculation remains `max(1.00, recommended dilute / actual)`. Shared calculation-only fallback normalizes nil/sub1/nonfinite stored factors to1.00 when valid volume evidence is unavailable; valid comparable volumes take priority. Ratio overflow cannot propagate infinity as a CF. New carrier/product calculations and the existing nonguided calculator entry points use this baseline; they do not modify saved historical factors/quantities. Invalid water or rates still fail their own validation, rather than a CF default inventing a chemical quantity.
- A missing frozen wire CF alone no longer invalidates otherwise complete retained planning outputs. No physical/tank values are inferred or discarded. Stored0.95 remains0.95 in historical records and replay bytes; only new calculations use the effective baseline or volume-derived result. Raw historical model/area/report derivation code was left unchanged. No backfill or sync rewrite was added.
- iOS unchanged NaN evidence is compared through an exact sorted, nonfinite-safe encoding solely for recipe confirmation equality, so NaN's nonreflexive equality cannot create a CF-only false changed-mix rejection. Different quantities/fields still fail comparison. This encoding is not a persistence or server serialization format.
- Orange label-permission warning remains optional and is now accessible beside Start in both Mixing presentations as well as calculator Review. Its text explains normalization and that Start Spray, Save for Later and Tank Mixing are not disabled by this information. No automatic label approval is claimed.

### Final executed evidence

| Surface / requirement | Result and scope |
|---|---|
|715L/ha recommended,750 actual | CF1.00, no CF rejection. Native calculation/gate regression on both platforms; Android receipt-v1 production serializer/reload/tank admission fixture. |
|715L/ha recommended,600 actual | CF1.191666... (approximately1.19), warning only. Same native and Android serializer scope. |
|LegacyCF0.95; missing/sub1/nonfinite factors | No CF-only operational denial. New quantity calculation uses baseline1 or valid-volume ratio; existing factor/chemical amounts retained. Android original payload enqueue/recreation and replay passes CF admission without changing evidence; queue-only replay then reports missing test repository, not fabricated network success. |
|Invalid water, rate, quantity; changed mix | Negative admission/quantity regressions retained; CF default does not make invalid inputs valid. |
|iOS native regression | **140 passed,0 failed,33s**: SprayMVPDefectTests, SprayPlanningIntentTests, SprayPlanningAttemptTests, SprayGuidedFlowTests, SprayCalculationContractTests, SprayTripStartAdmissionTests, LegacySprayPairReceiptTests, TankSessionLifecycleTests. Skipped metric not exposed. |
|iOS production calculator UI | **1 passed,0 failed,169s**: configured By Area with actual per100L product→Review→Mixing with Start enabled before warning acknowledgement; visible warning opens/closes; Start stays enabled; Cancel retains same draft and final stored records/Trips remain0. Isolated DEBUG local owner fixture, NOT authenticated Start submission or GPS. |
|Android host | **160 passed,0 failed,0 errors,0 skipped across15 XML suites**. Final combined runner exit0 plus assembleDebug,31s. Production calculator/planning/recipe/receipt/tank/ownership/recovery selection from existing runner; no live backend. |
|Android instrumentation | **31 passed,0 failed,0 skipped,50s**: SprayReleaseGateAndroidTest, SprayPlanningAndroidTest, LegacySpraySaveAndroidTest, SprayChemicalEditorAndroidTest. Configured receipt serialization/reload, retained original legacy evidence, actual preferences and Compose warning/action readiness. Warning action controls in the narrow Compose test use production gates; they are NOT the full production calculator/AppViewModel Start journey. |
|Build checks | iOS simulator runChecks PASS; Android final local assembleDebug and managed instrumentation app/test compilation PASS. Android runChecks deliberately not invoked because it builds/uploads Release artifacts forbidden by this scope. No release/store flow or device distribution. |
|Authenticated full activation, Tank1 and GPS; physical handset | **Not executed / still pending.** Existing client component PASS does not close those preceding operational acceptance gates. |

Development evidence, not concealed: the new iOS1-test regression and Android host1-test regression initially reproduced the old named CF rejection. After correction, iOS core passed. Two expanded iOS UI attempts failed warning hit-testing because the Review warning was behind the Mixing sheet; the same optional warning was added to Mixing beside Start, and the final real production-calculator UI run passed without relaxing enabled-button assertions. Initial Android instrumentation30/1 still asserted that a0.9-only legacy edit must not enqueue; replaced that obsolete CF-policy assertion with successful enqueue, preserved exact original payload and unchanged independently blocked Full Tank evidence. Final31/0/0 passed. Overlapping executions are not added.

Exact tested source: clean baseline **`cac4fcac2597a7d295b13cf2d4b91f7c322c0728`** (preceding same-draft repair) plus native/test/runner binary diff SHA-256 **`684cd141613c4ed32840082823e884dc1f532686c5f8f068c3aeb7a34786cf38`**. Final managed commit SHA is not yet exposed within this turn; no manual Git commit/push. Scoped whitespace PASS; no SQL/Edge, release metadata, raw historical model, production/customer data, store access, uploads or releases. Native instrumentation installs only its isolated debug test environment, not an owner handset.

## Urgent same-draft Start Spray correction — previous checkpoint, 15 October 2026

**Mobile correction implemented and native checks passed; issue remains OPEN until the authenticated complete operational path is verified.** The owner reports successful authenticated-role transaction-rollback tests of linked pair insertion, accepted receipt, exact recovery, idempotent retry and changed-request conflict, with no permanent rows. That is accepted as backend-owner evidence, not represented as native authenticated acceptance or rerun here.

### What changed

- Both native calculator flows no longer reject a valid By Area mix merely because Single Row/Over-Row was selected. They use the SAME configured calculator, Review, Tank Mixing, existing receipt-v1 paired save and original Trip activation implementation. No alternate Start pipeline or fresh empty calculator recovery remains.
- Lossless contract adapter: existing physical fields and tank recipe/IDs/quantities remain unchanged. Complete supported By Area pass intent, original input provenance, frozen physical/controller outputs and CF are serialized into the existing `notes` field inside `[VineTrack sprayer setup v1]` delimiters using the shared snake-case `SprayPlanningWireFields` shape. Existing operator notes remain verbatim as a prefix. iOS/Android reconstruct the frozen setup from this note when dedicated planning columns are absent; no mutable vineyard geometry or new equations are used. Re-encoding an unchanged setup does not append it again, regardless of JSON property ordering. This note is visible record data, not a claim that receipt-v1 gained new top-level columns or a new server planning/coverage authority.
- Only valid By Area tuples use this adapter. Full Tank inputs/outputs and explicit-clear/malformed intent are not silently stripped or admitted. Full Tank still requires its intended tank litres, specification, planned area/frozen outputs and operational attribution through the reviewed planning contract, not just storage of explanatory text. Its precise blocker tells the operator to choose By Area in the CURRENT draft. Existing inline controls retain unrelated inputs and retain the typed Full Tank fields when toggled back.
- Selected proposed passes explicitly block the calculator action until the operator deselects them in the existing Select Work Area sheet. This prevents a supported mix from silently discarding work selection. The original blocks, targets, location, equipment, products/rates and carrier remain in place. No proposed work or actual coverage is manufactured.
- CF permission uncertainty remains orange advisory text. **The CF-invalid/sub1 rejection described at this checkpoint was incorrect and is superseded by the 16 October correction above.** Invalid product rate/quantity, changed frozen recipe, account/vineyard/device ownership, retained uncertain receipt and active Trip protections remain enforced; Full Tank/controller equations are unchanged.

### Examples and executed evidence

| Requirement | Result and evidence level |
|---|---|
| Single Row600L/ha,2.8m | PASS native production resolver/serializer fixture: physical16.8L/100m; controller16.8; exact setup/targets/tanks round-trip through allowed receipt fields. |
| Over-Row same physical setup | PASS: physical16.8; controller33.6; effective width5.6m while physical spacing stays2.8m; no doubled chemical dose or carrier total. |
| Per100L chemical,CF1.02 plus valid per-hectare product | PASS on both native fixtures: positive frozen recipe accepted, CF label uncertainty contributes no denial; original per-tank quantities retained. |
| Rate0 | PASS rejection fixtures. The historical invalid/nonfinite CF rejection fixtures are superseded by the newest non-blocking correction. |
| Full Tank/proposed passes | Deliberately blocked with specific same-draft edit guidance; never silently downgraded. Android Compose control test switches Full Tank→By Area→Full Tank and retains original1500L/3ha entries. |
| Direct same-calculator Review→Mixing UI | iOS production-calculator UI1/0,104s: configured Single Row By Area Review opens Tank Mixing with enabled Start, Cancel retains the draft, no Trip/Record is saved. Isolated local fixture role only, no authenticated session and Start was not submitted. Android has production inline-control UI plus configured serializer/confirmation instrumentation; full production-screen Start through AppViewModel was NOT driven. |
| Unit/native regression | iOS final97/0,80s: SprayMVPDefectTests, SprayPlanningIntentTests, LegacySprayPairReceiptTests, SprayTripStartAdmissionTests, DeviceTripOwnershipTests, ActiveTripRouteRecoveryTests, TankSessionLifecycleTests, SprayTripPhase5FinalisationTests. Skipped metric not exposed. Android final159/0/0/0 across15 host XML suites; combined runner exit0/build32s. |
| Android instrumentation | Final30/0/0,55s: SprayReleaseGateAndroidTest, LegacySpraySaveAndroidTest, SprayPlanningAndroidTest, SprayChemicalEditorAndroidTest. Actual preference/transport mocks, valid configured receipt serialization/read-back and unchanged-recipe tank admission; no live JWT/backend/GPS start. |
| Native debug correctness | iOS runChecks simulator PASS; Android local assembleDebug and instrumentation app/test builds PASS. Android managed runChecks avoided because it produces/uploads Release artifacts. No device distribution. |
| Verified paired receipt→original Trip activation→required Tank1→GPS→End/restart | **NOT verified end-to-end.** Existing receipt/ownership/tank lifecycle/reconciliation component tests pass, but their aggregate is not a real authenticated operational Start. Need an explicitly isolated test account/vineyard and authorised native sessions. Owner's rollback SQL evidence does not close this gate. |
| Physical-device acceptance | Still pending. Issue is not marked closed. |

Earlier failures in this pass were resolved, not hidden: missing Android LegacySpraySetup import; test input missing required sprayEquipmentId; iOS new fixture decoder initially used numeric rather than ISO date strategy; historical blanket-message assertions failed after precise blockers replaced them (Android host2 and instrumentation2), then were updated while preserving blocked status/unchanged bytes/no transport assertions. Final runs above passed; overlapping runs are not added.

Exact tested source: baseline **`f90d4f06982f12131a514c3082da56a1d7ff83ac`** plus final binary diff for `ios android-vinetrack scripts`, SHA-256 **`bb87469c296e1240e7791a92119232529e72850b2904ba29d25e8918e0bc899f`**. The managed end-of-turn commit SHA is not exposed during this turn; no manual Git commit/push. Application baseline was clean, managed history left untouched. Scoped whitespace checks PASS. No SQL/Edge, release metadata, stores, uploads, distribution, customer record operations, queue purge, uninstall or completed-history changes. New source must not be confused with earlier171/code12 signed artifacts.

## Final MVP operational release gate — previous checkpoint, 15 October 2026

**Decision: FAIL / NO-GO for operational release.** Passing native fixtures, instrumentation and builds do not establish an authenticated server-backed Start or original-handset reconciliation. No stores, publishing, artifact upload/distribution, database reads/writes or release-metadata changes were performed in this pass. Debug test APKs were installed only on the isolated instrumentation emulator as explicitly requested, not on the owner's handset. Existing UI, dose equations and planning architecture remain unchanged.

### Exact source identity

- Requested `597d2aab1645ab82e38a56865ffcb164fb971e8a` is not available: Git returned `bad object` / `not our ref`. Do not label any execution as testing that commit.
- Available baseline: `a63e175a573b7bff21e53b222ab09153ec2419df`. Initial application/index clean; managed skill fingerprint left alone. Its native/test/runner diff from `d7b895d235ea50d50b5e92766c06a08f331e8c18` hashes to the previously reported `7aaee0e9b00e25103cd715271889b95efb4e8d68779513579c03cac3e0a9d892`. This establishes correction-content continuity, not identity with the unavailable object.
- Exact final tested source: that available baseline plus `git diff HEAD --binary -- ios android-vinetrack scripts`, SHA-256 **`2cbac77feb1100659bf19ea0a4b08488d9761e96c025c7005b8ad3f35c583d69`**. A new managed end-of-turn commit will contain the narrow corrections/tests below; its future commit SHA is not exposed within this turn. No manual commit or push. Use that resulting source, not historical iOS171/Android12 artifacts, for a separately authorised device-testing build.

### Supported legacy Start — exact routes and dependency

Both fresh supported presentations instantiate a separate empty calculator (iOS sheet, Android full-screen Dialog), defaulting to Free Drive with no selected pass configuration and By Area rather than Only Full Tanks. They do not clear, convert or resubmit the unsupported parent draft. Required block/equipment/tractor decision, application target/location, valid carrier, positive product rate/quantity and applicable canopy confirmation still must be completed. No planning intent is generated unless the newer configuration/Full Tank controls are deliberately chosen; no-evidence planning serializers omit the newer fields, while unknown planning fields are refused rather than stripped.

- iOS: calculator `saveAndStartJob` → Spray Tank Mixing preview / engine hours → `confirmAndStartJob` / `finalizeStartFromMixSummary` → frozen recipe admission → `TripTrackingService.startTrip` → durable inactive original record/Trip pair → receipt save/recovery → original-ID local active persistence/claim → existing location permission/tracking seam. The immediate route calls `finishLegacyTripStart`, not `activateSavedTrip`; saved-job activation separately checks held receipt and unchanged unstarted recipe/Trip. Mixing preview is not proof of confirmed Tank Actuals or live GPS.
- Android: calculator → `startSprayJobNow` → recipe/planning/device admission → `createSprayJobForLater` → durable original `LegacySpraySaveStore.Attempt` → receipt verification → accepted-row hydration → `startSprayJob` using the same Trip ID → existing saved activation and first-tank Actual Mix commitment → `beginTracking`. GPS is deferred while first-tank review is required; permission/provider and authenticated service execution remain acceptance requirements.
- Both require authenticated POST `/rest/v1/rpc/save_legacy_spray_pair_v1`, then `/rest/v1/rpc/recover_legacy_spray_pair_v1`, carrying the same `p_operation_id`, `p_trip`, `p_record`. Recovery must confirm version1 accepted, exact operation/vineyard/Trip/record identity, server request fingerprint and committed timestamp. A row existing, HTTP409, synthetic receipt or a locally active snapshot is not server-backed Start acceptance. After a lost response, recover the original operation; never remint or repeat create to make the UI green.
- New production-serializer fixtures on both platforms admit a valid 420L legacy recipe with recorded multiple targets/Full Canopy and no newer planning keys. This proves an implementable client payload reaches the receipt boundary; it does not prove the RPC is deployed/authorised/accepting that payload. **Precise unproven gate: authenticated immutable paired receipt save and exact recovery, followed by actual activation/tank/location service execution.** No unconditional fresh-draft operational PASS is claimed.

### Required isolated backend test scope — not executed/authorised here

Backend owner must provide an already provisioned disposable non-production project or expressly isolated synthetic vineyard/accounts, with receipt-v1 contract `bb72aa15335e51c30cdafbdedde1ff6a967695f2`, real authenticated operational-role JWTs, membership and matching seeded block/equipment/operator references. Never use service-role credentials in a client or the original customer vineyard. Backend owner must verify the deployed RPC signatures, grants/RLS and atomic two-row plus receipt transaction. This pass makes no catalog query, fixture provisioning, deployment or mutation.

Separately authorise native iOS/Android Start Now and Save for Later→relaunch→Start against that scope, using original operation/record/Trip IDs; verify exact receipt/recovery body and one paired creation, then existing activation, Tank1 Actuals and GPS permission/capture. Include dropped successful response, reconnect, account/vineyard revocation, rejection/conflict and duplicate taps. Verify no second pair or second recording, no dependent start before acceptance, original held evidence retained, and no unsupported planning payload conversion. Synthetic native fixtures cannot close this gate.

### Narrow reconciliation corrections and observed failures

- Reproduced two real iOS assertion failures before correction: equal-length divergent local GPS replaced on completed pull; inactive placeholder incorrectly cleared dirty activation. Corrected the sync coordinator to distinguish a saved inactive parent from recorded completion, preserve the pending owned activation, and allow that original activation to upload rather than suppress it as already ended.
- Completed iOS reconciliation now uses exact ordered coordinate inclusion (duplicate observations retained; generated coordinate IDs are not GPS facts), not point count. Missing route, conflicting/missing tank sessions, local-only coverage/block evidence stay local and pending/failed; remote end still stops/releases operation. A retained evidence hold prevents a full-sync success stamp and no completed-trip write is issued to resolve it. This is local component evidence, not a universal full-snapshot equivalence/physical recovery guarantee; arbitrary metadata conflict reconciliation and the original handset state were not comprehensively accepted here.
- Android end replay no longer removes intent merely because a row is inactive. A saved placeholder, contradictory lifecycle or different end time/notes/engine hours retains a blocked original end intent without a completed-row patch. Only matching terminal completion fields acknowledge that intent; a matching response also publishes the completed row. Predicate instrumentation covers these fields; no live end transport was exercised. Existing GPS inclusion recovery, actual-use authority and traversal code were not changed.

### One final release-gate table

PASS applies only to the explicitly named automated scope. FAIL means the required release proof is missing, not an invented observed server failure.

| Gate | Result | Evidence / remaining requirement |
|---|---|---|
| Exact requested commit `597d2aab…` | **FAIL** | Object unavailable. Available baseline and exact final patch identified above; no false commit equivalence claim. |
| Supported fresh legacy payload, receipt/duplicate admission and reconciliation components | **PASS — automated only** | Latest iOS47/0; Android30 instrumentation/0/0 plus159 host/0/0/0. Synthetic authority/receipts, isolated persistence and transport fixtures. |
| Real authenticated Start on both platforms, including fresh supported draft | **FAIL — unverified** | Isolated backend scope and authorised native HTTP/tank/GPS journey required. No live receipt or successful server-backed start observed. |
| Original completed Trip: no false active state, no evidence loss, no duplicate recording | **FAIL — unverified on original devices** | New iOS regression reproductions/fixes plus Android real secondary-process GPS probe with synthetic server data pass; original marker/Trip and complete4584-point/109-path evidence not inspected. |
| Android relevant instrumentation | **PASS** | Final five-class selection30 passed/0 failed/0 skipped,51s. Baseline-only selection27/0/0 preceded edits; overlapping intermediate29/30 counts not added. Not the full unrelated instrumentation suite. |
| Recorded multi-target/location PDF and applicable historical CSV | **PASS — native automated scope** | iOS actual record/program PDF text + target/location bounds/non-overlap and actual CSV. Android actual native record and paginated12-record program rendering/text/page bounds: every recorded target, custom target, Full Canopy and Undervine appears on each record; real CSV includes the same values. No export upload or live canonical report call. |
| Handset PDF/share appearance and Android custom-rate keyboard | **FAIL — unverified** | Rendered bitmap/text bounds are not a human handset visual/share-sheet acceptance. Existing Compose editor/planning controls pass, but do not drive the production calculator custom-rate IME journey. Physical default/large-font acceptance still required. |
| versionCode11→12 provenance / metadata freeze | **PASS** | Intentional earlier signed-test-candidate change in `d7b895d235ea50d50b5e92766c06a08f331e8c18` (15 October14:29:23UTC); existing prior checkpoint records its authorised test preparation. Not introduced by the spray corrections or this pass. Still3.1.7/code12; no further metadata edits. |
| Non-distribution build validation | **PASS** | iOS runChecks simulator build PASS; Android local combined host+assembleDebug PASS27s and final instrumentation debug/test build PASS. Android managed runChecks deliberately not used because it uploads Release artifacts. No signed device candidate or store validation implied. |
| Overall operational MVP release | **FAIL / NO-GO** | Close authenticated Start, original-handset reconciliation and physical keyboard/PDF acceptance before operational release. Device-testing build/distribution remains a separate owner authorisation. |

Latest iOS selection: ActiveTripRouteRecoveryTests, DeviceTripOwnershipTests, SprayTripPhase5FinalisationTests, SprayMVPDefectTests, LegacySprayPairReceiptTests and SprayTripStartAdmissionTests: **47 passed**,124s; separate skipped metric unavailable. Initial reproducer2 passed/2 failed, then one compilation failure (`Bool?` required explicit false comparison) corrected before final47/0. Android final selection: SprayReleaseGateAndroidTest, LegacySpraySaveAndroidTest, TripGpsRecoveryAndroidTest, SprayChemicalEditorAndroidTest and SprayPlanningAndroidTest. Host run used `scripts/run-spray-mvp-tests.py --combined --build --launch`; exit0 and15 XML suites independently total159/0/0/0. Counts are not summed with overlapping historical runs.

Source-scoped whitespace check PASS. No SQL/Supabase, version metadata, equations, planning architecture or completed UI changes. PDF production visibility changed private→internal solely to exercise the same offline renderer without invoking network enrichment/share side effects; rendering behavior unchanged. No original production fixture/locator was added, no uninstall/storage clear/queue purge, and no production Trip reopened.


## Exact recorded fixtures / genuine handset candidates — newest checkpoint, 15 October 2026

### A. Exact production samples — PASS, not reconstructed JSON

- Downloaded the supplied ZIP unchanged to `/tmp/vinetrack-exact-fixtures.zip`; extracted original member bytes only outside the repository. The Swift test process separately downloads the same archive into memory, checks archive/member SHA-256 and inflates original bytes without JSON normalization. No production sample or archive was written into the project, committed or included in the handset app. A temporary test-only URL locator was removed before handset source upload. The retained generic test skips explicitly if no private locator is supplied; it is not evidence of a future exact-fixture run without the locator.
- New reusable test source: `ios/VineTrackTests/RecordedSyncFixtureTests.swift`. Input arrays are passed unchanged to production `[TankSession]` and `BackendButtonConfig` decoders. Only surrounding transport rows are synthetic. Growth scope is the actual vineyard parsed from the supplied provenance, not a substituted synthetic vineyard; original array elements remain untouched.
- Both recorded session IDs, tank numbers, fractional start/end dates, start/end row values and complete ordered coverage arrays compare equal to the independent original JSON fields. BackendTrip→Trip mapping and historical cache round-trip retain both sessions. No session IDs, times or coverage were reminted/defaulted.
- All eight recorded Growth buttons compare equal to original names, colour strings, indices, modes and stage flags. All eight still lack original nested identity fields in the source bytes. Decoded scope/identities remain stable across repeated decoding and encode/decode; all eight derived IDs are distinct.
- Production `ButtonConfigSyncService` pulls the exact legacy Growth array alongside a newer dirty synthetic Repairs edit. A deliberately mismatched acknowledgement produces failure/no full-sync date and retains the Repairs marker. A matching acknowledgement clears only that edit, preserves Repairs values and all original Growth values, and permits success. Transport replies are synthetic; this is **not** deployed CAS/RLS or authenticated cross-device acceptance.
- Initial exact selection: **3 passed**, 93s. Final widened selection `RecordedSyncFixtureTests`, `SyncCompatibilityTests`, `TankSessionLifecycleTests`: **29 passed / 0 failed**, 123s; skipped metric not exposed. Initial three are included in 29, not additional passes.

| Immutable input | Bytes | SHA-256 |
|---|---:|---|
| Original ZIP | 1665 | `ffb05870f11efd94336ccb78608001291afa15c694df60d327f6b8d0ca8dd833` |
| Recorded tank_sessions JSON | 495 | `2af3729284692229c992f10e529232c2f78cfa7376b304a951894921ff436cfe` |
| Recorded legacy growth_buttons JSON | 1021 | `36339f0b264b8059576ef32ddb57184a1d94f2ba716f131a9a3a8f1fcbf4c960` |
| Supplied provenance text | 1369 | `5f6cd05ca9878ec6e824d852cc8317b31c6e0bcaee3f94fa055d1afce802084a` |

### B. Source identity and regressions

- Requested object **`1fd046f3d430e6454beb3ed0dd78070d5e42bdcc`** exists with message “Completed the urgent VineTrack sync fixes for iOS buttons, tank sessions and Android GPS recovery”. Its native diff contains the reported decoder, conditional acknowledgement and GPS recovery corrections (16 native implementation/test files, 860 insertions/157 deletions).
- Starting current HEAD **`46501ab84239edade9d7a8a07398eb78f75cb9b8`**, clean application/index; managed history differences left untouched. The requested object is not an ancestor in the current managed history: do not claim otherwise. Content comparison confirms inspected BackendButtonConfig, ButtonConfigSyncService, SupabaseButtonConfigSyncRepository, TankSession/Trip, TripGpsSync and PendingWriteRepository are identical to the requested commit. Current history's sync checkpoint is `bdc74929`; only the generated empty Config.swift differs between that native tree and the requested object. Subsequent Insights access changes remain preserved; no rollback.
- Android coherent host rerun: **84 passed / 0 failures / 0 errors / 0 skipped**, seven XML suites, runner exit0, 28s. GPS suite timestamp `2026-10-15T14:10:25.653Z`. Selection: TripGpsRecovery, ActiveTripStore, ReplayVersionIntegrity, AtomicPendingReplacement, AuthRetentionGate, RetentionReview and TankSessionLifecycle.
- Android `TripGpsRecoveryAndroidTest`: **1 passed / 0 failed / 0 skipped**, 10s on code12. Real secondary debug-process termination/relaunch and scoped preferences, synthetic completed-trip transport. This is not the original handset, its original marker, or real backend inclusion evidence.
- iOS `runChecks(ios)` simulator PASS after locator removal; Android `runChecks(android-vinetrack)` signed Release APK PASS after code12 increment. A release **build** is now authorized for test preparation, not a production release. Existing unrelated asset notices were not changed. Source-scoped diff whitespace check PASS.
- New retained changes in this pass: generic test source, Android versionCode11→12, this existing report, and existing approved-plan checkpoint. No application runtime logic, calculations, SQL, Edge, Trips tracking, storage identifiers, database records or unrelated features changed. iOS build171 is a publish-service override; the checked-in project still says139, so identify the installed archive by171 rather than the simulator/project setting.
- Final native source diff SHA-256 relative to starting HEAD: **`14783cf16c2a4e819e7e406eb135cb89b7dfd0885c6bfeeb05777da9e732caf0`**. No manual Git commit/push; final managed commit not exposed inside this turn.

### C. Fresh signed handset build availability — separate from acceptance

**iOS:** genuine signed **3.1.7 (171)**, bundle `app.rork.nt0v48tayl7v8noxcfe74`, existing Apple team `8Y879855VK`, ASC app `6761143377`. Existing ASC build170 was found before preparation, so169/170 were not reused. Certificate ready; capabilities unchanged. Managed submission **`8134acaa-0b55-41ea-81d9-086cb941dee1`** completed upload; ASC build **`f5647734-efe7-43e6-b6da-ac43729a6e9b`** confirmed **VALID**, uploaded `2026-10-15T14:17:49Z`. This is not simulator139. No App Store review submission/production release occurred. Tester-group availability and installation on iOS A/B are not yet proven; update the existing same-bundle TestFlight installation in place when171 is offered. A read-only attempt to inspect the build's betaGroups relationship was first rejected by CLI schema discovery and then by Apple's GET_RELATED restriction; no group/tester mutation or upload retry was made. This does not invalidate the confirmed VALID build, but is not proof a particular tester can see it.

**Android:** signed universal APK **3.1.7 / code12**, package `com.rork.vinetrack`, API24+, target36, ARM64/ARMv7/x86/x86_64. Artifact `android-vinetrack/app/build/outputs/apk/release/app-release.apk`, SHA-256 **`8af712194eb7a3a31fd7c3b4d3c4413b948a99a09e64b4c1a4950f62e3756943`**. Signature verification PASS, certificate SHA-256 **`241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3`**, CN=Rork Kotlin Play Upload. Matches the earlier documented signed code11 candidate, not the Debug certificate. No Play track publication or original-handset installation performed; no verified public download link claimed.

**Update safety:** package/team/storage paths remain unchanged. Existing handset certificate equivalence is unknown until read from the installed Android app; a Play-signed install may use a different certificate from this APK's upload key. Install only as an in-place compatible update. If Android rejects it, stop and retain the existing installation and all evidence; use its original signing/distribution channel. Never uninstall/clear data or substitute a Debug APK to overcome incompatibility. No automatic claim of all local data surviving an unperformed installation.

### D. Physical acceptance — PENDING, cannot be performed from this workspace

No access to the actual iOS A, iOS B or original Android handset exists here. Do not mark the following as passed based on tests, ASC VALID status, process probes or reported server counts:

1. Record each installed candidate/build and Android installed signing fingerprint/update origin; apply only compatible in-place updates. Preserve unsynced data, original GPS marker/payload and snapshot.
2. On owner/manager iOS A in the same vineyard, change one Repairs colour and sync. Verify genuine acknowledgement, then sync/relaunch iOS B and Android and compare the same button identity/colour. Retain device/build/timestamps and Sync Status evidence. Do not replace/delete configuration rows to make this pass.
3. On iOS, perform Trips and Button Config sync and confirm no missing-data decoder error. Inspect both exact sessions on the completed trip. This ZIP contains only sessions/Growth, not the full4584-point path or109-entry coverage array; full production-trip integrity is not proven by these fixtures.
4. On the original Android handset, let guarded retry read the completed trip and compare every preserved ordered observation (including duplicate multiplicity and available metadata). Only complete evidence inclusion may retire that exact marker as retained SYNCED. Missing/uncertain evidence stays held; no completed-trip PATCH/reopen, blanket marker removal or queue purge.
5. Capture authorized read-only before/after server integrity evidence: trip stays completed, exactly4584GPS points/109completed paths/two sessions with unchanged identities/content. No production database read/write was executed by Rork in this pass.
6. Verify each Sync Status surface: genuinely reconciled items may succeed; any unresolved GPS/config/other held work must remain visible, not be cleared for a green screen. Mismatch/decode/network/permission failures are not success.

Production release remains **NOT AUTHORIZED / gated on physical acceptance**. Supply handset screenshots/logs and installed Android signing/update origin to continue acceptance; do not send credentials or clear device storage. Exact-fixture gate is closed; physical gate is not.

## Urgent A/B/C sync corrections — historical checkpoint, 15 October 2026

### Scope and evidence boundary

Owner-reported production observations concern Stockmans Ridge legacy Growth buttons and completed trip `a3d88bdb-a9a4-497d-9a5c-7d14166ddc04`. This pass implements targeted mobile corrections only. The production row was not fetched, changed, reopened or deleted. No production SQL/data operation, backend deployment, queue purge, store action, release build, version increment or handset installation was performed. Other completed features remain frozen except the specifically necessary GPS sync/reconciliation seams below.

The two recorded tank-session JSON objects and raw legacy Growth array were not attached or found in the checked local docs/migration fixtures. Tests reproduce the described shapes with explicitly synthetic values. They are **not exact recorded-object acceptance**. The actual objects are required to close that gate; no test data was presented as production data.

### A. iOS Button Config

- Decode missing nested button `id` and `vineyardId` using the enclosing vineyard and a deterministic vineyard/config-type/slot identity. Existing supplied IDs, names, colour tokens, indices, mode and growth-stage flags are retained. Missing required values, invalid UUIDs, foreign scope and duplicate identities/slots fail visibly instead of generating default button configurations. Existing standalone/local ButtonConfig decoding is unchanged.
- Pull never replaces a real dirty Repairs/Growth edit or clears its marker merely because a remote timestamp is newer. The distant-past marker used only for generated initial defaults can still yield to a real server row.
- Existing server row IDs and creator identities are retained. Existing rows use conditional PATCH by vineyard/type/id, undeleted status and **exact server-issued `updated_at` text**, preserving microseconds. `sync_version` is not assumed to advance: checked source schema only guarantees a timestamp trigger. Missing concurrency evidence holds the edit. New rows use INSERT, not merge-upsert, so concurrent first creation cannot replace the winner.
- Require one returned server row matching IDs/scope/type and the exact sent button array. Zero-row CAS failures, forbidden/errors, malformed responses and mismatches retain dirty state. Clear only the exact pending timestamp and matching current local values; edits made during suspension remain pending. Dirty metadata saves use checked durable persistence, and failed acknowledgement persistence restores the pending state.
- A serialized full sync cannot show success or advance the displayed sync date while button changes or metadata failures remain. Account/sign-out-sequence/vineyard changes block local acknowledgement/publication. Existing server RLS still owns owner/manager write authorization; no role bypass was added.
- Synthetic iOS writer/shared-row/second-reader tests and Android LauncherButton wire decoding prove local compatibility. They do **not** confirm an authenticated owner/manager edit propagated between real devices or prove deployed RLS/trigger behavior.

### B. iOS tank sessions

- Read both camelCase local/iOS fields and the stored Android snake_case fields for tank number, start/end time, paths, start/end row and fill start/end time.
- Accept ISO8601 fractional/nonfractional strings and timezone offsets independently of the surrounding JSON date strategy. Numeric historical cache dates continue using the caller's existing Date decoder strategy. Invalid dates and contradictory aliases throw; dates/IDs/coverage are not guessed.
- Existing camelCase encoding is unchanged. No migration, historical rewrite, GPS/path derivation, session-ID reminting or completed-state change was introduced.
- Regression decodes two synthetic Android-shaped sessions and a synthetic full BackendTrip → Trip containing **4,584 points, 109 completed paths and two sessions**, then checks completed status and evidence counts/values. Numeric cache and ISO encoding/read-back are separately covered. The count match to the reported trip is a synthetic reproduction, not evidence that its actual objects were tested.

### C. Android interrupted GPS recovery

- Repository recreation changes only interrupted TRIP_GPS (alongside the pre-existing Work Task exception) from IN_PROGRESS to FAILED with a recovery explanation. ID/client ID, original payload, timestamps of the original operation, baseline and attempts remain retained; status/update timestamp changes only. No generic queue reset/clear or unrelated-operation recovery was added.
- Replay requires the current account incarnation, matching marker/trip, original owner, vineyard and exact current queue version. Old markers require a readable matching owned snapshot. Missing, unreadable, empty, foreign or mismatched evidence becomes a retained actionable hold, never a successful no-op.
- New markers persist the captured GPS observations and scope. When an owned snapshot contains a newer tail, retain that full evidence before any request and embed the original payload once as `originalPayloadJson`; the operation ID is unchanged. Snapshot divergence holds both sources. Same-trip completed restoration no longer replaces local GPS merely because the server path is longer, or blanket-deletes sibling trip markers.
- Fetch uses a captured-account request scope and original-claim admission. Verify server ID, vineyard, undeleted status, current claim/account and unchanged owned snapshot after suspension. Compare ordered **exact** coordinates, duplicate multiplicity and locally available bearing/speed/accuracy. Count, total distance or completion status alone cannot prove inclusion.
- If every retained observation is present remotely, durably retire only the exact GPS marker as SYNCED, retaining its payload/proof explanation. It no longer counts as pending. No completed-trip PATCH or active-trip publication occurs. If evidence is missing/divergent, retain it and show support/review instructions; never reopen or automatically merge into completed history.
- Active-trip GPS replay is separate: upload only a path containing all fetched server evidence, without jitter deduplication/discard. Require exact fetched `updated_at`, vineyard and still-active/unfinished/undeleted predicates in the PATCH, captured-account scope, complete returned evidence and current queue/snapshot before acknowledgement. Concurrent edits cannot be overwritten by a stale replay. A changed snapshot remains retryable. Existing normal live-capture equations/traversal and ordinary online autosave transport remain unchanged; new enqueue failures are contained in autosave and surfaced without dropping capture evidence.
- Retiring a verified marker is not a queue purge. Unrelated unresolved markers/holds are not silently cleared to make the overall Sync Status green.

### Focused executed evidence

| Surface | Result | Evidence level |
|---|---|---|
| iOS | **26 passed / 0 failed**, latest 56s | `VineTrackTests/SyncCompatibilityTests` (9 new cases) + `TankSessionLifecycleTests` (17 existing cases). Real temporary-file dirty metadata restart, failed disk acknowledgement, conflict/mismatch/newer-edit retention, full-sync failure→success, synthetic second-device row read, legacy identities, exact timestamp token, two tank/date/cache/full-trip decoding. Skipped count not exposed by runner. |
| Android host | **84 passed / 0 failures / 0 errors / 0 skipped**, seven XML suites | Final stable-source runner exit 0, 3m31s, independently XML-counted. Includes 11 new GPS/wire cases plus ActiveTripStore, ReplayVersionIntegrity, AtomicPendingReplacement, AuthRetentionGate, RetentionReview and TankSessionLifecycle. Final GPS XML timestamp `2026-10-15T13:43:01.658Z`. Overlapping runs are not summed. |
| Android process instrumentation | **Final 1 passed / 0 failed / 0 skipped**, 10s | `com.rork.vinetrack.data.TripGpsRecoveryAndroidTest`. Actually kills a separate debug Android app process, relaunches with a different PID, recreates real scoped preferences and the old marker shape, verifies all 4,584 synthetic observations against a synthetic completed response, retains original bytes/path and asserts pending count zero without PATCH/publication. Not real backend/network/main-authenticated-app or physical acceptance. Earlier 14s passing run overlaps and is not added. |
| iOS correctness build | **PASS** | Final `runChecks(ios)`, simulator only. No signed iOS handset build or IPA produced. Existing unrelated asset-URL notices left unchanged. |
| Android correctness build | **PASS**, final `:app:assembleDebug --build-cache --console=plain`, 11s | Final stable source; Debug only. Android runChecks was not invoked: it unconditionally builds Release, which the owner forbids. Latest instrumentation also compiled/installed debug app/test APKs on its isolated test emulator, not a handset. |
| Actual cross-device/handset/complete Sync Status UI | **NOT RUN** | Synthetic shared-row reading, decoder compatibility, coordinator state and pending-count assertions are not an authenticated three-device UI journey. |

Observed development failures, not hidden as passing/skipped: initial Swift test compile used an actor for a MainActor-isolated protocol; changed the test probe to a MainActor class. First executed Swift selection had 22 passes/1 failure because the new test had not created its temporary persistence directory; fixed the fixture directory and retained the assertion. Initial Android narrowed compilation omitted `RetentionReviewTest` shared helpers; added the required test source. First executed Android selection exposed the existing audit asserting GPS must remain stranded: updated only its explicit GPS expectations to preserve original bytes/attempts while checking the new FAILED recovery, and kept all other queue types stranded. Final selections above supersede overlapping development runs.

### Source and device-artifact identity

- Clean application/index baseline: **`354004cb0bd23e686eaa3f29a8eec9df4e517451`**. All prior receipt/calculator/keyboard/Inventory/Upcoming work preserved.
- Final native patch SHA-256 (`git diff HEAD --binary -- ios android-vinetrack`): **`c58d0181fa7e21a57ac121df9ad14f8b4595575a755e264d8d46227968bb4c11`**. This is baseline-plus-patch source identity, not a claim that baseline HEAD alone contains the fixes. Final managed end-of-turn commit SHA is not yet exposed. No manual commit/push.
- iOS: `app.rork.nt0v48tayl7v8noxcfe74`, **3.1.7 (139)**, unchanged. Simulator correctness build only. **A fresh signed physical-device artifact/build identifier is unavailable in this pass**; do not treat the old installed build or simulator output as handset acceptance of these changes.
- Android: `com.rork.vinetrack`, **3.1.7 / versionCode 11**, unchanged. Final APK `android-vinetrack/app/build/outputs/apk/debug/app-debug.apk`, SHA-256 **`2639e23934e374c20f091ba2bc9a051d18f71e8d9387b4cd7e5ece92135ab95f`**. Verified Android Debug certificate SHA-256 **`2be3dd871ef1b19723becbf8d556099274af3b740fd98ae3e5cfdaa6a3c000ce`**, API24+, target36. Earlier intermediate APK hashes are not this artifact. Debug signing may differ from an existing release install: never uninstall/clear data to overcome a mismatch while offline evidence exists. No APK/IPA upload, distribution or installation was performed.

### Exact changed-file inventory

All paths are project-relative; existing files except those labelled new.

**iOS**
1. `ios/VineTrack/Backend/Models/BackendButtonConfig.swift`
2. `ios/VineTrack/Backend/Repositories/ButtonConfigSyncRepositoryProtocol.swift`
3. `ios/VineTrack/Backend/Repositories/SupabaseButtonConfigSyncRepository.swift`
4. `ios/VineTrack/Backend/Sync/ButtonConfigSyncError.swift` (new)
5. `ios/VineTrack/Backend/Sync/ButtonConfigSyncService.swift`
6. `ios/VineTrack/LegacyImported/Models/Trip.swift` (TankSession reader only)
7. `ios/VineTrackTests/SyncCompatibilityTests.swift` (new)

**Android**
1. `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PendingWriteRepository.kt`
2. `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TripGpsSync.kt`
3. `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TripRepository.kt`
4. `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/Models.kt` (read-only Trip updated_at token)
5. `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt` (GPS autosave error containment and completed restoration only)
6. `android-vinetrack/app/src/debug/java/com/rork/vinetrack/data/LegacySprayProcessProbeActivity.kt` (isolated GPS fixture extension)
7. `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/RetentionReviewTest.kt` (explicit GPS recovery expectation)
8. `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/TripGpsRecoveryTest.kt` (new)
9. `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/TripGpsRecoveryAndroidTest.kt` (new)

**Supporting**
- `scripts/run-sync-recovery-tests.py` (new bounded runner; transient logs outside project)
- `scripts/sync-recovery-tests.init.gradle` (new source-narrowed host selection; no app build/version config change)
- `.rork/plans/android-live-trip-safe-automatic-complet_1791964262830.plan.md`
- `docs/reviews/final-mobile-acceptance-legacy-save-recovery-2026-10-15.md` (this existing report)

SQL, Edge, app build/version config, frozen GPS traversal/occurrence evaluator, TripsScreen, calculator formulas, keyboards, legacy receipt authority, Inventory and Upcoming source remain unchanged. Source-scoped whitespace checks pass.

### Remaining acceptance and operational risks

1. Supply the actual two tank-session objects and legacy Growth array; rerun exact-fixture regression without reconstructing production values. No credentials are needed for this.
2. With owner/manager handset access, change Repairs colour on iOS A, verify successful config sync, relaunch/sync iOS B and Android, and verify identity/colour and pin colour consumers. Confirm unauthorized writes are rejected by existing RLS without losing the local edit. No live test was performed here.
3. On the device retaining the interrupted GPS marker, restart then retry sync. If original evidence is readable and exactly included remotely, it becomes verified SYNCED; if its snapshot was already lost/replaced by older software, this fix cannot reconstruct it from a count. Keep the installation and retained evidence for support; do not clear the queue.
4. Review the completed trip on iOS and Android: server-completed state, GPS/coverage and both exact tank sessions unchanged. Confirm complete Sync Status independently; unrelated legitimate holds must remain visible, not be purged.
5. Deployed timestamp trigger/RLS and real-network CAS behavior were not queried or exercised. Exact-evidence policy can conservatively hold old paths if optional GPS metadata was historically discarded; this is intentional, not permission to drop observations. New frozen GPS evidence increases scoped local storage/write size; it prevents snapshot replacement from silently losing the queued route.
6. Fresh appropriately signed handset artifacts are required before physical acceptance. Current simulator/debug source verification is not a release, installed-handset result or authorization to distribute.

## Receipt-v1 integration closeout — historical checkpoint

This supersedes the historical containment-only checkpoint below. Allowed legacy no-route Save for Later now uses the deployed atomic RPC on both platforms. This is **mobile source integration plus synthetic/native evidence**, not authenticated backend or physical-handset acceptance. No SQL was executed, no backend deployed, no customer records mutated, no store access/distribution/version increment/release build or paid interactive simulator session was performed in this pass.

### 1. Exact source and preservation

- Current exposed committed HEAD: `a3aad9c287103e2f0904f25d75767120ddf62bc9`; application source/index initially clean. This preserves the prior keyboard, quantity, legacy containment, Inventory and Upcoming Tasks fixes from `041d72744229917046cff6d2619631b74a9ff7b3`.
- Native changes are identified by `git diff HEAD --binary -- ios android-vinetrack` SHA-256 **`16021a14dd8d30e19c56c5bde26da5e7a05049d93c0c54c25fe563404fcab608`**. The baseline HEAD is not misrepresented as the completed change commit. The final Rork-managed end-of-turn commit SHA is not exposed inside this turn; no manual commit/push was performed.
- Requested `99875fc2051fac1c3d55931a7d53ba71cb4cb61d` was unavailable to Git in this checkout. No reset/cherry-pick, older draft PR #2 restoration, linked-repo pointer update or external PR change was performed.
- Exact contract source: GitHub `stockmansridge/rork-vinetrack-june26` commit `bb72aa15335e51c30cdafbdedde1ff6a967695f2`, `docs/contracts/legacy_spray_pair_v1_handoff.md`, `legacy_spray_pair_v1_applied_migration.sql`, `legacy_spray_pair_v1_golden.json`. All three fetched/read as references only. Migration `20261015102804_legacy_spray_pair_receipts_v1` was already deployed by backend owner; Rork did not inspect/alter the live catalog or reapply it.
- Both platform golden fixtures are exact copies of the supplied synthetic file. Its fake UUIDs were never sent to a live server.

### 2. Request/receipt contract used on both platforms

Authenticated POST `/rest/v1/rpc/save_legacy_spray_pair_v1` and `/rest/v1/rpc/recover_legacy_spray_pair_v1` use exactly:

```json
{"p_operation_id":"<original durable UUID>","p_trip":{"...":"frozen typed Trip INSERT projection"},"p_record":{"...":"frozen typed Spray Record INSERT projection"}}
```

- No client actor parameter, client hash parameter, current-row adoption, HTTP409 acceptance, regenerated IDs or rebuilt timestamps. The current authorized user's JWT and normal anon API key are used; never service role. iOS captures token/user/refresh-session and checks its persistent actor/session/vineyard fence around transport/publication. Android uses account-access request attributes plus durable identity epoch and pre/post publication fences; the HTTP refresh interceptor cannot substitute another account.
- New allowed operations freeze original operation UUID and insert bodies durably before any send. A second durable claim precedes the first create request. Every subsequent uncertain/new-session-restoration attempt uses **recovery only**, never automatic create replay, even on `unknown`. This is deliberately more conservative than the contract's optional identical RPC-only retry allowance.
- iOS derives the insert from existing `BackendTrip.upsert`/`BackendSprayRecord.upsert` typed projections, excludes only known-empty non-insert runtime Trip fields after checking they are empty, and fails closed on additional fields. UUID identities are normalized to lowercase in the original insert projection because the deployed SQL compares text to `uuid::text`; identities are not changed. Full original native models and exact wire Data are retained separately.
- Android reuses the existing typed `ImportedTripInsert` and extracted shared `SprayInsert` constructor, including existing geometry/planning-wire projection. No full native model is serialized as an insert. Request JSON objects and original TripIntent/SprayInput are durably retained in the existing scoped store.
- Final receipts must have integer version 1; status `accepted` or `rejected`; exact operation/vineyard/Trip/Spray Record UUIDs; 64 lowercase hex `request_sha256`; valid `committed_at`; and valid status/code combination. Rejection codes accepted by v1 are `identity_conflict` and `validation_or_reference_conflict`. Arrays, errors, malformed bodies, unknown versions, conflicts, `unknown`, invalid IDs/hash/time and non-2xx responses cannot release a hold.
- Initial accepted/rejected receipt is retained as a candidate. Exact-request recovery must return the same complete receipt, including the SHA and committed timestamp. Recovery after a lost initial response can return a validated terminal receipt directly: the authenticated server has compared actor, immutable bodies, operation/scope/record IDs and PostgreSQL fingerprint. A different candidate/recovery hash or any lost follow-up remains held.
- There is **no native JSONB canonicalization implementation**. Golden tests hash only the supplied PostgreSQL canonical string and confirm 944 UTF-8 bytes and `f1950e94f85c8c3c3c431d74fcc83a17b7428a0b13e38a6c23f33aedab992a23`. This is not a claim that Swift sorted JSON/Kotlin serialization matches PostgreSQL.
- Verified acceptance is durably retained before dependent holds are released. Existing operational/compliance, Start, task-link, tank and authentication gates still apply. Android UI row reads occur only after acceptance and merely hydrate display. iOS skips generic original CREATE/upsert replay and cannot recreate a missing original through initial-sync fallback, including after later login/edit; an absent accepted row's dirty update remains pending/failed rather than recreating it. Unrelated eligible sync continues.
- A verified rejection is terminal, shown in native status and retained without deletion/reset/replacement. No new operation is silently minted. Old RPC-less evidence, including old Android REST `COMPLETE`, remains held; a local-complete flag or two historical REST echoes is not an immutable receipt. Arbitrary unjournaled historical records are not newly classified or rewritten.

### 3. Focused executed tests — current pass only

| Surface | Final result | Scope and evidence level |
|---|---|---|
| iOS unit/native | **106 passed / 0 failed**, 67s | Final disjoint class selection listed below. Includes 12 new receipt contract/file tests and production sync/task-link/fallback regression. Skipped metric not exposed. No live HTTP. Earlier 41/105/106 passing runs overlap and are not added. |
| iOS UI batch | **NOT ACCEPTED: runner overall failed/interrupted after 4 reported passes, 0 reported assertion failures** | Requested `KeyboardInteractionUITests` + `LegacySprayRecoveryUITests`. Output stops after test-product synchronization/run and gives no test names or cause. Managed `/tmp/rork-swift-test-ios.log` is inaccessible locally. No unchanged automatic rerun. Cannot attribute four passes to specific cases or claim the new RPC app-termination journey executed. New debug fixture/test is compiled, but current UI acceptance is unverified. Historical full keyboard/recovery UI successes below remain historical, not new passes. |
| Android host | **193 tests / 0 failures / 0 errors / 0 skipped**, 16 XML suites | Existing bounded calculator runner plus five new golden/decoder/request tests. Final runner exit 0, 3m28s including compilation. XML independently counted. All synthetic, not authenticated backend execution. |
| Android instrumentation | **84 passed / 0 failed / 0 skipped**, 20s | Final classes: LegacySpraySaveAndroidTest, data.auth.AuthRetentionAndroidTest, data.auth.FieldSaveContentionAndroidTest, ChemicalConditionPersistenceAndroidTest, InventoryUpcomingPersistenceAndroidTest. Includes 15 legacy tests, seven new receipt cases, and the existing real secondary-process kill test extended with RPC_CLAIMED/exact-request synthetic recovery. These are included in 84, not additional passes. |

Final iOS selection: `LegacySprayPairReceiptTests`, `SpraySaveForLaterTests`, `SyncStatusTimestampTests`, `SyncQueueRegressionTests`, `SprayTripStartAdmissionTests`, `SprayCalculationContractTests`, `SprayCalculatorUXPassTests`, `KeyboardSceneCoordinatorTests`, `ChemicalInventorySummaryTests`, `WorkTaskPlanningParityTests`.

Android host runner: `scripts/run-calculator-completion.py --launch` using the existing bounded init script plus `LegacySprayPairReceiptTest`; existing calculator/guided/carrier/rate/planning/first-tank selections retained. Exact XML output under ignored `android-vinetrack/app/build/test-results/testDebugUnitTest/` confirms 193/0/0/0.

Development failures retained: first Swift compile lacked the Supabase import; the next debug restart-fixture compile needed two explicit `try` expressions. Both corrected before final passing tests. Initial Android instrumentation used incorrect package names for two auth test classes (17 passes plus two class-load failures); corrected selectors to `.data.auth.*`, then final full 84 passed. This was a test-selection error, not a hidden passing business assertion. The separate iOS UI-run interruption remains unresolved and is not described as a pass. Final audit also found conditional accepted-ID suppression could vanish after a session/edit; fixed persistent accepted identity suppression, absent-row dirty-write containment and both Trip/record initial fallbacks, then final 106 tests passed.

### 4. Required scenario matrix and limits

| Requested scenario | Mobile synthetic/native evidence | Live authenticated authority |
|---|---|---|
| Initial atomic pair save | Requires validated create candidate plus matching exact-body recovery before release | BLOCKED: transaction/trigger/orphan behavior not independently exercised by Rork |
| Identical operation replay | Frozen operation/body equality, verified repeats do not resend, recovery receipt equality | BLOCKED: identical server stored-receipt replay not called |
| Lost successful response | Recreated native stores recover the exact claimed body with no create replay | BLOCKED: synthetic lost response/receipt, not real HTTP post-commit loss |
| Concurrent duplicate | Reentrant/connect overlap preserves IDs, one create claim; recovery-only competing path | BLOCKED: real database concurrent-lock/idempotency acceptance |
| Same operation / changed body | Original journal cannot be replaced; server conflict response cannot release hold | BLOCKED: real server changed-body call |
| Reused Trip/Record IDs | `identity_conflict` response is terminal and retained | BLOCKED: real cross-operation ID contention |
| Missing/revoked/foreign scope | Native account/epoch and original-scope checks prevent send/ack; errors do not become receipts | BLOCKED: real users A/B and current membership revocation |
| Reconnect / actual termination | Android real secondary process death retains RPC operation/body/claim and recovers via synthetic transport; iOS real-termination test authored/compiled, current UI run unaccepted | BLOCKED: main authenticated app network/lifecycle and physical handset |
| Old REST uncertainty/completion | Never adopted into RPC or automatically replayed; retained identity holds including old COMPLETE | No live old-row lookup used as evidence |
| Second-record failure / no orphan | Native client uses one atomic RPC; stored rejection/errors retain hold and original evidence; no compensating DELETE | BLOCKED: only backend owner transaction definition, no authenticated rollback test |
| Dependent Task/spray/Trip/Start | iOS production sync/task-link probes and native journals hold until verified acceptance; release still subject to all safety gates | BLOCKED: end-to-end authenticated operational dependency acceptance |
| Unrelated sync | Production iOS probes prove unrelated uploads while held; existing Android queues remain separate; retention/contention regressions pass | BLOCKED: combined deployed-main-app network acceptance |

No synthetic receipt, raw SQL review, golden hash, store recreation or secondary-process fixture is represented as authenticated backend acceptance, physical navigation, full cross-platform handover or real GPS evidence.

### 5. Native builds

- iOS final `runChecks(ios)`: **PASS, simulator build**. No device/release/App Store build.
- Android final `./gradlew :app:assembleDebug --build-cache --console=plain`: **PASS, 11s**; instrumentation also builds debug app/test APKs. Android `runChecks` was deliberately not invoked because that tool unconditionally builds `assembleRelease`, contrary to the explicit no-release-build restriction. No release APK was rebuilt or distributed in this pass.
- Versions/build numbers unchanged. Protected-source and application whitespace audits pass. Existing iOS legacy asset URL notices are unrelated and left unchanged.

### 6. Authenticated backend results and integration discrepancies

**Authenticated live calls: NOT RUN / BLOCKED.** The owner explicitly confirms there are no provisioned/verified genuine test users and isolated vineyard. No customer mutation, synthetic golden request submission, service-role validation, credential request, SQL Editor test, deployment or live authenticated receipt claim occurred. Provision/verify isolated genuine JWT users A/B, membership/reference fixtures and safe cleanup before executing the handoff's server matrix.

**Actual client/contract discrepancy:** v1's exact allowlists omit newer fields that the existing validated spray insert can emit: `sprayer_configuration`, `spray_planning_method`, `full_tank_specification`, `planning_input_provenance`, `planning_intended_tank_litres`, `planning_target_area_ha`, `planning_calibrated_litres_per_hectare`, `planned_application_area_ha`, `resolved_planning_carrier_litres`, `resolved_planning_litres_per_hectare`, `resolved_planning_physical_row_litres_per_100m`, `resolved_planning_concentration_factor`, `controller_litres_per_100m_travel`, `effective_working_width_metres` (and any explicit-cleared versions). A request carrying these is rejected **locally before transmission**, retaining the complete original native mix and a contract-review status. Exact shape is the same three-argument envelope above, but `p_record` includes the additional planning keys; no server result was observed. Failure classification: **local unsupported insert contract**, not accepted/rejected/unknown/HTTP failure. Removing necessary planning evidence, reclassifying it as manual, changing calculations or widening the server allowlist was not authorized and was not done. Similarly, an occurrence-backed or work-task-linked Trip is not routed through this legacy RPC. Backend-owner alignment is required before those out-of-contract mixes can be sent through v1.

There is no observed live server behavioral discrepancy to report, because no live authenticated tests were authorized or possible in this pass.

### 7. Changed native files

Android:
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/LegacySprayPairReceipt.kt` (new)
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/LegacySpraySaveStore.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/SprayRecordRepository.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TripRepository.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt` (legacy no-route creation/reconnect only)
- `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/LegacySpraySaveAndroidTest.kt`
- `android-vinetrack/app/src/debug/java/com/rork/vinetrack/data/LegacySprayProcessProbeActivity.kt`
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/LegacySprayPairReceiptTest.kt` (new)
- `android-vinetrack/app/src/test/resources/legacy-spray-pair-v1-golden.json` (new exact supplied fixture)

iOS:
- `ios/VineTrack/LegacyImported/Services/LegacySprayPairReceipt.swift` (new)
- `ios/VineTrack/LegacyImported/Services/LegacySpraySaveRecovery.swift`
- `ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift`
- `ios/VineTrack/Backend/Sync/TripSyncService.swift`
- `ios/VineTrack/Backend/Sync/SprayRecordSyncService.swift`
- `ios/VineTrack/App/BackendSettingsView.swift` (receipt/rejection status)
- `ios/VineTrack/App/Keyboard/LegacySprayRecoveryValidationView.swift` (debug-only synthetic restart fixture, not keyboard production behavior)
- `ios/VineTrackTests/LegacySprayPairReceiptTests.swift` (new)
- `ios/VineTrackTests/SpraySaveForLaterTests.swift`
- `ios/VineTrackTests/legacy-spray-pair-v1-golden.json` (new exact supplied fixture)
- `ios/VineTrackUITests/LegacySprayRecoveryUITests.swift`

Supporting updates: existing approved plan, this existing report, `.rork-tmp/calculator-completion.init.gradle` focused test selection and its existing runner log. No SQL/Edge/build configuration/linked-source changes. Rork-managed history/state remains tracked and untouched by manual edits.

### 8. Release-readiness and physical checklist — still open

**Not declared release-ready.** Remaining: isolated authenticated server matrix; v1/newer insert-field alignment for affected mixes; interrupted iOS UI batch; physical acceptance; final managed commit SHA exposure. Existing broader occurrence/Portal/full-schema gates remain separate and were not activated or resolved by this legacy-only pass.

Physical owner checklist (all unexecuted here):
- [ ] iOS VoiceOver focus/traversal and keyboard-only Done, retained prompt/draft, separate Confirm/Cancel.
- [ ] Small iPhone, larger Dynamic Type and dark mode; quantity text retains 0.525 kg → 0.53 kg.
- [ ] Archived Chemical Inventory remains excluded after actual device restart, both platforms.
- [ ] Upcoming Tasks refresh correctly after foreground resume and vineyard-local midnight/day rollover.
- [ ] Offline Save for Later retains original operation/IDs/payload after real main-app termination; authenticated recovery in isolated scope releases only matching accepted receipts; revoked/foreign accounts cannot adopt it.

Calculations/CF/rate safeguards, eight-step calculator UI, Single Row/Over-Row/Only Full Tanks, warning-only policy, native keyboard production dialog, Chemical Inventory archive logic, Upcoming Tasks/local-day logic, auth recovery, frozen Live Trip source and existing historical records/Actuals are protected and unchanged. New planning and occurrence creation were not activated. No store/publishing action is authorized by these results.

## Historical checkpoint — prior code-only containment

### Previous checkpoint — code only

This checkpoint supersedes the earlier status/evidence below. Store authentication/access, TestFlight/Play distribution, version increments and device installation are cancelled. No store workflow was called after the owner's STOP correction. No store build was submitted or distributed. No interactive simulator rental, production backend call/deployment, dosing arithmetic change or frozen Live Trip change was performed during this development pass.

| Deliverable | Current result |
|---|---|
| iOS editable-prompt keyboard | **PASS.** SwiftUI system alert was replaced only for editable prompts with an app-owned native modal input dialog. Done is a real button inside the dialog's accessibility hierarchy, resigns only the input and preserves the dialog/draft. Confirm/Save and Cancel remain separate. The global keyboard coordinator and existing focus-transfer implementation are unchanged. Full original keyboard XCTest class: **6/0**, including the corrected popup journey; only the popup container/Done locator changed for the approved alternative, all dismissal/draft/no-submit assertions remain. Actual physical VoiceOver traversal remains unverified. |
| iOS legacy recovery/status | **Local implementation PASS; immutable remote acceptance remains held.** Eligible push/pull success is distinguished from held pairs via a partial-sync state; full-sync/server-ready stamps do not advance. Per-pair local repair conflicts and foreign-session evidence do not veto unrelated synchronization. Retained IDs are excluded from upload/delete/pull and direct work-task link mutation; parent readiness and Start remain refused. Original WAL is not replaced or erased. |
| Android legacy recovery | **Provably-unsent recovery PASS.** PREPARED is the only first-send-admissible stage. Startup/vineyard load/reconnect reuse original IDs, timestamp, frozen Trip/input and captured authenticated authority. UNKNOWN is durably committed before transport, so cancellation/lost/malformed/409 outcomes never revert to PREPARED. No uncertain-stage replay, remint or rollback. Device-only saved/pending status is explicit; account-session changes remain fenced. |
| Calculator/UI freeze | Eight steps, Step 6 cards/illustrations, Single Row/Over-Row, By Area/Only Full Tanks, WARNING-only policy and rate/draft/regional corrections preserved. All new planning operational gates remain disabled. Final regressions exposed a quantity-display tie rounding error (0.525 kg was shown as 0.52 kg); product quantity formatting now rounds that tie to 0.53 kg, retaining local decimal separators. No dose/CF/conversion equation changed. An informational canopy-comparison flag now requires actual dilute-reference evidence rather than assuming canonical L/ha means a canopy comparison occurred. |
| iOS automated regressions | **525 unit/native tests passed, 0 failed** across two disjoint final selections (368 core + 157 recovery/regional/planning/keyboard). **12 UI tests passed, 0 failed** across two disjoint bounded selections (6 keyboard + 6 editing/presentation/restart). Final direct-link/held-status hardening: **30/0**, overlapping the 157 and not added. |
| Android automated regressions | **188 host tests / 0 failures/errors/skips**, 15 suites; **93 instrumentation tests / 0 failures/skips**, including editor/planning/chemical-condition persistence, legacy original first-send/lost-response containment, actual secondary-process death, occurrence persistence, account retention and field-store contention. Eight legacy tests are included, not extra. |
| Native correctness builds | **Both passed.** iOS simulator compilation and Android native build only; no signed iOS handset/TestFlight or Play release acceptance claim. App versions and release numbers unchanged. |
| Source | Current exposed HEAD `3331302aa4ceb023431df404d43eea238d1e5a13` plus the final native diff SHA-256 `74594230ef75462ef39ed4357a445184237d8ea6a752c8781f52ff1e743ff41b`. This HEAD alone is not the final changed source. Rork creates the final commit at turn completion; its final SHA is not exposed during this turn and cannot honestly be invented. Requested `59242a2568d485769db5b882be0a0c950441c34f` is unavailable to Git here; recovery source was reconciled by content without reset/cherry-pick or replacement of newer work. |
| Remaining external acceptance | Backend owner (ChatGPT/backend): authenticated immutable legacy paired-create receipt/recovery authority and real ambiguous-HTTP/reconnect/concurrent-server acceptance. Handset owner: separately authorised physical VoiceOver, small-screen/dark/larger-text and real screen timings. These are not unresolved automated mobile assertion failures. |

### Exact final selections

Core iOS 368/0: SprayCalculationContractTests, SprayCalculationParityTests, SprayCanopyAndRatePresetTests, SprayCanopyCarrierRoutingTests, SprayGuidedFlowTests, SprayGuidedWorkflowParityTests, SprayRegisteredUseRateTests, ChemicalLabelRateNormalizerTests, CropSilRateRegressionTests, SprayEditChemicalRegisteredRateDisplayTests, SprayRateBasisPreferenceTests, SprayLegacyRateUnitBoundaryTests, SprayApplicationGeometryTests, SprayApplicationSnapshotTests, SprayCarrierProductBasisTests, SprayVolumeDecisionTests, SprayManualVolumeTests, SprayBandedGroundCarrierTests, SprayCustomSprayerBasisHotfixTests, SprayEquipmentAndCarrierHandoffTests.

Recovery/regional iOS 157/0: SprayGrowthStageDecisionTests, SprayRegionClosureTests, RegionalInputTests, SprayPlanningIntentTests, SprayPlanningAttemptTests, SprayPlanningDraftTransitionTests, SpraySaveForLaterTests, SyncStatusTimestampTests, SyncQueueRegressionTests, KeyboardSceneCoordinatorTests, SprayCalculatorUXPassTests, SprayCarrierProvenanceTests, SprayTripStartAdmissionTests, SprayStartPresentationTests, SprayTripSetupTests.

UI: KeyboardInteractionUITests 6/0, 200s; SprayEditingAcceptanceUITests + SprayPresentationUITests + LegacySprayRecoveryUITests 6/0, 209s. The restart test covers all four original local boundaries using real app termination/relaunch and isolated storage; no authenticated server recovery is implied. iOS runner does not expose a separate skipped count.

Android host: `scripts/run-calculator-completion.py --launch`, final exit 0, 30s; XML independently confirms 188 tests / 0 failures/errors/skips. Instrumentation: LegacySpraySaveAndroidTest, SprayChemicalEditorAndroidTest, SprayPlanningAndroidTest, ChemicalConditionPersistenceAndroidTest, TripOccurrencePersistenceAndroidTest, AuthRetentionAndroidTest, FieldSaveContentionAndroidTest: 93/0/0, 47s. Secondary-process kill is genuine Android process evidence, not proof of main authenticated Activity/network recovery.

### Development failures retained, not hidden

- Accessory installation alone still failed the original popup query (9 passes/1 failure). Replaced affected editable prompts with the native dialog; the focused original journey plus native tests then passed 10/0, and final full keyboard class passed 6/0.
- The wider core selection exposed 23 failures: outdated prerequisite fixtures (explicit equipment/canopy/ground decisions, valid product before persistable snapshot), old stock-unit equivalent wording, locale-sensitive text and manual entry-versus-canonical-carrier metadata. Fixtures now reflect approved production contracts; unknown new canopy remains unconfirmed. Label-rate units are retained in equivalents; liquids use original canonical mL. No quantity assertions were relaxed or dose formulas changed. Valid display half-tie rounding and informational comparison metadata were corrected in source. The final core selection passed 368/0.
- Three later cross-surface failures were fixture-only: invalid `Kilograms` wire literal instead of `Kg`, liquid values entered as litres in a base-mL fixture, and an advisory Save test without authenticated WAL scope. The latter now also asserts that WARNING-only chemistry cannot bypass the separate receipt hold.
- One combined runner stopped after 162 passes with no reported assertion failures and was not counted as successful; the reported remote log path did not exist in this sandbox. Splitting unit and UI execution into bounded selections produced the explicit successful results above. Selector-validation errors executed no tests.

### Precise server dependency (unchanged)

Only uncertain remote outcomes and iOS receipt-held local pairs still require backend authority. Acceptance must bind the authenticated actor, vineyard, original operation/record/Trip IDs, complete immutable payload and any existing occurrence-parent dependencies; serialize same-request duplicates and reject same-ID/different-payload; atomically create the pair or retain an immutable conflict/rejection result. Recovery must return the original accepted/rejected/unknown result and exact request identity, not mutable current row existence or HTTP 409. Lost replies remain unknown until that receipt is verified. Historical valid rows remain compatible and must never be adopted as a new operation by inference. No tracking, actual coverage, tank, labour, inventory or current-geometry reconstruction effects belong to Save for Later recovery. Native integration against that contract and authenticated transport fixtures remains Rork's follow-up once the backend owner supplies the verified authority.

Application-scoped whitespace checks pass. SQL/Edge, frozen tracking/TripsScreen, new planning journals and version/build configuration have no changes in this pass. Existing asset-URL advisory warnings are nonblocking and were left outside the requested scope.

## Historical checkpoint — superseded status table

| Item | Result | Exact qualification |
|---|---|---|
| Six iOS canopy regressions | **PASS — all six** | The 96-test affected calculator/recovery selection passes. Only obsolete wording and outdated fixtures changed; production canopy calculations/validation unchanged. New selection still has no assumed VSP; historical/prefilled selection retains intentional confirmation. |
| SwiftUI alert Done | **OPEN** | Focused hosted-SwiftUI native diagnostic initially passed, then failed native visibility in the wider run (103 passes/1 failure). Original full XCTest still fails to find `keyboard.dismiss`. This is not established as a query-only defect. Real VoiceOver navigation unverified. |
| Legacy Save for Later | **Production local recovery / containment implemented; remote acceptance BLOCKED** | Both platforms retain the complete original attempt before dependent writes and integrate startup/sync admission. iOS repairs interrupted local files; Android retains uncertain REST stages without automatic resend/rollback. Receipt-based remote recovery is not implemented or claimed. |
| Android editor / label parity | **Preserved; focused regressions PASS** | Combined instrumentation 16/0/0; later recovery-only hardening run 5/0/0. Existing dot/comma, invalid-draft, Done and label-selection policies unchanged. iOS production editing/Step 6 UI passes. |
| Five Start Spray presentation decisions | **Unchanged** | No redesign or duplicate controls. Summary adds truthful device-local save status, not a CF acknowledgement or new planning gate. |
| New planning | **Operational gates remain closed** | New planning attempt journals/activation state unchanged. No planning RPC exercised; Review remains one intention-only selector and three distinct groups. |
| Source / native candidates | **Identified below; final managed commit pending** | Current exposed source is `a7fadaf856afa002c96ffd38cbbae8ffe52aa575` plus this pass's patch. Requested `0ab37a6ca5b008cdf5712fbf38ccb486710ad62c` object unavailable; no rollback to it. Both final builds pass. |
| Controlled handset UI acceptance | **Checklist READY; execution BLOCKED** | Independent of legacy recovery. Need separately authorised, exact-artifact handset session; no latest signed iOS device artifact or verified handset installation is available. Do not assume TestFlight 168/169 or old APKs contain this patch. |
| Full operational release acceptance | **BLOCKED** | Alert visibility/accessibility, verified legacy paired-create receipts/real HTTP reconnect, physical handset journeys and remaining broader backend acceptance are unaccepted. No release is authorised. |

## Source protection

Initial application/index state was clean at `a7fadaf856afa002c96ffd38cbbae8ffe52aa575`; only pre-existing managed Rork state/history differed and was left untouched. `git show` for the supplied 0ab37a6… revision returned “bad object / not our ref”. The current production files contain the consolidated numeric/label corrections; no attempt was made to restore an older tree or overwrite newer source.

Source-scoped whitespace checks pass. No SQL, Edge, chemical catalogue, GPS/row locking, coverage/tank Actual authorities, frozen `TripTrackingService.swift`, Android `OccurrenceTraversalTracker.kt` or `TripsScreen.kt` changes. Both new `SprayPlanningAttemptJournal` implementations are unchanged. The Android ViewModel edits are limited to legacy no-route creation, its admission/start hold and startup/dependent-sync containment; no traversal/ETA/tank tuning.

## Canopy reconciliation

All six named tests pass after source-backed fixture reconciliation:
- `foliarRequiresCanopyConfirmation`: matches “Select canopy type, size and density”.
- `canopyStepPrecedesProducts`: matches “Canopy & Spray Volume”; preserves eight-step ordering.
- `selectionUsesTheExistingTable`: explicitly chooses VSP before size/density, then compares the existing table.
- `touchingAPickerConfirms`: explicitly chooses a type before expecting a picker to resolve the complete canopy.
- `confirmingUnchangedValuesCounts`: explicitly chooses a type; confirming defaults without type remains unresolved in the opening-position assertion.
- `completingProductsDoesNotEndTheStep`: supplies an explicit confirmed canopy, target/head target, growth-stage decision, equipment selection/confirmation/capacity and volume decision, rather than bypassing genuine earlier prerequisites.

No new spray assumes VSP. Historical `prefilled` compatibility remains tested. Neither production validation nor equations changed.

## Alert diagnostic and genuine remaining defect

Hypothesis: SwiftUI presentation may replace/hide the accessory despite working native UIKit installation. Added one hosted SwiftUI `.alert` diagnostic using an app-owned scene window and the production coordinator. It finds the real text field across same-scene windows, checks its accessory/window, native visibility, accessibility-element label, keyboard-only dismissal and unchanged alert/draft/submission state.

Observed results:
- Initial focused diagnostic + original UI journey: **1 passed / 1 failed**. Native diagnostic passed; original XCTest failed its Button lookup for `keyboard.dismiss`.
- Subsequent wider selection: initially **104/0**, then **103/1**. The sole later failure was `swiftUIAlertOwnsAccessoryAndDismissesWithoutSubmitting`: `nativeVisible` failed. Its separate accessibility-label and programmatic dismissal assertions did not fail.
- Thus labelled native-control configuration and programmatic keyboard-only dismissal are demonstrated in the fixture, but reliable visible presentation is NOT. Actual VoiceOver traversal/publication cannot be inferred from native accessibility properties.
- The complete original XCTest remains **FAIL**: `Failed to no matches found for first query match sequence: Descendants matching type Button -> Elements matching predicate '"keyboard.dismiss" IN identifiers'`.
- Original assertions remain; production coordinator/accessory were not rewritten, and no unsupported workaround or additional dedicated simulator inspection was used. No unchanged failure was repeatedly retried to find a green result.

A later final calculator/recovery selection deliberately excludes the separately known failing keyboard diagnostic; its 96 passes do not erase the 103/1 wider result or full UI failure. Owner: Rork. Required closeout: establish reliable SwiftUI accessory presentation and real accessibility publication/tap without changing alert confirmation semantics.

## Legacy recovery implementation and exact containment

### iOS production integration

Files: `LegacyImported/Services/LegacySpraySaveRecovery.swift`, `MigratedDataStore.swift`, `NewBackendAuthService.swift`, `SprayCalculatorView.swift`, `SprayTripSetupSheet.swift`, Trip/SprayRecord sync services.

- A separate checked atomic local write-ahead record captures actor, vineyard, a durable session UUID, complete original record/Trip, stable IDs and frozen occurrence evidence. This is NOT a planning-protocol receipt/journal.
- Preparation now precedes even existing occurrence-parent preparation. The existing occurrence machinery is not replaced, reminted or enabled.
- A restored same-actor session uses its persisted UUID; explicit sign-out must durably rotate it first or sign-out is refused. Foreign actors/sessions never repair an old attempt.
- Original record/Trip are encoded into nested bytes preserving fractional dates. The legacy cache ISO-second projection is compared using its existing codec, not by relaxing chemical/route fields or rewriting historical codecs.
- Recipe and inactive Trip are checked/repaired from the original WAL, followed by a completion marker. Neither dirty callback fires before all three writes are durable. Existing differing values are held, not overwritten. Active/ended/tank-session/coverage-bearing attempts are refused.
- Hydration attempts reconciliation; both production sync writers reconcile again before dependent writes. Initial empty-server fallback, dirty upserts, deletes, remote replacement and work-task-clear admission exclude retained IDs. Unrelated records retain their normal sync path. A held sweep is not labelled server-success.
- Ordinary REST last-write-wins upsert cannot prove immutable original acceptance. New retained pairs therefore stay **device-local / remote-held**; generic upload, automatic recovery and saved-job activation are refused pending verified paired-create recovery. The summary explicitly states device-local status. Existing unjournalled eligible saved jobs keep their existing path.
- A locally completed but remotely held attempt cannot be bypassed with a new ID/session for that actor/vineyard. Retained evidence is never deleted automatically.

This is safe client containment, **not full legacy server completion**. There is intentionally no invented remote receipt or automatic LWW replay. Device-local completion does not imply synchronization or operational readiness.

### Android production integration

Files: `data/LegacySpraySaveStore.kt`, `TripRepository.kt`, `SprayRecordRepository.kt`, `auth/AccountTransitionEvidence.kt`, and narrowly scoped `AppViewModel.kt` seams.

- The no-route branch mints Trip/record IDs and timestamp once, captures full original accepted input/Trip intent, actor and persistent identity epoch, and durably commits before its first request. Qualified occurrence-backed flow remains separate and unchanged.
- Stages: Prepared → Trip Unknown → Trip Confirmed → Record Unknown → Complete. Every advance requires a checked synchronous preference commit/read-back under existing account admission. Failed commits never report success.
- Captured token/actor are used for both initial sends, never a newer login's credentials; tokens are not persisted. Publication is fenced by the original `AccountAccess`.
- Successful initial `return=representation` responses must echo submitted fields, including nested quantities/conditions, with only numeric/ISO timestamp representation equivalence. This validates that initial response; it is NOT acceptance of a later current-state read. 409/malformed/changed/lost replies remain uncertain.
- Startup/vineyard load surfaces retained work before reconnect replay. It never inserts this envelope into the generic outbox. Dependent queued references are held; unrelated pipelines are not globally disabled. A retained incomplete Trip cannot be started through Start Spray Job.
- No ambiguous rollback via `soft_delete_trip`, no fresh-ID resend and no automatic outcome inference. Sign-out evidence inspection includes the new retained store and fails conservatively; cross-account recovery is not adopted.
- Known offline preparation is retained and returns false, not server success. Unfinished attempts block a newly minted retry in that actor/vineyard. The original payload/IDs remain available for receipt-based reconciliation.

### Remaining essential backend dependency

ChatGPT/backend owns a validated authenticated legacy **paired-create acceptance/recovery contract** (or an explicitly approved mapping to existing immutable authority) that can establish:
1. Exact original actor/vineyard/operation and complete payload identity, including record/Trip IDs and occurrence-parent dependencies.
2. Authoritative immutable original acceptance versus rejection/unknown, not mere current row existence or HTTP409.
3. Atomic/idempotent acceptance of the same request, same-ID/different-payload refusal and conflict-safe parent/recipe ordering.
4. No tracking, coverage, tank/labour/inventory effects in Save for Later recovery; no route reconstruction from current geometry.

No signature/RPC installation, credentials, backend access or deployment is assumed. Rork still owns transport-failure/reconnect integration against approved receipt fixtures/authority once available. Full authenticated ambiguous-HTTP recovery and concurrent-server duplicate prevention are NOT claimed by these tests.

## Executed evidence — do not sum overlapping selections

| Surface | Latest result | Evidence limit |
|---|---|---|
| iOS final calculator/recovery unit selection | **96 passed / 0 failed**, 88s | Six calculator/recovery suites, excluding separately known keyboard failure. Includes all six canopy fixes and production sync fallback/containment regression. |
| iOS recovery-only final hardening | **9 passed / 0 failed**, 62s | WAL failure boundaries, conflict/scope guards, exact fractional-date evidence, dirty/fallback/delete containment and unrelated-record sync. Overlaps 96. |
| iOS final UI selection | **3 passed / 0 failed**, 190s | Two existing production chemical/regional tests plus one real app terminate/relaunch test looping four local boundaries. |
| iOS app-process restart fixture | **Pass at prepared, recipe, Trip and completed-local boundaries** | XCTest terminates/relaunches the real app with production store/WAL in isolated debug storage. Not abrupt OS kill during a disk write, not authenticated server reconnect. |
| Android combined instrumentation | **16 passed / 0 failed / 0 skipped**, 49s | Five legacy containment tests plus three editor and eight existing planning UI/persistence tests. Synthetic account and transport-free state scenarios. |
| Android final recovery hardening | **5 passed / 0 failed / 0 skipped**, 16s | Production checked preferences; failed commits, scope revocation, changed echoes, recreation and actual secondary-process death. Overlaps 16. |
| Android process-death probe | **Pass at all four unfinished stages** | `Process.killProcess` kills a debug-only `:legacySaveProbe` Android process; a newly launched process independently reads original IDs/payload/stage and retains the hold. Not a host JVM child, but also not the main authenticated Activity/ViewModel lifecycle or actual server reconnect. |
| Android host calculator regressions | **188 passed / 0 failures/errors/skips**, 15 suites | Existing bounded runner; model/state evidence only. No new screen timings inferred. |
| Original iOS full alert UI journey | **Failed** | Assertion retained. Native visibility diagnostic also has the later failure described above. |
| Final iOS build | **Passed** | Simulator build only, no new signed handset/TestFlight artifact. |
| Final Android build | **Passed** | Release APK only; no handset install/distribution/upload. |

New process fixtures are debug-only, use isolated synthetic scoped storage and never call live backend, create vineyard data or start recording. Standard native tests ran in the managed test environment; no dedicated interactive simulator rental or handset deployment was performed. Assertion failures during development are not hidden: initial date-equality tests exposed the legacy ISO-seconds codec; original WAL now preserves full dates and existing-store comparison uses the exact legacy codec. One throw-expression compile error in the sync fallback guard was corrected before the final passing build/tests.

## Exact candidate identities

- Visible HEAD: `a7fadaf856afa002c96ffd38cbbae8ffe52aa575` **plus this pass's managed native patch**, not HEAD alone.
- SHA-256 of `git diff HEAD --binary -- ios android-vinetrack`: `b4543b33c2cea2ace1dc6f65d39fe04a42f4dbdf3fb1925a9f944314707a094f`.
- Final managed commit is not exposed during this turn. No manual commit/push; post-finalization attribution is required for an immutable source-commit candidate.
- iOS: `app.rork.nt0v48tayl7v8noxcfe74`, project version 3.1.7/build 139; final simulator build passed. There is **no new exact signed IPA/TestFlight handset artifact** for this patch. 168/169 are not assumed current.
- Android: `com.rork.vinetrack`, release version 3.1.7/code 11; `android-vinetrack/app/build/outputs/apk/release/app-release.apk`.
- Android APK SHA-256: `eaab1e61e4bb8c13bc7044964dd3ac60f5b27dfc1e53d981ab26bbda0e4ced83`.
- This is the new calculator/legacy-containment candidate, not frozen Live Trip APK `8836a3025c30a779c04a0e1207490687f3d73a55ebf05eab1babb3eae4a538bb`. Shared version numbers do not identify code. Handset installation and independent new signer verification unexecuted.

## Controlled handset checklist — independent of legacy recovery

Checklist prepared; **do not install/upload/distribute without separate authorisation**. Use only an existing approved synthetic/non-operational account and an artifact whose installed identity is verified against this candidate. Never clear pending data/uninstall to overcome signature/version mismatch. No Trip creation or operational button activation is needed for these checks.

Record device/model, OS, installed commit/artifact identity, region, dark/light mode, text-size setting, approximate timestamps and screen recording before starting. Repeat on the smallest authorised display at default and larger accessibility text.

1. Navigate all eight guided steps; verify Back retains drafts and Continue unlocks only after actual prerequisites. Explicitly choose canopy type/size/density; do not assume VSP.
2. Step 6: retain the two inline cards, Single Row / Over-Row, original vines/sprayer and vine-facing cyan/blue arrowheads. At 600 L/ha and 2.8 m, controller travel is 16.8 / 33.6 L/100 m; physical rate/chemical dose stay unchanged.
3. By Area / Only Full Tanks: inspect existing Target area and Calibrated rate fields. 1500 L over 3 ha gives 500 L/ha; 1500 L at 600 L/ha gives 2.5 ha. Separate tank-load Full Tanks labels remain.
4. Open the existing label-rate sheet; confirm large numeric rate/unit and all crop/target, condition/direction/restriction/withholding/re-entry text. Select an explicit valid REVUS/Crop Sil condition or offered preset; do not guess missing rates. Incompatible DiPel dimension remains noncalculable.
5. Open/close orange WARNING details, including an eligible CF2/unknown-permission scenario. It changes no values and requires no acknowledgement; invalid calculations remain invalid. Do not activate disabled new planning.
6. Enter dot/comma pairs 25.75/25,75; 0.75/0,75; 1250.5/1250,5. Try incomplete trailing separators and malformed nonblank text; original draft remains visible and no old/recommended dose becomes executable. Inspect per-100 L and per-hectare independently.
7. Use Done, re-focus, Back and reconstruction in chemical editing. Done only dismisses keyboard. Change regional units: complete values convert together; incomplete groups retain original units and guidance.
8. Inspect the alert while typing: separately capture whether Done is visually present, VoiceOver reaches it, it dismisses keyboard only, alert/text persist and Confirm/Cancel/Save counters do not change. The automated failure is open; do not presume success.
9. Scroll all controls at large text/dark mode; no obscured fields, overlapping labels, clipped buttons or tiny forced text. Stop before any Save/Start effect.
10. Review contains Planned Spray Mix, Selected Physical Work and Actual Spray Coverage. Selection describes intention only, Over-Row is one travel occurrence/two controller equivalents, and no actual coverage is manufactured. No duplicate selector or tracking shortcut.
11. Confirm the existing eligible entry workflow is presented, but do not create Trips or invoke new planning to test it. Device-local legacy-held work must be labelled pending, not server-ready.
12. In the authorised authenticated session, capture timestamps for calculator opening, Step 6, numeric edit/Done, rate-sheet opening and Review rendering. Report actual visible-screen durations with device/network/context separately from model/I/O benchmarks. Do not add a performance refactor without a measured bottleneck.

No physical screen captures, VoiceOver navigation or genuine handset screen timings were collected in this pass. Existing Android caching and iOS product mapping optimisations are unchanged. Controlled UI inspection must not be delayed for backend recovery once an exact authorised handset artifact/session is available; operational Save/Start remains separately blocked where receipt evidence is missing.

# Mobile source closeout / legacy Save for Later — 15 October 2026

## Latest checkpoint — code only

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

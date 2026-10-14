# VineTrack — Device Testing Readiness Report

Date: 2026-10-13. Scope: controlled synthetic handset UI/local-data/blocked-state testing only. No Supabase/SQL/RLS/production chemical mutation, dosing equation change, planning-write activation or public release.

## 2026-10-14 Start Spray presentation and WARNING-ONLY correction

### Current policy and five implemented corrections

This owner request supersedes ALL historical permission-only CF/above-reference hard-block policy in the sections below. Unverified label approval, concentrate permission and limits are advisory, not execution authority and NOT independent Save/Start/Continue blockers. No equation, rate, persisted identifier, historical record, SQL migration, operational-planning activation or release was changed.

1. Removed CF > 1 permission-only refusal from both shared operational gates, including their consumers in calculator, local record/upsert, repositories, Save for Later, Start/Start Tank, enqueue and replay. Removed the above-reference gate whose only reason was independent label-review uncertainty; existing engine dose resolution and invalid-quantity requirements remain. CF must still be present/finite/>=1 for a dilute-rate tank; ambiguous dual rate basis remains blocking with accurate explicit-basis wording. Unknown permission does not enter readiness. Review now has a compact orange WARNING button followed by an optional native sheet with the exact requested explanation, affected dilute-product names and Close. No acknowledgement state, plan mutation, persistence or refresh is attached to this button.
2. Replaced the structured registered-rate dropdown with a large scrollable SwiftUI selection sheet and native Compose bottom sheet. Rate/unit text leads in title2 bold / 22sp bold; crop/target, condition, restrictions, re-entry, withholding and available method wording wrap underneath. Exact duplicate text is removed within an entry only, never by merging registered-use IDs. Selected rates have a distinct border/tint/checkmark (iOS) or Selected label (Android). Original range/preset selection policy is retained; opening/dismissal makes no choice. Units, IDs, raw rates/uses and evidence are unchanged. iOS resigns first responder before presentation; Android clears focus/hides IME. Rate details are display-only projections, not a rewritten catalogue.
3. Planning mode displays **By Area | Only Full Tanks** through the shared title. Stored `full_tank` and all calculations are unchanged. Actual full-tank COUNT tiles still say Full Tanks: these count loads and are not the planning-mode label.
4. Both diagrams retain green vines/grey machines/dashed blue-cyan lines; triangles now sit at the vine-facing endpoints with a four-point gap from foliage. Single Row points left/right. Over-Row outer heads point inward toward their nearest vine and inner heads point outward toward the opposite faces of those same two rows. No geometry model changed.
5. Shared configuration title is **Single Row | Over-Row**, retaining `standard_pass`/`over_row_two_rows`, with the requested complete-row-equivalent explanation. Accessibility and native previews updated.

### Honest remaining blockers and server audit

The separate schema/workflow gate is real and still disables newly captured planning intent/resolution/explicit clearing. It is NOT a CF/permission gate and was not activated by a presentation request. The Carrier card shows that notice only when configuration is selected or Only Full Tanks is chosen, matching the production foliar planning-intent condition; default legacy By Area/unset-configuration paths no longer receive a contradictory disabled notice. Review only says Ready to save or start when calculation completeness AND existing operational admission permit it; otherwise Calculation complete — action unavailable plus the actual reason.

Still enforced: missing mandatory inputs, unresolved/invalid doses (including incompatible DiPel dimensions), explicit rate choice, nonfinite/sub-1/missing dilute CF, ambiguous rate basis, inconsistent tank/area/rate, equipment/area bounds, stale recipe confirmation, role/scope/session admission, durable-commit failure, blocked evidence and unverified HTTP409 receipts. No BLOCKED outbox is silently reset or relabelled as successful after this policy change. Prior interrupted Save for Later repair/live regional-input/physical-device/server operational acceptance gaps remain unrelated unfinished work.

Searched both platform production sources, all Supabase function source and SQL for permission/CF enforcement. No matching active permission-only Supabase function implementation was found; the SQL match is the historical UNAPPLIED `sql/review/spray_label_server_admission_acceptance.sql` proposal/harness. No SQL/Supabase files changed, query/migration was run or server deployment made. This is source audit, NOT a fresh deployed-definition/live-server acceptance claim. Historical proposed unknown-permission server denial is superseded by this WARNING-ONLY request and must not be installed as the current policy.

### Performance scope

Warning sheet state is contained in its subview/composable; expansion and dismissal do not mutate calculator inputs or invoke onChanged/save/load. Android reuses already remembered hydrated rate rows; iOS now caches derived offered rates against the complete Saved Chemical value and snapshots them into the sheet when opening. Removed the unused iOS grouped dropdown renderer. Sheets perform no database fetch or registered-use decode and no quantity calculation. Existing immutable-flow Android caching is retained. Existing broader iOS flow/resistance/history/persistence hotspots remain outside this display correction; no new startup/frame-rate claim or unrelated architecture change. Current synthetic Android timing probe: 5.756748ms, checksum540000; single-shot host variability, not a before/after measurement for these UI changes.

### Executed validation, with levels separated

- Initial narrow iOS advisory regression attempt returned **fetch failed / 0 assertion result**. Not a reproduced assertion failure. After implementation and new tests, seven-suite selection `SprayStartPresentationTests`, `SprayPlanningIntentTests`, `SpraySaveForLaterTests`, `CropSilRateRegressionTests`, `SprayRegisteredUseRateTests`, `SprayGuidedWorkflowParityTests`, `SprayVolumeDecisionTests`: **114 passed, 0 failed,138s**. Includes real-file CF2 recipe/inactive-Trip save and matching frozen-recipe Start Tank ADMISSION, not actual authenticated tracking/server start. The formerly incomplete corrected guided parity now executed within this successful requested selection.
- iOS `VineTrackUITests/SprayPresentationUITests`: **3 passed,0 failed,191s**. DEBUG-only/no-network synthetic shell uses the actual production warning/sheet/cards. Warning opens/exact affected names/Close/no auto-selection; rates preserve both ranges, long conditions, restrictions and original units with explicit selection; renamed controls/diagram semantics render. Screenshot attachments are requested in test results; the managed runner supplies no exported images/result bundle in this workspace, and the local log remains the old fetch failure. No screenshot was viewed or supplied as pixel evidence.
- Strengthened iOS rate-sheet selector, after adding active numeric keyboard and draft retention assertions: **1 passed,0 failed,67s**. Numeric keyboard was visible before open, absent over the sheet; closing leaves exact draft1253 and no selection, followed by explicit choice. This tests the presentation shell using production sheet, not an authenticated full calculator journey.
- Android host selection via `scripts/run-calculator-completion.py --launch`: **166 passed,0 failed/errors/skips**,14 current XML suites, BUILD SUCCESSFUL24s / `CALCULATOR_REGRESSION_EXIT=0`; XML2026-10-14T01:45:38–39Z. Includes24 planning,30 guided flow,25 parity,17 snapshot,9 volume,10 CropSil,14 registered rate,14 StartTank,8 mobile safety,6 ground,3 durable CREATE,4 normalizer,1 child-JVM,1 timing. Tests asserting obsolete permission-only denial now assert warning-only admission; invalid-factor and undeployed-planning replay refusal/evidence retention remain covered rather than deleted.
- Android native selection `SprayPlanningAndroidTest` + `ChemicalConditionPersistenceAndroidTest`: **10 passed,0 failed/skipped,22s**. New warning sheet open/details/dismiss, rate ranges/long text/distinct explicit selection/no auto-choice, CF2 UPDATE enqueue/Start Tank admission (no transport) plus existing real preferences/mock chemical flows. Separate strengthened configuration/card test after conditioning the preview-only notice: **1 passed,0 failed/skipped,14s**, initially unset By Area has no disabled notice; configured Only Full Tanks still truthfully has it. No physical handset/OS restart/live server claim.
- Final `runChecks(ios)` simulator and `runChecks(android-vinetrack)` both PASSED after the last source changes. Existing asset notices unchanged. No release/export/upload. Full source/whitespace review checks recorded below; test log daemon whitespace normalized without changing results.

### Changed files (relative to each app folder)

**iOS production:** `VineTrack/App/SprayCalculatorView.swift`; `App/SprayPlanningCardsView.swift`; `App/SprayEngine/{SprayPlanningIntent,SprayGuidedFlow,SprayPlanningAdmissionError,SprayRegisteredUseRates}.swift`; new `App/{SprayConcentrationWarningView,SprayLabelRateSelectionView}.swift`. **DEBUG-only:** `App/{SprayPlanningPreviewView,SprayPresentationValidationView}.swift`, guarded route in `VineTrackApp.swift`. **Tests:** `VineTrackTests/{SprayPlanningIntentTests,SprayStartPresentationTests}.swift`, `VineTrackUITests/SprayPresentationUITests.swift`.

**Android production:** `app/src/main/java/com/rork/vinetrack/data/spray/{SprayPlanningIntent,SprayGuidedFlow}.kt`; `data/chemical/SprayRegisteredUseRates.kt`; `ui/screens/SprayCalculatorScreen.kt`; `ui/components/SprayPlanningCards.kt`; new `ui/components/{SprayConcentrationWarning,SprayLabelRateSheet}.kt`. **DEBUG-only:** `app/src/debug/java/com/rork/vinetrack/ui/components/SprayPlanningPreview.kt`. **Tests:** `app/src/test/java/com/rork/vinetrack/data/SprayPlanningIntentTest.kt`, `app/src/androidTest/java/com/rork/vinetrack/data/SprayPlanningAndroidTest.kt`.

### Preview/screenshot delivery boundary

Updated native #Preview/@Preview fixtures contain actual new diagrams, Only Full Tanks and clickable WARNING. iOS DEBUG presentation fixture is entered only with `--keyboard-validation --spray-presentation-validation`; normal/release routing is unchanged. It provides native warning/rate details interaction and both configurations with synthetic data, not the full authenticated Review. Requested exported seven-view review screenshot deck, small-screen/dark-mode pixel inspection, physical handset and actual authenticated Review screenshots remain **NOT DELIVERED**. No generated mockup/login screenshot is substituted. Native UI test screenshot attachments are not exportable through this runner output; an approved authenticated renderer/device capture is still required.

## 2026-10-14 calculator continuation — historical implemented corrections, acceptance still incomplete

This update supersedes the historical test counts below for the described calculator selection only. No new release, SQL/Supabase mutation, historical-record rewrite, chemical label change or operational-planning activation.

### A. UI implementation

The existing eight steps, two inline cards, order, illustrations and progressive disclosure remain. Step 6's shared title now matches the approved `Canopy & Spray Volume` wording on both platforms. Android card internal spacing now matches iOS's 12-point spacing; decimal fields expose IME Done, which clears focus/hides the keyboard without invoking a save or changing the selected step. iOS global keyboard implementation is unchanged. Selected/unselected configuration illustrations and both Full Tank paths were exercised through production Compose cards, not an authenticated whole-calculator journey or pixel/dark-mode/small-screen audit.

### B. Configuration and units

At physical spacing 2.8 m: Standard width 2.8 m / Over-Row width 5.6 m. At 600 L/ha, controller travel 16.8 / 33.6 L/100 m; at 500 L/ha, 14 / 28. Existing controller boundary retains physical L/ha while re-expressing controller travel; no row-spacing or product-quantity equation changes. Both Full Tank examples remain in focused tests: 1500 L / 3 ha = 500 L/ha; 1500 L / 600 L/ha = 2.5 ha. Capacity, gross-selected-area bounds, target/calibration equivalence and no invented partial-block coverage assertions remain.

Corrections: Android carrier basis is now saveable alongside rate text; same-basis L/ha configuration changes leave raw text alone on both apps; true rate-basis/controller transitions refuse nonblank invalid/partial/zero entries rather than changing their meaning. Full Tank parsing now uses the existing regional decimal parser (comma decimal supported, incomplete/nonfinite input unresolved). iOS legacy carrier-display cache is keyed by regional volume/area/length/country so a stale local-unit display is not reused under another region. The field state is not a new calculator/configuration model.

Remaining MOBILE unit work: certify and, where necessary, finish live global regional-settings changes while Full Tank raw fields are populated, exact raw-text restoration after repeated controller-unit/configuration round trips, and complete canonical-versus-original-text retention for By Area custom output. Current tests prove conversions/serialized captured-unit provenance and reopen contracts, not all production-screen setters. Do not call these remaining issues environment-only or all unit transitions accepted.

### C. Chemical calculations and stricter Option C

Existing CF/concentration/product quantity equations unchanged: CF minimum 1, per-100 L uses the existing relationship, area products never receive CF. Crop Sil, explicit REVUS conditional selection and DiPel dimension-refusal suites remain. A new admission-only above-reference blocker prevents CF 1.00 from authorising a dilute-rate mix above its established reference; flow and available frozen physical-row evidence are checked independently of typed/preferred rate. Area-only products are not assigned dilute CF. No label authority or server permission is inferred. This client check is NOT full server/direct-write/old-client authority; frozen legacy rows lacking a trustworthy comparable reference and complete server enforcement remain separately unresolved. New planning gates remain closed.

### D. Persistence and reliability

Reproduced iOS edit failure with a real-file PersistenceStore failure injection: the old method returned true and published an edit despite disk refusal. `updateSprayRecord` now requires matching current vineyard/record scope, writes via `saveRecordsSliceOrThrow`, then publishes/calls dirty notification. Failed write retains old disk and memory, returns false, emits no dirty callback; retry is tested. No record is moved into the currently selected vineyard.

Reproduced three Android pending CREATE defects before correction: failed replacement deleted original evidence; BLOCKED/IN_PROGRESS payloads could be replaced/unblocked; edits minted a new operation and lost retry history. Added one durable coalescing mutation using the existing auth-first repository lock/order, retaining operation ID/client ID/creation/attempts and original vineyard. Corrupt/multiple/foreign-scope entries refuse, blocked/in-flight evidence is immutable. CREATE replay now claims the exact version and uses compare-and-remove/status/retry, so stale acknowledgements cannot remove/fail/publish over newer intent. HTTP409 remains blocked without reviewed receipt. No synchronous durable commit was replaced with asynchronous apply.

Existing delayed Start Tank and established-factual-recovery tests remain. Save for Later still writes recipe then inactive Trip, preserving same-screen exact-ID retry. Process-restorable repair of an interrupted recipe-only save is NOT implemented/accepted; this is remaining MOBILE reliability work, not merely a server prerequisite. No newly enabled operational save/start/replay or actual coverage writes.

### E. Performance

Measured synthetic Android workload: immutable guided inputs with 100 blocks/20 products, 300 iterations reading plan twice plus geometry, checksum 540000 throughout. BEFORE caching: **39.178884 ms** (standalone executed test). First AFTER: **7.460265 ms** in the 78-case run; later 165-case runs **2.700177 ms** and **1.060520 ms**. Single-shot host/JIT variation prevents a statistical startup/frame-rate claim. Mechanism: geometry and plan are now per-flow lazy values; Compose remembers flow by the full immutable guided-input/profile value, avoiding reconstruction for unrelated UI changes. No arithmetic/durability change. All subsequent snapshot/ground/volume/chemical tests pass on Android.

iOS source hotspots remain: `SprayCalculatorView.flow` constructs inputs/flow on repeated property reads; `guidedProductLines` repeatedly scans saved chemicals and registered rate evidence; `flow.plan`/geometry computed getters repeat; resistance check rebuilds events from all records during product rendering; local spray persistence remains main-thread full-slice JSON/disk. A Swift timing probe executed 1/0 before changes, but managed successful test output supplied no probe timing and the local log remained a previous invocation. NO fabricated iOS before/after number or unmeasured optimisation. Latest iOS test-host launch failure had no crash log; runtime CLI returned no logs. Cold startup, real recomposition/frame counts, resistance history and codec/SharedPreferences disk latency remain unprofiled. No unsafe background durability refactor.

### F. Executed testing and builds

- iOS focused planning/save/recovery/captured chemistry/regional/timing selection: **66 passed, 0 failed, 112s**. This preceded the later same-basis L/ha text fast path and fixture reconciliation. The new edit regression first executed **0/1**, then passed in the 66-case selection after production correction.
- Six documented iOS wider suites: fixture reconciliation changed unsupported synthetic `Kilograms` to supported `Kg` (no production alias/label rewrite), expected display `L` to actual ChemicalUnit raw `Litres`, integer division to fractional arithmetic, original directions versus expanded presets to explicit 2-original/3-derived/5-unique assertions, confirmed equipment/canopy/ground inputs, physical equivalent controller values and regional CF number formatting. Execution progressed **127/15**, then **141/1**. The last failure was exact snapshot comparison's `customTargets:nil` versus actual empty array; the expected full projection now includes `flow.inputs.customTargets`, retaining whole equality. Its corrected selection (GuidedWorkflowParity + Planning + SaveForLater) then **0 executed**, host launch/connection failure with no crash log. No unchanged retry/startup bypass; final corrected iOS parity is UNVERIFIED, not142/0. Other five wider suites were green in the 141/1 execution, not an unchanged baseline certification.
- iOS UI selection of three KeyboardInteractionUITests: **2 passed / 1 failed**. Actual Calculator numeric Done/drag/passive-tap/no-save test PASSED; generic passive-tap/scroll test PASSED. Generic native formatted-number sample FAILED (`25.75` expected, `2.575` observed). Kept assertion/production keyboard unchanged; chemical-editor/Step6 numeric-field UI not separately certified.
- Android replacement regressions first executed **0/3** (after one missing nullable-fixture-argument compilation correction); all3 now pass. Focused selection then **78/0**. Expanded selection first **164/1**: stale ground test required a row-rate field that explicit Android L/ha carrier does not store. Expected projection now explicitly requires absent foliar/controller/dilute fields, exact625L/ha/CF1 and full snapshot/ground metadata, not canopy leakage. Final **165 passed / 0 failed/errors/skips**, BUILD SUCCESSFUL24s, `CALCULATOR_REGRESSION_EXIT=0`, XML2026-10-14T00:59:48Z. Includes all30 GuidedFlow,25 GuidedWorkflowParity,6 ground-carrier,17 snapshot,9 volume,23 planning,14 registered rates,10 captured-chemical,14 StartTank,8 mobile-safety,3 replacement,4 normalizer,1 timing and1 child-JVM cases. Child JVM is not Android OS termination. Init/logs `.rork-tmp/calculator-completion.*`; launcher `scripts/run-calculator-completion.py`. Geometry/regional source names requested in init were absent; do NOT claim their separate suites were discovered.
- Final Android native selection `SprayPlanningAndroidTest` + `ChemicalConditionPersistenceAndroidTest`: **7 passed / 0 failed/skipped,19s**, after correcting only the test's invalid chain on Unit-returning `performImeAction`. Covers production-card IME Done/text retention, both configurations/Full Tank paths and scoped real preferences/mock chemical REST. Earlier7/0/16s preceded the new IME assertion.
- Final `runChecks(ios)` simulator and `runChecks(android-vinetrack)` release both PASSED after source changes. Existing nonblocking asset notices unchanged. No device-release/iOS archive validation or distribution.

### G. Remaining work — explicit categories

**Mobile implementation/validation:** live regional setting/raw canonical retention gaps above; interrupted Save for Later process recovery; generic formatted-number input defect classification/correction; final corrected iOS full-snapshot parity execution; iOS/cold-start/resistance/persistence measured profiling. Do not label these finished from 165 Android passes.

**Physical-device testing:** authenticated full eight-step calculator/review/chemical editor on iPhone/Android, keyboard/focus behavior on actual Step6 fields, dark mode/small screens/Dynamic Type, saved legacy edit/reopen, true offline OS kill/restart and account/vineyard isolation. Native card semantics and file/prefs recreation are supporting evidence only.

**Backend/server compliance:** reviewed trusted label/reference/currentness and Option C authority, staged storage contract, typed scoped receipt/idempotence and atomic direct/job/Trip/tank/inventory admission. New operational planning remains disabled. No SQL applied or production data changed.

**Release dependencies:** no release authorised; updated final-source candidates would need separate permission, complete mobile/device/server acceptance and build identity. Historical TestFlight168 does not contain this continuation.

## 1. Mobile safety corrections (historical 2026-10-13)

### A. iOS Save for Later

- The production Calculator now calls `MigratedDataStore.saveSprayForLater` through `SpraySaveForLaterCoordinator`. Validate record/Trip linkage, vineyard, inactive Trip and current recipe admission before writes. Durably write the Spray Record first, then durably write its inactive Trip. Publish each local collection only after its durable write returns.
- A rejected/failed/uncertain record write does not reach the Trip write or UI success. A failed Trip write retains the already-saved recipe but creates no in-memory placeholder. No active Trip, GPS/tank start or inventory adjustment occurs in Save for Later.
- The screen retains the original record/Trip pair on failure and retries the same IDs and frozen evidence, not a newly generated operation. Store retries accept only an identical existing same-ID object and do not append duplicates. A retained retry saves the original attempt, not any subsequently edited form values.
- `addSprayRecord` now returns false on actual durable write failure and does not publish an unsaved row. Legitimate legacy recipes without new planning fields remain saveable. New planning still refuses before either write.
- Five new tests: successful real-file legacy save and duplicate retry; explicit disk failure/zero publication; uncertain record acknowledgement with exact-ID retry; Trip-write failure and retry without duplicate recipe; disabled planning with zero writes.
- Limits: injected uncertain acknowledgement is a controlled coordinator test, not live server acknowledgement loss. Same-screen retry is proven; the retry pair itself is view state, not a new process-restorable transaction journal. A recipe saved before a failed Trip write remains durable evidence and must not be discarded; automated repair after killing that screen is not certified. No server transaction/rollback claim.

### B. Android CREATE HTTP409

- Removed arbitrary409 queue removal. Structured check/safety denial, revision/data/uniqueness conflict, and unverified response get distinct blocked review messages.
- Every409 remains pending/blocked with the original operation ID, record ID, exact payload, creation time and prior attempt count. Only status/error/update time change. Repeated replay of the blocked row performs no request, removes nothing and publishes no success.
- Even23505, a claimed `accepted:true` receipt, or the same record UUID is not verified duplicate success. There is deliberately NO duplicate-acknowledgement branch until the reviewed server receipt contract binds record, actor, vineyard, operation and accepted payload/revision. Normal successful insert responses retain the existing online repository contract; this work does not certify server receipt semantics.
- Five new production-replay tests cover bare409,23505,PT409, unreviewed claimed receipt and chemical-compliance409, each seeded with two prior attempts and exact evidence assertions. Transport is a controlled create callback with no network fallback.
- SQLSTATE23514 is conservatively treated as permanent validation denial even if not chemical-specific; `SPRAY_LABEL_` message classifications also block, including erroneous5xx mappings. No raw server body is displayed to the user.

### C. Generic new spray Trip starts

- Android generic `AppViewModel.startTrip` has no linked validated recipe argument; new `spraying`/`spray` calls now refuse before Trip ID creation, labour journal, transport, claim, GPS or success. Users must use the existing recipe/calculator routes, whose current planning gate remains closed.
- For ordinary non-spray starts, only network/IO failure or non-safety5xx is eligible for the existing local start. Auth, permanent4xx, structured safety denial, not-configured and unknown exceptions refuse. Labour capture moved out of the pre-request path; a server denial cannot leave a new labour entry. Fallback success now checks the actual claimed active Trip rather than unconditionally reporting true.
- iOS generic spray start now requires a scoped, non-template, uncompleted admitted recipe. The Calculator hands the complete existing frozen record into the tracking service. The service durably saves recipe plus inactive Trip before activating its Trip and starting tracking. Missing/blocked recipe refuses before operational effects. Non-spray start behavior and established factual recovery paths are untouched.
- Four iOS admission tests cover generic missing recipe, unaffected non-spray, eligible legacy/wrong-vineyard recipe, disabled planning/template refusal. Three Android failure-policy tests cover permanent denial, transient spray-versus-non-spray behavior and unknown/auth/data errors.
- Limits: generic service/ViewModel wiring is source-reviewed; the new failure-policy cases are host tests, not authenticated end-to-end server denial journeys. The prepared/established recovery tests remain in the focused selections. These checks do not grant server authority to a legacy client-eligible recipe.

No calculator quantity/CF/unit conversion equation, original rate direction, illustration or historical snapshot was changed. No before-fix execution of these three new regressions is claimed; this turn corrected the previously documented source risks and executed the new assertions after correction.

## 2. Executed regression results

| Selection | Latest observed result | Meaning |
|---|---|---|
| iOS original focused64 plus `SpraySaveForLaterTests`5 and `SprayTripStartAdmissionTests`4 | **73 passed,0 failed;158s** | Includes all original editing/PDF/planning/coordinator checks and new save/admission cases |
| iOS six wider classification suites | **102 passed,40 failed;142 executed** | Exactly33 wider plus7 separate unit/scoping cases. NOT whole-app green or unchanged-baseline proof |
| Android original focused62 plus `SprayMobileSafetyTest`8 | **70 passed,0 failed/errors/skips;3m52s** | Production replay retention and start-failure classification included; XML timestamps11:58:02Z |
| Android native `SprayPlanningAndroidTest` + `ChemicalConditionPersistenceAndroidTest` | **7 passed,0 failed,0 skipped;15s** | Fresh single invocation: all five planning cases and two chemical persistence cases |
| iOS final `runChecks` and internal candidate | Simulator passed; signed3.1.7(168) built/uploaded | Apple processing; internal availability not yet verified |
| Android final `runChecks` | Passed release APK build | Not a Play publication |

Host selection: `.rork-tmp/spray-device-safety.init.gradle`; logs `.rork-tmp/spray-device-safety.{stdout,stderr}.log`. iOS classification diagnostics: managed `/tmp/rork-swift-test-ios.log` (local reader path `../../../../tmp/rork-swift-test-ios.log`), ending `40 of142 tests failed`; reported selectors/first assertions match the tool results. Do not interpret shifted Swift Testing `isClose` argument labels in diagnostic rendering as new arithmetic observations; compare their source call.

The two iOS selections are disjoint:175 passes/40 failures across215 executed cases. Focused73 remains the relevant new safety selection; aggregation does not erase the40 failures. Earlier chemical17/163 and Android chemical28 totals are historical, not silently added to this turn's totals. Prior Android wider15 failures retain historical executed baseline comparison, not a new all-suite pass.

## 3. Exact unresolved iOS classification

All selectors below are `VineTrackTests/<Suite>/<method>()`. The six original suite files are byte/source-unchanged against `d0d846cbb3adaa5acf49f32cdbf480a9953ad21c` (empty Git diff). This turn's current-source execution identifies actual first failures; it cannot establish their runtime result on that earlier source. **No row is certified runtime-baseline/pre-existing; no new regression is verified from these40 alone.** No correct safety assertion was weakened, no legacy unit alias/conversion introduced and no old test edited.

Classification: **D** = source-backed fixture/expectation discrepancy; **R** = contract reconciliation still required. Session relevance: **UI check** = include in matrix, not permission to execute; **fixture-only** = does not by itself block synthetic UI checks; **restrict data** = no operational use/unreviewed units. These are bounded device-session decisions, not release waivers.

### CalculationParity —2

| Exact Suite/method | Executed failing assertion / observation | Class | Next session / correction needed |
|---|---|---|---|
| `SprayCalculationParityTests/derivedLitresPerHectareNeedsUniformSpacing` | `totalLitres == 28_125 /100 *10`:2812.5 versus integer2810 | D: integer division contradicts fractional geometry | UI check mixed-spacing refusal. Correct expected arithmetic only in a separately approved fixture correction; never truncate engine |
| `SprayCalculationParityTests/switchingModesDoesNotReinterpretValues` | `perHa.appliedLitresPer100Metres == nil`:16 | R: derived physical-row projection versus old absence expectation | UI check entered basis versus derived controller output; agree field contract before assertion correction |

### GuidedWorkflowParity —14

The foliar helper omits canopy/equipment confirmation. Banded helper omits ground target/equipment confirmation and enters ground L/100m although current ground route uses L/ha. Completion/snapshot assertions must not bypass those real prerequisites.

| Exact Suite/method | Executed failing assertion / observation | Class | Next session / correction needed |
|---|---|---|---|
| `SprayGuidedWorkflowParityTests/singleTargetPersists` | `#require(flow.snapshot)`:nil | D: incomplete foliar helper | Fixture-only; supply explicit confirmations, retain frozen-target round trip |
| `SprayGuidedWorkflowParityTests/multipleTargetsAreOrdered` | `a.snapshot?.targets == expected`:nil versus ordered powdery/botrytis | D: incomplete foliar helper | Fixture-only; complete fixture, preserve ordering assertion |
| `SprayGuidedWorkflowParityTests/editingTargetsReplaces` | `before.snapshot?.targets == [.powderyMildew]`:nil | D: incomplete foliar helper | Fixture-only; complete before/after prerequisites, preserve replacement semantics |
| `SprayGuidedWorkflowParityTests/headTargetsPersist` | require head-specific flow snapshot:nil | D: incomplete foliar helper | UI check head selection; complete each fixture, preserve snapshots |
| `SprayGuidedWorkflowParityTests/storedRowLengthOnly` | `effectiveCarrierBasis == .litresPer100Metres`:perHectare | R/D: row policy applied to ground operation | UI check operation-specific basis; reconcile ground/foliar contract, not dosing equation |
| `SprayGuidedWorkflowParityTests/swnzLocksToRowLength` | same expected row-length basis:perHectare | R/D: SWNZ ground/foliar policy mismatch | UI check regional policy; use intended operation fixture, do not relax compliance |
| `SprayGuidedWorkflowParityTests/mixedBasisQuantities` | `flow.isComplete`:false | D: ground/equipment/carrier prerequisites absent | Restrict to preview; complete ground fixture before claiming quantity persistence |
| `SprayGuidedWorkflowParityTests/measurementsSurviveReload` | require banded flow snapshot:nil | D: incomplete ground helper | UI check frozen reload; complete fixture, preserve all operands |
| `SprayGuidedWorkflowParityTests/per100LNeverAsked` | Products blocker nil expected:unresolvedProducts Adjuvant | D: no valid ground carrier operand; basis not itself ambiguous | Restrict to preview; supply ground target/carrier rather than bypass product blocker |
| `SprayGuidedWorkflowParityTests/wholeBlockNeverAsked` | `flow.isComplete`:false | D: incomplete foliar helper | Fixture-only; complete confirmations, retain no extra basis-question rule |
| `SprayGuidedWorkflowParityTests/carrierIsolation` | carrier difference from6250 is6250 (actual0) | D: obsolete ground carrier input | UI check carrier-only isolation; supply supported operation/carrier inputs |
| `SprayGuidedWorkflowParityTests/blockChangeRecalculatesEverything` | difference from12500 is12500 (actual0) | D: obsolete ground carrier input | UI check block recalculation; retain independent gross/treated/product assertions |
| `SprayGuidedWorkflowParityTests/reviewEqualsPersistedRecord` | require flow.snapshot:nil | D: incomplete ground helper | Restrict persistence claim; complete fixture then retain exact Review/record parity |
| `SprayGuidedWorkflowParityTests/decisionOrderIsFixed` | noCarrier.activeStep carrier expected:target | D: preceding ground target unanswered | Fixture-only; isolate missing carrier by completing earlier steps, preserve gating |

### RegisteredUseRate —2

| Exact Suite/method | Executed failing assertion / observation | Class | Next session / correction needed |
|---|---|---|---|
| `SprayRegisteredUseRateTests/custodiaForteExposesBothLabelRates` | count2 expected:5 | D: original two directions expand band/presets | UI check original versus derived choices; assert original directions and expanded set independently |
| `SprayRegisteredUseRateTests/custodiaForteRatesHaveStableDistinctIdentities` | unique IDs2 expected:5 | D: same direction/entry conflation | UI check deliberate choice/reload identity; retain uniqueness/stability for actual expanded set |

### VolumeDecision —15

The unchanged helper says VSP Medium/High20L/100m, but that same test file's table assertions and default settings specify40. Many reported expected totals/factors are consequently half the actual reference. Its flow helper additionally omits target/head/growth/equipment/canopy confirmation. Those prerequisites must remain enforced.

| Exact Suite/method | Executed failing assertion / observation | Class | Next session / correction needed |
|---|---|---|---|
| `SprayVolumeDecisionTests/recommendedConversion` | recommendedPer100m20 expected:40 | D: contradictory canopy helper | UI check canopy reference; choose actual20 canopy or reconcile expected40 |
| `SprayVolumeDecisionTests/useRecommended` | actualL/ha714.285714 expected:1428.57142857 | D: same reference mismatch | UI check recommendation and CF1; correct fixture, not conversion |
| `SprayVolumeDecisionTests/customSprayerOutput` | CF1.190476 expected:2.38095238 | D: same reference mismatch | UI check custom600 retained; do not mistake CF display for authority |
| `SprayVolumeDecisionTests/actualAboveRecommended` | CF1 expected:1.7857142857 | D:800 is below actual1428.57 recommendation | UI check minimumCF1 with genuinely above-reference input |
| `SprayVolumeDecisionTests/totalWater` | recommended total350 expected:700 | D: same reference mismatch | UI check physical litres; align canopy fixture and preserve custom294 |
| `SprayVolumeDecisionTests/recommendedTracksCanopy` | before714.285714 expected:1428.57142857 | D: same starting reference mismatch | UI check canopy changes; correct initial expectation only after reconciliation |
| `SprayVolumeDecisionTests/customSurvivesCanopyChange` | beforeCF1.190476 expected:2.38095238 | D: same reference mismatch | UI check custom600 preservation; retain subsequent recalculation |
| `SprayVolumeDecisionTests/per100LUsesConcentrationFactor` | dilute quantity525 expected:1050 | D: reference20 versus40 | Restrict operational use; retain dilute-equivalent dose invariant with consistent fixture |
| `SprayVolumeDecisionTests/mixedBases` | per100L quantity525 expected:1050 | D: reference mismatch | UI check per-ha dose never inherits CF; preserve independent bases |
| `SprayVolumeDecisionTests/calculationReferenceMatchesEngine` | reference20.00 expected:40.00L/100m | D: reference mismatch | UI check workings agree with selected canopy; reconcile fixture |
| `SprayVolumeDecisionTests/hectareFiguresAreDerivedNotLookedUp` | at2.8m714.285714 expected:1428.57142857 | D: reference mismatch | UI check spacing-derived conversion; do not replace equation with lookup |
| `SprayVolumeDecisionTests/customRateResolvesStepSix` | CF1.190476 expected:2.38095238 | D: reference mismatch plus missing preceding steps | UI check carrier completion; complete prerequisites and consistent reference |
| `SprayVolumeDecisionTests/completionDoesNotMoveTheOperator` | Products unlocked expected:false | D: earlier prerequisites missing | UI check focus versus completion; do not remove gates |
| `SprayVolumeDecisionTests/bothBasesAgree` | CF equality:2.38095238 versus1 | D: both bases given numeric600, not equivalent physical quantities | Safety-relevant UI check600L/ha versus16.8L/100m at2.8m; correct equivalent-input fixture, never equate600 in unlike units |
| `SprayVolumeDecisionTests/stepNamingAndOrder` | title Canopy & Spray Volume expected:Carrier / Spray Volume | D/R: older title contract | Fixture-only title reconciliation; retain ordering prerequisites |

### Chemical unit/scoping —7 separate cases

Actual saved `ChemicalUnit.kilograms` raw spelling is `Kg`. The mixed-crop fixture supplies `Kilograms`; unchanged backend mapping defaults unknown spelling to litres. This is a **safety-relevant legacy decoding concern if such data is used**, not authority to invent a conversion or silently repair production chemicals. This session must use captured/current reviewed fixtures; DiPel remains explicitly non-calculable. Audit arbitrary unknown saved units separately before release.

| Exact Suite/method | Executed failing assertion / observation | Class | Next session / correction needed |
|---|---|---|---|
| `SprayLegacyRateUnitBoundaryTests/liquidRateCrossesTheBoundaryWhenSeedingARecordLine` | unitLabel L expected:Litres | D: display spelling contract | UI check label/magnitude; reconcile display spelling without weakening base-unit checks |
| `SprayLegacyRateUnitBoundaryTests/kilogramLineAdoptsLitreProductUnit` | unitLabel L expected:Litres | D: same display spelling | UI check correct product dimension; no dose borrowing/conversion change |
| `SprayVineyardRateScopingTests/vineyardPickerKeepsGrapevineRatesAndDropsOthers` | vineyard count1 expected:0 | D: Kilograms fixture decodes litres; mass choices refused | Restrict data; establish fixture versus supported stored-unit contract, preserve crop exclusion |
| `SprayVineyardRateScopingTests/defaultSelectionNeverSeedsANonVineyardRate` | required vineyard default:nil | D: same unit mismatch | Restrict data; preserve no other-crop default, review actual supported unit spelling |
| `SprayVineyardRateScopingTests/kilogramLabelRateConvertsToBaseGrams` | baseValue2.2kg2200 expected:nil | D: intended solid decoded liquid | Restrict data; correct evidence/fixture contract separately, no guessed density |
| `SprayVineyardRateScopingTests/mismatchedDimensionIsRefusedNotGuessed` | baseValue2.2L nil expected:2200 | D with legacy decoding risk: fixture labelled solid is actually decoded liquid | Restrict data; retain correct dimension-refusal assertion. Unknown-unit default needs separate evidence review before broader operation |
| `SprayVineyardRateScopingTests/kilogramQuantityRoundTripsWithoutInflating` | require baseValue2.2kg:nil | D: same unit mismatch | Restrict data; retain exact gram/display magnitude safeguards, no alias silently introduced |

No unresolved NEW safety regression was established by this classification. It does not certify that all old-client unit paths are safe, nor that later assertions hidden behind first failures pass.

## 4. Internal build register and installation

Source baseline observed at start: `3eb19c5126b9518120c4d489a99b8f007547ad1f`. Tested source is that baseline plus the current mobile working-tree changes/new files, not the unchanged commit alone. Rork records revisions automatically; no manual commit/push. Both app checks passed after final source changes. Android APK manifest/signature were independently checked with aapt/apksigner. `adb devices` reports no attached handset. Apple authentication was restored during this turn; the existing managed flow successfully built/uploaded signed iOS168. Exact register and Apple-processing limitations follow.

| Platform | Version/build and identity | Installation / state |
|---|---|---|
| iOS | **Signed candidate3.1.7(168)**; submission `c3d2577e-ebce-49ee-84d5-40fe0ded4511`; Apple upload `f5cca09c-e0ce-46b3-93a1-c3fa77e4325f` | Built/uploaded successfully; Apple upload PROCESSING, not yet visible as a VALID build after bounded50s wait. Existing Internal Testing group only; no new group/testers/public links created |
| Android | Verified APK3.1.7/code10/package `com.rork.vinetrack`; SHA256 `fa847e881823c833a18f419397ad450416cd22c7cf95a1a6518db5f1eb6113fc` | Existing privately transferred release APK arrangement. Use dedicated approved synthetic handset; verify APK/signature and installed package compatibility before in-place update. No Play upload/track mutation |

Artifact location: `android-vinetrack/app/build/outputs/apk/release/app-release.apk`. Verified signing certificate SHA256 `241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3`, matching the prior documented private-APK certificate. Verified minAPI24/targetAPI36; arm64-v8a/armeabi-v7a/x86/x86_64. No verified external download URL was returned; the build/project owner must transfer these exact bytes privately. Do not substitute an older APK with the same3.1.7/code10 label.

Source identity: observed HEAD `3eb19c5126b9518120c4d489a99b8f007547ad1f` plus mobile delta SHA256 `210aeda4089996010464d25930262ab9a8c70381489da28e3c6ec2481d7da354` (`git diff --binary <HEAD> -- ios android-vinetrack`, including managed-staged new files). This identifies the tested working tree, not an immutable server archive attestation. Both platform checks/test selections used these reviewed mobile changes; iOS signing/upload must use this same frozen source, not a later unreviewed tree. No app source changed after final tests/checks. No SQL/Supabase delta against HEAD. Final working-tree diff check and scoped staged app/report/plan checks passed; the full staged-index check still contained one already-normalized Gradle-log daemon-line whitespace addition (managed index lag), not an app source error. Source delta and APK hashes remained unchanged.

iOS distribution evidence: initial setup returned session_expired; `connectAppleDeveloper` completed successfully and subsequent setup wasready. Existing distribution certificate ready; ensureApp returned existing app (`created:false`); syncCapabilities changed nothing. `submitBuild` returned successful signed build/upload168; publishing status confirms complete/submit and `archiveSource:supplied-snapshot`, Xcode27.1. Apple independently reports the exact3.1.7/168/IOS upload PROCESSING, uploaded2026-10-13T12:30:56Z. Two bounded50s exact-number waits each exited7 pending/discovery, not failure or availability. No build retry was performed. No IPA/archive/dSYM download or immutable archive-source hash was exposed; source-register mapping is recorded, not cryptographic server attestation.

Existing Internal Testing group `1a8d95a6-44ec-47ac-8754-47a0a283582e` was read before upload and retains `isInternalGroup:true`/`hasAccessToAllBuilds:true`; no audience mutation. Verify168 becomes VALID, unexpired and internally available before handing it to testers. Resume status with `asc builds wait --app 6761143377 --build-number 168 --version 3.1.7 --platform IOS --fail-on-invalid --timeout 50s --report-pending`; then read exact build beta details/group relationship. Do not start another build merely because Apple processing is pending.

For iPhone: install **3.1.7(168)** through the existing TestFlight/Internal Testing invitation only after availability is verified. Do not substitute167 or source139. Keep automatic updates off; install exact candidate through existing invitation/Previous Builds while idle. Do not delete/reinstall a populated/customer app to make installation succeed.

For Android: transfer exact final APK privately using the existing project/build owner channel; verify receiving SHA256 and certificate. Confirm exact target handset/user and whether signature-compatible update is authorised. Install from trusted Files/ADB using the tester's own laptop; revoke temporary unknown-source permission afterward. No downgrade, data clear, package-ID change or customer installation overwrite. Reused code10 is not proof of forward data compatibility.

Prerequisites: existing approved synthetic accounts A/B (no credentials in report), synthetic vineyard membership and required operational role/entitlement, synthetic blocks with2.8m spacing and >=3ha,1500L equipment, valid canopy confirmations, captured chemical fixtures and reviewed unit spellings. Existing approved authentication/reference reads may hydrate those accounts; no production chemical edits or server fixture writes are performed here. Normal app builds retain their existing backend configuration, not a sandbox clone. Stop any workflow outside UI/local/blocked-state scope.

Feature state: all new planning-intent/resolution/explicit-clear operational save/start/enqueue/replay paths remain disabled on both platforms. Concentrate authority remains unverified; DiPel calculation is refused. Input-only preview/template evidence is not execution permission. Existing factual recovery is separate from fresh execution; FIELD_STORAGE_ISOLATION_ACTIVATED staysfalse on Android.

## 5. Physical-device acceptance matrix

All handset result columns intentionally start **PENDING**. Host/native-card pass is supporting evidence, not a handset pass. Record model/OS, candidate binary ID/hash, test aliases, units/country, time, network state, entered text and actual result separately on both phones. Use synthetic data only; stop if preview planned area is written as actual coverage or any blocked action starts tracking/tank/inventory.

| ID | Scenario and exact acceptance | iPhone | Android | Session boundary |
|---|---|---|---|---|
| S1 | Standard Pass correct left/right front-view sprayer; Over-Row two complete rows | PENDING | PENDING | Visual/UI only |
| S2 | Switch configurations; physical600L/ha unchanged at2.8m; travel16.8 Standard/33.6 Over-Row | PENDING | PENDING | UI calculations |
| F1 |1500L/3ha =500L/ha | PENDING | PENDING | Preview only |
| F2 |1500L/600L/ha =2.5ha | PENDING | PENDING | Preview only |
| F3 |500L/ha at2.8m ->14 Standard/28 Over-Row | PENDING | PENDING | UI calculations |
| F4 | Target-area/calibrated modes preserve equivalent physical quantities; retain active/inactive typing | PENDING | PENDING | Preview/local inputs |
| F5 | Change volume/area/controller units; same physical water and chemical dose; revert retains original captured evidence where supported | PENDING | PENDING | No chemical edits |
| F6 | Planned hectares clearly separate from actual sprayed Trip coverage; no route/coverage allocation invented | PENDING | PENDING | Inspect UI/history only |
| C1 | REVUS separate40/60mL/100L; read full conditions, choose each explicitly | PENDING | PENDING | Captured fixtures/reference reads |
| C2 | REVUS basis-only tap leaves ambiguous direction unselected; no first-rate default | PENDING | PENDING | Picker only |
| C3 | Crop Sil3–5L/ha and500–1000mL/100L retain original directions/high-water condition | PENDING | PENDING | Deliberate rate choice |
| C4 | Crop Sil unresolved active-concentration wording displays review warning, valid application directions still selectable | PENDING | PENDING | No concentration inference |
| C5 | DiPel original three mass directions visible with stored-Litres mismatch warning; cannot calculate | PENDING | PENDING | Refusal expected; no production correction |
| L1 | Local draft navigation/back/reopen retains exact fields; if no durable Calculator draft path is exposed, record NOT SUPPORTED/BLOCKED rather than seeding executable records | PENDING | PENDING | Do not bypass write gate |
| L2 | Relaunch same account retains eligible local draft/pending payload/raw units/rate evidence | PENDING | PENDING | Actual OS session evidence required |
| L3 | Offline force-stop/OS termination; retained eligible pending IDs/payload/creation/retry evidence; no new operational execution | PENDING | PENDING | Android force-stop / iOS termination, not screen recreation |
| L4 | Same-account reopening retains exact planning/chemical snapshots despite current catalogue/unit setting changes | PENDING | PENDING | Existing approved synthetic fixtures |
| L5 | Account B cannot access A cached private records or adopt A unfinished operation; refusal to sign out over retained work is a valid safety result | PENDING | PENDING | Never delete retained A work to force B login |
| L6 | Rejected local planning save/start shows actionable blocker, no success/Trip/tank/inventory; original pending evidence unchanged | PENDING | PENDING | No server rejection claimed |
| L7 | Changed/missing/blocked current recipe prevents prepared Start Tank recovery; retains journal and actual/Trip IDs | PENDING | PENDING | Preapproved synthetic journal fixture only |
| L8 | Previously durable actual/established session recovers factually with stable IDs/route; no duplicate marker/actual | PENDING | PENDING | Existing factual fixture, not new permission |
| L9 | Legacy iOS Save for Later controlled local failure/retry preserves original save and creates no orphan Trip/false success | PENDING | N/A | Only approved synthetic legacy record; no new planning |
| L10 | Generic new spray start refused; non-spray tracking/network fallback unchanged where eligible | PENDING | PENDING | Approved synthetic tracking only |

No hidden debug toggle/instrumentation harness is supplied as an operational gate bypass. If a pending/journal/draft fixture cannot be seeded through an already-approved local test path, that handset case is BLOCKED awaiting fixture access, not passed from host tests. Do not activate new server planning to create it.

## 6. Remaining blockers for this controlled session

1. iOS candidate168 has built/uploaded, but Apple processing/discovery and exact internal TestFlight availability remain pending. Signing reauthentication is resolved. Do not install old167 as the corrected candidate.
2. Android final APK acquisition/transfer and signature-compatible approved handset target must be confirmed; no connected phone is installed by this turn.
3. Existing approved accounts A/B, synthetic vineyard/role/entitlement and approved local pending/journal fixtures must be supplied by the test owner. No new account or paid environment provisioned.
4. Actual OS restart, authenticated whole-calculator navigation and long-condition visual checks remain pending. Local/repository recreation and native cards are not substitutes.
5. Use only reviewed/captured synthetic unit evidence. Unknown saved-unit default behavior is unresolved legacy safety work; DiPel remains blocked. Stop any unexpected dimensional calculation.
6. Save-for-Later same-screen retry is tested, not process-restorable transaction repair after an interrupted recipe-only save. Classify that separate case honestly; no new operational planning is needed for UI checks.

Once installation/fixture prerequisites are met, controlled UI/local-safe-blocked testing can proceed. **Neither handset installation is claimed; Android APK is prepared and iOS168 is uploaded pending Apple/internal availability.**

## 7. Separate backend-dependent release blockers — NOT handset PASS

| Backend-dependent case | Status / exact prerequisite |
|---|---|
| Full Tank/Over-Row online record/job save/start and SQLv2 read/edit/clear | BLOCKED; backend-owned reviewed contract/deployment and explicit future mobile activation approval |
| Server chemical authority/reference/currentness and typed product/tank denial | BLOCKED; validated actual PostgREST/RPC examples; server-owned reviewed evidence/reference, not client CF/catalogue status |
| Verified duplicate CREATE acknowledgement | BLOCKED; exact actor/vineyard/record/operation/accepted payload/revision receipt, including legacy pending provenance; no409 treated as approval |
| Acknowledgement-loss retry/idempotent replay | BLOCKED; approved connected server and receipts; retain pending evidence until verified acceptance; synthetic callback is not server replay |
| Transactional Trip/tank/claim/inventory/labour/events enforcement | BLOCKED; atomically reject before effects on every direct/old-client/generic/saved-job/tank boundary |
| Revoked/changed recipe concurrency and already-established factual policy | BLOCKED; reviewed server locking/revision/recovery contract with zero new rejected effects |
| Historical completed/manual protections and cross-account/RLS lifecycle | BLOCKED; actor-scoped backend acceptance; handset cache checks alone do not establish server enforcement |

Do not apply SQL, edit Crop Sil/REVUS/DiPel production records, enable new planning or submit public App Store/Play review/release. Successful signing/upload/internal artifact delivery does not approve any of those actions.

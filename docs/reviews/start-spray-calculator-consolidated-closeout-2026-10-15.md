# Consolidated Start Spray / Spray Calculator closeout — 15 October 2026

## Outcome

**Partial closeout; not release-ready.** Android numeric-entry defects are corrected and exercised through the actual production Compose chemical card/callbacks. Approved Start Spray controls and new planning components are retained. Both builds pass. The full iOS SwiftUI alert keyboard journey still fails; legacy Save for Later has no complete process-restorable startup recovery. These are Rork-owned remaining work, not requests for backend access.

## 1. Source authority and five approved improvements

Initial HEAD and final visible HEAD: `1b0b1e211fd8fa0b88046eec2d107cb7c3d26ec5`. Initial working tree/index were clean. Requested commit `e02a3735ec79801b99089dcf6fa986f67e33567d` exists but is not an ancestor in this checkout. A direct iOS/Android tree comparison found only the generated `ios/VineTrack/Config.swift` absent at HEAD. Other protected native source, including newer planning journals and Review, matches. No reset, cherry-pick or replacement of that work was performed; no generated configuration/secrets were copied from the other commit.

All five approved UI decisions remain:

| Decision | Evidence / difference |
|---|---|
| Single Row / Over-Row | Existing Step 6 controls and stored identifiers unchanged. Native Android planning control tests pass. iOS Step 6 production UI test passes. |
| Green vines, grey sprayer, cyan/blue vine-facing arrowheads | Illustration source unchanged. Android semantics verified by existing UI test; no pixel/physical-screen acceptance claimed. |
| By Area / Only Full Tanks | Existing labels, Target area / Calibrated rate fields and separate Full Tanks load counts retained. |
| Numeric-first label-rate sheet | Large bold rate, readable supporting evidence retained. No new picker/wizard. Distinct-condition identity protections strengthened as below. |
| Optional orange WARNING | Existing optional sheet and warning-only permission policy unchanged. Android opens/closes sheet without modifying plan; unverified CF 2.00 admission passes without new planning. Calculation/unit/input/CF/ambiguity and independent operational gates remain. |

### Narrow label-choice safety corrections

Source review demonstrated that iOS `selectBasis` used the first selectable matching row, whereas Android requires a unique structured condition. iOS now uses its existing ambiguity-aware default-selection resolver, constrained to the requested basis, and clears an old manual dose when changing to an unresolved condition. It does not choose a competing condition by order.

Generated selection IDs could collapse otherwise equal numeric rows under different restrictions/conditions; generated preset IDs did not retain the parent selection identity. Both native projections now include direction/condition/restriction/withholding/re-entry context in generated fallback IDs and parent identity in preset IDs. Android supplied server rate IDs remain unchanged; original registered-use/rate evidence is not rewritten. Reordering identical-number distinct-restriction fixtures retains eight choices (two bands plus their six presets). These are local selection projection changes, not catalogue writes or historical conversion.

Range/preset policy is intentionally not made identical: iOS shows a band with available points as a nonselectable reference and asks for a point; Android permits selecting the unresolved band followed by manual entry, or an explicit point. Both require an explicit valid dose. Neither selects an arithmetic preset automatically. Existing range/preset and Crop Sil tests plus the new collision regressions exercise this. No automatic rate inferred from being first.

## 2. Android numeric-rate parity

Production file: `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt`.

Reproduced in actual `CalcChemicalLineCard` with its actual state callbacks and effective-rate resolver:
- `25,75` did not survive the digit/dot filter as entered.
- Invalid nonblank override drafts resolved through the recommended-rate fallback.
- The editor did not declare a Done IME action; the initial test also exposed this separately.

Corrections:
- Preserve original editor text without stripping commas, letters, negative signs or malformed separators into another valid dose.
- Use the existing supported regional parser; reject nonpositive/nonfinite values and incomplete trailing decimal separators for chemical-rate commitment.
- A nonblank unresolved draft returns NaN, never an earlier/recommended/operational rate. It remains visible with rejection guidance.
- Empty/blank reset retains the existing recommended/default policy; unresolved bands stay unresolved.
- Done only clears focus/hides the keyboard. No calculation, save or selection callback is introduced.
- Manual-dose provenance uses the same parser, so comma decimals are not misclassified as defaults.
- The older nonguided calculation branch now rejects any unresolved chemical line instead of silently filtering it out of an otherwise executable mix. Engine equations are unchanged.

New instrumentation `SprayChemicalEditorAndroidTest`: dot/comma pairs 25.75, 0.75, 1250.5; invalid/incomplete drafts; Done/re-focus/card reconstruction; explicit preset identity; basis changes; empty reset and operational-source fallback rejection. It mounts the production card, not a replacement editor or authenticated full-screen journey. Reconstruction here is card/state recreation, **not OS-process death**.

## 3. iOS alert keyboard — unresolved

Original focus-transfer and alert assertions retained. Added a keyboard-hidden assertion after alert Done and a retained accessibility-hierarchy attachment for a missing accessory. A trial query across all accessibility element types did not resolve the failure and was reverted to the original Button query.

Full journey results:
- Initial button-query run: **0 passed / 1 failed**.
- General accessibility-query diagnostic run: **0 passed / 1 failed**.
- Combined diagnostic selection: **2 chemical/regional UI passes / 1 keyboard failure**.
- Exact failure: `Failed to no matches found for first query match sequence: Descendants matching type Any -> Elements matching predicate '"keyboard.dismiss" IN identifiers', given input App element` (the initial run reports Button instead of Any).

A new native UIKit alert diagnostic in `KeyboardSceneCoordinatorTests` proves that a real UIAlertController field receives a visible app-owned accessory; tapping it resigns the field, retains its draft and leaves the alert presented. It passed individually and within the wider unit selection. This does **not** prove SwiftUI alert accessibility publication or a stable XCTest tap target. A query-type-only fix was insufficient. Whether the failing SwiftUI alert loses the actual accessory or only its accessibility publication is still unresolved; it is not honestly classified as a test-only lookup issue.

Production keyboard coordinator/accessory and successful text-to-number transfer fix were **not changed speculatively**. The full alert acceptance criterion remains a release blocker. No confirmed/cancelled/saved draft is accepted as keyboard-dismissal success.

## 4. Regression evidence — latest selections, not summed

| Surface | Result | Limits |
|---|---|---|
| Android host calculator selection | **188 passed / 0 failures / 0 errors / 0 skipped**, 15 suites; BUILD SUCCESSFUL in 2m27s | Existing runner; production model/state tests, not device acceptance. Includes new equal-numeric distinct-direction regression. |
| Android instrumentation | **11 passed / 0 failed / 0 skipped**, 46s | New 3 chemical-editor tests + existing 8 planning UI/persistence tests; isolated synthetic components, no live services. Earlier overlapping 11-pass run not added. |
| iOS wider focused unit selection | **95 passed / 6 failed**; skip metric not exposed | Planning intent/draft/journal, Crop Sil, legacy Save for Later, keyboard coordinator, canopy/rate-preset suites. New direction and native-alert diagnostics pass; six old canopy assertions/fixtures fail. |
| iOS existing production chemical-card and regional Step 6 UI tests | **2 passed / 0 failed**, 127s, after final shared-screen changes | Exact raw drafts, invalid previous-dose rejection, reconstruction and canonical regional/controller invariants. Synthetic app fixture using production UI; not physical handset. |
| iOS full focus-transfer + alert UI test | **Failed**, as detailed above | Never represented by only its successful first portion. |
| iOS final runChecks | **Passed**, simulator build | Not signed handset IPA or App Store release. |
| Android final runChecks | **Passed**, release APK | No upload, tester change or release. |

Six iOS wider-suite failures (tests left intact, no relaxed expectations):
1. `foliarRequiresCanopyConfirmation`: expected “Select canopy size and density”; current title is “Select canopy type, size and density”.
2. `canopyStepPrecedesProducts`: expected “Canopy & Carrier”; current title is “Canopy & Spray Volume”.
3. `selectionUsesTheExistingTable`: an untyped canopy returns 0 versus old expected 75.
4. `touchingAPickerConfirms`: size/density alone no longer confirms a canopy with missing type.
5. `confirmingUnchangedValuesCounts`: same missing-type fixture issue.
6. `completingProductsDoesNotEndTheStep`: old incomplete guided-input fixture does not unlock Review.

The implicated canopy/flow implementations and these old assertions are unchanged from this pass's baseline. These failures are reported, not corrected by changing canopy policy or declared irrelevant green tests. The first Android host run included a new direction-collision assertion before the final production fix was compiled and failed 1/188; final stable-source rerun passed all 188. Initial instrumentation had IME/filter/fallback failures before correction; final two stable-source instrumentation selections passed. One iOS compile attempt referenced a nonexistent typed withholdingStatement; corrected to the existing preserved unknown-field representation before the passing build and executed unit selection.

## 5. Legacy Save for Later — exact release blocker, no isolated journal installed

No complete recovery contract was safely integrated this pass. The new planning attempt journal is unchanged and is not claimed to repair legacy attempts.

- iOS `SprayCalculatorView.pendingLaterSave` retains the original complete record/Trip only in view state. `MigratedDataStore.saveSprayForLater` durably writes and publishes the recipe/callback before writing its inactive Trip. Process death between them loses the original Trip attempt; sync can observe the recipe first. Same-screen retry and write-failure safeguards remain, but not a startup recovery barrier.
- Android no-route `AppViewModel.createSprayJobForLater` performs Trip creation then recipe insertion without one durable actor/vineyard/incarnation-fenced envelope. Ambiguous recipe acknowledgement can enter existing Trip rollback; unknown Trip creation acknowledgement also lacks the complete retained attempt. Qualified occurrence-backed saves have different retained dependencies and cannot be replayed as legacy.
- Original full route/recipe evidence, stable IDs, actor/vineyard fencing, startup discovery and dependency-sync admission must be integrated together before claiming recovery. Historical orphan evidence cannot be repaired by inventing missing routes or new IDs.
- Actual mobile process termination/restart at every persistence boundary was **not executed**. Existing six iOS failure/same-screen retry tests are included in the wider selection, not promoted to process-restart evidence.

Owner: **Rork**. Required next implementation: complete dedicated legacy attempt persistence before any write/callback; strict scoped startup reconciliation before dependent sync/start eligibility; exact-id idempotency/conflict retention; no destructive ambiguous rollback or active/inventory effects; then real app-process kill/relaunch/reconnect tests. This is not a missing Supabase credential issue. Existing production safeguards and workflow were left intact rather than installing an unintegrated file journal.

## 6. Combined acceptance matrix and new Review

| Journey | Current evidence on iOS / Android |
|---|---|
| Configuration labels and drawings | Source preserved; iOS production Step 6 UI / Android native planning component assertions pass. Pixel arrow orientation not newly screenshot-accepted. |
| 600 L/ha at 2.8 m; 16.8 / 33.6 L/100 m | iOS actual Step 6 UI regression passes; Android host intent/controller tests pass. Physical dose/area equations unchanged. |
| By Area / Only Full Tanks; progressive fields | Existing source preserved; Android component interaction pass; iOS source and model evidence. |
| 1500 L / 3 ha = 500 L/ha | Native model evidence; Android component interaction pass. |
| 1500 L / 600 L/ha = 2.5 ha | Both native planning model evidence; not an authenticated handset timing/capture. |
| Label picker, REVUS conditions, Crop Sil bases | Rate evidence/projection and synthetic fixture tests; Android numeric-first sheet interaction. No authenticated live-catalogue acceptance claimed. |
| DiPel incompatible dimension | Existing stored-evidence fixture validation remains noncalculable; no catalogue mutation. |
| WARNING optionality | Android open/close + CF2 admission tests pass; iOS source/model evidence; no permission-only gate added. |
| Regional entry, Done, focus, drafts | Android production-card instrumentation and iOS production chemical/regional UI pass; iOS native-alert exception remains failed. |
| Review distinction | Existing three groups and one selector preserved. Selected configuration participates in stale-selection validation. One travel pass/two controller equivalents never creates coverage. Native journal/model regressions included; no new authenticated Review screenshot. |
| Save / Start | Existing Create Spray Job & View Tank Mix → Spray Tank Mixing → Start Spray Trip route unchanged. No calculation-preview tracking shortcut. New planning mutation/replay gate unchanged/disabled; no disabled operation exercised. Legacy recovery blocker remains. |
| Dark mode / small screen / larger text | Full combined runtime matrix **outstanding** on both platforms. No layout acceptance inferred from builds or semantic tests. |

One existing-preview-only Android inspection (`allowDedicated=false`) failed immediately: “Open this app's simulator preview first. Simulator use drives the preview you have open.” No rental fallback, credentials, vineyard mutations or screenshots. iOS UI-test runs are synthetic simulator tests, not authenticated handset journeys. No physical-device captures or timings were collected.

New planning DTOs/transports/journals, preliminary physical selection, operation gate, tracking/GPS/coverage authority, tank Actuals and history were not changed. No second selector, rate engine, wizard or Save/Start controls added.

## 7. Performance

No actual calculator-open, Step 6, rate-sheet or Review screen latency was measured. Existing Android guided-flow caching and iOS section-local mapping are retained. The existing bounded regression runner still includes its existing model timing test; its workload is not screen performance and is not promoted to handset evidence. No new profiling loop or optimisation redesign was undertaken. Controlled authenticated handset measurements using existing authorised instrumentation remain outstanding.

## 8. Controlled candidate identity and release boundaries

- Visible source HEAD: `1b0b1e211fd8fa0b88046eec2d107cb7c3d26ec5` **plus this pass's managed patch**, not a claim that HEAD alone contains these fixes.
- SHA-256 of `git diff HEAD --binary -- ios android-vinetrack` after final native validation: `e2c52ab6f6eda04a19c076c9f9aa5acc840005eb54b0c6e9a53d4681195e6481`.
- Final managed source commit is **not yet exposed** during this turn; no manual commit/push was attempted. A post-finalisation commit attribution is still required before declaring an immutable handset candidate.
- iOS project identity: bundle `app.rork.nt0v48tayl7v8noxcfe74`, version **3.1.7 / build 139**. Simulator build passed; no new signed handset IPA/TestFlight build identity exists for this patch.
- Android: `com.rork.vinetrack`, version **3.1.7 / code 11**, final release APK `android-vinetrack/app/build/outputs/apk/release/app-release.apk`.
- APK SHA-256: `c33eb392913cc534c5b4061c47ce08673948d4ca07493976b7d1c824add71208`.
- This is a **new calculator/planning candidate**, not frozen Live Trip APK `8836a3025c30a779c04a0e1207490687f3d73a55ebf05eab1babb3eae4a538bb`. Shared version numbers are not artifact identity. New APK signing/handset installation not independently reverified in this pass.
- Physical iOS/Android installation, authenticated screen captures, actual process-kill/reconnect and combined dark/large-text acceptance: **not performed**.

Both native builds pass, but alert acceptance, six wider iOS test failures, complete legacy startup recovery and full handset/UI matrix prevent a full closeout/release GO. Limited controlled calculator inspection is possible; do not treat this as accepted reliability or operational readiness. No SQL, backend inspection, production data/catalogue mutation, tracking-authority edit, upload, tester change, capability activation or release occurred.

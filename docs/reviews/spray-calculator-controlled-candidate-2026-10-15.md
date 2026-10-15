# Spray Calculator mobile closeout — controlled candidate, 15 October 2026

## Status: partial, not final acceptance

**Do not declare all mobile blockers closed.** Production chemical-card callbacks and the live Step 6 regional test now pass. The original keyboard test passes its text-to-number and dismissal stage but still FAILS later at the alert accessory lookup. Full process-restorable Save for Later remains unresolved. Controlled diagnostic testing is appropriate; not operational new-planning acceptance, distribution or release.

No SQL, Edge/server, gate, Android application source, frozen Live Trip implementation, calculator equations or eight-step workflow changes. Single Row / Over-Row, By Area / Only Full Tanks, the two inline cards, illustrations, large rate selections and expandable orange WARNING remain. Unverified label/concentrate permission remains WARNING ONLY.

## Source isolation and candidate identities

- Starting/current exposed HEAD: `106c4e153dde5fbec2f3298ba5b64621da177216`. Initial difference was one managed history file; it was preserved. All current app edits are additional to this HEAD, not falsely attributed to it.
- User reference `1f237ebba1c1e3891a9f42b4089fc893e1da7cc8` exists but is not an ancestor of current HEAD. Application diff from it to HEAD showed only newer Config.swift changes (14 lines removed); calculator correction source was retained, not reset/cherry-picked over newer work.
- Corrected iOS tracked application patch SHA-256: `728bd526aca3a9aea357bda6e4d89193569e4b6839e17808f5065891dba61f1f`, computed with `git diff HEAD -- ios/VineTrack | sha256sum` after the final source/build checkpoint. Test/report files are not part of this application-only patch digest. A final managed commit is not yet exposed; bind it to these bytes before any distribution.
- iOS main simulator target project metadata: **3.1.7 / 139**. Simulator build passed. No signed physical-device IPA or IPA digest was produced/verified here. **Neither TestFlight 168 nor 169 is evidence of these edits.**
- Android application source unchanged this pass. Final release build passed. Package `com.rork.vinetrack`, version **3.1.7 / 11** from output-metadata.json.
- Android APK: `android-vinetrack/app/build/outputs/apk/release/app-release.apk`.
- APK SHA-256: `88046a0920717d201feef16afe6e3194ce3e8176040aaf3abb1af912ecb7bc6d`.
- Actual verified signer SHA-256: `241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3`, CN=Rork Kotlin Play Upload. apksigner verification succeeded.
- This APK is NOT the original frozen Live Trip artifact (`8836a302…`). Version code 11 is not a unique artifact identity. No upload, distribution, version bump, installation on a physical handset or store release.

## Outstanding issues and changes

| Priority | Outcome | Acceptance limits |
|---|---|---|
| 1 — keyboard transfer | Original missing-Done focus-transfer stage now progresses. Coordinator reconciles after native/SwiftUI focus transactions and text changes, resolves the current scene responder at dismissal, and owns a real 44pt accessible Done button rather than a transient toolbar-item proxy. Existing accessory content, field delegates, Return behaviour and scene isolation are retained. | Exact full test still fails at the later alert `keyboard.dismiss` query. Do not call the alert scenario passed. |
| 2 — chemical-rate card | Production `CalcChemicalLineCard` test passes 25.75/0.75/1250.5 and comma equivalents, effective canonical base-rate callbacks, Done, reconstruction and invalid nonblank entries. Added optional Codable original draft to ChemicalLine. Confirmed-band rejection uses unresolved zero instead of nil fallback. Reset/registered selection clear stale draft evidence. | Synthetic local production-component test, not authenticated catalogue/complete calculator journey. Whole-calculator persisted raw chemical-entry audit and every alternate confirmed/manual basis transition are not fully accepted by this one test. |
| 3 — region/draft | Production Step 6 callbacks pass live unit changes, 600 L/1 ha invariance, Single Row 16.8 → Over-Row 33.6 L/100m at 2.8m spacing and unresolved '.' retention. Complete planning groups convert atomically; an incomplete group retains its original units/labels and explicit guidance. Original provenance stays separate from converted display. Latest carrier cache replaces region-scoped historical display caches. Old-unit incomplete carrier drafts require explicit clearing, not reinterpretation. Trailing separators are incomplete editor drafts. | Saved prefill uses original raw text only when numerically consistent with the frozen displayed quantity; prior configuration text cannot overwrite the canonical prefill. General unsaved draft restoration after calculator destruction/process death and every carrier field/settings combination are NOT fully accepted. |
| 4 — interrupted save | Assessed, **not implemented**. Original write order/guards retained; no partial recovery envelope or startup automation installed. | Release blocker explained below. |
| 5 — responsiveness | Reproducible real elapsed simulator model and synchronous repository IO samples obtained; median/max below. No further product-section optimisation was needed or claimed. | No authenticated PerformanceCapture export, screen-to-usable-frame, history-scale UI or physical-handset latency evidence. |
| 6 — regression/candidate | Final model selection 226/0; UI aggregate 10/1; Android 168 host + 10 instrumentation passing; both native builds pass. | Not an all-green final mobile candidate because alert and restart recovery remain open. |

### Keyboard evidence and failure precision

Initial unmodified targeted run: 0 passed / 1 failed at `Dismiss accessory after text-to-number focus transfer`. Multiple narrow development experiments were tried; their failed/incomplete runs are not passing evidence. Final source uses the existing coordinator/accessory architecture, with no swizzling or delegate replacement.

The test retains the original value/non-submit/popup assertions and adds explicit pre-transfer visibility and post-transfer keyboard-hidden assertions. The current failure names the newly resolved alert accessor query (`Descendants matching type Button` → `keyboard.dismiss` first match), after transfer dismissal and popup entry. A prototype modifying UIAlertController accessibility containers was unsuccessful and **removed**; no modal accessibility override remains. The scene coordinator admits application windows only in its same UIWindowScene, with foreign/nil-scene windows still refused.

One earlier separate simulator run visually verified Draft/42 retained, numeric Done dismissing, and Popup draft/Cancel/Confirm retained after tapping visible Done. It explicitly observed the visible control missing its accessibility identifier. This lower-level screenshot evidence does not turn the failing XCTest into a pass, nor prove the final alert accessibility path.

### Chemical editing specifics

`applicationRateDraft` stores exact editor text independently from base-unit override authority. Focused typing is not resynchronised by its own numeric callbacks. Invalid nonempty or unfinished text becomes zero/unresolved, never a previous positive override. Confirmed range failure likewise cannot fall back to a prior/recommended value. The existing calculation still obtains rate from the same override/registered/legacy precedence and engine; no dosing equation is changed.

The UI fixture instantiates the actual card, not a second callback implementation. It asserts displayed input before/after Done, actual bound base-rate values, original raw text and card removal/recreation. Confirmed-selection clearing is exercised. Crop Sil/REVUS/DiPel captured safeguards remain in the passing regression selection. No catalogue correction or live chemical-data edits occurred.

### Regional testing harness correction

The first isolated Step 6 attempt was locked because its former keyboard fixture had no equipment. Completing synthetic prerequisites then exposed a harness-only crash: the foliar canopy controls required the missing CanopyReferenceImageRepository environment dependency. The fixture now supplies that dependency with an isolated local no-network remote and synthetic equipment/geometry. The final production Step 6 UI test passed after that correction. No production unlock logic or assertions were weakened to bypass prerequisites. The failed/crashed attempts are not acceptance evidence.

`SprayPlanningDraftTransition` has model round-trip checks for six decimal forms across L/ha and controller-travel display units, atomic refusal of partial/malformed groups, and ChemicalLine Codable raw-draft retention. The live UI test exercises the actual Step 6 bindings and configuration callback; model tests are not substituted for that test.

## Interrupted Save for Later: precise unresolved design

Current production `saveSprayForLater` in MigratedDataStore (1541+) invokes SpraySaveForLaterCoordinator: durable recipe slice → publish recipe/onSprayRecordChanged → durable inactive Trip slice → publish Trip/onTripChanged. Equality/identity guards reject conflicting retry edits; errors do not produce successful UI completion or recording.

The recipe publication callback can enqueue synchronization before the Trip exists. Calculator `pendingLaterSave` is still view-owned state. The separate prospective occurrence creation journal can retain exact Trip/create request identity, but does not bind the whole original recipe+Trip creation attempt into one restorable account-scoped authority. Legacy no-occurrence attempts have no such complete journal. Generic save is vineyard-checked, not a complete startup account/session-incarnation admission mechanism.

A safe implementation must capture the original recipe, inactive Trip, occurrence/create dependencies and all UUIDs BEFORE either write/callback; fence owner/account incarnation/vineyard; persist exact pending/held/completed phases; recover before dependent sync/start publication; verify existing durable slices against the original payload; and preserve a durable recipe on conflict. It must not independently mark completed merely because each ID exists, clear newer edits, retry under another actor, or regenerate route geometry/IDs.

No safe full startup/replay integration was installed in this pass. Writing a standalone file without recovery admission and sync dependency wiring would be partial recovery, not the requested fix. Existing six SaveForLater tests remain passing (record refusal, uncertain record acknowledgement, Trip write failure/same-ID retry, conflicting/edit failure protection and gate refusal), included in the model total. **No actual OS-termination/restart/reconnect or each-boundary recovery tests were executed for a new envelope, because no envelope was implemented.** Preserve retained recipes and repair-required state; do not delete/reconstruct them.

## Real measured performance — simulator, not handset

Source: DEBUG-only `SprayPerformanceValidationView`, using monotonic systemUptime. Eleven samples per case, median = sorted sample index 5; slower reported value = observed maximum, not p95 extrapolation. Same binary compares the removed repeated-read loop shape with current once-per-section snapshot. Thirty iterations per sample. This is a controlled model comparison, NOT timing old/new full screen binaries or a claimed UI speed-up.

| Synthetic case | Before median / max | After median / max | Samples |
|---|---:|---:|---:|
| 5 blocks, 3 products, plan reads | 0.982 / 1.615 ms | 0.335 / 0.350 ms | 11 each |
| 100 blocks, 20 products, plan reads | 124.849 / 138.379 ms | 6.140 / 6.186 ms | 11 each |

Both checksum comparisons were equal. These loops are not a representative catalogue/resistance-history workload.

| Real synchronous repository operation, synthetic records | Median | Maximum | Samples |
|---|---:|---:|---:|
| Durable save, 5 recipes | 0.366 ms | 2.144 ms | 11 |
| Load, 5 recipes | 0.068 ms | 0.076 ms | 11 |
| Durable save, 500 recipes | 6.789 ms | 7.177 ms | 11 |
| Load, 500 recipes | 3.131 ms | 3.270 ms | 11 |

Repository benchmark uses actual saveRecordsSliceOrThrow/loadAllRecords with isolated temporary files; loaded counts were 5/500. Warm codec/IO caches participate, so do not call this all-cold launch/disk performance. Durable acknowledgement was retained. Temporary files are removed afterward. No account or production records are used.

The existing opt-in/account-authorised PerformanceCapture spans remain intact; **no authorization bypass was introduced**. Without an authenticated authorised capture session, no actual PerformanceCapture report was exported. Opening calculator, entering Step 6, configuration/method changes, numeric editing, rate sheet, Review and resistance history still lack end-to-end elapsed capture samples. Model loop and IO measurements cannot fill those rows.

Android current JVM microbenchmark XML: 300 repeated plan loops **2.249092 ms**, checksum 540000.0. One aggregate host sample, not a median/maximum series, handset measurement or before/after UI comparison.

## Final current-source executed tests

Overlapping development runs are not summed. iOS skipped count is not exposed by the runner.

| Surface | Result | Evidence |
|---|---|---|
| iOS final consolidated model/regression | **226 passed / 0 failed**, 21s | 20 selected suites; includes seven native coordinator tests, six SaveForLater cases, three new transition/draft tests, parity/chemistry/Crop Sil/captured structures/snapshots/timing/policy. Prior 226/116s is overlapping. |
| iOS keyboard UI, final partition A | **2 passed / 1 failed** | Passive/interactive dismissal and multiline/large-text controls pass. Focus-transfer+alert test fails at alert query. |
| iOS keyboard UI, final partition B | **3 passed / 0 failed**, 153s | Actual calculator fans input drag/Done/background, all keyboard types including formatted decimal, sheet/fullscreen/nested list/searchable. |
| iOS presentation + editing UI | **5 passed / 0 failed**, 157s | Three existing warning/rate/illustration tests plus production chemical card and live Step 6 unit transition tests. |
| iOS distinct UI aggregate | **10 passed / 1 failed** | Eleven distinct tests across the final partitions, not one all-green suite. |
| Android calculator host | **168 passed / 0 failed / 0 errors / 0 skipped**, final runner 12s | 14 selected suites. Disabled test-result cache/up-to-date reuse for the actual rerun; Gradle executed testDebugUnitTest. An earlier FROM-CACHE invocation is not counted as fresh execution. |
| Android instrumentation | **10 passed / 0 failed / 0 skipped**, 19s | SprayPlanningAndroidTest + ChemicalConditionPersistenceAndroidTest; actual component/persistence fixtures, not authenticated workflow or OS process kill. |
| iOS final build | **Passed simulator build** | Final source checkpoint; no signed device release/IPA validation. |
| Android final build | **Passed release build** | Source unchanged; exact APK/signature above rechecked. |

Scoped diff whitespace checks passed. No tests were skipped or assertions changed to accept a different dose. Incomplete test runs, a transient fetch failure, harness crash and failed accessibility experiments are retained as development failures, not counted as final passes. Runtime log CLI returned no logs for the managed test/simulator attempts; no inaccessible test log is cited as inspected.

## Screenshots / simulator scope

**Authenticated calculator screenshots remain unavailable on both platforms.** No sign-in bypass or production vineyard fixtures were created. Four explicit simulator tasks used separate billed iPhone simulators, not the user's open Android preview: visible keyboard journey, benchmark report, initial locked regional fixture, and crash diagnosis. The later UI tests passed Step 6 after fixture correction. Do not label local fixture captures authenticated acceptance. No repeat simulator rental was used to claim final handset evidence.

## Controlled physical-device checklist — both platforms

1. Record handset/OS, source/artifact identity and regional units; do not uninstall/clear data with pending work.
2. Enter 25.75, 0.75, 1250.5 and comma equivalents in actual chemical/planning fields; check displayed/base values through Done, passive tap, drag, re-focus and reopen. Confirm malformed/trailing-separator text cannot retain an executable previous dose.
3. Move directly text → number → decimal. Verify Done each time, no submit/save and correct sheet/list behaviour. **Retest alert draft/Done/Cancel explicitly: unresolved iOS automated blocker.**
4. With complete values, switch units and return; physical quantities unchanged. With incomplete values, verify retained original-unit guidance and explicit resolution/clear. At 2.8 m, 600 L/ha remains the same while controller travel changes 16.8 ↔ 33.6; chemicals/water do not double.
5. Verify original label evidence, confirmed/manual selection, Crop Sil basis/unit protections, REVUS/DiPel conditions and orange WARNING details in the full authenticated eight-step calculator.
6. Use small handset/light/dark/large text; ensure cards, large rates, keyboard scrolling and Review stay readable. Record timings with authorised PerformanceCapture enabled/disabled; identify dataset sizes and thermal/power state.
7. Legacy Save for Later only: preserve retained work and collect failures/IDs. **Do not regard process-death recovery as accepted.** Controlled fault-injection/restart requires a complete creation-attempt implementation first; no destructive test against unsynced production work.
8. New-planning Save/Start/replay must remain disabled. Do not bypass a hold to test tank/coverage operations.

## Backend-dependent restrictions — distinct from mobile defects

- New planning operational gate remains closed for all four combinations; current capability/schema/lifecycle admission is not approved/deployed/accepted.
- Immutable server recipe revision/digest/operation receipts, exact lost-ack/409 reconciliation and atomic server creation remain a separate integration contract.
- Explicit partial-area/Over-Row physical scope and versioned server capability acceptance remain required; planned hectares/controller equivalents never imply actual coverage.
- Common-backend authenticated native interchange, full-schema security/legacy compatibility and Portal acceptance remain external gates.
- Supabase catalog access was not retried or changed for this mobile pass. No backend deployment, paid infrastructure, release or distribution was performed.

**Next mobile work:** finish the alert accessory accessibility/lookup defect, implement and accept full owner-scoped creation-attempt recovery, and close the remaining unsaved-draft/complete-screen and authenticated latency matrix. Do not confuse these mobile blockers with the independent backend hold.

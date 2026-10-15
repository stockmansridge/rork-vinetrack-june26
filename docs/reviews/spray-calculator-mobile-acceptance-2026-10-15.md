# Spray Calculator current-source acceptance — 15 October 2026

## Status

**Partial completion; NO-GO for declaring final mobile acceptance or new-planning operations ready.** This pass fixes a fixture-locale error and a narrow production chemical draft risk, removes repeated section-level computation, adds opt-in timing spans and executes current regressions. It does not supply authenticated screenshots, full Step 6 numeric callback acceptance, end-to-end latency measurements, or process-restorable Save for Later. Those remain explicit blockers, not inferred passes.

Baseline source: `d8d327be7ae76ed74a173f6f57d841a5cf07a98e`. Before edits, application source was clean; four managed conversation files already differed and were left untouched. Current source includes the accepted Start Spray presentation and WARNING ONLY policy; the older completion report was not used as final authority.

## Approved contract retained

- Exact Single Row | Over-Row and By Area | Only Full Tanks terms; two inline cards in the eight-step workflow.
- Existing cyan/blue arrowheads point toward green vine faces, enlarged numeric label rates with smaller descriptions, compact orange WARNING and optional detail sheet.
- No new CF>1/unknown-label permission denial or acknowledgement requirement. Genuine invalid CF/quantity/rate ambiguity blockers and independent new-planning operational gate remain.
- No engine equation, CF floor, label rate, dose, controller conversion, row-equivalent or Trip coverage change.
- No SQL/backend/catalogue edits, production data changes, gate activation, distribution, tester change or release. Android application source/cache was unchanged in this pass. Existing synchronous durable storage was not made asynchronous.

## Numeric investigation and correction

### Reproduced failure and root cause

The current UI run reproduced the old 25.75 -> 2.575 failure in `KeyboardInteractionUITests.testDoneAcrossKeyboardTypesKeepsValuesWithoutSavingOrSubmitting`, which edits a generic SwiftUI `TextField(value:format: .number)` fixture, not a production calculator string binding.

Replacing the entire initial number through Select All did not fix it. A diagnostic canonical-value label then proved that BEFORE keyboard dismissal, the fixture model held **2575.0** while the displayed field read 25.75. The locale-dependent formatter treated dot as grouping; it was not evidence that Done divided an actual calculator quantity by ten. The fixture now specifies en_AU for its dot-decimal literals, retains whole-value replacement, and asserts both displayed and canonical values before dismissal and displayed value afterward. This keeps numeric expectations intact instead of weakening them. The full post-fix nine-test UI selection passed this case.

Production carrier controls use raw String bindings through RegionalInput, not that generic formatted-number field. This distinction does NOT certify all production fields. Existing actual-calculator keyboard test edits fans/jets 42 in an isolated local calculator, not all Step 6 decimals.

### Production chemical editor correction

`CalcChemicalLineCard` formerly resynchronised text on every override-rate mutation, including while typing; comma text was compared through `Double` rather than the accepted comma-aware parser. Invalid nonblank text could leave an earlier valid override active. Changes:

- Preserve the editing String while focused; no global keyboard replacement or formatting on Done/blur.
- Reuse the existing finite comma/dot parser for comparison and editing.
- For invalid nonblank/nonpositive input, retain a zero unresolved override plus visible existing-style validation guidance rather than fall through to a prior/recommended positive dose. The plan continues to reject nonpositive product quantities.
- Preserve explicit rate selection/reset behaviour and current registered-rate checks.

Added numeric boundary tests for 25.75, 0.75, 1250.5 and comma equivalents, repeated resolution and malformed/mixed separators. These are production-parser tests, not screenshots or full editable-card UI acceptance. Focused chemical callback/re-focus acceptance remains required.

### Regional field-state limitations

Existing `changeRateDisplay` re-expresses controller/physical rates and refuses nonblank unresolvable basis changes. No conversion equations changed. However, live regional-settings changes still need remediation/acceptance: planning raw strings are interpreted against the current RegionFormatter, and invalid cached carrier display text is scoped to the old region. The complete values-already-entered region-change/navigation matrix is NOT passed. Do not claim that all raw drafts survive view destruction or that live settings changes can never reinterpret raw planning values. A region-aware independent canonical/draft transition must be finished and exercised through actual screen callbacks before final acceptance.

## Performance evidence and instrumentation

The production chemical section requested its entire plan-to-line mapping inside each product row. It now creates one immutable mapping per section construction and shares resistance applicability and area-picker eligibility. No long-lived cache is introduced: current inputs/history are reread on the next construction, duplicate chemical-line identity and skip behaviour stay intact.

Existing opt-in, account-authorised `PerformanceCapture` now instruments:

- calculator flow construction;
- geometry resolution;
- guided product lookup;
- resistance-history preparation;
- product-plan mapping;
- rate/configuration selection callback;
- spray-record repository load and durable slice save, alongside existing persistence codec/read/write/main-thread measurements.

Labels/counts/times only; no chemical/record content, account IDs or operator entries are logged. Existing access/export controls and synchronous disk acknowledgement remain.

`SprayCalculatorSectionTimingTests` compares the removed repeated plan-read shape against one current snapshot, with exact quantity/checksum equality, 30 iterations for 5 blocks/3 products, 30/10 and 100/20. Deterministic plan-read reductions are 90->30, 300->30 and 600->30 in those model loops. This is not a measured SwiftUI frame or latency claim.

| Requested metric | Before | After | Acceptance |
|---|---|---|---|
| Per-section plan mapping | Once per product row | Once per section construction | Source-backed; model equality benchmark passes |
| iOS synthetic elapsed times | Benchmark prints durations | Benchmark prints durations | Managed runner returned pass counts, not the printed timing series; no numeric ms claim available |
| Android cached repeated-plan host benchmark | No fresh baseline | 300 iterations 3.433807ms, checksum 540000 | Current host XML evidence only, not handset/UI responsiveness; cache untouched |
| Open calculator / enter Step 6 / option switch / numeric edit / rate sheet / Review usable frame | Not captured | Not captured | Still requires authenticated end-to-end capture |
| Large chemical catalogue + resistance histories + disk datasets | Not profiled in this pass | Timing spans prepared | No claim of full requested small/medium/large screen profiling |

Do not derive speed-up percentages from source call-count reductions or compare iOS simulator counts to Android JVM milliseconds.

## Save for Later interrupted-write assessment

The existing coordinator saves the recipe durably before the inactive Trip and uses a same-screen @State pair for retries. Current tests prove record-write refusal, retained recipe after Trip-write failure, ID-preserving same-screen retry and no active tracking.

**Release blocker retained:** after process termination between writes, the exact provisional Trip payload can be lost even though the recipe survives. Reconstructing it from today's geometry or recipe alone would fabricate original route/occurrence/setup evidence. No durable account/vineyard-scoped creation-attempt envelope or restart admission hook currently binds that exact pair across sync publication. The occurrence creation journal alone does not persist the complete linked recipe attempt.

No automatic reconstruction, deletion of the durable recipe, duplicate Trip attempt, tracking, inventory movement or gate bypass was added. Completing this safely requires a durable original record+inactive Trip attempt written before either effect, owner/vineyard fencing, original occurrence creation dependency, idempotent restore and hold/conflict handling, and cleanup only after both durable writes. It must integrate with startup and existing sync, not merely write another screen cache. Existing safeguards are retained rather than installing an unaccepted partial recovery path.

## Tests actually executed — overlapping runs not added

| Surface | Current evidence | Limits |
|---|---|---|
| iOS final consolidated model/regression selection | **223 passed**, 46s | 19 selected suites: planning, regional, registered rate, calculation/workflow parity, Save for Later, keyboard coordinator, section/flow timing, presentation policy, tank chemistry, captured production chemical structures, Crop Sil, custom sprayer/legacy unit boundaries, carrier sync, snapshots and performance access. Managed tool exposes no skipped count. Includes REVUS/DiPel captured structure cases; no catalogue corrections/live reads. |
| iOS post-locale-fix presentation+keyboard UI selection | **8 passed / 1 failed** | Three presentation tests passed; formatted numeric test and isolated production-calculator fans field dismissal passed. Remaining failure described below. Synthetic/local component/keyboard journeys, not authenticated calculator. |
| iOS focused failure localisation | **0 passed / 1 failed** | Failure is missing `keyboard.dismiss` accessory immediately after text-to-number focus transfer, before alert presentation. Assertion messages now identify that exact stage. |
| iOS attempted reconciliation experiment | **0 passed / 0 failed; execution unsuccessful** | A one-run-loop accessory reconciliation experiment could not be validated: runner reported warnings/no identified compiler error, log path unavailable in sandbox. Experiment removed; production KeyboardSceneCoordinator is identical to baseline. No passing result claimed. |
| Android host calculator selection | **168 passed / 0 failed / 0 errors / 0 skipped**, 24s | 14 suites; planning, registered rates, Crop Sil, frozen snapshots, pending-create edit/blocked/in-flight retention, model parity, process-JVM recreation, tank recovery and calculation regressions. Original runner reused. Not actual Android process death. |
| Android instrumentation | **10 passed / 0 failed / 0 skipped**, 23s | SprayPlanningAndroidTest + ChemicalConditionPersistenceAndroidTest. Real Compose components/callbacks and scoped preference replay, no authenticated full workflow or live backend. |
| Final iOS build | **Passed simulator build** | After final restored source/instrumentation. Not signed physical-device release/IPA acceptance. |
| Android build | **Passed release APK build** | No Android app source edits after this check. No store action. |

Intermediate iOS selections (125, 94, 111 passes) overlap the final 223 and must not be summed. Initial UI failures were real: original formatted case, then canonical-value diagnostic; they were not skipped or asserted to a different expected dose. No PostgreSQL/Edge rerun, SQL change or migration.

## Visual evidence

Presentation UI tests retain screenshot attachments for rate sheet, warning details and Over-Row synthetic native components. The managed result here exposes pass/fail counts, not downloadable attachment paths; no image has been inspected or presented as authenticated screenshot proof.

Existing-preview-only simulator attempts: Android unavailable (open preview required); iOS source/build mismatch after edits prevented the attempt. No dedicated rental/repeated screenshot loop, auth bypass or production fixtures created. Final source has since built; no authenticated screenshot acceptance claimed.

Still pending on BOTH platforms: authenticated full Review/Step6 state; normal/small phones; light/dark; large text; keyboard-covered numeric fields, scroll/re-focus; both diagrams and full-tank field/result visibility; compact WARNING and details; complete label-rate values/descriptions. A passing component fixture is not the complete eight-step journey.

## Candidate build register

No version bumps, uploads, release or tester changes. Do NOT assume TestFlight 3.1.7 (168) contains these edits.

| Platform | Source identity available during this pass | Version/build | Artifact |
|---|---|---|---|
| iOS | Baseline commit `d8d327be7ae76ed74a173f6f57d841a5cf07a98e` plus current source patch; tracked application diff SHA-256 `a444ac96fec7f7cee24df022af1103e47be42689387ea7edf2e92f4d6610cb8f` (`git diff HEAD -- ios/VineTrack`) | Project app target 3.1.7 / 139; no signed IPA Info.plist verified | Simulator build passed; no handset-installable signed IPA/hash returned locally |
| Android | Same baseline commit; Android application source unchanged from it | APK metadata 3.1.7 / 11 | Existing local release APK `android-vinetrack/app/build/outputs/apk/release/app-release.apk`, SHA-256 `88046a0920717d201feef16afe6e3194ce3e8176040aaf3abb1af912ecb7bc6d` |

The baseline commit does not itself contain this pass's iOS corrections. A new final managed Git revision was not yet exposed at register preparation; do not invent one or call the baseline the corrected-source commit. Before distribution, bind the final managed commit to the source manifest and signed artifact. Android version/build is not unique; use artifact hash. Build-output paths may be overwritten by later builds. The older frozen Live Trip APK hash is different and must not be substituted.

Current iOS application file SHA-256 identifiers:

- SprayCalculatorView.swift: `41710aec7b63a7d890184e4af76f8138647d7d7eb265eaadf3f4aaf086bb9966`
- KeyboardValidationView.swift: `2cd6d2ca64d3f2653fbc351e566a9f0f4cf5a0c22d7914f662f8341ad6c9f0dd`
- SprayRepository.swift: `f50321cd6a2b8b8049b6b0fcc5381d246f8adfccb9cc39b6a7f9a8f6ef4527e4`

## Controlled device-testing matrix — all actual-device rows pending

| Case | iOS handset | Android handset | Required evidence |
|---|---|---|---|
| Intended volume, area, calibration, custom sprayer, chemical rate/quantity: 25.75 / 0.75 / 1250.5 and comma equivalents | Pending | Pending | Raw before/after and physical canonical amount through Done/passive tap/drag/re-focus; no Save/Start from incomplete drafts |
| Configuration/method/specification/rate basis changes with complete values | Pending | Pending | Original water/hectares/dose retained; controller display changes only as approved |
| Partial/ambiguous text then basis/region/navigation changes | Pending; live-region risk open | Pending | Retained draft and explicit unavailable guidance; no guessed physical amount |
| Normal/small/light/dark/large-font complete calculator | Pending authenticated session | Pending authenticated session | Screenshots/recordings of Step6, rates, WARNING/details, Review and keyboard scroll |
| Crop Sil/REVUS/DiPel and missing dimensions/invalid CF | Pending | Pending | Frozen rates, true blockers, no uncertainty-only CF blocker |
| Legacy Save for Later interrupted after recipe write | Release blocker | Pending | Actual OS kill/relaunch; same IDs, retained recipe, no duplicate/active Trip or inventory effects |
| Saved-plan offline edit/relaunch/reconnect | Pending | Pending | Actual OS restart, queue retention, exact replay and server read-back; store recreation is lower evidence |
| New Single Row/Over-Row × By Area/Only Full Tanks Save+Start+Tank | Disabled | Disabled | Do not bypass gate; backend/workflow approval and reconciliation required first |
| Performance open/Step6/options/input/rates/Review | Pending capture | Pending observation | Small/medium/large data, latency to usable frame with capture enabled/disabled; no stale input/history cache |

**GO:** further controlled diagnostic/preview testing with the documented holds. **NO-GO:** final mobile acceptance, claim of complete responsive authenticated workflow, interrupted-save recovery acceptance, distribution or enabling new planning. Required follow-up is targeted focus-transfer diagnosis, region/draft callback closure, authenticated visual capture and measured screen latency—not a design/formula change.

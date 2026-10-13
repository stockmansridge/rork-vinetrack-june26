# VineTrack mobile acceptance — 2026-10-13

Historical checkpoint. The subsequently authorised corrections, new final test results,40-case classification and handset/internal-artifact status are in `docs/reviews/spray-device-testing-readiness-2026-10-13.md`. In particular the three source risks below have since received client containment corrections; their server-dependent acceptance remains open.

## Ownership and scope

Backend ownership (Supabase, SQL v2, Chemical V3 authority, RLS, triggers/RPCs and server validation) belongs to the owner's separate ChatGPT review. This mobile checkpoint performs no backend changes, operational activation or release. Calculator cards, illustrations, quantities, CF equations/minimum, Trip actual calculations and historical snapshots are frozen.

The requested `docs/reviews/spray-backend-takeover-2026-10-13.md` is absent from this checkout. `review/spray-backend-admission-20261013` is not a local Git ref; only main was listed. No branch switching, manual commit/push, SQL application or remote provisioning was performed. Consequently this report does NOT certify parity with that branch's unseen takeover document. The user's explicit boundaries and the existing SQL v2 client contract were used. Integration must compare the takeover document when supplied/synced.

## Executed evidence

### iOS

- A new real-file-backed recovery test, `StartTankCommitCoordinatorTests/testUnestablishedRecoveryRechecksCurrentRecipeWithoutDiscardingJournal`, executed before correction: **0 passed / 1 failed** (`XCTAssertFalse`). Prepared tank recovery could establish an operation after the current linked record gained blocked planning intent.
- After the narrow correction, `VineTrackTests/SprayProgramStepEditingTests`, `VineTrackTests/SprayProgramRound2Tests/programDatasetPreservesRateDenominatorsAndExcludesOperationalData()`, `VineTrackTests/SprayPlanningIntentTests`, and `VineTrackTests/StartTankCommitCoordinatorTests`: **64 passed / 0 failed, 72 seconds**.
- The original corrected 55-case editing/PDF/planning selection is included, with one new delayed-confirmation case and eight coordinator cases. The canonical snapshot fixture, unrelated-product unseeded replacement and exact PDF denominator contracts remain passing. No cross-product dose borrowing was restored.
- `runChecks(ios)` passed after all iOS source changes. Simulator compilation only; no App Store/device-release validation.

### Android

Final host selection: `SprayPlanningIntentTest`, `SprayPlanningProcessRestartTest`, `SprayProgramStepDraftTest`, `SprayProgramRound2Test`, `StartTankCommitCoordinatorTest`, via `.rork-tmp/spray-mobile-final.init.gradle`.

- Initial execution: **57 passed / 2 failed** out of 59. Both failures were editing test-contract discrepancies, not new dose-engine defects: an old exact PATCH inventory omitted existing ground-target/carrier-area keys; another expected converting an unrelated product's 2 L rate into 2 kg.
- Corrected only those demonstrably incorrect expectations: retain exact column inventory with the two real input fields, preserve all forbidden-field checks; replacement must have new chemical identity/unit, zero unseeded rate, no source/raw line/frozen snapshot. Production replacement behavior was not changed.
- Final execution: **62 passed / 0 failed/errors/skips**, BUILD SUCCESSFUL, 3m25s. Breakdown: planning20, child-process1, editing16, Round2/reference11, coordinator14. XML timestamps 2026-10-13T11:12:51–52Z. Logs `.rork-tmp/spray-mobile-corrected.{stdout,stderr}.log`.
- Android native instrumentation `SprayPlanningAndroidTest`: initial attempt failed test compilation before assertions (new fixture omitted required nullable SprayInput arguments). Supplied the actual API arguments; local compileDebugAndroidTestKotlin passed.
- Instrumentation then **4 passed / 1 failed / 0 skipped**. The new real-preference test alone expected unchanged updatedAt during a legitimate PENDING-to-BLOCKED status mutation. Exact failure showed identity, creation time, payload, attempts, error and status correct; only updatedAt advanced. Corrected the fixture to assert monotonic updatedAt while comparing EVERY other field exactly. Repeated blocked replay still requires whole-row equality, including updatedAt.
- Narrow corrected selector `SprayPlanningAndroidTest#realPreferenceRecreationPreservesPlanningTypingIdentityAndBlockedRetryState`: **1 passed / 0 failed / 0 skipped, 7 seconds**. No redundant full-class rerun. Thus four unchanged native cases passed in the earlier run and the fifth corrected case passed separately; do not call this one all-green five-case run.
- Native Compose case renders the production cards, asserts both configuration illustration descriptions, Full Tank1500L/3ha =500L/ha, controller14 Standard/28 Over-Row, target/calibrated500 modes and retained target text. This is native-card semantics/interaction evidence, not pixel/screenshot review or the authenticated whole Calculator.
- Real PendingWriteStore/Repository over isolated Context-backed preferences preserves raw `1,500`, `3.00`, `28.00`, captured NZ units, canonical inputs/resolution, payload/client/write IDs, creation timestamp and two prior attempts across new store instances. Rejected replay changes only status/error/update time; repeated replay is exact/no publication. Ordinary unverified concentrate enqueue throws before replacing existing evidence. No production endpoint fallback is installed.
- `runChecks(android-vinetrack)` passed after production changes; final validation also follows the instrumentation-fixture changes.

Command-scoped Gradle heap4096m/ParallelGC/soft-reference policy only. No project memory/release configuration change. Existing asset-address advisories are unchanged and unrelated.

## Persistence/restart claims

PASS at production-model/projection and local persistence levels: input-only templates; explicit replacement/clearing; unrelated reusable carrier/head/band fields; frozen chemical evidence; Standard/Over-Row physical-rate separation; equivalent Full Tank modes; declared NULL versus historical omission; repository/store recreation; retained blocked replay state.

New planning operational saves remain disabled. Tests seed synthetic drafts/pre-existing pending envelopes directly; they do not activate operator-screen planning writes. An unrelated edit or explicit clearing does not remove the migration/admission gate.

Android's abrupt Runtime.halt(73) child-JVM test uses production payload/replay logic and a synced test file adapter. It is genuine child-process termination, NOT Android application process death. iOS real temporary-directory reload and Android real preference recreation are also NOT OS app termination. No connected adb device was available. Actual iOS/Android force-stop/relaunch under original account, authenticated save/reopen and successful isolated-server replay remain unexecuted.

## Narrow safety corrections

1. Both tank confirmation callbacks now compare the current entire frozen record with the captured record, not just its UUID/tank UUID. Same-ID changed or missing mix refuses with a reconfirmation message; current blocked recipe also refuses. New pure admission cases pass on both platforms.
2. Both legacy no-recorded-mix Start Tank routes recheck any currently linked record's planning/compliance blocker and refuse fallback when a planned tank is now available. iOS also binds the callback to the displayed Trip ID. Legacy honest amount-not-recorded workflows remain available when there is no blocked linked recipe; no artificial zero actuals are written.
3. Prepared tank-journal recovery now rechecks admission before establishing a previously uncommitted operation. iOS uses the current scoped linked record; Android production constructor requires a scoped current-recipe callback. Android retries recovery after scoped cached/remote recipe hydration rather than treating missing startup recipe as permission. Blocked journals remain intact, with no new actual/Trip/tank marker.
4. An already durable actual or established tank session remains factual recovery, not a fresh recipe approval. Stable IDs, route/GPS/coverage metadata and original actual quantities are preserved. Android new factual-recovery test and existing both-platform recovery/idempotence tests pass.

No calculator screen, dosing equation, CF calculation, snapshot encoding/schema or Trip actual arithmetic was changed. The iOS prepared-recovery bypass was reproduced through an actual failing assertion. Same-ID stale-confirmation and fallback gaps were source-traced and narrowly rechecked; no authenticated tap-by-tap bypass reproduction is claimed.

## Client entry-point trace and remaining limitations

| Boundary | Current mobile containment | Limitation / integration dependency |
|---|---|---|
| Save Spray Record | iOS MigratedDataStore add/update -> operationalPlanningBlocker; form checks returned Boolean. Android AppViewModel create/update and SprayRecordRepository input recheck before optimistic/enqueue/network paths. | Server must independently validate effective recipe; no client CF/status/name can grant authority. |
| Save job / Program Step | Calculator/job paths gate before admitted writes; local Step edits use shared record admission. Both portal repositories refuse new planning-field PATCH while disabled. Templates retain inputs, not resolutions. | Input-only unverified template is not execution permission. Server must guard executable job transitions separately. |
| Calculator Start Trip / saved-job activation | iOS frozen final mix rechecked before tracking; saved-job activation checks current record. Android job-create/start input checks and existing-job current linked mix checks precede claim/tracking. | Not a server transaction/rollback proof. |
| Start Tank confirmation/fallback | Current recipe freshness, planning/compliance and Trip identity rechecks described above. | Factual actual quantities are not label-authority evidence; server admission must bind reviewed recipe/actual policy. |
| Interrupted tank operation | Prepared journal rechecked; existing factual operation recovered stable-ID/idempotently. | Native OS process death and actor-scoped server acknowledgement loss not tested. |
| Spray offline enqueue/replay | Existing create/update gate before enqueue and replay; repository/transport recheck. Rejection retains original bytes/ID/creation/retries and emits no success. iOS dirty sync and actual backend upsert both gate; initial empty-remote bootstrap depends on transport's gate. | Success under synthetic chemical transport is not server admission acceptance. |
| Resume existing tracking | Existing active Trip/route/session recovery retained; prepared new tank cannot use it as bypass. | Continuing an already established historical operation is not certification of label authority. Server must distinguish factual recovery from new execution. |

**Do not claim every operational route is fully accepted:**

- Generic (non-calculator) spray Trip starts do not carry a reviewed recipe admission contract. Android `AppViewModel.startTrip` also treats non-auth server exceptions as local/offline starts. Preserve historical generic tracking, but backend rejection must NOT be interpreted as permission to execute a newly admitted spray. This needs typed integration and server enforcement before activation.
- Android `SprayRecordCreateSync` currently treats all HTTP409 as duplicate acknowledgement and removes the CREATE marker without verifying that the same payload was accepted. Do not use409 for chemical-admission errors or assume409 proves idempotency. Matching server receipt/row verification plus narrower client conflict handling remains required.
- iOS Calculator `saveForLater` still creates a placeholder Trip before calling final record insertion and ignores addSprayRecord's Boolean. Earlier flow gating is present, but final admission mismatch/local insertion failure could produce false success/orphan placeholder. This is a source-level transactional/feedback concern; no production-control reproduction established here, so frozen calculator code was NOT speculatively changed. Must be acceptance-tested before activation.
- Backend-specific denial text is not yet mapped consistently by current Android status-based friendly errors/offline fallbacks. Do not claim the complete new admission UX or authoritative server rejection handling is integrated.
- Unknown/amount-only legacy evidence is not newly reinterpreted or erased. Present CF and recognised dilute basis checks are client containment, not proof of trusted reference/condition/permission. Server authority must resolve effective old-client/stale/ambiguous recipes without using a client-controlled CF1 bypass.

These are reported integration/release blockers, not an assertion that database activation alone completes all mobile lifecycle work.

## Wider failure classification without redundant runs

Fresh read-only git comparison against `d0d846cbb3adaa5acf49f32cdbf480a9953ad21c` confirms the four original iOS wider suite files are unchanged. Existing baseline archive remains untouched. Linux has no isolated Xcode baseline runner; rerunning registered current-source tests cannot establish unchanged-baseline evidence.

| iOS group | Count | Available classification |
|---|---:|---|
| CalculationParity |2| Integer-literal division expectation vs fractional geometry; old nil physical-row projection expectation requires contract reconciliation. |
| GuidedWorkflowParity |14| Missing explicit canopy/equipment/ground prerequisites and obsolete ground L/100m assumptions. Source-backed fixture discrepancies, not executed baseline confirmation. |
| RegisteredUseRate |2| Original two registered directions expand to five band/preset picker entries via existing preset expansion; count expectations conflate evidence directions with selectable entries. |
| VolumeDecision |15| Helper documents Medium/High20 while the same unchanged suite expects40; omitted prerequisites and old step naming. Source-backed fixture/contract discrepancies. |

All original33 remain runtime-baseline-unclassified, not waived or fixed. No wider rerun unable to add baseline evidence. The separately observed seven iOS unit/scoping failures remain separate: two Litres-versus-L label assertions and five fixtures using Kilograms where actual enum raw value is Kg/default decode falls back to litres. No historical unit mapping/formula patch was introduced here. No newly failing calculation case was established in this turn; new recovery defect is separately reproduced/corrected above.

Android prior wider15 failures have retained EXECUTED unchanged-baseline evidence (152 common cases, zero changed status/message/assertion-frame results); that historical comparison is not a current whole-app-green claim. Final planning/editing selection is green after the two invalid expectation corrections, not production rate borrowing.

## Exact client/server integration requirements

No additional database column is requested by this mobile checkpoint.

1. Preserve the already agreed SQL v2 tuple. Records: `sprayer_configuration`, `spray_planning_method`, `full_tank_specification`, `planning_input_provenance`, `planning_intended_tank_litres`, `planning_target_area_ha`, `planning_calibrated_litres_per_hectare`, `planned_application_area_ha`, `resolved_planning_carrier_litres`, `resolved_planning_litres_per_hectare`, `resolved_planning_physical_row_litres_per_100m`, `resolved_planning_concentration_factor`, `controller_litres_per_100m_travel`, `effective_working_width_metres`. Jobs carry only the first seven INPUT fields. No resolved-area-as-target substitution.
2. Omitted PATCH key = untouched; explicitNULL = clear. Declared input replacement clears obsolete input/output tuple atomically; historical absence stays omitted. `planningFieldsCleared` is local-only, never a database column. Completed/factual frozen evidence must not be rewritten by current template/catalogue geometry.
3. `planning_input_provenance`: schema_version1, tank_text/area_text/rate_text/volume_unit/area_unit/rate_area_unit/country_code. Preserve exact operator text independently from canonical numbers. Captured volume units litres/us_gallons/imperial_gallons; area hectares/acres; rate denominator includes hectare/acre/100m_travel/100ft_travel. Never use current country to reinterpret captured gallons. Controller rate is not trusted dilute reference.
4. Existing proposal error classification: SQLSTATE23514, `SPRAY_LABEL_AUTHORITY_UNVERIFIED`, `SPRAY_LABEL_RECIPE_INCONSISTENT`, `SPRAY_LABEL_CONCENTRATE_PROHIBITED`, plus a reviewed limit-exceeded classification if adopted by backend. Product identity in DETAIL and actionable HINT; integration also needs tank identity for mult-tank feedback. Exact PostgREST/operational-RPC JSON shape and HTTP mapping must be supplied with synthetic examples; current Android has BackendError.Server(code,body) but handlers mostly show generic status text. Do not classify permanent denial as network/offline or successful duplicate.
5. Idempotent success must identify the original client/record/operation ID and the accepted revision/payload, with actor/vineyard scope. On acknowledgement loss, read/receipt verification must distinguish same accepted operation from unrelated409, stale revision or denied recipe; no queue removal/publication without matching acknowledgement. Error/retry UI must retain payload/id/createdAt/attempt state.
6. Server must enforce the same authoritative admission across direct old-client record/job writes, generic Trip activation, saved-job activation, tank start and prepared-operation replay atomically before Trip/tank/inventory/labour/event effects. Client checks are not RLS/authority substitutes. Server must preserve legitimate manual factual history and already-established operation recovery, without a client-controlled historical bypass.
7. Reviewed dilute/reference/evidence semantics and currentness/revocation contract remain backend-owned. Supply a validated binding of product/revision/use/document digest/jurisdiction/conditions/reference and applicable limits; catalogue approval, saved-unit edits, displayed CF or a label range do not authorise concentrate execution. Do not invent a mobile Boolean authority field. Activation remains hard-disabled until the validated contract and mobile typed response/error integration are accepted together.

## Device/visual blockers

- No genuine iOS native preview screenshot/export renderer or connected process controller; retained synthetic SwiftUI previews compile but are not rendered acceptance.
- Android native-card renderer assertions passed; no pixel screenshot, authenticated Calculator journey or physical-device qualification claimed.
- Both platforms still need authenticated create/edit/save/reopen, real OS app kill/restart while offline, same-account recovery, cross-account isolation, reconnect to the approved backend, permanent-denial UX, acknowledgement loss/repeated replay and zero duplicate operational side effects.
- No screenshots were fabricated, no screenshot simulator rental was repeated, no schema/gate deployment, planning-write activation or app release occurred.

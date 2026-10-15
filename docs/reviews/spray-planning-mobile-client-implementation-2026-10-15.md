# Spray Planning mobile client implementation — 15 October 2026

## A. Outcome and source identity

**Substantial client components implemented and validated; full mobile completion is NOT achieved.** The new adapters/journals are not registered with production Save/Start/startup or existing projection stores. That is unfinished Rork implementation, not a database-access blocker. No operational-success or release claim is made.

Baseline/source HEAD: `ed74fae1e490be9e3c9a2730f2d1634de85d74c5`, plus this pass's managed native changes. Final managed commit is not yet exposed. SHA-256 of `git diff HEAD --binary -- ios android-vinetrack` at final native validation: `d8a4c77b97b74953f23f5e2225b24141aa82d84d0b78ec04169e87bfe81b4e25`.

Android build: package `com.rork.vinetrack`, version 3.1.7/code 11. New release APK SHA-256 `ece4143833e5b6f2804c687f8064b97b18a8c8b79e9094ebe55b58500f792154`. This is NOT the frozen Live Trip artifact. iOS simulator build passed; no signed handset IPA, TestFlight attribution or distribution.

### Added iOS components

Under `ios/VineTrack/App/SprayEngine/`:
- `SprayPlanningProtocol.swift`: typed operation/capability/recovery/request/receipt/result contracts, positive/frozen-output validation, explicit product basis and CF >=1 checks. Unknown label permission is not an admission condition.
- `SprayPlanningAttemptJournal.swift`: atomic protected Application Support file per actor/vineyard/incarnation, exact original request retention, intent/unknown/verified/repaired/complete/held/quarantined states, same-ID equality, exact receipt matching, revision-chain check and injected transport client. Entire original JSON recipe/Trip/geometry/chemical/dependency payloads are retained. No UUIDs minted during load/retry.
- `SprayPlanningSnapshotBuilder.swift`: freezes actual production SprayRecord/tank/chemical payloads; unbound save does not expose an executable Trip; changed recipe confirmation is rejected independently of label uncertainty.
- `SprayPlanningPresentation.swift`: distinguishes local/pending/receipt/repair/unbound/bound/ready/active states. Receipt verification alone is not user-visible completion.
- `SprayWorkAreaSelection.swift`: qualified repeated-pass identities, explicitly selected stable local IDs, frozen physical row facts, unknown geometry and stale selection detection. Over-Row retains one travel pass and two controller row equivalents.

Other iOS files:
- `ios/VineTrack/Backend/Repositories/SprayPlanningHTTPTransport.swift`: captured credentials, allowlisted RPCs, preserved HTTP status; not registered with production actions.
- `ios/VineTrack/App/SprayWorkAreaSelectionView.swift`: native whole-pass checklist, independent repeated pass selection, missing/unavailable geometry text and retained selections on return.
- `ios/VineTrack/App/SprayCalculatorView.swift`: Review exposes Planned Spray Mix, Selected Physical Work / Select Work Area, and Actual Spray Coverage separately. Existing operational gate, eight-step flow and concentration warning remain intact.
- `ios/VineTrackTests/SprayPlanningAttemptTests.swift`: 16 new tests.

### Added Android components

Under `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/spray/`:
- `SprayPlanningProtocol.kt`, `SprayPlanningAttemptJournal.kt`, `SprayPlanningClient.kt`: equivalent typed protocol, state machine, immutable receipts, original intent retention, scope quarantine and status-preserving controlled transports.
- `SprayPlanningNativeStore.kt`: AtomicFile replacement and read-back verification, scoped by actor/vineyard/incarnation and admitted through existing FieldStoreAccess. This production backend is compiled, but was NOT exercised on an Android device this pass.
- `SprayPlanningHTTPTransport.kt`: captured credentials; preserves 409 even when Ktor throws ResponseException. No legacy REST fallback.
- `SprayPlanningSnapshotBuilder.kt`, `SprayPlanningPresentation.kt`, `SprayWorkAreaSelection.kt`: production recipe snapshotting, confirmation equality, honest phase model and qualified whole-pass selection.

Other Android files:
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayWorkAreaSelectionSheet.kt`: Material 3 whole-pass checklist.
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt`: three separate Review concepts and selector integration. Selection is screen-local; complete calculator/process draft restoration is not claimed.
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/SprayPlanningAttemptTest.kt`: 19 new tests, including a real abruptly terminated child JVM.
- `.rork-tmp/calculator-completion.init.gradle`: includes new suite in the existing bounded host runner. Task up-to-date/cache reuse is disabled for test execution; compilation dependencies can remain cached.

## B. New executed evidence

| Surface | Latest result | Evidence boundary |
|---|---|---|
| iOS new journal/protocol/snapshot/presentation tests | 16 passed | Actual atomic file recreation and fault injection; controlled synthetic transport; not app termination/UI/server acceptance |
| iOS final focused selection | **56 passed / 0 failed**, 118 seconds | New 16 plus nearby SprayPlanningIntentTests, SpraySaveForLaterTests, SprayPlanningDraftTransitionTests. Skipped metric not exposed. Earlier overlapping 54/56 runs are not added. Final rerun includes stricter full raw JSON request/snapshot echo verification, including null-versus-omission protection. |
| Android final host selection | **187 passed / 0 failed / 0 errors / 0 skipped**, 15 suites | Includes 19 new tests plus existing 168. Final runner BUILD SUCCESSFUL in 2m54s. Final rerun includes raw request/snapshot null-versus-omission rejection and numeric JSONB formatting equivalence. Earlier overlapping 185/187-pass selections are not added. |
| Android new child-process test | Passed; included in 19 | Child writes original request and unknown state using fsynced atomic host-file replacement, calls Runtime.halt(73), parent independently reloads same IDs/full payload. Real JVM process termination, NOT Android app process termination and NOT production AtomicFile/device acceptance. |
| iOS simulator build | Passed | Latest runChecks after coherent source changes. Handset release build not verified. |
| Android release build | Passed | Latest runChecks after focused host execution. No store/upload operation. |
| Source-scoped whitespace / frozen-source check | Passed | No SQL, Edge, AppViewModel, TripsScreen, OccurrenceTraversalTracker or iOS TripTrackingService difference from baseline. |
| New native UI interaction/screenshots | **Unavailable, not accepted** | One simulatorUse call with allowDedicated=false failed: `Open this app's simulator preview first. Simulator use drives the preview you have open.` No retry, dedicated preview rental, credentials or data entry. |
| Authenticated RPC / handset acceptance | Not run | Levels 3 and 4 remain unaccepted. No backend calls or deployment attempted. |

The configuration test on each platform loops through six input variants (Single Row/Over-Row × By Area/Only Full Tanks target area/Only Full Tanks calibrated rate), and five operation kinds = 30 local contract cases in one test. It checks frozen values, raw input provenance, CF 2.00 with unknown label permission, receipt/request matching and encode/decode. It is NOT 30 executed server/UI journeys. Recovery and negative tests are separately exercised, not exhaustively multiplied through all 30 cases.

Other new assertions: failed write precedes HTTP; exact unknown retry; recipe/session identities; 409 held without acceptance; wrong receipt held (also rejects request/snapshot null-key presence changes before typed decoding); response loss followed by exact recovery receipt; existing record without receipt remains unknown; account/vineyard/incarnation quarantine; same UUID/different payload refusal; delayed old receipt leaves newer intent pending; idempotent repair callback; unbound receipt cannot claim ready; repeated labels/cross-block selections distinct; selection creates no coverage; stale tank confirmation rejected. Android additionally tests invalid CF and ambiguous chemical basis.

No new test assertion failed in the executed selections. Production snapshot/presentation components were added after the first selections, then final selections were executed. The pre-existing iOS alert-accessory UI failure was not worked around or rerun; it remains an independent Rork acceptance item. Existing five presentation improvements were preserved in source, not newly screenshot-accepted.

## C. Mobile completion matrix

| Area | iOS | Android | Remaining boundary |
|---|---|---|---|
| Typed v1 serializers, request identity, receipt verifier, controlled transport/recovery client | Implemented and tested locally | Implemented and tested locally | Exact backend wire conformance/authenticated acceptance pending |
| Durable attempt reducer and original full request retention | Implemented and file-recreation tested | Implemented and host-tested | Android production AtomicFile not device-tested; full app startup enumeration/account lifecycle not wired |
| Snapshot adapter using actual native record/tank models | Implemented and tested | Implemented and tested | Not registered with production actions |
| Physical whole-pass selection and three-concept Review | Implemented/build-tested, model-tested | Implemented/build-tested, model-tested | Native screen interaction, scope-change UI journeys, persistent full draft and saved-plan reopen not accepted |
| Over-Row treatment-context preparation | Implemented and tested | Implemented and tested | One travel pass/row equivalents retained; authoritative treatment-cell/face mapping requires backend R2 evidence |
| Unbound lifecycle/presentation states | Implemented and tested | Implemented and tested | No production saved-plan list/edit/reopen workflow wired to these receipts |
| Production Save/Replace/Bind/Start/Tank orchestration | **Not implemented for the new contract** | **Not implemented for the new contract** | Rork must bind journal preparation, auth incarnation, startup recovery and revision-CAS repair to existing native stores and tank coordinator. Keeping the gate closed is not a substitute for this work. |
| Factual tank/Trip recovery | Existing authority preserved; new adapter carries effects as evidence only | Same | Actual production idempotent repair/dependency callbacks and failure-boundary acceptance remain Rork work |
| App OS kill/offline relaunch/reconnect | Not accepted | Not accepted | Store recreation/host JVM halt are not mobile OS process evidence |
| Server operation execution | Awaiting backend acceptance; disabled | Same | No installed/enabled RPC capability claimed |

**Not satisfied:** complete process-restorable production attempts, full unsaved calculator draft restore, revision-aware projection repair into existing stores, automatic startup recovery coordinator and all configuration × lifecycle × failure native journeys. No attempt is made to disguise those as backend-only blockers. The journal API's repair callback must be supplied by production integration and must be idempotent/current-revision fenced; a test closure returning true is NOT proof that recipe/Trip/tank effects were repaired.

## D. Consolidated exact backend handoff — ChatGPT/backend owner

Rork will not request database access or run the historical catalog capture script. L1/R1/R3/R4/R5 are settled. The dedicated ledger/writer is assumed as approved DESIGN, not installed capability.

### Wire binding implemented in both clients

- JSON property names are camelCase as declared in `SprayPlanningProtocol.swift` / `.kt` (except RPC parameter names). Five mutation RPCs accept `{p_operation_id: UUID, p_request: Request}`. `Request.operationId` must equal p_operation_id.
- `get_spray_planning_capability_v1`: `{p_vineyard_id}` → Capability with contract, schemaVersion, vineyardId, enabled, migrationId, validationSuiteId, digestAlgorithm, operations, occurrenceVersion, tankVersion. No client flag enables production; missing/malformed/disabled response leaves original intent retained and sends no mutation.
- Mutations: `save_spray_plan_v1`, `replace_spray_plan_v1`, `bind_spray_plan_route_v1`, `start_spray_plan_v1`, `start_spray_plan_tank_v1`. Kind strings: save_plan / replace_plan / bind_route / start_spray / start_tank.
- `get_spray_planning_recovery_v1`: `{p_vineyard_id,p_operation_ids,p_record_ids,p_trip_ids}` → `{contract,schemaVersion,actorId,vineyardId,receipts,currentState}`. Current state is separately labelled JSON and never acknowledgement. Missing receipt is unknown. Exact retries must recover original immutable result rather than rebuild it from current rows.
- Receipt fields: contract, schemaVersion, operationId, actorId, vineyardId, full ORIGINAL typed request, digestAlgorithm, canonicalRequestSHA256, recipeSHA256, serverRevision (positive Int), acceptedAt, typed result. Digests are lowercase 64-hex server canonical digests under pg-jsonb-text-sha256-v1, not client JSON byte hashes.
- Result fields: recordId, nullable tripId, recipeRevisionId, nullable routeRevisionId/tankSessionId/actualUseId, phase, original frozen snapshot, establishedEffects. Phase strings: saved_unbound, bound, ready, active. An unbound save result must have no executable Trip and phase saved_unbound. Binding cannot be active. Start/tank result must be active; their recipe digest must match captured expected digest.
- Snapshot carries all IDs and previous revision/digest, original planning inputs, frozen outputs, chemical lines, equipment, geometry, nullable route, complete originalRecord/originalTrip, reviewedActuals and dependencies. Chemical index includes tankId/tankNumber/lineId, explicit rateBasis, quantity/unit and full originalLine. Original native record/Trip JSON is audit evidence, NOT a REST payload to forward blindly: Swift native Codable records/dates/UUIDs and Android column-mapped records differ. Implement authoritative normalisation from typed planning/chemical/geometry fields with an explicit native-evidence codec agreement. No client projection from current catalogue/geometry is permitted.
- The current immutable revision/result/digest/phase shape is a client integration binding, **not a claim that the owner's final RPC signatures are already installed or accepted**. Supply canonical golden accepted/error/recovery fixtures for these exact DTOs, or one explicit field mapping for Rork to adapt before authenticated tests. Supply exact route/tank compatible contract versions and establishedEffects schema; these must preserve existing actual/session effect keys.

### Server responsibilities affecting acceptance

1. Enforce actor/current membership/vineyard and complete immutable request equality; atomic recipe/revision/ledger commit; same-ID different payload conflict; original receipt on exact retry; consistent 409 errors. Do not use row existence/unique violations as success.
2. Confirm unbound save creates no executable Trip/effects, replace requires expected immutable revision/digest, bind yields authoritative route revision, start and tank validate those dependencies. Preserve existing factual effects in recovery, even if current planning eligibility fails.
3. Return canonical request/recipe digests and exact committed IDs/snapshots. A later current revision must never be substituted into an original receipt. New effects require proven atomic/idempotent integration with existing Trip/tank/actual/labour/inventory authority.
4. Supply accepted R2 route certificate/physical treatment mapping, geometry revision and area basis, whole-pass stable identities, retired/changed geometry behaviour and Over-Row treatment context. No client hectare tolerance, auto-selected work or duplicate completion will be introduced.
5. Own schema reconciliation, 14/7 column installation, immutable ledger/writer/security/direct-write guards, source-compatible lock order (including Spray before Trip), historical/manual/legacy preservation and authenticated nonproduction security/fault-injection/cross-platform evidence. This list assigns interfaces; it is not a request to rediscover known schema absence.
6. Keep capability disabled until installation and agreed acceptance pass. Do not make label permission or unknown concentrate approval an error at Save/Start/Tank; retain CF>=1 and independent invalid-dose/rate-basis safeguards. No client error mapping turns CF permission into a hard block.

## E. Preferred R2 proposal — certified treatment-cell union

Use server-versioned, non-overlapping certified treatment cells in an approved metric CRS, derived from surveyed row geometry, row boundaries, block/headland clipping and explicitly modelled treated vine faces. A physical whole travel pass binds an ordered list of treatment-cell/face IDs plus frozen block/path identity and geometry revision. Over-Row is ONE travel occurrence with its genuine treatment-cell context; row equivalents are controller facts, not area or completion multipliers.

The server computes the union of selected certified footprints, counting overlapping/repeated treatment cells once for planned physical area. Repeated travel identities remain distinct for intended execution; selection still creates zero actual coverage. Missing cell boundaries, uncertified outer paths, cross-block ambiguity or changed geometry prevents binding. Numeric row labels and current spacing are not substitutes.

Compare planned mix area with the certified union using the **same published canonical decimal area and declared survey/area precision**, not a newly invented hectare tolerance. A mismatch is blocking: the operator explicitly revises mix inputs or selected whole passes. Do not silently rescale doses, auto-select passes, cut segments or turn mismatch into advisory. Return the area algorithm/precision/CRS, geometry digest, selected identity digest and certificate revision in the authoritative binding receipt; both clients display the certified value and retain it without recalculation.

Smallest remaining owner decision: approve the physical-area authority as **unique certified treatment footprint counted once**, including repeats, rather than cumulative travel-equivalent or gross selected-block hectares, and approve its declared precision/equality rule. ChatGPT/backend then specifies exact geometry/cell certificate fields. This is one specific R2 proposal, not a reopened L1/R1/R3/R4/R5 decision. Until approved/implemented, route admission remains unavailable.

## F. GO / NO-GO

- **Local client components: GO for further native integration/testing**, not full mobile readiness.
- **Complete mobile client readiness: NO-GO** — production startup, action wiring and receipt-to-existing-store repair still unfinished on both platforms.
- **Authenticated server integration: NO-GO** until backend supplies final DTO fixtures/contract and approved nonproduction authority; there is no operational ledger/capability claim.
- **Full workflow: NO-GO**, independent operational gate remains closed. Legacy paths unchanged.
- **Physical handset acceptance: NO-GO / unexecuted.** No authenticated screenshot, GPS, keyboard or app-process kill/reconnect evidence added.

## G. Remaining actions and owners

1. **Rork:** wire production Save/Replace/Bind/Start/Tank, stable auth-incarnation/startup discovery, current-revision CAS projection repair and existing tank/factual dependency coordination. Restore saved/unbound plan editing and full local calculator drafts without manufacturing Trips/IDs.
2. **Rork:** device-backed AtomicFile tests, real native UI/failure-injection journeys and app kill/offline/reconnect tests; configuration/failure cross-product; clear existing iOS alert-accessory acceptance failure. Verify the five presentation improvements and complete new Review with actual screenshots when an existing preview is available.
3. **ChatGPT/backend:** final exact wire/golden fixtures, R2 certificate contract, ledger/RPC/security/legacy implementation and approved nonproduction authenticated acceptance. Owner approves only the narrowly stated remaining R2 area-authority decision.
4. **Handset acceptance:** physical iOS/Android keyboard/layout/GPS/offline/tank/cross-device operations after native/backend gates pass. No release until separately approved.

No production SQL, Supabase credentials/access request, catalog inspection, deployment, gate activation, distribution, frozen Live Trip source change, history rewrite or calculation/dose change occurred.

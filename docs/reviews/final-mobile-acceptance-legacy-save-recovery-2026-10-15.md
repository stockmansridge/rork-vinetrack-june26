# Mobile source closeout / legacy Save for Later — 15 October 2026

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

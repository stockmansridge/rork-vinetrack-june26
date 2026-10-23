# Mobile source closeout / legacy Save for Later — 15 October 2026

## Android Internal Testing delivery — 23 October 2026 (current checkpoint)

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

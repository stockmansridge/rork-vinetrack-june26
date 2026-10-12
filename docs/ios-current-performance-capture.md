# VineTrack iOS current-source performance capture

## Status and scope — 2026-10-12

Build 165's missing symbols are not a prerequisite. Its nine reports establish main-thread JSON and text-layout signatures, not particular current functions or screens. No release or TestFlight upload has been performed.

Current production source still synchronously loads and encodes whole collections through MainActor PersistenceStore. MigratedDataStore construction/reload loads Trips, Pins and Work Tasks; GrowthStageRecordSyncService construction loads observations and embedded-photo work. Trip slice updates read and rewrite the all-vineyard history, including GPS arrays. Pin/Growth photo queues encode embedded Data. These paths are source-confirmed, not attributed to the historical incidents.

The bounded correction adds exact-disk-byte decoded snapshot reuse for Trips, Work Task headers and Growth records within the existing shared 24 MiB encoded-byte budget. Legacy generated route/seed IDs and missing task dates are excluded. Disk is still read on every authoritative load; changed/missing/corrupt data cannot hide behind a memo. Existing synchronous atomic saves, acknowledgements and business logic are unchanged. This does NOT eliminate first-construction decoding, changed-payload encoding, disk IO, or large payloads above the memo budget. First Trip/Work Task reads additionally validate legacy decoder eligibility; capture their cold/first-load cost rather than assuming it improved. The encoded-byte budget is not a heap-memory bound.

Worker preparation now supports those audited collections and performs eligibility validation on the worker. Tests exercise it; ordinary startup still constructs stores synchronously. Do not describe test-driven preparation as automatic off-main startup hydration.

## Build 166 attempted — archive failed before upload (2026-10-12)

- Apple reauthentication completed; signing setup and distribution certificate ready. `ensureApp` reused ASC app6761143377 (`created:false`). Capability sync made no changes (`enabled:[]`, `disabled:[]`, `capabilitiesChanged:false`). Final exact166 lookup remained empty and entire iOS diff against the approved correction remained empty before submission.
- One `submitBuild` invocation requested unchanged VineTrack iOS3.1.7/build166, original bundle/team/app and `xcodeProjectPath:ios`. Submission **`725a8394-eb31-4e67-bd81-29e2110744cc`**, workflow **`38199326271`**. Server reports `archiveSource:supplied-snapshot`; no immutable snapshot ID/content hash was returned. Pre-submit managed HEAD/iOS tree are recorded below; do not claim an independently verified artifact-to-source mapping or invent a publishing buildId. Actual source snapshot identifier must be supplied by build-service evidence if required.
- Terminal status **error / failed**, updated2026-10-12T03:25:34.234Z. Release-iphoneos arm64 Swift compiler crash: Xcode26.4.1, Apple Swift6.3.1, effective Swift5.10, `EarlyPerfInliner`, generated `CatalogReadSingleFlight` deinit, `CatalogReadSingleFlight.swift:6:13`, `isCallerAndCalleeLayoutConstraintsCompatible`. Status metadata says xcodeMajor27 but actual compiler path says26.4.1; actual archive log is the observed toolchain evidence. No ordinary type-error or signing failure established.
- Post-failure ASC exact3.1.7/166 query still returns zero builds. **166 is not uploaded, processing or available in TestFlight.** No completed IPA/archive/dSYM download returned. No retry or code/build-setting workaround under this unchanged-source approval. Prior simulator validation is not Release archive success.
- Existing groups/public-link settings untouched; no testers added, external assignment, production review/release or Android work. Preserve installed165 and finish baseline captures where possible. Next requires separately approved narrow compatibility work or managed build-toolchain correction, not disabling Release optimisation or changing performance logic silently.

## Approved build 166 — source verification and signing checkpoint (2026-10-12)

User approves **iOS 3.1.7 (166), existing TestFlight testing only**, not production review/release. No application/performance code, diagnostics gates, bundle ID or data formats changed.

- GitHub `stockmansridge/rork-vinetrack-june26` main resolved to `5dc1ad036c5450fb075c3a67ceebb0bbd1e09150`. All 12 manifest files are byte-identical to approved correction `64fbafb62960e198f5c637be1531846db0239105` (exact Git blob/content diff empty). Capture procedure also matches current managed document, blob `20f74291b583b8711bf058d336ade330f4c8d52d`, before this new checkpoint text. External GitHub delivery is now verified; different commit SHAs are not source differences.
- Preflight managed HEAD `29dd78594eb9ac11ac0145baba04896ccd924515`; iOS tree `7c5a19decdbdaa3192569b424d17eb9ac7911fe2`; clean application tree and no iOS differences from the approved correction. External tree differs only by generated Config.swift, not performance code. The actual server-pinned submission snapshot will be recorded after signing readiness; these Git identifiers are not a fabricated publishing buildId.
- ASC exact build166 query returned zero builds; no active managed duplicate. Recheck immediately before submitBuild with explicit buildNumber166. Existing Internal Testing group has all-build access; do not add testers/groups or assign166 externally. External Tester already has a public link; leave its configuration untouched, do not add this candidate to it.
- Signing setup explicitly reported **expired Apple Developer session**. Reauthentication required before certificate/capability/build steps. Build166 is **not yet built/uploaded/available in TestFlight**. No archive/dSYM exposed yet; their absence will not block testing. Prior successful simulator validation covers unchanged app source, not signed-device availability.

The preparation checkpoints below are historical; latest approval/source verification above supersedes their awaiting-approval/unverified-GitHub statements.

## Next physical-iPhone milestone — preparation checkpoint (2026-10-12)

### Source and delivery identity

- The 12-file iOS correction and initial 79-line procedure are committed in `64fbafb62960e198f5c637be1531846db0239105` (commit time `2026-10-12T02:49:41Z`, whole-workspace tree `bcd9da05127eeb3b5b7a2cac31bc671073ca37cd`). The commit is not iOS-only; the iOS correction is the exact manifest below. Building `ios` does not build or distribute Android.
- Read-only `git ls-remote origin refs/heads/main` matched that commit. Implementation and procedure had no working-tree differences from it at this checkpoint. The original document blob is `be1c98e5bbe282f7f378df48b3d383a02d814a82`. This updated handoff is a subsequent documentation-only change; do not attribute its new text to the earlier commit.
- The inspected origin is Rork's managed project remote, not GitHub. No external GitHub remote/submodule or verified mirror receipt is available here. Rork manages synchronization; no manual commit/push is performed. External GitHub availability is **unverified**, not failed. To close this item, supply the connected repository URL or confirm these exact files on its main branch. If mirror SHAs differ, compare the 12-file contents and document, not commit subjects alone. Do not create a second source submodule merely to export this project.

### Build and TestFlight approval boundary

- Preparation `runChecks(appPath="ios")` passed again against the unchanged correction: **simulator build succeeded; signed device build unverified**. No new test run was needed; the accepted 139 passes remain synthetic/store-seam evidence. No downloadable signed IPA, xcarchive or matching dSYM was exposed by this result.
- Read-only App Store Connect setup resolved VineTrack, app `6761143377`, bundle `app.rork.nt0v48tayl7v8noxcfe74`, team `8Y879855VK`. The latest observed iOS 3.1.7 build is **165**, VALID. Proposed candidate is **3.1.7 (166)**, subject to user approval and a fresh collision check immediately before submission. Project configuration still says build 139; a publishing build-number override must be explicit. Do not upload 139 or label a simulator artifact 166.
- The managed signed build operation also uploads to App Store Connect and triggers the existing TestFlight invitation handling. It has no documented build-only/archive-only switch. Therefore the actual iPhone candidate is **awaiting approval**, not already built or distributed. API-key readiness does not establish a valid signing session.
- Approval requested: **build and upload VineTrack iOS 3.1.7 (166) for TestFlight performance testing only, using the unchanged iOS correction; no production review or release**. Test-only means distribution scope, not a changed bundle ID, separate installation, disabled persistence or altered field behaviour. Do not enable automatic candidate updates until baseline captures are complete.

After approval, use this exact sequence:
1. Recheck latest build number, correction source and unchanged `ios` tree; record the managed submission's pinned snapshot/source identifier. Confirm version, bundle, team and selected `ios` app. Any unrelated iOS source change requires review rather than silent inclusion.
2. `setupAsc(requireAppleSession:true, appPath:"ios", teamId:"8Y879855VK")`; resolve any actual session/agreement issue normally. Then `ensureCertificate`, `ensureApp` for VineTrack/iOS/3.1.7, and `syncCapabilities` with `xcodeProjectPath:"ios"`. Stop on unsupported capabilities; no feature removal or entitlement changes by implication.
3. `submitBuild` for those confirmed identities, explicit approved `buildNumber:166`, `xcodeProjectPath:"ios"` and the app ID from `ensureApp`. This is the approval-gated upload; retain the returned submission ID and actual version/build/source evidence. If 166 is occupied, agree a new number before using it.
4. Read the exact uploaded build and wait for VALID/available-for-testing status. The backend handles the TestFlight invite; do not add groups/testers, public links or expand the audience by default. If the invite is missing, inspect the existing invitation/group route before an explicitly approved fallback. External beta review, if required by Apple, is not production App Store review.
5. If the service exposes archive/dSYM/IPA links, retain the actual files plus hashes and verify binary/dSYM UUIDs as below. If unavailable, record that limitation and continue testing. Do not request build 165 symbols or delay the candidate solely for symbols.
6. On the iPhone install/open Apple's TestFlight app, accept the existing VineTrack invitation, select the **exact candidate version/build**, then update the existing VineTrack installation while idle. Do not delete the app, change bundle IDs, sign out or clear data. Verify the diagnostics report's version/build agrees with TestFlight. Stop if TestFlight requires removing the existing app or cannot offer that build; resolve distribution rather than reinstalling.
7. Do **not** call `submitReview`, select this build for a production release, or change App Store rollout settings. TestFlight availability is not performance acceptance.

### Diagnostics-to-evidence map

| Required distinction | Existing evidence | Boundary |
| --- | --- | --- |
| Startup / first vineyard | `startup membership and default vineyard`, `store global load and repair`, `store selected vineyard hydration`, scene/Home markers | Async spans include waits; early instrumentation begins when first reached, not OS launch. Video measures launch-to-usable Home and vineyard selection-to-usable data. |
| Initial / repeated JSON | Per-dataset `read`, `codec`, `decodeReused`, `bytes`, occurrence and `main` | First read in a process may decode; repeated reads only reuse eligible identical bytes under the budget. Reopening a screen need not issue a persistence read. No event is not proof of zero cost. |
| Trip / Growth / Work Task preparation | Fixed `viewPreparation` filter/order labels with occurrences, records and elapsed time | These are aggregate pure computations, not complete screen rendering or every formatter. |
| Photo queues | `pinPhotos` / `growthPhotos` read/save/durableSave codec and occupancy rows | A read-only run may have no encoding. Exercise writes only in a separate synthetic smoke run; never resave customer photos to produce events. |
| Touch-affecting main work | Synchronous `main` / `longMain=yes` at 100ms; foreground queue delay | 100ms is a prioritization threshold, not exact touch latency. Queue sampling can miss early startup and short stalls. Use video and traces for unexplained freezes. |
| Repeated SwiftUI / text work | Preparation occurrence counts; screen/scroll interval in video | **No CoreText/layout caller attribution** in the report. Repeated computations do not establish repeated expensive layout. Use Instruments Hangs/Time Profiler/SwiftUI trace or a current device hang report before modifying a row/formatter. |

No extra text/layout instrumentation or optimization was added in this milestone. First-load preparation remains the next candidate **only after device evidence identifies the dataset/operation**.

### Six-run evidence sheet and acceptance decision

Before updating, capture baseline `B-C1..3` and `B-W1..3` on the currently installed build if still possible; after updating capture candidate `C-C1..3` and `C-W1..3`. Cold means process terminated **while idle**, retaining all application data, not a fresh install or guaranteed cold filesystem cache. Warm means the same process returns after 30 seconds backgrounded. The first candidate launch that enables diagnostics is setup, not a fully captured cold run. Existing opt-in must already be armed before the measured cold launch.

For each run retain a separate report and video with: actual build/source, device/OS, network, start power/storage/temperature, run kind, launch/resume-to-usable Home, first vineyard-to-usable data (if selection occurs), first/repeat Trips/Growth/Work Tasks/Pins tap-to-usable, refresh completion separately, per-dataset first/reused read codec/main times, photo-queue codec/main where actually observed, longMain events, main-queue delays and dropped/unfinished-event counts. Note unchanged data or any sync-driven changes. Keep admin/export overhead outside measured intervals. Do not sum nested store/sync/persistence spans as independent time.

| Evidence | Before | Candidate | Current conclusion |
| --- | --- | --- | --- |
| Physical three cold / three warm runs | Not supplied | Not supplied | No measured iPhone gain yet |
| Physical GPS/Trip/tank/Pin/offline/restart smoke | Not supplied | Not supplied | Field acceptance pending |
| Realistic synthetic selected regressions | Not a paired physical baseline | 139 accepted passes | Correctness evidence at tested seams only |
| Exact-byte Trip reuse | Not a handset timing | Codec execution skipped in test | No startup or percent speedup claim |
| Fresh preparation build | Not a baseline benchmark | Simulator checks passed | Signed TestFlight candidate awaits approval |

If only candidate runs are supplied, report current absolute timings and identified operations; do not invent a before/after percentage or substitute historical 2.624–5.785s incident durations for matched launch times. For matched physical pairs report all three values, median and range for cold and warm separately. The user and reviewer must agree whether the observed usable-time reduction is worthwhile; green tests alone never close this milestone.

Physical field checks are recorded **pass/fail/not exercised**, with private local record identity/value comparisons (do not add field IDs/contents to numeric diagnostics):
- Existing cached records remain visible before/after the in-place update, idle restart and offline navigation; pending items stay present. Counts alone cannot prove no overwrite.
- Finish a synthetic GPS Trip through normal pause/resume/end flows, confirming route continuity and tank quantities/history; restart only once it is idle. Compare its saved identity and values, plus unaffected existing history.
- Synthetic Pin and linked Growth observation/photos remain linked and visible after offline save, idle restart and reconnect; check only one intended record and original attachments, not merely a nonempty list.
- Compare Work Task labour/machine/material quantities and calculated totals before/after save, restart and sync.
- Verify ordinary acknowledgements and local/remote records: no missing/duplicate identity, unexplained value change, overwrite or lost pending photo. Any discrepancy stops acceptance; preserve the installation and evidence, do not clear/reinstall/retry destructive actions.

When evidence establishes a costly first-load operation, the next bounded change may prepare immutable bytes/values off-main only. Before publication revalidate exact current source bytes, account/session/vineyard and load/lifecycle generation, cancellation and fresh pending overlays. A stale result is discarded, never persisted over newer field work. Atomic saves/acknowledgements stay ordered and synchronous/awaited; no detached writes, startup worker wiring by assumption, schema change or Android-auth work. CoreText changes require a responsible current view/formatter trace first.

## What the capture measures

Settings → System Admin → Performance Diagnostics retains the existing fresh-admin authorization and opt-in gates. It records only fixed operation/dataset labels and numbers, not keys, IDs, names, contents, photos, locations or credentials. No automatic upload.

- Whole-payload bytes and record count, read/codec/write durations, success and exact decode/encode reuse.
- Full synchronous main-actor wall occupancy (`main`), including disk IO and eligibility validation; `longMain=yes` at 100 ms. This is not sampled CPU time.
- Per-category/operation occurrence counts. Increasing occurrences show processing frequency, not proof of duplicate identical data.
- Worker preparation `offMain`; report delivery itself is on main. Worker codec elapsed includes eligibility validation.
- Aggregate Trips filter/sort, Pins ordering, Work Tasks filter/sort and Growth summary-block ordering durations. These do not measure SwiftUI/CoreText glyph layout or completed frames.
- Existing foreground main-queue delay sampling. It can miss stalls before authorization/foreground sampling starts and is not an exact Apple hang detector.
- Low Power Mode, thermal state and filesystem free bytes **at export**, not a historical sample of each operation. Record run-start conditions separately.

The 2,000-event memory buffer is lost on termination. A report with dropped events is incomplete for cumulative analysis; shorten the run and repeat only while idle. Export/admin verification and displaying the report have their own overhead: keep them outside the navigation measurement interval. Existing admin gating means ordinary non-admin users cannot use this capture.

## Safe matched-iPhone procedure

1. Keep the installation and field records intact. Do not uninstall, clear data, sign out, downgrade, or terminate active GPS/Trip/tank/photo work. Use a dedicated synthetic test account/vineyard for mutation smoke tests. Do not seed/delete customer data to make a benchmark.
2. Identify each artifact by its actual source snapshot/build identity, not version label alone. Before any candidate update, capture three idle process-cold launches and three warm returns on the currently installed baseline. Existing baseline diagnostics may lack new fields; compare video and common markers only in that case. Equivalent numeric before/after fields require a separately built instrumented baseline; one candidate report is not a paired baseline.
3. Match the same iPhone 13 Pro, OS, account/vineyard, record counts and approximate payload sizes, network, temperature and storage conditions. Use adequate free storage and Low Power Mode off for the primary comparison. Do not deliberately fill storage. If testing Low Power Mode, run a separate matched pair with it on; do not combine those numbers with the primary comparison. Preserve the historical low-storage context without assuming it caused every hang.
4. While online and idle, enable capture in Settings → System Admin → Performance Diagnostics. Enabling resets the buffer; leave it enabled across a cold launch so early numeric capture is armed. Screen-record the launch and each navigation. Video can contain personal data: use synthetic data or keep it private/redact before sharing.
5. For each cold run, terminate only while no field operation is active, reopen, wait for usable Home, open Trips, Pins, Growth Stage Records and Work Tasks. Scroll each normally, return Home and reopen each once. Do not reset capture between first and repeat navigation. Record time-to-usable controls separately from refresh completion; an appearance marker is not a usable-frame assertion.
6. Export each run online before the next termination: Refresh report → Share timing report. Note run number, cold/warm, baseline/candidate, build/source identity, network, Low Power Mode, free storage and thermal conditions outside the numeric report. Export remains fresh-admin verified. For warm runs reset capture while idle, background for 30 seconds, return, and repeat navigation three times across separate runs.
7. After preloading local data, perform a separate idle offline launch/navigation run. Return online before opening/verifying/exporting diagnostics. Never kill an active Trip to create a cold run. An authorization failure may clear the numeric buffer; label that run unavailable rather than treating missing rows as zero.
8. Compare individual values/ranges and medians from three matched runs. Track long synchronous main operations and main-queue delays; sum processing by dataset within matched intervals without double-counting nested spans. `codec=0` on a reused read does not mean the whole read is free. Report unmatched dataset/network/condition changes and missing metrics honestly.

## Synthetic functional smoke — physical checks still required

- Create/edit a Pin with photo and linked Growth observation; verify original IDs, coordinates, image bytes/display and Growth link/stage.
- Record a short GPS Trip; check pause/resume, route continuity, device ownership, tank start/confirm/close and actual-use values through normal flows. Do not terminate it while active.
- Create/edit a Work Task with labour, machine and materials; compare all displayed costing outputs and permissions against baseline.
- Repeat supported actions offline, background/return and verify pending states. Finish active field work using normal rules before an idle restart. Reopen and verify stored records/photos/links and absence of loss or duplication.
- Reconnect, allow ordinary sync, and compare IDs/values/quantities and pending acknowledgements. Check vineyard navigation and local/remote agreement. Record actual pass/fail; simulator store recreation is not OS process-kill or live-server acceptance.

## Symbols and optional Instruments for a future approved physical build

The managed checks in this change produced a simulator build, not a verified signed physical-device archive or TestFlight release. The tools did not return a matching dSYM/archive download, so symbol retention for those remote artifacts is NOT certified. Release configuration already requests `dwarf-with-dsym`; that setting alone is not evidence of retained files.

For a separately approved Xcode development archive/device build, preserve the **entire generated xcarchive**, its original app binary and `dSYMs/VineTrack.app.dSYM` together, outside transient DerivedData. Record source snapshot, actual version/build, device architecture, artifact hashes and build configuration. Verify the app binary and dSYM UUIDs match using `xcrun dwarfdump --uuid <binary>` and `xcrun dwarfdump --uuid <dSYM>`, then verify the retained copies. A simulator dSYM cannot symbolicate a physical-device incident. Do not rebuild later and assume the new UUID matches. No build 165 symbol retrieval is needed.

If connected to a Mac, profile the same safe idle/matched navigation using Instruments Time Profiler, Hangs and SwiftUI profiling where supported. Preserve the trace with the matching archive. Correlate source/operation timings with the sampled main-thread callers and layout updates before changing a specific row/text layout. No connected physical iPhone or Instruments is available in this coding sandbox.

## Observed validation, not physical acceptance

- Initial persistence/diagnostic selection: 21 passed, 1 failed; new Growth fixture used fractional default observation timestamps, which the existing ISO-8601 codec truncates. Fixture changed to the same explicit whole-second timestamp as the rest of the record; production codec and assertions retained.
- Final selected persistence/diagnostics, Pin photos, linked deletion, route recovery, device Trip ownership and tank lifecycle: **59 passed, 66 s**.
- Work Task full pull/labour/machine/material costing and sync queue regression selection: **80 passed, 21 s**.
- Managed iOS checks: **passed; simulator build succeeded**. Signed device build and physical responsiveness remain unverified. Two pre-existing asset-address advisories are unchanged.
- New test workloads: one Trip with 60,000 route points, tank state, operator identity and seeding precision; 2,000 Work Tasks; 2,000 linked Growth observations. Tests assert exact values, changed-byte invalidation, corruption visibility, legacy decoder exclusions, independent restart reads, actual worker execution and continued durable-write failure propagation. Existing photo-bearing persistence tests remain.
- Reused Trip reads execute no JSON decode (`codecMilliseconds == 0` asserted). Actual iPhone stall improvement in milliseconds/percent is **not measured**. Test benchmark prints were not returned by the managed result log, so no numeric wall-time speedup is reported.
- First-construction JSON, changed photo/history encoding, Work Task child decoding, CoreText layout, UI navigation, live sync and real interruption/low-storage outcomes remain profiling/device checks. No historical function/screen or specific text-layout cause has been invented.

## Exact changed-file manifest

Under `ios/VineTrack/`:
- `App/PerformanceCapture.swift`
- `App/PerformanceDiagnosticsView.swift`
- `LegacyImported/Repositories/LegacyStorage.swift`
- `LegacyImported/Repositories/PersistenceDataset.swift`
- `LegacyImported/Repositories/PersistenceDecodeEligibility.swift`
- `LegacyImported/Repositories/PersistenceDecodePreparation.swift`
- `LegacyImported/Repositories/PersistenceMeasurement.swift`
- `LegacyImported/Views/Trips/TripView.swift`
- `LegacyImported/Views/Pins/PinsView.swift`
- `LegacyImported/Views/Tasks/WorkTaskLogView.swift`
- `LegacyImported/Views/Phenology/GrowthStageRecordsListView.swift`

Also `ios/VineTrackTests/PersistencePerformanceTests.swift`, this requested capture procedure and the existing `.rork/plans/make-vinetrack-fast-on-every-open-with-s_1791595857066.plan.md`. No Android, Supabase/SQL, authentication, business-model, schema or release changes.

# VineTrack Android handset performance handoff

Prepared 2026-10-10. Test-only handoff: no development, new builds, instrumentation backport, migration, release, deployment or device installation performed. The handset does not need to connect to Rork's build environment.

## 1. Artifact register — do not substitute version labels for identity

### Candidate C: existing release-variant APK
- Existing file: `android-vinetrack/app/build/outputs/apk/release/app-release.apk`.
- APK SHA-256: `4dc92e8573b15d18f1223d4108ae067a841c07c41a785d4440ac5cdeee70941a`.
- Verified APK signature certificate SHA-256: `241548efe6df8100c833d4eaebd2b3cf22dd70ffb638d9faa77bbd03f0077ef3`.
- APK manifest verified with aapt: package `com.rork.vinetrack`, version `3.1.7`, code `10`, min API 24, target API 36; arm64-v8a/armeabi-v7a/x86/x86_64. Non-debuggable release variant. This is NOT proof of Play distribution or release approval.
- Current recorded source revision: `10fbf9805fab13f0d0cdc1ae89e6250dfd9bed98`.
- Android directory Git tree: `cc9066dc04f1511bbafa8fd4e6d22976aa2a5957`.
- That Android tree is identical to the completed Trip Start delivery revision `f4eec4a51d5988c9349d425796db93cb02d185ce`; there are no outstanding Android source changes. The prior managed release build passed after the Trip Start correction. The APK does not embed an exact Git revision, and no independent build-to-source attestation/download record was found: this is the recorded corresponding source, not cryptographic proof that every compiled input came from that tree.
- Candidate source includes early cache display/off-main read preparation, in-flight public catalogue sharing, five permitted concurrent Work Task reads and numeric timing/GET/body-byte diagnostics. It also includes the intervening targeted reliability/auth changes. It is not a performance-only build.
- No verified external download URL is available in this handoff. Retrieve the existing file above through the project/build owner or its retained build artifact. Transfer its unchanged bytes privately to the tester. Verify the receiving file against the APK and certificate digests above. Do not start a new build/export/publish operation merely to create a link under this request. If the workspace file cannot be retrieved, acquisition remains pending; do not invent a download URL.

### Baseline B: source comparator identified; APK not supplied
- Proposed comparator immediately before the approved cache-first/catalogue/diagnostics slice: `bcfcac2f81650c7c1a7a58908a69e382f2fd9fd4`.
- Android directory Git tree: `0350191a1526c29aefda2e797348326475240fc9`.
- Source declares package `com.rork.vinetrack`, version `3.1.7`, code `10`. This is source metadata, NOT verified baseline APK metadata.
- This is the parent of `30a78be3dffe0b462ab71fb3a8984acc95a51ae2`, which introduced AdminPerformanceCapture, PerformanceDiagnosticsCard, scoped catalogue single-flight and early cache publication; off-main preparation and Work Task overlap followed. Earlier historical optimisations may already exist in B. B is not certified as the last shipped/stable build or an entirely unoptimised app.
- Baseline APK location/download URL, APK SHA-256, signing certificate and artifact-to-source mapping: **unavailable**. Request an already-retained release-variant APK for this exact revision and its build provenance from the developer/build owner. Do not use the Stage1B debug/test APK, Stage1C harness, arbitrary Play APK or the current debug APK as B.
- No baseline rebuild is authorised or performed here. If no matching retained APK exists, run candidate-only captures/smoke now and mark paired comparison pending a separately authorised artifact step. A baseline hash cannot be derived from its source hash.

**Pair readiness:** not yet a fully downloadable verified pair. C bytes are identifiable locally; B bytes and both external artifact retrieval paths still need the developer/build owner. Both source version labels reuse 3.1.7/code10; they cannot distinguish the builds. Historical B and C include non-performance differences, so report an observed whole-build difference, not a performance-only causal result.

## 2. Diagnostics equivalence

They are **not equivalent**. B's source has no AdminPerformanceCapture/PerformanceDiagnosticsCard/ReadTrafficLedger. C's source has timing phases, Work Tasks preparation/publication/appearance and shared-client GET totals. Validate that the delivered C exposes these controls with the authorised test admin; source presence is not a completed runtime test.

| Evidence | Reliable paired comparison once B artifact is verified? |
| --- | --- |
| Video launch/resume to usable Home; first/repeat Work Tasks tap to usable content/controls | Yes, same device/dataset/network and consistent endpoints |
| Online/offline workflow outcomes, displayed quantities/totals, photo/Growth links, recorded route and pending/ack state | Yes; label failures and behaviour differences explicitly |
| Candidate internal elapsed phases | Candidate-only; no matching baseline phase export |
| GET attempts, repeated request fingerprints, retries, engine-observed response bytes | Candidate-only with these existing diagnostics; no supported percentage reduction versus B |
| Full wire traffic, CPU attribution, peak memory | Not measured by these diagnostics |

Do not compare Android OS total traffic bytes to C's response-body bytes. No HTTPS interception/certificate setup or instrumentation backport is part of this handoff. Video timing with C capture enabled has diagnostic overhead that B lacks: label it; for cleaner paired video timing, additionally collect the same video runs with capture off in C and collect its diagnostic reports separately.

## 3. Obtain and install safely — no Rork-connected handset needed

1. Developer supplies the unchanged existing APK(s), each with source revision/tree, APK SHA-256, certificate fingerprint, variant and verified package/version metadata in a small manifest. Share privately through an approved file-transfer channel, not a store rollout. Tester verifies the downloaded bytes, e.g. `sha256sum candidate.apk` (macOS: `shasum -a 256 candidate.apk`; Windows PowerShell: `Get-FileHash candidate.apk -Algorithm SHA256`). SDK users can run `apksigner verify --print-certs candidate.apk`.
2. Use a dedicated handset with **no customer VineTrack installation/data** and no restore of customer backups. Preferred strict no-overwrite setup: two already-approved fresh test users/profiles on that same handset, one per APK, with equivalent synthetic fixtures; no existing test installation is removed or cleared. Android multi-user package versions/signing are device-wide: the same `com.rork.vinetrack` package cannot hold two different versions simultaneously across users. Complete B testing first, then replace the device-wide binary with C only if the signatures and forward compatibility are verified; retain B profile data and do not run B again after replacement. Profiles alone do not provide simultaneous different binaries.
3. If the handset lacks an acceptable isolated setup, use a second dedicated synthetic handset and disclose hardware differences, or stop for installation review. Never treat a normal customer phone/work profile as a safe target. Do not install over real data, downgrade a data-bearing installation, clear data, uninstall, bypass a signature error or use a downgrade flag.
4. Baseline-first then candidate is the only potential same-handset forward sequence. Equal versionCode=10 does not establish forward data compatibility. A developer must verify APK signatures and compatibility before any replacement, even on synthetic profiles. If compatibility is not established, use independent test devices/approved fresh targets, retaining every existing installation. Do not modify package IDs or sign/rebuild APKs here.
5. Transfer to the handset and open the APK in Files. Temporarily allow installation from that trusted Files/browser source, install only on the approved target, then revoke that permission. Alternatively, a developer's own laptop can install locally with ADB after independently confirming the exact device/user/absence or approved forward-update target; that laptop need not connect to Rork. No generic overwrite/downgrade command is supplied.
6. Use an existing authorised synthetic test account/vineyard. An authorised system admin is necessary for C capture/export; do not grant production admin access as part of this handoff. Match permissions, entitlement, dataset/record counts, reference data, settings and cache warm-up. If no authorised fixture/account exists, record that as missing rather than changing the backend. Never import customer caches, photos or credentials.

## 4. Minimum capture

For each verified artifact, same handset where safely possible, Wi-Fi, power mode, comparable temperature and dataset:
1. Log APK hash, source, device/model/API, account/vineyard test aliases, dataset counts, network and capture setting. Complete login, required permissions and one identical cache warm-up before timing. A first install/login is not process-cold.
2. Screen-record **three idle process-cold launches** with retained caches. With no active Trip, open tank, capture or in-flight writes, use Android Settings → Apps → VineTrack → Force stop, then launch from its icon. Record icon tap → usable Home, then Work Tasks tap → usable rows/controls; return Home and repeat Work Tasks. Never force-stop active field work, even synthetic smoke work.
3. Screen-record **three warm returns** after 30 seconds backgrounded without stopping the process; repeat the same navigation. Record usable endpoints separately from visible loading/refresh completion.
4. For C diagnostic runs, enable Settings → Admin → Performance Diagnostics → Capture performance timings online before the cold launch. For warm diagnostic runs reset capture off/on while idle before backgrounding, not between first/repeat Work Tasks. Keep first/repeat within one buffer. Export after each run before any termination. For interval counts, export cumulative reports at Home, first Work Tasks and repeat Work Tasks settled, with export/admin intervals labelled separately. Such intermediate sharing changes navigation; keep the sequence identical between diagnostic runs and don't mix it with uninterrupted video-only timing.
5. Use Share timing report online: Android text share sheet → approved email/files/chat destination. Fresh server admin verification is required; numeric buffer is memory-only and may be cleared on rejected access. Read attempts include failed/retry shared-client GETs; body bytes exclude TLS/headers/compressed-wire totals/auth/uploads/other clients. Mark dropped events/evicted fingerprints/incomplete reports as limited or unavailable.

Report individual values and medians/ranges. Only compute `(B - C) / B * 100` for like-for-like observed measurements. No GET/byte reduction percentage without comparable baseline evidence.

## 5. Short operational smoke — after timing, synthetic only

Record pass/fail evidence on each artifact, with matched inputs:
- Online: create/edit Work Task and verify existing totals; record short GPS Trip with row progress and pause/resume; use existing spraying flow to start/confirm/close a tank; create/edit Pin with photo and linked Growth observation.
- Offline: after preloading references, repeat with separate synthetic records; keep location enabled (airplane mode does not disable GPS), verify local records/pending state, background/return without force-stop, complete via existing offline rules. If an action isn't supported offline in B, report that contract rather than treating new support as required.
- Reconnect: wait for normal replay/acknowledgement; verify no missing/duplicate records, unchanged input quantities/calculation outcomes, photo/Growth links and route precision. Use equivalent outdoor route conditions; live GPS points will not be bit-identical, so compare continuity/precision and rules rather than identical coordinates across walks.
- Do not mutate the timed fixture dataset before timing is complete. Retain all synthetic evidence; no cleanup/sign-out/reinstall workarounds. A smoke pass is operational evidence, not exhaustive lifecycle certification.

## 6. Share one results package and stop

Send the timing text reports, screen recordings, artifact manifest and a small CSV/table via the approved private channel, or attach them to this Rork conversation. Suggested rows:
`artifact_hash, source_revision, device_alias, run_type, run_number, capture_on, home_usable_ms, work_tasks_first_ms, work_tasks_repeat_ms, GET_attempts, repeated, retries, observed_body_bytes, smoke_online, smoke_offline, reconnect_result, notes`.
For B's missing counters use `unavailable`, not 0. Include dataset/network/cache preparation and any errors. No passwords/tokens/raw customer payloads. No automatic upload is performed.

## Separate Android release blocker

C contains the unreleasable permanent authentication recovery hold: legitimate definitive session rejection can prevent return to ordinary operation despite credential verification; clean sign-out remains blocked. If the hold appears, stop and retain installed data and evidence. Do not disable the hold, clear data, reinstall, switch accounts or claim verification unlocked field work. Do not deliberately induce rejection during performance runs.

Successful performance/smoke evidence does not authorise release. Read-only performance hunks can be retained on a separately qualified auth baseline or through a separately approved usable recovery correction; do not ship current main wholesale or blindly revert retention protection. Storage migration remains frozen and is not a prerequisite for this testing. No further development is requested by this handoff.

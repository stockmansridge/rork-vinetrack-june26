# Issue #43 — isolated Tank Actual RED contract tests

**Status: TEST SOURCES ONLY. No native tests run; RED outcomes expected but NOT yet observed. Do not approve/merge or create store builds.**

## Exact source base and branch access

- Dedicated GitHub branch: `issue43-tank-actual-p0`.
- Started at public `main` `2e628872aed599b998fe965fa39b89415bb73eaf` on 2 Nov 2026; Rork's managed `e5de6ff30dff2de8dd6840b90131a277a48cba56` was **not found as a public GitHub commit**. Do not assert matching build/source without a new SHA comparison.
- A GitHub branch is NOT automatically a branch-selected Rork workspace. If Rork still cannot checkout, it must not edit `main`: use a branch-enabled agent/local clone or author a reviewable patch that can be applied via the GitHub connector on THIS branch. Do not auto-sync managed `main` changes into the branch under a claimed equivalence.
- No production runtime sources, SQL, Portal code, migration, original data, signing, app release or CI workflow were edited by this test-only branch phase. CI on default is not established.

## Test files (existing native test classes; no Xcode target membership changes)

| Platform | Existing file / new focused test | Purpose; EXPECTED RED against pre-fix production source |
|---|---|---|
| Android | `app/src/test/java/com/rork/vinetrack/data/SprayTankActualTest.kt::issue43ProductionChemicalCodecRequiresExplicitNullLinkageKeys` | Real `SupabaseClient.json` serializer for nested chemical DTO currently `explicitNulls=false`; `plannedChemicalId` and `savedChemicalId` keys required by live SQL validator but absent from JSON. Also assert original actual base amount. |
| Android | Same class `issue43ChemicalRoundTripRetainsUnknownFutureEvidence` | Loss of unrecognized future nested JSON keys after read/encode (source `ignoreUnknownKeys=true` does not preserve unknown fields). |
| Android | `TankDependencyPhaseBTest.kt::issue43ActualAckRejectsSameAmountsWithDifferentLinkage` | Existing equality helper ignores changed planned/saved ID/usage when amount, name and unit match. |
| Android | Same class `issue43ActualAckRejectsSameAmountsWithDifferentProvenance` | Existing equality helper ignores changed original evidence snapshot timestamp. |
| iOS | `ios/VineTrackTests/SprayTankActualTests.swift::testIssue43ProductionRPCRequestRequiresNullLinkageKeys` | Tests the *actual* `SprayTankActualUpsertRequest` JSONEncoder output, not a manually manufactured JSON request; Swift optional fields currently omitted. |
| iOS | Same class `testIssue43ChemicalRoundTripRetainsAndroidProvenance` | Typed decode/re-encode of Android `productCategory`, `physicalForm`, `snapshotAt` must not silently lose metadata. |
| iOS | `ios/VineTrackTests/TankDependencyVerificationTests.swift::testIssue43ReadbackRejectsChangedLinkageAtSameQuantity` | Current `TankDependencyVerification.actualMatches` compares amounts only, not original linkage. |

**Gap:** Android's `SprayTankActualRepository.Request` type is `private`. These RED tests use the exact production nested chemical serializer but do **not** yet inspect the full POST body. Add a native Ktor request-capture fixture using the production repository and proper account auth seam, or a narrowly scoped internal test hook. Do not replace with a hand-written JSON fixture and call it a producer test.

**Gap:** These tests do not by themselves prove actual older **3.1.8** serializer compatibility. Freeze exact signed 3.1.8 writer outputs and map `p_chemicals` null/omission before any production migration.

## Required execution — branch-only

1. Verify the checkout's HEAD is the feature branch SHA and the diff contains ONLY this document and the 4 native test files; confirm no protected Trip data read/changed by the harness.
2. Run the existing targeted Android JVM test classes via the project's Gradle `:app:testDebugUnitTest` task, and the two corresponding iOS XCTest classes on a supported simulator. Capture reports/screenshots and compiler diagnostics, including exact source SHA.
3. A **compilation error is NOT a successful RED compatibility test**: correct test harness imports/signatures first without changing production source; expected failures should be assertion failures at the mismatch points. Record failing test names and messages.
4. Once deterministic RED receipts exist, apply **small scoped runtime corrections on this same branch**: canonical explicit-null linkage encoding, lossless unknown/provenance strategy, correct evidence-aware ACK, plus separately reviewed backend compatibility/concurrency design. Test GREEN after each with old-client fixtures.
5. Supabase production SQL remains unchanged until an authenticated, versioned, migration-reviewed compatibility decision; never globally flip Android serializer settings without entire app contract impact analysis.
6. Raise a draft PR from this branch into `main`; do not merge while RED, unverified native/Portal/backend or missing older version fixtures. Do not lift the 3.1.9 release hold.

## Review outcome

This is a safe, reviewable test harness starting point; it **does not** solve the runtime sync bug or bypass Rork's managed workspace branch selection limitation. All seven new tests are **written, unexecuted**, intended to establish original failing evidence at the production codec/comparator boundary.

## 2026-11-02 CI findings: original native runs were compiler failures, NOT RED assertions

Exact log evidence was retrieved through the GitHub job-log connector:

- **Android** [run 41390883677](https://github.com/stockmansridge/rork-vinetrack-june26/actions/runs/41390883677), branch SHA `71aba0a4c7d80176fbf6dea3a3795a62a9b134f5`: `:app:compileDebugKotlin` failed on `AppConfig.kt:5,116,148`, `unresolved reference Config`. The Rork-managed `com.rork.vinetrack.Config` generated class is not in this public GitHub checkout. There were **no JUnit XML reports**. Failure is infrastructure/build prerequisite, NOT Tank Actual RED.
- **iOS** [run 41390764735](https://github.com/stockmansridge/rork-vinetrack-june26/actions/runs/41390764735), Xcode 16.4, PR synthetic merge checkout unless explicitly overridden: native compile stopped in `PinPhotoStorageService.swift:54,81,136`, `expression is async but is not marked with await`. Another same-head workflow [run 41390759437](https://github.com/stockmansridge/rork-vinetrack-june26/actions/runs/41390759437) stopped in `SupabaseCloneRootstockCatalogRepository.swift:220,221`, main-actor isolated initializer in a synchronous nonisolated context. These are unrelated production Swift sources, **not evidence of native Tank Actual test assertions**.
- Both original iOS workflows produced `.xcresult` uploads, but their Xcode logs unambiguously said `Testing cancelled because the build failed`.

**Harness-only repair, not app fix:** branch workflows `.github/workflows/issue43-tank-actual-red-native.yml` and `issue43-android-red-v2.yml` now (a) pin the exact PR head in checkout rather than synthetic merge; (b) persist full Gradle and Xcode logs in always-upload artifacts; (c) use preinstalled Android SDK instead of deprecated `tools` setup; and (d) generate **an empty, CI-only, unconfigured `Config.kt` substitute in the temporary runner checkout** if needed, so the Android compiler can test the native wire-code without checking in credentials or modifying production config. This surrogate makes the test-runner compilation **non-identical to a signed Rork build**, and should be reported transparently.
- The main workflow is **PR-triggered only** with test/production-code paths and opt-in `workflow_dispatch`; the Android-only fallback is opt-in `workflow_dispatch` to avoid duplicate costly runs. These changes do not alter any production `.kt`/`.swift` sources, Supabase, signed builds, test assertions or live original records.
- **Next evidence:** exact new run SHA + JUnit/XCTest assertion failure logs, if any. If iOS unrelated production compilation still fails, report as an independent compile prerequisite and do not modify app sources without separate review. **RED→GREEN remains NOT ESTABLISHED** until named assertions fail at the actual production encoder or ACK boundary and later pass with source-matched corrections.

# iOS presentation performance follow-up — 21 October 2026

## Purpose and provenance

The upstream report records the owner's observation that PR #9 resolved Home scrolling during sync. That is owner-reported context, not physical-iPhone evidence collected in this integration.

- Repository: `stockmansridge/rork-vinetrack-june26`.
- PR #10 implementation: `84b9e5f5566d86a3d57bf6af7a744a7157e2f7bc`; verified against `refs/pull/10/head` and branch `perf/ios-presentation-20261021`.
- Original main comparison baseline: `ea32b0a407ebae57cb1001a0bb560ceb3d62d588`.
- Implementation HEAD's immediate parent is `ee3cacdbf7079649f2fb5a6b6f975746e59172fa`, not that original main baseline. The integration uses the full baseline-to-head patch, not only the last commit.
- Managed pre-integration HEAD: `cd8fb6c286b8285d349ca2f66b1aae9775c88367`.
- Isolated upstream reference: `linked-repos/vinetrack-presentation-review`; existing linked repositories retained.

All three existing production files touched by this patch exactly matched the original main baseline before integration. No conflicting newer edits required reconciliation. Only the five production and three test files below were integrated; all eight initially matched upstream byte-for-byte. Native compilation then required the single test-only correction documented below. All five production files and the other two test files remain byte-identical to the supplied implementation.

## Changes and source review

### Work Task Log

Prepare a temporary collection once per view evaluation and reuse filtered/sorted rows, hours, people, block labels and required cost rollups in the summary and list. Cost sorting compares prepared costs instead of invoking the calculator per comparison.

Retain original filtering, localized comparisons, planning order, equal-key behavior, duplicate-ID multiplicity, accumulation order, incomplete-cost indicators, financial/material permission inputs, badges and editor actions. WorkTask display helpers and WorkTaskCostRollup remain authoritative. Hidden financials do not compute rollups unless the existing cost sort needs them. No long-lived cache or save/sync involvement is introduced.

### Growth Stage Summary

Prepare the vineyard-local day once, group influencing observation values for the current blocks and reuse each maximum E-L for ordering and labels. Preserve `isInfluencing`, the stage/name comparator and block-array multiplicity. Navigation resolves detail values from current feed/time when its destination builder runs; detail membership uses the existing instant cutoff, separately from vineyard-local day policy. No refresh timer or persistent cache is added.

### Pruning block screen

Prepare one current PruningCalculator.metrics bundle per body evaluation plus editing locks and completion dates; reuse it across progress, rates, history and row-quarter presentation. Actions and sheet preparation retain live setup/entries/rows. Original quarter-button semantics, row identities, legacy fallback, skipped/pruned precedence, edit unlocking and save/reversal paths remain unchanged. Presentation values are not persisted or made save authority.

## Exact source/test inventory

- `ios/VineTrack/LegacyImported/Views/Tasks/WorkTaskLogView.swift`
- `ios/VineTrack/LegacyImported/Views/Tasks/WorkTaskLogPresentation.swift` (new)
- `ios/VineTrack/LegacyImported/Views/Phenology/GrowthStageRecordsListView.swift` (also contains GrowthStageSummaryPresentation)
- `ios/VineTrack/LegacyImported/Views/Pruning/PruningBlockDetailView.swift`
- `ios/VineTrack/LegacyImported/Views/Pruning/PruningBlockPresentation.swift` (new)
- `ios/VineTrackTests/WorkTaskLogPresentationTests.swift` (new)
- `ios/VineTrackTests/GrowthStageSummaryPresentationTests.swift` (new)
- `ios/VineTrackTests/PruningBlockPresentationTests.swift` (new, one compiler-compatibility correction)

Additional integration bookkeeping: this report, the existing approved plan checkpoint, `.gitmodules` and the new linked-repository pointer. Preserve the preexisting/system `.rork/.skills-mount-fingerprint` change and all managed history.

## Actual native validation

Only the following selection was requested and executed through the native simulator test runner (`appPath: ios`):

1. `VineTrackTests/WorkTaskLogPresentationTests`
2. `VineTrackTests/GrowthStageSummaryPresentationTests`
3. `VineTrackTests/PruningBlockPresentationTests`

Source contains 21 test functions (8/7/6). This source count was not used as passing evidence.

### First attempt — test compilation failed, no tests executed

Runner returned 0 passed / 0 failed because compilation stopped before execution. The error was in the newly integrated `PruningBlockPresentationTests.swift:233`: Swift Testing's expansion of `#expect(initial.metrics.rows.allSatisfy(\.isFallback))` emitted `call can throw, but it is not marked with 'try' and the error is not handled`. The expanded `allSatisfy` call was treated as throwing.

The full runner log was inspected at `/tmp/rork-swift-test-ios.log`, lines 1236–1249. This is temporary runner output, not a durable committed artifact. The diagnostic is recorded here because later runs may replace the log.

Minimal patch-attributable correction: replace only that assertion's key-path predicate with `#expect(initial.metrics.rows.allSatisfy { $0.isFallback })`. Existing `PruningCalculatorFixtureTests.swift:141` already uses this closure form. The assertion still checks every row is fallback; no expectation, fixture, production code or calculator changed. No unrelated warnings were corrected. The runner also emitted existing actor-isolation/Sendable and other warnings; these were not the stopping error.

### Corrected selection — PASS

Reran the same three-suite selection because the first attempt executed none of them. Runner explicitly reported **21 passed in 39 seconds**; no test failures were reported. Do not add the source-function count or the zero-execution attempt to this count. The runner's successful response is aggregate-only: no per-suite executed manifest, separate build duration or skipped count was exposed. No additional suites, UI test fixtures or new tests were added/executed for this checkpoint.

### Final iOS build — PASS

`runChecks(appPath: "ios")` returned **Checks passed; Simulator build succeeded** after the correction. The existing scheme's TestAction uses Debug. Filesystem-synchronized app/test groups include the new files without project edits. Device/Release build success is not established by this simulator result.

The build also reported two unrelated existing direct-storage image URL advisories in TripTypeChoiceSheet and UCRInfoSheet. They did not block checks and were not changed in this focused patch.

## Runtime smoke — blocked / unverified

After native checks passed, attempted Task Log inspection using only the current preview's existing session/data, with dedicated simulator fallback disabled and no fresh launch, credentials, fixture or record writes. The simulator tool returned: `Open this app's simulator preview first. Simulator use drives the preview you have open.` It explicitly reported it could not test the app. No screenshot or authentication/data state was observed; do not infer an auth blocker or absent records.

- Task Log existing layout, filters, sorting, totals, editor open/Cancel: **UNVERIFIED**; preview unavailable, no screen interactions executed.
- Growth Stage Summary ordering, displayed stages and detail navigation: **UNVERIFIED**; not attempted after the shared preview prerequisite failed.
- Populated Pruning block progress, quarter colors/locks and editor open/Cancel: **UNVERIFIED**; same prerequisite unavailable.
- No record creation/edit/save/delete, session reset or auth bypass was performed to manufacture smoke evidence. This describes actions taken, not a screenshot-proven absence of hidden background side effects.

Next runtime step: open the VineTrack iOS preview with its existing session/data, then perform the three bounded read-only checks. If a screen is inaccessible, leave it unverified rather than creating data. No repeated tests/builds are necessary merely to open the preview if source is unchanged.

## Preservation verification

The only iOS source/test delta from managed baseline is the eight-file inventory above. Android, scripts, SQL/Supabase paths and the Xcode project have no delta from managed HEAD. iOS version remains 3.1.8/build139; Android is untouched (3.1.8/code12). Newer Home/task batching, pin evidence, chemical reconciliation, calculation engines, permissions and persistence/sync code were not overwritten. No record or queue migration, replay, reset or history rewrite was introduced. Source whitespace check passed.

Protected chemical SHA-256 values reverified unchanged:

- ManagementSyncServices.swift: `8ac255ed70536596f178403a95395b4bcb59da056d8a963326dd9643e2b9a88e`
- SprayRepository.swift: `2d9b6af17d830e119eed1e89a66a6c66ebfafc3ad4741950f7deeeeb660c0037`
- MigratedDataStore+Spray.swift: `ca54fa3b93957ed77d5812d2de2d9a14f3fa94385e3050ce31a6cc292282dfac`
- SavedChemicalBatchReconciliationTests.swift: `2ec7d9840eba40f4edcf8cafd60099d3a964a13979c7326ad8f24b0530010c75`

## Validated source identity and post-save SHA

Managed baseline plus the following ordered SHA-256 manifest identifies the tested integrated files, including the sole compiler correction. Manifest encoding: UTF-8, each line `hash`, two spaces, project-relative path, LF; order exactly as below. SHA-256 of those eight lines is `6b3204ff5fb383d687c34e98dc62c104c3c0c41b07d5f54d4d77083bc5d5bc3e`.

```text
cbbc852f27242349ebbab7b9ed315baf85111a7dfa8019f7e5e7b36f1be8cc1b  ios/VineTrack/LegacyImported/Views/Phenology/GrowthStageRecordsListView.swift
0bad61cd254f18549df72b982af060f094098bcc89f7da8f87a1db6ca2c12851  ios/VineTrack/LegacyImported/Views/Pruning/PruningBlockDetailView.swift
3ec1c335867463ebca68b9d620fe753c1407a87ce058e6a5ab3e35ed605be31a  ios/VineTrack/LegacyImported/Views/Pruning/PruningBlockPresentation.swift
258eb42ab00217ed759bb5fec2389722d52d0b470603a017074a4bbc97356033  ios/VineTrack/LegacyImported/Views/Tasks/WorkTaskLogPresentation.swift
da3791384153849522ccebfd90aaffc452df21dad30b377682a3e823f74a1624  ios/VineTrack/LegacyImported/Views/Tasks/WorkTaskLogView.swift
e69d8b2a96e158e6c4a2335581358c5f32942c8003c2c12e5a19ce8097cf851d  ios/VineTrackTests/GrowthStageSummaryPresentationTests.swift
9e7820c940534ac9460fe3aec0326cc0c0cc247872fe8cbbba0225005a14a797  ios/VineTrackTests/PruningBlockPresentationTests.swift
07336e698ab1faca27a59f7950f506d8c97ed2959a65a7d13080466fce1aa5ef  ios/VineTrackTests/WorkTaskLogPresentationTests.swift
```

**Final post-save managed integration SHA: PENDING.** The latest actual `git rev-parse HEAD` still returns the pre-integration baseline `cd8fb6c286b8285d349ca2f66b1aae9775c88367`; managed saving assigns the new commit after this turn. Neither that baseline nor upstream implementation SHA is the final integration commit. Read the actual saved commit in a subsequent checkpoint, verify its eight file hashes against this manifest, and append that SHA here. No manual commit/push or invented final SHA.

## Acceptance and handoff boundaries

Native equivalence/build gate is green, but runtime smoke and physical-iPhone performance remain unverified. Source review establishes removal of repeated presentation calculations; neither tests nor simulator build measures frame times or representative-device responsiveness. Owner's separate phone check should cover all three screens and confirm Home remains smooth during sync, including an unchanged-cache pass with existing captures.

PR #10 draft/readiness state was not changed. No signing, IPA export, TestFlight/App Store delivery, Play operation, SQL/Portal change or distribution preparation occurred. The owner handles normal Rork upload. Target Nutrient remains CLOSED. Historical PR #9 and chemical results remain separate evidence, not counted as PR #10 tests.

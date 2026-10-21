# iOS presentation performance follow-up — 21 October 2026

## Purpose and baseline

The owner reported that PR #9 resolved the Home scrolling problem during sync, then authorised three further iOS presentation improvements: Work Task Log, Growth Stage Summary, and the Pruning block screen.

Reviewed implementation baseline: `ea32b0a407ebae57cb1001a0bb560ceb3d62d588` in `stockmansridge/rork-vinetrack-june26`.

This follow-up reduces repeated display preparation. It retains the existing calculation engines, storage and sync paths, navigation structure, and current record identities. The Android and additional reference-catalogue candidates from the audit are outside this patch.

## Changes

### Work Task Log

Prepare a temporary collection of row display values once per view evaluation. Reuse the filtered/sorted rows, hours, people, block labels and required cost roll-ups in the summary and list. Cost sorting compares the prepared costs rather than invoking the calculation engine for every comparison.

Preserve the existing filter scope, localized comparisons, default planning order, equal-key ordering, row multiplicity, accumulation order, incomplete-cost indicators, material/financial access checks, sync badges and edit actions. The existing WorkTask display helpers and WorkTaskCostRollup remain the calculation authority.

### Growth Stage Summary

Prepare the vineyard-local day once, group influencing observation values for the current blocks, resolve each block's maximum E-L, and reuse those values for row ordering and labels. Preserve the existing isInfluencing policy and the original stage/name comparator.

Navigation prepares detail values from the current feed and time when its destination builder runs. The detail-record timestamp cutoff remains separate from the E-L policy's vineyard-local day. No long-lived cached summary or new refresh timer is introduced.

### Pruning block screen

Prepare one current PruningCalculator.metrics bundle per body evaluation, along with the editing lock set and segment completion dates. Reuse it in the progress, rates, history and row-quarter display.

Action handlers and sheet preparation continue reading live setup/entries/rows. Existing quarter-button action semantics remain unchanged. Actual row identities/order, legacy row-number fallback, reversed entries, skipped/pruned precedence, own-entry unlocking, calculations and save/reversal paths are preserved.

## Validation plan

Three focused native suites exercise the new production presentation helpers:

1. `VineTrackTests/WorkTaskLogPresentationTests`
2. `VineTrackTests/GrowthStageSummaryPresentationTests`
3. `VineTrackTests/PruningBlockPresentationTests`

The suites contain 21 new test functions in source (8 Work Task Log, 7 Growth Stage Summary, 6 Pruning). They compare prepared output with the existing/reference calculations at fixed inputs and times. They cover ordering/duplicates, totals and permissions, E-L influence/day boundaries and live detail preparation, and Pruning metrics/row changes/edit locks. A counting test checks that cost sorting performs one roll-up per matching task rather than repeating the calculation during comparisons.

Run one Debug iOS simulator build and only these three suites. Correct a defect introduced by this patch if found; otherwise do not expand into unrelated test or feature work. Record the actual executed test count and result rather than deriving a passing count from source.

## Validation status in the editing environment

- Current source baseline verified against GitHub file blobs before editing.
- Source and diff review performed before publication.
- Swift and Xcode are unavailable in this environment: native compilation and all 21 new test functions remain unexecuted here.
- No simulator or physical-device performance result is claimed for these three new changes.
- The Xcode application and test folders are filesystem-synchronised; the project file requires no edits for the added helpers/tests.

## Rork integration and acceptance

Apply the focused patch to the current Rork project while retaining any newer work. If a touched file has changed since the recorded baseline, reconcile the specific edits rather than replacing the whole current file.

After the focused native checks pass, inspect Task Log, Growth Stage Summary and a populated Pruning block using existing data if those screens are available in the current session. Check the existing layout, filtering/order, displayed totals/stages, row grid and editor open/cancel behaviour. Record unavailable runtime checks as unverified.

The owner handles upload through the normal Rork workflow. The subsequent phone check should confirm responsiveness on the three affected screens and that Home remains smooth during sync. No signing/export preparation or distribution action is part of this source handoff.

## Evidence boundaries

The source establishes that repeated calculations were removed. The magnitude of a device speed-up remains to be measured with representative records. Native test success will establish the tested output equivalence; it will not itself establish a frame-time improvement.

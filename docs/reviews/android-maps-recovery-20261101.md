# Android recovery: concrete Maps files and remaining pruning blockers

Status: PARTIAL SOURCE REPAIR. Do not publish this alone as the recovery fix.
Baseline: f8d36eec3298071b92cb0d653e3b74d0d27ecc12.
Affected diagnostic build: 3.1.9 / 1793499661.

## Confirmed first-stage defect

The supplied complete top-level inventory has seven entries. Three ordinary files
fall through AccountTransitionEvidence.inspectLocations into emptyTree, which
requires a directory and therefore returns FILES_UNREVIEWED_CONTENT:

- DATA_ServerControlledParametersManager.data.v1.com.rork.vinetrack
- SavedClientParameters.data.cs
- _m_t

The other names are canopy_reference_images, profileInstalled,
profileinstaller_profileWrittenFor_lastUpdateTime.dat and vineyard_logos. They
already have dedicated routes; their nested contents were not supplied or inspected.
Neither a descriptive inventory category nor a filename proves byte contents.

These three names have Maps SDK provenance. Source references consulted:
- Maps issue: https://issuetracker.google.com/issues/154855417
  (the current public web view did not expose its detailed comments).
- App-maintainer implementation of the Maps cache workaround explicitly names both
  parameter paths: https://github.com/rtr-nettest/open-rmbt-android/blob/11e9a7dfb9c24237ee5142cb58e6ee74be7e852c/app/src/main/java/at/rtr/rmbt/android/App.kt
- Decompiled Maps writer using Context.openFileOutput("_m_t", 0):
  https://github.com/EstebanDalelR/codacytinder/blob/4be454abbe5897b41e8e7610fd5a41a7b82eebc9/sources/com/google/android/m4b/maps/aw/C4698d.java
  This is historical third-party-hosted bytecode analysis, NOT an official current
  SDK source distribution or a reproduction using VineTrack's installed renderer.
  It identifies SDK token metadata, not vineyard work. Do not export its contents.

## Implemented change

GoogleMapsRuntimeFiles recognises ONLY those three exact basenames, with the
parameter-cache suffix bound to Context.packageName. The file must be directly
under the canonical Context files root, regular, single-link, same filesystem and
UID as that root, with stable device/inode identity across metadata checks.
Symlinks (including dangling links), directories, hard links, FIFO/special files,
lookalikes, suffixes, foreign packages and unknown files are not exempted.

No runtime file is opened, parsed, copied, logged, deleted, moved, adopted or marked
synced. Size/mtime/content are SDK-owned and intentionally not forced to match one
phone's snapshot. The SDK token file remains opaque. AccountTransitionEvidence has
one new three-line route; all business validators and authority checks are unchanged.
Structural failures use MAPS_RUNTIME_FILE_CONTRACT, without filename disclosure.
The original privacy-safe diagnostics and descriptive inventory labels are unchanged.

## A Maps-only release is insufficient: two further source-confirmed gaps

The supplied inventory also includes vinetrack_pruning.xml and
vinetrack_pruning_yield_settings.xml. Both names are in businessPreferences but
neither has a validation branch nor belongs to CleanExitCacheContract.devicePreferences.
They reach `else -> check(values.isEmpty())`. Even a legitimate writer-produced
key containing an empty JSON list fails. Populated records therefore cannot recover
under the current implementation, irrespective of the Maps correction.

Do NOT add these stores to excludedPreferences or devicePreferences wholesale.
PruningStore contains setups_v2_, entries_v2_, activities_v1_ and
activity_labour_v1_ snapshots including locally edited/draft work.
PruningSyncCoordinator writes the store BEFORE enqueueCoalesced in several paths;
queue absence alone cannot prove that a pruning snapshot was acknowledged remotely.
PruningYieldSettingsStore writes settings_ after successful reads and local saves.
Neither a vineyard key nor current membership supplies missing operation authorship.

Required follow-on repair: implement a supported retained-state contract for these
actual writers. Distinguish verified read snapshots from unresolved local operations.
Where local provenance cannot establish that distinction, use isolated, read-only
server reconciliation after original /user and current membership verification.
Bind any verification proof to exact unchanged local state and the identity epoch
before unlocking; unknown, differing, unauthored or unverifiable operations remain
protected. Reuse verified wire contracts rather than inventing RPCs. No store reset,
silent overwrite, guessed owner, queue acknowledgement or fresh re-download over
retained bytes is acceptable. Do not activate FIELD_STORAGE_ISOLATION_ACTIVATED.

## Validation performed here

Executed scripts/test-android-maps-runtime-host.py: 21 passing checks.
This compiles the actual GoogleMapsRuntimeFiles production helper and runs nine
name-contract tests plus twelve filesystem tests against explicit Android/JUnit
host doubles and a real temporary Linux filesystem. See the captured log.
It is NOT Android-native, Gradle, Compose, authentication or original-device testing.

The baseline AccountTransitionEvidence blob was independently reconstructed and
matched Git object 69afd815dccc0d81097014cb45b11c1832dc029d before the single edit.

Added eight native integration methods in GoogleMapsRecoveryAndroidTest. These
have NOT been compiled or executed here. The suite includes synthetic original-user
recovery with all seven top-level names, unchanged cached pins/snapshots/files,
wrong-account and revoked-membership refusal, unknown-file refusal, unsafe file-type
refusal, and two explicit tests documenting the unresolved pruning-store blockers.
Those last two passing tests mean protection remains; they are NOT incident acceptance.
Synthetic file bytes at the reported lengths do not reproduce the installed SDK writer.

## Rork handoff and release gate

1. Import this exact branch/commit without reverting newer unrelated work. Review
   the implemented Maps contract and reproduce names with the shipping Maps/Play
   Services renderer; do not expose SDK token contents or private customer data.
2. Implement the pruning and pruning-yield retained-state contracts above, with
   negative cases for unknown keys, corrupt rows, missing authors, local-only edits,
   mismatched remote state, stale proof, account change and revoked access.
3. Turn the two documented pruning-gap scenarios into valid recoverable-snapshot
   acceptance tests only after the actual safety contract is implemented. Test
   nonempty setups, entries, activities, labour and yield settings as well.
4. Run GoogleMapsRuntimeFilesTest, GoogleMapsRuntimeFilesAndroidTest and
   GoogleMapsRecoveryAndroidTest with all new files explicitly selected, plus
   ProfileInstallerRecoveryAndroidTest, AuthRetentionAndroidTest,
   RetainedStartupConstructionTest and existing recovery inventory regressions.
   Do not confuse host-double tests or expected-refusal tests with recovery success.
5. The release fixture must contain the reported seven top-level entries AND
   representative populated domain cache, chemicals, tank actuals, recovery snapshots,
   pruning, pruning-yield settings and device preferences. Check all supplied store
   names against their writers, not only the first failure. No claims about actual
   private values without reading/validating them through the approved recovery path.
6. Only after complete supported populated recovery passes, build and publish an
   Android-only Internal Testing update using existing package/signing, with version
   code greater than 1793499661 and any later uploaded code. No iOS/backend/release
   policy changes. Do not publish another Maps-only or diagnostic-only candidate.
7. Keep the incident open until the original device reaches Home, retained work,
   vineyard/tractor/sprayer data is present, and close/reopen succeeds. No uninstall
   or app-storage clear. Do not send the owner back to a support address he owns.

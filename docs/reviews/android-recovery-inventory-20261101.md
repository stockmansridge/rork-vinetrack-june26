# Android retained-file incident: reviewed inventory (1 November 2026)

## Rork continuation — native/UI/build PASS; diagnostic delivery sync-blocked

**The original installation on Android3.1.9/code1793493625 is still locked at RETAINED_EVIDENCE / file_dependencies / FILES_UNREVIEWED_CONTENT. Incident OPEN.** The prior ProfileInstaller publication and emulator passes did not recover Jonathan's phone. This continuation validates evidence collection only; no new admission exception or login correction is implemented.

- Requested GitHub `7947edc7d52ee483288783525b54b112c11d1581` is already imported as managed `5d4e99e5e301c8ada3a4795d826cc537a3b0ccba`. All **1,234 Android files and executable modes** match the exact requested archive. Android tree `fb088acc24288469f653b6bb98ed761121564f1d`, source label `src_fb088acc24288469`. No old snapshot replacement or manual Git mutation.
- **Fresh Gradle/JVM:** `RecoveryStorageReportTest` **8passed,0failures,0errors,0skipped**. Explicit compile include `**/RecoveryStorageReportTest.kt`, exact class execution, uncached test task and exact XML discovery verified. Raw Gradle output/XML/result and init script are retained under `evidence/android-recovery-inventory-validation-20261101/gradle/`. The imported 16 host-double checks below are historical, not added to fresh native/JVM totals.
- **Fresh native filesystem:** explicit `RecoveryStorageInventoryAndroidTest` **8passed,0failed,0skipped in13s**, compiled through the normal complete androidTest source set, including its new filename. These cases use disposable redirected roots and are not the shipping-root acceptance below.
- **Affected native recovery regressions:** `AuthRetentionAndroidTest` + `PopulatedCleanExitActivityTest` **84passed,0failed,0skipped in75s**; separate `FieldSaveContentionAndroidTest` **18passed,0failed,0skipped in12s**. Existing original/wrong-account, retained-work, rendered recovery, Home/reopen/editor and field-save protections remain passing. No changed assertions, weakened protection, source patch or unchanged-failure retry.
- **Supplemental rendered shipping-root cold-start acceptance:** **1passed,0failed,0skipped in13s**. The test runner temporarily delegated Application creation to its actual manifest class, **android.app.Application**, rather than `CleanExitFixtureApplication`. Normal framework/provider startup and first production `MainActivity` initialization run against actual target Context files/cache/shared_prefs roots; no fixture root or transport override. A normal AndroidX Startup provider is required. The test logs startup metadata, but the successful remote tool does not expose raw logs, so no exact startup filename list or individual SDK initializer assertion is claimed.
- On that isolated emulator, two synthetic unknown top-level files kept the ordinary SessionStore locked and both names appeared in the rendered report before copy. Credential fields stayed empty and Restore remained disabled. Opening and Close preserved a sentinel clipboard; only a separate **Copy reviewed inventory** tap copied both names, not contents or absolute paths. Exact synthetic file bytes and regular preference-file bytes, session values, lock, identity epoch, principal and camera permission were unchanged. Activity recreation remained locked. This is **not** Jonathan's actual inventory, physical-device recovery, binary-upgrade compatibility or OS process-death acceptance. Nothing in this test unlocks unknown retained content.
- The supplemental source is retained at `scripts/fixtures/android-recovery-inventory/ShippingInventoryAcceptanceTest.kt`, outside the Android app. To reproduce on an isolated emulator, temporarily stage that file into the matching androidTest package and change only runner `super.newApplication(cl, CleanExitFixtureApplication::class.java.name, context)` to `super.newApplication(cl, className, context)`; run only the supplemental class, then restore the original runner and remove the staged file. Both temporary changes were restored **before** the normal build and Play attempt; the complete Android tree again exactly matches the requested commit.
- **111 disjoint native passes** across those four tool selections; the **8 JVM passes** are separate. Native success evidence is explicitly a transcription of tool results, not mislabeled stale raw emulator logs. Separate `runChecks(android-vinetrack)` **PASS** after restoration, with only the same two nonblocking asset-address advisories. iOS/configuration, backend, package/signing/version settings and disabled storage-isolation activation are unchanged. No iOS build or customer/backend operation.
- Separate exact source checkpoint: `evidence/android-recovery-inventory-validation-20261101/source-manifest.json`, SHA256 `760ebc2d2b7417b415efe06c44de0adb5aecec25cf993825d38b4ecd8f33f4e6`. Includes full Android file inventory and supplemental harness hash. Earlier manifests/evidence remain intact.
- **Delivery BLOCKED_PENDING_MANAGED_SYNC.** Play connection and existing `com.rork.vinetrack` package access succeed. No listed AAB matches the reviewed inventory source; the prior ProfileInstaller bundle was not selected. One matching-source `generatePlayAab` attempt returned exactly: `The current project has unsynced source changes. Finish this turn, then retry publishing.` **No new runId, bundle, version code, Play validation or publication exists.** No unchanged retry or gate bypass. Separate delivery receipt: `android-recovery-inventory-delivery-20261101.json`.
- After automatic sync, verify this unchanged Android tree/checkpoint and record the current managed revision separately. Build a matching Android3.1.9 AAB, verify exact backend-resolved source/run/package, validate and commit through **existing Internal Testing only**, at a managed code **greater than1793493625**. Do not reuse the old build or claim this turn made an update available.
- After that delivery, the next original-device action is **Review storage inventory → review the names → Copy reviewed inventory**. No repeated sign-in is needed to collect it. Keep the report private; do not publish personal filenames. Use the actual inventory to identify and reproduce each remaining writer/dependency before another recovery correction. Do not clear/uninstall, reset queues, adopt owners, recreate tasks or activate storage isolation. Original UUID, vineyard/task/request identities, drafts, queues/photos/Trips/deletions/receipts remain protected. Successful original-account recovery, retained work/equipment and close/reopen acceptance remain open.

## Original imported report — historical author-environment results

## Status: diagnostic correction only, NOT a login fix

Baseline: 7114341f77e02f817bb57fc76db7ef5abdfa50da.
The affected installation still reports Android 3.1.9 / code 1793493625,
RETAINED_EVIDENCE / file_dependencies / FILES_UNREVIEWED_CONTENT.
The installed ProfileInstaller correction and its passing synthetic tests have
not established recovery of the original phone. Do not repeat that claim.

## Confirmed limitation

AccountTransitionEvidence.inspectLocations exits on the first unrecognised
non-empty top-level location. RecoveryLocationContract.retainedRule supplies a
generic FILES_UNREVIEWED_CONTENT when that location is not a recognised name.
RecoveryDiagnostics intentionally omits all filenames. Neither this diagnostic
nor the previously isolated test files identifies the remaining actual location
on the affected device. Adding another guessed allowlist entry is not justified.

AuthRecoveryRepository verifies server identity and memberships before calling
SessionStore.restoreOriginal, where retained evidence can reject admission.
A RETAINED_EVIDENCE failure must not be described as proof that credentials were
never verified. Copying local diagnostics itself does not verify credentials.

## Change

A separate Review storage inventory button is available on the locked recovery
screen without another sign-in. It enumerates top-level entries at the same
storage roots relevant to this failure: files, shared_prefs, and legacy
cache/camera-captures. It shows names, entry types, regular-file sizes and
multiple-link metadata together instead of stopping at one unknown item.

No file is opened for its contents. Preference values, credentials, nested
filenames, symlink targets and absolute paths are not returned. Entries are not
recursed into; linked preference/camera roots are not traversed. Reporting is
limited to 256 entries per root, with total counts and explicit truncation.
All items are listed; their descriptive categories are NOT validation or proof
that any item is safe or a blocker. Read errors are generic, without exception
strings. Control and bidirectional characters in filenames are escaped.

Names can themselves contain personal information. The local dialog states this
and requires the user's separate Copy reviewed inventory action before anything
is placed on the clipboard. Nothing is automatically uploaded. The old
privacy-safe Copy recovery diagnostics action is unchanged. A name-free summary
formatter is tested but is not silently substituted for the existing report.

Account admission, auth, original-user matching, current membership, retained
validators, storage cutover, data replay, iOS and backend behavior are unchanged.
No file is deleted, moved, adopted, cleared or marked synced. This patch does NOT
itself unlock the installation. It obtains the missing evidence for a targeted
repair instead of another unverified exception.

## Validation in this environment

Executed scripts/test-android-recovery-inventory-host.py using Kotlin/JVM and
Java 21: 16 passed (8 formatter tests and 8 filesystem scenarios). The script
uses local JUnit and Android API doubles with a real temporary Linux filesystem.
It compiles the actual two production helpers and the checked-in test classes.
This is NOT Gradle, Android-native, Compose-screen or original-device acceptance.
The host runner is reproducible with python3, javac, java and kotlinc on PATH.

Eight native Android test methods are added in RecoveryStorageInventoryAndroidTest;
they still need execution with real Android APIs. RecoveryStorageReportTest
contains eight Gradle/JVM tests. Native SDK/emulator and signed Play delivery were
not available in this environment. No APK/AAB was built or published here.
The existing screen baseline was verified against blob
a3d7af0c3245bc04c63f683beda13f4ee8d71258 before editing.

## Rork validation and delivery

1. Import the final GitHub commit for this patch, preserving newer unrelated
   work. Compile Android and run RecoveryStorageReportTest plus
   RecoveryStorageInventoryAndroidTest with the new filenames explicitly
   included by any focused source filters. Do not count zero selected tests.
2. Verify the real recovery screen: Review storage inventory works while locked
   without entering credentials; review does not copy or upload automatically;
   Copy reviewed inventory requires the separate tap; Close does not copy;
   opening/closing the dialog leaves the retention guard and bytes unchanged.
   Include the existing auth retention and populated-recovery regressions.
3. Also run a cold launch with the shipping Application/SDK initialization and
   actual app storage roots, not only redirected FixtureContext directories.
   Check that the inventory can expose multiple unknown top-level locations.
   Do not claim this recreates the original device unless its inventory matches.
4. After the checks pass, deliver a clearly labelled diagnostic Internal Testing
   update, existing package/signing identity, version code >1793493625. No public
   production release or iOS build. Record exact source revision and result.
5. On the original installation, use Review storage inventory, review the names,
   then Copy reviewed inventory. No repeated sign-in is needed. Keep any report
   private; do not post personal filenames to this public repository.
6. Use that actual inventory to identify each remaining writer/dependency and
   reproduce its layout before authorizing any admission change. Do not ignore
   all unknown files, reset storage, drop work or activate untested isolation.
   Where genuine unfinished work is found, it needs an ownership-aware recovery
   path, not a runtime-file exception.
7. Incident acceptance remains successful original-account native recovery on
   the affected installation, retained work/equipment intact, and close/reopen.
   This diagnostic patch cannot satisfy that acceptance by itself.

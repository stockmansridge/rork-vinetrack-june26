# Android retained-file incident: reviewed inventory (1 November 2026)

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

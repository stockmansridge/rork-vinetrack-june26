# Android ProfileInstaller recovery correction - 1 November 2026

## Status and scope

Source correction, not a delivered or device-accepted recovery build. Baseline:
`74b0fa32e3bec3c7292be124cd844d2b207554a1`.

Reported installation: Android 3.1.9 / version code `1793489340`,
`RETAINED_EVIDENCE` / `file_dependencies` / `FILES_UNREVIEWED_CONTENT`.
The diagnostic does not disclose the rejected file, so it cannot establish that
this is the only blocker on the original phone.

## Confirmed defect

The existing file scan recognises AndroidX ProfileVerifier's `profileInstalled`
file, but sends AndroidX ProfileInstaller's separate
`profileinstaller_profileWrittenFor_lastUpdateTime.dat` through the generic
empty-directory requirement. A valid runtime marker therefore produces exactly
`FILES_UNREVIEWED_CONTENT`, before retained-record inspection can finish.

AndroidX `ProfileInstaller.noteProfileWrittenFor(PackageInfo, File)` writes one
big-endian long (`PackageInfo.lastUpdateTime`) to that exact filename beneath
`Context.filesDir`. This is independent runtime bookkeeping, not a vineyard
record or proof of identity. Primary source:
https://android.googlesource.com/platform/frameworks/support/+/refs/heads/androidx-main/profileinstaller/profileinstaller/src/main/java/androidx/profileinstaller/ProfileInstaller.java

The new branch admits only the exact filename at the trusted files root, an
unaliased regular file with a single link, exactly eight bytes and a positive
recorded package timestamp no later than the installed package update. The read
uses O_NOFOLLOW, checks the opened descriptor against lstat, checks EOF and checks
the file again afterwards. Older timestamps are deliberately supported for an
in-place update. Invalid markers remain blocked with the fixed, private-safe
`PROFILE_INSTALLER_MARKER_CONTRACT` rule.

No files are deleted, moved, rewritten, uploaded, reassigned or auto-replayed.
The existing profile-verifier and logo validators are unchanged. Original-user
server verification, live vineyard access, retained-record validation and the
retention guard remain unchanged. There is no blanket file/directory allowlist.
No iOS, backend, billing, entitlement, sync or release-configuration changes.

## Validation actually executed here

- 16 parser test methods passed on Kotlin/JVM 1.9.0 / JRE 21. A minimal local
  JUnit-compatible annotation/assertion runner executed the checked-in test class;
  this was not a Gradle Android test run.
- 22 filesystem scenarios passed in a JVM harness using the exact original and
  patched file-scan methods, the unchanged RecoveryLocationContract, and Android
  API doubles over a real temporary Linux filesystem. The old scan returned
  `FILES_UNREVIEWED_CONTENT` for a valid marker; the new scan accepted the same
  bytes without mutation. Existing verifier checks, malformed/trailing data,
  stale/current/future timestamps, symbolic/dangling/hard links, lookalikes,
  unknown sibling files, retained photo files, camera files and trusted-root
  aliases were exercised.
- The original source copies were verified against Git blob IDs
  `e17754be6ef534ae2a464513459fb61023b9fd38` (AccountTransitionEvidence) and
  `cd1d518ff5bc9f0271f9ee243b31b1344ec50b3f` (RecoveryLocationContract).
- Ten native tests were added in ProfileInstallerRecoveryAndroidTest. These
  include the actual installed AndroidX writer, populated original-account
  recovery, wrong-account and revoked-membership refusal, and byte preservation.
  They have NOT been executed in this environment: no Android SDK/emulator.
- No signed AAB/APK was built or published here. No original-device acceptance.
  Do not reuse earlier 96-test results as validation of this new source.

## Required build and device handoff

1. Sync the final GitHub revision into the existing Rork mobile project. Confirm
   the new helper, changed AccountTransitionEvidence, and both new test classes
   are present. Preserve current unrelated source and managed configuration.
2. Compile Android normally. Run ProfileInstallerSkipContractTest and native
   ProfileInstallerRecoveryAndroidTest, then AuthRetentionAndroidTest,
   PopulatedCleanExitActivityTest and FieldSaveContentionAndroidTest. A previous
   focused source filter may exclude the new JVM filename; explicitly include it
   rather than reporting a zero-test pass. Do not disable assertions or weaken
   retention/ownership checks to make these pass.
3. Produce a signed Android 3.1.9 candidate using the existing application ID,
   signing identity and Google Play Internal Testing route. The managed version
   code must be greater than `1793489340`. Record the exact source revision,
   native test counts, build code and testing-track delivery result. No production
   publication and no iOS rebuild or version change.
4. Install as an update over the existing affected installation. Do not uninstall,
   clear app storage, downgrade, reset ownership, delete unknown files or toggle
   the disabled storage-isolation cutover. Restore using the original account;
   verify Home, retained work, vineyard/equipment data and close/reopen behaviour.
5. Only the affected phone establishes incident resolution. If another retained
   category remains, retain the data and investigate that actual category. A
   valid marker does not exempt unrelated unknown files or authorless work.

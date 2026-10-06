# VineTrack Android build investigation and fixes

Date: 2026-10-05
Project: t1ycqwwwkgzt982ur27ya
App: android-vinetrack
Package: com.rork.vinetrack

## Executive summary

The current Android source builds successfully. The investigation reproduced JVM heap pressure on the normal local compile command, then successfully compiled the entire unfiltered JVM test source set with the previously proven command-only 4 GB heap override. The managed release APK check passed, and a local release AAB packaged successfully.

This is not proof that a new build has reached Google Play. The previously reported stale artifact/version-selection issue remains unresolved and was not rechecked or mutated through Google Play in this audit.

No production Kotlin logic, database, credentials, signing configuration, dependency versions, versionName or versionCode was changed in this audit. The permanent changes improve build diagnostics and correct misleading configuration comments. The memory workaround is command-only; runner defaults remain an operational dependency.

## 1. Current build identity

| Item | Value |
|---|---|
| Application ID / namespace | com.rork.vinetrack |
| Source versionName | 3.1.6 |
| Source versionCode | 10 |
| Gradle wrapper | 8.14.3 |
| Android Gradle Plugin | 8.13.2 |
| Kotlin plugin | 2.3.10 |
| Java used by local audit | 17.0.13 |
| Compile / target SDK | 36 / 36 |
| Minimum SDK | 24 |
| Kotlin / Java bytecode target | JVM 11 |
| Release minification | Disabled |
| Release lint gate | Non-blocking: checkReleaseBuilds=false, abortOnError=false |

These are inspected source and diagnostic values, not a verification of the version currently on Google Play. Java 17 running Gradle and JVM 11 bytecode targeting are separate settings, not inherently a mismatch.

## 2. Issues and evidence

### A. Earlier production compiler error: already corrected

The preceding implementation checkpoint recorded a missing RegionFormatter import in FuelLogScreen.kt as the production compilation correction. The current file contains `import com.rork.vinetrack.data.RegionFormatter`. It was not edited again in this audit.

The previous unresolved `formatVolumePerLandArea` test references also did not recur on current source. Current production and full JVM test-source compilation both completed with the command-only memory override.

### B. JVM heap pressure: reproduced, operational workaround validated

Command used first, from android-vinetrack:

```bash
./gradlew :app:compileDebugUnitTestKotlin --console=plain
```

The run reached `:app:compileDebugKotlin` and reported:

- `The Daemon will expire after the build after running out of JVM heap space.`
- `The project memory settings are likely not configured or are configured to an insufficient value.`
- Its warning reported currently configured max heap space as `1.3 GiB`.

Process inspection showed a Gradle JVM launched with `-Xmx2g` and ParallelGC, with RSS roughly 3.1 GB near the end of observation. The warning's heap figure and the launch limit are both preserved as observed; they should not be treated as interchangeable measurements.

The run was deliberately terminated after approximately five minutes of heap-pressure compilation. It did not produce a completed build result and is not counted as an assertion failure or a completed compiler-error diagnosis.

A changed command then succeeded:

```bash
./gradlew :app:androidBuildDiagnostics :app:compileDebugUnitTestKotlin '-Dorg.gradle.jvmargs=-Xmx4g -XX:+UseParallelGC -Dfile.encoding=UTF-8' --console=plain
```

Observed result: `BUILD SUCCESSFUL in 4m 30s`; 22 actionable tasks, 5 executed, 17 up-to-date.

Important configuration distinction:

- Project gradle.properties requests a 2560m Gradle heap and out-of-process Kotlin compilation.
- The configured Gradle property reported by the runner was still `-Xmx2g -Dfile.encoding=UTF-8 -XX:+UseParallelGC`.
- With the command override, the final diagnostics recorded active JVM arguments `-XX:+UseParallelGC -Xmx4g` and Runtime max heap 3641 MiB.
- The configured Kotlin strategy reported `out-of-process`, and configured daemon arguments reported `-Xmx2g`. These property values alone do not prove the actual compiler process topology. No separate Kotlin process was observed in the sampled process listings.

Conclusion: editing only the project heap property is not a reliable fix for runner overrides. The command-only override removes the observed compilation blocker in this workspace, but does not permanently fix every managed export environment. The platform's actual invocation and effective memory settings must be captured before changing its defaults.

### C. Historical stale-test compilation warning: not current

The existing module Gradle file said two unrelated legacy test files did not compile. This audit compiled the normal unfiltered `src/test` Kotlin source set, with no focused source-selector property, successfully.

The specific old failures are therefore not established current blockers. That comment was corrected rather than changing or deleting tests unnecessarily. Existing focused selectors remain available for narrower, faster feature validation. No test assertions were executed in this audit, so successful compilation is not a claim that the full test suite passes.

### D. APK and export checks are different

The inspected project disables the release unit-test variant and creates a `testReleaseUnitTest` alias depending on `testDebugUnitTest`. An export that requests that alias therefore compiles and runs debug-variant unit tests; an `assembleRelease` APK check does not do so.

Consequences:

1. An APK can build while an export fails in test compilation or execution.
2. A focused source-selector result does not certify the unfiltered suite.
3. Debug tests are not proof of identical release bytecode: BuildConfig and debug dependencies may differ.
4. The alias and lint exemptions are existing workarounds, not full release certification.

The misleading identical-bytecode/full-coverage wording was corrected. No tests or lint gates were newly disabled.

### E. Historical AGP/classpath/export failures: not reproduced here

Existing Gradle comments describe prior missing Guava/JAXB classes, PluginCrashReporter errors, release lint-model failures and constrained-runner resource limits. Current code already includes explicit plugin-classpath dependencies, an early writable ANDROID_USER_HOME setup, download retries and stack traces.

Those signatures did not recur during this audit's full source compilation, managed release check or local bundle packaging. The export environment can differ; existing protective settings were preserved. Old comments are historical evidence, not independent verification of the current platform runner.

### F. Google Play stale artifact selection: still unresolved

Prior conversation reported a stale selected release code `1791031740` despite fresh AAB attempts. The source code inspected here remains versionCode 10 and versionName 3.1.6.

No Google Play upload, track promotion, version increment or artifact selection was attempted in this audit. A newly generated local AAB cannot prove the managed publisher selected or delivered it. This remains a separate publication investigation, not a current Kotlin source-build failure.

## 3. Permanent fixes made

### android-vinetrack/app/build.gradle.kts

Added the opt-in `:app:androidBuildDiagnostics` task. It reports:

- Application ID and source version identity.
- Gradle and Java versions.
- Active JVM max heap and a restricted list of memory/collector launch flags.
- Allowlisted Gradle/Kotlin memory properties and worker count.
- Whether the release unit-test task delegates to debug.
- Explicit warnings that lint is non-blocking and packaging is not Google Play delivery.

It does not print environment variables, API keys, local.properties contents, signing passwords or arbitrary JVM arguments. It runs only when requested and does not affect app runtime.

Corrected historical stale-test and identical-release/debug-bytecode claims. While validating the new diagnostic code, Gradle's `java` extension shadowed a fully qualified Java package reference; this transient script error was corrected by importing ManagementFactory directly. The subsequent managed check passed.

### android-vinetrack/gradle.properties

Corrected comments that simultaneously claimed a single in-process 4 GB compiler JVM and out-of-process compilation, guaranteed RSS safety from heap arithmetic, and that kotlin.daemon.jvmargs established out-of-process heap sizing. All executable property values remain unchanged.

## 4. Validation completed

| Validation | Observed result | Limit |
|---|---|---|
| Default local test-source compile | Heap-pressure warning; deliberately stopped | No completed result; zero tests executed |
| Full unfiltered JVM test-source compile, command-only 4 GB heap | Passed in 4m30s | Compilation only; not test execution |
| Final managed runChecks(android-vinetrack) | Passed; release build succeeded | APK validation, not Play publication |
| Local diagnostics + bundleRelease, command-only 4 GB heap | Passed in 16 seconds | Warm/up-to-date tasks; local signing, not managed Play upload-key certification |
| git diff HEAD --check | Passed | Whitespace/diff check, not runtime validation |

No UI/instrumentation tests or broad test assertions were run in this audit. The prior 62 focused Android test passes remain prior results, not new execution here.

Local AAB path:

`android-vinetrack/app/build/outputs/bundle/release/app-release.aab`

SHA-256 observed:

`296deee9e2d21b1c7c33fd792a1be4b8c4bdc40bcd7583f367f98a296b5f1bc5`

This artifact is diagnostic packaging output. Do not treat it as the managed, correctly upload-signed Google Play release. Normal source release signing remains debug; Rork's managed AAB export supplies the project upload key separately.

## 5. Evidence locations

- Default compile stdout/stderr: `.rork/tmp/android-build-audit-compile.log`, `.rork/tmp/android-build-audit-compile.err`.
- Full-source compile and initial diagnostics: `.rork/tmp/android-build-audit-heap4.log`, `.rork/tmp/android-build-audit-heap4.err`.
- Final diagnostics and bundle packaging: `.rork/tmp/android-build-audit-bundle.log`, `.rork/tmp/android-build-audit-bundle.err`.

These temporary logs may not survive workspace cleanup. The important findings, commands and artifact fingerprint are retained in this report.

## 6. Remaining risks and recommended next actions

1. **Managed runner memory:** capture androidBuildDiagnostics in the actual export job. Confirm launch flags, compiler execution strategy, resource budget and task order. Align that runner with an observed successful configuration rather than raising global heap values blindly.
2. **Google Play artifact identity:** use the project-bound publishing workflow to correlate managed build ID, AAB SHA-256, embedded package/version, upload-key certificate and the bundle/version accepted by Play. Then read back the target track. Do not increment versions blindly to work around stale artifact selection.
3. **Test execution:** full JVM sources compile, but full assertions were not run. Debug alias tests do not establish release-variant behavior.
4. **Lint:** release lint is already non-blocking. A green build is not a lint or store-policy certification; audit lint separately before release hardening.
5. **Cold builds:** the bundle run reused release tasks. It proves packaging in this workspace, not repeatability on an empty-cache export worker.
6. **Structural compile cost:** AppViewModel.kt is roughly 16,700 lines and several Compose screens are very large. That is a compile-memory risk worth profiling, but no production refactor was made solely on that inference.
7. **Non-blocking notices:** the managed check reports two legacy image storage URLs in SprayManagementScreen.kt and TripsScreen.kt. They still work and were left unchanged because they are not build blockers.
8. **Feature readiness is separate:** remaining Region & Units scope is not an Android build failure. At this build-audit checkpoint migration 265 was unapplied; the owner subsequently confirmed applying it on 2026-10-06, and live read-only schema inspection confirms the nullable basis field has no default. The dependency is now unblocked. The agent did not apply it or backfill records; the broader feature plan remains incomplete.

## Bottom line

Current source compilation, release APK checking and local AAB packaging succeed. The confirmed operational weakness is runner-effective memory configuration, not a reproduced current production symbol error. Diagnostics and inaccurate comments were repaired. Google Play artifact delivery, full assertion execution and release-policy certification remain separate unverified work.

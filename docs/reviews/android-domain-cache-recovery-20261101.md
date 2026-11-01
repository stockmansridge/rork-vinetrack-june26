# Android domain-cache recovery correction - 1 November 2026

## Incident boundary

Device report: 3.1.9 / 1793504699, RETAINED_EVIDENCE,
vinetrack_domain_cache / STORE_CONTRACT, count 44. The count is the size of
SharedPreferences.all, NOT 44 corrupt records. It does not identify the failed
key, dataset, parser condition, owner or scope. Private cache values were not
provided or read. The seven-file inventory is unchanged but assessment has
reached a later preference-store check. Descriptive UNRECOGNISED_PATH inventory
labels do not mean Maps admission is failing again.

Baseline: 292cd8da2b089ee7729b32537793c8f55549d362 (current main when inspected).
Its message says combined integration, validation in progress. Its source has
the Maps and spray-input-draft routes, but still has the old domain classifier
and the previously identified empty-only pruning-store branches. This does not
prove that the delivered managed build has exactly that source: Rork must
provide/push the final built revision, not just an intermediate checkpoint.

## Two source-confirmed defects

1. recoveryScopes called the voluntary clean-exit validator. That validator
   rejects every Trip.isActive, although DomainCacheStore.saveTrips accepts
   active Trip list snapshots. Authentication recovery and voluntary sign-out
   have different requirements. This source error can produce the reported
   STORE_CONTRACT, but the private phone values have NOT proven it was the
   specific failing condition on that installation.
2. recoveryScopes did not skip the already-validated spray_target_outbox key.
   The shorter spray_ prefix interprets it as vineyard target_outbox. Even an
   empty outbox can therefore manufacture a later vineyard-access failure.
   This is a separate defect, not evidence of the phone's current failing key.

## Source change

Only CleanExitCacheContract.kt changes application behavior. It now separates
CLEAN_EXIT from ORIGINAL_ACCOUNT_RECOVERY. Same-principal cache inspection
accepts a structurally valid, correctly scoped active Trip list snapshot without
creating an ActiveTripStore claim or changing that row's operator. Original
cache owner is still mandatory, and SessionStore.restoreOriginal still verifies
all returned scopes against current access. ActiveTripStore, retained outboxes,
replay, ownership, original-principal checks and credential admission are unchanged.
Clean exit still refuses active trips. Nonempty spray-target outboxes still fail.

Metadata keys are excluded from scope-prefix matching only AFTER validation.
Unknown keys, corrupt JSON, wrong types/timestamps, foreign row scopes, missing
child parents and future unknown fields remain failures. No blanket
ignoreUnknownKeys change, cache clear, re-download, repair/rewrite, reassignment,
acknowledgement, backend change, storage cutover or release is performed.

Failures now use fixed dataset/condition rule codes, e.g.
DOMAIN_TRIPS_DECODE_SCHEMA, DOMAIN_TRIPS_TIMESTAMP,
DOMAIN_CACHE_OWNER_MISMATCH, DOMAIN_WORKTASK_LABOUR_RECOVERY_SCOPE.
No parser text, raw value, scoped key, account identifier or filename is included.
The existing UI's Copy recovery diagnostics consumes these typed failures.
Chemical-store and device-preference validators are byte-for-byte unchanged.
All prior combined iOS/Android spray changes are inherited from the baseline;
AccountTransitionEvidence.kt is not replaced or edited in this correction.

## Executed validation - limited, not native acceptance

The baseline source was reconstructed and its Git blob verified as
4e8fbd111b2063a9a77508f0f4070176463fde48. Modified source blob:
eb9509d61e53515201d1f4a720f1116eae48967f.

The unmodified production classifier reproduced both defects in a Kotlin/JVM
harness. The modified production classifier compiled and passed 18 control-flow
checks. The harness uses explicit model and JSON doubles: it does NOT run real
kotlinx serializers, Android APIs, authentication transport or an application.
These results must not be reported as native/Gradle or phone acceptance.
The local red/green harness and logs were retained in the conversation artifact.

Added (not run here): 18 Gradle/JVM tests in DomainCacheRecoveryContractTest using
real production serializers, and 6 instrumentation tests in
DomainCacheRecoveryAndroidTest using actual DomainCacheStore/SessionStore,
synthetic isolated preferences and direct admission. The latter deliberately
does not contact real backend accounts; existing AuthRecoveryRepository tests
must also pass. Matching a synthetic fixture's key count to 44 does NOT reproduce
the actual phone's data. No SDK, signed APK/AAB or on-device result is claimed.

## Rork handoff / delivery gate

1. Reconcile this correction with the EXACT managed source used for 1793504699;
   push the complete delivered revision and retain any newer pruning work.
   Do not reset to this baseline or drop either earlier repair.
2. Run both new test classes with real libraries/APIs and all relevant auth,
   retained-state, Maps, ProfileInstaller, spray-draft and resume regressions.
   Confirm actual discovered counts. Add native UI proof that an active cached
   trip is not adopted for tracking or resumed on the wrong device.
3. Expand writer-produced domain-cache fixtures to each persisted group,
   representative nonempty data, historical supported formats, quick actions,
   task children, trip/spray snapshots and mixed group ordering. Do not change
   tests to ignore a failing legitimate writer output.
4. Complete/verify the previously required pruning and pruning-yield recovery
   contracts. Current GitHub baseline still contains empty-only admission for
   these populated stores; this patch intentionally does not bypass that.
5. Test the entire reported populated-store topology, not just isolated domain
   fixtures. Preserve exact retained bytes and original authorities. Do not
   ship another partial candidate with a known unsupported ordinary store.
6. After complete native validation, deliver an in-place Android 3.1.9 Internal
   Testing update with code above 1793504699 and any later uploaded code, using
   the existing identity/signing. No production release. Keep all combined
   spray actuals/resume changes; no additional iOS change is required by this patch.
7. Report final commit, source reconciliation, native results and delivery ID.
   Keep incident open until the original installation reaches Home, retained
   records and equipment are intact, and close/reopen succeeds. Any remaining
   cache error must provide the new specific rule, not a generic STORE_CONTRACT.

# Android saved chemicals and multi-store recovery preflight

Incident OPEN. Source repair is not proof of recovery on the original phone.

## Latest handset evidence

The supplied Android 3.1.9 / version code 1793518944 report stops at RETAINED_EVIDENCE, vinetrack_saved_chemicals_local, STORE_CONTRACT, entry count 1. The inventory contains a 134093-byte chemical snapshot, a 10239970-byte domain cache, populated pruning/settings and actual-tank stores. No private values or records were supplied.

The generic count is the number of SharedPreferences entries, not the number of chemical rows. The change from the previous domain/yield blocker identifies a different reported stop; it does not establish complete recovery or exact installed-build source linkage.

## Confirmed source defects

At inspected main 8f902083f6b9b995077bd76834fc540cd14230ab, SavedChemicalLocalStore loads supported older JSON with the production serializer. CleanExitCacheContract separately requires that re-encoding the decoded rows with encodeDefaults=true exactly equals the supplied JSON. A later nullable/default field, such as vineyard_preferred_rate, makes a compatible older snapshot unequal even though all supplied information survives.

Some nested rate serializers are permissive and can return an empty list on malformed input. Simply deleting the comparison, enabling ignoreUnknownKeys, or treating decode failure as an empty cache would therefore be unsafe.

AccountTransitionEvidence also stopped at the first failed store. Copy diagnostics could use only the cached first failure, leaving later independent blockers undisclosed.

These defects are identified in source. The precise private chemical payload on the handset has not been inspected; do not claim that a missing optional field is definitively its only blocker.

## Bounded correction

Production checkpoint: f511b0a9e96518f4ee3176775b2f812b2e927a44.

- Strictly decode with the existing production model, then compare every supplied JSON field, type, value and ordered array element. Added optional defaults are permitted. Dropped or changed evidence is not. Exact decimal comparison permits numeric spelling such as 300 versus 300.0, but not string/number coercion, altered quantities or rounded large integers.
- Emit fixed chemical-specific validation codes without stored keys, identities, amounts or parser messages.
- Keep the original exact account and vineyard storage namespace, row-scope, preferred-rate, pending-operation and live-membership requirements unchanged. The store still uses exact account|vineyard keys; this repair does not adopt or redirect alias namespaces.
- After filesystem safety checks pass, inspect every independent business preference store and collect one failure per failing store. Any failure still denies admission. Unsafe locations stop content inspection before preference values are read.
- Copy diagnostics performs a fresh read-only inspection and includes the local blocker list. Local findings do not establish server-side pruning verification or successful authentication.

No writes to retained data, no fabricated acknowledgement, no queue clearing, no replay, no account adoption, no changes to iOS/backend/Quadrant Count, no version/signing changes and no store upload.

## Added tests and validation boundary

SavedChemicalRecoveryContractTest contains 18 production-serializer JVM cases: current and older snapshots, omitted optional fields, legacy rates, exact storage namespace, foreign account/vineyard, duplicates, malformed/unknown/lossy content, invalid preferred rates, retained writes, numeric precision and a populated mixed 100-row snapshot.

The imported ChemicalRecoveryPreflightAndroidTest contained four native cases, but its success used direct proof/admission and populated only a pruning setup, without a recovery snapshot. Managed validation extended it to five cases with populated production-written setup/entry/activity/labour/settings, a nonempty recovery snapshot, yield, old chemicals, pending actual amounts and exact input draft together. Recovery now calls AuthRecoveryRepository through independent intercepted token/user/membership/live-vineyard and pruning projections. Wrong account, revoked membership and unknown chemical fields fail globally with unchanged retained bytes; unsuccessful replacement credentials are locally revoked. Existing DomainCacheRecoveryAndroidTest remains included. A new rendered MainActivity case adds wrong-account refusal, correct form recovery, Home, Activity close/relaunch and reopened values with historical caches, snapshot, held queues, receipts, logo, pruning and acknowledged actuals plus draft. The acknowledged actual fixture is synthetic, not a backend acknowledgement of customer work.

The explicit JVM selector also includes DomainCacheRecoveryContractTest, PruningRecoveryVerifierTest, RetainedPlanningContractTest and SprayTankActualTest. It is not the whole Android suite.

Actions run 41287674297 completed successfully at 2026-11-01T09:22:08Z; both reviewed-source and android jobs succeeded, including serializer/debug compilation and emulator steps. Run head is 7165f01827089d864ab193eb2189b0ca8a2e3a09, not PR head dd021b953c284b61f5d334051a5fa18254048c71 or production checkpoint f511b0a9e96518f4ee3176775b2f812b2e927a44. The workflow's Android checkout uses needs.reviewed-source.outputs.source; exact resolved checkout SHA/raw success reports were not independently retrieved here. Saved run/job API responses record the observed final status, not an inferred CI test count. The CI Config.kt is synthetic, uncommitted, and uses an invalid backend URL. It supports debug compilation and isolated tests only, not release signing or real authentication. It must never be used for a distributed candidate.

## Managed results, 1 November 2026

- Starting managed HEAD1973aa4c44b947b43c149660a8f7380a8b5aa5c1 is not the final repaired revision. Exact nine-file delta integration and protected configuration hashes are in evidence/pr32-20261101/integration.json. The branch workflow was excluded. Subsequent native-fixture improvements are separate from that import.
- Fresh production-configuration JVM run:62 passed,0 failed/errors/skipped, five actual XML reports (18 chemical,21 domain,13 pruning,3 planning,7 tank actuals) and raw Gradle log under evidence/pr32-20261101/jvm-final/. No production files or tests were excluded from the application compilation; only the five requested JVM files were explicitly selected using the existing hook.
- Focused combined native selection:4 passed/0 failed/0 skipped in11s; focused rendered combined journey:1/0/0 in18s. Final20-class affected selection:255/0/0 in250s. Added explicit isolated-auth refusal of unknown chemical fields with every store populated; final five-case combined class:5/0/0 in10s. Focused and broad selections overlap; do not add their counts.
- Native pass counts are observed tool-result transcriptions, not raw success logs. The mutable /tmp native log still contains a previous PR #31 202-tests/2-failures run; preserved only as stale-tool-log-not-pr32/prior-pr31-202-tests-2-failures.log, never as PR #32 success. Duplicate attempted copies were removed after inspection. No native failure occurred in the PR #32 tool results above.
- Separate normal runChecks(android-vinetrack):PASS with real managed configuration. Two existing nonblocking asset-address advisories unchanged. Mocked authentication exercises the production recovery path, not live credentials or customer backend records. Activity close/relaunch is not a killed-process restart or original-handset acceptance.
- Google Play connection and com.rork.vinetrack package access pass. Listed older bundles have no verified mapping to this repaired checkpoint. No current managed snapshot/sourceHash identifying these uncommitted repairs was available; no identifiers were invented and no older build was selected. No generatePlayAab, version allocation, Play validation/commit, upload or new submission occurred. Final automatic sync and exact-source Play build remain open gates.
- iOS, SQL/Supabase, signing/package/version configuration and storage-isolation activation remain unchanged. Prior iOS/backend incidents are not resolved by this Android follow-up.

## Final inventory qualification

The final inventory found the ignored real Android Config.kt no longer matches its import-time protected hash: expected c79d68f9e9dc96559263dee80de69190df5c3886eab29a2f613104989d78eab7; observed a1da2e0589dbe2e6430459e36a7e32dc93c4b15c846e6bc7cccbc1499a4712e8. The import itself preserved configuration; the later mismatch cause and equivalence to configuration used during validation are unverified. No values were disclosed, guessed or restored. Other protected configuration hashes match. evidence/pr32-20261101/validated-checkpoint.json records a blocked inventory, not release certification. Reconcile real runtime configuration and its validation provenance before an exact-source candidate, in addition to the existing managed-sync/source/build gate. Earlier passing results remain observations, not proof of this final configuration's equivalence.

## Rork handoff and release gate

Integrate this exact delta into current managed source while preserving newer work. Resolve every failed test rather than deleting assertions or skipping files. Review/remove the temporary branch-specific workflow and confirm the managed source-to-build link.

Before another recovery candidate, reproduce the old chemical false rejection with the real serializer and prove recovery with populated chemical, yield, pruning, recovery-snapshot and actuals stores together. Exercise the normal isolated authentication/live-membership path, close/reopen, retention and wrong-account/revoked-membership refusal. The added fixture is useful but not a complete replica of the original handset.

When those gates pass, prepare an in-place Internal Testing update using the existing signing identity and a version code greater than 1793518944 and every subsequently uploaded code. Report exact source/build receipts. Do not release publicly or require reinstall/storage clearing.

If the original handset still refuses recovery, collect the complete fixed-code blocker report from that installation before proposing further changes; do not ship a one-store allowlist change or claim success because the first error changed. Recovery remains OPEN until Jonathan can access the original account, see retained work and close/reopen successfully.

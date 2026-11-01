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

ChemicalRecoveryPreflightAndroidTest contains four native cases: populated chemicals + yield + pruning + actual tank quantities together with reopen and unchanged snapshots; multiple simultaneous blockers without data disclosure; wrong-account/revoked-membership refusal; and unsafe filesystem locations stopping content inspection. Existing DomainCacheRecoveryAndroidTest is included in the emulator selection.

The explicit JVM selector also includes DomainCacheRecoveryContractTest, PruningRecoveryVerifierTest, RetainedPlanningContractTest and SprayTankActualTest. It is not the whole Android suite.

Actions run 41287674297 validates the final production checkpoint above. At this documentation checkpoint its Android build/test job was still running; no native or JVM pass is asserted here. Read final job logs and XML results before claiming any pass. The CI Config.kt is synthetic, uncommitted, and uses an invalid backend URL. It supports debug compilation and isolated tests only, not release signing or real authentication. It must never be used for a distributed candidate.

## Rork handoff and release gate

Integrate this exact delta into current managed source while preserving newer work. Resolve every failed test rather than deleting assertions or skipping files. Review/remove the temporary branch-specific workflow and confirm the managed source-to-build link.

Before another recovery candidate, reproduce the old chemical false rejection with the real serializer and prove recovery with populated chemical, yield, pruning, recovery-snapshot and actuals stores together. Exercise the normal isolated authentication/live-membership path, close/reopen, retention and wrong-account/revoked-membership refusal. The added fixture is useful but not a complete replica of the original handset.

When those gates pass, prepare an in-place Internal Testing update using the existing signing identity and a version code greater than 1793518944 and every subsequently uploaded code. Report exact source/build receipts. Do not release publicly or require reinstall/storage clearing.

If the original handset still refuses recovery, collect the complete fixed-code blocker report from that installation before proposing further changes; do not ship a one-store allowlist change or claim success because the first error changed. Recovery remains OPEN until Jonathan can access the original account, see retained work and close/reopen successfully.

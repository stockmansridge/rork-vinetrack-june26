# Occurrence coverage implementation checkpoint — 2026-10-14

## Status: partial implementation, not the completed Live Trip pass

The user approved implementation of the occurrence amendment and all original Live Trip work, with no production SQL/deployment/release. This checkpoint records the first backend dependency slice only. No additional approval is required to continue the authorised application implementation.

- Observed starting branch: `main`.
- Observed starting HEAD: `8e4893647774e9d9bced6bda1bfd4fec92223858`.
- Application/source working tree and index were clean. Only managed history had pending changes; it was left untouched.
- Inventory/Upcoming corrections, native Android/iOS application files, Supabase edge functions and previous SQL files remain unchanged.
- No live backend calls, production SQL, migration deployment, historical rewrites, app release or store submission.

## Files and authority

- `sql/276_trip_occurrence_authority_v1.sql`: nullable prospective document; NOLOGIN/NOBYPASSRLS RPC owner; scoped operation ledger; sticky numeric/downgrade guard; document and new geometry/setup admission; create, activate, action and finalise RPC definitions.
- `sql/277_trip_occurrence_reports_v2.sql`: v2 independent occurrence rows; conservative prospective v1 adapter; guard against numeric recovery evidence for new trips. Existing non-row report authorization/facts are delegated to the current canonical reader.
- `sql/tests/276_trip_occurrence_bootstrap.sql`: minimal synthetic auth/schema/report harness. TEST ONLY, never suitable for an existing database.
- `scripts/test-trip-occurrence-authority.py`: disposable PostgreSQL 17 cluster initialized under a private temporary directory; Unix socket only, no TCP listen; ignores PG environment configuration and accepts no remote URL.

For non-null occurrence documents, the document and ledger are sole authority. Numeric `completed_paths` and `skipped_paths` remain empty. Legacy NULL documents retain legacy rules; unsupported non-null documents do not downgrade.

## Executed validation

Command: `python3 scripts/test-trip-occurrence-authority.py`.

Latest observed result: **46 tests passed, zero failures/errors, 2.073 seconds** (fresh local cluster). `git diff --check` passed. Earlier development runs exposed harness session-role/boolean parsing issues, an ambiguous SQL column reference and a fixture that failed at an earlier physical-reference guard; these were corrected and the final selection re-executed.

Coverage includes:
- First Done/second Incomplete; second Done/first Incomplete; Done/Skip; Skip→Done; targeted Undo preserving the other pass.
- Incomplete→Done→Skip→Undo restoring immediate prior Done state, not numeric predecessor.
- Exact operation retry returning the original result after later actions; duplicate operation concurrent submission; competing stale revisions with exactly one winner; changed intent under one operation ID rejected.
- Trip/plan/block/account/setup-scope conflicts; canonical UUID enforcement; null/duplicate/fabricated row references rejected; stored geometry snapshots checked at NEW-item admission.
- Route reorder preserving IDs/states, retirement preserving performed evidence and replacement starting Incomplete.
- Explicit occurrence selection changing no coverage.
- Structural automatic-action admission for one selected A or B; ambiguous repeated work requiring selection; no reuse of one evidence run ID to credit another pass; Pause and unresolved geometry rejected.
- Failure injected at ledger INSERT rolling back the preceding Trip state write, with no accepted operation record.
- Saved-plan activation barrier/idempotency; finalisation preserving untreated work, requiring reviewed revision and explicit tank end; no automatic tank termination.
- Empty legacy arrays, old numeric/route/finalisation/NULL-downgrade rejection, inaccessible writer role, spoofed GUC rejection and direct ledger mutation denial.
- Prospective v2 A/B rows, conservative v1 output, retired report evidence, future-version rejection and report/private-alias permissions.
- Legacy unique and duplicate-path fixture rows unchanged apart from the newly added nullable column, and legacy v1 report fixture output unchanged.

### What those tests do NOT prove

- The automatic tests submit synthetic qualified action envelopes. They are NOT production GPS traversal/evaluator tests and do not prove Android or iOS automatically completes a driven path.
- Each request uses a fresh SQL connection, but these tests are NOT Android/iOS offline queues, application process restart or OS lifecycle tests.
- Report tests use a stub for existing non-coverage report facts. They validate the new adapter's row semantics/delegation, NOT the entire applied 225/227/228/229/232/234 chain, real cost privacy or deployed schema/ACL/trigger ordering.
- No Kotlin or Swift source changed, so no native build/tests were run for this slice. Backend validation here is real local PostgreSQL compilation/execution, not mobile `runChecks`.
- No actual Portal application integration or screenshot/device acceptance has occurred.

## Remaining implementation and verification

The overall pass remains open. Required next work, already authorised:

1. Align the staged SQL foundation with the full current non-production schema and native wire fixtures. Review create allowlist/default preservation and all existing start metadata; do not drop work-task/seeding/worker/other current setup fields during native transport adaptation. Verify actual migration privileges, function owners and trigger ordering.
2. Complete legacy-derived row-ID admission for rows lacking stored IDs, with golden Kotlin/Swift/SQL identity tests. Current foundation admits stored row IDs/snapshots; unresolved references remain manual-only. No fabrication or silent loss of eligibility.
3. Shared Kotlin/Swift raw-preserving discriminator/model mapping and durable journals; producer generation, actual-action history, ordered replay and session/account/acknowledgement fencing. Explicit incompatible-version/update-required states in updated clients.
4. Android/iOS creation, route edits and all occurrence mutators, narrow iOS evidence ownership, cross-platform handover and offline persistence tests.
5. Native v2 report/read/export and occurrence-keyed End Review; integration through the full canonical chain and external API/recovery capability updates.
6. Production Android traversal evaluator/manual correction, with real callback integration and the complete positive/negative evidence suite. Never enable against numeric ambiguity.
7. First-tank retained Actual confirmation before recording; active/next tank controls; ETA; geometry-based map context; density and responsive layout fixes.
8. Native tests/builds and requested matched screenshots; separately report physical field acceptance and Portal release gate.

## Portal integration requirement

Portal source is unavailable here. It does NOT block safe implementation/testing of available components, but DOES block end-to-end release acceptance.

- Recognise NULL legacy versus explicit occurrence contract/version; unsupported non-null means unsupported, not legacy.
- Use `get_spray_report_v2` for new trips, key rows by `occurrenceId`, retain block identity/pass context and show A/B independently in screens, PDF and CSV. No number-based deduplication or v2→v1 fallback for occurrence trips.
- Any new plan/action/finalisation writer must use the versioned RPCs and retain operation IDs across uncertain retry. No numeric/downgrade writes.
- Validate A Done/B Incomplete; A Done/B Skip; Undo A preserving B; B first; identical 38.5 in two blocks; legacy unique and duplicate fixtures unchanged.
- Supply updated source/integration evidence and rendered results before claiming Portal acceptance.

## Future migration/deployment order — NOT executed or ready to release

1. Finish and validate all available components first; preserve inactive producers until the contract capability is verified. The current SQL is an undeployed foundation checkpoint, not a deploy-now instruction.
2. In an explicitly authorised isolated/staging environment, inspect the applied schema, role privileges, all existing Trip/recovery triggers and full canonical report wrapper chain. Verify the dedicated RPC role can be created with no login/membership/bypass privileges; do not substitute a spoofable request/GUC bypass.
3. Apply the reviewed authority migration 276, then report/recovery adapter 277, in tracked transactions. They contain no historical data UPDATE/backfill. Once guards are installed, occurrence-aware rows can only be created/changed through supported RPCs; existing numeric rows retain legacy semantics.
4. Update the available API/recovery consumers and deploy native/Portal readers before enabling new-trip occurrence producers. Verify old-client rejection, actual role policies and non-row fact/privacy parity. Do not silently enable when RPCs/columns are missing.
5. Enable prospective producers only after Android↔iOS replay/read acceptance and required Portal integration. Then complete emulator and physical field acceptance.
6. Production migration, backend deployment, native release or store submission require separate authorisation. None is performed by this pass.

## Tested file fingerprints

- 276 authority: `d465d47dc11fae6b1620cd90b4bf78e5977655c831729857818cef0f652debce`
- 277 reports: `94925d9a6d3e7b2644a8179fc4961931db4cf55f787e3de55cb45baa0b3e4445`
- Bootstrap: `5a86f86b05d627167fc852fcd5849d2bbe78cac5f8df86acd4d2771612e1fee0`
- Runner: `dc0763549d9f1838005cb202d0f89fa4ab11d44a9918cdccd5d27e58386c17a0`

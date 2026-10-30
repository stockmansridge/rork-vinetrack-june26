# Android missing blocks / contradictory sync status - 30 October 2026

## Scope and evidence

User screenshots show **JH Testing**, Home `Not synced`, `Vineyard data unavailable - refresh to retry`, and no selectable blocks. User reports Sync Status nevertheless says up to date. This prevents testing the separate Android Work Task save repair.

Read-only production verification found **12 active JH Testing paddocks, 12 total**, with the latest block update on 9 October. A transaction-local authenticated-role check using the original account's JWT claims also selected all 12 active paddocks; the transaction was rolled back. The actual Stockmans Ridge vineyard still has 8 active blocks. No customer data was changed, and no blocks need recreation.

Around the screenshot period, project Ktor-client traffic contains failed refresh-token requests (400) and rate limits (429); Auth logs report `refresh_token_not_found` and `over_request_rate_limit`. The inspected recent Android requests did not show a successful JH Testing paddock download. iOS and Portal reads succeeded. Failed authentication logs do not carry an authenticated actor, so they do NOT independently prove which exact handset/account sent every failed refresh. Do not claim the original phone is fixed from project logs, or infer a password change or wrong password.

The source base is main `50438333921355136fc8d81a375affc8a3334da0`, preserving the integrated iOS PR24 recursion correction, PR23 weights/Trip changes, and Android Work Task recovery.

## Confirmed source defects

### 1. Legacy GoTrue error code is masked

`RefreshRejection.isDefinitive` previously read `(error["code"] ?: error["error_code"])`. Legacy GoTrue's error schema has a numeric HTTP status `code` and a separate machine-readable `error_code`. For `{"code":400,"error_code":"refresh_token_not_found"}`, the classifier selected `400`, incorrectly treating a definitive rejection as transient. The existing pre-send refresh gate then prevents data downloads, while further callers can repeat the failed refresh instead of entering retained-account recovery.

Correction: read string error fields explicitly, support legacy `error_code` and modern string `code`, and reject contradictory structured codes conservatively. No free-form message matching. HTTP 429/5xx are never credential-rejection evidence. Existing original-account/refresh-incarnation fencing and data-retention recovery remain unchanged. The change does not itself make an invalid refresh token valid: same-account recovery may still be required.

### 2. Empty upload queue is misreported as successful download

Home already uses `HomeReadKnowledge`. Sync Status previously marked each area `Up to date` whenever no outbox entries existed, even with no download timestamp. The Blocks row has no outbox entity types, so missing downloads could appear green indefinitely.

Correction: project known read state separately from outbox state. Unknown is `Not downloaded`, cached is saved data, a failed block read shows the existing scoped `paddockError`, and only a successful fresh online read is current. A timestamp alone is labelled historical download evidence. Recompute visible timestamps after the read state changes. Connectivity no longer promises server saves, and a delayed refresh request no longer unconditionally displays `refreshed`.

## Changes / unchanged boundaries

Production paths:
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/auth/RefreshRejection.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/SyncDownloadStatus.kt` (new pure presentation policy)
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SyncStatusScreen.kt`

No database migrations, RLS changes, token edits, account resets, block changes, replay changes, queue clearing, archive deletion, iOS/Portal changes, dependency upgrades, release counters, signing or upload. Cached/unknown/empty remain distinct; the UI fix does not fabricate blocks or success.

## Executed validation and limitations

Local Kotlin/JVM policy checks passed **67 refresh-code scenarios and 32 download-state combinations**. Eight source-wiring checks passed. The old code-precedence defect was reproduced using the exact old decision and Python's JSON parser: it selects numeric 400 and misses the machine-readable rejection. This is NOT an execution of the old shipping Android JSON stack.

Production blobs were verified byte-for-byte against the checked local sources:
- RefreshRejection: `19cb2cc38f20dfb37ba030e1c126c1a90680b948`
- SyncDownloadStatus: `4518bec98c425c3cbdc178b53e396d6319e2e3e8`
- SyncStatusScreen: `fc9fa7d0933f6bde8ec926b736bfab0d25c85e34`

`python3 scripts/test_android_download_status_host.py` retains the bounded reproducible policy checks. It requires existing kotlinc/java and never installs dependencies. The host compiles the exact pure production policy, actual HomeReadKnowledge and download presenter; it does not compile Compose or the kotlinx JSON classifier.

Added native JUnit suites: `RefreshRejectionLegacyTest` (real JSON classifier) and `SyncDownloadStatusTest`. These native suites, existing auth/recovery integration tests, rendered Sync UI, native build and original Android handset are **not run/verified in this environment**. This is a draft repair candidate, not a delivered or certified device fix.

## Required Rork closeout

1. Preserve newer work. Record the original phone's installed version/code, candidate source SHA and selected account/vineyard. Integrate only the scoped correction; do not overwrite main with an older repair branch.
2. Run the new JUnit tests plus existing `HomeSyncStatusTest`, auth-retention/session-refresh and same-account-recovery regressions, then the normal Android build. Do not repeat broad unrelated suites or alter iOS.
3. Use actual repository/session code with a legacy numeric-code rejection fixture. Verify it enters existing protected same-account recovery exactly once, retains draft/outbox bytes, and does not storm the refresh endpoint. Check modern errors, stale in-flight rejection after a newer login, transient/offline failures and 429 handling without clearing credentials on mere transport failure.
4. Render Home and Sync with an empty outbox and Unknown blocks: neither may claim successful download. Repeat with a failed read, saved offline data, and a legitimately empty successful read. Preserve tenant isolation when switching vineyards.
5. After controlled same-account recovery on the existing installation, verify a successful block response for **JH Testing** and all **12 blocks** visible on Home/Blocks and in Work Task and Trip selectors. Restart offline after a successful cache write and verify the same blocks remain available under authorised cached access. No reinstall, data reset or block recreation.
6. Check the original retained Work Task only after its block picker is operational. Do not create a duplicate task just to test this change.
7. If valid-session downloads still fail, capture the selected account/vineyard generation, failed stage/status and safe decoding path. Investigate cache-preservation admission and stale-load fences; do not disable those protections or declare this parser change the only possible root cause.

Do not mark the original incident resolved until the original Android installation demonstrates both block availability and honest sync status.

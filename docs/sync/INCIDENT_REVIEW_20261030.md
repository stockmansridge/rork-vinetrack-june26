# 30 October 2026: field access and sync compatibility findings

This document supplements OPERATIONAL_REPAIR_CONTRACT.md. It records verified findings, not a declaration that either release is ready.

## Production evidence and completed repair

Stockman's Ridge retains two active tractors (Kubota 7580, New Holland T4.N) and both spray units (Hardy Undervine Sprayer, Quantum 420). The older differently spelled tractor was soft-deleted on 5 May 2026, not by this incident. Modern machine records remain. Legacy tractors and new machines have different IDs; preserve legacy_tractor_id mappings rather than joining names.

Android equipment requests in the inspected logs returned HTTP 401/expired JWT. Refresh returned refresh_token_not_found. That is rejected authentication, not deletion. Do not reset the device or widen permissions to treat an invalid token as valid. Same-account recovery must retain original queues and evidence.

Earlier GRANT migrations did not establish auth schema USAGE: the project role lacked grant option on the managed schema. The applied migration occurrence_actor_identity_bridge_v1 provides an identity-only SECURITY DEFINER wrapper returning auth.uid() unchanged. The five occurrence RPCs retain their restricted owner, signatures, RLS and vineyard authorization. Only the restricted writer can call the bridge; PUBLIC, anon and authenticated cannot execute it directly. Receipt policy still requires actor equality. Source: supabase/migrations/20261030223000_occurrence_actor_bridge.sql.

Rollback-only database checks passed: five missing-identity rejections; five invalid authenticated request rejections; legacy Trip insert/read/update; rejection of direct protected occurrence edits; versioned create/exact replay/receipt recovery/activation; two retained operation receipts; missing/unauthorised Trip recovery rejected. All synthetic records rolled back. No customer Trip was started and no chemical recipe was approved.

## Source coverage and additional gaps

The static inventory discovers 37 iOS coordinator calls, 38 Android persisted pending-write discriminator values, 650 literal HTTP resource callsites and 185 dynamic resource callsites, plus 12 independently scheduled queue/cache families. The registry contains every discovered coordinator and discriminator; the generated report gives every resource's file and line.

The gate now fingerprints file/API/route and multiplicity for both literal and dynamic calls. A changed endpoint outside the main coordinator fails the register check. Line shifts do not. Eleven focused source tests pass. Passing an inventory is not passing every serializer, deletion or permission scenario; both release-baseline booleans remain false.

76 distinct literal relation candidates were checked against public schema, excluding the pseudo-route rpc. 74 exist; all existing ordinary tables in that selection have RLS enabled and authenticated SELECT grants. This is metadata coverage, not proof that each user's policies return correct rows.

Additional confirmed contract gap: Android AlertPreferencesRepository reads/writes alert_preferences, which is absent; iOS/backend use vineyard_alert_preferences. The DTO fields substantially overlap, but correcting a shipped client requires a tested legacy adapter or client fix, not silently creating a replacement table/view. Track this before claiming all-entity compatibility. The weather_daily_gdd references are inside LEGACY_SUPABASE_ENABLED in the inspected iOS source; verify the shipped flag before declaring a live dependency.

Memberships, some joins/allocations/row segments, attachment metadata, immutable audit records and caches do not all have updated_at/deleted_at/sync_version. They need per-parent snapshots or event contracts, not a blind universal timestamp cursor. Existing iOS phone-time watermarks and broad Android list refreshes remain architectural work.

## Test evidence and exact limits

Android source eb082dd9b483af0867fbe43a797cdd040ebafeaa compiled and passed 125 unique focused tests in nine suites. A later unchanged-Android run against eb592eaa6b1f9feebcf0448930e34d41a95100f6 also succeeded. Duplicate XML copies must not double the count.

The first two iOS runs stopped at compiler type-check complexity in TripDetailView before tests. The follow-on patch only decomposes existing result builders and modifier chains; it retains every original row, ordering, text and start guard. Its syntax and exact before/after checksum checks pass locally; native compilation/tests must be checked from the new run, not assumed from those checks.

The exact signed 3.1.8 source/build pair, all-entity old/new round trips, large-history measurements and original-device recovery remain unverified. Do not switch release verification booleans merely because the app compiles.

## Coordinated next gates

1. Finish native iOS compile/test and preserve exact source SHA, artifacts and failures.
2. Verify same-account Android reauthentication, equipment display, offline restart, retained local edits and empty-versus-unknown state without uninstalling or clearing storage.
3. Verify original iPhone Trip replay and receipts. Actual Start still requires original recipe/identity and explicit reviewed-rate evidence; never manufacture consent or a replacement Trip.
4. Run the per-family contract matrix from OPERATIONAL_REPAIR_CONTRACT.md against both old and new clients, including all independent queues.
5. Pilot additive server-controlled delta cursors on equipment/settings before expanding. Preserve 3.1.8 routes. Publish usable local data first, separate urgent ordered writes from history and media, and measure calls/bytes/rows/main-thread work for cold, no-change, ten-change and 1x/10x/100x histories.

No main merge, release upload, minimum-version increase, mass deletion or generic auth-policy rewrite is part of this audit. Keep one coordinated PR #22; do not stack unrelated releases while these gates are open.

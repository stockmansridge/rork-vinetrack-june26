import Testing
import Foundation
@testable import VineTrack

/// Phase 2A — tests for the pure combined-access decision core used by
/// `EntitlementGate`. Mirrors the agreed contract:
///   Supabase grants → access (paywall suppressed) → RevenueCat fallback →
///   legacy trial fallback → offline cache (network failures only) → paywall.
struct EntitlementDecisionTests {

    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private func input(
        enforced: Bool = true,
        server: EntitlementServerResult,
        rcEntitled: Bool = false,
        rcResolved: Bool = true,
        freeWindow: Bool = false,
        offline: Bool = false,
        cache: EntitlementDecision.CacheInfo? = nil
    ) -> EntitlementDecision.Input {
        EntitlementDecision.Input(
            enforcementEnabled: enforced,
            server: server,
            revenueCatEntitled: rcEntitled,
            revenueCatResolved: rcResolved,
            inLegacyFreeWindow: freeWindow,
            isOffline: offline,
            cache: cache,
            now: now,
            offlineGraceDays: 30
        )
    }

    private func cache(
        sameUser: Bool = true,
        entitled: Bool = true,
        ageDays: Double,
        knownExpiresAt: Date? = nil
    ) -> EntitlementDecision.CacheInfo {
        EntitlementDecision.CacheInfo(
            belongsToCurrentUser: sameUser,
            wasEntitled: entitled,
            verifiedAt: now.addingTimeInterval(-ageDays * 86_400),
            knownExpiresAt: knownExpiresAt
        )
    }

    // MARK: Supabase-first rules

    @Test func supabaseGrantUnlocksWithoutRevenueCat() {
        let outcome = EntitlementDecision.resolve(input(server: .granted, rcEntitled: false))
        #expect(outcome == .grantedBySupabase)
    }

    @Test func supabaseGrantSuppressesPaywallEvenWhenRevenueCatDenies() {
        // Internal Unlimited / portal subscription with no RC "pro" must never
        // fall into the RevenueCat paywall path.
        let outcome = EntitlementDecision.resolve(
            input(server: .granted, rcEntitled: false, rcResolved: true)
        )
        #expect(outcome == .grantedBySupabase)
    }

    @Test func supabaseDenialFallsBackToRevenueCatWithMismatch() {
        let outcome = EntitlementDecision.resolve(input(server: .denied, rcEntitled: true))
        #expect(outcome == .grantedByRevenueCat(mismatchWithServer: true))
    }

    @Test func mismatchIsDiagnosticOnlyAndNeverOverridesSupabaseGrant() {
        let outcome = EntitlementDecision.resolve(input(server: .granted, rcEntitled: true))
        #expect(outcome == .grantedBySupabase)
    }

    @Test func supabaseDenialThenLegacyTrialFallback() {
        let outcome = EntitlementDecision.resolve(
            input(server: .denied, rcEntitled: false, freeWindow: true)
        )
        #expect(outcome == .grantedByLegacyTrial)
    }

    @Test func nothingGrantsShowsPaywall() {
        let outcome = EntitlementDecision.resolve(input(server: .denied))
        #expect(outcome == .denied)
    }

    // MARK: Network failure vs confirmed denial

    @Test func networkFailureUsesEligibleCache() {
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, offline: true, cache: cache(ageDays: 5))
        )
        #expect(outcome == .offlineCachedAccess)
    }

    @Test func confirmedDenialReplacesPositiveCache() {
        // Even with a fresh entitled cache, a CONFIRMED server denial (with no
        // RC/trial fallback) must deny — the cache only covers network failure.
        let outcome = EntitlementDecision.resolve(
            input(server: .denied, cache: cache(ageDays: 1))
        )
        #expect(outcome == .denied)
    }

    @Test func cacheFromAnotherUserIsRejected() {
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, offline: true, cache: cache(sameUser: false, ageDays: 1))
        )
        #expect(outcome == .unverified)
    }

    @Test func expiredCacheDoesNotUnlockIndefinitely() {
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, offline: true, cache: cache(ageDays: 31))
        )
        #expect(outcome == .unverified)
    }

    @Test func knownEntitlementExpiryCapsOfflineCache() {
        // Verified 2 days ago, but the entitlement itself expired yesterday —
        // the 30-day grace must NOT extend past the known expiry.
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, offline: true,
                  cache: cache(ageDays: 2, knownExpiresAt: now.addingTimeInterval(-86_400)))
        )
        #expect(outcome == .unverified)
    }

    @Test func unlimitedGrantWithNoExpiryUsesNormalGrace() {
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, offline: true,
                  cache: cache(ageDays: 29, knownExpiresAt: nil))
        )
        #expect(outcome == .offlineCachedAccess)
    }

    @Test func negativeCacheNeverGrants() {
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, offline: true, cache: cache(entitled: false, ageDays: 1))
        )
        #expect(outcome == .unverified)
    }

    @Test func unreachableOnlineFallsBackToRevenueCatCache() {
        // Supabase down but the device is online and RC's SDK cache grants.
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, rcEntitled: true, offline: false)
        )
        #expect(outcome == .grantedByRevenueCat(mismatchWithServer: false))
    }

    @Test func offlineWithNothingShowsConnectNotice() {
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, offline: true)
        )
        #expect(outcome == .unverified)
    }

    // MARK: Feature flag disabled → legacy behaviour restored

    @Test func flagDisabledIgnoresSupabaseGrant() {
        // Legacy gate is RevenueCat-only; the Supabase result is not consulted.
        let outcome = EntitlementDecision.resolve(
            input(enforced: false, server: .granted, rcEntitled: false, rcResolved: true)
        )
        #expect(outcome == .denied)
    }

    @Test func flagDisabledRevenueCatStillUnlocks() {
        let outcome = EntitlementDecision.resolve(
            input(enforced: false, server: .denied, rcEntitled: true)
        )
        #expect(outcome == .grantedByRevenueCat(mismatchWithServer: false))
    }

    @Test func flagDisabledLegacyTrialStillUnlocks() {
        let outcome = EntitlementDecision.resolve(
            input(enforced: false, server: .unreachable, freeWindow: true)
        )
        #expect(outcome == .grantedByLegacyTrial)
    }

    @Test func flagDisabledOfflineGraceStillWorks() {
        let outcome = EntitlementDecision.resolve(
            input(enforced: false, server: .unreachable, offline: true, cache: cache(ageDays: 10))
        )
        #expect(outcome == .offlineCachedAccess)
    }

    // MARK: Server-authoritative account trial (SQL 143/144)

    @Test func serverTrialGrantFlowsThroughSharedResolver() {
        // Account created today / 1 month old / just under 3 months: the
        // server resolver returns active_trial -> .granted, which must unlock
        // without RevenueCat and without the local window.
        let outcome = EntitlementDecision.resolve(
            input(server: .granted, rcEntitled: false, freeWindow: false)
        )
        #expect(outcome == .grantedBySupabase)
    }

    @Test func serverTrialExpiryDeniesDespiteNothingElse() {
        // Account over 3 months old: server returns expired -> confirmed
        // denial; no RC, no local window -> paywall.
        let outcome = EntitlementDecision.resolve(
            input(server: .denied, rcEntitled: false, freeWindow: false)
        )
        #expect(outcome == .denied)
    }

    @Test func localTrialStillFallsBackWhenServerSaysExpired() {
        // Transition safety: device-time window active but the server trial
        // is expired. The temporary fallback grants (recorded as a throttled
        // mismatch by EntitlementGate) — it must NOT be a silent denial yet.
        let outcome = EntitlementDecision.resolve(
            input(server: .denied, rcEntitled: false, freeWindow: true)
        )
        #expect(outcome == .grantedByLegacyTrial)
    }

    @Test func networkFailureWithValidCachedTrialGrants() {
        // Server-granted trial cached 3 days ago, trial ends in the future:
        // offline access holds (inside grace, before the known expiry).
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, offline: true,
                  cache: cache(ageDays: 3, knownExpiresAt: now.addingTimeInterval(10 * 86_400)))
        )
        #expect(outcome == .offlineCachedAccess)
    }

    @Test func cachedTrialPastServerExpiryNeverGrants() {
        // Cached trial verification is recent, but the SERVER trial expiry
        // (knownExpiresAt = trial_ends_at) has passed — the cache is dead.
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, offline: true,
                  cache: cache(ageDays: 1, knownExpiresAt: now.addingTimeInterval(-3_600)))
        )
        #expect(outcome == .unverified)
    }

    @Test func anotherUsersCachedTrialNeverLeaks() {
        // User switch: the previous user's cached trial must not grant.
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, offline: true,
                  cache: cache(sameUser: false, ageDays: 1,
                               knownExpiresAt: now.addingTimeInterval(10 * 86_400)))
        )
        #expect(outcome == .unverified)
    }

    @Test func paidEntitlementTakesPrecedenceOverTrialFallback() {
        // Server grants (paid source) while the local window is also active:
        // the shared resolver wins — never the legacy trial label.
        let outcome = EntitlementDecision.resolve(
            input(server: .granted, rcEntitled: true, freeWindow: true)
        )
        #expect(outcome == .grantedBySupabase)
    }

    // MARK: Resolver payload decoding — account trial (SQL 144)

    @Test func trialResolverRowDecodesAndCapsExpiry() throws {
        let json = """
        {
          "has_supabase_access": true,
          "access_source": "trial",
          "plan_code": "trial",
          "plan_tier": "trial",
          "billing_provider": "trial",
          "status": "trialling",
          "trial_end": 1787000000,
          "can_use_ios_app": true,
          "can_use_android_app": true,
          "can_use_portal": true,
          "solo_check_required": false,
          "reason_code": "active_trial",
          "purchase_platform": null,
          "expires_at": 1787000000
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let row = try decoder.decode(BackendVineTrackAccess.self, from: Data(json.utf8))
        #expect(row.grantsSupabaseAccess)
        #expect(row.grantsIOSAppAccess)
        #expect(row.reasonCode == "active_trial")
        #expect(row.purchasePlatform == nil)   // null, never "none"
        // The offline cache cap picks up the trial end.
        let cap = row.knownExpiresAt(now: now)
        #expect(cap == Date(timeIntervalSince1970: 1_787_000_000))
    }

    @Test func expiredTrialDenialDecodesWithOriginalEnd() throws {
        let json = """
        {
          "has_supabase_access": false,
          "access_source": "trial",
          "plan_code": "trial",
          "status": "expired",
          "trial_end": 1700000000,
          "solo_check_required": true,
          "reason_code": "expired",
          "purchase_platform": null,
          "expires_at": 1700000000
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let row = try decoder.decode(BackendVineTrackAccess.self, from: Data(json.utf8))
        #expect(row.grantsSupabaseAccess == false)
        #expect(row.reasonCode == "expired")
        #expect(row.requiresSoloCheck)
        // A past expiry never produces a future cache cap.
        #expect(row.knownExpiresAt(now: now) == nil)
    }

    // MARK: Snapshot model compatibility

    @Test func oldSnapshotsDecodeWithoutNewFields() throws {
        let legacyJSON = """
        {"userId":"ABC","lastVerifiedAt":700000000,"wasEntitled":true,"productStatus":"active:x"}
        """
        let decoded = try JSONDecoder().decode(
            EntitlementVerificationSnapshot.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.wasEntitled == true)
        #expect(decoded.accessSource == nil)
        #expect(decoded.supabaseEnforced == nil)
        #expect(decoded.knownExpiresAt == nil)
    }
}

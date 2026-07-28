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

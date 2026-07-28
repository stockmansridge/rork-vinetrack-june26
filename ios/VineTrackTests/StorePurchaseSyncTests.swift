import Testing
import Foundation
@testable import VineTrack

/// Phase 2B — tests for the bounded post-purchase Supabase synchronisation
/// plan and the store-subscription decision cases of the combined gate.
struct StorePurchaseSyncTests {

    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    // MARK: Bounded sync plan (immediate → 2s → 5s → 10s)

    @Test func scheduleIsBoundedAndStartsImmediately() {
        #expect(StorePurchaseSyncPlan.delays == [0, 2, 5, 10])
    }

    @Test func serverGrantStopsPollingImmediately() {
        let verdict = StorePurchaseSyncPlan.verdict(afterAttempt: 0, serverGranted: true, revenueCatEntitled: true)
        #expect(verdict == .synced)
    }

    @Test func webhookDelayKeepsPollingWithoutBlockingAccess() {
        // RevenueCat grants (fallback access active); server not yet synced.
        let verdict = StorePurchaseSyncPlan.verdict(afterAttempt: 1, serverGranted: false, revenueCatEntitled: true)
        #expect(verdict == .retry)
    }

    @Test func pollingStopsWhenRevenueCatNoLongerGrants() {
        let verdict = StorePurchaseSyncPlan.verdict(afterAttempt: 1, serverGranted: false, revenueCatEntitled: false)
        #expect(verdict == .stopNoEntitlement)
    }

    @Test func scheduleExhaustionTimesOutInsteadOfLooping() {
        let lastAttempt = StorePurchaseSyncPlan.delays.count - 1
        let verdict = StorePurchaseSyncPlan.verdict(afterAttempt: lastAttempt, serverGranted: false, revenueCatEntitled: true)
        #expect(verdict == .timedOut)
    }

    // MARK: Store-subscription decision cases (combined gate)

    private func input(
        server: EntitlementServerResult,
        rcEntitled: Bool = false,
        rcResolved: Bool = true,
        offline: Bool = false,
        cache: EntitlementDecision.CacheInfo? = nil
    ) -> EntitlementDecision.Input {
        EntitlementDecision.Input(
            enforcementEnabled: true,
            server: server,
            revenueCatEntitled: rcEntitled,
            revenueCatResolved: rcResolved,
            inLegacyFreeWindow: false,
            isOffline: offline,
            cache: cache,
            now: now,
            offlineGraceDays: 30
        )
    }

    @Test func verifiedStoreSubscriptionInSupabaseUnlocksWithoutFreshRevenueCatCall() {
        // Once the webhook has written the verified purchase, Supabase alone
        // grants — a cross-platform (e.g. Google-purchased) entitlement works
        // on iOS even when local RevenueCat has no matching Apple purchase.
        let outcome = EntitlementDecision.resolve(input(server: .granted, rcEntitled: false))
        #expect(outcome == .grantedBySupabase)
    }

    @Test func webhookNotYetProcessedNeverShowsPaywall() {
        // Immediately after an Apple purchase the server may still deny
        // (webhook in flight): RevenueCat fallback grants, mismatch recorded,
        // paywall suppressed.
        let outcome = EntitlementDecision.resolve(input(server: .denied, rcEntitled: true))
        #expect(outcome == .grantedByRevenueCat(mismatchWithServer: true))
    }

    @Test func expiredEverywhereShowsPaywall() {
        let outcome = EntitlementDecision.resolve(input(server: .denied, rcEntitled: false))
        #expect(outcome == .denied)
    }

    @Test func networkFailureAfterPurchaseUsesEligibleCache() {
        let cache = EntitlementDecision.CacheInfo(
            belongsToCurrentUser: true,
            wasEntitled: true,
            verifiedAt: now.addingTimeInterval(-3 * 86_400),
            knownExpiresAt: now.addingTimeInterval(20 * 86_400)
        )
        let outcome = EntitlementDecision.resolve(
            input(server: .unreachable, rcEntitled: false, rcResolved: false, offline: true, cache: cache)
        )
        #expect(outcome == .offlineCachedAccess)
    }

    // MARK: Cache expiry cap — grace period extends an elapsed period end

    @Test func knownExpiryUsesLaterOfPeriodEndAndGraceEnd() throws {
        let json = """
        {
          "has_supabase_access": true,
          "reason_code": "app_store_subscription",
          "purchase_platform": "ios",
          "cancel_at_period_end": false,
          "current_period_end": "2026-08-01T00:00:00Z",
          "grace_period_end": "2026-08-17T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(BackendVineTrackAccess.self, from: Data(json.utf8))

        #expect(row.purchasePlatform == "ios")
        #expect(row.cancelAtPeriodEnd == false)

        let reference = Date(timeIntervalSince1970: 1_753_000_000) // well before both
        let expiry = try #require(row.knownExpiresAt(now: reference))
        let formatter = ISO8601DateFormatter()
        #expect(expiry == formatter.date(from: "2026-08-17T00:00:00Z"))
    }

    @Test func sql135FieldsAreOptionalForOldResponses() throws {
        let json = """
        { "has_supabase_access": true, "reason_code": "internal_unlimited" }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(BackendVineTrackAccess.self, from: Data(json.utf8))
        #expect(row.purchasePlatform == nil)
        #expect(row.cancelAtPeriodEnd == nil)
        #expect(row.gracePeriodEnd == nil)
        #expect(row.grantsSupabaseAccess)
    }
}

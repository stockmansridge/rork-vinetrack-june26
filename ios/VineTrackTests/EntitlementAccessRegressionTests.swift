import Testing
import Foundation
@testable import VineTrack

struct EntitlementAccessRegressionTests {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private func row(_ json: String) throws -> BackendVineTrackAccess {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(BackendVineTrackAccess.self, from: Data(json.utf8))
    }

    @Test func effectiveExpiryTakesPrecedenceOverHistoricalFields() throws {
        let access = try row("""
        {"has_access":true,"expires_at":1787000000,"trial_end":1786000000,
         "current_period_end":1789000000,"manual_grant_expires_at":1788000000}
        """)
        #expect(access.expiresAt == Date(timeIntervalSince1970: 1_787_000_000))
        #expect(access.knownExpiresAt(now: now) == access.expiresAt)
    }

    @Test func explicitNullExpiryIsAnIndefiniteGrant() throws {
        let access = try row("""
        {"has_access":true,"expires_at":null,"trial_end":1786000000,
         "current_period_end":1787000000}
        """)
        #expect(access.expiresAt == nil)
        #expect(access.knownExpiresAt(now: now) == nil)
    }

    @Test func explicitExpiredCapCannotBecomeUnlimitedOfflineAccess() throws {
        let access = try row("""
        {"has_access":false,"expires_at":1700000000,"current_period_end":1787000000}
        """)
        let cache = EntitlementDecision.CacheInfo(
            belongsToCurrentUser: true, wasEntitled: true, verifiedAt: now,
            knownExpiresAt: access.knownExpiresAt(now: now)
        )
        #expect(!EntitlementDecision.isCacheEligible(cache, now: now, graceDays: 30))
    }

    @Test func oldPayloadWithoutEffectiveExpiryKeepsItsTrialCap() throws {
        let access = try row("""
        {"has_supabase_access":true,"trial_end":1787000000}
        """)
        #expect(access.knownExpiresAt(now: now) == Date(timeIntervalSince1970: 1_787_000_000))
    }

    @Test func oldBillingGraceExtendsThePeriodEnd() throws {
        let access = try row("""
        {"has_supabase_access":true,"current_period_end":1784000000,"grace_period_end":1786000000}
        """)
        #expect(access.knownExpiresAt(now: now) == Date(timeIntervalSince1970: 1_786_000_000))
    }

    @Test func malformedAdditiveExpiryDoesNotBreakLegacyDecoding() throws {
        let access = try row("""
        {"has_supabase_access":true,"expires_at":"unavailable","trial_end":1787000000}
        """)
        #expect(access.grantsSupabaseAccess)
        #expect(access.knownExpiresAt(now: now) == Date(timeIntervalSince1970: 1_787_000_000))
    }

    @Test func effectiveExpiryUsesTheConfiguredWireDateDecoder() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let access = try decoder.decode(BackendVineTrackAccess.self, from: Data("""
        {"has_access":true,"expires_at":"2026-12-01T00:00:00Z"}
        """.utf8))
        #expect(access.expiresAt == ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }

    @Test func explicitIOSCapabilityDenialIsPreserved() throws {
        let access = try row("""
        {"has_access":true,"can_use_ios_app":false,"role":"billing"}
        """)
        #expect(access.grantsSupabaseAccess)
        #expect(!access.grantsIOSAppAccess)
    }

    @MainActor
    private func withStore(_ body: (EntitlementVerificationStore) -> Void) {
        let suite = "EntitlementAccessRegressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(EntitlementVerificationStore(defaults: defaults))
    }

    @Test @MainActor func authoritativeIndefiniteGrantClearsOldTrialAndSourceDetails() {
        withStore { store in
            let user = UUID().uuidString
            store.recordVerification(
                userId: user, entitled: true, productStatus: "trial",
                vineyardAccessActive: true, accessSource: "legacy_trial", planCode: "trial",
                reasonCode: "active_trial", knownExpiresAt: now.addingTimeInterval(-86_400),
                supabaseEnforced: true, accessibleVineyardIds: ["vineyard-a"]
            )
            let replaced = store.recordVerification(
                userId: user, entitled: true, productStatus: "supabase:team",
                accessSource: "supabase", planCode: "team", knownExpiresAt: nil,
                supabaseEnforced: true, accessDetailsUpdate: .replace
            )
            #expect(replaced.wasEntitled)
            #expect(replaced.knownExpiresAt == nil)
            #expect(replaced.accessSource == "supabase")
            #expect(replaced.planCode == "team")
            #expect(replaced.reasonCode == nil)
            #expect(replaced.vineyardAccessActive == nil)
            // The separately fetched matrix was unavailable, so keep its scope.
            #expect(replaced.accessibleVineyardIds == ["vineyard-a"])
            #expect(store.load()?.knownExpiresAt == nil)
            let cache = EntitlementDecision.CacheInfo(
                belongsToCurrentUser: true, wasEntitled: replaced.wasEntitled,
                verifiedAt: replaced.lastVerifiedAt, knownExpiresAt: replaced.knownExpiresAt
            )
            #expect(EntitlementDecision.isCacheEligible(
                cache, now: replaced.lastVerifiedAt.addingTimeInterval(86_400), graceDays: 30
            ))
        }
    }

    @Test @MainActor func providerPartialUpdatePreservesKnownAccessDetails() {
        withStore { store in
            let user = UUID().uuidString
            let expiry = now.addingTimeInterval(86_400)
            store.recordVerification(
                userId: user, entitled: true, productStatus: "supabase:team",
                accessSource: "supabase", planCode: "team", reasonCode: "manual_grant",
                knownExpiresAt: expiry, supabaseEnforced: true,
                accessibleVineyardIds: ["vineyard-a"], accessDetailsUpdate: .replace
            )
            let merged = store.recordVerification(userId: user, entitled: true, productStatus: "active:pro")
            #expect(merged.knownExpiresAt == expiry)
            #expect(merged.accessSource == "supabase")
            #expect(merged.planCode == "team")
            #expect(merged.reasonCode == "manual_grant")
            #expect(merged.supabaseEnforced == true)
            #expect(merged.accessibleVineyardIds == ["vineyard-a"])
        }
    }

    @Test @MainActor func anotherAccountNeverInheritsOptionalFieldsOrVineyardIDs() {
        withStore { store in
            let first = UUID()
            let second = UUID()
            store.recordVerification(
                userId: first.uuidString, entitled: true, productStatus: "supabase:team",
                accessSource: "supabase", planCode: "team", reasonCode: "manual_grant",
                knownExpiresAt: now.addingTimeInterval(86_400), supabaseEnforced: true,
                accessibleVineyardIds: ["vineyard-a"]
            )
            #expect(store.load(for: second) == nil)
            let next = store.recordVerification(userId: second.uuidString, entitled: false, productStatus: nil)
            #expect(next.knownExpiresAt == nil)
            #expect(next.accessSource == nil)
            #expect(next.planCode == nil)
            #expect(next.reasonCode == nil)
            #expect(next.supabaseEnforced == nil)
            #expect(next.accessibleVineyardIds == nil)
            #expect(store.load(for: first) == nil)
        }
    }

    @Test @MainActor func definitiveRevocationReplacesPositiveCacheAndEmptyMatrix() {
        withStore { store in
            let user = UUID().uuidString
            store.recordVerification(
                userId: user, entitled: true, productStatus: "supabase:team",
                accessSource: "supabase", planCode: "team", accessibleVineyardIds: ["vineyard-a"]
            )
            let denied = store.recordVerification(
                userId: user, entitled: false, productStatus: "access:denied",
                reasonCode: "revoked", accessibleVineyardIds: [], accessDetailsUpdate: .replace
            )
            #expect(!denied.wasEntitled)
            #expect(denied.accessSource == nil)
            #expect(denied.planCode == nil)
            #expect(denied.accessibleVineyardIds == [])
            let cache = EntitlementDecision.CacheInfo(
                belongsToCurrentUser: true, wasEntitled: denied.wasEntitled,
                verifiedAt: denied.lastVerifiedAt, knownExpiresAt: nil
            )
            #expect(!EntitlementDecision.isCacheEligible(cache, now: denied.lastVerifiedAt, graceDays: 30))
        }
    }

    private func presentation(
        _ outcome: EntitlementOutcome?,
        access: BackendVineTrackAccess? = nil,
        snapshot: EntitlementVerificationSnapshot? = nil,
        offline: Bool = false,
        storeExpiry: Date? = nil,
        renews: Bool = false
    ) -> EntitlementAccessPresentation {
        EntitlementAccessPresentation(
            outcome: outcome, serverAccess: access, verification: snapshot,
            isOffline: offline, legacyTrialEndsAt: now.addingTimeInterval(-86_400),
            storeExpiresAt: storeExpiry, storeWillRenew: renews, now: now
        )
    }

    @Test func complimentaryTeamGrantDoesNotShowExpiredStoreTrialOrPurchaseCTA() throws {
        let access = try row("""
        {"has_access":true,"plan_name":"Team","reason_code":"manual_grant",
         "role":"billing","expires_at":null,"trial_end":1700000000}
        """)
        let display = presentation(.grantedBySupabase, access: access, storeExpiry: now.addingTimeInterval(-86_400))
        #expect(display.hasAccess)
        #expect(display.statusTitle == "Team access active")
        #expect(display.statusSubtitle == "Your VineTrack access is active.")
        #expect(display.accessTitle == "Access active")
        #expect(display.accessDetail == "Verified with VineTrack.")
        #expect(display.icon == "checkmark.seal.fill")
        #expect(display.tone == .positive)
        #expect(!display.shouldOfferPlans)
    }

    @Test func temporaryGrantDisplaysItsEffectiveExpiry() throws {
        let access = try row("""
        {"has_access":true,"plan_name":"Team","expires_at":1787000000,"trial_end":1700000000}
        """)
        let display = presentation(.grantedBySupabase, access: access)
        let date = Date(timeIntervalSince1970: 1_787_000_000).formatted(date: .abbreviated, time: .omitted)
        #expect(display.statusSubtitle == "Access until \(date)")
        #expect(!display.shouldOfferPlans)
    }

    @Test func billingRoleDoesNotInventAnEntitlement() throws {
        let access = try row("""
        {"has_access":false,"role":"billing","plan_name":"Team","reason_code":"expired"}
        """)
        let display = presentation(.denied, access: access)
        #expect(!display.hasAccess)
        #expect(display.shouldOfferPlans)
        #expect(display.statusTitle == "No active access")
        #expect(display.icon == "lock.fill")
        #expect(display.tone == .negative)
    }

    @Test func emergencyFlagDenialDrivesDisplayDespiteServerGrant() throws {
        let access = try row("""
        {"has_access":true,"enforcement_enabled":false,"plan_name":"Team"}
        """)
        let outcome = EntitlementDecision.resolve(.init(
            enforcementEnabled: false, server: .granted, revenueCatEntitled: false,
            revenueCatResolved: true, inLegacyFreeWindow: false, isOffline: false,
            cache: nil, now: now
        ))
        let display = presentation(outcome, access: access)
        #expect(display.shouldOfferPlans)
        #expect(!display.hasAccess)
    }

    @Test func realStoreFallbackKeepsStoreRenewalDetails() {
        let expiry = now.addingTimeInterval(86_400)
        let display = presentation(.grantedByRevenueCat(mismatchWithServer: true), storeExpiry: expiry, renews: true)
        #expect(display.hasAccess)
        #expect(display.accessDetail == "Verified with the App Store.")
        #expect(display.statusSubtitle == "Renews \(expiry.formatted(date: .abbreviated, time: .omitted))")
        #expect(!display.shouldOfferPlans)
    }

    @Test func serverTrialUsesItsServerExpiryAndTrialLabel() throws {
        let access = try row("""
        {"has_access":true,"plan_code":"trial","reason_code":"active_trial","expires_at":1787000000}
        """)
        let display = presentation(.grantedBySupabase, access: access)
        #expect(display.statusTitle == "Free trial active")
        #expect(display.statusSubtitle.hasPrefix("Trial ends "))
        #expect(display.icon == "gift.fill")
        #expect(!display.shouldOfferPlans)
    }

    @Test func cachedGrantDisplayCapsGraceAtTheSameExpiryAsTheGate() {
        let expiry = now.addingTimeInterval(86_400)
        let snapshot = EntitlementVerificationSnapshot(
            userId: UUID().uuidString, lastVerifiedAt: now.addingTimeInterval(-86_400),
            wasEntitled: true, knownExpiresAt: expiry
        )
        let display = presentation(.offlineCachedAccess, snapshot: snapshot, offline: true)
        #expect(display.hasAccess)
        #expect(display.lastVerifiedAt == snapshot.lastVerifiedAt)
        #expect(display.offlineGraceEndsAt == expiry)
        #expect(display.icon == "wifi.slash")
        #expect(!display.shouldOfferPlans)
        #expect(!display.shouldOfferRefresh)
    }

    @Test func indefiniteCachedGrantStillHasThirtyDayGraceLimit() {
        let snapshot = EntitlementVerificationSnapshot(
            userId: UUID().uuidString, lastVerifiedAt: now, wasEntitled: true
        )
        let display = presentation(.offlineCachedAccess, snapshot: snapshot)
        #expect(display.offlineGraceEndsAt == now.addingTimeInterval(30 * 86_400))
        #expect(display.shouldOfferRefresh)
    }

    @Test func unverifiedAndCheckingStatesNeverOfferAPurchase() {
        for outcome: EntitlementOutcome? in [nil, .unverified] {
            let online = presentation(outcome)
            let offline = presentation(outcome, offline: true)
            #expect(!online.shouldOfferPlans)
            #expect(!offline.shouldOfferPlans)
            #expect(!online.hasAccess)
            #expect(!offline.hasAccess)
        }
    }
}

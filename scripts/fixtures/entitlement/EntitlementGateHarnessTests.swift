import Foundation
import Testing
@testable import VineTrack

@MainActor
private final class HarnessSignal {
    private var signalled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func signal() {
        signalled = true
        continuation?.resume()
        continuation = nil
    }
}

// These tests exercise the production observable service with suspended RPCs,
// actual UserDefaults persistence and deterministic simulated connectivity.
@Suite(.serialized)
@MainActor
struct EntitlementGateHarnessTests {
    private func row(_ json: String) throws -> BackendVineTrackAccess {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(BackendVineTrackAccess.self, from: Data(json.utf8))
    }

    private func grant() throws -> BackendVineTrackAccess {
        try row("""
        {"has_access":true,"can_use_ios_app":true,"enforcement_enabled":true,
         "plan_code":"team","plan_name":"Team","expires_at":null}
        """)
    }

    private func denial() throws -> BackendVineTrackAccess {
        try row("""
        {"has_access":false,"enforcement_enabled":true,"reason_code":"expired"}
        """)
    }

    @Test func freshIndefiniteGrantClearsExpiredTrialThenWorksOffline() async throws {
        let store = EntitlementVerificationStore.shared
        store.clear()
        defer { store.clear() }
        let user = UUID()
        store.recordVerification(
            userId: user.uuidString, entitled: true, productStatus: "trial",
            accessSource: "legacy_trial", planCode: "trial", knownExpiresAt: Date(timeIntervalSince1970: 1),
            supabaseEnforced: true, accessibleVineyardIds: [UUID().uuidString]
        )
        let subscription = SubscriptionService()
        let access = try grant()
        let gate = EntitlementGate(
            subscription: subscription,
            repository: .init(fetch: {
                if subscription.isOffline { throw URLError(.notConnectedToInternet) }
                return access
            }),
            matrixRepository: .init(fetch: { throw URLError(.timedOut) })
        )
        gate.login(userId: user)
        await gate.refresh()
        #expect(gate.outcome == .grantedBySupabase)
        #expect(store.load(for: user)?.knownExpiresAt == nil)
        #expect(store.load(for: user)?.planCode == "team")
        #expect(store.load(for: user)?.accessibleVineyardIds?.count == 1)

        subscription.isOffline = true
        await gate.refresh(force: true)
        #expect(gate.outcome == .offlineCachedAccess)
        #expect(gate.hasAccess)
    }

    @Test func reconnectBypassesRecentOfflineAttemptThrottle() async throws {
        EntitlementVerificationStore.shared.clear()
        defer { EntitlementVerificationStore.shared.clear() }
        let subscription = SubscriptionService()
        subscription.isOffline = true
        let access = try grant()
        var calls = 0
        let gate = EntitlementGate(subscription: subscription, repository: .init(fetch: {
            calls += 1
            if subscription.isOffline { throw URLError(.notConnectedToInternet) }
            return access
        }))
        gate.login(userId: UUID())
        await gate.refresh()
        #expect(gate.outcome == .unverified)
        subscription.isOffline = false
        await gate.refresh()
        #expect(calls == 1) // The ordinary fifteen-second throttle still applies.
        await gate.refresh(force: true) // The root view's reconnect request.
        #expect(calls == 2)
        #expect(gate.outcome == .grantedBySupabase)
    }

    @Test func reconnectDuringInflightRequestCoalescesIntoOneFollowUp() async throws {
        EntitlementVerificationStore.shared.clear()
        defer { EntitlementVerificationStore.shared.clear() }
        let started = HarnessSignal()
        var firstReply: CheckedContinuation<BackendVineTrackAccess?, Error>?
        var calls = 0
        let access = try grant()
        let gate = EntitlementGate(subscription: SubscriptionService(), repository: .init(fetch: {
            calls += 1
            if calls == 1 {
                return try await withCheckedThrowingContinuation {
                    firstReply = $0
                    started.signal()
                }
            }
            return access
        }))
        gate.login(userId: UUID())
        let initial = Task { await gate.refresh() }
        await started.wait()
        for _ in 0..<10 { await gate.refresh(force: true) }
        firstReply?.resume(throwing: URLError(.notConnectedToInternet))
        await initial.value
        #expect(calls == 2)
        #expect(gate.outcome == .grantedBySupabase)
    }

    @Test func switchingAccountsDropsOldResponseAndQueuesNewVerification() async throws {
        let store = EntitlementVerificationStore.shared
        store.clear()
        defer { store.clear() }
        let firstStarted = HarnessSignal()
        let secondStarted = HarnessSignal()
        var firstReply: CheckedContinuation<BackendVineTrackAccess?, Error>?
        var secondReply: CheckedContinuation<BackendVineTrackAccess?, Error>?
        var calls = 0
        let gate = EntitlementGate(subscription: SubscriptionService(), repository: .init(fetch: {
            calls += 1
            return try await withCheckedThrowingContinuation {
                if calls == 1 {
                    firstReply = $0
                    firstStarted.signal()
                } else {
                    secondReply = $0
                    secondStarted.signal()
                }
            }
        }))
        let firstUser = UUID()
        let secondUser = UUID()
        gate.login(userId: firstUser)
        let initial = Task { await gate.refresh() }
        await firstStarted.wait()
        gate.login(userId: secondUser)
        firstReply?.resume(returning: try grant())
        await secondStarted.wait()
        #expect(gate.lastServerAccess == nil)
        #expect(gate.lastServerResult == nil)
        #expect(!gate.hasAccess)
        #expect(store.load() == nil)
        secondReply?.resume(returning: try denial())
        await initial.value
        #expect(calls == 2)
        #expect(gate.outcome == .denied)
        #expect(store.load()?.userId == secondUser.uuidString)
        #expect(store.load(for: firstUser) == nil)
    }

    @Test func signOutDuringRequestCannotRestoreAccessOrCache() async throws {
        let store = EntitlementVerificationStore.shared
        store.clear()
        defer { store.clear() }
        let started = HarnessSignal()
        var reply: CheckedContinuation<BackendVineTrackAccess?, Error>?
        let gate = EntitlementGate(subscription: SubscriptionService(), repository: .init(fetch: {
            try await withCheckedThrowingContinuation {
                reply = $0
                started.signal()
            }
        }))
        gate.login(userId: UUID())
        let initial = Task { await gate.refresh() }
        await started.wait()
        gate.logout()
        reply?.resume(returning: try grant())
        await initial.value
        #expect(gate.phase == .idle)
        #expect(gate.lastServerResult == nil)
        #expect(!gate.hasAccess)
        #expect(store.load() == nil)
    }

    @Test func disabledEmergencyFlagCannotCacheAnIgnoredGrant() async throws {
        let store = EntitlementVerificationStore.shared
        store.clear()
        defer { store.clear() }
        let subscription = SubscriptionService()
        let access = try row("""
        {"has_access":true,"can_use_ios_app":true,"enforcement_enabled":false,"expires_at":null}
        """)
        let gate = EntitlementGate(subscription: subscription, repository: .init(fetch: {
            if subscription.isOffline { throw URLError(.notConnectedToInternet) }
            return access
        }))
        let user = UUID()
        gate.login(userId: user)
        await gate.refresh()
        #expect(gate.outcome == .denied)
        #expect(store.load(for: user)?.wasEntitled == false)
        subscription.isOffline = true
        await gate.refresh(force: true)
        #expect(gate.outcome == .unverified)
        #expect(!gate.hasAccess)
    }

    @Test func platformPermissionDenialDoesNotUnlockFromAccountFlag() async throws {
        let store = EntitlementVerificationStore.shared
        store.clear()
        defer { store.clear() }
        let access = try row("""
        {"has_access":true,"can_use_ios_app":false,"enforcement_enabled":true,"role":"billing"}
        """)
        let gate = EntitlementGate(subscription: SubscriptionService(), repository: .init(fetch: { access }))
        gate.login(userId: UUID())
        await gate.refresh()
        #expect(gate.lastServerResult == .denied)
        #expect(gate.outcome == .denied)
        #expect(!gate.hasAccess)
        #expect(store.load()?.wasEntitled == false)
    }

    @Test func confirmedRevocationReplacesEarlierGrant() async throws {
        let store = EntitlementVerificationStore.shared
        store.clear()
        defer { store.clear() }
        let allowed = try grant()
        let denied = try denial()
        var revoked = false
        let gate = EntitlementGate(subscription: SubscriptionService(), repository: .init(fetch: {
            revoked ? denied : allowed
        }))
        gate.login(userId: UUID())
        await gate.refresh()
        #expect(gate.hasAccess)
        revoked = true
        await gate.refresh(force: true)
        #expect(gate.outcome == .denied)
        #expect(store.load()?.wasEntitled == false)
        #expect(store.load()?.accessSource == nil)
        #expect(store.load()?.planCode == nil)
    }
}

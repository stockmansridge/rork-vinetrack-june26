import Foundation

// Only transport/SDK dependencies are substituted in the Linux harness. The
// entire production EntitlementGate, cache, DTO and presentation compile and run
// unchanged. These fakes are outside the iOS target and make no network calls.
@MainActor
final class SubscriptionService {
    static let offlineGraceDays = 30
    var isSubscribed = false
    var hasResolvedStatus = true
    var isInInitialFreeAccessPeriod = false
    var isOffline = false
    var freeAccessEndsAt: Date?
}

nonisolated struct VineTrackAccessRepository {
    var fetch: @MainActor () async throws -> BackendVineTrackAccess? = { nil }

    func fetchMyAccess() async throws -> BackendVineTrackAccess? {
        try await fetch()
    }

    func reportMismatch(platform: String, appVersion: String?) async throws {}
}

nonisolated struct VineyardAccessMatrixRepository {
    var fetch: @MainActor () async throws -> VineyardAccessMatrix = {
        VineyardAccessMatrix(account: nil, vineyards: [])
    }

    func fetchMatrix() async throws -> VineyardAccessMatrix {
        try await fetch()
    }
}

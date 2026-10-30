import Foundation
import Testing
@testable import VineTrack

@MainActor struct YieldMasterFullSyncTests {
    private let vineyard = UUID(), block = UUID()
    private func paddock() -> Paddock {
        Paddock(id: block, vineyardId: vineyard, name: "Synthetic", varietyAllocations: [
            PaddockVarietyAllocation(varietyId: UUID(), percent: 100, name: "Renamed variety", varietyKey: "shiraz")])
    }
    private func row(grams: Double, override: Bool = false, vineyard: UUID? = nil) -> YieldBunchWeightRow {
        .init(id: UUID(), vineyardId: vineyard ?? self.vineyard, paddockId: override ? block : nil,
              varietyKey: "shiraz", varietyName: "Shiraz", grams: grams, updatedAt: nil)
    }
    private var key: String { CurrentYieldEstimate.key(blockId: block, varietyKey: "shiraz") }
    @Test func fullReadUsesOverrideThenRemovedOverrideFallsBackToNewMaster() async throws {
        let name="batch-yield-\(UUID())", defaults=try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cache=YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { 1 })
        try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in [row(grams: 120), row(grams: 90, override: true)] }
        #expect(cache.weights(vineyardId: vineyard)[key]?.kg == 0.09)
        try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in [row(grams: 140)] }
        #expect(cache.weights(vineyardId: vineyard)[key]?.source == "variety_default")
        let restarted=YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { 1 })
        #expect(restarted.weights(vineyardId: vineyard)[key]?.kg == 0.14)
    }
    @Test func failedRefreshRetainsConfirmedWeightAndReportsStaleUntilSuccess() async throws {
        let name="batch-yield-\(UUID())", defaults=try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cache=YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { 1 })
        try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in [row(grams: 120)] }
        await #expect(throws: URLError.self) {
            try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in throw URLError(.timedOut) }
        }
        #expect(cache.weights(vineyardId: vineyard)[key]?.kg == 0.12)
        #expect(cache.syncError(vineyardId: vineyard) != nil)
        try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in [row(grams: 130)] }
        #expect(cache.syncError(vineyardId: vineyard) == nil)
        #expect(cache.weights(vineyardId: vineyard)[key]?.kg == 0.13)
    }
    @Test func confirmedEmptyReadClearsOldWeightsButFailedReadDoesNotInventConfiguration() async throws {
        let name="batch-yield-\(UUID())", defaults=try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cache=YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { 1 })
        await #expect(throws: URLError.self) {
            try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in throw URLError(.userAuthenticationRequired) }
        }
        #expect(cache.weights(vineyardId: vineyard).isEmpty)
        try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in [row(grams: 120)] }
        try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in [] }
        #expect(cache.weights(vineyardId: vineyard)[key]?.source == "not_configured")
        #expect(cache.weights(vineyardId: vineyard)[key]?.kg == nil)
    }
    @Test(arguments: ["foreign", "duplicate", "invalid"])
    func invalidReadNeverReplacesConfirmedSnapshot(kind: String) async throws {
        let name="batch-yield-\(UUID())", defaults=try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cache=YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { 1 })
        try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in [row(grams: 120)] }
        let bad=row(grams: kind == "invalid" ? -1 : 170, vineyard: kind == "foreign" ? UUID() : vineyard)
        await #expect(throws: URLError.self) {
            try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in kind == "duplicate" ? [bad,bad] : [bad] }
        }
        #expect(cache.weights(vineyardId: vineyard)[key]?.kg == 0.12)
    }
    @Test func changedAccountIncarnationDoesNotInstallOrPublishErrorIntoNewSession() async throws {
        let name="batch-yield-\(UUID())", defaults=try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var generation: UInt64=1
        let cache=YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { generation })
        await #expect(throws: CancellationError.self) {
            try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in
                generation += 2; return [row(grams: 200)]
            }
        }
        #expect(cache.weights(vineyardId: vineyard).isEmpty)
        #expect(cache.syncError(vineyardId: vineyard) == nil)
    }
    @Test func laterManagementConfirmationCannotBeOverwrittenByOlderFullSyncResponse() async throws {
        let name="batch-yield-\(UUID())", defaults=try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cache=YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { 1 })
        await #expect(throws: CancellationError.self) {
            try await cache.synchronize(vineyardId: vineyard, paddocks: [paddock()]) { _ in
                cache.installConfirmedRows([row(grams: 140)], vineyardId: vineyard, paddocks: [paddock()])
                return [row(grams: 120)]
            }
        }
        #expect(cache.weights(vineyardId: vineyard)[key]?.kg == 0.14)
        #expect(cache.syncError(vineyardId: vineyard) == nil)
    }
    @Test func canonicalIdentityMatchesDatabaseWithoutFuzzyVarietyNames() {
        let rows=[row(grams: 120), row(grams: 90, override: true)]
        #expect(YieldBunchWeightRow.resolved(rows, vineyard: vineyard, block: block, key: " SHIRAZ ").kg == 0.09)
        #expect(YieldBunchWeightRow.resolved(rows, vineyard: vineyard, block: block, key: "syrah").kg == nil)
    }
}

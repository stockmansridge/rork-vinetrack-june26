import Foundation
import Testing
@testable import VineTrack

@MainActor struct YieldMasterWeightCacheTests {
    private let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let block = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private func paddock() -> Paddock {
        Paddock(id: block, vineyardId: vineyard, name: "Synthetic", varietyAllocations: [PaddockVarietyAllocation(varietyId: vineyard, percent: 100, name: "Renamed", varietyKey: "shiraz")])
    }
    @Test func confirmedWeightSurvivesRecreatedCacheAndOfflineRead() async throws {
        let name = "yield-cache-test-\(UUID())"; let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let cache = YieldMasterWeightCache(defaults: defaults, accountBinding: { "actor-a" }, generation: { 1 }, resolve: { vineyard, _, key in
            #expect(vineyard == self.vineyard && key == "shiraz")
            return YieldMasterWeight(bunchWeightGrams: 120, source: "block_override", recordId: self.block, varietyKey: key)
        })
        await cache.refresh(vineyardId: vineyard, paddocks: [paddock()])
        let offline = YieldMasterWeightCache(defaults: defaults, accountBinding: { "actor-a" }, generation: { 1 }, resolve: { _, _, _ in throw URLError(.notConnectedToInternet) })
        await offline.refresh(vineyardId: vineyard, paddocks: [paddock()])
        #expect(offline.weights(vineyardId: vineyard).values.first?.kg == 0.12)
    }
    @Test func confirmedAbsenceReplacesAvailableWeightOnDisk() async throws {
        let name = "yield-cache-test-\(UUID())"; let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var absent = false
        let cache = YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { 1 }, resolve: { _, _, key in
            YieldMasterWeight(bunchWeightGrams: absent ? nil : 120, source: absent ? "not_configured" : "variety_default", recordId: absent ? nil : self.block, varietyKey: key)
        })
        await cache.refresh(vineyardId: vineyard, paddocks: [paddock()]); absent = true
        await cache.refresh(vineyardId: vineyard, paddocks: [paddock()])
        let recreated = YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { 1 })
        #expect(recreated.weights(vineyardId: vineyard).values.first?.source == "not_configured")
        #expect(recreated.weights(vineyardId: vineyard).values.first?.kg == nil)
    }
    @Test func accountVineyardBlockAndVarietyScopesCannotLeak() async throws {
        let name = "yield-cache-test-\(UUID())"; let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var account: String? = "a"
        let cache = YieldMasterWeightCache(defaults: defaults, accountBinding: { account }, generation: { 1 }, resolve: { _, _, key in YieldMasterWeight(bunchWeightGrams: 120, source: "block_override", recordId: self.block, varietyKey: key) })
        await cache.refresh(vineyardId: vineyard, paddocks: [paddock()])
        #expect(cache.weights(vineyardId: UUID()).isEmpty)
        #expect(cache.weights(vineyardId: vineyard)[CurrentYieldEstimate.key(blockId: UUID(), varietyKey: "shiraz")] == nil)
        #expect(cache.weights(vineyardId: vineyard)[CurrentYieldEstimate.key(blockId: block, varietyKey: "merlot")] == nil)
        account = "b"; #expect(cache.weights(vineyardId: vineyard).isEmpty)
        account = nil; #expect(cache.weights(vineyardId: vineyard).isEmpty)
    }
    @Test func sameAccountNewIncarnationCannotCommitOldResponse() async throws {
        let name = "yield-cache-test-\(UUID())"; let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var generation: UInt64 = 1
        let cache = YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { generation }, resolve: { _, _, key in
            generation += 2 // sign out and return while the request was suspended
            return YieldMasterWeight(bunchWeightGrams: 120, source: "block_override", recordId: self.block, varietyKey: key)
        })
        await cache.refresh(vineyardId: vineyard, paddocks: [paddock()])
        #expect(cache.weights(vineyardId: vineyard).isEmpty)
    }
    @Test func mismatchedOrMalformedResponseNeverEntersConfirmedCache() async throws {
        let name = "yield-cache-test-\(UUID())"; let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        var mismatch = true
        let cache = YieldMasterWeightCache(defaults: defaults, accountBinding: { "a" }, generation: { 1 }, resolve: { _, _, key in
            YieldMasterWeight(bunchWeightGrams: mismatch ? 120 : -1, source: "block_override", recordId: self.block, varietyKey: mismatch ? "wrong-key" : key)
        })
        await cache.refresh(vineyardId: vineyard, paddocks: [paddock()]); #expect(cache.weights(vineyardId: vineyard).isEmpty)
        mismatch = false; await cache.refresh(vineyardId: vineyard, paddocks: [paddock()]); #expect(cache.weights(vineyardId: vineyard).isEmpty)
    }
}

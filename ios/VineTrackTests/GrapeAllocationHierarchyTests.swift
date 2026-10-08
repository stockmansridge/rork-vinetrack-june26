import Foundation
import XCTest
@testable import VineTrack

final class GrapeAllocationHierarchyTests: XCTestCase {
    private let vineyard = UUID()
    private let b7 = UUID()
    private let b49 = UUID()

    private func allocation(_ tonnes: Double = 5, own: Bool = false, blocks: [GrapeAllocationBlock] = []) -> GrapeAllocation {
        GrapeAllocation(vineyardId: vineyard, vintage: 2026, allocationType: own ? .ownUse : .external,
                        varietyName: "Pinot Gris", quantityTonnes: tonnes, blocks: blocks)
    }
    private func link(_ id: UUID, _ tonnes: Double? = nil) -> GrapeAllocationBlock {
        GrapeAllocationBlock(paddockId: id, paddockName: "Old snapshot", quantityTonnes: tonnes)
    }
    private func rows(_ allocations: [GrapeAllocation], estimates: [GrapeAllocationHierarchy.Estimate] = []) -> [GrapeAllocationHierarchy.BlockRow] {
        GrapeAllocationHierarchy.rows(varietyKey: "pinot gris", vineyardId: vineyard, vintage: 2026,
                                     allocations: allocations, estimates: estimates, blockNames: [b7: "B7", b49: "B49"])
    }

    func testCustomerRelationshipsUseSetupNamesAndPersistedIDs() {
        let pinot = allocation(blocks: [link(b7)])
        var sauvignon = allocation(blocks: [link(b49)])
        sauvignon.varietyName = "Sauvignon Blanc"
        let all = [pinot, sauvignon]
        XCTAssertEqual(rows(all).first?.name, "B7")
        XCTAssertEqual(rows(all).first?.allocationIds, [pinot.id])
        let sb = GrapeAllocationHierarchy.rows(varietyKey: "sauvignon blanc", vineyardId: vineyard, vintage: 2026,
            allocations: all, estimates: [], blockNames: [b7: "B7", b49: "B49"])
        XCTAssertEqual(sb.first?.name, "B49")
        XCTAssertEqual(sb.first?.externalTonnes, 5)
    }

    func testSeveralAllocationsAndSplitReconcileWithCanonicalParent() {
        let own = allocation(2, own: true, blocks: [link(b7, 2)])
        let external = allocation(6, blocks: [link(b7, 1), link(b49, 4)])
        let children = rows([own, external])
        let block = children.first { $0.paddockId == b7 }
        XCTAssertEqual(block?.ownUseTonnes, 2)
        XCTAssertEqual(block?.externalTonnes, 1)
        XCTAssertEqual(Set(block?.allocationIds ?? []), Set([own.id, external.id]))
        XCTAssertEqual(children.first { $0.paddockId == nil }?.allocatedTonnes, 1)
        let parent = GrapeAllocationCalculator.canonicalVarietyRows(supply: [:], allocations: [own, external], vintage: 2026)[0]
        XCTAssertEqual(children.reduce(0) { $0 + $1.ownUseTonnes }, parent.ownUseTonnes)
        XCTAssertEqual(children.reduce(0) { $0 + $1.externalTonnes }, parent.externalTonnes)
    }

    func testMissingMultiBlockQuantitiesNeverInventDistribution() {
        let children = rows([allocation(9, blocks: [link(b7, 3), link(b49)])])
        XCTAssertEqual(children.first { $0.paddockId == b49 }?.allocatedTonnes, 0)
        XCTAssertEqual(children.first { $0.paddockId == b49 }?.hasUnspecifiedQuantity, true)
        XCTAssertEqual(children.first { $0.paddockId == nil }?.allocatedTonnes, 6)
        let missing = rows([allocation(blocks: [link(b7), link(b49)])])
        XCTAssertEqual(missing.first { $0.paddockId == nil }?.allocatedTonnes, 5)
    }

    func testExplicitZeroAndDuplicateLinksArePreserved() {
        let zero = rows([allocation(blocks: [link(b7, 0)])])
        XCTAssertEqual(zero.first { $0.paddockId == b7 }?.externalTonnes, 0)
        XCTAssertEqual(zero.first { $0.paddockId == nil }?.externalTonnes, 5)
        let duplicate = rows([allocation(blocks: [link(b7, 2), link(b7, 3)])])
        XCTAssertEqual(duplicate.count, 1)
        XCTAssertEqual(duplicate.first?.externalTonnes, 5)
        XCTAssertEqual(duplicate.first?.allocationIds.count, 1)
    }

    func testUnknownEstimateIsNotZeroAndKnownSupplyBalances() {
        let a = allocation(blocks: [link(b7)])
        let known = rows([a], estimates: [.init(paddockId: b7, varietyName: "Pinot Gris", tonnes: 8)])
        XCTAssertEqual(known.first?.estimatedTonnes, 8)
        XCTAssertEqual(known.first?.balanceTonnes, 3)
        let unknown = rows([a], estimates: [.init(paddockId: b7, varietyName: "Pinot Gris", tonnes: nil)])
        XCTAssertNil(unknown.first?.estimatedTonnes)
        XCTAssertNil(unknown.first?.balanceTonnes)
        let noBlock = rows([allocation()])[0]
        XCTAssertEqual(noBlock.name, "No block specified")
        XCTAssertNil(noBlock.estimatedTonnes)
    }

    func testEstimateGroupsSumWithoutCopyingVarietyTotal() {
        let children = rows([], estimates: [
            .init(paddockId: b7, varietyName: "Pinot Gris", tonnes: 4),
            .init(paddockId: b7, varietyName: "PINOT GRIS", tonnes: 2),
            .init(paddockId: b49, varietyName: "Pinot Gris", tonnes: 7),
            .init(paddockId: b49, varietyName: "Sauvignon Blanc", tonnes: 20)
        ])
        XCTAssertEqual(children.first { $0.paddockId == b7 }?.estimatedTonnes, 6)
        XCTAssertEqual(children.first { $0.paddockId == b49 }?.estimatedTonnes, 7)
        XCTAssertEqual(children.compactMap(\.estimatedTonnes).reduce(0, +), 13)
    }

    func testVineyardAndVintageIsolation() {
        let current = allocation(blocks: [link(b7)])
        var otherVineyard = current; otherVineyard.vineyardId = UUID()
        var otherVintage = current; otherVintage.vintage = 2025
        let children = rows([current, otherVineyard, otherVintage])
        XCTAssertEqual(children.first?.externalTonnes, 5)
        XCTAssertEqual(children.first?.allocationIds, [current.id])
    }

    func testLegacyOverassignmentReconcilesWithoutChangingRecords() {
        let a = allocation(5, blocks: [link(b7, 7)])
        let children = rows([a])
        XCTAssertEqual(children.first { $0.paddockId == nil }?.allocatedTonnes, -2)
        XCTAssertEqual(children.reduce(0) { $0 + $1.allocatedTonnes }, 5)
        XCTAssertEqual(a.blocks[0].quantityTonnes, 7)
    }

    @MainActor
    func testEditPayloadAndReloadKeepIdentityAndExactQuantity() throws {
        let original = allocation(5.123456789, blocks: [link(b7, 2.123456789), link(b49, 3)])
        let decoded = try JSONDecoder().decode(GrapeAllocation.self, from: JSONEncoder().encode(original))
        var edited = decoded
        edited.notes = "Edited through block child"
        let payload = BackendGrapeAllocation.upsert(from: edited, createdBy: nil, clientUpdatedAt: Date())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let remote = try decoder.decode(BackendGrapeAllocation.self, from: encoder.encode(payload))
        let reloaded = remote.toGrapeAllocation(blocks: edited.blocks)
        XCTAssertEqual(reloaded.id, original.id)
        XCTAssertEqual(reloaded.quantityTonnes, original.quantityTonnes)
        XCTAssertEqual(reloaded.blocks.map(\.id), original.blocks.map(\.id))
        XCTAssertEqual(rows([reloaded]).reduce(0) { $0 + $1.allocatedTonnes }, original.quantityTonnes, accuracy: 1e-10)
    }
}

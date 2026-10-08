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

    func testPortalAliasesCapitalizationAndDistinctVarieties() {
        for alias in ["Pinot Gris", " pinot   grigio ", "PINOT_GRIGIO", "Pinot Gris / Grigio", "PG"] {
            XCTAssertEqual(GrapeAllocationHierarchy.varietyKey(alias), "pinot gris")
            XCTAssertEqual(GrapeAllocationHierarchy.varietyLabel(alias), "Pinot Gris")
        }
        XCTAssertEqual(GrapeAllocationHierarchy.varietyLabel("sauvignon blanc"), "Sauvignon Blanc")
        XCTAssertEqual(GrapeAllocationHierarchy.varietyLabel("grüner veltliner"), "Gruner Veltliner")
        XCTAssertEqual(GrapeAllocationHierarchy.varietyKey("Syrah"), "shiraz")
        XCTAssertNotEqual(GrapeAllocationHierarchy.varietyKey("Pinot Noir"), GrapeAllocationHierarchy.varietyKey("Pinot Gris"))
        XCTAssertNotEqual(GrapeAllocationHierarchy.varietyKey("Custom-A"), GrapeAllocationHierarchy.varietyKey("Custom A"))
        XCTAssertNotEqual(GrapeAllocationHierarchy.varietyKey("Savagnin"), GrapeAllocationHierarchy.varietyKey("Sauvignon Blanc"))
        XCTAssertEqual(GrapeAllocationHierarchy.varietyLabel("custom variety"), "Custom Variety")
    }

    func testGroupedSupplyChildrenAndVineyardTotalsReconcileWithDamage() {
        let varieties = ["pinot gris", "Pinot Grigio", "SAUVIGNON BLANC"].enumerated().map { index, name in
            SeasonYieldProjection.VarietyRow(varietyIdentity: String(index), varietyKey: nil, displayName: name,
                isUnallocated: false, isEstimateComplete: true, baseTonnes: [4.0, 6.0, 8.0][index],
                knownBaseTonnes: [4.0, 6.0, 8.0][index], adjustedTonnes: [3.0, 5.0, 7.0][index],
                knownAdjustedTonnes: [3.0, 5.0, 7.0][index], paddockIds: [b7])
        }
        let own = allocation(2, own: true, blocks: [link(b7)])
        var external = allocation(5, blocks: [link(b7, 2), link(b49, 2)]); external.varietyName = "Pinot Grigio"
        var sb = allocation(3, blocks: [link(b49)]); sb.varietyName = "sauvignon blanc"
        var other = external; other.vineyardId = UUID()
        var old = external; old.vintage = 2025
        for damage in [false, true] {
            let projection = SeasonYieldProjection.Result(vineyardId: vineyard, vintage: 2026, damageApplied: damage,
                isEstimateComplete: true, totalBaseTonnes: 18, totalAdjustedTonnes: 15, knownBaseTonnes: 18,
                knownAdjustedTonnes: 15, estimateSource: "fixture", calculatedAt: nil, blocksTotal: 2,
                blocksAvailable: 2, blocksUnavailable: 0, blocksWithEstimates: 2, blocksMissingEstimates: 0,
                blocks: [], varieties: varieties, warnings: [])
            let grouped = GrapeAllocationHierarchy.varietyRows(supply: GrapeAllocationHierarchy.supply(projection),
                allocations: [own, external, sb, other, old], vineyardId: vineyard, vintage: 2026)
            XCTAssertEqual(grouped.count, 2)
            let pinot = grouped.first { $0.varietyKey == "pinot gris" }!
            XCTAssertEqual(pinot.displayName, "Pinot Gris")
            XCTAssertEqual(pinot.estimatedTonnes, damage ? 8 : 10)
            XCTAssertEqual(pinot.ownUseTonnes, 2)
            XCTAssertEqual(pinot.externalTonnes, 5)
            let children = rows([own, external], estimates: [
                .init(paddockId: b7, varietyName: "Pinot Gris", tonnes: damage ? 3 : 4),
                .init(paddockId: b7, varietyName: "Pinot Grigio", tonnes: damage ? 5 : 6)])
            XCTAssertEqual(children.compactMap(\.estimatedTonnes).reduce(0, +), pinot.estimatedTonnes)
            XCTAssertEqual(children.reduce(0) { $0 + $1.ownUseTonnes }, pinot.ownUseTonnes)
            XCTAssertEqual(children.reduce(0) { $0 + $1.externalTonnes }, pinot.externalTonnes)
            XCTAssertEqual(Set(children.flatMap(\.allocationIds)), Set([own.id, external.id]))
            let summary = GrapeAllocationCalculator.canonicalSummary(projection: projection, allocations: [own, external, sb], vintage: 2026)
            XCTAssertEqual(grouped.compactMap(\.estimatedTonnes).reduce(0, +), summary.estimatedTonnes)
            XCTAssertEqual(grouped.reduce(0) { $0 + $1.ownUseTonnes }, summary.ownUseTonnes)
            XCTAssertEqual(grouped.reduce(0) { $0 + $1.externalTonnes }, summary.committedTonnes)
            XCTAssertEqual(grouped.compactMap(\.balanceTonnes).reduce(0, +), summary.balanceTonnes)
        }
        XCTAssertEqual(external.varietyName, "Pinot Grigio")
        XCTAssertEqual(external.blocks.map(\.quantityTonnes), [2, 2])
    }

    func testGroupedUnknownSupplyStaysUnknownAndCustomNamesStaySeparate() {
        let supply: [GrapeAllocationCalculator.CanonicalSupply] = [
            .init(varietyKey: "a", displayName: "Pinot Gris", tonnes: 4, knownTonnes: 4, isEstimateComplete: true),
            .init(varietyKey: "b", displayName: "Pinot Grigio", tonnes: nil, knownTonnes: 2, isEstimateComplete: false)]
        var customA = allocation(); customA.varietyName = "Custom-A"
        var customB = allocation(); customB.varietyName = "Custom A"
        let grouped = GrapeAllocationHierarchy.varietyRows(supply: supply, allocations: [customA, customB], vineyardId: vineyard, vintage: 2026)
        XCTAssertEqual(grouped.count, 3)
        let pinot = grouped.first { $0.varietyKey == "pinot gris" }!
        XCTAssertNil(pinot.estimatedTonnes)
        XCTAssertNil(pinot.balanceTonnes)
        XCTAssertEqual(pinot.knownEstimatedTonnes, 6)
        XCTAssertFalse(pinot.isEstimateComplete)
        let children = rows([], estimates: [.init(paddockId: b7, varietyName: "Pinot Gris", tonnes: 4),
            .init(paddockId: b7, varietyName: "Pinot Grigio", tonnes: nil)])
        XCTAssertNil(children.first?.estimatedTonnes)
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

import XCTest
@testable import VineTrack

/// Contract tests for the Grape Allocation calculator. Mirrors
/// `GrapeAllocationCalculatorTest.kt` on Android so both platforms pin the
/// same rules:
///  - supply comes from the latest Yield Estimate rows and is split across a
///    block's variety allocations by percent share
///  - a NEW estimate changes the balance without touching any allocation
///  - Balance = Estimated − Own Use − External; negative = Shortfall
///  - money totals are sums of INDIVIDUAL contract values (tonnes × that
///    contract's $/t), never an averaged $/t
///  - a commitment split across multiple blocks attributes income per block
final class GrapeAllocationLogicTests: XCTestCase {

    private let vineyardId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let blockA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let blockB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

    private var paddocks: [Paddock] {
        [
            Paddock(
                id: blockA,
                vineyardId: vineyardId,
                name: "Shiraz North",
                vineCountOverride: 1000,
                varietyAllocations: [
                    PaddockVarietyAllocation(varietyId: UUID(), percent: 100, name: "Shiraz")
                ]
            ),
            Paddock(
                id: blockB,
                vineyardId: vineyardId,
                name: "River Block",
                vineCountOverride: 500,
                varietyAllocations: [
                    PaddockVarietyAllocation(varietyId: UUID(), percent: 60, name: "Shiraz"),
                    PaddockVarietyAllocation(varietyId: UUID(), percent: 40, name: "Grenache")
                ]
            )
        ]
    }

    private func estimateRow(blockId: UUID, blockName: String, tonnes: Double) -> YieldVintageReport.EstimateRow {
        YieldVintageReport.EstimateRow(
            paddockId: blockId,
            blockName: blockName,
            varietyLabel: "",
            areaHectares: 1,
            baseTonnes: tonnes,
            adjustedTonnes: tonnes,
            damageFactor: 1,
            applyDamage: false,
            averageBunchesPerVine: 0,
            samplesRecorded: 1,
            samplesTotal: 1,
            sessionId: UUID(),
            completedAt: nil
        )
    }

    private func allocation(
        type: GrapeAllocationType,
        variety: String,
        tonnes: Double,
        vintage: Int = 2027,
        purchaser: String? = nil,
        price: Double? = nil,
        blocks: [GrapeAllocationBlock] = []
    ) -> GrapeAllocation {
        GrapeAllocation(
            vineyardId: vineyardId,
            vintage: vintage,
            allocationType: type,
            varietyName: variety,
            quantityTonnes: tonnes,
            purchaserName: purchaser,
            pricePerTonne: price,
            blocks: blocks
        )
    }

    // MARK: - Supply split by variety allocation share

    func testVarietyEstimatesSplitBlocksByAllocationShare() {
        let estimates = GrapeAllocationCalculator.varietyEstimates(
            estimateRows: [
                estimateRow(blockId: blockA, blockName: "Shiraz North", tonnes: 10),
                estimateRow(blockId: blockB, blockName: "River Block", tonnes: 5),
            ],
            paddocks: paddocks
        )
        // Shiraz: 10 (block A) + 5 × 60% (block B) = 13; Grenache: 5 × 40% = 2.
        XCTAssertEqual(estimates["shiraz"]?.tonnes ?? 0, 13.0, accuracy: 0.0001)
        XCTAssertEqual(estimates["grenache"]?.tonnes ?? 0, 2.0, accuracy: 0.0001)
    }

    // MARK: - Balance & shortfall

    func testAvailableBecomesShortfallWhenOverCommitted() {
        let estimates = GrapeAllocationCalculator.varietyEstimates(
            estimateRows: [estimateRow(blockId: blockA, blockName: "Shiraz North", tonnes: 10)],
            paddocks: paddocks
        )
        let allocations = [
            allocation(type: .ownUse, variety: "Shiraz", tonnes: 3),
            allocation(type: .external, variety: "Shiraz", tonnes: 5, purchaser: "Winery A"),
        ]
        let summary = GrapeAllocationCalculator.summary(estimates: estimates, allocations: allocations, vintage: 2027)
        XCTAssertEqual(summary.balanceTonnes, 2.0, accuracy: 0.0001)
        XCTAssertFalse(summary.isShortfall)

        let overCommitted = allocations + [allocation(type: .external, variety: "Shiraz", tonnes: 4, purchaser: "Winery B")]
        let short = GrapeAllocationCalculator.summary(estimates: estimates, allocations: overCommitted, vintage: 2027)
        XCTAssertEqual(short.balanceTonnes, -2.0, accuracy: 0.0001)
        XCTAssertTrue(short.isShortfall)
    }

    func testNewYieldEstimateMovesBalanceWithoutTouchingAllocations() {
        let allocations = [allocation(type: .external, variety: "Shiraz", tonnes: 8, purchaser: "Winery A")]

        // First trip estimated 10 t → 2 t available.
        let before = GrapeAllocationCalculator.summary(
            estimates: GrapeAllocationCalculator.varietyEstimates(
                estimateRows: [estimateRow(blockId: blockA, blockName: "Shiraz North", tonnes: 10)],
                paddocks: paddocks
            ),
            allocations: allocations,
            vintage: 2027
        )
        XCTAssertEqual(before.balanceTonnes, 2.0, accuracy: 0.0001)
        XCTAssertFalse(before.isShortfall)

        // A NEWER completed trip (latest wins) estimates only 6 t: the SAME
        // allocation records now show a 2 t shortfall.
        let after = GrapeAllocationCalculator.summary(
            estimates: GrapeAllocationCalculator.varietyEstimates(
                estimateRows: [estimateRow(blockId: blockA, blockName: "Shiraz North", tonnes: 6)],
                paddocks: paddocks
            ),
            allocations: allocations,
            vintage: 2027
        )
        XCTAssertEqual(after.balanceTonnes, -2.0, accuracy: 0.0001)
        XCTAssertTrue(after.isShortfall)
    }

    func testVarietyRowsFlagPerVarietyShortfall() {
        let estimates = GrapeAllocationCalculator.varietyEstimates(
            estimateRows: [estimateRow(blockId: blockB, blockName: "River Block", tonnes: 5)],
            paddocks: paddocks
        )
        let rows = GrapeAllocationCalculator.varietyRows(
            estimates: estimates,
            allocations: [allocation(type: .external, variety: "Grenache", tonnes: 3, purchaser: "Winery A")],
            vintage: 2027
        )
        let grenache = rows.first { $0.varietyKey == "grenache" }
        XCTAssertNotNil(grenache)
        XCTAssertEqual(grenache?.estimatedTonnes ?? 0, 2.0, accuracy: 0.0001)
        XCTAssertEqual(grenache?.externalTonnes ?? 0, 3.0, accuracy: 0.0001)
        XCTAssertEqual(grenache?.balanceTonnes ?? 0, -1.0, accuracy: 0.0001)
        XCTAssertTrue(grenache?.isShortfall ?? false)

        // Shiraz has estimate but no allocation — still listed, no shortfall.
        let shiraz = rows.first { $0.varietyKey == "shiraz" }
        XCTAssertEqual(shiraz?.balanceTonnes ?? 0, 3.0, accuracy: 0.0001)
        XCTAssertFalse(shiraz?.isShortfall ?? true)
    }

    // MARK: - Money: individual contract values, never averaged

    func testContractsAtDifferentPricesTotalIndividually() {
        let allocations = [
            allocation(type: .external, variety: "Shiraz", tonnes: 20, purchaser: "Winery A", price: 2500),
            allocation(type: .external, variety: "Chardonnay", tonnes: 10, purchaser: "Winery B", price: 1800),
            // No price → contributes nothing (not a zero-priced average input).
            allocation(type: .external, variety: "Merlot", tonnes: 5, purchaser: "Winery C"),
            // Own use never contributes income.
            allocation(type: .ownUse, variety: "Shiraz", tonnes: 3),
        ]
        // 20×2500 + 10×1800 = 68 000 — NOT (35 t × averaged $/t).
        XCTAssertEqual(
            GrapeAllocationCalculator.totalContractedIncome(allocations: allocations, vintage: 2027),
            68000.0, accuracy: 0.0001
        )

        let byPurchaser = GrapeAllocationCalculator.incomeByPurchaser(allocations: allocations, vintage: 2027)
        XCTAssertEqual(byPurchaser.first { $0.label == "Winery A" }?.value ?? 0, 50000, accuracy: 0.0001)
        XCTAssertEqual(byPurchaser.first { $0.label == "Winery B" }?.value ?? 0, 18000, accuracy: 0.0001)
        XCTAssertNil(byPurchaser.first { $0.label == "Winery C" })

        let byVariety = GrapeAllocationCalculator.incomeByVariety(allocations: allocations, vintage: 2027)
        XCTAssertEqual(byVariety.first { $0.label == "Shiraz" }?.value ?? 0, 50000, accuracy: 0.0001)
    }

    func testCommitmentSplitAcrossMultipleBlocksAttributesIncomePerBlock() {
        let contract = allocation(
            type: .external, variety: "Shiraz", tonnes: 15, purchaser: "Winery A", price: 2000,
            blocks: [
                GrapeAllocationBlock(paddockId: blockA, paddockName: "Shiraz North", quantityTonnes: 9),
                GrapeAllocationBlock(paddockId: blockB, paddockName: "River Block", quantityTonnes: 6),
            ]
        )
        let byBlock = GrapeAllocationCalculator.incomeByBlock(allocations: [contract], vintage: 2027)
        XCTAssertEqual(byBlock.first { $0.label == "Shiraz North" }?.value ?? 0, 18000, accuracy: 0.0001)
        XCTAssertEqual(byBlock.first { $0.label == "River Block" }?.value ?? 0, 12000, accuracy: 0.0001)
    }

    func testBlockSplitSharesRemainderAndHandlesUnassigned() {
        // One block with an explicit 9 t, two without: they share 15−9 = 6 t.
        let mixed = allocation(
            type: .external, variety: "Shiraz", tonnes: 15, purchaser: "W", price: 1000,
            blocks: [
                GrapeAllocationBlock(paddockId: blockA, paddockName: "A", quantityTonnes: 9),
                GrapeAllocationBlock(paddockId: blockB, paddockName: "B"),
                GrapeAllocationBlock(paddockId: UUID(), paddockName: "C"),
            ]
        )
        let split = GrapeAllocationCalculator.blockTonnesSplit(mixed)
        XCTAssertEqual(split.first { $0.label == "A" }?.tonnes ?? 0, 9, accuracy: 0.0001)
        XCTAssertEqual(split.first { $0.label == "B" }?.tonnes ?? 0, 3, accuracy: 0.0001)
        XCTAssertEqual(split.first { $0.label == "C" }?.tonnes ?? 0, 3, accuracy: 0.0001)

        // No blocks at all → everything lands under "Unassigned".
        let unassigned = allocation(type: .external, variety: "Shiraz", tonnes: 4, purchaser: "W", price: 1000)
        let byBlock = GrapeAllocationCalculator.incomeByBlock(allocations: [unassigned], vintage: 2027)
        XCTAssertEqual(byBlock.first { $0.label == "Unassigned" }?.value ?? 0, 4000, accuracy: 0.0001)
    }

    // MARK: - Financial privacy at the model layer

    func testAllocationWithoutPriceNeverProducesAContractValue() {
        // A non-owner/manager device never receives prices — its model rows
        // therefore can never derive money.
        let masked = allocation(type: .external, variety: "Shiraz", tonnes: 20, purchaser: "Winery A", price: nil)
        XCTAssertNil(masked.contractValue)
        XCTAssertEqual(GrapeAllocationCalculator.totalContractedIncome(allocations: [masked], vintage: 2027), 0)
        XCTAssertTrue(GrapeAllocationCalculator.incomeByPurchaser(allocations: [masked], vintage: 2027).isEmpty)
        XCTAssertTrue(GrapeAllocationCalculator.incomeByBlock(allocations: [masked], vintage: 2027).isEmpty)
    }
}

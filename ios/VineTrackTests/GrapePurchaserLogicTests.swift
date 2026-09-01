import XCTest
@testable import VineTrack

/// Contract tests for the sql/219 purchaser + allocation-form rules. Mirrors
/// `GrapePurchaserFormLogicTest.kt` on Android so both platforms pin the
/// same behaviour:
///  - selecting a saved purchaser SNAPSHOTS its current details onto the
///    allocation (external only)
///  - editing the purchaser later never rewrites an existing snapshot
///  - Own Use can never carry a purchaser link or purchaser/contact data
///  - one purchaser can back multiple allocations, each with its own
///    contract (tonnes × THAT contract's $/t — never averaged)
///  - additive block assignment must never exceed the committed quantity
final class GrapePurchaserLogicTests: XCTestCase {

    private let vineyardId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let purchaserId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private var purchaser: GrapePurchaser {
        GrapePurchaser(
            id: purchaserId,
            vineyardId: vineyardId,
            wineryName: "Stone Hut Wines",
            contactName: "Alice",
            contactEmail: "alice@stonehut.test",
            contactPhone: "+61 400 000 001",
            contactAddress: "1 Cellar Lane"
        )
    }

    private func externalAllocation(tonnes: Double = 10, price: Double? = nil) -> GrapeAllocation {
        GrapeAllocation(
            vineyardId: vineyardId,
            vintage: 2027,
            allocationType: .external,
            varietyName: "Shiraz",
            quantityTonnes: tonnes,
            pricePerTonne: price
        )
    }

    // MARK: - Purchaser snapshot

    func testSelectingPurchaserCopiesCurrentDetailsOntoAllocation() {
        let linked = GrapeAllocationFormLogic.applyingPurchaserSnapshot(
            to: externalAllocation(), purchaser: purchaser
        )
        XCTAssertEqual(linked.purchaserId, purchaserId)
        XCTAssertEqual(linked.purchaserName, "Stone Hut Wines")
        XCTAssertEqual(linked.contactName, "Alice")
        XCTAssertEqual(linked.contactEmail, "alice@stonehut.test")
        XCTAssertEqual(linked.contactPhone, "+61 400 000 001")
        XCTAssertEqual(linked.contactAddress, "1 Cellar Lane")
    }

    func testEditingPurchaserLaterDoesNotAlterOldAllocationSnapshot() {
        let linked = GrapeAllocationFormLogic.applyingPurchaserSnapshot(
            to: externalAllocation(), purchaser: purchaser
        )
        // The purchaser record is renamed AFTER the allocation was saved.
        var renamed = purchaser
        renamed.wineryName = "Stone Hut Renamed"
        renamed.contactEmail = "new@stonehut.test"

        // The old allocation keeps its own snapshot untouched.
        XCTAssertEqual(linked.purchaserName, "Stone Hut Wines")
        XCTAssertEqual(linked.contactEmail, "alice@stonehut.test")

        // A NEW allocation snapshots the NEW details.
        let newAllocation = GrapeAllocationFormLogic.applyingPurchaserSnapshot(
            to: externalAllocation(), purchaser: renamed
        )
        XCTAssertEqual(newAllocation.purchaserName, "Stone Hut Renamed")
        XCTAssertEqual(newAllocation.contactEmail, "new@stonehut.test")
    }

    func testOwnUseCannotCarryPurchaser() {
        var ownUse = GrapeAllocation(
            vineyardId: vineyardId,
            vintage: 2027,
            allocationType: .ownUse,
            varietyName: "Shiraz",
            quantityTonnes: 3
        )
        // Applying a snapshot to Own Use is a no-op.
        let unchanged = GrapeAllocationFormLogic.applyingPurchaserSnapshot(to: ownUse, purchaser: purchaser)
        XCTAssertNil(unchanged.purchaserId)
        XCTAssertNil(unchanged.purchaserName)

        // And sanitising strips any stray purchaser data + price.
        ownUse.purchaserId = purchaserId
        ownUse.purchaserName = "Stray"
        ownUse.pricePerTonne = 999
        let sanitized = GrapeAllocationFormLogic.sanitized(ownUse)
        XCTAssertNil(sanitized.purchaserId)
        XCTAssertNil(sanitized.purchaserName)
        XCTAssertNil(sanitized.contactEmail)
        XCTAssertNil(sanitized.pricePerTonne)
    }

    func testSanitizedLeavesExternalAllocationUntouched() {
        let linked = GrapeAllocationFormLogic.applyingPurchaserSnapshot(
            to: externalAllocation(price: 2400), purchaser: purchaser
        )
        let sanitized = GrapeAllocationFormLogic.sanitized(linked)
        XCTAssertEqual(sanitized.purchaserId, purchaserId)
        XCTAssertEqual(sanitized.pricePerTonne, 2400)
    }

    func testOnePurchaserBacksMultipleIndividualContracts() {
        let first = GrapeAllocationFormLogic.applyingPurchaserSnapshot(
            to: externalAllocation(tonnes: 10, price: 2000), purchaser: purchaser
        )
        let second = GrapeAllocationFormLogic.applyingPurchaserSnapshot(
            to: externalAllocation(tonnes: 5, price: 3000), purchaser: purchaser
        )
        XCTAssertEqual(first.purchaserId, second.purchaserId)
        // Each contract's value is tonnes × ITS OWN price — summed, never averaged.
        XCTAssertEqual(first.contractValue, 20_000)
        XCTAssertEqual(second.contractValue, 15_000)
        let total = GrapeAllocationCalculator.totalContractedIncome(
            allocations: [first, second], vintage: 2027
        )
        XCTAssertEqual(total, 35_000, accuracy: 0.001)
    }

    // MARK: - Block assignment

    func testBlockAssignmentWithinQuantity() {
        let summary = GrapeAllocationFormLogic.blockAssignmentSummary(
            quantityTonnes: 6, blockTonnes: [2.5, 1.5]
        )
        XCTAssertEqual(summary.assignedTonnes, 4.0, accuracy: 0.0001)
        XCTAssertEqual(summary.unassignedTonnes, 2.0, accuracy: 0.0001)
        XCTAssertFalse(summary.exceedsQuantity)
    }

    func testBlockAssignmentCannotExceedCommittedQuantity() {
        let summary = GrapeAllocationFormLogic.blockAssignmentSummary(
            quantityTonnes: 6, blockTonnes: [4, 3]
        )
        XCTAssertEqual(summary.assignedTonnes, 7.0, accuracy: 0.0001)
        XCTAssertEqual(summary.unassignedTonnes, 0.0, accuracy: 0.0001)
        XCTAssertTrue(summary.exceedsQuantity)
    }

    func testBlockAssignmentIgnoresRowsWithoutTonnes() {
        let summary = GrapeAllocationFormLogic.blockAssignmentSummary(
            quantityTonnes: 6, blockTonnes: [2.5, nil, nil]
        )
        XCTAssertEqual(summary.assignedTonnes, 2.5, accuracy: 0.0001)
        XCTAssertEqual(summary.unassignedTonnes, 3.5, accuracy: 0.0001)
        XCTAssertFalse(summary.exceedsQuantity)
    }

    func testBlockAssignmentExactMatchIsNotAnOverrun() {
        let summary = GrapeAllocationFormLogic.blockAssignmentSummary(
            quantityTonnes: 6, blockTonnes: [4, 2]
        )
        XCTAssertFalse(summary.exceedsQuantity)
        XCTAssertEqual(summary.unassignedTonnes, 0.0, accuracy: 0.0001)
    }
}

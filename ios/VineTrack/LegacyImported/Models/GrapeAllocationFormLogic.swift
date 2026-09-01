import Foundation

/// Pure form rules for the Grape Allocation editor, shared contract with
/// Android (`GrapeAllocationFormLogic` in `GrapeAllocationModels.kt`) so
/// both platforms pin the same behaviour:
///
///  * Block assignment is ADDITIVE (add block → tonnes → remove) and the
///    assigned total must never exceed the committed quantity.
///  * Selecting a saved purchaser SNAPSHOTS its current details onto the
///    allocation; later purchaser edits never rewrite old snapshots
///    (value semantics — the allocation keeps its own copy).
///  * Own Use can never carry a purchaser link or purchaser/contact data.
nonisolated enum GrapeAllocationFormLogic {

    /// Tolerance below which an over-assignment is floating-point noise.
    static let assignmentTolerance: Double = 0.0005

    nonisolated struct BlockAssignmentSummary: Sendable, Equatable {
        /// Sum of the explicit per-block tonnes.
        let assignedTonnes: Double
        /// Committed quantity not yet assigned to a block (never negative).
        let unassignedTonnes: Double
        /// true when assigned tonnes exceed the committed quantity.
        let exceedsQuantity: Bool
    }

    /// Assigned / unassigned split for the "Assigned X of Y · Unassigned Z"
    /// line. `blockTonnes` carries one entry per block row (nil = the row
    /// has no tonnes entered yet).
    static func blockAssignmentSummary(
        quantityTonnes: Double,
        blockTonnes: [Double?]
    ) -> BlockAssignmentSummary {
        let assigned = blockTonnes.compactMap { $0 }.reduce(0, +)
        return BlockAssignmentSummary(
            assignedTonnes: assigned,
            unassignedTonnes: max(0, quantityTonnes - assigned),
            exceedsQuantity: assigned > quantityTonnes + assignmentTolerance
        )
    }

    /// Copies the purchaser's CURRENT details onto an external allocation as
    /// a point-in-time snapshot and links `purchaserId`. Own Use allocations
    /// are returned unchanged — they can never carry a purchaser.
    static func applyingPurchaserSnapshot(
        to allocation: GrapeAllocation,
        purchaser: GrapePurchaser
    ) -> GrapeAllocation {
        guard allocation.allocationType == .external else { return allocation }
        var updated = allocation
        updated.purchaserId = purchaser.id
        updated.purchaserName = purchaser.wineryName
        updated.contactName = purchaser.contactName
        updated.contactEmail = purchaser.contactEmail
        updated.contactPhone = purchaser.contactPhone
        updated.contactAddress = purchaser.contactAddress
        return updated
    }

    /// Enforces the Own Use rule client-side (the DB constraint is
    /// authoritative): strips the purchaser link, snapshot fields and price
    /// from non-external allocations.
    static func sanitized(_ allocation: GrapeAllocation) -> GrapeAllocation {
        guard allocation.allocationType != .external else { return allocation }
        var updated = allocation
        updated.purchaserId = nil
        updated.purchaserName = nil
        updated.contactName = nil
        updated.contactEmail = nil
        updated.contactPhone = nil
        updated.contactAddress = nil
        updated.pricePerTonne = nil
        return updated
    }
}

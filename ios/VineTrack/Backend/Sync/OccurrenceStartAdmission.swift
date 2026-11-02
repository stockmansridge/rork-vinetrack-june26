import Foundation

/// P0 3.1.9: decides whether a retained, unconfirmed occurrence start blocks a
/// new planned start.
///
/// The previous gate refused every new planned start while any retained
/// occurrence Trip had an unconfirmed creation. That blocked an unrelated
/// Grüner Veltliner start behind an unrecoverable Cab Franc Trip. The safety
/// intent is kept:
///  - the same original spray/job identity, not merely an overlapping block, must be
///    recovered with its original IDs, never re-minted;
///  - the device's own active Trip always blocks;
///  - an unheld create/activate chain could later replay and produce a second
///    active Trip, so it is durably held first. The hold keeps every pending
///    operation and history entry, blocks automatic replay, and can only be
///    lifted by `releaseHeldOriginalCreationAfterVerifiedServerAbsence`.
nonisolated enum OccurrenceStartAdmission {
    enum Decision: Equatable, Sendable {
        /// Creation is confirmed or not retained; this Trip does not affect the new start.
        case unrelated
        /// Independent work whose original start is already held and cannot replay automatically.
        case independentAlreadyHeld
        /// Independent work. Hold the original chain (no discard) before minting the new Trip.
        case holdBeforeIndependentStart
        /// Must be recovered first; the fixed code explains why.
        case conflict(String)
    }

    static let supersededHoldCode = "OCCURRENCE_START_HELD_FOR_INDEPENDENT_START"

    struct Retained: Sendable {
        let tripId: UUID
        let vineyardId: UUID
        let blockIds: Set<UUID>
        let isDeviceActiveTrip: Bool
        let creationConfirmed: Bool?
        let heldReason: String?
    }

    /// Overlapping blocks alone do not prove identical planned work: a grower can
    /// spray Cab Franc twice on different dates. The caller must prove a shared
    /// original spray/plan identity or obtain explicit confirmation that this is
    /// DIFFERENT work. Even then, the original unconfirmed create/activate chain
    /// is durably held before the new Trip obtains any identity.
    static func decide(
        _ retained: Retained, newVineyardId: UUID, newBlockIds: Set<UUID>,
        sameOriginalWorkProven: Bool = false, distinctWorkConfirmed: Bool = false
    ) -> Decision {
        guard retained.creationConfirmed == false else { return .unrelated }
        if retained.isDeviceActiveTrip { return .conflict("RETAINED_START_IS_DEVICE_ACTIVE_TRIP") }
        let sameVineyard = retained.vineyardId == newVineyardId
        if sameVineyard && sameOriginalWorkProven {
            return .conflict("RETAINED_START_SAME_PLANNED_WORK")
        }
        let overlapping = sameVineyard &&
            (retained.blockIds.isEmpty || newBlockIds.isEmpty || !retained.blockIds.isDisjoint(with: newBlockIds))
        if overlapping && !distinctWorkConfirmed {
            return .conflict("RETAINED_START_INDEPENDENT_WORK_CONFIRMATION_REQUIRED")
        }
        return retained.heldReason != nil ? .independentAlreadyHeld : .holdBeforeIndependentStart
    }
}

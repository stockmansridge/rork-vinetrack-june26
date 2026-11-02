import Foundation

/// Classification only. Legacy Trip upload metadata is keyed by Trip ID, not
/// account+vineyard. It must never be interpreted as permission to replay
/// against whichever vineyard happens to be selected.
nonisolated enum TripQueuedUploadScope: String, Sendable, Hashable {
    case selectedSlice = "SELECTED_SLICE"
    case persistedCurrentVineyardNotLoaded = "CURRENT_VINEYARD_SNAPSHOT_NOT_LOADED"
    case persistedOtherVineyard = "OTHER_VINEYARD_SNAPSHOT_PROTECTED"
    case noLocalSnapshot = "ORIGINAL_SNAPSHOT_UNAVAILABLE"

    static func classify(
        tripId: UUID,
        selectedVineyardId: UUID,
        selectedTrips: [UUID: UUID],
        persistedTrips: [UUID: UUID]
    ) -> Self {
        if selectedTrips[tripId] == selectedVineyardId { return .selectedSlice }
        if let vineyard = selectedTrips[tripId] ?? persistedTrips[tripId] {
            return vineyard == selectedVineyardId
                ? .persistedCurrentVineyardNotLoaded
                : .persistedOtherVineyard
        }
        return .noLocalSnapshot
    }

    /// The only scope eligible to reach the existing Trip upload path. This is
    /// NOT an upload ACK; all the other eligibility/retention gates still apply.
    var eligibleForCurrentVineyardUpload: Bool { self == .selectedSlice }
}

/** A server tombstone cannot acknowledge a different outstanding local upload.
 * This policy never clears Trip queue entries, operation journals or local data.
 */
nonisolated enum TripServerTombstonePolicy {
    static func mayApplyRemoteDeletion(hasOriginalPendingUpload: Bool) -> Bool {
        !hasOriginalPendingUpload
    }
}

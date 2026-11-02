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

/// Read-only distinction between pending queue entries on the selected vineyard
/// and legacy IDs whose original account/vineyard is not established in this
/// loaded slice. Never treats a foreign failure as failure of the selected
/// vineyard, nor an absent original snapshot as an acknowledged upload.
nonisolated struct TripQueuedScopeSummary: Equatable {
    let selectedQueuedCount: Int
    let outsideSelectedQueuedCount: Int
    let selectedFailedCount: Int
    var unresolvedCount: Int { selectedQueuedCount + outsideSelectedQueuedCount }

    static func evaluate(
        queuedIds: Set<UUID>, failedIds: Set<UUID>, selectedVineyardId: UUID,
        visibleTripVineyards: [UUID: UUID]
    ) -> Self {
        let selected = queuedIds.filter { visibleTripVineyards[$0] == selectedVineyardId }
        return Self(
            selectedQueuedCount: selected.count,
            outsideSelectedQueuedCount: queuedIds.count - selected.count,
            selectedFailedCount: failedIds.intersection(selected).count
        )
    }
}

/// Global legacy IDs still prevent a full-sync receipt, but a held Trip
/// belonging only to a foreign/unidentified scope is not a CURRENT vineyard
/// error. Never delete its queue entry or report a fully drained upload.
nonisolated enum TripSyncHoldPresentation {
    static func needsCurrentVineyardAttention(
        selectedQueuedCount: Int, currentRetainedCount: Int
    ) -> Bool {
        selectedQueuedCount > 0 || currentRetainedCount > 0
    }
}

/** A server tombstone cannot acknowledge a different outstanding local upload.
 * This policy never clears Trip queue entries, operation journals or local data.
 */
nonisolated enum TripServerTombstonePolicy {
    static func mayApplyRemoteDeletion(hasOriginalPendingUpload: Bool) -> Bool {
        !hasOriginalPendingUpload
    }
}

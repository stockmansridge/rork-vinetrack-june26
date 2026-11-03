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

/// Read-only, mutually exclusive explanation of every queued Trip upload ID.
///
/// The totals shown elsewhere (queue entries, failures, selected-vineyard work,
/// cancelled history) are different projections, which made healthy current
/// work look unhealthy next to old protected entries. Each ID falls into
/// exactly one bucket here, so the buckets always add up to the global count.
/// Never uploads, clears or acknowledges anything.
nonisolated struct TripQueueScopeBreakdown: Equatable, Sendable {
    nonisolated struct OtherVineyardEntry: Equatable, Sendable {
        let tripId: UUID
        let vineyardId: UUID
    }

    /// Live work saved under the selected vineyard.
    let selectedVineyardLive: Int
    /// Trips with a recorded cancellation: history, not live work.
    let cancelledHistory: Int
    /// Saved on this device under exactly one other vineyard: resumable there.
    let otherVineyardSavedOnDevice: [OtherVineyardEntry]
    /// No saved snapshot, or snapshots under several vineyards: stays protected.
    let unattributedOrAmbiguous: Int

    var total: Int {
        selectedVineyardLive + cancelledHistory + otherVineyardSavedOnDevice.count + unattributedOrAmbiguous
    }

    static func evaluate(
        queuedIds: Set<UUID>,
        selectedVineyardId: UUID,
        snapshots: [(tripId: UUID, vineyardId: UUID)],
        cancelledIds: Set<UUID>
    ) -> Self {
        let owners = Dictionary(grouping: snapshots, by: { $0.tripId })
            .mapValues { Set($0.map(\.vineyardId)) }
        var live = 0
        var history = 0
        var unattributed = 0
        var others: [OtherVineyardEntry] = []
        for id in queuedIds.sorted(by: { $0.uuidString < $1.uuidString }) {
            if cancelledIds.contains(id) {
                history += 1
            } else if let vineyards = owners[id], vineyards.count == 1, let owner = vineyards.first {
                if owner == selectedVineyardId {
                    live += 1
                } else {
                    others.append(OtherVineyardEntry(tripId: id, vineyardId: owner))
                }
            } else {
                unattributed += 1
            }
        }
        return Self(selectedVineyardLive: live, cancelledHistory: history,
                    otherVineyardSavedOnDevice: others, unattributedOrAmbiguous: unattributed)
    }

    /// Fixed keys only. Trip and vineyard IDs, never names or content.
    var lines: [String] {
        var out = [
            "queue_breakdown_total: \(total)",
            "queue_breakdown_selected_vineyard_live: \(selectedVineyardLive)",
            "queue_breakdown_cancelled_history: \(cancelledHistory)",
            "queue_breakdown_other_vineyard_saved_on_device: \(otherVineyardSavedOnDevice.count)",
            "queue_breakdown_unattributed_or_ambiguous_owner: \(unattributedOrAmbiguous)",
            "queue_breakdown_note: buckets_are_mutually_exclusive; trip_deletions_and_tank_actuals_are_separate_queues"
        ]
        for entry in otherVineyardSavedOnDevice {
            out.append("other_vineyard_queue_entry: trip=\(entry.tripId.uuidString.lowercased()); saved_vineyard=\(entry.vineyardId.uuidString.lowercased()); action: select_that_vineyard_to_resume; no_cross_vineyard_replay")
        }
        return out
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

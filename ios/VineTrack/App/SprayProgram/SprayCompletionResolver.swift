import Foundation

nonisolated enum SprayCompletionResolver {
    static func status(record: SprayRecord, trip: Trip?) -> SprayCompletionStatus {
        if record.endTime != nil { return .completed }
        if let trip, !trip.isActive, trip.endTime != nil { return .completed }
        if trip?.isActive == true { return .inProgress }
        return .upcoming
    }

    /// Reconcile server-owned Trip provenance and completion; retain pending form edits.
    static func preservingServerCompletion(local: SprayRecord, server: SprayRecord) -> SprayRecord {
        // A just-verified orphan repair is local, durable evidence. Until its
        // conditional server trip_id update succeeds, an ordinary sync may
        // return the still-unlinked remote snapshot; never erase this link.
        if local.recoveredFromServerOrphan && server.canonicalTripId != local.canonicalTripId {
            return local
        }
        var reconciled = local
        if let tripId = server.canonicalTripId {
            reconciled.linkToOperationalTrip(tripId)
        } else {
            reconciled.hasRecordedTripLink = false
        }
        if let end = server.endTime {
            reconciled.endTime = end
            reconciled.syncVersion = server.syncVersion
        }
        return reconciled
    }
}

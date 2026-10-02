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
        var reconciled = local
        if let tripId = server.canonicalTripId { reconciled.tripId = tripId }
        reconciled.hasRecordedTripLink = server.hasRecordedTripLink
        if let end = server.endTime {
            reconciled.endTime = end
            reconciled.syncVersion = server.syncVersion
        }
        return reconciled
    }
}

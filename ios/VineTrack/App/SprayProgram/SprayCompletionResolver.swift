import Foundation

nonisolated enum SprayCompletionResolver {
    static func status(record: SprayRecord, trip: Trip?) -> SprayCompletionStatus {
        if record.endTime != nil { return .completed }
        if let trip, !trip.isActive, trip.endTime != nil { return .completed }
        if trip?.isActive == true { return .inProgress }
        return .upcoming
    }

    /// Reconcile only completion metadata; retain legitimate pending form edits.
    static func preservingServerCompletion(local: SprayRecord, server: SprayRecord) -> SprayRecord {
        guard let end = server.endTime else { return local }
        var reconciled = local
        reconciled.endTime = end
        reconciled.syncVersion = server.syncVersion
        return reconciled
    }
}

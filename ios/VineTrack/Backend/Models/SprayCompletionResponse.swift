import Foundation

/// Canonical completion and sync metadata returned by SQL 259.
nonisolated struct SprayCompletionResponse: Decodable, Sendable {
    let sprayRecordId: UUID
    let endTime: Date
    let completionSource: String
    let serverConfirmed: Bool
    let updatedAt: Date
    let updatedBy: UUID?
    let clientUpdatedAt: Date?
    let syncVersion: Int

    func applying(to local: SprayRecord) throws -> SprayRecord {
        guard serverConfirmed, sprayRecordId == local.id,
              ["existing", "trip_end", "server_now"].contains(completionSource) else {
            throw SprayCompletionFailure.unconfirmed
        }
        var updated = local
        updated.endTime = endTime
        updated.syncVersion = syncVersion
        return updated
    }
}

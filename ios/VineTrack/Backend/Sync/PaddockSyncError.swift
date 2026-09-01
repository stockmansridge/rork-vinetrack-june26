import Foundation

/// Errors surfaced by the block (paddock) sync consistency gate.
nonisolated enum PaddockSyncError: LocalizedError, Equatable {
    /// The server reports active blocks that could not be hydrated into the
    /// local cache even after a full re-fetch. The sync must NOT advance the
    /// `lastSync` watermark or report success in this state, otherwise the
    /// device stays permanently "synced" with missing blocks.
    case hydrationIncomplete(vineyardId: UUID, missingCount: Int)

    /// The push path's read of the complete block cache discovered a decode
    /// failure — AFTER the sync had already decided whether orphan pending
    /// entries may be reclaimed. Nothing may be reclaimed against a cache
    /// that no longer exists, so the sync stops recoverably: the complete
    /// pending queue is preserved, no watermark advances, and the recovery
    /// flag (set by the failed read) sends the NEXT sync through the
    /// pull-first recovery flow.
    case cacheUnreadableDuringPush(vineyardId: UUID)

    var errorDescription: String? {
        switch self {
        case let .hydrationIncomplete(_, missingCount):
            return "Block sync incomplete: \(missingCount) block\(missingCount == 1 ? "" : "s") on the server could not be loaded onto this device. Nothing was marked as synced — sync again to retry."
        case .cacheUnreadableDuringPush:
            return "The local block cache was damaged and has been set aside. Nothing was uploaded or marked as synced — sync again to restore your blocks from the server."
        }
    }
}

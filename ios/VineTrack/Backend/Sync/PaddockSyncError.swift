import Foundation

/// Errors surfaced by the block (paddock) sync consistency gate.
nonisolated enum PaddockSyncError: LocalizedError, Equatable {
    /// The server reports active blocks that could not be hydrated into the
    /// local cache even after a full re-fetch. The sync must NOT advance the
    /// `lastSync` watermark or report success in this state, otherwise the
    /// device stays permanently "synced" with missing blocks.
    case hydrationIncomplete(vineyardId: UUID, missingCount: Int)

    var errorDescription: String? {
        switch self {
        case let .hydrationIncomplete(_, missingCount):
            return "Block sync incomplete: \(missingCount) block\(missingCount == 1 ? "" : "s") on the server could not be loaded onto this device. Nothing was marked as synced — sync again to retry."
        }
    }
}

import Foundation

/// Durable, revision-scoped attachment work for one pin.
nonisolated struct PendingPinPhoto: Codable, Sendable {
    let pinId: UUID
    let vineyardId: UUID
    let revision: UUID
    let imageData: Data
    let capturedAt: Date
    let previousRemotePath: String?
    var uploadedPath: String?
}

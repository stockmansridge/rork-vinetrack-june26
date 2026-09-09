import Foundation

/// Durable attachment work for a standalone or pin-linked growth observation.
nonisolated struct PendingGrowthPhoto: Codable, Sendable {
    let recordId: UUID
    let vineyardId: UUID
    let pinId: UUID?
    let revision: UUID
    let imageData: Data
    let capturedAt: Date
}

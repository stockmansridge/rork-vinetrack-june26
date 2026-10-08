import Foundation

/// Durable explicit removal, stored atomically with the edited Scout revision.
nonisolated struct ScoutAssessmentRemoval: Codable, Equatable, Sendable {
    let id: UUID
    let paddockID: UUID
    let removedAt: Date
    var status: String = "in_progress"
    var acknowledged: Bool? = nil
}

import Foundation

/// Operational status shared by lists, progression and vintage report selection.
nonisolated enum SprayCompletionStatus: Equatable, Sendable {
    case upcoming, inProgress, completed
}

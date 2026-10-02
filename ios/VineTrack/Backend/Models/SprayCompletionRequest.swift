import Foundation

nonisolated struct SprayCompletionRequest: Encodable, Sendable {
    let p_spray_record_id: UUID
    let p_allow_unlinked: Bool
}

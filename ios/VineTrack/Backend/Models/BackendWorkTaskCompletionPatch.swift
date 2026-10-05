import Foundation

/// Narrow, atomic completion write. Date-only corrections omit both audit fields.
nonisolated struct BackendWorkTaskCompletionPatch: Encodable, Sendable {
    let task: BackendWorkTaskUpsert
    let dateOnly: Bool

    enum CodingKeys: String, CodingKey {
        case isFinalized = "is_finalized"
        case endDate = "end_date"
        case finalizedAt = "finalized_at"
        case finalizedBy = "finalized_by"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(task.endDate, forKey: .endDate)
        try c.encode(task.clientUpdatedAt, forKey: .clientUpdatedAt)
        if !dateOnly {
            try c.encode(task.isFinalized, forKey: .isFinalized)
            try c.encode(task.finalizedAt, forKey: .finalizedAt)
            try c.encode(task.finalizedBy, forKey: .finalizedBy)
        }
    }
}

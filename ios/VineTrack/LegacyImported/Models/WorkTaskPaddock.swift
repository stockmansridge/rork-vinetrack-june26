import Foundation

/// Join row associating a WorkTask with a Paddock so a single work task
/// can span multiple paddocks. Mirrors public.work_task_paddocks on
/// Supabase (sql/051).
nonisolated struct WorkTaskPaddock: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var workTaskId: UUID
    var vineyardId: UUID
    var paddockId: UUID
    var areaHa: Double?

    init(
        id: UUID = UUID(),
        workTaskId: UUID,
        vineyardId: UUID,
        paddockId: UUID,
        areaHa: Double? = nil
    ) {
        self.id = id
        self.workTaskId = workTaskId
        self.vineyardId = vineyardId
        self.paddockId = paddockId
        self.areaHa = areaHa
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, workTaskId, vineyardId, paddockId, areaHa
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workTaskId = try c.decode(UUID.self, forKey: .workTaskId)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        paddockId = try c.decode(UUID.self, forKey: .paddockId)
        areaHa = try c.decodeIfPresent(Double.self, forKey: .areaHa)
    }
}

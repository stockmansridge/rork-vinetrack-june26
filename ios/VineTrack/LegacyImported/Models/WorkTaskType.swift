import Foundation

/// Vineyard-scoped, user-editable catalog entry for Work Task types.
/// Mirrors public.work_task_types on Supabase (sql/052). The picker layers
/// these on top of the local `WorkTaskTypeCatalog.defaults` fallback list.
///
/// `WorkTask.taskType` continues to store the resolved string for backward
/// compatibility — there is no `task_type_id` column yet.
nonisolated struct WorkTaskType: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var isDefault: Bool
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        isDefault: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.isDefault = isDefault
        self.sortOrder = sortOrder
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, name, isDefault, sortOrder
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

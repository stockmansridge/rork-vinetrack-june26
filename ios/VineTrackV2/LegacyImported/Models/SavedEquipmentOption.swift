import Foundation

nonisolated struct SavedEquipmentOption: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var category: String
    var value: String

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        category: String = "",
        value: String = ""
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.category = category
        self.value = value
    }

    nonisolated static let categoryEquipmentType = "equipmentType"
    nonisolated static let categoryTractor = "tractor"
    nonisolated static let categoryTractorGear = "tractorGear"
}

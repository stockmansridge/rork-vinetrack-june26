import Foundation

nonisolated struct ButtonConfig: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var color: String
    var index: Int
    var mode: PinMode
    var isGrowthStageButton: Bool

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String,
        color: String,
        index: Int,
        mode: PinMode,
        isGrowthStageButton: Bool = false
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.color = color
        self.index = index
        self.mode = mode
        self.isGrowthStageButton = isGrowthStageButton
    }

    static func defaultRepairButtons(for vineyardId: UUID) -> [ButtonConfig] {
        [
            ButtonConfig(vineyardId: vineyardId, name: "Irrigation", color: "blue", index: 0, mode: .repairs),
            ButtonConfig(vineyardId: vineyardId, name: "Broken Post", color: "brown", index: 1, mode: .repairs),
            ButtonConfig(vineyardId: vineyardId, name: "Vine Issue", color: "green", index: 2, mode: .repairs),
            ButtonConfig(vineyardId: vineyardId, name: "Other", color: "red", index: 3, mode: .repairs),
            ButtonConfig(vineyardId: vineyardId, name: "Irrigation", color: "blue", index: 4, mode: .repairs),
            ButtonConfig(vineyardId: vineyardId, name: "Broken Post", color: "brown", index: 5, mode: .repairs),
            ButtonConfig(vineyardId: vineyardId, name: "Vine Issue", color: "green", index: 6, mode: .repairs),
            ButtonConfig(vineyardId: vineyardId, name: "Other", color: "red", index: 7, mode: .repairs),
        ]
    }

    static func defaultGrowthButtons(for vineyardId: UUID) -> [ButtonConfig] {
        [
            ButtonConfig(vineyardId: vineyardId, name: "Growth Stage", color: "darkgreen", index: 0, mode: .growth, isGrowthStageButton: true),
            ButtonConfig(vineyardId: vineyardId, name: "Powdery", color: "gray", index: 1, mode: .growth),
            ButtonConfig(vineyardId: vineyardId, name: "Downy", color: "yellow", index: 2, mode: .growth),
            ButtonConfig(vineyardId: vineyardId, name: "Blackberries", color: "red", index: 3, mode: .growth),
            ButtonConfig(vineyardId: vineyardId, name: "Growth Stage", color: "darkgreen", index: 4, mode: .growth, isGrowthStageButton: true),
            ButtonConfig(vineyardId: vineyardId, name: "Powdery", color: "gray", index: 5, mode: .growth),
            ButtonConfig(vineyardId: vineyardId, name: "Downy", color: "yellow", index: 6, mode: .growth),
            ButtonConfig(vineyardId: vineyardId, name: "Blackberries", color: "red", index: 7, mode: .growth),
        ]
    }
}

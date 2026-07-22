import Foundation

nonisolated struct ButtonTemplateEntry: Codable, Sendable, Hashable {
    var name: String
    var color: String
    var isGrowthStageButton: Bool

    init(name: String, color: String, isGrowthStageButton: Bool = false) {
        self.name = name
        self.color = color
        self.isGrowthStageButton = isGrowthStageButton
    }
}

nonisolated struct ButtonTemplate: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var mode: PinMode
    var entries: [ButtonTemplateEntry]

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        mode: PinMode = .repairs,
        entries: [ButtonTemplateEntry] = []
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.mode = mode
        self.entries = entries
    }

    func toButtonConfigs(for vineyardId: UUID) -> [ButtonConfig] {
        var configs: [ButtonConfig] = []
        for (i, entry) in entries.prefix(4).enumerated() {
            configs.append(ButtonConfig(
                vineyardId: vineyardId,
                name: entry.name,
                color: entry.color,
                index: i,
                mode: mode,
                isGrowthStageButton: entry.isGrowthStageButton
            ))
            configs.append(ButtonConfig(
                vineyardId: vineyardId,
                name: entry.name,
                color: entry.color,
                index: i + 4,
                mode: mode,
                isGrowthStageButton: entry.isGrowthStageButton
            ))
        }
        return configs
    }

    var hasUniqueColors: Bool {
        let colors = entries.map { $0.color.lowercased() }
        return Set(colors).count == colors.count
    }

    static func defaultRepairTemplate(for vineyardId: UUID) -> ButtonTemplate {
        ButtonTemplate(
            vineyardId: vineyardId,
            name: "Default Repairs",
            mode: .repairs,
            entries: [
                ButtonTemplateEntry(name: "Irrigation", color: "blue"),
                ButtonTemplateEntry(name: "Broken Post", color: "brown"),
                ButtonTemplateEntry(name: "Vine Issue", color: "green"),
                ButtonTemplateEntry(name: "Other", color: "red"),
            ]
        )
    }

    static func defaultGrowthTemplate(for vineyardId: UUID) -> ButtonTemplate {
        ButtonTemplate(
            vineyardId: vineyardId,
            name: "Default Growth",
            mode: .growth,
            entries: [
                ButtonTemplateEntry(name: "Growth Stage", color: "darkgreen", isGrowthStageButton: true),
                ButtonTemplateEntry(name: "Powdery", color: "gray"),
                ButtonTemplateEntry(name: "Downy", color: "yellow"),
                ButtonTemplateEntry(name: "Blackberries", color: "red"),
            ]
        )
    }
}

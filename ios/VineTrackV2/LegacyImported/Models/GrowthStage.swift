import Foundation

nonisolated struct GrowthStage: Codable, Identifiable, Sendable, Hashable {
    let code: String
    let description: String
    var isEnabled: Bool

    var id: String { code }

    var displayName: String {
        "\(code) - \(description)"
    }

    var shortName: String {
        code
    }

    var imageName: String? {
        let hasImage: Set<String> = ["EL1","EL2","EL3","EL4","EL7","EL9","EL11","EL12","EL17","EL19","EL21","EL23","EL25","EL27","EL29","EL31","EL33","EL35","EL38","EL41","EL47"]
        return hasImage.contains(code) ? code : nil
    }

    /// E-L stage code treated as Budburst by the app. Recording a
    /// growth-stage pin with this code can auto-populate the block's
    /// `budburstDate` for Optimal Ripeness when none is set.
    static let budburstCode: String = "EL4"

    static let allStages: [GrowthStage] = [
        GrowthStage(code: "EL1", description: "Winter bud", isEnabled: true),
        GrowthStage(code: "EL2", description: "Bud scales opening", isEnabled: true),
        GrowthStage(code: "EL3", description: "Wooly Bud \u{00B1} green showing", isEnabled: true),
        GrowthStage(code: "EL4", description: "Budburst; leaf tips visible", isEnabled: true),
        GrowthStage(code: "EL7", description: "First leaf separated from shoot tip", isEnabled: true),
        GrowthStage(code: "EL9", description: "2 to 3 leaves separated; shoots 2-4 cm long", isEnabled: true),
        GrowthStage(code: "EL11", description: "4 leaves separated", isEnabled: true),
        GrowthStage(code: "EL12", description: "5 leaves separated; shoots about 10 cm long; inflorescence clear", isEnabled: true),
        GrowthStage(code: "EL13", description: "6 leaves separated", isEnabled: true),
        GrowthStage(code: "EL14", description: "7 leaves separated", isEnabled: true),
        GrowthStage(code: "EL15", description: "8 leaves separated, shoot elongating rapidly; single flowers in compact groups", isEnabled: true),
        GrowthStage(code: "EL16", description: "10 leaves separated", isEnabled: true),
        GrowthStage(code: "EL17", description: "12 leaves separated; inflorescence well developed, single flowers separated", isEnabled: true),
        GrowthStage(code: "EL18", description: "14 leaves separate and flower caps still in place, but cap colour fading from green", isEnabled: true),
        GrowthStage(code: "EL19", description: "About 16 leaves separated; beginning of flowering (first flower caps loosening)", isEnabled: true),
        GrowthStage(code: "EL20", description: "10% caps off", isEnabled: true),
        GrowthStage(code: "EL21", description: "30% caps off", isEnabled: true),
        GrowthStage(code: "EL23", description: "17-20 leaves separated; 50% caps off (= flowering)", isEnabled: true),
        GrowthStage(code: "EL25", description: "80% caps off", isEnabled: true),
        GrowthStage(code: "EL26", description: "Cap-fall complete", isEnabled: true),
        GrowthStage(code: "EL27", description: "Setting; young berries enlarging (>2 mm diam.), bunch at right angles to stem", isEnabled: true),
        GrowthStage(code: "EL29", description: "Berries pepper-corn size (4 mm diam.); bunches tending downwards", isEnabled: true),
        GrowthStage(code: "EL31", description: "Berries pea-size (7 mm diam.) (if bunches are tight)", isEnabled: true),
        GrowthStage(code: "EL32", description: "Beginning of bunch closure, berries touching (if bunches are tight)", isEnabled: true),
        GrowthStage(code: "EL33", description: "Berries still hard and green", isEnabled: true),
        GrowthStage(code: "EL34", description: "Berries begins to soft; Sugar starts increasing", isEnabled: true),
        GrowthStage(code: "EL35", description: "Berries begin to colour and enlarge", isEnabled: true),
        GrowthStage(code: "EL36", description: "Berries with intermediate sugar values", isEnabled: true),
        GrowthStage(code: "EL37", description: "Berries not quite ripe", isEnabled: true),
        GrowthStage(code: "EL38", description: "Berries harvest-ripe", isEnabled: true),
        GrowthStage(code: "EL39", description: "Berries over-ripe", isEnabled: true),
        GrowthStage(code: "EL41", description: "After harvest; cane maturation complete", isEnabled: true),
        GrowthStage(code: "EL43", description: "Begin of leaf fall", isEnabled: true),
        GrowthStage(code: "EL47", description: "End of leaf fall", isEnabled: true),
    ]
}

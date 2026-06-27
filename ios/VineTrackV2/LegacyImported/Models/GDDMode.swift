import Foundation

nonisolated enum GDDCalculationMode: String, Codable, Sendable, CaseIterable, Hashable {
    case gdd
    case bedd

    var displayName: String {
        switch self {
        case .gdd: "Standard GDD"
        case .bedd: "BEDD"
        }
    }

    var shortName: String {
        switch self {
        case .gdd: "GDD"
        case .bedd: "BEDD"
        }
    }

    var useBEDD: Bool { self == .bedd }
}

nonisolated enum GDDResetMode: String, Codable, Sendable, CaseIterable, Hashable {
    case seasonStart
    case budburst
    case flowering
    case veraison

    var displayName: String {
        switch self {
        case .seasonStart: "Season Start"
        case .budburst: "Budburst"
        case .flowering: "Flowering"
        case .veraison: "Veraison"
        }
    }

    var iconName: String {
        switch self {
        case .seasonStart: "calendar"
        case .budburst: "leaf.arrow.triangle.circlepath"
        case .flowering: "camera.macro"
        case .veraison: "circle.lefthalf.filled"
        }
    }
}

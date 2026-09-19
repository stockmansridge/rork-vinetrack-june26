import Foundation

/// The seeded Vintage Note type catalogue.
///
/// Mirrors the Android `VintageNoteCatalog.kt` exactly and the
/// `public.vintage_note_types` seed in SQL 236. All three must agree on code,
/// group, label and sort order.
///
/// ## Why the label is snapshotted onto each note
///
/// A note type is a living record: it can be renamed, re-sorted or retired. A
/// note is a historical claim about a season and must not change meaning
/// afterwards. So every saved note stores BOTH the type id (for grouping,
/// filtering and future reporting) and a snapshot of the label as it read on
/// the day it was written. Renaming "Frost" to "Frost event" updates the
/// dropdown for new notes and leaves the 2024 vintage saying exactly what the
/// observer chose.

/// A grouping heading in the note-type dropdown.
nonisolated enum VintageNoteGroup: String, CaseIterable, Identifiable, Sendable {
    case weather
    case phenology
    case disease
    case activity
    case other

    var id: String { rawValue }

    /// Stored `vintage_note_types.group_code`.
    var code: String { rawValue }

    /// Section heading shown in the picker.
    var label: String {
        switch self {
        case .weather: return "Weather and hazards"
        case .phenology: return "Phenology and crop development"
        case .disease: return "Disease and pest pressure"
        case .activity: return "Major vineyard activity"
        case .other: return "Other"
        }
    }

    /// Group ordering. Weather leads because it is what gets recorded most.
    var sortOrder: Int {
        switch self {
        case .weather: return 10
        case .phenology: return 20
        case .disease: return 30
        case .activity: return 40
        case .other: return 50
        }
    }

    static func byCode(_ code: String?) -> VintageNoteGroup? {
        guard let code else { return nil }
        return VintageNoteGroup(rawValue: code)
    }
}

/// One selectable note type.
nonisolated struct VintageNoteType: Identifiable, Equatable, Sendable {
    /// Database UUID. Codes are catalogue keys, never database identities.
    let databaseID: UUID?
    /// Stable stored code. Identity across platforms and renames.
    let code: String
    let group: VintageNoteGroup
    let label: String
    let sortOrder: Int
    /// True for a vineyard-authored type. Custom types are scoped to a single
    /// vineyard and never leak into another's dropdown.
    let isCustom: Bool
    /// Retired types stay readable on historical notes but are not offered for
    /// new ones — retiring is never a deletion.
    let isActive: Bool
    let vineyardID: UUID?
    let isSystem: Bool

    var id: String { databaseID?.uuidString ?? code }

    init(
        databaseID: UUID? = nil,
        code: String,
        group: VintageNoteGroup,
        label: String,
        sortOrder: Int,
        isCustom: Bool = false,
        isActive: Bool = true,
        vineyardID: UUID? = nil,
        isSystem: Bool = false
    ) {
        self.databaseID = databaseID
        self.code = code
        self.group = group
        self.label = label
        self.sortOrder = sortOrder
        self.isCustom = isCustom
        self.isActive = isActive
        self.vineyardID = vineyardID
        self.isSystem = isSystem
    }
}

nonisolated enum VintageNoteCatalog {

    /// Sentinel for the free-form entry at the end of the list.
    static let otherCustomCode = "other_custom"

    /// The seeded system types, in display order.
    ///
    /// Sort orders are spaced by 10 within each group so a later migration can
    /// insert a type between two existing ones without renumbering the rest —
    /// and therefore without a client and a server briefly disagreeing on order.
    static let systemTypes: [VintageNoteType] = {
        func make(_ group: VintageNoteGroup, _ code: String, _ label: String, _ order: Int) -> VintageNoteType {
            VintageNoteType(code: code, group: group, label: label, sortOrder: order, isSystem: true)
        }
        return [
            // Weather and hazards — the most commonly recorded events lead.
            make(.weather, "frost", "Frost", 10),
            make(.weather, "low_temperature", "Low temperature / cold spell", 20),
            make(.weather, "extended_dry", "Extended dry period", 30),
            make(.weather, "excessive_heat", "Excessive heat / heatwave", 40),
            make(.weather, "high_winds", "High winds", 50),
            make(.weather, "heavy_rain", "Heavy rain", 60),
            make(.weather, "extended_wet", "Extended wet period", 70),
            make(.weather, "flooding", "Flooding / waterlogging", 80),
            make(.weather, "hail", "Hail", 90),
            make(.weather, "smoke_exposure", "Smoke / bushfire exposure", 100),
            make(.weather, "high_humidity", "High humidity / persistent fog", 110),

            // Phenology and crop development.
            make(.phenology, "early_budburst", "Early budburst", 10),
            make(.phenology, "delayed_budburst", "Delayed budburst", 20),
            make(.phenology, "flowering_started", "Flowering started", 30),
            make(.phenology, "flowering_completed", "Flowering completed", 40),
            make(.phenology, "poor_fruit_set", "Poor or variable fruit set", 50),
            make(.phenology, "veraison_started", "Veraison started", 60),
            make(.phenology, "slow_ripening", "Slow or delayed ripening", 70),
            make(.phenology, "rapid_ripening", "Rapid or early ripening", 80),
            make(.phenology, "harvest_started", "Harvest started", 90),
            make(.phenology, "harvest_completed", "Harvest completed", 100),
            make(.phenology, "lower_yield", "Lower than expected yield", 110),
            make(.phenology, "higher_yield", "Higher than expected yield", 120),

            // Disease and pest pressure.
            make(.disease, "increased_disease_pressure", "Increased disease pressure", 10),
            make(.disease, "powdery_mildew", "Powdery mildew", 20),
            make(.disease, "downy_mildew", "Downy mildew", 30),
            make(.disease, "botrytis", "Botrytis", 40),
            make(.disease, "pest_bird_pressure", "Pest or bird pressure", 50),

            // Major vineyard activity.
            make(.activity, "pruning_started", "Pruning started", 10),
            make(.activity, "pruning_completed", "Pruning completed", 20),
            make(.activity, "shoot_thinning", "Shoot thinning", 30),
            make(.activity, "desuckering", "Desuckering", 40),
            make(.activity, "wire_lifting", "Wire lifting", 50),
            make(.activity, "leaf_plucking", "Leaf plucking", 60),
            make(.activity, "canopy_trimming", "Canopy trimming", 70),
            make(.activity, "fruit_thinning", "Fruit thinning", 80),
            make(.activity, "significant_irrigation", "Significant irrigation", 90),
            make(.activity, "cover_crop_activity", "Cover crop activity", 100),

            // Other.
            make(.other, otherCustomCode, "Other / custom event", 10),
        ]
    }()

    static func systemType(_ code: String?) -> VintageNoteType? {
        systemTypes.first { $0.code == code }
    }

    /// The picker's contents: seeded types plus this vineyard's custom types,
    /// grouped and ordered identically on both platforms.
    ///
    /// Retired types are excluded from NEW selection but remain resolvable by
    /// code for display of existing notes.
    static func selectable(customTypes: [VintageNoteType]) -> [VintageNoteType] {
        ((customTypes.contains { $0.isSystem } ? [] : systemTypes) + customTypes)
            .filter(\.isActive)
            .sorted { lhs, rhs in
                if lhs.group.sortOrder != rhs.group.sortOrder {
                    return lhs.group.sortOrder < rhs.group.sortOrder
                }
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.label < rhs.label
            }
    }

    /// Groups in display order, each with its selectable types.
    static func grouped(customTypes: [VintageNoteType]) -> [(group: VintageNoteGroup, types: [VintageNoteType])] {
        let all = selectable(customTypes: customTypes)
        return VintageNoteGroup.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { group in
                let types = all.filter { $0.group == group }
                return types.isEmpty ? nil : (group, types)
            }
    }

    /// Case-insensitive substring search over labels, preserving group order.
    /// A blank query returns everything rather than nothing.
    static func search(_ query: String, customTypes: [VintageNoteType]) -> [VintageNoteType] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return selectable(customTypes: customTypes) }
        return selectable(customTypes: customTypes).filter {
            $0.label.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

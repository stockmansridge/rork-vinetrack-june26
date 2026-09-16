import Foundation

/// The stable vocabulary shared by Scout and Vintage Notes.
///
/// Everything here is a CODE plus a LABEL, and the two are not interchangeable.
/// The code is what is stored, indexed, synced and reported on; the label is
/// what a person reads. A vineyard's scouting history outlives the wording used
/// to collect it, so a later decision to rename "Needs attention" must not
/// silently rewrite what was observed in a past season.
///
/// This file mirrors the Android `VineyardInsightsCatalog.kt` EXACTLY. Codes,
/// labels and ordering must stay identical across the two platforms: the same
/// vineyard is scouted from both, and a report that merges their rows cannot be
/// trusted if one platform stored `very_dry` where the other stored
/// `soil_very_dry`. Parity tests on both platforms assert the exact lists
/// below, so a divergence fails a build rather than a vintage.

/// A selectable option for one assessment item.
nonisolated struct ScoutOption: Identifiable, Equatable, Sendable {
    /// Stored value. Never a display string, never an ordinal.
    let code: String
    /// Exact user-facing wording. Snapshotted onto each saved observation.
    let label: String
    /// True when this selection describes something the operator would want to
    /// act on. Drives the Scout review's "needs attention" count ONLY.
    ///
    /// Round 1 deliberately stops there: this flag creates no Repair Pin and no
    /// Work Task. An automatic action raised from a dropdown nobody reviewed is
    /// how a vineyard ends up with a task list it does not trust, so the
    /// linkage fields exist in storage and stay null until that workflow is
    /// designed.
    let needsAttention: Bool

    var id: String { code }

    init(_ code: String, _ label: String, needsAttention: Bool = false) {
        self.code = code
        self.label = label
        self.needsAttention = needsAttention
    }
}

/// The assessment items captured per block, in display order.
///
/// `growthStage` is present as a first-class item because it is scouted like
/// the others, but it is emphatically NOT stored like the others: it writes
/// through the existing canonical Growth Stage pipeline. See
/// `ScoutGrowthStageLink`.
nonisolated enum ScoutItem: String, CaseIterable, Identifiable, Sendable {
    case growthStage = "growth_stage"
    case weeds
    case vineVigour = "vine_vigour"
    case soilMoisture = "soil_moisture"
    case powderyMildew = "powdery_mildew"
    case downyMildew = "downy_mildew"
    case otherIssue = "other_issue"
    case generalRecommendation = "general_recommendation"

    var id: String { rawValue }

    /// Stored `scout_observations.item_kind` value.
    var code: String { rawValue }

    /// Section heading in the block assessment form.
    var label: String {
        switch self {
        case .growthStage: return "E-L Growth Stage"
        case .weeds: return "Weeds"
        case .vineVigour: return "Vine vigour"
        case .soilMoisture: return "Soil moisture"
        case .powderyMildew: return "Powdery mildew"
        case .downyMildew: return "Downy mildew"
        case .otherIssue: return "Other issues"
        case .generalRecommendation: return "General recommendation"
        }
    }

    /// Free-text items carry notes and photos but no dropdown, so they are
    /// never counted as "not assessed" and never contribute an attention flag.
    var isFreeText: Bool { self == .otherIssue || self == .generalRecommendation }

    static func byCode(_ code: String?) -> ScoutItem? {
        guard let code else { return nil }
        return ScoutItem(rawValue: code)
    }
}

nonisolated enum VineyardInsightsCatalog {

    /// The stable Operational Tool id. Shared with Android and SQL 236.
    static let toolID = "vineyard_insights"
    static let toolTitle = "Vineyard Insights"
    static let toolSubtitle = "Scouting, vintage notes & reports"
    static let previewBadge = "System Admin Preview"

    /// The shared "no answer" code.
    ///
    /// Every dropdown defaults here and it is a real, stored answer meaning the
    /// operator did not assess this item — deliberately distinct from a null,
    /// which would be indistinguishable from a row that was never written. A
    /// report must be able to say "soil moisture was not assessed in Block 4"
    /// rather than quietly omitting the block.
    static let notAssessedCode = "not_assessed"
    static let notAssessedLabel = "Not assessed"

    private static let notAssessed = ScoutOption(notAssessedCode, notAssessedLabel)

    static let weeds: [ScoutOption] = [
        notAssessed,
        ScoutOption("under_control", "Under control"),
        ScoutOption("needs_attention", "Needs attention", needsAttention: true),
        ScoutOption("inhibiting_growth", "Inhibiting growth", needsAttention: true),
    ]

    static let vineVigour: [ScoutOption] = [
        notAssessed,
        ScoutOption("lacks_growth", "Lacks growth", needsAttention: true),
        ScoutOption("good_shoot_length", "Good shoot length"),
        ScoutOption("consider_trimming", "Consider trimming", needsAttention: true),
    ]

    static let soilMoisture: [ScoutOption] = [
        notAssessed,
        ScoutOption("adequate", "Adequate"),
        ScoutOption("low_soil_moisture", "Low soil moisture", needsAttention: true),
        ScoutOption("soil_very_dry", "Soil very dry", needsAttention: true),
        ScoutOption("vines_showing_stress", "Vines showing stress", needsAttention: true),
    ]

    static let powderyMildew: [ScoutOption] = [
        notAssessed,
        ScoutOption("no_sign", "No sign"),
        ScoutOption("growth_on_leaves", "Growth on leaves", needsAttention: true),
        ScoutOption("found_in_bunches", "Found in bunches", needsAttention: true),
    ]

    static let downyMildew: [ScoutOption] = [
        notAssessed,
        ScoutOption("no_sign", "No sign"),
        ScoutOption("primary_infection", "Primary infection", needsAttention: true),
        ScoutOption("on_leaves", "On leaves", needsAttention: true),
        ScoutOption("secondary_infection", "Secondary infection", needsAttention: true),
        ScoutOption("in_bunches", "In bunches", needsAttention: true),
    ]

    /// Options for a dropdown item; free-text items have none.
    static func options(for item: ScoutItem) -> [ScoutOption] {
        switch item {
        case .weeds: return weeds
        case .vineVigour: return vineVigour
        case .soilMoisture: return soilMoisture
        case .powderyMildew: return powderyMildew
        case .downyMildew: return downyMildew
        case .growthStage, .otherIssue, .generalRecommendation: return []
        }
    }

    static func option(for item: ScoutItem, code: String?) -> ScoutOption? {
        options(for: item).first { $0.code == code }
    }

    /// Label for a stored code, for display of a row saved by any platform or
    /// client version.
    ///
    /// A code this build does not recognise returns nil rather than an invented
    /// label — showing the raw stored code is honest, whereas guessing a label
    /// puts words in the operator's mouth.
    static func label(for item: ScoutItem, code: String?) -> String? {
        option(for: item, code: code)?.label
    }

    static func needsAttention(item: ScoutItem, code: String?) -> Bool {
        option(for: item, code: code)?.needsAttention == true
    }

    static func isAssessed(item: ScoutItem, code: String?) -> Bool {
        guard let code, code != notAssessedCode else { return false }
        return option(for: item, code: code) != nil
    }
}

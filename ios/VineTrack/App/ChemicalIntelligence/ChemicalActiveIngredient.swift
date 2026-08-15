import Foundation

/// The unit a label states an active's concentration in.
nonisolated enum ChemicalConcentrationUnit: String, Codable, Sendable, CaseIterable, Hashable {
    /// Grams of active per litre of product — liquid formulations.
    case gramsPerLitre = "g/L"
    /// Grams of active per kilogram of product — solid formulations.
    case gramsPerKilogram = "g/kg"
    /// Percent weight/weight.
    case percentWeightPerWeight = "% w/w"
    /// Percent weight/volume.
    case percentWeightPerVolume = "% w/v"
    /// Colony-forming units per gram — biological products.
    case colonyFormingUnitsPerGram = "CFU/g"

    nonisolated var label: String { rawValue }

    /// Tolerant reading of how labels and AI actually write these.
    static func parse(_ raw: String) -> ChemicalConcentrationUnit? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        switch v {
        case "g/l", "gl", "gpl", "gramsperlitre", "grams/litre": return .gramsPerLitre
        case "g/kg", "gkg", "gramsperkilogram", "grams/kg": return .gramsPerKilogram
        case "%w/w", "%ww", "percentw/w", "w/w": return .percentWeightPerWeight
        case "%w/v", "%wv", "percentw/v", "w/v": return .percentWeightPerVolume
        case "cfu/g", "cfug": return .colonyFormingUnitsPerGram
        case "%", "percent": return .percentWeightPerWeight
        default: return nil
        }
    }
}

/// One active constituent of a registered product.
///
/// This is the unit that carries an activity group. A product does NOT have a
/// group; each of its actives does. A two-active mixture therefore genuinely
/// belongs to two groups at once, which is exactly what resistance management
/// needs to know.
nonisolated struct ChemicalActiveIngredient: Codable, Sendable, Hashable, Identifiable {
    /// Stable identity for lists and diffing. Derived from the name so the
    /// same active reloads with the same id.
    nonisolated var id: String { name.lowercased() }

    /// The active's common (ISO) name, e.g. `"Tebuconazole"`.
    var name: String
    /// Concentration value as stated on the label, e.g. `200`.
    /// `nil` when the label concentration has not been established — never
    /// guessed, because a wrong concentration silently mis-doses.
    var concentration: Double?
    /// The unit the concentration is expressed in.
    var concentrationUnit: ChemicalConcentrationUnit?
    /// The resistance/activity group this active belongs to.
    /// `nil` = unknown, which is a legitimate and visible state.
    var activityGroup: ChemicalActivityGroup?
    /// Where the activity group specifically came from. Held per-active
    /// because a mixture can have one active confirmed against FRAC and
    /// another still only AI-suggested.
    var groupSource: ChemicalDataSourceKind?
    /// Where the identity/concentration came from.
    var identitySource: ChemicalDataSourceKind?

    init(
        name: String,
        concentration: Double? = nil,
        concentrationUnit: ChemicalConcentrationUnit? = nil,
        activityGroup: ChemicalActivityGroup? = nil,
        groupSource: ChemicalDataSourceKind? = nil,
        identitySource: ChemicalDataSourceKind? = nil
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.concentration = concentration
        self.concentrationUnit = concentrationUnit
        self.activityGroup = activityGroup
        self.groupSource = groupSource
        self.identitySource = identitySource
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case name, concentration
        case concentrationUnit = "concentration_unit"
        case activityGroup = "activity_group"
        case groupSource = "group_source"
        case identitySource = "identity_source"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try c.decodeIfPresent(String.self, forKey: .name) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        concentration = try c.decodeIfPresent(Double.self, forKey: .concentration)
        if let rawUnit = try c.decodeIfPresent(String.self, forKey: .concentrationUnit) {
            concentrationUnit = ChemicalConcentrationUnit(rawValue: rawUnit)
                ?? ChemicalConcentrationUnit.parse(rawUnit)
        } else {
            concentrationUnit = nil
        }
        activityGroup = try c.decodeIfPresent(ChemicalActivityGroup.self, forKey: .activityGroup)
        if let raw = try c.decodeIfPresent(String.self, forKey: .groupSource) {
            groupSource = ChemicalDataSourceKind(rawValue: raw) ?? .aiInterpretation
        } else {
            groupSource = nil
        }
        if let raw = try c.decodeIfPresent(String.self, forKey: .identitySource) {
            identitySource = ChemicalDataSourceKind(rawValue: raw) ?? .aiInterpretation
        } else {
            identitySource = nil
        }
    }

    /// `"Tebuconazole 200 g/L"`, or just the name when no concentration is known.
    nonisolated var displayLabel: String {
        guard let concentration, let concentrationUnit else { return name }
        return "\(name) \(ChemicalActiveIngredient.formatConcentration(concentration)) \(concentrationUnit.label)"
    }

    /// `"Tebuconazole 200 g/L — FRAC 3"`.
    nonisolated var displayLabelWithGroup: String {
        guard let activityGroup, activityGroup.isResistanceRelevant else { return displayLabel }
        return "\(displayLabel) — \(activityGroup.displayLabel)"
    }

    /// Whether this active is fully described for resistance purposes.
    nonisolated var isResistanceComplete: Bool {
        !name.isEmpty && (activityGroup?.isResistanceRelevant ?? false)
    }

    /// Whether the group came from a source strong enough to be called verified.
    nonisolated var hasAuthoritativeGroup: Bool {
        (groupSource?.isAuthoritative ?? false) && (activityGroup?.isResistanceRelevant ?? false)
    }

    /// Whether the label concentration is known.
    nonisolated var hasConcentration: Bool {
        concentration != nil && concentrationUnit != nil
    }

    static func formatConcentration(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1_000_000 {
            return String(Int(value))
        }
        return String(format: "%.4g", value)
    }
}

extension Array where Element == ChemicalActiveIngredient {
    /// Every activity group this product belongs to, de-duplicated and ordered.
    ///
    /// A Tebuconazole + Azoxystrobin product returns FRAC 3 AND FRAC 11 — the
    /// mixture counts as both, independently, which is precisely what
    /// `"3 + 11"` as a single string could never express.
    var activityGroups: [ChemicalActivityGroup] {
        compactMap(\.activityGroup).canonicalised
    }

    /// Actives whose group is still unknown. Non-empty here means the product
    /// can never be Verified.
    var missingGroups: [ChemicalActiveIngredient] {
        filter { !($0.activityGroup?.isResistanceRelevant ?? false) }
    }

    /// Actives whose group came only from a non-authoritative source.
    var unconfirmedGroups: [ChemicalActiveIngredient] {
        filter { ($0.activityGroup?.isResistanceRelevant ?? false) && !$0.hasAuthoritativeGroup }
    }

    /// `"Tebuconazole 200 g/L + Azoxystrobin 120 g/L"` — the legacy
    /// `active_ingredient` display projection, derived FROM the structured
    /// actives. Output only; nothing may parse it back.
    var legacyActiveIngredientProjection: String {
        map(\.displayLabel).joined(separator: " + ")
    }
}

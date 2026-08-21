import Foundation

/// The basis a registered LABEL quotes a product rate against.
///
/// This is emphatically NOT the spray carrier volume basis. An NZ vineyard
/// measuring carrier in L/100 m still applies a product whose label says
/// "1.5 L/ha" — the label basis belongs to the product, the carrier basis
/// belongs to the pass. Conflating them would silently re-rate the product.
///
/// See `SprayProductRateBasis` for the spray-side concept this informs.
nonisolated enum ChemicalLabelRateBasis: String, Codable, Sendable, CaseIterable, Hashable {
    /// A single rate per 100 litres of spray mixture, e.g. `100 mL/100 L`.
    case per100Litres = "per_100_litres"
    /// A single rate per hectare, e.g. `1.5 L/ha`.
    case perHectare = "per_hectare"
    /// A min–max band per 100 litres, e.g. `80–120 mL/100 L`.
    case rangePer100Litres = "range_per_100_litres"
    /// A min–max band per hectare, e.g. `1.0–2.0 L/ha`.
    case rangePerHectare = "range_per_hectare"
    /// Anything the label expresses differently (per vine, per metre of row,
    /// per tonne). Captured verbatim rather than forced into a shape it does
    /// not fit.
    case other

    nonisolated var label: String {
        switch self {
        case .per100Litres: return "Per 100 L"
        case .perHectare: return "Per hectare"
        case .rangePer100Litres: return "Range per 100 L"
        case .rangePerHectare: return "Range per hectare"
        case .other: return "Other"
        }
    }

    nonisolated var suffix: String {
        switch self {
        case .per100Litres, .rangePer100Litres: return "/100 L"
        case .perHectare, .rangePerHectare: return "/ha"
        case .other: return ""
        }
    }

    /// Whether this basis is quoted against spray mixture volume.
    nonisolated var isVolumeBased: Bool {
        self == .per100Litres || self == .rangePer100Litres
    }

    /// Whether this basis is quoted against ground area.
    nonisolated var isAreaBased: Bool {
        self == .perHectare || self == .rangePerHectare
    }

    /// The spray-workflow product bases this label basis can legitimately be
    /// applied through.
    ///
    /// This is the Phase 9 hand-off: Chemical Intelligence tells the Guided
    /// Spray workflow which choices to OFFER, so the operator picks from what
    /// the label actually supports instead of guessing.
    ///
    /// - A per-100 L label maps to exactly one option, so the workflow shows
    ///   no picker at all.
    /// - An area label maps to whole-block or treated-area, which is precisely
    ///   the ambiguity the banded-spray picker exists to resolve.
    nonisolated var compatibleProductRateBases: [SprayProductRateBasis] {
        switch self {
        case .per100Litres, .rangePer100Litres:
            return [.per100Litres]
        case .perHectare, .rangePerHectare:
            return [.wholeBlockArea, .treatedArea]
        case .other:
            return []
        }
    }
}

/// One rate option from a registered label.
nonisolated struct ChemicalLabelRate: Codable, Sendable, Hashable, Identifiable {
    nonisolated var id: String { "\(basis.rawValue)|\(label)|\(minValue ?? value ?? 0)" }

    /// What the label calls this rate, e.g. `"Low disease pressure"`.
    var label: String
    var basis: ChemicalLabelRateBasis
    /// A single rate value, for the non-range bases.
    var value: Double?
    /// Range lower bound, for the range bases.
    var minValue: Double?
    /// Range upper bound, for the range bases.
    var maxValue: Double?
    /// The unit the rate is quoted in, e.g. `"L"`, `"mL"`, `"kg"`, `"g"`.
    var unit: String
    /// Verbatim label text when `basis == .other`, so an unusual basis is
    /// preserved rather than discarded.
    var rawText: String?

    init(
        label: String = "",
        basis: ChemicalLabelRateBasis,
        value: Double? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        unit: String = "",
        rawText: String? = nil
    ) {
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.basis = basis
        self.value = value
        self.minValue = minValue
        self.maxValue = maxValue
        self.unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawText = (raw?.isEmpty ?? true) ? nil : raw
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case label, basis, value, unit
        case minValue = "min_value"
        case maxValue = "max_value"
        case rawText = "raw_text"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        let raw = try c.decodeIfPresent(String.self, forKey: .basis) ?? ""
        basis = ChemicalLabelRateBasis(rawValue: raw) ?? .other
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        minValue = try c.decodeIfPresent(Double.self, forKey: .minValue)
        maxValue = try c.decodeIfPresent(Double.self, forKey: .maxValue)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
    }

    /// `"1.5 L/ha"` or `"1.0–2.0 L/ha"`.
    nonisolated var displayRate: String {
        let number: String
        if let minValue, let maxValue {
            number = "\(Self.format(minValue))–\(Self.format(maxValue))"
        } else if let value {
            number = Self.format(value)
        } else if let rawText {
            return rawText
        } else {
            return "Rate not established"
        }
        return "\(number) \(unit)\(basis.suffix)".trimmingCharacters(in: .whitespaces)
    }

    /// The value a calculation should start from: a range proposes its LOW
    /// end, never its high end, so an automatic suggestion can never inflate
    /// a dose on the operator's behalf.
    nonisolated var proposedValue: Double? {
        if let value { return value }
        return minValue
    }

    private static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1_000_000 { return String(Int(v)) }
        return String(format: "%.4g", v)
    }
}

/// A registered use: which crop, which target, at which rates.
///
/// Structured as crop + target + rate because "Group 11 therefore powdery" is
/// not a registered use — it is an assumption. The future Resistance Engine
/// needs to evaluate chemistry against the disease actually being targeted,
/// and that mapping only exists on the label.
nonisolated struct ChemicalRegisteredUse: Codable, Sendable, Hashable, Identifiable {
    nonisolated var id: String { "\(crop)|\(targetRaw)" }

    /// The crop the use is registered for, e.g. `"Grapes"`. Kept as label text
    /// because registrations distinguish winegrapes from tablegrapes.
    var crop: String
    /// The target as the label words it, e.g. `"Powdery mildew"`.
    var targetRaw: String
    /// The target mapped onto VineTrack's typed spray vocabulary, when it maps
    /// cleanly. `nil` means the label named something VineTrack has no target
    /// for — recorded, not discarded, and never force-fitted.
    var target: SprayTarget?
    /// Rates registered for this use.
    var rates: [ChemicalLabelRate]
    /// Withholding period in days, where the label states one.
    var withholdingPeriodDays: Int?
    /// Re-entry interval in hours, where the label states one.
    var reEntryPeriodHours: Int?
    /// Any label restriction text worth surfacing verbatim.
    var restrictions: String?
    /// Per-fact evidence tiers recorded by the server's label merge, keyed by
    /// fact name (`claim`, `rates`, `withholding_period`, `re_entry`,
    /// `restrictions`) with tier values such as `manufacturer_label` or
    /// `ai_interpretation`. Stored VERBATIM: never derived from this record's
    /// values, never rewritten on device, and `nil` on records saved before
    /// the server published provenance — absence means "unknown", never
    /// "authoritative".
    var provenance: [String: String]?

    init(
        crop: String,
        targetRaw: String,
        target: SprayTarget? = nil,
        rates: [ChemicalLabelRate] = [],
        withholdingPeriodDays: Int? = nil,
        reEntryPeriodHours: Int? = nil,
        restrictions: String? = nil,
        provenance: [String: String]? = nil
    ) {
        self.crop = crop.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetRaw = targetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.target = target ?? ChemicalRegisteredUse.mapTarget(targetRaw)
        self.rates = rates
        self.withholdingPeriodDays = withholdingPeriodDays
        self.reEntryPeriodHours = reEntryPeriodHours
        let r = restrictions?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.restrictions = (r?.isEmpty ?? true) ? nil : r
        self.provenance = provenance
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case crop, target, rates, restrictions, provenance
        case targetRaw = "target_raw"
        case withholdingPeriodDays = "withholding_period_days"
        case reEntryPeriodHours = "re_entry_period_hours"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crop = try c.decodeIfPresent(String.self, forKey: .crop) ?? ""
        targetRaw = try c.decodeIfPresent(String.self, forKey: .targetRaw) ?? ""
        if let raw = try c.decodeIfPresent(String.self, forKey: .target) {
            target = SprayTarget(rawValue: raw) ?? ChemicalRegisteredUse.mapTarget(targetRaw)
        } else {
            target = ChemicalRegisteredUse.mapTarget(targetRaw)
        }
        rates = try c.decodeIfPresent([ChemicalLabelRate].self, forKey: .rates) ?? []
        withholdingPeriodDays = try c.decodeIfPresent(Int.self, forKey: .withholdingPeriodDays)
        reEntryPeriodHours = try c.decodeIfPresent(Int.self, forKey: .reEntryPeriodHours)
        restrictions = try c.decodeIfPresent(String.self, forKey: .restrictions)
        // Additive and tolerant: a malformed or missing provenance map reads
        // as nil so the use itself always loads; the value is never guessed.
        provenance = try? c.decodeIfPresent([String: String].self, forKey: .provenance)
    }

    /// Whether this use concerns grapevines.
    nonisolated var isViticultural: Bool {
        let c = crop.lowercased()
        return c.contains("grape") || c.contains("vine")
    }

    /// Conservative mapping from label wording onto VineTrack's typed targets.
    ///
    /// Only maps when the wording is unambiguous. Anything else stays `nil`
    /// rather than being guessed — a wrong target would tell the future
    /// Resistance Engine the wrong disease was being managed.
    static func mapTarget(_ raw: String) -> SprayTarget? {
        let v = raw.lowercased()
        if v.contains("powdery") || v.contains("uncinula") || v.contains("erysiphe") {
            return .powderyMildew
        }
        if v.contains("downy") || v.contains("plasmopara") { return .downyMildew }
        if v.contains("botrytis") || v.contains("bunch rot") { return .botrytis }
        if v.contains("weed") || v.contains("grass") && v.contains("control") { return .weeds }
        return nil
    }
}

extension Array where Element == ChemicalRegisteredUse {
    /// Uses registered on grapevines.
    var viticultural: [ChemicalRegisteredUse] { filter(\.isViticultural) }

    /// Every distinct label rate basis across all uses.
    var rateBases: [ChemicalLabelRateBasis] {
        var seen = Set<String>()
        var out: [ChemicalLabelRateBasis] = []
        for use in self {
            for rate in use.rates where seen.insert(rate.basis.rawValue).inserted {
                out.append(rate.basis)
            }
        }
        return out
    }

    /// Typed targets this product is actually registered against on grapes.
    var viticulturalTargets: [SprayTarget] {
        var seen = Set<String>()
        return viticultural.compactMap(\.target).filter { seen.insert($0.rawValue).inserted }
    }
}

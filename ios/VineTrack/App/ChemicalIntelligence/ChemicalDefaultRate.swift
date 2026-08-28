import Foundation

/// The two bases a grower can actually hold a default rate on.
///
/// Deliberately NOT `ChemicalLabelRateBasis`: that enum distinguishes a single
/// value from a range, which is a fact about the LABEL's wording. A default is
/// a decision about how this vineyard doses, and `2 L/100 L` and
/// `1.5–2 L/100 L` are two answers to the same question. `basis: .other` has no
/// case here at all — verbatim wording is a faithful record and not a rate a
/// calculation may run on, so it can never become a default.
nonisolated enum ChemicalDefaultRateBasis: String, Sendable, Hashable, CaseIterable {
    case per100Litres = "per_100_litres"
    case perHectare = "per_hectare"

    nonisolated var label: String {
        switch self {
        case .per100Litres: return "Per 100 L"
        case .perHectare: return "Per hectare"
        }
    }

    /// The wording shown when the label registers no rate on this basis.
    ///
    /// Exact, and deliberately about THIS LABEL rather than about VineTrack.
    /// "No rate found" reads as a lookup failure the operator might retry; the
    /// truth is that the document states none, and inventing one by converting
    /// from the other basis would need a carrier volume the label never gave.
    nonisolated var noRegisteredRateStatement: String {
        switch self {
        case .per100Litres: return "No registered per-100 L rate on this label"
        case .perHectare: return "No registered per-hectare rate on this label"
        }
    }

    /// The decision basis a label basis belongs to, or `nil` when it is not a
    /// rate a default can be held on.
    static func of(_ basis: ChemicalLabelRateBasis) -> ChemicalDefaultRateBasis? {
        switch basis {
        case .per100Litres, .rangePer100Litres: return .per100Litres
        case .perHectare, .rangePerHectare: return .perHectare
        case .other: return nil
        }
    }
}

/// One use+rate pairing that a default option was built from.
///
/// Kept so an option can always say WHICH registered uses stand behind it.
/// Collapsing several conditions into one option is only defensible while the
/// conditions themselves remain inspectable.
nonisolated struct ChemicalDefaultRateCondition: Sendable, Hashable, Identifiable {
    /// The crop the use registers, e.g. `"GRAPEVINES"`.
    let crop: String
    /// The target as the label words it, e.g. `"Grapevine scale"`.
    let targetRaw: String
    /// The condition the label attaches to this rate — on an Australian label
    /// this is usually the STATE column, e.g. `"NSW, Vic, SA"`.
    let conditionText: String
    /// The verbatim label wording the rate was read from, where the server
    /// supplied it.
    let rawText: String?
    /// Jurisdictions named by the condition. EMPTY means unrestricted.
    let jurisdictions: [ChemicalRateJurisdiction]

    nonisolated var id: String {
        [crop, targetRaw, conditionText, rawText ?? "-"].joined(separator: "|")
    }

    /// A single readable line: `"Grapevine scale — NSW, Vic, Qld, SA, WA"`.
    nonisolated var summary: String {
        let target = targetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let condition = conditionText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (target.isEmpty, condition.isEmpty) {
        case (false, false): return "\(target) — \(condition)"
        case (false, true): return target
        case (true, false): return condition
        case (true, true): return crop.isEmpty ? "Registered use" : crop
        }
    }

    /// Whether this condition permits use in the given jurisdiction.
    ///
    /// A condition naming no state permits every state: it is not restricted,
    /// and treating silence as exclusion would hide most of a label.
    nonisolated func applies(in jurisdiction: ChemicalRateJurisdiction?) -> Bool {
        guard !jurisdictions.isEmpty else { return true }
        guard let jurisdiction else { return true }
        return jurisdictions.contains(jurisdiction)
    }
}

/// One rate the operator may adopt as their default.
///
/// # What is and is not merged
///
/// Two registered rows quoting the SAME number on the SAME basis in the SAME
/// unit are one choice, however many conditions produced them — a VICOL label
/// stating `3 L/100 L` for European red mite in NSW/Vic/SA and `3 L/100 L` for
/// grapevine scale in NSW/Vic/Qld/SA/WA offers a grower exactly one number to
/// pour. Both conditions ride along in `conditions`, so nothing is lost and
/// the row can still be inspected.
///
/// What is NEVER merged is two DIFFERENT numbers. `2 L/100 L` and `3 L/100 L`
/// stay two options. They are not flattened into `2–3 L/100 L`: a range is
/// something a label states, not something a client derives, and a synthesised
/// band would authorise every dose between two numbers the label authorised
/// only at its ends, under conditions it named precisely.
nonisolated struct ChemicalDefaultRateOption: Sendable, Hashable, Identifiable {
    /// Content-addressed: basis, unit and the value(s). Deliberately excludes
    /// the condition, because the condition is what this type merges on.
    let id: String
    /// The rate itself, exactly as the label states it — value OR an ordered
    /// min/max pair, never both, never converted.
    let rate: ChemicalLabelRate
    /// Every registered use+condition that states this rate.
    let conditions: [ChemicalDefaultRateCondition]

    /// `"3 L/100 L"`, or `"100–200 mL/100 L"` for a true label range.
    nonisolated var displayRate: String { rate.displayRate }

    /// True when the label itself states this rate as a band.
    nonisolated var isLabelRange: Bool {
        rate.minValue != nil && rate.maxValue != nil
    }

    /// The inclusive bounds this option authorises, in the rate's own unit.
    ///
    /// A single-value rate authorises exactly one number, so its bounds are
    /// that number twice. A label range authorises everything between its
    /// printed ends. `nil` when the rate states no usable number at all.
    nonisolated var authorisedBounds: (min: Double, max: Double)? {
        if let minValue = rate.minValue, let maxValue = rate.maxValue {
            return minValue <= maxValue ? (minValue, maxValue) : (maxValue, minValue)
        }
        if let value = rate.value { return (value, value) }
        return nil
    }

    /// Whether `value` is a dose this registered rate actually authorises.
    ///
    /// Inclusive of both ends: a label printing `100–200 g/100 L` registers
    /// 100 and 200 as much as it registers 150. The comparison carries a small
    /// tolerance so a number the operator typed back in — and that made a
    /// round trip through text — still matches its own bound.
    nonisolated func authorises(_ value: Double) -> Bool {
        guard let bounds = authorisedBounds else { return false }
        let tolerance = 0.000_001
        return value >= bounds.min - tolerance && value <= bounds.max + tolerance
    }

    /// The dose this option starts from when the operator has named none.
    ///
    /// A range starts at its LOWER bound: defaulting to the top of a band
    /// would over-apply every product whose operator never opened the row.
    nonisolated var startingValue: Double? { rate.value ?? rate.minValue }

    /// Every jurisdiction any of this option's conditions names.
    nonisolated var jurisdictions: [ChemicalRateJurisdiction] {
        var seen = Set<ChemicalRateJurisdiction>()
        for condition in conditions {
            for jurisdiction in condition.jurisdictions { seen.insert(jurisdiction) }
        }
        return ChemicalRateJurisdiction.allCases.filter(seen.contains)
    }

    /// True when no condition restricts this rate to a state.
    nonisolated var isUnrestricted: Bool {
        conditions.contains { $0.jurisdictions.isEmpty } || conditions.isEmpty
    }

    /// Whether this option is registered for use in the given jurisdiction.
    nonisolated func applies(in jurisdiction: ChemicalRateJurisdiction?) -> Bool {
        guard let jurisdiction else { return true }
        if conditions.isEmpty { return true }
        return conditions.contains { $0.applies(in: jurisdiction) }
    }
}

/// Why an option is being recommended — or why none is.
nonisolated enum ChemicalDefaultRateRecommendation: Sendable, Hashable {
    /// The label registers no rate at all on this basis.
    case noRegisteredRate
    /// Exactly one distinct rate applies in the vineyard's own jurisdiction.
    case jurisdiction(ChemicalRateJurisdiction)
    /// Exactly one distinct rate exists on this basis, full stop.
    case onlyRegisteredRate
    /// Several apply and only the operator can choose between them.
    case operatorMustChoose

    /// The badge shown beside the recommended option, or `nil` when there is
    /// nothing to recommend.
    nonisolated var badge: String? {
        switch self {
        case .jurisdiction(let jurisdiction):
            return "Recommended for \(jurisdiction.displayName)"
        case .onlyRegisteredRate:
            return "Recommended"
        case .noRegisteredRate, .operatorMustChoose:
            return nil
        }
    }
}

/// The decision to be taken for ONE basis.
nonisolated struct ChemicalDefaultRateGroup: Sendable, Hashable {
    let basis: ChemicalDefaultRateBasis
    /// Every distinct registered rate on this basis, in label order.
    let options: [ChemicalDefaultRateOption]
    let recommendation: ChemicalDefaultRateRecommendation
    /// The option the recommendation points at, when it points at one.
    let recommendedOptionId: String?

    /// True when the operator must pick before this basis has a default.
    nonisolated var requiresChoice: Bool {
        if case .operatorMustChoose = recommendation { return true }
        return false
    }

    /// True when the label states nothing on this basis.
    nonisolated var isEmpty: Bool { options.isEmpty }

    /// The wording to show when there is nothing to choose from.
    nonisolated var emptyStatement: String { basis.noRegisteredRateStatement }

    nonisolated var recommendedOption: ChemicalDefaultRateOption? {
        guard let recommendedOptionId else { return nil }
        return options.first { $0.id == recommendedOptionId }
    }
}

/// The whole default-rate decision for a product, per basis.
nonisolated struct ChemicalDefaultRatePlan: Sendable, Hashable {
    let per100Litres: ChemicalDefaultRateGroup
    let perHectare: ChemicalDefaultRateGroup
    /// The jurisdiction the recommendation was computed against, if any.
    let jurisdiction: ChemicalRateJurisdiction?

    nonisolated var groups: [ChemicalDefaultRateGroup] { [per100Litres, perHectare] }

    nonisolated func group(_ basis: ChemicalDefaultRateBasis) -> ChemicalDefaultRateGroup {
        switch basis {
        case .per100Litres: return per100Litres
        case .perHectare: return perHectare
        }
    }

    /// True when at least one basis still needs the operator to decide.
    nonisolated var requiresChoice: Bool { groups.contains(where: \.requiresChoice) }
}

/// Builds the default-rate decision from authoritative grapevine rates.
///
/// # The rule, and why each step exists
///
/// ```text
/// 1. vineyard jurisdiction known AND exactly one distinct rate applies there
///        → recommend it, badged with the state
/// 2. otherwise exactly one distinct grapevine rate on this basis
///        → recommend it
/// 3. otherwise
///        → no automatic default; the operator chooses
/// ```
///
/// Step 1 comes first because a state-conditioned label is answering a
/// narrower question than the label as a whole: a Tasmanian rate is not a
/// candidate for a NSW vineyard at all, so counting it towards "how many
/// choices are there?" would manufacture an ambiguity the grower does not
/// have. Step 3 is a refusal, and refusing is the point — silently adopting
/// the first of several conditional rates applies a dose the label authorised
/// only under a condition nobody checked.
///
/// # What it will never do
///
/// * Convert between bases. A `/100 L`-only label has no hectare rate, and
///   the hectare group says exactly that.
/// * Split a label's own range into two defaults. `100–200 mL/100 L` is ONE
///   registered rate with both bounds preserved.
/// * Recommend a rate outside the vineyard's jurisdiction, at any step.
/// * Read a non-grapevine rate. Other crops are retained on the record and are
///   never candidates for a vineyard's default.
nonisolated enum ChemicalDefaultRate {

    /// Build the plan from GRAPEVINE uses only.
    ///
    /// - Parameters:
    ///   - grapevineUses: the authoritative grapevine registered uses. Callers
    ///     must pass the grapevine partition; passing the whole label would
    ///     offer a pome-fruit rate as a vineyard default.
    ///   - jurisdiction: the vineyard's state, when it is known. `nil` skips
    ///     step 1 — which is a weaker answer, never a wrong one.
    static func plan(
        grapevineUses: [ChemicalRegisteredUse],
        jurisdiction: ChemicalRateJurisdiction? = nil
    ) -> ChemicalDefaultRatePlan {
        ChemicalDefaultRatePlan(
            per100Litres: group(.per100Litres, from: grapevineUses, jurisdiction: jurisdiction),
            perHectare: group(.perHectare, from: grapevineUses, jurisdiction: jurisdiction),
            jurisdiction: jurisdiction
        )
    }

    /// Every distinct rate on one basis, with its conditions attached.
    static func options(
        _ basis: ChemicalDefaultRateBasis,
        from grapevineUses: [ChemicalRegisteredUse]
    ) -> [ChemicalDefaultRateOption] {
        // Insertion-ordered accumulation: the label's own order is the order a
        // grower reads, and re-sorting by value would silently re-rank the
        // register's presentation.
        var order: [String] = []
        var rates: [String: ChemicalLabelRate] = [:]
        var conditions: [String: [ChemicalDefaultRateCondition]] = [:]

        for use in grapevineUses {
            for rate in use.rates {
                guard ChemicalDefaultRateBasis.of(rate.basis) == basis else { continue }
                // Only a rate a calculation can run on may become a default.
                guard ChemicalSaveContract.isUsable(rate) else { continue }

                let key = distinctnessKey(rate)
                if rates[key] == nil {
                    order.append(key)
                    rates[key] = rate
                }
                let conditionText = conditionText(for: rate)
                let condition = ChemicalDefaultRateCondition(
                    crop: use.crop,
                    targetRaw: use.targetRaw,
                    conditionText: conditionText,
                    rawText: rate.rawText,
                    jurisdictions: ChemicalRateJurisdiction.mentioned(
                        in: [conditionText, rate.rawText ?? ""].joined(separator: " ")
                    )
                )
                var bucket = conditions[key] ?? []
                if !bucket.contains(condition) { bucket.append(condition) }
                conditions[key] = bucket
            }
        }

        return order.compactMap { key in
            guard let rate = rates[key] else { return nil }
            return ChemicalDefaultRateOption(
                id: key,
                rate: rate,
                conditions: conditions[key] ?? []
            )
        }
    }

    private static func group(
        _ basis: ChemicalDefaultRateBasis,
        from grapevineUses: [ChemicalRegisteredUse],
        jurisdiction: ChemicalRateJurisdiction?
    ) -> ChemicalDefaultRateGroup {
        let all = options(basis, from: grapevineUses)

        guard !all.isEmpty else {
            return ChemicalDefaultRateGroup(
                basis: basis,
                options: [],
                recommendation: .noRegisteredRate,
                recommendedOptionId: nil
            )
        }

        // Step 1 — the vineyard's own jurisdiction narrows the field.
        if let jurisdiction {
            let applicable = all.filter { $0.applies(in: jurisdiction) }
            if applicable.count == 1, let only = applicable.first {
                return ChemicalDefaultRateGroup(
                    basis: basis,
                    options: all,
                    recommendation: .jurisdiction(jurisdiction),
                    recommendedOptionId: only.id
                )
            }
            // Several apply here, or none does. Either way this vineyard has
            // no single answer, and step 2 must not resurrect one from rates
            // that are registered for somewhere else.
            if applicable.count > 1 {
                return ChemicalDefaultRateGroup(
                    basis: basis,
                    options: all,
                    recommendation: .operatorMustChoose,
                    recommendedOptionId: nil
                )
            }
            if applicable.isEmpty {
                return ChemicalDefaultRateGroup(
                    basis: basis,
                    options: all,
                    recommendation: .operatorMustChoose,
                    recommendedOptionId: nil
                )
            }
        }

        // Step 2 — one distinct rate on this basis, jurisdiction unknown.
        if all.count == 1, let only = all.first {
            return ChemicalDefaultRateGroup(
                basis: basis,
                options: all,
                recommendation: .onlyRegisteredRate,
                recommendedOptionId: only.id
            )
        }

        // Step 3 — the operator decides.
        return ChemicalDefaultRateGroup(
            basis: basis,
            options: all,
            recommendation: .operatorMustChoose,
            recommendedOptionId: nil
        )
    }

    /// What makes two registered rates the SAME choice.
    ///
    /// Basis, unit and the number(s). Never the condition — merging on the
    /// condition is this type's whole purpose — and never the use, because a
    /// grower pouring `3 L/100 L` pours the same thing whichever registered
    /// pest they are treating.
    static func distinctnessKey(_ rate: ChemicalLabelRate) -> String {
        [
            ChemicalDefaultRateBasis.of(rate.basis)?.rawValue ?? "other",
            rate.unit.lowercased(),
            rate.value.map(number) ?? "-",
            rate.minValue.map(number) ?? "-",
            rate.maxValue.map(number) ?? "-",
        ].joined(separator: "|")
    }

    /// The condition wording for a rate: the label's own condition, falling
    /// back to the verbatim row when the parser bound no separate condition.
    static func conditionText(for rate: ChemicalLabelRate) -> String {
        let label = rate.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { return label }
        return (rate.rawText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6g", value)
    }
}

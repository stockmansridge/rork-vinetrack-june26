import Foundation

/// The resistance classification state of an active, or of a product (task §10).
///
/// Three conditions that a blank cannot tell apart, and that the Resistance
/// Planner must never conflate:
///
/// ```text
/// classified      FRAC 3 / IRAC 4A / HRAC G — a code the Planner can rotate on
/// notApplicable   the product HAS no resistance group by design
/// unresolved      nobody has established it yet, or the lookup failed
/// ```
///
/// The wire values match `sql/210`'s CHECK constraint exactly.
nonisolated enum ChemicalResistanceState: String, Codable, Sendable, CaseIterable, Hashable {
    case classified
    case notApplicable = "not_applicable"
    case unresolved

    nonisolated var label: String {
        switch self {
        case .classified: return "Classified"
        case .notApplicable: return "Not applicable"
        case .unresolved: return "Not established"
        }
    }

    /// The state of ONE active ingredient.
    ///
    /// A missing group is `unresolved`, never `notApplicable`. Absence is not
    /// an assertion: an unclassified fungicide silently marked group-free
    /// would be excluded from every resistance warning it should raise. Only
    /// an explicit `notApplicable` scheme — something somebody or an
    /// authoritative pass actually stated — produces that answer.
    static func of(_ active: ChemicalActiveIngredient) -> ChemicalResistanceState {
        guard let group = active.activityGroup else { return .unresolved }
        if group.scheme == .notApplicable { return .notApplicable }
        // A scheme with no code is half a record, not knowledge.
        return group.code.isEmpty ? .unresolved : .classified
    }

    /// The product-level rollup, mirroring the `sql/210` backfill exactly.
    ///
    /// * No actives at all → `unresolved`. Every pre-sql/194 record is here.
    /// * Any active still unknown → `unresolved`. A half-classified mixture
    ///   must not report as classified: that would tell the Planner it knows
    ///   the whole chemistry when it knows half of it.
    /// * Every active explicitly group-free → `notApplicable`.
    /// * Otherwise → `classified`. A classified fungicide plus an explicitly
    ///   group-free wetter is classified; the wetter has nothing to add.
    static func rollup(_ actives: [ChemicalActiveIngredient]) -> ChemicalResistanceState {
        guard !actives.isEmpty else { return .unresolved }
        let states = actives.map(of)
        if states.contains(.unresolved) { return .unresolved }
        if states.allSatisfy({ $0 == .notApplicable }) { return .notApplicable }
        return .classified
    }
}

/// Every way a chemical can fail the mandatory save contract.
nonisolated enum ChemicalSaveViolationCode: String, Sendable, Hashable, CaseIterable {
    case productNameMissing = "product_name_missing"
    case productCategoryMissing = "product_category_missing"
    case activeIngredientNameMissing = "active_ingredient_name_missing"
    case grapevineUseMissing = "grapevine_use_missing"
    case usableRateMissing = "usable_rate_missing"
    case rateUnitMissing = "rate_unit_missing"
    case rateBasisUnrecognised = "rate_basis_unrecognised"
    case rateValueInvalid = "rate_value_invalid"
    case rateRangeInverted = "rate_range_inverted"
    case resistanceStateMissing = "resistance_state_missing"
    case registrationIdentityMissing = "registration_identity_missing"
    case officialLabelMissing = "official_label_missing"
}

/// One unmet requirement, phrased as the next action.
nonisolated struct ChemicalSaveViolation: Sendable, Hashable, Identifiable {
    let code: ChemicalSaveViolationCode
    /// Operator-facing sentence. Says what to DO, not what is wrong.
    let message: String
    /// Which part of the form the operator must go to.
    let field: String

    nonisolated var id: String { "\(code.rawValue)|\(field)" }
}

/// How complete the record has to be.
nonisolated enum ChemicalSaveIntent: String, Sendable, Hashable {
    /// Going into the Chemical Store for use in spray work.
    case sprayReady = "spray_ready"
    /// Additionally claiming registered identity.
    case verified
}

nonisolated struct ChemicalSaveEvaluation: Sendable, Hashable {
    let violations: [ChemicalSaveViolation]
    /// The state that will be persisted to `resistance_classification_state`
    /// once sql/210 lands. Derived here so the value the form shows and the
    /// value the record stores can never disagree.
    let resistanceState: ChemicalResistanceState
    /// True when at least one grapevine use carries a calculable rate.
    let hasUsableViticulturalRate: Bool
    /// True when every usable grapevine rate has an unproven condition, so a
    /// calculation must ask the operator which one applies.
    let requiresRateConditionChoice: Bool

    nonisolated var isSatisfied: Bool { violations.isEmpty }

    /// The first thing the operator should fix, for a one-line summary.
    nonisolated var primaryMessage: String? { violations.first?.message }
}

/// The mandatory contract for saving a chemical into the Chemical Store.
///
/// # Why this is not a button rule
///
/// "Save is disabled" used to be `!name.isEmpty` on this screen alone. The
/// Portal had its own idea and Android a third, so a record one client refused
/// another would happily write — and the store could hold products that no
/// spray calculation, compliance check or resistance warning could use.
///
/// The authoritative definition is the edge function's `save_contract.ts`;
/// this is its mirror, decision for decision, so the form can respond as the
/// operator types instead of waiting for a round trip. Any change must be made
/// in both, and `ChemicalSaveContractTests` pins the shared cases.
///
/// # What it deliberately does NOT require
///
/// * **WHP / REI** — null when the label does not state them. Demanding a
///   number the label never printed would manufacture regulatory information,
///   which is the opposite of this feature's job.
/// * **Manufacturer URL** — supplementary, never a substitute for the
///   regulator label, never mandatory.
/// * **A resistance CODE** — `notApplicable` and `unresolved` are both
///   acceptable answers. Only silence is refused, because the Planner cannot
///   tell a blank from "no concern".
nonisolated enum ChemicalSaveContract {

    /// Rate bases a calculation can actually run on.
    private static let calculableBases: Set<ChemicalLabelRateBasis> = [
        .per100Litres, .perHectare, .rangePer100Litres, .rangePerHectare
    ]

    /// Whether a rate can drive a calculation.
    ///
    /// Verbatim wording is deliberately excluded. "Apply as directed by an
    /// agronomist" is worth storing and cannot produce a dose; treating
    /// `rawText` as a rate is what let unusable chemicals into the store.
    static func isUsable(_ rate: ChemicalLabelRate) -> Bool {
        guard calculableBases.contains(rate.basis) else { return false }
        guard !rate.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch rate.basis {
        case .rangePer100Litres, .rangePerHectare:
            guard let low = rate.minValue, let high = rate.maxValue,
                  low.isFinite, high.isFinite, low > 0, high > 0, high >= low
            else { return false }
            return true
        case .per100Litres, .perHectare:
            guard let value = rate.value, value.isFinite, value > 0 else { return false }
            return true
        case .other:
            return false
        }
    }

    /// A rate a calculation may use WITHOUT asking the operator first.
    ///
    /// An ambiguous rate is usable but not automatic: the label states several
    /// rates on one basis and nothing proved which condition governs which
    /// number. Preserving them is right; silently applying the first is not.
    static func isAutoApplicable(_ rate: ChemicalLabelRate) -> Bool {
        isUsable(rate) && !rate.conditionIsAmbiguous
    }

    /// Evaluate a record against the contract.
    ///
    /// Returns EVERY violation rather than the first, so the form can show the
    /// whole remaining task instead of revealing it one field at a time.
    static func evaluate(
        productName: String,
        productCategory: String,
        intelligence: ChemicalIntelligence,
        intent: ChemicalSaveIntent = .sprayReady,
        resistanceState: ChemicalResistanceState? = nil
    ) -> ChemicalSaveEvaluation {
        var violations: [ChemicalSaveViolation] = []

        if productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.init(
                code: .productNameMissing,
                message: "Enter the product name.",
                field: "product_name"
            ))
        }

        // The calculation model picks litres vs kilograms from the category,
        // so a product without one cannot be dosed.
        let category = productCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? intelligence.productCategory.trimmingCharacters(in: .whitespacesAndNewlines)
            : productCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        if category.isEmpty {
            violations.append(.init(
                code: .productCategoryMissing,
                message: "Choose the product category so VineTrack knows how to measure it.",
                field: "product_category"
            ))
        }

        // "At least one active WHERE the product has one." A record with no
        // actives is a legitimate adjuvant or wetter, so absence is not a
        // fault — but a half-typed row with no name is.
        let actives = intelligence.activeIngredients
        if !actives.isEmpty,
           actives.allSatisfy({ $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            violations.append(.init(
                code: .activeIngredientNameMissing,
                message: "Enter the active ingredient name, or remove the empty row.",
                field: "active_ingredients"
            ))
        }

        // Product-level rate carriers are rate information, not use claims,
        // so the grapevine test reads STATED uses only.
        let viticultural = intelligence.registeredUses.statedUses.viticultural
        if viticultural.isEmpty {
            violations.append(.init(
                code: .grapevineUseMissing,
                message: "Add the grapevine use this product is registered for.",
                field: "registered_uses"
            ))
        }

        let viticulturalRates = viticultural.flatMap(\.rates)
        let usable = viticulturalRates.filter(isUsable)

        if !viticultural.isEmpty, usable.isEmpty {
            // The §11 case: research identified the product and the grapevine
            // use but produced no rate. This must not save as though ready.
            violations.append(.init(
                code: .usableRateMissing,
                message: "Rate not found — enter the rate from the label before saving.",
                field: "rates"
            ))
        }

        violations.append(contentsOf: rateViolations(viticulturalRates))

        // The shared contract also refuses a BLANK resistance state, because
        // the Planner cannot tell a blank from "no concern". That violation
        // is structurally unreachable here and deliberately so: on iOS the
        // state is a non-optional enum derived from the actives, so it is
        // always one of the three valid answers. The Portal sends a string
        // and can send an empty one, which is why `save_contract.ts` keeps
        // the check. Deriving it here rather than trusting a caller is what
        // makes the difference structural instead of merely likely.
        let resolvedState = resistanceState ?? ChemicalResistanceState.rollup(actives)

        if intent == .verified {
            let registration = intelligence.registration
            let number = registration?.registrationNumber?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let country = registration?.countryCode
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if number.isEmpty || country.isEmpty {
                violations.append(.init(
                    code: .registrationIdentityMissing,
                    message: "A verified product needs its registration number and country.",
                    field: "registration"
                ))
            }
            let label = registration?.labelReference?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if label.isEmpty {
                violations.append(.init(
                    code: .officialLabelMissing,
                    message: "A verified product needs a link to the official regulator label.",
                    field: "label_reference"
                ))
            }
        }

        // Deduplicate: several malformed rates produce one actionable message,
        // not the same sentence three times.
        var seen = Set<String>()
        let deduped = violations.filter { seen.insert($0.id).inserted }

        return ChemicalSaveEvaluation(
            violations: deduped,
            resistanceState: resolvedState,
            hasUsableViticulturalRate: !usable.isEmpty,
            requiresRateConditionChoice: !usable.isEmpty
                && usable.allSatisfy(\.conditionIsAmbiguous)
        )
    }

    /// Per-rate structural faults, so the operator can fix the value itself.
    private static func rateViolations(_ rates: [ChemicalLabelRate]) -> [ChemicalSaveViolation] {
        var out: [ChemicalSaveViolation] = []
        for rate in rates {
            // A verbatim entry is a legitimate record, not a malformed rate.
            if rate.basis == .other { continue }
            if rate.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.init(
                    code: .rateUnitMissing,
                    message: "Enter the unit for this rate (L, mL, kg or g).",
                    field: "rates"
                ))
            }
            switch rate.basis {
            case .rangePer100Litres, .rangePerHectare:
                guard let low = rate.minValue, let high = rate.maxValue,
                      low.isFinite, high.isFinite, low > 0, high > 0 else {
                    out.append(.init(
                        code: .rateValueInvalid,
                        message: "Enter both ends of this rate range from the label.",
                        field: "rates"
                    ))
                    continue
                }
                if high < low {
                    out.append(.init(
                        code: .rateRangeInverted,
                        message: "This rate range is back to front — the low value must come first.",
                        field: "rates"
                    ))
                }
            case .per100Litres, .perHectare:
                if !(rate.value.map { $0.isFinite && $0 > 0 } ?? false) {
                    out.append(.init(
                        code: .rateValueInvalid,
                        message: "Enter the rate from the label.",
                        field: "rates"
                    ))
                }
            case .other:
                continue
            }
        }
        return out
    }
}

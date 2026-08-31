import Foundation

/// The canonical default-rate options AS THE SERVER BUILT THEM.
///
/// # Why this type has to exist
///
/// The edge function already groups a label's grapevine rates into operator
/// choices and mints a stable `option_key` for each, citing the `rate_id` of
/// every printed direction behind it. iOS ignored that block entirely: it
/// re-grouped `registered_uses` on device and minted its own key with a local
/// mirror of the server's hashing.
///
/// A deterministic mirror is not the same guarantee as a shared value. The two
/// implementations agree only for as long as nobody changes either of them, and
/// the failure is silent and total — a key that drifts by one character stops
/// matching the Portal's and the server's, so the same confirmed choice reads
/// as two different options across clients and every "is this default still
/// current?" check quietly answers no.
///
/// So the identity now travels one way: the server issues it, this type carries
/// it verbatim, and the device never computes one.
///
/// Mirrors the Android `ChemicalServerDefaultRateOption` rule for rule. There
/// is deliberately no separate iOS interpretation of what makes an option
/// usable — two readers with two rules is how a rate becomes displayable on one
/// platform and unusable on the other.
///
/// # Validation, never repair
///
/// Every rule below answers yes or no about a WHOLE option. A malformed option
/// is discarded, not mended: a "fixed" option would be a canonical-looking
/// identity for a choice the register never issued, which is precisely what
/// minting on device did wrong.
nonisolated struct ChemicalServerDefaultRateOption: Codable, Sendable, Hashable {

    /// Server-minted. Never computed here.
    let optionKey: String
    /// Every printed direction supporting this amount. Never empty.
    let rateIds: [String]
    /// `per_hectare` or `per_100_litres`.
    let basis: String
    /// The LABEL's own unit — never the product's stock or inventory unit.
    let unit: String
    let value: Double?
    let minValue: Double?
    let maxValue: Double?

    // --- display metadata: presentation only, never identity, never stored ---

    let directionIds: [String]
    let targets: [String]
    let conditions: [String]
    let crops: [String]
    /// At least one supporting rate could not be tied to its condition by the
    /// server's deterministic grammar. Carried so a screen can make the
    /// operator choose deliberately rather than present an unproven
    /// association as settled. It says nothing about whether the NUMBER is
    /// right — that was read verbatim from the label.
    let conditionAmbiguous: Bool

    /// Every option key the shared identity minter produces carries this.
    static let optionKeyPrefix = "default_option_v1_"
    /// Gate D1 rate identities. A UUID here cites a row, not a direction.
    static let rateIDPrefix = "rate_v1_"

    nonisolated enum CodingKeys: String, CodingKey {
        case optionKey = "option_key"
        case rateIds = "rate_ids"
        case basis
        case unit
        case value
        case minValue = "min_value"
        case maxValue = "max_value"
        case directionIds = "direction_ids"
        case targets
        case conditions
        case crops
        case conditionAmbiguous = "condition_ambiguous"
    }

    init(
        optionKey: String = "",
        rateIds: [String] = [],
        basis: String = "",
        unit: String = "",
        value: Double? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        directionIds: [String] = [],
        targets: [String] = [],
        conditions: [String] = [],
        crops: [String] = [],
        conditionAmbiguous: Bool = false
    ) {
        self.optionKey = optionKey
        self.rateIds = rateIds
        self.basis = basis
        self.unit = unit
        self.value = value
        self.minValue = minValue
        self.maxValue = maxValue
        self.directionIds = directionIds
        self.targets = targets
        self.conditions = conditions
        self.crops = crops
        self.conditionAmbiguous = conditionAmbiguous
    }

    /// Tolerant on every field: a server that predates a key sends none, and a
    /// missing display field must cost the explanation rather than the option.
    /// The fields that carry MEANING are still validated by `isValid`.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        optionKey = (try? c.decodeIfPresent(String.self, forKey: .optionKey)) as? String ?? ""
        rateIds = (try? c.decodeIfPresent([String].self, forKey: .rateIds)) as? [String] ?? []
        basis = (try? c.decodeIfPresent(String.self, forKey: .basis)) as? String ?? ""
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) as? String ?? ""
        value = (try? c.decodeIfPresent(Double.self, forKey: .value)) ?? nil
        minValue = (try? c.decodeIfPresent(Double.self, forKey: .minValue)) ?? nil
        maxValue = (try? c.decodeIfPresent(Double.self, forKey: .maxValue)) ?? nil
        directionIds = (try? c.decodeIfPresent([String].self, forKey: .directionIds)) as? [String] ?? []
        targets = (try? c.decodeIfPresent([String].self, forKey: .targets)) as? [String] ?? []
        conditions = (try? c.decodeIfPresent([String].self, forKey: .conditions)) as? [String] ?? []
        crops = (try? c.decodeIfPresent([String].self, forKey: .crops)) as? [String] ?? []
        conditionAmbiguous =
            (try? c.decodeIfPresent(Bool.self, forKey: .conditionAmbiguous)) as? Bool ?? false
    }

    /// The decision basis this option belongs to, or `nil` when unrecognised.
    nonisolated var decisionBasis: ChemicalDefaultRateBasis? {
        let trimmed = basis.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChemicalDefaultRateBasis.allCases.first { $0.rawValue == trimmed }
    }

    /// True when the label states this amount as a band.
    nonisolated var isRange: Bool { minValue != nil && maxValue != nil }

    /// Whether this option may be believed.
    ///
    /// ```text
    /// option_key   server-minted, `default_option_v1_`, not the bare prefix
    /// rate_ids     non-empty, every entry a `rate_v1_` direction identity
    /// basis        one of the two a default can be held on
    /// unit         non-empty
    /// amount       scalar XOR range (shared shape D3), finite and positive
    /// ```
    nonisolated var isValid: Bool {
        let key = optionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix(Self.optionKeyPrefix), key.count > Self.optionKeyPrefix.count else {
            return false
        }

        let ids = rateIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !ids.isEmpty else { return false }
        guard ids.allSatisfy({ $0.hasPrefix(Self.rateIDPrefix) && $0.count > Self.rateIDPrefix.count })
        else { return false }

        guard decisionBasis != nil else { return false }
        guard !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        func usable(_ v: Double?) -> Bool {
            guard let v else { return false }
            return v.isFinite && v > 0
        }
        switch (value != nil, minValue != nil, maxValue != nil) {
        case (true, false, false):
            return usable(value)
        case (false, true, true):
            // An inverted band is not a narrow band, it is a corrupt one.
            guard usable(minValue), usable(maxValue), let lo = minValue, let hi = maxValue
            else { return false }
            return lo <= hi
        default:
            // Everything else: a lone bound, an empty amount, or both shapes.
            return false
        }
    }

    /// The label basis this amount was printed on.
    ///
    /// Derived from the server's basis PLUS the amount shape, because the label
    /// enum distinguishes a single figure from a band while the decision enum
    /// deliberately does not.
    nonisolated var labelBasis: ChemicalLabelRateBasis {
        switch decisionBasis {
        case .perHectare: return isRange ? .rangePerHectare : .perHectare
        case .per100Litres: return isRange ? .rangePer100Litres : .per100Litres
        case nil: return .other
        }
    }

    /// The condition wording the supporting directions carried, as one line.
    nonisolated var conditionText: String {
        conditions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// This option as the label rate it was read from.
    ///
    /// A straight copy of the server's own amount fields. Nothing is converted,
    /// rounded or re-derived — the numbers reaching the operator are the
    /// numbers the register printed.
    nonisolated func toLabelRate() -> ChemicalLabelRate {
        ChemicalLabelRate(
            label: conditionText,
            basis: labelBasis,
            value: value,
            minValue: minValue,
            maxValue: maxValue,
            unit: unit.trimmingCharacters(in: .whitespacesAndNewlines),
            conditionIsAmbiguous: conditionAmbiguous,
            // Deliberately nil: this rate stands for a GROUP of directions, and
            // the group's citations live in `rateIds`. Naming one of them here
            // would imply the option rests on a single direction.
            rateId: nil
        )
    }

    /// The display conditions behind this option, from the server's own
    /// metadata — so a screen explains the option using the directions the
    /// server actually grouped, not a set the device re-derived.
    nonisolated func toConditions() -> [ChemicalDefaultRateCondition] {
        let crop = crops.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCrop = (crop?.isEmpty == false ? crop! : "GRAPEVINES")
        let condition = conditionText
        let jurisdictions = ChemicalRateJurisdiction.mentioned(
            in: (conditions + targets).joined(separator: " ")
        )
        guard !targets.isEmpty else {
            return [
                ChemicalDefaultRateCondition(
                    crop: resolvedCrop,
                    targetRaw: "",
                    conditionText: condition,
                    rawText: nil,
                    jurisdictions: jurisdictions
                )
            ]
        }
        return targets.map { target in
            ChemicalDefaultRateCondition(
                crop: resolvedCrop,
                targetRaw: target.trimmingCharacters(in: .whitespacesAndNewlines),
                conditionText: condition,
                rawText: nil,
                jurisdictions: jurisdictions
            )
        }
    }

    /// This option as the domain option the picker renders.
    ///
    /// The `id` IS the server's `option_key`. Everything downstream —
    /// selection, confirmation, persistence — therefore carries the server's
    /// identity by construction rather than by a later lookup that could miss.
    nonisolated func toDomainOption() -> ChemicalDefaultRateOption {
        ChemicalDefaultRateOption(
            id: optionKey.trimmingCharacters(in: .whitespacesAndNewlines),
            rate: toLabelRate(),
            conditions: toConditions(),
            server: self
        )
    }
}

/// The server's options for a product, split by basis. The two are independent.
nonisolated struct ChemicalServerDefaultRateOptions: Codable, Sendable, Hashable {
    let perHectare: [ChemicalServerDefaultRateOption]
    let per100Litres: [ChemicalServerDefaultRateOption]

    nonisolated enum CodingKeys: String, CodingKey {
        case perHectare = "per_hectare"
        case per100Litres = "per_100_litres"
    }

    init(
        perHectare: [ChemicalServerDefaultRateOption] = [],
        per100Litres: [ChemicalServerDefaultRateOption] = []
    ) {
        self.perHectare = perHectare
        self.per100Litres = per100Litres
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        perHectare =
            (try? c.decodeIfPresent([ChemicalServerDefaultRateOption].self, forKey: .perHectare))
            as? [ChemicalServerDefaultRateOption] ?? []
        per100Litres =
            (try? c.decodeIfPresent([ChemicalServerDefaultRateOption].self, forKey: .per100Litres))
            as? [ChemicalServerDefaultRateOption] ?? []
    }

    /// Only the options that passed every rule, in the server's own order.
    nonisolated func validOptions(_ basis: ChemicalDefaultRateBasis)
        -> [ChemicalServerDefaultRateOption]
    {
        let raw: [ChemicalServerDefaultRateOption]
        switch basis {
        case .perHectare: raw = perHectare
        case .per100Litres: raw = per100Litres
        }
        // The containing list must agree with the option's own basis, exactly
        // as a persisted slot must agree with the slot it sits in: a per-100 L
        // option filed under per-hectare would be applied per hectare.
        return raw.filter { $0.isValid && $0.decisionBasis == basis }
    }

    /// True when the server supplied no usable option on either basis.
    nonisolated var isEmpty: Bool {
        ChemicalDefaultRateBasis.allCases.allSatisfy { validOptions($0).isEmpty }
    }
}

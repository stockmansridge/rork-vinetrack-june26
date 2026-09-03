import Foundation

/// Whether a stored operational default may be believed, and what amount it
/// actually records.
///
/// The iOS counterpart of Android's `ChemicalDefaultRateValidity`. The two are
/// kept deliberately identical: a rate that is spray-ready on one platform and
/// silently ignored on the other is a worse failure than either behaviour on
/// its own, because the disagreement is invisible until a tank is mixed.
///
/// Nothing here reads `rate_per_ha`. That column is a legacy projection with no
/// link back to a printed direction (sql/222), so it can never establish what
/// the operator confirmed.
nonisolated enum ChemicalDefaultRateValidity {

    /// Rate units a line may carry. Keyed lowercase; the value is the canonical
    /// spelling. These are LABEL rate units, never pack units.
    private static let supportedUnits: [String: String] = [
        "l": "L", "litre": "L", "litres": "L", "liter": "L", "liters": "L",
        "ml": "mL", "millilitre": "mL", "millilitres": "mL",
        "kg": "kg", "kilogram": "kg", "kilograms": "kg",
        "g": "g", "gram": "g", "grams": "g"
    ]

    /// Canonical spelling of a rate unit, or `nil` when it is not one a line
    /// may carry.
    static func canonicalUnit(_ raw: String?) -> String? {
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return supportedUnits[key]
    }

    /// The two amount shapes a slot may hold — never both (shared shape D3).
    nonisolated enum Amount: Equatable, Sendable {
        /// A confirmed dose. The only shape that may prefill a spray line.
        case scalar(Double)
        /// What the label permits. NOT a decision, and never a prefill.
        case range(min: Double, max: Double)
    }

    private static func isUsableNumber(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value.isFinite && value > 0
    }

    private static func amount(of slot: StoredChemicalDefaultRate) -> Amount? {
        let hasScalar = slot.value != nil
        let hasMin = slot.minValue != nil
        let hasMax = slot.maxValue != nil

        if hasScalar, !hasMin, !hasMax {
            guard let value = slot.value, isUsableNumber(value) else { return nil }
            return .scalar(value)
        }
        if !hasScalar, hasMin, hasMax {
            guard let min = slot.minValue, let max = slot.maxValue,
                  isUsableNumber(min), isUsableNumber(max),
                  // An inverted band is not a narrow band, it is a corrupt one.
                  min <= max
            else { return nil }
            return .range(min: min, max: max)
        }
        // Everything else: a lone bound, an empty row, or both shapes at once.
        return nil
    }

    /// A stored slot that passed every rule, with its amount already resolved.
    nonisolated struct ValidSlot: Equatable, Sendable {
        let basis: ChemicalDefaultRateBasis
        /// Canonical spelling of the LABEL rate's unit — never the pack unit.
        let unit: String
        let amount: Amount
        let slot: StoredChemicalDefaultRate

        /// The confirmed dose, or `nil` when this slot records an unnarrowed band.
        var scalar: Double? {
            if case .scalar(let value) = amount { return value }
            return nil
        }

        /// The registered band, or `nil` when this slot records a single dose.
        var range: (min: Double, max: Double)? {
            if case .range(let min, let max) = amount { return (min, max) }
            return nil
        }
    }

    /// The slot stored on `basis`, or `nil` when there is none the contract can
    /// believe.
    ///
    /// Checked in full, because each rule catches a different way a row stops
    /// meaning what it says:
    ///
    /// ```text
    /// root version          a document written to a contract this build cannot read
    /// containing basis      a per-100 L rate filed under per-hectare, applied per hectare
    /// option key identity   a key no minter produced, so no client can match it
    /// rate ids present      a default citing nothing can never be shown to be current
    /// rate id identity      a UUID cites a row, not a printed direction
    /// supported unit        an amount nothing can display or cost
    /// source vocabulary     provenance outside the closed set is unattributable
    /// amount shape (D3)     scalar XOR range, both finite and positive
    /// ```
    static func validSlot(
        _ defaults: StoredChemicalDefaultRates?,
        basis: ChemicalDefaultRateBasis
    ) -> ValidSlot? {
        guard let defaults else { return nil }
        guard defaults.version == StoredChemicalDefaultRates.currentVersion else { return nil }
        guard let slot = defaults.slot(basis) else { return nil }

        let key = slot.optionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPrefix = ChemicalServerDefaultRateOption.optionKeyPrefix
        guard key.hasPrefix(keyPrefix), key.count > keyPrefix.count else { return nil }

        // Trimmed rather than filtered: a blank entry in the citation list is a
        // malformed row, not a row with one fewer citation.
        let idPrefix = ChemicalServerDefaultRateOption.rateIDPrefix
        let ids = slot.rateIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !ids.isEmpty else { return nil }
        guard ids.allSatisfy({ $0.hasPrefix(idPrefix) && $0.count > idPrefix.count }) else {
            return nil
        }

        guard slot.basis.trimmingCharacters(in: .whitespacesAndNewlines) == basis.rawValue else {
            return nil
        }
        guard let unit = canonicalUnit(slot.unit) else { return nil }

        let source = slot.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownSource = source == StoredChemicalDefaultRate.sourceOperator
            || source == StoredChemicalDefaultRate.sourceRecommended
        guard knownSource else { return nil }

        guard let amount = amount(of: slot) else { return nil }
        return ValidSlot(basis: basis, unit: unit, amount: amount, slot: slot)
    }

    /// The CONFIRMED dose stored on `basis`, or `nil` when there is none.
    ///
    /// The scalar shape is the only confirmed amount: a slot still holding a
    /// band is a decision that was never finished, and its bounds are what the
    /// label permits rather than what this vineyard pours.
    static func confirmedScalar(
        _ defaults: StoredChemicalDefaultRates?,
        basis: ChemicalDefaultRateBasis
    ) -> ValidSlot? {
        guard let slot = validSlot(defaults, basis: basis), slot.scalar != nil else { return nil }
        return slot
    }

    /// Every basis carrying a believable slot, per-hectare first.
    static func validSlots(_ defaults: StoredChemicalDefaultRates?) -> [ValidSlot] {
        [
            validSlot(defaults, basis: .perHectare),
            validSlot(defaults, basis: .per100Litres)
        ].compactMap { $0 }
    }
}

extension StoredChemicalDefaultRates {
    /// The confirmed single dose on `basis`, or `nil` when this chemical records
    /// a range, records nothing, or records something malformed.
    ///
    /// This is the accessor the legacy `rate_per_ha` projection is built from,
    /// which is why it must never fall back to a bound or a midpoint.
    nonisolated func confirmedScalarAmount(for basis: ChemicalDefaultRateBasis) -> Double? {
        ChemicalDefaultRateValidity.confirmedScalar(self, basis: basis)?.scalar
    }

    /// The believable slot on `basis`, scalar or range.
    nonisolated func validSlot(for basis: ChemicalDefaultRateBasis) -> ChemicalDefaultRateValidity.ValidSlot? {
        ChemicalDefaultRateValidity.validSlot(self, basis: basis)
    }
}

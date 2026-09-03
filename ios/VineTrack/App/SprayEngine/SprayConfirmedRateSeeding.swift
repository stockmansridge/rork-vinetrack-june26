import Foundation

/// Wires the Chemical Rate Contract (`ChemicalSprayRateHandoff`) into the
/// Spray Program's product lines — the production seeding, range gating and
/// spray-record provenance, kept out of the SwiftUI file so the exact code the
/// screen runs can be exercised by tests.
///
/// # What this reads
///
/// A product's CONFIRMED `default_rates` first. The registered-use rates the
/// card already offers are then matched — never replaced — so a confirmed
/// `2 L/100 L` selects that exact registered rate on the line, and a confirmed
/// `2–3 L/100 L` selects that exact band and leaves the dose to the operator.
/// Nothing here converts a unit or a basis, and nothing here picks a point
/// inside a band.
nonisolated enum SprayConfirmedRateSeeding {

    /// Spray-side basis for a contract basis.
    static func lineBasis(_ basis: ChemicalDefaultRateBasis) -> ChemicalRateBasis {
        switch basis {
        case .perHectare: return .perHectare
        case .per100Litres: return .per100Litres
        }
    }

    /// Contract basis for a spray-side basis.
    static func contractBasis(_ basis: ChemicalRateBasis) -> ChemicalDefaultRateBasis {
        switch basis {
        case .perHectare: return .perHectare
        case .per100Litres: return .per100Litres
        }
    }

    /// The confirmed resolution governing a line on `basis`, or `nil` when
    /// the product confirms nothing on that basis.
    static func resolution(
        for chemical: SavedChemical,
        basis: ChemicalRateBasis
    ) -> ChemicalSprayRateHandoff.Resolution? {
        ChemicalSprayRateHandoff.resolutions(chemical.defaultRates)
            .first { lineBasis($0.basis) == basis }
    }

    /// The confirmed band governing a line on `basis`, when there is one.
    static func confirmedRange(
        for chemical: SavedChemical,
        basis: ChemicalRateBasis
    ) -> ChemicalSprayRateHandoff.RangeSelection? {
        resolution(for: chemical, basis: basis)?.rangeSelection
    }

    /// A new product line for `chemical`, seeded from its confirmed rate.
    ///
    /// ```text
    /// one confirmed scalar  → that basis, the matching registered rate selected
    /// one confirmed range   → that basis, the matching band selected, NO dose
    /// two confirmed bases   → no automatic answer; the existing carrier
    ///                         preference seeds as before
    /// nothing confirmed     → the existing registered-use seeding, unchanged
    /// ```
    static func seededLine(
        for chemical: SavedChemical,
        preferring order: [ChemicalRateBasis],
        fallbackBasis: ChemicalRateBasis
    ) -> ChemicalLine {
        var line = ChemicalLine(
            chemicalId: chemical.id,
            selectedRateId: UUID(),
            basis: fallbackBasis
        )
        seed(&line, from: chemical, preferring: order, fallbackBasis: fallbackBasis)
        return line
    }

    /// Re-seeds `line` for `chemical`, discarding whatever the previous
    /// product left behind.
    static func seed(
        _ line: inout ChemicalLine,
        from chemical: SavedChemical,
        preferring order: [ChemicalRateBasis],
        fallbackBasis: ChemicalRateBasis
    ) {
        line.chemicalId = chemical.id
        line.overrideRate = nil

        guard let confirmed = ChemicalSprayRateHandoff.resolution(chemical.defaultRates) else {
            let selection = SprayRegisteredUseRates.defaultSelection(for: chemical, preferring: order)
            line.selectedRateId = selection?.id ?? UUID()
            line.basis = selection?.basis ?? fallbackBasis
            return
        }

        let basis = lineBasis(confirmed.basis)
        line.basis = basis
        let offered = SprayRegisteredUseRates.vineyardRates(for: chemical)
            .filter { $0.basis == basis && $0.isSelectable }

        switch confirmed {
        case .prefilled(let prefill):
            let base = SprayRegisteredUseRates.baseValue(
                prefill.rate, labelUnit: prefill.unit, chemical: chemical
            )
            if let base,
               let match = offered.first(where: { rate in
                   guard !rate.isRangePreset, let seed = rate.seed.seedableValue else { return false }
                   return abs(seed - base) < 0.000_001
               }) {
                line.selectedRateId = match.id
            } else {
                // Confirmed, but not stated as a registered rate on this basis:
                // the confirmed amount itself populates the line.
                line.selectedRateId = UUID()
                line.overrideRate = base
            }

        case .requiresSelection(let range):
            let low = SprayRegisteredUseRates.baseValue(range.min, labelUnit: range.unit, chemical: chemical)
            let high = SprayRegisteredUseRates.baseValue(range.max, labelUnit: range.unit, chemical: chemical)
            let match = offered.first { rate in
                guard case let .range(minimum, maximum) = rate.seed, let low, let high else { return false }
                return abs(minimum - low) < 0.000_001 && abs(maximum - high) < 0.000_001
            }
            // The band is selected; the dose deliberately is not.
            line.selectedRateId = match?.id ?? UUID()
        }
    }

    /// Checks a dose the operator typed for a line governed by a confirmed
    /// band. Returns the accepted value in the band's own unit, or the
    /// refusal to show.
    static func validate(
        typed: Double,
        against range: ChemicalSprayRateHandoff.RangeSelection
    ) -> ChemicalSprayRateHandoff.ApplicationRateOutcome {
        ChemicalSprayRateHandoff.validateApplicationRate(typed, in: range)
    }

    /// The wording for a refused dose. Names the band, because "invalid" tells
    /// an operator nothing about what they may apply.
    static func rejectionMessage(
        _ outcome: ChemicalSprayRateHandoff.ApplicationRateOutcome,
        range: ChemicalSprayRateHandoff.RangeSelection,
        basisSuffix: String
    ) -> String? {
        let band = "\(SprayRateFormatter.format(range.min))–\(SprayRateFormatter.format(range.max)) \(range.unit)\(basisSuffix)"
        switch outcome {
        case .accepted:
            return nil
        case .belowMinimum, .aboveMaximum:
            return "The confirmed rate range is \(band). Enter a rate within it."
        case .notANumber:
            return "Enter the rate you are applying, within \(band)."
        }
    }

    // MARK: - Spray-record provenance

    /// What actually went on this line and where the number came from.
    nonisolated struct AppliedProvenance: Equatable, Sendable {
        let rate: Double
        let unit: String
        let basis: ChemicalDefaultRateBasis
        let entryMethod: String
        let confirmedRange: (min: Double, max: Double)?

        static func == (lhs: AppliedProvenance, rhs: AppliedProvenance) -> Bool {
            lhs.rate == rhs.rate && lhs.unit == rhs.unit && lhs.basis == rhs.basis
                && lhs.entryMethod == rhs.entryMethod
                && lhs.confirmedRange?.min == rhs.confirmedRange?.min
                && lhs.confirmedRange?.max == rhs.confirmedRange?.max
        }
    }

    /// The provenance to freeze onto a calculated line, or `nil` when the line
    /// carries no usable rate.
    ///
    /// The applied dose and unit are the plan's own label-rate descriptor —
    /// the number the Review step displayed, in the label's unit. The entry
    /// method comes from the confirmed slot on the line's basis; a dose typed
    /// for this spray with no confirmed slot behind it is `manual`.
    static func appliedProvenance(
        for chemical: SavedChemical,
        line: ChemicalLine,
        planLine: SprayProductLineResult
    ) -> AppliedProvenance? {
        guard planLine.rate.isFinite, planLine.rate > 0 else { return nil }
        let basis: ChemicalDefaultRateBasis = planLine.basis == .per100Litres ? .per100Litres : .perHectare

        let rate: Double
        let unit: String
        if let label = planLine.labelRate {
            rate = label.value
            unit = label.unit
        } else {
            rate = chemical.unit.fromBase(planLine.rate)
            unit = chemical.unit.rawValue
        }

        let slot = ChemicalDefaultRateValidity.confirmedSlots(chemical.defaultRates)
            .first { $0.basis == basis }
        let entryMethod: String
        if let slot {
            // A confirmed scalar that was then overridden with a DIFFERENT
            // number is a dose the operator typed for this spray. The same
            // number, however it reached the line, keeps the slot's provenance.
            let matchesConfirmedScalar: Bool = {
                guard let scalar = slot.scalar else { return false }
                guard ChemicalDefaultRateValidity.canonicalUnit(unit) == slot.unit else { return false }
                return abs(scalar - rate) < 0.000_001
            }()
            if slot.range == nil, line.overrideRate != nil, !matchesConfirmedScalar {
                entryMethod = StoredChemicalDefaultRate.entryManual
            } else {
                entryMethod = slot.isManualEntry
                    ? StoredChemicalDefaultRate.entryManual
                    : StoredChemicalDefaultRate.entryCanonical
            }
        } else {
            entryMethod = line.overrideRate != nil
                ? StoredChemicalDefaultRate.entryManual
                : StoredChemicalDefaultRate.entryCanonical
        }

        return AppliedProvenance(
            rate: rate,
            unit: unit,
            basis: basis,
            entryMethod: entryMethod,
            confirmedRange: slot?.range
        )
    }

    /// The snapshot to persist on a spray line: the chemistry capture with the
    /// applied dose recorded on it. A product with nothing structured still
    /// gets a minimal snapshot when a dose was applied, so provenance is never
    /// dropped merely because the chemistry was empty.
    static func snapshot(
        base: ChemicalLineSnapshot?,
        chemical: SavedChemical,
        line: ChemicalLine,
        planLine: SprayProductLineResult,
        at date: Date = Date()
    ) -> ChemicalLineSnapshot? {
        guard let provenance = appliedProvenance(for: chemical, line: line, planLine: planLine) else {
            return base
        }
        let start = base ?? ChemicalLineSnapshot(
            savedChemicalId: chemical.id.uuidString,
            productName: planLine.name,
            schemaVersion: 0,
            activityGroupTableVersion: 0,
            capturedAt: date
        )
        return start.recordingApplied(
            rate: provenance.rate,
            unit: provenance.unit,
            basis: provenance.basis,
            entryMethod: provenance.entryMethod,
            confirmedRange: provenance.confirmedRange
        )
    }
}

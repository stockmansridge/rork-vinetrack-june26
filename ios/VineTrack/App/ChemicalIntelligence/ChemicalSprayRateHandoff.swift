import Foundation

/// What a saved chemical offers a new spray line, and what it still needs.
///
/// The iOS counterpart of Android's `ChemicalSprayDefaultHandoff`, kept
/// deliberately identical: a rate that is spray-ready on one platform and
/// "confirmation required" on the other is worse than either behaviour alone,
/// because the disagreement is invisible until a tank is mixed.
///
/// # What may be read
///
/// `default_rates` and nothing else. Deliberately NOT `rates.first()`, NOT
/// `rate_per_ha`, and NOT the first registered use. Each was a previous
/// fallback, and each could put a number in the tank that no operator
/// confirmed — `rates` is ordered by accident, and `rate_per_ha` is a legacy
/// projection with no link back to a printed direction (sql/222).
nonisolated enum ChemicalSprayRateHandoff {

    /// A rate a spray line may start from. Rate, unit and basis travel
    /// TOGETHER and are never separated: a rate without its own unit is the
    /// bug this type exists to make impossible.
    nonisolated struct Prefill: Equatable, Sendable {
        /// The confirmed amount, in `unit`. Never converted.
        let rate: Double
        /// The LABEL rate's own unit — `L`, `mL`, `kg` or `g`. Never the pack unit.
        let unit: String
        let basis: ChemicalDefaultRateBasis
        /// True when the operator typed this rather than reading it off a label.
        let isUserEntered: Bool
    }

    /// A confirmed band the operator must choose a dose inside of.
    nonisolated struct RangeSelection: Equatable, Sendable {
        let min: Double
        let max: Double
        let unit: String
        let basis: ChemicalDefaultRateBasis
        let isUserEntered: Bool

        /// Whether `value` is a dose this band authorises. Inclusive: a label
        /// permits its own bounds.
        func authorises(_ value: Double) -> Bool {
            ChemicalDefaultRateValidity.isWithinRange(value, min: min, max: max)
        }
    }

    /// What one confirmed slot resolves to.
    nonisolated enum Resolution: Equatable, Sendable {
        /// A single confirmed dose. Ready to prefill.
        case prefilled(Prefill)
        /// A confirmed band. The chemical is selectable, but the spray cannot
        /// proceed until the operator names the dose they will actually apply.
        case requiresSelection(RangeSelection)

        var prefill: Prefill? {
            if case .prefilled(let value) = self { return value }
            return nil
        }

        var rangeSelection: RangeSelection? {
            if case .requiresSelection(let value) = self { return value }
            return nil
        }

        var basis: ChemicalDefaultRateBasis {
            switch self {
            case .prefilled(let value): return value.basis
            case .requiresSelection(let value): return value.basis
            }
        }
    }

    /// Everything a product confirms, per-hectare first.
    ///
    /// Both entry methods qualify. What decides spray-readiness is whether a
    /// HUMAN confirmed the rate, not whether a regulator printed it — a
    /// user-entered rate the operator explicitly confirmed is real VineTrack
    /// data, and refusing it merely because it carries no `rate_v1_` citation
    /// is what left confirmed products stuck behind "Rate confirmation
    /// required".
    static func resolutions(
        _ defaults: StoredChemicalDefaultRates?
    ) -> [Resolution] {
        ChemicalDefaultRateValidity.confirmedSlots(defaults).compactMap { slot in
            if let scalar = slot.scalar {
                return .prefilled(Prefill(
                    rate: scalar,
                    unit: slot.unit,
                    basis: slot.basis,
                    isUserEntered: slot.isManualEntry
                ))
            }
            if let range = slot.range {
                return .requiresSelection(RangeSelection(
                    min: range.min,
                    max: range.max,
                    unit: slot.unit,
                    basis: slot.basis,
                    isUserEntered: slot.isManualEntry
                ))
            }
            return nil
        }
    }

    /// The single resolution for a product, or `nil` when the operator must
    /// first choose a basis.
    ///
    /// Two confirmed bases produce NO automatic answer deliberately:
    /// per-hectare and per-100 L are different ways of dosing the same spray,
    /// and picking one would silently decide how the mix is built.
    static func resolution(
        _ defaults: StoredChemicalDefaultRates?
    ) -> Resolution? {
        let all = resolutions(defaults)
        return all.count == 1 ? all[0] : nil
    }

    /// The dose to seed a line with, or `nil` when there is nothing to seed.
    ///
    /// A confirmed BAND returns nil here on purpose — the chemical is usable,
    /// but its dose is not yet decided, and seeding the minimum, maximum or
    /// midpoint would be making that decision on the operator's behalf.
    static func prefill(
        _ defaults: StoredChemicalDefaultRates?
    ) -> Prefill? {
        resolution(defaults)?.prefill
    }

    /// True when the product carries at least one operator-confirmed rate, so
    /// it may be selected in Spray Program.
    ///
    /// A band counts. It means "choose a dose inside this", not "unconfirmed".
    static func isSprayReady(_ defaults: StoredChemicalDefaultRates?) -> Bool {
        !resolutions(defaults).isEmpty
    }

    /// Validates a dose the operator typed for a confirmed band.
    nonisolated enum ApplicationRateOutcome: Equatable, Sendable {
        case accepted(Double)
        /// Below the band's lower bound.
        case belowMinimum(min: Double)
        /// Above the band's upper bound.
        case aboveMaximum(max: Double)
        /// Not a usable positive number.
        case notANumber

        var acceptedValue: Double? {
            if case .accepted(let value) = self { return value }
            return nil
        }

        var isAccepted: Bool { acceptedValue != nil }
    }

    /// Checks a chosen application rate against a confirmed band.
    ///
    /// The chosen dose belongs to the SPRAY, never to the saved chemical: a
    /// 2.5 selected inside a confirmed 2–3 band is what went in this tank, and
    /// writing it back over the stored range would destroy the registered band
    /// the operator is entitled to keep working from.
    static func validateApplicationRate(
        _ value: Double?,
        in selection: RangeSelection
    ) -> ApplicationRateOutcome {
        guard let value, value.isFinite, value > 0 else { return .notANumber }
        if value < selection.min { return .belowMinimum(min: selection.min) }
        if value > selection.max { return .aboveMaximum(max: selection.max) }
        return .accepted(value)
    }
}

import CryptoKit
import Foundation

/// Where a selectable spray rate came from.
nonisolated enum SprayRateOrigin: String, Sendable, Hashable {
    /// A structured `registeredUses[].rates` entry — the shared Chemical
    /// Intelligence contract, tied to a crop and target.
    case registeredUse
    /// The legacy `saved_chemicals.rates` array. Backward compatibility only.
    case legacy
}

/// What a rate can contribute to a calculation.
///
/// Deliberately an enum rather than an optional Double: "no number", "a band"
/// and "read the label" are three different answers, and collapsing them would
/// be exactly the silent guessing this contract forbids.
nonisolated enum SprayRateSeed: Sendable, Hashable {
    /// A single rate, in the chemical's BASE units (mL or g) so it is
    /// interchangeable with a legacy `ChemicalRate.value`.
    case value(Double)
    /// A label band, in base units. Deliberately NOT seedable: picking a point
    /// inside a registered range is the operator's decision, not VineTrack's.
    case range(minimum: Double, maximum: Double)
    /// `basis:"other"` — reference wording only, never an application rate.
    case referenceOnly
    /// A rate with no usable number, or a unit this build cannot convert.
    case unresolved

    /// The value a calculation may start from, or `nil` when the operator has
    /// to establish it. Only `.value` ever qualifies.
    var seedableValue: Double? {
        if case let .value(v) = self { return v }
        return nil
    }
}

/// One rate the operator can pick in the Spray Tool.
///
/// Flattened out of the structured registered uses so the existing picker can
/// render it, but each entry KEEPS the crop and target it belongs to — a rate
/// detached from its registered use is just a number.
nonisolated struct SpraySelectableRate: Identifiable, Sendable, Hashable {
    let id: UUID
    let origin: SprayRateOrigin
    /// The registered use this rate belongs to. `nil` for legacy rates.
    let crop: String?
    let targetRaw: String?
    /// The label's own wording for this rate, e.g. `"Dilute"`.
    let label: String
    /// The spray-side basis. `nil` when the label basis maps to no application
    /// basis at all (`basis:"other"`), which is what makes it unselectable.
    let basis: ChemicalRateBasis?
    let seed: SprayRateSeed
    /// The rate exactly as the label states it, e.g. `"35–54 mL/100 L"`.
    let displayText: String

    /// `"GRAPEVINE · POWDERY MILDEW"`, or `nil` for a legacy rate.
    var useTitle: String? {
        guard let crop, !crop.isEmpty else { return targetRaw }
        guard let targetRaw, !targetRaw.isEmpty else { return crop }
        return "\(crop) · \(targetRaw)"
    }

    /// Whether the operator may choose this rate for a product line.
    ///
    /// A range IS selectable — choosing it fixes the basis and shows the band,
    /// then the existing override field establishes the applied rate. A
    /// reference-only or unresolved entry is not: there is nothing to apply.
    var isSelectable: Bool {
        guard basis != nil else { return false }
        switch seed {
        case .value, .range: return true
        case .referenceOnly, .unresolved: return false
        }
    }

    /// Whether the operator must type the rate before this line can calculate.
    var requiresOperatorRate: Bool {
        if case .range = seed { return true }
        return false
    }

    /// Menu wording: the label's name and its rate, e.g. `"Dilute: 35–54 mL/100 L"`.
    var menuText: String {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? displayText : "\(name): \(displayText)"
    }
}

/// Resolves the rates a Spray Tool product line may be calculated from.
///
/// # Precedence
///
/// Structured `registeredUses[].rates` are authoritative whenever the record
/// carries any. The legacy `saved_chemicals.rates` array is consulted ONLY when
/// structured rates are genuinely absent, which is what keeps pre-Chemical-
/// Intelligence records and hand-entered products working untouched.
///
/// The two are never merged. A record that has been matched against a register
/// would otherwise offer the operator a stale hand-typed rate alongside the
/// label's own, with nothing on screen to say which one the label agrees with.
nonisolated enum SprayRegisteredUseRates {

    // MARK: - Public API

    /// Whether this record carries any structured registered-use rate at all.
    static func hasStructuredRates(_ chemical: SavedChemical) -> Bool {
        chemical.chemicalIntelligence?.registeredUses.contains { !$0.rates.isEmpty } ?? false
    }

    /// The rates a VINEYARD spray job may be calculated from.
    ///
    /// # Why the operational picker is scoped and the record is not
    ///
    /// An approved label may register forty crops. Dithane Rainshield's carries
    /// tobacco blue mould, brown spot on mandarin and citrus black spot — real,
    /// authoritative registered uses, and every one of them was being offered in
    /// the vineyard Spray Calculator's Rate menu. That is how a `2.2 kg/ha`
    /// tobacco rate became selectable for a grapevine spray: not a data defect,
    /// but the operational picker declining to say what the job is FOR.
    ///
    /// So the calculator asks for vineyard rates. Nothing is deleted, nothing is
    /// rewritten, and every other crop stays in full on the record and in the
    /// Chemical editor's "Other crops on this label" disclosure — they simply
    /// are not rates for THIS job.
    ///
    /// Legacy rates are returned unscoped: they carry no crop at all, so there
    /// is nothing to scope by, and hiding them would silently empty the picker
    /// for every pre-Chemical-Intelligence product.
    static func vineyardRates(for chemical: SavedChemical) -> [SpraySelectableRate] {
        // A record that states ANY structured rate is answered only from its
        // structured rates. Falling back to the legacy array here would let a
        // product whose only structured rates are tobacco's offer a stale
        // hand-typed number in their place — which is the same borrowing this
        // scoping exists to stop, just from a different direction.
        if hasStructuredRates(chemical) {
            return structuredRates(for: chemical, scope: .vineyardOnly)
        }
        return legacyRates(for: chemical)
    }

    /// The vineyard rates that can actually be picked.
    static func selectableVineyardRates(for chemical: SavedChemical) -> [SpraySelectableRate] {
        vineyardRates(for: chemical).filter(\.isSelectable)
    }

    /// Whether this product states a vineyard registered use at all.
    ///
    /// Distinguishes "this product is not registered on grapevines" from "it is,
    /// but the label bound no rate to the use you picked". The two need
    /// different words in front of an operator, and an empty picker says
    /// neither.
    static func hasVineyardUse(_ chemical: SavedChemical) -> Bool {
        chemical.chemicalIntelligence?.registeredUses.contains {
            !ChemicalManualEntry.isProductRateCarrier($0) && $0.isViticultural
        } ?? false
    }

    /// Which registered uses a rate list is drawn from.
    nonisolated enum UseScope: Sendable, Hashable {
        /// Every registered use on the label — the Chemical record's own view.
        case allCrops
        /// Grapevine uses only, plus product-level rate carriers, which state a
        /// rate for the product as a whole and belong to no crop.
        case vineyardOnly
    }

    /// Every rate to OFFER for this chemical, in label order.
    ///
    /// Includes reference-only and unresolved entries: the operator needs to
    /// see that the label says "refer to the approved label" rather than be
    /// shown an empty picker and left to guess.
    static func rates(for chemical: SavedChemical) -> [SpraySelectableRate] {
        let structured = structuredRates(for: chemical)
        return structured.isEmpty ? legacyRates(for: chemical) : structured
    }

    /// The rates that can actually be picked.
    static func selectableRates(for chemical: SavedChemical) -> [SpraySelectableRate] {
        rates(for: chemical).filter(\.isSelectable)
    }

    /// The registered use a selected rate belongs to.
    ///
    /// Restrictions, withholding and re-entry are stated PER USE on a label: a
    /// product registered for two crops can carry two different withholding
    /// periods and two different restriction statements. Once the operator has
    /// chosen a rate, the use behind that rate is the only one whose legal text
    /// applies to the job being composed.
    ///
    /// `nil` for a legacy rate, an unknown id, or a record with no structured
    /// uses — the caller then has nothing use-specific to show, which is the
    /// honest answer rather than another use's wording.
    static func registeredUse(
        for chemical: SavedChemical,
        rateId: UUID
    ) -> ChemicalRegisteredUse? {
        guard let uses = chemical.chemicalIntelligence?.registeredUses else { return nil }
        for use in uses {
            for labelRate in use.rates where selectable(labelRate, use: use, chemical: chemical).id == rateId {
                return use
            }
        }
        return nil
    }

    /// Look up one offered rate by its stable id.
    static func rate(for chemical: SavedChemical, id: UUID) -> SpraySelectableRate? {
        rates(for: chemical).first { $0.id == id }
    }

    /// The value a product line should be calculated from, in base units.
    ///
    /// Returns `nil` — never 0 — when the selection cannot seed a calculation:
    /// a range, a reference-only entry, an unresolved rate, or a rate whose
    /// basis does not match the line's. The engine then reports the line as
    /// unresolved, which is the honest answer.
    ///
    /// The basis check is what stops a per-hectare rate being dosed against
    /// carrier volume (or the reverse) when a line's selection and basis have
    /// drifted apart — for example after switching to a different product.
    static func seedValue(
        for chemical: SavedChemical,
        rateId: UUID,
        basis: ChemicalRateBasis
    ) -> Double? {
        guard let match = rate(for: chemical, id: rateId), match.basis == basis else { return nil }
        return match.seed.seedableValue
    }

    /// The rate to select by default, preferring a given basis when asked.
    ///
    /// Prefers a directly usable single rate over a range, so opening a product
    /// does not immediately demand a manual entry when the label offers a plain
    /// rate as well.
    static func defaultSelection(
        for chemical: SavedChemical,
        preferring basis: ChemicalRateBasis? = nil
    ) -> SpraySelectableRate? {
        defaultSelection(for: chemical, preferring: basis.map { [$0] } ?? [])
    }

    /// The rate to select by default, trying each basis in preference order.
    ///
    /// The ordered form is what a carrier workflow needs: a 100 m runoff job
    /// prefers the label's per-100 L rate and falls back to its per-hectare
    /// rate, and an L/ha job does the reverse. Nothing is converted and nothing
    /// is hidden — a basis that the label does not state simply finds no
    /// candidate and the next preference is tried.
    ///
    /// Within a basis, a directly usable single rate beats a range, so opening
    /// a product does not immediately demand a manual entry when the label
    /// offers a plain rate as well. A range still wins over a rate on a
    /// less-preferred basis: `range_per_100_litres` is the right starting point
    /// for a runoff job even though the operator must still pick a point inside
    /// the band.
    static func defaultSelection(
        for chemical: SavedChemical,
        preferring order: [ChemicalRateBasis],
        scope: UseScope = .vineyardOnly
    ) -> SpraySelectableRate? {
        // Seeding is scoped for the same reason the picker is: a product line
        // opened in a vineyard spray must never START on a tobacco rate.
        let candidates = scope == .vineyardOnly
            ? selectableVineyardRates(for: chemical)
            : selectableRates(for: chemical)
        guard !candidates.isEmpty else { return nil }
        for basis in order {
            let matching = candidates.filter { $0.basis == basis }
            if let single = matching.first(where: { $0.seed.seedableValue != nil }) { return single }
            if let first = matching.first { return first }
        }
        if let single = candidates.first(where: { $0.seed.seedableValue != nil }) { return single }
        return candidates.first
    }

    /// The default selection for a carrier workflow.
    ///
    /// The single entry point every seeding call site should use, so "which
    /// basis does this vineyard start from" is answered in one place rather
    /// than re-derived — differently — at each one.
    static func defaultSelection(
        for chemical: SavedChemical,
        carrier: SprayCarrierBasis
    ) -> SpraySelectableRate? {
        defaultSelection(for: chemical, preferring: SprayRateBasisPreference.order(for: carrier))
    }

    // MARK: - Structured

    /// Flattens `registeredUses[].rates` while keeping each rate's use.
    static func structuredRates(
        for chemical: SavedChemical,
        scope: UseScope = .allCrops
    ) -> [SpraySelectableRate] {
        guard let uses = chemical.chemicalIntelligence?.registeredUses else { return [] }
        var seen = Set<UUID>()
        var out: [SpraySelectableRate] = []
        for use in uses where includes(use, scope: scope) {
            for labelRate in use.rates {
                let entry = selectable(labelRate, use: use, chemical: chemical)
                guard seen.insert(entry.id).inserted else { continue }
                out.append(entry)
            }
        }
        return out
    }

    /// Whether a registered use belongs in a scoped rate list.
    ///
    /// A product-level rate carrier (no crop, no target) is always included: it
    /// states a rate for the product as a whole, so scoping it out by crop
    /// would discard a rate that was never claimed for any crop in particular.
    private static func includes(_ use: ChemicalRegisteredUse, scope: UseScope) -> Bool {
        switch scope {
        case .allCrops:
            return true
        case .vineyardOnly:
            return ChemicalManualEntry.isProductRateCarrier(use) || use.isViticultural
        }
    }

    private static func selectable(
        _ rate: ChemicalLabelRate,
        use: ChemicalRegisteredUse,
        chemical: SavedChemical
    ) -> SpraySelectableRate {
        let basis = sprayBasis(for: rate.basis)
        let seed = self.seed(for: rate, chemical: chemical, hasBasis: basis != nil)
        // Built from explicit locals rather than one inline literal: the
        // optional-to-String conversions defeat the type checker when inlined.
        let singleValue: String = rate.value.map { String($0) } ?? ""
        let minimumValue: String = rate.minValue.map { String($0) } ?? ""
        let maximumValue: String = rate.maxValue.map { String($0) } ?? ""
        var parts: [String] = ["use"]
        parts.append(use.crop)
        parts.append(use.targetRaw)
        parts.append(rate.label)
        parts.append(rate.basis.rawValue)
        parts.append(rate.unit)
        parts.append(singleValue)
        parts.append(minimumValue)
        parts.append(maximumValue)
        let id = stableIdentifier(parts.joined(separator: "|"))
        return SpraySelectableRate(
            id: id,
            origin: .registeredUse,
            crop: use.crop,
            targetRaw: use.targetRaw,
            label: rate.label,
            basis: basis,
            seed: seed,
            displayText: rate.displayRate
        )
    }

    /// Maps a LABEL rate basis onto the spray-side basis it may be applied on.
    ///
    /// `.other` maps to nothing on purpose: an unusual basis (per vine, per
    /// tonne) is preserved and displayed, but VineTrack will not pretend it is
    /// a per-hectare or per-100 L rate.
    private static func sprayBasis(for basis: ChemicalLabelRateBasis) -> ChemicalRateBasis? {
        switch basis {
        case .perHectare, .rangePerHectare: return .perHectare
        case .per100Litres, .rangePer100Litres: return .per100Litres
        case .other: return nil
        }
    }

    private static func seed(
        for rate: ChemicalLabelRate,
        chemical: SavedChemical,
        hasBasis: Bool
    ) -> SprayRateSeed {
        guard hasBasis else { return .referenceOnly }
        // A band stays a band. Converting both ends keeps the range meaningful
        // in the operator's own units without ever choosing a point inside it.
        if let minimum = rate.minValue, let maximum = rate.maxValue {
            guard let low = baseValue(minimum, labelUnit: rate.unit, chemical: chemical),
                  let high = baseValue(maximum, labelUnit: rate.unit, chemical: chemical)
            else { return .unresolved }
            return .range(minimum: low, maximum: high)
        }
        // A single-ended band is still a band, not a rate.
        if rate.minValue != nil || rate.maxValue != nil, rate.value == nil {
            return .unresolved
        }
        guard let value = rate.value,
              let base = baseValue(value, labelUnit: rate.unit, chemical: chemical)
        else { return .unresolved }
        return .value(base)
    }

    /// Converts a label value into the chemical's base units (mL or g).
    ///
    /// Fails closed on anything it cannot convert with certainty: an unknown
    /// unit, or a unit whose dimension disagrees with the product's (a litre
    /// rate on a granule). Guessing here would silently mis-dose by 1000×.
    static func baseValue(
        _ value: Double,
        labelUnit: String,
        chemical: SavedChemical
    ) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        let unit = labelUnit
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isLiquidProduct = chemical.unit.baseLabel == "mL"

        switch unit {
        case "ml", "millilitre", "millilitres", "milliliter", "milliliters":
            return isLiquidProduct ? value : nil
        case "l", "litre", "litres", "liter", "liters":
            return isLiquidProduct ? value * 1000 : nil
        case "g", "gram", "grams":
            return isLiquidProduct ? nil : value
        case "kg", "kilogram", "kilograms":
            return isLiquidProduct ? nil : value * 1000
        default:
            return nil
        }
    }

    // MARK: - Legacy fallback

    /// The legacy `rates` array, presented through the same shape.
    ///
    /// Values are already stored in base units, so they pass straight through.
    static func legacyRates(for chemical: SavedChemical) -> [SpraySelectableRate] {
        chemical.rates.map { rate in
            let display = "\(SprayRateFormatter.format(chemical.unit.fromBase(rate.value))) "
                + "\(chemical.unit.rawValue)\(rate.basis == .perHectare ? "/ha" : "/100 L")"
            return SpraySelectableRate(
                id: rate.id,
                origin: .legacy,
                crop: nil,
                targetRaw: nil,
                label: rate.label,
                basis: rate.basis,
                seed: rate.value.isFinite && rate.value > 0 ? .value(rate.value) : .unresolved,
                displayText: display
            )
        }
    }

    // MARK: - Stable identity

    /// A deterministic id for a structured rate.
    ///
    /// Structured rates have no stored identifier, but a product line persists
    /// `selectedRateId`. Deriving the id from the rate's own content keeps a
    /// selection pointing at the same rate across redraws and app launches,
    /// and makes it fall away naturally if the label rate itself changes.
    private static func stableIdentifier(_ seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

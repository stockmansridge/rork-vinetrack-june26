import Foundation

/// An exact vineyard-defined operational preference, never registered label evidence.
nonisolated struct VineyardPreferredRate: Codable, Sendable, Hashable {
    var amount: Double
    var unit: String
    var basis: ChemicalRateBasis
    var note: String? = nil
    var updatedAt: String? = nil
    var updatedBy: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case amount, unit, basis, note
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
    }
    var isValid: Bool { amount.isFinite && amount > 0 && ["L", "mL", "kg", "g"].contains(unit) }
    var chemicalUnit: ChemicalUnit {
        switch unit { case "mL": return .millilitres; case "kg": return .kilograms; case "g": return .grams; default: return .litres }
    }
    var text: String { "\(amount.formatted(.number.precision(.fractionLength(0...6)))) \(unit)\(basis == .per100Litres ? "/100 L" : "/ha")" }
}

/// Shared operational priority. Lower tiers retain the existing registered selection workflow.
nonisolated enum OperationalRateResolver {
    enum Source: String, Codable, Sendable { case programStep, vineyardPreferred, confirmedDefault, operatorPlanning }
    struct Selection: Sendable, Equatable {
        let rate: VineyardPreferredRate
        let source: Source
        func sourceText(vineyard: String) -> String {
            switch source { case .programStep: return "Program Step rate"; case .vineyardPreferred: return "\(vineyard) preferred rate"; case .confirmedDefault: return "Confirmed/default rate"; case .operatorPlanning: return "Operator-entered rate" }
        }
    }
    static func rateFromProgram(_ product: SprayChemical) -> VineyardPreferredRate? {
        guard product.reportedRateBaseValue.isFinite, product.reportedRateBaseValue > 0 else { return nil }
        return VineyardPreferredRate(amount: product.displayReportedRate, unit: product.unit == .litres ? "L" : product.unit == .kilograms ? "kg" : product.unit.rawValue, basis: product.reportedRateBasis == .per100Litres ? .per100Litres : .perHectare)
    }
    static func resolve(program: VineyardPreferredRate? = nil, chemical: SavedChemical) -> Selection? {
        if let program, program.isValid { return Selection(rate: program, source: .programStep) }
        if let preferred = chemical.vineyardPreferredRate, preferred.isValid { return Selection(rate: preferred, source: .vineyardPreferred) }
        if let confirmed = ChemicalSprayRateHandoff.prefill(chemical.defaultRates) {
            let rate = VineyardPreferredRate(amount: confirmed.rate, unit: confirmed.unit, basis: confirmed.basis == .per100Litres ? .per100Litres : .perHectare)
            if rate.isValid { return Selection(rate: rate, source: .confirmedDefault) }
        }
        return nil
    }
    /// Compare exact linked catalogue options without copying or changing them.
    static func warning(_ rate: VineyardPreferredRate, revision: CatalogueWire) -> String? {
        guard rate.isValid else { return nil }
        let key = rate.basis.rawValue
        let bounds: [ClosedRange<Double>] = revision.rateRows(key).compactMap { row in
            guard let raw = row.text("unit")?.split(separator: "/").first,
                  let unit = ChemicalDefaultRateValidity.canonicalUnit(String(raw)),
                  ["L", "mL", "kg", "g"].contains(unit) else { return nil }
            let other = VineyardPreferredRate(amount: 1, unit: unit, basis: rate.basis).chemicalUnit
            guard other.isDimensionallyCompatible(with: rate.chemicalUnit),
                  let low = row.number("value") ?? row.number("min_value"),
                  let high = row.number("value") ?? row.number("max_value"),
                  low.isFinite, high.isFinite, low > 0, high >= low else { return nil }
            return other.toBase(low)...other.toBase(high)
        }
        guard !bounds.isEmpty, !bounds.contains(where: { $0.contains(rate.chemicalUnit.toBase(rate.amount)) }) else { return nil }
        return "Outside the recorded registered grapevine rates on this basis. Check the applicable label directions. This operational rate has not been changed."
    }

    /// Compare only usable registered grapevine options with the same basis and physical dimension.
    static func warning(_ rate: VineyardPreferredRate, chemical: SavedChemical) -> String? {
        guard rate.isValid, rate.chemicalUnit.isDimensionallyCompatible(with: chemical.unit) else { return nil }
        let value = rate.chemicalUnit.toBase(rate.amount)
        let options = SprayRegisteredUseRates.vineyardRates(for: chemical).filter { $0.origin == .registeredUse && $0.basis == rate.basis }
        let bounds: [ClosedRange<Double>] = options.compactMap {
            switch $0.seed { case .value(let v): return v...v; case .range(let min, let max): return min...max; default: return nil }
        }
        guard !bounds.isEmpty, !bounds.contains(where: { $0.contains(value) }) else { return nil }
        return "Outside the recorded registered grapevine rates on this basis. Check the applicable label directions. This operational rate has not been changed."
    }
}

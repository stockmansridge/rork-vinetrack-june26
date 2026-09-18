import Foundation

/// Canonicalises structured label rates without guessing across contradictory bases.
nonisolated enum ChemicalLabelRateNormalizer {
    private static let textPattern = try! NSRegularExpression(
        pattern: #"^\s*([0-9]+(?:[.,][0-9]+)?)(?:\s*[-–—]\s*([0-9]+(?:[.,][0-9]+)?))?\s*(mL|L|kg|g)\s*/\s*(100\s*L|ha)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let unitPattern = try! NSRegularExpression(
        pattern: #"^\s*(mL|L|kg|g)(?:\s*/\s*(100\s*L|ha))?\s*$"#,
        options: [.caseInsensitive]
    )

    static func canonicalBareUnit(_ raw: String?) -> String? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "l": return "L"
        case "ml": return "mL"
        case "kg": return "kg"
        case "g": return "g"
        default: return nil
        }
    }

    static func parse(_ text: String) -> ChemicalLabelRate? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = textPattern.firstMatch(in: text, range: range), match.range == range else { return nil }
        func group(_ index: Int) -> String? {
            let r = match.range(at: index)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let lowText = group(1), let low = Double(lowText.replacingOccurrences(of: ",", with: ".")), low.isFinite, low > 0,
              let unit = canonicalBareUnit(group(3)), let denominator = group(4) else { return nil }
        let high = group(2).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        if let high, (!high.isFinite || high < low) { return nil }
        let isPer100 = denominator.replacingOccurrences(of: " ", with: "").lowercased() == "100l"
        let basis: ChemicalLabelRateBasis = if high != nil {
            isPer100 ? .rangePer100Litres : .rangePerHectare
        } else {
            isPer100 ? .per100Litres : .perHectare
        }
        return ChemicalLabelRate(
            basis: basis, value: high == nil ? low : nil,
            minValue: high == nil ? nil : low, maxValue: high,
            unit: unit, rawText: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func normalize(_ rate: ChemicalLabelRate) -> ChemicalLabelRate? {
        if rate.basis == .other {
            guard var parsed = rate.rawText.flatMap(parse) else { return rate }
            parsed.label = rate.label; parsed.rateId = rate.rateId
            parsed.conditionIsAmbiguous = rate.conditionIsAmbiguous
            return parsed
        }
        let ns = rate.unit as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = unitPattern.firstMatch(in: rate.unit, range: full), match.range == full else { return nil }
        let numerator = ns.substring(with: match.range(at: 1))
        guard let unit = canonicalBareUnit(numerator) else { return nil }
        let denominatorRange = match.range(at: 2)
        if denominatorRange.location != NSNotFound {
            let denominator = ns.substring(with: denominatorRange).replacingOccurrences(of: " ", with: "")
            if (denominator.lowercased() == "100l") != rate.basis.isVolumeBased { return nil }
        }
        if let parsed = rate.rawText.flatMap(parse) {
            guard parsed.basis.isVolumeBased == rate.basis.isVolumeBased, parsed.unit == unit else { return nil }
            if let low = parsed.minValue {
                let agrees = (rate.minValue == nil && rate.maxValue == nil && rate.value == low)
                    || (rate.value == nil && rate.minValue == low && rate.maxValue == parsed.maxValue)
                guard agrees else { return nil }
                var result = rate
                result.basis = parsed.basis; result.value = nil
                result.minValue = low; result.maxValue = parsed.maxValue; result.unit = unit
                return result
            }
            guard rate.basis != .rangePerHectare, rate.basis != .rangePer100Litres,
                  rate.value == parsed.value else { return nil }
        }
        var result = rate
        result.unit = unit
        switch rate.basis {
        case .perHectare, .per100Litres:
            guard let value = rate.value, value.isFinite, value > 0, rate.minValue == nil, rate.maxValue == nil else { return nil }
        case .rangePerHectare, .rangePer100Litres:
            guard rate.value == nil, let low = rate.minValue, let high = rate.maxValue,
                  low.isFinite, high.isFinite, low > 0, high >= low else { return nil }
        case .other: break
        }
        return result
    }

    static func normalize(_ intelligence: ChemicalIntelligence) -> ChemicalIntelligence? {
        var result = intelligence
        var uses: [ChemicalRegisteredUse] = []
        for var use in intelligence.registeredUses {
            var rates: [ChemicalLabelRate] = []
            for rate in use.rates {
                guard let normalized = normalize(rate) else { return nil }
                rates.append(normalized)
            }
            use.rates = rates
            uses.append(use)
        }
        result.registeredUses = uses
        return result
    }
}

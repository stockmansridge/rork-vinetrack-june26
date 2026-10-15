import Foundation

/// A trailing decimal separator is an unfinished editor draft, not a committed quantity.
nonisolated enum SprayEditingNumber {
    static func completeValue(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasSuffix("."), !trimmed.hasSuffix(",") else { return nil }
        return SprayControllerRateEntry.parse(trimmed)
    }
}

/// Re-expresses a complete group atomically; partial text stays bound to its original units.
nonisolated enum SprayPlanningDraftTransition {
    struct Result {
        let tank: String
        let area: String
        let rate: String
    }

    static func convert(tank: String, area: String, rate: String,
                        from old: RegionFormatter, to new: RegionFormatter,
                        basis: SprayCarrierBasis) -> Result? {
        func converted(_ text: String, inverse: (Double) -> Double, forward: (Double) -> Double) -> String? {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            guard let number = SprayEditingNumber.completeValue(text), number > 0 else { return nil }
            let value = forward(inverse(number))
            guard value.isFinite, value > 0 else { return nil }
            return String(value)
        }
        guard let tank = converted(tank, inverse: old.volumeToCanonical, forward: new.volumeValue),
              let area = converted(area, inverse: old.areaToCanonical, forward: new.areaValue),
              let rate = converted(rate,
                inverse: basis == .litresPer100Metres ? old.volumePer100LengthToCanonical : old.volumePerAreaToCanonical,
                forward: basis == .litresPer100Metres ? new.volumePer100LengthValue : new.volumePerAreaValue)
        else { return nil }
        return Result(tank: tank, area: area, rate: rate)
    }
}

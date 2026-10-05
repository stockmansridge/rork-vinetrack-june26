import Foundation

/// Explicit planning basis. Missing saved values remain legacy snapshots.
nonisolated enum FertiliserVineCounts {
    static let actual = "actual"
    static let assumedFull = "assumed_full"
    static let manual = "manual"

    static func label(_ basis: String?) -> String {
        switch basis {
        case actual: "Actual"
        case assumedFull: "Assumed full"
        case manual: "Manual"
        default: "Legacy (basis not recorded)"
        }
    }

    /// Never substitutes a geometry-only estimate for an unavailable Actual count.
    static func count(_ block: Paddock, basis: String) -> Int? {
        switch basis {
        case actual:
            if let count = block.vineCountOverride, count > 0 { return count }
            guard block.rows.contains(where: { PaddockRowVineCount.sanitiseOverride($0.vineCountOverride) != nil }) else { return nil }
            var total = 0
            for row in block.rows {
                let override = PaddockRowVineCount.sanitiseOverride(row.vineCountOverride)
                guard override != nil || block.vineSpacingIsKnown != false else { return nil }
                guard let count = block.effectiveVineCount(for: row) else { return nil }
                let addition = total.addingReportingOverflow(count)
                guard !addition.overflow, addition.partialValue <= Int(Int32.max) else { return nil }
                total = addition.partialValue
            }
            return total > 0 ? total : nil
        case assumedFull:
            let spacing = block.vineSpacing
            let length = block.effectiveTotalRowLength
            guard block.vineSpacingIsKnown != false, spacing.isFinite, spacing > 0, length.isFinite, length > 0 else { return nil }
            if block.rowLengthOverride == nil {
                guard !block.rows.isEmpty, block.rows.allSatisfy({
                    let length = block.rowLengthMetres($0)
                    return length.isFinite && length > 0
                }) else { return nil }
            }
            let count = length / spacing
            guard count.isFinite, count >= 1, count < Double(Int32.max) else { return nil }
            return Int(count)
        default: return nil
        }
    }

    /// Every selected block must resolve; partial totals are never presented.
    static func total(_ blocks: [Paddock], basis: String) -> Int? {
        guard !blocks.isEmpty else { return nil }
        var total = 0
        for block in blocks {
            guard let count = count(block, basis: basis) else { return nil }
            let addition = total.addingReportingOverflow(count)
            guard !addition.overflow, addition.partialValue <= Int(Int32.max) else { return nil }
            total = addition.partialValue
        }
        return total > 0 ? total : nil
    }

    /// Last allocation absorbs floating-point residuals; stored product is not rounded.
    static func shares(total: Double, weights: [Double]) -> [Double] {
        let sum = weights.reduce(0, +)
        guard sum.isFinite, sum > 0, weights.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return [] }
        var allocated = 0.0
        return weights.enumerated().map { index, weight in
            let value = index == weights.count - 1 ? total - allocated : total * weight / sum
            allocated += value
            return value
        }
    }
}

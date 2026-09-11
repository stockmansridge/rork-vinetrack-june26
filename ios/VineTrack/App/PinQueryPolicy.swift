import Foundation

nonisolated enum PinCategoryFilter: String, CaseIterable, Hashable, Sendable {
    case repairs
    case growth
    case manualIssues

    var label: String {
        switch self {
        case .repairs: return "Repairs"
        case .growth: return "Growth"
        case .manualIssues: return "Manual Issues"
        }
    }
}

nonisolated struct PinQueryFilter: Sendable {
    var categories: Set<PinCategoryFilter> = Set(PinCategoryFilter.allCases)
    var includesELStages: Bool = false
    var selectedELStageCodes: Set<String> = []
    var completion: PinCompletionFilter = .notDone

    func matches(_ pin: VinePin) -> Bool {
        let stageCode = PinQueryPolicy.normalizedELCode(pin.growthStageCode)
        if let stageCode {
            guard includesELStages else { return false }
            if !selectedELStageCodes.isEmpty, !selectedELStageCodes.contains(stageCode) { return false }
        } else {
            let category: PinCategoryFilter
            switch pin.mode {
            case .repairs: category = .repairs
            case .growth: category = .growth
            case .manualIssue: category = .manualIssues
            }
            guard categories.contains(category) else { return false }
        }
        switch completion {
        case .notDone: return !pin.isCompleted
        case .done: return pin.isCompleted
        case .both: return true
        }
    }
}

nonisolated enum PinQueryPolicy {
    static func normalizedELCode(_ value: String?) -> String? {
        guard let code = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !code.isEmpty,
              GrowthStage.allStages.contains(where: { $0.code == code }) else { return nil }
        return code
    }

    static func usableRow(_ pin: VinePin) -> Double? {
        if let row = pin.pinRowNumber { return Double(row) }
        return pin.rowSegments?.map(\.row).min().map(Double.init)
    }

    static func nearestRowOrdered(_ pins: [VinePin], currentRow: Double) -> [VinePin] {
        pins.enumerated().sorted { lhs, rhs in
            switch (usableRow(lhs.element), usableRow(rhs.element)) {
            case let (left?, right?):
                let leftDistance = abs(left - currentRow)
                let rightDistance = abs(right - currentRow)
                return leftDistance == rightDistance ? lhs.offset < rhs.offset : leftDistance < rightDistance
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    static func qualifiedTravelContext(
        row: Double?,
        isRowQualified: Bool,
        heading: Double?,
        isHeadingQualified: Bool
    ) -> (row: Double, heading: Double?)? {
        guard isRowQualified, let row, row.isFinite else { return nil }
        let validHeading = heading.flatMap { value in
            isHeadingQualified && value.isFinite && value >= 0 && value < 360 ? value : nil
        }
        return (row, validHeading)
    }

    static func rowOrdered(_ pins: [VinePin], blockNames: [UUID: String]) -> [VinePin] {
        pins.enumerated().sorted { lhs, rhs in
            let leftBlock = lhs.element.paddockId.flatMap { blockNames[$0] }?.localizedStandardCompare(
                rhs.element.paddockId.flatMap { blockNames[$0] } ?? "\u{10FFFF}"
            ) ?? .orderedDescending
            if leftBlock != .orderedSame { return leftBlock == .orderedAscending }
            switch (usableRow(lhs.element), usableRow(rhs.element)) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

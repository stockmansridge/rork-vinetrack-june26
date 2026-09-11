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

    func matches(_ pin: VinePin, isELRecord: Bool? = nil) -> Bool {
        let hasAuthoritativeELIdentity = isELRecord ?? (pin.growthStageCode != nil)
        if hasAuthoritativeELIdentity {
            guard includesELStages else { return false }
            guard let stageCode = PinQueryPolicy.normalizedELCode(pin.growthStageCode) else {
                guard selectedELStageCodes.isEmpty else { return false }
                return completionMatches(pin)
            }
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
        return completionMatches(pin)
    }

    private func completionMatches(_ pin: VinePin) -> Bool {
        switch completion {
        case .notDone: return !pin.isCompleted
        case .done: return pin.isCompleted
        case .both: return true
        }
    }
}

nonisolated enum PinQueryPolicy {
    static func categories(for selection: PinCategoryFilter?) -> Set<PinCategoryFilter> {
        selection.map { [$0] } ?? Set(PinCategoryFilter.allCases)
    }

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

    /// Issue/Growth names backed by ordinary pin records. Authoritative E-L
    /// records are excluded by identity, never by customer-editable title text.
    static func ordinaryFilterNames(
        _ pins: [VinePin],
        authoritativeELPinIds: Set<UUID>
    ) -> [String] {
        Array(Set(pins.compactMap { pin in
            guard pin.growthStageCode == nil,
                  !authoritativeELPinIds.contains(pin.id) else { return nil }
            let name = pin.buttonName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        })).sorted()
    }

    static func cleanedNameSelection(_ selection: Set<String>, availableNames: [String]) -> Set<String> {
        selection.intersection(Set(availableNames))
    }

    static func nearestRowOrdered(
        _ pins: [VinePin],
        currentRow: Double,
        currentVineyardId: UUID,
        currentBlockId: UUID,
        blockNames: [UUID: String]
    ) -> [VinePin] {
        let indexed = pins.enumerated()
        let currentBlock = indexed.filter {
            $0.element.vineyardId == currentVineyardId && $0.element.paddockId == currentBlockId
        }.sorted { lhs, rhs in
            switch (usableRow(lhs.element), usableRow(rhs.element)) {
            case let (left?, right?):
                let leftDistance = abs(left - currentRow)
                let rightDistance = abs(right - currentRow)
                return leftDistance == rightDistance ? lhs.offset < rhs.offset : leftDistance < rightDistance
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }
        let otherBlocks = indexed.filter {
            !($0.element.vineyardId == currentVineyardId && $0.element.paddockId == currentBlockId)
        }.sorted { lhs, rhs in
            if lhs.element.vineyardId != rhs.element.vineyardId {
                return lhs.element.vineyardId.uuidString < rhs.element.vineyardId.uuidString
            }
            let leftName = lhs.element.paddockId.flatMap { blockNames[$0] } ?? "\u{10FFFF}"
            let rightName = rhs.element.paddockId.flatMap { blockNames[$0] } ?? "\u{10FFFF}"
            let blockComparison = leftName.localizedStandardCompare(rightName)
            if blockComparison != .orderedSame { return blockComparison == .orderedAscending }
            switch (usableRow(lhs.element), usableRow(rhs.element)) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }
        return (currentBlock + otherBlocks).map(\.element)
    }

    struct TravelContext: Equatable, Sendable {
        let vineyardId: UUID
        let blockId: UUID
        let row: Double
        let heading: Double?
        let isEstimated: Bool

        init(vineyardId: UUID, blockId: UUID, row: Double, heading: Double?, isEstimated: Bool = false) {
            self.vineyardId = vineyardId
            self.blockId = blockId
            self.row = row
            self.heading = heading
            self.isEstimated = isEstimated
        }
    }

    /// Heading qualification is intentionally independent from row resolution:
    /// losing mapped aisle evidence must not erase a fresh valid compass sample.
    static func qualifiedHeading(_ heading: Double?, isQualified: Bool) -> Double? {
        heading.flatMap { value in
            isQualified && value.isFinite && value >= 0 && value < 360 ? value : nil
        }
    }

    static func qualifiedTravelContext(
        selectedVineyardId: UUID?,
        contextVineyardId: UUID?,
        blockId: UUID?,
        row: Double?,
        isRowQualified: Bool,
        rowConfirmedAt: Date?,
        locationObservedAt: Date?,
        heading: Double?,
        isHeadingQualified: Bool,
        now: Date = Date(),
        freshness: TimeInterval = 10
    ) -> TravelContext? {
        guard let selectedVineyardId,
              contextVineyardId == selectedVineyardId,
              let blockId,
              isRowQualified,
              let row,
              row.isFinite,
              let rowConfirmedAt,
              now.timeIntervalSince(rowConfirmedAt) >= 0,
              now.timeIntervalSince(rowConfirmedAt) <= freshness,
              let locationObservedAt,
              now.timeIntervalSince(locationObservedAt) >= 0,
              now.timeIntervalSince(locationObservedAt) <= freshness else { return nil }
        let validHeading = qualifiedHeading(heading, isQualified: isHeadingQualified)
        return TravelContext(vineyardId: selectedVineyardId, blockId: blockId, row: row, heading: validHeading)
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

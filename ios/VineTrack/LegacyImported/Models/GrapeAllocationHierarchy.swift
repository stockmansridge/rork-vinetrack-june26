import Foundation

/// Read-only block attribution. Deliberately separate from financial block splitting.
nonisolated enum GrapeAllocationHierarchy {
    struct Estimate: Sendable {
        let paddockId: UUID
        let varietyName: String
        let tonnes: Double?
    }

    struct BlockRow: Identifiable, Sendable {
        var id: String { paddockId?.uuidString ?? "no-block" }
        let paddockId: UUID?
        let name: String
        var estimatedTonnes: Double?
        var ownUseTonnes: Double = 0
        var externalTonnes: Double = 0
        var allocationIds: [UUID] = []
        var hasUnspecifiedQuantity: Bool = false
        var allocatedTonnes: Double { ownUseTonnes + externalTonnes }
        var balanceTonnes: Double? { estimatedTonnes.map { $0 - allocatedTonnes } }
    }

    static func estimates(_ projection: SeasonYieldProjection.Result?) -> [Estimate] {
        guard let projection else { return [] }
        return projection.blocks.flatMap { block in
            block.groups.map { group in
                Estimate(paddockId: block.paddockId, varietyName: group.displayName,
                         tonnes: group.isEstimateAvailable ? (projection.damageApplied ? group.adjustedTonnes : group.baseTonnes) : nil)
            }
        }
    }

    /// Unknown estimates remain unknown, and duplicate links are merged by block UUID.
    /// A signed residual preserves reconciliation even for legacy over-assigned records.
    static func rows(varietyKey: String, vineyardId: UUID, vintage: Int,
                     allocations: [GrapeAllocation], estimates: [Estimate],
                     blockNames: [UUID: String]) -> [BlockRow] {
        var rows: [String: BlockRow] = [:]
        func ensure(_ id: UUID?) -> String {
            let key = id?.uuidString ?? "no-block"
            if rows[key] == nil {
                rows[key] = BlockRow(paddockId: id,
                    name: id.map { blockNames[$0] ?? "Unknown block" } ?? "No block specified",
                    estimatedTonnes: nil)
            }
            return key
        }
        var seenEstimates: Set<UUID> = []
        for estimate in estimates where PickingYieldAggregator.normalisedVariety(estimate.varietyName) == varietyKey {
            let key = ensure(estimate.paddockId)
            if seenEstimates.insert(estimate.paddockId).inserted {
                rows[key]?.estimatedTonnes = estimate.tonnes
            } else if let previous = rows[key]?.estimatedTonnes, let tonnes = estimate.tonnes {
                rows[key]?.estimatedTonnes = previous + tonnes
            } else {
                rows[key]?.estimatedTonnes = nil
            }
        }
        func add(_ id: UUID?, _ allocation: GrapeAllocation, _ tonnes: Double, unspecified: Bool = false) {
            let key = ensure(id)
            if allocation.allocationType == .ownUse { rows[key]?.ownUseTonnes += tonnes }
            else { rows[key]?.externalTonnes += tonnes }
            if rows[key]?.allocationIds.contains(allocation.id) == false { rows[key]?.allocationIds.append(allocation.id) }
            if unspecified { rows[key]?.hasUnspecifiedQuantity = true }
        }
        for allocation in allocations where allocation.vineyardId == vineyardId && allocation.vintage == vintage && PickingYieldAggregator.normalisedVariety(allocation.varietyName) == varietyKey {
            let links = Dictionary(grouping: allocation.blocks, by: \.paddockId)
            var assigned: Double = 0
            for (id, details) in links {
                let quantities = details.compactMap { $0.quantityTonnes }.filter(\.isFinite)
                let tonnes: Double? = quantities.isEmpty ? (links.count == 1 ? allocation.quantityTonnes : nil) : quantities.reduce(0, +)
                add(id, allocation, tonnes ?? 0, unspecified: tonnes == nil)
                assigned += tonnes ?? 0
            }
            let remainder = allocation.quantityTonnes - assigned
            if remainder != 0 || links.isEmpty { add(nil, allocation, remainder) }
        }
        return rows.values.sorted {
            if ($0.paddockId == nil) != ($1.paddockId == nil) { return $0.paddockId != nil }
            if $0.name == $1.name { return $0.id < $1.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

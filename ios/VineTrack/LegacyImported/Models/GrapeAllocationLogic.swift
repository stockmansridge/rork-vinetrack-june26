import Foundation

/// Grape Allocation derivations, shared contract with Android
/// (`GrapeAllocationCalculator.kt`) so both platforms pin the same rules:
///
///  * Supply comes from the CURRENT Yield Estimate — `YieldVintageReport`'s
///    latest-completed-trip rows — never from a second stored source, so a
///    newly completed Bunch Count Trip automatically moves every balance.
///  * A block-level estimate is split across the block's variety
///    allocations by percent share (the `varietyArea` share rule).
///  * Balance = Estimated − Own Use − External; a NEGATIVE balance is a
///    Shortfall, never clamped.
///  * Money: every contract's value is tonnes × THAT contract's $/t, and
///    totals are sums of individual contract values — an averaged $/t is
///    never used.
nonisolated enum GrapeAllocationCalculator {

    /// Tolerance below which a negative balance is treated as zero (guards
    /// floating-point noise, not real shortfalls).
    static let shortfallTolerance: Double = 0.0005

    // MARK: - Supply (from the latest Yield Estimate)

    /// Estimated tonnes per canonical variety for the vintage. Each block's
    /// latest-trip estimate (`displayTonnes` — damage-respecting) is split
    /// across the block's named variety allocations by percent share.
    /// Blocks with no named variety fall under "Unspecified".
    static func varietyEstimates(
        estimateRows: [YieldVintageReport.EstimateRow],
        paddocks: [Paddock]
    ) -> [String: (displayName: String, tonnes: Double)] {
        let paddockById = Dictionary(paddocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [String: (displayName: String, tonnes: Double)] = [:]

        func add(_ name: String, _ tonnes: Double) {
            let key = PickingYieldAggregator.normalisedVariety(name)
            let existing = result[key]
            result[key] = (existing?.displayName ?? name, (existing?.tonnes ?? 0) + tonnes)
        }

        for row in estimateRows {
            let allocations = (paddockById[row.paddockId]?.varietyAllocations ?? [])
                .filter { !($0.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            guard !allocations.isEmpty else {
                add("Unspecified", row.displayTonnes)
                continue
            }
            let totalPct = allocations.reduce(0.0) { $0 + $1.percent }
            for allocation in allocations {
                let share = totalPct > 0
                    ? allocation.percent / totalPct
                    : 1.0 / Double(allocations.count)
                add(allocation.name ?? "", row.displayTonnes * share)
            }
        }
        return result
    }

    // MARK: - Variety cards

    nonisolated struct VarietyRow: Identifiable, Sendable, Equatable {
        var id: String { varietyKey }
        /// Canonical (normalised) variety identity used for matching.
        let varietyKey: String
        let displayName: String
        let estimatedTonnes: Double
        let ownUseTonnes: Double
        let externalTonnes: Double

        var balanceTonnes: Double { estimatedTonnes - ownUseTonnes - externalTonnes }
        var isShortfall: Bool { balanceTonnes < -GrapeAllocationCalculator.shortfallTolerance }
    }

    /// One row per variety that has an estimate OR an allocation in the
    /// vintage, sorted by estimated tonnes descending then name.
    static func varietyRows(
        estimates: [String: (displayName: String, tonnes: Double)],
        allocations: [GrapeAllocation],
        vintage: Int
    ) -> [VarietyRow] {
        var names: [String: String] = [:]
        var own: [String: Double] = [:]
        var external: [String: Double] = [:]

        for (key, value) in estimates { names[key] = value.displayName }
        for allocation in allocations where allocation.vintage == vintage {
            let key = PickingYieldAggregator.normalisedVariety(allocation.varietyName)
            if names[key] == nil { names[key] = allocation.varietyName }
            switch allocation.allocationType {
            case .ownUse: own[key, default: 0] += allocation.quantityTonnes
            case .external: external[key, default: 0] += allocation.quantityTonnes
            }
        }

        return names.map { key, displayName in
            VarietyRow(
                varietyKey: key,
                displayName: displayName,
                estimatedTonnes: estimates[key]?.tonnes ?? 0,
                ownUseTonnes: own[key] ?? 0,
                externalTonnes: external[key] ?? 0
            )
        }
        .sorted {
            if $0.estimatedTonnes != $1.estimatedTonnes { return $0.estimatedTonnes > $1.estimatedTonnes }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Vintage summary

    nonisolated struct Summary: Sendable, Equatable {
        let estimatedTonnes: Double
        let ownUseTonnes: Double
        let committedTonnes: Double

        /// Positive = Available, negative = Shortfall.
        var balanceTonnes: Double { estimatedTonnes - ownUseTonnes - committedTonnes }
        var isShortfall: Bool { balanceTonnes < -GrapeAllocationCalculator.shortfallTolerance }
    }

    static func summary(
        estimates: [String: (displayName: String, tonnes: Double)],
        allocations: [GrapeAllocation],
        vintage: Int
    ) -> Summary {
        let inVintage = allocations.filter { $0.vintage == vintage }
        return Summary(
            estimatedTonnes: estimates.values.reduce(0.0) { $0 + $1.tonnes },
            ownUseTonnes: inVintage.filter { $0.allocationType == .ownUse }.reduce(0.0) { $0 + $1.quantityTonnes },
            committedTonnes: inVintage.filter { $0.allocationType == .external }.reduce(0.0) { $0 + $1.quantityTonnes }
        )
    }

    // MARK: - Contracted income (Owner/Manager only inputs)

    /// Vintage total contracted income: the SUM of individual contract
    /// values (tonnes × that contract's $/t). Contracts without a price
    /// contribute nothing.
    static func totalContractedIncome(allocations: [GrapeAllocation], vintage: Int) -> Double {
        allocations
            .filter { $0.vintage == vintage }
            .compactMap(\.contractValue)
            .reduce(0, +)
    }

    nonisolated struct IncomeLine: Identifiable, Sendable, Equatable {
        var id: String { label }
        let label: String
        let tonnes: Double
        let value: Double
    }

    /// Income grouped by purchaser, individual contract values summed.
    static func incomeByPurchaser(allocations: [GrapeAllocation], vintage: Int) -> [IncomeLine] {
        groupIncome(allocations: allocations, vintage: vintage) { allocation in
            let name = allocation.purchaserName?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? "Unnamed purchaser" : name
        }
    }

    /// Income grouped by variety, individual contract values summed.
    static func incomeByVariety(allocations: [GrapeAllocation], vintage: Int) -> [IncomeLine] {
        groupIncome(allocations: allocations, vintage: vintage) { $0.varietyName }
    }

    /// Income attributed to blocks. A contract's value is distributed across
    /// its assigned blocks proportionally by the block quantities when given
    /// (missing block quantities share the remaining tonnes equally);
    /// contracts with no block assignment land under "Unassigned".
    static func incomeByBlock(allocations: [GrapeAllocation], vintage: Int) -> [IncomeLine] {
        var tonnes: [String: Double] = [:]
        var values: [String: Double] = [:]

        for allocation in allocations where allocation.vintage == vintage {
            guard allocation.allocationType == .external, let price = allocation.pricePerTonne else { continue }
            let splits = blockTonnesSplit(allocation)
            for (label, splitTonnes) in splits {
                tonnes[label, default: 0] += splitTonnes
                values[label, default: 0] += splitTonnes * price
            }
        }

        return values
            .map { IncomeLine(label: $0.key, tonnes: tonnes[$0.key] ?? 0, value: $0.value) }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
    }

    /// Split of a contract's tonnes across its blocks: explicit block
    /// quantities are honoured; blocks without a quantity share whatever
    /// remains equally (never negative); no blocks = all "Unassigned".
    static func blockTonnesSplit(_ allocation: GrapeAllocation) -> [(label: String, tonnes: Double)] {
        guard !allocation.blocks.isEmpty else {
            return [("Unassigned", allocation.quantityTonnes)]
        }
        let specified = allocation.blocks.compactMap(\.quantityTonnes).reduce(0, +)
        let unspecified = allocation.blocks.filter { $0.quantityTonnes == nil }
        let remainder = max(0, allocation.quantityTonnes - specified)
        let perUnspecified = unspecified.isEmpty ? 0 : remainder / Double(unspecified.count)
        return allocation.blocks.map { block in
            let label = block.paddockName.isEmpty ? "Block" : block.paddockName
            return (label, block.quantityTonnes ?? perUnspecified)
        }
    }

    private static func groupIncome(
        allocations: [GrapeAllocation],
        vintage: Int,
        label: (GrapeAllocation) -> String
    ) -> [IncomeLine] {
        var tonnes: [String: Double] = [:]
        var values: [String: Double] = [:]
        for allocation in allocations where allocation.vintage == vintage {
            guard let value = allocation.contractValue else { continue }
            let key = label(allocation)
            tonnes[key, default: 0] += allocation.quantityTonnes
            values[key, default: 0] += value
        }
        return values
            .map { IncomeLine(label: $0.key, tonnes: tonnes[$0.key] ?? 0, value: $0.value) }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
    }
}

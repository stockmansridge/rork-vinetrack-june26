import Foundation

/// Derives `TripCostAllocation` rows for a single trip from a
/// `TripCostService.Result`. Keeps allocation logic in one place so the saved
/// breakdown matches the per-trip estimate users see in Trip Detail.
///
/// Allocation rules:
///   * Paddock allocation by `Paddock.areaHectares` (single paddock → 100%).
///   * Variety allocation by `Paddock.varietyAllocations` percentages; missing
///     varieties surface as an "Unassigned variety" row with a warning.
///   * Yield tonnes are sourced from `HistoricalYieldRecord.blockResults` and
///     attributed proportionally to each variety slice. If a paddock cannot be
///     matched the slice's yield/`costPerTonne` is left nil with a warning.
nonisolated enum TripCostAllocationCalculator {

    /// Build the saved allocation rows for `trip` from `result`. Returns an
    /// empty array when there is nothing usable to save.
    static func makeAllocations(
        trip: Trip,
        result: TripCostService.Result,
        paddocks: [Paddock],
        varieties: [GrapeVariety],
        historicalYieldRecords: [HistoricalYieldRecord],
        sourceTripUpdatedAt: Date? = nil,
        now: Date = Date()
    ) -> [TripCostAllocation] {
        let paddockIds: [UUID] = {
            if !trip.paddockIds.isEmpty { return trip.paddockIds }
            if let single = trip.paddockId { return [single] }
            return []
        }()
        guard !paddockIds.isEmpty else { return [] }

        let linkedPaddocks: [Paddock] = paddockIds.compactMap { id in
            paddocks.first { $0.id == id }
        }
        guard !linkedPaddocks.isEmpty else { return [] }

        let totalArea = linkedPaddocks.reduce(0.0) { $0 + max($1.areaHectares, 0) }

        let seasonYear = Calendar.current.component(.year, from: trip.startTime)

        let totalCost = result.totalCost
        let labourCost = result.labour.cost
        let fuelCost = result.fuel.cost
        let chemicalCost = result.chemical?.cost ?? 0
        let inputCost = result.seeding?.cost ?? 0

        var rows: [TripCostAllocation] = []

        for paddock in linkedPaddocks {
            let paddockArea = max(paddock.areaHectares, 0)
            let paddockFraction: Double = {
                if linkedPaddocks.count == 1 { return 1.0 }
                guard totalArea > 0 else {
                    return 1.0 / Double(linkedPaddocks.count)
                }
                return paddockArea / totalArea
            }()

            // Resolve variety shares for this paddock. Normalise percentages so
            // they always sum to 1.0 inside the paddock — handles both 0..1
            // and 0..100 inputs.
            let allocations = paddock.varietyAllocations.filter { $0.percent > 0 }
            let varietyShares: [(varietyId: UUID?, name: String?, fraction: Double, resolved: Bool)] = {
                guard !allocations.isEmpty else {
                    return [(nil, nil, 1.0, false)]
                }
                let sum = allocations.reduce(0.0) { $0 + $1.percent }
                guard sum > 0 else { return [(nil, nil, 1.0, false)] }
                return allocations.map { alloc in
                    let frac = alloc.percent / sum
                    let r = PaddockVarietyResolver.resolve(allocation: alloc, varieties: varieties)
                    #if DEBUG
                    print("[TripCostAllocation] paddock=\(paddock.name) alloc.varietyId=\(alloc.varietyId) alloc.name=\(alloc.name ?? "nil") -> id=\(r.varietyId?.uuidString ?? "nil") name=\(r.displayName ?? "nil") reason=\(r.reason)")
                    #endif
                    return (r.varietyId ?? alloc.varietyId, r.displayName, frac, r.isResolved)
                }
            }()

            // Paddock-level yield tonnes (sum from historical_yield_records).
            let paddockYield = resolvePaddockYieldTonnes(
                vineyardId: trip.vineyardId,
                paddockId: paddock.id,
                tripYear: seasonYear,
                records: historicalYieldRecords
            )

            for share in varietyShares {
                let sliceFraction = paddockFraction * share.fraction
                let sliceLabour = labourCost * sliceFraction
                let sliceFuel = fuelCost * sliceFraction
                let sliceChem = chemicalCost * sliceFraction
                let sliceInput = inputCost * sliceFraction
                let sliceTotal = totalCost * sliceFraction
                let sliceArea = paddockArea * share.fraction

                let sliceYield: Double? = {
                    guard let y = paddockYield, y > 0 else { return nil }
                    return y * share.fraction
                }()

                let costPerHa: Double? = {
                    guard sliceArea > 0, sliceTotal > 0 else { return nil }
                    return sliceTotal / sliceArea
                }()
                let costPerTonne: Double? = {
                    guard let y = sliceYield, y > 0, sliceTotal > 0 else { return nil }
                    return sliceTotal / y
                }()

                var warnings: [String] = []
                if sliceArea <= 0 {
                    warnings.append("Cost per ha unavailable — paddock area missing.")
                }
                if sliceYield == nil {
                    warnings.append("Cost per tonne unavailable — yield data missing.")
                }
                if !allocations.isEmpty && !share.resolved {
                    warnings.append("Variety unassigned — review block variety allocations.")
                }

                let basis: TripCostAllocationBasis = allocations.isEmpty ? .area : .varietyPercentage
                let status: TripCostAllocationStatus = {
                    switch result.completeness {
                    case .complete: return .complete
                    case .partial: return .partial
                    case .unavailable: return .unavailable
                    }
                }()

                let row = TripCostAllocation(
                    vineyardId: trip.vineyardId,
                    tripId: trip.id,
                    seasonYear: seasonYear,
                    tripFunction: trip.tripFunction,
                    paddockId: paddock.id,
                    paddockName: paddock.name,
                    variety: {
                        if let n = share.name, !n.isEmpty { return n }
                        // Only fall back to the "Unassigned variety" label when
                        // the paddock has allocations that the resolver could
                        // not resolve. Paddocks with no allocations at all keep
                        // a nil variety so the UI groups them under the empty
                        // bucket without the warning badge.
                        if !allocations.isEmpty { return "Unassigned variety" }
                        return nil
                    }(),
                    varietyId: share.varietyId,
                    varietyPercentage: share.fraction,
                    allocationAreaHa: sliceArea > 0 ? sliceArea : nil,
                    labourCost: sliceLabour,
                    fuelCost: sliceFuel,
                    chemicalCost: result.chemical == nil ? nil : sliceChem,
                    inputCost: result.seeding == nil ? nil : sliceInput,
                    totalCost: sliceTotal,
                    costPerHa: costPerHa,
                    yieldTonnes: sliceYield,
                    costPerTonne: costPerTonne,
                    allocationBasis: basis,
                    costingStatus: status,
                    warnings: warnings,
                    calculatedAt: now,
                    sourceTripUpdatedAt: sourceTripUpdatedAt ?? trip.endTime ?? trip.startTime
                )
                rows.append(row)
            }
        }
        return rows
    }

    /// Resolve actual yield tonnes for a single paddock. Mirrors
    /// `TripCostService.resolveYieldTonnes` but per-paddock so we can
    /// proportionally attribute yield to a variety slice. Returns nil when
    /// no reliable match exists — we never guess.
    static func resolvePaddockYieldTonnes(
        vineyardId: UUID,
        paddockId: UUID,
        tripYear: Int,
        records: [HistoricalYieldRecord]
    ) -> Double? {
        let scoped = records.filter { $0.vineyardId == vineyardId }
        guard !scoped.isEmpty else { return nil }
        let candidates: [(record: HistoricalYieldRecord, block: HistoricalBlockResult)] = scoped.flatMap { rec in
            rec.blockResults
                .filter { $0.paddockId == paddockId && $0.actualYieldTonnes != nil }
                .map { (rec, $0) }
        }
        guard !candidates.isEmpty else { return nil }
        let exact = candidates.first { $0.record.year == tripYear }
        let prior = candidates
            .filter { $0.record.year <= tripYear }
            .max { $0.record.year < $1.record.year }
        let mostRecent = candidates.max { $0.record.year < $1.record.year }
        let picked = exact ?? prior ?? mostRecent
        guard let t = picked?.block.actualYieldTonnes, t > 0 else { return nil }
        return t
    }
}

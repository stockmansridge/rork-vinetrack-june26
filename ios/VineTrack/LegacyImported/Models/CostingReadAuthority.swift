import Foundation

/// Read-only accounting boundaries. Never mutate the historical inputs.
nonisolated enum CostingReadAuthority {
    static func positive(_ area: Double?) -> Double? {
        area.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    @MainActor static func physicalArea(_ paddock: Paddock) -> Double? {
        positive(paddock.savedAreaHa) ?? positive(paddock.areaHectares)
    }

    @MainActor static func physicalArea(_ paddocks: [Paddock]) -> Double? {
        let unique = Dictionary(paddocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        guard !unique.isEmpty else { return nil }
        let areas = unique.compactMap { physicalArea($0) }
        return areas.count == unique.count ? areas.reduce(0, +) : nil
    }

    @MainActor static func taskArea(task: WorkTask, links: [WorkTaskPaddock], paddocks: [Paddock]) -> Double? {
        if let saved = positive(task.areaHa) { return saved }
        let linked = links.filter { $0.workTaskId == task.id && $0.vineyardId == task.vineyardId }
        let unique = Dictionary(linked.map { ($0.paddockId, $0) }, uniquingKeysWith: { first, _ in first })
        if !unique.isEmpty {
            let saved = unique.values.compactMap { positive($0.areaHa) }
            if saved.count == unique.count { return saved.reduce(0, +) }
        }
        let ids = unique.isEmpty ? Set(task.paddockId.map { [$0] } ?? []) : Set(unique.keys)
        guard !ids.isEmpty else { return nil }
        let blocks = paddocks.filter { ids.contains($0.id) && $0.vineyardId == task.vineyardId }
        guard Set(blocks.map(\.id)) == ids else { return nil }
        return physicalArea(blocks)
    }

    /// A marker and its slices represent the SAME labour, not two charges.
    /// Missing parents (including tombstoned Trips removed from the local store)
    /// cannot contribute. Allocation evidence itself is left untouched.
    static func allocations(_ rows: [TripCostAllocation], trips: [Trip]) -> [TripCostAllocation] {
        let parents = Dictionary(trips.map { ($0.id, $0.vineyardId) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<UUID> = []
        let live = rows.filter { $0.deletedAt == nil && parents[$0.tripId] == $0.vineyardId && seen.insert($0.id).inserted }
        return Dictionary(grouping: live, by: \.tripId).values.flatMap { group -> [TripCostAllocation] in
            let markers = group.filter { $0.allocationBasis == .labourSnapshot }
            let slices = group.filter { $0.allocationBasis != .labourSnapshot }
            guard let marker = markers.first else { return slices }
            guard !slices.isEmpty else { return markers }
            let labour = slices.reduce(0.0) { $0 + ($1.labourCost ?? 0) }
            let area = slices.reduce(0.0) { $0 + ($1.allocationAreaHa ?? 0) }
            return slices.map { original in
                var row = original
                let share = labour > 0 ? (original.labourCost ?? 0) / labour :
                    (area > 0 ? (original.allocationAreaHa ?? 0) / area : 1 / Double(slices.count))
                let snapshot = marker.totalCost ?? marker.labourCost
                row.labourCost = snapshot.map { $0 * share }
                row.totalCost = original.totalCost.flatMap { total in snapshot.map { total - (original.labourCost ?? 0) + $0 * share } }
                if marker.costingStatus == .partial || marker.costingStatus == .unavailable || markers.count != 1 { row.costingStatus = .partial }
                return row
            }
        }
    }

    static func distinctTrips(_ rows: [TripCostAllocation]) -> Int { Set(rows.map(\.tripId)).count }

    static func machineComplete(_ line: WorkTaskMachineLine) -> Bool {
        // An absent component is not zero: it is optional only if unconfigured.
        let machineOK = line.totalMachineCost?.isFinite ?? (line.hourlyMachineRate == nil)
        let fuelOK = line.fuelCost?.isFinite ?? (line.fuelLitres == nil || line.fuelLitres == 0)
        let hasEvidence = line.totalMachineCost != nil || line.fuelCost != nil
        return hasEvidence && machineOK && fuelOK
    }
}

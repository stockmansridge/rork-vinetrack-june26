import Foundation

/// One authoritative roll-up for every Work Task cost presentation.
/// Component engines retain their established semantics; this type only scopes
/// their saved inputs to one task and adds each authoritative source once.
nonisolated enum WorkTaskCostRollup {
    nonisolated struct Result: Equatable, Sendable {
        let labourCost: Decimal
        let manualMachineCost: Decimal
        let linkedTripCost: Decimal
        let materialCost: Decimal
        let totalCost: Decimal
        let isComplete: Bool

        func costPerHectare(areaHectares: Double) -> Decimal? {
            guard isComplete, areaHectares.isFinite, areaHectares > 0 else { return nil }
            return totalCost / WorkTaskCostRollup.decimal(areaHectares)
        }
    }

    static func resolve(
        task: WorkTask,
        labourLines: [WorkTaskLabourLine],
        machineLines: [WorkTaskMachineLine],
        trips: [Trip],
        tripCostAllocations: [TripCostAllocation],
        materials: [WorkTaskMaterial],
        includeMaterials: Bool
    ) -> Result {
        let taskLabourLines = labourLines.filter { $0.workTaskId == task.id }
        let labour: Double?
        let labourIsComplete: Bool
        if task.isPieceRate {
            labour = task.pieceRateCost
            labourIsComplete = labour != nil
        } else if taskLabourLines.isEmpty {
            labour = task.totalCost
            labourIsComplete = true
        } else {
            labour = WorkTaskLabourCosting.totalCost(taskLabourLines)
            labourIsComplete = taskLabourLines.allSatisfy { WorkTaskLabourCosting.lineCost($0) != nil }
        }

        let taskMachineLines = machineLines.filter { $0.workTaskId == task.id }
        // Preserve the established iOS contract: saved machine charge and saved
        // fuel are distinct values and both participate in the task total.
        let manualMachine = taskMachineLines.reduce(0.0) {
            $0 + ($1.totalMachineCost ?? 0) + ($1.fuelCost ?? 0)
        }

        let linkedTripIDs = Set(trips.filter { $0.workTaskId == task.id }.map(\.id))
        let linkedAllocations = tripCostAllocations.filter { linkedTripIDs.contains($0.tripId) }
        let linkedTrip = linkedAllocations.reduce(0.0) { $0 + ($1.totalCost ?? 0) }
        let allocatedTripIDs = Set(linkedAllocations.map(\.tripId))
        let tripIsComplete = linkedTripIDs.isSubset(of: allocatedTripIDs)
            && linkedAllocations.allSatisfy { $0.totalCost != nil }

        let material = includeMaterials
            ? WorkTaskMaterialCosting.total(materials, for: task.id)
            : 0
        let labourDecimal = decimal(labour ?? 0)
        let machineDecimal = decimal(manualMachine)
        let tripDecimal = decimal(linkedTrip)

        return combine(
            labourCost: labourDecimal,
            manualMachineCost: machineDecimal,
            linkedTripCost: tripDecimal,
            materialCost: material,
            isComplete: labourIsComplete && tripIsComplete
        )
    }

    static func combine(
        labourCost: Decimal,
        manualMachineCost: Decimal,
        linkedTripCost: Decimal,
        materialCost: Decimal,
        isComplete: Bool
    ) -> Result {
        Result(
            labourCost: labourCost,
            manualMachineCost: manualMachineCost,
            linkedTripCost: linkedTripCost,
            materialCost: materialCost,
            totalCost: labourCost + manualMachineCost + linkedTripCost + materialCost,
            isComplete: isComplete
        )
    }

    static func decimal(_ value: Double) -> Decimal {
        guard value.isFinite else { return 0 }
        return Decimal(string: String(value)) ?? 0
    }
}

@MainActor
extension WorkTask {
    /// Resolves this task from the store's durable child caches. Material cost is
    /// passed explicitly so callers cannot accidentally bypass the temporary gate.
    func costRollup(in store: MigratedDataStore, includeMaterials: Bool) -> WorkTaskCostRollup.Result {
        WorkTaskCostRollup.resolve(
            task: self,
            labourLines: store.workTaskLabourLines,
            machineLines: store.workTaskMachineLines,
            trips: store.trips,
            tripCostAllocations: store.tripCostAllocations,
            materials: store.workTaskMaterials,
            includeMaterials: includeMaterials
        )
    }
}

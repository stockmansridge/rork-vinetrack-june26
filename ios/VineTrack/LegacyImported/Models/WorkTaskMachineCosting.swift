import Foundation

/// Draft-only calculations. Saved amounts are snapshots, never recalculated by sync.
nonisolated enum WorkTaskMachineCosting {
    struct Result: Equatable, Sendable {
        let fuelLitres: Double?
        let fuelCost: Double?
        let machineCharge: Double?
    }

    static func fuelRate(vineyardID: UUID, source: String?, equipmentID: UUID?, machines: [VineyardMachine], tractors: [Tractor]) -> Double? {
        guard let equipmentID else { return nil }
        let machine = machines.first {
            $0.vineyardId == vineyardID && (source == "tractor" ? $0.legacyTractorId == equipmentID : source == "vineyard_machine" && $0.id == equipmentID)
        }
        if let rate = valid(machine?.fuelUsageLPerHour), rate > 0 { return rate }
        let tractorID = source == "tractor" ? equipmentID : machine?.legacyTractorId
        return valid(tractors.first { $0.vineyardId == vineyardID && $0.id == tractorID }?.fuelUsageLPerHour).flatMap { $0 > 0 ? $0 : nil }
    }

    @MainActor static func fuelPrice(vineyardID: UUID, purchases: [FuelPurchase]) -> Double? {
        let scoped = purchases.filter { $0.vineyardId == vineyardID && $0.volumeLitres.isFinite && $0.volumeLitres > 0 && $0.totalCost.isFinite && $0.totalCost >= 0 }
        return valid(TripCostService.weightedFuelCostPerLitre(scoped)).flatMap { $0 > 0 ? $0 : nil }
    }

    static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func product(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs = valid(lhs), let rhs = valid(rhs) else { return nil }
        return valid(lhs * rhs)
    }

    static func resolve(duration: Double?, engineHours: Double?, fuelRate: Double?, fuelPrice: Double?, hourlyRate: Double?, fuelOverride: Double?, fuelCostOverride: Double?, machineOverride: Double?) -> Result {
        let configuredRate = valid(fuelRate).flatMap { $0 > 0 ? $0 : nil }
        let price = valid(fuelPrice).flatMap { $0 > 0 ? $0 : nil }
        let fuel = fuelOverride ?? product(engineHours ?? duration, configuredRate)
        return Result(fuelLitres: fuel, fuelCost: fuelCostOverride ?? product(fuel, price), machineCharge: machineOverride ?? product(duration, hourlyRate))
    }
}

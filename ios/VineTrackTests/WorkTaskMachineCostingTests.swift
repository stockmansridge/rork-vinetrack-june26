import Foundation
import Testing
@testable import VineTrack

@MainActor
struct WorkTaskMachineCostingTests {
    @Test func automaticFuelAndCharges() {
        let result = WorkTaskMachineCosting.resolve(duration: 2, engineHours: nil, fuelRate: 8, fuelPrice: 2, hourlyRate: 40, fuelOverride: nil, fuelCostOverride: nil, machineOverride: nil)
        #expect(result.fuelLitres == 16)
        #expect(result.fuelCost == 32)
        #expect(result.machineCharge == 80)
    }
    @Test func engineHoursPreferredIncludingZero() {
        let used = WorkTaskMachineCosting.resolve(duration: 2, engineHours: 1, fuelRate: 8, fuelPrice: 2, hourlyRate: 40, fuelOverride: nil, fuelCostOverride: nil, machineOverride: nil)
        #expect(used.fuelLitres == 8)
        #expect(used.machineCharge == 80)
        let zero = WorkTaskMachineCosting.resolve(duration: 2, engineHours: 0, fuelRate: 8, fuelPrice: 2, hourlyRate: 40, fuelOverride: nil, fuelCostOverride: nil, machineOverride: nil)
        #expect(zero.fuelLitres == 0)
    }
    @Test func missingConfigurationIsNotZero() {
        let result = WorkTaskMachineCosting.resolve(duration: 2, engineHours: nil, fuelRate: nil, fuelPrice: nil, hourlyRate: nil, fuelOverride: nil, fuelCostOverride: nil, machineOverride: nil)
        #expect(result.fuelLitres == nil)
        #expect(result.fuelCost == nil)
        #expect(result.machineCharge == nil)
    }
    @Test func manualQuantityWithMissingRate() {
        let result = WorkTaskMachineCosting.resolve(duration: 2, engineHours: nil, fuelRate: nil, fuelPrice: 2, hourlyRate: 40, fuelOverride: 10, fuelCostOverride: nil, machineOverride: nil)
        #expect(result.fuelLitres == 10)
        #expect(result.fuelCost == 20)
    }
    @Test func missingPriceLeavesCostUnset() {
        let result = WorkTaskMachineCosting.resolve(duration: 2, engineHours: nil, fuelRate: 8, fuelPrice: nil, hourlyRate: 40, fuelOverride: nil, fuelCostOverride: nil, machineOverride: nil)
        #expect(result.fuelLitres == 16)
        #expect(result.fuelCost == nil)
    }
    @Test func allOverridesSurviveEquipmentAndPriceChanges() {
        let result = WorkTaskMachineCosting.resolve(duration: 9, engineHours: 4, fuelRate: 30, fuelPrice: 7, hourlyRate: 40, fuelOverride: 10.123456789, fuelCostOverride: 19.123456789, machineOverride: 55.123456789)
        #expect(result.fuelLitres == 10.123456789)
        #expect(result.fuelCost == 19.123456789)
        #expect(result.machineCharge == 55.123456789)
    }
    @Test func zeroOverridesRemainExplicit() {
        let result = WorkTaskMachineCosting.resolve(duration: 2, engineHours: nil, fuelRate: 8, fuelPrice: 2, hourlyRate: 40, fuelOverride: 0, fuelCostOverride: 0, machineOverride: 0)
        #expect(result == .init(fuelLitres: 0, fuelCost: 0, machineCharge: 0))
    }
    @Test func clearingOverridesRestoresAutomatic() {
        let result = WorkTaskMachineCosting.resolve(duration: 2, engineHours: nil, fuelRate: 12, fuelPrice: 3, hourlyRate: 40, fuelOverride: nil, fuelCostOverride: nil, machineOverride: nil)
        #expect(result == .init(fuelLitres: 24, fuelCost: 72, machineCharge: 80))
    }
    @Test func zeroRateIsUnconfiguredAndOverflowUnavailable() {
        #expect(WorkTaskMachineCosting.resolve(duration: 2, engineHours: nil, fuelRate: 0, fuelPrice: 2, hourlyRate: 40, fuelOverride: nil, fuelCostOverride: nil, machineOverride: nil).fuelLitres == nil)
        #expect(WorkTaskMachineCosting.product(Double.greatestFiniteMagnitude, 2) == nil)
        #expect(WorkTaskMachineCosting.valid(-1) == nil)
    }
    @Test func equipmentIsScopedAndLegacyMappingWorks() {
        let vineyard = UUID(), other = UUID(), id = UUID(), tractor = UUID()
        let machine = VineyardMachine(id: id, vineyardId: vineyard, fuelUsageLPerHour: 8, legacyTractorId: tractor)
        #expect(WorkTaskMachineCosting.fuelRate(vineyardID: vineyard, source: "vineyard_machine", equipmentID: id, machines: [machine], tractors: []) == 8)
        #expect(WorkTaskMachineCosting.fuelRate(vineyardID: vineyard, source: "tractor", equipmentID: tractor, machines: [machine], tractors: []) == 8)
        #expect(WorkTaskMachineCosting.fuelRate(vineyardID: other, source: "tractor", equipmentID: tractor, machines: [machine], tractors: []) == nil)
        #expect(WorkTaskMachineCosting.fuelRate(vineyardID: vineyard, source: "tractor", equipmentID: nil, machines: [machine], tractors: []) == nil)
    }
    @Test func weightedPriceIsVineyardScoped() {
        let vineyard = UUID()
        let purchases = [FuelPurchase(vineyardId: vineyard, volumeLitres: 10, totalCost: 10), FuelPurchase(vineyardId: vineyard, volumeLitres: 30, totalCost: 70), FuelPurchase(vineyardId: UUID(), volumeLitres: 100, totalCost: 900)]
        #expect(WorkTaskMachineCosting.fuelPrice(vineyardID: vineyard, purchases: purchases) == 2)
        #expect(WorkTaskMachineCosting.fuelPrice(vineyardID: UUID(), purchases: purchases) == nil)
    }
    @Test func durableSnapshotAndCanonicalPayload() throws {
        let line = WorkTaskMachineLine(workTaskId: UUID(), vineyardId: UUID(), durationHours: 2, engineHoursUsed: 0, fuelLitres: 16, fuelCost: 0, hourlyMachineRate: 40, totalMachineCost: 80)
        let data = try JSONEncoder().encode(line)
        let reopened = try JSONDecoder().decode(WorkTaskMachineLine.self, from: data)
        #expect(reopened == line)
        let payload = BackendWorkTaskMachineLine.upsert(from: reopened, createdBy: nil, updatedBy: nil, clientUpdatedAt: Date())
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(object["engine_hours_used"] as? Double == 0)
        #expect(object["fuel_litres"] as? Double == 16)
        #expect(object["fuel_cost"] as? Double == 0)
        #expect(object["total_machine_cost"] as? Double == 80)
    }
    @Test func localRepositoryReopensEditsAndDeletesWithoutRepricing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vineyard = UUID(), otherVineyard = UUID()
        let savedDate = Date(timeIntervalSince1970: 1_791_417_600)
        let line = WorkTaskMachineLine(workTaskId: UUID(), vineyardId: vineyard, workDate: savedDate, durationHours: 2, engineHoursUsed: 0, fuelLitres: 16.123456789, fuelCost: 0, hourlyMachineRate: 40, totalMachineCost: 80)
        let other = WorkTaskMachineLine(workTaskId: UUID(), vineyardId: otherVineyard, workDate: savedDate)
        let repository = WorkTaskMachineLineRepository(persistence: PersistenceStore(directory: directory))
        repository.saveSlice([other], for: otherVineyard)
        repository.saveSlice([line], for: vineyard)
        let reopened = WorkTaskMachineLineRepository(persistence: PersistenceStore(directory: directory))
        #expect(reopened.load(for: vineyard) == [line])
        var edited = line
        edited.fuelCost = 19.123456789
        reopened.saveSlice([edited], for: vineyard)
        let restarted = WorkTaskMachineLineRepository(persistence: PersistenceStore(directory: directory))
        #expect(restarted.load(for: vineyard) == [edited])
        restarted.saveSlice([], for: vineyard)
        #expect(restarted.load(for: vineyard).isEmpty)
        #expect(restarted.load(for: otherVineyard) == [other])
    }
    @Test func clearedFieldsEncodeNullForReplay() throws {
        let line = WorkTaskMachineLine(workTaskId: UUID(), vineyardId: UUID())
        let payload = BackendWorkTaskMachineLine.upsert(from: line, createdBy: nil, updatedBy: nil, clientUpdatedAt: Date())
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        for key in ["engine_hours_used", "fuel_litres", "fuel_cost", "hourly_machine_rate", "total_machine_cost"] { #expect(object[key] is NSNull) }
    }
    @Test func missingAmountsKeepSummaryIncomplete() {
        let task = WorkTask()
        let line = WorkTaskMachineLine(workTaskId: task.id, vineyardId: task.vineyardId, fuelLitres: 16, totalMachineCost: 80)
        let result = WorkTaskCostRollup.resolve(task: task, labourLines: [], machineLines: [line], trips: [], tripCostAllocations: [], materials: [], includeMaterials: false)
        #expect(!result.isComplete)
        #expect(result.costPerHectare(areaHectares: 2) == nil)
    }
    @Test func linkedTripCostsRemainSeparate() {
        let task = WorkTask()
        let trip = Trip(vineyardId: task.vineyardId, workTaskId: task.id)
        let allocation = TripCostAllocation(vineyardId: task.vineyardId, tripId: trip.id, seasonYear: 2026, labourCost: 5, fuelCost: 7, totalCost: 12)
        let machine = WorkTaskMachineLine(workTaskId: task.id, vineyardId: task.vineyardId, fuelCost: 32, totalMachineCost: 80)
        let result = WorkTaskCostRollup.resolve(task: task, labourLines: [], machineLines: [machine], trips: [trip], tripCostAllocations: [allocation], materials: [], includeMaterials: false)
        #expect(result.linkedTripCost == 12)
        #expect(result.manualMachineCost == 112)
        #expect(result.totalCost == 124)
    }
    @Test func taskRollupIncludesSeparateFuelOnce() {
        let task = WorkTask()
        let machine = WorkTaskMachineLine(workTaskId: task.id, vineyardId: task.vineyardId, durationHours: 2, fuelCost: 32, hourlyMachineRate: 40, totalMachineCost: 80)
        let labour = WorkTaskLabourLine(workTaskId: task.id, vineyardId: task.vineyardId, hoursPerWorker: 2, hourlyRate: 38)
        let result = WorkTaskCostRollup.resolve(task: task, labourLines: [labour], machineLines: [machine], trips: [], tripCostAllocations: [], materials: [], includeMaterials: false)
        #expect(result.labourCost == 76)
        #expect(result.manualMachineCost == 112)
        #expect(result.totalCost == 188)
        #expect(result.costPerHectare(areaHectares: 2) == 94)
    }
}

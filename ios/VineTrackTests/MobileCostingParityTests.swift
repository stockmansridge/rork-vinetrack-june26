import Foundation
import Testing
@testable import VineTrack

@MainActor
struct MobileCostingParityTests {
    @Test func mulchingFuelOnlyIsComplete() {
        let task = WorkTask()
        let labour = WorkTaskLabourLine(workTaskId: task.id, vineyardId: task.vineyardId, hoursPerWorker: 2, hourlyRate: 38)
        let machine = WorkTaskMachineLine(workTaskId: task.id, vineyardId: task.vineyardId, durationHours: 2, fuelLitres: 13.6, fuelCost: 20.79)
        let result = WorkTaskCostRollup.resolve(task: task, labourLines: [labour], machineLines: [machine], trips: [], tripCostAllocations: [], materials: [], includeMaterials: false)
        #expect(result.totalCost == Decimal(string: "96.79")!)
        #expect(result.isComplete)
    }
    @Test func savedHourlyTotalsWin() throws {
        let task = WorkTask()
        let json = """
        {"id":"\(UUID())","work_task_id":"\(task.id)","vineyard_id":"\(task.vineyardId)","worker_count":1,"hours_per_worker":2,"hourly_rate":999,"total_hours":10,"total_cost":76}
        """
        let remote = try JSONDecoder().decode(BackendWorkTaskLabourLine.self, from: Data(json.utf8))
        let line = remote.toWorkTaskLabourLine()
        let reopened = try JSONDecoder().decode(WorkTaskLabourLine.self, from: JSONEncoder().encode(line))
        #expect(PieceRateCosting.effectiveLabourCost(task: task, labourLines: [reopened]) == 76)
        #expect(WorkTaskLabourCosting.personHours(reopened) == 10)
        var unchanged = reopened
        unchanged.workerCount = line.workerCount
        unchanged.hoursPerWorker = line.hoursPerWorker
        unchanged.hourlyRate = line.hourlyRate
        #expect(WorkTaskLabourCosting.lineCost(unchanged) == 76)
        unchanged.hoursPerWorker = 3
        #expect(unchanged.savedTotalCost == nil && unchanged.savedTotalHours == nil)
    }
    @Test func pieceRateExcludesHourlyAndLegacy() {
        let task = WorkTask(durationHours: 10, resources: [.init(hourlyRate: 36, count: 14)], costingMethodRaw: "piece_rate", pieceRatePerVine: 0.5, pieceVineCount: 200)
        let line = WorkTaskLabourLine(workTaskId: task.id, vineyardId: task.vineyardId, hourlyRate: 999, savedTotalCost: 999)
        #expect(PieceRateCosting.effectiveLabourCost(task: task, labourLines: [line]) == 100)
        #expect(PieceRateCosting.roundedToCents(9.995) == 10)
        #expect(PieceRateCosting.roundedToCents(-9.995) == -10)
        #expect(PieceRateCosting.cost(vineCount: 3, ratePerVine: 0.335) == 1.01)
    }
    @Test func legacyOnlyWithoutCanonicalLines() {
        let task = WorkTask(durationHours: 10, resources: [.init(hourlyRate: 36, count: 14)])
        #expect(PieceRateCosting.effectiveLabourCost(task: task, labourLines: []) == 5040)
        let unrated = WorkTaskLabourLine(workTaskId: task.id, vineyardId: task.vineyardId, hoursPerWorker: 2)
        #expect(PieceRateCosting.effectiveLabourCost(task: task, labourLines: [unrated]) == nil)
        #expect(PieceRateCosting.effectiveCostsByWorkTask(tasks: [task], labourLines: [])[task.id] == 5040)
        let activity = PieceRateCosting.resolveActivityLabour(task: task, lines: [], legacyHours: 1, legacyRate: 1)
        #expect(activity.cost == 5040 && activity.hours == 140)
        #expect(PieceRateCosting.resolveActivityLabour(task: task, lines: [unrated], legacyHours: 1, legacyRate: 1).cost == nil)
    }
    @Test func pruningUsesRepresentedTaskLabourOnce() {
        let task = WorkTask()
        let line = WorkTaskLabourLine(workTaskId: task.id, vineyardId: task.vineyardId, hourlyRate: 1, savedTotalCost: 700)
        let result = PruningActivityLabourCosting.resolve(task: task, activityLines: [], taskLines: [line], legacyHours: 20, legacyRate: 100)
        #expect(result.cost == 700)
    }
    @Test func gpsMarkerAndSlicesCountOnce() {
        let task = WorkTask(), trip = Trip()
        var linked = trip; linked.vineyardId = task.vineyardId; linked.workTaskId = task.id
        let marker = TripCostAllocation(vineyardId: task.vineyardId, tripId: trip.id, seasonYear: 2027, labourCost: 10, totalCost: 10, allocationBasis: .labourSnapshot)
        let slice = TripCostAllocation(vineyardId: task.vineyardId, tripId: trip.id, seasonYear: 2027, labourCost: 10, fuelCost: 2, totalCost: 12)
        let result = WorkTaskCostRollup.resolve(task: task, labourLines: [], machineLines: [], trips: [linked], tripCostAllocations: [marker, slice, slice], materials: [], includeMaterials: false)
        #expect(result.linkedTripCost == 12)
    }
    @Test func deletedParentsExcludedWithoutDeletingAllocations() {
        let vineyard = UUID()
        let rows = [TripCostAllocation(vineyardId: vineyard, tripId: UUID(uuidString: "1423c592-a4ee-4b9e-ab58-30edc7101b8d")!, seasonYear: 2027, totalCost: 0.43), TripCostAllocation(vineyardId: vineyard, tripId: UUID(uuidString: "a373b464-4b5f-4e45-82d1-7d8e6213aad4")!, seasonYear: 2027, totalCost: 0.39)]
        #expect(CostingReadAuthority.allocations(rows, trips: []).isEmpty)
        #expect(rows.count == 2)
        #expect(abs(rows.compactMap(\.totalCost).reduce(0, +) - 0.82) < 0.000001)
    }
    @Test func frozenMaterialsContributeOnce() {
        let task = WorkTask()
        let material = WorkTaskMaterial(workTaskId: task.id, vineyardId: task.vineyardId, materialName: "Post", unit: "Each", quantity: 2, unitCost: 90)
        let result = WorkTaskCostRollup.resolve(task: task, labourLines: [], machineLines: [], trips: [], tripCostAllocations: [], materials: [material], includeMaterials: true)
        #expect(result.totalCost == 180)
        #expect(result.materialCost == 180)
    }
    @Test func machineAndFuelAreIndependentSavedComponents() {
        let task = WorkTask()
        let machine = WorkTaskMachineLine(workTaskId: task.id, vineyardId: task.vineyardId, durationHours: 99, fuelCost: 20.79, hourlyMachineRate: 999, totalMachineCost: 50)
        let result = WorkTaskCostRollup.resolve(task: task, labourLines: [], machineLines: [machine], trips: [], tripCostAllocations: [], materials: [], includeMaterials: false)
        #expect(result.manualMachineCost == Decimal(string: "70.79")!)
        #expect(result.isComplete)
    }
    @Test func optionalComponentsDifferFromUnresolvedComponents() {
        let task = WorkTask()
        let chargeOnly = WorkTaskMachineLine(workTaskId: task.id, vineyardId: task.vineyardId, totalMachineCost: 50)
        #expect(CostingReadAuthority.machineComplete(chargeOnly))
        var missingFuel = chargeOnly; missingFuel.fuelLitres = 13.6
        #expect(!CostingReadAuthority.machineComplete(missingFuel))
        var missingCharge = chargeOnly; missingCharge.totalMachineCost = nil; missingCharge.hourlyMachineRate = 40; missingCharge.fuelCost = 20.79
        #expect(!CostingReadAuthority.machineComplete(missingCharge))
        #expect(!CostingReadAuthority.machineComplete(.init(workTaskId: task.id, vineyardId: task.vineyardId)))
    }
    @Test func fullMultiBlockAreaNotPrimaryOnly() {
        let task = WorkTask(), a = UUID(), b = UUID()
        var first = Paddock(id: a, vineyardId: task.vineyardId); first.savedAreaHa = 1.804291796875
        var second = Paddock(id: b, vineyardId: task.vineyardId); second.savedAreaHa = 3.85180625
        let links = [WorkTaskPaddock(workTaskId: task.id, vineyardId: task.vineyardId, paddockId: a), WorkTaskPaddock(workTaskId: task.id, vineyardId: task.vineyardId, paddockId: b)]
        let area = CostingReadAuthority.taskArea(task: task, links: links, paddocks: [first, second])
        #expect(area == 5.656098046875)
        #expect(abs(4585 / area! - 810.63) < 0.01)
    }
    @Test func savedTaskAreaWins() {
        let task = WorkTask(areaHa: 1.075619921875)
        let link = WorkTaskPaddock(workTaskId: task.id, vineyardId: task.vineyardId, paddockId: UUID(), areaHa: 9)
        #expect(CostingReadAuthority.taskArea(task: task, links: [link], paddocks: []) == task.areaHa)
        #expect(abs(315 / task.areaHa! - 292.85) < 0.01)
    }
    @Test func completeSavedLinksWin() {
        let task = WorkTask(), a = UUID(), b = UUID()
        let links = [WorkTaskPaddock(workTaskId: task.id, vineyardId: task.vineyardId, paddockId: a, areaHa: 0.414428125), WorkTaskPaddock(workTaskId: task.id, vineyardId: task.vineyardId, paddockId: b, areaHa: 0.906815625)]
        let area = CostingReadAuthority.taskArea(task: task, links: links, paddocks: [])!
        #expect(abs(area - 1.32124375) < 0.00000001)
        #expect(abs(3465 / area - 2622.53) < 0.01)
    }
    @Test func mappedGeometryFallbackNeverWritesHistory() {
        let task = WorkTask(), id = UUID()
        let block = Paddock(id: id, vineyardId: task.vineyardId, polygonPoints: [.init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.001), .init(latitude: 0.001, longitude: 0.001), .init(latitude: 0.001, longitude: 0)])
        let link = WorkTaskPaddock(workTaskId: task.id, vineyardId: task.vineyardId, paddockId: id)
        #expect(CostingReadAuthority.taskArea(task: task, links: [link], paddocks: [block]) == block.areaHectares)
        #expect(task.areaHa == nil && link.areaHa == nil)
        #expect(block.areaHectares > 0)
        var shiraz = block; shiraz.savedAreaHa = 1.075619921875
        #expect(abs(700 / CostingReadAuthority.physicalArea(shiraz)! - 650.79) < 0.01)
    }
    @Test func partialAreaUnavailable() {
        let task = WorkTask(), a = UUID(), b = UUID()
        let links = [WorkTaskPaddock(workTaskId: task.id, vineyardId: task.vineyardId, paddockId: a, areaHa: 1), WorkTaskPaddock(workTaskId: task.id, vineyardId: task.vineyardId, paddockId: b)]
        var block = Paddock(id: a, vineyardId: task.vineyardId); block.savedAreaHa = 1
        #expect(CostingReadAuthority.taskArea(task: task, links: links, paddocks: [block]) == nil)
        #expect(CostingReadAuthority.physicalArea([block, Paddock(vineyardId: task.vineyardId)]) == nil)
    }
    @Test func tripCountIsDistinctAcrossRows() {
        let trip = Trip()
        let rows = [TripCostAllocation(vineyardId: trip.vineyardId, tripId: trip.id, seasonYear: 2027), TripCostAllocation(vineyardId: trip.vineyardId, tripId: trip.id, seasonYear: 2027)]
        #expect(CostingReadAuthority.distinctTrips(rows) == 1)
    }
    @Test func physicalAreaCountedOnce() {
        var block = Paddock(); block.savedAreaHa = 6.14908359375
        #expect(CostingReadAuthority.physicalArea([block, block]) == block.savedAreaHa)
    }
    @Test func repeatOperationsOnlyIncreaseTreatedArea() {
        var block = Paddock(); block.savedAreaHa = 6.14908359375
        let rows = (0..<3).map { _ in TripCostAllocation(vineyardId: block.vineyardId, tripId: UUID(), seasonYear: 2027, allocationAreaHa: block.savedAreaHa) }
        #expect(rows.compactMap(\.allocationAreaHa).reduce(0, +) > 18)
        #expect(CostingReadAuthority.physicalArea([block, block, block]) == 6.14908359375)
    }
    @Test func stockmansAggregateTotal() {
        // Owner-supplied aggregate fixture, not invented individual production tasks.
        let task = WorkTask()
        let line = WorkTaskLabourLine(workTaskId: task.id, vineyardId: task.vineyardId, savedTotalHours: 543.5, savedTotalCost: 18937)
        let machine = WorkTaskMachineLine(workTaskId: task.id, vineyardId: task.vineyardId, fuelLitres: 13.6, fuelCost: 20.79)
        let result = WorkTaskCostRollup.resolve(task: task, labourLines: [line], machineLines: [machine], trips: [], tripCostAllocations: [], materials: [], includeMaterials: false)
        #expect(result.totalCost == Decimal(string: "18957.79")!)
        #expect(WorkTaskLabourCosting.totalPersonHours([line]) == 543.5)
        let functionLabour: [Double] = [10678, 4585, 3465, 133, 76]
        #expect(functionLabour.reduce(0.0, +) == 18937)
    }
    @Test func stockmansSeasonCostPerPhysicalHectare() {
        var block = Paddock(); block.savedAreaHa = 6.14908359375
        let total = WorkTaskCostRollup.combine(labourCost: 18937, manualMachineCost: Decimal(string: "20.79")!, linkedTripCost: 0, materialCost: 0, isComplete: true)
        let rate = total.costPerHectare(areaHectares: CostingReadAuthority.physicalArea([block])!)!
        #expect(abs(NSDecimalNumber(decimal: rate).doubleValue - 3083.03) < 0.01)
        #expect(abs(96.79 / block.savedAreaHa! - 15.74) < 0.01)
    }
}

package com.rork.vinetrack.data

import com.rork.vinetrack.data.material.WorkTaskMaterial
import com.rork.vinetrack.data.model.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.math.BigDecimal

class MobileCostingParityTest {
    @Test fun mulchingFuelOnlyIsComplete() {
        val task = WorkTask(id = "task", vineyardId = "vineyard")
        val labour = WorkTaskLabourLine(id = "labour", workTaskId = task.id, vineyardId = task.vineyardId, hoursPerWorker = 2.0, hourlyRate = 38.0)
        val machine = WorkTaskMachineLine(id = "machine", workTaskId = task.id, vineyardId = task.vineyardId, durationHours = 2.0, fuelLitres = 13.6, fuelCost = 20.79)
        val result = WorkTaskCostRollup.resolve(task, listOf(labour), listOf(machine), emptyList(), emptyList(), emptyList(), false)
        assertEquals(BigDecimal("96.79"), result.totalCost)
        assertTrue(result.isComplete)
    }
    @Test fun savedHourlyTotalsWin() {
        val task = WorkTask(id = "task", vineyardId = "vineyard")
        val line = Json.decodeFromString<WorkTaskLabourLine>("""{"id":"line","work_task_id":"task","vineyard_id":"vineyard","worker_count":1,"hours_per_worker":2,"hourly_rate":999,"total_hours":10,"total_cost":76}""")
        val reopened = Json.decodeFromString<WorkTaskLabourLine>(Json.encodeToString(WorkTaskLabourLine.serializer(), line))
        assertEquals(76.0, PieceRateCosting.effectiveLabourCost(task, listOf(reopened))!!, 0.0)
        assertEquals(10.0, WorkTaskLabourCosting.personHours(reopened), 0.0)
        assertEquals(76.0, PieceRateCosting.effectiveLabourCost(task, listOf(reopened.copy(hourlyRate = null)))!!, 0.0)
    }
    @Test fun pieceRateExcludesHourlyAndLegacy() {
        val task = WorkTask(id = "task", vineyardId = "vineyard", durationHours = 10.0, resources = listOf(WorkTaskResource(hourlyRate = 36.0, count = 14)), costingMethod = "piece_rate", pieceRatePerVine = 0.5, pieceVineCount = 200)
        val line = WorkTaskLabourLine(id = "line", workTaskId = task.id, vineyardId = task.vineyardId, hourlyRate = 999.0, totalCost = 999.0)
        assertEquals(100.0, PieceRateCosting.effectiveLabourCost(task, listOf(line))!!, 0.0)
        assertEquals(10.0, PieceRateCosting.roundedToCents(9.995), 0.0)
        assertEquals(-10.0, PieceRateCosting.roundedToCents(-9.995), 0.0)
        assertEquals(1.01, PieceRateCosting.cost(3, 0.335)!!, 0.0)
    }
    @Test fun legacyOnlyWithoutCanonicalLines() {
        val task = Json.decodeFromString<WorkTask>("""{"id":"task","vineyard_id":"vineyard","duration_hours":10,"resources":[{"hourlyRate":36,"count":14}],"area_ha":1.075619921875}""")
        assertEquals(5040.0, PieceRateCosting.effectiveLabourCost(task, emptyList())!!, 0.0)
        val unrated = WorkTaskLabourLine(id = "line", workTaskId = task.id, vineyardId = task.vineyardId, hoursPerWorker = 2.0)
        assertNull(PieceRateCosting.effectiveLabourCost(task, listOf(unrated)))
        assertEquals(5040.0, PieceRateCosting.effectiveCostsByWorkTask(listOf(task), emptyList())[task.id]!!, 0.0)
        assertEquals(1.075619921875, task.areaHa!!, 0.0)
        val activity = PieceRateCosting.resolveActivityLabour(task, emptyList(), 1.0, 1.0)
        assertEquals(5040.0, activity.cost!!, 0.0)
        assertEquals(140.0, activity.hours!!, 0.0)
        assertNull(PieceRateCosting.resolveActivityLabour(task, listOf(unrated), 1.0, 1.0).cost)
    }
    @Test fun pruningUsesRepresentedTaskLabourOnce() {
        val task = WorkTask(id = "task", vineyardId = "vineyard")
        val line = WorkTaskLabourLine(id = "line", workTaskId = task.id, vineyardId = task.vineyardId, hourlyRate = 1.0, totalCost = 700.0)
        val result = PruningActivityLabourCosting.resolve(task, emptyList(), listOf(line), 20.0, 100.0)
        assertEquals(700.0, result.cost!!, 0.0)
    }
    @Test fun gpsMarkerAndSlicesCountOnce() {
        val task = WorkTask(id = "task", vineyardId = "vineyard")
        val trip = Trip(id = "trip", vineyardId = task.vineyardId, workTaskId = task.id)
        val marker = TripCostAllocation(id = "marker", vineyardId = task.vineyardId, tripId = trip.id, totalCostRaw = "10", labourCostRaw = "10", allocationBasis = "labour_snapshot")
        val slice = TripCostAllocation(id = "slice", vineyardId = task.vineyardId, tripId = trip.id, totalCostRaw = "12", labourCostRaw = "10", fuelCostRaw = "2")
        val result = WorkTaskCostRollup.resolve(task, emptyList(), emptyList(), listOf(trip), listOf(marker, slice, slice), emptyList(), false)
        assertEquals(BigDecimal("12.00"), result.linkedTripCost)
    }
    @Test fun deletedParentsExcludedWithoutDeletingAllocations() {
        val rows = listOf(TripCostAllocation(id = "a", vineyardId = "vineyard", tripId = "1423c592-a4ee-4b9e-ab58-30edc7101b8d", totalCostRaw = "0.43"), TripCostAllocation(id = "b", vineyardId = "vineyard", tripId = "a373b464-4b5f-4e45-82d1-7d8e6213aad4", totalCostRaw = "0.39"))
        val deleted = rows.map { Trip(id = it.tripId, vineyardId = it.vineyardId, deletedAt = "2026-10-23") }
        assertTrue(CostingReadAuthority.allocations(rows, deleted).isEmpty())
        assertTrue(CostingReadAuthority.allocations(rows, emptyList()).isEmpty())
        assertEquals(2, rows.size)
        assertEquals(BigDecimal("0.82"), rows.sumOf { it.totalCost!! })
    }
    @Test fun frozenMaterialsContributeOnce() {
        val task = WorkTask(id = "task", vineyardId = "vineyard")
        val material = WorkTaskMaterial(id = "post", workTaskId = task.id, vineyardId = task.vineyardId, materialName = "Post", quantityRaw = "2", unitCostRaw = "90", totalCostRaw = "180")
        val result = WorkTaskCostRollup.resolve(task, emptyList(), emptyList(), emptyList(), emptyList(), listOf(material), true)
        assertEquals(BigDecimal("180.00"), result.totalCost)
        assertEquals(BigDecimal("180.00"), result.materialCost)
    }
    @Test fun machineAndFuelAreIndependentSavedComponents() {
        val task = WorkTask(id = "task", vineyardId = "vineyard")
        val machine = WorkTaskMachineLine(id = "machine", workTaskId = task.id, vineyardId = task.vineyardId, durationHours = 99.0, fuelCost = 20.79, hourlyMachineRate = 999.0, totalMachineCost = 50.0)
        val result = WorkTaskCostRollup.resolve(task, emptyList(), listOf(machine), emptyList(), emptyList(), emptyList(), false)
        assertEquals(BigDecimal("70.79"), result.manualMachineCost)
        assertTrue(result.isComplete)
    }
    @Test fun optionalComponentsDifferFromUnresolvedComponents() {
        val chargeOnly = WorkTaskMachineLine(id = "machine", workTaskId = "task", vineyardId = "vineyard", totalMachineCost = 50.0)
        assertTrue(CostingReadAuthority.machineComplete(chargeOnly))
        assertFalse(CostingReadAuthority.machineComplete(chargeOnly.copy(fuelLitres = 13.6)))
        assertFalse(CostingReadAuthority.machineComplete(chargeOnly.copy(totalMachineCost = null, hourlyMachineRate = 40.0, fuelCost = 20.79)))
        assertFalse(CostingReadAuthority.machineComplete(chargeOnly.copy(totalMachineCost = null)))
    }
    @Test fun fullMultiBlockAreaNotPrimaryOnly() {
        val task = WorkTask(id = "task", vineyardId = "vineyard", paddockId = "a")
        val first = Paddock(id = "a", vineyardId = task.vineyardId, name = "Pinot", savedAreaHa = 1.804291796875)
        val second = Paddock(id = "b", vineyardId = task.vineyardId, name = "Other", savedAreaHa = 3.85180625)
        val links = listOf(WorkTaskPaddock(id = "la", workTaskId = task.id, vineyardId = task.vineyardId, paddockId = "a"), WorkTaskPaddock(id = "lb", workTaskId = task.id, vineyardId = task.vineyardId, paddockId = "b"))
        val area = CostingReadAuthority.taskArea(task, links, listOf(first, second))!!
        assertEquals(5.656098046875, area, 0.00000001)
        assertEquals(810.63, 4585 / area, 0.01)
    }
    @Test fun savedTaskAreaWins() {
        val task = WorkTask(id = "task", vineyardId = "vineyard", areaHa = 1.075619921875)
        val link = WorkTaskPaddock(id = "link", workTaskId = task.id, vineyardId = task.vineyardId, paddockId = "a", areaHa = 9.0)
        assertEquals(task.areaHa, CostingReadAuthority.taskArea(task, listOf(link), emptyList()))
        assertEquals(292.85, 315 / task.areaHa!!, 0.01)
    }
    @Test fun completeSavedLinksWin() {
        val task = WorkTask(id = "task", vineyardId = "vineyard")
        val links = listOf(WorkTaskPaddock(id = "a", workTaskId = task.id, vineyardId = task.vineyardId, paddockId = "a", areaHa = 0.414428125), WorkTaskPaddock(id = "b", workTaskId = task.id, vineyardId = task.vineyardId, paddockId = "b", areaHa = 0.906815625))
        val area = CostingReadAuthority.taskArea(task, links, emptyList())!!
        assertEquals(1.32124375, area, 0.00000001)
        assertEquals(2622.53, 3465 / area, 0.01)
    }
    @Test fun mappedGeometryFallbackNeverWritesHistory() {
        val task = WorkTask(id = "task", vineyardId = "vineyard")
        val block = Paddock(id = "a", vineyardId = task.vineyardId, name = "Mapped", polygonPoints = listOf(CoordinatePoint(latitude = 0.0, longitude = 0.0), CoordinatePoint(latitude = 0.0, longitude = 0.001), CoordinatePoint(latitude = 0.001, longitude = 0.001), CoordinatePoint(latitude = 0.001, longitude = 0.0)))
        val link = WorkTaskPaddock(id = "link", workTaskId = task.id, vineyardId = task.vineyardId, paddockId = block.id)
        assertEquals(block.areaHectares, CostingReadAuthority.taskArea(task, listOf(link), listOf(block))!!, 0.0)
        assertNull(task.areaHa); assertNull(link.areaHa)
        assertTrue(block.areaHectares > 0)
        assertEquals(650.79, 700 / CostingReadAuthority.physicalArea(block.copy(savedAreaHa = 1.075619921875))!!, 0.01)
    }
    @Test fun partialAreaUnavailable() {
        val task = WorkTask(id = "task", vineyardId = "vineyard", paddockId = "a")
        val links = listOf(WorkTaskPaddock(id = "a", workTaskId = task.id, vineyardId = task.vineyardId, paddockId = "a", areaHa = 1.0), WorkTaskPaddock(id = "b", workTaskId = task.id, vineyardId = task.vineyardId, paddockId = "b"))
        val block = Paddock(id = "a", vineyardId = task.vineyardId, name = "Known", savedAreaHa = 1.0)
        assertNull(CostingReadAuthority.taskArea(task, links, listOf(block)))
        assertNull(CostingReadAuthority.physicalArea(listOf(block, block.copy(id = "b", savedAreaHa = null))))
    }
    @Test fun tripCountIsDistinctAcrossRows() {
        val rows = listOf(TripCostAllocation(id = "a", vineyardId = "vineyard", tripId = "trip"), TripCostAllocation(id = "b", vineyardId = "vineyard", tripId = "trip"))
        assertEquals(1, CostingReadAuthority.distinctTrips(rows))
    }
    @Test fun physicalAreaCountedOnce() {
        val block = Paddock(id = "block", vineyardId = "vineyard", name = "Stockmans", savedAreaHa = 6.14908359375)
        assertEquals(block.savedAreaHa, CostingReadAuthority.physicalArea(listOf(block, block)))
    }
    @Test fun repeatOperationsOnlyIncreaseTreatedArea() {
        val block = Paddock(id = "block", vineyardId = "vineyard", name = "Stockmans", savedAreaHa = 6.14908359375)
        val rows = (1..3).map { TripCostAllocation(id = "$it", vineyardId = block.vineyardId, tripId = "$it", allocationAreaHa = block.savedAreaHa) }
        assertTrue(rows.sumOf { it.allocationAreaHa!! } > 18)
        assertEquals(6.14908359375, CostingReadAuthority.physicalArea(listOf(block, block, block))!!, 0.0)
    }
    @Test fun stockmansAggregateTotal() {
        // Owner-supplied aggregate fixture, not invented individual production tasks.
        val task = WorkTask(id = "aggregate", vineyardId = "vineyard")
        val line = WorkTaskLabourLine(id = "line", workTaskId = task.id, vineyardId = task.vineyardId, totalHours = 543.5, totalCost = 18937.0)
        val machine = WorkTaskMachineLine(id = "machine", workTaskId = task.id, vineyardId = task.vineyardId, fuelLitres = 13.6, fuelCost = 20.79)
        val result = WorkTaskCostRollup.seasonTotal(listOf(task), listOf(line), listOf(machine), emptyList(), emptyList(), emptyList(), false)
        assertEquals(BigDecimal("18957.79"), result.totalCost)
        assertEquals(543.5, WorkTaskLabourCosting.totalPersonHours(listOf(line)), 0.0)
        assertEquals(18937.0, listOf(10678.0, 4585.0, 3465.0, 133.0, 76.0).sum(), 0.0)
    }
    @Test fun stockmansSeasonCostPerPhysicalHectare() {
        val block = Paddock(id = "block", vineyardId = "vineyard", name = "Stockmans", savedAreaHa = 6.14908359375)
        val task = WorkTask(id = "aggregate", vineyardId = block.vineyardId)
        val line = WorkTaskLabourLine(id = "line", workTaskId = task.id, vineyardId = task.vineyardId, totalCost = 18937.0)
        val machine = WorkTaskMachineLine(id = "machine", workTaskId = task.id, vineyardId = task.vineyardId, fuelCost = 20.79)
        val result = WorkTaskCostRollup.resolve(task, listOf(line), listOf(machine), emptyList(), emptyList(), emptyList(), false)
        val area = CostingReadAuthority.physicalArea(listOf(block))!!
        assertEquals(BigDecimal("3083.03"), result.costPerArea(area, area))
        assertEquals(15.74, 96.79 / area, 0.01)
    }
}
